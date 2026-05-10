//! IR-based prefilter harvesting for the Phase 2R compiler.
//!
//! This module harvests regex literal groups from the IR (not the AST) after
//! lowering and fuse have completed. The key advantage over the legacy
//! compiler's AST-based harvest is that we avoid a second AST parse — the IR
//! is already in memory from the normal compile pipeline.
//!
//! Matches the exact idiom:
//!
//!     select( <pure-accessor> | <regex-builtin>("<literal>" [; "<flags>"]) )
//!
//! where <regex-builtin> is `test` or `scan` only. Other regex builtins are
//! not prefilter-safe (match/capture can error, splits can return non-empty
//! on no-match, sub/gsub are mutators).
//!
//! The harvester walks the IR DAG read-only, inspecting node structure and
//! string_buf contents to detect the idiom. No IR mutations occur.
//!
//! OOM safety: on allocation failure, the harvest simply returns — the
//! filter still runs correctly, just without the prefilter optimization.

const std = @import("std");
const regex_mod = @import("regex");
const ir = @import("ir.zig");
const types_mod = @import("types");
const projection_plan_mod = @import("projection_plan");
const build_options = @import("build_options");

pub const enabled = regex_mod.enabled;
pub const ProjectionPlan = projection_plan_mod.ProjectionPlan;
pub const PlanNode = projection_plan_mod.PlanNode;
pub const PlanNodeKind = projection_plan_mod.PlanNodeKind;
pub const Predicate = projection_plan_mod.Predicate;
pub const PredicateOp = projection_plan_mod.PredicateOp;
pub const Literal = projection_plan_mod.Literal;

/// Harvested literal group — compatible with prefilter.LiteralGroup.
pub const LiteralGroup = struct {
    literals: [][]const u8,
    all_required: bool,
};

/// Harvest prefilter literal groups from the IR into `out`.
///
/// Appends zero or one `LiteralGroup` depending on whether the IR root matches
/// the supported `select(... | test|scan("lit"[; "flags"]))` idiom. Never
/// rejects on shape mismatch — absence of a group is the default.
///
/// The IR walk is read-only; no mutations to the IR occur.
///
/// ## Correctness
///
/// The harvester only extracts literals when the filter shape guarantees that
/// a record whose regex doesn't match will never be output. This holds for:
///   - `select(pure-accessor | test("lit"))` — test returns false on no-match
///   - `select(pure-accessor | scan("lit"))` — scan returns null on no-match
///
/// Other regex builtins are excluded:
///   - `match`/`capture` raise TypeError on no-match — skipping would hide errors
///   - `splits` returns the original string on no-match (non-empty)
///   - `sub`/`gsub` are mutators, not filters
///
/// ## IR shape matched
///
/// ```
/// root (last node): call_builtin("select")
///   children[0]: pipe
///     children[0]: pure accessor chain (load_field, load_index, iterate, slice, identity, recurse)
///     children[1]: call_builtin("test") or call_builtin("scan")
///       extra_data[extra+2]: pool_idx (REGEX_POOL_DYNAMIC means dynamic pattern → bail)
///       extra_data[extra+3]: n_flag
/// ```
///
/// Pure accessor detection is recursive: a chain of `pipe` nodes whose leaves
/// are all pure operations (field/index/iterate/slice/identity/recurse/try).
/// Any other op (load_var, call_user, arith, cmp, logical, etc.) invalidates.
pub fn harvestFromIr(
    alloc: std.mem.Allocator,
    ir_obj: *const ir.IR,
    regex_pool: *const regex_mod.RegexPool,
    out: *std.ArrayList(LiteralGroup),
) error{OutOfMemory}!void {
    if (!enabled) return;
    if (ir_obj.nodes.items.len == 0) return;

    // IR root is the last node (lowering is post-order).
    const root_idx: u32 = @intCast(ir_obj.nodes.items.len - 1);
    const root = ir_obj.nodes.items[root_idx];

    // Root must be `select(...)`.
    const builtin_name = getBuiltinName(ir_obj, root) orelse return;
    if (!std.mem.eql(u8, builtin_name, "select")) return;

    // select must have exactly one child (the body).
    if (root.children[0] == 0 and root.span_len == 0) return;
    const body_idx = if (root.span_len == 0) root.children[0] else blk: {
        // Variadic case: check first child in span.
        if (root.span_len == 0) return;
        break :blk ir_obj.extra_children.items[root.span_start];
    };
    const body = ir_obj.nodes.items[body_idx];

    // Body must be a pipe.
    if (body.op != .pipe) return;
    const left_idx = body.children[0];
    const right_idx = body.children[1];

    // Left side of pipe must be a pure accessor.
    if (!isPureAccessor(ir_obj, left_idx)) return;

    // Right side must be test or scan.
    const right = ir_obj.nodes.items[right_idx];
    const regex_name = getBuiltinName(ir_obj, right) orelse return;
    const is_test = std.mem.eql(u8, regex_name, "test");
    const is_scan = std.mem.eql(u8, regex_name, "scan");
    if (!is_test and !is_scan) return;

    // Extract pool_idx from extra_data.
    // Layout: name_off, name_len, pool_idx, n_flag
    const pool_idx_slot = right.extra + 2;
    if (pool_idx_slot >= ir_obj.extra_data.items.len) return;
    const pool_idx = ir_obj.extra_data.items[pool_idx_slot];

    // REGEX_POOL_DYNAMIC means the pattern was dynamic — not harvestable.
    if (pool_idx == types_mod.REGEX_POOL_DYNAMIC) return;

    // Get the regex from the pool and extract literals.
    const regex_ptr = regex_pool.get(pool_idx);
    const group = try extractLiteralGroup(alloc, regex_ptr) orelse return;
    try out.append(alloc, group);
}

