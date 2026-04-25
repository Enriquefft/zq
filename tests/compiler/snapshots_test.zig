//! Snapshot tests for `lower.zig`. Each fixture pairs a filter source
//! with the expected IR text dump. The dumper is in `src/compiler/ir.zig`;
//! the format spec is `research/compiler-ir-format.md` §10.
//!
//! Layout: one fixture per `tests/compiler/snapshots/lower/<name>.txt`.
//! The `# source: <filter>` line tells the runner which filter to compile;
//! the rest of the file is the expected dump (including the `# SemOp`
//! banner and the indented IR tree).
//!
//! Plan §3 R3 step 9: regeneration uses `zig build snapshots-update`,
//! which rewrites every fixture from the dumper's current output.
//! Hand-edits to fixture text become drift on the next regen.

const std = @import("std");
const ast = @import("ast");
const compiler = @import("compiler");

/// Embed every snapshot file at comptime so the test binary doesn't
/// shell out to disk during the test run. The fixtures live in
/// `tests/compiler/snapshots/lower/`; when adding a new one, append it
/// to the array below — the build's bundle step copies each path
/// straight into the binary via `@embedFile`.
const Fixture = struct { name: []const u8, expected: []const u8 };

const FIXTURES = [_]Fixture{
    .{ .name = "literal_null", .expected = @embedFile("snapshots/lower/literal_null.txt") },
    .{ .name = "literal_true", .expected = @embedFile("snapshots/lower/literal_true.txt") },
    .{ .name = "literal_false", .expected = @embedFile("snapshots/lower/literal_false.txt") },
    .{ .name = "literal_int", .expected = @embedFile("snapshots/lower/literal_int.txt") },
    .{ .name = "literal_float", .expected = @embedFile("snapshots/lower/literal_float.txt") },
    .{ .name = "literal_string", .expected = @embedFile("snapshots/lower/literal_string.txt") },
    .{ .name = "identity", .expected = @embedFile("snapshots/lower/identity.txt") },
    .{ .name = "recurse", .expected = @embedFile("snapshots/lower/recurse.txt") },
    .{ .name = "unary_neg", .expected = @embedFile("snapshots/lower/unary_neg.txt") },
    .{ .name = "not_zero_arg", .expected = @embedFile("snapshots/lower/not_zero_arg.txt") },
    .{ .name = "type_zero_arg", .expected = @embedFile("snapshots/lower/type_zero_arg.txt") },
    .{ .name = "load_field", .expected = @embedFile("snapshots/lower/load_field.txt") },
    .{ .name = "load_index", .expected = @embedFile("snapshots/lower/load_index.txt") },
    .{ .name = "iterate", .expected = @embedFile("snapshots/lower/iterate.txt") },
    .{ .name = "slice", .expected = @embedFile("snapshots/lower/slice.txt") },
    .{ .name = "try_optional", .expected = @embedFile("snapshots/lower/try_optional.txt") },
    .{ .name = "pipe_simple", .expected = @embedFile("snapshots/lower/pipe_simple.txt") },
    .{ .name = "pipe_chain", .expected = @embedFile("snapshots/lower/pipe_chain.txt") },
    .{ .name = "comma_simple", .expected = @embedFile("snapshots/lower/comma_simple.txt") },
    .{ .name = "comma_pipe_mixed", .expected = @embedFile("snapshots/lower/comma_pipe_mixed.txt") },
    .{ .name = "arith_add", .expected = @embedFile("snapshots/lower/arith_add.txt") },
    .{ .name = "arith_sub", .expected = @embedFile("snapshots/lower/arith_sub.txt") },
    .{ .name = "arith_mul", .expected = @embedFile("snapshots/lower/arith_mul.txt") },
    .{ .name = "arith_div", .expected = @embedFile("snapshots/lower/arith_div.txt") },
    .{ .name = "arith_mod", .expected = @embedFile("snapshots/lower/arith_mod.txt") },
    .{ .name = "arith_chain", .expected = @embedFile("snapshots/lower/arith_chain.txt") },
    .{ .name = "cmp_eq", .expected = @embedFile("snapshots/lower/cmp_eq.txt") },
    .{ .name = "cmp_ne", .expected = @embedFile("snapshots/lower/cmp_ne.txt") },
    .{ .name = "cmp_lt", .expected = @embedFile("snapshots/lower/cmp_lt.txt") },
    .{ .name = "cmp_ge", .expected = @embedFile("snapshots/lower/cmp_ge.txt") },
    .{ .name = "logical_and", .expected = @embedFile("snapshots/lower/logical_and.txt") },
    .{ .name = "logical_or", .expected = @embedFile("snapshots/lower/logical_or.txt") },
    .{ .name = "alt_basic", .expected = @embedFile("snapshots/lower/alt_basic.txt") },
    .{ .name = "alt_chain", .expected = @embedFile("snapshots/lower/alt_chain.txt") },
    .{ .name = "obj_static_keys", .expected = @embedFile("snapshots/lower/obj_static_keys.txt") },
    .{ .name = "obj_computed_keys", .expected = @embedFile("snapshots/lower/obj_computed_keys.txt") },
    .{ .name = "obj_shorthand", .expected = @embedFile("snapshots/lower/obj_shorthand.txt") },
    .{ .name = "arr_simple", .expected = @embedFile("snapshots/lower/arr_simple.txt") },
    .{ .name = "arr_nested", .expected = @embedFile("snapshots/lower/arr_nested.txt") },
    .{ .name = "interp_basic", .expected = @embedFile("snapshots/lower/interp_basic.txt") },
    .{ .name = "interp_nested", .expected = @embedFile("snapshots/lower/interp_nested.txt") },
    .{ .name = "format_at_base64", .expected = @embedFile("snapshots/lower/format_at_base64.txt") },
    .{ .name = "format_at_csv_tail", .expected = @embedFile("snapshots/lower/format_at_csv_tail.txt") },
    .{ .name = "assign_set", .expected = @embedFile("snapshots/lower/assign_set.txt") },
    .{ .name = "assign_add", .expected = @embedFile("snapshots/lower/assign_add.txt") },
    .{ .name = "assign_sub", .expected = @embedFile("snapshots/lower/assign_sub.txt") },
    .{ .name = "assign_mul", .expected = @embedFile("snapshots/lower/assign_mul.txt") },
    .{ .name = "assign_div", .expected = @embedFile("snapshots/lower/assign_div.txt") },
    .{ .name = "assign_mod", .expected = @embedFile("snapshots/lower/assign_mod.txt") },
    .{ .name = "assign_alt", .expected = @embedFile("snapshots/lower/assign_alt.txt") },
    .{ .name = "assign_update", .expected = @embedFile("snapshots/lower/assign_update.txt") },
    .{ .name = "assign_general_iterate", .expected = @embedFile("snapshots/lower/assign_general_iterate.txt") },
    .{ .name = "try_simple", .expected = @embedFile("snapshots/lower/try_simple.txt") },
    .{ .name = "try_catch", .expected = @embedFile("snapshots/lower/try_catch.txt") },
    .{ .name = "if_basic", .expected = @embedFile("snapshots/lower/if_basic.txt") },
    .{ .name = "if_elif", .expected = @embedFile("snapshots/lower/if_elif.txt") },
    .{ .name = "path_simple", .expected = @embedFile("snapshots/lower/path_simple.txt") },
    .{ .name = "path_iterate", .expected = @embedFile("snapshots/lower/path_iterate.txt") },
    .{ .name = "var_load", .expected = @embedFile("snapshots/lower/var_load.txt") },
    .{ .name = "as_simple", .expected = @embedFile("snapshots/lower/as_simple.txt") },
    .{ .name = "destructure_array", .expected = @embedFile("snapshots/lower/destructure_array.txt") },
    .{ .name = "destructure_nested", .expected = @embedFile("snapshots/lower/destructure_nested.txt") },
    .{ .name = "destructure_object", .expected = @embedFile("snapshots/lower/destructure_object.txt") },
    .{ .name = "destructure_object_shorthand", .expected = @embedFile("snapshots/lower/destructure_object_shorthand.txt") },
    .{ .name = "alt_bind", .expected = @embedFile("snapshots/lower/alt_bind.txt") },
};

