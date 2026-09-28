#!/usr/bin/env bash
# =============================================================================
#  01-preflight.sh —— 部署前检查。只读，不改任何资源。
#  发现阻塞性问题会以非 0 退出；02-deploy.sh 会自动修掉网络类问题。
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# config.env 的网络配置在当前账号 / 区域无效（例如仍是随包示例值）时，先走交互式网络配置向导。
# 也可用 --configure 强制重新选择 VPC / 子网。
if [[ "${1:-}" == "--configure" ]] || ! network_config_ok; then
  if [[ "${1:-}" != "--configure" ]]; then
    warn "config.env 中的 VPC / 子网（VPC_ID=${VPC_ID:-空}）在账号 $(account_id) / ${AWS_REGION} 中不存在或不匹配"
    printf '  %s\n' "随包的是示例值，需要换成你自己的网络。下面进入网络配置向导（只写 config.env，不改任何 AWS 资源）"
  fi
  [[ -t 0 ]] || die "非交互环境无法选择子网：请先执行 ASSUME_YES=1 ./scripts/configure-network.sh <vpc-id>"
  "$(dirname "${BASH_SOURCE[0]}")/configure-network.sh"
  echo; log "网络配置已更新，重新加载 config.env 继续预检"
  exec "$0"
fi

FAILED=0
fail() { err "$*"; FAILED=$((FAILED+1)); }

section "1. 本地工具"
for c in aws curl; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c: $(command -v "$c")"; else fail "缺少 $c"; fi
done
MISSING_K8S_TOOLS=0
for c in kubectl helm; do
  if command -v "$c" >/dev/null 2>&1; then
    ok "$c: $(command -v "$c")"
  else
    warn "缺少 ${c}（CloudShell 默认不带）"
    MISSING_K8S_TOOLS=1
  fi
done
if (( MISSING_K8S_TOOLS == 1 )); then
  printf '  %s\n' "→ 先执行：./scripts/install-tools.sh && export PATH=\"\$HOME/.local/bin:\$PATH\""
  printf '  %s\n' "  （02-deploy.sh 不需要 kubectl/helm；03-post-install.sh 需要）"
fi
printf '  python3 : %s\n' "$(python3 --version 2>&1)"
printf '  aws cli : %s\n' "$(aws --version 2>&1)"
if [[ -n "${AWS_EXECUTION_ENV:-}" ]]; then
  printf '  运行环境: %s\n' "${AWS_EXECUTION_ENV}"
fi

section "2. 身份与区域"
ACCOUNT="$(account_id)"
printf '  Account : %s\n' "${ACCOUNT}"
printf '  Caller  : %s\n' "$(caller_arn)"
printf '  Region  : %s\n' "${AWS_REGION}"
printf '  Cluster : %s (K8s %s)\n' "${CLUSTER_NAME}" "${K8S_VERSION}"

section "3. EKS 版本可用性"
VER_INFO=$(aws eks describe-cluster-versions \
  --query "clusterVersions[?clusterVersion=='${K8S_VERSION}'].[clusterVersion,kubernetesPatchVersion,versionStatus,endOfStandardSupportDate,defaultVersion]" \
  --output text)
if [[ -z "${VER_INFO}" ]]; then
  fail "区域 ${AWS_REGION} 不支持 EKS ${K8S_VERSION}，可用版本："
  aws eks describe-cluster-versions --query 'clusterVersions[].clusterVersion' --output text
else
  printf '  %s\n' "${VER_INFO}"
  STATUS=$(echo "${VER_INFO}" | awk '{print $3}')
  [[ "${STATUS}" == "STANDARD_SUPPORT" ]] \
    && ok "EKS ${K8S_VERSION} 处于标准支持期" \
    || warn "EKS ${K8S_VERSION} 状态为 ${STATUS}（扩展支持会产生额外费用）"
fi

section "4. Addon 默认版本（存档用，部署时不写死版本）"
for a in eks-pod-identity-agent vpc-cni kube-proxy coredns aws-ebs-csi-driver metrics-server; do
  v=$(aws eks describe-addon-versions --kubernetes-version "${K8S_VERSION}" --addon-name "$a" \
      --query 'addons[0].addonVersions[?compatibilities[0].defaultVersion==`true`].addonVersion | [0]' \
      --output text 2>/dev/null)
  printf '  %-26s %s\n' "$a" "${v:-解析失败}"
done

section "5. VPC 与子网"
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null) \
  || fail "VPC ${VPC_ID} 不存在或无权访问"
printf '  VPC %s  CIDR %s\n' "${VPC_ID}" "${VPC_CIDR}"

