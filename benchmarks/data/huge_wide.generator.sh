#!/bin/bash
# Generate wide JSONL records (~50 fields, ~1KB each) with deterministic
# ids in 1..HUGE_WIDE_LINES. Every record has an .id field; the remaining
# fields are a fixed schema of strings + numbers + a small nested object
# so the parser exercises tape-slot pressure on a per-record basis.
#
# Why a separate scenario from huge.jsonl? huge.jsonl is mixed-shape and
# narrow (~80 byte mean record). The selective-query attribution
# benchmark on it shows an ~1.05x predicate-pushdown win because the
# parser tape per record is small — there's not much VM work to skip
# when a record is dropped. Wide records (~1KB, 50 fields) shift the
# attribution: the per-record parse cost grows linearly with field count
# while the predicate-pushdown win compounds because every dropped
# record skips the entire VM body (not just one or two emit
# instructions).
#
# Schema (50 fields total): id + 24 strings + 12 ints + 6 floats + 6
# bools + 1 nested {p, q, r} object. Field names are short so each line
# stays close to 1 KB without exotic Unicode.

LINES="${HUGE_WIDE_LINES:-1000000}"

awk -v lines="$LINES" 'BEGIN {
    base = ""
    for (j = 1; j <= 4; j++) base = base "abcdefghij"

    for (i = 1; i <= lines; i++) {
        # 24 string fields s00..s23
        s = ""
        for (k = 0; k < 24; k++) {
            len = 8 + ((i + k) % 24)
            s = s "\"s" sprintf("%02d", k) "\":\"" substr(base, 1, len) "\","
        }
        # 12 int fields n00..n11
        n = ""
        for (k = 0; k < 12; k++) {
            n = n "\"n" sprintf("%02d", k) "\":" ((i * (k + 1)) % 100000) ","
        }
        # 6 float fields f0..f5
        f = ""
        for (k = 0; k < 6; k++) {
            whole = (i + k) % 1000
            frac  = ((i * 7) + k) % 1000
            f = f "\"f" k "\":" whole "." sprintf("%03d", frac) ","
        }
        # 6 bool fields b0..b5
        b = ""
        for (k = 0; k < 6; k++) {
            v = ((i + k) % 2 == 0) ? "true" : "false"
            b = b "\"b" k "\":" v ","
        }
        # nested object — exercises one level of descent the parser must
        # traverse on the no-plan path.
        nested = sprintf("\"nest\":{\"p\":%d,\"q\":\"%s\",\"r\":%s}", \
            (i * 11) % 1000, substr(base, 1, 6), ((i % 3 == 0) ? "true" : "false"))

        printf "{\"id\":%d,%s%s%s%s%s}\n", i, s, n, f, b, nested
    }
}' > huge_wide.jsonl
