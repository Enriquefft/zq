#!/usr/bin/env bash
set -euo pipefail

# Usage: ./pypi/publish.sh <version> <artifacts-dir>
# Called by CI after downloading release artifacts.
# Idempotent: skips versions already on PyPI.

VERSION="${1:?Usage: publish.sh <version> <artifacts-dir>}"
ARTIFACTS="$(cd "${2:?Usage: publish.sh <version> <artifacts-dir>}" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check if version already exists on PyPI
if pip index versions zq-json 2>/dev/null | grep -qF "$VERSION"; then
  echo "zq-json ${VERSION} already on PyPI, skipping"
  exit 0
fi

WHEEL_DIR="/tmp/zq-pypi-wheels"
rm -rf "$WHEEL_DIR"
mkdir -p "$WHEEL_DIR"

# Map: artifact-glob -> wheel-platform-tag -> binary-name
declare -A PLATFORM_MAP=(
  ["linux-amd64.tar.gz"]="manylinux_2_17_x86_64.manylinux2014_x86_64:zq"
  ["linux-arm64.tar.gz"]="manylinux_2_17_aarch64.manylinux2014_aarch64:zq"
  ["macos-amd64.tar.gz"]="macosx_11_0_x86_64:zq"
  ["macos-arm64.tar.gz"]="macosx_11_0_arm64:zq"
  ["windows-amd64.zip"]="win_amd64:zq.exe"
)

PEP_VERSION="${VERSION}"

for glob in "${!PLATFORM_MAP[@]}"; do
  IFS=':' read -r platform_tag binary <<< "${PLATFORM_MAP[$glob]}"

  artifact=$(find "$ARTIFACTS" -name "*${glob}" | head -1)
  if [ -z "$artifact" ]; then
    echo "Warning: no artifact for ${glob}, skipping"
    continue
  fi

  echo "Building wheel for ${platform_tag}..."

  work="/tmp/zq-wheel-${platform_tag}"
  rm -rf "$work"
  mkdir -p "$work/zq_json/_bin"

  if [[ "$artifact" == *.zip ]]; then
    unzip -o "$artifact" "$binary" -d "$work/zq_json/_bin"
  else
    tar -xzf "$artifact" -C "$work/zq_json/_bin" "$binary"
  fi
  chmod +x "$work/zq_json/_bin/${binary}"

  cp "$SCRIPT_DIR/__init__.py" "$work/zq_json/__init__.py"
  cp "$SCRIPT_DIR/__main__.py" "$work/zq_json/__main__.py"
  sed -i "s/__version__ = \"0.0.0\"/__version__ = \"${PEP_VERSION}\"/" "$work/zq_json/__init__.py"

  dist_info="$work/zq_json-${PEP_VERSION}.dist-info"
  mkdir -p "$dist_info"

  cat > "$dist_info/METADATA" <<EOF
Metadata-Version: 2.1
Name: zq-json
Version: ${PEP_VERSION}
Summary: Drop-in jq replacement — 26x faster JSON processing
Home-page: https://github.com/Enriquefft/zq
License: MIT
Author: Enrique Flores
Requires-Python: >=3.8
Classifier: Development Status :: 4 - Beta
Classifier: Environment :: Console
Classifier: Intended Audience :: Developers
Classifier: License :: OSI Approved :: MIT License
Classifier: Operating System :: OS Independent
Classifier: Programming Language :: Python :: 3
Classifier: Topic :: Utilities
Description-Content-Type: text/markdown

# zq-json

Drop-in jq replacement — 26x faster JSON processing via parallelization, SIMD, and zero-allocation parsing.

## Usage

\`\`\`bash
pip install zq-json
zq '.name' data.json
\`\`\`

See [GitHub](https://github.com/Enriquefft/zq) for full documentation.
EOF

  cat > "$dist_info/WHEEL" <<EOF
Wheel-Version: 1.0
Generator: zq-publish
Root-Is-Purelib: false
Tag: py3-none-${platform_tag}
EOF

  cat > "$dist_info/entry_points.txt" <<EOF
[console_scripts]
zq = zq_json:main
EOF

  # Generate RECORD with SHA256 hashes
  python3 -c "
import hashlib, base64, os

os.chdir('${work}')
record_path = '${dist_info##*/}/RECORD'
lines = []
for root, dirs, files in os.walk('.'):
    for f in sorted(files):
        path = os.path.join(root, f).lstrip('./')
        if path == record_path:
            continue
        with open(path, 'rb') as fh:
            digest = hashlib.sha256(fh.read()).digest()
        b64 = base64.urlsafe_b64encode(digest).rstrip(b'=').decode()
        size = os.path.getsize(path)
        lines.append(f'{path},sha256={b64},{size}')

lines.sort()
lines.append(f'{record_path},,')
with open(record_path, 'w') as fh:
    fh.write('\n'.join(lines) + '\n')
"

  # Build wheel
  wheel_name="zq_json-${PEP_VERSION}-py3-none-${platform_tag}.whl"
  (cd "$work" && zip -r "$WHEEL_DIR/$wheel_name" . -x '.*')

  echo "Built: $wheel_name"
  rm -rf "$work"
done

echo ""
echo "Wheels built in $WHEEL_DIR:"
ls -la "$WHEEL_DIR"/*.whl

echo ""
echo "Uploading to PyPI..."
twine upload "$WHEEL_DIR"/*.whl
