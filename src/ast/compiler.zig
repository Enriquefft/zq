//! AST-walk compile pipeline — Phase 2 (Stage 0 + Stage 1 + Stage 2 + Stage 3 + Stage 4 + Stage 5 + Stage 6 + Stage 7).
//!
//! Goal: walk the `src/ast/parser.zig`-produced AST and emit bytecode byte-for-byte
//! equivalent to the legacy token-driven compiler at `src/query/src/compiler.zig`.
//! This file is the future replacement for that compiler; for now it covers only
//! the scope documented in `research/phase-2-ast-walk-plan.md` §4 Stage 0–7:
//!   - `.literal` (int, float, string, bool, null)
//!   - `.identity` (bare `.`)
//!   - `.recurse` (`..` operator → `call_builtin(recurse)`)
//!   - `.unary_neg` — all operand shapes (literals via Stage 1, non-literals
//!     via Stage 5)
//!   - `.field_access` — `.foo`
//!   - `.index_access` — `.[n]`
//!   - `.iterate` — `.[]`
//!   - `.slice` — `.[a:b]`, `.[:b]`, `.[a:]`, `.[:]`
//!   - `.optional` — `expr?`
//!   - `.suffix` — `.a.b`, `.a[0]`, `.a[]`, `.a?.b`, etc.
//!   - `.pipe` — `a | b`, chained
//!   - `.comma` — `a, b, c`
//!   - `.variable_ref` — `$name` (including `$__loc__` marker object)
//!   - `.as_pattern` — `. as $x | body`, array/object destructuring
//!   - `.destruct_alt` — `. as PAT1 ?// PAT2 | body`
//!   - `.arithmetic` — `+`, `-`, `*`, `/`, `%`
//!   - `.comparison` — `<`, `<=`, `>`, `>=`, `==`, `!=`
//!   - `.and_expr`, `.or_expr` — `A and B`, `A or B`
//!   - `.alternative` — `A // B`, chained
//!   - `.paren` — `(EXPR)` grouping (Stage 6, transparent)
//!   - `.try_catch` — `try BODY [catch HANDLER]` (Stage 6)
//!   - `.if_expr` — `if COND then THEN [elif COND then THEN]* [else ELSE] end` (Stage 6)
//!   - `.builtin_call("path", [EXPR])` / `.func_call("path", [EXPR])` — Stage 6
//!   - `.object_construct` — `{...}` with static / shorthand / computed /
//!     string-interp keys, and `{__loc__}` marker shorthand (Stage 7)
//!   - `.array_construct` — `[...]` with zero or more items (Stage 7)
//!   - `.string_interp` — `"\(expr)..."` (Stage 7)
//!   - `.format_string` — `@base64`, `@csv "literal"`, `@csv "\(.x),\(.y)"` (Stage 7)
//!   - `.builtin_call("@name", [])` — standalone `@base64`/etc. pipe target
//!
//! Every other node kind returns `error.AstCompilerStageIncomplete`. This is NOT
//! a workaround — it is the scaffold boundary, to be removed as later stages
//! (8–13) extend coverage. See the plan doc for the full stage breakdown.
//!
//! Production code is unaffected. The legacy compiler at
//! `src/query/src/compiler.zig` remains the definitional compiler until Stage 13
//! cutover.

const std = @import("std");
const ast = @import("ast");
const types = @import("types");
const err_mod = @import("error");
const regex_mod = @import("regex");
const Instruction = types.Instruction;
const Node = ast.Node;
const ParseResult = ast.ParseResult;

// ── Public surface ────────────────────────────────────────────────────────────

/// Re-export so callers can speak a single result shape regardless of which
/// compiler they invoked. Mirrors `compiler.zig:Compiled` field-for-field.
pub const Compiled = struct {
    instructions: []Instruction,
    function_table: []const types.FunctionDef,
    string_buf: []u8,
    external_var_ids: []u32,
    source_map: []u32,
    regex_pool: regex_mod.RegexPool,
    prefilter: ?void, // Stage 1/2 never populates prefilter; keep field for layout parity.

    pub fn deinit(c: *Compiled, alloc: std.mem.Allocator) void {
        alloc.free(c.instructions);
        alloc.free(c.string_buf);
        alloc.free(c.source_map);
        alloc.free(c.external_var_ids);
        c.regex_pool.deinit();
        _ = c.prefilter;
    }
};

pub const ExternalVarDecl = struct {
    name: []const u8,
};

pub const CompileResult = union(enum) {
    ok: Compiled,
    err: err_mod.CompileError,
};

/// Public scaffold-boundary error. Returned by the walker when it reaches an
/// AST node kind that the current stage does not yet cover. Later stages will
/// remove these one-by-one; when the full dispatch is complete this error
/// disappears from the public surface.
pub const WalkerError = error{AstCompilerStageIncomplete};

/// Compile a filter source via AST walk.
///
/// Signature matches `src/query/src/compiler.zig:compile` plus an optional
/// `filename` parameter (reserved for future diagnostic stages; unused in
/// Stage 0/1/2 but recorded here so the signature is stable).
///
/// Returns:
///   - `.ok` on success.
///   - `.err` when parse fails or when the walker hits a node kind outside
///     the current scope (maps to `error.AstCompilerStageIncomplete` →
///     `query_syntax_error` for CompileResult compatibility; the Zig error
///     is what the harness matches on to distinguish scaffold misses from
///     real compile errors).
pub fn compile(
    alloc: std.mem.Allocator,
    src: []const u8,
    filename: ?[]const u8,
) (error{ OutOfMemory, AstCompilerStageIncomplete })!CompileResult {
    _ = filename;
    return compileWithExternals(alloc, src, &.{});
}

/// Variant that accepts pre-declared external variables — mirrors the legacy
/// compile entry point. External-var declaration is a Stage 4 concern, but the
/// parameter is kept here so that the harness signature lines up without churn
/// when Stage 4 lands.
pub fn compileWithExternals(
    alloc: std.mem.Allocator,
    src: []const u8,
    external_vars: []const ExternalVarDecl,
) (error{ OutOfMemory, AstCompilerStageIncomplete })!CompileResult {
    // Stage 2 does not support external variables; reject rather than silently
    // drop them. Stage 4 lifts this.
    if (external_vars.len > 0) return error.AstCompilerStageIncomplete;

    var parsed = ast.parse(src, alloc);
    defer parsed.deinit();

    if (parsed.hasErrors()) {
        // Stage 0/1/2 error mapping — everything routes to query_syntax_error.
        // Stage 9 (user functions) + Stage 10 (builtins) will widen this.
        const first = parsed.errors[0];
        return .{ .err = .{
            .kind = .query_syntax_error,
            .offset = first.span.start,
            .len = if (first.span.end > first.span.start) first.span.end - first.span.start else 0,
        } };
    }

    var walker: Walker = .{
        .alloc = alloc,
        .src = src,
        .raw = .{},
        .intern = .{},
        .scope_vars = .{},
        .scope_marks = .{},
    };
    defer walker.raw.deinit(alloc);
    defer walker.scope_vars.deinit(alloc);
    defer walker.scope_marks.deinit(alloc);
    var intern_consumed = false;
    defer if (!intern_consumed) walker.intern.deinit(alloc);

    walker.walk(parsed.root) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AstCompilerStageIncomplete => return error.AstCompilerStageIncomplete,
        error.AstCompileError => return .{ .err = walker.compile_err.? },
    };

    // Append implicit yield_output if not already present (mirrors legacy at
    // `compiler.zig:1449-1453`).
    const needs_output = walker.raw.items.len == 0 or
        walker.raw.items[walker.raw.items.len - 1].op != .yield_output;
    if (needs_output) {
        try walker.raw.append(alloc, .{
            .op = .yield_output,
            .operand = .{ .none = {} },
            .src_offset = walker.last_emit_offset,
        });
    }

    const compiled = try fuse(alloc, walker.raw.items, &walker.intern);
    intern_consumed = true; // fuse took ownership via toOwnedSlice.
    return .{ .ok = compiled };
}

// ── Walker ────────────────────────────────────────────────────────────────────

/// Byte range within the intern buffer. Matches `compiler.zig:StrRef` layout so
/// the two compilers produce the same operand bytes for `.push_string`.
const StrRef = extern struct { offset: u32, len: u32 };

const RawOp = extern union {
    str_ref: StrRef,
    index: i64,
    bool: bool,
    int: i64,
    float: f64,
    none: void,
    slice_args: types.SliceArgs,
};

const RawInstr = extern struct {
    op: Instruction.Op,
    operand: RawOp,
    src_offset: u32 = 0,
};

/// Stage 4 — variable scope entry. A name→id mapping added whenever an
/// `as` pattern declares a new variable. Legacy's `VariableScope` at
/// `src/query/src/compiler.zig:186` is a linked list of per-function-body
/// scopes; Stage 4's walker has no user functions (Stage 9), so a single
/// flat list of entries with shadow-by-update semantics (see
/// `declareVariable` at `compiler.zig:312`) is sufficient.
const VarEntry = struct {
    name: []const u8,
    id: u32,
};

