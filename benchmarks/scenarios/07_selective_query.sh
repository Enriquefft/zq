#!/bin/bash
# Scenario 7: Selective Query — Predicate Pushdown Attribution
# Runs zq twice on the same selective-filter workload:
#   - default build (projection-plan harvester active, predicate pushed
#     into `feedPlanned`'s top-of-record evaluator)
#   - `-Dno-plan=true` build (harvester returns null, every record
#     reaches the VM regardless of predicate outcome)
# The ratio between the two runs is the clean attribution number for
# the predicate-pushdown work. Both must beat jq.

set -e
set -o pipefail

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BENCHMARK_DIR/common.sh"

DATA_FILE="$DATA_DIR/huge.jsonl"
RESULT_FILE="$RESULTS_DIR/07_selective_query.md"
JSON_FILE="$RESULTS_DIR/07_selective_query.json"

mkdir -p "$RESULTS_DIR"

require_data "$DATA_FILE"
require_hyperfine
detect_tools

# We need both binaries: the production zq (already at zig-out/bin/zq)
# and a no-plan build for attribution. Build the latter to a sibling
# path so the production binary is unaffected.
ZQ_DEFAULT="$ROOT_DIR/zig-out/bin/zq"
ZQ_NOPLAN="$ROOT_DIR/zig-out/bin/zq-noplan"

if [ ! -x "$ZQ_DEFAULT" ]; then
    echo "Error: default zq not found at $ZQ_DEFAULT. Build with: zig build -Doptimize=ReleaseFast" >&2
    exit 1
fi

# Build the no-plan attribution binary.  Output goes to a temporary
# install prefix to avoid clobbering zig-out/bin/zq.  After the build,
# the binary lives at the standard install path inside the temp tree;
# move it to a stable name in the production zig-out/bin/.
echo "Building no-plan attribution binary (-Dno-plan=true)..." >&2
NOPLAN_BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$NOPLAN_BUILD_DIR"' EXIT
(cd "$ROOT_DIR" && zig build -Doptimize=ReleaseFast -Dcpu=native -Dno-plan=true --prefix "$NOPLAN_BUILD_DIR") || {
    echo "No-plan build failed" >&2
    exit 1
}
cp "$NOPLAN_BUILD_DIR/bin/zq" "$ZQ_NOPLAN"
echo "No-plan binary at: $ZQ_NOPLAN" >&2

DISPLAY_FILE=$(display_filename "$DATA_FILE")
FILE_SIZE=$(file_size_display "$DATA_FILE")
LINE_COUNT=$(wc -l < "$DATA_FILE")

# Pure-scalar selective predicate the harvester recognizes — yields a
# `ProjectionPlan { predicate: { op: .gt, ... } }` in the default
# build. The threshold is chosen so that ~25% of records pass; the
# other ~75% are dropped at the parser boundary in the default build,
# but reach the VM in the no-plan build. This shapes the attribution
# delta clearly without being so selective that the work is dominated
# by output formatting.
QUERY='.[] | select(.id > 11250000) | .id'

# Identity-stream variant for the verification step. zq's `.[]`
# emits scalars, but jq with the same query also iterates a single
# record-stream. EXPECTED_PASSED is recomputed from awk over the data
# file because the deterministic huge generator's id distribution is
# uniform 1..LINE_COUNT.
EXPECTED_PASSED=$(awk -F'"id":' 'NR > 0 { split($2, a, ","); if (a[1] + 0 > 11250000) c++ } END { print c }' "$DATA_FILE")

echo "# Scenario 7: Selective Query (Predicate Pushdown Attribution)" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Description:** Selective-filter throughput, comparing the default zq build (predicate pushed into the parser via \`feedPlanned\`) against the \`-Dno-plan=true\` attribution build (every record reaches the VM)." >> "$RESULT_FILE"
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

# Correctness verification — all tools must produce the same passing-
# record count. zq must produce the same count under both builds.
echo "## Correctness" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

CORRECT=true

if $HAVE_JQ; then
    verify_correctness "jq" "$EXPECTED_PASSED" jq -c "$QUERY" "$DATA_FILE" || CORRECT=false
fi
verify_correctness "zq (default)" "$EXPECTED_PASSED" "$ZQ_DEFAULT" -c "$QUERY" "$DATA_FILE" || CORRECT=false
verify_correctness "zq (no-plan)" "$EXPECTED_PASSED" "$ZQ_NOPLAN" -c "$QUERY" "$DATA_FILE" || CORRECT=false

if $CORRECT; then
    echo "All tools verified: $EXPECTED_PASSED records pass the predicate." >> "$RESULT_FILE"
else
    echo "**WARNING:** Some tools produced incorrect output — see stderr." >> "$RESULT_FILE"
fi
echo "" >> "$RESULT_FILE"

# Build hyperfine command — three runners: jq, zq-default, zq-noplan.
# Single hyperfine invocation so the run order is interleaved (better
# noise rejection than three separate sessions).
HYPERFINE_ARGS=(
    --warmup "$HYPERFINE_WARMUP" --runs "$HYPERFINE_RUNS"
    --export-markdown "$RESULTS_DIR/07_selective_query_raw.md"
    --export-json "$JSON_FILE"
)

if $HAVE_JQ; then
    HYPERFINE_ARGS+=(--command-name jq "jq -c '$QUERY' '$DATA_FILE' > /dev/null")
fi
HYPERFINE_ARGS+=(--command-name "zq-default" "'$ZQ_DEFAULT' -c '$QUERY' '$DATA_FILE' > /dev/null")
HYPERFINE_ARGS+=(--command-name "zq-noplan"  "'$ZQ_NOPLAN' -c '$QUERY' '$DATA_FILE' > /dev/null")

echo "" >&2
start_phase_timer "Hyperfine benchmark (selective query — pushdown attribution)"
hyperfine "${HYPERFINE_ARGS[@]}" | tee -a "$RESULT_FILE"
end_phase_timer "Hyperfine benchmark"

echo "Benchmark results saved to: $RESULT_FILE" >&2