/// Extract a literal group from a compiled regex.
/// Mirrors the logic in `prefilter.groupFromRegex` but avoids the circular import.
fn extractLiteralGroup(alloc: std.mem.Allocator, regex: *const regex_mod.Regex) error{OutOfMemory}!?LiteralGroup {
    const lits = regex.requiredLiterals() orelse return null;
    const count = lits.count();
    if (count == 0) return null;

    const MIN_LITERAL_LEN: usize = 2;

    // First pass: count how many literals survive the safety filter.
    var safe_count: usize = 0;
    var any_unsafe_dropped = false;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const b = lits.at(i);
        if (b.len >= MIN_LITERAL_LEN) safe_count += 1 else any_unsafe_dropped = true;
    }

    // If the set is exhaustive (AND) and any literal was dropped, we've lost
    // information — downgrade to OR-semantics over the safe subset.
    const is_exhaustive_src = lits.isExhaustive();
    const effective_all_required = is_exhaustive_src and !any_unsafe_dropped;

    // If the set is OR (alternation) and ANY literal was dropped, we lose
    // coverage — disable prefilter for this group entirely.
    if (!is_exhaustive_src and any_unsafe_dropped) {
        return null;
    }
    if (safe_count == 0) return null;

    const out = try alloc.alloc([]const u8, safe_count);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |l| alloc.free(l);
        alloc.free(out);
    }
    i = 0;
    while (i < count) : (i += 1) {
        const b = lits.at(i);
        if (b.len < MIN_LITERAL_LEN) continue;
        const copy = try alloc.dupe(u8, b);
        out[filled] = copy;
        filled += 1;
    }

    return LiteralGroup{
        .literals = out,
        .all_required = effective_all_required,
    };
}

/// Get the builtin name from a `call_builtin` IR node. Returns null if the
/// node is not a `call_builtin` or if the name cannot be extracted.
fn getBuiltinName(ir_obj: *const ir.IR, node: ir.Node) ?[]const u8 {
    if (node.op != .call_builtin) return null;
    // extra_data layout: name_off, name_len, pool_idx, n_flag
    const name_off_idx = node.extra;
    const name_len_idx = node.extra + 1;
    if (name_off_idx >= ir_obj.extra_data.items.len) return null;
    if (name_len_idx >= ir_obj.extra_data.items.len) return null;
    const name_off = ir_obj.extra_data.items[name_off_idx];
    const name_len = ir_obj.extra_data.items[name_len_idx];
    if (name_off + name_len > ir_obj.string_buf.items.len) return null;
    return ir_obj.string_buf.items[name_off .. name_off + name_len];
}

