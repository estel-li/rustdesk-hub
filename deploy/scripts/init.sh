#!/usr/bin/env bash
# 一键初始化 + 启动 CE 栈。
#
# 分两阶段:
#   阶段 A:build + gen-secrets + 先起 hbbs/hbbr,等 hbbs 写出 id_ed25519
#   阶段 B:从 hbbs 数据目录提取公钥,回写 .env,起 rustdesk-api
#
# 用法:
#   ./scripts/init.sh                # 全流程
#   ./scripts/init.sh --skip-build   # 跳过 docker build
#   ./scripts/init.sh --recreate     # 重新生成 secrets / 强制覆盖 .env 公钥
set -euo pipefail

cd "$(dirname "$0")/.."

SKIP_BUILD=0
RECREATE=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --recreate)   RECREATE=1 ;;
    -h|--help)
      sed -n '1,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

# ---- 0. 检查依赖 ----
command -v docker >/dev/null || { echo "需要 docker"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "需要 docker compose v2"; exit 1; }
command -v openssl >/dev/null || { echo "需要 openssl"; exit 1; }

# ---- 1. 初始化 .env ----
if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "==> 写出 .env(基于 .env.example),按需编辑后再继续"
fi

# ---- 2. 生成 secrets ----
if [[ $RECREATE -eq 1 ]]; then
  ./scripts/gen-secrets.sh --force
else
  ./scripts/gen-secrets.sh
fi

# ---- 3. 构建镜像 ----
if [[ $SKIP_BUILD -eq 0 ]]; then
  ./build.sh
else
  echo "==> skip docker build"
fi

# ---- 3.5. 准备数据目录 + 修正 UID ----
# 容器内 hbbs/hbbr/api 都以 UID 1000 (rustdesk) 跑。Linux bind mount 不会
# 自动 remap UID,host 目录如果不是 1000 拥有,容器内进程写不进去
# (典型症状:"unable to open database file" / "Failed to create directory")。
# macOS docker desktop 透明 remap,这步等于 no-op。
DATA_DIR_HOST="$(grep -E '^DATA_DIR=' .env | cut -d= -f2- || true)"
DATA_DIR_HOST="${DATA_DIR_HOST:-./data}"
mkdir -p "${DATA_DIR_HOST}/server" "${DATA_DIR_HOST}/api"

if [[ "$(uname)" == "Linux" ]]; then
  CURRENT_OWNER="$(stat -c '%u' "${DATA_DIR_HOST}" 2>/dev/null || echo 0)"
  if [[ "$CURRENT_OWNER" != "1000" ]]; then
    echo "==> ${DATA_DIR_HOST}/ 当前 owner=${CURRENT_OWNER},需要 chown 到 1000:1000"
    if [[ "$(id -u)" == "0" ]]; then
      chown -R 1000:1000 "${DATA_DIR_HOST}"
    elif command -v sudo >/dev/null; then
      sudo chown -R 1000:1000 "${DATA_DIR_HOST}"
    else
      echo "❌ 需要 root 权限 chown ${DATA_DIR_HOST}/ 到 1000:1000,请手动执行:" >&2
      echo "   sudo chown -R 1000:1000 ${DATA_DIR_HOST}" >&2
      exit 1
    fi
  fi
fi

# ---- 4. 阶段 A:先起 hbbs/hbbr ----
echo "==> phase A: start hbbs + hbbr"
docker compose up -d hbbs hbbr

# 等 hbbs 写出 id_ed25519.pub(DATA_DIR_HOST 在 3.5 步已解析)
KEY_FILE="${DATA_DIR_HOST}/server/id_ed25519.pub"

echo "==> wait for $KEY_FILE"
for i in $(seq 1 30); do
  if [[ -s "$KEY_FILE" ]]; then break; fi
  sleep 1
done
if [[ ! -s "$KEY_FILE" ]]; then
  echo "❌ hbbs 启动 30s 后仍未产生 id_ed25519.pub,看 docker logs hbbs 排障" >&2
  exit 1
fi

PUB_KEY="$(tr -d '\n' < "$KEY_FILE")"
echo "==> 公钥 = $PUB_KEY"

# ---- 5. 写回 .env(RUSTDESK_PUB_KEY)----
if grep -qE '^RUSTDESK_PUB_KEY=' .env; then
  if [[ $RECREATE -eq 1 ]] || ! grep -qE "^RUSTDESK_PUB_KEY=.+" .env; then
    # sed 兼容 mac/bsd
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "s|^RUSTDESK_PUB_KEY=.*|RUSTDESK_PUB_KEY=${PUB_KEY}|" .env
    else
      sed -i "s|^RUSTDESK_PUB_KEY=.*|RUSTDESK_PUB_KEY=${PUB_KEY}|" .env
    fi
    echo "==> .env 已更新 RUSTDESK_PUB_KEY"
  else
    echo "==> .env 已有 RUSTDESK_PUB_KEY,保持不变(--recreate 可强制覆盖)"
  fi
else
  echo "RUSTDESK_PUB_KEY=${PUB_KEY}" >> .env
fi

# 同步写到 secrets/rustdesk_key,某些场景(client builder)会直接挂载读
echo -n "$PUB_KEY" > secrets/rustdesk_key
chmod 0600 secrets/rustdesk_key

# ---- 6. 阶段 B:起 api(并重启 hbbs/hbbr 让新公钥环境变量生效,不强制)----
echo "==> phase B: start rustdesk-api"
docker compose up -d rustdesk-api

echo
echo "==> 全部就绪。运行 ./scripts/show-info.sh 看连接信息"
