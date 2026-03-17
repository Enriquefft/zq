#!/bin/bash
# Scenario 4: Streaming/Pipe Throughput
# Measures throughput when data is piped via stdin (cat | tool)

set -e
set -o pipefail

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BENCHMARK_DIR/common.sh"

DATA_FILE="$DATA_DIR/huge.jsonl"
RESULT_FILE="$RESULTS_DIR/04_streaming.md"
JSON_FILE="$RESULTS_DIR/04_streaming.json"

mkdir -p "$RESULTS_DIR"

require_data "$DATA_FILE"
require_hyperfine
require_zq
detect_tools

DISPLAY_FILE=$(display_filename "$DATA_FILE")
FILE_SIZE=$(file_size_display "$DATA_FILE")
LINE_COUNT=$(wc -l < "$DATA_FILE")

echo "# Scenario 4: Streaming/Pipe Throughput" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Description:** Throughput when processing data piped via stdin (\`cat file | tool\`)" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "## Test Details" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "- **File:** \`$DISPLAY_FILE\`" >> "$RESULT_FILE"
echo "- **Size:** $FILE_SIZE" >> "$RESULT_FILE"
echo "- **Lines:** $LINE_COUNT" >> "$RESULT_FILE"
echo "- **Query:** \`.id\` (simple field extraction)" >> "$RESULT_FILE"
echo "- **Method:** \`cat file | tool '.id' > /dev/null\`" >> "$RESULT_FILE"
echo "- **Warmup runs:** $HYPERFINE_WARMUP" >> "$RESULT_FILE"
echo "- **Benchmark runs:** $HYPERFINE_RUNS" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

# Correctness verification using verify_correctness from common.sh
echo "## Correctness" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

EXPECTED_LINES=$LINE_COUNT
CORRECT=true

verify_streaming() {
    local label="$1"; shift
    local actual
    actual=$(cat "$DATA_FILE" | "$@" 2>/dev/null | wc -l)
    if [ "$actual" -ne "$EXPECTED_LINES" ]; then
        echo "WARNING: $label streaming produced $actual lines, expected $EXPECTED_LINES" >&2
        return 1
    fi
    return 0
}

$HAVE_JQ   && verify_streaming "jq"   jq '.id'       || CORRECT=false
$HAVE_JAQ  && verify_streaming "jaq"  jaq -c '.id'    || CORRECT=false
$HAVE_GOJQ && verify_streaming "gojq" gojq '.id'      || CORRECT=false
verify_streaming "zq" "$ZQ" '.id' || CORRECT=false

if $CORRECT; then
    echo "All tools verified: $EXPECTED_LINES lines output via pipe." >> "$RESULT_FILE"
else
    echo "**WARNING:** Some tools produced incorrect output — see stderr." >> "$RESULT_FILE"
fi
echo "" >> "$RESULT_FILE"

# Build hyperfine command
HYPERFINE_ARGS=(
    --warmup "$HYPERFINE_WARMUP" --runs "$HYPERFINE_RUNS"
    --export-markdown "$RESULTS_DIR/04_streaming_raw.md"
    --export-json "$JSON_FILE"
    --time-limit 300
)

if $HAVE_JQ; then
    HYPERFINE_ARGS+=(--command-name jq "cat '$DATA_FILE' | jq '.id' > /dev/null")
fi
if $HAVE_JAQ; then
    HYPERFINE_ARGS+=(--command-name jaq "cat '$DATA_FILE' | jaq -c '.id' > /dev/null")
fi
if $HAVE_GOJQ; then
    HYPERFINE_ARGS+=(--command-name gojq "cat '$DATA_FILE' | gojq '.id' > /dev/null")
fi
HYPERFINE_ARGS+=(--command-name zq "cat '$DATA_FILE' | '$ZQ' '.id' > /dev/null")

echo "" >&2
start_phase_timer "Hyperfine benchmark (streaming comparison)"
hyperfine "${HYPERFINE_ARGS[@]}" | tee -a "$RESULT_FILE"
end_phase_timer "Hyperfine benchmark"

echo "Benchmark results saved to: $RESULT_FILE" >&2
