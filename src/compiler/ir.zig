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

/// `arith` op-kind discriminant. Stored as a u32 in `extra_data[node.extra]`.
/// Mirrors `ast.Node.Arithmetic.ArithOp` one-for-one. Single source of
/// truth for emit + dumper + fuse decode (plan §1.3 row 5).
pub const ArithKind = enum(u32) {
    add = 0,
    sub = 1,
    mul = 2,
    div = 3,
    mod = 4,
};

/// `cmp` op-kind discriminant. Stored as a u32 in `extra_data[node.extra]`.
/// Mirrors `ast.Node.Comparison.CmpOp` one-for-one.
pub const CmpKind = enum(u32) {
    eq = 0,
    ne = 1,
    lt = 2,
    le = 3,
    gt = 4,
    ge = 5,
};

/// `logical` op-kind discriminant. Stored as a u32 in `extra_data[node.extra]`.
/// `and_` / `or_` because `and`/`or` are Zig keywords; the dumper renders
/// them as `and`/`or` (mirroring the spec §3 op-name strip-trailing-underscore
/// convention used for `if_`, `try_`).
pub const LogicalKind = enum(u32) {
    and_ = 0,
    or_ = 1,
};

/// `update_assign` op-kind discriminant. Stored as a u32 in
/// `extra_data[node.extra]`. The first 8 entries cover the operator
/// alphabet shared by `update_assign` and `assign_general` AST node
/// kinds (`ast.Node.UpdateAssign.AssignOp`); `general` is a form
/// marker used when the LHS is non-trivial (the AST routed the
/// expression through `assign_general` rather than `update_assign`)
/// and an additional `extra_data[node.extra + 1]` slot carries the
/// actual operator kind (one of the first 8). Plan §1.3 row 5
/// (`update_assign | binary + extra → op kind`); plan §3 R3 step 6
/// item 8.
///
/// Single source of truth — the same enum decodes lowering, dumper,
/// fuse, and emit. Adding a new operator alphabet entry means
/// updating exactly one `switch` here.
pub const UpdateOpKind = enum(u32) {
    set = 0, // =
    add = 1, // +=
    sub = 2, // -=
    mul = 3, // *=
    div = 4, // /=
    mod = 5, // %=
    alt = 6, // //=
    update = 7, // |=
    /// `assign_general` form — LHS is a non-trivial path expression
    /// (paren-grouped, comma'd, `.[]`, function-based, ...). The
    /// trailing `extra_data[node.extra + 1]` slot carries the actual
    /// operator kind (one of the first 8).
    general = 8,
};

