#!/bin/bash
# Scenario 1: Embarrassing Parallelism Metric
# Compare wall-clock time on large JSONL file
# Narrative: "We stopped waiting for single-threaded code in 2010. Why is jq still single-threaded?"

set -e

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_FILE="$BENCHMARK_DIR/data/huge.jsonl"
RESULT_FILE="$BENCHMARK_DIR/results/01_parallelism.md"

# Source progress utilities
source "$BENCHMARK_DIR/progress.sh"

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

echo "# Scenario 1: Embarrassing Parallelism" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Narrative:** We stopped waiting for single-threaded code in 2010. Why is jq still single-threaded?" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "## Test Details" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "- **File:** \`$DATA_FILE\`" >> "$RESULT_FILE"
echo "- **Size:** $(du -h "$DATA_FILE" | cut -f1)" >> "$RESULT_FILE"
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
    --ignore-failure
)

[ "$SKIP_JQ"  != true ] && HYPERFINE_ARGS+=("jq '.id' '$DATA_FILE' > /dev/null")
[ "$SKIP_JAQ" != true ] && HYPERFINE_ARGS+=("jaq -c '.id' '$DATA_FILE' > /dev/null")
HYPERFINE_ARGS+=("timeout 60 '$BENCHMARK_DIR/../zig-out/bin/zq' '.id' '$DATA_FILE' > /dev/null")

echo "" >&2
start_phase_timer "Hyperfine benchmark (parallelism comparison)"
hyperfine "${HYPERFINE_ARGS[@]}" | tee -a "$RESULT_FILE"
end_phase_timer "Hyperfine benchmark"

echo "" >> "$RESULT_FILE"
echo "## Analysis" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "This benchmark demonstrates the power of multi-core processing." >> "$RESULT_FILE"
echo "- jq runs on a single core by default" >> "$RESULT_FILE"
echo "- zq utilizes all available cores for parallel processing" >> "$RESULT_FILE"
echo "- The speedup factor should approximate the number of CPU cores" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "Benchmark results saved to: $RESULT_FILE" >&2
cat "$RESULT_FILE"
