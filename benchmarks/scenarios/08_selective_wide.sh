#!/bin/bash
# Scenario 8: Selective Query — Wide Records (workload coverage)
# Mirror of scenario 7 but on huge_wide.jsonl (~50-field, ~1KB-per-line
# records). Single-binary zq vs jq. Tracks selective-filter throughput
# on wide records, where the per-record VM body dominates parse cost.
# Workload coverage benchmark, not pushdown attribution: the
# predicate-pushdown experiment was reverted (see
# `research/09-pushdown-doesnt-transfer.md` on the `research` branch).

set -e
set -o pipefail

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BENCHMARK_DIR/common.sh"

DATA_FILE="$DATA_DIR/huge_wide.jsonl"
RESULT_FILE="$RESULTS_DIR/08_selective_wide.md"
JSON_FILE="$RESULTS_DIR/08_selective_wide.json"

mkdir -p "$RESULTS_DIR"

require_data "$DATA_FILE"
require_hyperfine
require_zq
detect_tools

DISPLAY_FILE=$(display_filename "$DATA_FILE")
FILE_SIZE=$(file_size_display "$DATA_FILE")
LINE_COUNT=$(wc -l < "$DATA_FILE")

# Threshold derived from LINE_COUNT for ~25% selectivity. The wide
# generator emits ids 1..LINE_COUNT, so any threshold expressed as a
# fraction lands the same selectivity regardless of HUGE_WIDE_LINES.
THRESHOLD=$(( LINE_COUNT * 3 / 4 ))

QUERY="select(.id > $THRESHOLD)"

# EXPECTED_PASSED computed by awk over the data file. The id is the
# first field in every record so `awk -F'"id":'` then split on `,`
# extracts it without parsing the rest of the line.
EXPECTED_PASSED=$(awk -F'"id":' -v t="$THRESHOLD" 'BEGIN { c = 0 } NR > 0 { split($2, a, ","); if (a[1] + 0 > t) c++ } END { print c }' "$DATA_FILE")

echo "# Scenario 8: Selective Query — Wide Records" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Description:** Selective-filter throughput on wide records (~50 fields, ~1KB/line). Workload-coverage benchmark, counterpart to scenario 7." >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "## Test Details" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "- **File:** \`$DISPLAY_FILE\`" >> "$RESULT_FILE"
echo "- **Size:** $FILE_SIZE" >> "$RESULT_FILE"
echo "- **Lines:** $LINE_COUNT (≈ $EXPECTED_PASSED pass the predicate)" >> "$RESULT_FILE"
echo "- **Query:** \`$QUERY\`" >> "$RESULT_FILE"
echo "- **Warmup runs:** $HYPERFINE_WARMUP" >> "$RESULT_FILE"
echo "- **Benchmark runs:** $HYPERFINE_RUNS" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "## Correctness" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

CORRECT=true

if $HAVE_JQ; then
    verify_correctness "jq" "$EXPECTED_PASSED" jq -c "$QUERY" "$DATA_FILE" || CORRECT=false
fi
verify_correctness "zq" "$EXPECTED_PASSED" "$ZQ" -c "$QUERY" "$DATA_FILE" || CORRECT=false

if $CORRECT; then
    echo "All tools verified: $EXPECTED_PASSED records pass the predicate." >> "$RESULT_FILE"
else
    echo "**WARNING:** Some tools produced incorrect output — see stderr." >> "$RESULT_FILE"
fi
echo "" >> "$RESULT_FILE"

HYPERFINE_ARGS=(
    --warmup "$HYPERFINE_WARMUP" --runs "$HYPERFINE_RUNS"
    --export-markdown "$RESULTS_DIR/08_selective_wide_raw.md"
    --export-json "$JSON_FILE"
)

if $HAVE_JQ; then
    HYPERFINE_ARGS+=(--command-name jq "jq -c '$QUERY' '$DATA_FILE' > /dev/null")
fi
HYPERFINE_ARGS+=(--command-name zq "'$ZQ' -c '$QUERY' '$DATA_FILE' > /dev/null")

echo "" >&2
start_phase_timer "Hyperfine benchmark (selective query — wide records)"
hyperfine "${HYPERFINE_ARGS[@]}" | tee -a "$RESULT_FILE"
end_phase_timer "Hyperfine benchmark"

echo "Benchmark results saved to: $RESULT_FILE" >&2
