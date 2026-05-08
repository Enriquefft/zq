//! Snapshot tests for `fuse.zig` (Phase 19, plan §3 R3 step 8). Each
//! fixture pins a filter source, the IR shape produced by lowering
//! (rendered by the IR-walking dumper), and the IR shape after fuse.
//! Format spec: `src/compiler/IR-FORMAT.md` §3a (file directives)
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
    // Sub-chain folds when the outer fold is blocked. Both `.a | .b`
    // (before the iterate) AND `.c | .d` (after) collapse into
    // load_paths — matches legacy fuse's bytecode-stream behavior of
    // re-scanning past chain-breakers.
    .{ .name = "sub_chain_folds", .expected = @embedFile("snapshots/fuse/sub_chain_folds.txt") },
    // Three independent runs separated by two different chain-breakers
    // (`iterate` and `load_index`). Verifies the linearized walk fuses
    // every load_field run, not just the first.
    .{ .name = "sub_chain_three_runs", .expected = @embedFile("snapshots/fuse/sub_chain_three_runs.txt") },
    // Fold rule fires inside variable-arity contexts (object value).
    // Verifies `copyNode`'s span re-assembly handles a child that
    // collapses from a 5-node pipe chain to a single `load_path`
    // EmitOp without corrupting the parent's `extra_children` slice.
    .{ .name = "fold_inside_obj", .expected = @embedFile("snapshots/fuse/fold_inside_obj.txt") },
    // Fold inside a non-recursive UDF body. The body is inlined into
    // the call_user's variable-arity span; the snapshot shows the
    // body's pipe chain collapsing into a load_path inside the
    // inlined region.
    .{ .name = "fold_in_udf_body", .expected = @embedFile("snapshots/fuse/fold_in_udf_body.txt") },
    // Fold inside a recursive UDF body. Recursive UDFs lower the body
    // ONCE and route subsequent calls via `function_table.body_ir_root`
    // (a node index that fuse must re-point through `index_map`).
    // The fixture's `# function_body fn_id=0` block dumps the body
    // subtree AFTER remap so the index_map path is observable in the
    // diff — this is the surface that broke during dev (recursive
    // `def fact` returned `false` because the stale index pointed at
    // the wrong node).
    .{ .name = "fold_in_recursive_udf", .expected = @embedFile("snapshots/fuse/fold_in_recursive_udf.txt") },
    // Fold inside an `if` then-arm. Exercises the 3-arity span
    // (cond/then/else) re-assembly path in `copyNode` — distinct from
    // the variable-arity obj_ctor / call_user paths covered above.
    .{ .name = "fold_in_if_then", .expected = @embedFile("snapshots/fuse/fold_in_if_then.txt") },
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

        // Mirror `compile()` in `root.zig`: gather body roots and pass
        // them as extra walk roots so fuse traverses the off-main-root
        // function-body subtrees too. Without this, body indices stay
        // at sentinel in `index_map` and the remap below would clobber
        // `body_ir_root` to `BODY_IR_NOT_LOWERED`.
        var extra_roots: std.ArrayList(u32) = .{};
        defer extra_roots.deinit(std.testing.allocator);
        for (lowerer.function_table.items) |entry| {
            if (entry.body_ir_root == compiler.BODY_IR_NOT_LOWERED) continue;
            try extra_roots.append(std.testing.allocator, entry.body_ir_root);
        }
        const fuse_out = try compiler.fuse(lowerer.out, extra_roots.items);
        try compiler.dumpIR(&fuse_out.ir, w);

        // Recursive-UDF body verification: when lowering populated any
        // `function_table.body_ir_root` (cat-9 recursive functions),
        // emit a `# function_body fn_id=N` directive followed by the
        // post-remap body subtree. The body root lives off-tree (emit
        // walks it via `function_table`, not via the IR root), so the
        // fixture would otherwise hide whether `index_map` correctly
        // re-pointed the entry. Mirrors `compile()` in `root.zig` —
        // body_ir_root is patched there and we replay the same
        // translation here so the snapshot reflects production state.
        for (lowerer.function_table.items, 0..) |entry, fn_id| {
            if (entry.body_ir_root == compiler.BODY_IR_NOT_LOWERED) continue;
            const remapped = fuse_out.index_map[entry.body_ir_root];
            try w.print("# function_body fn_id={d}\n", .{fn_id});
            try compiler.dumpIRSubtree(&fuse_out.ir, remapped, w);
        }

        std.testing.expectEqualStrings(fx.expected, actual_buf.items) catch |e| {
            std.debug.print(
                "fuse snapshot mismatch: {s}\n--- expected ---\n{s}\n--- actual ---\n{s}\n",
                .{ fx.name, fx.expected, actual_buf.items },
            );
            return e;
        };
    }
}
