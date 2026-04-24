//! Leak-detection matrix for `query.CompiledQuery.compile` error paths.
//!
//! Origin: BUG-005 defect 2. During a hermetic `nixos-rebuild switch` on
//! commit `1f57ce1`, mdbook's `anchors` preprocessor shelled out to zq with
//! a filter that errored through the pre-BUG-005-d1 parser path, and the
//! GPA reported `memory address 0x7ffff7e60000 leaked`. Defect 1 (the
//! parser rejection of `|` inside object-field values) has landed, so the
//! original trigger filter now compiles cleanly. The leak claim itself
//! was never independently reproduced.
//!
//! Rather than leave the entry "parked," this matrix exercises a
//! representative filter per class of compile-time failure against a
//! *loud* `std.heap.GeneralPurposeAllocator(.{ .safety = true })` — the
//! leak detector prints an allocation stack trace for every byte that
//! survives `deinit`. Every filter in the matrix is expected to return
//! `CompileResult.err`, and every compile cycle must leave the GPA
//! leak-free. Any regression that drops a `defer`, fails to hand off
//! ownership on an error path, or otherwise leaks through a new
//! compile-error site will fail this test at CI time.
//!
//! Coverage — one filter per distinct error class in
//! `src/query/src/compiler.zig` + `src/query/src/lexer.zig`:
//!
//!   - unexpected top-level token      `"1 2 3"`
//!   - trailing comma in object lit    `"{ ,"`
//!   - trailing comma in array lit     `"[ ,"`
//!   - missing close-brace              `"{"`
//!   - missing close-bracket            `"["`
//!   - missing close-paren              `"("`
//!   - unterminated string literal      `"\"hello"`
//!   - malformed float (two dots)       `"1.2.3"`
//!   - malformed exponent (no digit)    `"1e"`
//!   - unknown numeric prefix           `"0x"`      (tokenised as `0 x`)
//!   - missing bracket in destructure   `". as {,} | ."`
//!   - invalid as-pattern shape         `". as 1 | ."`
//!   - invalid regex literal pattern    `"test(\"[invalid\")"` (regex-enabled build only)
//!   - rejected regex flag letter       `"test(\"x\"; \"Z\")"` (regex-enabled build only)
//!   - regex compile rejects backref    `"test(\"(a)\\\\1\")"` (regex-enabled build only)
//!   - function-def syntax error        `"def f(a,b: . ; ."`
//!   - label-var break without scope    `". as $x | break $x"`
//!   - trailing dot after pipe          `".foo."`
//!   - empty source                     `""`
//!   - regex-in-object-field (BUG-005-shape successor)
//!                                      `"{a: test(\"(bad\")}"`
//!   - invalid token after pipe in
//!     object-field value (new today,
//!     defect-1 shape)                  `"{a: 1 | length, b: @@@}"`
//!   - invalid format directive name    `"@notaformat"`
//!   - bad numeric index literal        `".[]. as [1] | ."` (pattern form)

const std = @import("std");
const query = @import("query");
const regex = @import("regex");

/// Run `compile` against a `.safety = true` GPA and assert:
///   1. the result is `.err` (not `.ok`);
///   2. `deinit` on the GPA reports no leaks.
///
/// On any failure, include `filter` in the diagnostic so the offending
/// input is immediately identifiable in CI output.
fn expectNoLeakOnCompileError(filter: []const u8) !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{ .safety = true }) = .{};
    const alloc = gpa.allocator();

    const result = try query.CompiledQuery.compile(filter, .{}, alloc);
    switch (result) {
        .ok => |cq| {
            // The filter unexpectedly compiled. Clean up before failing so
            // we don't attribute an "expected compile error" failure to a
            // leak that was really the compile succeeding.
            var q = cq;
            q.deinit();
            std.debug.print(
                "filter was expected to fail compile but succeeded: `{s}`\n",
                .{filter},
            );
            _ = gpa.deinit();
            return error.ExpectedCompileError;
        },
        .err => {
            // CompileError is a plain struct (kind/offset/len) — no deinit.
        },
    }

    const check = gpa.deinit();
    if (check == .leak) {
        std.debug.print(
            "leak on compile-error path for filter: `{s}`\n",
            .{filter},
        );
        return error.LeakedOnCompileError;
    }
}

test "BUG-005 d2: compile-error matrix is leak-clean (non-regex filters)" {
    // These exercise parser/lexer error sites that do not require the regex
    // shim. They run in every build configuration.
    const filters = [_][]const u8{
        // Unexpected top-level token (lexer/parser surface).
        "1 2 3",
        // Trailing commas inside collection literals.
        "{ ,",
        "[ ,",
        // Missing closers.
        "{",
        "[",
        "(",
        // Unterminated string literal (lexer path).
        "\"hello",
        // Malformed numeric literals.
        "1.2.3",
        "1e",
        "0x",
        // Destructure pattern shape errors.
        ". as {,} | .",
        ". as 1 | .",
        // Function-def syntax (colon in wrong spot).
        "def f(a,b: . ; .",
        // `break $x` without enclosing `label $x |`.
        ". as $x | break $x",
        // Trailing-dot shapes.
        ".foo.",
        // Empty source.
        "",
        // Invalid token after pipe inside object-field value — the
        // syntactic shape that defect 1 regulated, now re-exercised via a
        // different (still invalid) token after the pipe survives.
        "{a: 1 | length, b: @@@}",
        // Bare invalid format directive.
        "@notaformat",
        // Non-ident after `.` — trailing-dot variant.
        ".[]. as [1] | .",
    };

    for (filters) |f| try expectNoLeakOnCompileError(f);
}

test "BUG-005 d2: compile-error matrix is leak-clean (regex filters)" {
    if (!regex.enabled) return error.SkipZigTest;

    // Each of these threads allocations through the filter-compile regex
    // pool *before* hitting a compile error, exercising the regex-pool
    // rollback path specifically.
    const filters = [_][]const u8{
        // Unclosed character class — shim rejects the pattern itself.
        "test(\"[invalid\")",
        // Unknown flag letter — rejected in the flag-parsing path.
        "test(\"x\"; \"Z\")",
        // Backreference — ROADMAP-documented as compile-rejected.
        "test(\"(a)\\\\1\")",
        // Regex inside an object-field value: would historically have
        // failed at the parser before defect 1 landed; now fails at regex
        // compile. Exercises the intersection of object-literal scope
        // management and regex-pool rollback.
        "{a: test(\"(bad\")}",
        // One valid pattern followed by a failing one — forces the pool
        // to own at least one prior entry at the moment of error.
        "test(\"ok\") | test(\"[unclosed\")",
        // Regex compile error inside a function body.
        "def f: test(\"[bad\"); f",
    };

    for (filters) |f| try expectNoLeakOnCompileError(f);
}
