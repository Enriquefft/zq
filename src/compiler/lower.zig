//! AST → IR lowering — Phase 2R / R3.
//!
//! Categories landed: 1 (literals, identity, recurse, unary), 2
//! (field/index/iterate/slice + postfix `?`, including Suffix chains),
//! and 7 (object/array constructors, string interpolation, @format
//! application). AST shapes outside these categories return
//! `error.NewCompilerNotImplemented` (caught by the harness as
//! SKIP-NotImplemented at vm-equiv time; the dispatcher falls back
//! to legacy at runtime).
//!
//! Plan §3 R3 step 6 enumerates the operator categories; plan §1.3
//! freezes the IR variable-arity contract; spec
//! `research/compiler-ir-format.md` pins the text-dump shape that
//! snapshot tests diff against (§10 examples are the contract).
//!
//! Lowering is a recursive descent on the typed AST root; no virtual
//! dispatch, switch on `Kind` per plan §1.3 row 4. Children are
//! captured as IR-array indices (u32) before parent emission so the
//! parent's `children[0..1]` (or `extra_children` span) carries an
//! immutable index — plan §1.3 row 3.

const std = @import("std");
const ast = @import("ast");
const err_mod = @import("error");
const ir = @import("ir.zig");

const Node = ast.Node;
const Span = ast.Span;

/// Options consumed by lowering. Currently only the strict-mode flag and
/// the external-var declaration slice. Exposed as a concrete struct (not
/// `anytype`) so callers can construct it with `.{}` defaults.
pub const LowerOpts = struct {
    /// `query.Opts.allow_null_propagation` — relevant for category 2+.
    /// Category 1 ignores it; kept for forward compatibility with the
    /// per-category port path.
    allow_null_propagation: bool = false,
    /// External variables pre-declared by the caller. Empty for
    /// non-LSP usage; category 1 does not touch this slice.
    external_vars: []const struct { name: []const u8 } = &.{},
};

/// Errors surfaced by lowering. `OutOfMemory` propagates from arena
/// allocs; `NewCompilerNotImplemented` is the SKIP marker for AST shapes
/// that later categories own. `CompileError` encodes user-facing
/// diagnostics (kind, offset, len) without an unstructured zig error.
pub const LowerError = error{
    OutOfMemory,
    NewCompilerNotImplemented,
    /// Surfaces a structured compile diagnostic via `Lowerer.diag`.
    /// Inspect the `Lowerer.compile_err` field on the catch site.
    LowerDiagnostic,
};

/// Recursive-descent lowering context. Owns nothing — the IR's arena
/// owns every node, child span, extra-data scalar, and string-buf byte.
pub const Lowerer = struct {
    arena: *std.heap.ArenaAllocator,
    /// Original filter source. Used by category 1 to re-scan string
    /// literal source bytes for invalid JSON escapes (the AST parser
    /// is lenient on unknown escapes for LSP tolerance, but the
    /// VM-semantics contract requires rejection — see `validateJsonEscapes`).
    src: []const u8,
    out: ir.IR,
    opts: LowerOpts,
    /// Diagnostic emitted alongside `error.LowerDiagnostic`. The harness
    /// reads this to populate `CompileResult.err` for parity with the
    /// legacy compiler's error shape (kind, offset, len).
    compile_err: err_mod.CompileError = .{ .kind = .query_syntax_error, .offset = 0, .len = 0 },

    /// Append a node and return its index. Plan §1.3 row 3 — children
    /// are u32 indices, never pointers.
    fn pushNode(self: *Lowerer, node: ir.Node) error{OutOfMemory}!u32 {
        const idx: u32 = @intCast(self.out.nodes.items.len);
        try self.out.nodes.append(self.arena.allocator(), node);
        return idx;
    }

    /// Intern a UTF-8 string into the per-IR `string_buf`, returning the
    /// `(offset, len)` pair encoded into two consecutive `extra_data`
    /// slots. Spec §6 row "String-buf id" — the dumper resolves the pair
    /// back to the literal at print time.
    fn internString(self: *Lowerer, s: []const u8) error{OutOfMemory}!u32 {
        const alloc = self.arena.allocator();
        const offset: u32 = @intCast(self.out.string_buf.items.len);
        try self.out.string_buf.appendSlice(alloc, s);

        const extra_idx: u32 = @intCast(self.out.extra_data.items.len);
        try self.out.extra_data.append(alloc, offset);
        try self.out.extra_data.append(alloc, @intCast(s.len));
        return extra_idx;
    }

    fn span(node: *const Node) struct { start: u32, len: u32 } {
        const s = node.span;
        return .{ .start = s.start, .len = if (s.end >= s.start) s.end - s.start else 0 };
    }
};

// Public entry: callers construct a `Lowerer` and invoke `lowerNode`
// directly. Wrapping in a `fn lower()` adds nothing over the explicit
// init pattern and would force every caller (including snapshot
// tests) into a stack-allocated copy of the result. Stay explicit.

