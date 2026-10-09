#!/usr/bin/env bash
# =============================================================================
#  jenkins-bastion-deploy.sh —— Jenkins 调用：
#    本地编译 JAR -> SSH 上传到跳板机 -> 跳板机 build-push-jar 构建并推送 ECR
#    -> 跳板机 kubectl 发布到 EKS（滚动更新 + 冒烟，失败自动回滚到发布前版本）
#
#  Jenkins 上只需要 bash + ssh + JDK/Maven(Gradle)，不需要 docker / aws CLI / kubectl / AWS 密钥。
#  跳板机由 ./scripts/50-bastion.sh 部署，build-push-jar 与 kubectl 已就绪（见 docs/bastion-upgrade.md）。
#
#  用法：
#    Pipeline   ：见 ci/Jenkinsfile.bastion-deploy（推荐：编译阶段不绑定私钥，只在发布阶段绑定）
#    Freestyle  ：Execute shell 里  APP_NAME=order-service bash ci/jenkins-bastion-deploy.sh
#                 注意 Freestyle 的凭据绑定覆盖整个构建，编译期执行的 Maven 插件 / 单测也能读到私钥，
#                 只构建受信任的代码；不受信任的分支请用 Pipeline 并把编译与发布分开。
#
#  环境变量（Jenkins 全局变量 / Job 参数 / 脚本前 export 均可）：
#   跳板机连接
#    BASTION_HOST        跳板机公网 IP（必填，./scripts/50-bastion.sh jenkins 打印）
#    BASTION_HOST_KEY    "<ip> ssh-ed25519 AAAA..."，校验跳板机主机指纹（必填）
#    BASTION_USER        默认 ec2-user
#    SSH_KEY             私钥文件路径（必填）。Jenkins「SSH User Private Key」绑定的 Key File Variable
#    INSECURE_SKIP_HOSTKEY  true = 没有 BASTION_HOST_KEY 时也继续（不校验指纹，仅限排障）
#   编译
#    BUILD_CMD           编译命令。默认自动识别：mvnw/mvn -> package -DskipTests；gradlew/gradle -> bootJar
#    SKIP_BUILD          true = 不编译，直接用 JAR_PATH / 工作区已有 jar
#    JAR_PATH            指定 JAR（多模块工程产出多个 jar 时必填）
#   镜像
#    APP_NAME            ECR 仓库名（必填），自动加跳板机上的仓库前缀，如 sharetronic/order-service
#    IMAGE_TAG           默认 ${BUILD_NUMBER}-<git短提交号>
#    JAVA_VERSION        8 | 11 | 17 | 21，默认 17；须 >= JAR 的编译目标版本（构建前自动检查）
#    APP_PORT            容器端口，默认 8080
#    JAVA_OPTS           镜像默认 JAVA_OPTS，默认 -XX:MaxRAMPercentage=75.0
#    DOCKERFILE          自带 Dockerfile 路径；默认工作区根目录有 Dockerfile 就用它
#    PUSH_LATEST         true = 额外推 latest，默认 false
#   发布到 EKS（镜像按 digest 引用，tag 被覆盖也不影响已发布版本）
#    DEPLOY              true | false，默认 true（false = 只推镜像）
#    K8S_NAMESPACE       默认 app（不存在自动创建）；拒绝 default / kube-* 等系统命名空间
#    ALLOWED_NAMESPACES  可选，逗号分隔的命名空间白名单（建议在 Jenkins 全局变量里设置，限制 Build 用户能发布到哪）
#    K8S_DEPLOYMENT      默认 = APP_NAME
#    K8S_CONTAINER       默认 = Deployment 第一个容器
#    K8S_MANIFEST        自带 K8s YAML（工作区内的相对路径），有则 kubectl apply 它。占位符：
#                          __IMAGE_URI__ -> <仓库>:<tag>@sha256:...    __IMAGE_TAG__ -> <tag>
#    REPLICAS            无 K8S_MANIFEST 且首次创建时的副本数，默认 2
#    ROLLOUT_TIMEOUT     等待滚动完成的超时，默认 300s
#    MIN_READY_SECONDS   新 Pod 须持续就绪多少秒才算可用，默认 20（挡住"启动后几秒就崩"的版本）
#    SMOKE_PATH          发布后冒烟的 HTTP 路径，如 /actuator/health；经 API Server 代理访问 Service，
#                        不需要 Ingress / 网络放通。默认空 = 不冒烟
#    K8S_SERVICE         冒烟访问的 Service，默认 = K8S_DEPLOYMENT
#
#  产出：工作区 image.env（IMAGE_URI / IMAGE_DIGEST），可 archiveArtifacts 或给后续步骤 source
# =============================================================================
set -euo pipefail

