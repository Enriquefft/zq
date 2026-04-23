const std = @import("std");
const lsp = @import("lsp");
const ast = @import("ast");

const testing = std.testing;

// ── AST parsing integration ──────────────────────────────────────────────

test "parse produces valid AST for completion" {
    var result = ast.parse(".foo | map(. + 1)", testing.allocator);
    defer result.deinit();
    try testing.expect(!result.hasErrors());
}

test "analysis produces semantic model" {
    var result = ast.parse("def f(x): x; f(1)", testing.allocator);
    defer result.deinit();
    try testing.expect(!result.hasErrors());

    var model = lsp.analysis.SemanticModel.analyze(result.root, testing.allocator);
    defer model.deinit();

    // Should have symbols for builtins + the user function + parameter
    try testing.expect(model.symbols.items.len > 0);
}

// ── Builtin metadata ────────────────────────────────────────────────────

test "builtin lookup" {
    const info = lsp.builtins.lookup("map");
    try testing.expect(info != null);
    try testing.expectEqualStrings("map(f)", info.?.signature);
}

test "builtin lookup unknown" {
    const info = lsp.builtins.lookup("nonexistent_builtin");
    try testing.expect(info == null);
}

// ── Protocol utilities ──────────────────────────────────────────────────

test "byteOffsetToPosition simple" {
    const source = "abc\ndef\nghi";
    const pos = lsp.protocol.byteOffsetToPosition(source, 5); // 'e' in "def"
    try testing.expectEqual(@as(u32, 1), pos.line);
    try testing.expectEqual(@as(u32, 1), pos.character);
}

test "byteOffsetToPosition at start" {
    const source = "hello";
    const pos = lsp.protocol.byteOffsetToPosition(source, 0);
    try testing.expectEqual(@as(u32, 0), pos.line);
    try testing.expectEqual(@as(u32, 0), pos.character);
}

test "utf16 offset for ascii" {
    const text = "hello world";
    const offset = lsp.protocol.utf8ToUtf16Offset(text, 5);
    try testing.expectEqual(@as(u32, 5), offset);
}

// ── Regex compile-error diagnostics ─────────────────────────────────────
//
// `fromCompileErrors` runs the real compiler and maps the structured
// `CompileError` (or `regex_not_compiled` when the feature is off) into
// an LSP diagnostic anchored at the offending string literal.

test "fromCompileErrors: invalid regex literal surfaces a diagnostic" {
    const source = "test(\"[invalid\")";
    const diags = lsp.features.diagnostics.fromCompileErrors(source, testing.allocator);
    defer {
        for (diags) |d| testing.allocator.free(d.message);
        testing.allocator.free(diags);
    }

    try testing.expect(diags.len >= 1);
    const d = diags[0];
    try testing.expectEqual(lsp.protocol.DiagnosticSeverity.@"error", d.severity);

    // Range must point at the offending string literal (cols 5..15 on line 0).
    try testing.expectEqual(@as(u32, 0), d.range.start.line);
    try testing.expectEqual(@as(u32, 5), d.range.start.character);
    try testing.expectEqual(@as(u32, 0), d.range.end.line);
    try testing.expectEqual(@as(u32, 15), d.range.end.character);
}

test "fromCompileErrors: valid filter produces no diagnostics" {
    const source = ".foo | length";
    const diags = lsp.features.diagnostics.fromCompileErrors(source, testing.allocator);
    defer {
        for (diags) |d| testing.allocator.free(d.message);
        testing.allocator.free(diags);
    }
    try testing.expectEqual(@as(usize, 0), diags.len);
}

// ── Memoized compile: F10 regression ───────────────────────────────────
//
// `reparse` must NOT rerun `fromCompileErrors` on a didChange whose text
// matches the prior source — otherwise every no-op keystroke / save / echo
// edit rebuilds the RegexPool (and shells out to the regex shim per literal
// pattern), a hundreds-of-µs stall we observed as the F10 hot path.
//
// Drive two back-to-back didChange events with identical text. The compile
// counter must advance at most once across both edits (once for the
// preceding didOpen, not again for either didChange — the hash check
// short-circuits).

test "didChange with identical text does not recompile" {
    // `/dev/null` I/O: the server publishes diagnostics via the transport,
    // which we discard. The message flow below never reads from stdin, so
    // pointing `in_file` at /dev/null is safe (reads would return EOF).
    const devnull_in = try std.fs.openFileAbsolute("/dev/null", .{});
    defer devnull_in.close();
    const devnull_out = try std.fs.createFileAbsolute("/dev/null", .{ .truncate = false });
    defer devnull_out.close();

    var srv = lsp.Server.init(devnull_in, devnull_out, testing.allocator);
    defer srv.deinit();

    // didOpen with a literal-regex filter (the exact shape F10 was about).
    const open_msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///t.jq","languageId":"jq","version":1,"text":"test(\"^GET \")"}}}
    ;
    srv.dispatchForTest(open_msg);
    const after_open = srv.compile_count;
    try testing.expect(after_open >= 1); // at least one compile on open

    // Two identical didChange events. Neither should bump compile_count.
    const change_msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///t.jq","version":2},"contentChanges":[{"text":"test(\"^GET \")"}]}}
    ;
    srv.dispatchForTest(change_msg);
    srv.dispatchForTest(change_msg);

    try testing.expectEqual(after_open, srv.compile_count);

    // Sanity: a change with DIFFERENT text must recompile (the cache keys
    // on the source hash, not on object identity).
    const change_msg2 =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///t.jq","version":3},"contentChanges":[{"text":"test(\"^POST \")"}]}}
    ;
    srv.dispatchForTest(change_msg2);
    try testing.expect(srv.compile_count > after_open);
}
