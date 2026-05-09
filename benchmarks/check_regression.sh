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

# Peak-RSS gate (zq only). Two checks fire independently; either tripping
# fails CI.
#
#   RSS_CEILING_PCT  — hard absolute ceiling expressed as zq_max_rss_kb /
#                      input_size_kb. README publishes "0.31x input RSS"
#                      (440 MB on 1.3 GB). Local measurement on the same
#                      input is ~0.34x. The ceiling sits at 0.40x — ~18%
#                      headroom over the live measurement, ~29% over the
#                      published claim. Tightens when README updates.
#
#   RSS_DELTA_PCT    — creeping-growth gate: zq peak RSS may not rise
#                      more than 25% vs the cached CI baseline. Catches
#                      drift even when the absolute ceiling still holds.
RSS_CEILING_PCT=40
RSS_DELTA_PCT=25

if [ -z "$CURRENT" ] || [ -z "$BASELINE" ]; then
    echo "Usage: $0 <current-summary.json> <baseline.json>" >&2
    exit 2
fi

if [ ! -f "$CURRENT" ]; then
    echo "Error: current results file not found: $CURRENT" >&2
    exit 2
fi

if [ ! -f "$BASELINE" ]; then
    echo "No baseline found at $BASELINE — skipping regression check (bootstrap run)"
    exit 0
fi

BASELINE_DATE=$(jq -r '.date // "unknown"' "$BASELINE" 2>/dev/null)
echo "Baseline from: $BASELINE_DATE"
echo ""

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

# RSS gate: absolute ceiling on zq_max_rss_kb / input_size_kb plus a delta
# gate vs baseline zq_max_rss_kb. RSS is a hard ceiling, not a moving
# target — perf commits that trade memory for speed must not breach the
# published RSS claim regardless of where the baseline drifted to.
check_rss() {
    local cur_rss cur_input base_rss
    cur_rss=$(jq -r '.scenarios.memory.zq_max_rss_kb // empty' "$CURRENT" 2>/dev/null)
    cur_input=$(jq -r '.scenarios.memory.input_size_kb // empty' "$CURRENT" 2>/dev/null)
    base_rss=$(jq -r '.scenarios.memory.zq_max_rss_kb // empty' "$BASELINE" 2>/dev/null)

    if [ -z "$cur_rss" ] || [ "$cur_rss" = "null" ] || \
       [ -z "$cur_input" ] || [ "$cur_input" = "null" ] || \
       [ "$cur_input" = "0" ]; then
        echo "SKIP: rss_absolute — current run missing zq_max_rss_kb or input_size_kb"
    else
        local abs_result
        abs_result=$(awk -v rss="$cur_rss" -v input="$cur_input" -v ceil="$RSS_CEILING_PCT" '
        BEGIN {
            pct = rss / input * 100
            is_breach = (pct > ceil) ? 1 : 0
            printf "%s %.1f", (is_breach ? "BREACH" : "OK"), pct
        }')
        local abs_status abs_pct
        read -r abs_status abs_pct <<< "$abs_result"
        if [ "$abs_status" = "BREACH" ]; then
            echo "REGRESSION: rss_absolute — zq peak RSS ${cur_rss} KB on ${cur_input} KB input = ${abs_pct}% (ceiling ${RSS_CEILING_PCT}%)"
            FAILED=1
        else
            echo "OK: rss_absolute — zq peak RSS ${abs_pct}% of input (ceiling ${RSS_CEILING_PCT}%)"
        fi
    fi

    if [ -z "$base_rss" ] || [ "$base_rss" = "null" ] || \
       [ -z "$cur_rss" ] || [ "$cur_rss" = "null" ] || \
       [ "$base_rss" = "0" ]; then
        echo "SKIP: rss_delta — baseline missing zq_max_rss_kb"
    else
        local delta_result
        delta_result=$(awk -v cur="$cur_rss" -v base="$base_rss" -v thresh="$RSS_DELTA_PCT" '
        BEGIN {
            change = (cur - base) / base * 100
            is_reg = (change > thresh) ? 1 : 0
            printf "%s %.1f", (is_reg ? "REGRESSION" : "OK"), change
        }')
        local delta_status delta_change
        read -r delta_status delta_change <<< "$delta_result"
        if [ "$delta_status" = "REGRESSION" ]; then
            echo "REGRESSION: rss_delta — zq peak RSS ${cur_rss} KB vs baseline ${base_rss} KB (${delta_change}% growth, threshold ${RSS_DELTA_PCT}%)"
            FAILED=1
        else
            echo "OK: rss_delta — zq peak RSS ${cur_rss} KB vs baseline ${base_rss} KB (${delta_change}% change)"
        fi
    fi
}

echo "Benchmark Regression Check (ratio-based, threshold: ${THRESHOLD}%)"
echo "==================================================================="
echo ""

check_scenario "parallelism"     ".scenarios.parallelism.zq_mean_s"     ".scenarios.parallelism.jq_mean_s"
check_scenario "streaming"       ".scenarios.streaming.zq_mean_s"       ".scenarios.streaming.jq_mean_s"
check_scenario "startup_latency" ".scenarios.startup_latency.zq_mean_s" ".scenarios.startup_latency.jq_mean_s"
check_scenario "complex_query"   ".scenarios.complex_query.zq_mean_s"   ".scenarios.complex_query.jq_mean_s"
check_rss

echo ""

if [ "$FAILED" -eq 1 ]; then
    echo "FAILED: Performance regression detected (>${THRESHOLD}% ratio degradation or RSS gate breach)"
    exit 1
else
    echo "PASSED: No significant regressions detected"
    exit 0
fi
