#!/bin/bash
# Scenario 3: Cold Start Metric (Dev Experience)
# Compare execution time for trivial query on tiny input
# Narrative: "Snappy enough for a shell loop."

set -e

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT_FILE="$BENCHMARK_DIR/results/03_cold_start.md"
ZQ_BIN="$BENCHMARK_DIR/../zig-out/bin/zq"

# Source progress utilities
source "$BENCHMARK_DIR/progress.sh"

mkdir -p "$BENCHMARK_DIR/results"

# Quick mode reduces statistical rigor for faster iteration
if [ "${ZQ_QUICK:-0}" = "1" ]; then
    BM_WARMUP=1; BM_RUNS=10
else
    BM_WARMUP=5; BM_RUNS=100
fi

# Check prerequisites
if ! command -v hyperfine &> /dev/null; then
    echo "Error: hyperfine not found. Install with: cargo install hyperfine" >&2
    exit 1
fi
if ! command -v "$ZQ_BIN" &> /dev/null; then
    echo "Error: zq not found. Build with: zig build" >&2
    exit 1
fi

command -v jq  &> /dev/null || { echo "Warning: jq not found, skipping." >&2;  SKIP_JQ=true;  }
command -v jaq &> /dev/null || { echo "Warning: jaq not found, skipping." >&2; SKIP_JAQ=true; }
command -v yq  &> /dev/null || { echo "Warning: yq not found, skipping." >&2;  SKIP_YQ=true;  }

echo "# Scenario 3: Cold Start (Dev Experience)" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Narrative:** Snappy enough for a shell loop." >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "## Test Details" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "- **Input:** Single JSON object \`{\"a\":1}\`" >> "$RESULT_FILE"
echo "- **Query:** \`.a\` (simple field extraction)" >> "$RESULT_FILE"
echo "- **Warmup runs:** $BM_WARMUP" >> "$RESULT_FILE"
echo "- **Benchmark runs:** $BM_RUNS" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

# Build hyperfine command as an array to avoid quoting issues with eval
HYPERFINE_ARGS=(hyperfine --warmup "$BM_WARMUP" --runs "$BM_RUNS"
    --export-markdown "$BENCHMARK_DIR/results/03_cold_start_raw.md"
    --ignore-failure)

[ "$SKIP_JQ"  != true ] && HYPERFINE_ARGS+=("echo '{\"a\":1}' | jq .a")
[ "$SKIP_JAQ" != true ] && HYPERFINE_ARGS+=("echo '{\"a\":1}' | jaq .a")
[ "$SKIP_YQ"  != true ] && HYPERFINE_ARGS+=("echo '{\"a\":1}' | yq .a")
HYPERFINE_ARGS+=("echo '{\"a\":1}' | \"$ZQ_BIN\" .a")

echo "" >&2
start_phase_timer "Hyperfine benchmark (cold start comparison)"
"${HYPERFINE_ARGS[@]}" | tee -a "$RESULT_FILE"
end_phase_timer "Hyperfine benchmark"

echo "" >> "$RESULT_FILE"
echo "## Analysis" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "Startup latency matters for:" >> "$RESULT_FILE"
echo "- **Interactive use**: Developers running ad-hoc queries in a shell" >> "$RESULT_FILE"
echo "- **Loop scenarios**: Processing records one at a time in scripts" >> "$RESULT_FILE"
echo "- **Pipeline usage**: When zq is invoked per-request (e.g., inside a loop with \`curl | zq\`)" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Performance targets:**" >> "$RESULT_FILE"
echo "- **< 10ms**: Excellent — feels instantaneous" >> "$RESULT_FILE"
echo "- **10–50ms**: Good — fast enough for interactive use" >> "$RESULT_FILE"
echo "- **50–100ms**: Acceptable — minor latency noticeable" >> "$RESULT_FILE"
echo "- **> 100ms**: Slow — will feel sluggish in shell loops" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "Benchmark results saved to: $RESULT_FILE" >&2
cat "$RESULT_FILE"