/// Check if the IR subtree rooted at `node_idx` is a pure accessor
/// expression for the *prefilter* harvest — looser than
/// `isProjectionEligible` below because the prefilter only needs the
/// expression to be side-effect-free, not lowerable into a static
/// projection plan.
///
/// Pure accessors (prefilter sense) are chains of:
///   - identity
///   - recurse
///   - load_field / load_path
///   - load_index
///   - slice
///   - iterate
///   - try (optional)
///   - pipe (connecting the above)
///
/// `recurse` and `slice` are admitted here because the prefilter only
/// needs the literal regex to be reachable; it is safe to over-match
/// the prefilter set (false positives are filtered by the regex itself
/// at runtime). The projection-plan harvester runs the stricter
/// `isProjectionEligible` predicate that rejects both — see notes
/// there.
fn isPureAccessor(ir_obj: *const ir.IR, node_idx: u32) bool {
    const node = ir_obj.nodes.items[node_idx];
    return switch (node.op) {
        .identity => true,
        .recurse => true,
        .load_field => true,
        // EmitOp produced by fuse — semantically equivalent to a
        // pipe-chain of `load_field`s, so equally pure. Without this
        // arm any prefilter on `select(.a.b | test("…"))` would
        // regress after Phase 2R/Phase 19's load-path fold landed.
        .load_path => true,
        .load_index => true,
        .slice => true,
        // `computed_slice` carries expression bounds whose purity isn't
        // guaranteed; conservative `false` keeps the prefilter from
        // descending into a node it can't statically classify.
        .computed_slice => false,
        .iterate => true,
        .try_ => isPureAccessor(ir_obj, node.children[0]),
        .pipe => isPureAccessor(ir_obj, node.children[0]) and isPureAccessor(ir_obj, node.children[1]),
        else => false,
    };
}

/// Stricter purity check for the projection-plan harvester. Rejects
/// `recurse` (`..`) and `slice` (`.[a:b]`) because lowering them into
/// a static projection plan would require materializing every
/// reachable element — defeating the projection win. Also rejects
/// `computed_slice` (runtime-bounded slice indices). Single source of
/// truth — `lowerProjection` returns `null` for the same set, so the
/// up-front check via this function lets the harvester reject early
/// without entering the lowering recursion. Keep this function and
/// `lowerProjection`'s rejection arm in lockstep.
fn isProjectionEligible(ir_obj: *const ir.IR, node_idx: u32) bool {
    const node = ir_obj.nodes.items[node_idx];
    return switch (node.op) {
        .identity, .load_field, .load_path, .load_index, .iterate => true,
        .try_ => isProjectionEligible(ir_obj, node.children[0]),
        .pipe => isProjectionEligible(ir_obj, node.children[0]) and isProjectionEligible(ir_obj, node.children[1]),
        .slice, .computed_slice, .recurse => false,
        else => false,
    };
}

// ── Projection-plan harvester (C1) ───────────────────────────────────────────
//
// Walks the post-fuse IR DAG read-only and produces a `ProjectionPlan`
// when the entire query body is a pure path projection. Any non-pure
// IR node aborts the harvest by returning `null`. Predicate harvest is
// a separate pass that runs only after the projection plan succeeds —
// the predicate's terminal field must be reachable through the plan
// for the parser to evaluate it inline.
//
// Plan layout produced:
//   - `nodes` is densely packed; the harvester pushes nodes in
//     pre-order (root first) so the parser's plan_cursor descents are
//     a forward walk.
//   - `children` is a flat overflow array — each non-leaf node points
//     to a contiguous slice via `children_start`/`children_len`.
//   - `string_buf` holds key bytes interned during the walk and any
//     predicate string literals.

