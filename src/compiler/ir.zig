//! IR — single-arena tree of `Node`s shared by lowering, fuse, and emission.
//!
//! See `src/compiler/IR-FORMAT.md` for the canonical text-dump shape that
//! snapshot tests will diff (R3, Phase 6+). This file owns the in-memory
//! representation; the dumper, lowering rules, fuse rewrites, and emit logic
//! live in the sibling files.
//!
//! Zig 0.15 unmanaged-collection convention: `std.ArrayListUnmanaged(T){}` for
//! init, allocator passed to every method (matches the rest of the tree, e.g.
//! `src/microbench/main.zig`). The IR's allocator is the arena it was given —
//! `deinit` is a no-op on the lists themselves; the arena owns the storage.
const std = @import("std");

/// Op-namespace classification. `SemOp` ops are produced by `lower.zig`;
/// `EmitOp` ops are produced by `fuse.zig` for emission shortcuts. The
/// IR-walking dumper switches the banner (`# SemOp` / `# EmitOp`) on
/// namespace transitions; emit handles both. Spec
/// `src/compiler/IR-FORMAT.md` §4.
pub const Namespace = enum { sem_op, emit_op };

/// Classify an op tag by its namespace. Single source of truth — the
/// dumper, fuse, and emit all consult this. Plan §1.3 row 6.
pub fn opNamespace(op: Op) Namespace {
    return switch (op) {
        .load_path => .emit_op,
        else => .sem_op,
    };
}

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
    /// Out-of-range numeric literal; payload encoded like string (offset/len).
    big_number = 6,
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
    /// Out-of-range numeric literal in normalized form, e.g. "9E+999999999".
    big_number: []const u8,
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
/// `emit.zig`). The split is documented in `src/compiler/IR-FORMAT.md`
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
    /// Computed-key array/object access (`base[expr]` / `.[expr]`).
    /// `children[0]` lowers the base expression (`identity` for the
    /// standalone `.[expr]` form), `children[1]` lowers the key. Emit
    /// captures the outer input first, evaluates `base` against it,
    /// restores the outer input, then evaluates `key` against it
    /// (jq semantic: `EXPR[key]` — `key` resolves against outer
    /// input, not against `EXPR`'s output). Generator-form bases
    /// and keys re-run the per-iteration `load_computed` for every
    /// yielded value via the natural fork/backtrack flow over the
    /// lowered IR. Plan §3.5 row P27 / cat-18.
    computed_index,

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
    /// `expr as PATTERN | body` (cat-4) and the same shape used as the
    /// outer node by `?//` desugar. The wrapper exists because plain
    /// `pipe(expr, pipe(destructure, body))` would emit an extra `pipe`
    /// opcode between expr and destructure that clobbers `current` with
    /// the EXPR's result — breaking simple-as semantics where `body`
    /// must run on the input that was current BEFORE `expr` evaluated.
    /// Emit shape (mirrors legacy `parseLogical` + user `|` between
    /// `expr as $x` and body, `compiler.zig:2499-2517` plus `parsePipe`'s
    /// trailing `pipe` op):
    ///   <expr>
    ///   <destructure ladder>
    ///   pipe                      ; the user-written | between (expr as $x) and body
    ///   <body>
    /// The IR node uses `extra_children` (span = 3): expr_idx, dx_idx,
    /// body_idx. All variables introduced by the pattern are declared
    /// BEFORE `body` is lowered so `$x` references inside `body` resolve.
    /// Plan §3.5 row P23 / cat-14.
    as_bind,

    path_begin,
    path_end,

    // ── Cat-15: control-flow constructs (label/break/until/while) ──────
    /// `label $name | <body>`. Allocates a fresh label var_id at lower
    /// time, registers it as a label binding, lowers the body with
    /// `$name` visible. `extra_data[node.extra]` carries the var_id;
    /// `children[0]` is the body IR-node index. Emitted as:
    ///   label_begin(exit_ip)         — backpatched to instr after body
    ///   capture_variable($name)
    ///   pipe
    ///   <body>
    ///   exit_ip:                      — handleBreak target
    label,
    /// `break $name`. Loads the label-var (which holds the break token
    /// captured by the matching `label`) and emits `break_op`. Lowering
    /// validates the named binding is a label var (not a regular `as`
    /// binding) and surfaces a structured compile diagnostic on
    /// undefined / non-label names. `extra_data[node.extra]` carries the
    /// resolved var_id. Maps to legacy `parsePipe` `.break_kw` handler
    /// (`compiler.zig:6245`):
    ///   load_variable($name)
    ///   break_op
    break_,
    /// `while(cond; update)`. Streams values by emitting `current` then
    /// piping through `update` while `cond` holds. `children[0]` is the
    /// cond IR root; `children[1]` is the update IR root. Maps to
    /// legacy `compileWhile` (`compiler.zig:3428`):
    ///   loop_top:
    ///     save_input
    ///     <cond>
    ///     jump_if_false → loop_exit
    ///     restore_input
    ///     yield_output                 — emit current
    ///     <update>
    ///     pipe
    ///     jump → loop_top
    ///   loop_exit:
    ///     restore_input
    ///     backtrack
    while_,
    /// `until(cond; update)`. Applies `update` until `cond` holds, then
    /// emits the final value. `children[0]` is the cond IR root;
    /// `children[1]` is the update IR root. Maps to legacy
    /// `compileUntil` (`compiler.zig:3495`):
    ///   loop_top:
    ///     save_input
    ///     <cond>
    ///     jump_if_false → loop_body
    ///     restore_input
    ///     jump → loop_done
    ///   loop_body:
    ///     restore_input
    ///     <update>
    ///     pipe
    ///     jump → loop_top
    ///   loop_done:
    ///     push_current
    until_,

    // ── EmitOp namespace (produced by fuse, consumed by emit) ─────────────
    // Plan §1.3 row 6 / §3 R3 step 8: chained `.a | .b | .c` field loads
    // collapse to a single `load_path` whose payload is the dot-joined key
    // sequence. The payload `extra` indexes a 2-slot `(offset, len)` pair
    // into `string_buf` — same encoding as `load_field` so emit can route
    // both through one decode helper. Maps to legacy
    // `Instruction.Op.load_path` (operand `str_ref`).
    load_path,
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
        .big_number => blk: {
            const offset: u32 = slots[node.extra + 1];
            const len: u32 = slots[node.extra + 2];
            break :blk .{ .big_number = ir_obj.string_buf.items[offset .. offset + len] };
        },
    };
}

