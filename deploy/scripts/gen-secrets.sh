#!/usr/bin/env bash
# 生成 deploy/secrets/ 下的全部 secret 文件。已存在的文件不覆盖。
# 用法:./scripts/gen-secrets.sh [--force]
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p secrets

FORCE=0
for arg in "$@"; do
  case "$arg" in
    -f|--force) FORCE=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

gen() {
  local name="$1" gen_cmd="$2" mode="${3:-0600}"
  local path="secrets/$name"
  if [[ -s "$path" && $FORCE -eq 0 ]]; then
    echo "  keep    $path (already exists)"
    return
  fi
  bash -c "$gen_cmd" > "$path"
  chmod "$mode" "$path"
  echo "  wrote   $path"
}

echo "==> generating secrets/"

# CE-M0-7:hbbs/hbbr 管理 CLI token,32 字节 hex
gen admin_token       "openssl rand -hex 32"

# CE-M1-1:user_mfa secret 列的 AES-GCM 加密 key,32 字节 hex
gen mfa_encryption_key "openssl rand -hex 32"

# CE-M1-3:两步登录 ticket JWT 签名 key,64 字节 hex
gen jwt_signing_key   "openssl rand -hex 64"

# postgres 密码,仅在切 profiles/postgres.yml 时使用,先随手生成
gen postgres_password "openssl rand -base64 24 | tr -d '=+/' | head -c 32"

# rustdesk_key 是 hbbs 启动时自己产生的(./data/server/id_ed25519),不在此处生成。
# 但保留一个占位符文件,让 docker secret 挂载不报错(api 用到此 secret 时通过 _FILE 引用)。
if [[ ! -e secrets/rustdesk_key ]]; then
  : > secrets/rustdesk_key
  chmod 0600 secrets/rustdesk_key
  echo "  placeholder secrets/rustdesk_key (hbbs 首次启动后由 scripts/show-info.sh 填入)"
fi

echo "==> done"
ls -l secrets/
