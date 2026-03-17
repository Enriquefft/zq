#!/bin/bash
# Benchmark regression detection (ratio-based)
# Compares zq_mean/jq_mean ratio against baseline ratio.
# Both tools run on the same machine, so noisy neighbors affect them equally.
# Usage: ./check_regression.sh current.json baseline.json
# Exits 1 if any scenario regresses > 15% relative to baseline ratio

set -e
set -o pipefail

CURRENT="$1"
BASELINE="$2"
THRESHOLD=15

if [ -z "$CURRENT" ] || [ -z "$BASELINE" ]; then
    echo "Usage: $0 <current-summary.json> <baseline.json>" >&2
    exit 2
fi

if [ ! -f "$CURRENT" ]; then
    echo "Error: current results file not found: $CURRENT" >&2
    exit 2
fi

if [ ! -f "$BASELINE" ]; then
    echo "No baseline found at $BASELINE — skipping regression check (first run)" >&2
    exit 0
fi

FAILED=0

# Compare zq/jq ratio against baseline ratio
# Usage: check_scenario "scenario_name" "zq_key" "jq_key"
check_scenario() {
    local name="$1"
    local zq_key="$2"
    local jq_key="$3"

    local cur_zq cur_jq base_zq base_jq
    cur_zq=$(jq -r "$zq_key" "$CURRENT" 2>/dev/null)
    cur_jq=$(jq -r "$jq_key" "$CURRENT" 2>/dev/null)
    base_zq=$(jq -r "$zq_key" "$BASELINE" 2>/dev/null)
    base_jq=$(jq -r "$jq_key" "$BASELINE" 2>/dev/null)

    # Skip if any value is missing
    for val in "$cur_zq" "$cur_jq" "$base_zq" "$base_jq"; do
        if [ "$val" = "null" ] || [ -z "$val" ]; then
            echo "SKIP: $name — incomplete data"
            return
        fi
    done

    local result
    result=$(awk -v cz="$cur_zq" -v cj="$cur_jq" -v bz="$base_zq" -v bj="$base_jq" -v thresh="$THRESHOLD" '
    BEGIN {
        if (cj > 0 && bj > 0) {
            cur_ratio = cz / cj
            base_ratio = bz / bj
            if (base_ratio > 0) {
                change = (cur_ratio - base_ratio) / base_ratio * 100
                is_reg = (change > thresh) ? 1 : 0
                printf "%s %.3f %.3f %.1f", (is_reg ? "REGRESSION" : "OK"), cur_ratio, base_ratio, change
            } else {
                print "SKIP 0 0 0"
            }
        } else {
            print "SKIP 0 0 0"
        }
    }')

    local status cur_ratio base_ratio change
    read -r status cur_ratio base_ratio change <<< "$result"

    if [ "$status" = "SKIP" ]; then
        echo "SKIP: $name — zero jq baseline"
        return
    fi

    if [ "$status" = "REGRESSION" ]; then
        echo "REGRESSION: $name — ratio ${cur_ratio} vs baseline ${base_ratio} (${change}% worse)"
        FAILED=1
    else
        echo "OK: $name — ratio ${cur_ratio} vs baseline ${base_ratio} (${change}% change)"
    fi
}

echo "Benchmark Regression Check (ratio-based, threshold: ${THRESHOLD}%)"
echo "==================================================================="
echo ""

check_scenario "parallelism"     ".scenarios.parallelism.zq_mean_s"     ".scenarios.parallelism.jq_mean_s"
check_scenario "streaming"       ".scenarios.streaming.zq_mean_s"       ".scenarios.streaming.jq_mean_s"
check_scenario "startup_latency" ".scenarios.startup_latency.zq_mean_s" ".scenarios.startup_latency.jq_mean_s"
check_scenario "complex_query"   ".scenarios.complex_query.zq_mean_s"   ".scenarios.complex_query.jq_mean_s"

echo ""

if [ "$FAILED" -eq 1 ]; then
    echo "FAILED: Performance regression detected (>${THRESHOLD}% ratio degradation)"
    exit 1
else
    echo "PASSED: No significant regressions detected"
    exit 0
fi
