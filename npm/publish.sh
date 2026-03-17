#!/usr/bin/env bash
set -euo pipefail

# Usage: ./npm/publish.sh <version> <artifacts-dir>
# Called by CI after downloading release artifacts.

VERSION="${1:?Usage: publish.sh <version> <artifacts-dir>}"
ARTIFACTS="${2:?Usage: publish.sh <version> <artifacts-dir>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Map: npm-dir -> artifact-glob -> binary-name
declare -A PLATFORM_MAP=(
  ["linux-x64"]="linux-amd64.tar.gz:zq"
  ["linux-arm64"]="linux-arm64.tar.gz:zq"
  ["darwin-x64"]="macos-amd64.tar.gz:zq"
  ["darwin-arm64"]="macos-arm64.tar.gz:zq"
  ["win32-x64"]="windows-amd64.zip:zq.exe"
  ["freebsd-x64"]="freebsd-amd64.tar.gz:zq"
)

for platform in "${!PLATFORM_MAP[@]}"; do
  IFS=':' read -r glob binary <<< "${PLATFORM_MAP[$platform]}"
  pkg_dir="${SCRIPT_DIR}/${platform}"
  bin_dir="${pkg_dir}/bin"
  mkdir -p "$bin_dir"

  # Find matching artifact
  artifact=$(find "$ARTIFACTS" -name "*${glob}" | head -1)
  if [ -z "$artifact" ]; then
    echo "Warning: no artifact for ${platform} (${glob}), skipping"
    continue
  fi

  # Extract binary
  if [[ "$artifact" == *.zip ]]; then
    unzip -o "$artifact" "$binary" -d "$bin_dir"
  else
    tar -xzf "$artifact" -C "$bin_dir" "$binary"
  fi
  chmod +x "${bin_dir}/${binary}"

  # Stamp version
  sed -i "s/\"version\": \".*\"/\"version\": \"${VERSION}\"/" "${pkg_dir}/package.json"

  echo "Publishing @zqjson/${platform}@${VERSION}"
  npm publish "$pkg_dir" --access public
done

# Publish main package
main_dir="${SCRIPT_DIR}/zq"
sed -i "s/\"version\": \".*\"/\"version\": \"${VERSION}\"/" "${main_dir}/package.json"
# Update optionalDependencies versions
sed -i "s/\": \"[0-9][^\"]*\"/\": \"${VERSION}\"/g" "${main_dir}/package.json"

echo "Publishing @zqjson/zq@${VERSION}"
npm publish "$main_dir" --access public
