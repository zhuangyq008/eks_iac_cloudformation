#!/usr/bin/env bash
# =============================================================================
#  04-verify.sh —— 端到端验收
#
#  用法：
#    ./scripts/04-verify.sh                # 基础验收（不产生额外费用）
#    ./scripts/04-verify.sh --with-storage # 额外验证 EBS CSI 动态供给（会建/删一个 1Gi 卷）
#    ./scripts/04-verify.sh --with-alb     # 额外验证 ALB Controller（会真建一个 ALB，产生费用）
#    ./scripts/04-verify.sh --all
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_cmd kubectl

WITH_STORAGE=0; WITH_ALB=0
for a in "$@"; do
  case "$a" in
    --with-storage) WITH_STORAGE=1 ;;
    --with-alb)     WITH_ALB=1 ;;
    --all)          WITH_STORAGE=1; WITH_ALB=1 ;;
    *) die "未知参数: $a" ;;
  esac
done

PASS=0; FAIL=0; WARNN=0
check()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; PASS=$((PASS+1)); else err "$1"; FAIL=$((FAIL+1)); fi; }
note()   { warn "$1"; WARNN=$((WARNN+1)); }

# =============================================================================
section "1. CloudFormation 栈状态"
# network-prereq 在客户已有可用 NAT 时本就不会创建；nacos 受 INSTALL_NACOS 控制。
# 这两个不存在属于正常情况，不算失败。
EXPECTED_STACKS=("${STACK_NETWORK}" "${STACK_CLUSTER}" "${STACK_NODEGROUP}" "${STACK_ADDONS}")
[[ "${INSTALL_NACOS}" == "true" ]] && EXPECTED_STACKS+=("${STACK_NACOS}")
for s in "${EXPECTED_STACKS[@]}"; do
  st="$(stack_status "$s")"
  case "${st}" in
    CREATE_COMPLETE|UPDATE_COMPLETE) ok "$(printf '%-46s %s' "$s" "${st}")"; PASS=$((PASS+1)) ;;
    DOES_NOT_EXIST)                  note "$(printf '%-46s %s' "$s" "${st}")" ;;
    *)                               err "$(printf '%-46s %s' "$s" "${st}")"; FAIL=$((FAIL+1)) ;;
  esac
done
if [[ "${INSTALL_NACOS}" != "true" ]]; then
  printf '  %-46s %s\n' "${STACK_NACOS}" "按 INSTALL_NACOS=false 跳过"
fi

# =============================================================================
section "2. EKS 控制面"
CL=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --output json)
py() { echo "${CL}" | python3 -c "import json,sys; c=json.load(sys.stdin)['cluster']; print($1)"; }
printf '  状态          : %s\n' "$(py 'c["status"]')"
printf '  版本          : %s (platform %s)\n' "$(py 'c["version"]')" "$(py 'c["platformVersion"]')"
printf '  端点          : %s\n' "$(py 'c["endpoint"]')"
printf '  公共端点      : %s\n' "$(py 'c["resourcesVpcConfig"]["endpointPublicAccess"]')"
printf '  私有端点      : %s\n' "$(py 'c["resourcesVpcConfig"]["endpointPrivateAccess"]')"
printf '  公网白名单    : %s\n' "$(py '",".join(c["resourcesVpcConfig"]["publicAccessCidrs"])')"
printf '  鉴权模式      : %s\n' "$(py 'c["accessConfig"]["authenticationMode"]')"
printf '  控制面日志    : %s\n' "$(py '",".join(sum([l["types"] for l in c["logging"]["clusterLogging"] if l["enabled"]],[])) or "无"')"
printf '  Secrets 加密  : %s\n' "$(py 'c.get("encryptionConfig",[{}])[0].get("provider",{}).get("keyArn","未启用")')"
printf '  Service CIDR  : %s\n' "$(py 'c["kubernetesNetworkConfig"]["serviceIpv4Cidr"]')"

check "集群状态 ACTIVE"            '[[ "$(py "c[\"status\"]")" == ACTIVE ]]'
check "公共端点已启用"              '[[ "$(py "c[\"resourcesVpcConfig\"][\"endpointPublicAccess\"]")" == True ]]'
check "私有端点已启用"              '[[ "$(py "c[\"resourcesVpcConfig\"][\"endpointPrivateAccess\"]")" == True ]]'
if [[ "$(py '",".join(c["resourcesVpcConfig"]["publicAccessCidrs"])')" == *"0.0.0.0/0"* ]]; then
  note "公共端点对 0.0.0.0/0 开放"
