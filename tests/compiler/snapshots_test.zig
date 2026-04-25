//! Snapshot tests for `lower.zig`. Each fixture pairs a filter source
//! with the expected IR text dump. The dumper is in `src/compiler/ir.zig`;
//! the format spec is `research/compiler-ir-format.md` §10.
//!
//! Layout: one fixture per `tests/compiler/snapshots/lower/<name>.txt`.
//! The `# source: <filter>` line tells the runner which filter to compile;
//! the rest of the file is the expected dump (including the `# SemOp`
//! banner and the indented IR tree).
//!
//! Plan §3 R3 step 9: regeneration uses `zig build snapshots-update`.
//! At this commit we ship fixtures hand-written from the spec's worked
//! examples; the regeneration step is a Cluster B+ TODO once the
//! fixture corpus grows past category 1.

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

test "snapshot fixtures: lower category 1" {
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