// ── Text dumper (used by snapshot tests) ─────────────────────────────────────
// Spec: src/compiler/IR-FORMAT.md §10. Indented-tree, one node per line,
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
    try dumpAst(ir_obj, ast_root, source, 0, writer);
}

/// Cat-10 zero-arg builtin name predicate for the dumper. Mirrors the
/// wider list in `lower.zig` (`isZeroArgBuiltin`) — bare-ident references
/// to these names render as `call_builtin("name")` to match the IR shape
/// produced by `lowerBuiltinCall`. The AST parser's own zero-arg list
/// (`src/ast/parser.zig:1601`) is narrower, so cat-10 picks up the
/// remainder via `field_access` re-classification. Cat-9 disambiguates
/// against this list — bare-ident `field_access` whose name does NOT
/// match any cat-10 builtin renders as `call_user("name")`.
fn isCat10ZeroArgBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "arrays") or
        std.mem.eql(u8, name, "objects") or
        std.mem.eql(u8, name, "strings") or
        std.mem.eql(u8, name, "numbers") or
        std.mem.eql(u8, name, "booleans") or
        std.mem.eql(u8, name, "nulls") or
        std.mem.eql(u8, name, "scalars") or
        std.mem.eql(u8, name, "normals") or
        std.mem.eql(u8, name, "iterables") or
        std.mem.eql(u8, name, "utf8bytelength") or
        std.mem.eql(u8, name, "toboolean") or
        std.mem.eql(u8, name, "trim") or
        std.mem.eql(u8, name, "ltrim") or
        std.mem.eql(u8, name, "rtrim") or
        std.mem.eql(u8, name, "now") or
        std.mem.eql(u8, name, "gmtime") or
        std.mem.eql(u8, name, "mktime") or
        std.mem.eql(u8, name, "todate") or
        std.mem.eql(u8, name, "fromdate") or
        std.mem.eql(u8, name, "todateiso8601") or
        std.mem.eql(u8, name, "fromdateiso8601") or
        std.mem.eql(u8, name, "have_decnum") or
        std.mem.eql(u8, name, "have_literal_numbers");
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
    source: []const u8,
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
                .big_number => |bn| try writer.print("load_const(big_number:{s})", .{bn}),
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
            try dumpAst(ir_obj, un.operand, source, depth + 1, writer);
        },
        .field_access => |fa| {
            try writeIndent(writer, depth);
            // Bare-ident `field_access` (no leading `.` in the source
            // span) is the AST encoding for two distinct surfaces:
            //   * Zero-arg builtins outside the AST parser's narrow
            //     `isZeroArgBuiltin` list (cat-10, e.g. `arrays`,
            //     `now`, `utf8bytelength`) — render as
            //     `call_builtin("name")`.
            //   * Zero-arg user-function calls (cat-9) — render as
            //     `call_user("name")`.
            // Disambiguate by name against `isCat10ZeroArgBuiltin`;
            // the lowerer makes the same decision via
            // `classifyBuiltin`, keeping snapshot output aligned.
            const is_dot_field = node.span.start < source.len and source[node.span.start] == '.';
            if (!is_dot_field) {
                if (isCat10ZeroArgBuiltin(fa.name)) {
                    try writer.writeAll("call_builtin(");
                } else {
                    try writer.writeAll("call_user(");
                }
                try writeStringLit(writer, fa.name);
                try writer.writeAll(")");
                try writeSpan(writer, node.span);
                try writer.writeAll("\n");
                return;
            }
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
            try dumpAst(ir_obj, un.operand, source, depth + 1, writer);
        },
        .pipe => |bp| {
            try writeIndent(writer, depth);
            try writer.writeAll("pipe");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, bp.left, source, depth + 1, writer);
            try dumpAst(ir_obj, bp.right, source, depth + 1, writer);
        },
        .comma => |bc| {
            try writeIndent(writer, depth);
            try writer.writeAll("comma");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, bc.left, source, depth + 1, writer);
            try dumpAst(ir_obj, bc.right, source, depth + 1, writer);
        },
        .suffix => |sf| try dumpSuffix(ir_obj, &sf, node.span, source, depth, writer),
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
            try dumpAst(ir_obj, bn.left, source, depth + 1, writer);
            try dumpAst(ir_obj, bn.right, source, depth + 1, writer);
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
            try dumpAst(ir_obj, bn.left, source, depth + 1, writer);
            try dumpAst(ir_obj, bn.right, source, depth + 1, writer);
        },
        .and_expr => |bn| {
            try writeIndent(writer, depth);
            try writer.writeAll("logical(and)");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, bn.left, source, depth + 1, writer);
            try dumpAst(ir_obj, bn.right, source, depth + 1, writer);
        },
        .or_expr => |bn| {
            try writeIndent(writer, depth);
            try writer.writeAll("logical(or)");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, bn.left, source, depth + 1, writer);
            try dumpAst(ir_obj, bn.right, source, depth + 1, writer);
        },
        .alternative => |bn| {
            try writeIndent(writer, depth);
            try writer.writeAll("alt");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, bn.left, source, depth + 1, writer);
            try dumpAst(ir_obj, bn.right, source, depth + 1, writer);
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
                try dumpAst(ir_obj, bc.args[0], source, depth + 1, writer);
                return;
            }
            // Cat-15 — `while(cond; update)` and `until(cond; update)`
            // lower to dedicated SemOps `while_` / `until_`. Render in
            // the IR-level shape so snapshot diffs match the lowered tree.
            if (bc.args.len == 2 and std.mem.eql(u8, bc.name, "while")) {
                try writer.writeAll("while");
                try writeSpan(writer, node.span);
                try writer.writeAll("\n");
                try dumpAst(ir_obj, bc.args[0], source, depth + 1, writer);
                try dumpAst(ir_obj, bc.args[1], source, depth + 1, writer);
                return;
            }
            if (bc.args.len == 2 and std.mem.eql(u8, bc.name, "until")) {
                try writer.writeAll("until");
                try writeSpan(writer, node.span);
                try writer.writeAll("\n");
                try dumpAst(ir_obj, bc.args[0], source, depth + 1, writer);
                try dumpAst(ir_obj, bc.args[1], source, depth + 1, writer);
                return;
            }
            // `__computed_access(expr)` is the parser's synthesized form
            // for standalone `.[expr]`. Lowers to the cat-18 binary
            // `computed_index(base, key)` SemOp; the base is `identity`
            // (the outer input itself), the key is the bracketed
            // expression. Render that shape so suffixed and standalone
            // forms surface uniformly. Plan §3.5 row P27.
            if (bc.args.len == 1 and std.mem.eql(u8, bc.name, "__computed_access")) {
                try writer.writeAll("computed_index");
                try writeSpan(writer, node.span);
                try writer.writeAll("\n");
                try writeIndent(writer, depth + 1);
                try writer.writeAll("identity");
                try writeSpan(writer, node.span);
                try writer.writeAll("\n");
                try dumpAst(ir_obj, bc.args[0], source, depth + 1, writer);
                return;
            }
            // Generic builtin call: rendered as `call_builtin("name")`.
            // For regex builtins with a literal pattern arg, also
            // render the pool ref annotation per spec §6 "Regex pool
            // refs": `call_builtin("name", re_0 "/<pat>/<flags>")`.
            // The pool index is rendered as `re_0` because the
            // dumper has no access to the lowerer's interned
            // index — snapshot stability comes from the
            // human-readable pattern + flag suffix.
            try writer.writeAll("call_builtin(");
            try writeStringLit(writer, bc.name);
            if (isRegexBuiltinByName(bc.name)) {
                try writeRegexPoolRef(writer, &bc);
            }
            try writer.writeAll(")");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            // For regex builtins, skip the args absorbed into the
            // pool ref (literal pattern + literal flags); render the
            // rest as ordinary children. Non-regex builtins render
            // every arg.
            for (bc.args, 0..) |arg, i| {
                if (isRegexBuiltinByName(bc.name) and shouldSkipRegexArg(&bc, i)) continue;
                try dumpAst(ir_obj, arg, source, depth + 1, writer);
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
                try dumpObjectKey(ir_obj, &fld, source, depth + 1, writer);
                // Shorthand object field — `{a}` / `{a, b}` — has a
                // synthesized `field_access` value whose span starts
                // at the key (no leading `.`). Render as `load_field`
                // directly: the cat-9 bare-ident-as-`call_user`
                // disambiguation in the generic `field_access` arm
                // would otherwise mis-render shorthands as UDF calls.
                if (fld.value.kind == .field_access and fld.value.span.start == fld.span.start) {
                    const fa = fld.value.kind.field_access;
                    try writeIndent(writer, depth + 1);
                    try writer.writeAll("load_field(");
                    try writeStringLit(writer, fa.name);
                    try writer.writeAll(")");
                    try writeSpan(writer, fld.value.span);
                    try writer.writeAll("\n");
                    continue;
                }
                try dumpAst(ir_obj, fld.value, source, depth + 1, writer);
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
                try dumpArrayElems(ir_obj, inner, source, depth + 1, writer);
            }
        },
        .string_interp => |si| {
            try writeIndent(writer, depth);
            try writer.writeAll("interp");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpStringParts(ir_obj, si.parts, node.span, source, depth + 1, writer);
        },
        .format_string => |fs| {
            try writeIndent(writer, depth);
            try writer.writeAll("format(");
            try writeStringLit(writer, fs.format);
            try writer.writeAll(")");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpStringParts(ir_obj, fs.parts, node.span, source, depth + 1, writer);
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
            try dumpAst(ir_obj, ua.rhs, source, depth + 1, writer);
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
            try dumpAst(ir_obj, ag.lhs, source, depth + 1, writer);
            try dumpAst(ir_obj, ag.rhs, source, depth + 1, writer);
        },
        // ── Parens `(expr)` (cat-6 — passthrough) ───────────────────
        // The AST has a `paren` wrapper for source-position fidelity;
        // lowering treats it as transparent (the inner IR is emitted
        // directly). The dump mirrors that — recurse into the operand
        // without emitting a wrapper node.
        .paren => |un| try dumpAst(ir_obj, un.operand, source, depth, writer),
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
            try dumpAst(ir_obj, tc.body, source, depth + 1, writer);
            if (tc.catch_body) |handler| {
                try dumpAst(ir_obj, handler, source, depth + 1, writer);
            }
        },
        // ── if / elif / else (cat-6) ────────────────────────────────
        // elif chains desugar to nested `if` IR nodes at lowering time
        // (one big AST `if_expr` → nested `if(cond1, then1, if(cond2,
        // then2, else))`). The dumper mirrors that: each elif slot
        // produces a nested `if` child in the else position. Implicit
        // else (no `else` clause) materializes as `identity`.
        .if_expr => |ifx| try dumpIfExpr(ir_obj, &ifx, node.span, source, depth, writer),
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
            // Lowering shape: `as_bind(expr, destructure, body)` —
            // emits `<expr> ; <destructure ladder> ; pipe ; <body>` so
            // `body` runs against the input that was current BEFORE
            // `expr` evaluated (mirrors legacy `parseLogical` flow).
            try writeIndent(writer, depth);
            try writer.writeAll("as_bind");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, ap.expr, source, depth + 1, writer);
            try dumpPattern(ir_obj, ap.pattern, node.span, source, depth + 1, writer);
            try dumpAst(ir_obj, ap.body, source, depth + 1, writer);
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
            try dumpAst(ir_obj, da.expr, source, depth + 1, writer);
            try writeIndent(writer, depth + 1);
            try writer.writeAll("pipe");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try writeIndent(writer, depth + 2);
            try writer.writeAll("destructure(alt_bind)");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            for (da.patterns) |alt_pat| {
                try dumpPattern(ir_obj, alt_pat, node.span, source, depth + 3, writer);
            }
            try dumpAst(ir_obj, da.body, source, depth + 2, writer);
        },
        // ── User-defined function definition (cat-9) ────────────────
        // The def itself produces no IR — only the `rest`
        // continuation flows into the IR tree. The dump mirrors that:
        // recurse into `rest` at the SAME depth, with no header for
        // the def. Single-source-of-truth with `lowerFuncDef` in
        // `lower.zig` (which also emits no IR for the def itself).
        .func_def => |fd| try dumpAst(ir_obj, fd.rest, source, depth, writer),

        // ── User-defined function call (cat-9) ──────────────────────
        // Render as `call_user("name")` followed by the AST args at
        // depth+1. This is the source-level shape — internally
        // lowering may inline-expand the body or emit a recursive
        // `call_user` IR node, but the dump captures the source
        // intent. The function name is rendered as a string literal
        // so the snapshot diff stays stable across name escaping.
        .func_call => |fc| {
            try writeIndent(writer, depth);
            try writer.writeAll("call_user(");
            try writeStringLit(writer, fc.name);
            try writer.writeAll(")");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            for (fc.args) |arg| {
                try dumpAst(ir_obj, arg, source, depth + 1, writer);
            }
        },
        // ── Cat-15 — `label $name | <body>` ─────────────────────────
        // Renders without the var_id (which is allocated only at lower
        // time and not visible from the AST walk). The IR-side dumper
        // surfaces the var_id; this one is the source-level shape so
        // snapshot diffs read like the input filter.
        .label_expr => |le| {
            try writeIndent(writer, depth);
            try writer.writeAll("label(");
            try writeStringLit(writer, le.name);
            try writer.writeAll(")");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, le.body, source, depth + 1, writer);
        },
        // ── Cat-14 — `reduce EXPR as PAT (INIT; UPDATE)` ────────────
        // Renders four children in lowering order: expr, pattern,
        // init, update. Mirrors `lowerReduce`'s span layout so the
        // snapshot diff line-up tracks the IR storage exactly.
        .reduce => |rd| {
            try writeIndent(writer, depth);
            try writer.writeAll("reduce");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, rd.expr, source, depth + 1, writer);
            try dumpPattern(ir_obj, rd.pattern, node.span, source, depth + 1, writer);
            try dumpAst(ir_obj, rd.init, source, depth + 1, writer);
            try dumpAst(ir_obj, rd.update, source, depth + 1, writer);
        },
        // ── Cat-14 — `foreach EXPR as PAT (INIT; UPDATE [; EXTRACT])` ──
        // Renders 4 or 5 children depending on extract presence. Same
        // ordering as `lowerForeach` so snapshot lines map 1:1 with
        // the IR span.
        .foreach => |fe| {
            try writeIndent(writer, depth);
            try writer.writeAll("foreach");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
            try dumpAst(ir_obj, fe.expr, source, depth + 1, writer);
            try dumpPattern(ir_obj, fe.pattern, node.span, source, depth + 1, writer);
            try dumpAst(ir_obj, fe.init, source, depth + 1, writer);
            try dumpAst(ir_obj, fe.update, source, depth + 1, writer);
            if (fe.extract) |ex| try dumpAst(ir_obj, ex, source, depth + 1, writer);
        },
        // ── Cat-15 — `break $name` ─────────────────────────────────
        // The body has no children; the var-name is rendered so the
        // dump remains source-faithful.
        .break_expr => |be| {
            try writeIndent(writer, depth);
            try writer.writeAll("break(");
            try writeStringLit(writer, be.name);
            try writer.writeAll(")");
            try writeSpan(writer, node.span);
            try writer.writeAll("\n");
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
    source: []const u8,
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
        .expr => |expr| try dumpAst(ir_obj, expr, source, depth, writer),
    }
}

