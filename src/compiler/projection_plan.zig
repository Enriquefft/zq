//! Static projection plan + pure-scalar predicate harvested at query
//! compile time from the IR DAG. Consumed by `parser.feedPlanned` to
//! skip out-of-projection JSON values without materializing them and
//! to drop top-level records that fail a pure-scalar select() predicate
//! before the VM ever runs.
//!
//! Single source of truth: this file owns the type definitions; both
//! `compiler/harvest.zig` (producer) and `parser/src/parser.zig`
//! (consumer) import these types verbatim. No second copy lives
//! anywhere in the codebase.
//!
//! Lifetime: the `ProjectionPlan` is owned by `CompiledQuery`. The
//! `nodes` slice and any string bytes referenced by predicate string
//! literals are allocated from the same allocator that owns the
//! compiled bytecode and freed in `CompiledQuery.deinit`.

const std = @import("std");

/// Discriminant for a single plan node. `terminal` is the only kind
/// without children — it marks the leaf that the parser is allowed to
/// materialize into the tape verbatim. Every other kind navigates
/// deeper into the JSON tree.
pub const PlanNodeKind = enum(u8) {
    /// Object key step — `key_start` / `key_len` index into
    /// `plan.string_buf`. Children are sibling fan-out within the
    /// surrounding object: the parser walks the object's keys in input
    /// order, when a key matches a child's `key`, that child becomes
    /// the active plan node.
    object_key,
    /// Array index step `.[N]` — `index` carries the i64 (bit-cast to
    /// u64). Plain `.[N]` selects the Nth element; non-matching
    /// elements are skipped scalarly.
    array_index,
    /// `.[]` iterate — the active plan descends into every array
    /// element. `children` always has length 1: the sub-plan applied
    /// per element.
    iterate_array,
    /// Leaf node — the parser materializes the underlying JSON value
    /// into the tape unchanged. No further plan navigation occurs
    /// inside a terminal.
    terminal,
};

/// A single node in the static projection plan. Layout is fully
/// resolved at query-compile time; the parser does no string lookups.
pub const PlanNode = struct {
    kind: PlanNodeKind,
    /// `object_key`: byte offset into `plan.string_buf`.
    /// `array_index`: low 32 bits of i64-bit-cast (high bits in `index_hi`).
    /// other kinds: 0.
    key_or_index_lo: u32 = 0,
    /// `object_key`: length of the key in `plan.string_buf`.
    /// `array_index`: high 32 bits of i64-bit-cast.
    /// other kinds: 0.
    key_or_index_hi: u32 = 0,
    /// Slice into `plan.children` — sibling fan-out for objects, the
    /// per-element sub-plan for `iterate_array` (length 1), the inner
    /// step for an array index navigation (length 0 or 1). Terminals
    /// have length 0.
    children_start: u32 = 0,
    children_len: u32 = 0,
};

/// Comparison operator for the harvested pure-scalar predicate.
/// Mirrors a *subset* of `ir.CmpKind`; the parser cannot reach the IR
/// module (compile-time-only) at runtime, so the predicate is decoded
/// into this enum at harvest time. `has_key` is plan-specific and has
/// no IR equivalent (it covers `has(K)` builtin calls). The shapes
/// happen to overlap on the comparison operators but the harvester
/// re-encodes them rather than aliasing the IR enum, because
/// `ir.CmpKind` is `enum(u32)` (it's stored in extra-data slots) and
/// this is `enum(u8)` (compact in the predicate struct).
pub const PredicateOp = enum(u8) {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    /// `has(<key>)` — presence test. The evaluator looks up the watched
    /// key directly in the finalized tape window via `findObjectKey`
    /// when the predicate fires at the top of the record.
    has_key,
};

/// Literal value the predicate compares against. Strings are interned
/// into `plan.string_buf` (offset/len encoding) — the parser compares
/// the just-decoded JSON string slice against the byte view obtained
/// from `plan.string_buf[off..off+len]`.
pub const Literal = union(enum) {
    null_,
    bool_: bool,
    int: i64,
    float: f64,
    /// `(offset, len)` into `plan.string_buf`.
    string: struct { offset: u32, len: u32 },
};

/// Pure-scalar select() predicate. When non-null on the
/// `ProjectionPlan`, the parser evaluates the predicate as soon as the
/// terminal field referenced by `field_path_node` is materialized; if
/// the predicate is false, the entire surrounding top-level value is
/// rolled back via tape/string-buf snapshot truncation and the parser
/// returns `FeedResult.dropped`.
pub const Predicate = struct {
    /// Plan-node index of the terminal that the predicate's pure-path
    /// resolves to. The path itself is implied by the plan: the
    /// terminal is reachable from `plan.root` through the plan tree.
    field_path_node: u32,
    op: PredicateOp,
    literal: Literal,
};

/// Static projection plan + optional pure-scalar predicate. Produced
/// by the harvester after `lower` and `fuse` complete; consumed by the
/// parser via `feedPlanned`. The plan owns its node array, child
/// overflow array, and string buffer through the supplied allocator.
pub const ProjectionPlan = struct {
    allocator: std.mem.Allocator,
    nodes: []const PlanNode,
    children: []const u32,
    string_buf: []const u8,
    root: u32,
    predicate: ?Predicate,
    has_iterate: bool,

    pub fn deinit(p: *ProjectionPlan) void {
        if (p.nodes.len > 0) p.allocator.free(p.nodes);
        if (p.children.len > 0) p.allocator.free(p.children);
        if (p.string_buf.len > 0) p.allocator.free(p.string_buf);
    }

    /// Read the i64 payload from an `array_index` node. Plan §1.
    pub inline fn arrayIndex(_: *const ProjectionPlan, node: PlanNode) i64 {
        std.debug.assert(node.kind == .array_index);
        const u: u64 = @as(u64, node.key_or_index_lo) | (@as(u64, node.key_or_index_hi) << 32);
        return @bitCast(u);
    }

    /// Read the key bytes from an `object_key` node.
    pub inline fn keyBytes(p: *const ProjectionPlan, node: PlanNode) []const u8 {
        std.debug.assert(node.kind == .object_key);
        const off = node.key_or_index_lo;
        const len = node.key_or_index_hi;
        return p.string_buf[off .. off + len];
    }

    /// Get the plan-node-children slice for a parent plan node.
    pub inline fn childIndices(p: *const ProjectionPlan, node: PlanNode) []const u32 {
        return p.children[node.children_start .. node.children_start + node.children_len];
    }

    /// Read the literal-string bytes from a `string` literal payload.
    pub inline fn literalBytes(p: *const ProjectionPlan, lit: Literal) []const u8 {
        return switch (lit) {
            .string => |s| p.string_buf[s.offset .. s.offset + s.len],
            else => unreachable,
        };
    }
};
