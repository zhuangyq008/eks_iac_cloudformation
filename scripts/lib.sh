#!/usr/bin/env bash
# =============================================================================
#  公共函数库 —— 所有脚本 source 本文件
# =============================================================================
set -euo pipefail

# 脚本里有大量中文提示。若 locale 不是 UTF-8，bash 在 set -u 下会把中文的字节
# 误并入变量名（典型报错：`c?: unbound variable`）。这里统一兜底到 C.UTF-8。
if ! locale charmap 2>/dev/null | grep -qi 'utf-\?8'; then
  if locale -a 2>/dev/null | grep -qx 'C.UTF-8'; then
    export LC_ALL=C.UTF-8 LANG=C.UTF-8
  elif locale -a 2>/dev/null | grep -qix 'en_US.utf-\?8'; then
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CFN_DIR="${ROOT_DIR}/cloudformation"
IAM_DIR="${ROOT_DIR}/iam"
MANIFEST_DIR="${ROOT_DIR}/manifests"
OUT_DIR="${ROOT_DIR}/.out"

# shellcheck source=../config.env
source "${ROOT_DIR}/config.env"
mkdir -p "${OUT_DIR}"

# API_PUBLIC_ACCESS_CIDRS=auto -> 解析为当前出口 IP/32。
# 主要为 CloudShell 准备：它的出口 IP 不固定，写死 /32 过一段时间就失效。
if [[ "${API_PUBLIC_ACCESS_CIDRS:-}" == "auto" ]]; then
  _myip="$(curl -s --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')"
  if [[ "${_myip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    API_PUBLIC_ACCESS_CIDRS="${_myip}/32"
  else
    echo "FATAL: API_PUBLIC_ACCESS_CIDRS=auto 但取不到当前出口 IP。请在 config.env 里写死 CIDR。" >&2
    exit 1
  fi
  unset _myip
fi

export AWS_REGION
export AWS_DEFAULT_REGION="${AWS_REGION}"
if [[ -n "${AWS_PROFILE:-}" ]]; then export AWS_PROFILE; fi

# ---------------------------------------------------------------- 日志
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_RST=''
fi
log()   { printf '%s[ %s ]%s %s\n' "${C_BLU}" "$(date +%H:%M:%S)" "${C_RST}" "$*"; }
ok()    { printf '%s  OK  %s %s\n' "${C_GRN}" "${C_RST}" "$*"; }
warn()  { printf '%s WARN %s %s\n' "${C_YEL}" "${C_RST}" "$*"; }
err()   { printf '%s FAIL %s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; }
die()   { err "$*"; exit 1; }
hr()    { printf '%s%s%s\n' "${C_DIM}" "$(printf '─%.0s' {1..76})" "${C_RST}"; }
section() { echo; hr; printf '  %s\n' "$*"; hr; }

confirm() {
  # confirm "问题" —— 设置 ASSUME_YES=1 可跳过交互（CI 用）
  local prompt="$1"
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then return 0; fi
  read -r -p "${prompt} [y/N] " ans
  [[ "${ans}" == "y" || "${ans}" == "Y" ]]
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1（见 README 前置要求）"; }

# ---------------------------------------------------------------- 基础信息
account_id() { aws sts get-caller-identity --query Account --output text; }
caller_arn() { aws sts get-caller-identity --query Arn --output text; }
partition()  { local a; a=$(caller_arn); echo "${a}" | cut -d: -f2; }

csv_to_json_list() {
  # "a,b,c" -> ["a","b","c"]   （用于 cfn 的 List 型参数其实可以直传 CSV，这里给 jq-free 的调试输出）
  local IFS=','; read -r -a arr <<< "$1"
  local out=""; for x in "${arr[@]}"; do out="${out},\"${x}\""; done
  echo "[${out:1}]"
}

# ---------------------------------------------------------------- CloudFormation
stack_status() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST"
}

stack_output() {
  # stack_output <stack> <OutputKey>
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text 2>/dev/null
}

deploy_stack() {
  # deploy_stack <stack-name> <template-file> [ParamKey=Value ...]
  local stack="$1"; shift
  local template="$1"; shift
  local st; st="$(stack_status "${stack}")"

  case "${st}" in
    ROLLBACK_COMPLETE|REVIEW_IN_PROGRESS)
      warn "栈 ${stack} 处于 ${st}，无法更新，先删除"
      aws cloudformation delete-stack --stack-name "${stack}"
      aws cloudformation wait stack-delete-complete --stack-name "${stack}"
      ;;
    *_IN_PROGRESS)
      # CloudShell 会话断开后重跑脚本时会命中这里：等它跑完再继续，而不是直接退出
      warn "栈 ${stack} 正在 ${st}，等待其结束后再继续"
      case "${st}" in
        CREATE_IN_PROGRESS)         aws cloudformation wait stack-create-complete --stack-name "${stack}" || true ;;
        DELETE_IN_PROGRESS)         aws cloudformation wait stack-delete-complete --stack-name "${stack}" || true ;;
        *ROLLBACK_IN_PROGRESS)      aws cloudformation wait stack-rollback-complete --stack-name "${stack}" 2>/dev/null || true ;;
        *)                          aws cloudformation wait stack-update-complete --stack-name "${stack}" || true ;;
      esac
      log "栈 ${stack} 当前状态: $(stack_status "${stack}")"
      ;;
  esac

  log "部署栈 ${stack}  (${template##*/})"
  # 用 --no-fail-on-empty-changeset 让"无变更"成为幂等成功路径
  aws cloudformation deploy \
    --stack-name "${stack}" \
    --template-file "${template}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --tags "Project=${PROJECT}" "Environment=${ENVIRONMENT}" "ManagedBy=cloudformation" \
    --parameter-overrides "$@" \
    || {
      err "栈 ${stack} 部署失败，最近的失败事件："
      aws cloudformation describe-stack-events --stack-name "${stack}" \
        --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[Timestamp,LogicalResourceId,ResourceStatusReason]' \
        --output table | head -40
      return 1
    }
  ok "栈 ${stack} 完成（$(stack_status "${stack}")）"
}

