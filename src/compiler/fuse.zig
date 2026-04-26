//! IR rewrite passes — Phase 2R / R3 step 8.
//!
//! Single rule today: chained static-key field loads collapse to one
//! `load_path` EmitOp. `.a | .b | .c` lowers to a left-deep
//! `pipe(pipe(load_field("a"), load_field("b")), load_field("c"))` IR;
//! this pass rewrites that subtree to a single `load_path("a.b.c")`
//! whose extra-data payload mirrors `load_field`'s (offset/len into
//! string_buf). Plan §3 R3 step 8: "port legacy's `.a | .b | .c` →
//! `load_path` fold into `fuse.zig` as one IR→IR pass. Other fuse
//! opportunities deferred."
//!
//! Mirrors the legacy fuse at `src/query/src/compiler.zig:7186` — a
//! pipe whose every leaf is `load_field` collapses; any non-`load_field`
//! leaf (e.g. `iterate`, `try_`, `load_index`) breaks the chain. A
//! single-key chain (just one `load_field`) is NOT folded — emit's
//! `load_field` handler already produces the same `Instruction.Op.load_key`
//! the legacy compiler emits, so wrapping it in `load_path` would be
//! pure overhead.
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
/// the load-path fold rule whenever a pipe-chain of `load_field`s is
/// detected. Returns the index of the copied/folded node in `out`.
fn copyAndFold(ctx: *WalkCtx, src_idx: u32) error{OutOfMemory}!u32 {
    // Path-fold attempt: if this node is a pipe-chain of `load_field`s,
    // collapse it now. Returns the new index on a successful fold;
    // null when the chain is broken (any non-`load_field` leaf, or a
    // single-key chain).
    if (try tryFoldLoadPath(ctx, src_idx)) |folded_idx| return folded_idx;

    // Default: copy this node, recursing into children. Any subtree
    // beneath us may still trigger the fold rule independently.
    return copyNode(ctx, src_idx);
}

/// Detect and fold a chained-load-path subtree rooted at `src_idx`.
/// Returns the index of the new `load_path` node on success, null when
/// the subtree is not a fold candidate (single-key chain or any
/// non-`load_field` leaf in the chain).
fn tryFoldLoadPath(ctx: *WalkCtx, src_idx: u32) error{OutOfMemory}!?u32 {
    const root = ctx.src.nodes.items[src_idx];
    if (root.op != .pipe) return null;

    // Collect every leaf along the pipe-chain into a key list. The
    // collector walks pipe nodes greedily; a non-`load_field` leaf at
    // any position aborts the fold (returns null).
    var keys: KeyList = .{};
    var consumed: ConsumedList = .{};
    if (!collectChainKeys(ctx.src, src_idx, &keys, &consumed)) return null;

    // Single-key "chains" don't benefit — `load_field` already maps
    // straight to legacy `Instruction.Op.load_key`. Mirrors legacy
    // fuse's `if (keys.items.len == 1) .load_key else .load_path`.
    if (keys.len < 2) return null;

    const new_idx = try emitLoadPath(ctx.out, root, &keys);
    // Every old index consumed by the fold (the chain's pipe joins +
    // load_field leaves) maps to the new `load_path` node — keeps the
    // index_map total over `src.nodes` even when nodes vanish in the
    // rewrite.
    for (consumed.slice()) |old_idx| ctx.record(old_idx, new_idx);
    return new_idx;
}

/// Walk a pipe-chain rooted at `node_idx` and collect every leaf into
/// `keys` and every visited node into `consumed`. Returns false (and
/// leaves both lists partially populated) on the first non-fusable
/// shape so the caller bails on the fold. A fusable shape is
/// recursive: a `pipe` whose left and right are both fusable, OR a
/// `load_field` leaf.
fn collectChainKeys(
    src_ir: *const ir.IR,
    node_idx: u32,
    keys: *KeyList,
    consumed: *ConsumedList,
) bool {
    const node = src_ir.nodes.items[node_idx];
    switch (node.op) {
        .load_field => {
            const slots = src_ir.extra_data.items;
            const offset: u32 = slots[node.extra];
            const len: u32 = slots[node.extra + 1];
            keys.push(.{
                .name = src_ir.string_buf.items[offset .. offset + len],
                .src_start = node.src_start,
                .src_len = node.src_len,
            }) catch return false;
            consumed.push(node_idx) catch return false;
            return true;
        },
        .pipe => {
            // Walk left then right so the resulting key list is in
            // source order — `pipe(pipe(.a, .b), .c)` yields `[a, b, c]`,
            // mirroring `.a | .b | .c`.
            if (!collectChainKeys(src_ir, node.children[0], keys, consumed)) return false;
            if (!collectChainKeys(src_ir, node.children[1], keys, consumed)) return false;
            consumed.push(node_idx) catch return false;
            return true;
        },
        else => return false,
    }
}

