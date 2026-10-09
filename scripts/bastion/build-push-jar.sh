#!/usr/bin/env bash
# =============================================================================
#  build-push-jar —— 在跳板机上把 JAR 包构建成 x86 镜像并推送到 ECR
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
#    --latest            额外推送 latest tag
#    --keep-local        推送后保留本地镜像（默认删除，节省磁盘）
#
#  成功时最后输出一行：IMAGE_URI=<registry>/<prefix>/<app>:<tag>
#                     IMAGE_DIGEST=sha256:...
# =============================================================================
set -euo pipefail

ENV_FILE=/etc/bastion-build.env
[[ -r "${ENV_FILE}" ]] || { echo "FAIL 缺少 ${ENV_FILE}（跳板机未按 50-bastion.yaml 初始化）" >&2; exit 1; }
# shellcheck disable=SC1090
source "${ENV_FILE}"
export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

log()  { printf '[ %s ] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'FAIL %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR<3 {next} /^# ={10,}/ {exit} {sub(/^# ?/,""); print}' "$0"; exit "${1:-0}"; }

JAR="" APP="" TAG="$(date +%Y%m%d%H%M%S)" JAVA_VER="17" BASE_IMAGE="" PORT="8080"
JAVA_OPTS_DEFAULT="-XX:MaxRAMPercentage=75.0" DOCKERFILE="" PUSH_LATEST=0 KEEP_LOCAL=0
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
if ! unzip -p "${JAR}" META-INF/MANIFEST.MF 2>/dev/null | grep -qi '^Main-Class:'; then
  [[ -n "${DOCKERFILE}" ]] || die "${JAR} 的 MANIFEST 里没有 Main-Class，无法 java -jar 启动（Spring Boot 请用 repackage 后的 fat jar，或用 --dockerfile 自定义启动方式）"
fi

REPO="${ECR_REPO_PREFIX}/${APP}"
IMAGE="${ECR_REGISTRY}/${REPO}:${TAG}"
JAR_SIZE="$(du -h "${JAR}" | cut -f1)"
log "JAR      : ${JAR} (${JAR_SIZE})"
log "基础镜像 : ${BASE_IMAGE}"
log "目标镜像 : ${IMAGE}"

# ---------------------------------------------------------------- 磁盘
avail_gb=$(df -BG --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "${avail_gb}" ]] && (( avail_gb < 10 )); then
  log "磁盘剩余 ${avail_gb}G < 10G，清理构建缓存与未使用镜像"
  # 只清 24 小时前的：不误删并发构建正在使用的镜像 / 缓存
  docker builder prune -af --filter until=24h >/dev/null 2>&1 || true
  docker image prune -af --filter until=24h >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- 构建上下文
CTX="$(mktemp -d /tmp/build-push-jar.XXXXXX)"
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
  cat > "${CTX}/Dockerfile" <<EOF
FROM ${BASE_IMAGE}
# 非 root 运行
RUN (groupadd -g 10001 app && useradd -u 10001 -g app -M -d /app -s /sbin/nologin app) 2>/dev/null \\
 || (addgroup -g 10001 app && adduser -u 10001 -G app -D -H -h /app app)
WORKDIR /app
COPY --chown=10001:10001 app.jar /app/app.jar
ENV JAVA_OPTS="${JAVA_OPTS_DEFAULT}" TZ=Asia/Shanghai
EXPOSE ${PORT}
USER 10001
# sh -c + exec：既能展开 JAVA_OPTS，又让 java 成为 PID 1 正常接收 SIGTERM
ENTRYPOINT ["sh", "-c", "exec java \$JAVA_OPTS -jar /app/app.jar \"\$@\"", "--"]
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

# ---------------------------------------------------------------- 构建 + 推送
log "docker build（linux/amd64）"
docker build --pull --platform linux/amd64 \
  --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --label "build.jar=$(basename "${JAR}")" \
  -t "${IMAGE}" "${CTX}"

log "docker push ${IMAGE}"
docker push "${IMAGE}"
if (( PUSH_LATEST )); then
  docker tag "${IMAGE}" "${ECR_REGISTRY}/${REPO}:latest"
  docker push "${ECR_REGISTRY}/${REPO}:latest"
fi

DIGEST=$(aws ecr describe-images --repository-name "${REPO}" --image-ids "imageTag=${TAG}" \
         --query 'imageDetails[0].imageDigest' --output text)
[[ "${DIGEST}" == sha256:* ]] || die "推送后在 ECR 里查不到 ${REPO}:${TAG}"

if (( ! KEEP_LOCAL )); then
  docker image rm "${IMAGE}" >/dev/null 2>&1 || true
  (( PUSH_LATEST )) && docker image rm "${ECR_REGISTRY}/${REPO}:latest" >/dev/null 2>&1 || true
fi

log "完成"
echo "IMAGE_URI=${IMAGE}"
echo "IMAGE_DIGEST=${DIGEST}"