const Walker = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    raw: std.ArrayList(RawInstr),
    intern: std.ArrayList(u8),
    /// Tracks the `src_offset` of the most recently emitted raw instruction.
    /// Used for the trailing implicit `yield_output`, matching the legacy
    /// compiler's "stamp with last consumed token offset" convention.
    last_emit_offset: u32 = 0,
    /// Set when an `error_node` is reached during walk. The walk then returns
    /// `error.AstCompileError` which the entry point maps to `CompileResult.err`.
    compile_err: ?err_mod.CompileError = null,
    /// Running source-byte offset used by suffix-chain scanners to recover
    /// `?` / `]` / ident offsets that the legacy lexer tracked via
    /// `last_tok_offset`. Each suffix op's scanner advances the cursor past
    /// the bytes it consumed.
    scan_cursor: u32 = 0,
    /// Stage 4 — monotonically increasing variable id counter. Matches legacy's
    /// `ctx.next_var_id`. IDs stay unique across the entire compile; even
    /// shadowed rebindings allocate a new id (legacy does the same via
    /// `declareVariable` at `compiler.zig:312-324`).
    next_var_id: u32 = 0,
    /// Stage 4 — flat scope list. Shadowing is an update-in-place on the
    /// same entry (mirrors legacy's behavior in `declareVariable`). The
    /// walker has no Stage 4 construct that opens/closes a sub-scope, so a
    /// single list suffices. Stage 9 (user functions) will introduce
    /// push/pop. Uses `scope_marks` as a stack of saved lengths so that
    /// scope restoration is cheap when it is needed by later stages.
    scope_vars: std.ArrayList(VarEntry),
    /// Stage 4 — saved-length stack for nested scopes (currently unused by
    /// Stage 4 shapes but populated as groundwork for Stage 9). Pushed on
    /// `pushScope`, popped on `popScope`.
    scope_marks: std.ArrayList(usize),

    const Error = error{ OutOfMemory, AstCompilerStageIncomplete, AstCompileError };

    fn emit(w: *Walker, op: Instruction.Op, operand: RawOp, src_offset: u32) error{OutOfMemory}!void {
        try w.raw.append(w.alloc, .{ .op = op, .operand = operand, .src_offset = src_offset });
        w.last_emit_offset = src_offset;
    }

    fn walk(w: *Walker, node: *const Node) Error!void {
        switch (node.kind) {
            .identity => {
                // Bare `.` — push current. Legacy stamps offset of the `.`
                // token; AST `identity.span.start` is the same byte.
                try w.emit(.push_current, .{ .none = {} }, node.span.start);
            },

            .recurse => {
                // `..` → call_builtin(recurse). See compiler.zig:6293.
                try w.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.recurse) }, node.span.start);
            },

            .literal => |lit| switch (lit) {
                .null_val => {
                    try w.emit(.push_null, .{ .none = {} }, node.span.start);
                },
                .bool_val => |b| {
                    try w.emit(.push_bool, .{ .bool = b }, node.span.start);
                },
                .int => |n| {
                    try w.emit(.push_int, .{ .int = n }, node.span.start);
                },
                .float => |f| {
                    try w.emit(.push_float, .{ .float = f }, node.span.start);
                },
                .string => |s| {
                    // The AST parser already decoded escapes; intern the
                    // decoded bytes directly. Matches legacy's
                    // internDecodedStr outcome because both paths store the
                    // post-decode content.
                    const ref = try internStr(&w.intern, w.alloc, s);
                    try w.emit(.push_string, .{ .str_ref = ref }, node.span.start);
                },
            },

            .unary_neg => |u| {
                // Stage 1 covered `unary_neg` wrapping a numeric literal — the
                // bare-negative-literal case (e.g. `-1`, `-0.5`). Stage 5
                // extends this to any non-literal operand (e.g. `-.x`, `-.[0]`,
                // `- .items[0]`).
                //
                // Legacy `parseUnary` at `src/query/src/compiler.zig:2859-2871`:
                //   1. Consume `-`             last_tok_offset = `-`.offset
                //   2. Recurse parseUnary(op)  emits operand bytecode; last
                //                              becomes the operand's final
                //                              consumed-token offset.
                //   3. emit .negate            src_offset = that final offset
                //
                // For the literal case the operand's span.start IS that final
                // offset (single-token literal). For non-literal operands the
                // walker stamps `.negate` with `w.last_emit_offset`, which
                // equals the legacy `last_tok_offset` at the `.negate` emit
                // site (every emit inside the operand updates last_emit_offset
                // to match the legacy's `last_tok_offset` policy).
                switch (u.operand.kind) {
                    .literal => |lit| switch (lit) {
                        .int => |n| {
                            try w.emit(.push_int, .{ .int = n }, u.operand.span.start);
                            try w.emit(.negate, .{ .none = {} }, u.operand.span.start);
                        },
                        .float => |f| {
                            try w.emit(.push_float, .{ .float = f }, u.operand.span.start);
                            try w.emit(.negate, .{ .none = {} }, u.operand.span.start);
                        },
                        else => {
                            // Non-literal operand (e.g. `-.x`). Walk the
                            // operand, then stamp .negate with the walker's
                            // last_emit_offset (matches legacy's
                            // last_tok_offset after operand compilation).
                            try w.walk(u.operand);
                            try w.emit(.negate, .{ .none = {} }, w.last_emit_offset);
                        },
                    },
                    else => {
                        try w.walk(u.operand);
                        try w.emit(.negate, .{ .none = {} }, w.last_emit_offset);
                    },
                }
            },

            // ── Stage 5: arithmetic, comparison, logical, alternative ──

            .arithmetic => |a| {
                // Stage 5 — `A op B` where op ∈ { +, -, *, /, % }.
                // Legacy `parseAdditive` / `parseMultiplicative`:
                //   - walk left; walk right; emit binop.
                //   - src_offset of binop = last_tok_offset after walking
                //     right = offset of the right operand's final consumed
                //     token. We mirror via `w.last_emit_offset`.
                //
                // Generator-on-right (e.g. `. * (1,2)`) is handled by the
                // VM's `Forkpoint.saved_stack` machinery; the compiler just
                // emits the binop normally.
                try w.walk(a.left);
                try w.walk(a.right);
                const op: Instruction.Op = switch (a.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .mod => .mod,
                };
                try w.emit(op, .{ .none = {} }, w.last_emit_offset);
            },

            .comparison => |c| {
                // Stage 5 — `A op B` where op ∈ { <, <=, >, >=, ==, != }.
                // Legacy `parseComparison`: walk left, walk right, emit op.
                try w.walk(c.left);
                try w.walk(c.right);
                const op: Instruction.Op = switch (c.op) {
                    .eq => .eq,
                    .ne => .ne,
                    .lt => .lt,
                    .le => .le,
                    .gt => .gt,
                    .ge => .ge,
                };
                try w.emit(op, .{ .none = {} }, w.last_emit_offset);
            },

            .and_expr => |b| {
                // Stage 5 — `A and B`. Legacy `parseAnd`: walk left, walk
                // right, emit .and_op. Short-circuit is handled at the VM
                // level (the opcode itself takes two booleans; jq's `and`
                // short-circuits by the VM's evaluation order because both
                // sides are already pushed — the actual jq semantics are
                // encoded at the VM, not via compile-time jumps).
                //
                // Note: legacy chains `a and b and c` as
                // `arithmetic(arithmetic(a, b), c)` — left-leaning — and the
                // AST matches.
                try w.walk(b.left);
                try w.walk(b.right);
                try w.emit(.and_op, .{ .none = {} }, w.last_emit_offset);
            },

            .or_expr => |b| {
                // Stage 5 — `A or B`. See `.and_expr` notes.
                try w.walk(b.left);
                try w.walk(b.right);
                try w.emit(.or_op, .{ .none = {} }, w.last_emit_offset);
            },

            .alternative => {
                // Stage 5 — `A // B [// C ...]` emission.
                //
                // Legacy `parseAlternative` at
                // `src/query/src/compiler.zig:2578-2617` records
                // `chain_start` = raw.len BEFORE compiling the first left.
                // For each subsequent `//`:
                //   1. insertRawInstr(chain_start, fork_alt(0))
                //      — splices fork_alt BEFORE the entire left subtree.
                //   2. emit pipe, push_current, jump_if_false(0),
                //          pop_try, push_current, jump(0), backtrack.
                //   3. patch fork_alt operand → right_ip (= raw.len after
                //      backtrack).
                //   4. parseLogical(right).
                //   5. patch the jump from step 2 → end_ip (= raw.len after
                //      right).
                //
                // Every emit inside the loop is stamped with
                // `last_tok_offset`, which was updated to `//`.offset by
                // `nextToken` consuming the `//` operator. AST `alternative`
                // is left-leaning (`alternative(alternative(a, b), c)`), so
                // flatten to a list and scan each `//` in sequence.
                var ops_list: std.ArrayList(*const Node) = .{};
                defer ops_list.deinit(w.alloc);
                try flattenAlternativeOperands(w.alloc, &ops_list, node);

                const chain_start: usize = w.raw.items.len;
                try w.walk(ops_list.items[0]);

                var prev_end: u32 = ops_list.items[0].span.end;
                var i: usize = 1;
                while (i < ops_list.items.len) : (i += 1) {
                    const right = ops_list.items[i];
                    const slash_off = scanDoubleSlash(w.src, prev_end) orelse prev_end;

                    // Insert fork_alt at chain_start. src_offset = 0 (legacy
                    // literal omits the field).
                    try insertRawInstr(w, chain_start, .{
                        .op = .fork_alt,
                        .operand = .{ .index = 0 },
                        .src_offset = 0,
                    });

                    // Emit middle block — every emit stamped with
                    // `//`.offset (legacy's last_tok_offset after
                    // nextToken).
                    try w.emit(.pipe, .{ .none = {} }, slash_off);
                    try w.emit(.push_current, .{ .none = {} }, slash_off);

                    const jif_pos = w.raw.items.len;
                    try w.emit(.jump_if_false, .{ .index = 0 }, slash_off);

                    try w.emit(.pop_try, .{ .none = {} }, slash_off);
                    try w.emit(.push_current, .{ .none = {} }, slash_off);

                    const jump_end_pos = w.raw.items.len;
                    try w.emit(.jump, .{ .index = 0 }, slash_off);

                    // Patch jif → raw.len (backtrack position).
                    w.raw.items[jif_pos].operand = .{ .index = @intCast(w.raw.items.len) };
                    try w.emit(.backtrack, .{ .none = {} }, slash_off);

                    // right_ip = current raw.len. Patch fork_alt at
                    // chain_start → right_ip.
                    const right_ip: u32 = @intCast(w.raw.items.len);
                    w.raw.items[chain_start].operand = .{ .index = @intCast(right_ip) };

                    try w.walk(right);

                    // Patch jump_end → raw.len (end of this alternative).
                    w.raw.items[jump_end_pos].operand = .{ .index = @intCast(w.raw.items.len) };

                    prev_end = right.span.end;
                }
            },

            // ── Stage 2: field access / index access / iterate / slice ──

            .field_access => |fa| {
                // `.foo` (bare) — emit load_key(foo). Legacy stamps src_offset
                // with the offset of the `foo` ident token. For `.["k"]` the
                // legacy path stamps `]`.offset (parseBracket consumes `]`
                // via nextToken, setting last_tok_offset before the emit).
                // We discriminate by inspecting the source byte after the
                // leading `.` to pick the correct stamp location.
                const ref = try internStr(&w.intern, w.alloc, fa.name);
                const src_off = stampFieldAccessOrBracket(w.src, node.span, fa.name);
                try w.emit(.load_key, .{ .str_ref = ref }, src_off);
            },

            .index_access => |ia| {
                // `.[n]` — emit load_index(n). Legacy stamps src_offset with
                // the offset of the `]` token (see compiler.zig parseBracket
                // .int_lit branch: nextToken consumes `]` → last_tok_offset
                // = `]`.offset, then emit). The AST Suffix/IndexAccess spans
                // extend to one-past-`]`, so `]`.offset = node.span.end - 1.
                try w.emit(.load_index, .{ .index = ia.index }, node.span.end - 1);
            },

            .iterate => {
                // `.[]` — emit `each`. Legacy parseBracket stamps src_offset
                // with the `]` offset (nextToken on `]` sets last_tok_offset).
                try w.emit(.each, .{ .none = {} }, node.span.end - 1);
            },

            .slice => |s| {
                // `.[a:b]` / `.[:b]` / `.[a:]` / `.[:]` — emit single `slice`.
                // Legacy stamps `]` offset (last nextToken before emit).
                try w.emit(.slice, .{ .slice_args = .{
                    .from = s.from,
                    .to = s.to,
                    .has_from = s.has_from,
                    .has_to = s.has_to,
                } }, node.span.end - 1);
            },

            .optional => |u| {
                // `expr?` — wrap the inner subtree in fork_try(0) + body +
                // pop_try. In Stage 2 scope, legacy always handles `?` via
                // `parseSuffixes` (compiler.zig:7040-7051), which calls
                // `insertRawInstr` with NO src_offset set — the RawInstr
                // literal omits the field, so it defaults to 0. Then
                // `pop_try` uses `ctx.last_tok_offset`, which is the `?`
                // token offset.
                //
                // parsePrimary's OUTER postfix-? loop (compiler.zig:5800-
                // 5807) is unreachable in Stage 2 because every primary
                // branch that can be followed by `?` already calls
                // parseSuffixes, which consumes the `?` first. So the
                // AST's `optional` — which was produced by the parser's
                // postfix-? loop at parser.zig:376-381 — still maps to the
                // same legacy emission sequence as the inline ?-in-suffix
                // path: fork_try src=0, pop_try src=?.offset.
                const q_off = node.span.end - 1;
                try w.emit(.fork_try, .{ .index = 0 }, 0);
                try w.walk(u.operand);
                try w.emit(.pop_try, .{ .none = {} }, q_off);
            },

            .suffix => |sfx| {
                // A suffix chain: emit the base first, then each op in order.
                // `?` ops retroactively wrap the preceding segment (since the
                // last `?`) in fork_try/pop_try.
                //
                // Matches `parseSuffixes` at compiler.zig:6966-7055 byte-for-
                // byte: each non-`?` op after the base is preceded by `pipe`;
                // a `?` op uses `insertRawInstr` to splice fork_try at the
                // current segment start and append pop_try.
                try w.walk(sfx.base);
                // `segment_start` tracks the raw-instr index where the current
                // `?`-scope began. Reset after every `?` so the next `?` wraps
                // only what comes after. Mirrors the legacy `segment_start`.
                var segment_start: usize = base_segment_start(sfx.base, w);

                for (sfx.ops) |op| switch (op) {
                    .field => |name| {
                        // Legacy parseSuffixes:
                        //   1) advance `.`     (last_tok_offset = dot.offset)
                        //   2) advance ident   (last_tok_offset = ident.offset)
                        //   3) emit pipe       src = ident.offset
                        //   4) emit load_key   src = ident.offset
                        // Compute ident.offset by scanning source from the
                        // walker's cursor.
                        const off = scanDotIdentOffset(w, name);
                        try w.emit(.pipe, .{ .none = {} }, off);
                        segment_start = w.raw.items.len;
                        const ref = try internStr(&w.intern, w.alloc, name);
                        try w.emit(.load_key, .{ .str_ref = ref }, off);
                    },
                    .bracket_str => |name| {
                        // `.foo["k"]` — legacy parseBracket consumes `[`,
                        // then advances string_lit (last_tok_offset = str.offset),
                        // then advances `]` (last_tok_offset = `]`.offset),
                        // then emits load_key with src = `]`.offset. Pipe was
                        // emitted just before with src = `[`.offset (or, more
                        // precisely, the lex position after `[` scan — the
                        // legacy pipe is emitted BEFORE parseBracket runs, so
                        // its src_offset = offset of the `[` token).
                        const lbracket_off = scanForSkipWs(w.src, w.scan_cursor, '[') orelse w.scan_cursor;
                        w.scan_cursor = lbracket_off + 1;
                        // pipe carries `[`.offset because legacy emits it
                        // right after consuming `[` (last_tok_offset = `[`.offset).
                        try w.emit(.pipe, .{ .none = {} }, lbracket_off);
                        segment_start = w.raw.items.len;
                        // Advance to the end of the bracket group, then the
                        // load_key stamps `]`.offset.
                        const rbracket_off = scanBracketPairEndFrom(w.src, lbracket_off);
                        w.scan_cursor = rbracket_off + 1;
                        const ref = try internStr(&w.intern, w.alloc, name);
                        try w.emit(.load_key, .{ .str_ref = ref }, rbracket_off);
                    },
                    .index => |idx| {
                        const lbracket_off = scanForSkipWs(w.src, w.scan_cursor, '[') orelse w.scan_cursor;
                        w.scan_cursor = lbracket_off + 1;
                        try w.emit(.pipe, .{ .none = {} }, lbracket_off);
                        segment_start = w.raw.items.len;
                        const rbracket_off = scanBracketPairEndFrom(w.src, lbracket_off);
                        w.scan_cursor = rbracket_off + 1;
                        try w.emit(.load_index, .{ .index = idx }, rbracket_off);
                    },
                    .iterate => {
                        const lbracket_off = scanForSkipWs(w.src, w.scan_cursor, '[') orelse w.scan_cursor;
                        w.scan_cursor = lbracket_off + 1;
                        try w.emit(.pipe, .{ .none = {} }, lbracket_off);
                        segment_start = w.raw.items.len;
                        const rbracket_off = scanBracketPairEndFrom(w.src, lbracket_off);
                        w.scan_cursor = rbracket_off + 1;
                        try w.emit(.each, .{ .none = {} }, rbracket_off);
                    },
                    .slice => |s| {
                        const lbracket_off = scanForSkipWs(w.src, w.scan_cursor, '[') orelse w.scan_cursor;
                        w.scan_cursor = lbracket_off + 1;
                        try w.emit(.pipe, .{ .none = {} }, lbracket_off);
                        segment_start = w.raw.items.len;
                        const rbracket_off = scanBracketPairEndFrom(w.src, lbracket_off);
                        w.scan_cursor = rbracket_off + 1;
                        try w.emit(.slice, .{ .slice_args = .{
                            .from = s.from,
                            .to = s.to,
                            .has_from = s.has_from,
                            .has_to = s.has_to,
                        } }, rbracket_off);
                    },
                    .optional => {
                        // Retroactively wrap the current segment. Legacy
                        // inserts fork_try with src_offset=0 (default from
                        // compiler.zig:7045 — the RawInstr literal omits
                        // .src_offset), emits pop_try with src_offset =
                        // ctx.last_tok_offset (= offset of `?`). Segment_start
                        // advances past pop_try.
                        const q_off = scanForSkipWs(w.src, w.scan_cursor, '?') orelse w.scan_cursor;
                        w.scan_cursor = q_off + 1;
                        try insertRawInstr(w, segment_start, .{
                            .op = .fork_try,
                            .operand = .{ .index = 0 },
                            .src_offset = 0,
                        });
                        try w.emit(.pop_try, .{ .none = {} }, q_off);
                        segment_start = w.raw.items.len;
                    },
                    .bracket_expr => return error.AstCompilerStageIncomplete,
                };
            },

            .pipe => {
                // Stage 3 — `a | b` emits `<A>, pipe, <B>`. Pipe opcode's
                // src_offset = `|` token offset. AST is left-leaning for
                // chains (`a | b | c` → `pipe(pipe(a, b), c)`); flattening
                // the chain mirrors the legacy iterative `parsePipe` at
                // `src/query/src/compiler.zig:2449-2471` byte-for-byte.
                var buf: std.ArrayList(*const Node) = .{};
                defer buf.deinit(w.alloc);
                try flattenPipeOperands(w.alloc, &buf, node);
                // Emit first operand.
                try w.walk(buf.items[0]);
                // For each subsequent operand, emit .pipe at the `|` token
                // offset between the previous operand and this one, then
                // walk the operand.
                var prev_end: u32 = buf.items[0].span.end;
                var i: usize = 1;
                while (i < buf.items.len) : (i += 1) {
                    const op = buf.items[i];
                    const pipe_off = scanForSkipWs(w.src, prev_end, '|') orelse prev_end;
                    try w.emit(.pipe, .{ .none = {} }, pipe_off);
                    try w.walk(op);
                    prev_end = op.span.end;
                }
            },

            .comma => {
                // Stage 3 — `a, b, c` emits the chained FORK/JUMP generator
                // pattern from legacy `parseComma` at
                // `src/query/src/compiler.zig:2504-2558`. The resulting
                // byte layout for an N-way comma is:
                //
                //   FORK(k1), <A>, JUMP(end), FORK(k2), <B>, JUMP(end),
                //   ..., FORK(kN-1), <N-1>, JUMP(end), <N>
                //
                // where each FORK's target points at the next FORK (or, for
                // the last, at the last operand), and every JUMP lands just
                // past the final operand. FORKs are injected via
                // `insertRawInstr` with src_offset = 0 (the RawInstr literal
                // in legacy omits the field); JUMPs are emitted via
                // `ctx.emit` after `ctx.nextToken` consumed the `,` token,
                // so their src_offset = that comma's byte offset.
                //
                // AST builds comma chains left-leaning
                // (`comma(comma(a, b), c)`), so we flatten to walk the
                // legacy iterative pattern exactly.
                var buf: std.ArrayList(*const Node) = .{};
                defer buf.deinit(w.alloc);
                try flattenCommaOperands(w.alloc, &buf, node);

                var jump_fixups: std.ArrayList(usize) = .{};
                defer jump_fixups.deinit(w.alloc);

                var left_start: usize = w.raw.items.len;
                try w.walk(buf.items[0]);

                var prev_fork_pos: ?usize = null;
                // Track source cursor to locate each `,` token between
                // operand[i-1] and operand[i]. Start scanning from the end
                // of the first operand.
                var prev_end: u32 = buf.items[0].span.end;

                var i: usize = 1;
                while (i < buf.items.len) : (i += 1) {
                    const comma_off = scanForSkipWs(w.src, prev_end, ',') orelse prev_end;

                    // Insert FORK at left_start. src_offset=0 matches the
                    // legacy RawInstr literal which omits the field.
                    try insertRawInstr(w, left_start, .{
                        .op = .fork,
                        .operand = .{ .index = 0 },
                        .src_offset = 0,
                    });

                    // Point previous FORK at this new FORK so backtracking
                    // from the earlier branch lands here. Legacy sets this
                    // BEFORE the insertRawInstr adjusts IPs, but since the
                    // previous FORK's current target was left_start (set by
                    // the prior backpatch) and insertRawInstr's ">pos" rule
                    // only bumps strictly-greater targets, the prior target
                    // (== left_start) is preserved — unlike the legacy code
                    // which overwrites it to the same value.
                    if (prev_fork_pos) |pfp| {
                        w.raw.items[pfp].operand.index = @intCast(left_start);
                    }

                    // Emit JUMP(0) placeholder. src = comma_off (legacy's
                    // last_tok_offset after nextToken consumed `,`).
                    const jump_pos = w.raw.items.len;
                    try w.emit(.jump, .{ .index = 0 }, comma_off);
                    try jump_fixups.append(w.alloc, jump_pos);

                    const current_fork_pos = left_start;

                    // Parse the right side.
                    left_start = w.raw.items.len;
                    try w.walk(buf.items[i]);

                    // Backpatch FORK target to the start of this operand.
                    w.raw.items[current_fork_pos].operand.index = @intCast(left_start);
                    prev_fork_pos = current_fork_pos;

                    prev_end = buf.items[i].span.end;
                }

                // Backpatch all JUMP targets to end-of-block.
                const end_pos: i64 = @intCast(w.raw.items.len);
                for (jump_fixups.items) |fixup| {
                    w.raw.items[fixup].operand.index = end_pos;
                }
            },

            .variable_ref => |vr| {
                // Stage 4 — `$name` evaluates a previously-captured variable
                // and pushes its value onto the value stack. Legacy equivalent:
                // `parseVariableReference` at `src/query/src/compiler.zig:6567`.
                //
                // Legacy stamps `load_variable` with `ctx.last_tok_offset`,
                // which is the offset of the ident token after `$name` is
                // consumed. The AST's `variable_ref.span` runs from the `$`
                // byte to one-past the ident's last byte, so the ident's
                // offset is `span.end - name.len` (idents have no escapes).
                //
                // `$__loc__` expands to a synthesized marker object via
                // `emitLocObject` — same opcode sequence the legacy compiler
                // produces at `src/query/src/compiler.zig:6574-6577`. Stamp
                // every emit with the ident offset (`__loc__` token's byte
                // position), matching legacy's `last_tok_offset` after
                // `parseVariableReference` consumed the ident token.
                if (std.mem.eql(u8, vr.name, "__loc__")) {
                    const ident_off = identOffsetOfVarRef(node.span, vr.name);
                    try emitLocObject(w, ident_off);
                    return;
                }
                const var_id = lookupVariable(w, vr.name) orelse {
                    // Undefined variable — legacy raises query_syntax_error
                    // at `last_tok_offset` with len=0. AST walker mirrors.
                    const ident_off = identOffsetOfVarRef(node.span, vr.name);
                    w.compile_err = .{
                        .kind = .query_syntax_error,
                        .offset = ident_off,
                        .len = 0,
                    };
                    return error.AstCompileError;
                };
                const ident_off = identOffsetOfVarRef(node.span, vr.name);
                try w.emit(.load_variable, .{ .index = @as(i64, @intCast(var_id)) }, ident_off);
            },

            .as_pattern => |ap| {
                // Stage 4 — `expr as PATTERN | body`.
                //
                // Legacy flow in `parseLogical` at
                // `src/query/src/compiler.zig:2624-2643`:
                //   1. Compile `expr`. Result is on the value stack.
                //   2. Consume `as`.
                //   3. `scanAndDeclarePattern` allocates variable IDs in
                //      left-to-right, depth-first order as they are
                //      encountered in the pattern.
                //   4. `emitPatternCapture` emits the capture sequence using
                //      `ctx.last_tok_offset`, which is the offset of the
                //      pattern's final token (the ident for simple; `]`/`}`
                //      for array/object).
                //   5. `parseLogical` returns, the surrounding `parsePipe`
                //      sees `|`, emits `.pipe` stamped at `|`.offset, and
                //      compiles the body.
                //
                // No `pop_variable` is emitted — legacy leaves the variable
                // live in the flat scope list. Stage 4 mirrors this.
                try w.walk(ap.expr);

                // Locate the pattern's token-span in source. This must match
                // what legacy's lexer would have tracked via `last_tok_offset`
                // at the moment `emitPatternCapture` starts firing.
                //
                // The scanner expects to begin at the pattern's first byte,
                // so we first advance past the `as` keyword.
                const after_as = advancePastAsKeyword(w.src, ap.expr.span.end);
                const pat_layout = scanPatternLayout(w.src, after_as, ap.pattern);

                // Declare pattern variables in the same traversal order as
                // legacy's `scanAndDeclarePattern`. IDs are allocated into the
                // flat `scope_vars` list.
                try declarePatternVars(w, ap.pattern);

                try emitPatternCapture(w, ap.pattern, pat_layout.last_tok_offset);

                // Emit `.pipe` for the `|` token between pattern-end and body.
                const pipe_off = scanForSkipWs(w.src, pat_layout.end_after, '|') orelse pat_layout.end_after;
                try w.emit(.pipe, .{ .none = {} }, pipe_off);

                try w.walk(ap.body);
            },

            .destruct_alt => |da| {
                // Stage 4 — `expr as PAT1 ?// PAT2 [?// PAT3 ...] | body`.
                //
                // Legacy flow: after `parseLogical` scans PAT1 and sees `?//`,
                // `parseDestructAlt` at `src/query/src/compiler.zig:2698`
                // takes over. Variables from subsequent patterns REUSE ids
                // when a name collides (`scanAndDeclarePatternReuse` at
                // `compiler.zig:443`), ensuring all alternatives write to
                // the same slots.
                //
                // Emission shape (legacy `parseDestructAlt` body):
                //   - For each unique var_id in pattern-iteration order:
                //       push_null ; capture_variable(var_id)   (null-init)
                //   - .pipe ; save_input
                //   - For each pattern (i):
                //       if i > 0: restore_input ; save_input
                //       fork_try(0)             [catch backpatched to next block]
                //       push_current
                //       <emitPatternCaptureStrict pattern>
                //       pop_try
                //       restore_input
                //       jump(body)              [backpatched later]
                //       (if last:) restore_input ; backtrack
                //
                // All emits inside parseDestructAlt use `ctx.last_tok_offset`
                // which is the last consumed token during pattern scanning —
                // the pattern-end offset of the *most recent pattern* that
                // was scanned. Tracking this precisely requires walking each
                // pattern's source range in turn.
                try w.walk(da.expr);

                // Scan each pattern's source range to learn the final
                // pattern's closing-token offset. That offset rules every
                // emit in this node (see legacy-parity comment below).
                const patterns = da.patterns;

                // Cursor starts just past the `as` keyword; advance through
                // each pattern, skipping the `?//` separators between them.
                var cursor = advancePastAsKeyword(w.src, da.expr.span.end);
                var final_last_tok_scan: u32 = 0;
                for (patterns, 0..) |pat, i| {
                    const layout = scanPatternLayout(w.src, cursor, pat);
                    final_last_tok_scan = layout.last_tok_offset;
                    cursor = layout.end_after;
                    if (i + 1 < patterns.len) {
                        // Advance past `?` and `//`.
                        cursor = skipTrivia(w.src, cursor);
                        if (cursor < w.src.len and w.src[cursor] == '?') cursor += 1;
                        cursor = skipTrivia(w.src, cursor);
                        if (cursor + 1 < w.src.len and w.src[cursor] == '/' and w.src[cursor + 1] == '/') cursor += 2;
                    }
                }

                // Declare pattern variables. First pattern allocates new ids;
                // later patterns reuse by-name when an id already exists in
                // the current scope (legacy `scanAndDeclarePatternReuse`).
                for (patterns, 0..) |pat, i| {
                    if (i == 0) {
                        try declarePatternVars(w, pat);
                    } else {
                        try declarePatternVarsReuse(w, pat);
                    }
                }

                // Collect all unique var ids in pattern-iteration order —
                // mirrors legacy's `collectPatternVarIds` loop at
                // `compiler.zig:2715-2717`.
                var all_ids = std.ArrayList(u32){};
                defer all_ids.deinit(w.alloc);
                for (patterns) |pat| {
                    try collectPatternVarIds(w, pat, &all_ids);
                }

                // Null-init all variables. Legacy stamps both ops with
                // `last_tok_offset` = offset of the FINAL pattern's last
                // token (since pattern scanning ended there).
                const final_last_tok = final_last_tok_scan;
                for (all_ids.items) |vid| {
                    try w.emit(.push_null, .{ .none = {} }, final_last_tok);
                    try w.emit(.capture_variable, .{ .index = @as(i64, @intCast(vid)) }, final_last_tok);
                }

                // pipe ; save_input — stamp with final pattern's last tok.
                try w.emit(.pipe, .{ .none = {} }, final_last_tok);
                try w.emit(.save_input, .{ .none = {} }, final_last_tok);

                var jump_to_body = std.ArrayList(usize){};
                defer jump_to_body.deinit(w.alloc);

                // Per plan §6.2 / legacy behavior at
                // `src/query/src/compiler.zig:2698-2779`: every emit inside
                // `parseDestructAlt` uses `ctx.last_tok_offset`, which has
                // been advanced to the FINAL pattern's last token by the
                // time the emit phase starts. `peekIsDestructAlt` reads
                // `?//` via raw `lex.next()` without stamping
                // `last_tok_offset`, so the final pattern's closing-token
                // offset rules every emit — including those conceptually
                // attached to earlier patterns.
                for (patterns, 0..) |pat, i| {
                    const is_last = (i == patterns.len - 1);

                    if (i > 0) {
                        try w.emit(.restore_input, .{ .none = {} }, final_last_tok);
                        try w.emit(.save_input, .{ .none = {} }, final_last_tok);
                    }

                    const fork_try_pos = w.raw.items.len;
                    try w.emit(.fork_try, .{ .index = 0 }, final_last_tok);
                    try w.emit(.push_current, .{ .none = {} }, final_last_tok);
                    try emitPatternCaptureStrict(w, pat, final_last_tok);
                    try w.emit(.pop_try, .{ .none = {} }, final_last_tok);
                    try w.emit(.restore_input, .{ .none = {} }, final_last_tok);

                    const jmp_pos = w.raw.items.len;
                    try w.emit(.jump, .{ .index = 0 }, final_last_tok);
                    try jump_to_body.append(w.alloc, jmp_pos);

                    const catch_ip: u32 = @intCast(w.raw.items.len);
                    w.raw.items[fork_try_pos].operand = .{ .index = @intCast(catch_ip) };

                    if (is_last) {
                        try w.emit(.restore_input, .{ .none = {} }, final_last_tok);
                        try w.emit(.backtrack, .{ .none = {} }, final_last_tok);
                    }
                }

                const body_ip: u32 = @intCast(w.raw.items.len);
                for (jump_to_body.items) |jmp_pos| {
                    w.raw.items[jmp_pos].operand = .{ .index = @intCast(body_ip) };
                }

                // Emit `.pipe` for the `|` between final pattern end and body.
                const pipe_off = scanForSkipWs(w.src, cursor, '|') orelse cursor;
                try w.emit(.pipe, .{ .none = {} }, pipe_off);

                try w.walk(da.body);
            },

            .error_node => |en| {
                // Error nodes surface the parser's best-effort recovery. They
                // must reject as a compile error, not return "stage incomplete".
                w.compile_err = .{
                    .kind = .query_syntax_error,
                    .offset = node.span.start,
                    .len = if (node.span.end > node.span.start) node.span.end - node.span.start else 0,
                };
                _ = en;
                return error.AstCompileError;
            },

            // ── Stage 6: parens, try/catch, if/elif/else, path() ──────

            .paren => |u| {
                // Stage 6 — `(EXPR)` grouping. Transparent: the legacy
                // `parsePrimaryInner` at `src/query/src/compiler.zig:6295-6301`
                // consumes `(`, calls `parsePipe` on the inner expression, then
                // consumes `)` and runs `parseSuffixes`. The `(` / `)` tokens
                // do NOT emit bytecode of their own — only the inner expression
                // contributes instructions.
                //
                // Legacy side-effect: consuming `)` updates
                // `ctx.last_tok_offset = ).offset`. Any emit that fires AFTER
                // the parens (e.g. a surrounding `parseAdditive`'s `add`, or
                // the trailing implicit `yield_output`) picks up `).offset`.
                // Mirror this by bumping `w.last_emit_offset` to `).offset`
                // after the inner walk. `).offset = span.end - 1` because
                // `paren.span.end` is `p.lex.pos` after the `)` consume (see
                // `src/ast/parser.zig:441`).
                //
                // The AST wraps `(inner)` in `paren { operand = inner }` but
                // does NOT eagerly merge suffixes — the parser at
                // `src/ast/parser.zig:441` produces a bare `paren` node and
                // the caller (parseSuffix) builds a suffix chain on top if
                // trailing suffixes exist. In that case the AST is
                // `suffix { base = paren{inner}, ops = [...] }` and `.paren`
                // is walked as the base, with the suffix walker driving
                // subsequent emits.
                try w.walk(u.operand);
                if (node.span.end > node.span.start) {
                    w.last_emit_offset = node.span.end - 1;
                }
            },

            .try_catch => |tc| {
                // Stage 6 — `try BODY [catch HANDLER]`.
                //
                // Legacy `parseTryCatch` at
                // `src/query/src/compiler.zig:6422-6452`:
                //   1. emit fork_try(0)                    [stamp=try.offset]
                //   2. parsePrimary(body)
                //   3. if catch present:
                //        consume catch kw                  [last=catch.offset]
                //        emit pop_try                      [stamp=catch.offset]
                //        emit jump(0)                      [stamp=catch.offset]
                //        backpatch fork_try → handler_ip
                //        parsePrimary(handler)
                //        backpatch jump → raw.len
                //      else:
                //        emit pop_try                      [stamp=body's last]
                //
                // `try.offset` == `node.span.start`. The catch-keyword offset
                // is scanned from `body.span.end` forward.
                const try_off = node.span.start;
                const fork_try_pos = w.raw.items.len;
                try w.emit(.fork_try, .{ .index = 0 }, try_off);

                try w.walk(tc.body);

                if (tc.catch_body) |handler| {
                    const catch_off = scanKeyword(w.src, tc.body.span.end, "catch");
                    try w.emit(.pop_try, .{ .none = {} }, catch_off);

                    const jump_pos = w.raw.items.len;
                    try w.emit(.jump, .{ .index = 0 }, catch_off);

                    const catch_ip: u32 = @intCast(w.raw.items.len);
                    w.raw.items[fork_try_pos].operand = .{ .index = @intCast(catch_ip) };

                    try w.walk(handler);

                    w.raw.items[jump_pos].operand = .{ .index = @intCast(w.raw.items.len) };
                } else {
                    try w.emit(.pop_try, .{ .none = {} }, w.last_emit_offset);
                }
            },

            .if_expr => |ife| {
                // Stage 6 — `if COND then THEN [elif COND then THEN]* [else ELSE] end`.
                //
                // Legacy `parseIfBody` at
                // `src/query/src/compiler.zig:6467-6522` emits:
                //   save_input           [stamp=if.offset (or elif.offset for nested)]
                //   <COND>
                //   jump_if_false(0)     [stamp=then.offset]
                //   restore_input        [stamp=then.offset]
                //   <THEN>
                //   jump(0)              [stamp=last emit from THEN]
                //   <backpatch jif>
                //   restore_input        [stamp=last emit from THEN]
                //   (elif → nested parseIfBody; else → <ELSE> + end consumed;
                //    no-else → emit identity stamped end.offset)
                //   <backpatch jump>
                //
                // For elif, legacy is RECURSIVE: after the outer's
                // `restore_input` it consumes `elif`, then recursively calls
                // `parseIfBody`. That inner call emits its own save_input
                // stamped with `elif.offset`, and so on. The AST flattens
                // elif_chains, so the walker must re-recurse to match.
                try emitIfBody(
                    w,
                    node.span.start,
                    ife.cond,
                    ife.then_body,
                    ife.elif_chains,
                    ife.else_body,
                );
            },

            .builtin_call => |bc| {
                // Stage 6 handles ONLY `path(EXPR)` here. Every other builtin
                // stays at AstCompilerStageIncomplete. The AST parser's
                // `isBuiltinName` (at `src/ast/parser.zig:1484-1503`) does NOT
                // include "path" — so `path(.a)` actually arrives as a
                // `func_call` node (see `.func_call` branch below for the
                // primary dispatch). This arm is kept for defensive coverage:
                // if a future parser fix adds "path" to isBuiltinName, the
                // walker already handles it.
                if (std.mem.eql(u8, bc.name, "path") and bc.args.len == 1) {
                    try emitPathCall(w, node.span, bc.args[0]);
                    return;
                }

                // Stage 7 — standalone format builtins (`. | @base64`,
                // `. | @uri`, …). The AST parser stores the leading `@` in the
                // name via `internFormatName` (parser.zig:1441), so any
                // builtin whose first byte is `@` is a format call. Legacy
                // emits `call_builtin(format_*)` stamped with the format-name
                // ident offset (= `@`.offset + 1), matching `ctx.last_tok_offset`
                // after `nextToken` consumed the ident token in
                // `parsePrimaryInner`'s `.at` branch at
                // `src/query/src/compiler.zig:6330-6357`.
                if (bc.name.len >= 2 and bc.name[0] == '@' and bc.args.len == 0) {
                    if (formatBuiltinId(bc.name[1..])) |bid| {
                        try w.emit(
                            .call_builtin,
                            .{ .index = @intFromEnum(bid) },
                            node.span.start + 1,
                        );
                        return;
                    }
                }
                return error.AstCompilerStageIncomplete;
            },

            .func_call => |fc| {
                // Stage 6 handles ONLY `path(EXPR)` here. The AST routes
                // `path(.a)` through the `func_call` branch because
                // `isBuiltinName` omits "path" (known AST latent mismatch —
                // see comment on `.builtin_call`). Every other func_call
                // stays at Stage 9/10.
                if (std.mem.eql(u8, fc.name, "path") and fc.args.len == 1) {
                    try emitPathCall(w, node.span, fc.args[0]);
                    return;
                }
                return error.AstCompilerStageIncomplete;
            },

            // ── Stage 7: array / object / string-interp / format-string ──

            .array_construct => |ac| {
                // Legacy `parseArrayConstruct` at
                // `src/query/src/compiler.zig:6535-6564` emits:
                //
                //   array_collect_start(end_ip)      @ `[`.offset
                //   (if non-empty body:
                //     save_input                     @ `[`.offset
                //     <EXPR>                         (parsePipe — includes
                //                                     comma handling!)
                //     yield_output                   @ expr's final token
                //     restore_input                  @ expr's final token
                //   )
                //   array_collect_end                @ `]`.offset
                //   (backpatch start → raw.len - 1 == end's IP pre-fuse)
                //
                // Note: the legacy outer while-comma loop at 6546-6552 is
                // dead code — `parsePipe` already consumes the entire comma
                // chain via its internal `parseComma`. So the AST walker
                // just walks `ac.expr` (which IS a `comma` tree for
                // comma-joined items) and the comma walker emits the
                // FORK/JUMP generator pattern exactly like Stage 3.
                const lbracket_off = node.span.start;
                const rbracket_off = if (node.span.end > node.span.start)
                    node.span.end - 1
                else
                    node.span.start;

                const start_pos = w.raw.items.len;
                try w.emit(.array_collect_start, .{ .index = 0 }, lbracket_off);

                if (ac.expr) |expr| {
                    try w.emit(.save_input, .{ .none = {} }, lbracket_off);
                    try w.walk(expr);
                    try w.emit(.yield_output, .{ .none = {} }, w.last_emit_offset);
                    try w.emit(.restore_input, .{ .none = {} }, w.last_emit_offset);
                }

                try w.emit(.array_collect_end, .{ .none = {} }, rbracket_off);
                // start operand points at end's raw IP = raw.len - 1.
                w.raw.items[start_pos].operand = .{ .index = @intCast(w.raw.items.len - 1) };
            },

            .object_construct => |oc| {
                // Legacy `parseObjectLiteral` at
                // `src/query/src/compiler.zig:6827-6907` emits
                // `object_construct_start`, a (key, value, object_key) triad
                // per field, and `object_construct_end`. See the per-field
                // helper below for the field lowering detail — it must match
                // legacy byte-for-byte including the dynamic-key replay dance.
                try w.emit(.object_construct_start, .{ .none = {} }, node.span.start);

                // Track the cursor for per-field source-byte scanning. The
                // first field starts immediately after `{`.
                var field_cursor: u32 = node.span.start + 1;
                for (oc.fields, 0..) |field, idx| {
                    field_cursor = skipTrivia(w.src, field_cursor);
                    try emitObjectField(w, field, &field_cursor);

                    if (idx + 1 < oc.fields.len) {
                        // Field separator `,` — consumes last_tok_offset.
                        // We don't emit anything for the comma itself but
                        // we DO need to advance the cursor past it for the
                        // next field's scan.
                        const comma_off = scanForSkipWs(w.src, field_cursor, ',') orelse field_cursor;
                        field_cursor = comma_off + 1;
                    }
                }

                const rbrace_off = if (node.span.end > node.span.start)
                    node.span.end - 1
                else
                    node.span.start;
                try w.emit(.object_construct_end, .{ .none = {} }, rbrace_off);
            },

            .string_interp => |si| {
                // Legacy `compileStringInterpolation` at
                // `src/query/src/compiler.zig:5729-5793` with no format.
                //
                // The AST's `.span.start` equals `first_part_tok.offset`
                // (parser.zig:959), which is the first byte AFTER the opening
                // `"`. That is the offset legacy stamps on the initial
                // `push_string(first_literal)` because `parsePrimaryInner`'s
                // `.string_part` branch consumes the first string_part token
                // whose offset is `content_start`.
                try emitStringInterp(w, node.span, si.parts, null);
            },

            .format_string => |fs| {
                // Two AST shapes flow through here:
                //   (A) `@name "literal"` with NO interpolation — parser path
                //       at `src/ast/parser.zig:902-911` builds a format_string
                //       whose `parts = [.literal(decoded)]` and whose span
                //       starts at `@`.offset.
                //   (B) `@name "...\(expr)..."` (interp) — parser path at
                //       `src/ast/parser.zig:898-901` reuses `parseStringInterp`
                //       whose span starts at `first_part_tok.offset`
                //       (= content_start after the opening `"`).
                //
                // Plan §6.6 call-out: legacy routes (A) through a bare
                // `push_string(decoded)` (compiler.zig:6344-6350) stamped at
                // the `"`.offset (= string_lit.offset). Route (B) goes through
                // `compileStringInterpolation` with the format bid threaded in.
                // The walker must discriminate on structure AND on span shape.

                const bid = formatBuiltinId(fs.format) orelse
                    return error.AstCompilerStageIncomplete;

                const is_pure_literal = fs.parts.len == 1 and
                    fs.parts[0] == .literal;

                // Shape (A) is detectable because the span starts at `@` (not
                // at a string content byte) AND there are no `.expr` parts.
                // We probe by checking the first byte at span.start.
                const starts_with_at = node.span.start < w.src.len and
                    w.src[node.span.start] == '@';

                if (is_pure_literal and starts_with_at) {
                    // (A) — locate `"`.offset by scanning past `@name`.
                    const quote_off = scanOpeningQuoteAfterFormat(w.src, node.span.start);
                    const ref = try internStr(
                        &w.intern,
                        w.alloc,
                        fs.parts[0].literal,
                    );
                    try w.emit(.push_string, .{ .str_ref = ref }, quote_off);
                } else {
                    // (B) — interp path with format bid.
                    try emitStringInterp(w, node.span, fs.parts, bid);
                }
            },

            // ── Scaffold boundary: every other kind is a future stage. ──
            .func_def,
            .reduce,
            .foreach,
            .label_expr,
            .break_expr,
            .update_assign,
            => return error.AstCompilerStageIncomplete,
        }
    }
};

