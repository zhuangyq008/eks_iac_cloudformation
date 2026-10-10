#!/usr/bin/env bash
# =============================================================================
#  build-push-jar —— 在跳板机上把 JAR 包构建成多架构（amd64 + arm64）镜像并推送到 ECR
#
#  JAR 是字节码、与 CPU 架构无关：x86 跳板机一次构建即可产出 x86 与 Graviton 节点都能拉取的
#  多架构镜像（同一 tag / digest，节点按自身架构拉对应版本）。默认生成的 Dockerfile 没有 RUN，
#  构建 arm64 不需要 QEMU 模拟；自带 Dockerfile 含 RUN 时自动注册 binfmt（QEMU）。
#
#  由 ./scripts/50-bastion.sh 经 SSM 安装到跳板机 /usr/local/bin/build-push-jar，
#  Jenkins 通过 SSH（ec2-user）调用。凭证来自实例角色，Jenkins 上不需要任何 AWS 密钥。
#  ECR 地址 / 仓库前缀读取 /etc/bastion-build.env（由 CloudFormation UserData 写入）。
#
#  用法：
#    build-push-jar --jar <app.jar> --app <仓库名> [选项]
#
#  选项：
#    --jar FILE          要打包的 JAR（必填）
#    --app NAME          ECR 仓库名，自动加前缀 ${ECR_REPO_PREFIX}/（必填）
#    --tag TAG           镜像 tag，默认 时间戳（Jenkins 传 BUILD_NUMBER）
#    --java VER          基础镜像 JRE 版本：8 | 11 | 17 | 21，默认 17
#    --base-image IMG    自定义基础镜像（覆盖 --java）
#    --port PORT         EXPOSE 的端口，默认 8080
#    --java-opts OPTS    写进镜像的默认 JAVA_OPTS，默认 "-XX:MaxRAMPercentage=75.0"
#    --dockerfile FILE   使用自带的 Dockerfile（JAR 会以 app.jar 放在同一构建上下文里）
#    --platforms LIST    目标平台，默认 linux/amd64,linux/arm64；只要单架构时传 linux/amd64 或 linux/arm64
#    --latest            额外推送 latest tag
#    --keep-local        推送后把本机架构的镜像拉到本地（默认不保留，节省磁盘）
#
#  构建器：首次运行时创建 docker-container 驱动的 buildx 构建器 build-push-jar（多架构必需，
#  默认 docker 驱动不支持），之后复用。镜像默认来自 Docker Hub，访问不了时在
#  /etc/bastion-build.env 设置 BUILDKIT_IMAGE / BINFMT_IMAGE 指向内部 ECR 的副本
#  （BUILDKIT_IMAGE 只在创建构建器时生效，改了之后先 docker buildx rm build-push-jar）。
#
#  成功时最后输出一行：IMAGE_URI=<registry>/<prefix>/<app>:<tag>
#                     IMAGE_DIGEST=sha256:...
# =============================================================================
set -euo pipefail

ENV_FILE=/etc/bastion-build.env
[[ -r "${ENV_FILE}" ]] || { echo "FAIL 缺少 ${ENV_FILE}（跳板机未按 50-bastion.yaml 初始化）" >&2; exit 1; }
# 构建器 / binfmt 镜像以特权运行：只认 env 文件里的值，调用方（Jenkins ssh 命令行）的环境变量不生效
unset BUILDKIT_IMAGE BINFMT_IMAGE
# shellcheck disable=SC1090
source "${ENV_FILE}"
export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

