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
const parser_mod = @import("parser");
const query_mod = @import("query");

fn requireRegex() !void {
    if (!regex.enabled) return error.SkipZigTest;
}

/// Strict-iteration variant of `h.runFilter`: propagates iterator errors
/// instead of swallowing them via `it.next() catch null`. Tests that need
/// to assert "no runtime error AND empty output" use this so a regression
/// to the TypeError path can't masquerade as a passing result. Mirrors the
/// CLI's exit-code contract: a raised error here is what the CLI prints
/// to stderr and exits non-zero on.
fn runFilterStrict(filter: []const u8, input_json: []const u8) ![][]const u8 {
    var p = try parser_mod.Parser.init(h.alloc);
    defer p.deinit();

    const tape = switch (try p.feed(input_json, true)) {
        .done => |d| d.tape,
        .need_more => return error.ParseIncomplete,
    };

    const result = try query_mod.CompiledQuery.compile(filter, .{}, h.alloc);
    var q = switch (result) {
        .ok => |cq| cq,
        .err => return error.QuerySyntaxError,
    };
    defer q.deinit();

    var it = try q.execute(tape, &.{}, h.alloc);
    defer it.deinit();

    var result_list = std.ArrayList([]const u8){};
    errdefer {
        for (result_list.items) |s| h.alloc.free(s);
        result_list.deinit(h.alloc);
    }

    while (try it.next()) |val| {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(h.alloc);
        try h.serializeValue(&buf, val);
        try result_list.append(h.alloc, try buf.toOwnedSlice(h.alloc));
    }

    return result_list.toOwnedSlice(h.alloc);
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

// ── `n` flag — ignore-empty-match across all regex builtins ──────────────────
//
// jq's `n` flag, applied to every regex builtin (test/match/capture/scan/
// sub/gsub/splits), filters zero-width overall matches. Zero-width optional
// capture groups inside a non-empty match still surface as unmatched slots
// with `offset:-1, length:0, string:null` (jq emits `null` for `capture`
// named groups) — `n` only inspects the overall match span.
//
// Engine caveat: a narrow class of patterns that lead with an empty
// alternative (e.g. `"|a"`) behaves differently between Oniguruma and
// regex-automata under `n`. Oniguruma's `ONIG_OPTION_FIND_NOT_EMPTY`
// retries alternatives at the same position, so `match("|a"; "n")` lands
// on `"a"` in jq; regex-automata has no equivalent knob, so zq advances
// past the empty match and returns no match. Documented under "Compat
// delta vs jq" in ROADMAP.md; not covered by the assertions below.

test "jq:n-flag test filters zero-width matches" {
    try requireRegex();
    const results = try h.runFilter(
        "[test(\"\"; \"n\"), test(\"^\"; \"n\"), test(\"a\"; \"n\")]",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false,false,true]", results[0]);
}

test "jq:n-flag match(g) filters zero-width matches" {
    try requireRegex();
    const results = try h.runFilter(
        "[match(\"a|b\"; \"gn\")] | map({o: .offset, l: .length, s: .string})",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings(
        "[{\"o\":0,\"l\":1,\"s\":\"a\"},{\"o\":1,\"l\":1,\"s\":\"b\"}]",
        results[0],
    );
}

test "jq:n-flag match drops empty-only pattern to no-match" {
    try requireRegex();
    // match(""; "n") on "" — the only match is zero-width (empty pattern),
    // n-flag filters it out, and jq emits *no output* with exit 0.
    // We use the strict runner so a raised error here would FAIL the test
    // (the catch-null in `runFilter` would otherwise mask the TypeError
    // that R-pass observed via the CLI repro).
    const results = try runFilterStrict("match(\"\"; \"n\")", "\"\"");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:n-flag match empty pattern on non-empty string emits nothing" {
    try requireRegex();
    // R-pass MISS (regex:n-flag-empty-pattern):
    //   `match(""; "n")` on `"abc"` raised TypeError → stderr + exit 4
    //   under the previous slot-only fix. jq-1.8.1 emits nothing, exit 0.
    const results = try runFilterStrict("match(\"\"; \"n\")", "\"abc\"");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:n-flag match noncapturing-empty group on non-empty string emits nothing" {
    try requireRegex();
    // Sibling probe to the R-pass MISS — `(?:)` is the noncapturing-empty
    // form of the empty pattern. Same parity: zero output, exit 0.
    const results = try runFilterStrict("match(\"(?:)\"; \"n\")", "\"abc\"");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:n-flag capture empty pattern on non-empty string emits nothing" {
    try requireRegex();
    // Same fix lands in builtinCapture's n-flag exhaustion path.
    const results = try runFilterStrict("capture(\"\"; \"n\")", "\"abc\"");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:n-flag capture(g) skips zero-width alternatives" {
    try requireRegex();
    const results = try h.runFilter(
        "[capture(\"(?<x>a)|\"; \"gn\")]",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[{\"x\":\"a\"}]", results[0]);
}

test "jq:n-flag scan filters empty tail matches" {
    try requireRegex();
    const results = try h.runFilter(
        "[scan(\"a*\"; \"n\")]",
        "\"aaa\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"aaa\"]", results[0]);
}

test "jq:n-flag scan empty pattern yields empty output" {
    try requireRegex();
    const results = try h.runFilter(
        "[scan(\"\"; \"n\")]",
        "\"aaa\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:n-flag sub skips zero-width match" {
    try requireRegex();
    const results = try h.runFilter(
        "sub(\"^\"; \"X\"; \"n\")",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"abc\"", results[0]);
}

test "jq:n-flag gsub empty pattern is a no-op" {
    try requireRegex();
    const results = try h.runFilter(
        "gsub(\"\"; \"-\"; \"n\")",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"abc\"", results[0]);
}

test "jq:n-flag gsub non-empty pattern still replaces" {
    try requireRegex();
    const results = try h.runFilter(
        "gsub(\"a\"; \"-\"; \"n\")",
        "\"aaa\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"---\"", results[0]);
}

test "jq:n-flag splits empty pattern returns input unchanged" {
    try requireRegex();
    const results = try h.runFilter(
        "[splits(\"\"; \"n\")]",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"abc\"]", results[0]);
}

test "jq:n-flag splits trailing empty-alt collapses to same segmentation" {
    try requireRegex();
    // "b|" — zero-width alt at every position plus a concrete 'b' split;
    // n-flag must only honour the concrete split, matching jq's output.
    const results = try h.runFilter(
        "[splits(\"b|\"; \"n\")]",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\",\"c\"]", results[0]);
}

test "jq:n-flag combines with i flag (case-insensitive still applies)" {
    try requireRegex();
    const results = try h.runFilter(
        "[match(\"a\"; \"ni\")]",
        "\"ABC\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings(
        "[{\"offset\":0,\"length\":1,\"string\":\"A\",\"captures\":[]}]",
        results[0],
    );
}

test "jq:n-flag without-n-flag paths unchanged (regression)" {
    // Guard that adding the operand bit didn't perturb the no-flag path.
    try requireRegex();
    const results = try h.runFilter(
        "[match(\"\"; \"g\")] | length",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    // Without n, match("";"g") yields four zero-width matches (one per
    // position, inclusive of end). Exactly jq's behaviour pre-n.
    try std.testing.expectEqualStrings("4", results[0]);
}