check_subnets() {
  local label="$1" csv="$2" want_public="$3"
  local IFS=','; read -r -a arr <<< "${csv}"; unset IFS
  local azs=() free_total=0
  for sn in "${arr[@]}"; do
    local vpc az free rtb state target
    vpc=$(subnet_field "${sn}" VpcId 2>/dev/null) || { fail "${label} ${sn} 不存在"; continue; }
    [[ "${vpc}" == "${VPC_ID}" ]] || fail "${label} ${sn} 不属于 ${VPC_ID}（实际 ${vpc}）"
    az=$(subnet_field "${sn}" AvailabilityZone)
    free=$(subnet_field "${sn}" AvailableIpAddressCount)
    rtb="$(route_table_for_subnet "${sn}")"
    read -r state target <<< "$(default_route_state "${rtb}")"
    azs+=("${az}"); free_total=$((free_total+free))
    printf '  %-10s %-26s %-17s free=%-5s %s -> %s/%s\n' "${label}" "${sn}" "${az}" "${free}" "${rtb}" "${state}" "${target}"
    if [[ "${want_public}" == "yes" && ! ( "${target}" == igw-* && "${state}" == "active" ) ]]; then
      fail "${label} ${sn} 默认路由未指向 IGW，不能当公有子网用（NAT 网关与 internet-facing ALB 依赖它）"
    fi
    if [[ "${want_public}" == "no" && "${target}" == igw-* && "${state}" == "active" ]]; then
      warn "${label} ${sn} 默认路由指向 IGW，实际是公有子网"
    fi
  done
  local uniq_az; uniq_az=$(printf '%s\n' "${azs[@]}" | sort -u | wc -l | tr -d ' ')
  if (( uniq_az < 2 )); then
    fail "${label} 只覆盖 ${uniq_az} 个 AZ，EKS 要求至少 2 个 AZ"
  else
    ok "${label} 覆盖 ${uniq_az} 个 AZ，可用 IP 合计 ${free_total}"
  fi
  echo "${free_total}" > "${OUT_DIR}/free_ip_${label}"
}
check_subnets public  "${PUBLIC_SUBNET_IDS}"  yes
check_subnets private "${PRIVATE_SUBNET_IDS}" no

section "6. VPC DNS 属性（EKS 节点注册的硬性前提）"
if ! ensure_vpc_dns_attributes check; then
  case "${FIX_VPC_DNS:-auto}" in
    auto|true)
      warn "02-deploy.sh 会在建集群前自动开启这两个属性"
      printf '  %s\n' "说明：属性为 false 时，节点会把集群端点解析成公网 IP 并走 NAT 访问，"
      printf '  %s\n' "      而公共端点白名单里没有 NAT 的 EIP，节点会一直注册失败且报错不指向 DNS。"
      ;;
    *)
      fail "VPC DNS 属性不满足要求，且 FIX_VPC_DNS=${FIX_VPC_DNS}。请手工执行："
      printf '  %s\n' "aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-support"
      printf '  %s\n' "aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-hostnames"
      ;;
  esac
fi

section "7. 私有子网出网能力（EKS 节点拉 ECR 镜像 / Nacos 下载安装包的前提）"
analyze_private_egress no
printf '  私有路由表      : %s\n' "${PRIVATE_RTBS}"
if (( NEED_NAT == 1 )); then
  printf '  需要补路由的表  : %s\n' "${RTBS_NEED_ROUTE}"
  case "${CREATE_NAT_GATEWAY}" in
    auto|true)
      warn "私有子网当前无法出网。CREATE_NAT_GATEWAY=${CREATE_NAT_GATEWAY}，02-deploy.sh 会自动清理残留路由并创建 NAT 网关"
      if NAT_SN=$(pick_nat_public_subnet); then
        ok "NAT 网关将放在公有子网 ${NAT_SN}"
      else
        fail "找不到默认路由指向 IGW 的公有子网，无法放置 NAT 网关"
      fi
      ;;
    false)
      fail "私有子网无法出网，且 CREATE_NAT_GATEWAY=false。请先修好出网，或配置 ECR/EKS/S3/STS/Logs/SSM 等 VPC Endpoint"
      ;;
  esac
else
  ok "私有子网已具备出网能力，无需创建 NAT 网关"
fi

