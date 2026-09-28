#!/usr/bin/env bash
# =============================================================================
#  00-discover.sh —— 探测目标 VPC 的网络实况，并给出 config.env 建议值
#  只读报告，排查网络问题时用。填写 config.env 请用 configure-network.sh（01-preflight 会自动调用）
#  用法： ./scripts/00-discover.sh [vpc-id]    （不传则用 config.env 里的 VPC_ID）
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TARGET_VPC="${1:-${VPC_ID}}"

section "身份与区域"
printf '  Account : %s\n' "$(account_id)"
printf '  Caller  : %s\n' "$(caller_arn)"
printf '  Region  : %s\n' "${AWS_REGION}"

section "VPC ${TARGET_VPC}"
aws ec2 describe-vpcs --vpc-ids "${TARGET_VPC}" \
  --query 'Vpcs[].{VpcId:VpcId,Cidr:CidrBlock,Name:Tags[?Key==`Name`].Value|[0],DnsSupport:EnableDnsSupport}' \
  --output table
echo "  所有关联 CIDR:"
aws ec2 describe-vpcs --vpc-ids "${TARGET_VPC}" \
  --query 'Vpcs[0].CidrBlockAssociationSet[].CidrBlock' --output text | tr '\t' '\n' | sed 's/^/    /'

section "子网（含所属路由表与默认路由）"
printf '  %-26s %-17s %-16s %-7s %-6s %-23s %s\n' SUBNET AZ CIDR PUB_IP FREE_IP ROUTE_TABLE DEFAULT_ROUTE
while read -r sn az cidr pub free name; do
  rtb="$(route_table_for_subnet "${sn}")"
  read -r state target <<< "$(default_route_state "${rtb}")"
  kind="private"
  [[ "${target}" == igw-* && "${state}" == "active" ]] && kind="PUBLIC"
  printf '  %-26s %-17s %-16s %-7s %-6s %-23s %s/%s  [%s] %s\n' \
    "${sn}" "${az}" "${cidr}" "${pub}" "${free}" "${rtb}" "${state}" "${target}" "${kind}" "${name}"
done < <(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${TARGET_VPC}" \
  --query 'sort_by(Subnets,&AvailabilityZone)[].[SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch,AvailableIpAddressCount,Tags[?Key==`Name`].Value|[0]]' \
  --output text)

section "NAT 网关 / IGW / VPC Endpoint"
echo "  NAT 网关:"
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${TARGET_VPC}" \
  --query 'NatGateways[].[NatGatewayId,State,SubnetId,ConnectivityType]' --output text | sed 's/^/    /' \
  || true
[[ -z "$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${TARGET_VPC}" --query 'NatGateways[]' --output text)" ]] \
  && echo "    （无）"
echo "  Internet Gateway:"
aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${TARGET_VPC}" \
  --query 'InternetGateways[].InternetGatewayId' --output text | tr '\t' '\n' | sed 's/^/    /'
echo "  VPC Endpoint:"
aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${TARGET_VPC}" \
  --query 'VpcEndpoints[].[VpcEndpointId,ServiceName,VpcEndpointType,State]' --output text | sed 's/^/    /'
[[ -z "$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${TARGET_VPC}" --query 'VpcEndpoints[]' --output text)" ]] \
  && echo "    （无）"

section "子网上已有的 kubernetes.io 标签"
aws ec2 describe-subnets --filters "Name=vpc-id,Values=${TARGET_VPC}" \
  --query 'Subnets[].{Subnet:SubnetId,K8sTags:join(`; `,Tags[?contains(Key,`kubernetes.io`)].[Key,Value][])}' \
  --output table

section "建议的 config.env 片段"
PUBS=""; PRIS=""
while read -r sn; do
  rtb="$(route_table_for_subnet "${sn}")"
  read -r state target <<< "$(default_route_state "${rtb}")"
  if [[ "${target}" == igw-* && "${state}" == "active" ]]; then
    PUBS="${PUBS},${sn}"
  else
    PRIS="${PRIS},${sn}"
  fi
done < <(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${TARGET_VPC}" \
  --query 'sort_by(Subnets,&AvailabilityZone)[].SubnetId' --output text | tr '\t' '\n')

cat <<EOF
  VPC_ID="${TARGET_VPC}"
  PUBLIC_SUBNET_IDS="${PUBS:1}"
  PRIVATE_SUBNET_IDS="${PRIS:1}"
  PRIVATE_ROUTE_TABLE_IDS=""          # 留空由脚本自动反查
  API_PUBLIC_ACCESS_CIDRS="$(curl -s --max-time 8 https://checkip.amazonaws.com 2>/dev/null || echo '<你的出口IP>')/32"

  注意：上面按"默认路由是否指向 IGW"来区分公私有子网。请人工复核，
  特别是既无 IGW 也无 NAT 路由的子网会被归到 PRIVATE。
EOF
echo
