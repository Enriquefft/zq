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

pub const enabled = regex_mod.enabled;

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

/// Check if the IR subtree rooted at `node_idx` is a pure accessor expression.
///
/// Pure accessors are chains of:
///   - identity
///   - recurse
///   - load_field
///   - load_index
///   - slice
///   - iterate
///   - try (optional)
///   - pipe (connecting the above)
///
/// Any other operation (load_var, call_user, arith, cmp, logical, etc.)
/// makes the expression impure.
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
