//! IR rewrite passes — Phase 2R / R3 step 8.
//!
//! Single rule today: chained static-key field loads collapse to one
//! `load_path` EmitOp per maximal contiguous run of `load_field`s
//! within a pipe tree. Plan §3 R3 step 8: "port legacy's `.a | .b |
//! .c` → `load_path` fold into `fuse.zig` as one IR→IR pass. Other
//! fuse opportunities deferred."
//!
//! The fuse pass walks the linearized IR pipe-tree and folds every maximal
//! run of consecutive `load_field` leaves separated only by `pipe` nodes —
//! including runs that appear AFTER a chain-breaker like `each` /
//! `load_index`. This mirrors the behavior of the bytecode-stream fold
//! that the Phase 2R compiler replaced. To achieve that on the IR-tree
//! shape, this pass:
//!
//!   1. Linearizes a pipe tree's leaves (anything not a `pipe` node)
//!      into a flat sequence in source order.
//!   2. Walks the sequence, grouping maximal runs of `load_field`
//!      leaves; runs of length ≥ 2 collapse to a single `load_path`,
//!      runs of length 1 (and non-`load_field` leaves) pass through
//!      unchanged.
//!   3. Reconstructs a left-deep pipe tree from the resulting
//!      sequence, matching the IR shape lowering would have produced
//!      had the source filter been written without the folded
//!      segments.
//!
//! For `.a | .b | .[] | .c | .d` this yields `pipe(pipe(load_path
//! "a.b", iterate), load_path "c.d")` — both runs fuse, with the
//! `iterate` segment preserved between them. A single-key chain
//! (one `load_field`) is NOT folded — emit's `load_field` handler
//! already produces the same `Instruction.Op.load_key` the legacy
//! compiler emits, so wrapping it in `load_path` would be pure
//! overhead.
//!
//! The pass produces a fresh `IR` rather than mutating in place. Both
//! IRs share the input arena (the caller passes the lowered `IR` whose
//! arena is owned by the compile call); the fresh IR appends new nodes
//! into the same arena, copies extra_data slots forward, and copies
//! `string_buf` bytes — `load_path`'s dot-joined name is interned into
//! the arena's string_buf at fuse time. The old IR's nodes become
//! unreachable (still resident in the arena, freed when the compile
//! call's arena is destroyed); `emit.zig` walks the new IR exclusively.
//!
//! Aux-table re-pointing: cat-9 user-functions reach the body IR via
//! `Lowerer.function_table[fn_id].body_ir_root`, which is a node index
//! into the LOWERED IR. After fuse re-emits nodes in fresh order, that
//! index is stale. The pass returns an `index_map` so callers can
//! translate auxiliary indices to the new IR before `emit` runs.
const std = @import("std");
const ir = @import("ir.zig");

/// Output of the fuse pass. Carries the rewritten IR plus an
/// old-to-new node-index map so the Lowerer's auxiliary tables (cat-9
/// `body_ir_root` pointers in `function_table`) can be re-pointed at
/// the new IR. The map is allocated in the IR arena.
///
/// `index_map[old_idx]` returns the corresponding new index. Folded
/// pipe-chain interior nodes (the consumed `pipe` and `load_field`
/// nodes) all map to the index of the synthesized `load_path` so any
/// stray reference still resolves to the semantically-equivalent
/// replacement.
pub const Result = struct {
    ir: ir.IR,
    index_map: []const u32,
};

