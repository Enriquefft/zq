#!/usr/bin/env bash
# Benchmark: --describe schema inference
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZQ="${ROOT_DIR}/zig-out/bin/zq"
DATA_DIR="${SCRIPT_DIR}/../data"

echo "=== Schema Inference Benchmark ==="
echo ""

# Cold start: tiny input
echo "--- Cold start (single record) ---"
if command -v hyperfine &>/dev/null; then
    echo '{"id":1,"name":"alice","tags":["a"]}' | hyperfine --warmup 3 \
        "${ZQ} --describe" \
        --shell=none 2>&1 || echo "(hyperfine not available or failed)"
else
    echo '{"id":1,"name":"alice","tags":["a"]}' | /usr/bin/time -v "${ZQ}" --describe 2>&1
fi
echo ""

# Larger file if available
HUGE_FILE="${DATA_DIR}/huge.jsonl"
if [ -f "$HUGE_FILE" ]; then
    echo "--- Large file: $(wc -l < "$HUGE_FILE") records ---"

    echo "zq --describe:"
    if command -v hyperfine &>/dev/null; then
        hyperfine --warmup 1 "${ZQ} --describe ${HUGE_FILE}" --shell=none 2>&1
    else
        /usr/bin/time -v "${ZQ}" --describe "$HUGE_FILE" > /dev/null 2>&1
    fi

    echo ""
    echo "jq baseline (type inference equivalent):"
    if command -v jq &>/dev/null; then
        if command -v hyperfine &>/dev/null; then
            hyperfine --warmup 1 "jq -s '[.[] | to_entries | .[] | {key, type: (.value | type)}] | group_by(.key) | map({(.[0].key): [.[] | .type] | unique}) | add' ${HUGE_FILE}" --shell=bash 2>&1
        fi
    else
        echo "(jq not installed, skipping baseline)"
    fi

    echo ""
    echo "Memory usage (zq --describe):"
    /usr/bin/time -v "${ZQ}" --describe "$HUGE_FILE" > /dev/null 2>&1 || true
else
    echo "(No huge.jsonl found at ${HUGE_FILE}, skipping large file benchmark)"
    echo "Generate with: seq 1 15000000 | jq -c '{id: ., name: \"user\\(.)\", active: (. % 2 == 0)}' > ${HUGE_FILE}"
fi
