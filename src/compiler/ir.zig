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

/// `load_const` payload discriminant. Encoded into `extra_data[node.extra]`
/// by `lower.zig` and decoded by `emit.zig`; the trailing slots carry the
/// concrete value (lo32/hi32 for int/float, offset/len for string).
pub const LiteralKind = enum(u32) {
    null_val = 0,
    false_val = 1,
    true_val = 2,
    int = 3,
    float = 4,
    string = 5,
};

/// Decoded `load_const` payload — single-source-of-truth for emit /
/// dumper / fuse / snapshot consumers. The string variant references
/// the IR's `string_buf` directly (the IR arena owns the bytes for the
/// caller's lifetime). Plan §3 R3 step 9 — seam 1 (single-source const
/// decode). All decode sites must route through `loadConstValue`.
pub const ConstValue = union(enum) {
    null_val,
    bool_val: bool,
    int: i64,
    float: f64,
    string: []const u8,
};

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
    /// Identity `.` — pass-through of the current input. Emitted by
    /// `lower.zig` for the AST `.identity` kind (plan §3 R3 step 6
    /// category 1). Maps to bytecode `Instruction.Op.identity`.
    identity,
    /// Static-key field access (`.foo`, `.["foo"]`). `extra` indexes a
    /// 2-slot `(offset, len)` pair into `string_buf`. Maps to legacy
    /// `Instruction.Op.load_key`. Plan §1.3 row 5.
    load_field,
    /// Static-int array index (`.[N]`). `extra` indexes a 2-slot
    /// `(lo32, hi32)` of an i64. Maps to legacy `Instruction.Op.load_index`.
    /// Plan §1.3 row 5.
    load_index,
    /// Array/string slice (`.[from:to]`). `extra` indexes a 2-slot
    /// `(packed_from_to, flags)` payload — see `lower.zig` for the bit
    /// layout. Maps to legacy `Instruction.Op.slice` (operand
    /// `slice_args`). Plan §1.3 row 5.
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
///   (the common case: `pipe`, `comma`, `cmp`, `arith`, `try_`, etc.).
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

/// Single-source-of-truth decoder for `load_const` payloads. The IR's
/// `extra_data[node.extra]` slot is the discriminant; trailing slots
/// carry the concrete value. Callers must guarantee `node.op == .load_const`;
/// debug builds will panic on mismatch.
pub fn loadConstValue(ir_obj: *const IR, node: Node) ConstValue {
    std.debug.assert(node.op == .load_const);
    const slots = ir_obj.extra_data.items;
    const kind: LiteralKind = @enumFromInt(slots[node.extra]);
    return switch (kind) {
        .null_val => .null_val,
        .false_val => .{ .bool_val = false },
        .true_val => .{ .bool_val = true },
        .int => blk: {
            const lo: u64 = slots[node.extra + 1];
            const hi: u64 = slots[node.extra + 2];
            const u: u64 = lo | (hi << 32);
            break :blk .{ .int = @bitCast(u) };
        },
        .float => blk: {
            const lo: u64 = slots[node.extra + 1];
            const hi: u64 = slots[node.extra + 2];
            const u: u64 = lo | (hi << 32);
            break :blk .{ .float = @bitCast(u) };
        },
        .string => blk: {
            const offset: u32 = slots[node.extra + 1];
            const len: u32 = slots[node.extra + 2];
            break :blk .{ .string = ir_obj.string_buf.items[offset .. offset + len] };
        },
    };
}

// ── Text dumper (used by snapshot tests) ─────────────────────────────────────
// Spec: research/compiler-ir-format.md §10. Indented-tree, one node per line,
// child indent +2 spaces, `# SemOp` banner once at the top, every line ends
// with `@<start>..<end>` source bytes. The dumper is callable in any build —
// the spec promises stable output, so snapshot tests reach for it directly.

const ast = @import("ast");

/// Dump `ir_obj` lowered from `ast_root` into `writer`. Emits one
/// `# source:` directive line + the `# SemOp` banner + the IR tree.
/// The `source` parameter is the original filter text used as the
/// `# source:` payload — the dumper does not parse it, only echoes it.
///
/// Order of emission walks the AST: every IR node was produced in the
/// order of `lowerNode`, so we walk the AST recursively and print the
/// IR node corresponding to each AST step. This keeps the dump
/// deterministic across re-runs and matches the spec's worked examples
/// (§10) without depending on internal `nodes.items` ordering.
pub fn dump(
    ir_obj: *const IR,
    ast_root: *const ast.Node,
    source: []const u8,
    writer: anytype,
) @TypeOf(writer).Error!void {
    try writer.print("# source: {s}\n", .{source});
    try writer.writeAll("# SemOp\n");
    try dumpAst(ir_obj, ast_root, 0, writer);
}

