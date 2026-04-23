// jq onig.test compat — ported subset.
//
// Source: https://github.com/jqlang/jq/blob/master/tests/onig.test
//
// Scope of this port:
//   - Every jq test whose pattern/flags/replacement uses ONLY features that
//     regex-automata supports is expected to PASS and is written as a real
//     test. Behaviour must match jq byte-for-byte (we use the same compat
//     harness as every other tests/compat/*.zig file).
//   - Tests that rely on features regex-automata deliberately lacks (pattern
//     backrefs, lookaround, onig-only escape sequences) are represented as
//     `skip` tests with a one-line reason. They document the compat delta and
//     survive jq behaviour changes — if jq ever weakens its requirements a
//     skip can be promoted to a real test.
//   - `match([re,flags])` array-overload is the only jq-builtin-shape that is
//     still skipped and tracked here. `splits` and `match(re;"g")` landed in
//     Phase E.5 and now carry real assertions below.
//
// Every real test must pass today; every skipped test carries its reason.
// Invariant: `zig build test -Dregex=true` finishes with `regex.zig` tests
// either PASS or SkipZigTest — no failures.

const std = @import("std");
const h = @import("helpers.zig");
const regex = @import("regex");

fn requireRegex() !void {
    if (!regex.enabled) return error.SkipZigTest;
}

// ── capture: named groups ────────────────────────────────────────────────────

test "jq:onig capture named groups xyzzy-14" {
    try requireRegex();
    const results = try h.runFilter(
        "capture(\"(?<a>[a-z]+)-(?<n>[0-9]+)\")",
        "\"xyzzy-14\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":\"xyzzy\",\"n\":\"14\"}", results[0]);
}

test "jq:onig capture unmatched optional group emits null" {
    try requireRegex();
    const results = try h.runFilter(
        "capture(\"(?<x>a)?b?\")",
        "\"b\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"x\":null}", results[0]);
}

test "jq:onig capture matched optional group carries string" {
    try requireRegex();
    const results = try h.runFilter(
        "capture(\"(?<x>a)?b?\")",
        "\"a\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"x\":\"a\"}", results[0]);
}

// ── test ─────────────────────────────────────────────────────────────────────

