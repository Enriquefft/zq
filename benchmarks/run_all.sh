#!/bin/bash
# Orchestrate all benchmark scenarios and generate summary report

set -e
set -o pipefail

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMARY_FILE="$BENCHMARK_DIR/results/SUMMARY.md"
TIMESTAMP=$(date -u +"%Y%m%d_%H%M%S")

# Parse flags — honor the environment variable if already set, then allow
# the --quick command-line flag to override.
ZQ_QUICK="${ZQ_QUICK:-0}"
for arg in "$@"; do
    case "$arg" in
        --quick) ZQ_QUICK=1 ;;
    esac
done
export ZQ_QUICK

# Source progress utilities
source "$BENCHMARK_DIR/progress.sh"

# All five scenarios run in both modes. Regression mode consumes 02_memory's
# peak-RSS reading via check_regression.sh's absolute-ceiling gate, so the
# memory scenario is no longer optional.
BENCH_MODE="${BENCH_MODE:-comparison}"
TOTAL_SCENARIOS=5

init_main_progress

echo "" >&2
echo "Started: $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >&2
echo "" >&2

# Check prerequisites
echo "Checking prerequisites..." >&2

MISSING_REQUIRED=()

if ! command -v hyperfine &> /dev/null; then
    MISSING_REQUIRED+=("hyperfine (install: cargo install hyperfine)")
fi

if ! command -v jq &> /dev/null; then
    MISSING_REQUIRED+=("jq (install: package manager)")
fi