log()  { printf '[ %s ] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'FAIL %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR<3 {next} /^# ={10,}/ {exit} {sub(/^# ?/,""); print}' "$0"; exit "${1:-0}"; }

JAR="" APP="" TAG="$(date +%Y%m%d%H%M%S)" JAVA_VER="17" BASE_IMAGE="" PORT="8080"
JAVA_OPTS_DEFAULT="-XX:MaxRAMPercentage=75.0" DOCKERFILE="" PUSH_LATEST=0 KEEP_LOCAL=0
PLATFORMS="linux/amd64,linux/arm64"
BUILDER="build-push-jar"
# 默认按 digest 固定（tag 可被覆盖，digest 不会）；在 env 文件覆盖时也建议带 @sha256:
BUILDKIT_IMAGE="${BUILDKIT_IMAGE:-moby/buildkit:v0.23.2@sha256:ddd1ca44b21eda906e81ab14a3d467fa6c39cd73b9a39df1196210edcb8db59e}"
BINFMT_IMAGE="${BINFMT_IMAGE:-tonistiigi/binfmt:qemu-v9.2.2@sha256:1b804311fe87047a4c96d38b4b3ef6f62fca8cd125265917a9e3dc3c996c39e6}"
readonly BUILDKIT_IMAGE BINFMT_IMAGE
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jar)        JAR="$2"; shift 2 ;;
    --app)        APP="$2"; shift 2 ;;
    --tag)        TAG="$2"; shift 2 ;;
    --java)       JAVA_VER="$2"; shift 2 ;;
    --base-image) BASE_IMAGE="$2"; shift 2 ;;
    --port)       PORT="$2"; shift 2 ;;
    --java-opts)  JAVA_OPTS_DEFAULT="$2"; shift 2 ;;
    --dockerfile) DOCKERFILE="$2"; shift 2 ;;
    --platforms)  PLATFORMS="$2"; shift 2 ;;
    --latest)     PUSH_LATEST=1; shift ;;
    --keep-local) KEEP_LOCAL=1; shift ;;
    -h|--help)    usage 0 ;;
    *)            echo "未知参数: $1" >&2; usage 1 ;;
  esac
done

# ---------------------------------------------------------------- 参数校验
[[ -n "${JAR}" && -n "${APP}" ]] || { echo "--jar 与 --app 必填" >&2; usage 1; }
[[ -f "${JAR}" ]] || die "JAR 不存在: ${JAR}"
# JAR 就是 zip：头 4 字节必须是 PK\x03\x04，挡住上传错文件 / 上传了 HTML 错误页的情况
[[ "$(head -c 4 "${JAR}" | od -An -tx1 | tr -d ' \n')" == "504b0304" ]] || die "${JAR} 不是合法的 JAR/zip 文件"
[[ "${APP}" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || die "--app 只能是小写字母/数字/.-_ ：${APP}"
[[ "${TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "--tag 不合法：${TAG}"
[[ "${PORT}" =~ ^[0-9]+$ ]] || die "--port 必须是数字：${PORT}"
if [[ -z "${BASE_IMAGE}" ]]; then
  case "${JAVA_VER}" in
    8|11|17|21) BASE_IMAGE="public.ecr.aws/docker/library/eclipse-temurin:${JAVA_VER}-jre" ;;
    *) die "--java 只支持 8 / 11 / 17 / 21（其他版本用 --base-image 指定）" ;;
  esac
fi
[[ -z "${DOCKERFILE}" || -f "${DOCKERFILE}" ]] || die "Dockerfile 不存在: ${DOCKERFILE}"
case "${PLATFORMS}" in
  linux/amd64|linux/arm64|linux/amd64,linux/arm64|linux/arm64,linux/amd64) ;;
  *) false ;;
