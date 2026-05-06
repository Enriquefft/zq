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

# Source shared configuration (also sources progress.sh)
source "$BENCHMARK_DIR/common.sh"

mkdir -p "$BENCHMARK_DIR/results"

BM_RUNS=$HYPERFINE_RUNS_COLD

require_hyperfine
require_zq

TINY_FILE="$BENCHMARK_DIR/data/tiny.json"
if [ ! -f "$TINY_FILE" ]; then
    echo '{"a":1}' > "$TINY_FILE"
fi

detect_tools

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

# --warmup 0 and --shell=none measure actual startup, not cached.
HYPERFINE_ARGS=(hyperfine --warmup 0 --runs "$BM_RUNS"
    --shell=none
    --export-markdown "$BENCHMARK_DIR/results/03_startup_latency_raw.md"
    --export-json "$JSON_FILE")

$HAVE_JQ  && HYPERFINE_ARGS+=(--command-name jq  "jq .a $TINY_FILE")
$HAVE_JAQ && HYPERFINE_ARGS+=(--command-name jaq "jaq .a $TINY_FILE")
$HAVE_YQ  && HYPERFINE_ARGS+=(--command-name yq  "yq .a $TINY_FILE")
HYPERFINE_ARGS+=(--command-name zq "$ZQ_BIN .a $TINY_FILE")

echo "" >&2
start_phase_timer "Hyperfine benchmark (startup latency comparison)"
"${HYPERFINE_ARGS[@]}" | tee -a "$RESULT_FILE"
end_phase_timer "Hyperfine benchmark"

echo "Benchmark results saved to: $RESULT_FILE" >&2