// ── Source-byte scanning helpers ─────────────────────────────────────────────
//
// The legacy compiler's `src_offset` comes from `ctx.last_tok_offset`, updated
// on every `nextToken`. The AST parser does not preserve each intermediate
// token offset; to produce byte-identical bytecode, we rescan the source from
// the current segment's start position to locate the offsets of `[` / `]` / `?`
// tokens as they appear in the legacy lexer.
//
// These scanners are deliberately minimal — they handle only the tokens that
// appear in Stage 2 suffix chains (`.`, `[`, `]`, `:`, `?`, integer literals,
// `"..."` string literals). They must stay lexically consistent with
// `src/query/src/lexer.zig` for whitespace and comment handling; Stage 2
// relies on the AST's well-formedness to ensure the expected token sequence
// exists at the scanned span.

fn stampFieldAccess(span: ast.Span, name: []const u8) u32 {
    // `.ident`: the ident offset is `span.end - name.len` because ident
    // tokens have identical source and interned lengths. For `."str"` with
    // escapes the interned len may differ from the source token length — the
    // fixture list calls this out as known-drift where it applies.
    if (span.end > name.len) return span.end - @as(u32, @intCast(name.len));
    return span.start;
}

/// Like `stampFieldAccess`, but distinguishes `.foo` / `."foo"` from `.["foo"]`.
/// For the latter, legacy stamps the `]` offset (= span.end - 1).
fn stampFieldAccessOrBracket(src: []const u8, span: ast.Span, name: []const u8) u32 {
    // Skip trivia after the leading `.` (at span.start) to see if the next
    // token is `[`. If so, this is a `.[...]` bracket-access form.
    if (span.start >= src.len or src[span.start] != '.') {
        return stampFieldAccess(span, name);
    }
    const after_dot = skipTrivia(src, span.start + 1);
    if (after_dot < src.len and src[after_dot] == '[') {
        // Bracket form: stamp `]`.offset = span.end - 1.
        if (span.end > span.start) return span.end - 1;
        return span.start;
    }
    return stampFieldAccess(span, name);
}

