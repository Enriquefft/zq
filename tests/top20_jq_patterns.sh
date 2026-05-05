#!/usr/bin/env bash
set -euo pipefail

# Top 20 jq one-liner compatibility test
# Validates that `alias jq=zq` is safe for the most common real-world patterns.
# Usage: bash tests/top20_jq_patterns.sh

PASS=0
FAIL=0
ERRORS=()

for tool in jq zq; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: $tool not found in PATH" >&2
        exit 1
    fi
done

check() {
    local name="$1"
    local input="$2"
    local filter="$3"
    shift 3
    local jq_args=("$@")

    local jq_out zq_out
    jq_out="$(echo "$input" | jq "${jq_args[@]}" "$filter" 2>/dev/null)" || jq_out="__JQ_ERROR__"
    zq_out="$(echo "$input" | zq "${jq_args[@]}" "$filter" 2>/dev/null)" || zq_out="__ZQ_ERROR__"

    if [ "$jq_out" = "$zq_out" ]; then
        echo "  PASS  $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name"
        ERRORS+=("$name|jq: $(echo "$jq_out" | head -1)|zq: $(echo "$zq_out" | head -1)")
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Top 20 jq Pattern Compatibility ==="
echo ""

# Test data
OBJ='{"name":"Alice","age":30,"city":"NYC","scores":[85,92,78]}'
NESTED='{"user":{"name":"Bob","address":{"zip":"10001"}}}'
ARR='[{"id":1,"name":"a","type":"x"},{"id":2,"name":"b","type":"y"},{"id":3,"name":"c","type":"x"}]'
NUMS='[3,1,4,1,5,9,2,6]'
KV='{"a":1,"b":2,"c":3}'

# 1. Field access
check "1.  .field" "$OBJ" '.name'

# 2. Nested field access
check "2.  .nested.field" "$NESTED" '.user.address.zip'

# 3. Iterate array
check "3.  .[]" "$NUMS" '.[]'

# 4. Iterate + extract field
check "4.  .[] | .field" "$ARR" '.[] | .name'

# 5. select filter
check "5.  select(.x > N)" "$ARR" '[.[] | select(.id > 1)]'

# 6. Object reshape
check "6.  {a: .b, c: .d}" "$OBJ" '{n: .name, c: .city}'

# 7. Collect into array
check "7.  [.[] | .field]" "$ARR" '[.[] | .name]'

# 8. length
check "8.  length" "$ARR" 'length'

# 9. keys
check "9.  keys" "$KV" 'keys'

# 10. map(expr)
check "10. map(expr)" "$ARR" 'map(.name)'

# 11. sort_by(.field)
check "11. sort_by(.field)" "$ARR" 'sort_by(.name)'

# 12. group_by + count
check "12. group_by | map(length)" "$ARR" 'group_by(.type) | map(length)'

# 13. to_entries / from_entries
check "13. to_entries" "$KV" 'to_entries | sort_by(.key) | from_entries'

# 14. Null coalescing (//)
check "14. .field // default" '{"a":null}' '.a // "fallback"'

# 15. if-then-else
check "15. if-then-else" "$OBJ" 'if .age > 25 then "adult" else "young" end'

# 16. -r (raw output)
check "16. -r flag" "$OBJ" '.name' -r

# 17. -s (slurp)
SLURP_INPUT=$'{"x":1}\n{"x":2}\n{"x":3}'
check "17. -s flag" "$SLURP_INPUT" '[.[] | .x]' -s

# 18. --arg
check "18. --arg" "$OBJ" '.name == $val' --arg val Alice

# 19. Filter pipeline
check "19. select + pipeline" "$ARR" '[.[] | select(.type == "x") | .name]'

# 20. reduce
check "20. reduce" "$NUMS" 'reduce .[] as $x (0; . + $x)'

# 21. --slurpfile
SLURPFILE="$(mktemp -t zq_top20_slurp_XXXX.json)"
trap 'rm -f "$SLURPFILE"' EXIT
printf '{"x":1}\n{"x":2}\n' > "$SLURPFILE"
check "21. --slurpfile" "null" '$X' --null-input --slurpfile X "$SLURPFILE"

# 22. --rawfile
RAWFILE="$(mktemp -t zq_top20_raw_XXXX.txt)"
trap 'rm -f "$SLURPFILE" "$RAWFILE"' EXIT
printf 'hello\n' > "$RAWFILE"
check "22. --rawfile" "null" '$Y' --null-input --rawfile Y "$RAWFILE"

# 23. --unbuffered
check "23. --unbuffered" "$NUMS" '.[]' --unbuffered

echo ""
echo "=== Results: $PASS passed, $FAIL failed (out of $((PASS + FAIL))) ==="

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        IFS='|' read -r name jq_val zq_val <<< "$err"
        echo "  $name"
        echo "    $jq_val"
        echo "    $zq_val"
    done
fi

exit "$FAIL"