/// Extract the filter source text from a snapshot's `# source:` directive
/// (always the first line).
fn extractSource(snapshot: []const u8) []const u8 {
    const prefix = "# source: ";
    std.debug.assert(std.mem.startsWith(u8, snapshot, prefix));
    const after = snapshot[prefix.len..];
    const newline = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
    return after[0..newline];
}

test "snapshot fixtures: lower" {
    const alloc = std.testing.allocator;
    inline for (FIXTURES) |fx| {
        const filter = extractSource(fx.expected);

        // Parse → lower → dump.
        var parse_result = ast.parse(filter, alloc);
        defer parse_result.deinit();
        try std.testing.expect(!parse_result.hasErrors());

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        var lowerer = compiler.Lowerer{
            .arena = &arena,
            .src = filter,
            .out = compiler.IR.init(&arena),
            .opts = .{},
        };
        _ = try compiler.lowerNode(&lowerer, parse_result.root);

        var actual_buf: std.ArrayList(u8) = .{};
        defer actual_buf.deinit(alloc);
        try compiler.dump(&lowerer.out, parse_result.root, filter, actual_buf.writer(alloc));

        std.testing.expectEqualStrings(fx.expected, actual_buf.items) catch |e| {
            std.debug.print(
                "snapshot mismatch: {s}\n--- expected ---\n{s}\n--- actual ---\n{s}\n",
                .{ fx.name, fx.expected, actual_buf.items },
            );
            return e;
        };
    }
}