/// Skip ASCII whitespace and `#` line comments. Returns the next non-skip
/// byte offset, or `src.len` if end-of-input.
fn skipTrivia(src: []const u8, start: u32) u32 {
    var i: usize = start;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '#') {
            while (i < src.len and src[i] != '\n') : (i += 1) {}
            continue;
        }
        break;
    }
    return @intCast(i);
}

/// Scan forward from `start` skipping trivia and return the offset of the
/// first byte matching `target`, or null if the first non-trivia byte is
/// something else.
fn scanForSkipWs(src: []const u8, start: u32, target: u8) ?u32 {
    const off = skipTrivia(src, start);
    if (off >= src.len or src[off] != target) return null;
    return off;
}

/// Given an offset of a `[`, return the offset of the matching `]`. Handles
/// nested brackets and `"..."` string literals with escapes.
fn scanBracketPairEndFrom(src: []const u8, open_lbracket: u32) u32 {
    std.debug.assert(open_lbracket < src.len and src[open_lbracket] == '[');
    var i: usize = open_lbracket + 1;
    var depth: u32 = 1;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '"') {
            i += 1;
            while (i < src.len) : (i += 1) {
                if (src[i] == '\\') {
                    if (i + 1 < src.len) i += 1;
                    continue;
                }
                if (src[i] == '"') break;
            }
            continue;
        }
        if (c == '[') depth += 1;
        if (c == ']') {
            depth -= 1;
            if (depth == 0) return @intCast(i);
        }
    }
    return @intCast(src.len - 1);
}