/// Apply fuse passes to `input` and return the rewritten IR plus an
/// old-to-new node-index map. The rewrite is structural: the old IR
/// is read-only during the walk, the new IR inherits the same arena
/// (every allocation lands in the arena that owns `input`), so the
/// caller's arena lifetime covers both.
///
/// Extra-data and string_buf are bulk-copied up front. Op payloads
/// reference these arrays by absolute index (`Node.extra`, plus
/// `(offset, len)` pairs into `string_buf`); copying the full slices
/// keeps every existing index valid without per-op slot-count
/// bookkeeping. New `load_path` payloads are then appended at the
/// tail of each array. Nodes themselves are re-emitted in fresh order
/// because folding removes intermediate `pipe`/`load_field` nodes — a
/// new `load_path` replaces the chain — so child indices need
/// remapping. Auxiliary tables that point into the IR by node index
/// (Lowerer's `function_table.body_ir_root`) consult `Result.index_map`
/// to update their references.
pub fn fuse(input: ir.IR) error{OutOfMemory}!Result {
    // Empty IR: emit returns immediately, fuse follows. Lowering always
    // produces ≥1 node for a non-empty AST so this path is only hit on
    // malformed inputs.
    if (input.nodes.items.len == 0) return .{ .ir = input, .index_map = &.{} };

    var out = ir.IR.init(input.arena);
    const alloc = out.arena.allocator();

    // Bulk-copy the immutable scalar payload arrays. `extra` indices on
    // copied nodes stay valid because they reference these arrays by
    // absolute position. New fuse payloads (`load_path`) append at the
    // tail and never overlap the lower-time region.
    try out.string_buf.appendSlice(alloc, input.string_buf.items);
    try out.extra_data.appendSlice(alloc, input.extra_data.items);

    // Sentinel-fill the index map; every visited node overwrites its
    // slot. The sentinel value `maxInt(u32)` is also the
    // `BODY_IR_NOT_LOWERED` sentinel used by `function_table` —
    // chosen so a stale lookup against an unvisited entry still trips
    // emit's existing assertion path rather than silently miscompiling.
    const map = try alloc.alloc(u32, input.nodes.items.len);
    @memset(map, std.math.maxInt(u32));

    var ctx = WalkCtx{ .src = &input, .out = &out, .index_map = map };
    const root_idx: u32 = @intCast(input.nodes.items.len - 1);
    _ = try copyAndFold(&ctx, root_idx);

    return .{ .ir = out, .index_map = map };
}

// ── Implementation ─────────────────────────────────────────────────────────

/// Walk context passed by pointer through the recursion. Bundles the
/// read-only source IR, the mutable destination IR, and the running
/// `[old_idx → new_idx]` map. Avoids threading three parameters
/// through every helper.
const WalkCtx = struct {
    src: *const ir.IR,
    out: *ir.IR,
    index_map: []u32,

    fn record(self: *WalkCtx, src_idx: u32, new_idx: u32) void {
        // First-write wins. Lowering's IR is a tree (no shared
        // subtrees), so each src_idx is visited exactly once. Folded
        // pipe-chain interior indices are recorded en-masse against
        // the synthesized `load_path` index in `tryFoldLoadPath`.
        std.debug.assert(self.index_map[src_idx] == std.math.maxInt(u32));
        self.index_map[src_idx] = new_idx;
    }
};

/// Walk `src_idx`, copy the subtree into the destination, and apply
/// the load-path fold rule whenever a pipe-tree is encountered.
/// Returns the index of the copied/folded node in `out`. Pipe trees
/// route through the linearized fold so multi-segment chains separated
/// by chain-breakers (`iterate`, `load_index`, etc.) still fuse each
/// run of `load_field`s individually — matching legacy bytecode-level
/// fuse semantics.
fn copyAndFold(ctx: *WalkCtx, src_idx: u32) error{OutOfMemory}!u32 {
    const node = ctx.src.nodes.items[src_idx];
    if (node.op == .pipe) return foldPipeTree(ctx, src_idx);
    return copyNode(ctx, src_idx);
}