/// Per-build accumulator for the projection plan harvester. Owned by
/// `harvestProjectionPlan`; heap-allocated to keep the recursive walk
/// function lightweight.
const PlanBuilder = struct {
    alloc: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(PlanNode) = .{},
    children: std.ArrayListUnmanaged(u32) = .{},
    string_buf: std.ArrayListUnmanaged(u8) = .{},

    fn deinit(b: *PlanBuilder) void {
        b.nodes.deinit(b.alloc);
        b.children.deinit(b.alloc);
        b.string_buf.deinit(b.alloc);
    }

    fn pushNode(b: *PlanBuilder, node: PlanNode) error{OutOfMemory}!u32 {
        const idx: u32 = @intCast(b.nodes.items.len);
        try b.nodes.append(b.alloc, node);
        return idx;
    }

    fn internKey(b: *PlanBuilder, key: []const u8) error{OutOfMemory}!struct { off: u32, len: u32 } {
        const off: u32 = @intCast(b.string_buf.items.len);
        try b.string_buf.appendSlice(b.alloc, key);
        return .{ .off = off, .len = @intCast(key.len) };
    }
};

/// Decode a `load_field` IR node's key bytes from `ir.string_buf`.
/// Layout: `extra_data[node.extra]` = offset, `[node.extra+1]` = len.
fn loadFieldKey(ir_obj: *const ir.IR, node: ir.Node) ?[]const u8 {
    std.debug.assert(node.op == .load_field);
    const slots = ir_obj.extra_data.items;
    if (node.extra + 1 >= slots.len) return null;
    const off = slots[node.extra];
    const len = slots[node.extra + 1];
    if (off + len > ir_obj.string_buf.items.len) return null;
    return ir_obj.string_buf.items[off .. off + len];
}

/// Decode a `load_index` IR node's i64 index. Layout:
/// `extra_data[node.extra]` low32, `[node.extra+1]` high32.
fn loadIndexValue(ir_obj: *const ir.IR, node: ir.Node) ?i64 {
    std.debug.assert(node.op == .load_index);
    const slots = ir_obj.extra_data.items;
    if (node.extra + 1 >= slots.len) return null;
    const lo: u64 = slots[node.extra];
    const hi: u64 = slots[node.extra + 1];
    return @bitCast(lo | (hi << 32));
}

/// Decode a `load_path` IR node's joined key bytes. Layout:
/// `extra_data[node.extra]` = offset, `[node.extra+1]` = len.
fn loadPathBytes(ir_obj: *const ir.IR, node: ir.Node) ?[]const u8 {
    std.debug.assert(node.op == .load_path);
    const slots = ir_obj.extra_data.items;
    if (node.extra + 1 >= slots.len) return null;
    const off = slots[node.extra];
    const len = slots[node.extra + 1];
    if (off + len > ir_obj.string_buf.items.len) return null;
    return ir_obj.string_buf.items[off .. off + len];
}

