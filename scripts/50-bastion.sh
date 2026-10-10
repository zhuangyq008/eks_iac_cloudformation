#!/usr/bin/env bash
# =============================================================================
#  50-bastion.sh —— 可选扩展：公有子网跳板 / 构建机（x86，SSH + SSM 登录）
#
#  Jenkins 通过 SSH 登录本机，上传 JAR 后调用 build-push-jar 构建多架构（amd64 + arm64）镜像并推送 ECR；
#  本机经 EKS 私有端点访问集群（kubectl，集群管理员）与节点；实例角色可读写账号内 S3 桶。
#  独立于 02-deploy / 99-destroy：不会被它们创建或删除。需要 EKS 集群已存在。
#  配置项见 config.env 的「扩展：跳板 / 构建机」段（未配置时使用下方默认值）。
#
#  用法（在 CloudShell 里执行）：
#    ./scripts/50-bastion.sh                 # 部署 / 更新（幂等），结束后自动安装构建工具并验收
#    ./scripts/50-bastion.sh info            # 打印登录方式与连接信息
#    ./scripts/50-bastion.sh jenkins         # 打印 Jenkins 需要配置的凭据 / 全局变量 / 主机指纹
#    ./scripts/50-bastion.sh key             # 重新取回 Jenkins 用的私钥到 ~/.ssh（CloudShell 里的文件丢了时用）
#    ./scripts/50-bastion.sh verify          # 验收：SSM / 22 端口 / docker / kubectl / ECR / S3
#    ./scripts/50-bastion.sh test-build      # 端到端冒烟：机上编译示例 JAR -> 多架构镜像推 ECR -> 在 x86（及 Graviton）节点跑起来
#    ./scripts/50-bastion.sh install-tools   # 重新安装跳板机上的 build-push-jar（脚本更新后）
#    ./scripts/50-bastion.sh ssh [命令]      # SSH 登录（需要私钥文件，见 BASTION_SSH_KEY_FILE）
#    ./scripts/50-bastion.sh ssm             # SSM Session Manager 登录（无需密钥、无需 22 端口）
#    ./scripts/50-bastion.sh allow-my-ip     # 把当前出口 IP/32 追加到 SSH 白名单
#    ./scripts/50-bastion.sh destroy         # 删除本栈（EIP、密钥对随栈删除）
#
#  密钥对由本栈自动创建（<PROJECT>-<ENV>-bastion-key），私钥托管在 SSM Parameter Store，
#  部署后自动保存到 ~/.ssh/<密钥名>.pem，Jenkins 凭据用它（见 docs/bastion-upgrade.md）。
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASTION_SUBNET_ID="${BASTION_SUBNET_ID:-}"
[[ -n "${BASTION_SUBNET_ID}" ]] || BASTION_SUBNET_ID="${PUBLIC_SUBNET_IDS%%,*}"
BASTION_INSTANCE_TYPE="${BASTION_INSTANCE_TYPE:-m7i.large}"
BASTION_SSH_CIDRS="${BASTION_SSH_CIDRS:-auto}"
BASTION_ROOT_VOLUME_SIZE="${BASTION_ROOT_VOLUME_SIZE:-100}"
BASTION_ALLOCATE_EIP="${BASTION_ALLOCATE_EIP:-true}"
BASTION_S3_ALLOW_DELETE="${BASTION_S3_ALLOW_DELETE:-false}"
BASTION_EKS_ACCESS="${BASTION_EKS_ACCESS:-admin}"
JENKINS_EGRESS_CIDRS="${JENKINS_EGRESS_CIDRS:-}"
STACK_BASTION="${STACK_BASTION:-${PROJECT}-${ENVIRONMENT}-bastion}"

SSH_USER="ec2-user"
BUILD_TOOL_SRC="${SCRIPT_DIR}/bastion/build-push-jar.sh"
BUILD_TOOL_DST="/usr/local/bin/build-push-jar"

out() { stack_output "${STACK_BASTION}" "$1"; }
# 已部署栈的参数值；栈不存在时为空
stack_param() {
  aws cloudformation describe-stacks --stack-name "${STACK_BASTION}" \
    --query "Stacks[0].Parameters[?ParameterKey=='$1'].ParameterValue | [0]" --output text 2>/dev/null \
    | grep -v '^None$' || true
}

# 私钥本地路径：CloudShell 只持久化 $HOME，所以放 ~/.ssh
key_file() {
  if [[ -n "${BASTION_SSH_KEY_FILE:-}" ]]; then echo "${BASTION_SSH_KEY_FILE}"; return; fi
  echo "${HOME}/.ssh/$(out KeyName).pem"
}

require_stack() {
  [[ "$(stack_status "${STACK_BASTION}")" == *_COMPLETE && "$(stack_status "${STACK_BASTION}")" != *ROLLBACK* ]] \
    || die "栈 ${STACK_BASTION} 未部署成功（当前 $(stack_status "${STACK_BASTION}")），先执行 ./scripts/50-bastion.sh"
}

ssh_whitelist() {
  aws ec2 describe-security-groups --group-ids "$(out SecurityGroupId)" \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].CidrIp' --output text | tr '\t' '\n'
}

