//! IR — single-arena tree of `Node`s shared by lowering, fuse, and emission.
//!
//! See `research/compiler-ir-format.md` for the canonical text-dump shape that
//! snapshot tests will diff (R3, Phase 6+). This file owns the in-memory
//! representation; the dumper, lowering rules, fuse rewrites, and emit logic
//! live in the sibling files.
//!
//! Zig 0.15 unmanaged-collection convention: `std.ArrayListUnmanaged(T){}` for
//! init, allocator passed to every method (matches the rest of the tree, e.g.
//! `src/microbench/main.zig`). The IR's allocator is the arena it was given —
//! `deinit` is a no-op on the lists themselves; the arena owns the storage.
const std = @import("std");

/// Op tag — a single flat namespace covering both `SemOp` (lowered from AST,
/// produced by `lower.zig`) and `EmitOp` (produced by `fuse.zig`, consumed by
/// `emit.zig`). The split is documented in `research/compiler-ir-format.md`
/// §4: tag names are unique across the union, dump banners separate the two
/// at render time.
///
/// Naming convention: Zig-keyword-clashing tags use a trailing underscore
/// (`if_`, `try_`). The `op_tag` in the text dump strips this underscore (see
/// the dumper in R3) so the wire format remains `if`, `try` per the spec.
pub const Op = enum(u8) {
    // ── SemOp namespace (lowered from AST) ────────────────────────────────
    load_const,
    load_var,
    field,
    index,
    slice,

    pipe,
    comma,
    arith,
    cmp,
    logical,
    alt,

    iterate,
    recurse,
    try_,
    neg,
    not,

    if_,
    reduce,
    foreach,

    interp,
    format,

    obj_ctor,
    arr_ctor,

    call_user,
    call_builtin,

    update_assign,
    destructure,

    path_begin,
    path_end,

    // ── EmitOp namespace (reserved; no variants today) ────────────────────
    // Fuse's output ops (e.g. `load_path`, `key_count`, `key_exists`) and
    // any future emission shortcuts will be added here. Plan §1.3 row 6:
    // "none today; reserved namespace for fuse's output and future passes."
};

/// A single IR node — the universal record type for both SemOp and EmitOp.
///
/// Storage layout:
/// - `children[0..1]` — fixed-arity child indices for nodes with ≤2 children
///   (the common case: `pipe`, `comma`, `cmp`, `arith`, `field`, etc.).
/// - `(span_start, span_len)` — slice into `IR.extra_children` for nodes with
///   ≥3 children (`if_`, `reduce`, `foreach`, `obj_ctor`, `arr_ctor`,
///   `interp`, `call_*`, `destructure`).
/// - `extra` — index into `IR.extra_data` for scalar payloads (string-buf id,
///   regex-pool id, flag bitsets, format-spec id). Plan §1.3 row 5.
/// - `(src_start, src_len)` — source byte span used for diagnostics and the
///   text-dump `@<start>..<end>` annotation. Always populated; never lossy.
///
/// Comptime size assert: `@sizeOf(Node) <= 32`. Hitting 32 keeps a single
/// node in one cache line on modern x86_64 / aarch64 (64-byte lines fit two
/// nodes), which matters once the lowering loop walks dense IR trees.
pub const Node = struct {
    op: Op,
    children: [2]u32 = .{ 0, 0 },
    span_start: u32 = 0,
    span_len: u32 = 0,
    extra: u32 = 0,
    src_start: u32 = 0,
    src_len: u32 = 0,
};

comptime {
    // 1 (op) + 1*3 padding + 8 (children) + 4 (span_start) + 4 (span_len)
    // + 4 (extra) + 4 (src_start) + 4 (src_len) = 32 bytes on a 4-byte
    // aligned struct. The `<= 32` ceiling guards future field additions.
    std.debug.assert(@sizeOf(Node) <= 32);
}

/// IR container — owns the node arena, the variable-arity child overflow
/// array, the scalar-payload table, and the interned string buffer. All
/// allocations live in the caller-supplied arena, so `deinit` is mostly a
/// formality (provided for symmetry; safe to call without freeing the arena).
pub const IR = struct {
    arena: *std.heap.ArenaAllocator,
    nodes: std.ArrayListUnmanaged(Node),
    /// Overflow child indices for nodes with ≥3 children. Indexed by
    /// `Node.span_start[..span_start+span_len]`.
    extra_children: std.ArrayListUnmanaged(u32),
    /// Scalar payloads (string-buf ids, regex-pool ids, flag bitsets,
    /// format-spec ids). Indexed by `Node.extra` (the consumer must know
    /// the payload arity from the op tag).
    extra_data: std.ArrayListUnmanaged(u32),
    /// Interned UTF-8 string storage for `field` names, `format` specs,
    /// `interp` literal segments, etc. String-buf ids are byte offsets
    /// paired with a length stored in `extra_data`.
    string_buf: std.ArrayListUnmanaged(u8),

    /// Initialize an empty IR backed by `arena`. The arena owns every list's
    /// storage; the caller must keep `arena` alive for the IR's lifetime.
    pub fn init(arena: *std.heap.ArenaAllocator) IR {
        return .{
            .arena = arena,
            .nodes = .{},
            .extra_children = .{},
            .extra_data = .{},
            .string_buf = .{},
        };
    }

    /// Release list capacities. The arena retains ownership of the byte
    /// blocks themselves — destroy the arena to reclaim memory. Provided
    /// for symmetry with the rest of the codebase's `init`/`deinit` pairs.
    pub fn deinit(self: *IR) void {
        const alloc = self.arena.allocator();
        self.nodes.deinit(alloc);
        self.extra_children.deinit(alloc);
        self.extra_data.deinit(alloc);
        self.string_buf.deinit(alloc);
    }
};
