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

# Quick mode reduces statistical rigor for faster iteration
if [ "${ZQ_QUICK:-0}" = "1" ]; then
    BM_WARMUP=1; BM_RUNS=3
else
    BM_WARMUP=2; BM_RUNS=10
fi

# Check prerequisites
if [ ! -f "$DATA_FILE" ]; then
    echo "Error: $DATA_FILE not found. Run data/huge.generator.sh first." >&2
    exit 1
fi
if ! command -v hyperfine &> /dev/null; then
    echo "Error: hyperfine not found. Install with: cargo install hyperfine" >&2
    exit 1
fi
if ! command -v "$BENCHMARK_DIR/../zig-out/bin/zq" &> /dev/null; then
    echo "Error: zq not found. Build with: zig build" >&2
    exit 1
fi

command -v jq  &> /dev/null || { echo "Warning: jq not found, skipping." >&2;  SKIP_JQ=true;  }
command -v jaq &> /dev/null || { echo "Warning: jaq not found, skipping." >&2; SKIP_JAQ=true; }
# yq does not support JSONL multi-record files — skip it here
SKIP_YQ=true

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

# Build hyperfine command
HYPERFINE_ARGS=(
    --warmup "$BM_WARMUP" --runs "$BM_RUNS"
    --export-markdown "$BENCHMARK_DIR/results/01_parallelism_raw.md"
    --export-json "$BENCHMARK_DIR/results/01_parallelism.json"
    --ignore-failure
)

[ "$SKIP_JQ"  != true ] && HYPERFINE_ARGS+=(--command-name jq "jq '.id' '$DATA_FILE' > /dev/null")
[ "$SKIP_JAQ" != true ] && HYPERFINE_ARGS+=(--command-name jaq "jaq -c '.id' '$DATA_FILE' > /dev/null")
HYPERFINE_ARGS+=(--command-name zq "timeout 60 '$BENCHMARK_DIR/../zig-out/bin/zq' '.id' '$DATA_FILE' > /dev/null")

echo "" >&2
start_phase_timer "Hyperfine benchmark (parallelism comparison)"
hyperfine "${HYPERFINE_ARGS[@]}" | tee -a "$RESULT_FILE"
end_phase_timer "Hyperfine benchmark"


echo "Benchmark results saved to: $RESULT_FILE" >&2
