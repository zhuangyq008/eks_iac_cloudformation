#!/usr/bin/env bash
# =============================================================================
#  55-arm-nodegroup.sh —— 可选扩展：Graviton（arm64）托管节点组 ng-arm64
#
#  与 x86 节点组 ng-general 并存，由 Cluster Autoscaler 一起管理（自动发现，无需改 CAS）。
#  默认带 taint arch=arm64:NoSchedule：只有声明了容忍的 Pod 才会调度上来，
#  只有 amd64 镜像的存量应用不会误落到 arm 节点（误落会 exec format error）。
#  独立于 02-deploy：不会被它创建；99-destroy 会在删集群前先删本栈。
#  配置项见 config.env 的「扩展：Graviton 节点组」段（未配置时使用下方默认值）。
#
#  用法：
#    ./scripts/55-arm-nodegroup.sh               # 部署 / 更新（幂等），结束后自动验收
#    ./scripts/55-arm-nodegroup.sh info          # 节点组 / ASG / 节点状态，以及应用接入示例
#    ./scripts/55-arm-nodegroup.sh verify        # 验收：AWS 侧配置 + 集群内冒烟（uname -m、taint 隔离）
#    ./scripts/55-arm-nodegroup.sh test-scale    # CAS 扩容测试：制造 Pending，验证 arm 节点组 +1
#    WAIT_SCALE_DOWN=1 ./scripts/55-arm-nodegroup.sh test-scale   # 同上，并等待缩回（约 10-15 分钟）
#    ./scripts/55-arm-nodegroup.sh destroy       # 删除本栈（节点上的 Pod 会被驱逐）
#
#  集群内检查需要 kubectl。ARM_KUBE_VIA 控制在哪里执行：
#    auto    本机 kubectl 能连上就用本机，否则经跳板机（50-bastion.sh）SSM 执行（默认）
#    local   只用本机    bastion  只用跳板机
#  本脚本不会自动改 API Server 白名单；本机连不上又没有跳板机时，先执行 ./scripts/allow-my-ip.sh。
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARM_NODEGROUP_NAME="${ARM_NODEGROUP_NAME:-ng-arm64}"
ARM_NODE_INSTANCE_TYPES="${ARM_NODE_INSTANCE_TYPES:-m8g.large,m7g.large}"
ARM_NODE_CAPACITY_TYPE="${ARM_NODE_CAPACITY_TYPE:-ON_DEMAND}"
ARM_NODE_DESIRED_SIZE="${ARM_NODE_DESIRED_SIZE:-1}"
ARM_NODE_MIN_SIZE="${ARM_NODE_MIN_SIZE:-0}"
ARM_NODE_MAX_SIZE="${ARM_NODE_MAX_SIZE:-4}"
ARM_NODE_VOLUME_SIZE="${ARM_NODE_VOLUME_SIZE:-${NODE_VOLUME_SIZE:-80}}"
ARM_NODE_SUBNET_IDS="${ARM_NODE_SUBNET_IDS:-}"
ARM_NODE_TAINT="${ARM_NODE_TAINT:-true}"
ARM_TAINT_KEY="${ARM_TAINT_KEY:-arch}"
ARM_TAINT_VALUE="${ARM_TAINT_VALUE:-arm64}"
ARM_KUBE_VIA="${ARM_KUBE_VIA:-auto}"
STACK_NODEGROUP_ARM="${STACK_NODEGROUP_ARM:-${PROJECT}-${ENVIRONMENT}-eks-nodegroup-arm64}"
STACK_BASTION="${STACK_BASTION:-${PROJECT}-${ENVIRONMENT}-bastion}"

TEST_NS="arm64-test"
CAS_TAG_PREFIX="k8s.io/cluster-autoscaler/node-template"

# =============================================================================
#  纯函数（tests/test-55-arm-nodegroup.sh 直接调用）
# =============================================================================
# validate_sizes <min> <desired> <max>
validate_sizes() {
  local min="$1" desired="$2" max="$3"
  [[ "${min}" =~ ^[0-9]+$ && "${desired}" =~ ^[0-9]+$ && "${max}" =~ ^[0-9]+$ ]] \
    || { err "节点数必须是非负整数：min=${min} desired=${desired} max=${max}"; return 1; }
  (( max >= 1 ))                   || { err "max 至少为 1（当前 ${max}）"; return 1; }
  (( min <= desired && desired <= max )) || { err "需要 min <= desired <= max（当前 ${min}/${desired}/${max}）"; return 1; }
}