delete_stack() {
  local stack="$1"
  local st; st="$(stack_status "${stack}")"
  if [[ "${st}" == "DOES_NOT_EXIST" ]]; then
    log "栈 ${stack} 不存在，跳过"
    return 0
  fi
  log "删除栈 ${stack}"
  aws cloudformation delete-stack --stack-name "${stack}"
  aws cloudformation wait stack-delete-complete --stack-name "${stack}" \
    && ok "栈 ${stack} 已删除" \
    || { err "栈 ${stack} 删除失败/超时，请到控制台查看残留资源"; return 1; }
}

# ---------------------------------------------------------------- VPC DNS 属性
# EKS 硬性要求：VPC 必须同时开启 enableDnsSupport 与 enableDnsHostnames。
#
# 踩坑记录（2026-09-21 实测）：
#   enableDnsHostnames=false 时，EKS 仍会为私有端点创建 Route53 私有托管区，
#   但私有托管区只在两个属性都为 true 时才对 VPC 生效。结果节点把集群端点解析成
#   **公网 IP**，转而走 NAT 访问公共端点；而公共端点有 CIDR 白名单、NAT 的 EIP 不在
#   白名单里，于是节点永远注册不上。
#
#   这个故障的表象极具误导性：
#     - EC2 实例正常 running，SSM 能上线（说明出网没问题）
#     - describe-nodegroup 的 health.issues 是空数组，status 长时间停在 CREATING
#     - 最终才以 NodeCreationFailure 超时失败，且不会指向 DNS
#   所以必须在建集群**之前**就检出并修掉。
vpc_dns_attr() {
  # vpc_dns_attr <enableDnsSupport|enableDnsHostnames>
  local attr="$1" key
  case "${attr}" in
    enableDnsSupport)   key=EnableDnsSupport ;;
    enableDnsHostnames) key=EnableDnsHostnames ;;
    *) die "未知 VPC 属性: ${attr}" ;;
  esac
  aws ec2 describe-vpc-attribute --vpc-id "${VPC_ID}" --attribute "${attr}" \
    --query "${key}.Value" --output text
}

