//! AST-walk compile pipeline — Phase 2 (Stage 0 + Stage 1 + Stage 2).
//!
//! Goal: walk the `src/ast/parser.zig`-produced AST and emit bytecode byte-for-byte
//! equivalent to the legacy token-driven compiler at `src/query/src/compiler.zig`.
//! This file is the future replacement for that compiler; for now it covers only
//! the scope documented in `research/phase-2-ast-walk-plan.md` §4 Stage 0/1/2:
//!   - `.literal` (int, float, string, bool, null)
//!   - `.identity` (bare `.`)
//!   - `.recurse` (`..` operator → `call_builtin(recurse)`)
//!   - `.unary_neg` over a numeric literal (bare negative literals)
//!   - `.field_access` — `.foo`
//!   - `.index_access` — `.[n]`
//!   - `.iterate` — `.[]`
//!   - `.slice` — `.[a:b]`, `.[:b]`, `.[a:]`, `.[:]`
//!   - `.optional` — `expr?`
//!   - `.suffix` — `.a.b`, `.a[0]`, `.a[]`, `.a?.b`, etc.
//!
//! Every other node kind returns `error.AstCompilerStageIncomplete`. This is NOT
//! a workaround — it is the scaffold boundary, to be removed as later stages
//! (3–13) extend coverage. See the plan doc for the full stage breakdown.
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
    };
    defer walker.raw.deinit(alloc);
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
                // Stage 1 supports ONLY `unary_neg` wrapping a literal — the
                // bare-negative-literal case (e.g. `-1`, `-0.5`). The legacy
                // compiler at compiler.zig:5834 emits:
                //     push_<num>(N) [src_offset = literal_offset]
                //     negate        [src_offset = literal_offset]
                // because `ctx.last_tok_offset` after recursing through
                // `parsePrimary` sits on the numeric literal. The operand's
                // `span.start` is that same literal offset, so we reuse it
                // for byte-identical emission.
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
                        else => return error.AstCompilerStageIncomplete,
                    },
                    else => return error.AstCompilerStageIncomplete,
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

            // ── Scaffold boundary: every other kind is a future stage. ──
            .func_def,
            .alternative,
            .or_expr,
            .and_expr,
            .comparison,
            .arithmetic,
            .as_pattern,
            .destruct_alt,
            .paren,
            .variable_ref,
            .array_construct,
            .object_construct,
            .string_interp,
            .format_string,
            .builtin_call,
            .func_call,
            .if_expr,
            .try_catch,
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

fn base_segment_start(base: *const Node, w: *Walker) usize {
    // Initialize the walker's scan cursor to the end of the base's source
    // span so subsequent suffix scans begin where the base left off. For an
    // `optional{field_access}` base (e.g. `.foo?.bar`), the base span ends
    // past the `?`; the suffix scan correctly picks up from there.
    w.scan_cursor = base.span.end;
    return w.raw.items.len;
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