test "jq:onig test matches multibyte literal" {
    try requireRegex();
    const results = try h.runFilter(
        "test(\"ā\")",
        "\"ā\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

// ── sub ──────────────────────────────────────────────────────────────────────

test "jq:onig sub first-match literal" {
    try requireRegex();
    const results = try h.runFilter(
        "[.[] | sub(\", \"; \":\")]",
        "[\"a,b, c, d, e,f\",\", a,b, c, d, e,f, \"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a,b:c, d, e,f\",\":a,b, c, d, e,f, \"]", results[0]);
}

test "jq:onig sub 3-arg x-flag on empty input returns empty" {
    try requireRegex();
    const results = try h.runFilter(
        "gsub(\"(.*)\"; \"\"; \"x\")",
        "\"\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"\"", results[0]);
}

// ── gsub ─────────────────────────────────────────────────────────────────────

test "jq:onig gsub literal comma-space" {
    try requireRegex();
    const results = try h.runFilter(
        "[.[] | gsub(\", \"; \":\")]",
        "[\"a,b, c, d, e,f\",\", a,b, c, d, e,f, \"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a,b:c:d:e,f\",\":a,b:c:d:e,f:\"]", results[0]);
}

test "jq:onig gsub single letter" {
    try requireRegex();
    const results = try h.runFilter(
        "gsub(\"a\";\"b\")",
        "\"aaaaa\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"bbbbb\"", results[0]);
}

test "jq:onig gsub caret anchor does not loop" {
    try requireRegex();
    const results = try h.runFilter(
        "gsub(\"^\"; \"a\")",
        "\"\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"a\"", results[0]);
}

test "jq:onig gsub greedy prefix .*a" {
    try requireRegex();
    const results = try h.runFilter(
        "gsub(\"^.*a\"; \"b\")",
        "\"aaa\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"b\"", results[0]);
}

test "jq:onig gsub non-greedy prefix .*?a" {
    try requireRegex();
    const results = try h.runFilter(
        "gsub(\"^.*?a\"; \"b\")",
        "\"aaa\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"baa\"", results[0]);
}

// ── scan ─────────────────────────────────────────────────────────────────────

test "jq:onig scan literal across array elements" {
    try requireRegex();
    const results = try h.runFilter(
        "[.[] | scan(\", \")]",
        "[\"a,b, c, d, e,f\",\", a,b, c, d, e,f, \"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\", \",\", \",\", \",\", \",\", \",\", \",\", \",\", \"]", results[0]);
}

test "jq:onig scan with i flag is case-insensitive" {
    try requireRegex();
    const results = try h.runFilter(
        "[.[] | scan(\"b+\"; \"i\")]",
        "[\"\",\"bBb\",\"abcABBBCabbbc\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"bBb\",\"b\",\"BBB\",\"bbb\"]", results[0]);
}

// ── match offsets (character-count semantics) ────────────────────────────────

test "jq:onig match counts characters not bytes" {
    try requireRegex();
    // "ā bar with a combining codepoint U+0304" → "ā" is one char, space 1,
    // "bar" starts at char index 2 (but in jq the input uses NFC; our test
    // string has one-char "ā" which should land bar at char offset 2).
    // Use a slightly simpler form to avoid combining-codepoint semantics:
    // "café bar" → "bar" starts at char 5.
    const results = try h.runFilter(
        "match(\"bar\") | .offset",
        "\"café bar\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("5", results[0]);
}

// ── Skipped tests (documented compat delta) ──────────────────────────────────

test "jq:onig match-g generator yields one object per occurrence" {
    try requireRegex();
    // `match(re; "g")` is a generator — one jq-match-object per
    // non-overlapping match.
    const results = try h.runFilter(
        "[match(\"a\"; \"g\")]",
        "\"ababab\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings(
        "[{\"offset\":0,\"length\":1,\"string\":\"a\",\"captures\":[]},{\"offset\":2,\"length\":1,\"string\":\"a\",\"captures\":[]},{\"offset\":4,\"length\":1,\"string\":\"a\",\"captures\":[]}]",
        results[0],
    );
}

test "jq:onig match-g generator — zero-width matches step one byte at a time" {
    try requireRegex();
    // Classic onig-test invocation: `[match("( )*"; "g")]`. Every position in
    // the input is a valid zero-width match, so jq yields N+1 objects for a
    // length-N string.
    const results = try h.runFilter(
        "[match(\"( )*\"; \"g\") | .offset]",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,3]", results[0]);
}

test "jq:onig match-array-overload — SKIP: match([re,flags]) not wired" {
    // [match(["foo (?<bar123>bar)? foo", "ig"])] — array overload that packs
    // pattern+flags into one arg. Uncommon idiom; the two-arg form covers the
    // same ground and is what every real-world jq program uses.
    return error.SkipZigTest;
}

test "jq:onig replacement-interpolation — SKIP: \\(.name) in repl not supported" {
    // sub("^(?<head>.)"; "Head=\(.head) Tail=")
    //   — jq interprets the replacement as a filter evaluated against the
    // capture object. zq's current sub/gsub accept \1..\9 and \g<name> for
    // backref substitution but do not execute the replacement as a filter.
    // Promote this test when the VM gains replacement-filter evaluation.
    return error.SkipZigTest;
}

test "jq:onig lookaround — SKIP: (?=u) not supported by regex-automata" {
    // gsub("(?=u)"; "u") — positive lookahead. regex-automata rejects this at
    // compile time. Documented compat delta. Rewrite suggestion for users:
    // `gsub("u"; "uu")` — identical effect for this pattern.
    return error.SkipZigTest;
}

test "jq:onig splits empty-pattern yields every character + flanking empties" {
    try requireRegex();
    const results = try h.runFilter(
        "[splits(\"\")]",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"\",\"a\",\"b\",\"c\",\"\"]", results[0]);
}

test "jq:onig splits single-char pattern yields surrounding segments" {
    try requireRegex();
    const results = try h.runFilter(
        "[splits(\"c\")]",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"ab\",\"\"]", results[0]);
}

test "jq:onig splits with i flag collapses mixed-case runs" {
    try requireRegex();
    const results = try h.runFilter(
        "[splits(\"a+\"; \"i\")]",
        "\"aAaAbCbBbC\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"\",\"bCbBbC\"]", results[0]);
}

test "jq:onig match-array-single-arg — SKIP: match([re]) not wired" {
    // [match(["(bar)"])] — single-element array as pattern. Same array
    // overload as the flags variant above, also uncommon. Skip together.
    return error.SkipZigTest;
}

test "jq:onig test with n flag is rejected at compile time" {
    // Historical delta: jq's `n` (no-empty-match) flag changes every regex
    // builtin to treat zero-width matches as non-matches. zq previously
    // accepted `n` and ignored it — silently producing jq-incompatible
    // output. Per CLAUDE.md §4 (zero workarounds), we now reject it at
    // compile time with RegexCompileError. Implementing `n` is a separate
    // design task (needs per-builtin zero-width detection paths).
    try requireRegex();
    try h.expectCompileError("test(\"( )*\"; \"gn\")");
}