esac || die "--platforms 只支持 linux/amd64、linux/arm64 或两者（逗号分隔）：${PLATFORMS}"
IMG_RE='^[a-z0-9][a-z0-9._/:@-]{0,254}$'
[[ "${BUILDKIT_IMAGE}" =~ ${IMG_RE} && "${BINFMT_IMAGE}" =~ ${IMG_RE} ]] || die "BUILDKIT_IMAGE / BINFMT_IMAGE 不合法"
# 这两项会原样写进生成的 Dockerfile：挡住换行 / 引号 / $ 等，防止注入额外指令
[[ "${BASE_IMAGE}" =~ ${IMG_RE} ]] || die "--base-image 不合法：${BASE_IMAGE}"
[[ "${JAVA_OPTS_DEFAULT}" =~ ^[A-Za-z0-9\ ._:=+%,/@-]*$ ]] || die "--java-opts 含不允许的字符（只允许字母数字与 空格 . _ : = + % , / @ -）"
if ! unzip -p "${JAR}" META-INF/MANIFEST.MF 2>/dev/null | grep -qi '^Main-Class:'; then
  [[ -n "${DOCKERFILE}" ]] || die "${JAR} 的 MANIFEST 里没有 Main-Class，无法 java -jar 启动（Spring Boot 请用 repackage 后的 fat jar，或用 --dockerfile 自定义启动方式）"
fi

REPO="${ECR_REPO_PREFIX}/${APP}"
IMAGE="${ECR_REGISTRY}/${REPO}:${TAG}"
JAR_SIZE="$(du -h "${JAR}" | cut -f1)"
log "JAR      : ${JAR} (${JAR_SIZE})"
log "基础镜像 : ${BASE_IMAGE}"
log "目标镜像 : ${IMAGE}"
log "目标平台 : ${PLATFORMS}"

# ---------------------------------------------------------------- 磁盘
avail_gb=$(df -BG --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "${avail_gb}" ]] && (( avail_gb < 10 )); then
  log "磁盘剩余 ${avail_gb}G < 10G，清理构建缓存与未使用镜像"
  # 只清 24 小时前的：不误删并发构建正在使用的镜像 / 缓存
  docker builder prune -af --filter until=24h >/dev/null 2>&1 || true
  docker buildx prune --builder "${BUILDER}" -af --filter until=24h >/dev/null 2>&1 || true
  docker image prune -af --filter until=24h >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- 构建上下文
CTX="$(mktemp -d /tmp/build-push-jar.XXXXXX)"
# buildx 构建器的元数据要持久化（否则每次都新建 buildkit 容器），必须在改 DOCKER_CONFIG 之前固定
export BUILDX_CONFIG="${BUILDX_CONFIG:-${HOME}/.docker/buildx}"
mkdir -p "${BUILDX_CONFIG}"
# docker 登录凭证只放本次构建的临时目录：并发构建互不影响，也不会留在 ~/.docker
export DOCKER_CONFIG="${CTX}/.docker"
cleanup() {
  docker logout "${ECR_REGISTRY}" >/dev/null 2>&1 || true
  rm -rf "${CTX}"
}
trap cleanup EXIT
mkdir -p "${DOCKER_CONFIG}"
# 让 buildx 插件在自定义 DOCKER_CONFIG 下也能被找到
[[ -x /usr/local/lib/docker/cli-plugins/docker-buildx ]] \
  && mkdir -p "${DOCKER_CONFIG}/cli-plugins" \
  && ln -s /usr/local/lib/docker/cli-plugins/docker-buildx "${DOCKER_CONFIG}/cli-plugins/docker-buildx"

cp "${JAR}" "${CTX}/app.jar"
if [[ -n "${DOCKERFILE}" ]]; then
  cp "${DOCKERFILE}" "${CTX}/Dockerfile"
else
  # 不写 RUN：数字 UID/GID 不需要在镜像里建用户，因此构建任意架构都不需要 QEMU 模拟
  cat > "${CTX}/Dockerfile" <<EOF