ensure_vpc_dns_attributes() {
  # ensure_vpc_dns_attributes [fix]
  #   不带参数 = 只检查，返回 1 表示有问题
  #   fix      = 自动开启缺失的属性
  local mode="${1:-check}" rc=0 sup host
  sup="$(vpc_dns_attr enableDnsSupport)"
  host="$(vpc_dns_attr enableDnsHostnames)"
  printf '  enableDnsSupport   : %s\n' "${sup}"
  printf '  enableDnsHostnames : %s\n' "${host}"

  if [[ "${sup}" == "True" && "${host}" == "True" ]]; then
    ok "VPC DNS 属性满足 EKS 要求"
    return 0
  fi

  if [[ "${mode}" != "fix" ]]; then
    err "VPC ${VPC_ID} 的 DNS 属性不满足 EKS 要求（节点将无法注册到集群）"
    return 1
  fi

  [[ "${sup}" == "True" ]] || {
    log "开启 enableDnsSupport"
    aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-support
  }
  [[ "${host}" == "True" ]] || {
    log "开启 enableDnsHostnames"
    aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-hostnames
  }

  # 属性生效到 VPC 解析器有数十秒延迟，这里确认一下再往下走
  for _ in $(seq 1 12); do
    sup="$(vpc_dns_attr enableDnsSupport)"; host="$(vpc_dns_attr enableDnsHostnames)"
    [[ "${sup}" == "True" && "${host}" == "True" ]] && { ok "VPC DNS 属性已开启"; sleep 15; return 0; }
    sleep 5
  done
  err "VPC DNS 属性修改后未生效"
  return 1
}

# ---------------------------------------------------------------- 网络探测
subnet_field() {
  # subnet_field <subnet-id> <jmespath-field>
  aws ec2 describe-subnets --subnet-ids "$1" --query "Subnets[0].$2" --output text
}

network_config_ok() {
  # config.env 的 VPC / 子网在当前账号 + 区域是否存在且归属正确。
  # 只做"能不能用"的粗判（随包示例值在客户账号里必然不通过），细项由 01-preflight 检查。
  [[ -n "${VPC_ID:-}" && -n "${PUBLIC_SUBNET_IDS:-}" && -n "${PRIVATE_SUBNET_IDS:-}" ]] || return 1
  aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" >/dev/null 2>&1 || return 1
  local ids n
  read -r -a ids <<< "${PUBLIC_SUBNET_IDS//,/ } ${PRIVATE_SUBNET_IDS//,/ }"
  n=$(aws ec2 describe-subnets --subnet-ids "${ids[@]}" \
      --query "length(Subnets[?VpcId=='${VPC_ID}'])" --output text 2>/dev/null) || return 1
  [[ "${n}" == "${#ids[@]}" ]]
}

route_table_for_subnet() {
  # 显式关联优先；没有显式关联时回退到 VPC 的 main 路由表
  local sn="$1" rtb
  rtb=$(aws ec2 describe-route-tables \
          --filters "Name=association.subnet-id,Values=${sn}" \
          --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo None)
  if [[ "${rtb}" == "None" || -z "${rtb}" ]]; then
    rtb=$(aws ec2 describe-route-tables \
            --filters "Name=vpc-id,Values=${VPC_ID}" "Name=association.main,Values=true" \
            --query 'RouteTables[0].RouteTableId' --output text)
  fi
  echo "${rtb}"
}

default_route_state() {
  # 输出 "<state> <target>"；无默认路由时输出 "NONE -"
  local rtb="$1" state target
  state=$(aws ec2 describe-route-tables --route-table-ids "${rtb}" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].State | [0]" --output text)
  target=$(aws ec2 describe-route-tables --route-table-ids "${rtb}" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].[NatGatewayId,TransitGatewayId,GatewayId,VpcPeeringConnectionId,NetworkInterfaceId] | [0] | [?@!=null] | [0]" --output text)
  [[ "${state}" == "None" || -z "${state}" ]] && state="NONE"
  [[ "${target}" == "None" || -z "${target}" ]] && target="-"
  echo "${state} ${target}"
}