/// Compute `ident.offset` for a `.<ident>` or `.<"str">` suffix element. The
/// scan starts at `w.scan_cursor`, which must point at the byte of (or just
/// before) the `.` token. Advances `w.scan_cursor` past the element.
fn scanDotIdentOffset(w: *Walker, name: []const u8) u32 {
    const dot_off = scanForSkipWs(w.src, w.scan_cursor, '.') orelse w.scan_cursor;
    const tok_off = skipTrivia(w.src, dot_off + 1);
    if (tok_off < w.src.len and w.src[tok_off] == '"') {
        // `."..."` — advance past the closing `"`.
        var i: usize = tok_off + 1;
        while (i < w.src.len) : (i += 1) {
            if (w.src[i] == '\\') {
                if (i + 1 < w.src.len) i += 1;
                continue;
            }
            if (w.src[i] == '"') {
                w.scan_cursor = @intCast(i + 1);
                return tok_off;
            }
        }
        w.scan_cursor = @intCast(w.src.len);
        return tok_off;
    }
    // Ident — source length == name length (idents have no escapes).
    w.scan_cursor = @intCast(tok_off + name.len);
    return tok_off;
}

/// Flatten a left-leaning `pipe(pipe(a, b), c)` chain into `[a, b, c]`.
/// Any non-pipe node is emitted as-is; pipe children are recursed into on the
/// left only (matching the parser's left-to-right accumulation at
/// `src/ast/parser.zig:148-173`).
fn flattenPipeOperands(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(*const Node),
    node: *const Node,
) error{OutOfMemory}!void {
    switch (node.kind) {
        .pipe => |p| {
            try flattenPipeOperands(alloc, out, p.left);
            try out.append(alloc, p.right);
        },
        else => try out.append(alloc, node),
    }
}

/// Flatten a left-leaning `comma(comma(a, b), c)` chain into `[a, b, c]`.
fn flattenCommaOperands(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(*const Node),
    node: *const Node,
) error{OutOfMemory}!void {
    switch (node.kind) {
        .comma => |c| {
            try flattenCommaOperands(alloc, out, c.left);
            try out.append(alloc, c.right);
        },
        else => try out.append(alloc, node),
    }
}

/// Flatten a left-leaning `alternative(alternative(a, b), c)` chain into
/// `[a, b, c]`. Matches the AST parser's accumulation order at
/// `src/ast/parser.zig:198-209`.
fn flattenAlternativeOperands(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(*const Node),
    node: *const Node,
) error{OutOfMemory}!void {
    switch (node.kind) {
        .alternative => |a| {
            try flattenAlternativeOperands(alloc, out, a.left);
            try out.append(alloc, a.right);
        },
        else => try out.append(alloc, node),
    }
}

/// Scan forward from `start` skipping trivia and return the offset of the
/// first byte of a `//` token, or null if the next non-trivia bytes are not
/// `//`. Whitespace between `/` and `/` is NOT allowed by jq's lexer; the
/// two bytes must be contiguous.
fn scanDoubleSlash(src: []const u8, start: u32) ?u32 {
    const off = skipTrivia(src, start);
    if (@as(usize, off) + 1 >= src.len) return null;
    if (src[off] != '/' or src[off + 1] != '/') return null;
    return off;
}

// ── Stage 6 helpers: try/catch, if/elif/else, path() ────────────────────────

/// Scan forward from `start`, skipping trivia, and return the offset of the
/// first byte of the literal keyword `kw`. If the keyword is not found at
/// the next non-trivia position, returns `start` as a defensive fallback —
/// AST well-formedness guarantees the keyword is present for every callsite.
fn scanKeyword(src: []const u8, start: u32, kw: []const u8) u32 {
    const off = skipTrivia(src, start);
    if (@as(usize, off) + kw.len > src.len) return off;
    if (!std.mem.eql(u8, src[off..][0..kw.len], kw)) return off;
    // Require the byte after to be a non-ident byte (so `catchf` doesn't
    // count as `catch`).
    const after: usize = @as(usize, off) + kw.len;
    if (after < src.len and isIdentByte(src[after])) return off;
    return off;
}

/// Recursive helper for `if_expr` emission. Mirrors the legacy
/// `parseIfBody` control flow in `src/query/src/compiler.zig:6467-6522`,
/// including the nested-recursion pattern used for `elif`.
///
/// Parameters:
///   - `if_off`    — offset of the `if` or `elif` keyword that begins this
///     level. Stamps the initial `save_input` emit.
///   - `cond`      — condition AST node.
///   - `then_body` — then-branch AST node.
///   - `elif_chains` — the AST's flat list of `elif` branches at this level
///     and below. When non-empty, the first elif is consumed at THIS level
///     (recursive mirror of legacy).
///   - `else_body` — optional else branch at the deepest level. `null` means
///     no `else` — legacy emits `identity` at end.offset.
fn emitIfBody(
    w: *Walker,
    if_off: u32,
    cond: *const Node,
    then_body: *const Node,
    elif_chains: []const Node.ElifChain,
    else_body: ?*const Node,
) Walker.Error!void {
    // save_input — legacy stamps with last_tok_offset, which is the `if`/
    // `elif` keyword offset (set when parsePrimaryInner/parseIfBody consumed
    // it). For the outer `if`, that's node.span.start. For recursed elif,
    // that's the elif-kw offset the caller computed.
    try w.emit(.save_input, .{ .none = {} }, if_off);

    try w.walk(cond);

    // `then` keyword offset — scanned from cond.span.end forward.
    const then_off = scanKeyword(w.src, cond.span.end, "then");

    const jif_pos = w.raw.items.len;
    try w.emit(.jump_if_false, .{ .index = 0 }, then_off);

    try w.emit(.restore_input, .{ .none = {} }, then_off);

    try w.walk(then_body);

    const jmp_pos = w.raw.items.len;
    // Legacy stamps this `.jump` with last_tok_offset after THEN compiled —
    // i.e. the offset of the then-body's final consumed token. Mirror via
    // w.last_emit_offset.
    const after_then_off = w.last_emit_offset;
    try w.emit(.jump, .{ .index = 0 }, after_then_off);

    // Backpatch jif → raw.len (else-branch entry).
    w.raw.items[jif_pos].operand = .{ .index = @intCast(w.raw.items.len) };

    // restore_input before else-branch, same stamp as the jump above.
    try w.emit(.restore_input, .{ .none = {} }, after_then_off);

    if (elif_chains.len > 0) {
        // Legacy consumes `elif` (last_tok_offset = elif.offset), then
        // recurses into parseIfBody. Mirror by scanning for `elif` from
        // then_body.span.end.
        const elif_off = scanKeyword(w.src, then_body.span.end, "elif");
        const head = elif_chains[0];
        try emitIfBody(
            w,
            elif_off,
            head.cond,
            head.body,
            elif_chains[1..],
            else_body,
        );
    } else if (else_body) |eb| {
        // Legacy: consume `else`, parsePipe(else-body), consume `end`.
        // The `else` / `end` keywords don't stamp emits directly — the
        // else-body's internal emits use their own offsets. But after
        // `end` is consumed, legacy's `last_tok_offset = end.offset` — so
        // any subsequent implicit emit (e.g. the trailing yield_output)
        // picks up that offset. Mirror by bumping `last_emit_offset` to
        // `end.offset` after the walk.
        try w.walk(eb);
        const end_off = scanKeyword(w.src, eb.span.end, "end");
        w.last_emit_offset = end_off;
    } else {
        // No-else form: legacy emits `.identity` stamped with end.offset.
        const end_off = scanKeyword(w.src, then_body.span.end, "end");
        try w.emit(.identity, .{ .none = {} }, end_off);
    }

    // Backpatch jmp → raw.len (past entire else-block).
    w.raw.items[jmp_pos].operand = .{ .index = @intCast(w.raw.items.len) };
}

/// Emit `path(EXPR)` bytecode — legacy `compilePath` at
/// `src/query/src/compiler.zig:4858-4871`:
///   emit path_begin(0)          [stamp=(`.offset]
///   <EXPR>
///   emit path_end               [stamp=`)`.offset]
///   backpatch path_begin → raw.len - 1   (== path_end's IP, pre-fuse)
///
/// `node_span` is the span of the full `path(EXPR)` call — start at `path`
/// ident, end one-past `)`. `(` is scanned from `span.start + 4` (after the
/// `path` keyword). `)` is at `span.end - 1`.
fn emitPathCall(w: *Walker, node_span: ast.Span, arg: *const Node) Walker.Error!void {
    const path_kw_len: u32 = @intCast("path".len);
    const after_kw = node_span.start + path_kw_len;
    const lparen_off = scanForSkipWs(w.src, after_kw, '(') orelse after_kw;
    const rparen_off = if (node_span.end > 0) node_span.end - 1 else node_span.start;

    const begin_ip = w.raw.items.len;
    try w.emit(.path_begin, .{ .index = 0 }, lparen_off);

    try w.walk(arg);

    try w.emit(.path_end, .{ .none = {} }, rparen_off);

    // path_begin's operand points at path_end's raw IP (raw.len - 1 at the
    // moment path_end was emitted). This matches the legacy backpatch at
    // `compiler.zig:4870`.
    w.raw.items[begin_ip].operand = .{ .index = @intCast(w.raw.items.len - 1) };
}

fn base_segment_start(base: *const Node, w: *Walker) usize {
    // Initialize the walker's scan cursor to the end of the base's source
    // span so subsequent suffix scans begin where the base left off. For an
    // `optional{field_access}` base (e.g. `.foo?.bar`), the base span ends
    // past the `?`; the suffix scan correctly picks up from there.
    w.scan_cursor = base.span.end;
    return w.raw.items.len;
}

// ── Stage 4 helpers: variables + patterns ───────────────────────────────────

/// Compute the offset of the ident after the `$` in a `variable_ref` node.
/// The AST records `span.start = $.offset` and `span.end = ident.offset +
/// ident.len` (see `src/ast/parser.zig:685`), and idents have no escapes, so
/// `ident.offset = span.end - name.len`.
fn identOffsetOfVarRef(span: ast.Span, name: []const u8) u32 {
    if (span.end > name.len) return span.end - @as(u32, @intCast(name.len));
    return span.start;
}

/// Look up `name` in the walker's flat scope. Mirrors legacy's
/// `lookupVariable` at `src/query/src/compiler.zig:353`. Since Stage 4 has
/// no sub-scopes, the flat list doubles as the scope chain.
fn lookupVariable(w: *Walker, name: []const u8) ?u32 {
    // Walk in reverse so that a shadowing entry (appended later) wins. The
    // legacy implementation uses `declareVariable` which UPDATES an existing
    // entry in place, preserving insertion order; either order is equivalent
    // here because we also update-in-place when declaring.
    var i = w.scope_vars.items.len;
    while (i > 0) {
        i -= 1;
        const ve = w.scope_vars.items[i];
        if (std.mem.eql(u8, ve.name, name)) return ve.id;
    }
    return null;
}

/// Declare a variable in the current (only) scope, allocating a fresh id.
/// Matches legacy's `declareVariable` at `compiler.zig:312-332`:
///   - If the name already exists in the current scope, REPLACE its id
///     (shadowing); a fresh id is still allocated.
///   - Otherwise append a new entry.
fn declareVariable(w: *Walker, name: []const u8) error{OutOfMemory}!u32 {
    const new_id = w.next_var_id;
    w.next_var_id += 1;
    for (w.scope_vars.items) |*ve| {
        if (std.mem.eql(u8, ve.name, name)) {
            ve.id = new_id;
            return new_id;
        }
    }
    try w.scope_vars.append(w.alloc, .{ .name = name, .id = new_id });
    return new_id;
}

/// Reuse an existing id if the name is already bound in the current scope;
/// otherwise allocate a new one. Matches legacy's `reuseOrDeclareVariable`
/// at `compiler.zig:339-350`. Used for the non-first patterns in a `?//`
/// chain so that shared names map to the same slot.
fn reuseOrDeclareVariable(w: *Walker, name: []const u8) error{OutOfMemory}!u32 {
    for (w.scope_vars.items) |ve| {
        if (std.mem.eql(u8, ve.name, name)) return ve.id;
    }
    return declareVariable(w, name);
}

/// Walk a pattern in left-to-right, depth-first order, allocating a fresh
/// id for every `simple` variable slot. Matches legacy's
/// `scanAndDeclarePattern` / `scanAndDeclarePatternWithComputed` traversal.
/// For object patterns with `$k` shorthand, the key name AND the pattern
/// name are the same string (see AST parser at `src/ast/parser.zig:1336`).
fn declarePatternVars(w: *Walker, pat: ast.Pattern) Walker.Error!void {
    switch (pat) {
        .simple => |name| {
            _ = try declareVariable(w, name);
        },
        .array => |elems| {
            for (elems) |elem| try declarePatternVars(w, elem);
        },
        .object => |fields| {
            for (fields) |field| {
                // Computed keys `({expr}): pat` are Stage 7 scope: they
                // require compiling the key expression (object_construct
                // dynamic keys). Stage 4 rejects so the scaffold boundary
                // stays visible. Simple + static-key objects cover the
                // Stage 4 fixtures.
                switch (field.key) {
                    .static => {},
                    .computed => return error.AstCompilerStageIncomplete,
                }
                try declarePatternVars(w, field.pattern);
            }
        },
    }
}