/// Materialize the folded `load_path` IR node. The dot-joined name is
/// interned into `out.string_buf`; the resulting `(offset, len)` pair
/// is appended to `out.extra_data`. The new node's source span starts
/// at the leftmost key's `src_start` and ends one past the rightmost
/// key's `src_start + src_len` — preserves the chain's source coverage
/// so `path()` snapshots and error diagnostics stay accurate.
fn emitLoadPath(out: *ir.IR, root: ir.Node, keys: *const KeyList) error{OutOfMemory}!u32 {
    const alloc = out.arena.allocator();

    // Intern dot-joined path into the new IR's string_buf. The offset
    // is the index into `out.string_buf` BEFORE the appendSlice runs;
    // the joined length is computed up-front so `extra_data` writes
    // need no fix-up pass.
    const offset: u32 = @intCast(out.string_buf.items.len);
    const total_len = blk: {
        var n: usize = keys.len - 1; // dot separators
        for (keys.slice()) |k| n += k.name.len;
        break :blk n;
    };
    try out.string_buf.ensureTotalCapacity(alloc, out.string_buf.items.len + total_len);
    for (keys.slice(), 0..) |k, i| {
        if (i > 0) out.string_buf.appendAssumeCapacity('.');
        out.string_buf.appendSliceAssumeCapacity(k.name);
    }

    const extra_idx: u32 = @intCast(out.extra_data.items.len);
    try out.extra_data.append(alloc, offset);
    try out.extra_data.append(alloc, @intCast(total_len));

    // Span: leftmost key's start through rightmost key's end. Preserves
    // the chain's source coverage so error diagnostics and `path()`
    // dumps still highlight the original `.a | .b | .c` text.
    const first = keys.slice()[0];
    const last = keys.slice()[keys.len - 1];
    const start = first.src_start;
    const end = last.src_start + last.src_len;
    const src_start = @min(start, root.src_start);
    const src_end = @max(end, root.src_start + root.src_len);

    const new_idx: u32 = @intCast(out.nodes.items.len);
    try out.nodes.append(alloc, .{
        .op = .load_path,
        .extra = extra_idx,
        .src_start = src_start,
        .src_len = if (src_end >= src_start) src_end - src_start else 0,
    });
    return new_idx;
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
        .pipe, .comma, .arith, .cmp, .logical, .alt => .{ 0, 2 },
        // `not` is lowered as a leaf — it operates on the implicit
        // current input and consumes no IR child (`lower.zig:1539`).
        // `neg`, `try_`, and `path_begin` carry their operand at
        // `children[0]`.
        .try_, .neg, .path_begin => .{ 0, 1 },
        .update_assign => blk: {
            const kind: ir.UpdateOpKind = @enumFromInt(ctx.src.extra_data.items[node.extra]);
            break :blk if (kind == .general) .{ 0, 2 } else .{ 1, 2 }; // skip slot 0 (sentinel) for fast path
        },
        else => .{ 0, 0 },
    };
}

// ── Bounded inline buffers ─────────────────────────────────────────────────
//
// Pipe-chains in real filters are short (≤ a few dozen segments). We
// avoid heap allocations by stack-allocating inline buffers; if a
// pathological input exceeds the bound the fold simply bails and the
// chain stays as nested pipes — no correctness loss.

/// Single key collected during the chain walk. Carries a slice
/// referencing the input IR's `string_buf` (read-only — we re-intern
/// the dot-joined name into the OUTPUT IR before the input becomes
/// unused), plus the source-byte span used to recompute the folded
/// node's coverage.
const Key = struct {
    name: []const u8,
    src_start: u32,
    src_len: u32,
};

/// Bounded stack buffer of keys collected from a chain. The cap is
/// generous compared to real-world inputs (longest jq pipe-chains in
/// the wild are ≤8 segments). Hitting the cap aborts the fold rather
/// than spilling to the heap — a pathological 64-segment chain still
/// runs correctly via the unfolded pipe path.
const MAX_CHAIN_KEYS: usize = 64;

const KeyList = struct {
    items: [MAX_CHAIN_KEYS]Key = undefined,
    len: usize = 0,

    fn push(self: *KeyList, k: Key) error{Overflow}!void {
        if (self.len == MAX_CHAIN_KEYS) return error.Overflow;
        self.items[self.len] = k;
        self.len += 1;
    }

    fn slice(self: *const KeyList) []const Key {
        return self.items[0..self.len];
    }
};

/// Bounded stack buffer of source-IR indices consumed by a fold. Used
/// to populate the index_map after the synthesized `load_path` is
/// pushed — every fused interior pipe and `load_field` leaf maps to
/// the new `load_path` index. A chain of N keys consumes
/// `N + (N - 1)` nodes (N leaves + N−1 pipe joins) so the cap is sized
/// generously above `2 * MAX_CHAIN_KEYS`.
const MAX_CONSUMED: usize = 2 * MAX_CHAIN_KEYS;

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
