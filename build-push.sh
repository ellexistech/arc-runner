#!/usr/bin/env bash
# Build and push ghcr.io/ellexistech/arc-runner as :<VERSION> and :latest.
# Bump VERSION by hand before running.
#
# Usage:
#   bash ./build-push.sh              # build + push VERSION and latest
#   bash ./build-push.sh --no-push    # build only
#   IMAGE_REPO=ghcr.io/org/name bash ./build-push.sh
#
# Login first (example):
#   echo "$GITHUB_TOKEN" | docker login ghcr.io -u USERNAME --password-stdin

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ -z "$VERSION" || ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-].+)?$ ]]; then
  echo "error: VERSION must look like 1.2.3 (got: '${VERSION:-empty}')" >&2
  exit 1
fi

IMAGE_REPO="${IMAGE_REPO:-ghcr.io/ellexistech/arc-runner}"
TAG_VERSION="${IMAGE_REPO}:${VERSION}"
TAG_LATEST="${IMAGE_REPO}:latest"
PUSH=1
for arg in "$@"; do
  case "$arg" in
    --no-push) PUSH=0 ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown arg: $arg" >&2
      exit 1
      ;;
  esac
done

echo "Building ${TAG_VERSION} (also tagged ${TAG_LATEST})"
docker build \
  --build-arg "IMAGE_VERSION=${VERSION}" \
  -t "$TAG_VERSION" \
  -t "$TAG_LATEST" \
  .

echo "Smoke: node / pnpm / gh / jq / scc"
docker run --rm "$TAG_VERSION" node -v
docker run --rm "$TAG_VERSION" pnpm -v
docker run --rm "$TAG_VERSION" gh --version
docker run --rm "$TAG_VERSION" jq --version
docker run --rm "$TAG_VERSION" scc --version

if [[ "$PUSH" -eq 1 ]]; then
  echo "Pushing ${TAG_VERSION}"
  docker push "$TAG_VERSION"
  echo "Pushing ${TAG_LATEST}"
  docker push "$TAG_LATEST"
  echo "done: ${TAG_VERSION} + ${TAG_LATEST}"
else
  echo "done: local tags only (--no-push)"
fi
