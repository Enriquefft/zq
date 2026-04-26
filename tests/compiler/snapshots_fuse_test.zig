//! Snapshot tests for `fuse.zig` (Phase 19, plan §3 R3 step 8). Each
//! fixture pins a filter source, the IR shape produced by lowering
//! (rendered by the IR-walking dumper), and the IR shape after fuse.
//! Format spec: `research/compiler-ir-format.md` §3a (file directives)
//! + §8 ("Fuse snapshot").
//!
//! Layout: one fixture per `tests/compiler/snapshots/fuse/<name>.txt`.
//! The `# source: <filter>` line tells the runner which filter to
//! compile; `# before` brackets the pre-fuse IR; `# after` brackets
//! the post-fuse IR. Both IR blocks are rendered by `compiler.dumpIR`
//! (NOT the AST-walking `compiler.dump` used by `lower/`) — fuse
//! rewrites the IR's node structure independently of the AST, so the
//! fuse view is the only one that surfaces the rewrite.
//!
//! Plan §3 R3 step 9: regeneration uses `zig build snapshots-update`,
//! which now also rewrites every `fuse/` fixture from the pass's
//! current output.

const std = @import("std");
const ast = @import("ast");
const compiler = @import("compiler");

/// Embed every snapshot file at comptime so the test binary doesn't
/// shell out to disk during the test run. Mirrors the bundling
/// convention in `snapshots_test.zig`.
const Fixture = struct { name: []const u8, expected: []const u8 };

const FIXTURES = [_]Fixture{
    // 2-deep fold: minimum chain that triggers the rewrite.
    .{ .name = "two_deep", .expected = @embedFile("snapshots/fuse/two_deep.txt") },
    // 3-deep fold: the canonical `.a | .b | .c` shape called out in the
    // plan. Keys are dot-joined into `load_path("a.b.c")`.
    .{ .name = "three_deep", .expected = @embedFile("snapshots/fuse/three_deep.txt") },
    // 1-deep "chain": single `load_field`. The fold rule explicitly
    // skips this case (legacy `if (keys.items.len == 1) .load_key`),
    // so the post-fuse IR is the same as pre-fuse — verifies no-op
    // behavior.
    .{ .name = "single_load", .expected = @embedFile("snapshots/fuse/single_load.txt") },
    // Fold blocked by an intervening `iterate` inside the pipe chain
    // (`.a | .[] | .b`). The chain walker bails because `iterate` is
    // not a `load_field` leaf — the pipe stays as nested pipes in the
    // post-fuse IR.
    .{ .name = "blocked_by_iterate", .expected = @embedFile("snapshots/fuse/blocked_by_iterate.txt") },
    // Fold blocked by an intervening static-int index (`.a | .[0] |
    // .b`). Same rule as `iterate` — only `load_field` leaves fold,
    // `load_index` breaks the chain.
    .{ .name = "blocked_by_index", .expected = @embedFile("snapshots/fuse/blocked_by_index.txt") },
    // Source-position preservation: the folded `load_path` node's
    // `@start..end` span covers the entire chain text from the first
    // `.a` byte to the last `.c` byte. This fixture exercises the
    // span carry-over written by `emitLoadPath`.
    .{ .name = "preserves_span", .expected = @embedFile("snapshots/fuse/preserves_span.txt") },
    // Sub-chain folds when the outer fold is blocked. `.a | .b` (a
    // contiguous load_field pair) folds into a load_path even though
    // the surrounding `.[]` breaks the outer chain.
    .{ .name = "sub_chain_folds", .expected = @embedFile("snapshots/fuse/sub_chain_folds.txt") },
    // Fold rule fires inside variable-arity contexts (object value).
    // Verifies `copyNode`'s span re-assembly handles a child that
    // collapses from a 5-node pipe chain to a single `load_path`
    // EmitOp without corrupting the parent's `extra_children` slice.
    .{ .name = "fold_inside_obj", .expected = @embedFile("snapshots/fuse/fold_inside_obj.txt") },
};

/// Read the leading `# source: <filter>` directive (always the first
/// line of the snapshot). The runner parses + lowers + fuses with
/// this filter, then byte-compares the full text (header + IR blocks)
/// against the fixture.
fn extractSource(snapshot: []const u8) []const u8 {
    const prefix = "# source: ";
    std.debug.assert(std.mem.startsWith(u8, snapshot, prefix));
    const after = snapshot[prefix.len..];
    const newline = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
    return after[0..newline];
}

test "snapshot fixtures: fuse" {
    const alloc = std.testing.allocator;
    inline for (FIXTURES) |fx| {
        const filter = extractSource(fx.expected);

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
            .pool_alloc = alloc,
        };
        defer lowerer.deinitRegexPool();
        _ = try compiler.lowerNode(&lowerer, parse_result.root);

        var actual_buf: std.ArrayList(u8) = .{};
        defer actual_buf.deinit(alloc);
        const w = actual_buf.writer(alloc);

        // Header + before/after blocks: spec §8 worked example.
        try w.print("# source: {s}\n", .{filter});
        try w.writeAll("# before\n");
        try compiler.dumpIR(&lowerer.out, w);
        try w.writeAll("# after\n");

        const fuse_out = try compiler.fuse(lowerer.out);
        try compiler.dumpIR(&fuse_out.ir, w);

        std.testing.expectEqualStrings(fx.expected, actual_buf.items) catch |e| {
            std.debug.print(
                "fuse snapshot mismatch: {s}\n--- expected ---\n{s}\n--- actual ---\n{s}\n",
                .{ fx.name, fx.expected, actual_buf.items },
            );
            return e;
        };
    }
}
