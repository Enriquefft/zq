#!/usr/bin/env bash
set -euo pipefail

# Trim the first N seconds from the benchmark GIF
# Usage: bash demo/trim_gif.sh [seconds_to_cut] [input] [output]
# Default: cut 4s from demo/benchmark.gif

SECONDS_TO_CUT="${1:-4}"
INPUT="${2:-demo/benchmark.gif}"
OUTPUT="${3:-demo/benchmark.gif}"

if ! command -v ffmpeg &>/dev/null; then
    echo "Error: ffmpeg required. Install with: nix-shell -p ffmpeg" >&2
    exit 1
fi

TMP="$(mktemp /tmp/trimmed_XXXXXX.gif)"
trap 'rm -f "$TMP"' EXIT

ffmpeg -y -i "$INPUT" -ss "$SECONDS_TO_CUT" -f gif "$TMP" 2>/dev/null
mv "$TMP" "$OUTPUT"
trap - EXIT

echo "Trimmed ${SECONDS_TO_CUT}s from start -> $OUTPUT"
