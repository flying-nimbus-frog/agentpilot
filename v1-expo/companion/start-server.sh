#!/bin/bash
# OpenCode 手机遥控 · 电脑侧伴侣服务
# 用法: ./start-server.sh [项目目录]
# 环境变量: PORT(默认4096), OPENCODE_BIN(opencode 可执行文件路径, 默认取 PATH)

set -euo pipefail

PORT="${PORT:-4096}"
HOST="0.0.0.0"
DIR="${1:-$PWD}"

# 生成/复用密码（存放在 ~/.config/opencode-remote/password）
PASS_DIR="$HOME/.config/opencode-remote"
mkdir -p "$PASS_DIR"
if [[ ! -f "$PASS_DIR/password" ]]; then
  echo "oc-remote-$(openssl rand -hex 8)" > "$PASS_DIR/password"
  chmod 600 "$PASS_DIR/password"
fi
PASSWORD="$(cat "$PASS_DIR/password")"

# 获取局域网 IP
IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '127.0.0.1')"

echo "============================================================"
echo " OpenCode 手机遥控伴侣服务"
echo " 手机 App 填写:"
echo "   地址: $IP"
echo "   端口: $PORT"
echo "   密码: $PASSWORD"
echo " 工作目录: $DIR"
echo " Ctrl+C 停止"
echo "============================================================"

export OPENCODE_SERVER_PASSWORD="$PASSWORD"
cd "$DIR"
exec opencode serve --hostname "$HOST" --port "$PORT"