FROM ${BASE_IMAGE}
WORKDIR /app
COPY --chown=10001:10001 app.jar /app/app.jar
# 镜像里没有 UID 10001 的 passwd 条目，JVM 从 passwd 取的 user.name / user.home 会是 "?"
# （Hadoop UGI 等按用户名取身份的库会报错）：启动时显式给值，JAVA_OPTS 里再写同名 -D 可覆盖
ENV JAVA_OPTS="${JAVA_OPTS_DEFAULT}" TZ=Asia/Shanghai HOME=/tmp
EXPOSE ${PORT}
# 非 root 运行（数字形式也满足 K8s runAsNonRoot 校验）
USER 10001:10001
# sh -c + exec：既能展开 JAVA_OPTS，又让 java 成为 PID 1 正常接收 SIGTERM
ENTRYPOINT ["sh", "-c", "exec java -Duser.name=app -Duser.home=/tmp \$JAVA_OPTS -jar /app/app.jar \"\$@\"", "--"]
EOF
fi
printf '%s\n' '.docker' > "${CTX}/.dockerignore"
log "Dockerfile:"; sed 's/^/    /' "${CTX}/Dockerfile"

# ---------------------------------------------------------------- ECR
if ! aws ecr describe-repositories --repository-names "${REPO}" >/dev/null 2>&1; then
  log "ECR 仓库 ${REPO} 不存在，创建（推送时自动漏洞扫描）"
  aws ecr create-repository --repository-name "${REPO}" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 >/dev/null
fi
aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR_REGISTRY}" >/dev/null
log "docker login ${ECR_REGISTRY} 成功（实例角色 $(aws sts get-caller-identity --query Arn --output text | awk -F/ '{print $2}')）"

# ---------------------------------------------------------------- 多架构前置
native_platform() { case "$(uname -m)" in x86_64) echo linux/amd64 ;; aarch64) echo linux/arm64 ;; *) echo "linux/$(uname -m)" ;; esac; }