/// `destructure` pattern-kind discriminant. Stored as a u32 in
/// `extra_data[node.extra]` (slot 0). Mirrors the AST `Pattern` union
/// plus the binding-context alt (`?//` desugar). Single source of truth
/// for emit + dumper + fuse decode (plan §1.3 row 5).
///
/// Per-kind extra-data layout (slot 0 is always the kind):
///   .as       → slot 1: name_offset, slot 2: name_len, slot 3: var_id
///   .array    → no trailing slots; sub-patterns live in `extra_children`
///                 via `Node.span_start`/`Node.span_len`
///   .object   → no trailing slots; key/sub-pattern pairs in `extra_children`
///                 (interleaved: k0, p0, k1, p1, …)
///   .alt_bind → no trailing slots; alternative sub-patterns in
///                 `extra_children` (top-level patterns only)
pub const PatternKind = enum(u32) {
    as = 0,
    array = 1,
    object = 2,
    alt_bind = 3,
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
        .pipe => |bp| {
            try writeIndent(writer, depth);
            try writer.writeAll("pipe");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, bp.left, depth + 1, writer);
            try dumpAst(ir_obj, bp.right, depth + 1, writer);
        },
        .comma => |bc| {
            try writeIndent(writer, depth);
            try writer.writeAll("comma");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, bc.left, depth + 1, writer);
            try dumpAst(ir_obj, bc.right, depth + 1, writer);
        },
        .suffix => |sf| try dumpSuffix(ir_obj, &sf, node.span, depth, writer),
        .arithmetic => |bn| {
            const op_name = switch (bn.op) {
                .add => "add",
                .sub => "sub",
                .mul => "mul",
                .div => "div",
                .mod => "mod",
            };
            try writeIndent(writer, depth);
            try writer.print("arith({s})", .{op_name});
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, bn.left, depth + 1, writer);
            try dumpAst(ir_obj, bn.right, depth + 1, writer);
        },
        .comparison => |bn| {
            const op_name = switch (bn.op) {
                .eq => "eq",
                .ne => "ne",
                .lt => "lt",
                .le => "le",
                .gt => "gt",
                .ge => "ge",
            };
            try writeIndent(writer, depth);
            try writer.print("cmp({s})", .{op_name});
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, bn.left, depth + 1, writer);
            try dumpAst(ir_obj, bn.right, depth + 1, writer);
        },
        .and_expr => |bn| {
            try writeIndent(writer, depth);
            try writer.writeAll("logical(and)");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, bn.left, depth + 1, writer);
            try dumpAst(ir_obj, bn.right, depth + 1, writer);
        },
        .or_expr => |bn| {
            try writeIndent(writer, depth);
            try writer.writeAll("logical(or)");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, bn.left, depth + 1, writer);
            try dumpAst(ir_obj, bn.right, depth + 1, writer);
        },
        .alternative => |bn| {
            try writeIndent(writer, depth);
            try writer.writeAll("alt");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, bn.left, depth + 1, writer);
            try dumpAst(ir_obj, bn.right, depth + 1, writer);
        },
        .builtin_call => |bc| {
            try writeIndent(writer, depth);
            if (bc.args.len == 0 and std.mem.eql(u8, bc.name, "not")) {
                try writer.writeAll("not");
                try writeSpan(writer, node.span);
                try writer.writeAll("\n");
                return;
            }
            // `path(expr)` lowers to a unary `path_begin` IR node — render
            // the dump in the same shape so the text format mirrors the
            // IR (cat-6, Phase 12). The dedicated `path_end` SemOp stays
            // emit-only and never appears in the dump tree.
            if (bc.args.len == 1 and std.mem.eql(u8, bc.name, "path")) {
                try writer.writeAll("path_begin");
                try writeSpan(writer, node.span);
                try writer.writeAll("\n");
                try dumpAst(ir_obj, bc.args[0], depth + 1, writer);
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
        .object_construct => |oc| {
            try writeIndent(writer, depth);
            try writer.writeAll("obj_ctor");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            // Render every (key, value) pair as two indented children.
            // Ident/string keys mirror `synthLoadConstString` — the IR
            // synthesizes a `load_const(string)` for them; the dump
            // shows the same shape as a real string literal so the
            // text format remains uniform across key shapes.
            for (oc.fields) |fld| {
                try dumpObjectKey(ir_obj, &fld, depth + 1, writer);
                try dumpAst(ir_obj, fld.value, depth + 1, writer);
            }
        },
        .array_construct => |ac| {
            try writeIndent(writer, depth);
            try writer.writeAll("arr_ctor");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            if (ac.expr) |inner| {
                // Flatten comma chains so the dump matches the IR's
                // variadic span exactly (lowering pre-flattens for the
                // same reason — see `collectArrayElems`).
                try dumpArrayElems(ir_obj, inner, depth + 1, writer);
            }
        },
        .string_interp => |si| {
            try writeIndent(writer, depth);
            try writer.writeAll("interp");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpStringParts(ir_obj, si.parts, node.span, depth + 1, writer);
        },
        .format_string => |fs| {
            try writeIndent(writer, depth);
            try writer.writeAll("format(");
            try writeStringLit(writer, fs.format);
            try writer.writeAll(")");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpStringParts(ir_obj, fs.parts, node.span, depth + 1, writer);
        },
        .update_assign => |ua| {
            // Fast-path AST shape: `.path1.path2[N] OP= rhs`. The path
            // steps are encoded inline in `extra_data` (no IR child for
            // the LHS path); `rhs` is lowered as a normal AST node and
            // appears as the only indented child.
            try writeIndent(writer, depth);
            try writer.writeAll("update_assign(");
            try writer.writeAll(updateOpName(ua.op));
            try writer.writeAll(", path=");
            try writePathSteps(writer, ua.path);
            try writer.writeAll(")");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, ua.rhs, depth + 1, writer);
        },
        .assign_general => |ag| {
            // General-LHS AST shape. The dump renders both LHS and
            // RHS as indented children, mirroring the IR's two child
            // edges. Operator alphabet shared with `update_assign`.
            try writeIndent(writer, depth);
            try writer.writeAll("update_assign(general[");
            try writer.writeAll(updateOpName(ag.op));
            try writer.writeAll("])");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, ag.lhs, depth + 1, writer);
            try dumpAst(ir_obj, ag.rhs, depth + 1, writer);
        },
        // ── Parens `(expr)` (cat-6 — passthrough) ───────────────────
        // The AST has a `paren` wrapper for source-position fidelity;
        // lowering treats it as transparent (the inner IR is emitted
        // directly). The dump mirrors that — recurse into the operand
        // without emitting a wrapper node.
        .paren => |un| try dumpAst(ir_obj, un.operand, depth, writer),
        // ── Try / catch (cat-6) ─────────────────────────────────────
        // Without a catch handler the dump emits `try` with a single
        // child (the body); with a catch handler the second indented
        // child is the handler. Mirrors the IR shape: handler-absent
        // uses `children[0]`, handler-present uses the variable-arity
        // span `[body, handler]` with `span_len == 2`.
        .try_catch => |tc| {
            try writeIndent(writer, depth);
            try writer.writeAll("try");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, tc.body, depth + 1, writer);
            if (tc.catch_body) |handler| {
                try dumpAst(ir_obj, handler, depth + 1, writer);
            }
        },
        // ── if / elif / else (cat-6) ────────────────────────────────
        // elif chains desugar to nested `if` IR nodes at lowering time
        // (one big AST `if_expr` → nested `if(cond1, then1, if(cond2,
        // then2, else))`). The dumper mirrors that: each elif slot
        // produces a nested `if` child in the else position. Implicit
        // else (no `else` clause) materializes as `identity` — matches
        // legacy `parseIfBody` (`src/query/src/compiler.zig:6390`).
        .if_expr => |ifx| try dumpIfExpr(ir_obj, &ifx, node.span, depth, writer),
        // ── Variable load `$name` (category 4) ──────────────────────
        // Mirrors `lowerVariable` — the IR is a leaf `load_var` whose
        // payload echoes the variable name. Var-id resolution happens
        // at lower-time but is not surfaced in the dump (the dump
        // captures source-level shape, not bytecode operand values).
        .variable_ref => |vr| {
            try writeIndent(writer, depth);
            try writer.writeAll("load_var(");
            try writeStringLit(writer, vr.name);
            try writer.writeAll(")");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
        },
        // ── `expr as PATTERN | body` (category 4) ───────────────────
        // Lowering shape: `pipe(expr, pipe(destructure(PATTERN), body))`.
        // The dump mirrors that nested-pipe layout so snapshot diffs
        // line up with the lowered IR. The destructure node renders
        // its sub-pattern children inline.
        .as_pattern => |ap| {
            try writeIndent(writer, depth);
            try writer.writeAll("pipe");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, ap.expr, depth + 1, writer);
            try writeIndent(writer, depth + 1);
            try writer.writeAll("pipe");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpPattern(ir_obj, ap.pattern, node.span, depth + 2, writer);
            try dumpAst(ir_obj, ap.body, depth + 2, writer);
        },
        // ── `expr as P1 ?// P2 ?// … | body` (category 4) ──────────
        // Lowering shape: `pipe(expr, pipe(destructure(alt_bind, …), body))`.
        // Each top-level alternative is itself a pattern subnode of the
        // outer alt_bind destructure.
        .destruct_alt => |da| {
            try writeIndent(writer, depth);
            try writer.writeAll("pipe");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, da.expr, depth + 1, writer);
            try writeIndent(writer, depth + 1);
            try writer.writeAll("pipe");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try writeIndent(writer, depth + 2);
            try writer.writeAll("destructure(alt_bind)");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            for (da.patterns) |alt_pat| {
                try dumpPattern(ir_obj, alt_pat, node.span, depth + 3, writer);
            }
            try dumpAst(ir_obj, da.body, depth + 2, writer);
        },
        else => {
            try writeIndent(writer, depth);
            try writer.print("# unimplemented({s})", .{@tagName(node.kind)});
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
        },
    }
}

