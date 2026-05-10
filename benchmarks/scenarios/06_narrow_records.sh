#!/bin/bash
# Scenario 6: Narrow Records — No-Plan Code Path Throughput
# Tests `.id` extraction on huge.jsonl, the canonical "no-plan" workload
# (simple identifier query the projection harvester emits no plan for).
# Acts as the runtime invariant guarding the no-plan parse loop after
# Commit 1: any throughput regression vs master ≥2% indicates the
# plan-aware path's coexistence with `feed` perturbed inlining or
# register allocation in a measurable way. The 06 ratio gate is the
# load-bearing safety net replacing the original byte-identity-via-
# objdump invariant (see commit message §β for rationale).

set -e
set -o pipefail

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BENCHMARK_DIR/common.sh"

DATA_FILE="$DATA_DIR/huge.jsonl"
RESULT_FILE="$RESULTS_DIR/06_narrow_records.md"
JSON_FILE="$RESULTS_DIR/06_narrow_records.json"

mkdir -p "$RESULTS_DIR"

require_data "$DATA_FILE"
require_hyperfine
require_zq
detect_tools

DISPLAY_FILE=$(display_filename "$DATA_FILE")
FILE_SIZE=$(file_size_display "$DATA_FILE")
LINE_COUNT=$(wc -l < "$DATA_FILE")

# Pure scalar identity at the top — emits no projection plan, exercises
# the no-plan `feed` body exclusively. This is the "narrow" baseline
# that all other workloads are compared against.
QUERY='.id'

echo "# Scenario 6: Narrow Records (No-Plan Code Path)" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Description:** Throughput of the no-plan parse path under a narrow scalar query (\`.id\`). Guards against regressions caused by plan-aware code coexisting with the master \`feed\` body." >> "$RESULT_FILE"
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

# Correctness: zq and jq must produce the same line count.
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
    --export-markdown "$RESULTS_DIR/06_narrow_records_raw.md"
    --export-json "$JSON_FILE"
)

if $HAVE_JQ; then
    HYPERFINE_ARGS+=(--command-name jq "jq -c '$QUERY' '$DATA_FILE' > /dev/null")
fi
if $HAVE_JAQ; then
    HYPERFINE_ARGS+=(--command-name jaq "jaq -c '$QUERY' '$DATA_FILE' > /dev/null")
fi
if $HAVE_GOJQ; then
    HYPERFINE_ARGS+=(--command-name gojq "gojq '$QUERY' '$DATA_FILE' > /dev/null")
fi
HYPERFINE_ARGS+=(--command-name zq "'$ZQ' -c '$QUERY' '$DATA_FILE' > /dev/null")

echo "" >&2
start_phase_timer "Hyperfine benchmark (narrow records — no-plan path)"
hyperfine "${HYPERFINE_ARGS[@]}" | tee -a "$RESULT_FILE"
end_phase_timer "Hyperfine benchmark"

echo "Benchmark results saved to: $RESULT_FILE" >&2
