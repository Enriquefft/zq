#!/bin/bash
# Generate diverse JSONL records with 7 deterministic shapes.
# Record count controlled by HUGE_LINES (default 15M).
# Every record has an .id field. Shape selected by i % 7.
#
# Shapes:
#   0: {id, tag}                                          — small records
#   1: {id, meta: {source, priority}, data}               — nested objects
#   2: {id, values: [N,N,N], active: bool}                — arrays + booleans
#   3: {id, data: "<variable-length string>"}             — variable-length strings
#   4: {id, count, rate: float, flag: bool, label: null}  — mixed types + nulls
#   5: {id, a: {b: {c: N}}}                               — deep nesting
#   6: {id, name, data, status, tags: [str,str]}           — multi-field + array

LINES="${HUGE_LINES:-15000000}"

awk -v lines="$LINES" 'BEGIN {
    base = ""
    for (j = 1; j <= 50; j++) base = base "abcdefghij"

    for (i = 1; i <= lines; i++) {
        shape = i % 7
        if (shape == 0) {
            printf "{\"id\":%d,\"tag\":\"s%d\"}\n", i, i % 100
        } else if (shape == 1) {
            printf "{\"id\":%d,\"meta\":{\"source\":\"src%d\",\"priority\":%d},\"data\":\"v%d\"}\n", i, i % 50, i % 5, i
        } else if (shape == 2) {
            printf "{\"id\":%d,\"values\":[%d,%d,%d],\"active\":%s}\n", i, i % 1000, (i*7) % 1000, (i*13) % 1000, (i % 2 == 0 ? "true" : "false")
        } else if (shape == 3) {
            len = 10 + (i % 491)
            printf "{\"id\":%d,\"data\":\"%s\"}\n", i, substr(base, 1, len)
        } else if (shape == 4) {
            printf "{\"id\":%d,\"count\":%d,\"rate\":%d.%02d,\"flag\":%s,\"label\":%s}\n", i, i % 10000, i % 100, i % 99, (i % 3 == 0 ? "true" : "false"), (i % 4 == 0 ? "null" : "\"l" i "\"")
        } else if (shape == 5) {
            printf "{\"id\":%d,\"a\":{\"b\":{\"c\":%d}}}\n", i, i * 3
        } else {
            printf "{\"id\":%d,\"name\":\"n%d\",\"data\":\"d%d\",\"status\":\"ok\",\"tags\":[\"t%d\",\"t%d\"]}\n", i, i % 1000, i, i % 20, (i+1) % 20
        }
    }
}' > "$(dirname "$0")/huge.jsonl"
