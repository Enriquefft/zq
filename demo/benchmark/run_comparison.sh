#!/usr/bin/env bash
set -euo pipefail

# zq vs jq benchmark comparison
# Usage: bash demo/run_comparison.sh [records]
# Default: 1,000,000 records

RECORDS="${1:-1000000}"
TMPFILE="$(mktemp /tmp/zq_bench_XXXXXX.jsonl)"
trap 'rm -f "$TMPFILE"' EXIT

echo "=== zq vs jq benchmark ==="
echo ""

# Generate test data
echo "Generating $RECORDS records..."
awk -v n="$RECORDS" 'BEGIN{for(i=1;i<=n;i++) printf "{\"id\":%d,\"name\":\"user_%d\",\"active\":true}\n",i,i}' > "$TMPFILE"
echo "Data: $(du -h "$TMPFILE" | cut -f1) ($(wc -l < "$TMPFILE") records)"
echo ""

# Check tools are available
for tool in jq zq; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: $tool not found in PATH" >&2
        exit 1
    fi
done

echo "--- .id extraction ---"
echo ""

echo "jq:"
time jq '.id' "$TMPFILE" > /dev/null
echo ""

echo "zq:"
time zq '.id' "$TMPFILE" > /dev/null
echo ""

echo "--- select(.id > $((RECORDS / 2))) ---"
echo ""

echo "jq:"
time jq "select(.id > $((RECORDS / 2)))" "$TMPFILE" > /dev/null
echo ""

echo "zq:"
time zq "select(.id > $((RECORDS / 2)))" "$TMPFILE" > /dev/null
echo ""

echo "=== Done ==="