/// Like `declarePatternVars` but REUSES ids when a name already exists.
/// Mirrors legacy's `scanAndDeclarePatternReuse` at `compiler.zig:443`.
fn declarePatternVarsReuse(w: *Walker, pat: ast.Pattern) Walker.Error!void {
    switch (pat) {
        .simple => |name| {
            _ = try reuseOrDeclareVariable(w, name);
        },
        .array => |elems| {
            for (elems) |elem| try declarePatternVarsReuse(w, elem);
        },
        .object => |fields| {
            for (fields) |field| {
                switch (field.key) {
                    .static => {},
                    .computed => return error.AstCompilerStageIncomplete,
                }
                try declarePatternVarsReuse(w, field.pattern);
            }
        },
    }
}

/// Collect all variable ids referenced by a pattern in iteration order.
/// Mirrors legacy's `collectPatternVarIds` at `compiler.zig:965`.
fn collectPatternVarIds(w: *Walker, pat: ast.Pattern, list: *std.ArrayList(u32)) error{OutOfMemory}!void {
    switch (pat) {
        .simple => |name| {
            // Look up the id assigned during declaration. The walk order here
            // matches the one in `declarePatternVars`, so ids come out in
            // allocation order.
            const id = lookupVariable(w, name) orelse return;
            try list.append(w.alloc, id);
        },
        .array => |elems| {
            for (elems) |elem| try collectPatternVarIds(w, elem, list);
        },
        .object => |fields| {
            for (fields) |field| try collectPatternVarIds(w, field.pattern, list);
        },
    }
}

/// Emit destructuring bytecode for `pat` against the value on the stack.
/// Mirrors legacy's `emitPatternCapture` at
/// `src/query/src/compiler.zig:601-702`. Every emitted instruction is
/// stamped with `last_tok_offset` — the offset of the pattern's closing
/// token (`]`/`}`), or the ident offset for `simple`.
fn emitPatternCapture(w: *Walker, pat: ast.Pattern, last_tok: u32) Walker.Error!void {
    switch (pat) {
        .simple => |name| {
            const id = lookupVariable(w, name) orelse unreachable;
            try w.emit(.capture_variable, .{ .index = @as(i64, @intCast(id)) }, last_tok);
        },
        .array => |elems| {
            try w.emit(.pipe, .{ .none = {} }, last_tok);

            for (elems, 0..) |elem, idx| {
                try w.emit(.save_input, .{ .none = {} }, last_tok);

                const fork_pos = w.raw.items.len;
                try w.emit(.fork_try, .{ .index = 0 }, last_tok);

                try w.emit(.load_index, .{ .index = @as(i64, @intCast(idx)) }, last_tok);

                try w.emit(.pop_try, .{ .none = {} }, last_tok);

                const jump_pos = w.raw.items.len;
                try w.emit(.jump, .{ .index = 0 }, last_tok);

                const catch_ip: u32 = @intCast(w.raw.items.len);
                w.raw.items[fork_pos].operand = .{ .index = @intCast(catch_ip) };
                try w.emit(.push_null, .{ .none = {} }, last_tok);

                const continue_ip: u32 = @intCast(w.raw.items.len);
                w.raw.items[jump_pos].operand = .{ .index = @intCast(continue_ip) };

                try emitPatternCapture(w, elem, last_tok);

                try w.emit(.restore_input, .{ .none = {} }, last_tok);
            }
        },
        .object => |fields| {
            try w.emit(.pipe, .{ .none = {} }, last_tok);

            for (fields) |field| {
                try w.emit(.save_input, .{ .none = {} }, last_tok);

                switch (field.key) {
                    .static => |key_name| {
                        const fork_pos = w.raw.items.len;
                        try w.emit(.fork_try, .{ .index = 0 }, last_tok);

                        const ref = try internStr(&w.intern, w.alloc, key_name);
                        try w.emit(.load_key, .{ .str_ref = ref }, last_tok);

                        try w.emit(.pop_try, .{ .none = {} }, last_tok);

                        const jump_pos = w.raw.items.len;
                        try w.emit(.jump, .{ .index = 0 }, last_tok);

                        const catch_ip: u32 = @intCast(w.raw.items.len);
                        w.raw.items[fork_pos].operand = .{ .index = @intCast(catch_ip) };
                        try w.emit(.push_null, .{ .none = {} }, last_tok);

                        const continue_ip: u32 = @intCast(w.raw.items.len);
                        w.raw.items[jump_pos].operand = .{ .index = @intCast(continue_ip) };
                    },
                    .computed => return error.AstCompilerStageIncomplete,
                }

                try emitPatternCapture(w, field.pattern, last_tok);

                try w.emit(.restore_input, .{ .none = {} }, last_tok);
            }
        },
    }
}

/// Like `emitPatternCapture` but without the try/catch-per-element wrapping.
/// Used inside `?//` alternatives — errors propagate up to the outer
/// `fork_try` in `parseDestructAlt`. Mirrors legacy's
/// `emitPatternCaptureStrict` at `compiler.zig:709-756`.
fn emitPatternCaptureStrict(w: *Walker, pat: ast.Pattern, last_tok: u32) Walker.Error!void {
    switch (pat) {
        .simple => |name| {
            const id = lookupVariable(w, name) orelse unreachable;
            try w.emit(.capture_variable, .{ .index = @as(i64, @intCast(id)) }, last_tok);
        },
        .array => |elems| {
            try w.emit(.pipe, .{ .none = {} }, last_tok);

            for (elems, 0..) |elem, idx| {
                try w.emit(.save_input, .{ .none = {} }, last_tok);
                try w.emit(.load_index, .{ .index = @as(i64, @intCast(idx)) }, last_tok);
                try emitPatternCaptureStrict(w, elem, last_tok);
                try w.emit(.restore_input, .{ .none = {} }, last_tok);
            }
        },
        .object => |fields| {
            try w.emit(.pipe, .{ .none = {} }, last_tok);

            for (fields) |field| {
                try w.emit(.save_input, .{ .none = {} }, last_tok);

                switch (field.key) {
                    .static => |key_name| {
                        const ref = try internStr(&w.intern, w.alloc, key_name);
                        try w.emit(.load_key, .{ .str_ref = ref }, last_tok);
                    },
                    .computed => return error.AstCompilerStageIncomplete,
                }

                try emitPatternCaptureStrict(w, field.pattern, last_tok);
                try w.emit(.restore_input, .{ .none = {} }, last_tok);
            }
        },
    }
}

/// Result of scanning a pattern's source range:
///   - `last_tok_offset` — offset of the pattern's closing token start
///     (`]`/`}` for array/object; the ident byte for `simple`). This is the
///     `ctx.last_tok_offset` that legacy's lexer would land on after
///     consuming the pattern.
///   - `end_after` — byte offset just past the closing token (= one-past
///     `]`/`}` for nested patterns; = ident.end for simple). Used by
///     callers to advance their source cursor.
const PatternLayout = struct {
    last_tok_offset: u32,
    end_after: u32,
};

/// Scan a pattern in source starting at `start` (which must be at or before
/// the first pattern byte). Returns the pattern's layout. The pattern
/// structure (kind + element count) is already known from the AST; this
/// scanner only needs to skip past matching brackets and quoted strings.
fn scanPatternLayout(src: []const u8, start: u32, pat: ast.Pattern) PatternLayout {
    const cursor = skipTrivia(src, start);
    switch (pat) {
        .simple => {
            // `$name` — advance past `$` then the ident characters.
            std.debug.assert(cursor < src.len and src[cursor] == '$');
            const name_start = skipTrivia(src, cursor + 1);
            var i: usize = name_start;
            while (i < src.len and isIdentByte(src[i])) : (i += 1) {}
            return .{
                .last_tok_offset = @intCast(name_start),
                .end_after = @intCast(i),
            };
        },
        .array => {
            std.debug.assert(cursor < src.len and src[cursor] == '[');
            const rb = scanBracketPairEndFrom(src, cursor);
            return .{
                .last_tok_offset = rb,
                .end_after = rb + 1,
            };
        },
        .object => {
            std.debug.assert(cursor < src.len and src[cursor] == '{');
            const rb = scanBracePairEndFrom(src, cursor);
            return .{
                .last_tok_offset = rb,
                .end_after = rb + 1,
            };
        },
    }
}

/// Skip trivia starting at `start`, then consume the literal `as` keyword
/// (exactly two bytes: `a` then `s`) and return the offset just past it.
/// If the expected bytes are not present the original `start` is returned
/// (defensive; the AST's well-formedness guarantees `as` exists for any
/// `as_pattern`/`destruct_alt` node).
fn advancePastAsKeyword(src: []const u8, start: u32) u32 {
    var cursor = skipTrivia(src, start);
    if (@as(usize, cursor) + 2 <= src.len and src[cursor] == 'a' and src[cursor + 1] == 's') {
        cursor += 2;
    }
    return cursor;
}

/// Return true if `c` is a valid identifier continuation character.
fn isIdentByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

/// Given an offset of a `{`, return the offset of the matching `}`.
/// Handles nested braces and `"..."` string literals with escapes. Mirrors
/// `scanBracketPairEndFrom` but for curly braces.
fn scanBracePairEndFrom(src: []const u8, open_lbrace: u32) u32 {
    std.debug.assert(open_lbrace < src.len and src[open_lbrace] == '{');
    var i: usize = open_lbrace + 1;
    var depth: u32 = 1;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '"') {
            i += 1;
            while (i < src.len) : (i += 1) {
                if (src[i] == '\\') {
                    if (i + 1 < src.len) i += 1;
                    continue;
                }
                if (src[i] == '"') break;
            }
            continue;
        }
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return @intCast(i);
        }
    }
    return @intCast(src.len - 1);
}

// ── Stage 7 helpers: object / array / string-interp / format ────────────────

/// Emit the `{__loc__}` / `$__loc__` marker-object opcode sequence. Mirrors
/// `emitLocObject` at `src/query/src/compiler.zig:6586-6605`. All emits are
/// stamped with `stamp`, which is the `last_tok_offset` legacy carried when
/// entering this helper — for `$__loc__` that is the `__loc__` ident offset;
/// for `{__loc__}` it is the `__loc__` ident offset consumed inside the field.
fn emitLocObject(w: *Walker, stamp: u32) Walker.Error!void {
    try w.emit(.object_construct_start, .{ .none = {} }, stamp);

    const file_key = try internStr(&w.intern, w.alloc, "file");
    try w.emit(.push_string, .{ .str_ref = file_key }, stamp);

    const file_val = try internStr(&w.intern, w.alloc, "<top-level>");
    try w.emit(.push_string, .{ .str_ref = file_val }, stamp);

    try w.emit(.object_key, .{ .none = {} }, stamp);

    const line_key = try internStr(&w.intern, w.alloc, "line");
    try w.emit(.push_string, .{ .str_ref = line_key }, stamp);

    try w.emit(.push_int, .{ .int = 1 }, stamp);
    try w.emit(.object_key, .{ .none = {} }, stamp);

    try w.emit(.object_construct_end, .{ .none = {} }, stamp);
}