fi

# =============================================================================
section "3. kubeconfig 与 API Server 连通性"
# 不能假设 03-post-install.sh 已经跑过：直接跑本脚本时若没有 kubeconfig，
# kubectl 会退化到 localhost:8080，报出完全指错方向的错误。
# setup_kubeconfig 会写好 kubeconfig、验证可达性，连不上时做分类诊断。
setup_kubeconfig

section "3a. 节点与 Addon"
kubectl get nodes -o wide
READY=$(kubectl get nodes --no-headers | awk '$2=="Ready"' | wc -l | tr -d ' ')
TOTAL=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
check "节点 Ready 数 ${READY}/${TOTAL} >= ${NODE_MIN_SIZE}" "(( ${READY} >= ${NODE_MIN_SIZE} ))"

for a in eks-pod-identity-agent vpc-cni kube-proxy coredns aws-ebs-csi-driver metrics-server; do
  st=$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name "$a" \
        --query 'addon.status' --output text 2>/dev/null || echo MISSING)
  v=$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name "$a" \
        --query 'addon.addonVersion' --output text 2>/dev/null || echo -)
  if [[ "${st}" == "ACTIVE" ]]; then ok "$(printf 'addon %-24s %-8s %s' "$a" "${st}" "${v}")"; PASS=$((PASS+1));
  else err "$(printf 'addon %-24s %s' "$a" "${st}")"; FAIL=$((FAIL+1)); fi
done

section "3b. 系统 Pod"
kubectl -n kube-system get pods --no-headers \
  | awk '{printf "  %-52s %-12s restarts=%s\n", $1, $3, $4}'
BAD=$(kubectl -n kube-system get pods --no-headers | awk '$3!="Running" && $3!="Completed"' | wc -l | tr -d ' ')
check "kube-system 无异常 Pod（异常数 ${BAD}）" "(( ${BAD} == 0 ))"

section "3c. metrics-server / HPA 依赖"
check "kubectl top nodes 可用" 'kubectl top nodes'
kubectl top nodes 2>/dev/null | sed 's/^/  /' || true

section "3d. CoreDNS 解析"
check "集群内 DNS 解析 kubernetes.default" \
  'kubectl run dnstest-$$ --rm -i --restart=Never --image=public.ecr.aws/amazonlinux/amazonlinux:2023 --command -- getent hosts kubernetes.default.svc.cluster.local'

# =============================================================================
section "4. StorageClass"
kubectl get sc 2>/dev/null | sed 's/^/  /'
DEFAULTS=$(kubectl get sc -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(" ".join(i["metadata"]["name"] for i in d["items"]
      if i["metadata"].get("annotations",{}).get("storageclass.kubernetes.io/is-default-class")=="true"))')
printf '  默认 StorageClass: %s\n' "${DEFAULTS:-无}"
check "有且仅有 1 个默认 StorageClass" '[[ $(echo ${DEFAULTS} | wc -w) -eq 1 ]]'

if (( WITH_STORAGE == 1 )); then
  section "4b. EBS CSI 动态供给（建一个 1Gi gp3 卷）"
  kubectl create namespace app --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: ebs-smoke-pvc, namespace: app }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: ebs-smoke-pod, namespace: app }
spec:
  restartPolicy: Never
  containers:
    - name: t
      image: public.ecr.aws/amazonlinux/amazonlinux:2023
      command: ["/bin/bash","-c","echo ok > /data/probe && cat /data/probe && sleep 5"]
      volumeMounts: [{ name: v, mountPath: /data }]
  volumes:
    - name: v
      persistentVolumeClaim: { claimName: ebs-smoke-pvc }
EOF
  if kubectl -n app wait --for=condition=Ready pod/ebs-smoke-pod --timeout=240s >/dev/null 2>&1 \
     || kubectl -n app wait --for=jsonpath='{.status.phase}'=Succeeded pod/ebs-smoke-pod --timeout=240s >/dev/null 2>&1; then
    ok "PVC 动态供给 + 挂载成功"; PASS=$((PASS+1))
    kubectl -n app get pvc ebs-smoke-pvc | sed 's/^/  /'
  else
    err "PVC 动态供给失败"; FAIL=$((FAIL+1))
    kubectl -n app describe pvc ebs-smoke-pvc | tail -20
  fi
  kubectl -n app delete pod ebs-smoke-pod --ignore-not-found >/dev/null
  kubectl -n app delete pvc ebs-smoke-pvc --ignore-not-found >/dev/null
  ok "测试卷已清理"