/// Linearize the pipe tree rooted at `pipe_idx`, collapse every
/// maximal run of consecutive `load_field` leaves into a single
/// `load_path` EmitOp, then rebuild a left-deep pipe tree from the
/// resulting sequence. Replicates the bytecode-stream fold behavior
/// from the pre-Phase-2R pipeline, applied to the IR-tree shape instead.
///
/// Non-`load_field` leaves recurse through `copyAndFold` themselves —
/// e.g. an `obj_ctor` value containing its own pipe-chain still folds.
/// Every consumed source node (the pipe joins + load_field leaves) is
/// recorded in `index_map`; its new-IR target is the rebuilt pipe-tree
/// root so external references (cat-9 `body_ir_root`) still land on
/// the semantically equivalent replacement.
fn foldPipeTree(ctx: *WalkCtx, pipe_idx: u32) error{OutOfMemory}!u32 {
    // Step 1 — linearize. Collect every leaf (anything that isn't a
    // `pipe` node) in source order; remember every visited pipe node
    // so the index_map can be patched after the rebuild.
    var leaves: LeafList = .{};
    var pipes_consumed: ConsumedList = .{};
    if (!collectLeaves(ctx.src, pipe_idx, &leaves, &pipes_consumed)) {
        // Buffer overflow — fall back to a leaf-by-leaf copy without
        // folding. Pathological pipe-trees still compile correctly.
        return copyNode(ctx, pipe_idx);
    }

    // Step 2 — group + fold consecutive load_field runs. Each output
    // segment is either a pre-existing leaf (copied via copyAndFold)
    // or a freshly-emitted load_path collapsing a run of ≥2 leaves.
    var segments: SegmentList = .{};
    var i: usize = 0;
    const leaves_slice = leaves.slice();
    while (i < leaves_slice.len) : (i += 0) {
        // Scan the maximal load_field run starting at `i`.
        var j: usize = i;
        while (j < leaves_slice.len and leaves_slice[j].op == .load_field) : (j += 1) {}
        const run_len = j - i;

        if (run_len >= 2) {
            const new_idx = try emitLoadPathFromLeaves(ctx, leaves_slice[i..j]);
            // Every consumed `load_field` maps to the synthesized
            // `load_path` so `body_ir_root` lookups land somewhere
            // semantically equivalent.
            for (leaves_slice[i..j]) |leaf| ctx.record(leaf.src_idx, new_idx);
            segments.push(new_idx) catch return error.OutOfMemory;
            i = j;
        } else if (run_len == 1) {
            // Single load_field: copy verbatim — emit's `load_field`
            // handler already produces `Instruction.Op.load_key`.
            const new_idx = try copyNode(ctx, leaves_slice[i].src_idx);
            segments.push(new_idx) catch return error.OutOfMemory;
            i += 1;
        } else {
            // Non-load_field leaf: recurse through copyAndFold so
            // any nested pipe-trees get their own fold pass.
            const new_idx = try copyAndFold(ctx, leaves_slice[i].src_idx);
            segments.push(new_idx) catch return error.OutOfMemory;
            i += 1;
        }
    }

    // Step 3 — rebuild a left-deep pipe tree from `segments`. The
    // root pipe carries the original tree's outermost src span so
    // diagnostics/path() snapshots still highlight the full source
    // range.
    const root = ctx.src.nodes.items[pipe_idx];
    const new_root = try rebuildPipeTree(ctx.out, segments.slice(), root);

    // Step 4 — patch the index_map. Every consumed pipe node maps to
    // the rebuilt root (the natural semantic replacement). Folded
    // load_field leaves were already mapped above; standalone leaves
    // were mapped by their copyNode call. All consumed pipe indices
    // get the new root.
    for (pipes_consumed.slice()) |old_idx| ctx.record(old_idx, new_root);

    return new_root;
}

