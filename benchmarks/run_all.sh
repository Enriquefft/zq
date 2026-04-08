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

TOTAL_SCENARIOS=5

# Initialize main progress bar
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

# Scenario 1
start_phase_timer "Multi-core Scalability"
bash "$BENCHMARK_DIR/scenarios/01_parallelism.sh"
end_phase_timer "Multi-core Scalability"
update_main_progress 1 $TOTAL_SCENARIOS "Multi-core Scalability"
echo "" >> "$SUMMARY_FILE"
echo "## Scenario 1: Multi-core Scalability" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"
echo "Full results: [01_parallelism.md](01_parallelism.md)" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

# Scenario 2
start_phase_timer "Memory Efficiency"
bash "$BENCHMARK_DIR/scenarios/02_memory.sh"
end_phase_timer "Memory Efficiency"
update_main_progress 2 $TOTAL_SCENARIOS "Memory Efficiency"
echo "" >> "$SUMMARY_FILE"
echo "## Scenario 2: Memory Efficiency" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"
echo "Full results: [02_memory.md](02_memory.md)" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

# Scenario 3
start_phase_timer "Startup Latency"
bash "$BENCHMARK_DIR/scenarios/03_startup_latency.sh"
end_phase_timer "Startup Latency"
update_main_progress 3 $TOTAL_SCENARIOS "Startup Latency"
echo "" >> "$SUMMARY_FILE"
echo "## Scenario 3: Startup Latency" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"
echo "Full results: [03_startup_latency.md](03_startup_latency.md)" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

# Scenario 4
start_phase_timer "Streaming Throughput"
bash "$BENCHMARK_DIR/scenarios/04_streaming.sh"
end_phase_timer "Streaming Throughput"
update_main_progress 4 $TOTAL_SCENARIOS "Streaming Throughput"
echo "" >> "$SUMMARY_FILE"
echo "## Scenario 4: Streaming/Pipe Throughput" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"
echo "Full results: [04_streaming.md](04_streaming.md)" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

# Scenario 5
start_phase_timer "Complex Query"
bash "$BENCHMARK_DIR/scenarios/05_complex_query.sh"
end_phase_timer "Complex Query"
update_main_progress 5 $TOTAL_SCENARIOS "Complex Query"
echo "" >> "$SUMMARY_FILE"
echo "## Scenario 5: Complex Query" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"
echo "Full results: [05_complex_query.md](05_complex_query.md)" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

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

    # Memory (uses wall clock time from our custom JSON)
    M_ZQ=$(extract_mean "$BENCHMARK_DIR/results/02_memory.json" "zq")
    M_JQ=$(extract_mean "$BENCHMARK_DIR/results/02_memory.json" "jq")
    printf '    "memory": {"zq_mean_s": %s, "jq_mean_s": %s},\n' "${M_ZQ:-null}" "${M_JQ:-null}"

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
