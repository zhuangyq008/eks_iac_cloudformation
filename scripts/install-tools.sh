#!/usr/bin/env bash
# =============================================================================
#  install-tools.sh —— 在 AWS CloudShell（或任意 Linux）上装好 kubectl 与 helm
#  装到 ~/.local/bin：CloudShell 只持久化 $HOME，装到 /usr/local/bin 会话结束即丢失。
#  用法： ./scripts/install-tools.sh
#  之后： export PATH="$HOME/.local/bin:$PATH"   （脚本会写进 ~/.bashrc）
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN_DIR="${HOME}/.local/bin"
mkdir -p "${BIN_DIR}"

case "$(uname -m)" in
  x86_64)          ARCH=amd64 ;;
  aarch64|arm64)   ARCH=arm64 ;;
  *) die "不支持的架构: $(uname -m)" ;;
esac
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
log "目标平台 ${OS}/${ARCH}，安装目录 ${BIN_DIR}"

# ---------------------------------------------------------------- kubectl
if command -v kubectl >/dev/null 2>&1 && [[ "${FORCE:-0}" != "1" ]]; then
  ok "kubectl 已存在: $(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | head -1)"
else
  # kubectl 与集群版本保持同一 minor（官方支持 ±1 minor）
  KVER="$(curl -fsSL --max-time 20 "https://dl.k8s.io/release/stable-${K8S_VERSION}.txt" 2>/dev/null || true)"
  if [[ -z "${KVER}" ]]; then
    KVER="$(curl -fsSL --max-time 20 https://dl.k8s.io/release/stable.txt)"
    warn "取不到 stable-${K8S_VERSION}.txt，回退到最新稳定版 ${KVER}"
  fi
  log "下载 kubectl ${KVER}"
  curl -fsSL --max-time 180 -o "${BIN_DIR}/kubectl" \
    "https://dl.k8s.io/release/${KVER}/bin/${OS}/${ARCH}/kubectl"
  curl -fsSL --max-time 60 -o /tmp/kubectl.sha256 \
    "https://dl.k8s.io/release/${KVER}/bin/${OS}/${ARCH}/kubectl.sha256"
  echo "$(cat /tmp/kubectl.sha256)  ${BIN_DIR}/kubectl" | sha256sum -c - \
    || die "kubectl 校验和不匹配"
  chmod +x "${BIN_DIR}/kubectl"
  ok "kubectl ${KVER} 安装完成"
fi

# ---------------------------------------------------------------- helm
if command -v helm >/dev/null 2>&1 && [[ "${FORCE:-0}" != "1" ]]; then
  ok "helm 已存在: $(helm version --short 2>/dev/null)"
else
  log "下载 helm 安装脚本"
  curl -fsSL --max-time 60 -o /tmp/get_helm.sh \
    https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod +x /tmp/get_helm.sh
  HELM_INSTALL_DIR="${BIN_DIR}" USE_SUDO=false /tmp/get_helm.sh --no-sudo
  ok "helm 安装完成: $(${BIN_DIR}/helm version --short)"
fi

# ---------------------------------------------------------------- PATH
if ! grep -qs 'HOME/.local/bin' "${HOME}/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME}/.bashrc"
  ok "已把 ~/.local/bin 写入 ~/.bashrc"
fi

hr
cat <<EOF
  本次会话请先执行（或重开一个 shell）：

      export PATH="\$HOME/.local/bin:\$PATH"

  然后验证：
      kubectl version --client
      helm version --short
EOF
