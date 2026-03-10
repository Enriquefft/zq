#!/bin/bash
# Scenario 4: Fault Tolerance Metric
# Compare recovery rate on malformed/incomplete streams
# Narrative: "LLMs hallucinate. They cut off JSON. jq dies. zq survives."

set -e

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MALFORMED_FILE="$BENCHMARK_DIR/data/malformed.jsonl"
RESULT_FILE="$BENCHMARK_DIR/results/04_fault_tolerance.md"

# Source progress utilities
source "$BENCHMARK_DIR/progress.sh"

mkdir -p "$BENCHMARK_DIR/results"

echo "# Scenario 4: Fault Tolerance" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Narrative:** LLMs hallucinate. They cut off JSON. jq dies. zq survives." >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

# Check if malformed file exists, generate if needed
if [ ! -f "$MALFORMED_FILE" ]; then
    echo "Generating malformed test dataset..." >&2
    bash "$BENCHMARK_DIR/data/malformed.generator.sh"
    mv malformed.jsonl "$MALFORMED_FILE"
fi

TOTAL_LINES=$(wc -l < "$MALFORMED_FILE")
VALID_RECORDS=$(jq -c '.' "$MALFORMED_FILE" 2>/dev/null | wc -l)
INVALID_RECORDS=$(( TOTAL_LINES - VALID_RECORDS ))

echo "## Test Details" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "- **File:** \`$MALFORMED_FILE\`" >> "$RESULT_FILE"
echo "- **Total lines:** $TOTAL_LINES" >> "$RESULT_FILE"
echo "- **Valid records:** $VALID_RECORDS" >> "$RESULT_FILE"
echo "- **Invalid records:** $INVALID_RECORDS (truncated/malformed JSON)" >> "$RESULT_FILE"
echo "- **Query:** \`.valid\` (extract valid field)" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "## Warning" >> "$RESULT_FILE"
    echo "jq not found. Skipping jq comparison." >> "$RESULT_FILE"
    echo "" >> "$RESULT_FILE"
    SKIP_JQ=true
fi

# Check if jaq is available
if ! command -v jaq &> /dev/null; then
    echo "## Warning" >> "$RESULT_FILE"
    echo "jaq not found. Skipping jaq comparison." >> "$RESULT_FILE"
    echo "" >> "$RESULT_FILE"
    SKIP_JAQ=true
fi

# Check if yq is available
if ! command -v yq &> /dev/null; then
    echo "## Warning" >> "$RESULT_FILE"
    echo "yq not found. Skipping yq comparison." >> "$RESULT_FILE"
    echo "" >> "$RESULT_FILE"
    SKIP_YQ=true
fi

# Check if zq is built
if ! command -v "$BENCHMARK_DIR/../zig-out/bin/zq" &> /dev/null; then
    echo "## Error" >> "$RESULT_FILE"
    echo "zq not found. Build with: \`zig build\`" >> "$RESULT_FILE"
    echo "" >> "$RESULT_FILE"
    cat "$RESULT_FILE"
    exit 1
fi

echo "## Results" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

# Results are stored here for dynamic analysis generation
declare -A TOOL_RECORDS
declare -A TOOL_EXIT

# Run a tool against the malformed file and report results.
# Stdout/stderr are captured separately so line counts are accurate.
run_fault_test() {
    local label="$1"; shift
    local cmd=("$@")

    echo "### $label" >> "$RESULT_FILE"
    echo "\`\`\`" >> "$RESULT_FILE"
    start_phase_timer "Testing $label fault tolerance"

    local tmp_out; tmp_out=$(mktemp)
    local tmp_err; tmp_err=$(mktemp)

    set +e
    "${cmd[@]}" > "$tmp_out" 2> "$tmp_err"
    local exit_code=$?
    set -e

    local lines_out; lines_out=$(wc -l < "$tmp_out")
    local pct=$(( VALID_RECORDS > 0 ? lines_out * 100 / VALID_RECORDS : 0 ))

    echo "Exit code:      $exit_code" >> "$RESULT_FILE"
    echo "Records output: $lines_out / $VALID_RECORDS valid ($pct% recovery)" >> "$RESULT_FILE"
    if [ -s "$tmp_err" ]; then
        echo "Errors (stderr):" >> "$RESULT_FILE"
        head -5 "$tmp_err" >> "$RESULT_FILE"
    fi

    TOOL_RECORDS["$label"]=$lines_out
    TOOL_EXIT["$label"]=$exit_code

    rm -f "$tmp_out" "$tmp_err"
    end_phase_timer "Testing $label fault tolerance"
    echo "\`\`\`" >> "$RESULT_FILE"
    echo "" >> "$RESULT_FILE"
}

[ "$SKIP_JQ"  != true ] && run_fault_test "jq"  jq  '.valid' "$MALFORMED_FILE"
[ "$SKIP_JAQ" != true ] && run_fault_test "jaq" jaq '.valid' "$MALFORMED_FILE"
[ "$SKIP_YQ"  != true ] && run_fault_test "yq"  yq  '.valid' "$MALFORMED_FILE"
run_fault_test "zq" timeout 30 "$BENCHMARK_DIR/../zig-out/bin/zq" '.valid' "$MALFORMED_FILE"

# Generate analysis dynamically from captured results
echo "## Analysis" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Recovery Rate = Records Output / Valid Records × 100%**" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "| Tool | Records Output | Valid Records | Recovery | Exit Code |" >> "$RESULT_FILE"
echo "|------|---------------|---------------|----------|-----------|" >> "$RESULT_FILE"
for tool in jq jaq yq zq; do
    if [ -n "${TOOL_RECORDS[$tool]+x}" ]; then
        local_records=${TOOL_RECORDS[$tool]}
        local_exit=${TOOL_EXIT[$tool]}
        local_pct=$(( VALID_RECORDS > 0 ? local_records * 100 / VALID_RECORDS : 0 ))
        printf "| %-4s | %-13s | %-13s | %-8s | %-9s |\n" \
            "$tool" "$local_records" "$VALID_RECORDS" "${local_pct}%" "$local_exit" >> "$RESULT_FILE"
    fi
done
echo "" >> "$RESULT_FILE"
echo "**Why this matters:**" >> "$RESULT_FILE"
echo "- LLMs frequently generate incomplete or malformed JSON" >> "$RESULT_FILE"
echo "- Network streams can be cut off mid-record" >> "$RESULT_FILE"
echo "- Logs from distributed systems often contain corrupted entries" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "Benchmark results saved to: $RESULT_FILE" >&2
cat "$RESULT_FILE"
