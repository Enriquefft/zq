#!/bin/bash
# Scenario 2: Memory Efficiency
# Memory footprint stability when processing large datasets in streaming mode

set -e
set -o pipefail

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_FILE="$BENCHMARK_DIR/data/huge.jsonl"
RESULT_FILE="$BENCHMARK_DIR/results/02_memory.md"
JSON_FILE="$BENCHMARK_DIR/results/02_memory.json"
ZQ_BIN="$BENCHMARK_DIR/../zig-out/bin/zq"

# Source shared configuration (also sources progress.sh)
source "$BENCHMARK_DIR/common.sh"

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

detect_tools
# yq does not support JSONL multi-record files — never participates here.

echo "# Scenario 2: Memory Efficiency" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Description:** Memory footprint stability when processing large datasets in streaming mode" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "## Test Details" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "- **File:** \`$DATA_FILE\`" >> "$RESULT_FILE"
echo "- **Size:** $(file_size_display "$DATA_FILE")" >> "$RESULT_FILE"
echo "- **Lines:** $(wc -l < "$DATA_FILE")" >> "$RESULT_FILE"
echo "- **Query:** \`select(.id > 500000)\` (streaming filter)" >> "$RESULT_FILE"
echo "- **Note:** yq excluded — does not support JSONL multi-record files." >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "## Results" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

# Capture metrics for JSON export
declare -A WALL_CLOCK RSS_KB

run_memory_test() {
    local label="$1"; shift
    local cmd=("$@")

    echo "### $label" >> "$RESULT_FILE"
    echo "\`\`\`" >> "$RESULT_FILE"
    start_phase_timer "Memory benchmark: $label"
    local time_output
    time_output=$( (/usr/bin/time -v "${cmd[@]}" > /dev/null) 2>&1 )
    echo "$time_output" \
        | grep -E "(Maximum resident set size|User time|System time|Elapsed \(wall clock\) time)" \
        | tee -a "$RESULT_FILE"
    end_phase_timer "Memory benchmark: $label"
    echo "\`\`\`" >> "$RESULT_FILE"
    echo "" >> "$RESULT_FILE"

    # Extract wall clock (m:ss.ss or h:mm:ss format) and convert to seconds
    local wall_raw
    wall_raw=$(echo "$time_output" | grep "Elapsed (wall clock)" | sed 's/.*: //')
    local wall_s
    if [[ "$wall_raw" == *:*:* ]]; then
        wall_s=$(echo "$wall_raw" | awk -F: '{printf "%.2f", $1*3600 + $2*60 + $3}')
    else
        wall_s=$(echo "$wall_raw" | awk -F: '{printf "%.2f", $1*60 + $2}')
    fi
    WALL_CLOCK[$label]=$wall_s

    # Extract RSS in kbytes
    local rss
    rss=$(echo "$time_output" | grep "Maximum resident set size" | awk '{print $NF}')
    RSS_KB[$label]=$rss
}

$HAVE_JQ  && run_memory_test "jq"  jq  'select(.id > 500000)' "$DATA_FILE"
$HAVE_JAQ && run_memory_test "jaq" jaq 'select(.id > 500000)' "$DATA_FILE"
run_memory_test "zq" "$ZQ_BIN" 'select(.id > 500000)' "$DATA_FILE"

# Capture input size in KB so the regression gate can compute RSS-per-input
# without re-statting the file on a different machine.
INPUT_SIZE_BYTES=$(stat --format='%s' "$DATA_FILE" 2>/dev/null || stat -f '%z' "$DATA_FILE" 2>/dev/null)
INPUT_SIZE_KB=$(( INPUT_SIZE_BYTES / 1024 ))

# Write JSON export
{
    echo '{'
    printf '"input_size_kb":%s,\n' "$INPUT_SIZE_KB"
    echo '"results":['
    first=true
    for label in jq jaq zq; do
        if [ -n "${WALL_CLOCK[$label]+x}" ]; then
            $first || echo ','
            first=false
            printf '{"command":"%s","mean":%s,"max_rss_kb":%s}' \
                "$label" "${WALL_CLOCK[$label]}" "${RSS_KB[$label]}"
        fi
    done
    echo ']}'
} > "$JSON_FILE"

echo "Benchmark results saved to: $RESULT_FILE" >&2