/// Recursively lower an IR projection subtree into PlanBuilder nodes.
/// Returns the root index of the lowered subtree, or null on a shape
/// rejection (any unsupported op). The caller chains the result into
/// its surrounding plan node via `children`.
///
/// `has_iterate` is set if any `iterate_array` is encountered along
/// the path — surfaced on the final ProjectionPlan so the pool can
/// decide whether to bias buffer sizing.
fn lowerProjection(
    b: *PlanBuilder,
    ir_obj: *const ir.IR,
    ir_idx: u32,
    has_iterate: *bool,
) error{OutOfMemory}!?u32 {
    const node = ir_obj.nodes.items[ir_idx];
    switch (node.op) {
        .identity => {
            // `.` on its own materializes the entire current value.
            return try b.pushNode(.{ .kind = .terminal });
        },
        .load_field => {
            const key = loadFieldKey(ir_obj, node) orelse return null;
            const interned = try b.internKey(key);
            // Place the terminal child first, then the parent that
            // references it.
            const terminal_idx = try b.pushNode(.{ .kind = .terminal });
            const child_start: u32 = @intCast(b.children.items.len);
            try b.children.append(b.alloc, terminal_idx);
            return try b.pushNode(.{
                .kind = .object_key,
                .key_or_index_lo = interned.off,
                .key_or_index_hi = interned.len,
                .children_start = child_start,
                .children_len = 1,
            });
        },
        .load_path => {
            // `.a.b.c` collapsed by fuse — payload is "a.b.c" (dot-joined).
            const joined = loadPathBytes(ir_obj, node) orelse return null;
            // Walk segments right-to-left so the deepest node is built
            // first; the parser descends through the chain via
            // `children` slices of length 1.
            var segs: [16][]const u8 = undefined;
            var n_segs: usize = 0;
            var rest = joined;
            while (rest.len > 0) {
                if (n_segs == segs.len) return null; // path too deep for plan
                if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
                    segs[n_segs] = rest[0..dot];
                    n_segs += 1;
                    rest = rest[dot + 1 ..];
                } else {
                    segs[n_segs] = rest;
                    n_segs += 1;
                    rest = "";
                }
            }
            if (n_segs == 0) return null;

            // Build deepest first: terminal at the bottom.
            var current_idx: u32 = try b.pushNode(.{ .kind = .terminal });
            var i: usize = n_segs;
            while (i > 0) {
                i -= 1;
                const interned = try b.internKey(segs[i]);
                const child_start: u32 = @intCast(b.children.items.len);
                try b.children.append(b.alloc, current_idx);
                current_idx = try b.pushNode(.{
                    .kind = .object_key,
                    .key_or_index_lo = interned.off,
                    .key_or_index_hi = interned.len,
                    .children_start = child_start,
                    .children_len = 1,
                });
            }
            return current_idx;
        },
        .load_index => {
            const i = loadIndexValue(ir_obj, node) orelse return null;
            const u: u64 = @bitCast(i);
            const terminal_idx = try b.pushNode(.{ .kind = .terminal });
            const child_start: u32 = @intCast(b.children.items.len);
            try b.children.append(b.alloc, terminal_idx);
            return try b.pushNode(.{
                .kind = .array_index,
                .key_or_index_lo = @truncate(u),
                .key_or_index_hi = @truncate(u >> 32),
                .children_start = child_start,
                .children_len = 1,
            });
        },
        .iterate => {
            has_iterate.* = true;
            const terminal_idx = try b.pushNode(.{ .kind = .terminal });
            const child_start: u32 = @intCast(b.children.items.len);
            try b.children.append(b.alloc, terminal_idx);
            return try b.pushNode(.{
                .kind = .iterate_array,
                .children_start = child_start,
                .children_len = 1,
            });
        },
        .try_ => {
            // `try EXPR` — propagate the inner plan; runtime errors on
            // missing keys still produce no output, which is what we
            // want for projection.
            return try lowerProjection(b, ir_obj, node.children[0], has_iterate);
        },
        .pipe => {
            // Lower the LEFT half first, then graft RIGHT onto its
            // terminal. The leftmost terminal becomes the join point
            // because pipes are left-deep (`(a | b) | c` ⇒ left child
            // is the chain so far, right child is the next step).
            //
            // Implementation: lower left, find its terminal, lower
            // right *and splice in-place* by overwriting the terminal
            // node with right's content. To keep `b.nodes` dense (no
            // dead trailing storage), we record the right-root node
            // index *before* lowering right, so we can detect the
            // common case where right_root is the very last node and
            // pop it after the splice. For deeper right plans where
            // the lowering pushed multiple nodes, the splice still
            // works but the trailing node remains in place — see the
            // single-source-of-truth note in `harvest_compose_test`.
            const left_root = try lowerProjection(b, ir_obj, node.children[0], has_iterate) orelse return null;
            var t_idx = left_root;
            while (true) {
                const tn = b.nodes.items[t_idx];
                if (tn.kind == .terminal) break;
                if (tn.children_len != 1) return null; // ambiguous fan-out
                t_idx = b.children.items[tn.children_start];
            }
            const right_root = try lowerProjection(b, ir_obj, node.children[1], has_iterate) orelse return null;
            // Splice: copy right_root's content over the left
            // terminal. `right_root` is the last node pushed by the
            // right lowering (post-order builder). Its trailing entry
            // is unreferenced after the copy because nothing in
            // `b.children` points to right_root itself — only to
            // its sub-nodes (which retain their indices). Pop it to
            // keep `nodes` dense.
            b.nodes.items[t_idx] = b.nodes.items[right_root];
            if (right_root + 1 == b.nodes.items.len) {
                var any_ref = false;
                for (b.children.items) |ci| {
                    if (ci == right_root) {
                        any_ref = true;
                        break;
                    }
                }
                if (!any_ref) _ = b.nodes.pop();
            }
            return left_root;
        },
        .slice, .computed_slice, .recurse => {
            // Slices and recursive descent require materialization of
            // every reachable element — no projection benefit. Reject.
            return null;
        },
        else => return null,
    }
}