# ---------------------------------------------------------------- SSH 白名单
resolve_ssh_cidrs() {
  local cidrs="${BASTION_SSH_CIDRS}"
  if [[ "${cidrs}" == "auto" ]]; then
    local ip; ip="$(my_egress_ip)"
    [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "BASTION_SSH_CIDRS=auto 但取不到当前出口 IP，请在 config.env 写死 CIDR"
    cidrs="${ip}/32"
  fi
  # Jenkins 要 SSH 进来，它的出口必须在白名单里：自动并入 JENKINS_EGRESS_CIDRS
  cidrs="${cidrs// /},${JENKINS_EGRESS_CIDRS// /}"
  python3 - "${cidrs}" <<'PY' || die "SSH 白名单不合法：${cidrs}（BASTION_SSH_CIDRS + JENKINS_EGRESS_CIDRS 合计最多 5 个 IPv4 CIDR）"
import ipaddress, sys
items = []
for c in sys.argv[1].split(","):
    if c and c not in items:
        ipaddress.IPv4Network(c, strict=True)
        items.append(c)
assert 1 <= len(items) <= 5
print(",".join(items))
PY
}

# ---------------------------------------------------------------- 交互式配置
# CloudShell 里直接运行时只问 Jenkins 出口 IP，回答写回 config.env，重跑不再询问；
# ASSUME_YES=1 或非终端时不询问，缺项直接报错。
interactive() { [[ -t 0 && "${ASSUME_YES:-0}" != "1" ]]; }

# save_config KEY=VALUE[#注释] ...：改写 config.env 里的同名行（带 #注释 时连注释一起换），没有则追加
save_config() {
  local cfg="${ROOT_DIR}/config.env"
  # 同一次运行只备份一次，保证 .bak 是运行前的原始文件
  [[ -n "${CONFIG_BACKED_UP:-}" ]] || { cp -p "${cfg}" "${cfg}.bak"; CONFIG_BACKED_UP=1; }
  python3 - "${cfg}" "$@" <<'PYEOF'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    v, _, note = v.partition("#")
    if note:
        pat, new = r'^%s=.*$' % re.escape(k), ('%s="%s"' % (k, v)).ljust(38) + ' # ' + note.strip()
        repl = lambda m, new=new: new
    else:
        pat, new = r'^(%s=)"[^"]*"' % re.escape(k), '%s="%s"' % (k, v)
        repl = lambda m, v=v: '%s"%s"' % (m.group(1), v)
    if re.search(pat, text, flags=re.M):
        text = re.sub(pat, repl, text, count=1, flags=re.M)
    else:
        text = text.rstrip("\n") + "\n" + new + "\n"
open(path, "w", encoding="utf-8").write(text)
PYEOF
  local kv names=()
  for kv in "$@"; do names+=("${kv%%=*}"); done
  ok "已写入 config.env：${names[*]}（原文件备份为 config.env.bak）"
}

# 把 "1.2.3.4, 5.6.7.0/24" 规范成 "1.2.3.4/32,5.6.7.0/24"；不合法时返回非 0
normalize_cidrs() {
  python3 - "$1" <<'PYEOF'
import ipaddress, re, sys
out = []
for c in filter(None, re.split(r"[\s,，]+", sys.argv[1])):
    n = ipaddress.IPv4Network(c if "/" in c else c + "/32", strict=False)
    if n.prefixlen == 0 or not n.is_global:
        sys.exit(1)
    if str(n) not in out:
        out.append(str(n))
print(",".join(out))
PYEOF
}

ask_jenkins_egress() {
  local v norm
  echo
  echo "  【需要你填写】Jenkins 服务器的出口公网 IP（会加入跳板机 SSH 白名单）"
  echo "    在 Jenkins 服务器上执行这条命令即可查到：  curl -s https://checkip.amazonaws.com"
  while true; do
    read -r -p "  Jenkins 出口 IP（多个用逗号分隔；暂时不知道就直接回车，之后重跑本脚本补上）: " v
    [[ -n "${v}" ]] || { warn "未填写 Jenkins 出口 IP：Jenkins 暂时连不上跳板机，之后重跑 ./scripts/50-bastion.sh 补上"; return 0; }
    if norm="$(normalize_cidrs "${v}" 2>/dev/null)" && [[ -n "${norm}" ]]; then
      JENKINS_EGRESS_CIDRS="${norm}"; return 0
    fi
    warn "「${v}」不是合法的公网 IPv4 地址 / CIDR，请重新输入"
  done
}

# 老版本 config.env 的默认值是 t4g.large(arm64) / 30 GiB：自动改成 x86 与 100 GiB
fix_legacy_defaults() {
  local arch changes=()
  arch="$(instance_type_arch "${BASTION_INSTANCE_TYPE}" 2>/dev/null || echo unknown)"
  if [[ "${arch}" != "x86_64" ]]; then
    warn "config.env 中 BASTION_INSTANCE_TYPE=${BASTION_INSTANCE_TYPE}（${arch}，老版本默认值）：跳板 / 构建机必须是 x86，改为 m7i.large"
    BASTION_INSTANCE_TYPE="m7i.large"
    changes+=("BASTION_INSTANCE_TYPE=m7i.large#x86_64（与 EKS x86 节点一致），AMI 自动按架构解析")
  fi
  if [[ "${BASTION_ROOT_VOLUME_SIZE}" == "30" ]]; then
    warn "config.env 中 BASTION_ROOT_VOLUME_SIZE=30（老版本默认值）：docker 镜像与构建缓存需要空间，改为 100"
    BASTION_ROOT_VOLUME_SIZE="100"
    changes+=("BASTION_ROOT_VOLUME_SIZE=100#GiB, gp3, 加密（docker 镜像与构建缓存都在根卷上）")
  fi
  (( ${#changes[@]} == 0 )) || save_config "${changes[@]}"
}

# 部署前收集配置：交互模式只问缺的项；非交互模式缺项只告警
collect_config() {
  fix_legacy_defaults
  if [[ -n "${JENKINS_EGRESS_CIDRS}" ]]; then
    ok "Jenkins 出口：${JENKINS_EGRESS_CIDRS}（config.env）"
  elif interactive; then
    ask_jenkins_egress
    [[ -z "${JENKINS_EGRESS_CIDRS}" ]] || save_config "JENKINS_EGRESS_CIDRS=${JENKINS_EGRESS_CIDRS}"
  fi
}

# 栈还在、但实例已被手动删除（或已终止）：这种栈无法原地更新，需要删掉重建
stack_is_stale() {
  local st id state
  st="$(stack_status "${STACK_BASTION}")"
  [[ "${st}" == "DOES_NOT_EXIST" || "${st}" == *_IN_PROGRESS || "${st}" == "ROLLBACK_COMPLETE" ]] && return 1
  id="$(out InstanceId)"
  [[ "${id}" == i-* ]] || return 0
  state="$(aws ec2 describe-instances --instance-ids "${id}" \
           --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo missing)"
  [[ "${state}" == "terminated" || "${state}" == "shutting-down" || "${state}" == "missing" || "${state}" == "None" ]]
}

fetch_private_key() {
  # 仅在本栈新建密钥对时可用：CFN 把私钥写在 SSM Parameter /ec2/keypair/<KeyPairId>
  local kpid file
  kpid="$(out KeyPairId)"
  [[ "${kpid}" == key-* ]] || return 0
  file="${HOME}/.ssh/$(out KeyName).pem"
  mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
  # 每次都重新取：栈若被删除重建，同名密钥的内容已经变了
  if aws ssm get-parameter --name "/ec2/keypair/${kpid}" --with-decryption \
       --query Parameter.Value --output text > "${file}.tmp" 2>/dev/null && [[ -s "${file}.tmp" ]]; then
    mv "${file}.tmp" "${file}" && chmod 600 "${file}"
    ok "私钥已保存到 ${file}"
    printf '  %s\n' "下载到本地：CloudShell 右上角「操作 -> 下载文件」，路径填 ${file}"
  else
    rm -f "${file}.tmp"
    warn "读取私钥失败（需要 ssm:GetParameter + kms:Decrypt）。可手工执行："
    printf '  aws ssm get-parameter --name /ec2/keypair/%s --with-decryption --query Parameter.Value --output text > %s\n' "${kpid}" "${file}"
  fi
}

# ---------------------------------------------------------------- EKS
# 输出 "<集群安全组> <版本> <私有端点开关> <VPC> <状态>"
cluster_facts() {
  aws eks describe-cluster --name "${CLUSTER_NAME}" \
    --query 'cluster.[resourcesVpcConfig.clusterSecurityGroupId,version,resourcesVpcConfig.endpointPrivateAccess,resourcesVpcConfig.vpcId,status]' \
    --output text 2>/dev/null || true
}

# 集群 minor 对应的最新 kubectl patch；取不到就用 .0
resolve_kubectl_version() {
  local minor="$1" v
  v="$(curl -fsSL --max-time 10 "https://dl.k8s.io/release/stable-${minor}.txt" 2>/dev/null | tr -d '[:space:]')"
  [[ "${v}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || v="v${minor}.0"
  echo "${v}"
}

# 实例角色的 Access Entry 已在栈外创建过时，再交给栈创建会冲突 -> 沿用现有授权
resolve_eks_access() {
  [[ "${BASTION_EKS_ACCESS}" == "admin" ]] || { echo none; return; }
  local role_arn
  role_arn="arn:$(partition):iam::$(account_id):role/${PROJECT}-${ENVIRONMENT}-bastion-role"
  if aws eks describe-access-entry --cluster-name "${CLUSTER_NAME}" --principal-arn "${role_arn}" >/dev/null 2>&1 \
     && ! aws cloudformation describe-stack-resource --stack-name "${STACK_BASTION}" \
            --logical-resource-id EksAccessEntry >/dev/null 2>&1; then
    warn "集群里已有 ${role_arn} 的 Access Entry（非本栈创建），沿用现有授权" >&2
    echo none; return
  fi
  echo admin
}

# ---------------------------------------------------------------- SSM 远程执行
# ssm_run <本地脚本> [超时秒] [运行用户]  —— 打印远端 stdout/stderr，返回远端是否成功
ssm_run() { ssm_run_script "$(out InstanceId)" "$@"; }

wait_ssm_online() {
  local id ping="None" i
  id="$(out InstanceId)"
  log "等待 SSM Agent 上线（最长 5 分钟）"
  for i in $(seq 1 30); do
    ping=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=${id}" \
           --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)
    [[ "${ping}" == "Online" ]] && { ok "SSM 在线"; return 0; }
    sleep 10
  done
  warn "SSM 状态 ${ping}（实例需能出网访问 ssm/ssmmessages/ec2messages 端点）"
  return 1
}

# ---------------------------------------------------------------- 子命令
cmd_deploy() {
  local stale=0
  section "跳板 / 构建机配置（只需回答缺少的项，其余使用默认值）"
  collect_config
  stack_is_stale && stale=1

  section "跳板 / 构建机部署计划"
  local cidrs; cidrs="$(resolve_ssh_cidrs)"
  local cluster_sg k8s_ver private_ep cluster_vpc cluster_st kubectl_ver eks_access
  read -r cluster_sg k8s_ver private_ep cluster_vpc cluster_st <<< "$(cluster_facts)"
  [[ -n "${cluster_sg:-}" ]] || die "EKS 集群 ${CLUSTER_NAME} 在 ${AWS_REGION} 不存在（跳板机需要先有集群）"
  kubectl_ver="$(resolve_kubectl_version "${k8s_ver}")"
  eks_access="$(resolve_eks_access)"
  cat <<EOF
  Stack        : ${STACK_BASTION}
  VPC / 子网   : ${VPC_ID} / ${BASTION_SUBNET_ID}
  机型         : ${BASTION_INSTANCE_TYPE}   根卷 ${BASTION_ROOT_VOLUME_SIZE} GiB gp3 加密
  SSH 白名单   : ${cidrs}
  密钥对       : 自动创建 ${PROJECT}-${ENVIRONMENT}-bastion-key（私钥托管在 SSM Parameter Store，部署后保存到 ~/.ssh/）
  弹性 IP      : ${BASTION_ALLOCATE_EIP}
  EKS          : ${CLUSTER_NAME} (${k8s_ver})，集群安全组 ${cluster_sg} 放通本机；kubectl ${kubectl_ver}；授权 ${eks_access}
  ECR          : 推拉 / 创建 ${PROJECT}/* 仓库（docker 构建推送）
  S3 权限      : 所有桶 列举/下载/上传$( [[ "${BASTION_S3_ALLOW_DELETE}" == "true" ]] && echo "/删除" || echo "（不含删除）" )
EOF
  (( stale )) && echo "  旧栈         : 实例已不存在（手动删除过），先删除旧栈再重新创建"

  section "检查"
  local vpc az rtb state target
  vpc="$(subnet_field "${BASTION_SUBNET_ID}" VpcId 2>/dev/null)" || die "子网 ${BASTION_SUBNET_ID} 不存在"
  [[ "${vpc}" == "${VPC_ID}" ]] || die "子网 ${BASTION_SUBNET_ID} 不属于 ${VPC_ID}"
  az="$(subnet_field "${BASTION_SUBNET_ID}" AvailabilityZone)"
  rtb="$(route_table_for_subnet "${BASTION_SUBNET_ID}")"
  read -r state target <<< "$(default_route_state "${rtb}")"
  [[ "${state}" == "active" && "${target}" == igw-* ]] \
    || die "子网 ${BASTION_SUBNET_ID} 默认路由为 ${state}/${target}，不是公有子网（需指向 IGW）"
  ok "子网 ${BASTION_SUBNET_ID} (${az}) 为公有子网 -> ${target}"

  [[ -n "$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
      --filters "Name=instance-type,Values=${BASTION_INSTANCE_TYPE}" "Name=location,Values=${az}" \
      --query 'InstanceTypeOfferings[0].InstanceType' --output text | grep -v None)" ]] \
    || die "${BASTION_INSTANCE_TYPE} 在 ${az} 不可用，换一个 BASTION_SUBNET_ID"
  local arch ami
  arch="$(instance_type_arch "${BASTION_INSTANCE_TYPE}")"
  ami="$(resolve_al2023_ami "${arch}")"
  ok "${BASTION_INSTANCE_TYPE} 在 ${az} 可用，AMI (${arch}): ${ami}"
  # 老版本 config.env 默认 t4g.large（arm64）：arm 上构建的镜像在 x86 节点跑不起来，直接拒绝
  [[ "${arch}" == "x86_64" ]] \
    || die "${BASTION_INSTANCE_TYPE} 是 ${arch} 机型，跳板 / 构建机必须是 x86。把 config.env 改成 BASTION_INSTANCE_TYPE=\"m7i.large\" 后重试"
  (( BASTION_ROOT_VOLUME_SIZE >= 100 )) \
    || warn "根卷 ${BASTION_ROOT_VOLUME_SIZE} GiB（老版本默认 30）：docker 镜像与构建缓存都在根卷上，建议 BASTION_ROOT_VOLUME_SIZE=\"100\""

  [[ "${cluster_st}" == "ACTIVE" ]] || die "集群 ${CLUSTER_NAME} 状态为 ${cluster_st}"
  [[ "${cluster_vpc}" == "${VPC_ID}" ]] || die "集群在 ${cluster_vpc}，跳板机在 ${VPC_ID}：必须同一 VPC 才能走私有端点"
  if [[ "${private_ep}" == "True" ]]; then
    ok "集群已开启私有端点：跳板机经 VPC 内网访问 API Server，不需要加公共端点白名单"
  else
    warn "集群未开启私有端点：跳板机只能走公共端点，需要把跳板机公网 IP 加进 EKS 公共端点白名单"
  fi
  if [[ -z "${JENKINS_EGRESS_CIDRS}" ]]; then
    warn "JENKINS_EGRESS_CIDRS 为空：Jenkins 出口 IP 不在 SSH 白名单里，Jenkins 会连不上跳板机 22 端口"
  else
    ok "Jenkins 出口 ${JENKINS_EGRESS_CIDRS} 已并入 SSH 白名单"
  fi

  if [[ ",${cidrs}," == *",0.0.0.0/0,"* ]]; then
    warn "SSH 对 0.0.0.0/0 开放，会持续遭到互联网扫描与爆破。建议收紧到 Jenkins / 办公网出口"
    confirm "仍然继续？" || die "已取消"
  fi
  [[ "${BASTION_SSH_CIDRS}" == "auto" ]] \
    && warn "BASTION_SSH_CIDRS=auto 只放通当前出口 IP（CloudShell 会轮换）。日常登录用 ./scripts/50-bastion.sh ssm 即可"

  if (( stale )); then
    warn "旧栈的实例已被删除：将删除旧栈（旧 EIP、旧安全组、老版本自建的密钥对随之删除）后重建，跳板机公网 IP 会变"
  else
    local cur_type legacy
    cur_type="$(stack_param InstanceType)"
    if [[ -n "${cur_type}" && "${cur_type}" != "${BASTION_INSTANCE_TYPE}" ]]; then
      warn "机型 ${cur_type} -> ${BASTION_INSTANCE_TYPE}：实例会被替换，旧实例根卷上的数据会丢失（EIP 保留不变）。需要保留的文件请先传到 S3"
    fi
    legacy="$(stack_param ExistingKeyName)"
    [[ -z "${legacy}" ]] \
      || warn "密钥对 ${legacy} 改为栈自动创建的 ${PROJECT}-${ENVIRONMENT}-bastion-key：实例会被替换，Jenkins 凭据要换成新私钥"
  fi

  confirm "开始部署？" || die "已取消"

  if (( stale )); then
    section "删除旧栈 ${STACK_BASTION}"
    delete_stack "${STACK_BASTION}" || die "旧栈删除失败，请到 CloudFormation 控制台查看原因后重试"
  fi

  section "部署栈 ${STACK_BASTION}"
  deploy_stack "${STACK_BASTION}" "${CFN_DIR}/50-bastion.yaml" \
    "ProjectName=${PROJECT}" \
    "EnvironmentName=${ENVIRONMENT}" \
    "VpcId=${VPC_ID}" \
    "PublicSubnetId=${BASTION_SUBNET_ID}" \
    "SshAllowedCidrs=${cidrs}" \
    "AllocateEip=${BASTION_ALLOCATE_EIP}" \
    "InstanceType=${BASTION_INSTANCE_TYPE}" \
    "AmiId=${ami}" \
    "RootVolumeSize=${BASTION_ROOT_VOLUME_SIZE}" \
    "ExistingKeyName=" \
    "ClusterName=${CLUSTER_NAME}" \
    "ClusterSecurityGroupId=${cluster_sg}" \
    "EksAccess=${eks_access}" \
    "KubectlVersion=${kubectl_ver}" \
    "EcrRepoPrefix=${PROJECT}" \
    "S3AllowDelete=${BASTION_S3_ALLOW_DELETE}"

  fetch_private_key
  cmd_install_tools
  cmd_verify || warn "验收有失败项，见上方输出"
  cmd_info
  cmd_jenkins
}

# 把 build-push-jar 装到跳板机（先等 UserData 跑完，docker / kubectl 才齐全）
cmd_install_tools() {
  require_stack
  wait_ssm_online || die "SSM 不在线，无法安装构建工具"
  section "安装构建工具 ${BUILD_TOOL_DST}"
  local tmp; tmp="$(mktemp)"
  { echo 'set -euo pipefail'
    echo 'cloud-init status --wait >/dev/null 2>&1 || true'
    printf 'echo %s | base64 -d | gunzip > %s\n' "$(gzip -9c "${BUILD_TOOL_SRC}" | base64 | tr -d '\n')" "${BUILD_TOOL_DST}"
    echo "chmod 755 ${BUILD_TOOL_DST}"
    echo "echo \"installed ${BUILD_TOOL_DST} sha256=\$(sha256sum ${BUILD_TOOL_DST} | cut -c1-12)\""
    echo 'tail -1 /var/log/bastion-bootstrap.log'
  } > "${tmp}"
  if ssm_run "${tmp}" 900; then rm -f "${tmp}"; ok "构建工具已安装"; else rm -f "${tmp}"; die "构建工具安装失败"; fi
}

cmd_info() {
  require_stack
  local id ip
  id="$(out InstanceId)"; ip="$(out PublicIp)"
  section "跳板机连接信息"
  cat <<EOF
  实例 ID   : ${id}
  公网 IP   : ${ip}
  私网 IP   : $(out PrivateIp)
  安全组    : $(out SecurityGroupId)
  实例角色  : $(out InstanceRoleArn)
  密钥对    : $(out KeyName)

  SSM 登录（CloudShell 推荐，无需密钥与 22 端口）：
    ./scripts/50-bastion.sh ssm
    # 等价于：$(out SsmCommand)

  SSH 登录（Jenkins 用这个方式）：
    ssh -i $(out KeyName).pem ${SSH_USER}@${ip}

  机上构建推送（Jenkins 通过 SSH 调用，见 ci/Jenkinsfile.bastion-jar.example）：
    build-push-jar --jar ./app.jar --app demo-app --tag 1 --java 17
    # -> $(out EcrRegistry)/$(out EcrRepoPrefix)/demo-app:1

  机上访问 EKS（kubeconfig 已指向 ${CLUSTER_NAME}，走私有端点）：
    kubectl get nodes

  机上使用 S3（实例角色自动提供凭证，无需 aws configure）：
    aws s3 ls
    aws s3 cp ./file s3://<bucket>/path/
EOF
}

cmd_verify() {
  require_stack
  local ip fail=0 c
  ip="$(out PublicIp)"
  section "跳板机验收"

  wait_ssm_online || fail=1

  # CloudShell(Linux) 有 timeout；macOS 没有，退回 nc
  local probe
  if command -v timeout >/dev/null 2>&1; then
    probe=(timeout 6 bash -c "cat < /dev/null > /dev/tcp/${ip}/22")
  else
    probe=(nc -z -G 6 "${ip}" 22)
  fi
  if "${probe[@]}" >/dev/null 2>&1; then
    ok "从当前环境可连通 ${ip}:22"
  else
    warn "从当前环境连不通 ${ip}:22（当前出口 $(my_egress_ip) 不在 SSH 白名单时属正常，只要 Jenkins 出口在白名单即可）"
  fi

  for c in ${JENKINS_EGRESS_CIDRS//,/ }; do
    if ssh_whitelist | grep -qx "${c}"; then
      ok "Jenkins 出口 ${c} 在 SSH 白名单内"
    else
      err "Jenkins 出口 ${c} 不在 SSH 白名单内，重跑 ./scripts/50-bastion.sh"; fail=1
    fi
  done

  # 以 Jenkins 登录的同一用户 ec2-user 检查：docker 免 sudo、kubectl、ECR、S3
  local tmp; tmp="$(mktemp)"
  cat > "${tmp}" <<'EOF'
set -u
source /etc/bastion-build.env
rc=0
chk() {
  local o
  if o=$(bash -c "$2" 2>&1); then echo "OK   $1 : $(tail -1 <<< "$o")"; else echo "FAIL $1 : $(tail -1 <<< "$o")"; rc=1; fi
}
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null | sed 's#https://##')
node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
chk "身份       " "aws sts get-caller-identity --query Arn --output text"
chk "架构       " "uname -m | grep -x x86_64"
chk "根卷       " "df -h / | awk 'NR==2{print \$2\" total, \"\$4\" free\"}'"
chk "docker     " "docker version --format 'server {{.Server.Version}}'"
chk "buildx     " "docker buildx version"
chk "构建工具   " "test -x /usr/local/bin/build-push-jar && echo /usr/local/bin/build-push-jar"
chk "ECR 登录   " "aws ecr get-login-password | DOCKER_CONFIG=\$(mktemp -d) docker login -u AWS --password-stdin $ECR_REGISTRY"
chk "kubectl    " "kubectl version --client -o json | jq -r .clientVersion.gitVersion"
chk "API 端点   " "getent hosts $server | awk '{print \$1}' | paste -sd, - | sed 's/\$/ (VPC 私网地址)/'"
chk "EKS 节点   " "kubectl get nodes --no-headers | awk '{print \$1\" \"\$2}' | paste -sd';' -"
chk "EKS 权限   " "echo create deployments -A: \$(kubectl auth can-i create deployments -A)"
chk "节点 10250 " "timeout 5 bash -c '</dev/tcp/$node_ip/10250' && echo $node_ip:10250 reachable"
chk "S3         " "echo buckets=\$(aws s3api list-buckets --query 'length(Buckets)' --output text)"
exit $rc
EOF
  if ssm_run "${tmp}" 120 "${SSH_USER}"; then ok "机上检查全部通过（以 ${SSH_USER} 身份）"; else err "机上检查有失败项"; fail=1; fi
  rm -f "${tmp}"
  (( fail == 0 ))
}

# 打印 Jenkins 侧需要的全部配置
cmd_jenkins() {
  require_stack
  local tmp hostkey ip
  ip="$(out PublicIp)"
  tmp="$(mktemp)"
  echo "awk '{print \$1\" \"\$2}' /etc/ssh/ssh_host_ed25519_key.pub" > "${tmp}"
  hostkey="$(ssm_run "${tmp}" 60 | sed 's/^  //' | head -1)"; rm -f "${tmp}"
  local key pem
  key="$(out KeyName)"
  pem="${HOME}/.ssh/${key}.pem"
  [[ -f "${pem}" ]] || fetch_private_key >/dev/null
  section "Jenkins 配置（详见 docs/bastion-upgrade.md 第 3 步）"
  cat <<EOF
  1) 凭据：Manage Jenkins -> Credentials -> 新建「SSH Username with private key」
       ID          : bastion-ssh
       Username    : ${SSH_USER}
       Private Key : Enter directly，粘贴密钥对 ${key} 的 .pem 全部内容
EOF
  [[ ! -f "${pem}" ]] || cat <<EOF
       私钥文件    : ${pem}
                     CloudShell 右上角「操作 -> 下载文件」，路径填上面这行；或执行 cat ${pem} 直接复制
EOF
  cat <<EOF

  2) 全局环境变量：Manage Jenkins -> System -> Global properties -> Environment variables
       BASTION_HOST      = ${ip}
       BASTION_USER      = ${SSH_USER}
       BASTION_HOST_KEY  = ${ip} ${hostkey}
     BASTION_HOST_KEY 用来校验跳板机身份（防中间人）。实例被替换后主机密钥会变，重新执行本命令更新即可

  3) 插件：Pipeline、Credentials Binding、SSH Credentials、File Parameters（页面上传 JAR 用）

  4) Jenkins 出口 IP 必须在跳板机 SSH 白名单内，当前白名单：$(ssh_whitelist | paste -sd, -)
     不在的话把 Jenkins 出口填进 config.env 的 JENKINS_EGRESS_CIDRS，重跑 ./scripts/50-bastion.sh

  5) 流水线：ci/Jenkinsfile.bastion-jar.example（新建 Pipeline Job 粘贴即可）
EOF
}

# 端到端冒烟：不依赖 Jenkins。在跳板机上现编一个示例 JAR，走与 Jenkins 完全相同的 build-push-jar，
# 再用该镜像在 EKS 里起一个 Pod，并从跳板机直连 Pod IP 验证
cmd_test_build() {
  require_stack
  local tag tmp ns="${BASTION_TEST_NAMESPACE:-default}" arm=0 st
  tag="smoke-$(date +%Y%m%d%H%M%S)"
  # 部署了 Graviton 节点组（55-arm-nodegroup.sh）时，同一个多架构镜像再在 arm 节点上跑一遍
  st="$(stack_status "${STACK_NODEGROUP_ARM:-${PROJECT}-${ENVIRONMENT}-eks-nodegroup-arm64}")"
  [[ "${st}" == *_COMPLETE && "${st}" != *ROLLBACK* ]] && arm=1
  # 这些值会拼进远端的 JSON / trap 字符串，先做白名单校验
  local v
  for v in "${ns}" "${ARM_NODEGROUP_NAME:-ng-arm64}" "${ARM_TAINT_KEY:-arch}" "${ARM_TAINT_VALUE:-arm64}"; do
    [[ "${v}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,62}$ ]] || die "测试参数不合法：${v}"
  done
  section "端到端冒烟：JAR -> 多架构镜像 -> ECR -> EKS（tag ${tag}$( (( arm )) && echo '，x86 + Graviton 节点' )）"
  tmp="$(mktemp)"
  printf 'set -euo pipefail\nTAG=%q\nNS=%q\nARM=%q\nARM_NG=%q\nTKEY=%q\nTVAL=%q\nTAINT=%q\n' "${tag}" "${ns}" "${arm}" \
    "${ARM_NODEGROUP_NAME:-ng-arm64}" "${ARM_TAINT_KEY:-arch}" "${ARM_TAINT_VALUE:-arm64}" "${ARM_NODE_TAINT:-true}" > "${tmp}"
  cat >> "${tmp}" <<'EOF'
W=$(mktemp -d); cd "$W"
cat > Hello.java <<'J'
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
public class Hello {
  public static void main(String[] a) throws Exception {
    HttpServer s = HttpServer.create(new InetSocketAddress(8080), 0);
    s.createContext("/", x -> {
      byte[] b = ("hello from jar, java " + System.getProperty("java.version")
                  + ", arch " + System.getProperty("os.arch") + "\n").getBytes();
      x.sendResponseHeaders(200, b.length); x.getResponseBody().write(b); x.close();
    });
    s.start(); System.out.println("listening on 8080");
  }
}
J
printf 'Main-Class: Hello\n' > manifest.txt
echo "== 编译示例 JAR（容器内 JDK，跳板机无需安装 Java）"
docker pull -q public.ecr.aws/docker/library/eclipse-temurin:17-jdk >/dev/null
docker run --rm -u "$(id -u):$(id -g)" -v "$W:/w" -w /w public.ecr.aws/docker/library/eclipse-temurin:17-jdk \
  sh -c 'javac Hello.java && jar cfm hello.jar manifest.txt Hello*.class'
ls -l hello.jar
echo "== build-push-jar"
build-push-jar --jar hello.jar --app smoke-test --tag "$TAG" --java 17 2>&1 | tee build.log | grep -vE '^ *#[0-9]+ (sha256|extracting|[0-9.]+ ?[kMG]?B)' | tail -25
IMAGE=$(sed -n 's/^IMAGE_URI=//p' build.log)
test -n "$IMAGE"
PLAT=$(sed -n 's/^IMAGE_PLATFORMS=//p' build.log | tail -n1)
echo "== 镜像平台: ${PLAT}"
[[ "$PLAT" == *linux/amd64* && "$PLAT" == *linux/arm64* ]] || { echo "FAIL 镜像平台不全: ${PLAT}"; exit 1; }

# run_on <pod名> <期望 os.arch> <超时秒> [kubectl run 的 --overrides JSON]
run_on() {
  local pod="$1" want="$2" timeout="$3" ov="${4:-}" out ip
  echo "== 在 EKS 运行 $IMAGE（期望 arch ${want}）"
  kubectl -n "$NS" delete pod "$pod" --ignore-not-found --wait=true >/dev/null
  kubectl -n "$NS" run "$pod" --image="$IMAGE" --port=8080 --restart=Never ${ov:+--overrides="$ov"} >/dev/null
  # 中途失败（超时 / curl 失败 / 架构不符）也删掉测试 Pod
  trap "kubectl -n '$NS' delete pod '$pod' --ignore-not-found --wait=false >/dev/null 2>&1" EXIT
  kubectl -n "$NS" wait pod/"$pod" --for=condition=Ready --timeout="${timeout}s"
  kubectl -n "$NS" get pod "$pod" -o wide --no-headers
  ip=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}')
  echo "== 从跳板机直连 Pod ${ip}:8080"
  out=$(curl -sf --retry 5 --retry-connrefused --max-time 10 "http://${ip}:8080/")
  echo "$out"
  kubectl -n "$NS" delete pod "$pod" --wait=false >/dev/null
  [[ "$out" == *"arch ${want}"* ]] || { echo "FAIL 期望 arch ${want}"; return 1; }
}
run_on bastion-smoke-test amd64 180 '{"spec":{"nodeSelector":{"kubernetes.io/arch":"amd64"}}}'
if [[ "$ARM" == "1" ]]; then
  TOL=""
  [[ "$TAINT" == "true" ]] && TOL=",\"tolerations\":[{\"key\":\"${TKEY}\",\"operator\":\"Equal\",\"value\":\"${TVAL}\",\"effect\":\"NoSchedule\"}]"
  # arm 节点组可能缩到了 0，等 CAS 从 0 扩容
  run_on bastion-smoke-test-arm64 aarch64 420 "{\"spec\":{\"nodeSelector\":{\"eks.amazonaws.com/nodegroup\":\"${ARM_NG}\"}${TOL}}}"
fi
cd /; rm -rf "$W"
EOF
  if ssm_run "${tmp}" 900 "${SSH_USER}"; then
    rm -f "${tmp}"
    ok "端到端冒烟通过$( (( arm )) && echo '（同一镜像在 x86 与 Graviton 节点均运行正常）' )。测试仓库可删除：aws ecr delete-repository --repository-name ${PROJECT}/smoke-test --force"
  else
    rm -f "${tmp}"; die "端到端冒烟失败"
  fi
}

cmd_ssh() {
  require_stack
  local kf; kf="$(key_file)"
  [[ -f "${kf}" ]] || die "找不到私钥 ${kf}。把下载的 .pem 上传到 CloudShell 该路径（chmod 600），或设置 BASTION_SSH_KEY_FILE=<路径>；不想用私钥就用 ./scripts/50-bastion.sh ssm"
  exec ssh -i "${kf}" -o StrictHostKeyChecking=accept-new "${SSH_USER}@$(out PublicIp)" "$@"
}

cmd_ssm() {
  require_stack
  command -v session-manager-plugin >/dev/null 2>&1 \
    || die "缺少 session-manager-plugin（CloudShell 已自带；本地请按 AWS 文档安装）"
  exec aws ssm start-session --target "$(out InstanceId)"
}

cmd_allow_my_ip() {
  require_stack
  local ip sg
  ip="$(my_egress_ip)"; sg="$(out SecurityGroupId)"
  [[ "${ip}" =~ ^[0-9.]+$ ]] || die "取不到当前出口 IP"
  # 与 CFN 管理的规则分开：栈更新不会删掉这些带外追加的规则
  if aws ec2 authorize-security-group-ingress --group-id "${sg}" \
       --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${ip}/32,Description=added-by-50-bastion-allow-my-ip}]" \
       >/dev/null 2>"${OUT_DIR}/bastion-sg.err"; then
    ok "已放通 ${ip}/32 -> ${sg}:22"
  elif grep -q 'Duplicate' "${OUT_DIR}/bastion-sg.err"; then
    ok "${ip}/32 已在 SSH 白名单内"
  else
    cat "${OUT_DIR}/bastion-sg.err" >&2; die "更新安全组失败"
  fi
  warn "这是带外修改，不再需要时请到安全组 ${sg} 删除描述为 added-by-50-bastion-allow-my-ip 的规则"
}

cmd_destroy() {
  local st kf=""
  st="$(stack_status "${STACK_BASTION}")"
  [[ "${st}" != "DOES_NOT_EXIST" ]] || { log "栈 ${STACK_BASTION} 不存在"; return 0; }
  [[ "$(out KeyPairId)" == key-* ]] && kf="${HOME}/.ssh/$(out KeyName).pem"
  warn "将删除跳板机 ${STACK_BASTION}：实例、根卷、EIP、安全组、实例角色、EKS Access Entry 与集群安全组放通规则$( [[ -n "${kf}" ]] && echo '、本栈新建的密钥对' )"
  warn "实例本地磁盘上的数据会随实例删除，请先把需要的文件传到 S3"
  [[ -z "${kf}" ]] && log "客户自建的密钥对 $(out KeyName) 不会删除；ECR 里的镜像保留"
  confirm "确认删除？" || die "已取消"
  delete_stack "${STACK_BASTION}"
  if [[ -n "${kf}" && -f "${kf}" ]]; then rm -f "${kf}" && ok "已删除失效的本地私钥 ${kf}"; fi
}

case "${1:-deploy}" in
  deploy)        cmd_deploy ;;
  key)           require_stack; fetch_private_key ;;
  info)          cmd_info ;;
  jenkins)       cmd_jenkins ;;
  verify)        cmd_verify ;;
  test-build)    cmd_test_build ;;
  install-tools) cmd_install_tools ;;
  ssh)           shift; cmd_ssh "$@" ;;
  ssm)           cmd_ssm ;;
  allow-my-ip)   cmd_allow_my_ip ;;
  destroy)       cmd_destroy ;;
  -h|--help)     awk 'NR<3 {next} /^# ={10,}/ {exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}" ;;
  *)             die "未知子命令: $1（见 --help）" ;;
esac
