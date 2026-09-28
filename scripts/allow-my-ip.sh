#!/usr/bin/env bash
# =============================================================================
#  allow-my-ip.sh —— 把当前出口 IP 加入 EKS API Server 公共端点白名单
#
#  为什么需要它：CloudShell 的出口 IP 不固定（不同会话/不同后端可能不同），
#  一旦轮换，之前白名单里的 /32 就失效，kubectl 会连不上。断连后跑一次本脚本即可。
#
#  用法：
#    ./scripts/allow-my-ip.sh            # 追加当前出口 IP
#    ./scripts/allow-my-ip.sh --replace  # 只保留当前出口 IP（清掉历史 /32）
#    ./scripts/allow-my-ip.sh --list     # 只看当前白名单
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="append"
case "${1:-}" in
  --replace) MODE="replace" ;;
  --list)    MODE="list" ;;
  "")        ;;
  *) die "未知参数: $1" ;;
esac

CURRENT=$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
  --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text | tr '\t' '\n' | sort -u)

section "集群 ${CLUSTER_NAME} 当前公共端点白名单"
printf '%s\n' "${CURRENT}" | sed 's/^/  /'

if [[ "${MODE}" == "list" ]]; then exit 0; fi

MYIP=$(curl -s --max-time 10 https://checkip.amazonaws.com | tr -d '\n')
[[ -n "${MYIP}" ]] || die "取不到当前出口 IP"
log "当前出口 IP: ${MYIP}"

if [[ "${MODE}" == "append" ]]; then
  if printf '%s\n' "${CURRENT}" | grep -qx "${MYIP}/32"; then
    ok "${MYIP}/32 已在白名单内，无需改动"
    exit 0
  fi
  NEW=$(printf '%s\n%s\n' "${CURRENT}" "${MYIP}/32" | grep -v '^$' | sort -u | paste -sd, -)
else
  NEW="${MYIP}/32"
fi

log "更新为: ${NEW}"
confirm "确认更新 ${CLUSTER_NAME} 的 publicAccessCidrs？" || die "已取消"

aws eks update-cluster-config --name "${CLUSTER_NAME}" \
  --resources-vpc-config "publicAccessCidrs=${NEW},endpointPublicAccess=true,endpointPrivateAccess=true" \
  --query 'update.[id,status]' --output text

log "等待集群配置更新完成（通常 1-3 分钟）"
for _ in $(seq 1 60); do
  st=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.status' --output text)
  [[ "${st}" == "ACTIVE" ]] && { ok "更新完成"; break; }
  sleep 10
done

warn "注意：这是对集群的带外修改，CloudFormation 栈 ${STACK_CLUSTER} 会出现配置漂移。"
warn "建议把最终白名单同步回 config.env 的 API_PUBLIC_ACCESS_CIDRS，保持 IaC 一致。"
aws eks describe-cluster --name "${CLUSTER_NAME}" \
  --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text | tr '\t' '\n' | sed 's/^/  /'