/// Harvest a projection plan from the IR. Returns null if the IR root
/// is not a pure path projection (any `select`, `arith`, `cmp`, etc.
/// at the root level) or if the body contains any unsupported op.
///
/// The caller owns the returned plan via the supplied allocator and
/// must call `plan.deinit()` to release it.
///
/// Honors `-Dno-plan=true` by unconditionally returning null — this
/// lets the selective-query bench scenario attribute the speedup to
/// the projection / predicate pushdown work cleanly.
pub fn harvestProjectionPlan(
    alloc: std.mem.Allocator,
    ir_obj: *const ir.IR,
) error{OutOfMemory}!?ProjectionPlan {
    if (build_options.no_plan) return null;
    if (ir_obj.nodes.items.len == 0) return null;

    // The IR is post-order; the root is the last node.
    const root_idx: u32 = @intCast(ir_obj.nodes.items.len - 1);

    // Reject early on a select-rooted query: that goes through the
    // predicate harvester (which calls back into us for the body).
    const root_node = ir_obj.nodes.items[root_idx];
    const is_select_root = blk: {
        if (root_node.op != .call_builtin) break :blk false;
        const name = getBuiltinName(ir_obj, root_node) orelse break :blk false;
        break :blk std.mem.eql(u8, name, "select");
    };
    if (is_select_root) return null;

    // Reject anything `lowerProjection` can't handle. Uses the
    // stricter `isProjectionEligible` (rejects recurse/slice) — kept in
    // lockstep with `lowerProjection`'s explicit rejection arm.
    if (!isProjectionEligible(ir_obj, root_idx)) return null;

    var b = PlanBuilder{ .alloc = alloc };
    errdefer b.deinit();

    var has_iterate = false;
    const plan_root = (try lowerProjection(&b, ir_obj, root_idx, &has_iterate)) orelse return null;

    // Hand ownership over to the plan struct; clear the builder so
    // `b.deinit()` becomes a no-op on the success path.
    const nodes_slice = try b.nodes.toOwnedSlice(alloc);
    const children_slice = try b.children.toOwnedSlice(alloc);
    const string_buf_slice = try b.string_buf.toOwnedSlice(alloc);

    return ProjectionPlan{
        .allocator = alloc,
        .nodes = nodes_slice,
        .children = children_slice,
        .string_buf = string_buf_slice,
        .root = plan_root,
        .predicate = null,
        .has_iterate = has_iterate,
    };
}

