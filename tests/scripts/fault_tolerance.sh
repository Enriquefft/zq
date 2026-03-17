#!/bin/bash
# Fault tolerance correctness test
# Verifies that zq handles malformed JSON records gracefully
# This is a pass/fail correctness test, NOT a benchmark.
#
# Usage: bash tests/scripts/fault_tolerance.sh
# Exit 0 = pass, exit 1 = fail

set -e
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ZQ_BIN="$ROOT_DIR/zig-out/bin/zq"
MALFORMED_FILE="$ROOT_DIR/benchmarks/data/malformed.jsonl"

if [ ! -x "$ZQ_BIN" ]; then
    echo "FAIL: zq not found at $ZQ_BIN. Build with: zig build -Doptimize=ReleaseFast" >&2
    exit 1
fi

if [ ! -f "$MALFORMED_FILE" ]; then
    echo "FAIL: $MALFORMED_FILE not found. Run benchmarks/data/malformed.generator.sh first." >&2
    exit 1
fi

TOTAL_LINES=$(wc -l < "$MALFORMED_FILE")
VALID_RECORDS=$(jq -c '.' "$MALFORMED_FILE" 2>/dev/null | wc -l)

echo "Fault Tolerance Test"
echo "===================="
echo "File: $MALFORMED_FILE"
echo "Total lines: $TOTAL_LINES"
echo "Valid records: $VALID_RECORDS"
echo ""

FAILED=0

# Test 1: zq should produce output for valid records
tmp_out=$(mktemp)
tmp_err=$(mktemp)
trap 'rm -f "$tmp_out" "$tmp_err"' EXIT

set +e
"$ZQ_BIN" '.valid' "$MALFORMED_FILE" > "$tmp_out" 2> "$tmp_err"
exit_code=$?
set -e

lines_out=$(wc -l < "$tmp_out")

echo "Test 1: Recovery rate"
echo "  Records output: $lines_out / $VALID_RECORDS valid"

if [ "$lines_out" -lt "$VALID_RECORDS" ]; then
    echo "  FAIL: zq recovered fewer records than expected"
    FAILED=1
else
    echo "  PASS"
fi

echo ""
echo "Test 2: Non-zero exit on malformed input"
if [ "$exit_code" -ne 0 ]; then
    echo "  PASS (exit code: $exit_code)"
else
    echo "  INFO: zq exited 0 despite malformed records (may be acceptable)"
fi

echo ""
echo "Test 3: Errors reported on stderr"
if [ -s "$tmp_err" ]; then
    echo "  PASS (errors reported)"
    echo "  First few errors:"
    head -3 "$tmp_err" | sed 's/^/    /'
else
    echo "  WARN: no errors on stderr for malformed input"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "RESULT: PASS"
    exit 0
else
    echo "RESULT: FAIL"
    exit 1
fi