/// Render an object-key payload (ident / string / expr) as a
/// `load_const(string)` node for the synthesized literal cases or
/// recurse into the AST for `expr` keys. Matches `lowerObjectKey`'s
/// synthesis so the text dump and the IR shape stay byte-identical.
fn dumpObjectKey(
    ir_obj: *const IR,
    fld: *const ast.Node.ObjectField,
    depth: usize,
    writer: anytype,
) @TypeOf(writer).Error!void {
    switch (fld.key) {
        .ident => |name| {
            try writeIndent(writer, depth);
            try writer.writeAll("load_const(");
            try writeStringLit(writer, name);
            try writer.writeAll(")");
            try writeSpan(writer, fld.span);
            try writer.writeAll("\n");
        },
        .string => |raw_content| {
            try writeIndent(writer, depth);
            try writer.writeAll("load_const(");
            try writeStringLit(writer, raw_content);
            try writer.writeAll(")");
            try writeSpan(writer, fld.span);
            try writer.writeAll("\n");
        },
        .expr => |expr| try dumpAst(ir_obj, expr, depth, writer),
    }
}

/// Recursive walk of the array-construct inner expression, flattening
/// comma chains into element nodes for the dump. Keeps the IR
/// dumper's child sequence aligned with `collectArrayElems` in
/// `lower.zig` — every leaf appears once, in source order.
fn dumpArrayElems(
    ir_obj: *const IR,
    node: *const ast.Node,
    depth: usize,
    writer: anytype,
) @TypeOf(writer).Error!void {
    if (node.kind == .comma) {
        const c = node.kind.comma;
        try dumpArrayElems(ir_obj, c.left, depth, writer);
        try dumpArrayElems(ir_obj, c.right, depth, writer);
        return;
    }
    try dumpAst(ir_obj, node, depth, writer);
}