if [ ${#MISSING_REQUIRED[@]} -gt 0 ]; then
    echo "Missing required tools:" >&2
    for tool in "${MISSING_REQUIRED[@]}"; do
        echo "  - $tool" >&2
    done
    exit 1
fi

# Optional comparison tools — warn but continue
command -v jaq &> /dev/null || echo "Note: jaq not found, skipping jaq comparisons." >&2
command -v gojq &> /dev/null || echo "Note: gojq not found, skipping gojq comparisons." >&2

echo "All prerequisites found!" >&2
echo "" >&2

echo "Building zq (ReleaseFast, native CPU)..." >&2
(cd "$BENCHMARK_DIR/.." && zig build -Doptimize=ReleaseFast -Dcpu=native) || {
    echo "Build failed" >&2
    exit 1
}
echo "Build complete." >&2
echo "" >&2

# Clean previous results
echo "Cleaning previous results..." >&2
rm -rf "$BENCHMARK_DIR/results"/*.md
rm -rf "$BENCHMARK_DIR/results"/*.csv
echo "Done." >&2
echo "" >&2

# Create results directory
mkdir -p "$BENCHMARK_DIR/results"

# Initialize summary report
cat > "$SUMMARY_FILE" << EOF
# zq Benchmark Suite Summary

**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")

This report summarizes benchmark results comparing zq against jq across 5 key scenarios.

---

## Test Environment

EOF

# Capture system info
echo "\`\`\`" >> "$SUMMARY_FILE"
echo "OS: $(uname -s) $(uname -r)" >> "$SUMMARY_FILE"
echo "CPU: $(lscpu | grep 'Model name' | head -1 | cut -d':' -f2 | xargs)" >> "$SUMMARY_FILE"
echo "Cores: $(nproc)" >> "$SUMMARY_FILE"
echo "Memory: $(free -h | grep Mem | awk '{print $2}')" >> "$SUMMARY_FILE"
echo "\`\`\`" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

echo "---" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

# Run each scenario
echo "Running benchmarks..." >&2

echo "" >> "$SUMMARY_FILE"

SCENARIO_IDX=0

run_scenario() {
    local label="$1" script="$2" md="$3"
    SCENARIO_IDX=$((SCENARIO_IDX + 1))
    start_phase_timer "$label"
    bash "$BENCHMARK_DIR/scenarios/$script"
    end_phase_timer "$label"
    update_main_progress $SCENARIO_IDX $TOTAL_SCENARIOS "$label"
    {
        echo ""
        echo "## $label"
        echo ""
        echo "Full results: [$md]($md)"
        echo ""
    } >> "$SUMMARY_FILE"
}

run_scenario "Multi-core Scalability" "01_parallelism.sh" "01_parallelism.md"
run_scenario "Memory Efficiency"      "02_memory.sh"          "02_memory.md"
run_scenario "Startup Latency"        "03_startup_latency.sh" "03_startup_latency.md"
run_scenario "Streaming Throughput"   "04_streaming.sh"       "04_streaming.md"
run_scenario "Complex Query"          "05_complex_query.sh"   "05_complex_query.md"

echo "" >&2

# Generate machine-readable summary.json from per-scenario JSON exports
SUMMARY_JSON="$BENCHMARK_DIR/results/summary.json"

# Helper: extract mean for a command from a hyperfine JSON export
extract_mean() {
    local json_file="$1" cmd_name="$2"
    if [ -f "$json_file" ]; then
        jq -r --arg cmd "$cmd_name" '.results[] | select(.command == $cmd) | .mean // empty' "$json_file" 2>/dev/null
    fi
}

# Helper: extract a numeric per-command field (e.g. max_rss_kb) from 02_memory.json
extract_field() {
    local json_file="$1" cmd_name="$2" field="$3"
    if [ -f "$json_file" ]; then
        jq -r --arg cmd "$cmd_name" --arg f "$field" \
            '.results[] | select(.command == $cmd) | .[$f] // empty' "$json_file" 2>/dev/null
    fi
}

# Helper: extract a top-level scalar (e.g. input_size_kb) from 02_memory.json
extract_top() {
    local json_file="$1" field="$2"
    if [ -f "$json_file" ]; then
        jq -r --arg f "$field" '.[$f] // empty' "$json_file" 2>/dev/null
    fi
}

# Build summary JSON
{
    cat <<HEADER
{
  "version": "1.0",
  "date": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "scenarios": {
HEADER

    # Parallelism
    P_ZQ=$(extract_mean "$BENCHMARK_DIR/results/01_parallelism.json" "zq")
    P_JQ=$(extract_mean "$BENCHMARK_DIR/results/01_parallelism.json" "jq")
    printf '    "parallelism": {"zq_mean_s": %s, "jq_mean_s": %s},\n' "${P_ZQ:-null}" "${P_JQ:-null}"

    # Memory: wall-clock means + peak RSS (additive, non-breaking schema).
    # input_size_kb is captured at measurement time so the regression gate
    # computes RSS-per-input on the file the run actually saw.
    M_JSON="$BENCHMARK_DIR/results/02_memory.json"
    M_ZQ=$(extract_mean  "$M_JSON" "zq")
    M_JQ=$(extract_mean  "$M_JSON" "jq")
    M_ZQ_RSS=$(extract_field "$M_JSON" "zq" "max_rss_kb")
    M_JQ_RSS=$(extract_field "$M_JSON" "jq" "max_rss_kb")
    M_INPUT_KB=$(extract_top "$M_JSON" "input_size_kb")
    printf '    "memory": {"zq_mean_s": %s, "jq_mean_s": %s, "zq_max_rss_kb": %s, "jq_max_rss_kb": %s, "input_size_kb": %s},\n' \
        "${M_ZQ:-null}" "${M_JQ:-null}" "${M_ZQ_RSS:-null}" "${M_JQ_RSS:-null}" "${M_INPUT_KB:-null}"

    # Startup latency
    SL_ZQ=$(extract_mean "$BENCHMARK_DIR/results/03_startup_latency.json" "zq")
    SL_JQ=$(extract_mean "$BENCHMARK_DIR/results/03_startup_latency.json" "jq")
    printf '    "startup_latency": {"zq_mean_s": %s, "jq_mean_s": %s},\n' "${SL_ZQ:-null}" "${SL_JQ:-null}"

    # Streaming
    ST_ZQ=$(extract_mean "$BENCHMARK_DIR/results/04_streaming.json" "zq")
    ST_JQ=$(extract_mean "$BENCHMARK_DIR/results/04_streaming.json" "jq")
    printf '    "streaming": {"zq_mean_s": %s, "jq_mean_s": %s},\n' "${ST_ZQ:-null}" "${ST_JQ:-null}"

    # Complex query
    CQ_ZQ=$(extract_mean "$BENCHMARK_DIR/results/05_complex_query.json" "zq")
    CQ_JQ=$(extract_mean "$BENCHMARK_DIR/results/05_complex_query.json" "jq")
    printf '    "complex_query": {"zq_mean_s": %s, "jq_mean_s": %s}\n' "${CQ_ZQ:-null}" "${CQ_JQ:-null}"

    echo '  }'
    echo '}'
} > "$SUMMARY_JSON"

# Validate the generated JSON
if jq . "$SUMMARY_JSON" > /dev/null 2>&1; then
    echo "Summary JSON validated: $SUMMARY_JSON" >&2
else
    echo "WARNING: summary.json is not valid JSON" >&2
fi

# Add final summary
cat >> "$SUMMARY_FILE" << EOF

---

## Test Scenarios

This benchmark suite includes five test scenarios:

1. **Multi-core Scalability**: Throughput on large-scale batch processing
2. **Memory Efficiency**: Resource footprint during streaming operations
3. **Startup Latency**: Process initialization overhead
4. **Streaming Throughput**: Pipe-based stdin processing performance
5. **Complex Query**: Real-world transformation with multiple operators

---

*Generated by zq benchmark suite*
EOF

echo -e "${COLOR_CYAN}+=========================================================+${COLOR_RESET}" >&2
echo -e "${COLOR_CYAN}|                  Benchmarks Complete!                   |${COLOR_RESET}" >&2
echo -e "${COLOR_CYAN}+=========================================================+${COLOR_RESET}" >&2
echo "" >&2
echo "  Finished: $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >&2
echo "" >&2
echo "  Results:" >&2
echo "    01_parallelism.md      — Multi-core Scalability" >&2
echo "    02_memory.md           — Memory Efficiency" >&2
echo "    03_startup_latency.md  — Startup Latency" >&2
echo "    04_streaming.md        — Streaming Throughput" >&2
echo "    05_complex_query.md    — Complex Query" >&2
echo "" >&2
echo "  Full Summary: $SUMMARY_FILE" >&2
echo "" >&2
