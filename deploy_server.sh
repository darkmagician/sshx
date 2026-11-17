#!/usr/bin/env bash
#
# 将 dist/ 中的构建产物部署到 /opt/sshx,并重启 sshx 服务。
#
# 用法:
#   ./deploy_server.sh                 # 部署并重启服务
#   ./deploy_server.sh --no-restart    # 只复制文件,不重启
#   ./deploy_server.sh --help
#
# 环境变量:
#   DEST_DIR=/opt/sshx   目标目录
#   SERVICE=sshx         systemd 服务名
#
# 说明:
#   - 二进制与前端采用"先写临时文件、再原子替换"的方式,不会出现
#     "Text file busy" 错误,运行中的进程也不受影响;
#   - 重启后单机内存模式会丢失现有会话(客户端重新连接即可);
#   - 不会修改 /etc/sshx/sshx.env 或 systemd unit。
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$ROOT_DIR/dist"
DEST_DIR="${DEST_DIR:-/opt/sshx}"
SERVICE="${SERVICE:-sshx}"
DO_RESTART=1

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
    "${BASH_SOURCE[0]}"
}

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m错误: %s\033[0m\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --no-restart) DO_RESTART=0 ;;
    -h|--help)    usage; exit 0 ;;
    *)
      echo "错误:未知参数 $arg(使用 --help 查看用法)" >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# 检查
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || fail "需要 root 权限运行,请使用 sudo $0"

[[ -x "$SRC_DIR/sshx-server" ]] || \
  fail "缺少 $SRC_DIR/sshx-server,请先运行 ./build_server.sh"
[[ -f "$SRC_DIR/build/spa.html" ]] || \
  fail "缺少 $SRC_DIR/build/spa.html,请先运行 ./build_server.sh"

if systemctl cat "$SERVICE" >/dev/null 2>&1; then
  UNIT_DIR="$(systemctl show -p WorkingDirectory --value "$SERVICE" 2>/dev/null || true)"
  if [[ -n "$UNIT_DIR" && "$UNIT_DIR" != "$DEST_DIR" ]]; then
    printf '\033[1;33m警告: %s.service 的 WorkingDirectory 是 %s,与目标目录 %s 不一致\033[0m\n' \
      "$SERVICE" "$UNIT_DIR" "$DEST_DIR"
  fi
fi

# ---------------------------------------------------------------------------
# 复制
# ---------------------------------------------------------------------------
log "部署到 $DEST_DIR"
mkdir -p "$DEST_DIR"

# 二进制:写入临时文件后原子替换
install -m 755 "$SRC_DIR/sshx-server" "$DEST_DIR/.sshx-server.new"
mv -f "$DEST_DIR/.sshx-server.new" "$DEST_DIR/sshx-server"

# 前端:先完整复制到临时目录,再整体替换
rm -rf "$DEST_DIR/.build.new" "$DEST_DIR/.build.old"
cp -a "$SRC_DIR/build" "$DEST_DIR/.build.new"
if [[ -d "$DEST_DIR/build" ]]; then
  mv "$DEST_DIR/build" "$DEST_DIR/.build.old"
fi
mv "$DEST_DIR/.build.new" "$DEST_DIR/build"
rm -rf "$DEST_DIR/.build.old"

chown -R root:root "$DEST_DIR"

log "文件部署完成"
ls -lh "$DEST_DIR/sshx-server" "$DEST_DIR/build/spa.html"

# ---------------------------------------------------------------------------
# 重启服务
# ---------------------------------------------------------------------------
if (( DO_RESTART )); then
  if systemctl cat "$SERVICE" >/dev/null 2>&1; then
    log "重启 $SERVICE.service"
    systemctl restart "$SERVICE"
    systemctl --no-pager --full status "$SERVICE" | head -6 || true
    printf '\n查看日志:journalctl -u %s -f\n' "$SERVICE"
    printf '注意:单机内存模式下,现有会话已丢失,客户端需重新连接。\n'
  else
    log "未找到 $SERVICE.service,已跳过重启"
    printf '如需安装为系统服务,请参考 deploy_server.md 第 5 节。\n'
  fi
else
  log "已跳过重启(--no-restart)"
fi