fn writeIndent(writer: anytype, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try writer.writeAll("  ");
    }
}

fn writeSpan(writer: anytype, span: ast.Span) !void {
    try writer.print(" @{d}..{d}", .{ span.start, span.end });
}

/// Render the IR shape lowered from `node`, recurse into AST children
/// in lowering order. Mirrors `lowerNode` in `lower.zig`. Categories
/// not yet ported emit `# unimplemented(<kind>)` comment lines so the
/// snapshot diff still produces a stable record.
fn dumpAst(
    ir_obj: *const IR,
    node: *const ast.Node,
    depth: usize,
    writer: anytype,
) @TypeOf(writer).Error!void {
    switch (node.kind) {
        .literal => |lit| {
            try writeIndent(writer, depth);
            switch (lit) {
                .null_val => try writer.writeAll("load_const(null)"),
                .bool_val => |b| try writer.print("load_const({s})", .{if (b) "true" else "false"}),
                .int => |n| try writer.print("load_const({d})", .{n}),
                .float => |f| {
                    // Use the shortest repro-able form; snapshot files
                    // are diffed byte-for-byte so we want a stable
                    // representation. `{d}` matches Zig's default
                    // f64 formatter which is round-trippable.
                    try writer.print("load_const({d})", .{f});
                },
                .string => |s| {
                    try writer.writeAll("load_const(");
                    try writeStringLit(writer, s);
                    try writer.writeAll(")");
                },
            }
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
        },
        .identity => {
            try writeIndent(writer, depth);
            try writer.writeAll("identity");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
        },
        .recurse => {
            try writeIndent(writer, depth);
            try writer.writeAll("recurse");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
        },
        .unary_neg => |un| {
            try writeIndent(writer, depth);
            try writer.writeAll("neg");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, un.operand, depth + 1, writer);
        },
        .field_access => |fa| {
            try writeIndent(writer, depth);
            try writer.writeAll("load_field(");
            try writeStringLit(writer, fa.name);
            try writer.writeAll(")");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
        },
        .index_access => |ia| {
            try writeIndent(writer, depth);
            try writer.print("load_index({d})", .{ia.index});
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
        },
        .iterate => {
            try writeIndent(writer, depth);
            try writer.writeAll("iterate");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
        },
        .slice => |sl| {
            try writeIndent(writer, depth);
            try writer.writeAll("slice(");
            if (sl.has_from) try writer.print("{d}", .{sl.from}) else try writer.writeAll("_");
            try writer.writeAll(", ");
            if (sl.has_to) try writer.print("{d}", .{sl.to}) else try writer.writeAll("_");
            try writer.writeAll(")");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
        },
        .optional => |un| {
            try writeIndent(writer, depth);
            try writer.writeAll("try");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, un.operand, depth + 1, writer);
        },
        .suffix => |sf| try dumpSuffix(ir_obj, &sf, node.span, depth, writer),
        .builtin_call => |bc| {
            try writeIndent(writer, depth);
            if (bc.args.len == 0 and std.mem.eql(u8, bc.name, "not")) {
                try writer.writeAll("not");
                try writeSpan(writer, node.span);
                try writer.writeAll("\n");
                return;
            }
            // Generic builtin call: rendered as `call_builtin("name")`.
            try writer.writeAll("call_builtin(");
            try writeStringLit(writer, bc.name);
            try writer.writeAll(")");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            for (bc.args) |arg| {
                try dumpAst(ir_obj, arg, depth + 1, writer);
            }
        },
        else => {
            try writeIndent(writer, depth);
            try writer.print("# unimplemented({s})", .{@tagName(node.kind)});
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
        },
    }
}

/// Render a suffix-chain as a left-deep `pipe` tree mirroring the
/// `lower.zig` Suffix → pipe-chain expansion. Each non-`optional` op
/// appends a new pipe layer (left = accumulated chain, right = new op).
/// Each `optional` op wraps the rightmost chain element in `try`,
/// matching the legacy `?`-segment-wrap semantic. Single source of
/// truth — the same fold runs at lowering time.
///
/// Walks the ops list to construct an abstract chain shape, then
/// renders it recursively. The abstract shape is encoded as a
/// trailing index: `last_kind` identifies whether the rightmost
/// element is a SuffixOp or the bare base; `prefix_len` tells the
/// renderer how much of the chain to recurse into. This keeps the
/// dumper allocation-free.
fn dumpSuffix(
    ir_obj: *const IR,
    sf: *const ast.Node.Suffix,
    span: ast.Span,
    depth: usize,
    writer: anytype,
) @TypeOf(writer).Error!void {
    try renderSuffixChain(ir_obj, sf, sf.ops.len, span, depth, writer);
}

