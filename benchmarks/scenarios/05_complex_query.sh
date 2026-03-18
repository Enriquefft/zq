#!/bin/bash
# Scenario 5: Complex Query — Real-World Transformation
# Tests object construction, arithmetic, comparison, alternative operator, type builtin

set -e
set -o pipefail

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BENCHMARK_DIR/common.sh"

DATA_FILE="$DATA_DIR/huge.jsonl"
RESULT_FILE="$RESULTS_DIR/05_complex_query.md"
JSON_FILE="$RESULTS_DIR/05_complex_query.json"

mkdir -p "$RESULTS_DIR"

require_data "$DATA_FILE"
require_hyperfine
require_zq
detect_tools

DISPLAY_FILE=$(display_filename "$DATA_FILE")
FILE_SIZE=$(file_size_display "$DATA_FILE")
LINE_COUNT=$(wc -l < "$DATA_FILE")

QUERY='{id: .id, mod3: (.id % 3), big: (.id > 7500000), kind: (.values // .meta // .data // "none" | type)}'

echo "# Scenario 5: Complex Query" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Description:** Real-world transformation — object construction, arithmetic, comparison, alternative operator, type builtin" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "## Test Details" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "- **File:** \`$DISPLAY_FILE\`" >> "$RESULT_FILE"
echo "- **Size:** $FILE_SIZE" >> "$RESULT_FILE"
echo "- **Lines:** $LINE_COUNT" >> "$RESULT_FILE"
echo "- **Query:** \`$QUERY\`" >> "$RESULT_FILE"
echo "- **Warmup runs:** $HYPERFINE_WARMUP" >> "$RESULT_FILE"
echo "- **Benchmark runs:** $HYPERFINE_RUNS" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

# Correctness verification
echo "## Correctness" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

EXPECTED_LINES=$LINE_COUNT
CORRECT=true

if $HAVE_JQ; then
    verify_correctness "jq" "$EXPECTED_LINES" jq -c "$QUERY" "$DATA_FILE" || CORRECT=false
fi
if $HAVE_JAQ; then
    verify_correctness "jaq" "$EXPECTED_LINES" jaq -c "$QUERY" "$DATA_FILE" || CORRECT=false
fi
if $HAVE_GOJQ; then
    verify_correctness "gojq" "$EXPECTED_LINES" gojq -c "$QUERY" "$DATA_FILE" || CORRECT=false
fi
verify_correctness "zq" "$EXPECTED_LINES" "$ZQ" -c "$QUERY" "$DATA_FILE" || CORRECT=false

if $CORRECT; then
    echo "All tools verified: $EXPECTED_LINES lines output." >> "$RESULT_FILE"
else
    echo "**WARNING:** Some tools produced incorrect output — see stderr." >> "$RESULT_FILE"
fi
echo "" >> "$RESULT_FILE"

# Build hyperfine command
HYPERFINE_ARGS=(
    --warmup "$HYPERFINE_WARMUP" --runs "$HYPERFINE_RUNS"
    --export-markdown "$RESULTS_DIR/05_complex_query_raw.md"
    --export-json "$JSON_FILE"
)

if $HAVE_JQ; then
    HYPERFINE_ARGS+=(--command-name jq "jq -c '$QUERY' '$DATA_FILE' > /dev/null")
fi
if $HAVE_JAQ; then
    HYPERFINE_ARGS+=(--command-name jaq "jaq -c '$QUERY' '$DATA_FILE' > /dev/null")
fi
if $HAVE_GOJQ; then
    HYPERFINE_ARGS+=(--command-name gojq "gojq -c '$QUERY' '$DATA_FILE' > /dev/null")
fi
HYPERFINE_ARGS+=(--command-name zq "'$ZQ' -c '$QUERY' '$DATA_FILE' > /dev/null")

echo "" >&2
start_phase_timer "Hyperfine benchmark (complex query comparison)"
hyperfine "${HYPERFINE_ARGS[@]}" | tee -a "$RESULT_FILE"
end_phase_timer "Hyperfine benchmark"

echo "Benchmark results saved to: $RESULT_FILE" >&2
