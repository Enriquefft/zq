#!/bin/bash
# Scenario 1: Multi-core Scalability
# Throughput performance on multi-core systems processing large datasets

set -e
set -o pipefail

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_FILE="$BENCHMARK_DIR/data/huge.jsonl"
RESULT_FILE="$BENCHMARK_DIR/results/01_parallelism.md"

# Source shared configuration (also sources progress.sh)
source "$BENCHMARK_DIR/common.sh"

mkdir -p "$BENCHMARK_DIR/results"

BM_WARMUP=$HYPERFINE_WARMUP
BM_RUNS=$HYPERFINE_RUNS

require_data "$DATA_FILE"
require_hyperfine
require_zq
detect_tools
# yq does not support JSONL multi-record files — never participates here.

echo "# Scenario 1: Multi-core Scalability" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Description:** Throughput performance on multi-core systems processing large JSONL datasets" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "## Test Details" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "- **File:** \`$DATA_FILE\`" >> "$RESULT_FILE"
echo "- **Size:** $(file_size_display "$DATA_FILE")" >> "$RESULT_FILE"
echo "- **Lines:** $(wc -l < "$DATA_FILE")" >> "$RESULT_FILE"
echo "- **Query:** \`.id\` (simple field extraction)" >> "$RESULT_FILE"
echo "- **Warmup runs:** $BM_WARMUP" >> "$RESULT_FILE"
echo "- **Benchmark runs:** $BM_RUNS" >> "$RESULT_FILE"
echo "- **Note:** yq excluded — does not support JSONL multi-record files." >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

HYPERFINE_ARGS=(
    --warmup "$BM_WARMUP" --runs "$BM_RUNS"
    --export-markdown "$BENCHMARK_DIR/results/01_parallelism_raw.md"
    --export-json "$BENCHMARK_DIR/results/01_parallelism.json"
)

$HAVE_JQ  && HYPERFINE_ARGS+=(--command-name jq  "jq '.id' '$DATA_FILE' > /dev/null")
$HAVE_JAQ && HYPERFINE_ARGS+=(--command-name jaq "jaq -c '.id' '$DATA_FILE' > /dev/null")
HYPERFINE_ARGS+=(--command-name zq "'$ZQ' '.id' '$DATA_FILE' > /dev/null")

echo "" >&2
start_phase_timer "Hyperfine benchmark (parallelism comparison)"
hyperfine "${HYPERFINE_ARGS[@]}" | tee -a "$RESULT_FILE"
end_phase_timer "Hyperfine benchmark"


echo "Benchmark results saved to: $RESULT_FILE" >&2