/// Render the chain `sf.base + sf.ops[0 .. ops_len]`. The rightmost
/// op (excluding trailing `optional`s, which wrap it) is the right
/// child of the topmost `pipe`; everything before it is the left
/// subtree (rendered recursively by trimming `ops_len`). Trailing
/// `optional`s on the right child collapse into nested `try` wraps.
fn renderSuffixChain(
    ir_obj: *const IR,
    sf: *const ast.Node.Suffix,
    ops_len: usize,
    span: ast.Span,
    depth: usize,
    writer: anytype,
) @TypeOf(writer).Error!void {
    // Skip trailing `optional` ops — they wrap the right-child op.
    var rh_end = ops_len;
    var try_wrap_count: usize = 0;
    while (rh_end > 0 and sf.ops[rh_end - 1] == .optional) {
        try_wrap_count += 1;
        rh_end -= 1;
    }

    if (rh_end == 0) {
        // No non-optional ops — every op is a trailing `optional`.
        // Render `try^N(base)` (N nested try wraps over the base).
        var i: usize = 0;
        while (i < try_wrap_count) : (i += 1) {
            try writeIndent(writer, depth + i);
            try writer.writeAll("try");
            try writeSpan(writer, span);
            try writer.writeAll("\n");
        }
        try dumpAst(ir_obj, sf.base, depth + try_wrap_count, writer);
        return;
    }

    // Topmost pipe: left = chain[0 .. rh_end-1], right = ops[rh_end-1]
    // possibly wrapped in `try` (one wrap per trailing optional).
    try writeIndent(writer, depth);
    try writer.writeAll("pipe");
    try writeSpan(writer, span);
    try writer.writeAll("\n");

    // Left subtree: recursive call with reduced ops_len. If
    // rh_end - 1 == 0 the left subtree is just the base.
    if (rh_end - 1 == 0) {
        try dumpAst(ir_obj, sf.base, depth + 1, writer);
    } else {
        try renderSuffixChain(ir_obj, sf, rh_end - 1, span, depth + 1, writer);
    }

    // Right subtree: the rightmost non-optional op, wrapped in
    // `try_wrap_count` nested `try`s.
    var t: usize = 0;
    while (t < try_wrap_count) : (t += 1) {
        try writeIndent(writer, depth + 1 + t);
        try writer.writeAll("try");
        try writeSpan(writer, span);
        try writer.writeAll("\n");
    }
    try dumpSuffixOp(sf.ops[rh_end - 1], depth + 1 + try_wrap_count, span, writer);
}

/// Render a single SuffixOp as the IR node it lowers to. Used by
/// `dumpSuffix` for inner ops; standalone shapes (top-level
/// `field_access`, `iterate`, etc.) flow through `dumpAst` directly.
fn dumpSuffixOp(
    op: ast.Node.SuffixOp,
    depth: usize,
    span: ast.Span,
    writer: anytype,
) @TypeOf(writer).Error!void {
    try writeIndent(writer, depth);
    switch (op) {
        .field => |name| {
            try writer.writeAll("load_field(");
            try writeStringLit(writer, name);
            try writer.writeAll(")");
        },
        .bracket_str => |name| {
            try writer.writeAll("load_field(");
            try writeStringLit(writer, name);
            try writer.writeAll(")");
        },
        .index => |i| try writer.print("load_index({d})", .{i}),
        .iterate => try writer.writeAll("iterate"),
        .slice => |sl| {
            try writer.writeAll("slice(");
            if (sl.has_from) try writer.print("{d}", .{sl.from}) else try writer.writeAll("_");
            try writer.writeAll(", ");
            if (sl.has_to) try writer.print("{d}", .{sl.to}) else try writer.writeAll("_");
            try writer.writeAll(")");
        },
        .optional => unreachable, // handled by renderSuffixChain wrap
        .bracket_expr => try writer.writeAll("# unimplemented(bracket_expr)"),
    }
    try writeSpan(writer, span);
    try writer.writeAll("\n");
}

/// JSON-style escape per spec §3 (`string_lit`). Bytes 0x00..0x1F other
/// than \t and \n become `\uXXXX` four-hex; backslash and double-quote
/// are escaped. Bytes ≥ 0x80 are written raw (UTF-8 source text).
fn writeStringLit(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11, 12, 14...31 => try writer.print("\\u{X:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}