discover_private_route_tables() {
  # 输出去重后的私有子网路由表 ID（空格分隔）
  local IFS=','; read -r -a subs <<< "${PRIVATE_SUBNET_IDS}"; unset IFS
  local seen=() rtb
  for sn in "${subs[@]}"; do
    rtb="$(route_table_for_subnet "${sn}")"
    if [[ ! " ${seen[*]-} " == *" ${rtb} "* ]]; then seen+=("${rtb}"); fi
  done
  echo "${seen[@]}"
}

# 判定私有子网是否已具备出网能力，并按需修掉 blackhole 残留路由。
# 输出（写入全局变量）：
#   NEED_NAT           : 1 = 需要创建 NAT 网关
#   RTBS_NEED_ROUTE    : 需要补 0.0.0.0/0 路由的路由表（空格分隔）
#   PRIVATE_RTBS       : 全部私有路由表
analyze_private_egress() {
  local fix="${1:-no}"    # fix=yes 时自动删除 blackhole 残留路由
  PRIVATE_RTBS="$(discover_private_route_tables)"
  RTBS_NEED_ROUTE=""
  NEED_NAT=0

  for rtb in ${PRIVATE_RTBS}; do
    read -r state target <<< "$(default_route_state "${rtb}")"
    case "${state}" in
      active)
        case "${target}" in
          nat-*|tgw-*|eni-*|pcx-*)
            ok "${rtb} 默认路由正常 -> ${target}" ;;
          igw-*)
            warn "${rtb} 默认路由指向 IGW（${target}）——该子网实际是公有子网，EKS 节点可出网但无 NAT 隔离" ;;
          *)
            warn "${rtb} 默认路由目标未知（${target}），按已具备出网处理" ;;
        esac
        ;;
      blackhole)
        # 只报告事实，是否致命由调用方按 CREATE_NAT_GATEWAY 策略判断
        warn "${rtb} 默认路由是 blackhole（目标 ${target} 已被删除）—— 私有子网当前无法出网"
        if [[ "${fix}" == "yes" ]]; then
          log "删除 ${rtb} 上的残留默认路由"
          aws ec2 delete-route --route-table-id "${rtb}" --destination-cidr-block 0.0.0.0/0
          ok "${rtb} 残留路由已清理"
          RTBS_NEED_ROUTE="${RTBS_NEED_ROUTE} ${rtb}"
          NEED_NAT=1
        else
          RTBS_NEED_ROUTE="${RTBS_NEED_ROUTE} ${rtb}"
          NEED_NAT=1
        fi
        ;;
      NONE)
        warn "${rtb} 没有 0.0.0.0/0 默认路由 —— 私有子网无法出网"
        RTBS_NEED_ROUTE="${RTBS_NEED_ROUTE} ${rtb}"
        NEED_NAT=1
        ;;
      *)
        warn "${rtb} 默认路由状态 ${state}（目标 ${target}），按需人工确认"
        ;;
    esac
  done
  RTBS_NEED_ROUTE="$(echo "${RTBS_NEED_ROUTE}" | xargs || true)"
}

