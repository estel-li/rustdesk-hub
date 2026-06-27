#!/usr/bin/env bash
# 打印当前 CE 栈的连接信息:
#   - 客户端 Configuration String(Base64,扫码/粘贴一行搞定)
#   - Web Admin URL
#   - hbbs/hbbr 公钥指纹
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "未找到 .env,先跑 ./scripts/init.sh" >&2
  exit 1
fi

# 读取 .env(忽略注释 / 空行)
set -a
# shellcheck disable=SC1091
. ./.env
set +a

SERVER_HOST="${SERVER_HOST:-127.0.0.1}"
HBBS_TCP_PORT="${HBBS_TCP_PORT:-21116}"
HBBR_TCP_PORT="${HBBR_TCP_PORT:-21117}"
API_PORT="${API_PORT:-21114}"
PUB_KEY="${RUSTDESK_PUB_KEY:-}"

if [[ -z "$PUB_KEY" ]]; then
  echo "❌ RUSTDESK_PUB_KEY 为空,先跑 ./scripts/init.sh" >&2
  exit 1
fi

# RustDesk 客户端 Configuration String:base64( "host=...,key=...,api=..." )
# 与 rustdesk-api 下发逻辑一致
CONF_RAW="host=${SERVER_HOST}:${HBBS_TCP_PORT},key=${PUB_KEY},api=http://${SERVER_HOST}:${API_PORT}"
if command -v base64 >/dev/null; then
  CONF_B64="$(printf '%s' "$CONF_RAW" | base64 | tr -d '\n')"
else
  CONF_B64="(no base64 binary)"
fi

cat <<EOF

================================================================
  RustDesk CE 自托管栈 — 当前配置
================================================================
ID Server   : ${SERVER_HOST}:${HBBS_TCP_PORT}
Relay Server: ${SERVER_HOST}:${HBBR_TCP_PORT}
API Server  : http://${SERVER_HOST}:${API_PORT}
Public Key  : ${PUB_KEY}

Web Admin   : http://${SERVER_HOST}:${API_PORT}/_admin/
              默认账号: ${ADMIN_USERNAME:-admin} / ${ADMIN_PASSWORD:-admin}
              (首次登录后改密码!)

客户端 Configuration String(粘贴到客户端 → ID/Relay 服务器 → 导入):
${CONF_B64}

----------------------------------------------------------------
排障速查:
  docker compose ps
  docker compose logs -f hbbs
  docker compose logs -f rustdesk-api
================================================================
EOF
