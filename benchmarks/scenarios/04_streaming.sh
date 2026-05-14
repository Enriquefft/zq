#!/bin/bash
# Scenario 4: Three-mode streaming throughput (file-arg vs redirect vs pipe)
#
# Pins the post-Phase-1/2 invariant that:
#   - `zq < file`   (shell redirect, regular-file stdin) routes through the
#                   mmap/file path via `Pool.submit_source`. Should match
#                   `zq file` time within noise.
#   - `cat | zq`    (true pipe, ring-backed stdin) routes through the
#                   slot-pool stream path. Faster than pre-Phase-2 baseline
#                   thanks to the zero-copy InputSlotPool, but still
#                   irreducibly slower than mmap by the IO-thread CPU floor.
#
# Other tools are benchmarked in pipe mode only for ecosystem comparison.

set -e
set -o pipefail

BENCHMARK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BENCHMARK_DIR/common.sh"

DATA_FILE="$DATA_DIR/huge.jsonl"
RESULT_FILE="$RESULTS_DIR/04_streaming.md"
JSON_FILE="$RESULTS_DIR/04_streaming.json"

mkdir -p "$RESULTS_DIR"

require_data "$DATA_FILE"
require_hyperfine
require_zq
detect_tools

DISPLAY_FILE=$(display_filename "$DATA_FILE")
FILE_SIZE=$(file_size_display "$DATA_FILE")
LINE_COUNT=$(wc -l < "$DATA_FILE")

echo "# Scenario 4: Three-Mode Streaming Throughput" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "**Description:** Compares zq across three stdin-delivery modes (file-arg, shell-redirect, true-pipe) to verify Phase 1 (\`submit_source\` mmap dispatch) and Phase 2 (\`InputSlotPool\`) gains independently. Other tools are benchmarked in pipe mode only for ecosystem context." >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

echo "## Test Details" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "- **File:** \`$DISPLAY_FILE\`" >> "$RESULT_FILE"
echo "- **Size:** $FILE_SIZE" >> "$RESULT_FILE"
echo "- **Lines:** $LINE_COUNT" >> "$RESULT_FILE"
echo "- **Query:** \`.id\` (simple field extraction)" >> "$RESULT_FILE"
echo "- **Modes:**" >> "$RESULT_FILE"
echo "  - \`zq '.id' file\`     — file-arg (baseline mmap path)" >> "$RESULT_FILE"
echo "  - \`zq '.id' < file\`   — shell redirect (mmap-dispatch via \`submit_source\`)" >> "$RESULT_FILE"
echo "  - \`cat file | zq '.id'\` — true pipe (slot-pool stream path)" >> "$RESULT_FILE"
echo "- **Warmup runs:** $HYPERFINE_WARMUP" >> "$RESULT_FILE"
echo "- **Benchmark runs:** $HYPERFINE_RUNS" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

# Correctness verification: all three zq modes must produce identical
# byte-for-byte output (Phase 1 invariant), and all output one line per record.
echo "## Correctness" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

EXPECTED_LINES=$LINE_COUNT
CORRECT=true

verify_pipe() {
    local label="$1"; shift
    local actual
    actual=$(cat "$DATA_FILE" | "$@" 2>/dev/null | wc -l)
    if [ "$actual" -ne "$EXPECTED_LINES" ]; then
        echo "WARNING: $label pipe produced $actual lines, expected $EXPECTED_LINES" >&2
        return 1
    fi
    return 0
}

# Three-mode zq parity: all must produce identical output.
ZQ_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$ZQ_TMP_DIR"' EXIT

"$ZQ" '.id' "$DATA_FILE"        > "$ZQ_TMP_DIR/file.out"
"$ZQ" '.id'                    < "$DATA_FILE" > "$ZQ_TMP_DIR/redirect.out"
cat "$DATA_FILE" | "$ZQ" '.id'  > "$ZQ_TMP_DIR/pipe.out"

if ! cmp -s "$ZQ_TMP_DIR/file.out" "$ZQ_TMP_DIR/redirect.out"; then
    echo "WARNING: zq file-arg and redirect modes differ" >&2
    CORRECT=false
fi
if ! cmp -s "$ZQ_TMP_DIR/file.out" "$ZQ_TMP_DIR/pipe.out"; then
    echo "WARNING: zq file-arg and pipe modes differ" >&2
    CORRECT=false
fi

# Competitor correctness in pipe mode only. Uses `if $HAVE_X; then ... fi`
# because the more compact `$HAVE_X && verify || CORRECT=false` pattern fires
# the `|| CORRECT=false` arm when `$HAVE_X` is false, falsely flagging
# correctness failure on systems without the competitor installed.
if $HAVE_JQ;   then verify_pipe "jq"   jq '.id'     || CORRECT=false; fi
if $HAVE_JAQ;  then verify_pipe "jaq"  jaq -c '.id' || CORRECT=false; fi
if $HAVE_GOJQ; then verify_pipe "gojq" gojq '.id'   || CORRECT=false; fi

if $CORRECT; then
    echo "All zq modes produce byte-identical output ($EXPECTED_LINES lines)." >> "$RESULT_FILE"
    echo "All competitors verified in pipe mode." >> "$RESULT_FILE"
else
    echo "**WARNING:** Output mismatch — see stderr." >> "$RESULT_FILE"
fi
echo "" >> "$RESULT_FILE"

# Build hyperfine command. zq gets three named modes; competitors stay in pipe.
HYPERFINE_ARGS=(
    --warmup "$HYPERFINE_WARMUP" --runs "$HYPERFINE_RUNS"
    --export-markdown "$RESULTS_DIR/04_streaming_raw.md"
    --export-json "$JSON_FILE"
)

HYPERFINE_ARGS+=(--command-name "zq (file-arg)"    "'$ZQ' '.id' '$DATA_FILE' > /dev/null")
HYPERFINE_ARGS+=(--command-name "zq (< redirect)"  "'$ZQ' '.id' < '$DATA_FILE' > /dev/null")
HYPERFINE_ARGS+=(--command-name "zq (cat | pipe)"  "cat '$DATA_FILE' | '$ZQ' '.id' > /dev/null")

if $HAVE_JQ; then
    HYPERFINE_ARGS+=(--command-name "jq (cat | pipe)" "cat '$DATA_FILE' | jq '.id' > /dev/null")
fi
if $HAVE_JAQ; then
    HYPERFINE_ARGS+=(--command-name "jaq (cat | pipe)" "cat '$DATA_FILE' | jaq -c '.id' > /dev/null")
fi
if $HAVE_GOJQ; then
    HYPERFINE_ARGS+=(--command-name "gojq (cat | pipe)" "cat '$DATA_FILE' | gojq '.id' > /dev/null")
fi

echo "" >&2
start_phase_timer "Hyperfine benchmark (three-mode streaming)"
hyperfine "${HYPERFINE_ARGS[@]}" | tee -a "$RESULT_FILE"
end_phase_timer "Hyperfine benchmark"

echo "Benchmark results saved to: $RESULT_FILE" >&2
