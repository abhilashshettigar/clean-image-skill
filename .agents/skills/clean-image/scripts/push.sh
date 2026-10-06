#!/usr/bin/env bash
# Log in, tag the local build as $REGISTRY/$TARGET_REPO/<name>:<tag>-cvefixed-amd64, push.
# usage: push.sh <image:tag> <tag>
set -uo pipefail

image="${1:-}"
tag="${2:-}"
if [[ -z "$image" || -z "$tag" ]]; then
  echo "usage: push.sh <image:tag> <tag>" >&2
  exit 2
fi

: "${REGISTRY:?REGISTRY is not set}"
: "${TARGET_REPO:?TARGET_REPO is not set}"
: "${REGISTRY_USER:?REGISTRY_USER is not set}"
: "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is not set}"

slug=$(echo "$image" | sed 's#[/:]#_#g')
local_ref="clean/$slug:local"

name="${image##*/}"
name="${name%%:*}"
target="$REGISTRY/$TARGET_REPO/$name:$tag-cvefixed-amd64"

docker image inspect "$local_ref" >/dev/null 2>&1 || {
  echo "missing local build: $local_ref (run patch-build.sh first)" >&2
  exit 2
}

echo "==> docker login $REGISTRY"
if ! printf '%s' "$REGISTRY_PASSWORD" | docker login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin; then
  echo "LOGIN_FAILED" >&2
  exit 1
fi

docker tag "$local_ref" "$target"
echo "==> pushing $target"
if ! docker push "$target"; then
  echo "PUSH_FAILED: $target" >&2
  exit 1
fi

echo "PUSHED=$target"
