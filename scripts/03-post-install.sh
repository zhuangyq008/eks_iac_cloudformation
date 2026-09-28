#!/usr/bin/env bash
# =============================================================================
#  03-post-install.sh —— 集群内组件安装（需要 kubectl + helm）
#    1. 写 kubeconfig
#    2. 等节点 Ready
#    3. gp3 设为默认 StorageClass（取消 gp2 默认）
#    4. AWS Load Balancer Controller（Helm + Pod Identity）
#    5. Cluster Autoscaler（Helm + Pod Identity，对接托管节点组 ASG）
#    6. 落一份 nacos-config ConfigMap，业务 Deployment 直接引用
#  幂等：可重复执行（helm upgrade --install）
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need_cmd kubectl
need_cmd helm

# =============================================================================
section "1. kubeconfig"
setup_kubeconfig
kubectl version --output=json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  client:",d["clientVersion"]["gitVersion"]," server:",d.get("serverVersion",{}).get("gitVersion","?"))' \
  || kubectl version --client --short || true

# =============================================================================
section "2. 节点就绪"
wait_nodes_ready "${NODE_MIN_SIZE}" 900 || die "节点未在 15 分钟内 Ready。用 'kubectl describe node' 和节点组事件排查（最常见原因是私有子网无法出网拉取 ECR 镜像）"
kubectl get nodes -o wide

section "2b. 托管 Addon 状态"
for a in eks-pod-identity-agent vpc-cni kube-proxy coredns aws-ebs-csi-driver metrics-server; do
  st=$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name "$a" \
        --query 'addon.[status,addonVersion]' --output text 2>/dev/null || echo "NOT_INSTALLED -")
  printf '  %-26s %s\n' "$a" "${st}"
done

# =============================================================================
if [[ "${SET_GP3_DEFAULT_SC}" == "true" ]]; then
  section "3. gp3 设为默认 StorageClass"
  kubectl apply -f "${MANIFEST_DIR}/gp3-storageclass.yaml"
  # EKS 自带的 gp2 是默认 SC，两个默认 SC 会让 PVC 绑定行为不确定，这里取消 gp2 的默认标记
  if kubectl get sc gp2 >/dev/null 2>&1; then
    kubectl patch storageclass gp2 \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null
    ok "gp2 已取消默认标记"
  fi
  kubectl get sc
fi

# =============================================================================
if [[ "${INSTALL_LB_CONTROLLER}" == "true" ]]; then
  section "4. AWS Load Balancer Controller (chart ${LB_CONTROLLER_CHART_VERSION})"

  ROLE_ARN="$(stack_output "${STACK_ADDONS}" LbControllerRoleArn)"
  [[ -n "${ROLE_ARN}" && "${ROLE_ARN}" != "None" ]] \
    || die "取不到 LbControllerRoleArn，请确认 ${STACK_ADDONS} 栈已成功部署"
  ok "Pod Identity 角色: ${ROLE_ARN}"
  aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" \
    --namespace kube-system --service-account aws-load-balancer-controller \
    --query 'associations[].associationId' --output text | sed 's/^/  association: /'

  helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
  helm repo update eks >/dev/null

  # 用 Pod Identity，不需要给 ServiceAccount 加 eks.amazonaws.com/role-arn 注解
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --version "${LB_CONTROLLER_CHART_VERSION}" \
    --set "clusterName=${CLUSTER_NAME}" \
    --set "region=${AWS_REGION}" \
    --set "vpcId=${VPC_ID}" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set replicaCount=2 \
    --set enableServiceMutatorWebhook=false \
    --wait --timeout 10m

  kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=300s
  ok "AWS Load Balancer Controller 就绪"
  kubectl get ingressclass 2>/dev/null || true
fi

# =============================================================================
if [[ "${INSTALL_CLUSTER_AUTOSCALER}" == "true" ]]; then
  section "5. Cluster Autoscaler (chart ${CLUSTER_AUTOSCALER_CHART_VERSION})"

  CA_ROLE_ARN="$(stack_output "${STACK_ADDONS}" ClusterAutoscalerRoleArn)"
  [[ -n "${CA_ROLE_ARN}" && "${CA_ROLE_ARN}" != "None" ]] \
    || die "取不到 ClusterAutoscalerRoleArn"
  ok "Pod Identity 角色: ${CA_ROLE_ARN}"

  helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null 2>&1 || true
  helm repo update autoscaler >/dev/null

  CA_ARGS=(
    --namespace kube-system
    --version "${CLUSTER_AUTOSCALER_CHART_VERSION}"
    --set "autoDiscovery.clusterName=${CLUSTER_NAME}"
    --set "awsRegion=${AWS_REGION}"
    # SA 名称必须与栈里创建的 Pod Identity 关联一致（chart 默认名带 release 前缀）
    --set rbac.serviceAccount.create=true
    --set rbac.serviceAccount.name=cluster-autoscaler
    --set extraArgs.balance-similar-node-groups=true
    --set extraArgs.skip-nodes-with-system-pods=false
    --set extraArgs.scale-down-unneeded-time=10m
    --set extraArgs.expander=least-waste
  )
  if [[ -n "${CLUSTER_AUTOSCALER_IMAGE_TAG}" ]]; then
    CA_ARGS+=(--set "image.tag=${CLUSTER_AUTOSCALER_IMAGE_TAG}")
  fi

  helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler "${CA_ARGS[@]}" \
    --wait --timeout 10m

  kubectl -n kube-system rollout status deploy/cluster-autoscaler-aws-cluster-autoscaler --timeout=300s \
    || kubectl -n kube-system get deploy | grep -i autoscaler || true
  ok "Cluster Autoscaler 就绪（通过托管节点组自动打的 k8s.io/cluster-autoscaler/* 标签发现 ASG）"
fi

# =============================================================================
section "6. 下发 nacos-config ConfigMap"
if [[ "${INSTALL_NACOS}" != "true" ]]; then
  NACOS_ADDR=""
  warn "INSTALL_NACOS=false，跳过（本次只交付 EKS）"
else
  NACOS_ADDR="$(stack_output "${STACK_NACOS}" NacosServerAddr)"
fi
if [[ -n "${NACOS_ADDR}" && "${NACOS_ADDR}" != "None" ]]; then
  kubectl create namespace app --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n app create configmap nacos-config \
    --from-literal=NACOS_SERVER_ADDR="${NACOS_ADDR}" \
    --from-literal=NACOS_NAMESPACE="public" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "namespace app 下已创建 ConfigMap/nacos-config  ->  ${NACOS_ADDR}"
  printf '  业务 Deployment 用法：envFrom: [{configMapRef: {name: nacos-config}}]\n'
  warn "Nacos 开启了鉴权，业务侧还需要用户名/口令。建议为应用单独建 Nacos 用户，"
  warn "再用 Secrets Manager + External Secrets（或 kubectl create secret）注入，不要直接用 admin 账号。"
elif [[ "${INSTALL_NACOS}" == "true" ]]; then
  warn "取不到 Nacos server-addr —— Nacos 栈还没部署成功，先跑 ./scripts/02-deploy.sh nacos"
fi

hr
ok "post-install 完成，接下来执行 ./scripts/04-verify.sh"
