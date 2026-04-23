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
