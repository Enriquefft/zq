#!/bin/bash
# Shared configuration and helpers for benchmark scenarios
# Source this from all scenario scripts: source "$BENCHMARK_DIR/common.sh"

set -o pipefail

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$BENCHMARK_DIR/.." && pwd)"
ZQ="$ROOT_DIR/zig-out/bin/zq"
DATA_DIR="$BENCHMARK_DIR/data"
RESULTS_DIR="$BENCHMARK_DIR/results"

# Source progress utilities
source "$BENCHMARK_DIR/progress.sh"

# Quick mode reduces statistical rigor for faster iteration
if [ "${ZQ_QUICK:-0}" = "1" ]; then
    HYPERFINE_WARMUP=1
    HYPERFINE_RUNS=3
    HYPERFINE_RUNS_COLD=10
    MEMORY_RUNS=1
else
    HYPERFINE_WARMUP=2
    HYPERFINE_RUNS=10
    HYPERFINE_RUNS_COLD=100
    MEMORY_RUNS=3
fi

# BENCH_MODE selects which comparison tools participate.
#   regression  — only zq + jq (jq used as noise-normalization baseline)
#   comparison  — zq vs jq + jaq + gojq + yq (full marketing comparison)
BENCH_MODE="${BENCH_MODE:-comparison}"

HAVE_JQ=false
HAVE_JAQ=false
HAVE_GOJQ=false
HAVE_YQ=false

detect_tools() {
    command -v jq &>/dev/null && HAVE_JQ=true || echo "Warning: jq not found, skipping." >&2

    if [ "$BENCH_MODE" = "regression" ]; then
        # External tools are pinned and don't change between commits;
        # running them every CI burns time without adding signal.
        return
    fi

    command -v jaq &>/dev/null && HAVE_JAQ=true || echo "Warning: jaq not found, skipping." >&2
    command -v gojq &>/dev/null && HAVE_GOJQ=true || echo "Warning: gojq not found, skipping." >&2
    command -v yq &>/dev/null && HAVE_YQ=true || echo "Warning: yq not found, skipping." >&2
}

# Check that zq binary exists
require_zq() {
    if [ ! -x "$ZQ" ]; then
        echo "Error: zq not found at $ZQ. Build with: zig build -Doptimize=ReleaseFast" >&2
        exit 1
    fi
}

# Check that hyperfine is available
require_hyperfine() {
    if ! command -v hyperfine &>/dev/null; then
        echo "Error: hyperfine not found. Install with: cargo install hyperfine" >&2
        exit 1
    fi
}

# Check that a data file exists
require_data() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "Error: $file not found. Run data/huge.generator.sh first." >&2
        exit 1
    fi
}

# Verify correctness: run a command, count output lines, compare to expected
# Usage: verify_correctness "label" expected_lines cmd [args...]
# Returns 0 on match, 1 on mismatch (prints warning but does not exit)
verify_correctness() {
    local label="$1"
    local expected="$2"
    shift 2

    local actual
    actual=$("$@" 2>/dev/null | wc -l)

    if [ "$actual" -ne "$expected" ]; then
        echo "WARNING: $label produced $actual lines, expected $expected — WRONG OUTPUT" >&2
        return 1
    fi
    return 0
}

# Get display filename (basename only, no absolute paths)
display_filename() {
    echo "${1##*/}"
}

# Display file size deterministically via stat (avoids non-deterministic du -h)
file_size_display() {
    local bytes
    bytes=$(stat --format='%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null)
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(( bytes / 1073741824 ))G"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(( bytes / 1048576 ))M"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(( bytes / 1024 ))K"
    else
        echo "${bytes}B"
    fi
}