/// Emit one object field. `cursor` is the walker's running source-byte cursor
/// pointing at (or just before) the field's first token; updated in-place to
/// point just past the field's last token for the outer loop to pick up.
///
/// Mirrors `parseObjectLiteral`'s per-field lowering at
/// `src/query/src/compiler.zig:6836-6903` with careful src_offset parity:
///   - Static key: emit `push_string(key)` stamped with ident/string_lit
///     offset. Legacy's `parseObjectKey` consumes an ident/string_lit and
///     `ctx.last_tok_offset` becomes that token's offset.
///   - `{a}` (shorthand, static): emit `push_string("a")` then `load_key("a")`,
///     both stamped with ident.offset (legacy does not consume any further
///     token before the `load_key` emit — `last_tok_offset` stays at ident).
///   - `{$x}` (dollar shorthand): consume `$` then ident → last_tok_offset =
///     ident.offset. Emit push_string(name) + load_variable(var_id) both at
///     ident.offset, then `object_key`.
///   - `{$x: value}`: read VALUE of $x as key (legacy: load_variable) then
///     parseObjectFieldValue for value, then `object_key`.
///   - `{(expr): value}`: parseObjectKey consumes `(`, parseLogical, `)`.
///     last_tok_offset = `)`.offset. Then `:`, then value. Then `object_key`
///     stamped with value's last token.
///   - `{(expr)}` (computed shorthand): like above but with no colon. Replay
///     the key-producing raw instrs between `save_input` and `load_computed`,
///     all stamped with `)`.offset. Then `object_key` stamped with `)`.offset.
///   - `{"\(.x)": value}`: string-interp key — `compileStringInterpolation`.
///   - `{__loc__}`: bare ident shorthand AST → field_access("__loc__") as
///     VALUE with key ident "__loc__". Compiler path in legacy is
///     `parseObjectLiteral`'s ident branch plus `parseObjectFieldValue`.
fn emitObjectField(
    w: *Walker,
    field: Node.ObjectField,
    cursor: *u32,
) Walker.Error!void {
    const field_start_cursor = cursor.*;

    switch (field.key) {
        .ident => |name| {
            // Two subtleties collide here:
            //   1. `{$x}` and `{$x: expr}` both come through the parser as an
            //      ObjectKey.ident — the AST treats `$x` and `x` uniformly at
            //      the key-ident level. We disambiguate via source: the byte
            //      at `cursor` is `$` iff this is the dollar form.
            //   2. `{__loc__}` and `{__loc__: expr}` are possible. Legacy
            //      hard-codes `__loc__` in the DOLLAR branch only (parsing
            //      `$__loc__`), not in the bare-ident branch.
            const is_dollar = cursor.* < w.src.len and w.src[cursor.*] == '$';

            if (is_dollar) {
                // Consume `$` and the ident name in source.
                cursor.* += 1;
                cursor.* = skipTrivia(w.src, cursor.*);
                const ident_off = cursor.*;
                cursor.* = advancePastIdentBytes(w.src, ident_off);

                // Is this `{$x: VALUE}` or shorthand `{$x}`?
                const after = skipTrivia(w.src, cursor.*);
                const is_pair = after < w.src.len and w.src[after] == ':';

                if (is_pair) {
                    // `{$x: VALUE}` — KEY is the VALUE of $x. Legacy at
                    // compiler.zig:6847-6855 emits `load_variable($x)` (or
                    // `emitLocObject` for __loc__) stamped with ident offset.
                    if (std.mem.eql(u8, name, "__loc__")) {
                        try emitLocObject(w, ident_off);
                    } else {
                        const var_id = lookupVariable(w, name) orelse {
                            w.compile_err = .{
                                .kind = .query_syntax_error,
                                .offset = ident_off,
                                .len = 0,
                            };
                            return error.AstCompileError;
                        };
                        try w.emit(
                            .load_variable,
                            .{ .index = @as(i64, @intCast(var_id)) },
                            ident_off,
                        );
                    }
                    // Consume `:` then parse value. Advance cursor past the
                    // value's source span so the outer loop's comma scan
                    // finds the field separator after the value, not somewhere
                    // inside it.
                    cursor.* = field.value.span.end;
                    try w.walk(field.value);
                } else {
                    // Shorthand `{$x}` — key is literal "x", value is $x.
                    const key_ref = try internStr(&w.intern, w.alloc, name);
                    try w.emit(.push_string, .{ .str_ref = key_ref }, ident_off);
                    if (std.mem.eql(u8, name, "__loc__")) {
                        try emitLocObject(w, ident_off);
                    } else {
                        const var_id = lookupVariable(w, name) orelse {
                            w.compile_err = .{
                                .kind = .query_syntax_error,
                                .offset = ident_off,
                                .len = 0,
                            };
                            return error.AstCompileError;
                        };
                        try w.emit(
                            .load_variable,
                            .{ .index = @as(i64, @intCast(var_id)) },
                            ident_off,
                        );
                    }
                }

                try w.emit(.object_key, .{ .none = {} }, w.last_emit_offset);
            } else {
                // Bare-ident key. Static key, optionally followed by `:` and
                // value, or shorthand `{a}` → `{a: .a}`.
                const ident_off = cursor.*;
                cursor.* = advancePastIdentBytes(w.src, ident_off);
                const name_len: u32 = @intCast(name.len);
                _ = name_len;

                const key_ref = try internStr(&w.intern, w.alloc, name);
                try w.emit(.push_string, .{ .str_ref = key_ref }, ident_off);

                const after = skipTrivia(w.src, cursor.*);
                const is_pair = after < w.src.len and w.src[after] == ':';

                if (is_pair) {
                    // `{a: VALUE}`. Advance cursor past the value's span so
                    // the outer loop's comma scan doesn't trip on bytes
                    // inside the value.
                    cursor.* = field.value.span.end;
                    try w.walk(field.value);
                } else {
                    // `{a}` shorthand — legacy at compiler.zig:6880-6882 emits
                    // `load_key(name)` stamped with last_tok_offset (= ident
                    // offset). The AST stores `field.value` as a synthesized
                    // `field_access(name)` — but we do NOT walk that here;
                    // `field_access.span.start` is the same ident byte position
                    // so it would stamp `load_key` with the same offset, but
                    // we prefer the explicit emission to keep stamp policy
                    // obvious and avoid any walker-drift.
                    try w.emit(.load_key, .{ .str_ref = key_ref }, ident_off);
                }

                try w.emit(.object_key, .{ .none = {} }, w.last_emit_offset);
            }
        },
        .string => |content| {
            // `"literal"` key. Legacy `parseObjectKey` at compiler.zig:6924-
            // 6931 consumes string_lit → last_tok_offset = `"`.offset, then
            // emits `push_string(decoded)`.
            const quote_off = cursor.*;
            const key_ref = try internStr(&w.intern, w.alloc, content);
            try w.emit(.push_string, .{ .str_ref = key_ref }, quote_off);

            // Advance cursor past the closing `"`.
            cursor.* = skipStringLiteral(w.src, quote_off);

            const after = skipTrivia(w.src, cursor.*);
            if (after < w.src.len and w.src[after] == ':') {
                cursor.* = field.value.span.end;
                try w.walk(field.value);
            } else {
                // `{"a"}` shorthand — legacy emits `load_key(decoded_key)`
                // stamped with `"`.offset. Same as ident branch above.
                try w.emit(.load_key, .{ .str_ref = key_ref }, quote_off);
            }
            try w.emit(.object_key, .{ .none = {} }, w.last_emit_offset);
        },
        .expr => |key_node| {
            // Two variants, distinguished by AST shape:
            //   (1) `{(expr): value}` — the parser's `parseObjectKey`
            //       `.lparen` branch produces ObjectKey.expr; the value comes
            //       next via `parseObjectFieldValue`. Legacy also uses this
            //       straight `(expr): value` path at compiler.zig:6916-6923.
            //   (2) `{"\(.x)": value}` — string-interp key. Parser
            //       `parseObjectKey` `.string_part` branch produces
            //       ObjectKey.expr wrapping a `string_interp` node.
            //
            // Legacy's dynamic-key-replay (`save_input`/<key>/`load_computed`)
            // ONLY fires for the SHORTHAND (no colon) form:
            //   `{(expr)}` or `{"\(.x)"}` — both implicit-self-key forms.
            // With a `:` present, the key instrs push a string onto the
            // value-stack which `object_key` pops, and the value is compiled
            // straight after. No replay.
            //
            // Since the AST's ObjectField always has a value (parser.zig:722-
            // 732 makes the value mandatory via parseObjectFieldValue), we
            // never see the shorthand form here. BUT: for
            // `{(expr)}`/`{"\(.x)"}` jq's legacy compiler special-cases the
            // "no colon" path via peek in parseObjectLiteral. If the AST
            // parser emits a synthesized value for shorthand forms, this
            // branch handles them transparently. Today the AST parser does
            // NOT accept this shorthand: `parseObjectField` unconditionally
            // expects `:` (parser.zig:725). So only the (1) shape reaches us
            // here with a user-written colon.
            //
            // Stamp policy: legacy's `parseObjectKey` `.lparen` branch
            // consumes `(`, parseLogical, `)` — so last_tok_offset =
            // `)`.offset at key-end. Then `:` is consumed →
            // last_tok_offset = `:`.offset. Then value emits update
            // last_tok_offset. Finally `object_key` stamps with the value's
            // last token. Our walker's `w.last_emit_offset` tracks the most
            // recent emit's stamp — which for the key subtree ends at the
            // key's last-emit offset, not `)`. But the `object_key` stamp
            // comes from the VALUE phase in this branch, so no drift.
            //
            // For `{"\(.x)": v}`: parser produces ObjectKey.expr wrapping
            // string_interp. We walk that node; its emits go to the raw
            // buffer the same as any other. Then colon is located, value is
            // compiled, object_key emitted with value's last stamp.

            // Scan the key's source extent so we can advance the cursor past
            // `)` (for `(expr)`) or `"` (for interp key).
            const first_byte = if (cursor.* < w.src.len) w.src[cursor.*] else 0;
            if (first_byte == '(') {
                // `(expr)` key — walk the inner expression.
                try w.walk(key_node);
                // Advance cursor past the matching `)`.
                const rparen = scanParenPairEndFrom(w.src, cursor.*);
                cursor.* = rparen + 1;
            } else {
                // `"...interp..."` key — walk the string_interp node; it
                // covers the entire span from opening `"` through closing `"`.
                try w.walk(key_node);
                cursor.* = key_node.span.end;
            }

            const after = skipTrivia(w.src, cursor.*);
            if (after < w.src.len and w.src[after] == ':') {
                // `{(expr): value}` or `{"\(.x)": value}` — value emits.
                cursor.* = field.value.span.end;
                try w.walk(field.value);
                try w.emit(.object_key, .{ .none = {} }, w.last_emit_offset);
            } else {
                // Shorthand — replay key subtree between save_input and
                // load_computed. Not reachable with today's AST parser, but
                // kept here as the byte-identical port of legacy's
                // compiler.zig:6884-6894 for forward-compat when the parser
                // gains shorthand-expr-key support.
                return error.AstCompilerStageIncomplete;
            }
        },
    }
    _ = field_start_cursor;
}

/// Emit a `string_interp` or interp-format `format_string` parts sequence.
/// When `format_bid` is `null`, this mirrors `compileStringInterpolation`
/// with no format; when non-null, each interpolation expression is routed
/// through `call_builtin(format_bid)` before `tostring`.
///
/// `node_span.start` holds the `first_part_tok.offset` (parser.zig:959 /
/// :955), which is the byte AFTER the opening `"`. We drive the source
/// cursor from that position.
fn emitStringInterp(
    w: *Walker,
    node_span: ast.Span,
    parts: []const Node.StringPart,
    format_bid: ?types.BuiltinId,
) Walker.Error!void {
    // Legacy's initial `push_string(first_literal)` stamp is
    // first_part_tok.offset.
    const content_start = node_span.start;
    var current_stamp: u32 = content_start;
    var cursor: u32 = content_start;

    // parts[0] is always a literal (possibly empty). Emit push_string of it.
    // Legacy uses `internDecodedStr(raw)`; AST pre-decodes in decodeString so
    // the bytes identical via plain `internStr`.
    const first = parts[0].literal;
    const first_ref = try internStr(&w.intern, w.alloc, first);
    try w.emit(.push_string, .{ .str_ref = first_ref }, current_stamp);

    // Advance cursor past the first literal's source bytes (scanning stops
    // at `\(` or `"`). For string_interp the first literal ends at `\(`.
    cursor = scanStringSegmentEnd(w.src, cursor);

    var i: usize = 1;
    while (i < parts.len) : (i += 1) {
        switch (parts[i]) {
            .expr => |expr| {
                // Legacy save_input stamp = last_tok_offset BEFORE walking the
                // expr: for iter 1 that's string_part.offset (first content
                // byte); for subsequent iters it's the previous `)`.offset.
                try w.emit(.save_input, .{ .none = {} }, current_stamp);

                try w.walk(expr);

                // After walking expr, last_emit_offset = expr's last emit.
                const expr_last = w.last_emit_offset;
                try w.emit(.pipe, .{ .none = {} }, expr_last);

                if (format_bid) |bid| {
                    try w.emit(
                        .call_builtin,
                        .{ .index = @intFromEnum(bid) },
                        expr_last,
                    );
                    try w.emit(.pipe, .{ .none = {} }, expr_last);
                }

                try w.emit(
                    .call_builtin,
                    .{ .index = @intFromEnum(types.BuiltinId.tostring) },
                    expr_last,
                );
                try w.emit(.add, .{ .none = {} }, expr_last);

                // Advance cursor to just past the matching `)` of the
                // interpolation. Legacy's nextToken on `)` sets
                // last_tok_offset = `)`.offset.
                const rparen_off = scanForSkipWs(w.src, expr.span.end, ')') orelse expr.span.end;
                current_stamp = rparen_off;
                cursor = rparen_off + 1;

                try w.emit(.restore_input, .{ .none = {} }, current_stamp);
            },
            .literal => |content| {
                // Middle or trailing literal. Legacy scans string tail via
                // `lex.scanStringTail` — which does NOT update
                // `last_tok_offset`. So the push_string + add both remain
                // stamped at the prior `)`.offset == current_stamp.
                if (content.len > 0) {
                    const ref = try internStr(&w.intern, w.alloc, content);
                    try w.emit(.push_string, .{ .str_ref = ref }, current_stamp);
                    try w.emit(.add, .{ .none = {} }, current_stamp);
                }
                cursor = scanStringSegmentEnd(w.src, cursor);
            },
        }
    }
}

/// Scan source from `start` (just past an opening `"` or a closing `)`) until
/// the next `\(` or closing `"`. Returns the offset of the START of that
/// delimiter. Handles JSON-style `\"`, `\\` and other escape sequences by
/// skipping the backslash+next byte. Used to walk past a string-interpolation
/// literal segment's source bytes.
fn scanStringSegmentEnd(src: []const u8, start: u32) u32 {
    var i: usize = start;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\') {
            if (i + 1 >= src.len) return @intCast(i);
            if (src[i + 1] == '(') return @intCast(i);
            i += 2; // skip backslash + next byte
            continue;
        }
        if (c == '"') return @intCast(i);
        i += 1;
    }
    return @intCast(src.len);
}

/// Locate the opening `"` after `@name` starting at `@`.offset. Scans past
/// the `@` byte, past the format-name ident bytes, past whitespace, and
/// returns the offset of the `"` byte. Used for shape (A) of format_string
/// (the zero-interp `@name "literal"` path).
fn scanOpeningQuoteAfterFormat(src: []const u8, at_off: u32) u32 {
    var i: u32 = at_off;
    if (i < src.len and src[i] == '@') i += 1;
    // Skip ident bytes.
    while (i < src.len and isIdentByte(src[i])) : (i += 1) {}
    // Skip trivia (whitespace + comments).
    i = skipTrivia(src, i);
    return i;
}

/// Advance past an identifier starting at `start`. Returns the offset of the
/// first non-ident byte (or src.len).
fn advancePastIdentBytes(src: []const u8, start: u32) u32 {
    var i: usize = start;
    while (i < src.len and isIdentByte(src[i])) : (i += 1) {}
    return @intCast(i);
}

/// Given an offset of an opening `"`, return the offset one-past the closing
/// `"`. Handles JSON escape sequences (`\"`, `\\`, `\uXXXX`, etc.) by skipping
/// the backslash and its paired byte.
fn skipStringLiteral(src: []const u8, quote_off: u32) u32 {
    std.debug.assert(quote_off < src.len and src[quote_off] == '"');
    var i: usize = quote_off + 1;
    while (i < src.len) {
        if (src[i] == '\\') {
            if (i + 1 < src.len) i += 2 else i += 1;
            continue;
        }
        if (src[i] == '"') return @intCast(i + 1);
        i += 1;
    }
    return @intCast(src.len);
}

/// Given an offset of an opening `(`, return the offset of the matching `)`.
/// Handles nested parens and `"..."` string literals with escapes.
fn scanParenPairEndFrom(src: []const u8, open_lparen: u32) u32 {
    std.debug.assert(open_lparen < src.len and src[open_lparen] == '(');
    var i: usize = open_lparen + 1;
    var depth: u32 = 1;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '"') {
            i += 1;
            while (i < src.len) : (i += 1) {
                if (src[i] == '\\') {
                    if (i + 1 < src.len) i += 1;
                    continue;
                }
                if (src[i] == '"') break;
            }
            continue;
        }
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) return @intCast(i);
        }
    }
    return @intCast(src.len - 1);
}