/// In-order walk of the pipe tree rooted at `node_idx`. Pipe nodes
/// are followed; every non-pipe node is appended to `leaves` as a
/// leaf segment. Every visited pipe is appended to `pipes` so the
/// caller can update `index_map` after the rebuild. Returns false if
/// either bounded buffer overflows.
fn collectLeaves(
    src_ir: *const ir.IR,
    node_idx: u32,
    leaves: *LeafList,
    pipes: *ConsumedList,
) bool {
    const node = src_ir.nodes.items[node_idx];
    if (node.op != .pipe) {
        leaves.push(.{ .src_idx = node_idx, .op = node.op }) catch return false;
        return true;
    }
    if (!collectLeaves(src_ir, node.children[0], leaves, pipes)) return false;
    if (!collectLeaves(src_ir, node.children[1], leaves, pipes)) return false;
    pipes.push(node_idx) catch return false;
    return true;
}

/// Materialize a `load_path` node from a run of `load_field` leaves.
/// The dot-joined name is interned into `out.string_buf`; the new
/// node's source span covers from the first key's start to the last
/// key's end so error diagnostics and `path()` dumps still highlight
/// the original chain text. Mirrors legacy
/// `internPath`/`load_path`-emit at `compiler.zig:7164-7228`.
fn emitLoadPathFromLeaves(ctx: *WalkCtx, leaves: []const Leaf) error{OutOfMemory}!u32 {
    std.debug.assert(leaves.len >= 2);
    const out = ctx.out;
    const alloc = out.arena.allocator();

    // Resolve each leaf's `(offset, len)` against the source IR's
    // string_buf — bytes are then re-interned into the OUTPUT IR's
    // string_buf below. Doing the lookup here (vs in `collectLeaves`)
    // keeps the linearization step allocation-free for the common case
    // where no run requires a fold.
    const src_strings = ctx.src.string_buf.items;
    const src_extra = ctx.src.extra_data.items;

    // Compute total joined length up front so we can do a single
    // ensureTotalCapacity against `out.string_buf` and avoid mid-loop
    // realloc-then-aliased-slice trouble.
    const total_len = blk: {
        var n: usize = leaves.len - 1; // dot separators
        for (leaves) |leaf| {
            const node = ctx.src.nodes.items[leaf.src_idx];
            const len: u32 = src_extra[node.extra + 1];
            n += len;
        }
        break :blk n;
    };
    const offset: u32 = @intCast(out.string_buf.items.len);
    try out.string_buf.ensureTotalCapacity(alloc, out.string_buf.items.len + total_len);
    for (leaves, 0..) |leaf, i| {
        if (i > 0) out.string_buf.appendAssumeCapacity('.');
        const node = ctx.src.nodes.items[leaf.src_idx];
        const off: u32 = src_extra[node.extra];
        const len: u32 = src_extra[node.extra + 1];
        out.string_buf.appendSliceAssumeCapacity(src_strings[off .. off + len]);
    }

    const extra_idx: u32 = @intCast(out.extra_data.items.len);
    try out.extra_data.append(alloc, offset);
    try out.extra_data.append(alloc, @intCast(total_len));

    // Span covers leftmost-key-start through rightmost-key-end.
    const first_node = ctx.src.nodes.items[leaves[0].src_idx];
    const last_node = ctx.src.nodes.items[leaves[leaves.len - 1].src_idx];
    const src_start = first_node.src_start;
    const src_end = last_node.src_start + last_node.src_len;

    const new_idx: u32 = @intCast(out.nodes.items.len);
    try out.nodes.append(alloc, .{
        .op = .load_path,
        .extra = extra_idx,
        .src_start = src_start,
        .src_len = if (src_end >= src_start) src_end - src_start else 0,
    });
    return new_idx;
}