/// Harvest a pure-scalar predicate from a `select(...)`-rooted IR. The
/// inner body of `select` must match exactly one of:
///
///   1. `<pure-path> <cmp> <load_const literal>` (cmp ∈ eq/ne/lt/le/gt/ge)
///   2. `has(<load_const string-literal>)`
///
/// On success, returns a `ProjectionPlan` whose `predicate` field is
/// populated. On any rejection (composite predicates, impure pipes,
/// nested selects), returns null and the caller falls back to running
/// the predicate via the VM as before.
pub fn harvestPredicate(
    alloc: std.mem.Allocator,
    ir_obj: *const ir.IR,
) error{OutOfMemory}!?ProjectionPlan {
    if (build_options.no_plan) return null;
    if (ir_obj.nodes.items.len == 0) return null;

    const root_idx: u32 = @intCast(ir_obj.nodes.items.len - 1);
    const root_node = ir_obj.nodes.items[root_idx];

    if (root_node.op != .call_builtin) return null;
    const root_name = getBuiltinName(ir_obj, root_node) orelse return null;
    if (!std.mem.eql(u8, root_name, "select")) return null;

    // `select` carries its body as either children[0] (when span_len ==
    // 0) or extra_children[span_start] (variadic shape).
    const body_idx = if (root_node.span_len == 0) root_node.children[0] else blk: {
        if (root_node.span_len == 0) return null;
        break :blk ir_obj.extra_children.items[root_node.span_start];
    };
    const body = ir_obj.nodes.items[body_idx];

    // Branch 1: comparison `pure-path CMP literal` (possibly wrapped in
    // a single pipe — `select(.a == 1)` lowers either as `cmp(...)`
    // directly or as `pipe(., cmp(...))` depending on AST shape).
    if (body.op == .cmp) {
        return try buildPredicatePlan(
            alloc,
            ir_obj,
            null, // no leading projection chain
            body,
        );
    }

    if (body.op == .pipe) {
        // `select(<path> | <comparator>)` lowers to
        //   pipe(<path>, cmp(<identity-or-shorter-path>, <literal>))
        // We accept this idiom: the projection plan covers <path>, and
        // the predicate's RHS-path projection collapses to `.` (the
        // value piped through).
        const left_idx = body.children[0];
        const right_idx = body.children[1];
        const right = ir_obj.nodes.items[right_idx];
        if (right.op == .cmp) {
            return try buildPredicatePlan(
                alloc,
                ir_obj,
                left_idx,
                right,
            );
        }
        if (right.op == .call_builtin) {
            const name = getBuiltinName(ir_obj, right) orelse return null;
            if (std.mem.eql(u8, name, "has")) {
                return try buildHasPredicatePlan(alloc, ir_obj, left_idx, right);
            }
        }
        return null;
    }

    if (body.op == .call_builtin) {
        const name = getBuiltinName(ir_obj, body) orelse return null;
        if (std.mem.eql(u8, name, "has")) {
            return try buildHasPredicatePlan(alloc, ir_obj, null, body);
        }
        return null;
    }

    return null;
}

/// Build a projection plan whose root represents the projection chain
/// (or `.` when none) followed by a predicate that compares the
/// terminal field against a literal.
fn buildPredicatePlan(
    alloc: std.mem.Allocator,
    ir_obj: *const ir.IR,
    leading_path_idx: ?u32,
    cmp_node: ir.Node,
) error{OutOfMemory}!?ProjectionPlan {
    std.debug.assert(cmp_node.op == .cmp);

    // Decode cmp kind.
    const slots = ir_obj.extra_data.items;
    if (cmp_node.extra >= slots.len) return null;
    const cmp_kind: ir.CmpKind = @enumFromInt(slots[cmp_node.extra]);
    const op: PredicateOp = switch (cmp_kind) {
        .eq => .eq,
        .ne => .ne,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
    };

    // The cmp's left child must be a pure path; right child must be a
    // literal load_const. (jq does NOT canonicalize operand order, so
    // we only accept the `<path> CMP <literal>` form.)
    const left_idx = cmp_node.children[0];
    const right_idx = cmp_node.children[1];
    const right = ir_obj.nodes.items[right_idx];
    if (right.op != .load_const) return null;

    // Build the projection plan: leading projection (if any) chained
    // with the cmp's left path. Both must be pure accessors.
    var b = PlanBuilder{ .alloc = alloc };
    errdefer b.deinit();
    var has_iterate = false;

    if (leading_path_idx) |lpi| {
        if (!isProjectionEligible(ir_obj, lpi)) return null;
    }
    if (!isProjectionEligible(ir_obj, left_idx)) return null;

    const proj_root = blk: {
        if (leading_path_idx) |lpi| {
            const left_plan = (try lowerProjection(&b, ir_obj, lpi, &has_iterate)) orelse return null;
            const right_plan = (try lowerProjection(&b, ir_obj, left_idx, &has_iterate)) orelse return null;
            // Splice right onto the leftmost terminal of left_plan.
            var t_idx = left_plan;
            while (true) {
                const tn = b.nodes.items[t_idx];
                if (tn.kind == .terminal) break;
                if (tn.children_len != 1) return null;
                t_idx = b.children.items[tn.children_start];
            }
            b.nodes.items[t_idx] = b.nodes.items[right_plan];
            break :blk left_plan;
        } else {
            break :blk (try lowerProjection(&b, ir_obj, left_idx, &has_iterate)) orelse return null;
        }
    };

    // Locate the terminal of proj_root — that's where the predicate
    // fires.
    var pred_terminal = proj_root;
    while (true) {
        const tn = b.nodes.items[pred_terminal];
        if (tn.kind == .terminal) break;
        if (tn.children_len != 1) return null;
        pred_terminal = b.children.items[tn.children_start];
    }

    // Decode the literal and (if string) intern it into string_buf.
    const lit_value = ir.loadConstValue(ir_obj, right);
    const literal: Literal = switch (lit_value) {
        .null_val => .null_,
        .bool_val => |bv| .{ .bool_ = bv },
        .int => |iv| .{ .int = iv },
        .float => |fv| .{ .float = fv },
        .string => |s| blk: {
            const interned = try b.internKey(s);
            break :blk .{ .string = .{ .offset = interned.off, .len = interned.len } };
        },
        .big_number => return null,
    };

    const nodes_slice = try b.nodes.toOwnedSlice(alloc);
    const children_slice = try b.children.toOwnedSlice(alloc);
    const string_buf_slice = try b.string_buf.toOwnedSlice(alloc);

    return ProjectionPlan{
        .allocator = alloc,
        .nodes = nodes_slice,
        .children = children_slice,
        .string_buf = string_buf_slice,
        .root = proj_root,
        .predicate = .{
            .field_path_node = pred_terminal,
            .op = op,
            .literal = literal,
        },
        .has_iterate = has_iterate,
    };
}