pick_nat_public_subnet() {
  # 选一个默认路由指向 IGW 的公有子网放 NAT 网关
  local IFS=','; read -r -a subs <<< "${PUBLIC_SUBNET_IDS}"; unset IFS
  local rtb state target
  for sn in "${subs[@]}"; do
    rtb="$(route_table_for_subnet "${sn}")"
    read -r state target <<< "$(default_route_state "${rtb}")"
    if [[ "${state}" == "active" && "${target}" == igw-* ]]; then
      echo "${sn}"; return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------- 子网标签
tag_subnets_for_k8s() {
  # AWS Load Balancer Controller 靠子网标签做自动发现：
  #   公有子网 kubernetes.io/role/elb=1           -> internet-facing ALB/NLB
  #   私有子网 kubernetes.io/role/internal-elb=1  -> internal ALB/NLB
  # 集群标签用 shared，表示子网由客户拥有、EKS 只是共享使用（删集群不会动子网）。
  local cluster_tag="kubernetes.io/cluster/${CLUSTER_NAME}"
  local IFS=','

  read -r -a pubs <<< "${PUBLIC_SUBNET_IDS}"
  for sn in "${pubs[@]}"; do
    aws ec2 create-tags --resources "${sn}" \
      --tags "Key=kubernetes.io/role/elb,Value=1" "Key=${cluster_tag},Value=shared"
    ok "公有子网 ${sn} 已打标签 role/elb=1, ${cluster_tag}=shared"
  done

  read -r -a pris <<< "${PRIVATE_SUBNET_IDS}"
  for sn in "${pris[@]}"; do
    aws ec2 create-tags --resources "${sn}" \
      --tags "Key=kubernetes.io/role/internal-elb,Value=1" "Key=${cluster_tag},Value=shared"
    ok "私有子网 ${sn} 已打标签 role/internal-elb=1, ${cluster_tag}=shared"
  done
}

untag_subnets_for_k8s() {
  local cluster_tag="kubernetes.io/cluster/${CLUSTER_NAME}"
  local IFS=','
  read -r -a pubs <<< "${PUBLIC_SUBNET_IDS}"
  read -r -a pris <<< "${PRIVATE_SUBNET_IDS}"
  for sn in "${pubs[@]}"; do
    aws ec2 delete-tags --resources "${sn}" \
      --tags "Key=kubernetes.io/role/elb" "Key=${cluster_tag}" 2>/dev/null || true
  done
  for sn in "${pris[@]}"; do
    aws ec2 delete-tags --resources "${sn}" \
      --tags "Key=kubernetes.io/role/internal-elb" "Key=${cluster_tag}" 2>/dev/null || true
  done
  ok "子网上的 kubernetes.io/* 标签已清理"
}

# ---------------------------------------------------------------- AMI 解析
resolve_al2023_ami() {
  # resolve_al2023_ami <arm64|x86_64>
  # 不使用 {{resolve:ssm:/aws/service/...}}：部分账号的 SCP/权限边界禁止读 /aws/ 命名空间。
  local arch="$1" ami
  ami=$(aws ec2 describe-images --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023.*-kernel-6.1-${arch}" \
              "Name=state,Values=available" "Name=architecture,Values=${arch}" \
    --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)
  [[ -n "${ami}" && "${ami}" != "None" ]] || die "无法解析 ${arch} 的 AL2023 AMI"
  echo "${ami}"
}

instance_type_arch() {
  aws ec2 describe-instance-types --instance-types "$1" \
    --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures[0]' --output text
}

# ---------------------------------------------------------------- ALB Controller IAM 策略
ensure_lb_controller_policy() {
  # 输出策略 ARN。策略文件已随仓库固化（iam/），部署过程不依赖外网。
  local name="${CLUSTER_NAME}-AWSLoadBalancerControllerIAMPolicy"
  local file="${IAM_DIR}/aws-load-balancer-controller-iam-policy.json"
  local acct part arn
  acct="$(account_id)"; part="$(partition)"
  arn="arn:${part}:iam::${acct}:policy/${name}"
  [[ -f "${file}" ]] || die "缺少 IAM 策略文件: ${file}"

  if aws iam get-policy --policy-arn "${arn}" >/dev/null 2>&1; then
    echo "${arn}"; return 0
  fi
  aws iam create-policy --policy-name "${name}" \
    --policy-document "file://${file}" \
    --description "AWS Load Balancer Controller for EKS ${CLUSTER_NAME}" \
    --query 'Policy.Arn' --output text
}

delete_lb_controller_policy() {
  local name="${CLUSTER_NAME}-AWSLoadBalancerControllerIAMPolicy"
  local acct part arn v
  acct="$(account_id)"; part="$(partition)"
  arn="arn:${part}:iam::${acct}:policy/${name}"
  aws iam get-policy --policy-arn "${arn}" >/dev/null 2>&1 || return 0
  # 删除非默认版本后才能删策略
  for v in $(aws iam list-policy-versions --policy-arn "${arn}" \
              --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "${arn}" --version-id "${v}" || true
  done
  aws iam delete-policy --policy-arn "${arn}" && ok "IAM 策略 ${name} 已删除"
}

# ---------------------------------------------------------------- kubectl / helm
my_egress_ip() { curl -s --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]'; }

cluster_api_endpoint() {
  aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.endpoint' --output text 2>/dev/null
}

kubeconfig_endpoint() {
  kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null
}

public_access_cidrs() {
  aws eks describe-cluster --name "${CLUSTER_NAME}" \
    --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text 2>/dev/null | tr '\t' '\n'
}

# 等 update-cluster-config 真正生效。不能只看 cluster.status：刚提交时它可能还是 ACTIVE
wait_eks_update() {
  local st
  for _ in $(seq 1 90); do
    st=$(aws eks describe-update --name "${CLUSTER_NAME}" --update-id "$1" --query 'update.status' --output text 2>/dev/null)
    case "${st}" in
      Successful) return 0 ;;
      Failed|Cancelled) err "集群更新 $1 ${st}"; return 1 ;;
    esac
    sleep 10
  done
  err "集群更新 $1 15 分钟内未完成"; return 1
}

# 追加当前出口 IP 到公共端点白名单（allow-my-ip.sh 的函数化版本，供脚本内自动修复调用）
append_my_ip_to_whitelist() {
  local ip new
  ip="$(my_egress_ip)"
  [[ "${ip}" =~ ^[0-9.]+$ ]] || { err "取不到当前出口 IP"; return 1; }
  if public_access_cidrs | grep -qx "${ip}/32"; then
    ok "${ip}/32 已在白名单内"; return 0
  fi
  # 必须追加而不是替换，否则会把正在使用的其他终端（例如客户的 CloudShell）踢出去
  new=$(printf '%s\n%s\n' "$(public_access_cidrs)" "${ip}/32" | grep -v '^$' | sort -u | paste -sd, -)
  log "把 ${ip}/32 追加到公共端点白名单：${new}"
  local uid
  uid=$(aws eks update-cluster-config --name "${CLUSTER_NAME}" \
    --resources-vpc-config "publicAccessCidrs=${new},endpointPublicAccess=true,endpointPrivateAccess=true" \
    --query 'update.id' --output text) || { err "更新白名单失败"; return 1; }
  wait_eks_update "${uid}" || return 1
  ok "白名单已更新（注意：这是带外修改，${STACK_CLUSTER} 栈会出现配置漂移，建议同步回 config.env）"
}

# 用 `get --raw /version` 探活：失败时只吐纯文本错误，不会像 `kubectl version` 那样
# 混入 JSON，便于下面 diagnose_kube_access 做归类和展示。
kube_reachable() { kubectl get --raw /version --request-timeout=20s >/dev/null 2>&1; }

# kubectl 连不上时做分类诊断。三种失败模式的补救措施完全不同：
#   no such host          -> kubeconfig 指向已删除的集群（同名集群重建后最容易踩，context 名一模一样）
#   localhost:8080 refused-> 根本没有 kubeconfig（例如跳过 03-post-install 直接跑 04-verify）
#   i/o timeout           -> 出口 IP 不在公共端点白名单里
diagnose_kube_access() {
  local errmsg api_ep kc_ep myip
  errmsg="$(kubectl get --raw /version --request-timeout=20s 2>&1 || true)"
  api_ep="$(cluster_api_endpoint)"
  kc_ep="$(kubeconfig_endpoint)"
  myip="$(my_egress_ip)"

  hr
  err "kubectl 无法访问 API Server，分类诊断如下"
  printf '  集群实际端点   : %s\n' "${api_ep:-取不到}"
  printf '  kubeconfig 端点: %s\n' "${kc_ep:-未配置}"
  printf '  当前出口 IP    : %s\n' "${myip:-取不到}"
  printf '  白名单         : %s\n' "$(public_access_cidrs | paste -sd, -)"
  printf '  原始报错       : %s\n' "$(printf '%s' "${errmsg}" | grep -v '^[[:space:]]*$' | head -1 | cut -c1-200)"
  echo

  case "${errmsg}" in
    *"no such host"*|*"server could not find"*)
      err "原因：kubeconfig 指向的端点已不存在 —— 通常是同名集群被重建过，而 context 名完全一样所以没察觉"
      printf '  修复：aws eks update-kubeconfig --region %s --name %s\n' "${AWS_REGION}" "${CLUSTER_NAME}"
      ;;
    *"localhost:8080"*|*"127.0.0.1:8080"*|*"[::1]:8080"*)
      err "原因：当前没有可用的 kubeconfig（kubectl 退化到默认的 localhost:8080）"
      printf '  修复：aws eks update-kubeconfig --region %s --name %s\n' "${AWS_REGION}" "${CLUSTER_NAME}"
      ;;
    *timeout*|*"deadline exceeded"*|*"i/o"*)
      if [[ -n "${myip}" ]] && ! public_access_cidrs | grep -qx "${myip}/32"; then
        err "原因：当前出口 IP ${myip} 不在公共端点白名单里（CloudShell 的出口 IP 会轮换）"
        printf '  修复：./scripts/allow-my-ip.sh\n'
      else
        err "原因：出口 IP 在白名单内但仍超时 —— 检查本机到 AWS 的网络、代理，或安全组是否被改动"
      fi
      ;;
    *Unauthorized*|*forbidden*|*"401"*|*"403"*)
      err "原因：网络通但鉴权失败 —— 当前 IAM 身份没有集群访问权限"
      printf '  当前身份：%s\n' "$(caller_arn)"
      printf '  已有 Access Entry：\n'
      aws eks list-access-entries --cluster-name "${CLUSTER_NAME}" --query 'accessEntries' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/    /'
      printf '  修复：在 config.env 里设置 ADMIN_PRINCIPAL_ARN 后重新部署 cluster 栈，或手工创建 Access Entry\n'
      ;;
    *)
      err "未能归类，请把上面的原始报错贴出来"
      ;;
  esac
  hr
}