# 基础镜像必须包含每个目标平台，否则 buildx 报错晦涩，这里提前给出明确提示
check_base_platforms() {
  local have p
  have=$(docker buildx imagetools inspect --raw "${BASE_IMAGE}" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(" ".join(sorted({m["platform"]["os"] + "/" + m["platform"]["architecture"]
                      for m in d.get("manifests", []) if "platform" in m})))') \
    || die "无法读取基础镜像 ${BASE_IMAGE} 的清单（镜像不存在或无权限）"
  [[ -n "${have}" ]] || { [[ "${PLATFORMS}" == "$(native_platform)" ]] && return 0
                          die "基础镜像 ${BASE_IMAGE} 是单架构镜像，无法构建 ${PLATFORMS}"; }
  for p in ${PLATFORMS//,/ }; do
    [[ " ${have} " == *" ${p} "* ]] || die "基础镜像 ${BASE_IMAGE} 不含 ${p}（有：${have}）。换多架构基础镜像，或用 --platforms 只构建支持的平台"
  done
}

# Dockerfile 含 RUN 且要构建非本机架构时，RUN 需要 QEMU 执行
ensure_binfmt() {
  local p arch
  grep -qiE '^[[:space:]]*RUN[[:space:]]' "${CTX}/Dockerfile" || return 0
  for p in ${PLATFORMS//,/ }; do
    [[ "${p}" == "$(native_platform)" ]] && continue
    case "${p}" in linux/arm64) arch=aarch64 ;; linux/amd64) arch=x86_64 ;; esac
    [[ -e "/proc/sys/fs/binfmt_misc/qemu-${arch}" ]] && continue
    log "Dockerfile 含 RUN，注册 QEMU（${p##*/}）以便在本机执行目标架构的指令（重启后需重新注册，脚本会自动处理）"
    docker run --privileged --rm "${BINFMT_IMAGE}" --install "${p##*/}" >/dev/null \
      || die "注册 QEMU 失败（需要能拉取 ${BINFMT_IMAGE}）"
  done
}

# 复用 docker-container 驱动的构建器；并发构建用 flock 串行化首次创建
ensure_builder() {
  (
    # 首次创建要拉 buildkit 镜像，Docker Hub 慢时可能要几分钟
    flock -w 300 9 || die "等待构建器锁超时（另一个构建可能正在首次拉取 ${BUILDKIT_IMAGE}）"
    if ! docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
      log "创建 buildx 构建器 ${BUILDER}（docker-container 驱动，${BUILDKIT_IMAGE}）"
      docker buildx create --name "${BUILDER}" --driver docker-container \
        --driver-opt "image=${BUILDKIT_IMAGE}" >/dev/null || die "创建构建器失败（需要能拉取 ${BUILDKIT_IMAGE}）"
    fi
    # 构建器容器被删 / 机器重启后，--bootstrap 会自动拉起
    docker buildx inspect "${BUILDER}" --bootstrap >/dev/null || die "构建器 ${BUILDER} 启动失败"
  ) 9>"${BUILDX_CONFIG}/.build-push-jar.lock"
}

docker buildx version >/dev/null 2>&1 || die "缺少 docker buildx 插件（跳板机初始化时下载失败？重跑 ./scripts/50-bastion.sh）"
check_base_platforms
ensure_binfmt
ensure_builder

# ---------------------------------------------------------------- 构建 + 推送
tags=(-t "${IMAGE}")
(( PUSH_LATEST )) && tags+=(-t "${ECR_REGISTRY}/${REPO}:latest")
log "docker buildx build（${PLATFORMS}）并推送"
# provenance/sbom 关闭：否则镜像索引里多出 unknown/unknown 条目，部分扫描 / 部署工具不识别
docker buildx build --builder "${BUILDER}" --pull --platform "${PLATFORMS}" \
  --provenance=false --sbom=false \
  --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --label "build.jar=$(basename "${JAR}")" \
  --metadata-file "${CTX}/meta.json" "${tags[@]}" --push "${CTX}"

# digest 取本次推送的结果，不按 tag 回查：并发重跑同一 tag 时，按 tag 查可能拿到别人的 digest
DIGEST=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("containerimage.digest",""))' "${CTX}/meta.json")
[[ "${DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "buildx 未返回镜像 digest"
aws ecr describe-images --repository-name "${REPO}" --image-ids "imageDigest=${DIGEST}" >/dev/null \
  || die "推送后在 ECR 里查不到 ${REPO}@${DIGEST}"

# 校验推上去的镜像确实包含每个目标平台
GOT=$(docker buildx imagetools inspect --raw "${ECR_REGISTRY}/${REPO}@${DIGEST}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ms = d.get("manifests")
print(" ".join(sorted(m["platform"]["os"] + "/" + m["platform"]["architecture"] for m in ms if "platform" in m)) if ms else "single")')
if [[ "${GOT}" == "single" ]]; then
  [[ "${PLATFORMS}" != *,* ]] || die "推送结果是单架构镜像，期望 ${PLATFORMS}"
  GOT="${PLATFORMS}"
else
  for p in ${PLATFORMS//,/ }; do
    [[ " ${GOT} " == *" ${p} "* ]] || die "推送的镜像缺少 ${p}（实际：${GOT}）"
  done
fi
log "镜像平台 : ${GOT}"

if (( KEEP_LOCAL )); then
  if [[ ",${PLATFORMS}," != *",$(native_platform),"* ]]; then
    log "WARN --keep-local：镜像不含本机架构 $(native_platform)，跳过拉取"
  elif docker pull -q "${IMAGE}" >/dev/null; then
    log "已拉取本机架构镜像到本地：${IMAGE}"
  else
    log "WARN --keep-local：拉取 ${IMAGE} 失败（镜像已推送成功，不影响结果）"
  fi
fi

# 每周 cron 以 root 运行，只清默认构建器；本构建器（属于当前用户）的旧缓存在这里顺手清掉
docker buildx prune --builder "${BUILDER}" -f --filter until=168h >/dev/null 2>&1 || true

log "完成"
echo "IMAGE_URI=${IMAGE}"
echo "IMAGE_DIGEST=${DIGEST}"
echo "IMAGE_PLATFORMS=${GOT// /,}"