/// Render an interp/format parts list — literals as `load_const`
/// nodes, exprs via the recursive AST walker. Mirrors
/// `lowerStringParts` so dump shape == IR shape.
fn dumpStringParts(
    ir_obj: *const IR,
    parts: []const ast.Node.StringPart,
    parent_span: ast.Span,
    depth: usize,
    writer: anytype,
) @TypeOf(writer).Error!void {
    for (parts) |part| {
        switch (part) {
            .literal => |s| {
                try writeIndent(writer, depth);
                try writer.writeAll("load_const(");
                try writeStringLit(writer, s);
                try writer.writeAll(")");
                try writeSpan(writer, parent_span);
                try writer.writeAll("\n");
            },
            .expr => |expr| try dumpAst(ir_obj, expr, depth, writer),
        }
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

/// Map an `ast.Node.UpdateAssign.AssignOp` to its dump tag. Single
/// source of truth shared by both `update_assign` and `assign_general`
/// dump paths — the operator alphabet is one and the same.
fn updateOpName(op: ast.Node.UpdateAssign.AssignOp) []const u8 {
    return switch (op) {
        .eq => "set",
        .plus_eq => "add",
        .minus_eq => "sub",
        .star_eq => "mul",
        .slash_eq => "div",
        .percent_eq => "mod",
        .double_slash_eq => "alt",
        .pipe_eq => "update",
    };
}

/// Render a path-step sequence as a `.foo.bar[2]` style string for
/// the fast-path `update_assign` dump payload. Path steps are stored
/// inline in `extra_data`; the dumper has direct access to the AST
/// here so it renders straight from the AST representation. The
/// resulting string is wrapped in quotes for parser ergonomics — the
/// snapshot tests diff bytes only, so the format stays stable.
fn writePathSteps(writer: anytype, steps: []const ast.Node.PathStep) !void {
    try writer.writeByte('"');
    for (steps) |step| {
        switch (step) {
            .key => |name| {
                try writer.writeByte('.');
                // Keys may contain non-ident characters; keep raw bytes
                // (snapshot test compares bytes). Escape backslash and
                // double-quote for round-trip safety.
                for (name) |c| {
                    switch (c) {
                        '"' => try writer.writeAll("\\\""),
                        '\\' => try writer.writeAll("\\\\"),
                        else => try writer.writeByte(c),
                    }
                }
            },
            .index => |i| try writer.print("[{d}]", .{i}),
            .iterate => try writer.writeAll("[]"),
        }
    }
    try writer.writeByte('"');
}

/// Render an `if cond then a [elif c then b]* [else c] end` form as a
/// chain of nested `if` nodes. The first `if` always emits the original
/// `cond`/`then_body`. The else position is either:
///   - the next elif (recursively rendered as a nested `if`),
///   - the explicit else_body, or
///   - `identity` (synthesized — matches legacy implicit-else rule).
/// The `chain_idx` parameter walks the elif list one element per
/// recursion. Snapshot output therefore makes the elif desugar
/// explicit (no `# elif` directive needed; the nested-if shape IS the
/// dump).
fn dumpIfExpr(
    ir_obj: *const IR,
    ifx: *const ast.Node.IfExpr,
    span: ast.Span,
    depth: usize,
    writer: anytype,
) @TypeOf(writer).Error!void {
    try writeIndent(writer, depth);
    try writer.writeAll("if");
    try writeSpan(writer, span);
    try writer.writeAll("\n");
    try dumpAst(ir_obj, ifx.cond, depth + 1, writer);
    try dumpAst(ir_obj, ifx.then_body, depth + 1, writer);
    try dumpIfElsePosition(ir_obj, ifx, 0, span, depth + 1, writer);
}

/// Render the else-arm of an if/elif/else chain. `chain_idx` is the
/// index of the next elif slot to consume; when it equals
/// `ifx.elif_chains.len` the else_body (or synthesized identity) is
/// emitted instead. Each elif consumes one recursion layer, producing
/// a nested `if` node — matching the lowering desugar.
fn dumpIfElsePosition(
    ir_obj: *const IR,
    ifx: *const ast.Node.IfExpr,
    chain_idx: usize,
    span: ast.Span,
    depth: usize,
    writer: anytype,
) @TypeOf(writer).Error!void {
    if (chain_idx < ifx.elif_chains.len) {
        const elif = ifx.elif_chains[chain_idx];
        try writeIndent(writer, depth);
        try writer.writeAll("if");
        try writeSpan(writer, span);
        try writer.writeAll("\n");
        try dumpAst(ir_obj, elif.cond, depth + 1, writer);
        try dumpAst(ir_obj, elif.body, depth + 1, writer);
        try dumpIfElsePosition(ir_obj, ifx, chain_idx + 1, span, depth + 1, writer);
        return;
    }
    if (ifx.else_body) |eb| {
        try dumpAst(ir_obj, eb, depth, writer);
        return;
    }
    // Implicit else → identity. Mirrors legacy `parseIfBody` line 6390.
    try writeIndent(writer, depth);
    try writer.writeAll("identity");
    try writeSpan(writer, span);
    try writer.writeAll("\n");
}

/// Render a destructuring pattern as a `destructure` IR node. Matches
/// `lowerPattern` in `lower.zig` so the text dump and the lowered IR
/// shape stay aligned. The `parent_span` is the AST span of the
/// enclosing `as_pattern` / `destruct_alt` (patterns themselves do not
/// carry AST spans).
fn dumpPattern(
    ir_obj: *const IR,
    pat: ast.Pattern,
    parent_span: ast.Span,
    depth: usize,
    writer: anytype,
) @TypeOf(writer).Error!void {
    try writeIndent(writer, depth);
    switch (pat) {
        .simple => |name| {
            try writer.writeAll("destructure(as, ");
            try writeStringLit(writer, name);
            try writer.writeAll(")");
            try writeSpan(writer, parent_span);
            try writer.writeAll("\n");
        },
        .array => |elems| {
            try writer.writeAll("destructure(array)");
            try writeSpan(writer, parent_span);
            try writer.writeAll("\n");
            for (elems) |sub| {
                try dumpPattern(ir_obj, sub, parent_span, depth + 1, writer);
            }
        },
        .object => |fields| {
            try writer.writeAll("destructure(object)");
            try writeSpan(writer, parent_span);
            try writer.writeAll("\n");
            for (fields) |fld| {
                try dumpPatternKey(ir_obj, fld.key, parent_span, depth + 1, writer);
                try dumpPattern(ir_obj, fld.pattern, parent_span, depth + 1, writer);
            }
        },
    }
}

/// Render an object-pattern key (static or computed) as the IR sub-node
/// the lowerer synthesizes. Static keys become `load_const(string)`;
/// computed keys recurse into the AST expression. Mirrors
/// `lowerPatternKey` in `lower.zig`.
fn dumpPatternKey(
    ir_obj: *const IR,
    key: ast.PatternKey,
    parent_span: ast.Span,
    depth: usize,
    writer: anytype,
) @TypeOf(writer).Error!void {
    switch (key) {
        .static => |name| {
            try writeIndent(writer, depth);
            try writer.writeAll("load_const(");
            try writeStringLit(writer, name);
            try writer.writeAll(")");
            try writeSpan(writer, parent_span);
            try writer.writeAll("\n");
        },
        .computed => |expr| try dumpAst(ir_obj, expr, depth, writer),
    }
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
