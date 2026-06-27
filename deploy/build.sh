#!/usr/bin/env bash
# 本地 buildx 构建 hbbs / hbbr / rustdesk-api 三个 CE 镜像。
#
# 用法:
#   ./build.sh                # 全部构建
#   ./build.sh hbbs hbbr      # 只构建指定 target
#   IMAGE_TAG=v0.1.0 ./build.sh
#
# 想推送到 registry(可选):REGISTRY=ghcr.io/myorg ./build.sh
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

build_one() {
  local target="$1" context="$2" dockerfile="$3"
  echo "==> building $NS/$target:$IMAGE_TAG (platform=$PLATFORM, ctx=$context)"
  local buildx_args=(
    --file "$dockerfile"
    --target "$target"
    --tag "$NS/$target:$IMAGE_TAG"
    --platform "$PLATFORM"
  )
  if [[ "$PUSH" == "1" ]]; then
    buildx_args+=(--push)
  else
    buildx_args+=(--load)
  fi
  ( cd "$REPO_ROOT" && docker buildx build "${buildx_args[@]}" "$context" )
}

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(hbbs hbbr api)
fi

for t in "${targets[@]}"; do
  case "$t" in
    hbbs)
      build_one hbbs rustdesk-server/ "$DEPLOY_DIR/Dockerfile.server"
      ;;
    hbbr)
      build_one hbbr rustdesk-server/ "$DEPLOY_DIR/Dockerfile.server"
      ;;
    api|rustdesk-api)
      # api 的 Dockerfile 不用 multi-target,直接 build 整个文件
      echo "==> building $NS/api:$IMAGE_TAG (platform=$PLATFORM, ctx=rustdesk-api/)"
      buildx_args=(
        --file "$DEPLOY_DIR/Dockerfile.api"
        --tag "$NS/api:$IMAGE_TAG"
        --platform "$PLATFORM"
      )
      if [[ "$PUSH" == "1" ]]; then buildx_args+=(--push); else buildx_args+=(--load); fi
      ( cd "$REPO_ROOT" && docker buildx build "${buildx_args[@]}" rustdesk-api/ )
      ;;
    *)
      echo "unknown target: $t (expected: hbbs | hbbr | api)" >&2
      exit 1
      ;;
  esac
done

echo
echo "==> done. Images:"
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | grep "^$NS/" || true