/// Lower one AST node and return the IR-array index of its root.
/// Children are lowered first; the parent is emitted last so its
/// `children[0..1]` (or extra-children span) references already-emitted
/// indices. Plan §1.3 row 3.
pub fn lowerNode(ctx: *Lowerer, node: *const Node) LowerError!u32 {
    const sp = Lowerer.span(node);

    switch (node.kind) {
        // ── Literals (category 1) ─────────────────────────────────
        .literal => |lit| {
            const alloc = ctx.arena.allocator();
            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            switch (lit) {
                .null_val => {
                    try ctx.out.extra_data.append(alloc, @intFromEnum(ir.LiteralKind.null_val));
                },
                .bool_val => |b| {
                    const k: ir.LiteralKind = if (b) .true_val else .false_val;
                    try ctx.out.extra_data.append(alloc, @intFromEnum(k));
                },
                .int => |n| {
                    try ctx.out.extra_data.append(alloc, @intFromEnum(ir.LiteralKind.int));
                    const u: u64 = @bitCast(n);
                    try ctx.out.extra_data.append(alloc, @truncate(u));
                    try ctx.out.extra_data.append(alloc, @truncate(u >> 32));
                },
                .float => |f| {
                    try ctx.out.extra_data.append(alloc, @intFromEnum(ir.LiteralKind.float));
                    const u: u64 = @bitCast(f);
                    try ctx.out.extra_data.append(alloc, @truncate(u));
                    try ctx.out.extra_data.append(alloc, @truncate(u >> 32));
                },
                .string => |s| {
                    // Re-scan the source bytes for invalid JSON escapes.
                    // The AST parser is lenient on unknown escapes for
                    // LSP tolerance, but legacy rejects them at compile
                    // time — VM-semantics contract requires the same
                    // (plan §1.2 row 3 — same compile-error kind on
                    // rejected queries).
                    if (sp.start < sp.start + sp.len and sp.start + sp.len <= ctx.src.len) {
                        const span_bytes = ctx.src[sp.start .. sp.start + sp.len];
                        // Strip the surrounding double-quotes; the
                        // tokenizer kept them in the span. Leading and
                        // trailing `"` are guaranteed by the lexer.
                        if (span_bytes.len >= 2 and span_bytes[0] == '"' and span_bytes[span_bytes.len - 1] == '"') {
                            const inner = span_bytes[1 .. span_bytes.len - 1];
                            if (!validateJsonEscapes(inner)) {
                                ctx.compile_err = .{
                                    .kind = .query_syntax_error,
                                    .offset = sp.start,
                                    .len = sp.len,
                                };
                                return error.LowerDiagnostic;
                            }
                        }
                    }
                    try ctx.out.extra_data.append(alloc, @intFromEnum(ir.LiteralKind.string));
                    const offset: u32 = @intCast(ctx.out.string_buf.items.len);
                    try ctx.out.string_buf.appendSlice(alloc, s);
                    try ctx.out.extra_data.append(alloc, offset);
                    try ctx.out.extra_data.append(alloc, @intCast(s.len));
                },
            }
            return ctx.pushNode(.{
                .op = .load_const,
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Identity (category 1) ─────────────────────────────────
        .identity => return ctx.pushNode(.{
            .op = .identity,
            .src_start = sp.start,
            .src_len = sp.len,
        }),

        // ── Recursive descent `..` (category 1) ───────────────────
        .recurse => return ctx.pushNode(.{
            .op = .recurse,
            .src_start = sp.start,
            .src_len = sp.len,
        }),

        // ── Unary negation `-x` (category 1) ──────────────────────
        .unary_neg => |un| {
            const child = try lowerNode(ctx, un.operand);
            return ctx.pushNode(.{
                .op = .neg,
                .children = .{ child, 0 },
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Static-key field access `.foo` / `.["foo"]` (category 2) ─
        // Bare-identifier zero-arg builtins (e.g. `utf8bytelength`,
        // `mktime`) reach the AST as `field_access` because the AST
        // parser uses a narrower zero-arg-builtin list than the legacy
        // compiler. A leading `.` in the source span is the structural
        // marker that this is a true field access; absent that, defer
        // to legacy (cat-10 owns the wider builtin alphabet).
        .field_access => |fa| {
            const is_dot_field = sp.start < ctx.src.len and ctx.src[sp.start] == '.';
            if (!is_dot_field) return error.NewCompilerNotImplemented;
            const extra_idx = try ctx.internString(fa.name);
            return ctx.pushNode(.{
                .op = .load_field,
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Static-int array index `.[N]` (category 2) ──────────────
        .index_access => |ia| {
            const alloc = ctx.arena.allocator();
            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            const u: u64 = @bitCast(ia.index);
            try ctx.out.extra_data.append(alloc, @truncate(u));
            try ctx.out.extra_data.append(alloc, @truncate(u >> 32));
            return ctx.pushNode(.{
                .op = .load_index,
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Iterate `.[]` (category 2) ──────────────────────────────
        .iterate => return ctx.pushNode(.{
            .op = .iterate,
            .src_start = sp.start,
            .src_len = sp.len,
        }),

        // ── Slice `.[from:to]` (category 2) ─────────────────────────
        .slice => |sl| {
            const alloc = ctx.arena.allocator();
            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            // Pack the four SliceArgs fields into two u32 slots: slot 0
            // packs `from` (i32 low) | `to` (i32 high); slot 1 packs the
            // two has_* booleans into the low two bits. Mirrors the
            // legacy `types.SliceArgs` ABI without re-importing the
            // shared types module across the compiler boundary.
            const from_u: u32 = @bitCast(sl.from);
            const to_u: u32 = @bitCast(sl.to);
            try ctx.out.extra_data.append(alloc, from_u);
            try ctx.out.extra_data.append(alloc, to_u);
            const flags: u32 = (@as(u32, @intFromBool(sl.has_from))) | (@as(u32, @intFromBool(sl.has_to)) << 1);
            try ctx.out.extra_data.append(alloc, flags);
            return ctx.pushNode(.{
                .op = .slice,
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Postfix optional `expr?` (category 2) ───────────────────
        // Wraps the inner expression in `try_`, matching the legacy
        // `fork_try`/`pop_try` segment-wrap. Cat-2 owns the postfix
        // form; the explicit `try expr catch handler` keyword is cat-6.
        .optional => |un| {
            const child = try lowerNode(ctx, un.operand);
            return ctx.pushNode(.{
                .op = .try_,
                .children = .{ child, 0 },
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Pipe `lhs | rhs` (category 3) ───────────────────────────
        .pipe => |bp| {
            const left = try lowerNode(ctx, bp.left);
            const right = try lowerNode(ctx, bp.right);
            return ctx.pushNode(.{
                .op = .pipe,
                .children = .{ left, right },
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Comma `lhs , rhs` (category 3) ──────────────────────────
        .comma => |bc| {
            const left = try lowerNode(ctx, bc.left);
            const right = try lowerNode(ctx, bc.right);
            return ctx.pushNode(.{
                .op = .comma,
                .children = .{ left, right },
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Suffix chain (category 2) ───────────────────────────────
        // Each non-`optional` SuffixOp produces a new pipe layer
        // wrapping (accumulated_chain, new_op_node). Each `optional`
        // op wraps the rightmost chain element in `try_` — matching
        // the legacy segment-wrap semantic where `?` only covers the
        // segment from the most recent pipe onwards.
        .suffix => |sf| {
            var cur = try lowerNode(ctx, sf.base);
            for (sf.ops) |op| {
                switch (op) {
                    .optional => {
                        // Wrap the current rightmost element. If `cur` is
                        // a `pipe`, replace its right child with `try_(R)`;
                        // otherwise wrap `cur` itself. Mirrors the
                        // legacy `?`-only-wraps-the-last-segment rule.
                        cur = try wrapRightmostInTry(ctx, cur, sf.base.span);
                    },
                    .field, .bracket_str => |name| {
                        const op_idx = try lowerSuffixField(ctx, name, sf.base.span);
                        cur = try lowerSuffixPipe(ctx, cur, op_idx, sf.base.span);
                    },
                    .index => |i| {
                        const op_idx = try lowerSuffixIndex(ctx, i, sf.base.span);
                        cur = try lowerSuffixPipe(ctx, cur, op_idx, sf.base.span);
                    },
                    .iterate => {
                        const op_idx = try lowerSuffixIterate(ctx, sf.base.span);
                        cur = try lowerSuffixPipe(ctx, cur, op_idx, sf.base.span);
                    },
                    .slice => |sl| {
                        const op_idx = try lowerSuffixSlice(ctx, sl, sf.base.span);
                        cur = try lowerSuffixPipe(ctx, cur, op_idx, sf.base.span);
                    },
                    .bracket_expr => return error.NewCompilerNotImplemented,
                }
            }
            return cur;
        },

        // ── Arithmetic `+ - * / %` (category 5) ────────────────────
        // Lower lhs and rhs first; parent records `(left, right)` index
        // edges and stashes the op-kind discriminant in `extra_data`.
        // Matches `ast.Node.Arithmetic.ArithOp` enum order one-for-one
        // (`ir.ArithKind` is the single source of truth).
        .arithmetic => |bn| {
            const left = try lowerNode(ctx, bn.left);
            const right = try lowerNode(ctx, bn.right);
            const alloc = ctx.arena.allocator();
            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            const kind: ir.ArithKind = switch (bn.op) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                .mod => .mod,
            };
            try ctx.out.extra_data.append(alloc, @intFromEnum(kind));
            return ctx.pushNode(.{
                .op = .arith,
                .children = .{ left, right },
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Comparison `== != < <= > >=` (category 5) ─────────────
        .comparison => |bn| {
            const left = try lowerNode(ctx, bn.left);
            const right = try lowerNode(ctx, bn.right);
            const alloc = ctx.arena.allocator();
            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            const kind: ir.CmpKind = switch (bn.op) {
                .eq => .eq,
                .ne => .ne,
                .lt => .lt,
                .le => .le,
                .gt => .gt,
                .ge => .ge,
            };
            try ctx.out.extra_data.append(alloc, @intFromEnum(kind));
            return ctx.pushNode(.{
                .op = .cmp,
                .children = .{ left, right },
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Logical `and` / `or` (category 5) ──────────────────────
        // Single `logical` op; `extra_data[extra]` holds the
        // `LogicalKind` discriminant (and/or). Legacy emits the runtime
        // `and_op`/`or_op` opcodes which evaluate both sides eagerly
        // — jq does NOT short-circuit at the bytecode level
        // (`src/query/src/vm.zig:6575-6589`). The new compiler matches
        // that emission shape so VM-equivalence holds byte-for-byte.
        .and_expr => |bn| {
            const left = try lowerNode(ctx, bn.left);
            const right = try lowerNode(ctx, bn.right);
            const alloc = ctx.arena.allocator();
            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            try ctx.out.extra_data.append(alloc, @intFromEnum(ir.LogicalKind.and_));
            return ctx.pushNode(.{
                .op = .logical,
                .children = .{ left, right },
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },
        .or_expr => |bn| {
            const left = try lowerNode(ctx, bn.left);
            const right = try lowerNode(ctx, bn.right);
            const alloc = ctx.arena.allocator();
            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            try ctx.out.extra_data.append(alloc, @intFromEnum(ir.LogicalKind.or_));
            return ctx.pushNode(.{
                .op = .logical,
                .children = .{ left, right },
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Alternative `//` (category 5) ──────────────────────────
        // No `extra` — `alt` is shape-only. Emit lowers it to the
        // `fork_alt`/truthiness/backtrack scaffold legacy uses
        // (`src/query/src/compiler.zig:2453`).
        .alternative => |bn| {
            const left = try lowerNode(ctx, bn.left);
            const right = try lowerNode(ctx, bn.right);
            return ctx.pushNode(.{
                .op = .alt,
                .children = .{ left, right },
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Builtin call: `not` / `type` (category 1 zero-arg) ────
        // Most builtins are category 10, but `not` and `type` are the
        // only zero-arg builtins category 1 owns (per orchestrator
        // brief). Other zero-arg builtins (`length`, `keys`, ...) are
        // category 10's responsibility. We accept here only the names
        // the brief lists.
        .builtin_call => |bc| {
            if (bc.args.len == 0) {
                // `not` is a logical op the brief explicitly assigns
                // to category 1 (unary). The IR encodes it as the
                // dedicated `not` op so the bytecode stays a single
                // `not` instruction (no `call_builtin` overhead).
                if (std.mem.eql(u8, bc.name, "not")) {
                    // `not` consumes its current input — the parser
                    // exposes it as a zero-arg builtin call (no
                    // operand AST). The IR mirrors that: a SemOp
                    // `not` with no children. Emit threads the
                    // `current` value through the bytecode `not`
                    // op directly.
                    return ctx.pushNode(.{
                        .op = .not,
                        .src_start = sp.start,
                        .src_len = sp.len,
                    });
                }

                // `type` and other zero-arg builtins fall through to
                // a generic `call_builtin` lowering that category 10
                // will own. For now, emit `call_builtin` only for the
                // category-1-relevant `type` — other builtins surface
                // as NotImplemented so vm-equiv reports SKIP and the
                // category-10 implementer fills them in.
                if (std.mem.eql(u8, bc.name, "type")) {
                    // Stash the builtin name in `string_buf` and
                    // record `(offset, len)` in `extra_data`. The
                    // encoding matches plan §1.3 row 5: a single
                    // `extra` index pointing at the name pair.
                    const extra_idx = try ctx.internString(bc.name);
                    return ctx.pushNode(.{
                        .op = .call_builtin,
                        .extra = extra_idx,
                        .src_start = sp.start,
                        .src_len = sp.len,
                    });
                }
            }
            return error.NewCompilerNotImplemented;
        },

        // ── Object constructor `{...}` (category 7) ──────────────────
        // Each AST `ObjectField` is lowered to a (key_idx, value_idx)
        // pair and recorded back-to-back in the variadic span. Key
        // shapes:
        //   `.ident` / `.string` → synthesized `load_const(string)` IR
        //                          node (legacy `push_string`).
        //   `.expr`              → lowered expression node (legacy
        //                          `parseLogical` result).
        // Shorthand `{a}` → ident key + value=`load_field("a")`. The
        // dynamic-shorthand `{(expr)}` (no colon) shape — legacy's
        // `save_input/load_computed` dance — is intentionally deferred:
        // the AST parser preserves the same `expr` pointer in both key
        // and value, which would re-execute the expression. Defer to
        // legacy via NotImplemented (per parser comment in
        // `src/ast/parser.zig:846-851`).
        .object_construct => |oc| {
            const alloc = ctx.arena.allocator();
            // Collect (key, value) pair indices in a local buffer first;
            // any nested obj/arr/interp lowering also writes to
            // `extra_children`, so bulk-appending at the end keeps our
            // `span_start..span_start+span_len` slice contiguous and
            // points to OUR pairs only.
            var pairs: std.ArrayListUnmanaged(u32) = .{};
            defer pairs.deinit(alloc);
            for (oc.fields) |fld| {
                const key_idx = try lowerObjectKey(ctx, &fld);
                const value_idx = try lowerObjectFieldValue(ctx, &fld);
                try pairs.append(alloc, key_idx);
                try pairs.append(alloc, value_idx);
            }
            const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
            try ctx.out.extra_children.appendSlice(alloc, pairs.items);
            const span_len: u32 = @intCast(pairs.items.len);
            return ctx.pushNode(.{
                .op = .obj_ctor,
                .span_start = span_start,
                .span_len = span_len,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Array constructor `[...]` (category 7) ───────────────────
        // The inner expression is a single AST node; comma chains are
        // flattened into element children so each element becomes one
        // child of `arr_ctor`. Empty `[]` has zero children. Generators
        // (`[range(3)]`, `[.[]]`) appear as a single child whose own
        // backtracking semantics drive the `yield_output` ladder.
        .array_construct => |ac| {
            const alloc = ctx.arena.allocator();
            // Collect element indices in a local buffer first — nested
            // obj/arr/interp lowering writes to `extra_children`, so a
            // direct append-as-we-go would interleave their data with
            // ours and break our span. Bulk-append at the end.
            var elems: std.ArrayListUnmanaged(u32) = .{};
            defer elems.deinit(alloc);
            if (ac.expr) |inner| {
                // Flatten the comma chain. Comma is left-associative in
                // the AST (`comma(comma(a, b), c)`), so we recursively
                // collect every leaf in source order.
                try collectArrayElems(ctx, inner, &elems);
            }
            const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
            try ctx.out.extra_children.appendSlice(alloc, elems.items);
            const span_len: u32 = @intCast(elems.items.len);
            return ctx.pushNode(.{
                .op = .arr_ctor,
                .span_start = span_start,
                .span_len = span_len,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── String interpolation `"... \(expr) ..."` (category 7) ────
        // Each `StringPart` becomes a child node:
        //   `.literal` → synthesized `load_const(string)` IR node.
        //   `.expr`    → lowered expression node.
        // Emit ladders the children into the legacy `push_string` /
        // `save_input` / tostring / `add` / `restore_input` pattern.
        // `format` is the same shape with a non-zero format-spec id.
        .string_interp => |si| {
            const alloc = ctx.arena.allocator();
            // Interp parts may include nested obj/arr constructors that
            // also write `extra_children`; collect into a local buffer
            // and bulk-append so our span stays contiguous.
            var parts: std.ArrayListUnmanaged(u32) = .{};
            defer parts.deinit(alloc);
            try lowerStringParts(ctx, si.parts, &parts);
            const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
            try ctx.out.extra_children.appendSlice(alloc, parts.items);
            const span_len: u32 = @intCast(parts.items.len);
            return ctx.pushNode(.{
                .op = .interp,
                .span_start = span_start,
                .span_len = span_len,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Format application `@fmt "..."` (category 7) ─────────────
        // The `format` field of the AST node is the format name with a
        // leading `@` (e.g. `"@base64"`); lowering interns the name in
        // `string_buf` and stamps `(offset, len)` into a fresh
        // `extra_data` entry. Emit decodes the name back to a
        // `BuiltinId` (matching legacy `formatBuiltinId`).
        //
        // Special case: a single literal part with NO interpolations
        // emits as a bare `push_string` (legacy
        // `src/query/src/compiler.zig:6219-6225`). The IR records this
        // as `format(span_len=1, child=load_const(...))` and emit
        // detects the shape.
        .format_string => |fs| {
            const alloc = ctx.arena.allocator();
            var parts: std.ArrayListUnmanaged(u32) = .{};
            defer parts.deinit(alloc);
            try lowerStringParts(ctx, fs.parts, &parts);
            const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
            try ctx.out.extra_children.appendSlice(alloc, parts.items);
            const span_len: u32 = @intCast(parts.items.len);
            const extra_idx = try ctx.internString(fs.format);
            return ctx.pushNode(.{
                .op = .format,
                .span_start = span_start,
                .span_len = span_len,
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Update assignment, fast path (cat-8) ────────────────────
        // `.path1.path2[N] OP= rhs`. The AST guarantees `path` is a
        // chain of `key`/`index` steps only — `peekIsUpdateAssign`
        // bails to `assign_general` the moment it sees a non-static
        // step (`.[]`, `.[ident]`, `.[expr]`). Single SemOp
        // (`update_assign`) per plan §1.3 row 5; operator alphabet
        // shared with `assign_general` via `UpdateOpKind`.
        .update_assign => |ua| {
            const alloc = ctx.arena.allocator();
            const rhs_idx = try lowerNode(ctx, ua.rhs);

            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            const kind = updateOpKindFromAssignOp(ua.op);
            try ctx.out.extra_data.append(alloc, @intFromEnum(kind));
            // Path steps follow in extra_data. Layout per step (3 slots):
            //   [0] = step kind (0 = key, 1 = index)
            //   [1] = payload_lo (string offset for key, lo32 of i64 for index)
            //   [2] = payload_hi (string len for key, hi32 of i64 for index)
            // Iterate steps cannot reach this fast path (parser
            // invariant — see `peekIsUpdateAssign` at parser.zig:1344).
            try ctx.out.extra_data.append(alloc, @intCast(ua.path.len));
            for (ua.path) |step| {
                switch (step) {
                    .key => |name| {
                        const offset: u32 = @intCast(ctx.out.string_buf.items.len);
                        try ctx.out.string_buf.appendSlice(alloc, name);
                        try ctx.out.extra_data.append(alloc, 0); // kind = key
                        try ctx.out.extra_data.append(alloc, offset);
                        try ctx.out.extra_data.append(alloc, @intCast(name.len));
                    },
                    .index => |i| {
                        const u: u64 = @bitCast(i);
                        try ctx.out.extra_data.append(alloc, 1); // kind = index
                        try ctx.out.extra_data.append(alloc, @truncate(u));
                        try ctx.out.extra_data.append(alloc, @truncate(u >> 32));
                    },
                    .iterate => unreachable, // parser guarantees this
                }
            }

            return ctx.pushNode(.{
                .op = .update_assign,
                .children = .{ 0, rhs_idx },
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Update assignment, general LHS (cat-8) ──────────────────
        // `LHS OP= rhs` where the LHS is any path expression: paren,
        // comma, iteration, function call. Lowers LHS as a regular
        // expression — the emitter will wrap it in `path_begin` /
        // `path_end` to harvest the path set. Operator alphabet shared
        // with `update_assign` via `UpdateOpKind` (`general` form +
        // trailing operator slot).
        .assign_general => |ag| {
            const alloc = ctx.arena.allocator();
            const lhs_idx = try lowerNode(ctx, ag.lhs);
            const rhs_idx = try lowerNode(ctx, ag.rhs);

            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            try ctx.out.extra_data.append(alloc, @intFromEnum(ir.UpdateOpKind.general));
            const inner_kind = updateOpKindFromAssignOp(ag.op);
            try ctx.out.extra_data.append(alloc, @intFromEnum(inner_kind));

            return ctx.pushNode(.{
                .op = .update_assign,
                .children = .{ lhs_idx, rhs_idx },
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Other AST kinds: defer to later categories ─────────────
        else => return error.NewCompilerNotImplemented,
    }
}

/// Map AST `AssignOp` → `UpdateOpKind` (excluding `general`, which is a
/// form marker, not an operator). Single source of truth shared by both
/// fast-path and general lowering; `general` form callers pass the inner
/// op through this same helper.
fn updateOpKindFromAssignOp(op: ast.Node.UpdateAssign.AssignOp) ir.UpdateOpKind {
    return switch (op) {
        .eq => .set,
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        .percent_eq => .mod,
        .double_slash_eq => .alt,
        .pipe_eq => .update,
    };
}

/// Append a `load_field` node for a SuffixOp `.field` / `.bracket_str`.
fn lowerSuffixField(ctx: *Lowerer, name: []const u8, span: ast.Span) error{OutOfMemory}!u32 {
    const extra_idx = try ctx.internString(name);
    const sp = .{ .start = span.start, .len = if (span.end >= span.start) span.end - span.start else 0 };
    return ctx.pushNode(.{
        .op = .load_field,
        .extra = extra_idx,
        .src_start = sp.start,
        .src_len = sp.len,
    });
}

/// Append a `load_index` node for a SuffixOp `.index`.
fn lowerSuffixIndex(ctx: *Lowerer, i: i64, span: ast.Span) error{OutOfMemory}!u32 {
    const alloc = ctx.arena.allocator();
    const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
    const u: u64 = @bitCast(i);
    try ctx.out.extra_data.append(alloc, @truncate(u));
    try ctx.out.extra_data.append(alloc, @truncate(u >> 32));
    const sp = .{ .start = span.start, .len = if (span.end >= span.start) span.end - span.start else 0 };
    return ctx.pushNode(.{
        .op = .load_index,
        .extra = extra_idx,
        .src_start = sp.start,
        .src_len = sp.len,
    });
}

/// Append an `iterate` node for a SuffixOp `.iterate`.
fn lowerSuffixIterate(ctx: *Lowerer, span: ast.Span) error{OutOfMemory}!u32 {
    const sp = .{ .start = span.start, .len = if (span.end >= span.start) span.end - span.start else 0 };
    return ctx.pushNode(.{
        .op = .iterate,
        .src_start = sp.start,
        .src_len = sp.len,
    });
}

/// Append a `slice` node for a SuffixOp `.slice`.
fn lowerSuffixSlice(ctx: *Lowerer, sl: ast.Node.Slice, span: ast.Span) error{OutOfMemory}!u32 {
    const alloc = ctx.arena.allocator();
    const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
    const from_u: u32 = @bitCast(sl.from);
    const to_u: u32 = @bitCast(sl.to);
    try ctx.out.extra_data.append(alloc, from_u);
    try ctx.out.extra_data.append(alloc, to_u);
    const flags: u32 = (@as(u32, @intFromBool(sl.has_from))) | (@as(u32, @intFromBool(sl.has_to)) << 1);
    try ctx.out.extra_data.append(alloc, flags);
    const sp = .{ .start = span.start, .len = if (span.end >= span.start) span.end - span.start else 0 };
    return ctx.pushNode(.{
        .op = .slice,
        .extra = extra_idx,
        .src_start = sp.start,
        .src_len = sp.len,
    });
}

/// Append a `pipe` node connecting `left` and `right`. The span
/// covers the full suffix-chain origin so source-position parity with
/// the legacy `pipe` instruction's `last_tok_offset` stays trivial.
fn lowerSuffixPipe(ctx: *Lowerer, left: u32, right: u32, span: ast.Span) error{OutOfMemory}!u32 {
    const sp = .{ .start = span.start, .len = if (span.end >= span.start) span.end - span.start else 0 };
    return ctx.pushNode(.{
        .op = .pipe,
        .children = .{ left, right },
        .src_start = sp.start,
        .src_len = sp.len,
    });
}

/// Wrap the rightmost element of `cur` in `try_`. If `cur` is a
/// `pipe(L, R)` we wrap `R` only and return a fresh pipe over `(L,
/// try_(R))`; otherwise we wrap `cur` itself. Mirrors the legacy
/// `?`-segment-wrap rule where `?` only wraps from `segment_start`
/// onwards (the segment is the most-recent pipe-right side).
fn wrapRightmostInTry(ctx: *Lowerer, cur: u32, span: ast.Span) error{OutOfMemory}!u32 {
    const sp = .{ .start = span.start, .len = if (span.end >= span.start) span.end - span.start else 0 };
    const node = ctx.out.nodes.items[cur];
    if (node.op == .pipe) {
        const left = node.children[0];
        const right = node.children[1];
        const wrapped = try ctx.pushNode(.{
            .op = .try_,
            .children = .{ right, 0 },
            .src_start = sp.start,
            .src_len = sp.len,
        });
        return ctx.pushNode(.{
            .op = .pipe,
            .children = .{ left, wrapped },
            .src_start = sp.start,
            .src_len = sp.len,
        });
    }
    return ctx.pushNode(.{
        .op = .try_,
        .children = .{ cur, 0 },
        .src_start = sp.start,
        .src_len = sp.len,
    });
}

/// Lower an `ObjectField.value` honoring the parser's shorthand
/// synthesis. For `{a}` / `{a, b}` / `{"a"}` shorthand the parser emits
/// a `field_access` value whose span starts at the key (no leading
/// `.` in the source bytes). The general `field_access` arm in
/// `lowerNode` rejects that shape (the leading-`.` guard filters
/// zero-arg builtins like `utf8bytelength`), so we synthesize
/// `load_field` directly here. Detection: synthesized shorthand
/// `field_access` has `value.span.start == fld.span.start`; a real
/// `key: value` field has the value span starting after the colon.
fn lowerObjectFieldValue(ctx: *Lowerer, fld: *const ast.Node.ObjectField) LowerError!u32 {
    if (fld.value.kind == .field_access and fld.value.span.start == fld.span.start) {
        const fa = fld.value.kind.field_access;
        const vsp = fld.value.span;
        const vsp_len: u32 = if (vsp.end >= vsp.start) vsp.end - vsp.start else 0;
        const extra_idx = try ctx.internString(fa.name);
        return ctx.pushNode(.{
            .op = .load_field,
            .extra = extra_idx,
            .src_start = vsp.start,
            .src_len = vsp_len,
        });
    }
    return lowerNode(ctx, fld.value);
}

/// Lower an `ObjectField.key` into a fresh IR node. Ident and string
/// keys synthesize a `load_const(string)` literal; expr keys recurse
/// through `lowerNode`. Mirrors legacy's `parseObjectKey`
/// (`src/query/src/compiler.zig:6788`): ident keys take the raw token
/// bytes; string keys decode JSON escapes; `(expr)` keys evaluate the
/// expression and leave the result on the value stack.
fn lowerObjectKey(ctx: *Lowerer, fld: *const ast.Node.ObjectField) LowerError!u32 {
    const alloc = ctx.arena.allocator();
    const sp = .{ .start = fld.span.start, .len = if (fld.span.end >= fld.span.start) fld.span.end - fld.span.start else 0 };
    switch (fld.key) {
        .ident => |name| {
            // Ident keys are the raw token bytes — no escape decoding
            // (legacy `internStr`, `src/query/src/compiler.zig:6823`).
            return synthLoadConstString(ctx, name, sp.start, sp.len);
        },
        .string => |raw_content| {
            // The AST parser stripped the surrounding quotes but did
            // NOT decode JSON escapes for string keys (parser line 921;
            // contrast `decodeString` for value-position string lits).
            // Match legacy `internDecodedStr` by decoding here.
            const decoded = try decodeJsonString(alloc, raw_content);
            return synthLoadConstString(ctx, decoded, sp.start, sp.len);
        },
        .expr => |expr| return lowerNode(ctx, expr),
    }
}

/// Synthesize a `load_const(string)` IR node owning `bytes` in the
/// per-IR `string_buf`. Used by object-key lowering and interp/format
/// part lowering so emit can dispatch on `node.op == .load_const` to
/// distinguish literal segments from expression segments.
fn synthLoadConstString(
    ctx: *Lowerer,
    bytes: []const u8,
    src_start: u32,
    src_len: u32,
) error{OutOfMemory}!u32 {
    const alloc = ctx.arena.allocator();
    const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
    try ctx.out.extra_data.append(alloc, @intFromEnum(ir.LiteralKind.string));
    const offset: u32 = @intCast(ctx.out.string_buf.items.len);
    try ctx.out.string_buf.appendSlice(alloc, bytes);
    try ctx.out.extra_data.append(alloc, offset);
    try ctx.out.extra_data.append(alloc, @intCast(bytes.len));
    return ctx.pushNode(.{
        .op = .load_const,
        .extra = extra_idx,
        .src_start = src_start,
        .src_len = src_len,
    });
}

/// Recursive walk of the array-construct inner expression, flattening
/// comma chains into element children. Appends each leaf's IR-node
/// index into `out` (a local buffer the caller bulk-merges into
/// `extra_children` after all elements are lowered — see the array
/// construct arm for why we cannot append directly).
fn collectArrayElems(
    ctx: *Lowerer,
    node: *const ast.Node,
    out: *std.ArrayListUnmanaged(u32),
) LowerError!void {
    if (node.kind == .comma) {
        const c = node.kind.comma;
        try collectArrayElems(ctx, c.left, out);
        try collectArrayElems(ctx, c.right, out);
        return;
    }
    const alloc = ctx.arena.allocator();
    const child_idx = try lowerNode(ctx, node);
    try out.append(alloc, child_idx);
}

/// Lower an `interp` / `format` parts list, appending each lowered
/// child's IR-node index into `out` (a local buffer the caller
/// bulk-merges into `extra_children` after all parts are lowered).
fn lowerStringParts(
    ctx: *Lowerer,
    parts: []const ast.Node.StringPart,
    out: *std.ArrayListUnmanaged(u32),
) LowerError!void {
    const alloc = ctx.arena.allocator();
    for (parts) |part| {
        const child_idx: u32 = switch (part) {
            .literal => |s| try synthLoadConstString(ctx, s, 0, 0),
            .expr => |expr| try lowerNode(ctx, expr),
        };
        try out.append(alloc, child_idx);
    }
}

/// Decode a JSON-style string body (without surrounding quotes) into a
/// fresh arena-allocated buffer. Mirrors `src/ast/parser.zig:1525`'s
/// `decodeString`. Used by object-key lowering — string keys reach the
/// AST without escape decoding (parser inconsistency: value-position
/// string literals decode but key-position string literals do not),
/// and legacy keys decode via `internDecodedStr`. Restoring decode
/// parity here keeps VM equivalence.
fn decodeJsonString(alloc: std.mem.Allocator, raw: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            try buf.append(alloc, raw[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= raw.len) break;
        switch (raw[i]) {
            '\\' => try buf.append(alloc, '\\'),
            '"' => try buf.append(alloc, '"'),
            '/' => try buf.append(alloc, '/'),
            'n' => try buf.append(alloc, '\n'),
            'r' => try buf.append(alloc, '\r'),
            't' => try buf.append(alloc, '\t'),
            'b' => try buf.append(alloc, 0x08),
            'f' => try buf.append(alloc, 0x0C),
            'u' => {
                i += 1;
                if (i + 4 > raw.len) break;
                const hi = std.fmt.parseInt(u21, raw[i..][0..4], 16) catch break;
                i += 4;
                var codepoint: u21 = hi;
                if (hi >= 0xD800 and hi <= 0xDBFF) {
                    if (i + 6 <= raw.len and raw[i] == '\\' and raw[i + 1] == 'u') {
                        const lo = std.fmt.parseInt(u21, raw[i + 2 ..][0..4], 16) catch break;
                        if (lo >= 0xDC00 and lo <= 0xDFFF) {
                            codepoint = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
                            i += 6;
                        }
                    }
                }
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(@intCast(codepoint), &utf8_buf) catch break;
                try buf.appendSlice(alloc, utf8_buf[0..utf8_len]);
                continue;
            },
            else => try buf.append(alloc, raw[i]),
        }
        i += 1;
    }
    return buf.toOwnedSlice(alloc);
}

/// Validate a string-literal body (without surrounding quotes) for the
/// JSON escape set legacy accepts. Returns `false` on the first invalid
/// escape — caller surfaces a compile diagnostic. Mirrors the legacy
/// `internDecodedStr` checks in `src/query/src/compiler.zig:7091`.
///
/// Accepted escapes: `\\`, `\"`, `\/`, `\n`, `\r`, `\t`, `\b`, `\f`,
/// `\uXXXX`, `\(...)` (interpolation — left intact for category 7).
/// Anything else (e.g. `\v`) is invalid per legacy.
fn validateJsonEscapes(body: []const u8) bool {
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '\\') continue;
        i += 1;
        if (i >= body.len) return false;
        switch (body[i]) {
            '\\', '"', '/', 'n', 'r', 't', 'b', 'f' => {},
            '(' => {
                // String interpolation — out of scope for category 1
                // but legacy accepts it as a valid escape. Skip the
                // entire `\(...)` form; balanced-paren counting is
                // unnecessary here since interpolation lowering
                // (category 7) will re-parse with proper nesting.
                // For now, accept the prefix and break — any further
                // invalid escape after it would only matter once
                // category 7 is wired.
                return true;
            },
            'u' => {
                if (i + 4 >= body.len) return false;
                for (body[i + 1 .. i + 5]) |c| {
                    if (!std.ascii.isHex(c)) return false;
                }
                i += 4;
            },
            else => return false,
        }
    }
    return true;
}