fi

# =============================================================================
section "5. AWS Load Balancer Controller"
if kubectl -n kube-system get deploy aws-load-balancer-controller >/dev/null 2>&1; then
  kubectl -n kube-system get deploy aws-load-balancer-controller | sed 's/^/  /'
  check "LB Controller 副本全部就绪" \
    '[[ "$(kubectl -n kube-system get deploy aws-load-balancer-controller -o jsonpath="{.status.readyReplicas}")" == "$(kubectl -n kube-system get deploy aws-load-balancer-controller -o jsonpath="{.spec.replicas}")" ]]'
  # Pod Identity 是否真的注入了凭证。
  # 注意：不能用 `kubectl exec ... printenv` —— 控制器镜像是 distroless，没有 printenv/shell，
  # 会得到假阴性。正确做法是读 Pod spec 里被 Pod Identity webhook 注入的 env 与 token 卷。
  POD=$(kubectl -n kube-system get pod -l app.kubernetes.io/name=aws-load-balancer-controller \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -n "${POD}" ]]; then
    PI_URI=$(kubectl -n kube-system get pod "${POD}" \
      -o jsonpath='{.spec.containers[0].env[?(@.name=="AWS_CONTAINER_CREDENTIALS_FULL_URI")].value}' 2>/dev/null)
    PI_TOK=$(kubectl -n kube-system get pod "${POD}" \
      -o jsonpath='{.spec.containers[0].env[?(@.name=="AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE")].value}' 2>/dev/null)
    if [[ -n "${PI_URI}" && -n "${PI_TOK}" ]]; then
      ok "Pod Identity 凭证已注入控制器 Pod (${PI_URI})"; PASS=$((PASS+1))
    else
      err "控制器 Pod 未拿到 Pod Identity 凭证（检查 eks-pod-identity-agent 与 PodIdentityAssociation）"; FAIL=$((FAIL+1))
    fi
  fi
  echo "  近期报错日志（有则说明权限/子网标签有问题）:"
  kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=200 2>/dev/null \
    | grep -iE 'error|denied|failed' | tail -8 | sed 's/^/    /' || echo "    （无）"
else
  note "未安装 AWS Load Balancer Controller"
fi

