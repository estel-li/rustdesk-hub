#!/usr/bin/env bash
# 本地 buildx 构建 hbbs / hbbr / rustdesk-api 三个 CE 镜像。
#
# Dockerfile 真源在各 sub-repo 的 deploy/Dockerfile 里(就近原则,跟着代码走 CI);
# 这个脚本只是本地开发用的薄壳,跟 GHCR workflow 完全等价的输入。
#
# 用法:
#   ./build.sh                # 全部构建(hbbs / hbbr / api)
#   ./build.sh hbbs hbbr      # 只构建指定 target
#   IMAGE_TAG=v0.1.0 ./build.sh
#
# 想推送到 registry(可选):REGISTRY=ghcr.io/myorg ./build.sh
# 直接拉 GHCR 镜像跑(不本地 build):
#   IMAGE_NS=ghcr.io/estel-li/rustdesk-ce IMAGE_TAG=edge docker compose pull
set -euo pipefail

cd "$(dirname "$0")"
DEPLOY_DIR="$(pwd)"
REPO_ROOT="$(cd .. && pwd)"

IMAGE_NS="${IMAGE_NS:-rustdesk-ce}"
IMAGE_TAG="${IMAGE_TAG:-dev}"
REGISTRY="${REGISTRY:-}"
PUSH="${PUSH:-0}"

prefix() {
  if [[ -n "$REGISTRY" ]]; then echo "$REGISTRY/$IMAGE_NS"; else echo "$IMAGE_NS"; fi
}
NS="$(prefix)"

# 默认 amd64;CI 跨架构改成 "linux/amd64,linux/arm64"
PLATFORM="${PLATFORM:-linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"

SERVER_DOCKERFILE="$REPO_ROOT/rustdesk-server/deploy/Dockerfile"
API_DOCKERFILE="$REPO_ROOT/rustdesk-api/deploy/Dockerfile"

require_file() {
  local path="$1" hint="$2"
  if [[ ! -f "$path" ]]; then
    echo "error: $path not found." >&2
    echo "       $hint" >&2
    exit 1
  fi
}

build_server_target() {
  local target="$1"
  require_file "$SERVER_DOCKERFILE" "rustdesk-server/deploy/Dockerfile 缺失,checkout estel-li/rustdesk-server@master。"
  echo "==> building $NS/$target:$IMAGE_TAG (platform=$PLATFORM, ctx=rustdesk-server/)"
  local buildx_args=(
    --file "$SERVER_DOCKERFILE"
    --target "$target"
    --tag "$NS/$target:$IMAGE_TAG"
    --platform "$PLATFORM"
  )
  if [[ "$PUSH" == "1" ]]; then buildx_args+=(--push); else buildx_args+=(--load); fi
  ( cd "$REPO_ROOT" && docker buildx build "${buildx_args[@]}" rustdesk-server/ )
}

build_api() {
  require_file "$API_DOCKERFILE" "rustdesk-api/deploy/Dockerfile 缺失,checkout estel-li/rustdesk-api@master。"
  require_file "$REPO_ROOT/rustdesk-api-web/package.json" \
    "rustdesk-api-web/package.json 缺失,checkout estel-li/rustdesk-api-web@master 到根目录。"
  echo "==> building $NS/api:$IMAGE_TAG (platform=$PLATFORM, ctx=rustdesk-api/)"
  local buildx_args=(
    --file "$API_DOCKERFILE"
    --tag "$NS/api:$IMAGE_TAG"
    --platform "$PLATFORM"
    --build-context "api-web=$REPO_ROOT/rustdesk-api-web"
  )
  if [[ "$PUSH" == "1" ]]; then buildx_args+=(--push); else buildx_args+=(--load); fi
  ( cd "$REPO_ROOT" && docker buildx build "${buildx_args[@]}" rustdesk-api/ )
}

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(hbbs hbbr api)
fi

for t in "${targets[@]}"; do
  case "$t" in
    hbbs)              build_server_target hbbs ;;
    hbbr)              build_server_target hbbr ;;
    api|rustdesk-api)  build_api ;;
    *)
      echo "unknown target: $t (expected: hbbs | hbbr | api)" >&2
      exit 1
      ;;
  esac
done

echo
echo "==> done. Images:"
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | grep "^$NS/" || true
