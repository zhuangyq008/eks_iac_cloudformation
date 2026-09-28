#!/usr/bin/env bash
# =============================================================================
#  bg.sh —— 把长时间运行的脚本放到 tmux 里跑，扛住浏览器刷新 / 短暂断网
#
#  为什么需要：CloudShell 的终端是浏览器 WebSocket。断开时前台进程收到 SIGHUP
#  会被杀掉，`nohup` 也没用（闲置约 20-30 分钟后整个容器会被回收）。
#  tmux 把进程挂在 tmux server 上、不绑 pty，因此能扛住断网和刷新页面。
#
#  能扛住                          扛不住
#  ------------------------------  --------------------------------
#  刷新浏览器、关标签页再打开      闲置 20-30 分钟后会话被回收
#  短暂断网后重连                  连续使用超过 12 小时被强制结束
#
#  即便最坏情况被回收，CloudFormation 仍在 AWS 侧继续执行，
#  重连后重跑 ./scripts/02-deploy.sh 即可接上（脚本幂等）。
#
#  用法：
#    ./scripts/bg.sh 02-deploy.sh              # 后台跑并实时跟随输出
#    ./scripts/bg.sh 02-deploy.sh nacos        # 带参数
#    ./scripts/bg.sh --attach                  # 断线重连后回到 tmux 会话
#    ./scripts/bg.sh --log                     # 只跟随日志，不进 tmux
#    ./scripts/bg.sh --status                  # 看有没有在跑 + 栈状态
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SESSION="eks-delivery"

ensure_tmux() {
  if command -v tmux >/dev/null 2>&1; then return 0; fi
  warn "未检测到 tmux，尝试安装"
  sudo dnf install -y -q tmux >/dev/null 2>&1 || sudo yum install -y -q tmux >/dev/null 2>&1 || true
  command -v tmux >/dev/null 2>&1 || die "tmux 安装失败，请改为前台直接运行脚本"
  ok "tmux 已就绪"
}

case "${1:-}" in
  --attach)
    ensure_tmux
    tmux has-session -t "${SESSION}" 2>/dev/null \
      || die "没有名为 ${SESSION} 的 tmux 会话（可能已随 CloudShell 会话被回收）。直接重跑部署脚本即可接上。"
    log "接入 tmux 会话 ${SESSION}（脱离快捷键：Ctrl-b 然后按 d）"
    exec tmux attach -t "${SESSION}"
    ;;
  --log)
    LATEST=$(ls -t "${OUT_DIR}"/*.log 2>/dev/null | head -1)
    [[ -n "${LATEST}" ]] || die "${OUT_DIR} 下没有日志"
    log "跟随 ${LATEST}（Ctrl-C 只停止跟随，不影响后台任务）"
    exec tail -f "${LATEST}"
    ;;
  --status)
    section "tmux 会话"
    if command -v tmux >/dev/null 2>&1 && tmux has-session -t "${SESSION}" 2>/dev/null; then
      ok "会话 ${SESSION} 存在"
      tmux list-panes -t "${SESSION}" -F '  pane #{pane_index}  运行中命令: #{pane_current_command}'
    else
      warn "没有活跃的 ${SESSION} 会话"
    fi
    section "日志"
    ls -lt "${OUT_DIR}"/*.log 2>/dev/null | awk '{printf "  %s %s %s  %s\n",$6,$7,$8,$9}' || echo "  （无）"
    section "CloudFormation 栈"
    for s in "${STACK_NETWORK}" "${STACK_CLUSTER}" "${STACK_NODEGROUP}" "${STACK_ADDONS}" "${STACK_NACOS}"; do
      printf '  %-46s %s\n' "$s" "$(stack_status "$s")"
    done
    exit 0
    ;;
  ""|--help|-h)
    # 打印文件头的注释块：从第 3 行起，遇到下一条 "# ====" 分隔线即停
    awk 'NR<3 {next} /^# ={10,}/ {exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

SCRIPT="$1"; shift
[[ -x "${SCRIPT_DIR}/${SCRIPT}" ]] || die "找不到可执行脚本: ${SCRIPT_DIR}/${SCRIPT}"

ensure_tmux
LOG="${OUT_DIR}/${SCRIPT%.sh}.log"

if tmux has-session -t "${SESSION}" 2>/dev/null; then
  warn "tmux 会话 ${SESSION} 已存在"
  confirm "结束旧会话并重新开始？（选 n 则接入旧会话）" \
    && tmux kill-session -t "${SESSION}" \
    || exec tmux attach -t "${SESSION}"
fi

# ASSUME_YES=1：tmux 里没法交互确认，所以跳过确认提示
log "在 tmux 会话 ${SESSION} 里启动 ${SCRIPT} $*"
log "日志: ${LOG}"
tmux new-session -d -s "${SESSION}" \
  "cd '${ROOT_DIR}' && ASSUME_YES=1 PATH=\"\$HOME/.local/bin:\$PATH\" './scripts/${SCRIPT}' $* 2>&1 | tee '${LOG}'; echo; echo '=== 已结束，按任意键关闭 ==='; read -n1"

sleep 2
hr
cat <<EOF
  已在后台运行。常用操作：

    ./scripts/bg.sh --attach     接入 tmux 实时查看（脱离: Ctrl-b 再按 d）
    ./scripts/bg.sh --log        只跟随日志（Ctrl-C 不影响后台任务）
    ./scripts/bg.sh --status     看是否在跑 + 各栈状态

  断网/刷新后重连 CloudShell，先执行：
    cd ~/eks_delivery && export PATH="\$HOME/.local/bin:\$PATH"
    ./scripts/bg.sh --status

  若会话已被回收（闲置超时），CloudFormation 仍在 AWS 侧继续执行，
  直接重跑 ./scripts/${SCRIPT} 即可接上，不会重复创建资源。
EOF
echo
log "现在开始跟随日志（Ctrl-C 只停止跟随）"
sleep 1
exec tail -f "${LOG}"