/// Rebuild a left-deep pipe tree from `segments`. A single segment
/// returns its index unchanged (no pipe needed); multiple segments
/// produce `pipe(pipe(...pipe(s0, s1)...sN-2), sN-1)`. Each new pipe's
/// source span unions its children's spans so diagnostics still reach
/// the correct source bytes after the rewrite. The outermost pipe also
/// expands to cover `original_root.src_*` so path() error reports still
/// highlight the entire original chain text.
fn rebuildPipeTree(out: *ir.IR, segments: []const u32, original_root: ir.Node) error{OutOfMemory}!u32 {
    std.debug.assert(segments.len >= 1);
    if (segments.len == 1) return segments[0];

    const alloc = out.arena.allocator();
    var current = segments[0];
    for (segments[1..], 1..) |right, i| {
        const left_node = out.nodes.items[current];
        const right_node = out.nodes.items[right];
        var src_start = @min(left_node.src_start, right_node.src_start);
        var src_end = @max(
            left_node.src_start + left_node.src_len,
            right_node.src_start + right_node.src_len,
        );
        // Outermost pipe: ensure span covers the original tree's root
        // span — handles edge cases where leading/trailing whitespace
        // around the chain made the pre-fold pipe span wider than the
        // union of its leaves.
        if (i == segments.len - 1) {
            src_start = @min(src_start, original_root.src_start);
            src_end = @max(src_end, original_root.src_start + original_root.src_len);
        }
        const new_idx: u32 = @intCast(out.nodes.items.len);
        try out.nodes.append(alloc, .{
            .op = .pipe,
            .children = .{ current, right },
            .src_start = src_start,
            .src_len = if (src_end >= src_start) src_end - src_start else 0,
        });
        current = new_idx;
    }
    return current;
}

/// Copy `src_idx` from the source IR into the destination, recursing
/// into children (which may themselves trigger the fold rule). Preserves
/// every node field; child indices are remapped to point into
/// `out.nodes`. The `extra` index passes through unchanged because
/// `out.extra_data` is a bulk-copy of `src_ir.extra_data` (see `fuse`
/// entry point) — every pre-existing absolute payload index stays valid.
///
/// For variable-arity ops, child indices are first collected into a
/// stack-local buffer and only appended into `out.extra_children` AFTER
/// every child has been copied. This is critical: a recursive
/// `copyAndFold` may itself append to `out.extra_children` (for its own
/// children), which would otherwise interleave with this node's span and
/// fragment its layout. The bounded buffer caps span length at
/// `MAX_VAR_SPAN`; lowering does not produce variable-arity spans
/// beyond this size, so the cap is unreachable in practice (assert in
/// debug builds catches a regression at lowering).
fn copyNode(ctx: *WalkCtx, src_idx: u32) error{OutOfMemory}!u32 {
    const node = ctx.src.nodes.items[src_idx];
    const alloc = ctx.out.arena.allocator();

    var new_children: [2]u32 = .{ 0, 0 };
    var new_span_start: u32 = 0;
    const new_span_len: u32 = node.span_len;
    if (node.span_len > 0) {
        // Variable-arity: copy each child via copyAndFold, accumulate
        // new indices into a contiguous buffer, then bulk-append into
        // `out.extra_children`. The bulk-append captures
        // `new_span_start` AFTER all recursive copies have grown
        // `out.extra_children`, so the parent's span lands in a
        // contiguous tail-allocated region. Small spans use a stack
        // buffer; oversized spans spill into the arena to keep the
        // recursion-frame size bounded.
        const span_end = node.span_start + node.span_len;
        const src_children = ctx.src.extra_children.items[node.span_start..span_end];
        if (node.span_len <= MAX_VAR_SPAN) {
            var local_children: [MAX_VAR_SPAN]u32 = undefined;
            for (src_children, 0..) |child_src_idx, i| {
                local_children[i] = try copyAndFold(ctx, child_src_idx);
            }
            new_span_start = @intCast(ctx.out.extra_children.items.len);
            try ctx.out.extra_children.appendSlice(alloc, local_children[0..node.span_len]);
        } else {
            const heap_children = try alloc.alloc(u32, node.span_len);
            // The heap-spill buffer lives in the arena and dies with
            // the compile; no `defer free` needed.
            for (src_children, 0..) |child_src_idx, i| {
                heap_children[i] = try copyAndFold(ctx, child_src_idx);
            }
            new_span_start = @intCast(ctx.out.extra_children.items.len);
            try ctx.out.extra_children.appendSlice(alloc, heap_children);
        }
    } else {
        // Fixed-arity: copy whichever children slots the op uses. The
        // start/end pair lets `update_assign`'s fast-path shape skip
        // its sentinel `children[0]` (real children live at the
        // single index `children[1]`). Leaves (load_field, identity,
        // etc.) hit `[0, 0)` and skip the recursion entirely.
        const arity = childArity(ctx, node);
        const start = arity[0];
        const end = arity[1];
        var i: u8 = start;
        while (i < end) : (i += 1) {
            new_children[i] = try copyAndFold(ctx, node.children[i]);
        }
    }

    const new_idx: u32 = @intCast(ctx.out.nodes.items.len);
    try ctx.out.nodes.append(alloc, .{
        .op = node.op,
        .children = new_children,
        .span_start = new_span_start,
        .span_len = new_span_len,
        // Bulk-copied `extra_data` keeps absolute payload indices
        // stable, so a copied node's `extra` passes through verbatim.
        // Newly-folded `load_path` nodes get a fresh `extra` written
        // by `emitLoadPath` directly.
        .extra = node.extra,
        .src_start = node.src_start,
        .src_len = node.src_len,
    });
    ctx.record(src_idx, new_idx);
    return new_idx;
}