# 写 kubeconfig 并确认真的连得上。
# 这是 03/04 脚本的统一入口：04-verify 必须自己写 kubeconfig，
# 不能假设 03-post-install 已经跑过（否则会得到误导性的 localhost:8080 报错）。
setup_kubeconfig() {
  need_cmd kubectl
  local st
  st=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.status' --output text 2>/dev/null || echo MISSING)
  case "${st}" in
    ACTIVE)   ;;
    MISSING)  die "集群 ${CLUSTER_NAME} 不存在（区域 ${AWS_REGION}）。请先执行 ./scripts/02-deploy.sh" ;;
    CREATING) die "集群 ${CLUSTER_NAME} 还在 CREATING，请等它 ACTIVE 后重试" ;;
    *)        die "集群 ${CLUSTER_NAME} 状态为 ${st}，无法继续" ;;
  esac

  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null
  ok "kubeconfig 已指向 $(cluster_api_endpoint)"
  printf '  context: %s\n' "$(kubectl config current-context)"

  if kube_reachable; then
    ok "API Server 可达"
    return 0
  fi

  # 连不上：白名单类问题可按 FIX_API_WHITELIST 自动修
  local myip; myip="$(my_egress_ip)"
  if [[ -n "${myip}" ]] && ! public_access_cidrs | grep -qx "${myip}/32"; then
    case "${FIX_API_WHITELIST:-auto}" in
      auto|true)
        warn "当前出口 IP ${myip} 不在公共端点白名单里，按 FIX_API_WHITELIST=${FIX_API_WHITELIST:-auto} 自动追加"
        append_my_ip_to_whitelist || { diagnose_kube_access; die "白名单自动修复失败"; }
        kube_reachable && { ok "API Server 现在可达"; return 0; }
        ;;
    esac
  fi

  diagnose_kube_access
  die "无法访问 API Server，请按上面的修复建议处理后重试"
}

wait_nodes_ready() {
  local want="${1:-1}" timeout="${2:-600}" elapsed=0 ready
  log "等待至少 ${want} 个节点 Ready（超时 ${timeout}s）"
  while (( elapsed < timeout )); do
    ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
    if (( ready >= want )); then ok "${ready} 个节点 Ready"; return 0; fi
    sleep 15; elapsed=$((elapsed+15))
  done
  kubectl get nodes || true
  return 1
}