log()  { printf '[ %s ] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'FAIL %s\n' "$*" >&2; exit 1; }
is_bool() { [[ "$1" == "true" || "$1" == "false" ]]; }

# ---------------------------------------------------------------- 参数
: "${BASTION_HOST:?未设置 BASTION_HOST（跳板机公网 IP）}"
: "${SSH_KEY:?未设置 SSH_KEY（跳板机私钥文件路径，用 Jenkins 凭据绑定注入）}"
: "${APP_NAME:?未设置 APP_NAME（ECR 仓库名 / 应用名）}"
BASTION_USER="${BASTION_USER:-ec2-user}"
BASTION_HOST_KEY="${BASTION_HOST_KEY:-}"
INSECURE_SKIP_HOSTKEY="${INSECURE_SKIP_HOSTKEY:-false}"
SKIP_BUILD="${SKIP_BUILD:-false}"
BUILD_NUMBER="${BUILD_NUMBER:-local}"
GIT_SHORT="$(git rev-parse --short=7 HEAD 2>/dev/null || true)"
IMAGE_TAG="${IMAGE_TAG:-${BUILD_NUMBER}${GIT_SHORT:+-${GIT_SHORT}}}"
JAVA_VERSION="${JAVA_VERSION:-17}"
APP_PORT="${APP_PORT:-8080}"
JAVA_OPTS="${JAVA_OPTS:--XX:MaxRAMPercentage=75.0}"
PUSH_LATEST="${PUSH_LATEST:-false}"
DEPLOY="${DEPLOY:-true}"
K8S_NAMESPACE="${K8S_NAMESPACE:-app}"
ALLOWED_NAMESPACES="${ALLOWED_NAMESPACES:-}"
K8S_DEPLOYMENT="${K8S_DEPLOYMENT:-${APP_NAME}}"
K8S_CONTAINER="${K8S_CONTAINER:-}"
K8S_MANIFEST="${K8S_MANIFEST:-}"
REPLICAS="${REPLICAS:-2}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
MIN_READY_SECONDS="${MIN_READY_SECONDS:-20}"
SMOKE_PATH="${SMOKE_PATH:-}"
K8S_SERVICE="${K8S_SERVICE:-${K8S_DEPLOYMENT}}"
DOCKERFILE="${DOCKERFILE:-}"
[[ -z "${DOCKERFILE}" && -f Dockerfile ]] && DOCKERFILE="Dockerfile"

# 全部参数白名单校验：这些值会进入 ssh 远端命令、bash 算术、Dockerfile、sed 与 kubectl
DNS_LABEL='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
[[ -r "${SSH_KEY}" ]] || die "私钥不可读: ${SSH_KEY}"
[[ "${BASTION_HOST}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "BASTION_HOST 不合法：${BASTION_HOST}"
[[ "${BASTION_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "BASTION_USER 不合法：${BASTION_USER}"
[[ "${BUILD_NUMBER}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "BUILD_NUMBER 不合法：${BUILD_NUMBER}"
[[ "${APP_NAME}" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || die "APP_NAME 只能是小写字母/数字/.-_ ：${APP_NAME}"
[[ "${IMAGE_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "IMAGE_TAG 不合法：${IMAGE_TAG}"
[[ "${JAVA_VERSION}" =~ ^(8|11|17|21)$ ]] || die "JAVA_VERSION 只支持 8 / 11 / 17 / 21：${JAVA_VERSION}"
[[ "${APP_PORT}" =~ ^[1-9][0-9]{0,4}$ ]] && (( APP_PORT <= 65535 )) || die "APP_PORT 必须是 1-65535：${APP_PORT}"
[[ "${JAVA_OPTS}" =~ ^[A-Za-z0-9_\ .:=/@,+%-]*$ ]] || die "JAVA_OPTS 含不允许的字符（引号 / 换行 / \$ 等）：${JAVA_OPTS}"
is_bool "${PUSH_LATEST}" || die "PUSH_LATEST 只能是 true / false"
is_bool "${DEPLOY}" || die "DEPLOY 只能是 true / false"
is_bool "${SKIP_BUILD}" || die "SKIP_BUILD 只能是 true / false"
is_bool "${INSECURE_SKIP_HOSTKEY}" || die "INSECURE_SKIP_HOSTKEY 只能是 true / false"
[[ "${K8S_NAMESPACE}" =~ ${DNS_LABEL} ]] || die "K8S_NAMESPACE 不合法：${K8S_NAMESPACE}"
# 跳板机是集群管理员：不允许 Build 参数把镜像发布到系统命名空间、替换系统组件
[[ "${K8S_NAMESPACE}" =~ ^(default|kube-.*|amazon-.*|aws-.*|karpenter|cert-manager)$ ]] \
  && die "不允许发布到系统命名空间：${K8S_NAMESPACE}"
[[ -z "${ALLOWED_NAMESPACES}" || ",${ALLOWED_NAMESPACES// /}," == *",${K8S_NAMESPACE},"* ]] \
  || die "K8S_NAMESPACE=${K8S_NAMESPACE} 不在 ALLOWED_NAMESPACES（${ALLOWED_NAMESPACES}）内"
[[ "${K8S_DEPLOYMENT}" =~ ${DNS_LABEL} ]] || die "K8S_DEPLOYMENT 不合法：${K8S_DEPLOYMENT}"
[[ "${K8S_SERVICE}" =~ ${DNS_LABEL} ]] || die "K8S_SERVICE 不合法：${K8S_SERVICE}"
[[ -z "${K8S_CONTAINER}" || "${K8S_CONTAINER}" =~ ${DNS_LABEL} ]] || die "K8S_CONTAINER 不合法：${K8S_CONTAINER}"
[[ "${REPLICAS}" =~ ^[0-9]+$ ]] || die "REPLICAS 必须是数字：${REPLICAS}"
[[ "${MIN_READY_SECONDS}" =~ ^[0-9]+$ ]] || die "MIN_READY_SECONDS 必须是数字：${MIN_READY_SECONDS}"
[[ "${ROLLOUT_TIMEOUT}" =~ ^[0-9]+[smh]$ ]] || die "ROLLOUT_TIMEOUT 格式如 300s / 10m：${ROLLOUT_TIMEOUT}"
# 经 API Server 代理访问：禁止 .. / // / % 编码，防止路径穿越到其他 API
[[ -z "${SMOKE_PATH}" || ( "${SMOKE_PATH}" =~ ^/[A-Za-z0-9._~/-]*(\?[A-Za-z0-9._~=\&-]*)?$ \
   && "${SMOKE_PATH}" != *..* && "${SMOKE_PATH}" != *//* ) ]] || die "SMOKE_PATH 不合法：${SMOKE_PATH}"
[[ -z "${DOCKERFILE}" || -f "${DOCKERFILE}" ]] || die "DOCKERFILE 不存在: ${DOCKERFILE}"
if [[ -n "${K8S_MANIFEST}" ]]; then
  # 只允许工作区内的普通文件：防止用参数把 agent 上的任意文件上传出去
  [[ -f "${K8S_MANIFEST}" && ! -L "${K8S_MANIFEST}" ]] || die "K8S_MANIFEST 不存在或是符号链接: ${K8S_MANIFEST}"
  [[ "$(realpath -e -- "${K8S_MANIFEST}")" == "$(pwd -P)"/* ]] || die "K8S_MANIFEST 必须在工作区内: ${K8S_MANIFEST}"
fi
[[ "${BASTION_HOST_KEY}" != *$'\n'* ]] || die "BASTION_HOST_KEY 只能是一行"
if [[ -z "${BASTION_HOST_KEY}" ]]; then
  [[ "${INSECURE_SKIP_HOSTKEY}" == "true" ]] \
    || die "未设置 BASTION_HOST_KEY（./scripts/50-bastion.sh jenkins 打印）。仅排障时可设 INSECURE_SKIP_HOSTKEY=true 跳过指纹校验"
elif [[ ",${BASTION_HOST_KEY%% *}," != *",${BASTION_HOST},"* ]]; then
  die "BASTION_HOST_KEY 的主机字段（${BASTION_HOST_KEY%% *}）与 BASTION_HOST（${BASTION_HOST}）不一致，跳板机可能已重建"
fi

# ---------------------------------------------------------------- 1. 编译
build_jar() {
  local cmd="${BUILD_CMD:-}"
  if [[ -z "${cmd}" ]]; then
    if   [[ -x ./mvnw ]];                              then cmd="./mvnw -B -ntp clean package -DskipTests"
    elif [[ -f pom.xml ]] && command -v mvn >/dev/null; then cmd="mvn -B -ntp clean package -DskipTests"
    elif [[ -x ./gradlew ]];                           then cmd="./gradlew clean bootJar -x test --no-daemon"
    elif [[ -f build.gradle || -f build.gradle.kts ]] && command -v gradle >/dev/null; then
      cmd="gradle clean bootJar -x test --no-daemon"
    else
      die "识别不到 Maven / Gradle 工程，请设置 BUILD_CMD，或 SKIP_BUILD=true + JAR_PATH"
    fi
  fi
  log "编译：${cmd}"
  bash -c "${cmd}"
}

find_jar() {
  if [[ -n "${JAR_PATH:-}" ]]; then
    [[ -f "${JAR_PATH}" ]] || die "JAR_PATH 不存在: ${JAR_PATH}"
    echo "${JAR_PATH}"; return
  fi
  local jars
  jars="$(find . -path ./.git -prune -o -type f -name '*.jar' \
            \( -path '*/target/*' -o -path '*/build/libs/*' \) \
            ! -name '*-plain.jar' ! -name '*-sources.jar' ! -name '*-javadoc.jar' \
            ! -name '*-tests.jar' ! -name 'original-*' -print)"
  [[ -n "${jars}" ]] || die "target/ 或 build/libs/ 下没有找到 jar，请设置 JAR_PATH"
  (( $(wc -l <<< "${jars}") == 1 )) || die "找到多个 jar，请用 JAR_PATH 指定：
${jars}"
  echo "${jars}"
}

[[ "${SKIP_BUILD}" == "true" ]] || build_jar
JAR="$(find_jar)"
[[ "$(head -c 4 "${JAR}" | od -An -tx1 | tr -d ' \n')" == "504b0304" ]] || die "${JAR} 不是合法的 JAR"
log "JAR：${JAR} ($(du -h "${JAR}" | cut -f1))"

# ---------------------------------------------------------------- 2. SSH 准备
SSH_DIR="$(mktemp -d)"
REMOTE_DIR="builds/${APP_NAME}-${BUILD_NUMBER}-$$"
if [[ -n "${BASTION_HOST_KEY}" ]]; then
  printf '%s\n' "${BASTION_HOST_KEY}" > "${SSH_DIR}/known_hosts"; HOST_CHECK=yes
else
  log "WARN INSECURE_SKIP_HOSTKEY=true：不校验跳板机主机指纹"
  : > "${SSH_DIR}/known_hosts"; HOST_CHECK=accept-new
fi
# -F /dev/null：不读构建机上的 ~/.ssh/config（ProxyCommand 等会改变连接行为）
SSH_OPTS=(-F /dev/null -i "${SSH_KEY}" -o IdentitiesOnly=yes -o "UserKnownHostsFile=${SSH_DIR}/known_hosts"
          -o GlobalKnownHostsFile=/dev/null -o "StrictHostKeyChecking=${HOST_CHECK}" -o BatchMode=yes
          -o PasswordAuthentication=no -o ForwardAgent=no -o ClearAllForwardings=yes
          -o ConnectTimeout=15 -o ServerAliveInterval=30 -o LogLevel=ERROR)
bssh() { ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_HOST}" "$@"; }

cleanup() {
  bssh "rm -rf ~/${REMOTE_DIR}" >/dev/null 2>&1 || true
  rm -rf "${SSH_DIR}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- 3. 上传
log "上传到 ${BASTION_USER}@${BASTION_HOST}:~/${REMOTE_DIR}"
# 700 目录：JAR / 清单 / 日志对跳板机上其他用户不可读
bssh "umask 077 && mkdir -p ~/${REMOTE_DIR}" \
  || die "SSH 连不上跳板机（检查 Jenkins 出口 IP 白名单 / 私钥 / BASTION_HOST_KEY）"
# ssh 流式上传：不依赖 scp/sftp
bssh "cat > ~/${REMOTE_DIR}/app.jar" < "${JAR}"
[[ -z "${DOCKERFILE}" ]]   || { bssh "cat > ~/${REMOTE_DIR}/Dockerfile" < "${DOCKERFILE}"; log "使用 Dockerfile：${DOCKERFILE}"; }
[[ -z "${K8S_MANIFEST}" ]] || { bssh "cat > ~/${REMOTE_DIR}/k8s.yaml"  < "${K8S_MANIFEST}"; log "使用 K8s 清单：${K8S_MANIFEST}"; }
local_sum="$(sha256sum "${JAR}" | cut -d' ' -f1)"
remote_sum="$(bssh "sha256sum ~/${REMOTE_DIR}/app.jar" | cut -d' ' -f1)"
[[ "${local_sum}" == "${remote_sum}" ]] || die "JAR 上传后校验和不一致"

# ---------------------------------------------------------------- 4. 跳板机：构建推送 + 发布
# 参数用 printf %q 转义后作为变量注入远端脚本；远端只把它们当字符串用（已在上面白名单校验）
remote_env() {
  local v
  for v in REMOTE_DIR APP_NAME IMAGE_TAG JAVA_VERSION APP_PORT JAVA_OPTS PUSH_LATEST DEPLOY \
           K8S_NAMESPACE K8S_DEPLOYMENT K8S_CONTAINER REPLICAS ROLLOUT_TIMEOUT MIN_READY_SECONDS \
           SMOKE_PATH K8S_SERVICE; do
    printf '%s=%q\n' "${v}" "${!v}"
  done
  printf 'HAS_DOCKERFILE=%q\nHAS_MANIFEST=%q\n' "${DOCKERFILE:+1}" "${K8S_MANIFEST:+1}"
}

remote_body() {
  cat <<'REMOTE'
set -euo pipefail
umask 077
cd ~/"${REMOTE_DIR}"
log() { printf '[ %s ] [bastion] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { echo "FAIL $*" >&2; exit 1; }
IMAGE_RE='^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(\.cn)?/[a-z0-9._/-]+:[A-Za-z0-9_.-]+$'

# 被 kill 掉的构建会留下临时目录，顺手清理 12 小时前的
find ~/builds -mindepth 1 -maxdepth 1 -mmin +720 -exec rm -rf {} + 2>/dev/null || true

# 字节码版本 > 镜像 JRE 时容器必然 UnsupportedClassVersionError，构建前拦下（自带 Dockerfile 时跳过）
[[ "${JAVA_VERSION}" =~ ^(8|11|17|21)$ ]] || fail "JAVA_VERSION 不合法"
if [[ -z "${HAS_DOCKERFILE}" ]]; then
  mf="$(unzip -p app.jar META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' || true)"
  cls="$(sed -n 's/^Start-Class: *//p' <<< "${mf}")"; cls_prefix="BOOT-INF/classes/"
  [[ -n "${cls}" ]] || { cls="$(sed -n 's/^Main-Class: *//p' <<< "${mf}")"; cls_prefix=""; }
  if [[ "${cls}" =~ ^[A-Za-z0-9_.$]+$ ]]; then
    # class 文件第 8 字节 = major 版本低字节；Java N 对应 44+N
    major="$(unzip -p app.jar "${cls_prefix}${cls//.//}.class" 2>/dev/null | od -An -tu1 -j7 -N1 | tr -d ' ' || true)"
    if [[ "${major}" =~ ^[0-9]+$ ]] && (( major - 44 > JAVA_VERSION )); then
      fail "${cls} 由 Java $((major - 44)) 编译，高于镜像 JRE ${JAVA_VERSION}：把 JAVA_VERSION 设为 $((major - 44))，或编译时加 --release ${JAVA_VERSION}（Maven: maven.compiler.release）"
    fi
  fi
fi

args=(--jar app.jar --app "${APP_NAME}" --tag "${IMAGE_TAG}" --java "${JAVA_VERSION}"
      --port "${APP_PORT}" --java-opts "${JAVA_OPTS}")
[[ -z "${HAS_DOCKERFILE}" ]] || args+=(--dockerfile Dockerfile)
[[ "${PUSH_LATEST}" != "true" ]] || args+=(--latest)
build-push-jar "${args[@]}" 2>&1 | tee build.log
# 只认最后一行且必须是 ECR 地址格式：构建日志里伪造的 IMAGE_URI= 行不会被采信
IMAGE_URI="$(grep '^IMAGE_URI=' build.log | tail -n1 | cut -d= -f2-)"
IMAGE_DIGEST="$(grep '^IMAGE_DIGEST=' build.log | tail -n1 | cut -d= -f2-)"
[[ "${IMAGE_URI}" =~ ${IMAGE_RE} ]] || fail "build-push-jar 输出的 IMAGE_URI 不合法：${IMAGE_URI}"
[[ "${IMAGE_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "build-push-jar 输出的 IMAGE_DIGEST 不合法：${IMAGE_DIGEST}"
# 按 digest 发布：tag 之后被覆盖也不会改变已发布的版本
IMAGE_REF="${IMAGE_URI}@${IMAGE_DIGEST}"

[[ "${DEPLOY}" == "true" ]] || { log "DEPLOY=false，跳过发布"; exit 0; }

NS="${K8S_NAMESPACE}" DEP="${K8S_DEPLOYMENT}"
# 同一 Deployment 串行发布：避免并发构建互相回滚
# 锁文件放在自己的 700 目录：/tmp 下的可预测路径可被其他用户预置符号链接
mkdir -p -m 700 ~/.locks
exec 9> ~/.locks/"jenkins-deploy-${NS}-${DEP}.lock"
flock -w 900 9 || fail "等待 ${NS}/${DEP} 的发布锁超时（另一个构建正在发布）"

kubectl get namespace "${NS}" >/dev/null 2>&1 || kubectl create namespace "${NS}"
# 记录发布前的 revision，失败时精确回滚到它（而不是"上一个"）
PREV_REV="$(kubectl -n "${NS}" get deployment "${DEP}" \
            -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null || true)"

rollback_and_fail() {
  log "$1，现场信息："
  kubectl -n "${NS}" get pods -l "app=${DEP}" -o wide || true
  kubectl -n "${NS}" get events --sort-by=.lastTimestamp | tail -20 || true
  if [[ "${PREV_REV}" =~ ^[0-9]+$ ]]; then
    log "自动回滚到发布前版本（revision ${PREV_REV}）"
    kubectl -n "${NS}" rollout undo "deployment/${DEP}" --to-revision="${PREV_REV}"
    kubectl -n "${NS}" rollout status "deployment/${DEP}" --timeout="${ROLLOUT_TIMEOUT}" || true
  fi
  fail "发布失败：${NS}/${DEP}"
}

if [[ -n "${HAS_MANIFEST}" ]]; then
  log "kubectl apply 自带清单（__IMAGE_URI__ -> ${IMAGE_REF}）"
  sed -e "s#__IMAGE_URI__#${IMAGE_REF}#g" -e "s#__IMAGE_TAG__#${IMAGE_TAG}#g" k8s.yaml > k8s.rendered.yaml
  kubectl -n "${NS}" apply -f k8s.rendered.yaml
elif [[ -z "${PREV_REV}" ]]; then
  log "首次发布：创建 Deployment ${NS}/${DEP}（${REPLICAS} 副本）+ Service :80 -> :${APP_PORT}"
  # 没有就绪探针时容器一启动就算 Ready，崩溃的版本也会被判成功：注入 TCP 就绪探针 + minReadySeconds
  kubectl -n "${NS}" create deployment "${DEP}" --image="${IMAGE_REF}" \
    --port="${APP_PORT}" --replicas="${REPLICAS}" --dry-run=client -o json \
  | jq --argjson port "${APP_PORT}" --argjson mrs "${MIN_READY_SECONDS}" '
      .spec.minReadySeconds = $mrs
      | .spec.template.spec.containers[0].readinessProbe =
          {tcpSocket: {port: $port}, initialDelaySeconds: 5, periodSeconds: 5, failureThreshold: 3}' \
  | kubectl -n "${NS}" apply -f -
  kubectl -n "${NS}" expose deployment "${DEP}" --port=80 --target-port="${APP_PORT}" \
    --dry-run=client -o yaml | kubectl -n "${NS}" apply -f -
else
  CONTAINER="${K8S_CONTAINER:-$(kubectl -n "${NS}" get deployment "${DEP}" -o jsonpath='{.spec.template.spec.containers[0].name}')}"
  log "滚动更新 ${NS}/${DEP} 容器 ${CONTAINER} -> ${IMAGE_REF}"
  # 已有 Deployment 没设 minReadySeconds 时补上；客户自己设过的不动
  if [[ "$(kubectl -n "${NS}" get deployment "${DEP}" -o jsonpath='{.spec.minReadySeconds}')" =~ ^0?$ ]]; then
    kubectl -n "${NS}" patch deployment "${DEP}" -p "{\"spec\":{\"minReadySeconds\":${MIN_READY_SECONDS}}}" >/dev/null
  fi
  kubectl -n "${NS}" set image "deployment/${DEP}" "${CONTAINER}=${IMAGE_REF}"
fi
kubectl -n "${NS}" annotate deployment "${DEP}" --overwrite \
  kubernetes.io/change-cause="jenkins ${IMAGE_URI}" >/dev/null

kubectl -n "${NS}" rollout status "deployment/${DEP}" --timeout="${ROLLOUT_TIMEOUT}" || rollback_and_fail "滚动失败"
kubectl -n "${NS}" get deployment "${DEP}" -o wide

if [[ -n "${SMOKE_PATH}" ]]; then
  port="$(kubectl -n "${NS}" get service "${K8S_SERVICE}" -o jsonpath='{.spec.ports[0].port}')"
  url="/api/v1/namespaces/${NS}/services/http:${K8S_SERVICE}:${port}/proxy${SMOKE_PATH}"
  log "冒烟：GET svc/${K8S_SERVICE}:${port}${SMOKE_PATH}"
  smoke_ok=0
  for _ in 1 2 3 4 5 6; do
    if body="$(kubectl get --raw "${url}" 2>&1)"; then smoke_ok=1; break; fi
    sleep 5
  done
  (( smoke_ok )) || { log "冒烟响应：${body:0:500}"; rollback_and_fail "冒烟失败"; }
  log "冒烟通过：${body:0:300}"
fi
log "发布成功：${NS}/${DEP} -> ${IMAGE_REF}"
REMOTE
}

log "跳板机构建镜像并推送 ECR（DEPLOY=${DEPLOY}）"
# 远端脚本先落盘再执行：bash -s 从 stdin 读脚本时，子进程若读 stdin 会把后续脚本吃掉
{ remote_env; remote_body; } | bssh "cat > ~/${REMOTE_DIR}/deploy.sh"
bssh "bash ~/${REMOTE_DIR}/deploy.sh" < /dev/null | tee build-push.log

# ---------------------------------------------------------------- 5. 产出
IMAGE_URI="$(grep '^IMAGE_URI=' build-push.log | tail -n1 | cut -d= -f2-)"
IMAGE_DIGEST="$(grep '^IMAGE_DIGEST=' build-push.log | tail -n1 | cut -d= -f2-)"
[[ "${IMAGE_URI}" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(\.cn)?/[a-z0-9._/-]+:[A-Za-z0-9_.-]+$ ]] \
  || die "没有拿到合法的镜像地址：${IMAGE_URI}"
[[ "${IMAGE_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "没有拿到合法的镜像 digest：${IMAGE_DIGEST}"
printf 'IMAGE_URI=%s\nIMAGE_DIGEST=%s\n' "${IMAGE_URI}" "${IMAGE_DIGEST}" > image.env
log "完成：${IMAGE_URI}@${IMAGE_DIGEST}"