/// Cap on a variable-arity node's span length, used to size the
/// `local_children` buffer in `copyNode`. Lowering's wide nodes
/// (`obj_ctor`, `arr_ctor`, `interp`, `call_*`, `destructure`) all
/// stay well under this in real filters. The buffer is stack-allocated
/// per `copyNode` frame; sizing it small keeps recursion stack bounded.
/// Larger spans take the heap-fallback path so unusual filters still
/// fuse correctly.
const MAX_VAR_SPAN: usize = 64;

/// Children-arity for the fixed-arity (`children[0..N]`) shape — used
/// when `span_len == 0`. Variable-arity ops (`if_`, `reduce`,
/// `foreach`, `obj_ctor`, `arr_ctor`, `interp`, `call_*`,
/// `destructure`) always carry their children via `extra_children` and
/// never hit this path.
///
/// `update_assign` is special: the fast-path shape (`UpdateOpKind` !=
/// `.general`) stores the LHS path inline in `extra_data` and uses
/// `children[0] == 0` as a "no-LHS" sentinel — the only real child is
/// `children[1]` (the RHS). The general form (`.general`) stores both
/// LHS and RHS as IR children. We discriminate by reading the kind
/// from extra_data so the wrong slot isn't copied as a stray ref to
/// node 0.
fn childArity(ctx: *const WalkCtx, node: ir.Node) struct { u8, u8 } {
    return switch (node.op) {
        .pipe, .comma, .arith, .cmp, .logical, .alt, .while_, .until_, .computed_index => .{ 0, 2 },
        // `not` is lowered as a leaf — it operates on the implicit
        // current input and consumes no IR child (`lower.zig:1539`).
        // `neg`, `try_`, and `path_begin` carry their operand at
        // `children[0]`. `label` is unary — body lives in `children[0]`.
        // `extra_data`). `computed_index` is binary — base at
        // `children[0]`, key at `children[1]` (handled by the
        // binary-arity row above alongside `.pipe`/`.comma`/etc).
        .try_, .neg, .path_begin, .label => .{ 0, 1 },
        // `computed_slice` carries up to two child expressions
        // (`from_expr` at children[0], `to_expr` at children[1]) gated
        // by flag bits 2 and 3 in `extra_data[extra+2]`. Unused slots
        // hold sentinel `0` and must be skipped during the copy walk
        // so a stray ref to node 0 isn't introduced. The suffix-form
        // case (flag bit 4 has_base) lifts all children into
        // `extra_children` and uses the variable-arity copy path —
        // this fixed-arity arm only fires for the no-base shape.
        .computed_slice => blk: {
            const flags: u32 = ctx.src.extra_data.items[node.extra + 2];
            const has_from_expr = (flags & 4) != 0;
            const has_to_expr = (flags & 8) != 0;
            if (has_from_expr and has_to_expr) break :blk .{ 0, 2 };
            if (has_from_expr) break :blk .{ 0, 1 };
            if (has_to_expr) break :blk .{ 1, 2 };
            break :blk .{ 0, 0 };
        },
        .update_assign => blk: {
            const kind: ir.UpdateOpKind = @enumFromInt(ctx.src.extra_data.items[node.extra]);
            break :blk if (kind == .general) .{ 0, 2 } else .{ 1, 2 }; // skip slot 0 (sentinel) for fast path
        },
        else => .{ 0, 0 },
    };
}

