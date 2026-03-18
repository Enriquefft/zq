#!/usr/bin/env bash
set -euo pipefail

# Usage: ./docker/publish.sh <version> <artifacts-dir>
# Called by CI after downloading release artifacts.

VERSION="${1:?Usage: publish.sh <version> <artifacts-dir>}"
ARTIFACTS="$(cd "${2:?Usage: publish.sh <version> <artifacts-dir>}" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="ghcr.io/enriquefft/zq"

# Create temp build context
BUILD_CTX="$(mktemp -d)"
trap 'rm -rf "$BUILD_CTX"' EXIT

# Extract linux binaries from artifacts
for arch in amd64 arm64; do
  artifact=$(find "$ARTIFACTS" -name "*linux-${arch}.tar.gz" | head -1)
  if [ -z "$artifact" ]; then
    echo "Error: no artifact found for linux-${arch}" >&2
    exit 1
  fi
  tar -xzf "$artifact" -C "$BUILD_CTX" zq
  mv "$BUILD_CTX/zq" "$BUILD_CTX/zq-${arch}"
done

cp "$SCRIPT_DIR/Dockerfile" "$BUILD_CTX/"

# Compute tags
TAGS="--tag ${REGISTRY}:${VERSION}"
if [[ "$VERSION" != *-* ]]; then
  # Stable release — add floating tags
  MAJOR="${VERSION%%.*}"
  MINOR="${VERSION%.*}"
  TAGS="$TAGS --tag ${REGISTRY}:latest"
  TAGS="$TAGS --tag ${REGISTRY}:${MINOR}"
  TAGS="$TAGS --tag ${REGISTRY}:${MAJOR}"
fi

# Build and push multi-arch image
# shellcheck disable=SC2086
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --provenance=true \
  --sbom=true \
  --label "org.opencontainers.image.version=${VERSION}" \
  --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --label "org.opencontainers.image.revision=${GITHUB_SHA:-$(git rev-parse HEAD)}" \
  $TAGS \
  --push \
  "$BUILD_CTX"