section "8. Service CIDR 冲突检查"
overlap() {
  python3 - "$1" "$2" <<'PY'
import ipaddress, sys
a = ipaddress.ip_network(sys.argv[1]); b = ipaddress.ip_network(sys.argv[2])
sys.exit(0 if a.overlaps(b) else 1)
PY
}
ALL_CIDRS=$(aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" \
  --query 'Vpcs[0].CidrBlockAssociationSet[].CidrBlock' --output text)
CONFLICT=0
for c in ${ALL_CIDRS}; do
  if overlap "${SERVICE_IPV4_CIDR}" "${c}"; then
    fail "Service CIDR ${SERVICE_IPV4_CIDR} 与 VPC CIDR ${c} 重叠（集群创建后不可修改）"
    CONFLICT=1
  fi
done
(( CONFLICT == 0 )) && ok "Service CIDR ${SERVICE_IPV4_CIDR} 与 VPC CIDR(${ALL_CIDRS//$'\t'/, }) 无重叠"

section "9. 机型可用性与架构匹配"
AZS=$(aws ec2 describe-subnets --subnet-ids ${PRIVATE_SUBNET_IDS//,/ } \
      --query 'Subnets[].AvailabilityZone' --output text | tr '\t' ',')
check_type() {
  local it="$1" expect_arch="$2" arch offered
  arch="$(instance_type_arch "${it}")"
  if [[ -n "${expect_arch}" && "${arch}" != "${expect_arch}" ]]; then
    fail "${it} 架构为 ${arch}，与期望 ${expect_arch} 不符"
  fi
  offered=$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=${it}" "Name=location,Values=${AZS}" \
    --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' ',')
  if [[ -z "${offered}" ]]; then
    fail "${it} 在 ${AZS} 均不可用"
  else
    ok "${it} (${arch}) 可用于: ${offered}"
  fi
}
EXPECT_NODE_ARCH=x86_64
[[ "${NODE_AMI_TYPE}" == *ARM_64* ]] && EXPECT_NODE_ARCH=arm64
for it in ${NODE_INSTANCE_TYPES//,/ }; do check_type "${it}" "${EXPECT_NODE_ARCH}"; done
if [[ "${INSTALL_NACOS}" == "true" ]]; then
  check_type "${NACOS_INSTANCE_TYPE}" ""
else
  warn "INSTALL_NACOS=false，跳过 Nacos 机型检查（本次只交付 EKS）"
fi

section "10. Pod IP 容量估算（VPC CNI 二级 IP 模式）"
FIRST_NODE_TYPE="${NODE_INSTANCE_TYPES%%,*}"
read -r NIC IPP <<< "$(aws ec2 describe-instance-types --instance-types "${FIRST_NODE_TYPE}" \
  --query 'InstanceTypes[0].NetworkInfo.[MaximumNetworkInterfaces,Ipv4AddressesPerInterface]' --output text)"
MAXPODS=$(( NIC * (IPP - 1) + 2 ))
PRIV_FREE=$(cat "${OUT_DIR}/free_ip_private" 2>/dev/null || echo 0)
printf '  %s: %s ENI x %s IP  => 单节点最多 %s 个 Pod\n' "${FIRST_NODE_TYPE}" "${NIC}" "${IPP}" "${MAXPODS}"
printf '  私有子网可用 IP 合计 %s，MAX 节点数 %s\n' "${PRIV_FREE}" "${NODE_MAX_SIZE}"
NEED_IP=$(( NODE_MAX_SIZE * (NIC * IPP) ))
if (( NEED_IP > PRIV_FREE )); then
  warn "满负载（${NODE_MAX_SIZE} 节点）理论需要约 ${NEED_IP} 个 IP，超过可用 ${PRIV_FREE}。可给 VPC 加辅助 CIDR（如 100.64.0.0/16）或调低 NODE_MAX_SIZE"
else
  ok "IP 容量充足（满负载约需 ${NEED_IP}，可用 ${PRIV_FREE}）"
fi

section "11. API Server 公共端点白名单"
printf '  config.env 原始值: %s\n' "$(grep -m1 '^API_PUBLIC_ACCESS_CIDRS=' "${ROOT_DIR}/config.env" | cut -d= -f2-)"
printf '  实际生效值      : %s\n' "${API_PUBLIC_ACCESS_CIDRS}"
if [[ "${API_PUBLIC_ACCESS_CIDRS}" == *"0.0.0.0/0"* ]]; then
  warn "公共端点对 0.0.0.0/0 开放。功能可用，但安全审计通常会要求收紧"
else
  ok "公共端点白名单: ${API_PUBLIC_ACCESS_CIDRS}"
  MYIP=$(curl -s --max-time 8 https://checkip.amazonaws.com 2>/dev/null || echo "")
  if [[ -n "${MYIP}" ]]; then
    printf '  当前出口 IP: %s\n' "${MYIP}"
    if [[ "${API_PUBLIC_ACCESS_CIDRS}" != *"${MYIP}"* ]]; then
      warn "当前出口 IP ${MYIP} 不在白名单里，部署完成后本机将无法 kubectl 访问集群"
    fi
  fi
fi

section "12. 已存在的同名资源"
for s in "${STACK_NETWORK}" "${STACK_CLUSTER}" "${STACK_NODEGROUP}" "${STACK_ADDONS}" "${STACK_NACOS}"; do
  st="$(stack_status "$s")"
  [[ "${st}" == "DOES_NOT_EXIST" ]] && printf '  %-44s -\n' "$s" || printf '  %-44s %s\n' "$s" "${st}"
done
if aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  warn "EKS 集群 ${CLUSTER_NAME} 已存在（若不是本套栈创建的，02-deploy 会失败）"
fi

hr
if (( FAILED > 0 )); then
  err "preflight 发现 ${FAILED} 个阻塞项，修复后再部署"
  exit 1
fi
ok "preflight 全部通过，可以执行 ./scripts/02-deploy.sh"