validate_names() {
  [[ "${ARM_NODE_MAX_SIZE}" =~ ^[0-9]+$ ]]    || { err "ARM_NODE_MAX_SIZE 必须是整数"; return 1; }
  [[ "${ARM_NODE_VOLUME_SIZE}" =~ ^[0-9]+$ ]] || { err "ARM_NODE_VOLUME_SIZE 必须是整数"; return 1; }
  [[ -z "${ARM_NODE_SUBNET_IDS}" || "${ARM_NODE_SUBNET_IDS// /}" =~ ^subnet-[0-9a-f]+(,subnet-[0-9a-f]+)*$ ]] \
    || { err "ARM_NODE_SUBNET_IDS 格式不合法：${ARM_NODE_SUBNET_IDS}"; return 1; }
  [[ "${ARM_NODEGROUP_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$ ]] \
    || { err "ARM_NODEGROUP_NAME 不合法：${ARM_NODEGROUP_NAME}"; return 1; }
  [[ "${ARM_NODEGROUP_NAME}" != "${NODEGROUP_NAME}" ]] \
    || { err "ARM_NODEGROUP_NAME 不能与 x86 节点组同名（${NODEGROUP_NAME}）"; return 1; }
  [[ "${ARM_NODE_CAPACITY_TYPE}" =~ ^(ON_DEMAND|SPOT)$ ]] \
    || { err "ARM_NODE_CAPACITY_TYPE 只能是 ON_DEMAND | SPOT"; return 1; }
  [[ "${ARM_NODE_TAINT}" =~ ^(true|false)$ ]] || { err "ARM_NODE_TAINT 只能是 true | false"; return 1; }
  [[ "${ARM_TAINT_KEY}" =~ ^[A-Za-z0-9]([-A-Za-z0-9_./]*[A-Za-z0-9])?$ ]] || { err "ARM_TAINT_KEY 不合法"; return 1; }
  [[ "${ARM_TAINT_VALUE}" =~ ^[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$ ]] || { err "ARM_TAINT_VALUE 不合法"; return 1; }
  [[ "${ARM_KUBE_VIA}" =~ ^(auto|local|bastion)$ ]] || { err "ARM_KUBE_VIA 只能是 auto | local | bastion"; return 1; }
  [[ -n "${ARM_NODE_INSTANCE_TYPES//[ ,]/}" ]] || { err "ARM_NODE_INSTANCE_TYPES 不能为空"; return 1; }
  local t
  for t in ${ARM_NODE_INSTANCE_TYPES//,/ }; do
    [[ "${t}" =~ ^[a-z0-9-]+\.[a-z0-9]+$ ]] || { err "机型格式不合法：${t}"; return 1; }
  done
}

# 已存在的节点组再次部署时沿用当前 desired（夹在 [min,max]）：
# 否则 CFN 一旦下发 ScalingConfig，就会把 CAS 调整过的节点数打回模板值。
# clamp_desired <当前值|空> <配置的 desired> <min> <max>
clamp_desired() {
  local cur="$1" want="$2" min="$3" max="$4"
  [[ "${cur}" =~ ^[0-9]+$ ]] || { echo "${want}"; return; }
  (( cur < min )) && cur="${min}"
  (( cur > max )) && cur="${max}"
  echo "${cur}"
}

# CAS 从 0 扩容时没有真实节点可参考，只能按 ASG 上的 node-template 标签构造模板节点。
# 输出 "Key=Value"，一行一个；taint 关闭时不输出 taint 标签。
cas_template_tags() {
  local ng="$1" taint="$2" key="$3" value="$4"
  echo "${CAS_TAG_PREFIX}/label/eks.amazonaws.com/nodegroup=${ng}"
  echo "${CAS_TAG_PREFIX}/label/kubernetes.io/arch=arm64"
  echo "${CAS_TAG_PREFIX}/label/role=arm64"
  [[ "${taint}" == "true" ]] && echo "${CAS_TAG_PREFIX}/taint/${key}=${value}:NoSchedule"
  return 0
}

# =============================================================================
#  AWS 侧
# =============================================================================
ng_field() {
  aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "$1" \
    --query "nodegroup.$2" --output text 2>/dev/null | grep -v '^None$' || true
}
arm_asg() { ng_field "${ARM_NODEGROUP_NAME}" 'resources.autoScalingGroups[0].name'; }

require_cluster() {
  local st
  st=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query cluster.status --output text 2>/dev/null || echo MISSING)
  [[ "${st}" == "ACTIVE" ]] || die "集群 ${CLUSTER_NAME} 状态为 ${st}（需要 ACTIVE），先执行 ./scripts/02-deploy.sh"
}

require_stack() {
  local st; st="$(stack_status "${STACK_NODEGROUP_ARM}")"
  [[ "${st}" == *_COMPLETE && "${st}" != *ROLLBACK* ]] \
    || die "栈 ${STACK_NODEGROUP_ARM} 未部署成功（当前 ${st}），先执行 ./scripts/55-arm-nodegroup.sh"
}

# 留空 = 复用 x86 节点组的子网（与现有节点同一批私有子网、同一套出网路径）
resolve_subnets() {
  if [[ -n "${ARM_NODE_SUBNET_IDS}" ]]; then echo "${ARM_NODE_SUBNET_IDS// /}"; return; fi
  local s; s="$(ng_field "${NODEGROUP_NAME}" 'subnets' | tr '\t' ',')"
  [[ -n "${s}" ]] || { err "无法从节点组 ${NODEGROUP_NAME} 读取子网，请在 config.env 设置 ARM_NODE_SUBNET_IDS"; return 1; }
  echo "${s}"
}

# 每个机型都必须是 arm64，且在每个子网所在 AZ 都有供给（否则节点组创建会卡在某个 AZ）
check_instance_types() {
  local types="$1" subnets="$2" t arch azs az offered rc=0
  azs=$(aws ec2 describe-subnets --subnet-ids ${subnets//,/ } --query 'Subnets[].AvailabilityZone' --output text) \
    || { err "无法读取子网 ${subnets}"; return 1; }
  for t in ${types//,/ }; do
    arch="$(instance_type_arch "${t}" 2>/dev/null || true)"
    if [[ "${arch}" != "arm64" ]]; then
      err "机型 ${t} 的架构是 ${arch:-未知}，不是 arm64（Graviton 机型形如 m7g / m8g / c8g / r8g）"; rc=1; continue
    fi
    # --output text 多个值以 TAB 分隔，统一成空格再做整词匹配
    offered=$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
      --filters "Name=instance-type,Values=${t}" --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' ' ') \
      || { err "无法查询机型 ${t} 的 AZ 供给"; rc=1; continue; }
    for az in ${azs}; do
      [[ " ${offered} " == *" ${az} "* ]] || { err "机型 ${t} 在 ${az} 没有供给"; rc=1; }
    done
  done
  return "${rc}"
}

tag_asg_for_cas() {
  local asg; asg="$(arm_asg)"
  [[ -n "${asg}" ]] || { err "读不到节点组 ${ARM_NODEGROUP_NAME} 的 ASG"; return 1; }
  local args=() line
  while IFS= read -r line; do
    args+=("ResourceId=${asg},ResourceType=auto-scaling-group,Key=${line%%=*},Value=${line#*=},PropagateAtLaunch=false")
  done < <(cas_template_tags "${ARM_NODEGROUP_NAME}" "${ARM_NODE_TAINT}" "${ARM_TAINT_KEY}" "${ARM_TAINT_VALUE}")
  aws autoscaling create-or-update-tags --tags "${args[@]}"
  # 删掉本前缀下不再期望的旧标签（关掉 taint、改了 taint key/value 后），
  # 否则 CAS 从 0 扩容时仍按旧 taint 构造模板节点，带新容忍的 Pod 会被判定调度不上
  local want existing
  want="$(cas_template_tags "${ARM_NODEGROUP_NAME}" "${ARM_NODE_TAINT}" "${ARM_TAINT_KEY}" "${ARM_TAINT_VALUE}" | cut -d= -f1)"
  existing=$(aws autoscaling describe-tags --filters "Name=auto-scaling-group,Values=${asg}" \
    --query "Tags[?starts_with(Key,'${CAS_TAG_PREFIX}/')].Key" --output text | tr '\t' '\n')
  for line in ${existing}; do
    # 客户端再卡一次前缀：绝不能删到 k8s.io/cluster-autoscaler/enabled 这类自动发现标签
    [[ "${line}" == "${CAS_TAG_PREFIX}/"* ]] || continue
    grep -qxF "${line}" <<< "${want}" && continue
    aws autoscaling delete-tags --tags "ResourceId=${asg},ResourceType=auto-scaling-group,Key=${line}"
    log "删除过期的 CAS 模板标签 ${line}"
  done
  ok "ASG ${asg} 已打 CAS node-template 标签（支持从 0 扩容）"
}

# =============================================================================
#  集群内检查：同一段脚本在本机或跳板机上执行
# =============================================================================
# render_k8s_script <verify|scale|workloads> <输出文件>
render_k8s_script() {
  local mode="$1" file="$2"
  {
    echo '#!/usr/bin/env bash'
    printf 'MODE=%q NG=%q NS=%q TAINT=%q TKEY=%q TVAL=%q MAX=%q WAIT_DOWN=%q\n' \
      "${mode}" "${ARM_NODEGROUP_NAME}" "${TEST_NS}" "${ARM_NODE_TAINT}" \
      "${ARM_TAINT_KEY}" "${ARM_TAINT_VALUE}" "${ARM_NODE_MAX_SIZE}" "${WAIT_SCALE_DOWN:-0}"
    cat <<'EOF'
set -u
export PATH="${PATH}:/usr/local/bin"
[[ "${MAX}" =~ ^[0-9]+$ ]] || { echo "FAIL MAX 不是整数"; exit 1; }
rc=0
pass() { echo "OK   $*"; }
fail() { echo "FAIL $*"; rc=1; }
info() { echo "INFO $*"; }
SEL="eks.amazonaws.com/nodegroup=${NG}"
command -v kubectl >/dev/null || { echo "FAIL 执行环境没有 kubectl"; exit 1; }
kubectl get --raw /version --request-timeout=15s >/dev/null 2>&1 || { echo "FAIL 执行环境连不上 API Server"; exit 1; }

tolerations=""
[[ "${TAINT}" == "true" ]] && tolerations="tolerations: [{key: ${TKEY}, operator: Equal, value: ${TVAL}, effect: NoSchedule}]"
# 满足 Pod Security Admission restricted（测试 namespace 以 enforce=restricted 创建）
SEC='securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, runAsUser: 65534, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}'

node_count() { kubectl get nodes -l "${SEL}" --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' '; }
to_milli() { case "$1" in *m) echo "${1%m}" ;; *) awk -v c="$1" 'BEGIN{printf "%d", c*1000}' ;; esac; }
OWNER="app.kubernetes.io/managed-by=55-arm-nodegroup"
# 只删自己创建（带 OWNER 标签）的 namespace，同名的他人 namespace 不碰
cleanup() { [[ -n "$(kubectl get ns -l "${OWNER}" --field-selector "metadata.name=${NS}" -o name 2>/dev/null)" ]] \
            && kubectl delete ns "${NS}" --wait=false >/dev/null 2>&1; }
# 精确匹配 NODE 列（grep 子串匹配会把 ip-10-0-1-5 误配到 ip-10-0-1-50）
pods_on_ng() {
  kubectl get pods -A -o wide --no-headers 2>/dev/null \
    | awk 'NR==FNR{n[$1]=1; next} ($8 in n)' <(kubectl get nodes -l "${SEL}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') -
}
DS_RE='aws-node|kube-proxy|ebs-csi-node|eks-pod-identity|guardduty'
cas_present() { [[ -n "$(kubectl -n kube-system get deploy -l app.kubernetes.io/name=aws-cluster-autoscaler -o name 2>/dev/null)" ]]; }

# 上一轮的 namespace 可能还在 Terminating：等它删完再重建
ensure_ns() {
  local i phase
  for i in $(seq 1 60); do
    phase=$(kubectl get ns "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null)
    case "${phase}" in
      Active)
        [[ "$(kubectl get ns "${NS}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')" == "55-arm-nodegroup" ]] && return 0
        trap - EXIT; fail "namespace ${NS} 已存在且不是本脚本创建的，为避免误删已中止"; exit 1 ;;
      "")
        # create + 标签一次完成，不会留下没有归属标签的 namespace
        kubectl create -f - >/dev/null 2>&1 <<Y || true
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels: {app.kubernetes.io/managed-by: 55-arm-nodegroup, pod-security.kubernetes.io/enforce: restricted}
Y
        ;;
    esac
    sleep 5
  done
  fail "namespace ${NS} 300s 内未就绪（phase=${phase}）"; exit 1
}

# ---------------------------------------------------------------- verify
check_nodes() {
  local n node arch taints ds_bad
  n=$(node_count)
  (( n > 0 )) || { fail "节点组 ${NG} 没有 Ready 节点"; return; }
  for node in $(kubectl get nodes -l "${SEL}" -o jsonpath='{.items[*].metadata.name}'); do
    arch=$(kubectl get node "${node}" -o jsonpath='{.metadata.labels.kubernetes\.io/arch}')
    [[ "${arch}" == "arm64" ]] && pass "${node} arch=${arch}" || fail "${node} arch=${arch}（期望 arm64）"
    taints=$(kubectl get node "${node}" -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{" "}{end}')
    if [[ "${TAINT}" == "true" ]]; then
      [[ " ${taints} " == *" ${TKEY}=${TVAL}:NoSchedule "* ]] && pass "${node} taint ${TKEY}=${TVAL}:NoSchedule" \
        || fail "${node} 缺少 taint ${TKEY}=${TVAL}:NoSchedule（实际: ${taints:-无}）"
    fi
    # DaemonSet（vpc-cni / kube-proxy / ebs-csi / pod-identity …）必须都能在 arm 节点上跑起来
    local i ds
    for i in $(seq 1 24); do   # 新节点上 ebs-csi / pod-identity 等可能还在启动
      ds=$(kubectl get pods -A --field-selector "spec.nodeName=${node}" -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="DaemonSet")]}{.metadata.namespace}/{.metadata.name}={.status.phase}{"\n"}{end}') \
        || ds="kubectl=调用失败"
      ds_bad=$(grep -v '=Running$' <<< "${ds}" || true)
      [[ -n "${ds}" && -z "${ds_bad}" ]] && break; sleep 5
    done
    [[ -n "${ds}" && -z "${ds_bad}" ]] && pass "${node} DaemonSet Pod 全部 Running（$(kubectl get pods -A --field-selector "spec.nodeName=${node}" --no-headers | wc -l | tr -d ' ') 个 Pod）" \
      || fail "${node} 有 DaemonSet Pod 未 Running: ${ds_bad//$'\n'/ }"
  done
}

smoke_arch() {
  local out t0=$SECONDS
  kubectl apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: arch-smoke, namespace: ${NS}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  nodeSelector: {eks.amazonaws.com/nodegroup: ${NG}}
  ${tolerations}
  containers:
  - name: t
    image: public.ecr.aws/docker/library/busybox:1.37
    command: [sh, -c, 'echo arch=\$(uname -m)']
    resources: {requests: {cpu: 50m, memory: 32Mi}}
    ${SEC}
Y
  local phase i
  for i in $(seq 1 120); do   # wait --for 对 Failed 不会提前返回，自己轮询
    phase=$(kubectl -n "${NS}" get pod arch-smoke -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "${phase}" == Succeeded || "${phase}" == Failed ]] && break; sleep 5
  done
  if [[ "${phase}" == Succeeded ]]; then
    out=$(kubectl -n "${NS}" logs arch-smoke)
    [[ "${out}" == "arch=aarch64" ]] && pass "冒烟 Pod 在 $(kubectl -n "${NS}" get pod arch-smoke -o jsonpath='{.spec.nodeName}') 上输出 ${out}（$((SECONDS-t0))s）" \
      || fail "冒烟 Pod 输出 ${out}（期望 arch=aarch64）"
  else
    fail "冒烟 Pod 未成功（phase=${phase:-无}）：$(kubectl -n "${NS}" get pod arch-smoke -o jsonpath='{.status.phase} {.status.conditions[?(@.type=="PodScheduled")].message}')"
    kubectl -n "${NS}" get events --sort-by=.lastTimestamp 2>/dev/null | tail -5 | sed 's/^/     /'
  fi
}

# 不带容忍、但明确要求 arm64 的 Pod 必须被 taint 挡住（同时验证 CAS 不会为它扩容）
isolation() {
  local msg
  kubectl apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: no-toleration, namespace: ${NS}}
spec:
  automountServiceAccountToken: false
  nodeSelector: {kubernetes.io/arch: arm64, eks.amazonaws.com/nodegroup: ${NG}}
  containers:
  - name: t
    image: registry.k8s.io/pause:3.10
    resources: {requests: {cpu: 10m, memory: 16Mi}}
    ${SEC}
Y
  sleep 30
  msg=$(kubectl -n "${NS}" get pod no-toleration -o jsonpath='{.status.phase}|{.status.conditions[?(@.type=="PodScheduled")].message}')
  if [[ "${msg}" == Pending\|*"untolerated taint"* ]]; then
    pass "未声明容忍的 Pod 被 taint 挡住（Pending: untolerated taint）"
  else
    fail "未声明容忍的 Pod 没有被挡住：${msg}"
  fi
}

do_verify() {
  if (( $(node_count) == 0 )); then
    cas_present || { fail "节点组当前 0 个节点且集群里没有 Cluster Autoscaler，冒烟 Pod 无法触发扩容"; return; }
    info "节点组当前 0 个节点，冒烟 Pod 会触发 CAS 从 0 扩容（约 2-3 分钟）"
  fi
  smoke_arch
  check_nodes
  if [[ "${TAINT}" == "true" ]]; then isolation; else info "ARM_NODE_TAINT=false，跳过 taint 隔离测试"; fi
  info "arm 节点上的业务 Pod（非系统 DaemonSet、非本测试）：$(pods_on_ng | awk -v ns="${NS}" '$1!=ns' | grep -vcE "${DS_RE}" || true) 个"
}

# ---------------------------------------------------------------- scale
do_scale() {
  local cur target alloc per t0 n i ready
  cas_present || { fail "集群里没有 Cluster Autoscaler"; return; }
  cur=$(node_count); target=$(( cur + 1 ))
  (( target <= MAX )) || { fail "节点组已有 ${cur} 个节点，再 +1 会超过 max=${MAX}，无法测试扩容"; return; }
  # 每个 Pod 请求单节点 60% 的 CPU：一节点只放得下一个，target 个副本必然需要 cur+1 个节点
  alloc=$(kubectl get nodes -l "${SEL}" -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)
  per=$(( $(to_milli "${alloc:-1834m}") * 60 / 100 ))m
  info "当前 ${cur} 个 arm 节点，部署 ${target} 个副本（每个请求 cpu=${per}），期望扩到 ${target} 个节点"
  kubectl apply -f - >/dev/null <<Y
apiVersion: apps/v1
kind: Deployment
metadata: {name: arm64-inflate, namespace: ${NS}}
spec:
  replicas: ${target}
  selector: {matchLabels: {app: arm64-inflate}}
  template:
    metadata: {labels: {app: arm64-inflate}}
    spec:
      terminationGracePeriodSeconds: 0
      automountServiceAccountToken: false
      nodeSelector: {eks.amazonaws.com/nodegroup: ${NG}}
      ${tolerations}
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.10
        resources: {requests: {cpu: ${per}, memory: 64Mi}}
        ${SEC}
Y
  t0=$SECONDS
  for i in $(seq 1 120); do
    ready=$(kubectl -n "${NS}" get deploy arm64-inflate -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    [[ "${ready:-0}" == "${target}" ]] && break
    (( i % 6 == 0 )) && info "$((SECONDS-t0))s: ready=${ready:-0}/${target} nodes=$(node_count)"
    sleep 5
  done
  n=$(node_count)
  if [[ "${ready:-0}" == "${target}" && "${n}" -ge "${target}" ]]; then
    pass "CAS 扩容 ${cur} -> ${n} 个 arm 节点，${target} 个 Pod 全部 Running（$((SECONDS-t0))s）"
  else
    fail "600s 内未完成扩容：ready=${ready:-0}/${target} nodes=${n}"
    kubectl -n kube-system logs deploy/$(kubectl -n kube-system get deploy -l app.kubernetes.io/name=aws-cluster-autoscaler -o jsonpath='{.items[0].metadata.name}') --since=10m 2>/dev/null \
      | grep -iE "scale-up|NotTriggerScaleUp|${NG}" | tail -5 | sed 's/^/     /'
  fi
  kubectl -n "${NS}" delete deploy arm64-inflate --wait=false >/dev/null 2>&1
  if [[ "${WAIT_DOWN}" == "1" ]]; then
    info "等待 CAS 缩回 ${cur} 个节点（scale-down-unneeded-time + 扩容后冷却，通常 10-15 分钟）"
    t0=$SECONDS
    for i in $(seq 1 150); do (( $(node_count) <= cur )) && break; sleep 10; done
    (( $(node_count) <= cur )) && pass "CAS 缩容回 $(node_count) 个节点（$((SECONDS-t0))s）" \
      || fail "1500s 内未缩回：当前 $(node_count) 个节点"
  else
    info "未等待缩容（WAIT_SCALE_DOWN=1 可等待），空闲节点约 10 分钟后由 CAS 回收"
  fi
}

# ---------------------------------------------------------------- workloads
do_workloads() {
  local nodes; nodes=$(kubectl get nodes -l "${SEL}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  [[ -n "${nodes}" ]] || { info "节点组没有节点"; return; }
  pods_on_ng | grep -vE "${DS_RE}" | awk '{print "     "$1"/"$2" ("$4")"}' | grep . || info "没有业务 Pod"
}

case "${MODE}" in
  verify)    trap cleanup EXIT; ensure_ns; do_verify ;;
  scale)     trap cleanup EXIT; ensure_ns; do_scale ;;
  workloads) do_workloads ;;
esac
exit "${rc}"
EOF
  } > "${file}"
}

# 选执行位置：本机 kubectl 可达优先，其次跳板机；都不行返回 1（不自动改白名单）
kube_target() {
  if [[ "${ARM_KUBE_VIA}" != "bastion" ]] && command -v kubectl >/dev/null 2>&1 \
     && aws eks update-kubeconfig --name "${CLUSTER_NAME}" >/dev/null 2>&1 && kube_reachable; then
    echo local; return 0
  fi
  if [[ "${ARM_KUBE_VIA}" != "local" ]]; then
    local st; st="$(stack_status "${STACK_BASTION}")"
    if [[ "${st}" == *_COMPLETE && "${st}" != *ROLLBACK* && -n "$(stack_output "${STACK_BASTION}" InstanceId)" ]]; then
      echo bastion; return 0
    fi
  fi
  return 1
}

# kube_run <mode> [超时秒]
kube_run() {
  local mode="$1" timeout="${2:-900}" target tmp rc=0
  if ! target="$(kube_target)"; then
    err "本机连不上 API Server（ARM_KUBE_VIA=${ARM_KUBE_VIA}），也没有可用的跳板机栈 ${STACK_BASTION}"
    printf '  修复：./scripts/allow-my-ip.sh 把当前出口加入白名单，或 ./scripts/50-bastion.sh 部署跳板机\n'
    return 1
  fi
  tmp="$(mktemp)"; render_k8s_script "${mode}" "${tmp}"
  if [[ "${target}" == "local" ]]; then
    log "集群内检查：本机 kubectl（$(kubectl config current-context)）"
    bash "${tmp}" | sed 's/^/  /' || rc=1   # lib.sh 开了 pipefail：取到的是 bash 的退出码
  else
    log "集群内检查：经跳板机 $(stack_output "${STACK_BASTION}" InstanceId) SSM 执行（本机连不上 API Server）"
    ssm_run_script "$(stack_output "${STACK_BASTION}" InstanceId)" "${tmp}" "${timeout}" ec2-user || rc=1
  fi
  rm -f "${tmp}"
  return "${rc}"
}

# =============================================================================
#  子命令
# =============================================================================
cmd_deploy() {
  validate_sizes "${ARM_NODE_MIN_SIZE}" "${ARM_NODE_DESIRED_SIZE}" "${ARM_NODE_MAX_SIZE}" || die "配置不合法"
  require_cluster
  local subnets desired
  subnets="$(resolve_subnets)" || die "无法确定节点子网"
  log "检查机型 ${ARM_NODE_INSTANCE_TYPES} 的架构与各 AZ 供给"
  check_instance_types "${ARM_NODE_INSTANCE_TYPES}" "${subnets}" || die "机型检查未通过"
  desired="$(clamp_desired "$(ng_field "${ARM_NODEGROUP_NAME}" 'scalingConfig.desiredSize')" \
            "${ARM_NODE_DESIRED_SIZE}" "${ARM_NODE_MIN_SIZE}" "${ARM_NODE_MAX_SIZE}")"

  section "Graviton 节点组部署计划"
  cat <<EOF
  集群        : ${CLUSTER_NAME}  (${AWS_REGION})
  栈          : ${STACK_NODEGROUP_ARM}
  节点组      : ${ARM_NODEGROUP_NAME}  AL2023_ARM_64_STANDARD  ${ARM_NODE_CAPACITY_TYPE}
  机型        : ${ARM_NODE_INSTANCE_TYPES}
  节点数      : min ${ARM_NODE_MIN_SIZE} / desired ${desired} / max ${ARM_NODE_MAX_SIZE}$( [[ "${desired}" != "${ARM_NODE_DESIRED_SIZE}" ]] && echo "（沿用当前 desired，避免覆盖 CAS 的调整）" )
  子网        : ${subnets}$( [[ -z "${ARM_NODE_SUBNET_IDS}" ]] && echo "（复用 ${NODEGROUP_NAME}）" )
  调度隔离    : $( [[ "${ARM_NODE_TAINT}" == "true" ]] && echo "taint ${ARM_TAINT_KEY}=${ARM_TAINT_VALUE}:NoSchedule" || echo "无 taint（任何 Pod 都可能调度上来，确认镜像都是多架构）" )
  预计耗时    : 新建约 3-5 分钟
EOF
  confirm "开始部署？" || die "已取消"

  deploy_stack "${STACK_NODEGROUP_ARM}" "${CFN_DIR}/55-eks-nodegroup-arm64.yaml" \
    "ProjectName=${PROJECT}" \
    "EnvironmentName=${ENVIRONMENT}" \
    "ClusterName=${CLUSTER_NAME}" \
    "NodeGroupName=${ARM_NODEGROUP_NAME}" \
    "NodeSubnetIds=${subnets}" \
    "InstanceTypes=${ARM_NODE_INSTANCE_TYPES}" \
    "CapacityType=${ARM_NODE_CAPACITY_TYPE}" \
    "DesiredSize=${desired}" \
    "MinSize=${ARM_NODE_MIN_SIZE}" \
    "MaxSize=${ARM_NODE_MAX_SIZE}" \
    "VolumeSize=${ARM_NODE_VOLUME_SIZE}" \
    "EnableArchTaint=${ARM_NODE_TAINT}" \
    "TaintKey=${ARM_TAINT_KEY}" \
    "TaintValue=${ARM_TAINT_VALUE}" || die "部署失败"

  tag_asg_for_cas || die "ASG 打标签失败"
  cmd_verify
}

# chk <描述> <期望> <实际>
chk() {
  if [[ "$3" == "$2" ]]; then ok "$1: $3"; else err "$1: 期望 $2，实际 ${3:-空}"; VERIFY_FAIL=1; fi
}

cmd_verify() {
  require_stack
  VERIFY_FAIL=0
  section "Graviton 节点组验收：AWS 侧"
  local asg tags want line st
  chk "栈状态      " "COMPLETE" "$(stack_status "${STACK_NODEGROUP_ARM}" | grep -oE 'COMPLETE$' | head -1)"
  chk "节点组状态  " "ACTIVE" "$(ng_field "${ARM_NODEGROUP_NAME}" status)"
  chk "AMI 类型    " "AL2023_ARM_64_STANDARD" "$(ng_field "${ARM_NODEGROUP_NAME}" amiType)"
  chk "健康问题    " "" "$(ng_field "${ARM_NODEGROUP_NAME}" 'health.issues[].code' | tr '\t' ',')"
  want=""; [[ "${ARM_NODE_TAINT}" == "true" ]] && want="${ARM_TAINT_KEY}=${ARM_TAINT_VALUE}:NO_SCHEDULE"
  chk "节点组 taint" "${want}" "$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${ARM_NODEGROUP_NAME}" \
      --query 'nodegroup.taints[].[key,value,effect]' --output text 2>/dev/null | awk '{print $1"="$2":"$3}' | paste -sd, -)"

  asg="$(arm_asg)"
  if [[ -z "${asg}" ]]; then
    err "读不到节点组 ${ARM_NODEGROUP_NAME} 的 ASG"; VERIFY_FAIL=1
  elif tags=$(aws autoscaling describe-tags --filters "Name=auto-scaling-group,Values=${asg}" \
            --query 'Tags[].[Key,Value]' --output text 2>/dev/null); then
    chk "CAS 自动发现" "true" "$(awk -v k=k8s.io/cluster-autoscaler/enabled '$1==k{print $2}' <<< "${tags}")"
    chk "CAS 集群归属" "owned" "$(awk -v k="k8s.io/cluster-autoscaler/${CLUSTER_NAME}" '$1==k{print $2}' <<< "${tags}")"
    local key
    while IFS= read -r line; do
      key="${line%%=*}"
      chk "CAS 模板 ${key#"${CAS_TAG_PREFIX}"/}" "${line#*=}" "$(awk -v k="${key}" '$1==k{print $2}' <<< "${tags}")"
    done < <(cas_template_tags "${ARM_NODEGROUP_NAME}" "${ARM_NODE_TAINT}" "${ARM_TAINT_KEY}" "${ARM_TAINT_VALUE}")
    st=$(aws ec2 describe-instances --filters "Name=tag:aws:autoscaling:groupName,Values=${asg}" "Name=instance-state-name,Values=running" \
         --query 'Reservations[].Instances[].[InstanceType,Architecture]' --output text | sort | uniq -c | awk '{print $2"("$3")x"$1}' | paste -sd' ' -) \
      || { warn "无法查询 ASG 实例，跳过实例架构检查"; st=""; }
    ok "运行中实例  : ${st:-无（min=0 时正常，集群内冒烟会触发扩容）}"
    [[ -z "${st}" || "${st}" != *x86_64* ]] || { err "ASG 里有 x86_64 实例"; VERIFY_FAIL=1; }
  else
    warn "无权限读取 ASG ${asg} 的标签，跳过 CAS 标签检查"
  fi

  section "Graviton 节点组验收：集群内"
  kube_run verify 900 || VERIFY_FAIL=1
  (( VERIFY_FAIL == 0 )) && ok "Graviton 节点组验收全部通过" || { err "验收有失败项"; return 1; }
}

cmd_test_scale() {
  require_stack
  section "Cluster Autoscaler 扩容测试（${ARM_NODEGROUP_NAME}）"
  kube_run scale "$( [[ "${WAIT_SCALE_DOWN:-0}" == "1" ]] && echo 2400 || echo 900 )"
}

cmd_info() {
  require_stack
  local asg; asg="$(arm_asg)"
  section "Graviton 节点组 ${ARM_NODEGROUP_NAME}"
  printf '  栈          : %s (%s)\n' "${STACK_NODEGROUP_ARM}" "$(stack_status "${STACK_NODEGROUP_ARM}")"
  printf '  状态        : %s\n' "$(ng_field "${ARM_NODEGROUP_NAME}" status)"
  printf '  机型        : %s  %s\n' "$(ng_field "${ARM_NODEGROUP_NAME}" instanceTypes | tr '\t' ',')" "$(ng_field "${ARM_NODEGROUP_NAME}" capacityType)"
  printf '  min/des/max : %s\n' "$(ng_field "${ARM_NODEGROUP_NAME}" '[scalingConfig.minSize,scalingConfig.desiredSize,scalingConfig.maxSize]' | tr '\t' '/')"
  printf '  ASG         : %s\n' "${asg}"
  printf '  taint       : %s\n' "$( [[ "${ARM_NODE_TAINT}" == "true" ]] && echo "${ARM_TAINT_KEY}=${ARM_TAINT_VALUE}:NoSchedule" || echo 无 )"
  cat <<EOF

  应用接入（镜像必须包含 linux/arm64，见 docker buildx --platform linux/amd64,linux/arm64）：
    spec:
      template:
        spec:
          nodeSelector:
            kubernetes.io/arch: arm64          # 只跑 arm；两种都行时去掉，改用下面的容忍即可
$( [[ "${ARM_NODE_TAINT}" == "true" ]] && cat <<T
          tolerations:
            - { key: ${ARM_TAINT_KEY}, operator: Equal, value: ${ARM_TAINT_VALUE}, effect: NoSchedule }
T
)
EOF
}

cmd_destroy() {
  local st; st="$(stack_status "${STACK_NODEGROUP_ARM}")"
  [[ "${st}" != "DOES_NOT_EXIST" ]] || { log "栈 ${STACK_NODEGROUP_ARM} 不存在"; return 0; }
  warn "将删除 Graviton 节点组 ${ARM_NODEGROUP_NAME}：实例、启动模板、节点 IAM 角色"
  log "arm 节点上当前的业务 Pod（会被驱逐，没有 x86 可用镜像的会一直 Pending）："
  kube_run workloads 120 || warn "无法检查集群内 Pod，继续"
  confirm "确认删除？" || die "已取消"
  delete_stack "${STACK_NODEGROUP_ARM}"
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0   # 被测试 source 时只加载函数

# 所有子命令都会把这些值带进 aws 参数和集群内脚本，先统一校验
validate_names || die "config.env 的 Graviton 节点组配置不合法"

case "${1:-deploy}" in
  deploy)     cmd_deploy ;;
  info)       cmd_info ;;
  verify)     cmd_verify ;;
  test-scale) cmd_test_scale ;;
  destroy)    cmd_destroy ;;
  -h|--help)  awk 'NR<3 {next} /^# ={10,}/ {exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}" ;;
  *)          die "未知子命令: $1（见 --help）" ;;
esac