/// Build a projection plan for `select(has(<key-literal>))` and
/// `select(<path> | has(<key-literal>))`.
///
/// `has(K)` evaluated on an object returns true if K is one of its
/// keys. The evaluator runs at top-of-record and resolves the lookup
/// directly against the finalized tape window via `findObjectKey`.
fn buildHasPredicatePlan(
    alloc: std.mem.Allocator,
    ir_obj: *const ir.IR,
    leading_path_idx: ?u32,
    has_node: ir.Node,
) error{OutOfMemory}!?ProjectionPlan {
    std.debug.assert(has_node.op == .call_builtin);

    // `has(K)` — the argument is a single literal string. The
    // call_builtin's argument layout: span_start / span_len carries the
    // arg-IR-node index (single arg).
    const arg_idx: u32 = if (has_node.span_len == 1)
        ir_obj.extra_children.items[has_node.span_start]
    else if (has_node.children[0] != 0 or has_node.span_len == 0)
        has_node.children[0]
    else
        return null;
    if (arg_idx >= ir_obj.nodes.items.len) return null;
    const arg = ir_obj.nodes.items[arg_idx];
    if (arg.op != .load_const) return null;
    const arg_val = ir.loadConstValue(ir_obj, arg);
    const key_bytes = switch (arg_val) {
        .string => |s| s,
        else => return null,
    };

    if (leading_path_idx) |lpi| {
        if (!isProjectionEligible(ir_obj, lpi)) return null;
    }

    var b = PlanBuilder{ .alloc = alloc };
    errdefer b.deinit();
    var has_iterate = false;

    const proj_root = blk: {
        if (leading_path_idx) |lpi| {
            break :blk (try lowerProjection(&b, ir_obj, lpi, &has_iterate)) orelse return null;
        } else {
            // `select(has("k"))` operates on the top-level value.
            break :blk try b.pushNode(.{ .kind = .terminal });
        }
    };

    // Find terminal of proj_root for predicate-firing point.
    var pred_terminal = proj_root;
    while (true) {
        const tn = b.nodes.items[pred_terminal];
        if (tn.kind == .terminal) break;
        if (tn.children_len != 1) return null;
        pred_terminal = b.children.items[tn.children_start];
    }

    // Intern the key literal.
    const interned = try b.internKey(key_bytes);

    const nodes_slice = try b.nodes.toOwnedSlice(alloc);
    const children_slice = try b.children.toOwnedSlice(alloc);
    const string_buf_slice = try b.string_buf.toOwnedSlice(alloc);

    return ProjectionPlan{
        .allocator = alloc,
        .nodes = nodes_slice,
        .children = children_slice,
        .string_buf = string_buf_slice,
        .root = proj_root,
        .predicate = .{
            .field_path_node = pred_terminal,
            .op = .has_key,
            .literal = .{ .string = .{ .offset = interned.off, .len = interned.len } },
        },
        .has_iterate = has_iterate,
    };
}