/// Recursive walk of the array-construct inner expression, flattening
/// comma chains into element nodes for the dump. Keeps the IR
/// dumper's child sequence aligned with `collectArrayElems` in
/// `lower.zig` — every leaf appears once, in source order.
fn dumpArrayElems(
    ir_obj: *const IR,
    node: *const ast.Node,
    source: []const u8,
    depth: usize,
    writer: anytype,
) @TypeOf(writer).Error!void {
    if (node.kind == .comma) {
        const c = node.kind.comma;
        try dumpArrayElems(ir_obj, c.left, source, depth, writer);
        try dumpArrayElems(ir_obj, c.right, source, depth, writer);
        return;
    }
    try dumpAst(ir_obj, node, source, depth, writer);
}

/// Render an interp/format parts list — literals as `load_const`
/// nodes, exprs via the recursive AST walker. Mirrors
/// `lowerStringParts` so dump shape == IR shape.
fn dumpStringParts(
    ir_obj: *const IR,
    parts: []const ast.Node.StringPart,
    parent_span: ast.Span,
    source: []const u8,
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
            .expr => |expr| try dumpAst(ir_obj, expr, source, depth, writer),
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
    source: []const u8,
    depth: usize,
    writer: anytype,
) @TypeOf(writer).Error!void {
    try renderSuffixChain(ir_obj, sf, sf.ops.len, span, source, depth, writer);
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
    source: []const u8,
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
        try dumpAst(ir_obj, sf.base, source, depth + try_wrap_count, writer);
        return;
    }

    // `bracket_expr` carries an AST sub-tree (the key expression).
    // Lowering produces a binary `computed_index(base, key)` node
    // (no surrounding pipe) — base is the chain accumulated so far,
    // key is the bracketed expression evaluated against the outer
    // input. Render that shape directly. Trailing `optional`s on
    // the bracket op nest `try` wraps around the `computed_index`.
    const tail_op = sf.ops[rh_end - 1];
    if (tail_op == .bracket_expr) {
        var t: usize = 0;
        while (t < try_wrap_count) : (t += 1) {
            try writeIndent(writer, depth + t);
            try writer.writeAll("try");
            try writeSpan(writer, span);
            try writer.writeAll("\n");
        }
        try writeIndent(writer, depth + try_wrap_count);
        try writer.writeAll("computed_index");
        try writeSpan(writer, span);
        try writer.writeAll("\n");
        // Base chain (children[0]).
        if (rh_end - 1 == 0) {
            try dumpAst(ir_obj, sf.base, source, depth + 1 + try_wrap_count, writer);
        } else {
            try renderSuffixChain(ir_obj, sf, rh_end - 1, span, source, depth + 1 + try_wrap_count, writer);
        }
        // Key expression (children[1]).
        try dumpAst(ir_obj, tail_op.bracket_expr, source, depth + 1 + try_wrap_count, writer);
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
        try dumpAst(ir_obj, sf.base, source, depth + 1, writer);
    } else {
        try renderSuffixChain(ir_obj, sf, rh_end - 1, span, source, depth + 1, writer);
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
    try dumpSuffixOp(tail_op, depth + 1 + try_wrap_count, span, writer);
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
        // Invariant: `bracket_expr` always reaches `renderSuffixChain`
        // as the rightmost (post-trailing-`optional`-skip) op of some
        // sub-chain. The chain renderer recursively peels the rightmost
        // op into the right child of a `pipe` and recurses into the
        // shorter left chain; at every recursion the rightmost is
        // explicitly checked for `bracket_expr` BEFORE delegating to
        // this `dumpSuffixOp` (see `renderSuffixChain` tail special-case
        // ~line 998). The standalone `.[expr]` form never reaches here
        // either — it parses as `BuiltinCall{__computed_access, [expr]}`
        // and is rendered by the dedicated arm in `dumpAst`. Lock-in
        // snapshot: `cat-18-bracket-mid-chain.txt` exercises a chain
        // with `bracket_expr` in the middle position.
        .bracket_expr => unreachable,
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
    source: []const u8,
    depth: usize,
    writer: anytype,
) @TypeOf(writer).Error!void {
    try writeIndent(writer, depth);
    try writer.writeAll("if");
    try writeSpan(writer, span);
    try writer.writeAll("\n");
    try dumpAst(ir_obj, ifx.cond, source, depth + 1, writer);
    try dumpAst(ir_obj, ifx.then_body, source, depth + 1, writer);
    try dumpIfElsePosition(ir_obj, ifx, 0, span, source, depth + 1, writer);
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
    source: []const u8,
    depth: usize,
    writer: anytype,
) @TypeOf(writer).Error!void {
    if (chain_idx < ifx.elif_chains.len) {
        const elif = ifx.elif_chains[chain_idx];
        try writeIndent(writer, depth);
        try writer.writeAll("if");
        try writeSpan(writer, span);
        try writer.writeAll("\n");
        try dumpAst(ir_obj, elif.cond, source, depth + 1, writer);
        try dumpAst(ir_obj, elif.body, source, depth + 1, writer);
        try dumpIfElsePosition(ir_obj, ifx, chain_idx + 1, span, source, depth + 1, writer);
        return;
    }
    if (ifx.else_body) |eb| {
        try dumpAst(ir_obj, eb, source, depth, writer);
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
    source: []const u8,
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
                try dumpPattern(ir_obj, sub, parent_span, source, depth + 1, writer);
            }
        },
        .object => |fields| {
            try writer.writeAll("destructure(object)");
            try writeSpan(writer, parent_span);
            try writer.writeAll("\n");
            for (fields) |fld| {
                try dumpPatternKey(ir_obj, fld.key, parent_span, source, depth + 1, writer);
                try dumpPattern(ir_obj, fld.pattern, parent_span, source, depth + 1, writer);
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
    source: []const u8,
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
        .computed => |expr| try dumpAst(ir_obj, expr, source, depth, writer),
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

// ── Regex-aware dumper helpers (cat-11) ─────────────────────────────────────

/// Recognize regex builtin names for dump-time pool-ref rendering.
/// Mirrors `lower.isRegex1BuiltinName` / `isRegex2BuiltinName` — kept
/// inline because the dumper is pure and shouldn't depend on
/// `lower.zig`. The internal `match__g` variant is included so a
/// `match("pat";"g")` source still routes through the regex render
/// path even after lowering substitutes the bid name.
fn isRegexBuiltinByName(name: []const u8) bool {
    return std.mem.eql(u8, name, "test") or
        std.mem.eql(u8, name, "match") or
        std.mem.eql(u8, name, "match__g") or
        std.mem.eql(u8, name, "capture") or
        std.mem.eql(u8, name, "scan") or
        std.mem.eql(u8, name, "splits") or
        std.mem.eql(u8, name, "sub") or
        std.mem.eql(u8, name, "gsub");
}

/// Decide whether the dumper should skip arg index `i` of a regex
/// `builtin_call` because the arg is absorbed into the inline pool
/// ref rendering. Pattern arg (idx 0) is skipped when literal; flag
/// arg (idx 1 for 1-arg builtins, idx 2 for sub/gsub) is skipped
/// when literal.
fn shouldSkipRegexArg(bc: *const ast.Node.BuiltinCall, i: usize) bool {
    if (bc.args.len == 0) return false;
    const is_2arg = std.mem.eql(u8, bc.name, "sub") or std.mem.eql(u8, bc.name, "gsub");
    const flag_arg_idx: usize = if (is_2arg) 2 else 1;
    if (i == 0) {
        // Skip pattern arg if it's a literal string.
        if (bc.args[0].kind == .literal) {
            switch (bc.args[0].kind.literal) {
                .string => return true,
                else => {},
            }
        }
        return false;
    }
    if (i == flag_arg_idx and bc.args.len > flag_arg_idx) {
        // Skip the flag arg if it's a literal string.
        if (bc.args[i].kind == .literal) {
            switch (bc.args[i].kind.literal) {
                .string => return true,
                else => {},
            }
        }
    }
    return false;
}

/// Render an inline `, re_<idx> "/<pattern>/<flags>"` pool ref for
/// regex builtins whose pattern arg is a string literal. When the
/// pattern is dynamic (a non-literal expression), nothing is rendered
/// — the pattern lowers to a regular IR child instead, and the dump
/// shows it as such. Pool index renders as `re_0` because the
/// dumper has no access to the lowerer's interned index; snapshot
/// stability comes from the human-readable pattern + flag suffix per
/// spec §6 worked example.
fn writeRegexPoolRef(writer: anytype, bc: *const ast.Node.BuiltinCall) !void {
    if (bc.args.len == 0) return;
    const pat_lit = switch (bc.args[0].kind) {
        .literal => |lit| switch (lit) {
            .string => |s| s,
            else => return,
        },
        else => return,
    };

    // Detect a literal flag string at args[1] for 1-arg regex
    // builtins (test/match/...) or args[2] for 2-arg (sub/gsub).
    var flag_body: []const u8 = "";
    const is_2arg = std.mem.eql(u8, bc.name, "sub") or std.mem.eql(u8, bc.name, "gsub");
    const flag_arg_idx: usize = if (is_2arg) 2 else 1;
    if (bc.args.len > flag_arg_idx and bc.args[flag_arg_idx].kind == .literal) {
        switch (bc.args[flag_arg_idx].kind.literal) {
            .string => |s| flag_body = s,
            else => {},
        }
    }

    try writer.writeAll(", re_0 \"/");
    // Pattern body: emit raw bytes with JSON-style escapes applied
    // (per spec §6 "Regex pool refs" example).
    for (pat_lit) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11, 12, 14...31 => try writer.print("\\u{X:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll("/");
    // Strip the `g` flag — `match__g` already encodes that signal in
    // the renamed bid; rendering `g` here would confuse the snapshot
    // reader. Other flags (i/x/m/s/n) flow through verbatim.
    for (flag_body) |c| {
        switch (c) {
            'g' => continue,
            'i', 'x', 'm', 's', 'n' => try writer.writeByte(c),
            else => {},
        }
    }
    try writer.writeAll("\"");
}

// ── IR-walking dumper (fuse snapshots) ──────────────────────────────────────
//
// The AST-walking `dump()` above renders the IR in source order — sufficient
// for `lower/` snapshots where the IR matches the AST. After fuse, the IR
// no longer mirrors the AST (chained `load_field`s collapse to `load_path`
// EmitOps). The fuse snapshot suite (`tests/compiler/snapshots/fuse/`)
// therefore drives this IR-walking dumper instead, so the post-rewrite
// shape surfaces in the diff.
//
// The dumper writes the namespace banner (`# SemOp` / `# EmitOp`) on entry
// and re-emits it at every namespace transition encountered during the
// walk. Single-namespace IRs see exactly one banner; mixed IRs see one
// per transition. Spec `src/compiler/IR-FORMAT.md` §4.

/// Dump-time state for namespace banner switching during a recursive
/// IR walk. The first emitted node always emits its banner; subsequent
/// nodes emit a fresh banner only on a SemOp ↔ EmitOp transition.
const NamespaceTracker = struct {
    last: ?Namespace = null,

    fn maybeEmit(self: *NamespaceTracker, ns: Namespace, writer: anytype) @TypeOf(writer).Error!void {
        if (self.last) |prev| {
            if (prev == ns) return;
        }
        self.last = ns;
        switch (ns) {
            .sem_op => try writer.writeAll("# SemOp\n"),
            .emit_op => try writer.writeAll("# EmitOp\n"),
        }
    }
};

/// Dump the IR tree rooted at the last-pushed node. Emits the namespace
/// banner before the first node and on every SemOp ↔ EmitOp transition,
/// then walks the tree depth-first, rendering each node with its payload
/// and source span. Used by the fuse snapshot harness; the `dump()` AST
/// walker is preferred for `lower/` snapshots because it captures the
/// source-order shape independent of IR storage choices.
///
/// Returns immediately on an empty IR (no banner, no tree). Lowering
/// always produces at least one node for a non-empty AST, so this only
/// fires on malformed/no-op inputs.
pub fn dumpIR(
    ir_obj: *const IR,
    writer: anytype,
) @TypeOf(writer).Error!void {
    if (ir_obj.nodes.items.len == 0) return;
    const root_idx: u32 = @intCast(ir_obj.nodes.items.len - 1);
    var tracker: NamespaceTracker = .{};
    try dumpIRNode(ir_obj, root_idx, 0, &tracker, writer);
}

/// Dump an arbitrary subtree starting from `root_idx`. Used by the
/// fuse snapshot harness to render off-tree subtrees that aren't
/// reachable from the IR's last-pushed node — specifically cat-9
/// `function_table.body_ir_root` references, which `emit` walks via
/// the function table rather than via the IR root. Banner switching
/// follows the same rules as `dumpIR`.
pub fn dumpIRSubtree(
    ir_obj: *const IR,
    root_idx: u32,
    writer: anytype,
) @TypeOf(writer).Error!void {
    if (root_idx >= ir_obj.nodes.items.len) return;
    var tracker: NamespaceTracker = .{};
    try dumpIRNode(ir_obj, root_idx, 0, &tracker, writer);
}

/// Render a single IR node and recurse into its children. Each node line
/// is preceded by the appropriate banner if the namespace changed since
/// the last emitted line.
fn dumpIRNode(
    ir_obj: *const IR,
    node_idx: u32,
    depth: usize,
    tracker: *NamespaceTracker,
    writer: anytype,
) @TypeOf(writer).Error!void {
    const node = ir_obj.nodes.items[node_idx];
    try tracker.maybeEmit(opNamespace(node.op), writer);
    try writeIndent(writer, depth);
    try renderNodePayload(ir_obj, node, writer);
    try writeIRSpan(writer, node);
    try writer.writeAll("\n");
    try dumpIRChildren(ir_obj, node, depth + 1, tracker, writer);
}

/// Render one node's `op_tag(payload)` head — span and newline are
/// appended by the caller. Single-source-of-truth payload decoding for
/// each op variant. Op variants without inline payloads emit only the
/// tag; variants whose payload semantics aren't fully decoded by the
/// dumper fall back to `extra=<index>` per spec §6.
fn renderNodePayload(ir_obj: *const IR, node: Node, writer: anytype) !void {
    switch (node.op) {
        .load_const => {
            const value = loadConstValue(ir_obj, node);
            switch (value) {
                .null_val => try writer.writeAll("load_const(null)"),
                .bool_val => |b| try writer.print("load_const({s})", .{if (b) "true" else "false"}),
                .int => |n| try writer.print("load_const({d})", .{n}),
                .float => |f| try writer.print("load_const({d})", .{f}),
                .string => |s| {
                    try writer.writeAll("load_const(");
                    try writeStringLit(writer, s);
                    try writer.writeAll(")");
                },
                .big_number => |bn| try writer.print("load_const(big_number({s}))", .{bn}),
            }
        },
        .load_var => {
            // Var-id lives at extra_data[extra]; the var's name is not
            // stored on the IR (var_table lives on the Lowerer). Render
            // as `load_var(id=<n>)` so fuse-snapshot diffs stay stable
            // without depending on the lowerer's name table.
            const slots = ir_obj.extra_data.items;
            const var_id: u32 = slots[node.extra];
            try writer.print("load_var(id={d})", .{var_id});
        },
        .identity => try writer.writeAll("identity"),
        .load_field => {
            const slots = ir_obj.extra_data.items;
            const offset: u32 = slots[node.extra];
            const len: u32 = slots[node.extra + 1];
            const name = ir_obj.string_buf.items[offset .. offset + len];
            try writer.writeAll("load_field(");
            try writeStringLit(writer, name);
            try writer.writeAll(")");
        },
        .load_index => {
            const slots = ir_obj.extra_data.items;
            const lo: u64 = slots[node.extra];
            const hi: u64 = slots[node.extra + 1];
            const u: u64 = lo | (hi << 32);
            const n: i64 = @bitCast(u);
            try writer.print("load_index({d})", .{n});
        },
        .slice => {
            const slots = ir_obj.extra_data.items;
            const from_u: u32 = slots[node.extra];
            const to_u: u32 = slots[node.extra + 1];
            const flags: u32 = slots[node.extra + 2];
            const has_from = (flags & 1) != 0;
            const has_to = (flags & 2) != 0;
            try writer.writeAll("slice(");
            if (has_from) try writer.print("{d}", .{@as(i32, @bitCast(from_u))}) else try writer.writeAll("_");
            try writer.writeAll(", ");
            if (has_to) try writer.print("{d}", .{@as(i32, @bitCast(to_u))}) else try writer.writeAll("_");
            try writer.writeAll(")");
        },
        .pipe => try writer.writeAll("pipe"),
        .comma => try writer.writeAll("comma"),
        .computed_index => try writer.writeAll("computed_index"),
        .iterate => try writer.writeAll("iterate"),
        .recurse => try writer.writeAll("recurse"),
        .try_ => try writer.writeAll("try"),
        .neg => try writer.writeAll("neg"),
        .not => try writer.writeAll("not"),
        // Cat-5 + cat-6 binary/composite ops: render the op-kind via the
        // shared discriminator enums (single-source-of-truth with the
        // AST dumper's strings).
        .arith => {
            const kind: ArithKind = @enumFromInt(ir_obj.extra_data.items[node.extra]);
            const name = switch (kind) {
                .add => "add",
                .sub => "sub",
                .mul => "mul",
                .div => "div",
                .mod => "mod",
            };
            try writer.print("arith({s})", .{name});
        },
        .cmp => {
            const kind: CmpKind = @enumFromInt(ir_obj.extra_data.items[node.extra]);
            const name = switch (kind) {
                .eq => "eq",
                .ne => "ne",
                .lt => "lt",
                .le => "le",
                .gt => "gt",
                .ge => "ge",
            };
            try writer.print("cmp({s})", .{name});
        },
        .logical => {
            const kind: LogicalKind = @enumFromInt(ir_obj.extra_data.items[node.extra]);
            try writer.print("logical({s})", .{switch (kind) {
                .and_ => "and",
                .or_ => "or",
            }});
        },
        .alt => try writer.writeAll("alt"),
        .if_ => try writer.writeAll("if"),
        .reduce => try writer.writeAll("reduce"),
        .foreach => try writer.writeAll("foreach"),
        .interp => try writer.writeAll("interp"),
        .format => {
            // Format payload encoding varies by lowering site; render as
            // `format(extra=<i>)` fallback per spec §6 — fuse fixtures
            // don't cover format strings.
            try writer.print("format(extra={d})", .{node.extra});
        },
        .obj_ctor => try writer.writeAll("obj_ctor"),
        .arr_ctor => try writer.writeAll("arr_ctor"),
        .call_user => {
            // call_user payload is `extra_data[extra+0]` = fn_id; the
            // fn name lives on Lowerer's function_table. Render with
            // the id only — fuse fixtures don't cross UDF boundaries.
            const fn_id: u32 = ir_obj.extra_data.items[node.extra];
            try writer.print("call_user(fn_id={d})", .{fn_id});
        },
        .call_builtin => {
            // call_builtin payload is `extra_data[extra+0]` = name
            // string-buf id (offset), `[extra+1]` = len. Mirrors
            // load_field's encoding so the fuse dumper resolves both
            // through the same path.
            const slots = ir_obj.extra_data.items;
            const offset: u32 = slots[node.extra];
            const len: u32 = slots[node.extra + 1];
            const name = ir_obj.string_buf.items[offset .. offset + len];
            try writer.writeAll("call_builtin(");
            try writeStringLit(writer, name);
            try writer.writeAll(")");
        },
        .update_assign => {
            const kind: UpdateOpKind = @enumFromInt(ir_obj.extra_data.items[node.extra]);
            try writer.print("update_assign({s})", .{switch (kind) {
                .set => "set",
                .add => "add",
                .sub => "sub",
                .mul => "mul",
                .div => "div",
                .mod => "mod",
                .alt => "alt",
                .update => "update",
                .general => "general",
            }});
        },
        .destructure => {
            const kind: PatternKind = @enumFromInt(ir_obj.extra_data.items[node.extra]);
            try writer.print("destructure({s})", .{switch (kind) {
                .as => "as",
                .array => "array",
                .object => "object",
                .alt_bind => "alt_bind",
            }});
        },
        .as_bind => try writer.writeAll("as_bind"),
        .path_begin => try writer.writeAll("path_begin"),
        .path_end => try writer.writeAll("path_end"),

        // ── Cat-15 control-flow ops ─────────────────────────────────
        .label => {
            const var_id: u32 = ir_obj.extra_data.items[node.extra];
            try writer.print("label(var_id={d})", .{var_id});
        },
        .break_ => {
            const var_id: u32 = ir_obj.extra_data.items[node.extra];
            try writer.print("break(var_id={d})", .{var_id});
        },
        .while_ => try writer.writeAll("while"),
        .until_ => try writer.writeAll("until"),

        // EmitOp namespace: same string-buf encoding as load_field.
        .load_path => {
            const slots = ir_obj.extra_data.items;
            const offset: u32 = slots[node.extra];
            const len: u32 = slots[node.extra + 1];
            const path = ir_obj.string_buf.items[offset .. offset + len];
            try writer.writeAll("load_path(");
            try writeStringLit(writer, path);
            try writer.writeAll(")");
        },
    }
}

/// Recurse into a node's children in IR storage order. The depth-2
/// `children[0..]` slot is used for nodes whose `span_len` is 0; the
/// variable-arity `extra_children[span_start..]` slice is used
/// otherwise. Leaves with no children are no-ops.
fn dumpIRChildren(
    ir_obj: *const IR,
    node: Node,
    depth: usize,
    tracker: *NamespaceTracker,
    writer: anytype,
) @TypeOf(writer).Error!void {
    // Leaf ops with no children — bail out without touching `children` or
    // `span_*` slots which are 0/uninitialized for true leaves. `not` is
    // a leaf in the IR even though emit treats it as a unary op (it
    // operates on the implicit current input — see `lower.zig:1539`).
    switch (node.op) {
        .load_const, .load_var, .identity, .load_field, .load_index, .slice, .iterate, .recurse, .not, .load_path, .path_end, .break_ => return,
        else => {},
    }
    if (node.span_len > 0) {
        const span_end = node.span_start + node.span_len;
        for (ir_obj.extra_children.items[node.span_start..span_end]) |child_idx| {
            try dumpIRNode(ir_obj, child_idx, depth, tracker, writer);
        }
        return;
    }
    // Fixed-arity slot: 1 or 2 children depending on op. `update_assign`
    // 's fast-path shape stores `children[0] == 0` as a "no-LHS"
    // sentinel — the only real child is `children[1]`. The discriminator
    // is the `UpdateOpKind` in `extra_data[node.extra]`. Mirrors the
    // same special case in `fuse.zig:childArity`.
    const arity: struct { u8, u8 } = switch (node.op) {
        // Binary
        .pipe, .comma, .arith, .cmp, .logical, .alt, .while_, .until_, .computed_index => .{ 0, 2 },
        // Unary
        .try_, .neg, .path_begin, .label => .{ 0, 1 },
        .update_assign => blk: {
            const kind: UpdateOpKind = @enumFromInt(ir_obj.extra_data.items[node.extra]);
            break :blk if (kind == .general) .{ 0, 2 } else .{ 1, 2 };
        },
        // Composite ops should always use span; if span_len==0 here it's
        // a malformed IR — render with arity 0 to avoid touching empty
        // children slots.
        else => .{ 0, 0 },
    };
    var i: u8 = arity[0];
    while (i < arity[1]) : (i += 1) {
        try dumpIRNode(ir_obj, node.children[i], depth, tracker, writer);
    }
}

/// Render a node's source span as `@<start>..<end>`. The `dump()`
/// (AST-walking) sibling reaches for the AST's `Span`; the IR-walking
/// dumper reads `(src_start, src_len)` directly from the node.
fn writeIRSpan(writer: anytype, node: Node) !void {
    try writer.print(" @{d}..{d}", .{ node.src_start, node.src_start + node.src_len });
}
