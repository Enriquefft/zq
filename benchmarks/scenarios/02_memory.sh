#!/bin/bash
# Scenario 2: Memory Efficiency
# Memory footprint stability when processing large datasets in streaming mode

set -e

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_FILE="$BENCHMARK_DIR/data/huge.jsonl"
RESULT_FILE="$BENCHMARK_DIR/results/02_memory.md"
ZQ_BIN="$BENCHMARK_DIR/../zig-out/bin/zq"

# Source progress utilities
source "$BENCHMARK_DIR/progress.sh"

mkdir -p "$BENCHMARK_DIR/results"

# Check prerequisites
if [ ! -f "$DATA_FILE" ]; then
    echo "Error: $DATA_FILE not found. Run data/huge.generator.sh first." >&2
    exit 1
fi
if ! command -v /usr/bin/time &> /dev/null; then
    echo "Error: /usr/bin/time not found (Linux GNU time required)." >&2
    exit 1
fi
if ! command -v "$ZQ_BIN" &> /dev/null; then
    echo "Error: zq not found. Build with: zig build" >&2
    exit 1
fi

command -v jq  &> /dev/null || { echo "Warning: jq not found, skipping." >&2;  SKIP_JQ=true;  }
command -v jaq &> /dev/null || { echo "Warning: jaq not found, skipping." >&2; SKIP_JAQ=true; }
# yq does not support JSONL multi-record files — skip it here
SKIP_YQ=true

echo "# Scenario 2: Memory Efficiency" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Description:** Memory footprint stability when processing large datasets in streaming mode" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "## Test Details" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "- **File:** \`$DATA_FILE\`" >> "$RESULT_FILE"
echo "- **Size:** $(du -h "$DATA_FILE" | cut -f1)" >> "$RESULT_FILE"
echo "- **Lines:** $(wc -l < "$DATA_FILE")" >> "$RESULT_FILE"
echo "- **Query:** \`select(.id > 500000)\` (streaming filter)" >> "$RESULT_FILE"
echo "- **Note:** yq excluded — does not support JSONL multi-record files." >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "## Results" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

run_memory_test() {
    local label="$1"; shift
    local cmd=("$@")

    echo "### $label" >> "$RESULT_FILE"
    echo "\`\`\`" >> "$RESULT_FILE"
    start_phase_timer "Memory benchmark: $label"
    (/usr/bin/time -v "${cmd[@]}" > /dev/null) 2>&1 \
        | grep -E "(Maximum resident set size|User time|System time|Elapsed \(wall clock\) time)" \
        | tee -a "$RESULT_FILE"
    end_phase_timer "Memory benchmark: $label"
    echo "\`\`\`" >> "$RESULT_FILE"
    echo "" >> "$RESULT_FILE"
}

[ "$SKIP_JQ"  != true ] && run_memory_test "jq"  jq  'select(.id > 500000)' "$DATA_FILE"
[ "$SKIP_JAQ" != true ] && run_memory_test "jaq" jaq 'select(.id > 500000)' "$DATA_FILE"
run_memory_test "zq" timeout 60 "$ZQ_BIN" 'select(.id > 500000)' "$DATA_FILE"


echo "Benchmark results saved to: $RESULT_FILE" >&2
cat "$RESULT_FILE"