section "5b. 子网发现标签"
for sn in ${PUBLIC_SUBNET_IDS//,/ }; do
  v=$(aws ec2 describe-subnets --subnet-ids "$sn" \
      --query 'Subnets[0].Tags[?Key==`kubernetes.io/role/elb`].Value | [0]' --output text)
  [[ "$v" == "1" ]] && { ok "公有 ${sn} role/elb=1"; PASS=$((PASS+1)); } || { err "公有 ${sn} 缺 role/elb 标签"; FAIL=$((FAIL+1)); }
done
for sn in ${PRIVATE_SUBNET_IDS//,/ }; do
  v=$(aws ec2 describe-subnets --subnet-ids "$sn" \
      --query 'Subnets[0].Tags[?Key==`kubernetes.io/role/internal-elb`].Value | [0]' --output text)
  [[ "$v" == "1" ]] && { ok "私有 ${sn} role/internal-elb=1"; PASS=$((PASS+1)); } || { err "私有 ${sn} 缺 role/internal-elb 标签"; FAIL=$((FAIL+1)); }
done

if (( WITH_ALB == 1 )); then
  section "5c. 真实 ALB 冒烟（会产生 ALB 费用）"
  kubectl create namespace app --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: { name: alb-smoke, namespace: app }
spec:
  replicas: 2
  selector: { matchLabels: { app: alb-smoke } }
  template:
    metadata: { labels: { app: alb-smoke } }
    spec:
      containers:
        - name: web
          image: public.ecr.aws/nginx/nginx:1.27
          ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata: { name: alb-smoke, namespace: app }
spec:
  selector: { app: alb-smoke }
  ports: [{ port: 80, targetPort: 80 }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: alb-smoke
  namespace: app
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: alb-smoke, port: { number: 80 } } }
EOF
  log "等待 ALB 分配地址（最长 5 分钟）"
  ALB=""
  for _ in $(seq 1 30); do
    ALB=$(kubectl -n app get ingress alb-smoke -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    [[ -n "${ALB}" ]] && break
    sleep 10
  done
  if [[ -n "${ALB}" ]]; then
    ok "ALB 已创建: ${ALB}"; PASS=$((PASS+1))
    log "等待 ALB 变为可用并回 200"
    HTTP=000
    for _ in $(seq 1 30); do
      HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://${ALB}/" || echo 000)
      [[ "${HTTP}" == "200" ]] && break
      sleep 10
    done
    check "ALB 返回 HTTP 200（实测 ${HTTP}）" "[[ ${HTTP} == 200 ]]"
  else
    err "ALB 未创建，查看控制器日志"; FAIL=$((FAIL+1))
    kubectl -n app describe ingress alb-smoke | tail -20
  fi
  log "清理 ALB 冒烟资源"
  kubectl -n app delete ingress alb-smoke --ignore-not-found >/dev/null
  kubectl -n app delete svc alb-smoke --ignore-not-found >/dev/null
  kubectl -n app delete deploy alb-smoke --ignore-not-found >/dev/null
  ok "已清理（ALB 由控制器异步删除，约 1-2 分钟）"
fi

# =============================================================================
section "6. Cluster Autoscaler"
if kubectl -n kube-system get deploy -l app.kubernetes.io/name=aws-cluster-autoscaler -o name >/dev/null 2>&1; then
  kubectl -n kube-system get deploy -l app.kubernetes.io/name=aws-cluster-autoscaler | sed 's/^/  /'
  echo "  自动发现到的节点组:"
  kubectl -n kube-system logs -l app.kubernetes.io/name=aws-cluster-autoscaler --tail=300 2>/dev/null \
    | grep -oE 'ASG [^ ]+' | sort -u | tail -5 | sed 's/^/    /' || echo "    （日志中暂无）"
  ASG=$(aws autoscaling describe-auto-scaling-groups \
    --query "AutoScalingGroups[?contains(to_string(Tags[?Key=='eks:cluster-name'].Value), '${CLUSTER_NAME}')].[AutoScalingGroupName,MinSize,DesiredCapacity,MaxSize]" \
    --output text)
  printf '  节点组 ASG: %s\n' "${ASG:-未找到}"
else
  note "未安装 Cluster Autoscaler"
fi

# =============================================================================
section "7. Nacos"
NACOS_ADDR=""
[[ "${INSTALL_NACOS}" == "true" ]] && NACOS_ADDR="$(stack_output "${STACK_NACOS}" NacosServerAddr)"
if [[ "${INSTALL_NACOS}" != "true" ]]; then
  ok "INSTALL_NACOS=false，按配置跳过 Nacos 验收（本次只交付 EKS）"
  PASS=$((PASS+1))
elif [[ -z "${NACOS_ADDR}" || "${NACOS_ADDR}" == "None" ]]; then
  err "INSTALL_NACOS=true 但 Nacos 栈未部署 —— 先跑 ./scripts/02-deploy.sh nacos"
  FAIL=$((FAIL+1))
else
  printf '  server-addr : %s\n' "${NACOS_ADDR}"
  printf '  RDS         : %s\n' "$(stack_output "${STACK_NACOS}" DbEndpoint)"

  ASG_NAME="$(stack_output "${STACK_NACOS}" AutoScalingGroupName)"
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG_NAME}" \
    --query 'AutoScalingGroups[0].Instances[].[InstanceId,LifecycleState,HealthStatus,AvailabilityZone]' \
    --output text | sed 's/^/  实例: /'

  TG_ARN="$(stack_output "${STACK_NACOS}" TargetGroupHttpArn)"
  TH=$(aws elbv2 describe-target-health --target-group-arn "${TG_ARN}" \
        --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output text)
  printf '  目标健康: %s\n' "${TH:-无目标}"
  check "Nacos NLB 目标健康" '[[ "$(aws elbv2 describe-target-health --target-group-arn "'"${TG_ARN}"'" --query "TargetHealthDescriptions[0].TargetHealth.State" --output text)" == healthy ]]'

  RDS_ID="${PROJECT}-${ENVIRONMENT}-nacos-mysql"
  RDS_ST=$(aws rds describe-db-instances --db-instance-identifier "${RDS_ID}" \
            --query 'DBInstances[0].[DBInstanceStatus,MultiAZ,StorageEncrypted,BackupRetentionPeriod]' --output text 2>/dev/null)
  printf '  RDS 状态: %s\n' "${RDS_ST}"
  check "RDS available" '[[ "$(aws rds describe-db-instances --db-instance-identifier "'"${RDS_ID}"'" --query "DBInstances[0].DBInstanceStatus" --output text)" == available ]]'

  section "7b. 从集群内做 Nacos 端到端冒烟"
  kubectl create namespace app --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n app create configmap nacos-config \
    --from-literal=NACOS_SERVER_ADDR="${NACOS_ADDR}" \
    --from-literal=NACOS_NAMESPACE=public \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  ADMIN_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "${PROJECT}/${ENVIRONMENT}/nacos/console-admin" --query SecretString --output text)
  NU=$(echo "${ADMIN_JSON}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["username"])')
  NP=$(echo "${ADMIN_JSON}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["password"])')
  kubectl -n app create secret generic nacos-smoke-secret \
    --from-literal=NACOS_USER="${NU}" --from-literal=NACOS_PASSWORD="${NP}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl -n app delete job nacos-smoke-test --ignore-not-found >/dev/null
  kubectl apply -f "${MANIFEST_DIR}/nacos-smoke-test.yaml" >/dev/null
  log "等待冒烟 Job 结束（最长 4 分钟）"
  if kubectl -n app wait --for=condition=complete job/nacos-smoke-test --timeout=240s >/dev/null 2>&1; then
    kubectl -n app logs job/nacos-smoke-test | sed 's/^/  /'
    ok "Nacos 冒烟测试全部通过"; PASS=$((PASS+1))
  else
    err "Nacos 冒烟测试未通过"; FAIL=$((FAIL+1))
    kubectl -n app logs job/nacos-smoke-test 2>/dev/null | sed 's/^/  /' || true
    kubectl -n app describe job nacos-smoke-test | tail -15
  fi
  kubectl -n app delete job nacos-smoke-test --ignore-not-found >/dev/null
  kubectl -n app delete secret nacos-smoke-secret --ignore-not-found >/dev/null

  # ---- 证明配置真的落在 RDS 里（而不是内嵌 Derby / 本地缓存）----
  # 这是"EC2 重建不丢配置"这一设计目标的关键断言，直接在 Nacos 实例上查表最直观。
  section "7c. RDS 持久化断言（直连 MySQL 查 Nacos 表）"
  NACOS_INST=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG_NAME}" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId|[0]' --output text 2>/dev/null)
  if [[ -n "${NACOS_INST}" && "${NACOS_INST}" != "None" ]]; then
    # 远端脚本用单引号 heredoc 原样写出，再由 python 转成 SSM 需要的 JSON，
    # 避免在 shell -> JSON -> 远端 shell -> SQL 四层里手工转义。
    cat > "${OUT_DIR}/nacos-rds-check.sh" <<'REMOTE_EOF'
set -uo pipefail
J=$(aws secretsmanager get-secret-value --region __REGION__ --secret-id __SECRET__ --query SecretString --output text)
export MYSQL_PWD=$(echo "$J" | jq -r .password)
U=$(echo "$J" | jq -r .username)
H=$(grep -m1 '^db.url.0' /opt/nacos/conf/application.properties | sed -E 's#.*//([^:/]+).*#\1#')
M="mysql -N -B -h $H -u $U"
echo "db_host=$H"
echo "nacos_version=$(cat /opt/nacos/INSTALLED_VERSION 2>/dev/null)"
echo "datasource_is_mysql=$(grep -c '^db.url.0=jdbc:mysql' /opt/nacos/conf/application.properties)"
echo "nacos_tables=$($M -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='nacos_config'")"
echo "users_rows=$($M -e 'SELECT COUNT(*) FROM nacos_config.users')"
echo "bootstrap_marker=$($M -e "SELECT v FROM nacos_config.nacos_bootstrap_meta WHERE k='admin_password_set'")"
echo "nacos_service_active=$(systemctl is-active nacos)"
REMOTE_EOF
    sed -i.bak -e "s#__REGION__#${AWS_REGION}#" -e "s#__SECRET__#${PROJECT}/${ENVIRONMENT}/nacos/db#" \
      "${OUT_DIR}/nacos-rds-check.sh" && rm -f "${OUT_DIR}/nacos-rds-check.sh.bak"

    SSM_PARAMS=$(python3 -c '
import json,sys
cmds = open(sys.argv[1]).read().splitlines()
print(json.dumps({"commands": cmds}))' "${OUT_DIR}/nacos-rds-check.sh")

    SSM_CMD=$(aws ssm send-command --instance-ids "${NACOS_INST}" --document-name AWS-RunShellScript \
      --comment "nacos rds persistence check" \
      --parameters "${SSM_PARAMS}" --query 'Command.CommandId' --output text 2>/dev/null)
    if [[ -n "${SSM_CMD}" ]]; then
      for _ in $(seq 1 20); do
        SSM_ST=$(aws ssm get-command-invocation --command-id "${SSM_CMD}" --instance-id "${NACOS_INST}" \
                 --query Status --output text 2>/dev/null || echo Pending)
        [[ "${SSM_ST}" == "Success" || "${SSM_ST}" == "Failed" ]] && break
        sleep 5
      done
      SSM_OUT=$(aws ssm get-command-invocation --command-id "${SSM_CMD}" --instance-id "${NACOS_INST}" \
                --query StandardOutputContent --output text 2>/dev/null)
      printf '%s\n' "${SSM_OUT}" | grep -E '=' | sed 's/^/  /'
      NTBL=$(printf  '%s\n' "${SSM_OUT}" | sed -n 's/^nacos_tables=//p'        | tr -d ' \r')
      NDS=$(printf   '%s\n' "${SSM_OUT}" | sed -n 's/^datasource_is_mysql=//p' | tr -d ' \r')
      NMARK=$(printf '%s\n' "${SSM_OUT}" | sed -n 's/^bootstrap_marker=//p'    | tr -d ' \r')
      NSVC=$(printf  '%s\n' "${SSM_OUT}" | sed -n 's/^nacos_service_active=//p'| tr -d ' \r')
      NVER=$(printf  '%s\n' "${SSM_OUT}" | sed -n 's/^nacos_version=//p'       | tr -d ' \r')
      check "Nacos schema 已建在 RDS（表数 ${NTBL:-0} > 10）"                    "(( ${NTBL:-0} > 10 ))"
      check "Nacos 数据源指向 MySQL（非内嵌 Derby）"                              "(( ${NDS:-0} == 1 ))"
      check "首次部署已覆盖默认 nacos/nacos 口令（marker=${NMARK:-none}）"        "[[ '${NMARK:-}' == '1' ]]"
      check "nacos.service 运行中（systemd 前台托管）"                            "[[ '${NSVC:-}' == 'active' ]]"
      check "安装版本与配置一致（${NVER:-?} == ${NACOS_VERSION}）"                "[[ '${NVER:-}' == '${NACOS_VERSION}' ]]"
    else
      note "SSM 命令下发失败，跳过 RDS 持久化断言"
    fi
  else
    note "取不到 Nacos 实例 ID，跳过 RDS 持久化断言"
  fi
fi

# =============================================================================
section "验收结果"
printf '  通过 %d 项 / 失败 %d 项 / 提示 %d 项\n' "${PASS}" "${FAIL}" "${WARNN}"
if (( FAIL > 0 )); then
  err "存在未通过项，请按上面输出排查"
  exit 1
fi
ok "全部验收项通过"
hr
if [[ "${INSTALL_NACOS}" != "true" ]]; then
  cat <<EOF
  本次未部署 Nacos（INSTALL_NACOS=false）。需要时执行：

    sed -i 's/^INSTALL_NACOS=.*/INSTALL_NACOS="true"/' config.env
    ./scripts/02-deploy.sh nacos
    ./scripts/03-post-install.sh
    ./scripts/04-verify.sh
EOF
  exit 0
fi
cat <<EOF
  访问 Nacos 控制台（NLB 是内网地址，从本地需要经集群做端口转发）：

    kubectl -n app run nacos-fwd --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \\
      --restart=Never --command -- sleep infinity
    # 更常用的做法是在 VPC 内的跳板机上直接访问：
    #   http://$(stack_output "${STACK_NACOS}" NlbDnsName):8848/nacos

  控制台账号口令：
    aws secretsmanager get-secret-value --region ${AWS_REGION} \\
      --secret-id ${PROJECT}/${ENVIRONMENT}/nacos/console-admin \\
      --query SecretString --output text
EOF
