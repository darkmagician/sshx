#!/usr/bin/env bash
#
# 构建 sshx 服务端:Rust 后端 + SvelteKit 前端,所有产物统一输出到 ./dist。
#
# 用法:
#   ./build_server.sh                  # 完整构建
#   ./build_server.sh --skip-frontend  # 只构建 Rust 服务端
#   ./build_server.sh --skip-backend   # 只构建前端
#   ./build_server.sh --help
#
# 产物:
#   dist/sshx-server   服务端二进制
#   dist/build/        前端静态资源(必须与二进制在同一工作目录下)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$ROOT_DIR/dist"
TARGET_BIN="$ROOT_DIR/target/release/sshx-server"
START_TIME=$SECONDS

# ---------------------------------------------------------------------------
# 工具链
# ---------------------------------------------------------------------------
# 1. 确保 rustup 安装的 cargo/rustc 可用。
# 2. 确保 protoc 可用(编译 crates/sshx-core/proto/sshx.proto 时需要)。
# 3. 确保 `cc` 解析到真正的 C 编译器:本机 PATH 中可能存在名为 cc 的
#    包装脚本,它会破坏 rustc 链接和 cc-rs 原生依赖编译。因此把标准
#    系统目录放在 PATH 前部,并显式指定 CC/CXX。
for dir in "$HOME/.cargo/bin" "$HOME/.local/protoc-25.3/bin" \
           "/root/.local/protoc-25.3/bin"; do
  if [[ -d "$dir" ]]; then
    PATH="$dir:$PATH"
  fi
done
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH
export CC="${CC:-/usr/bin/gcc}"
export CXX="${CXX:-/usr/bin/g++}"
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="${CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER:-$CC}"

DO_BACKEND=1
DO_FRONTEND=1

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
    "${BASH_SOURCE[0]}"
}

for arg in "$@"; do
  case "$arg" in
    --skip-backend)  DO_BACKEND=0 ;;
    --skip-frontend) DO_FRONTEND=0 ;;
    -h|--help)       usage; exit 0 ;;
    *)
      echo "错误:未知参数 $arg(使用 --help 查看用法)" >&2
      exit 2
      ;;
  esac
done

if (( !DO_BACKEND && !DO_FRONTEND )); then
  echo "错误:--skip-backend 与 --skip-frontend 不能同时使用" >&2
  exit 2
fi

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m错误: %s\033[0m\n' "$*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || fail "找不到 $1,请先安装"
}

step_backend() {
  require cargo
  require protoc
  log "构建服务端:cargo build --release --bin sshx-server"
  cd "$ROOT_DIR"
  cargo build --release --bin sshx-server
  [[ -x "$TARGET_BIN" ]] || fail "未生成 $TARGET_BIN"
}

step_frontend() {
  require npm
  require git  # vite.config.ts 需要 git rev-parse
  log "构建前端:npm ci && npm run build"
  cd "$ROOT_DIR"
  npm ci --no-audit --no-fund
  npm run build
  [[ -f "$ROOT_DIR/build/spa.html" ]] || fail "前端产物缺少 build/spa.html"
}

step_assemble() {
  log "组装产物到 dist/"
  mkdir -p "$DIST_DIR"

  if (( DO_BACKEND )); then
    rm -f "$DIST_DIR/sshx-server"
    install -m 755 "$TARGET_BIN" "$DIST_DIR/sshx-server"
  fi

  if (( DO_FRONTEND )); then
    rm -rf "$DIST_DIR/build"
    cp -a "$ROOT_DIR/build" "$DIST_DIR/build"
  fi

  [[ -x "$DIST_DIR/sshx-server" ]] || fail "dist/sshx-server 缺失"
  if (( DO_FRONTEND )); then
    [[ -f "$DIST_DIR/build/spa.html" ]] || fail "dist/build/spa.html 缺失"
  fi
}

(( DO_BACKEND ))  && step_backend
(( DO_FRONTEND )) && step_frontend
step_assemble

log "构建完成,耗时 $((SECONDS - START_TIME))s"
cat <<EOF

产物目录:$DIST_DIR
  sshx-server    服务端二进制
  build/         前端静态资源

运行(必须在 dist 目录下启动,server 从当前工作目录读取 build/):
  cd "$DIST_DIR"
  SSHX_SECRET=<任意长随机字符串> ./sshx-server --listen 0.0.0.0 --port 8051
EOF
