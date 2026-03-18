#!/bin/bash
# Scenario 3: Startup Latency
# Time overhead of process initialization and single-record processing
# Uses --warmup 0 and --shell=none to measure actual startup cost

set -e
set -o pipefail

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT_FILE="$BENCHMARK_DIR/results/03_startup_latency.md"
JSON_FILE="$BENCHMARK_DIR/results/03_startup_latency.json"
ZQ_BIN="$BENCHMARK_DIR/../zig-out/bin/zq"

# Source progress utilities
source "$BENCHMARK_DIR/progress.sh"

mkdir -p "$BENCHMARK_DIR/results"

# Quick mode reduces statistical rigor for faster iteration
if [ "${ZQ_QUICK:-0}" = "1" ]; then
    BM_RUNS=10
else
    BM_RUNS=100
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

# Create a tiny input file to avoid pipe overhead
TINY_FILE="$BENCHMARK_DIR/data/tiny.json"
if [ ! -f "$TINY_FILE" ]; then
    echo '{"a":1}' > "$TINY_FILE"
fi

command -v jq  &> /dev/null || { echo "Warning: jq not found, skipping." >&2;  SKIP_JQ=true;  }
command -v jaq &> /dev/null || { echo "Warning: jaq not found, skipping." >&2; SKIP_JAQ=true; }
command -v yq  &> /dev/null || { echo "Warning: yq not found, skipping." >&2;  SKIP_YQ=true;  }

echo "# Scenario 3: Startup Latency" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Description:** Time overhead of process initialization and single-record processing" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "## Test Details" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "- **Input:** \`tiny.json\` containing \`{\"a\":1}\`" >> "$RESULT_FILE"
echo "- **Query:** \`.a\` (simple field extraction)" >> "$RESULT_FILE"
echo "- **Warmup runs:** 0 (measures actual startup, not cached)" >> "$RESULT_FILE"
echo "- **Benchmark runs:** $BM_RUNS" >> "$RESULT_FILE"
echo "- **Shell:** none (--shell=none eliminates ~2-3ms shell overhead)" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

# Build hyperfine command — --warmup 0 and --shell=none
HYPERFINE_ARGS=(hyperfine --warmup 0 --runs "$BM_RUNS"
    --shell=none
    --export-markdown "$BENCHMARK_DIR/results/03_startup_latency_raw.md"
    --export-json "$JSON_FILE"
    --ignore-failure)

[ "$SKIP_JQ"  != true ] && HYPERFINE_ARGS+=(--command-name jq "jq .a $TINY_FILE")
[ "$SKIP_JAQ" != true ] && HYPERFINE_ARGS+=(--command-name jaq "jaq .a $TINY_FILE")
[ "$SKIP_YQ"  != true ] && HYPERFINE_ARGS+=(--command-name yq "yq .a $TINY_FILE")
HYPERFINE_ARGS+=(--command-name zq "$ZQ_BIN .a $TINY_FILE")

echo "" >&2
start_phase_timer "Hyperfine benchmark (startup latency comparison)"
"${HYPERFINE_ARGS[@]}" | tee -a "$RESULT_FILE"
end_phase_timer "Hyperfine benchmark"

echo "Benchmark results saved to: $RESULT_FILE" >&2