/// Map a format name (without the leading `@`) to its BuiltinId. Mirrors
/// `formatBuiltinId` at `src/query/src/compiler.zig:5698-5710`.
fn formatBuiltinId(name: []const u8) ?types.BuiltinId {
    if (std.mem.eql(u8, name, "text")) return .format_text;
    if (std.mem.eql(u8, name, "json")) return .format_json;
    if (std.mem.eql(u8, name, "csv")) return .format_csv;
    if (std.mem.eql(u8, name, "tsv")) return .format_tsv;
    if (std.mem.eql(u8, name, "html")) return .format_html;
    if (std.mem.eql(u8, name, "uri")) return .format_uri;
    if (std.mem.eql(u8, name, "urid")) return .format_urid;
    if (std.mem.eql(u8, name, "sh")) return .format_sh;
    if (std.mem.eql(u8, name, "base64")) return .format_base64;
    if (std.mem.eql(u8, name, "base64d")) return .format_base64d;
    return null;
}

// ── insertRawInstr ────────────────────────────────────────────────────────────

/// Insert `instr` at position `pos`, shifting later instructions forward by
/// one slot and patching all jump/fork IP operands that pointed STRICTLY past
/// `pos`. Mirrors `compiler.zig:insertRawInstr` behavior so the final IP
/// layout is identical.
fn insertRawInstr(w: *Walker, pos: usize, instr: RawInstr) error{OutOfMemory}!void {
    try w.raw.append(w.alloc, .{ .op = .identity, .operand = .{ .none = {} } });
    var i = w.raw.items.len - 1;
    while (i > pos) : (i -= 1) {
        w.raw.items[i] = w.raw.items[i - 1];
    }
    w.raw.items[pos] = instr;
    const p = @as(u32, @intCast(pos));
    for (w.raw.items) |*r| {
        if (r.op.hasIpOperand()) {
            if (r.operand.index > p) r.operand.index += 1;
        } else if (r.op.hasSentinelIpOperand()) {
            if (r.operand.index > 0 and r.operand.index > p) r.operand.index += 1;
        }
    }
}

// ── Intern / fuse ─────────────────────────────────────────────────────────────

fn internStr(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}!StrRef {
    const off: u32 = @intCast(buf.items.len);
    try buf.appendSlice(alloc, s);
    return .{ .offset = off, .len = @intCast(s.len) };
}

/// Append a dot-joined path from `keys` into `buf`, reading key bytes from a
/// pre-taken snapshot of `buf`. Mirrors `compiler.zig:internPath`.
fn internPath(
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    keys: []const StrRef,
    src: []const u8,
) error{OutOfMemory}!StrRef {
    const off: u32 = @intCast(buf.items.len);
    for (keys, 0..) |ref, i| {
        if (i > 0) try buf.append(alloc, '.');
        try buf.appendSlice(alloc, src[ref.offset..][0..ref.len]);
    }
    return .{ .offset = off, .len = @intCast(buf.items.len - off) };
}

/// Fuse pass: collapse `load_key; pipe; load_key; ...` chains into a single
/// `load_path` with a dot-joined key string. Mirrors `compiler.zig:fuse` for
/// Stage 2's instruction subset.
fn fuse(
    alloc: std.mem.Allocator,
    raw: []const RawInstr,
    intern: *std.ArrayList(u8),
) error{OutOfMemory}!Compiled {
    var fused = std.ArrayList(RawInstr){};
    defer fused.deinit(alloc);

    var fused_src_offsets = std.ArrayList(u32){};
    defer fused_src_offsets.deinit(alloc);

    var index_map = std.ArrayList(u32){};
    defer index_map.deinit(alloc);
    try index_map.ensureTotalCapacity(alloc, raw.len + 1);

    var i: usize = 0;
    while (i < raw.len) {
        index_map.appendAssumeCapacity(@intCast(fused.items.len));

        if (raw[i].op == .load_key) {
            var keys = std.ArrayList(StrRef){};
            defer keys.deinit(alloc);

            try keys.append(alloc, raw[i].operand.str_ref);
            var j = i + 1;
            while (j + 1 < raw.len and raw[j].op == .pipe and raw[j + 1].op == .load_key) {
                try keys.append(alloc, raw[j + 1].operand.str_ref);
                j += 2;
            }

            const ref: StrRef = if (keys.items.len == 1)
                keys.items[0]
            else blk: {
                const src_snap = intern.items;
                break :blk try internPath(intern, alloc, keys.items, src_snap);
            };

            const op: Instruction.Op = if (keys.items.len == 1) .load_key else .load_path;
            try fused.append(alloc, RawInstr{
                .op = op,
                .operand = .{ .str_ref = ref },
                .src_offset = raw[i].src_offset,
            });
            try fused_src_offsets.append(alloc, raw[i].src_offset);

            var k = i + 1;
            while (k < j) : (k += 1) {
                index_map.appendAssumeCapacity(@intCast(fused.items.len - 1));
            }
            i = j;
        } else {
            try fused.append(alloc, raw[i]);
            try fused_src_offsets.append(alloc, raw[i].src_offset);
            i += 1;
        }
    }

    index_map.appendAssumeCapacity(@intCast(fused.items.len));

    const string_buf = try intern.toOwnedSlice(alloc);
    errdefer alloc.free(string_buf);

    const instructions = try alloc.alloc(Instruction, fused.items.len);
    errdefer alloc.free(instructions);

    for (fused.items, instructions) |r, *out| {
        out.* = .{
            .op = r.op,
            .operand = switch (r.op) {
                .push_null, .push_current, .identity, .negate, .pipe => .{ .none = {} },
                .push_bool => .{ .bool = r.operand.bool },
                .push_int => .{ .int = r.operand.int },
                .push_float => .{ .float = r.operand.float },
                .push_string, .load_key, .load_path => .{ .str_ref = .{
                    .offset = r.operand.str_ref.offset,
                    .len = r.operand.str_ref.len,
                } },
                .call_builtin => .{ .index = r.operand.index },
                .load_index => .{ .index = r.operand.index },
                .each => .{ .none = {} },
                .slice => .{ .slice_args = r.operand.slice_args },
                .fork_try => blk: {
                    // fork_try's operand is a catch_ip (0 sentinel → catch-
                    // less). Stage 2 always uses the 0 sentinel; pass it
                    // through unchanged. Later stages will map non-zero IPs
                    // through index_map like the legacy fuse does.
                    const idx_usize: usize = @intCast(r.operand.index);
                    const mapped: i64 = if (r.operand.index > 0)
                        @intCast(index_map.items[idx_usize])
                    else
                        0;
                    break :blk .{ .index = mapped };
                },
                .pop_try => .{ .none = {} },
                .yield_output => .{ .none = {} },
                // Stage 3: `fork` and `jump` carry raw-IP operands that must be
                // remapped through index_map after load_key/load_path fusion.
                // Mirrors `src/query/src/compiler.zig:7427-7431, 7482-7486`.
                .fork, .jump => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                // Stage 4: variable + destructuring opcodes. Legacy's fuse
                // passes these operands through with the same layout as
                // shown at `src/query/src/compiler.zig:7392` (index) and
                // `:7432-7433` (none). No IP remapping is needed because
                // none of these opcodes carry an instruction pointer.
                .capture_variable, .load_variable, .pop_variable => .{ .index = r.operand.index },
                .save_input, .restore_input, .backtrack => .{ .none = {} },
                // Stage 5: arithmetic, comparison, logical, negate — all
                // take a none-operand (operands are on the value stack).
                // Mirrors `src/query/src/compiler.zig:7408-7422`.
                .add, .sub, .mul, .div, .mod => .{ .none = {} },
                .eq, .ne, .lt, .le, .gt, .ge => .{ .none = {} },
                .and_op, .or_op, .not => .{ .none = {} },
                // Stage 5: jump_if_false carries a raw-IP operand that must
                // be remapped through index_map (same treatment as .jump).
                .jump_if_false => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                // Stage 5: fork_alt uses sentinel-0 semantics like fork_try,
                // but also always fires on exhaustion. Mirror the legacy
                // remap at `src/query/src/compiler.zig:7442-7446`.
                .fork_alt => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const mapped: i64 = if (r.operand.index > 0)
                        @intCast(index_map.items[idx_usize])
                    else
                        0;
                    break :blk .{ .index = mapped };
                },
                // Stage 6: path_begin carries a raw-IP operand pointing at
                // its paired path_end that must be remapped through
                // index_map. Mirrors `src/query/src/compiler.zig:7469-7473`.
                .path_begin => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .path_end => .{ .none = {} },
                // Stage 7: array_collect_start carries a raw-IP operand
                // pointing at its paired `array_collect_end` that must be
                // remapped through index_map. Mirrors
                // `src/query/src/compiler.zig:7434-7439`.
                .array_collect_start => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .array_collect_end => .{ .none = {} },
                // Stage 7: object-construct opcodes carry no operand.
                // Mirrors `src/query/src/compiler.zig:7423-7425`.
                .object_construct_start,
                .object_key,
                .object_construct_end,
                => .{ .none = {} },
                // Stage 7: load_computed carries no operand. Legacy at
                // `src/query/src/compiler.zig:7400`.
                .load_computed => .{ .none = {} },
                else => .{ .none = {} },
            },
        };
    }

    const function_defs = try alloc.alloc(types.FunctionDef, 0);
    errdefer alloc.free(function_defs);

    const external_var_ids = try alloc.alloc(u32, 0);
    errdefer alloc.free(external_var_ids);

    const source_map = try fused_src_offsets.toOwnedSlice(alloc);
    errdefer alloc.free(source_map);

    return Compiled{
        .instructions = instructions,
        .function_table = function_defs,
        .string_buf = string_buf,
        .external_var_ids = external_var_ids,
        .source_map = source_map,
        .regex_pool = regex_mod.RegexPool.init(alloc),
        .prefilter = null,
    };
}

// ── Tests: Stage 1/2 sanity checks. The full equivalence harness lives at
//    `tests/ast_compile_equiv.zig` and is exercised via
//    `zig build ast-compile-equiv`. ────────────────────────────────────────────

test "walker: identity emits push_current + yield_output" {
    const alloc = std.testing.allocator;
    var result = try compile(alloc, ".", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    const ins = result.ok.instructions;
    try std.testing.expectEqual(@as(usize, 2), ins.len);
    try std.testing.expectEqual(Instruction.Op.push_current, ins[0].op);
    try std.testing.expectEqual(Instruction.Op.yield_output, ins[1].op);
}

test "walker: recurse emits call_builtin(recurse)" {
    const alloc = std.testing.allocator;
    var result = try compile(alloc, "..", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    const ins = result.ok.instructions;
    try std.testing.expectEqual(Instruction.Op.call_builtin, ins[0].op);
    try std.testing.expectEqual(
        @as(i64, @intFromEnum(types.BuiltinId.recurse)),
        ins[0].operand.index,
    );
}

test "walker: negative integer emits push_int + negate" {
    const alloc = std.testing.allocator;
    var result = try compile(alloc, "-42", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    const ins = result.ok.instructions;
    try std.testing.expectEqual(Instruction.Op.push_int, ins[0].op);
    try std.testing.expectEqual(@as(i64, 42), ins[0].operand.int);
    try std.testing.expectEqual(Instruction.Op.negate, ins[1].op);
}

test "walker: pipe emits <A> pipe <B> (Stage 3)" {
    const alloc = std.testing.allocator;
    var result = try compile(alloc, ". | .", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    const ins = result.ok.instructions;
    // push_current, pipe, push_current, yield_output.
    try std.testing.expectEqual(@as(usize, 4), ins.len);
    try std.testing.expectEqual(Instruction.Op.push_current, ins[0].op);
    try std.testing.expectEqual(Instruction.Op.pipe, ins[1].op);
    try std.testing.expectEqual(Instruction.Op.push_current, ins[2].op);
    try std.testing.expectEqual(Instruction.Op.yield_output, ins[3].op);
}

test "walker: comma chain emits FORK/JUMP pattern (Stage 3)" {
    const alloc = std.testing.allocator;
    var result = try compile(alloc, "1, 2", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    const ins = result.ok.instructions;
    // FORK(3), push_int(1), JUMP(4), push_int(2), yield_output.
    try std.testing.expectEqual(@as(usize, 5), ins.len);
    try std.testing.expectEqual(Instruction.Op.fork, ins[0].op);
    try std.testing.expectEqual(Instruction.Op.push_int, ins[1].op);
    try std.testing.expectEqual(Instruction.Op.jump, ins[2].op);
    try std.testing.expectEqual(Instruction.Op.push_int, ins[3].op);
    try std.testing.expectEqual(Instruction.Op.yield_output, ins[4].op);
}

test "walker: .foo emits load_key" {
    const alloc = std.testing.allocator;
    var result = try compile(alloc, ".foo", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    const ins = result.ok.instructions;
    try std.testing.expectEqual(@as(usize, 2), ins.len);
    try std.testing.expectEqual(Instruction.Op.load_key, ins[0].op);
}

test "walker: .[0] emits load_index" {
    const alloc = std.testing.allocator;
    var result = try compile(alloc, ".[0]", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    const ins = result.ok.instructions;
    try std.testing.expectEqual(@as(usize, 2), ins.len);
    try std.testing.expectEqual(Instruction.Op.load_index, ins[0].op);
    try std.testing.expectEqual(@as(i64, 0), ins[0].operand.index);
}

test "walker: .[] emits each" {
    const alloc = std.testing.allocator;
    var result = try compile(alloc, ".[]", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    const ins = result.ok.instructions;
    try std.testing.expectEqual(Instruction.Op.each, ins[0].op);
}

test "walker: .foo? emits fork_try/load_key/pop_try" {
    const alloc = std.testing.allocator;
    var result = try compile(alloc, ".foo?", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    const ins = result.ok.instructions;
    try std.testing.expectEqual(Instruction.Op.fork_try, ins[0].op);
    try std.testing.expectEqual(Instruction.Op.load_key, ins[1].op);
    try std.testing.expectEqual(Instruction.Op.pop_try, ins[2].op);
}

test "walker: .foo.bar fuses to load_path" {
    const alloc = std.testing.allocator;
    var result = try compile(alloc, ".foo.bar", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    const ins = result.ok.instructions;
    try std.testing.expectEqual(@as(usize, 2), ins.len);
    try std.testing.expectEqual(Instruction.Op.load_path, ins[0].op);
}