// ── Bounded inline buffers ─────────────────────────────────────────────────
//
// Pipe-trees in real filters are short (≤ a few dozen leaves). We
// avoid heap allocations by stack-allocating inline buffers; if a
// pathological input exceeds the bound the fold falls back to a
// straight `copyNode` walk — no correctness loss, just no fold for
// that particular tree.

/// One linearized leaf collected during the in-order pipe walk.
/// `src_idx` is the leaf's index in the source IR; `op` is cached so
/// `foldPipeTree` can group `load_field` runs without re-fetching the
/// node. Run-grouping reads `op` only; `emitLoadPathFromLeaves`
/// resolves payloads against `ctx.src` via `src_idx`.
const Leaf = struct {
    src_idx: u32,
    op: ir.Op,
};

/// Bounded stack buffer of linearized pipe-tree leaves. The cap is
/// generous compared to real-world inputs (jq filters typically
/// stay under a dozen segments). Overflow falls back to `copyNode` —
/// a 128-segment pipe tree still compiles correctly via the unfolded
/// path.
const MAX_LEAVES: usize = 128;

const LeafList = struct {
    items: [MAX_LEAVES]Leaf = undefined,
    len: usize = 0,

    fn push(self: *LeafList, l: Leaf) error{Overflow}!void {
        if (self.len == MAX_LEAVES) return error.Overflow;
        self.items[self.len] = l;
        self.len += 1;
    }

    fn slice(self: *const LeafList) []const Leaf {
        return self.items[0..self.len];
    }
};

/// Bounded stack buffer of new-IR segment indices. Each fold-pass
/// produces at most one segment per leaf (consecutive load_field runs
/// collapse into ONE segment, which only makes the count smaller), so
/// `MAX_LEAVES` is a sound upper bound.
const SegmentList = struct {
    items: [MAX_LEAVES]u32 = undefined,
    len: usize = 0,

    fn push(self: *SegmentList, idx: u32) error{Overflow}!void {
        if (self.len == MAX_LEAVES) return error.Overflow;
        self.items[self.len] = idx;
        self.len += 1;
    }

    fn slice(self: *const SegmentList) []const u32 {
        return self.items[0..self.len];
    }
};

/// Bounded stack buffer of source-IR pipe indices consumed by a
/// linearization. Each pipe in the source tree contributes one
/// element — they all map to the rebuilt-tree root in the index_map
/// after fold completes. A pipe tree with N leaves has N−1 pipe
/// joins, so `MAX_LEAVES` is a safe upper bound.
const MAX_CONSUMED: usize = MAX_LEAVES;

const ConsumedList = struct {
    items: [MAX_CONSUMED]u32 = undefined,
    len: usize = 0,

    fn push(self: *ConsumedList, idx: u32) error{Overflow}!void {
        if (self.len == MAX_CONSUMED) return error.Overflow;
        self.items[self.len] = idx;
        self.len += 1;
    }

    fn slice(self: *const ConsumedList) []const u32 {
        return self.items[0..self.len];
    }
};
