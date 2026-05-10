#!/bin/bash
# Scenario 8: Selective Query (Wide Records) — Predicate-Pushdown Attribution
# Mirror of scenario 7 (`07_selective_query.sh`) but on huge_wide.jsonl
# (~50-field, ~1KB-per-line records). Same shape: zq default vs zq
# `-Dno-plan=true` vs jq, all running the same selective-filter query.
#
# Why the wide variant. On narrow records (huge.jsonl, ~80 byte mean
# line) the per-record VM body is short, so the predicate-pushdown
# speedup attributed by scenario 7 is bounded above by ~1.05x even
# when the harvester accepts the shape — there's not much VM work to
# skip. Wide records shift the balance: the per-record parse cost is
# amortized over ~1 KB of bytes, but every dropped record skips the
# full VM body whose work scales with field count. The default→no-plan
# ratio measured here is the load-bearing attribution for the C1
# predicate-pushdown work on realistic per-record-cost workloads.
#
# Informational only — `check_regression.sh` logs the
# `wide_selective_attribution` ratio without a hard threshold. Hardware
# variance and field-count drift in the generator make a fixed ratio
# unstable across CI runners; the *direction* (default ≤ no-plan) is
# the invariant we care about, and any flip would already be caught by
# the property test's byte-eq invariant.

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
detect_tools

# We need both binaries: the production zq (already at zig-out/bin/zq)
# and a no-plan build for attribution. Build the latter to a sibling
# path so the production binary is unaffected. Reuse the no-plan binary
# from scenario 7 if it already exists in zig-out/bin/zq-noplan, since
# both scenarios share the same `-Dno-plan=true` build artifact.
ZQ_DEFAULT="$ROOT_DIR/zig-out/bin/zq"
ZQ_NOPLAN="$ROOT_DIR/zig-out/bin/zq-noplan"

if [ ! -x "$ZQ_DEFAULT" ]; then
    echo "Error: default zq not found at $ZQ_DEFAULT. Build with: zig build -Doptimize=ReleaseFast" >&2
    exit 1
fi

if [ ! -x "$ZQ_NOPLAN" ]; then
    echo "Building no-plan attribution binary (-Dno-plan=true)..." >&2
    NOPLAN_BUILD_DIR=$(mktemp -d)
    trap 'rm -rf "$NOPLAN_BUILD_DIR"' EXIT
    (cd "$ROOT_DIR" && zig build -Doptimize=ReleaseFast -Dcpu=native -Dno-plan=true --prefix "$NOPLAN_BUILD_DIR") || {
        echo "No-plan build failed" >&2
        exit 1
    }
    cp "$NOPLAN_BUILD_DIR/bin/zq" "$ZQ_NOPLAN"
fi
echo "No-plan binary at: $ZQ_NOPLAN" >&2

DISPLAY_FILE=$(display_filename "$DATA_FILE")
FILE_SIZE=$(file_size_display "$DATA_FILE")
LINE_COUNT=$(wc -l < "$DATA_FILE")

# Threshold derived from LINE_COUNT for ~25% selectivity. The wide
# generator emits ids 1..LINE_COUNT, so any threshold expressed as a
# fraction lands the same selectivity regardless of HUGE_WIDE_LINES.
THRESHOLD=$(( LINE_COUNT * 3 / 4 ))

# Pure-scalar selective predicate the harvester recognizes — the same
# select-rooted shape as scenario 7 so the attribution is directly
# comparable. The strip transform (Task A) runs on this shape: the
# IR root replaces `select(...)` with identity, so kept records flow
# through `Op.identity` → `push_current` rather than re-evaluating
# the predicate body.
QUERY="select(.id > $THRESHOLD)"

# EXPECTED_PASSED computed by awk over the data file. The id is the
# first field in every record so `awk -F'"id":'` then split on `,`
# extracts it without parsing the rest of the line.
EXPECTED_PASSED=$(awk -F'"id":' -v t="$THRESHOLD" 'BEGIN { c = 0 } NR > 0 { split($2, a, ","); if (a[1] + 0 > t) c++ } END { print c }' "$DATA_FILE")

echo "# Scenario 8: Selective Query — Wide Records (Predicate Pushdown Attribution)" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Description:** Selective-filter throughput on wide records (~50 fields, ~1KB/line), comparing the default zq build (predicate pushed into the parser via \`feedPlanned\`, \`select(...)\` root stripped to identity at compile time) against the \`-Dno-plan=true\` attribution build (every record reaches the VM with its full predicate body intact). Counterpart to scenario 7 on narrow records." >> "$RESULT_FILE"
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
    --export-markdown "$RESULTS_DIR/08_selective_wide_raw.md"
    --export-json "$JSON_FILE"
)

if $HAVE_JQ; then
    HYPERFINE_ARGS+=(--command-name jq "jq -c '$QUERY' '$DATA_FILE' > /dev/null")
fi
HYPERFINE_ARGS+=(--command-name "zq-default" "'$ZQ_DEFAULT' -c '$QUERY' '$DATA_FILE' > /dev/null")
HYPERFINE_ARGS+=(--command-name "zq-noplan"  "'$ZQ_NOPLAN' -c '$QUERY' '$DATA_FILE' > /dev/null")

echo "" >&2
start_phase_timer "Hyperfine benchmark (selective query — wide records — pushdown attribution)"
hyperfine "${HYPERFINE_ARGS[@]}" | tee -a "$RESULT_FILE"
end_phase_timer "Hyperfine benchmark"

echo "Benchmark results saved to: $RESULT_FILE" >&2
