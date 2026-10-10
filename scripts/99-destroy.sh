#!/usr/bin/env bash
# =============================================================================
#  99-destroy.sh —— 逆序清理本套交付创建的全部资源
#
#  顺序很重要：先清集群内由控制器创建的 AWS 资源（ALB/NLB/安全组），
#  否则这些"CFN 不知道的"资源会挂在子网/安全组上，导致后面的栈删不掉。
#
#  用法：
#    ./scripts/99-destroy.sh              # 交互确认
#    ASSUME_YES=1 ./scripts/99-destroy.sh # 无人值守
#    KEEP_NETWORK=1 ./scripts/99-destroy.sh  # 保留 NAT 网关栈
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
STACK_NODEGROUP_ARM="${STACK_NODEGROUP_ARM:-${PROJECT}-${ENVIRONMENT}-eks-nodegroup-arm64}"

section "将要删除的内容"
cat <<EOF
  Region / Account : ${AWS_REGION} / $(account_id)

  1. 集群内 Helm release 与 Ingress/LoadBalancer Service（连带其 ALB/NLB）
  2. 栈 ${STACK_NACOS}          （Nacos EC2 + RDS + NLB + Secrets）
     —— 不受 INSTALL_NACOS 开关影响：始终尝试清理，以防之前部署过后又把开关关掉
  3. 栈 ${STACK_ADDONS}         （Addon + 控制器 IAM 角色）
  4. 栈 ${STACK_NODEGROUP_ARM}（Graviton 节点组，55-arm-nodegroup.sh 部署过时）
     栈 ${STACK_NODEGROUP}      （托管节点组 + 节点 IAM）
  5. 栈 ${STACK_CLUSTER}        （EKS 控制面 + 控制面日志组）
  6. 子网上的 kubernetes.io/* 标签
  7. IAM 策略 ${CLUSTER_NAME}-AWSLoadBalancerControllerIAMPolicy
  8. Secrets Manager 中 4 个 Nacos 密钥（强制立即删除，不留 30 天恢复期）
$( [[ "${KEEP_NETWORK:-0}" == "1" ]] && echo "  （保留）栈 ${STACK_NETWORK}" || echo "  9. 栈 ${STACK_NETWORK}          （NAT 网关 + EIP + 私有默认路由）" )

  保留项（需要时手工处理）：
    - RDS 最终快照（DeletionPolicy: Snapshot，删库时会自动留一份）
    - EKS Secrets 加密用的 KMS CMK（DeletionPolicy: Retain）
    - 客户自有的 VPC / 子网 / 路由表本身（本套交付从不创建或删除它们）
EOF
confirm "确认删除？此操作不可逆" || die "已取消"
echo
confirm "再确认一次：这会删掉 Nacos 的 RDS 实例和 EKS 集群" || die "已取消"

# =============================================================================
section "1. 清理集群内资源"
if command -v kubectl >/dev/null 2>&1 && aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true

  if kubectl get ns >/dev/null 2>&1; then
    log "删除所有 Ingress（触发 ALB 回收）"
    kubectl delete ingress --all-namespaces --all --ignore-not-found --timeout=180s || true

    log "删除所有 type=LoadBalancer 的 Service（触发 NLB/CLB 回收）"
    kubectl get svc --all-namespaces -o json 2>/dev/null \
      | python3 -c '
import json,sys
d=json.load(sys.stdin)
for s in d["items"]:
    if s["spec"].get("type")=="LoadBalancer":
        print(s["metadata"]["namespace"], s["metadata"]["name"])' \
      | while read -r ns name; do
          log "  删除 svc ${ns}/${name}"
          kubectl -n "${ns}" delete svc "${name}" --ignore-not-found --timeout=180s || true
        done

    log "等待 60 秒让控制器完成 AWS 侧负载均衡器删除"
    sleep 60

    for r in cluster-autoscaler aws-load-balancer-controller; do
      if helm -n kube-system status "$r" >/dev/null 2>&1; then
        log "卸载 helm release ${r}"
        helm -n kube-system uninstall "$r" --wait --timeout 5m || true
      fi
    done

    kubectl delete namespace app --ignore-not-found --timeout=180s || true
    ok "集群内资源清理完成"
  else
    warn "kubectl 连不上集群（可能出口 IP 不在白名单），跳过集群内清理"
    warn "若集群内还有 Ingress/LoadBalancer Service，残留的 ALB/NLB 会阻塞后续删除"
  fi
else
  log "集群不存在或本机无 kubectl，跳过"
fi

# =============================================================================
section "2. 栈 ${STACK_NACOS}"
delete_stack "${STACK_NACOS}" || warn "继续执行后续清理"

section "3. 栈 ${STACK_ADDONS}"
delete_stack "${STACK_ADDONS}" || warn "继续执行后续清理"

section "4. 栈 ${STACK_NODEGROUP_ARM} / ${STACK_NODEGROUP}"
# 集群上还挂着任何节点组都删不掉控制面，所以扩展的 arm 节点组必须在这里一起删
delete_stack "${STACK_NODEGROUP_ARM}" || warn "继续执行后续清理"
delete_stack "${STACK_NODEGROUP}" || warn "继续执行后续清理"

section "5. 栈 ${STACK_CLUSTER}"
delete_stack "${STACK_CLUSTER}" || warn "继续执行后续清理"

# =============================================================================
section "6. 子网标签"
untag_subnets_for_k8s

section "7. ALB Controller IAM 策略"
delete_lb_controller_policy || warn "策略删除失败（可能仍被其他角色引用）"

# =============================================================================
section "8. Secrets Manager 密钥"
# CFN 删除 Secret 时默认保留 30 天恢复期，期间同名密钥无法重建。
# 交付演练/反复重建场景下必须强制清掉，否则下次 02-deploy 会失败。
for s in db console-admin auth-token server-identity; do
  name="${PROJECT}/${ENVIRONMENT}/nacos/${s}"
  if aws secretsmanager describe-secret --secret-id "${name}" >/dev/null 2>&1; then
    aws secretsmanager delete-secret --secret-id "${name}" --force-delete-without-recovery \
      --query 'Name' --output text >/dev/null 2>&1 \
      && ok "密钥 ${name} 已强制删除" \
      || warn "密钥 ${name} 删除失败"
  else
    log "密钥 ${name} 不存在"
  fi
done

# =============================================================================
if [[ "${KEEP_NETWORK:-0}" == "1" ]]; then
  section "9. 栈 ${STACK_NETWORK}（按 KEEP_NETWORK=1 保留）"
  warn "NAT 网关保留，会持续计费（约 \$0.045/小时 + 数据处理费）"
else
  section "9. 栈 ${STACK_NETWORK}"
  warn '删除后私有子网将恢复为「无默认路由」状态（即本次部署前的原始状态）'
  delete_stack "${STACK_NETWORK}" || warn "删除失败"
fi

# =============================================================================
section "残留检查"
echo "  CloudFormation 栈:"
for s in "${STACK_NETWORK}" "${STACK_CLUSTER}" "${STACK_NODEGROUP}" "${STACK_NODEGROUP_ARM}" "${STACK_ADDONS}" "${STACK_NACOS}"; do
  printf '    %-46s %s\n' "$s" "$(stack_status "$s")"
done
BASTION_ST="$(stack_status "${STACK_BASTION:-${PROJECT}-${ENVIRONMENT}-bastion}")"
if [[ "${BASTION_ST}" != "DOES_NOT_EXIST" ]]; then
  printf '    %-46s %s\n' "${STACK_BASTION:-${PROJECT}-${ENVIRONMENT}-bastion}" "${BASTION_ST}"
  warn "运维 EC2 扩展栈不随本脚本删除（仍在计费），需要时执行 ./scripts/50-bastion.sh destroy"
fi
CI_ST="$(stack_status "${STACK_CI:-${PROJECT}-${ENVIRONMENT}-ci-ecr}")"
if [[ "${CI_ST}" != "DOES_NOT_EXIST" ]]; then
  printf '    %-46s %s\n' "${STACK_CI:-${PROJECT}-${ENVIRONMENT}-ci-ecr}" "${CI_ST}"
  warn "Jenkins CI 扩展栈（IAM 用户 / 访问密钥或 Roles Anywhere）不随本脚本删除，需要时执行 ./scripts/60-ci-setup.sh destroy"
fi

echo "  VPC 内残留的负载均衡器:"
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?VpcId=='${VPC_ID}'].[LoadBalancerName,Type,Scheme,State.Code]" --output text \
  | sed 's/^/    /' || true
[[ -z "$(aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='${VPC_ID}']" --output text)" ]] \
  && echo "    （无）"

echo "  RDS 快照（如需彻底清理请手工删除）:"
aws rds describe-db-snapshots --snapshot-type manual \
  --query "DBSnapshots[?contains(DBInstanceIdentifier,'${PROJECT}-${ENVIRONMENT}-nacos')].[DBSnapshotIdentifier,Status,SnapshotCreateTime]" \
  --output text | sed 's/^/    /' || true

echo "  保留的 KMS CMK（DeletionPolicy: Retain）:"
# 别名是随栈删除的（AWS::KMS::Alias 没设 Retain），所以不能靠别名找，
# 否则保留下来的密钥会变成"查不到的孤儿"，反复演练时按每把 \$1/月累积。
# 这里按 Description 扫描，并直接给出可复制的删除命令。
KMS_FOUND=0
for k in $(aws kms list-keys --query 'Keys[].KeyId' --output text); do
  read -r desc state <<< "$(aws kms describe-key --key-id "${k}" \
    --query 'KeyMetadata.[Description,KeyState]' --output text 2>/dev/null || echo '- -')"
  case "${desc}" in
    *"${CLUSTER_NAME} etcd secrets"*)
      printf '    %s  [%s]  %s\n' "${k}" "${state}" "${desc}"
      printf '      删除: aws kms schedule-key-deletion --region %s --key-id %s --pending-window-in-days 7\n' \
        "${AWS_REGION}" "${k}"
      KMS_FOUND=1
      ;;
  esac
done
(( KMS_FOUND == 1 )) || echo "    （无）"

hr
ok "清理流程结束，请按上面的残留清单人工复核"
cat <<EOF

  说明：以下两处是**故意不回滚**的，因为回滚可能影响客户其他工作负载：

    1. VPC 的 enableDnsSupport / enableDnsHostnames 保持开启
       —— 这是 EKS 的硬性要求，也是通用的良好实践，回滚反而会埋坑。
    2. RDS 最终快照与 KMS CMK 保留
       —— 数据类资源不做自动销毁，需要时按上面给出的命令手工删除。

  私有子网的默认路由已随 NAT 栈一起删除，恢复为部署前状态。
EOF
