//! AST-walk compile pipeline — Phase 2 (Stage 0 + Stage 1 + Stage 2 + Stage 3 + Stage 4 + Stage 5 + Stage 6 + Stage 7 + Stage 8 + Stage 9 + Stage 10a + Stage 10b + Stage 10c + Stage 11).
//!
//! Stage 10 is split into multiple partials because the total scope (reduce /
//! foreach / label / break + 11+ generator/reducing builtins) is too large to
//! land byte-identically in a single commit. Stage 10a covered the builtin
//! subset whose emission is a straight `( arg )` descent with no EXPR-after-INIT
//! reorder and no variable-id bookkeeping beyond what Stage 4/9 already
//! provide:
//!
//!   - `select(f)` — predicate filter (save_input + cond + jif/restore/jump/backtrack)
//!   - `map(f)` — collect `[.[] | f]` via array_collect_start/each/arg/yield/end
//!   - `map_values(f)` — filter-arg builtin (`map_values_` opcode)
//!   - `walk(f)` — walk_start/arg/walk_end bracketed recursion
//!   - `while(cond; update)` — loop_top/save/cond/jif/restore/yield/update/pipe/jump
//!   - `until(cond; update)` — loop_top/save/cond/jif/restore/jump_done/restore/update/pipe/jump
//!   - `repeat(f)` — loop_top/yield/f/pipe/jump (infinite; bounded by label/first/limit)
//!   - `any`/`all` — 0-arg (call_builtin), 1-arg (`[.[] | f]` desugar), 2-arg (generator;cond)
//!   - `add(f)` — save_input + collect + pipe + call_builtin(add) + restore_input
//!   - `first(f)` — limit(1;f) fast path: push_int(1) + limit_start/arg/yield
//!   - `last(f)` — collect + pipe + load_index(-1)
//!
//! Stage 10b — landed here — covers the builtins that require EXPR-after-INIT
//! reorder, hidden var-id allocation in lock-step with legacy, or label-frame
//! emission:
//!
//!   - `reduce E as P (INIT; UPDATE)` — saved_input + acc hidden vars,
//!       EXPR captured + spliced after INIT via rebaseExprBuf.
//!   - `foreach E as P (INIT; UPDATE [; EXTRACT])` — as reduce but with an
//!       array_collect wrapper + per-iteration yield.
//!   - `label $name | body` + `break $name` — label_begin/label exit-ip +
//!       load_variable/break_op with compile-time label-var verification.
//!   - `range(hi)` / `range(lo; hi)` / `range(lo; hi; step)` — parseArgToArray
//!       per arg + Cartesian-product rangeN_gen builtin + each.
//!   - `limit(n; f)` / `skip(n; f)` / `nth(n; f)` — hidden input_var +
//!       parseArgToArray(n) + each + counter-gated {limit,skip,nth}_start.
//!
//! Stage 10c will land del/pick/INDEX/IN/JOIN once the reduce machinery here
//! is verified against the harness.
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
//!   - `.builtin_call("path", [EXPR])` — Stage 6
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
const prefilter_mod = @import("prefilter");
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
    /// Sparser raw-byte prefilter — populated at compile time when the source
    /// matches the `select(PATH | regex_builtin("lit"))` idiom. `null`
    /// otherwise. Shape-equivalent to `src/query/src/compiler.zig:Compiled`'s
    /// `prefilter` field; the legacy compiler and the AST walker share
    /// `prefilter_mod.harvestFromAstRoot` so the two paths produce identical
    /// group lists by construction.
    prefilter: ?prefilter_mod.PrefilterSet,

    pub fn deinit(c: *Compiled, alloc: std.mem.Allocator) void {
        alloc.free(c.instructions);
        alloc.free(c.string_buf);
        alloc.free(c.source_map);
        alloc.free(c.external_var_ids);
        c.regex_pool.deinit();
        if (c.prefilter) |*p| p.deinit();
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
        .func_table = .{},
        .filter_bindings = .{},
        .regex_pool = regex_mod.RegexPool.init(alloc),
    };
    defer walker.raw.deinit(alloc);
    defer walker.scope_vars.deinit(alloc);
    defer walker.scope_marks.deinit(alloc);
    defer {
        for (walker.func_table.items) |entry| alloc.free(entry.params);
        walker.func_table.deinit(alloc);
    }
    defer walker.filter_bindings.deinit(alloc);
    defer walker.label_var_ids.deinit(alloc);
    var intern_consumed = false;
    defer if (!intern_consumed) walker.intern.deinit(alloc);
    var regex_pool_consumed = false;
    defer if (!regex_pool_consumed) walker.regex_pool.deinit();
    // Stage 12 — prefilter harvest. Share the AST parse with bytecode emission
    // (no second `ast.parse` call). Ownership matches legacy's
    // `prefilter_groups_consumed` pattern at `compiler.zig:1354-1361`: on
    // success, the groups are moved into `Compiled.prefilter`; on any error
    // path, the `defer` below frees every group's literal bytes.
    var prefilter_groups: std.ArrayList(prefilter_mod.LiteralGroup) = .{};
    var prefilter_groups_consumed = false;
    defer if (!prefilter_groups_consumed) {
        for (prefilter_groups.items) |g| {
            for (g.literals) |l| alloc.free(l);
            alloc.free(g.literals);
        }
        prefilter_groups.deinit(alloc);
    };

    walker.walk(parsed.root) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AstCompilerStageIncomplete => return error.AstCompilerStageIncomplete,
        error.AstCompileError => return .{ .err = walker.compile_err.? },
    };

    // Stage 12 — harvest prefilter literals from the SAME AST we walked.
    // Delegated to `prefilter_mod.harvestFromAstRoot` so the legacy compiler
    // and the walker share one idiom matcher (single source of truth).
    try prefilter_mod.harvestFromAstRoot(alloc, parsed.root, &prefilter_groups);

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

    var compiled = try fuse(alloc, walker.raw.items, &walker.intern);
    intern_consumed = true; // fuse took ownership via toOwnedSlice.
    // Transfer regex-pool ownership into the Compiled. `fuse` seeded an empty
    // pool; deinit it before swapping in the walker's pool (matching legacy's
    // dance at `src/query/src/compiler.zig:1462-1464`).
    compiled.regex_pool.deinit();
    compiled.regex_pool = walker.regex_pool;
    regex_pool_consumed = true;

    // Transfer prefilter literal groups into a PrefilterSet that owns them.
    // Mirrors legacy's ownership transfer at
    // `src/query/src/compiler.zig:1470-1490`: allocate a fresh group array,
    // copy the group pointers (NOT the bytes, so the literal-byte ownership
    // moves directly), then flip `prefilter_groups_consumed` so the defer
    // above doesn't double-free.
    if (prefilter_groups.items.len > 0) {
        const moved_groups = alloc.alloc(prefilter_mod.LiteralGroup, prefilter_groups.items.len) catch {
            // OOM on the move: fall back to no prefilter rather than failing
            // the whole compile. Matches legacy's behavior.
            compiled.prefilter = null;
            return .{ .ok = compiled };
        };
        @memcpy(moved_groups, prefilter_groups.items);
        compiled.prefilter = prefilter_mod.PrefilterSet{
            .allocator = alloc,
            .groups = moved_groups,
        };
        prefilter_groups.clearAndFree(alloc);
        prefilter_groups_consumed = true;
    } else {
        compiled.prefilter = null;
    }
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
/// scopes; the walker uses a flat list with scope marks to track push/pop
/// boundaries. Stage 9 added function-body scopes (push on func_def,
/// pop after walking rest / at end of expansion).
const VarEntry = struct {
    name: []const u8,
    id: u32,
};

// ── Stage 9 — user-function support ─────────────────────────────────────────

/// One parameter of a user-defined function. `parse_var_id` mirrors legacy's
/// `ParamInfo.var_id` for value params (`$name`) — allocated in
/// `parseFunctionDef` BEFORE body parsing. Filter params (`name`) don't need
/// a var_id; their `parse_var_id` is unused. `body_scope_var_id` is the
/// additional id legacy's body-scope `declareVariable` allocates for every
/// param (value or filter) at `src/query/src/compiler.zig:6695-6702`; we
/// record it to keep `next_var_id` in lock-step with legacy's counter.
const FuncParam = struct {
    name: []const u8,
    is_filter: bool,
    parse_var_id: u32,
    body_scope_var_id: u32,
};

/// A registered user-defined function. `body_node` is the AST subtree of the
/// function body; the walker recompiles it per-call (non-recursive) or once
/// in the recursive trampoline (recursive).
const FuncEntry = struct {
    name: []const u8,
    params: []FuncParam,
    body_node: *const Node,
    is_recursive: bool,
    /// For recursive functions: raw-instr offset where the body was emitted.
    /// 0 means not yet emitted. Set on first call-site expansion; subsequent
    /// expansions reuse it. Mirrors legacy's `recursive_body_ip`.
    recursive_body_ip: u32,
    /// Lexical scope snapshot: length of `func_table` at registration time.
    /// During body re-emission, entries in `[func_table_snapshot, outer_len)`
    /// are hidden from lookups, enforcing jq's lexical scoping.
    func_table_snapshot: usize,

    fn paramCount(self: *const FuncEntry) u8 {
        return @intCast(self.params.len);
    }
};

/// Active binding from a filter-parameter name to the caller's AST argument
/// subtree. When the body walker hits a `field_access`/`func_call` whose
/// name matches an active binding, it emits the binding's AST subtree in
/// place (with the CALLER's scope/binding state restored per legacy's
/// `reParseBodyWithBindings` at `src/query/src/compiler.zig:1125`).
const FilterBinding = struct {
    name: []const u8,
    arg_node: *const Node,
    /// Length of the filter_bindings stack at the moment this binding was
    /// PUSHED — i.e. the stack position of the NEXT binding pushed at or
    /// above it. When the walker re-emits this binding's arg subtree, it
    /// temporarily truncates the stack to this index so a filter-arg whose
    /// value is another filter-arg name (pass-through) doesn't resolve to
    /// itself. Mirrors legacy's `ctx.filter_arg_bindings.items.len = bk`
    /// trick at `src/query/src/compiler.zig:6216`.
    hide_from_index: usize,
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

    // ── Stage 9 — user-function state ─────────────────────────────────────
    /// Registered user-defined functions. Append-only during func_def
    /// processing; entries may be temporarily hidden via `func_hidden_*`
    /// during recursive/lexically-scoped body re-emission.
    func_table: std.ArrayList(FuncEntry),
    /// Active filter-arg bindings. Pushed when a non-recursive function is
    /// expanded with filter args; popped after the body emits. Nested calls
    /// stack their bindings on top.
    filter_bindings: std.ArrayList(FilterBinding),
    /// Lexical-scoping hidden range — functions in `[start, end)` are
    /// skipped by `lookupUserFunc` during body re-emission. Matches legacy's
    /// `func_hidden_start/_end` at `src/query/src/compiler.zig:107-108`.
    func_hidden_start: ?usize = null,
    func_hidden_end: ?usize = null,
    /// Index of the function currently being emitted in its recursive-body
    /// trampoline. Self-refs emit `call_function(recursive_body_ip)` instead
    /// of re-entering `expandFunctionCall` (which would infinite-loop).
    /// Matches legacy's `expanding_recursive_func` at
    /// `src/query/src/compiler.zig:100`.
    expanding_recursive_func: ?usize = null,
    /// When true, the walker is in "scan-only" mode: inside a function-def
    /// body-scan pass that advances `next_var_id` to match legacy's
    /// counter without actually committing state. Function calls emitted
    /// during the scan are NOT expanded (they emit `load_key` placeholders
    /// that get discarded when the caller truncates the raw buffer), and
    /// `recursive_body_ip` is NOT mutated. Mirrors legacy's
    /// `scanning_body` at `src/query/src/compiler.zig:95`.
    scanning_body: bool = false,

    // ── Stage 10b — label / break state ───────────────────────────────────
    /// Variable ids allocated to `label $name` declarations. `break $name`
    /// verifies at compile time that the named variable was introduced by
    /// `label`, not by an `as` binding. Mirrors legacy's `ctx.label_var_ids`
    /// at `src/query/src/compiler.zig:120` (populated at `:3766`, checked
    /// at `:6380-6385`).
    label_var_ids: std.ArrayList(u32) = .{},

    // ── Stage 11 — regex builtin state ────────────────────────────────────
    /// Compile-time regex intern pool. Fast-path regex builtins
    /// (`test("lit")`, `match("lit"; "flags")`, …) compile the literal
    /// pattern bytes through this pool and pack the resulting u32 index into
    /// the `call_builtin` operand's upper slot. Slow/dynamic paths emit the
    /// `REGEX_POOL_DYNAMIC` sentinel instead. Mirrors legacy's
    /// `ctx.regex_pool` at `src/query/src/compiler.zig:1321`. Ownership is
    /// transferred to the final `Compiled` in `fuse` (see `regex_pool_consumed`).
    regex_pool: regex_mod.RegexPool,
    /// When a regex pattern literal fails to compile, `emitFlagPrefix` /
    /// `internRegexPattern` record the span of the offending literal here so
    /// the CompileResult.err can point its caret at the pattern. Mirrors
    /// legacy's `ctx.last_regex_pattern_offset` / `_len` at
    /// `src/query/src/compiler.zig:128-131`.
    last_regex_pattern_offset: u32 = 0,
    last_regex_pattern_len: u32 = 0,

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
                // Stage 9 — if the field_access is a BARE ident (span doesn't
                // start with `.`) and it matches an active filter-arg binding
                // OR a registered zero-arg user function OR the currently-
                // expanding recursive function, dispatch to the user-function
                // path instead of emitting load_key. This mirrors legacy's
                // ident-dispatch at `src/query/src/compiler.zig:6200-6250`.
                //
                // A leading `.` means this is `.name` (legit field access), so
                // the user-func check is skipped.
                const starts_with_dot = node.span.start < w.src.len and
                    w.src[node.span.start] == '.';
                if (!starts_with_dot) {
                    if (try tryDispatchBareIdent(w, fa.name, node.span)) return;
                }
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
                // `isBuiltinName` includes "path", so `path(.a)` arrives as a
                // `builtin_call` node.
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

                // Stage 9 — zero-arg builtin dispatch. The AST parser emits
                // `builtin_call(name, [])` for bare identifiers that match
                // `isZeroArgBuiltin` (e.g. `length`, `keys`). Legacy's
                // `zeroArgBuiltinId` at `src/query/src/compiler.zig:2874`
                // emits `call_builtin(bid)` stamped at `last_tok_offset` =
                // ident offset (= node.span.start for a bare-ident call).
                //
                // User-defined functions that SHADOW a zero-arg builtin do
                // NOT win: legacy at `src/query/src/compiler.zig:5896-5906`
                // checks `zeroArgBuiltinId` BEFORE user-function lookup for
                // bare idents. We match.
                if (bc.args.len == 0) {
                    if (zeroArgBuiltinId(bc.name)) |bid| {
                        try w.emit(
                            .call_builtin,
                            .{ .index = @intFromEnum(bid) },
                            node.span.start,
                        );
                        return;
                    }
                }

                // ── Stage 10a: generator / reducing builtins ──────────
                // Each helper expects the builtin name already verified and
                // handles its own arg walk + source-byte offset scanning.
                if (try dispatchStage10aBuiltin(w, bc, node.span)) return;

                // ── Stage 10b: range / limit / skip / nth ─────────────
                if (try dispatchStage10bBuiltin(w, bc, node.span)) return;

                // ── Stage 10c: del / pick / INDEX / IN / JOIN ─────────
                if (try dispatchStage10cBuiltin(w, bc, node.span)) return;

                // ── Stage 11: regex / datetime / string-ops remainder ─
                if (try dispatchStage11Builtin(w, bc, node.span)) return;

                return error.AstCompilerStageIncomplete;
            },

            .func_call => |fc| {
                // Stage 9 — user-defined function call with arguments.
                // During scanning_body, legacy emits a placeholder load_key
                // (the instrs are discarded by the caller). We mirror by
                // walking the args for var_id burn simulation and emitting
                // a cheap placeholder that gets truncated.
                const arity: u8 = @intCast(fc.args.len);
                if (w.scanning_body) {
                    if (lookupUserFunc(w, fc.name, arity) != null) {
                        // Walk args so any var_id burns inside them
                        // (e.g. `as` patterns) update next_var_id.
                        for (fc.args) |arg| try w.walk(arg);
                        const ref = try internStr(&w.intern, w.alloc, fc.name);
                        try w.emit(.load_key, .{ .str_ref = ref }, node.span.start);
                        return;
                    }
                    return error.AstCompilerStageIncomplete;
                }
                if (lookupUserFunc(w, fc.name, arity)) |idx| {
                    try expandFunctionCall(w, idx, fc.args, node.span);
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

            // ── Stage 8: update assignments ────────────────────────────

            .update_assign => |ua| {
                // Simple `.path.chain OP= rhs` fast path — the AST's strict
                // `peekIsUpdateAssign` only produces `update_assign` when the
                // LHS is a pure `.field1.field2[idx][...]` chain. Mirrors
                // the legacy fast-path at
                // `src/query/src/compiler.zig:1735-1906`.
                try emitSimpleUpdateAssign(w, node.span, ua);
            },

            .assign_general => |ag| {
                // Complex LHS — parens, comma, pipe, iteration, function call
                // that produces paths. Mirrors legacy `compilePathExprUpdate`
                // at `src/query/src/compiler.zig:1951-2035`.
                try emitGeneralAssign(w, ag);
            },

            // ── Stage 9: user functions, filter args, recursion ─────────

            .func_def => |fd| try emitFuncDef(w, fd),

            // ── Stage 10b: reduce / foreach / label / break ─────────────

            .reduce => |r| try emitReduce(w, node.span, r),

            .foreach => |f| try emitForeach(w, node.span, f),

            .label_expr => |le| try emitLabel(w, node.span, le),

            .break_expr => |be| try emitBreak(w, node.span, be),
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

// ── Stage 8 helpers: update assignments ─────────────────────────────────────

/// Reproduce the legacy compiler's `ctx.last_tok_offset` at the moment
/// `compilePathExprUpdate` starts emitting its first `push_current`. See
/// the comment on `emitGeneralAssign` for the three route variants; this
/// scanner walks the source from the LHS start the same way
/// `parseUpdateAssign` does, stopping where the legacy fallback triggered.
///
/// Routes:
///   - LHS first byte != '.': legacy peek(non-dot) → `compilePathExprUpdate`
///     without consuming any token. last_tok stays at the assign op.
///   - LHS first byte == '.': legacy consumed `.`, any number of `.ident`
///     segments, and potentially a leading `[`. It bails to the general
///     path on:
///       * `[` followed by `]` (bare iterate).
///       * `[` followed by an ident (computed key).
///       * `[` followed by a number-like that tryParseIndexInt rejects
///         (e.g. `[1,2]`). We conservatively trigger on any `[` that
///         doesn't enclose a single integer or single string literal
///         — matching legacy's behavior byte-for-byte.
///     In every fallback branch, the `[` was the most recent `nextToken`,
///     so the returned stamp is that `[`.offset.
fn computeGeneralAssignInitialStamp(
    src: []const u8,
    lhs: *const Node,
    op_offset: u32,
) u32 {
    // Route 1: non-dot leading byte → no token consumption pre-fallback.
    const start = lhs.span.start;
    if (start >= src.len or src[start] != '.') return op_offset;

    // Route 2/3: simulate parseUpdateAssign token loop.
    var i: u32 = start + 1; // past the `.`
    while (i < src.len) {
        i = skipTrivia(src, i);
        if (i >= src.len) break;
        const c = src[i];
        if (isIdentByte(c) and !std.ascii.isDigit(c)) {
            i = advancePastIdentBytes(src, i);
            // Optional `.` separator.
            const sep = skipTrivia(src, i);
            if (sep < src.len and src[sep] == '.') i = sep + 1 else i = sep;
            continue;
        }
        if (c == '[') {
            const lbracket_off = i;
            i += 1;
            const inner = skipTrivia(src, i);
            if (inner >= src.len) return lbracket_off;
            const ic = src[inner];
            if (ic == ']') {
                // Bare `.[]` — legacy fallback at `[`.offset.
                return lbracket_off;
            }
            if (ic == '"') {
                // `.["str"]` — simple, continue.
                const after_str = skipStringLiteral(src, inner);
                const close = skipTrivia(src, after_str);
                if (close < src.len and src[close] == ']') {
                    i = close + 1;
                    const sep = skipTrivia(src, i);
                    if (sep < src.len and src[sep] == '.') i = sep + 1 else i = sep;
                    continue;
                }
                return lbracket_off;
            }
            if (ic == '-' or std.ascii.isDigit(ic)) {
                // Try to parse as single int.
                var j: u32 = inner;
                if (ic == '-') j += 1;
                while (j < src.len and std.ascii.isDigit(src[j])) : (j += 1) {}
                const after_int = skipTrivia(src, j);
                if (after_int < src.len and src[after_int] == ']') {
                    i = after_int + 1;
                    const sep = skipTrivia(src, i);
                    if (sep < src.len and src[sep] == '.') i = sep + 1 else i = sep;
                    continue;
                }
                // Multi-index or slice — legacy fallback at `[`.offset.
                return lbracket_off;
            }
            // Ident / expr — legacy fallback at `[`.offset.
            return lbracket_off;
        }
        // Anything else ends the simple-path loop without fallback (e.g.
        // the assignment operator itself). Legacy's stamp at that point
        // is the assign op offset.
        break;
    }
    return op_offset;
}

/// Locate the byte offset of an assignment operator starting from `start`.
/// Scans past trivia and returns the first offset where one of `=`, `|=`,
/// `+=`, `-=`, `*=`, `/=`, `%=`, `//=` begins. Used by the simple-LHS path
/// which does not carry `op_offset` on the `update_assign` AST node (the
/// path tokens are a `PathStep` slice that loses the operator position).
fn scanAssignOpOffset(src: []const u8, start: u32) u32 {
    var i: u32 = skipTrivia(src, start);
    // Scan past the LHS path tokens. For the simple-path AST, the LHS is a
    // sequence of `.field` / `.[n]` / `.[str]` / `.[]` steps; the first
    // byte outside that grammar is the assignment operator's first byte.
    // We walk `.ident`, `[…]` blocks, and `.` separators linearly until we
    // hit one of the operator leading bytes.
    while (i < src.len) {
        const c = src[i];
        switch (c) {
            '=', '|', '+', '-', '*', '/', '%' => return i,
            '.' => i += 1,
            '[' => {
                const close = scanBracketPairEndFrom(src, i);
                i = close + 1;
            },
            else => {
                if (isIdentByte(c)) {
                    i = advancePastIdentBytes(src, i);
                } else {
                    i += 1;
                }
            },
        }
        i = skipTrivia(src, i);
    }
    return i;
}

/// Emit navigation instructions for a simple path (save_input +
/// navigate_key/index for each step). Mirrors `emitNavigation` at
/// `src/query/src/compiler.zig:1910-1918`. All emits are stamped with
/// `stamp` (the walker's current `last_tok_offset` equivalent).
fn emitSimpleNavigation(
    w: *Walker,
    steps: []const Node.PathStep,
    stamp: u32,
) error{OutOfMemory}!void {
    for (steps) |step| {
        try w.emit(.save_input, .{ .none = {} }, stamp);
        switch (step) {
            .key => |name| {
                const ref = try internStr(&w.intern, w.alloc, name);
                try w.emit(.navigate_key, .{ .str_ref = ref }, stamp);
            },
            .index => |idx| {
                try w.emit(.navigate_index, .{ .index = idx }, stamp);
            },
            .iterate => {
                // AST's simple `update_assign` path never includes `.iterate`
                // — `peekIsUpdateAssign` (parser.zig:1256) returns FALSE when
                // the path contains `.[]` because the post-`[` branch
                // explicitly requires int/string/close; bare `]` takes a
                // fallthrough that returns false. Defensive guard: any
                // `.iterate` reaching here is a parser invariant violation.
                unreachable;
            },
        }
    }
}

/// Emit update instructions in reverse path order. Mirrors `emitUpdateChain`
/// at `src/query/src/compiler.zig:1921-1931`.
fn emitSimpleUpdateChain(
    w: *Walker,
    steps: []const Node.PathStep,
    stamp: u32,
) error{OutOfMemory}!void {
    var i = steps.len;
    while (i > 0) {
        i -= 1;
        const step = steps[i];
        switch (step) {
            .key => |name| {
                const ref = try internStr(&w.intern, w.alloc, name);
                try w.emit(.update_key, .{ .str_ref = ref }, stamp);
            },
            .index => |idx| {
                try w.emit(.update_index, .{ .index = idx }, stamp);
            },
            .iterate => unreachable,
        }
    }
}

/// Emit the simple `.path.chain OP= rhs` fast path. Mirrors
/// `src/query/src/compiler.zig:1735-1906`.
///
/// Source-offset policy (legacy's `ctx.last_tok_offset` after each nextToken):
///   - Consuming `.path...`: last_tok = path's final ident / `]` offset.
///   - Consuming the assignment operator: last_tok = op_offset.
///   - Emits during navigation / path setup: stamped with op_offset (for
///     `|=` and compound ops, since no RHS walk has happened yet).
///   - Emits after walking RHS: stamped with walker's `last_emit_offset`,
///     which equals the RHS's final emit offset (matches legacy's
///     last_tok_offset after parseAlternative returns).
fn emitSimpleUpdateAssign(
    w: *Walker,
    node_span: ast.Span,
    ua: Node.UpdateAssign,
) Walker.Error!void {
    const op_offset = scanAssignOpOffset(w.src, node_span.start);

    switch (ua.op) {
        .pipe_eq => {
            // Navigate first, then RHS against navigated value, then update.
            try emitSimpleNavigation(w, ua.path, op_offset);
            try w.walk(ua.rhs);
            try emitSimpleUpdateChain(w, ua.path, w.last_emit_offset);
        },
        .eq => {
            // RHS evaluated against original input FIRST, then navigate.
            try w.walk(ua.rhs);
            const rhs_last = w.last_emit_offset;
            try emitSimpleNavigation(w, ua.path, rhs_last);
            try emitSimpleUpdateChain(w, ua.path, rhs_last);
        },
        .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq => {
            // 1. Save original input into tmp var.
            const tmp_var_id = w.next_var_id;
            w.next_var_id += 1;
            try w.emit(.push_current, .{ .none = {} }, op_offset);
            try w.emit(.capture_variable, .{ .index = @intCast(tmp_var_id) }, op_offset);

            // 2. Navigate to target.
            try emitSimpleNavigation(w, ua.path, op_offset);

            // 3. Push navigated value.
            try w.emit(.push_current, .{ .none = {} }, op_offset);

            // 4. Restore original for RHS.
            try w.emit(.load_variable, .{ .index = @intCast(tmp_var_id) }, op_offset);
            try w.emit(.pipe, .{ .none = {} }, op_offset);

            // 5. Evaluate RHS.
            try w.walk(ua.rhs);
            const rhs_last = w.last_emit_offset;

            // 6. Apply arithmetic — stamp = rhs_last (legacy emits arith_op
            //    via ctx.emit which stamps last_tok_offset == RHS's last).
            const arith_op: Instruction.Op = switch (ua.op) {
                .plus_eq => .add,
                .minus_eq => .sub,
                .star_eq => .mul,
                .slash_eq => .div,
                .percent_eq => .mod,
                else => unreachable,
            };
            try w.emit(arith_op, .{ .none = {} }, rhs_last);

            // 7. Update chain.
            try emitSimpleUpdateChain(w, ua.path, rhs_last);
        },
        .double_slash_eq => {
            // `.path //= rhs` — keep truthy value, else replace.
            const tmp_var_id = w.next_var_id;
            w.next_var_id += 1;
            try w.emit(.push_current, .{ .none = {} }, op_offset);
            try w.emit(.capture_variable, .{ .index = @intCast(tmp_var_id) }, op_offset);

            try emitSimpleNavigation(w, ua.path, op_offset);

            const fork_alt_pos = w.raw.items.len;
            try w.emit(.fork_alt, .{ .index = 0 }, op_offset);
            try w.emit(.push_current, .{ .none = {} }, op_offset);

            const jif_pos = w.raw.items.len;
            try w.emit(.jump_if_false, .{ .index = 0 }, op_offset);
            try w.emit(.pop_try, .{ .none = {} }, op_offset);
            try w.emit(.push_current, .{ .none = {} }, op_offset);

            const jump_end_pos = w.raw.items.len;
            try w.emit(.jump, .{ .index = 0 }, op_offset);

            // Falsy branch.
            w.raw.items[jif_pos].operand = .{ .index = @intCast(w.raw.items.len) };
            try w.emit(.backtrack, .{ .none = {} }, op_offset);

            // Right side.
            const right_ip: u32 = @intCast(w.raw.items.len);
            w.raw.items[fork_alt_pos].operand = .{ .index = @intCast(right_ip) };

            try w.emit(.load_variable, .{ .index = @intCast(tmp_var_id) }, op_offset);
            try w.emit(.pipe, .{ .none = {} }, op_offset);
            try w.walk(ua.rhs);
            const rhs_last = w.last_emit_offset;

            w.raw.items[jump_end_pos].operand = .{ .index = @intCast(w.raw.items.len) };

            try emitSimpleUpdateChain(w, ua.path, rhs_last);
        },
    }
}

/// Captured snapshot of RHS raw instructions, including the base IP they
/// were originally emitted at so that later re-emissions can rebase internal
/// jump targets. Mirrors `CapturedRhs` at
/// `src/query/src/compiler.zig:2432-2436`.
const CapturedRhs = struct {
    instrs: []RawInstr,
    original_start: u32,
};

/// Rebase internal jump/fork IP operands in a captured RHS buffer by `offset`.
/// Mirrors `rebaseExprBuf` at `src/query/src/compiler.zig:1256-1264`.
fn rebaseExprBuf(buf: []RawInstr, offset: i64) void {
    for (buf) |*r| {
        if (r.op.hasIpOperand()) {
            r.operand.index += offset;
        } else if (r.op.hasSentinelIpOperand()) {
            if (r.operand.index > 0) r.operand.index += offset;
        }
    }
}

/// Copy raw instructions in `[start, end)` into a heap buffer and truncate
/// the walker's stream back to `start`. Caller must free the returned slice.
/// Mirrors `captureAndTruncate` at `src/query/src/compiler.zig:2421-2427`.
fn captureAndTruncate(
    w: *Walker,
    start: usize,
    end: usize,
) error{OutOfMemory}!CapturedRhs {
    const slice = w.raw.items[start..end];
    const buf = try w.alloc.alloc(RawInstr, slice.len);
    @memcpy(buf, slice);
    w.raw.items.len = start;
    return .{ .instrs = buf, .original_start = @intCast(start) };
}

/// Append a rebased copy of the captured RHS at the walker's current tail.
/// Mirrors `appendRebasedInstrsCopy` at
/// `src/query/src/compiler.zig:2439-2447`. Also updates the walker's
/// `last_emit_offset` to the final appended instruction's src_offset so
/// subsequent `emit` calls default-stamp with the RHS's last token offset
/// (legacy's `ctx.last_tok_offset` state after parseAlternative left it
/// at the RHS's last consumed token; appending via appendSlice bypasses
/// `emit` and therefore does not update the walker's tracker by itself).
fn appendRebasedInstrsCopy(
    w: *Walker,
    captured: CapturedRhs,
) error{OutOfMemory}!void {
    const new_start: i64 = @intCast(w.raw.items.len);
    const offset: i64 = new_start - @as(i64, @intCast(captured.original_start));
    const copy = try w.alloc.alloc(RawInstr, captured.instrs.len);
    defer w.alloc.free(copy);
    @memcpy(copy, captured.instrs);
    rebaseExprBuf(copy, offset);
    try w.raw.appendSlice(w.alloc, copy);
    if (copy.len > 0) {
        w.last_emit_offset = copy[copy.len - 1].src_offset;
    }
}

/// Emit `[]` (empty array literal). Mirrors `emitEmptyArray` at
/// `src/query/src/compiler.zig:2411-2417`.
fn emitEmptyArray(w: *Walker, stamp: u32) error{OutOfMemory}!void {
    const start = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, stamp);
    const end: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, stamp);
    w.raw.items[start].operand = .{ .index = @intCast(end) };
}

/// Detect whether a captured RHS is exactly a single `call_builtin(empty)`.
/// Mirrors `isEmptyBuiltinCall` at `src/query/src/compiler.zig:2039-2043`.
fn isEmptyBuiltinCall(buf: []const RawInstr) bool {
    return buf.len == 1 and
        buf[0].op == .call_builtin and
        buf[0].operand.index == @intFromEnum(types.BuiltinId.empty);
}

/// Emit `[path(LHS)]` — collects every path the LHS expression produces.
/// Mirrors `emitPathCollection` at `src/query/src/compiler.zig:2049-2066`.
/// The LHS is walked in path-expression mode (wrapped in path_begin/end).
fn emitPathCollection(
    w: *Walker,
    lhs: *const Node,
    stamp: u32,
) Walker.Error!void {
    // Legacy stamp sequence (mirrors `emitPathCollection` at
    // `src/query/src/compiler.zig:2049-2066` with the `ctx.last_tok_offset`
    // convention):
    //   - array_collect_start / path_begin   → `assign_tok.offset`
    //     (last_tok_offset at entry, which is the operator position because
    //     `peekIsUpdateAssign` advanced through it without restoring).
    //   - after parseAlternative(LHS)         → last_tok = LHS's final token
    //     offset (e.g. the `)` offset for `(.a, .b)` LHS).
    //   - path_end / yield_output / array_collect_end → that LHS-final
    //     offset.
    const ace_start = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, stamp);

    const path_begin_ip = w.raw.items.len;
    try w.emit(.path_begin, .{ .index = 0 }, stamp);

    try w.walk(lhs);

    // All post-LHS emits stamp with the final LHS emit offset, matching the
    // legacy `ctx.last_tok_offset` state after `parseAlternative` returns.
    const lhs_last = w.last_emit_offset;
    try w.emit(.path_end, .{ .none = {} }, lhs_last);
    w.raw.items[path_begin_ip].operand = .{ .index = @intCast(w.raw.items.len - 1) };

    try w.emit(.yield_output, .{ .none = {} }, lhs_last);

    const ace_end: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, lhs_last);
    w.raw.items[ace_start].operand = .{ .index = @intCast(ace_end) };
}

/// Complex LHS / general path-expression update.
/// Mirrors `compilePathExprUpdate` at `src/query/src/compiler.zig:1951-2035`.
///
/// All emits inside this helper stamp with `op_offset` because the legacy
/// path-capture loop sets `ctx.last_tok_offset = assign_tok.offset` (see
/// `src/query/src/compiler.zig:1977-1978`) before every bytecode-generating
/// helper runs. `$orig/$paths` captures happen BEFORE the RHS walk, so they
/// carry the assign-op offset; post-RHS emits inherit from RHS's last emit.
fn emitGeneralAssign(w: *Walker, ag: Node.AssignGeneral) Walker.Error!void {
    const op_offset = ag.op_offset;

    // Reproduce legacy's `ctx.last_tok_offset` at the moment
    // `compilePathExprUpdate` starts emitting. Legacy reaches that entry
    // via one of three routes, each leaving last_tok_offset at a different
    // value (see `parseUpdateAssign` at `src/query/src/compiler.zig:1735`):
    //   1. Non-`.` LHS: `parseUpdateAssign` falls through on first peek
    //      without consuming tokens. last_tok_offset stays at the assign
    //      op (`peekIsUpdateAssign` set it before returning).
    //   2. `.`-prefix LHS with a bare `.[]` or `.[ident]` fallback: legacy
    //      consumed `.`, path idents, and the `[` before bailing. The `[`
    //      was the most recent `nextToken`, so last_tok = `[`.offset.
    //   3. `.`-prefix LHS with a multi-index `.[n,m]` fallback: same as
    //      (2), `[` was last consumed.
    // We reconstruct the value by scanning the source the same way. The
    // AST's LHS subtree suffices to distinguish (1) from (2)/(3).
    const initial_stamp = computeGeneralAssignInitialStamp(w.src, ag.lhs, op_offset);

    const orig_var = w.next_var_id;
    w.next_var_id += 1;
    const paths_var = w.next_var_id;
    w.next_var_id += 1;
    const acc_var = w.next_var_id;
    w.next_var_id += 1;
    const dels_var = w.next_var_id;
    w.next_var_id += 1;
    const p_var = w.next_var_id;
    w.next_var_id += 1;
    const r_var = w.next_var_id;
    w.next_var_id += 1;

    // $orig = current input.
    try w.emit(.push_current, .{ .none = {} }, initial_stamp);
    try w.emit(.capture_variable, .{ .index = @intCast(orig_var) }, initial_stamp);

    // $paths = [path(LHS)]. After `emitPathCollection`, the walker's
    // `last_emit_offset` = LHS's final emit offset (legacy's
    // `ctx.last_tok_offset` state after parseAlternative left it at the
    // LHS's last consumed token). `capture_variable($paths)` stamps with
    // that value — see legacy `src/query/src/compiler.zig:1974` which
    // emits via `ctx.emit`, inheriting `ctx.last_tok_offset`.
    try emitPathCollection(w, ag.lhs, initial_stamp);
    try w.emit(
        .capture_variable,
        .{ .index = @intCast(paths_var) },
        w.last_emit_offset,
    );

    // Capture RHS into a buffer so we can re-emit inside the reduce body.
    // Legacy stamps assign_tok.offset on `ctx.last_tok_offset` right before
    // parseAlternative (compiler.zig:1977); during the walk of RHS, emits
    // follow RHS span offsets — the walker's `w.walk(rhs)` does the same.
    const rhs_start = w.raw.items.len;
    try w.walk(ag.rhs);
    const rhs_end = w.raw.items.len;

    // Special case: `|= empty` desugars to `delpaths($paths)` directly.
    if (ag.op == .pipe_eq and isEmptyBuiltinCall(w.raw.items[rhs_start..rhs_end])) {
        w.raw.items.len = rhs_start;
        try w.emit(.load_variable, .{ .index = @intCast(orig_var) }, op_offset);
        try w.emit(.pipe, .{ .none = {} }, op_offset);
        try w.emit(.load_variable, .{ .index = @intCast(paths_var) }, op_offset);
        try w.emit(
            .call_builtin,
            .{ .index = @intFromEnum(types.BuiltinId.delpaths) },
            op_offset,
        );
        return;
    }

    const captured = try captureAndTruncate(w, rhs_start, rhs_end);
    defer w.alloc.free(captured.instrs);

    // At this point legacy's `ctx.last_tok_offset` == RHS's final token
    // offset (parseAlternative walked through the RHS; captureAndTruncate
    // only trims raw buffer, not last_tok). Every subsequent `ctx.emit`
    // inside the per-op emitters stamps with that value. Mirror here by
    // passing `w.last_emit_offset` (set by captureAndTruncate to the final
    // appended RHS emit's src_offset — see `appendRebasedInstrsCopy` and
    // the `emit` updates in `w.walk(ag.rhs)`).
    //
    // `w.walk(rhs)` above already set `w.last_emit_offset = RHS_last` for
    // emitGeneralEqUpdate/etc. — captureAndTruncate does not clear it.
    const post_rhs_stamp = w.last_emit_offset;

    switch (ag.op) {
        .pipe_eq => try emitGeneralPipeEqUpdate(
            w,
            post_rhs_stamp,
            orig_var,
            paths_var,
            acc_var,
            dels_var,
            p_var,
            r_var,
            captured,
        ),
        .eq => try emitGeneralEqUpdate(
            w,
            post_rhs_stamp,
            orig_var,
            paths_var,
            acc_var,
            p_var,
            captured,
        ),
        .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq => {
            const arith_op: Instruction.Op = switch (ag.op) {
                .plus_eq => .add,
                .minus_eq => .sub,
                .star_eq => .mul,
                .slash_eq => .div,
                .percent_eq => .mod,
                else => unreachable,
            };
            try emitGeneralCompoundUpdate(
                w,
                post_rhs_stamp,
                orig_var,
                paths_var,
                acc_var,
                p_var,
                arith_op,
                captured,
            );
        },
        .double_slash_eq => try emitGeneralAlternativeUpdate(
            w,
            post_rhs_stamp,
            orig_var,
            paths_var,
            acc_var,
            p_var,
            captured,
        ),
    }
}

/// Emit the general `LHS |= f` update. Mirrors `emitGeneralPipeEqUpdate` at
/// `src/query/src/compiler.zig:2106-2215`.
fn emitGeneralPipeEqUpdate(
    w: *Walker,
    stamp: u32,
    orig_var: u32,
    paths_var: u32,
    acc_var: u32,
    dels_var: u32,
    p_var: u32,
    r_var: u32,
    rhs: CapturedRhs,
) Walker.Error!void {
    // $acc = $orig
    try w.emit(.load_variable, .{ .index = @intCast(orig_var) }, stamp);
    try w.emit(.pipe, .{ .none = {} }, stamp);
    try w.emit(.capture_variable, .{ .index = @intCast(acc_var) }, stamp);

    // $dels = []
    try emitEmptyArray(w, stamp);
    try w.emit(.capture_variable, .{ .index = @intCast(dels_var) }, stamp);

    // For each $p in $paths:
    try w.emit(.load_variable, .{ .index = @intCast(paths_var) }, stamp);
    try w.emit(.pipe, .{ .none = {} }, stamp);

    const inner_ace_start = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, stamp);
    try w.emit(.each, .{ .none = {} }, stamp);
    try w.emit(.capture_variable, .{ .index = @intCast(p_var) }, stamp);

    // Compute $r = [ ($acc | getpath($p)) | f ]
    try w.emit(.load_variable, .{ .index = @intCast(acc_var) }, stamp);
    try w.emit(.pipe, .{ .none = {} }, stamp);
    try w.emit(.load_variable, .{ .index = @intCast(p_var) }, stamp);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.getpath) },
        stamp,
    );
    try w.emit(.pipe, .{ .none = {} }, stamp);

    const r_ace_start = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, stamp);
    try appendRebasedInstrsCopy(w, rhs);
    try w.emit(.yield_output, .{ .none = {} }, w.last_emit_offset);
    const r_ace_end: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, stamp);
    w.raw.items[r_ace_start].operand = .{ .index = @intCast(r_ace_end) };
    try w.emit(.capture_variable, .{ .index = @intCast(r_var) }, stamp);

    // if length($r) == 0 then add $p to $dels else $acc = setpath(...)
    try w.emit(.load_variable, .{ .index = @intCast(r_var) }, stamp);
    try w.emit(.pipe, .{ .none = {} }, stamp);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.length) },
        stamp,
    );
    try w.emit(.pipe, .{ .none = {} }, stamp);
    try w.emit(.push_int, .{ .int = 0 }, stamp);
    try w.emit(.eq, .{ .none = {} }, stamp);

    const jif_pos = w.raw.items.len;
    try w.emit(.jump_if_false, .{ .index = 0 }, stamp);

    // THEN: $dels = $dels + [$p]
    try w.emit(.load_variable, .{ .index = @intCast(dels_var) }, stamp);
    try w.emit(.pipe, .{ .none = {} }, stamp);
    try w.emit(.push_current, .{ .none = {} }, stamp);

    const p_arr_start = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, stamp);
    try w.emit(.load_variable, .{ .index = @intCast(p_var) }, stamp);
    try w.emit(.yield_output, .{ .none = {} }, stamp);
    const p_arr_end: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, stamp);
    w.raw.items[p_arr_start].operand = .{ .index = @intCast(p_arr_end) };
    try w.emit(.add, .{ .none = {} }, stamp);
    try w.emit(.capture_variable, .{ .index = @intCast(dels_var) }, stamp);

    const jump_end_pos = w.raw.items.len;
    try w.emit(.jump, .{ .index = 0 }, stamp);

    // ELSE: $acc = setpath($acc; $p; $r[0])
    w.raw.items[jif_pos].operand = .{ .index = @intCast(w.raw.items.len) };
    try w.emit(.load_variable, .{ .index = @intCast(acc_var) }, stamp);
    try w.emit(.pipe, .{ .none = {} }, stamp);
    try w.emit(.save_input, .{ .none = {} }, stamp);
    try w.emit(.load_variable, .{ .index = @intCast(p_var) }, stamp);
    try w.emit(.restore_input, .{ .none = {} }, stamp);
    try w.emit(.save_input, .{ .none = {} }, stamp);
    try w.emit(.load_variable, .{ .index = @intCast(r_var) }, stamp);
    try w.emit(.pipe, .{ .none = {} }, stamp);
    try w.emit(.load_index, .{ .index = 0 }, stamp);
    try w.emit(.restore_input, .{ .none = {} }, stamp);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.setpath) },
        stamp,
    );
    try w.emit(.capture_variable, .{ .index = @intCast(acc_var) }, stamp);

    // END
    w.raw.items[jump_end_pos].operand = .{ .index = @intCast(w.raw.items.len) };

    try w.emit(.backtrack, .{ .none = {} }, stamp);

    const inner_ace_end: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, stamp);
    w.raw.items[inner_ace_start].operand = .{ .index = @intCast(inner_ace_end) };

    try w.emit(.pipe, .{ .none = {} }, stamp);

    // Apply deletions: $acc | delpaths($dels)
    try w.emit(.load_variable, .{ .index = @intCast(acc_var) }, stamp);
    try w.emit(.pipe, .{ .none = {} }, stamp);
    try w.emit(.load_variable, .{ .index = @intCast(dels_var) }, stamp);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.delpaths) },
        stamp,
    );
}

/// Emit the general `LHS = v` update. Mirrors `emitGeneralEqUpdate` at
/// `src/query/src/compiler.zig:2220-2270`.
fn emitGeneralEqUpdate(
    w: *Walker,
    stamp: u32,
    orig_var: u32,
    paths_var: u32,
    acc_var: u32,
    p_var: u32,
    rhs: CapturedRhs,
) Walker.Error!void {
    const value_var = w.next_var_id;
    w.next_var_id += 1;

    // $value = $orig | v
    try w.emit(.load_variable, .{ .index = @intCast(orig_var) }, stamp);
    try w.emit(.pipe, .{ .none = {} }, stamp);
    try appendRebasedInstrsCopy(w, rhs);
    try w.emit(.capture_variable, .{ .index = @intCast(value_var) }, w.last_emit_offset);

    // $acc = $orig
    try w.emit(.load_variable, .{ .index = @intCast(orig_var) }, w.last_emit_offset);
    try w.emit(.pipe, .{ .none = {} }, w.last_emit_offset);
    try w.emit(.capture_variable, .{ .index = @intCast(acc_var) }, w.last_emit_offset);

    // For each $p in $paths: $acc = setpath($acc; $p; $value)
    try w.emit(.load_variable, .{ .index = @intCast(paths_var) }, w.last_emit_offset);
    try w.emit(.pipe, .{ .none = {} }, w.last_emit_offset);

    const after_rhs_stamp = w.last_emit_offset;

    const inner_ace_start = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, after_rhs_stamp);
    try w.emit(.each, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.capture_variable, .{ .index = @intCast(p_var) }, after_rhs_stamp);

    try w.emit(.load_variable, .{ .index = @intCast(acc_var) }, after_rhs_stamp);
    try w.emit(.pipe, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.save_input, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.load_variable, .{ .index = @intCast(p_var) }, after_rhs_stamp);
    try w.emit(.restore_input, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.save_input, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.load_variable, .{ .index = @intCast(value_var) }, after_rhs_stamp);
    try w.emit(.restore_input, .{ .none = {} }, after_rhs_stamp);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.setpath) },
        after_rhs_stamp,
    );
    try w.emit(.capture_variable, .{ .index = @intCast(acc_var) }, after_rhs_stamp);

    try w.emit(.backtrack, .{ .none = {} }, after_rhs_stamp);

    const inner_ace_end: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, after_rhs_stamp);
    w.raw.items[inner_ace_start].operand = .{ .index = @intCast(inner_ace_end) };

    try w.emit(.pipe, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.load_variable, .{ .index = @intCast(acc_var) }, after_rhs_stamp);
}

/// Emit the general `LHS op= v` compound update. Mirrors
/// `emitGeneralCompoundUpdate` at `src/query/src/compiler.zig:2276-2332`.
fn emitGeneralCompoundUpdate(
    w: *Walker,
    stamp: u32,
    orig_var: u32,
    paths_var: u32,
    acc_var: u32,
    p_var: u32,
    arith_op: Instruction.Op,
    rhs: CapturedRhs,
) Walker.Error!void {
    const tmp_var = w.next_var_id;
    w.next_var_id += 1;

    try w.emit(.load_variable, .{ .index = @intCast(orig_var) }, stamp);
    try w.emit(.pipe, .{ .none = {} }, stamp);
    try appendRebasedInstrsCopy(w, rhs);
    try w.emit(.capture_variable, .{ .index = @intCast(tmp_var) }, w.last_emit_offset);

    try w.emit(.load_variable, .{ .index = @intCast(orig_var) }, w.last_emit_offset);
    try w.emit(.pipe, .{ .none = {} }, w.last_emit_offset);
    try w.emit(.capture_variable, .{ .index = @intCast(acc_var) }, w.last_emit_offset);

    try w.emit(.load_variable, .{ .index = @intCast(paths_var) }, w.last_emit_offset);
    try w.emit(.pipe, .{ .none = {} }, w.last_emit_offset);

    const after_rhs_stamp = w.last_emit_offset;

    const inner_ace_start = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, after_rhs_stamp);
    try w.emit(.each, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.capture_variable, .{ .index = @intCast(p_var) }, after_rhs_stamp);

    try w.emit(.load_variable, .{ .index = @intCast(acc_var) }, after_rhs_stamp);
    try w.emit(.pipe, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.save_input, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.load_variable, .{ .index = @intCast(p_var) }, after_rhs_stamp);
    try w.emit(.restore_input, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.save_input, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.load_variable, .{ .index = @intCast(p_var) }, after_rhs_stamp);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.getpath) },
        after_rhs_stamp,
    );
    try w.emit(.load_variable, .{ .index = @intCast(tmp_var) }, after_rhs_stamp);
    try w.emit(arith_op, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.restore_input, .{ .none = {} }, after_rhs_stamp);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.setpath) },
        after_rhs_stamp,
    );
    try w.emit(.capture_variable, .{ .index = @intCast(acc_var) }, after_rhs_stamp);

    try w.emit(.backtrack, .{ .none = {} }, after_rhs_stamp);

    const inner_ace_end: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, after_rhs_stamp);
    w.raw.items[inner_ace_start].operand = .{ .index = @intCast(inner_ace_end) };

    try w.emit(.pipe, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.load_variable, .{ .index = @intCast(acc_var) }, after_rhs_stamp);
}

/// Emit the general `LHS //= v` alternative-assignment update. Mirrors
/// `emitGeneralAlternativeUpdate` at
/// `src/query/src/compiler.zig:2336-2408`.
fn emitGeneralAlternativeUpdate(
    w: *Walker,
    stamp: u32,
    orig_var: u32,
    paths_var: u32,
    acc_var: u32,
    p_var: u32,
    rhs: CapturedRhs,
) Walker.Error!void {
    const tmp_var = w.next_var_id;
    w.next_var_id += 1;

    try w.emit(.load_variable, .{ .index = @intCast(orig_var) }, stamp);
    try w.emit(.pipe, .{ .none = {} }, stamp);
    try appendRebasedInstrsCopy(w, rhs);
    try w.emit(.capture_variable, .{ .index = @intCast(tmp_var) }, w.last_emit_offset);

    try w.emit(.load_variable, .{ .index = @intCast(orig_var) }, w.last_emit_offset);
    try w.emit(.pipe, .{ .none = {} }, w.last_emit_offset);
    try w.emit(.capture_variable, .{ .index = @intCast(acc_var) }, w.last_emit_offset);

    try w.emit(.load_variable, .{ .index = @intCast(paths_var) }, w.last_emit_offset);
    try w.emit(.pipe, .{ .none = {} }, w.last_emit_offset);

    const after_rhs_stamp = w.last_emit_offset;

    const inner_ace_start = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, after_rhs_stamp);
    try w.emit(.each, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.capture_variable, .{ .index = @intCast(p_var) }, after_rhs_stamp);

    // current = getpath($acc; $p)
    try w.emit(.load_variable, .{ .index = @intCast(acc_var) }, after_rhs_stamp);
    try w.emit(.pipe, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.load_variable, .{ .index = @intCast(p_var) }, after_rhs_stamp);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.getpath) },
        after_rhs_stamp,
    );
    try w.emit(.pipe, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.push_current, .{ .none = {} }, after_rhs_stamp);

    const jif_pos = w.raw.items.len;
    try w.emit(.jump_if_false, .{ .index = 0 }, after_rhs_stamp);

    const jump_end_pos = w.raw.items.len;
    try w.emit(.jump, .{ .index = 0 }, after_rhs_stamp);

    // ELSE: $acc = setpath($acc; $p; $tmp)
    w.raw.items[jif_pos].operand = .{ .index = @intCast(w.raw.items.len) };
    try w.emit(.load_variable, .{ .index = @intCast(acc_var) }, after_rhs_stamp);
    try w.emit(.pipe, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.save_input, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.load_variable, .{ .index = @intCast(p_var) }, after_rhs_stamp);
    try w.emit(.restore_input, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.save_input, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.load_variable, .{ .index = @intCast(tmp_var) }, after_rhs_stamp);
    try w.emit(.restore_input, .{ .none = {} }, after_rhs_stamp);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.setpath) },
        after_rhs_stamp,
    );
    try w.emit(.capture_variable, .{ .index = @intCast(acc_var) }, after_rhs_stamp);

    w.raw.items[jump_end_pos].operand = .{ .index = @intCast(w.raw.items.len) };

    try w.emit(.backtrack, .{ .none = {} }, after_rhs_stamp);

    const inner_ace_end: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, after_rhs_stamp);
    w.raw.items[inner_ace_start].operand = .{ .index = @intCast(inner_ace_end) };

    try w.emit(.pipe, .{ .none = {} }, after_rhs_stamp);
    try w.emit(.load_variable, .{ .index = @intCast(acc_var) }, after_rhs_stamp);
}

// ── Stage 9 helpers: user functions, filter args, recursion ────────────────

/// Map a bare-ident name to a zero-arg BuiltinId. Mirrors legacy's
/// `zeroArgBuiltinId` at `src/query/src/compiler.zig:2874`. Returns null if
/// the name isn't a recognized zero-arg builtin.
fn zeroArgBuiltinId(name: []const u8) ?types.BuiltinId {
    if (std.mem.eql(u8, name, "length")) return .length;
    if (std.mem.eql(u8, name, "keys")) return .keys;
    if (std.mem.eql(u8, name, "keys_unsorted")) return .keys_unsorted;
    if (std.mem.eql(u8, name, "values")) return .values;
    if (std.mem.eql(u8, name, "type")) return .type_;
    if (std.mem.eql(u8, name, "empty")) return .empty;
    if (std.mem.eql(u8, name, "tostring")) return .tostring;
    if (std.mem.eql(u8, name, "tonumber")) return .tonumber;
    if (std.mem.eql(u8, name, "error")) return .error_;
    if (std.mem.eql(u8, name, "add")) return .add;
    if (std.mem.eql(u8, name, "sort")) return .sort;
    if (std.mem.eql(u8, name, "reverse")) return .reverse;
    if (std.mem.eql(u8, name, "flatten")) return .flatten;
    if (std.mem.eql(u8, name, "min")) return .min;
    if (std.mem.eql(u8, name, "max")) return .max;
    if (std.mem.eql(u8, name, "to_entries")) return .to_entries;
    if (std.mem.eql(u8, name, "from_entries")) return .from_entries;
    if (std.mem.eql(u8, name, "any")) return .any;
    if (std.mem.eql(u8, name, "all")) return .all;
    if (std.mem.eql(u8, name, "unique")) return .unique;
    if (std.mem.eql(u8, name, "paths")) return .paths;
    if (std.mem.eql(u8, name, "leaf_paths")) return .leaf_paths;
    if (std.mem.eql(u8, name, "recurse")) return .recurse;
    if (std.mem.eql(u8, name, "abs")) return .abs;
    if (std.mem.eql(u8, name, "floor")) return .floor_;
    if (std.mem.eql(u8, name, "ceil")) return .ceil_;
    if (std.mem.eql(u8, name, "round")) return .round_;
    if (std.mem.eql(u8, name, "sqrt")) return .sqrt_;
    if (std.mem.eql(u8, name, "fabs")) return .fabs_;
    if (std.mem.eql(u8, name, "nan")) return .nan_;
    if (std.mem.eql(u8, name, "infinite")) return .infinite_;
    if (std.mem.eql(u8, name, "isinfinite")) return .isinfinite_;
    if (std.mem.eql(u8, name, "isnan")) return .isnan_;
    if (std.mem.eql(u8, name, "isnormal")) return .isnormal_;
    if (std.mem.eql(u8, name, "exp")) return .exp_;
    if (std.mem.eql(u8, name, "exp2")) return .exp2_;
    if (std.mem.eql(u8, name, "exp10")) return .exp10_;
    if (std.mem.eql(u8, name, "log")) return .log_;
    if (std.mem.eql(u8, name, "log2")) return .log2_;
    if (std.mem.eql(u8, name, "log10")) return .log10_;
    if (std.mem.eql(u8, name, "cbrt")) return .cbrt_;
    if (std.mem.eql(u8, name, "sin")) return .sin_;
    if (std.mem.eql(u8, name, "cos")) return .cos_;
    if (std.mem.eql(u8, name, "tan")) return .tan_;
    if (std.mem.eql(u8, name, "asin")) return .asin_;
    if (std.mem.eql(u8, name, "acos")) return .acos_;
    if (std.mem.eql(u8, name, "atan")) return .atan_;
    if (std.mem.eql(u8, name, "rint")) return .rint_;
    if (std.mem.eql(u8, name, "nearbyint")) return .nearbyint_;
    if (std.mem.eql(u8, name, "trunc")) return .trunc_;
    if (std.mem.eql(u8, name, "ascii_downcase")) return .ascii_downcase;
    if (std.mem.eql(u8, name, "ascii_upcase")) return .ascii_upcase;
    if (std.mem.eql(u8, name, "ascii")) return .ascii_;
    if (std.mem.eql(u8, name, "explode")) return .explode_;
    if (std.mem.eql(u8, name, "implode")) return .implode_;
    if (std.mem.eql(u8, name, "tojson")) return .tojson;
    if (std.mem.eql(u8, name, "fromjson")) return .fromjson;
    if (std.mem.eql(u8, name, "transpose")) return .transpose_;

    // Stage 11 additions: date/time + misc zero-arg names. Legacy's
    // `zeroArgBuiltinId` at `src/query/src/compiler.zig:2962-2989` lists
    // them; the AST parser's `isZeroArgBuiltin` omits them (they come
    // through as `field_access` instead). We translate here.
    if (std.mem.eql(u8, name, "now")) return .now_;
    if (std.mem.eql(u8, name, "gmtime")) return .gmtime_;
    if (std.mem.eql(u8, name, "mktime")) return .mktime_;
    if (std.mem.eql(u8, name, "todate")) return .todate_;
    if (std.mem.eql(u8, name, "fromdate")) return .fromdate_;
    if (std.mem.eql(u8, name, "todateiso8601")) return .todateiso8601_;
    if (std.mem.eql(u8, name, "fromdateiso8601")) return .fromdateiso8601_;

    if (std.mem.eql(u8, name, "env")) return .env_;
    if (std.mem.eql(u8, name, "builtins")) return .builtins_;
    if (std.mem.eql(u8, name, "debug")) return .debug_;
    if (std.mem.eql(u8, name, "stderr")) return .stderr_;
    if (std.mem.eql(u8, name, "input")) return .input_;
    if (std.mem.eql(u8, name, "inputs")) return .inputs_;
    if (std.mem.eql(u8, name, "halt")) return .halt_;

    if (std.mem.eql(u8, name, "toboolean")) return .toboolean;
    if (std.mem.eql(u8, name, "utf8bytelength")) return .utf8bytelength;
    if (std.mem.eql(u8, name, "trim")) return .trim_;
    if (std.mem.eql(u8, name, "ltrim")) return .ltrim_;
    if (std.mem.eql(u8, name, "rtrim")) return .rtrim_;

    // Type-filter builtins.
    if (std.mem.eql(u8, name, "arrays")) return .arrays_;
    if (std.mem.eql(u8, name, "objects")) return .objects_;
    if (std.mem.eql(u8, name, "strings")) return .strings_;
    if (std.mem.eql(u8, name, "numbers")) return .numbers_;
    if (std.mem.eql(u8, name, "booleans")) return .booleans_;
    if (std.mem.eql(u8, name, "nulls")) return .nulls_;
    if (std.mem.eql(u8, name, "scalars")) return .scalars_;
    if (std.mem.eql(u8, name, "normals")) return .normals_;
    if (std.mem.eql(u8, name, "iterables")) return .iterables_;

    // Math extras.
    if (std.mem.eql(u8, name, "significand")) return .significand_;
    if (std.mem.eql(u8, name, "logb")) return .logb_;
    if (std.mem.eql(u8, name, "j0")) return .j0_;
    if (std.mem.eql(u8, name, "j1")) return .j1_;
    if (std.mem.eql(u8, name, "lgamma")) return .lgamma_;
    if (std.mem.eql(u8, name, "tgamma")) return .tgamma_;

    return null;
}

/// Look up a user-defined function by name and arity. Respects the
/// `func_hidden_*` range for lexical scoping during body re-emission.
/// Searches backward so the latest (innermost/shadowing) def wins. Mirrors
/// legacy's `lookupFunction` at `src/query/src/compiler.zig:1018`.
fn lookupUserFunc(w: *Walker, name: []const u8, arity: u8) ?usize {
    var i = w.func_table.items.len;
    while (i > 0) {
        i -= 1;
        if (w.func_hidden_start) |start| {
            if (w.func_hidden_end) |end| {
                if (i >= start and i < end) continue;
            }
        }
        const entry = &w.func_table.items[i];
        if (entry.paramCount() == arity and std.mem.eql(u8, entry.name, name)) {
            return i;
        }
    }
    return null;
}

/// Handle bare-ident lookup in the walker: filter bindings first, then
/// recursive self-call (if we're emitting a recursive body), then user
/// function (zero-arg) lookup. Returns true if the walker dispatched the
/// emission; false if the caller should fall through to load_key.
fn tryDispatchBareIdent(
    w: *Walker,
    name: []const u8,
    span: ast.Span,
) Walker.Error!bool {
    // During the initial body-scan pass (`scanning_body=true`), skip
    // user-function expansion. This matches legacy's `scanning_body`
    // guard at `src/query/src/compiler.zig:6230` which only dispatches
    // user-func calls when NOT scanning. The body-scan emits a
    // `load_key` placeholder (our caller's default) whose raw-buffer
    // entries are discarded when the scan returns.
    if (w.scanning_body) return false;

    // Filter-arg binding (innermost first) — the body references a filter
    // parameter by name, so re-emit the caller's arg AST subtree. Legacy
    // mirror: `src/query/src/compiler.zig:6200-6227`.
    var bk = w.filter_bindings.items.len;
    while (bk > 0) {
        bk -= 1;
        const binding = &w.filter_bindings.items[bk];
        if (std.mem.eql(u8, binding.name, name)) {
            try expandFilterArg(w, binding.*);
            return true;
        }
    }

    // Recursive self-call: the walker is currently emitting a function's
    // recursive body, and the body references the function itself. Emit
    // `call_function(recursive_body_ip)` directly (no re-expansion). Legacy
    // mirror: `src/query/src/compiler.zig:6234-6241`.
    if (w.expanding_recursive_func) |expanding_idx| {
        const exp = &w.func_table.items[expanding_idx];
        if (exp.paramCount() == 0 and std.mem.eql(u8, exp.name, name)) {
            try w.emit(
                .call_function,
                .{ .index = @intCast(exp.recursive_body_ip) },
                span.start,
            );
            return true;
        }
    }

    // Zero-arg user function lookup.
    if (lookupUserFunc(w, name, 0)) |idx| {
        try expandFunctionCall(w, idx, &.{}, span);
        return true;
    }

    // Stage 11: zero-arg builtins that the AST parser doesn't list in
    // `isZeroArgBuiltin` (e.g. `now`, `gmtime`, `env`, `debug`, trim, etc.)
    // arrive here as bare-ident `field_access` nodes. Legacy resolves them
    // via the full `zeroArgBuiltinId` table (compiler.zig:2874-2991) BEFORE
    // emitting `load_key`. Mirror by consulting the walker's `zeroArgBuiltinId`
    // (extended to match legacy's full table) after the user-func check.
    if (zeroArgBuiltinId(name)) |bid| {
        try w.emit(.call_builtin, .{ .index = @intFromEnum(bid) }, span.start);
        return true;
    }

    return false;
}

/// Expand a filter-arg binding: re-walk the caller's AST subtree with the
/// filter_bindings stack temporarily truncated to `binding.hide_from_index`.
/// This prevents a pass-through binding (`g: f; ...`) from recursing into
/// itself. Mirrors legacy's source-range re-parse at
/// `src/query/src/compiler.zig:6211-6226`, but replaces source re-parse
/// with AST subtree re-walk.
fn expandFilterArg(w: *Walker, binding: FilterBinding) Walker.Error!void {
    const saved_len = w.filter_bindings.items.len;
    w.filter_bindings.items.len = binding.hide_from_index;
    defer w.filter_bindings.items.len = saved_len;
    try w.walk(binding.arg_node);
}

/// Detect whether a function's AST body references the function itself (by
/// name, zero-arg). Mirrors the effect of legacy's `is_recursive` detection
/// at `src/query/src/compiler.zig:6753-6778` which scans the processed body
/// for `load_key(name)` matches. For the AST walker, a self-reference shows
/// up as a `field_access`/`func_call` whose `name` matches, plus the
/// function must not be shadowed by an inner `def` of the same name+arity.
///
/// Only arity-0 recursion is detected: legacy's is_recursive flag is only
/// set for arity 0 (see `compiler.zig:6757`). Higher-arity recursion is
/// handled by normal expansion (which, thanks to `expanding_recursive_func`,
/// emits call_function instead of re-expanding).
fn detectRecursion(
    name: []const u8,
    body: *const Node,
    arity: u8,
) bool {
    if (arity != 0) return false;
    return astContainsSelfRef(body, name, false);
}

/// Recursively scan an AST subtree for a zero-arg self-reference by name.
/// Skips the body of inner `def` nodes that SHADOW the target name, so an
/// inner `def foo: ...; foo` doesn't falsely flag an outer `def foo` as
/// recursive when the outer's body only contains calls to the inner shadow.
/// `inside_shadow` tracks whether the current subtree is under a shadowing
/// def and therefore can't contribute a self-ref.
fn astContainsSelfRef(node: *const Node, name: []const u8, inside_shadow: bool) bool {
    switch (node.kind) {
        .field_access => |fa| {
            if (inside_shadow) return false;
            return std.mem.eql(u8, fa.name, name);
        },
        .func_call => |fc| {
            // Zero-arg user-func calls: `f` with no args — matches recursion.
            // Non-zero-arg calls are higher-arity; ignore per legacy.
            if (!inside_shadow and fc.args.len == 0 and std.mem.eql(u8, fc.name, name)) {
                return true;
            }
            for (fc.args) |arg| {
                if (astContainsSelfRef(arg, name, inside_shadow)) return true;
            }
            return false;
        },
        .builtin_call => |bc| {
            for (bc.args) |arg| {
                if (astContainsSelfRef(arg, name, inside_shadow)) return true;
            }
            return false;
        },
        .func_def => |fd| {
            // Inner def — if its name shadows the target AND same arity (0),
            // the inner body CANNOT reference the target. The inner's rest
            // continues normally but with `inside_shadow` set ONLY for the
            // inner's body.
            const shadows = std.mem.eql(u8, fd.name, name) and fd.params.len == 0;
            const body_shadow = inside_shadow or shadows;
            if (astContainsSelfRef(fd.body, name, body_shadow)) return true;
            return astContainsSelfRef(fd.rest, name, inside_shadow);
        },
        .pipe => |p| {
            return astContainsSelfRef(p.left, name, inside_shadow) or
                astContainsSelfRef(p.right, name, inside_shadow);
        },
        .comma => |c| {
            return astContainsSelfRef(c.left, name, inside_shadow) or
                astContainsSelfRef(c.right, name, inside_shadow);
        },
        .arithmetic => |a| {
            return astContainsSelfRef(a.left, name, inside_shadow) or
                astContainsSelfRef(a.right, name, inside_shadow);
        },
        .comparison => |c| {
            return astContainsSelfRef(c.left, name, inside_shadow) or
                astContainsSelfRef(c.right, name, inside_shadow);
        },
        .and_expr, .or_expr, .alternative => |b| {
            return astContainsSelfRef(b.left, name, inside_shadow) or
                astContainsSelfRef(b.right, name, inside_shadow);
        },
        .unary_neg, .paren, .optional => |u| {
            return astContainsSelfRef(u.operand, name, inside_shadow);
        },
        .as_pattern => |ap| {
            return astContainsSelfRef(ap.expr, name, inside_shadow) or
                astContainsSelfRef(ap.body, name, inside_shadow);
        },
        .destruct_alt => |da| {
            return astContainsSelfRef(da.expr, name, inside_shadow) or
                astContainsSelfRef(da.body, name, inside_shadow);
        },
        .if_expr => |ife| {
            if (astContainsSelfRef(ife.cond, name, inside_shadow)) return true;
            if (astContainsSelfRef(ife.then_body, name, inside_shadow)) return true;
            for (ife.elif_chains) |ec| {
                if (astContainsSelfRef(ec.cond, name, inside_shadow)) return true;
                if (astContainsSelfRef(ec.body, name, inside_shadow)) return true;
            }
            if (ife.else_body) |eb| {
                if (astContainsSelfRef(eb, name, inside_shadow)) return true;
            }
            return false;
        },
        .try_catch => |tc| {
            if (astContainsSelfRef(tc.body, name, inside_shadow)) return true;
            if (tc.catch_body) |cb| {
                if (astContainsSelfRef(cb, name, inside_shadow)) return true;
            }
            return false;
        },
        .suffix => |sfx| {
            if (astContainsSelfRef(sfx.base, name, inside_shadow)) return true;
            for (sfx.ops) |op| switch (op) {
                .bracket_expr => |expr| {
                    if (astContainsSelfRef(expr, name, inside_shadow)) return true;
                },
                else => {},
            };
            return false;
        },
        .array_construct => |ac| {
            if (ac.expr) |e| return astContainsSelfRef(e, name, inside_shadow);
            return false;
        },
        .object_construct => |oc| {
            for (oc.fields) |field| {
                switch (field.key) {
                    .expr => |kn| {
                        if (astContainsSelfRef(kn, name, inside_shadow)) return true;
                    },
                    else => {},
                }
                if (astContainsSelfRef(field.value, name, inside_shadow)) return true;
            }
            return false;
        },
        .string_interp => |si| {
            for (si.parts) |p| switch (p) {
                .expr => |e| {
                    if (astContainsSelfRef(e, name, inside_shadow)) return true;
                },
                else => {},
            };
            return false;
        },
        .format_string => |fs| {
            for (fs.parts) |p| switch (p) {
                .expr => |e| {
                    if (astContainsSelfRef(e, name, inside_shadow)) return true;
                },
                else => {},
            };
            return false;
        },
        .update_assign => |ua| {
            return astContainsSelfRef(ua.rhs, name, inside_shadow);
        },
        .assign_general => |ag| {
            return astContainsSelfRef(ag.lhs, name, inside_shadow) or
                astContainsSelfRef(ag.rhs, name, inside_shadow);
        },
        .reduce => |r| {
            return astContainsSelfRef(r.expr, name, inside_shadow) or
                astContainsSelfRef(r.init, name, inside_shadow) or
                astContainsSelfRef(r.update, name, inside_shadow);
        },
        .foreach => |fe| {
            if (astContainsSelfRef(fe.expr, name, inside_shadow)) return true;
            if (astContainsSelfRef(fe.init, name, inside_shadow)) return true;
            if (astContainsSelfRef(fe.update, name, inside_shadow)) return true;
            if (fe.extract) |ex| {
                if (astContainsSelfRef(ex, name, inside_shadow)) return true;
            }
            return false;
        },
        .label_expr => |le| {
            return astContainsSelfRef(le.body, name, inside_shadow);
        },
        .identity,
        .recurse,
        .iterate,
        .slice,
        .literal,
        .variable_ref,
        .index_access,
        .break_expr,
        .error_node,
        => return false,
    }
}

/// Emit a `func_def` node: register the function entry and walk the
/// continuation. Mirrors legacy `parseFunctionDef` at
/// `src/query/src/compiler.zig:6614`, but operates on AST instead of tokens.
fn emitFuncDef(w: *Walker, fd: Node.FuncDef) Walker.Error!void {
    // Allocate parse-time var_ids for value params in source order.
    // Legacy: `src/query/src/compiler.zig:6642-6648`. Filter params don't
    // get a parse-time id.
    var params = try w.alloc.alloc(FuncParam, fd.params.len);
    errdefer w.alloc.free(params);
    for (fd.params, 0..) |p, i| {
        const parse_id: u32 = if (p.is_filter) 0 else blk: {
            const id = w.next_var_id;
            w.next_var_id += 1;
            break :blk id;
        };
        params[i] = .{
            .name = p.name,
            .is_filter = p.is_filter,
            .parse_var_id = parse_id,
            .body_scope_var_id = 0, // filled below
        };
    }

    // Enter a body scope. For every param (filter OR value), legacy's
    // body-scope loop at `src/query/src/compiler.zig:6695-6702` calls
    // `declareVariable` — burning one var_id per param. Value params
    // also emit `load_variable(body_scope_var_id)` in the BODY during
    // legacy's initial scan; filter params stay as load_key and are
    // post-processed to call_filter_arg. We record body_scope_var_id so
    // the walker's next_var_id counter matches legacy's, though the AST
    // walker's non-recursive path doesn't emit load_variable with this id
    // (the call-site path uses the fresh capture var_id instead).
    try pushScope(w);
    for (params) |*p| {
        const id = w.next_var_id;
        w.next_var_id += 1;
        p.body_scope_var_id = id;
        try w.scope_vars.append(w.alloc, .{ .name = p.name, .id = id });
    }

    // Record the registration's func_table snapshot BEFORE walking the
    // body. Legacy: `src/query/src/compiler.zig:6705`.
    const func_table_snapshot = w.func_table.items.len;

    // Register the function entry NOW, before walking its rest, so that
    // inner calls (recursive or otherwise) during `rest` can look it up.
    // For the body scan (recursion detection), we check the AST structure —
    // no emission happens yet.
    const is_recursive = detectRecursion(fd.name, fd.body, @intCast(fd.params.len));

    try w.func_table.append(w.alloc, .{
        .name = fd.name,
        .params = params,
        .body_node = fd.body,
        .is_recursive = is_recursive,
        .recursive_body_ip = 0,
        .func_table_snapshot = func_table_snapshot,
    });

    // Simulate legacy's body-scan pass: legacy parses the body into a
    // throwaway raw buffer, which advances `next_var_id` for every `as`
    // pattern / nested def / compound assignment encountered. To keep
    // the walker's var_id counter in lock-step we walk the body here
    // in `scanning_body` mode — user-func expansions are skipped (they
    // emit placeholder `load_key` that gets discarded), but var_id
    // allocations proceed normally.
    const body_raw_start = w.raw.items.len;
    const saved_scanning = w.scanning_body;
    w.scanning_body = true;
    w.walk(fd.body) catch |e| {
        w.scanning_body = saved_scanning;
        w.raw.items.len = body_raw_start;
        // Clean up any inner defs that the scan registered.
        while (w.func_table.items.len > func_table_snapshot + 1) {
            const removed = w.func_table.pop() orelse unreachable;
            w.alloc.free(removed.params);
        }
        return e;
    };
    w.scanning_body = saved_scanning;
    w.raw.items.len = body_raw_start;

    // Remove any inner defs registered during the scan — they're scoped
    // to the body and re-registered on each expansion. Legacy mirror:
    // `src/query/src/compiler.zig:6783-6786`.
    while (w.func_table.items.len > func_table_snapshot + 1) {
        const removed = w.func_table.pop() orelse unreachable;
        w.alloc.free(removed.params);
    }

    // Pop the body scope: we registered the function but we DON'T emit the
    // body here. The body is walked per-call in `expandFunctionCall`.
    popScope(w);

    // Walk the continuation (code after the `;`). The new function is
    // visible during this walk. Per-def nested-scoping of inner defs is
    // handled when the outer def is expanded (see expandFunctionCall).
    try w.walk(fd.rest);
}

/// Push a new variable scope — records the current scope_vars length so
/// `popScope` can restore to it. Mirrors legacy's `pushScope` at
/// `src/query/src/compiler.zig:290`.
fn pushScope(w: *Walker) error{OutOfMemory}!void {
    try w.scope_marks.append(w.alloc, w.scope_vars.items.len);
}

/// Pop the most recent variable scope. Truncates `scope_vars` to the mark
/// set by the matching `pushScope`. `next_var_id` is NOT rolled back —
/// legacy leaks var_ids the same way. Mirrors `popScope` at
/// `src/query/src/compiler.zig:301`.
fn popScope(w: *Walker) void {
    const mark = w.scope_marks.pop() orelse unreachable;
    w.scope_vars.items.len = mark;
}

/// Expand a user-function call at the walker's current tail. Mirrors
/// legacy's `expandFunctionCall` at `src/query/src/compiler.zig:1066`.
///
/// `args` are the caller's AST argument subtrees. `call_span` is the span
/// of the full call (used for src_offset stamps that derive from legacy's
/// `last_tok_offset` at various emission points).
fn expandFunctionCall(
    w: *Walker,
    func_idx: usize,
    args: []const *Node,
    call_span: ast.Span,
) Walker.Error!void {
    const entry = &w.func_table.items[func_idx];

    // For byte-identical bytecode with legacy, we need to determine the
    // `ctx.last_tok_offset` at each emission point. Legacy consumes the
    // closing `)` of the call (or nothing if zero-arg), landing at:
    //   - `(`.offset for zero-arg (legacy doesn't emit `(` stamp here; but
    //     zero-arg calls in legacy reach expandFunctionCall after the ident
    //     was consumed, so last_tok = ident.offset).
    //   - `)`.offset for N-arg (last nextToken consumed `)`).
    // For call_span.end: 1-past the `)`. So `)`.offset = call_span.end - 1
    // when the call has parens. Zero-arg: no parens → ident.offset =
    // call_span.end - name.len (but for field_access calls, span ends
    // at one-past ident).
    const has_parens = args.len > 0 or callHasParens(w.src, call_span);
    const close_off: u32 = if (has_parens) call_span.end - 1 else call_span.start;

    // ── Emit value-arg bytecode + capture_variable per value arg. ─────
    // Count value args in definition order (NOT call order). For each
    // value param: evaluate the arg subtree, alloc new_var_id, emit
    // capture_variable. Filter args are recorded as bindings below.
    //
    // Variable holding each value-param's call-site id, indexed by param
    // index.
    var call_var_ids = try w.alloc.alloc(u32, entry.params.len);
    defer w.alloc.free(call_var_ids);
    for (call_var_ids) |*id| id.* = 0;

    for (entry.params, 0..) |p, i| {
        if (p.is_filter) continue;
        if (i >= args.len) continue;

        // Walk the arg AST — emits the arg bytecode into w.raw.
        try w.walk(args[i]);

        // Allocate fresh var_id, emit capture. Legacy stamps capture with
        // `ctx.last_tok_offset` = `)`.offset of the call (set when
        // parseCallExpr consumed `)`).
        const new_id = w.next_var_id;
        w.next_var_id += 1;
        call_var_ids[i] = new_id;
        try w.emit(.capture_variable, .{ .index = @intCast(new_id) }, close_off);
    }

    // ── Emit body. ────────────────────────────────────────────────────
    if (entry.is_recursive) {
        if (entry.recursive_body_ip == 0) {
            // First expansion: emit jump-over-body, the body, return_function,
            // patch jump, then call_function.
            const jump_pos = w.raw.items.len;
            try w.emit(.jump, .{ .index = 0 }, call_span.start);

            const body_start: u32 = @intCast(w.raw.items.len);
            entry.recursive_body_ip = body_start;

            const saved_expanding = w.expanding_recursive_func;
            w.expanding_recursive_func = func_idx;
            defer w.expanding_recursive_func = saved_expanding;

            try emitFunctionBody(w, func_idx, args, call_var_ids);

            // return_function — stamped with last emit (end of body).
            try w.emit(.return_function, .{ .none = {} }, w.last_emit_offset);

            const body_end: u32 = @intCast(w.raw.items.len);
            // Patch the jump to skip over the body.
            w.raw.items[jump_pos].operand = .{ .index = @intCast(body_end) };

            // Invoke the body. Legacy stamps `call_function` with
            // `ctx.last_tok_offset` — after the body's `return_function`
            // emission, that equals the body's final token offset. Mirror
            // via w.last_emit_offset.
            try w.emit(.call_function, .{ .index = @intCast(body_start) }, w.last_emit_offset);
        } else {
            // Subsequent expansion — just emit call_function.
            try w.emit(
                .call_function,
                .{ .index = @intCast(entry.recursive_body_ip) },
                call_span.start,
            );
        }
    } else {
        try emitFunctionBody(w, func_idx, args, call_var_ids);
    }

    // ── Emit pop_variable for each value arg. ─────────────────────────
    // Stamp with last_emit_offset (legacy stamps `ctx.last_tok_offset`
    // which, after body expansion, is the body's final token).
    for (entry.params, 0..) |p, i| {
        if (p.is_filter) continue;
        if (i >= args.len) continue;
        try w.emit(
            .pop_variable,
            .{ .index = @intCast(call_var_ids[i]) },
            w.last_emit_offset,
        );
    }
}

/// Detect whether the call's source range includes a `(...)` — zero-arg
/// user-func calls land here via `field_access`, so `has_parens` is false.
/// Arity ≥ 1 calls arrive via `func_call` and have parens. We detect by
/// scanning forward from call_span.start past the ident to see if the
/// next non-trivia byte is `(`.
fn callHasParens(src: []const u8, call_span: ast.Span) bool {
    var i: u32 = call_span.start;
    // Skip ident bytes.
    while (i < src.len and isIdentByte(src[i])) : (i += 1) {}
    i = skipTrivia(src, i);
    return i < src.len and src[i] == '(';
}

/// Emit a function's body with the caller's filter-arg bindings active and
/// the per-call value-arg var_ids substituted. Pushes a body scope,
/// redeclares each value-param (allocating a throwaway var_id to keep
/// `next_var_id` in lock-step with legacy) and rewrites the scope entry to
/// the caller's `call_var_ids[i]`, then walks the body AST.
fn emitFunctionBody(
    w: *Walker,
    func_idx: usize,
    args: []const *Node,
    call_var_ids: []const u32,
) Walker.Error!void {
    const entry = &w.func_table.items[func_idx];

    // Save & set hidden range for lexical scoping. Legacy's
    // `reParseBodyWithBindings` at `src/query/src/compiler.zig:1171-1176`
    // hides functions defined AFTER this function but before the current
    // re-parse. Stage 9 tracks the snapshot and current length; if the
    // snapshot is less than the current length (i.e. there ARE newer
    // functions that should be hidden), set the hidden range.
    const saved_hidden_start = w.func_hidden_start;
    const saved_hidden_end = w.func_hidden_end;
    const table_len = w.func_table.items.len;
    if (entry.func_table_snapshot < table_len) {
        w.func_hidden_start = entry.func_table_snapshot;
        w.func_hidden_end = table_len;
    }
    defer {
        w.func_hidden_start = saved_hidden_start;
        w.func_hidden_end = saved_hidden_end;
    }

    // Push filter-arg bindings for every filter param. Use the caller's
    // arg AST subtree directly — no source re-parse needed.
    const bindings_start = w.filter_bindings.items.len;
    for (entry.params, 0..) |p, i| {
        if (!p.is_filter) continue;
        if (i >= args.len) continue;
        try w.filter_bindings.append(w.alloc, .{
            .name = p.name,
            .arg_node = args[i],
            // The hide index: filter_bindings length at the moment this
            // binding was pushed. When the binding is expanded, the walker
            // truncates to this index so the arg's own references to
            // earlier bindings (like a pass-through `g: f` call) don't
            // infinite-loop. Mirrors legacy's `bk` truncation at
            // `compiler.zig:6216`.
            .hide_from_index = w.filter_bindings.items.len,
        });
    }
    defer w.filter_bindings.items.len = bindings_start;

    // Push body scope + declare value params to match legacy's var_id burn.
    try pushScope(w);
    defer popScope(w);

    for (entry.params, 0..) |p, i| {
        if (p.is_filter) continue;
        // Allocate a throwaway var_id (next_var_id++) — this matches
        // legacy's `declareVariable` at `compiler.zig:1149` which burns
        // an id and then rewrites the entry to the call-site id. The
        // body's lookupVariable for this param name resolves to
        // call_var_ids[i], but the counter still advanced.
        _ = w.next_var_id;
        w.next_var_id += 1;
        const call_id = if (i < call_var_ids.len) call_var_ids[i] else 0;
        try w.scope_vars.append(w.alloc, .{ .name = p.name, .id = call_id });
    }

    // Walk the body AST. Emissions go to w.raw in sequence.
    try w.walk(entry.body_node);

    // Remove any inner defs registered during the body walk — they're
    // scoped to this expansion only. Legacy mirror:
    // `src/query/src/compiler.zig:1188-1192`.
    while (w.func_table.items.len > table_len) {
        const removed = w.func_table.pop() orelse unreachable;
        w.alloc.free(removed.params);
    }
}

// ── Stage 10a: generator / reducing builtins ───────────────────────────────
//
// Legacy reference: `src/query/src/compiler.zig:5909-6051` dispatch table plus
// `compileSelect` / `compileMap` / `compileMapValues` / `compileWalk` /
// `compileWhile` / `compileUntil` / `compileRepeat` / `compileAnyAll` /
// `compileAddExpr` / `compileFirst` / `compileLast` / `compileFilterArgBuiltin`.
//
// Source-offset policy (all helpers below mirror it exactly):
//   - `lparen_off` — offset of the `(` between the builtin name and its first
//     arg. Legacy stamps `ctx.last_tok_offset` with this value after the
//     `nextToken` that consumes `(`; every emit BEFORE the arg walk picks up
//     `lparen_off`.
//   - Arg walk — `w.walk(arg)` stamps with the arg's own node offsets and
//     updates `w.last_emit_offset` to the arg's final emitted instruction's
//     src_offset (mirrors legacy's last_tok after `parsePipe`).
//   - `rparen_off` — offset of the closing `)` (= `node.span.end - 1`). Legacy
//     consumes `)` via `nextToken`, updating `last_tok_offset = rparen.offset`;
//     every emit AFTER the arg walk (that is not itself from a nested walk)
//     picks up `rparen_off`.
//   - `semi_off` — offset of a `;` separator between semicolon-split args.
//     Scanned via `scanForSkipWs(w.src, prev_arg.span.end, ';')`.
//
// For builtins whose first emit fires AFTER `lparen` consume and before the
// arg walk, stamp with `lparen_off`. For emits AFTER the arg walk that don't
// depend on mid-consume state, stamp with `w.last_emit_offset` (arg's final
// token, matches legacy's last_tok_offset just before the `)` consume) OR
// with `rparen_off` (for emits AFTER the `)` consume).
//
// All helpers return `true` if they handled the call, `false` if the walker
// should fall through to the AstCompilerStageIncomplete default. Stage 10a
// covers a subset of the 26 Stage-10 builtins; names outside this subset
// return `false` so later stages (10b/10c) slot in cleanly.

/// Dispatch a builtin_call node to the matching Stage 10a helper. Returns
/// true on handled (walker emits the builtin's bytecode); false if no match
/// (caller falls through to AstCompilerStageIncomplete). Each helper stamps
/// src_offsets byte-identically with the legacy compiler.
fn dispatchStage10aBuiltin(
    w: *Walker,
    bc: Node.BuiltinCall,
    call_span: ast.Span,
) Walker.Error!bool {
    // Uniform requirement: every Stage 10a builtin requires parens. Args length
    // distinguishes arity variants handled by each helper.
    if (std.mem.eql(u8, bc.name, "select") and bc.args.len == 1) {
        try emitSelect(w, call_span, bc.args[0]);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "map") and bc.args.len == 1) {
        try emitMap(w, call_span, bc.args[0]);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "map_values") and bc.args.len == 1) {
        try emitMapValues(w, call_span, bc.args[0]);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "walk") and bc.args.len == 1) {
        try emitWalk(w, call_span, bc.args[0]);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "while") and bc.args.len == 2) {
        try emitWhileUntil(w, call_span, bc.args[0], bc.args[1], .kw_while);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "until") and bc.args.len == 2) {
        try emitWhileUntil(w, call_span, bc.args[0], bc.args[1], .kw_until);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "repeat") and bc.args.len == 1) {
        try emitRepeat(w, call_span, bc.args[0]);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "any")) {
        if (bc.args.len == 1) {
            try emitAnyAll(w, call_span, bc.args[0], null, .any);
            return true;
        }
        if (bc.args.len == 2) {
            try emitAnyAll(w, call_span, bc.args[0], bc.args[1], .any);
            return true;
        }
    }
    if (std.mem.eql(u8, bc.name, "all")) {
        if (bc.args.len == 1) {
            try emitAnyAll(w, call_span, bc.args[0], null, .all);
            return true;
        }
        if (bc.args.len == 2) {
            try emitAnyAll(w, call_span, bc.args[0], bc.args[1], .all);
            return true;
        }
    }
    if (std.mem.eql(u8, bc.name, "add") and bc.args.len == 1) {
        try emitAddExpr(w, call_span, bc.args[0]);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "first") and bc.args.len == 1) {
        try emitFirstExpr(w, call_span, bc.args[0]);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "last") and bc.args.len == 1) {
        try emitLastExpr(w, call_span, bc.args[0]);
        return true;
    }
    return false;
}

const WhileKind = enum { kw_while, kw_until };
const AnyAllKind = enum { any, all };

/// Locate the offset of the `(` token that opens a builtin call. The AST
/// records `call_span.start = name_tok.offset`; we advance past the name
/// ident bytes and skip trivia to find the `(`.
fn scanBuiltinLparen(src: []const u8, call_span: ast.Span) u32 {
    var i: u32 = call_span.start;
    while (i < src.len and isIdentByte(src[i])) : (i += 1) {}
    const lp = scanForSkipWs(src, i, '(') orelse i;
    return lp;
}

/// `rparen_off` for a builtin call — the AST's span ends one-past the closing
/// `)` (see parser.zig:596 — `const end = p.lex.pos` after `rparen` consume).
fn builtinRparenOff(call_span: ast.Span) u32 {
    return if (call_span.end > call_span.start) call_span.end - 1 else call_span.start;
}

/// Emit `select(f)`. Legacy reference: `compileSelect` at
/// `src/query/src/compiler.zig:3501-3535`. Bytecode:
///   save_input                   [stamp=lparen]
///   <f>                          [arg walk]
///   jump_if_false -> skip        [stamp=rparen]
///   restore_input                [stamp=rparen]
///   jump -> done                 [stamp=rparen]
///   skip:
///   restore_input                [stamp=rparen]
///   backtrack                    [stamp=rparen]
///   done:
fn emitSelect(w: *Walker, call_span: ast.Span, arg: *const Node) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    try w.emit(.save_input, .{ .none = {} }, lparen_off);
    try w.walk(arg);

    const jif_pos = w.raw.items.len;
    try w.emit(.jump_if_false, .{ .index = 0 }, rparen_off);
    try w.emit(.restore_input, .{ .none = {} }, rparen_off);

    const jmp_pos = w.raw.items.len;
    try w.emit(.jump, .{ .index = 0 }, rparen_off);

    // skip:
    const skip_ip: u32 = @intCast(w.raw.items.len);
    w.raw.items[jif_pos].operand = .{ .index = @intCast(skip_ip) };
    try w.emit(.restore_input, .{ .none = {} }, rparen_off);
    try w.emit(.backtrack, .{ .none = {} }, rparen_off);

    // done:
    const done_ip: u32 = @intCast(w.raw.items.len);
    w.raw.items[jmp_pos].operand = .{ .index = @intCast(done_ip) };
}

/// Emit `map(f)`. Legacy reference: `compileMap` at
/// `src/query/src/compiler.zig:3463-3488`. Bytecode:
///   array_collect_start(end)     [stamp=lparen]
///   each                         [stamp=lparen]
///   <f>                          [arg walk]
///   yield_output                 [stamp=arg's last]
///   array_collect_end            [stamp=rparen]
///   (backpatch start operand → end's raw IP)
fn emitMap(w: *Walker, call_span: ast.Span, arg: *const Node) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    const start_pos = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, lparen_off);
    try w.emit(.each, .{ .none = {} }, lparen_off);

    try w.walk(arg);

    try w.emit(.yield_output, .{ .none = {} }, w.last_emit_offset);

    const end_pos: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, rparen_off);
    w.raw.items[start_pos].operand = .{ .index = @intCast(end_pos) };
}

/// Emit `map_values(f)` — legacy routes to `compileFilterArgBuiltin` with
/// `bid = map_values_`. See `compileMapValues` at
/// `src/query/src/compiler.zig:4029-4031` and the generic helper at
/// `:4597-4626`. Bytecode:
///   save_input                       [stamp=lparen]
///   array_collect_start(end)         [stamp=lparen]
///   each                             [stamp=lparen]
///   <f>                              [arg walk]
///   yield_output                     [stamp=arg's last]
///   array_collect_end                [stamp=rparen]
///   call_builtin(map_values_)        [stamp=rparen]
fn emitMapValues(w: *Walker, call_span: ast.Span, arg: *const Node) Walker.Error!void {
    try emitFilterArgBuiltin(w, call_span, arg, .map_values_);
}

/// Generic filter-arg builtin emission. Used directly for `map_values` in
/// Stage 10a; `sort_by` / `group_by` / `min_by` / `max_by` / `unique_by` all
/// share the same shape and can land in a later stage by dispatching here.
fn emitFilterArgBuiltin(
    w: *Walker,
    call_span: ast.Span,
    arg: *const Node,
    bid: types.BuiltinId,
) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    try w.emit(.save_input, .{ .none = {} }, lparen_off);

    const start_pos = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, lparen_off);
    try w.emit(.each, .{ .none = {} }, lparen_off);

    try w.walk(arg);
    try w.emit(.yield_output, .{ .none = {} }, w.last_emit_offset);

    const end_pos: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, rparen_off);
    w.raw.items[start_pos].operand = .{ .index = @intCast(end_pos) };

    try w.emit(.call_builtin, .{ .index = @intFromEnum(bid) }, rparen_off);
}

/// Emit `walk(f)`. Legacy reference: `compileWalk` at
/// `src/query/src/compiler.zig:4976-4994`. Bytecode:
///   walk_start(exit_ip)          [stamp=lparen]
///   <f>                          [arg walk]
///   walk_end                     [stamp=rparen]
///   (backpatch walk_start.exit → raw.len after walk_end)
fn emitWalk(w: *Walker, call_span: ast.Span, arg: *const Node) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    const walk_ip: u32 = @intCast(w.raw.items.len);
    try w.emit(.walk_start, .{ .index = 0 }, lparen_off);

    try w.walk(arg);

    try w.emit(.walk_end, .{ .none = {} }, rparen_off);
    w.raw.items[walk_ip].operand = .{ .index = @intCast(w.raw.items.len) };
}

/// Emit `while(cond; update)` or `until(cond; update)`. Legacy references:
/// `compileWhile` (`:3553-3601`), `compileUntil` (`:3620-3673`). Both share
/// structure; kind-specific differences are the branch layout.
///
/// `while` bytecode:
///   loop_top:
///     save_input                  [stamp=lparen]
///     <cond>                      [arg walk]
///     jump_if_false -> loop_exit  [stamp=semi]
///     restore_input               [stamp=semi]
///     yield_output                [stamp=semi]
///     <update>                    [arg walk]
///     pipe                        [stamp=rparen]
///     jump -> loop_top            [stamp=rparen]
///   loop_exit:
///     restore_input               [stamp=rparen]
///     backtrack                   [stamp=rparen]
///
/// `until` bytecode:
///   loop_top:
///     save_input                  [stamp=lparen]
///     <cond>                      [arg walk]
///     jump_if_false -> loop_body  [stamp=semi]
///     restore_input               [stamp=semi]
///     jump -> loop_done           [stamp=semi]
///   loop_body:
///     restore_input               [stamp=semi]
///     <update>                    [arg walk]
///     pipe                        [stamp=rparen]
///     jump -> loop_top            [stamp=rparen]
///   loop_done:
///     push_current                [stamp=rparen]
fn emitWhileUntil(
    w: *Walker,
    call_span: ast.Span,
    cond: *const Node,
    update: *const Node,
    kind: WhileKind,
) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);
    const semi_off = scanForSkipWs(w.src, cond.span.end, ';') orelse cond.span.end;

    const loop_top: u32 = @intCast(w.raw.items.len);
    try w.emit(.save_input, .{ .none = {} }, lparen_off);

    try w.walk(cond);

    const jif_pos = w.raw.items.len;
    try w.emit(.jump_if_false, .{ .index = 0 }, semi_off);

    switch (kind) {
        .kw_while => {
            // True path: restore + output + update + pipe + jump loop_top.
            try w.emit(.restore_input, .{ .none = {} }, semi_off);
            try w.emit(.yield_output, .{ .none = {} }, semi_off);

            try w.walk(update);

            try w.emit(.pipe, .{ .none = {} }, rparen_off);
            try w.emit(.jump, .{ .index = @intCast(loop_top) }, rparen_off);

            // loop_exit:
            const loop_exit: u32 = @intCast(w.raw.items.len);
            w.raw.items[jif_pos].operand = .{ .index = @intCast(loop_exit) };

            try w.emit(.restore_input, .{ .none = {} }, rparen_off);
            try w.emit(.backtrack, .{ .none = {} }, rparen_off);
        },
        .kw_until => {
            // True path: condition met — restore and jump to done.
            try w.emit(.restore_input, .{ .none = {} }, semi_off);

            const jmp_done_pos = w.raw.items.len;
            try w.emit(.jump, .{ .index = 0 }, semi_off);

            // loop_body:
            const loop_body: u32 = @intCast(w.raw.items.len);
            w.raw.items[jif_pos].operand = .{ .index = @intCast(loop_body) };

            try w.emit(.restore_input, .{ .none = {} }, semi_off);
            try w.walk(update);

            try w.emit(.pipe, .{ .none = {} }, rparen_off);
            try w.emit(.jump, .{ .index = @intCast(loop_top) }, rparen_off);

            // loop_done:
            const loop_done: u32 = @intCast(w.raw.items.len);
            w.raw.items[jmp_done_pos].operand = .{ .index = @intCast(loop_done) };

            try w.emit(.push_current, .{ .none = {} }, rparen_off);
        },
    }
}

/// Emit `repeat(f)`. Legacy reference: `compileRepeat` at
/// `src/query/src/compiler.zig:3684-3705`. Bytecode:
///   loop_top:
///     yield_output                [stamp=lparen]
///     <f>                         [arg walk]
///     pipe                        [stamp=rparen]
///     jump -> loop_top            [stamp=rparen]
/// Infinite loop — bounded by caller (`limit`, `first`, `label`/`break`).
fn emitRepeat(w: *Walker, call_span: ast.Span, arg: *const Node) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    const loop_top: u32 = @intCast(w.raw.items.len);
    try w.emit(.yield_output, .{ .none = {} }, lparen_off);

    try w.walk(arg);

    try w.emit(.pipe, .{ .none = {} }, rparen_off);
    try w.emit(.jump, .{ .index = @intCast(loop_top) }, rparen_off);
}

/// Emit `any(f)` / `all(f)` / `any(gen; cond)` / `all(gen; cond)`. Legacy
/// reference: `compileAnyAll` at `src/query/src/compiler.zig:4667-4708`.
///
/// 1-arg bytecode:
///   array_collect_start(end)     [stamp=lparen]
///   each                         [INSERTED at start+1, stamp=0 default]
///   <f>                          [arg walk]
///   yield_output                 [stamp=arg's last]
///   array_collect_end            [stamp=rparen]
///   pipe                         [stamp=rparen]
///   call_builtin(any|all)        [stamp=rparen]
///
/// Legacy uses `insertRawInstr(start_pos + 1, each)` AFTER the arg walk, so
/// the inserted `each`'s src_offset = 0 (RawInstr literal default). All
/// jump/fork IPs inside the arg that pointed past `start_pos+1` get bumped
/// by +1 — this is the key reason for the `insertRawInstr` approach.
///
/// 2-arg bytecode:
///   array_collect_start(end)     [stamp=lparen]
///   <gen>                        [arg walk]
///   pipe                         [stamp=semi]
///   <cond>                       [arg walk]
///   yield_output                 [stamp=cond's last]
///   array_collect_end            [stamp=rparen]
///   pipe                         [stamp=rparen]
///   call_builtin(any|all)        [stamp=rparen]
fn emitAnyAll(
    w: *Walker,
    call_span: ast.Span,
    first: *const Node,
    maybe_second: ?*const Node,
    kind: AnyAllKind,
) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    const start_pos = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, lparen_off);

    try w.walk(first);

    if (maybe_second) |second| {
        const semi_off = scanForSkipWs(w.src, first.span.end, ';') orelse first.span.end;
        try w.emit(.pipe, .{ .none = {} }, semi_off);
        try w.walk(second);
    } else {
        // 1-arg form — insert `each` AFTER the arg walk at start_pos+1.
        // Legacy's `insertRawInstr` emits with src_offset=0 (default).
        try insertRawInstr(w, start_pos + 1, .{
            .op = .each,
            .operand = .{ .none = {} },
            .src_offset = 0,
        });
    }

    try w.emit(.yield_output, .{ .none = {} }, w.last_emit_offset);

    const end_pos: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, rparen_off);
    w.raw.items[start_pos].operand = .{ .index = @intCast(end_pos) };

    try w.emit(.pipe, .{ .none = {} }, rparen_off);
    const bid: types.BuiltinId = switch (kind) {
        .any => .any,
        .all => .all,
    };
    try w.emit(.call_builtin, .{ .index = @intFromEnum(bid) }, rparen_off);
}

/// Emit `add(f)` — parens form that collects a generator into an array then
/// calls the zero-arg `add` builtin. Legacy reference: `compileAddExpr` at
/// `src/query/src/compiler.zig:4718-4754`. Bytecode:
///   save_input                   [stamp=lparen]
///   array_collect_start(end)     [stamp=lparen]
///   <f>                          [arg walk]
///   yield_output                 [stamp=arg's last]
///   array_collect_end            [stamp=rparen]
///   pipe                         [stamp=rparen]
///   call_builtin(add)            [stamp=rparen]
///   restore_input                [stamp=rparen]
fn emitAddExpr(w: *Walker, call_span: ast.Span, arg: *const Node) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    try w.emit(.save_input, .{ .none = {} }, lparen_off);

    const start_pos = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, lparen_off);

    try w.walk(arg);
    try w.emit(.yield_output, .{ .none = {} }, w.last_emit_offset);

    const end_pos: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, rparen_off);
    w.raw.items[start_pos].operand = .{ .index = @intCast(end_pos) };

    try w.emit(.pipe, .{ .none = {} }, rparen_off);
    try w.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.add) }, rparen_off);
    try w.emit(.restore_input, .{ .none = {} }, rparen_off);
}

/// Emit `first(f)`. Legacy reference: `compileFirst` at
/// `src/query/src/compiler.zig:4758-4780`. Desugars to `limit(1; f)` using
/// the streaming `limit_start` opcode. Bytecode:
///   push_int(1)                  [stamp=lparen]
///   limit_start(exit_ip)         [stamp=lparen]
///   <f>                          [arg walk]
///   yield_output                 [stamp=rparen]
///   (backpatch limit_start.exit → raw.len after yield)
///
/// Stamp note: legacy's `ctx.nextToken()` consumes the closing `)` BEFORE
/// the final `emit(yield_output, …)`, so `yield_output.src_offset =
/// rparen.offset`. The walker matches by stamping `rparen_off` explicitly
/// rather than falling through to `w.last_emit_offset` (which would be the
/// arg's last token offset — wrong by the legacy's exact emission order).
fn emitFirstExpr(w: *Walker, call_span: ast.Span, arg: *const Node) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    try w.emit(.push_int, .{ .int = 1 }, lparen_off);

    const limit_ip: u32 = @intCast(w.raw.items.len);
    try w.emit(.limit_start, .{ .index = 0 }, lparen_off);

    try w.walk(arg);

    try w.emit(.yield_output, .{ .none = {} }, rparen_off);

    w.raw.items[limit_ip].operand = .{ .index = @intCast(w.raw.items.len) };
}

/// Emit `last(f)`. Legacy reference: `compileLast` at
/// `src/query/src/compiler.zig:4783-4804`. Collects `[f]` into an array then
/// loads index -1. Bytecode:
///   array_collect_start(end)     [stamp=lparen]
///   <f>                          [arg walk]
///   yield_output                 [stamp=arg's last]
///   array_collect_end            [stamp=rparen]
///   pipe                         [stamp=rparen]
///   load_index(-1)               [stamp=rparen]
fn emitLastExpr(w: *Walker, call_span: ast.Span, arg: *const Node) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    const start_pos = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, lparen_off);

    try w.walk(arg);
    try w.emit(.yield_output, .{ .none = {} }, w.last_emit_offset);

    const end_pos: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, rparen_off);
    w.raw.items[start_pos].operand = .{ .index = @intCast(end_pos) };

    try w.emit(.pipe, .{ .none = {} }, rparen_off);
    try w.emit(.load_index, .{ .index = -1 }, rparen_off);
}

// ── Stage 10b: reduce / foreach / label / break / range / limit / skip / nth ──
//
// Legacy references:
//   - `compileReduce`       @ src/query/src/compiler.zig:4090
//   - `compileForeach`      @ :4246
//   - `compileLabel`        @ :3753 + `break_kw` handler @ :6370
//   - `compileRange`        @ :4442
//   - `compileLimit`        @ :4809
//   - `compileSkip`         @ :4999
//   - `compileNth`          @ :5049
//
// Variable-id allocation order policy (matches legacy byte-for-byte):
//   - reduce:  saved_input_id, acc_id, then pattern vars (in pattern DFS order).
//   - foreach: saved_input_id, acc_id, then pattern vars (in pattern DFS order).
//   - label:   declareVariable($name) — one id.
//   - limit/skip/nth: input_var_id (one hidden id per call site).
//   - range:   none (no hidden vars).
//
// Source-offset policy mirrors legacy's `ctx.last_tok_offset` as it evolves
// through token consumption. The walker reconstructs each stamp by scanning
// source bytes for keyword/delimiter offsets and tracking `w.last_emit_offset`
// after each sub-walk. Key offsets:
//   - reduce: `reduce` kw offset = node.span.start.
//   - after EXPR walk: EXPR's last emit offset.
//   - after INIT walk: INIT's last emit offset (splice of EXPR between INIT
//     and pattern capture does NOT update last_emit_offset in legacy, and
//     the walker mirrors by NOT bumping w.last_emit_offset during splice).
//   - after UPDATE walk: UPDATE's last emit offset.
//   - `)` offset = node.span.end - 1.

/// `reduce E as P (INIT; UPDATE)`.
///
/// Bytecode (byte-identical to legacy `compileReduce`):
///   push_current                  @ reduce_kw
///   capture_variable(saved)       @ reduce_kw
///   <EXPR walk in place>
///   [capture+truncate EXPR buffer]
///   <INIT walk>                   stamps by INIT
///   capture_variable(acc)         @ init_last
///   load_variable(saved)          @ init_last
///   pipe                          @ init_last
///   fork L_done                   @ init_last (backpatched)
///   <splice EXPR>                 (src_offsets preserved from EXPR walk)
///   emitPatternCapture(pattern)   @ init_last
///   load_variable(acc)            @ init_last
///   pipe                          @ init_last
///   <UPDATE walk>                 stamps by UPDATE
///   capture_variable(acc)         @ update_last
///   backtrack                     @ update_last
///   L_done:
///   load_variable(acc)            @ rparen
///   pop_variable(pattern vars ...) — reverse pattern-id order, @ rparen
///   pop_variable(acc)             @ rparen
fn emitReduce(w: *Walker, call_span: ast.Span, r: Node.Reduce) Walker.Error!void {
    const reduce_off = call_span.start;
    const rparen_off = if (call_span.end > call_span.start) call_span.end - 1 else call_span.start;

    // Hidden var id allocation mirrors legacy order: saved_input_id then acc_id.
    const saved_input_id = w.next_var_id;
    w.next_var_id += 1;
    const acc_id = w.next_var_id;
    w.next_var_id += 1;

    try w.emit(.push_current, .{ .none = {} }, reduce_off);
    try w.emit(.capture_variable, .{ .index = @intCast(saved_input_id) }, reduce_off);

    // Walk EXPR in place, then capture + truncate into a temp buffer so it
    // can be spliced after INIT (legacy ordering via `rebaseExprBuf`).
    const expr_start: usize = w.raw.items.len;
    try w.walk(r.expr);
    const expr_end: usize = w.raw.items.len;

    const captured = try captureAndTruncate(w, expr_start, expr_end);
    defer w.alloc.free(captured.instrs);

    // Declare pattern variables in a new scope. Legacy's
    // `scanAndDeclarePattern` allocates ids in pattern DFS order; the walker
    // does the same via `declarePatternVars`.
    try pushScope(w);
    defer popScope(w);
    try declarePatternVars(w, r.pattern);

    // Walk INIT — emits with INIT's own src_offsets; w.last_emit_offset ends
    // at INIT's final emit.
    try w.walk(r.init);
    const init_last = w.last_emit_offset;

    try w.emit(.capture_variable, .{ .index = @intCast(acc_id) }, init_last);
    try w.emit(.load_variable, .{ .index = @intCast(saved_input_id) }, init_last);
    try w.emit(.pipe, .{ .none = {} }, init_last);

    const fork_pos = w.raw.items.len;
    try w.emit(.fork, .{ .index = 0 }, init_last);

    // Splice EXPR back. `appendRebasedInstrsCopy` updates w.last_emit_offset
    // to EXPR's final emitted src_offset; we restore init_last before the
    // subsequent emit so the following stamps match legacy (which keeps
    // ctx.last_tok_offset at INIT's last tok across the splice — splice does
    // not go through emit and thus does not mutate ctx.last_tok_offset).
    try appendRebasedInstrsCopy(w, captured);
    w.last_emit_offset = init_last;

    try emitPatternCapture(w, r.pattern, init_last);
    try w.emit(.load_variable, .{ .index = @intCast(acc_id) }, init_last);
    try w.emit(.pipe, .{ .none = {} }, init_last);

    // Walk UPDATE — stamps by UPDATE's tokens.
    try w.walk(r.update);
    const update_last = w.last_emit_offset;

    try w.emit(.capture_variable, .{ .index = @intCast(acc_id) }, update_last);
    try w.emit(.backtrack, .{ .none = {} }, update_last);

    // L_done: backpatch the earlier fork.
    const l_done: u32 = @intCast(w.raw.items.len);
    w.raw.items[fork_pos].operand = .{ .index = @intCast(l_done) };

    try w.emit(.load_variable, .{ .index = @intCast(acc_id) }, rparen_off);

    // Pop pattern vars in reverse pattern-id order, then acc_id.
    var pvar_ids: std.ArrayList(u32) = .{};
    defer pvar_ids.deinit(w.alloc);
    try collectPatternVarIds(w, r.pattern, &pvar_ids);
    var pi = pvar_ids.items.len;
    while (pi > 0) {
        pi -= 1;
        try w.emit(.pop_variable, .{ .index = @intCast(pvar_ids.items[pi]) }, rparen_off);
    }
    try w.emit(.pop_variable, .{ .index = @intCast(acc_id) }, rparen_off);
}

/// `foreach E as P (INIT; UPDATE)` (2-arg) or
/// `foreach E as P (INIT; UPDATE; EXTRACT)` (3-arg).
///
/// Bytecode (byte-identical to legacy `compileForeach`):
///   push_current                  @ foreach_kw
///   capture_variable(saved)       @ foreach_kw
///   <EXPR walk in place>
///   [capture+truncate EXPR buffer]
///   <INIT walk>                   stamps by INIT
///   capture_variable(acc)         @ init_last
///   load_variable(saved)          @ init_last
///   pipe                          @ init_last
///   array_collect_start(ACE)      @ semi (between INIT and UPDATE)
///   fork L_done                   @ semi (backpatched)
///   <splice EXPR>                 (src_offsets from EXPR walk)
///   emitPatternCapture(pattern)   @ semi
///   load_variable(acc)            @ semi
///   pipe                          @ semi
///   <UPDATE walk>
///   capture_variable(acc)         @ update_last
///   [2-arg form] load_variable(acc); yield_output  @ update_last
///   [3-arg form] load_variable(acc); pipe; <EXTRACT>; yield_output
///   backtrack                     @ update_last or extract_last
///   L_done:
///   array_collect_end             @ rparen
///   pipe                          @ rparen
///   pop_variable(pattern vars ...) @ rparen
///   pop_variable(acc)             @ rparen
///   each                          @ rparen
fn emitForeach(w: *Walker, call_span: ast.Span, f: Node.Foreach) Walker.Error!void {
    const foreach_off = call_span.start;
    const rparen_off = if (call_span.end > call_span.start) call_span.end - 1 else call_span.start;

    const saved_input_id = w.next_var_id;
    w.next_var_id += 1;
    const acc_id = w.next_var_id;
    w.next_var_id += 1;

    try w.emit(.push_current, .{ .none = {} }, foreach_off);
    try w.emit(.capture_variable, .{ .index = @intCast(saved_input_id) }, foreach_off);

    const expr_start: usize = w.raw.items.len;
    try w.walk(f.expr);
    const expr_end: usize = w.raw.items.len;

    const captured = try captureAndTruncate(w, expr_start, expr_end);
    defer w.alloc.free(captured.instrs);

    try pushScope(w);
    defer popScope(w);
    try declarePatternVars(w, f.pattern);

    try w.walk(f.init);
    const init_last = w.last_emit_offset;

    try w.emit(.capture_variable, .{ .index = @intCast(acc_id) }, init_last);
    try w.emit(.load_variable, .{ .index = @intCast(saved_input_id) }, init_last);
    try w.emit(.pipe, .{ .none = {} }, init_last);

    // Legacy consumes the `;` between INIT and UPDATE between the pipe emit
    // and the array_collect_start emit, so array_collect_start and fork are
    // stamped at `;`.offset. Locate the first `;` after INIT's source range.
    const semi_off = scanForSkipWs(w.src, f.init.span.end, ';') orelse f.init.span.end;

    const ace_start = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, semi_off);

    const fork_pos = w.raw.items.len;
    try w.emit(.fork, .{ .index = 0 }, semi_off);

    try appendRebasedInstrsCopy(w, captured);
    w.last_emit_offset = semi_off;

    try emitPatternCapture(w, f.pattern, semi_off);
    try w.emit(.load_variable, .{ .index = @intCast(acc_id) }, semi_off);
    try w.emit(.pipe, .{ .none = {} }, semi_off);

    try w.walk(f.update);
    const update_last = w.last_emit_offset;

    try w.emit(.capture_variable, .{ .index = @intCast(acc_id) }, update_last);

    if (f.extract) |extract| {
        // 3-arg form. Legacy consumes `;` between UPDATE and EXTRACT →
        // last_tok = `;`.offset, then load_variable and pipe stamp there,
        // then EXTRACT's walk proceeds.
        const semi2_off = scanForSkipWs(w.src, f.update.span.end, ';') orelse f.update.span.end;
        try w.emit(.load_variable, .{ .index = @intCast(acc_id) }, semi2_off);
        try w.emit(.pipe, .{ .none = {} }, semi2_off);
        try w.walk(extract);
        const extract_last = w.last_emit_offset;
        try w.emit(.yield_output, .{ .none = {} }, extract_last);
        try w.emit(.backtrack, .{ .none = {} }, extract_last);
    } else {
        // 2-arg form. Output accumulator directly. Legacy emits
        // load_variable+yield_output+backtrack all stamped at UPDATE's last
        // token (no `;` consumed in this branch — `)` is consumed only
        // after backtrack).
        try w.emit(.load_variable, .{ .index = @intCast(acc_id) }, update_last);
        try w.emit(.yield_output, .{ .none = {} }, update_last);
        try w.emit(.backtrack, .{ .none = {} }, update_last);
    }

    const l_done: u32 = @intCast(w.raw.items.len);
    w.raw.items[fork_pos].operand = .{ .index = @intCast(l_done) };

    const ace_end: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, rparen_off);
    w.raw.items[ace_start].operand = .{ .index = @intCast(ace_end) };

    try w.emit(.pipe, .{ .none = {} }, rparen_off);

    var pvar_ids: std.ArrayList(u32) = .{};
    defer pvar_ids.deinit(w.alloc);
    try collectPatternVarIds(w, f.pattern, &pvar_ids);
    var pi = pvar_ids.items.len;
    while (pi > 0) {
        pi -= 1;
        try w.emit(.pop_variable, .{ .index = @intCast(pvar_ids.items[pi]) }, rparen_off);
    }
    try w.emit(.pop_variable, .{ .index = @intCast(acc_id) }, rparen_off);

    try w.emit(.each, .{ .none = {} }, rparen_off);
}

/// `label $name | body`.
///
/// Bytecode (byte-identical to legacy `compileLabel`):
///   label_begin(exit_ip)    @ name_tok   (backpatched)
///   capture_variable(vid)   @ name_tok
///   pipe                    @ `|`.offset
///   <body walk>
///   — no label_end / pop_variable (legacy intentionally leaves the label
///     frame live; see `compileLabel` comment at compiler.zig:3785-3793).
fn emitLabel(w: *Walker, call_span: ast.Span, le: Node.LabelExpr) Walker.Error!void {
    const label_kw_off = call_span.start;
    const name_off = scanLabelNameOffset(w.src, label_kw_off);

    try pushScope(w);
    defer popScope(w);
    const var_id = try declareVariable(w, le.name);
    try w.label_var_ids.append(w.alloc, var_id);

    const label_begin_pos = w.raw.items.len;
    try w.emit(.label_begin, .{ .index = 0 }, name_off);
    try w.emit(.capture_variable, .{ .index = @intCast(var_id) }, name_off);

    // Locate the `|` between the label decl and the body.
    const pipe_off = scanForSkipWs(w.src, le.body.span.start -| 1, '|') orelse scanBackForPipe(w.src, name_off, le.body.span.start);
    try w.emit(.pipe, .{ .none = {} }, pipe_off);

    try w.walk(le.body);

    // Backpatch label_begin's exit_ip to raw.len (end of body).
    w.raw.items[label_begin_pos].operand = .{ .index = @intCast(w.raw.items.len) };
}

/// `break $name`.
///
/// Bytecode (byte-identical to legacy `break_kw` branch at compiler.zig:6370):
///   load_variable(var_id)   @ name_tok
///   break_op                @ name_tok
/// Compile-time verification: the variable must have been declared by a
/// `label` (not a plain `as` binding). Legacy raises query_syntax_error with
/// `offset = name_tok.offset, len = 0` otherwise.
fn emitBreak(w: *Walker, call_span: ast.Span, be: Node.BreakExpr) Walker.Error!void {
    const break_kw_off = call_span.start;
    const name_off = scanBreakNameOffset(w.src, break_kw_off);

    const var_id = lookupVariable(w, be.name) orelse {
        w.compile_err = .{
            .kind = .query_syntax_error,
            .offset = name_off,
            .len = 0,
        };
        return error.AstCompileError;
    };

    var is_label_var = false;
    for (w.label_var_ids.items) |lid| {
        if (lid == var_id) {
            is_label_var = true;
            break;
        }
    }
    if (!is_label_var) {
        w.compile_err = .{
            .kind = .query_syntax_error,
            .offset = name_off,
            .len = 0,
        };
        return error.AstCompileError;
    }

    try w.emit(.load_variable, .{ .index = @intCast(var_id) }, name_off);
    try w.emit(.break_op, .{ .none = {} }, name_off);
}

/// Locate the offset of the name token after `label `. The span starts at
/// `label` kw; scan past 5 bytes + trivia + `$` + trivia to land on the name.
fn scanLabelNameOffset(src: []const u8, label_kw_off: u32) u32 {
    var cursor: u32 = label_kw_off + 5; // past "label"
    cursor = skipTrivia(src, cursor);
    if (cursor < src.len and src[cursor] == '$') cursor += 1;
    cursor = skipTrivia(src, cursor);
    return cursor;
}

/// Locate the offset of the name token after `break `. The span starts at
/// `break` kw; scan past 5 bytes + trivia + `$` + trivia to land on the name.
fn scanBreakNameOffset(src: []const u8, break_kw_off: u32) u32 {
    var cursor: u32 = break_kw_off + 5; // past "break"
    cursor = skipTrivia(src, cursor);
    if (cursor < src.len and src[cursor] == '$') cursor += 1;
    cursor = skipTrivia(src, cursor);
    return cursor;
}

/// Scan backward from `body_start` for the `|` that introduces a label body.
/// Fallback for layouts where the body starts with trivia (e.g. newline).
fn scanBackForPipe(src: []const u8, lo: u32, body_start: u32) u32 {
    var i: usize = body_start;
    while (i > lo) : (i -= 1) {
        if (src[i - 1] == '|') return @intCast(i - 1);
    }
    return lo;
}

// ── Stage 10b dispatch for builtins ────────────────────────────────────────

/// Dispatch a builtin_call node to the Stage 10b helper matching its name/arity.
/// Returns true if handled, false to fall through.
fn dispatchStage10bBuiltin(
    w: *Walker,
    bc: Node.BuiltinCall,
    call_span: ast.Span,
) Walker.Error!bool {
    if (std.mem.eql(u8, bc.name, "range")) {
        if (bc.args.len == 1 or bc.args.len == 2 or bc.args.len == 3) {
            try emitRange(w, call_span, bc.args);
            return true;
        }
    }
    if (std.mem.eql(u8, bc.name, "limit") and bc.args.len == 2) {
        try emitLimit(w, call_span, bc.args[0], bc.args[1]);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "skip") and bc.args.len == 2) {
        try emitSkip(w, call_span, bc.args[0], bc.args[1]);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "nth") and bc.args.len == 2) {
        try emitNth(w, call_span, bc.args[0], bc.args[1]);
        return true;
    }
    return false;
}

/// Emit `range(hi)` / `range(lo; hi)` / `range(lo; hi; step)`. Legacy
/// reference: `compileRange` at `src/query/src/compiler.zig:4442`.
///
/// Each arg is collected into an array (to support generators like `1,2; 3`),
/// then a builtin `range1_gen` / `range2_gen` / `range3_gen` produces the
/// full flat output array which is iterated via `each`.
///
/// Single-arg bytecode:
///   array_collect_start(end) @ lparen
///   <arg>                    @ arg walk
///   yield_output             @ arg_last
///   array_collect_end        @ rparen
///   pipe                     @ rparen
///   call_builtin(range1_gen) @ rparen
///   pipe                     @ rparen
///   each                     @ rparen
///
/// Multi-arg (2/3) bytecode: collect arg1 into array + pipe + save_input,
/// semi, collect arg2 + pipe, (for 3-arg: save_input + semi + collect arg3
/// + pipe), then call_builtin(range{2,3}_gen) + pipe + each.
fn emitRange(w: *Walker, call_span: ast.Span, args: []const *const Node) Walker.Error!void {
    _ = scanBuiltinLparen(w.src, call_span); // compile-only assertion the `(` exists.
    const rparen_off = builtinRparenOff(call_span);

    // Legacy quirk: compileRange runs a depth-0 lookahead that ADVANCES the
    // lexer (consuming every token until it hits a `;` at depth 1 or the
    // closing `)`). The lookahead restores `ctx.lex` to just after `(` but
    // does NOT restore `ctx.last_tok_offset`. Consequence: `parseArgToArray`
    // emits `array_collect_start` stamped at the offset of the last token the
    // lookahead saw — `)`.offset for single-arg, `;`.offset for multi-arg.
    // We mirror this exactly so the harness stays byte-identical.
    const first_stamp: u32 = blk: {
        if (args.len == 1) break :blk rparen_off;
        break :blk scanForSkipWs(w.src, args[0].span.end, ';') orelse rparen_off;
    };

    try parseArgToArrayEmit(w, args[0], first_stamp);
    try w.emit(.pipe, .{ .none = {} }, w.last_emit_offset);

    if (args.len == 1) {
        try w.emit(
            .call_builtin,
            .{ .index = @intFromEnum(types.BuiltinId.range1_gen) },
            rparen_off,
        );
        try w.emit(.pipe, .{ .none = {} }, rparen_off);
        try w.emit(.each, .{ .none = {} }, rparen_off);
        return;
    }

    // Multi-arg: save first array on if_stack so later builtin can pop it.
    // Legacy stamps save_input at `ctx.last_tok_offset` after parseArgToArray's
    // `pipe` (which stamps at its own last-tok) — so stamp at w.last_emit_offset.
    try w.emit(.save_input, .{ .none = {} }, w.last_emit_offset);

    // Legacy consumes `;` BEFORE parseArgToArray for arg[1], so the second
    // array_collect_start stamps at the `;` position.
    const semi1_off = scanForSkipWs(w.src, args[0].span.end, ';') orelse args[0].span.end;
    try parseArgToArrayEmit(w, args[1], semi1_off);
    try w.emit(.pipe, .{ .none = {} }, w.last_emit_offset);

    if (args.len == 2) {
        try w.emit(
            .call_builtin,
            .{ .index = @intFromEnum(types.BuiltinId.range2_gen) },
            rparen_off,
        );
        try w.emit(.pipe, .{ .none = {} }, rparen_off);
        try w.emit(.each, .{ .none = {} }, rparen_off);
        return;
    }

    // 3-arg: legacy consumes the 2nd `;` BEFORE emitting save_input, so
    // save_input's stamp = 2nd `;`.offset (not arg[1]'s last tok).
    const semi2_off = scanForSkipWs(w.src, args[1].span.end, ';') orelse args[1].span.end;
    try w.emit(.save_input, .{ .none = {} }, semi2_off);
    try parseArgToArrayEmit(w, args[2], semi2_off);
    try w.emit(.pipe, .{ .none = {} }, w.last_emit_offset);

    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.range3_gen) },
        rparen_off,
    );
    try w.emit(.pipe, .{ .none = {} }, rparen_off);
    try w.emit(.each, .{ .none = {} }, rparen_off);
}

/// Emit the legacy `parseArgToArray` shape for a single arg: wrap the arg's
/// emit in `array_collect_start(end) ... yield_output ; array_collect_end`
/// with the start operand backpatched to the end IP.
///
/// Stamping policy — matches legacy's `parseArgToArray` at
/// `src/query/src/compiler.zig:3445-3459`:
///   - array_collect_start: legacy stamps at `ctx.last_tok_offset` which is
///     `stamp_hint` here (e.g. lparen for the first arg of range, or
///     last_emit_offset after arg-separator emits for later args).
///   - yield_output: stamped at arg's last tok.
///   - array_collect_end: stamped at arg's last tok (legacy never consumes
///     a token between parsePipe return and the end emit — last_tok_offset
///     remains the arg's last tok).
fn parseArgToArrayEmit(
    w: *Walker,
    arg: *const Node,
    stamp_hint: u32,
) Walker.Error!void {
    const start_pos = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, stamp_hint);
    try w.walk(arg);
    const arg_last = w.last_emit_offset;
    try w.emit(.yield_output, .{ .none = {} }, arg_last);
    const end_pos: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, arg_last);
    w.raw.items[start_pos].operand = .{ .index = @intCast(end_pos) };
}

/// Emit `limit(n; f)`. Legacy reference: `compileLimit` at compiler.zig:4809.
///
/// Bytecode:
///   [pushScope]
///   push_current                  @ lparen
///   capture_variable(input_var)   @ lparen
///   array_collect_start(end)      @ lparen
///   <n walk>                      stamps by n
///   yield_output                  @ n_last
///   array_collect_end             @ n_last
///   pipe                          @ n_last
///   each                          @ n_last
///   push_current                  @ n_last
///   load_variable(input_var)      @ n_last
///   pipe                          @ n_last
///   limit_start(exit_ip)          @ semi (backpatched)
///   <f walk>                      stamps by f
///   yield_output                  @ rparen
///   [popScope]
fn emitLimit(w: *Walker, call_span: ast.Span, n: *const Node, f: *const Node) Walker.Error!void {
    try emitCounterGatedBuiltin(w, call_span, n, f, .limit_start, null);
}

/// Emit `skip(n; f)`. Legacy reference: `compileSkip` at compiler.zig:4999.
/// Identical shape to limit but with `.skip_start` opcode.
fn emitSkip(w: *Walker, call_span: ast.Span, n: *const Node, f: *const Node) Walker.Error!void {
    try emitCounterGatedBuiltin(w, call_span, n, f, .skip_start, null);
}

/// Emit `nth(n; f)`. Legacy reference: `compileNth` at compiler.zig:5049.
/// Same shape as limit/skip but wraps the body in a nested `limit_start(1; ...)`.
fn emitNth(w: *Walker, call_span: ast.Span, n: *const Node, f: *const Node) Walker.Error!void {
    try emitCounterGatedBuiltin(w, call_span, n, f, .nth_start, .limit_start);
}

/// Shared emitter for limit/skip/nth. `outer_op` is the outer counter-gated
/// opcode (`limit_start` / `skip_start` / `nth_start`); `inner_op` is the
/// nested opcode (only used by `nth` which adds a `limit_start(1)` inside).
fn emitCounterGatedBuiltin(
    w: *Walker,
    call_span: ast.Span,
    n: *const Node,
    f: *const Node,
    outer_op: Instruction.Op,
    inner_op: ?Instruction.Op,
) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);
    const semi_off = scanForSkipWs(w.src, n.span.end, ';') orelse n.span.end;

    // Hidden variable: input saved before body eval. ID burns one slot.
    const input_var = w.next_var_id;
    w.next_var_id += 1;

    try pushScope(w);
    defer popScope(w);

    try w.emit(.push_current, .{ .none = {} }, lparen_off);
    try w.emit(.capture_variable, .{ .index = @intCast(input_var) }, lparen_off);

    // Collect n values into array (parseArgToArray equivalent).
    try parseArgToArrayEmit(w, n, lparen_off);
    const n_last = w.last_emit_offset;
    try w.emit(.pipe, .{ .none = {} }, n_last);
    try w.emit(.each, .{ .none = {} }, n_last);

    try w.emit(.push_current, .{ .none = {} }, n_last);
    try w.emit(.load_variable, .{ .index = @intCast(input_var) }, n_last);
    try w.emit(.pipe, .{ .none = {} }, n_last);

    // Outer counter-gated scope.
    const outer_ip = w.raw.items.len;
    try w.emit(outer_op, .{ .index = 0 }, semi_off);

    // Nested limit_start(1) for nth.
    var inner_ip: ?usize = null;
    if (inner_op) |op| {
        try w.emit(.push_int, .{ .int = 1 }, semi_off);
        inner_ip = w.raw.items.len;
        try w.emit(op, .{ .index = 0 }, semi_off);
    }

    try w.walk(f);

    try w.emit(.yield_output, .{ .none = {} }, rparen_off);

    if (inner_ip) |pos| {
        w.raw.items[pos].operand = .{ .index = @intCast(w.raw.items.len) };
    }
    w.raw.items[outer_ip].operand = .{ .index = @intCast(w.raw.items.len) };
}

// ── Stage 10c: del / pick / INDEX / IN / JOIN ──────────────────────────────
//
// Legacy references:
//   - `compileDel`   — `src/query/src/compiler.zig:5654-5695`
//   - `compilePick`  — `src/query/src/compiler.zig:4875-4961`
//   - `compileINDEX` — `src/query/src/compiler.zig:5104-5223`
//   - `compileIN`    — `src/query/src/compiler.zig:5228-5254` (dispatch)
//     - `compileIN1` — `src/query/src/compiler.zig:5260-5355`
//     - `compileIN2` — `src/query/src/compiler.zig:5361-5521`
//   - `compileJOIN`  — `src/query/src/compiler.zig:5529-5651`
//
// Source-offset policy — verbatim mirror of legacy's `ctx.last_tok_offset`
// state after each `nextToken`/`parsePipe` call:
//   - `lparen_off` — offset of `(` opening the call (legacy emits stamped
//     here after `nextToken` consumes `(`).
//   - After `parsePipe(arg)` emits the arg's instructions, `last_tok_offset`
//     advances to the arg's last token; `w.last_emit_offset` mirrors this
//     because every `w.emit` updates it.
//   - After `nextToken(';')` or `nextToken(')')` in legacy, all subsequent
//     emits stamp at the semi / rparen offset.
//   - After a skip-parse-and-truncate (legacy's technique for advancing the
//     lexer past a stored source range), `last_tok_offset` remains at the
//     skipped arg's last token — the truncate does not undo the token-state
//     updates that happened during parsing.
//   - `appendSlice` of a captured raw-instr buffer does NOT update
//     `last_tok_offset`; legacy's prior state carries over verbatim. The
//     walker's `appendRebasedInstrsCopy` DOES bump `last_emit_offset` to the
//     spliced block's last src_offset, so any emitter that splices must
//     explicitly restore `w.last_emit_offset` before its next stamp-by-
//     last-emit emission.

/// Dispatch a Stage 10c builtin_call. Returns true on handled, false for
/// fall-through (caller returns `AstCompilerStageIncomplete`).
fn dispatchStage10cBuiltin(
    w: *Walker,
    bc: Node.BuiltinCall,
    call_span: ast.Span,
) Walker.Error!bool {
    if (std.mem.eql(u8, bc.name, "del") and bc.args.len == 1) {
        try emitDel(w, call_span, bc.args[0]);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "pick") and bc.args.len == 1) {
        try emitPick(w, call_span, bc.args[0]);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "INDEX") and bc.args.len == 2) {
        try emitINDEX(w, call_span, bc.args[0], bc.args[1]);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "IN")) {
        if (bc.args.len == 1) {
            try emitIN1(w, call_span, bc.args[0]);
            return true;
        }
        if (bc.args.len == 2) {
            try emitIN2(w, call_span, bc.args[0], bc.args[1]);
            return true;
        }
    }
    if (std.mem.eql(u8, bc.name, "JOIN") and bc.args.len == 2) {
        try emitJOIN(w, call_span, bc.args[0], bc.args[1]);
        return true;
    }
    return false;
}

/// Emit `del(PATH_EXPR)`. Legacy `compileDel` desugar:
///   . as $orig | [path(f)] as $paths | $orig | delpaths($paths)
///
/// Bytecode (every emit stamp mirrors legacy):
///   push_current                     @ lparen
///   capture_variable(orig)           @ lparen
///   array_collect_start(end)         @ lparen   (backpatched)
///   path_begin(end)                  @ lparen   (backpatched)
///   <f walk>                         (arg's offsets; w.last_emit_offset = arg_last)
///   path_end                         @ arg_last
///   yield_output                     @ arg_last
///   array_collect_end                @ arg_last
///   capture_variable(paths)          @ arg_last
///   load_variable(orig)              @ arg_last
///   pipe                             @ arg_last
///   load_variable(paths)             @ arg_last
///   call_builtin(delpaths)           @ arg_last
fn emitDel(w: *Walker, call_span: ast.Span, arg: *const Node) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);

    try pushScope(w);
    defer popScope(w);

    const orig_var = w.next_var_id;
    w.next_var_id += 1;
    const paths_var = w.next_var_id;
    w.next_var_id += 1;

    try w.emit(.push_current, .{ .none = {} }, lparen_off);
    try w.emit(.capture_variable, .{ .index = @intCast(orig_var) }, lparen_off);

    const ace_start = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, lparen_off);

    const path_begin_ip = w.raw.items.len;
    try w.emit(.path_begin, .{ .index = 0 }, lparen_off);

    try w.walk(arg);
    const arg_last = w.last_emit_offset;

    try w.emit(.path_end, .{ .none = {} }, arg_last);
    // path_begin's operand points at path_end's raw IP (= raw.len - 1 now).
    w.raw.items[path_begin_ip].operand = .{ .index = @intCast(w.raw.items.len - 1) };

    try w.emit(.yield_output, .{ .none = {} }, arg_last);

    const ace_end: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, arg_last);
    w.raw.items[ace_start].operand = .{ .index = @intCast(ace_end) };

    try w.emit(.capture_variable, .{ .index = @intCast(paths_var) }, arg_last);

    try w.emit(.load_variable, .{ .index = @intCast(orig_var) }, arg_last);
    try w.emit(.pipe, .{ .none = {} }, arg_last);
    try w.emit(.load_variable, .{ .index = @intCast(paths_var) }, arg_last);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.delpaths) },
        arg_last,
    );

    // Legacy consumes `)` AFTER the final call_builtin via nextToken (see
    // `compileDel` at `src/query/src/compiler.zig:5691`), updating
    // `ctx.last_tok_offset` to the rparen position. Subsequent emits (e.g.
    // the outer trailing yield_output, or an enclosing arithmetic op that
    // stamps with `last_tok_offset`) observe the rparen offset. Mirror by
    // setting `w.last_emit_offset` explicitly.
    const rparen_off = builtinRparenOff(call_span);
    w.last_emit_offset = rparen_off;
}

/// Emit `pick(PATH_EXPR)`. Legacy `compilePick` builds a reduce over the
/// collected `[path(f)]` that rebuilds an object/array with only the listed
/// paths preserved from `$in`.
///
/// Legacy consumes `)` BEFORE emitting `path_end`; from that point on every
/// remaining emit is stamped at rparen_off.
///
/// Bytecode (stamps mirror legacy precisely):
///   push_current                     @ lparen
///   capture_variable(in)             @ lparen
///   array_collect_start(end)         @ lparen   (backpatched)
///   path_begin(end)                  @ lparen   (backpatched)
///   <f walk>                         arg's offsets
///   path_end                         @ rparen
///   yield_output                     @ rparen
///   array_collect_end                @ rparen
///   capture_variable(arr)            @ rparen
///   push_null                        @ rparen
///   capture_variable(acc)            @ rparen
///   load_variable(arr)               @ rparen
///   pipe                             @ rparen
///   array_collect_start(end2)        @ rparen   (backpatched)
///   each                             @ rparen
///   capture_variable(p)              @ rparen
///   load_variable(acc)               @ rparen
///   pipe                             @ rparen
///   save_input                       @ rparen
///   load_variable(p)                 @ rparen
///   restore_input                    @ rparen
///   save_input                       @ rparen
///   load_variable(in)                @ rparen
///   pipe                             @ rparen
///   load_variable(p)                 @ rparen
///   call_builtin(getpath)            @ rparen
///   restore_input                    @ rparen
///   call_builtin(setpath)            @ rparen
///   capture_variable(acc)            @ rparen
///   backtrack                        @ rparen
///   array_collect_end                @ rparen
///   pipe                             @ rparen
///   load_variable(acc)               @ rparen
///   pop_variable(p)                  @ rparen
///   pop_variable(acc)                @ rparen
///   pop_variable(arr)                @ rparen
///   pop_variable(in)                 @ rparen
fn emitPick(w: *Walker, call_span: ast.Span, arg: *const Node) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    // Legacy var-id allocation order: in, acc, p, arr — BEFORE pushScope.
    const in_var_id = w.next_var_id;
    w.next_var_id += 1;
    const acc_id = w.next_var_id;
    w.next_var_id += 1;
    const p_var_id = w.next_var_id;
    w.next_var_id += 1;
    const arr_var_id = w.next_var_id;
    w.next_var_id += 1;

    try pushScope(w);
    defer popScope(w);

    try w.emit(.push_current, .{ .none = {} }, lparen_off);
    try w.emit(.capture_variable, .{ .index = @intCast(in_var_id) }, lparen_off);

    const ace_start = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, lparen_off);

    const path_begin_ip = w.raw.items.len;
    try w.emit(.path_begin, .{ .index = 0 }, lparen_off);

    try w.walk(arg);

    try w.emit(.path_end, .{ .none = {} }, rparen_off);
    w.raw.items[path_begin_ip].operand = .{ .index = @intCast(w.raw.items.len - 1) };

    try w.emit(.yield_output, .{ .none = {} }, rparen_off);

    const ace_end: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, rparen_off);
    w.raw.items[ace_start].operand = .{ .index = @intCast(ace_end) };

    try w.emit(.capture_variable, .{ .index = @intCast(arr_var_id) }, rparen_off);

    try w.emit(.push_null, .{ .none = {} }, rparen_off);
    try w.emit(.capture_variable, .{ .index = @intCast(acc_id) }, rparen_off);

    try w.emit(.load_variable, .{ .index = @intCast(arr_var_id) }, rparen_off);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);

    const inner_ace_start = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, rparen_off);
    try w.emit(.each, .{ .none = {} }, rparen_off);
    try w.emit(.capture_variable, .{ .index = @intCast(p_var_id) }, rparen_off);
    try w.emit(.load_variable, .{ .index = @intCast(acc_id) }, rparen_off);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);

    // setpath($p; $in | getpath($p))
    try w.emit(.save_input, .{ .none = {} }, rparen_off);
    try w.emit(.load_variable, .{ .index = @intCast(p_var_id) }, rparen_off);
    try w.emit(.restore_input, .{ .none = {} }, rparen_off);
    try w.emit(.save_input, .{ .none = {} }, rparen_off);
    try w.emit(.load_variable, .{ .index = @intCast(in_var_id) }, rparen_off);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);
    try w.emit(.load_variable, .{ .index = @intCast(p_var_id) }, rparen_off);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.getpath) },
        rparen_off,
    );
    try w.emit(.restore_input, .{ .none = {} }, rparen_off);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.setpath) },
        rparen_off,
    );

    try w.emit(.capture_variable, .{ .index = @intCast(acc_id) }, rparen_off);
    try w.emit(.backtrack, .{ .none = {} }, rparen_off);

    const inner_ace_end: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, rparen_off);
    w.raw.items[inner_ace_start].operand = .{ .index = @intCast(inner_ace_end) };

    try w.emit(.pipe, .{ .none = {} }, rparen_off);
    try w.emit(.load_variable, .{ .index = @intCast(acc_id) }, rparen_off);

    try w.emit(.pop_variable, .{ .index = @intCast(p_var_id) }, rparen_off);
    try w.emit(.pop_variable, .{ .index = @intCast(acc_id) }, rparen_off);
    try w.emit(.pop_variable, .{ .index = @intCast(arr_var_id) }, rparen_off);
    try w.emit(.pop_variable, .{ .index = @intCast(in_var_id) }, rparen_off);
}

/// Emit `INDEX(STREAM; IDX_EXPR)`. Legacy `compileINDEX` desugar:
///   reduce STREAM as $x ({}; . + {($x | IDX_EXPR | tostring): $x})
///
/// Variable-id allocation order (legacy `:5108-5113`): saved_input, acc, x.
///
/// Stamping mirrors legacy's `ctx.last_tok_offset` trajectory:
///   - lparen consumed → `@ lparen`
///   - parsePipe STREAM → `@ stream's own offsets`, ends at stream_last
///   - semi consumed → `@ semi`
///   - skip-parse IDX_EXPR → ends at idx_last (legacy parses+discards to
///     advance the lexer; we walk+capture to the same effect, burning the
///     same var_ids in the process)
///   - rparen consumed → `@ rparen` (all emits until the re-parse of IDX_EXPR)
///   - splicing captured STREAM does NOT advance legacy's last_tok_offset —
///     after the splice, emits are still `@ rparen`
///   - splicing captured IDX_EXPR likewise does not advance legacy's
///     last_tok_offset directly, BUT legacy's `ctx.lex.pos = idx_expr_src_start;
///     parsePipe(ctx)` emits fresh and DOES update last_tok_offset to the
///     IDX_EXPR's final token. Restoring `ctx.lex.pos = saved_lex_pos` does
///     NOT roll last_tok back. So every emit AFTER the idx splice is stamped
///     at idx_last.
fn emitINDEX(
    w: *Walker,
    call_span: ast.Span,
    stream: *const Node,
    idx: *const Node,
) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    const saved_input_id = w.next_var_id;
    w.next_var_id += 1;
    const acc_id = w.next_var_id;
    w.next_var_id += 1;
    const x_id = w.next_var_id;
    w.next_var_id += 1;

    try pushScope(w);
    defer popScope(w);

    try w.emit(.push_current, .{ .none = {} }, lparen_off);
    try w.emit(.capture_variable, .{ .index = @intCast(saved_input_id) }, lparen_off);

    // Walk STREAM and capture+truncate for later splicing.
    const stream_start: usize = w.raw.items.len;
    try w.walk(stream);
    const stream_end: usize = w.raw.items.len;
    const captured_stream = try captureAndTruncate(w, stream_start, stream_end);
    defer w.alloc.free(captured_stream.instrs);

    // Walk IDX_EXPR purely to burn var_ids (mirrors legacy's skip-parse) and
    // capture the instructions so we can splice them later where legacy
    // re-parses from source.
    const idx_start: usize = w.raw.items.len;
    try w.walk(idx);
    const idx_end: usize = w.raw.items.len;
    const captured_idx = try captureAndTruncate(w, idx_start, idx_end);
    defer w.alloc.free(captured_idx.instrs);
    const idx_last = w.last_emit_offset;

    // From here (rparen consumed) every emit is stamped at rparen until we
    // splice IDX_EXPR, at which point the stamps become idx_last.
    try w.emit(.object_construct_start, .{ .none = {} }, rparen_off);
    try w.emit(.object_construct_end, .{ .none = {} }, rparen_off);

    try w.emit(.capture_variable, .{ .index = @intCast(acc_id) }, rparen_off);

    try w.emit(.load_variable, .{ .index = @intCast(saved_input_id) }, rparen_off);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);

    const fork_pos = w.raw.items.len;
    try w.emit(.fork, .{ .index = 0 }, rparen_off);

    // Splice STREAM. Legacy's `appendSlice` does not touch last_tok_offset,
    // so we restore `w.last_emit_offset = rparen_off` after the splice.
    try appendRebasedInstrsCopy(w, captured_stream);
    w.last_emit_offset = rparen_off;

    try w.emit(.capture_variable, .{ .index = @intCast(x_id) }, rparen_off);

    try w.emit(.load_variable, .{ .index = @intCast(acc_id) }, rparen_off);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);

    // UPDATE body: . + {($x | IDX_EXPR | tostring): $x}
    try w.emit(.push_current, .{ .none = {} }, rparen_off);

    try w.emit(.object_construct_start, .{ .none = {} }, rparen_off);
    try w.emit(.load_variable, .{ .index = @intCast(x_id) }, rparen_off);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);

    // Splice IDX_EXPR — legacy's re-parse updates last_tok to idx_last, and
    // the splice's last instruction's src_offset matches that.
    try appendRebasedInstrsCopy(w, captured_idx);
    w.last_emit_offset = idx_last;

    try w.emit(.pipe, .{ .none = {} }, idx_last);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.tostring) },
        idx_last,
    );
    try w.emit(.load_variable, .{ .index = @intCast(x_id) }, idx_last);
    try w.emit(.object_key, .{ .none = {} }, idx_last);
    try w.emit(.object_construct_end, .{ .none = {} }, idx_last);

    try w.emit(.add, .{ .none = {} }, idx_last);

    try w.emit(.capture_variable, .{ .index = @intCast(acc_id) }, idx_last);
    try w.emit(.backtrack, .{ .none = {} }, idx_last);

    const l_done: u32 = @intCast(w.raw.items.len);
    w.raw.items[fork_pos].operand = .{ .index = @intCast(l_done) };

    try w.emit(.load_variable, .{ .index = @intCast(acc_id) }, idx_last);
}

/// Emit 1-arg `IN(S)`. Legacy `compileIN1` desugar:
///   reduce S as $y (false; if . then . elif $y == $x then true else . end)
///
/// Variable-id allocation order (legacy `:5262-5269`): x, acc, y, saved_input.
///
/// Stamping mirrors legacy:
///   - lparen `@ lparen`
///   - parsePipe S → s's own offsets; last_tok ends at s_last
///   - rparen `@ rparen`
///   - splice S — appendSlice preserves last_tok (still rparen), every
///     subsequent emit `@ rparen`.
fn emitIN1(w: *Walker, call_span: ast.Span, s: *const Node) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    const x_id = w.next_var_id;
    w.next_var_id += 1;
    const acc_id = w.next_var_id;
    w.next_var_id += 1;
    const y_id = w.next_var_id;
    w.next_var_id += 1;
    const saved_input_id = w.next_var_id;
    w.next_var_id += 1;

    try pushScope(w);
    defer popScope(w);

    try w.emit(.push_current, .{ .none = {} }, lparen_off);
    try w.emit(.capture_variable, .{ .index = @intCast(x_id) }, lparen_off);

    try w.emit(.push_current, .{ .none = {} }, lparen_off);
    try w.emit(.capture_variable, .{ .index = @intCast(saved_input_id) }, lparen_off);

    const s_start: usize = w.raw.items.len;
    try w.walk(s);
    const s_end: usize = w.raw.items.len;
    const captured_s = try captureAndTruncate(w, s_start, s_end);
    defer w.alloc.free(captured_s.instrs);

    try w.emit(.push_bool, .{ .bool = false }, rparen_off);
    try w.emit(.capture_variable, .{ .index = @intCast(acc_id) }, rparen_off);

    try w.emit(.load_variable, .{ .index = @intCast(saved_input_id) }, rparen_off);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);

    const fork_pos = w.raw.items.len;
    try w.emit(.fork, .{ .index = 0 }, rparen_off);

    try appendRebasedInstrsCopy(w, captured_s);
    w.last_emit_offset = rparen_off;

    try w.emit(.capture_variable, .{ .index = @intCast(y_id) }, rparen_off);

    try w.emit(.load_variable, .{ .index = @intCast(acc_id) }, rparen_off);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);

    try w.emit(.push_current, .{ .none = {} }, rparen_off);
    const jf_already_true = w.raw.items.len;
    try w.emit(.jump_if_false, .{ .index = 0 }, rparen_off);
    const jump_to_capture = w.raw.items.len;
    try w.emit(.jump, .{ .index = 0 }, rparen_off);

    w.raw.items[jf_already_true].operand = .{ .index = @intCast(w.raw.items.len) };
    try w.emit(.load_variable, .{ .index = @intCast(y_id) }, rparen_off);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);
    try w.emit(.push_current, .{ .none = {} }, rparen_off);
    try w.emit(.load_variable, .{ .index = @intCast(x_id) }, rparen_off);
    try w.emit(.eq, .{ .none = {} }, rparen_off);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);

    w.raw.items[jump_to_capture].operand = .{ .index = @intCast(w.raw.items.len) };

    try w.emit(.capture_variable, .{ .index = @intCast(acc_id) }, rparen_off);
    try w.emit(.backtrack, .{ .none = {} }, rparen_off);

    w.raw.items[fork_pos].operand = .{ .index = @intCast(w.raw.items.len) };

    try w.emit(.load_variable, .{ .index = @intCast(acc_id) }, rparen_off);
}

/// Emit 2-arg `IN(S; T)`. Legacy `compileIN2` desugar:
///   reduce S as $x (false; . or ($x | IN(T)))
///
/// The inner `IN(T)` is itself a reduce, so the full bytecode nests two
/// reductions. Variable-id allocation order:
///   - Outer: saved_input, outer_acc, x (legacy `:5363-5368`)
///   - Inner (after outer's fork): inner_acc, y (legacy `:5446-5449`)
fn emitIN2(
    w: *Walker,
    call_span: ast.Span,
    s: *const Node,
    t: *const Node,
) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    const saved_input_id = w.next_var_id;
    w.next_var_id += 1;
    const outer_acc_id = w.next_var_id;
    w.next_var_id += 1;
    const x_id = w.next_var_id;
    w.next_var_id += 1;

    try pushScope(w);
    defer popScope(w);

    try w.emit(.push_current, .{ .none = {} }, lparen_off);
    try w.emit(.capture_variable, .{ .index = @intCast(saved_input_id) }, lparen_off);

    // Walk S and capture+truncate.
    const s_start: usize = w.raw.items.len;
    try w.walk(s);
    const s_end: usize = w.raw.items.len;
    const captured_s = try captureAndTruncate(w, s_start, s_end);
    defer w.alloc.free(captured_s.instrs);

    // Skip-walk T to burn var_ids and capture for the inner re-parse.
    const t_start: usize = w.raw.items.len;
    try w.walk(t);
    const t_end: usize = w.raw.items.len;
    const captured_t = try captureAndTruncate(w, t_start, t_end);
    defer w.alloc.free(captured_t.instrs);
    const t_last = w.last_emit_offset;

    // From here until the inner T splice, stamps are rparen.
    try w.emit(.push_bool, .{ .bool = false }, rparen_off);
    try w.emit(.capture_variable, .{ .index = @intCast(outer_acc_id) }, rparen_off);

    try w.emit(.load_variable, .{ .index = @intCast(saved_input_id) }, rparen_off);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);

    const fork_pos = w.raw.items.len;
    try w.emit(.fork, .{ .index = 0 }, rparen_off);

    try appendRebasedInstrsCopy(w, captured_s);
    w.last_emit_offset = rparen_off;

    try w.emit(.capture_variable, .{ .index = @intCast(x_id) }, rparen_off);

    try w.emit(.load_variable, .{ .index = @intCast(outer_acc_id) }, rparen_off);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);

    try w.emit(.push_current, .{ .none = {} }, rparen_off);
    const jf_already_true = w.raw.items.len;
    try w.emit(.jump_if_false, .{ .index = 0 }, rparen_off);
    const jump_to_capture = w.raw.items.len;
    try w.emit(.jump, .{ .index = 0 }, rparen_off);

    w.raw.items[jf_already_true].operand = .{ .index = @intCast(w.raw.items.len) };

    // Inner IN(T): new var_ids allocated HERE, after outer's fork (mirrors
    // legacy `:5446-5449`).
    const inner_acc_id = w.next_var_id;
    w.next_var_id += 1;
    const y_id = w.next_var_id;
    w.next_var_id += 1;

    try w.emit(.push_bool, .{ .bool = false }, rparen_off);
    try w.emit(.capture_variable, .{ .index = @intCast(inner_acc_id) }, rparen_off);

    try w.emit(.load_variable, .{ .index = @intCast(saved_input_id) }, rparen_off);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);

    const inner_fork = w.raw.items.len;
    try w.emit(.fork, .{ .index = 0 }, rparen_off);

    // Splice T. Legacy's inner re-parse updates last_tok to t_last, so
    // subsequent emits stamp there.
    try appendRebasedInstrsCopy(w, captured_t);
    w.last_emit_offset = t_last;

    try w.emit(.capture_variable, .{ .index = @intCast(y_id) }, t_last);

    try w.emit(.load_variable, .{ .index = @intCast(inner_acc_id) }, t_last);
    try w.emit(.pipe, .{ .none = {} }, t_last);

    try w.emit(.push_current, .{ .none = {} }, t_last);
    const inner_jf = w.raw.items.len;
    try w.emit(.jump_if_false, .{ .index = 0 }, t_last);
    const inner_jt = w.raw.items.len;
    try w.emit(.jump, .{ .index = 0 }, t_last);

    w.raw.items[inner_jf].operand = .{ .index = @intCast(w.raw.items.len) };
    try w.emit(.load_variable, .{ .index = @intCast(y_id) }, t_last);
    try w.emit(.pipe, .{ .none = {} }, t_last);
    try w.emit(.push_current, .{ .none = {} }, t_last);
    try w.emit(.load_variable, .{ .index = @intCast(x_id) }, t_last);
    try w.emit(.eq, .{ .none = {} }, t_last);
    try w.emit(.pipe, .{ .none = {} }, t_last);

    w.raw.items[inner_jt].operand = .{ .index = @intCast(w.raw.items.len) };

    try w.emit(.capture_variable, .{ .index = @intCast(inner_acc_id) }, t_last);
    try w.emit(.backtrack, .{ .none = {} }, t_last);

    w.raw.items[inner_fork].operand = .{ .index = @intCast(w.raw.items.len) };

    try w.emit(.load_variable, .{ .index = @intCast(inner_acc_id) }, t_last);
    try w.emit(.pipe, .{ .none = {} }, t_last);

    w.raw.items[jump_to_capture].operand = .{ .index = @intCast(w.raw.items.len) };

    try w.emit(.capture_variable, .{ .index = @intCast(outer_acc_id) }, t_last);
    try w.emit(.backtrack, .{ .none = {} }, t_last);

    w.raw.items[fork_pos].operand = .{ .index = @intCast(w.raw.items.len) };

    try w.emit(.load_variable, .{ .index = @intCast(outer_acc_id) }, t_last);
}

/// Emit `JOIN($IDX; IDX_EXPR)`. Legacy `compileJOIN` desugar:
///   [.[] | [., $idx[idx_expr|tostring]]]
///
/// Variable-id allocation order (legacy `:5533-5586`):
///   input, idx, elem, key, lookup — note elem/key/lookup are allocated
///   mid-body, AFTER the skip-parse burns idx_expr's var_ids.
fn emitJOIN(
    w: *Walker,
    call_span: ast.Span,
    idx: *const Node,
    idx_expr: *const Node,
) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    const input_id = w.next_var_id;
    w.next_var_id += 1;
    const idx_id = w.next_var_id;
    w.next_var_id += 1;

    try pushScope(w);
    defer popScope(w);

    try w.emit(.push_current, .{ .none = {} }, lparen_off);
    try w.emit(.capture_variable, .{ .index = @intCast(input_id) }, lparen_off);

    // Walk idx — a VALUE expression. Emits happen in place at idx's offsets.
    try w.walk(idx);
    const idx_arg_last = w.last_emit_offset;
    try w.emit(.capture_variable, .{ .index = @intCast(idx_id) }, idx_arg_last);

    // Skip-walk idx_expr to burn var_ids and capture for later re-splice.
    const idx_expr_start: usize = w.raw.items.len;
    try w.walk(idx_expr);
    const idx_expr_end: usize = w.raw.items.len;
    const captured_idx_expr = try captureAndTruncate(w, idx_expr_start, idx_expr_end);
    defer w.alloc.free(captured_idx_expr.instrs);
    const idx_expr_last = w.last_emit_offset;

    // From here until the idx_expr splice, legacy stamps at rparen.
    try w.emit(.load_variable, .{ .index = @intCast(input_id) }, rparen_off);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);

    const outer_start = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, rparen_off);

    try w.emit(.each, .{ .none = {} }, rparen_off);

    // elem_id allocated mid-body; mirrors legacy's `:5579-5580`.
    const elem_id = w.next_var_id;
    w.next_var_id += 1;
    try w.emit(.push_current, .{ .none = {} }, rparen_off);
    try w.emit(.capture_variable, .{ .index = @intCast(elem_id) }, rparen_off);

    // key_id allocated next; mirrors legacy's `:5585-5586`.
    const key_id = w.next_var_id;
    w.next_var_id += 1;

    // Splice IDX_EXPR — legacy's re-parse updates last_tok to idx_expr_last.
    try appendRebasedInstrsCopy(w, captured_idx_expr);
    w.last_emit_offset = idx_expr_last;

    try w.emit(.pipe, .{ .none = {} }, idx_expr_last);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.tostring) },
        idx_expr_last,
    );
    try w.emit(.capture_variable, .{ .index = @intCast(key_id) }, idx_expr_last);

    try w.emit(.load_variable, .{ .index = @intCast(idx_id) }, idx_expr_last);
    try w.emit(.pipe, .{ .none = {} }, idx_expr_last);
    try w.emit(.save_input, .{ .none = {} }, idx_expr_last);

    try w.emit(.load_variable, .{ .index = @intCast(key_id) }, idx_expr_last);

    const try_pos = w.raw.items.len;
    try w.emit(.fork_try, .{ .index = 0 }, idx_expr_last);

    try w.emit(.load_computed, .{ .none = {} }, idx_expr_last);

    try w.emit(.pop_try, .{ .none = {} }, idx_expr_last);
    const jump_past_null = w.raw.items.len;
    try w.emit(.jump, .{ .index = 0 }, idx_expr_last);

    w.raw.items[try_pos].operand = .{ .index = @intCast(w.raw.items.len) };
    try w.emit(.push_null, .{ .none = {} }, idx_expr_last);

    w.raw.items[jump_past_null].operand = .{ .index = @intCast(w.raw.items.len) };

    // lookup_id allocated after the try block; mirrors legacy's `:5623-5624`.
    const lookup_id = w.next_var_id;
    w.next_var_id += 1;
    try w.emit(.capture_variable, .{ .index = @intCast(lookup_id) }, idx_expr_last);

    const inner_start = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, idx_expr_last);

    try w.emit(.load_variable, .{ .index = @intCast(elem_id) }, idx_expr_last);
    try w.emit(.yield_output, .{ .none = {} }, idx_expr_last);

    try w.emit(.load_variable, .{ .index = @intCast(lookup_id) }, idx_expr_last);
    try w.emit(.yield_output, .{ .none = {} }, idx_expr_last);

    const inner_end: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, idx_expr_last);
    w.raw.items[inner_start].operand = .{ .index = @intCast(inner_end) };

    try w.emit(.yield_output, .{ .none = {} }, idx_expr_last);

    const outer_end: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, idx_expr_last);
    w.raw.items[outer_start].operand = .{ .index = @intCast(outer_end) };
}

// ── Stage 11: regex / datetime / string-ops remainder ─────────────────────────
//
// Legacy references:
//   - `compileRegexBuiltin1`                @ src/query/src/compiler.zig:3184
//   - `compileRegexBuiltin1FastLiteral`     @ :3229
//   - `emitFlagPrefix`                      @ :3304
//   - `compileRegexBuiltinSlow`             @ :3351
//   - `compileRegexBuiltin2`                @ :3867
//   - `compileValueArgBuiltin1Collecting`   @ :3091
//   - `compileTwoArgMath` / `compileThreeArgMath` @ :3832 / :3992
//   - `compileFilterArgBuiltin`             @ :4597
//   - `compileWithEntries`                  @ :4629
//   - `compileSetpath`                      @ :3801
//   - `compileIsempty`                      @ :4037
//   - `compileDebugArg` / `compileHaltErrorArg` / `compileErrorArg` @ :4061/:4071/:4081
//   - `compileIn` (1-arg generator-aware)   @ :4401
//
// Stamp policy (mirrors legacy's `ctx.last_tok_offset`):
//   For a builtin-call `name(ARG1[; ARG2[; ARG3]])`:
//     - `(` consumption updates last_tok_offset to `lparen_off`.
//     - Each `ctx.emit` between argN walk and argN+1 is stamped at the
//       offset of the most recent non-EXPR token (lparen/semi/rparen).
//     - After the final `)`, every trailing emit stamps at `rparen_off`.
//   The walker reconstructs each offset via source-byte scans (scanForSkipWs,
//   scanBuiltinLparen) and `w.last_emit_offset` bookkeeping.

/// Dispatch a Stage 11 builtin_call. Returns true if handled, false for
/// fall-through. Each helper asserts arity and emits byte-identical bytecode
/// to legacy. On compile error inside a regex path, the caller surfaces
/// `error.AstCompileError` via `w.compile_err` (set by `internRegexPattern`
/// or `emitFlagPrefixInto` before returning).
fn dispatchStage11Builtin(
    w: *Walker,
    bc: Node.BuiltinCall,
    call_span: ast.Span,
) Walker.Error!bool {
    // ── Regex builtins: 1-arg (pattern[; flags]) ──────────────────────────
    if (std.mem.eql(u8, bc.name, "test") and (bc.args.len == 1 or bc.args.len == 2)) {
        try emitRegex1(w, call_span, bc.args, .test_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "match") and (bc.args.len == 1 or bc.args.len == 2)) {
        try emitRegex1(w, call_span, bc.args, .match_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "capture") and (bc.args.len == 1 or bc.args.len == 2)) {
        try emitRegex1(w, call_span, bc.args, .capture_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "scan") and (bc.args.len == 1 or bc.args.len == 2)) {
        try emitRegex1(w, call_span, bc.args, .scan_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "splits") and (bc.args.len == 1 or bc.args.len == 2)) {
        try emitRegex1(w, call_span, bc.args, .splits_);
        return true;
    }
    // ── Regex builtins: 2-arg / 3-arg (pattern; repl[; flags]) ────────────
    if (std.mem.eql(u8, bc.name, "sub") and (bc.args.len == 2 or bc.args.len == 3)) {
        try emitRegex2(w, call_span, bc.args, .sub_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "gsub") and (bc.args.len == 2 or bc.args.len == 3)) {
        try emitRegex2(w, call_span, bc.args, .gsub_);
        return true;
    }

    // ── Datetime / one-arg format builtins ────────────────────────────────
    if (std.mem.eql(u8, bc.name, "strftime") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .strftime_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "strptime") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .strptime_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "strflocaltime") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .strflocaltime_);
        return true;
    }

    // ── 1-arg string / path / value builtins ──────────────────────────────
    if (std.mem.eql(u8, bc.name, "has") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .has);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "contains") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .contains);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "inside") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .inside);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "indices") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .indices);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "index") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .index_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "rindex") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .rindex);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "flatten") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .flatten_n);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "bsearch") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .bsearch_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "split") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .split_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "join") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .join_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "startswith") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .startswith_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "endswith") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .endswith_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "ltrimstr") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .ltrimstr_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "rtrimstr") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .rtrimstr_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "trimstr") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .trimstr_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "getpath") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .getpath);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "delpaths") and bc.args.len == 1) {
        try emitValueArg1(w, call_span, bc.args, .delpaths);
        return true;
    }

    // ── Filter-arg builtins ───────────────────────────────────────────────
    if (std.mem.eql(u8, bc.name, "sort_by") and bc.args.len == 1) {
        try emitFilterArgBuiltin(w, call_span, bc.args[0], .sort_by);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "group_by") and bc.args.len == 1) {
        try emitFilterArgBuiltin(w, call_span, bc.args[0], .group_by);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "min_by") and bc.args.len == 1) {
        try emitFilterArgBuiltin(w, call_span, bc.args[0], .min_by);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "max_by") and bc.args.len == 1) {
        try emitFilterArgBuiltin(w, call_span, bc.args[0], .max_by);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "unique_by") and bc.args.len == 1) {
        try emitFilterArgBuiltin(w, call_span, bc.args[0], .unique_by);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "with_entries") and bc.args.len == 1) {
        try emitWithEntries(w, call_span, bc.args[0]);
        return true;
    }

    // ── 2-arg and 3-arg math builtins ─────────────────────────────────────
    if (std.mem.eql(u8, bc.name, "pow") and bc.args.len == 2) {
        try emitTwoArgMath(w, call_span, bc.args[0], bc.args[1], .pow_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "atan2") and bc.args.len == 2) {
        try emitTwoArgMath(w, call_span, bc.args[0], bc.args[1], .atan2_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "remainder") and bc.args.len == 2) {
        try emitTwoArgMath(w, call_span, bc.args[0], bc.args[1], .remainder_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "hypot") and bc.args.len == 2) {
        try emitTwoArgMath(w, call_span, bc.args[0], bc.args[1], .hypot_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "scalb") and bc.args.len == 2) {
        try emitTwoArgMath(w, call_span, bc.args[0], bc.args[1], .scalb_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "scalbln") and bc.args.len == 2) {
        try emitTwoArgMath(w, call_span, bc.args[0], bc.args[1], .scalbln_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "ldexp") and bc.args.len == 2) {
        try emitTwoArgMath(w, call_span, bc.args[0], bc.args[1], .ldexp_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "drem") and bc.args.len == 2) {
        try emitTwoArgMath(w, call_span, bc.args[0], bc.args[1], .drem_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "fma") and bc.args.len == 3) {
        try emitThreeArgMath(w, call_span, bc.args, .fma_);
        return true;
    }

    // ── Setpath(PATH; VALUE) ──────────────────────────────────────────────
    if (std.mem.eql(u8, bc.name, "setpath") and bc.args.len == 2) {
        try emitSetpath(w, call_span, bc.args[0], bc.args[1]);
        return true;
    }

    // ── Debug/halt_error/error/isempty (1-arg) ────────────────────────────
    if (std.mem.eql(u8, bc.name, "debug") and bc.args.len == 1) {
        try emitSimpleCall1(w, call_span, bc.args[0], .debug_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "halt_error") and bc.args.len == 1) {
        try emitSimpleCall1(w, call_span, bc.args[0], .halt_error_);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "error") and bc.args.len == 1) {
        try emitErrorArg(w, call_span, bc.args[0]);
        return true;
    }
    if (std.mem.eql(u8, bc.name, "isempty") and bc.args.len == 1) {
        try emitIsempty(w, call_span, bc.args[0]);
        return true;
    }

    // ── in(expr) — 1-arg, save_input/restore_input style ──────────────────
    if (std.mem.eql(u8, bc.name, "in") and bc.args.len == 1) {
        try emitInExpr(w, call_span, bc.args[0]);
        return true;
    }

    return false;
}

// ── Stage 11 emission helpers ─────────────────────────────────────────────────

/// Pack regex compile-error CompileError and surface via the walker's
/// `compile_err` field. Callers `return error.AstCompileError` immediately
/// after so `compileWithExternals` maps to `CompileResult.err`.
fn setRegexCompileErr(w: *Walker, offset: u32, len: u32) void {
    w.compile_err = .{
        .kind = .regex_compile_error,
        .offset = offset,
        .len = len,
    };
}

/// Intern a decoded regex pattern string (optionally flag-prefixed) into the
/// walker's `regex_pool`. Sets `last_regex_pattern_*` on failure so callers
/// can surface diagnostics. Mirrors legacy's `regex_pool.intern` branches
/// at `src/query/src/compiler.zig:3253-3258` / `:3931-3936` / `:3974-3979`.
fn internRegexPattern(
    w: *Walker,
    pattern: []const u8,
    pat_offset: u32,
    pat_len: u32,
) Walker.Error!u32 {
    return w.regex_pool.intern(pattern) catch |e| switch (e) {
        regex_mod.Error.RegexCompileFailed,
        regex_mod.Error.RegexInternalError,
        regex_mod.Error.RegexNotCompiled,
        => {
            w.last_regex_pattern_offset = pat_offset;
            w.last_regex_pattern_len = pat_len;
            setRegexCompileErr(w, pat_offset, pat_len);
            return error.AstCompileError;
        },
        regex_mod.Error.OutOfMemory => return error.OutOfMemory,
    };
}

/// Jq flag-letter parser for regex builtins. Mirrors
/// `src/query/src/compiler.zig:3304-3346` `emitFlagPrefix` exactly:
///   - `i` / `m` / `s` / `x` → inline `(?imsx)` prefix prepended to pattern.
///   - `g` → select generator-mode opcode (flagged via `has_g`).
///   - `n` → record `has_n` for the caller to pack into operand bit 48.
///   - `p` / `l` / anything else → compile error; walker's `compile_err` set.
const RegexFlagResult = struct { has_g: bool = false, has_n: bool = false };

fn emitFlagPrefixInto(
    w: *Walker,
    out: *std.ArrayList(u8),
    flag_body: []const u8,
    pat_offset: u32,
    pat_len: u32,
) Walker.Error!RegexFlagResult {
    var has_inline: bool = false;
    var inline_buf: [8]u8 = undefined;
    var inline_len: usize = 0;
    var result: RegexFlagResult = .{};

    for (flag_body) |ch| {
        switch (ch) {
            'i', 'x', 'm', 's' => {
                inline_buf[inline_len] = ch;
                inline_len += 1;
                has_inline = true;
            },
            'g' => result.has_g = true,
            'n' => result.has_n = true,
            else => {
                // `p`, `l`, and everything else reject identically.
                w.last_regex_pattern_offset = pat_offset;
                w.last_regex_pattern_len = pat_len;
                setRegexCompileErr(w, pat_offset, pat_len);
                return error.AstCompileError;
            },
        }
    }

    if (has_inline) {
        try out.appendSlice(w.alloc, "(?");
        try out.appendSlice(w.alloc, inline_buf[0..inline_len]);
        try out.append(w.alloc, ')');
    }
    return result;
}

/// Locate the span of a string-literal AST arg. The legacy probe uses a
/// cloned lexer; here we inspect the AST node and compute `name_tok.offset`
/// and `name_tok.len` from the source bytes by scanning the `"…"` around the
/// literal's `span.start`. For a literal whose AST `span.start` is at the
/// opening `"`, the slice is `span.end - span.start`.
fn literalStringArg(arg: *const Node) ?[]const u8 {
    if (arg.kind != .literal) return null;
    return switch (arg.kind.literal) {
        .string => |s| s,
        else => null,
    };
}

/// Emit a 1-arg regex builtin: `test(p)`, `match(p)`, `capture(p)`, `scan(p)`,
/// `splits(p)`. Optionally `test(p; flags)`, `match(p; "g")`, etc.
///
/// Legacy flow:
///   Fast path (both args literal): `compileRegexBuiltin1FastLiteral`.
///     - Consume `(` → last_tok = `(`.offset
///     - Consume pattern literal → last_tok = `"p"`.offset
///     - Consume `;` / flag literal / `)` in turn.
///     - Final `call_builtin` stamps at `)`.offset.
///   Slow path (non-literal pattern): `compileRegexBuiltinSlow` →
///     `compileValueArgBuiltin1Collecting` with `REGEX_POOL_DYNAMIC` sentinel.
///     Emission shape matches the generic value-arg-builtin (no flags accepted).
///
/// The walker: if `args[0]` is `.literal.string` AND — when present — `args[1]`
/// is also `.literal.string`, take fast path. Otherwise slow path (and only
/// 1 arg — legacy rejects `test("literal"; dynamic)` because probe sees
/// string+semi then checks the third tok is a string_lit; non-literal flags
/// fall through to `compileRegexBuiltinSlow`, which only handles 1 arg — the
/// emitted arg walks the raw 1 arg, not `pattern; flags`. To stay byte-
/// identical, the walker only takes fast path when both are literals; for
/// `args.len == 2` with non-literal flags we return AstCompilerStageIncomplete
/// since legacy's slow path would consume the semicolon/flag as part of the
/// arg expression (parsePipe), which is grammatically ill-formed and legacy
/// would syntax-error on it.
fn emitRegex1(
    w: *Walker,
    call_span: ast.Span,
    args: []const *const Node,
    bid: types.BuiltinId,
) Walker.Error!void {
    const rparen_off = builtinRparenOff(call_span);
    const pat = literalStringArg(args[0]);
    const flags: ?[]const u8 = if (args.len == 2) literalStringArg(args[1]) else null;

    // Fast path: literal pattern (+ literal flags if 2 args).
    if (pat != null and (args.len == 1 or flags != null)) {
        var pattern_buf = std.ArrayList(u8){};
        defer pattern_buf.deinit(w.alloc);

        const pat_span = args[0].span;
        const pat_off = pat_span.start;
        const pat_len: u32 = if (pat_span.end > pat_span.start)
            pat_span.end - pat_span.start
        else
            0;

        var flag_result: RegexFlagResult = .{};
        if (flags) |f| {
            flag_result = try emitFlagPrefixInto(w, &pattern_buf, f, pat_off, pat_len);
        }
        try pattern_buf.appendSlice(w.alloc, pat.?);

        w.last_regex_pattern_offset = pat_off;
        w.last_regex_pattern_len = pat_len;

        const pool_idx = try internRegexPattern(w, pattern_buf.items, pat_off, pat_len);

        // `match(re; "g")` rewrites to match_g_ at compile time.
        const effective_bid: types.BuiltinId =
            if (bid == .match_ and flag_result.has_g) .match_g_ else bid;

        try w.emit(
            .call_builtin,
            .{ .index = types.packRegexBuiltinOperandFlags(effective_bid, pool_idx, flag_result.has_n) },
            rparen_off,
        );
        return;
    }

    // Slow path — legacy only supports 1 non-literal arg (dynamic pattern,
    // no flags). For `args.len == 2` with non-literal-flags, legacy would
    // syntax-error; we reject by AstCompilerStageIncomplete (the probe in
    // legacy falls through and the caller ends up on `compileRegexBuiltinSlow`
    // which then sees an unexpected `;` at parsePipe — so legacy rejects).
    if (args.len != 1) return error.AstCompilerStageIncomplete;

    try emitRegexBuiltinSlow(w, call_span, args[0], bid);
}

/// Emit the slow-path regex lowering. Delegates to `emitValueArg1`'s comma
/// fold and then retrofits every `call_builtin` operand to carry the
/// `REGEX_POOL_DYNAMIC` sentinel. Mirrors legacy `compileRegexBuiltinSlow`
/// at `src/query/src/compiler.zig:3351-3366`.
fn emitRegexBuiltinSlow(
    w: *Walker,
    call_span: ast.Span,
    arg: *const Node,
    bid: types.BuiltinId,
) Walker.Error!void {
    var sink = std.ArrayList(u32){};
    defer sink.deinit(w.alloc);
    try emitValueArg1Collecting(w, call_span, arg, bid, &sink);

    const packed_operand = types.packRegexBuiltinOperand(bid, types.REGEX_POOL_DYNAMIC);
    for (sink.items) |idx| {
        w.raw.items[idx].operand.index = packed_operand;
    }
}

/// Emit a 2-arg or 3-arg regex builtin: `sub(p; r)`, `gsub(p; r)`, or
/// `sub(p; r; flags)`. Legacy `compileRegexBuiltin2` at
/// `src/query/src/compiler.zig:3867-3989`.
///
/// 2-arg bytecode (byte-identical):
///   save_input                @ lparen
///   <pattern>                 (literal fast path: nothing emitted; decoded
///                              into pending_pattern. dynamic: parsePipe
///                              emits the expression evaluating to a string.)
///   restore_input             @ semi (after consuming `;`)
///   save_input                @ semi
///   <replacement>             (parsePipe)
///   restore_input             @ rparen (after consuming `)`)
///   call_builtin(bid)         @ rparen
///     — operand = packRegexBuiltinOperand(bid, pool_idx_or_DYNAMIC).
///
/// 3-arg (`sub(lit; repl; lit_flags)`): literal flags ONLY — any non-literal
/// flag rejects at compile time identically. Final `sub` rewrites to `gsub_`
/// when `g` present.
fn emitRegex2(
    w: *Walker,
    call_span: ast.Span,
    args: []const *const Node,
    bid: types.BuiltinId,
) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);
    const semi1_off = scanForSkipWs(w.src, args[0].span.end, ';') orelse args[0].span.end;
    const semi2_off: ?u32 = if (args.len == 3)
        (scanForSkipWs(w.src, args[1].span.end, ';') orelse args[1].span.end)
    else
        null;

    // Fast-path probe: pattern is literal string AND followed by `;` at the
    // AST-arg separator. `args.len >= 2` always in this branch.
    const pat_lit = literalStringArg(args[0]);
    var flags_lit: ?[]const u8 = null;
    if (args.len == 3) {
        flags_lit = literalStringArg(args[2]);
        if (flags_lit == null) {
            // Legacy surfaces a compile error with `flags_tok.offset` — we
            // point at args[2].span.
            setRegexCompileErr(w, args[2].span.start, 0);
            return error.AstCompileError;
        }
    }
    if (args.len == 3 and pat_lit == null) {
        // Legacy: 3-arg with non-literal pattern also rejects via
        // `fast_path_handled == false`. Mirror.
        setRegexCompileErr(w, args[2].span.start, 0);
        return error.AstCompileError;
    }

    // The fast-path branch decodes the pattern into `pending_pattern` BEFORE
    // interning. Interning happens only once — with flag-prefix baked in for
    // the 3-arg form.
    var pending_pattern = std.ArrayList(u8){};
    defer pending_pattern.deinit(w.alloc);

    const fast_path = (pat_lit != null);
    var pat_off: u32 = 0;
    var pat_len: u32 = 0;
    if (pat_lit) |p| {
        try pending_pattern.appendSlice(w.alloc, p);
        pat_off = args[0].span.start;
        pat_len = if (args[0].span.end > args[0].span.start)
            args[0].span.end - args[0].span.start
        else
            0;
        w.last_regex_pattern_offset = pat_off;
        w.last_regex_pattern_len = pat_len;
    }

    // save_input — stamp lparen.
    try w.emit(.save_input, .{ .none = {} }, lparen_off);

    if (!fast_path) {
        // Dynamic pattern: evaluate the expression into the stack.
        try w.walk(args[0]);
    }

    try w.emit(.restore_input, .{ .none = {} }, semi1_off);
    try w.emit(.save_input, .{ .none = {} }, semi1_off);

    try w.walk(args[1]);

    if (args.len == 2) {
        // 2-arg: intern now if fast path; leave sentinel otherwise.
        var pool_idx: u32 = types.REGEX_POOL_DYNAMIC;
        if (fast_path) {
            pool_idx = try internRegexPattern(w, pending_pattern.items, pat_off, pat_len);
        }
        try w.emit(.restore_input, .{ .none = {} }, rparen_off);
        try w.emit(
            .call_builtin,
            .{ .index = types.packRegexBuiltinOperand(bid, pool_idx) },
            rparen_off,
        );
        return;
    }

    // 3-arg: literal flags form.
    var final_key = std.ArrayList(u8){};
    defer final_key.deinit(w.alloc);
    const flag_result = try emitFlagPrefixInto(w, &final_key, flags_lit.?, pat_off, pat_len);
    try final_key.appendSlice(w.alloc, pending_pattern.items);

    const pool_idx = try internRegexPattern(w, final_key.items, pat_off, pat_len);

    const effective_bid: types.BuiltinId =
        if (bid == .sub_ and flag_result.has_g) .gsub_ else bid;

    // Legacy consumes flags + `)` tokens then emits restore + call_builtin —
    // both stamped at `)`.offset. semi2_off is unused by the emit path but
    // captured for parity with comment.
    _ = semi2_off;

    try w.emit(.restore_input, .{ .none = {} }, rparen_off);
    try w.emit(
        .call_builtin,
        .{ .index = types.packRegexBuiltinOperandFlags(effective_bid, pool_idx, flag_result.has_n) },
        rparen_off,
    );
}

/// Emit a 1-arg value-argument builtin — the comma-fold pattern used by
/// `has(x)`, `contains(x)`, `indices(s)`, `getpath(p)`, `strftime(fmt)`, etc.
/// Delegates to the collecting variant with no sink.
fn emitValueArg1(
    w: *Walker,
    call_span: ast.Span,
    args: []const *const Node,
    bid: types.BuiltinId,
) Walker.Error!void {
    try emitValueArg1Collecting(w, call_span, args[0], bid, null);
}

/// Comma-fold emission: mirrors legacy `compileValueArgBuiltin1Collecting` at
/// `src/query/src/compiler.zig:3091-3161`.
///
/// For a non-comma arg, this is simple:
///   <arg>                  @ arg walk
///   call_builtin(bid)      @ rparen
///
/// For a comma chain `a, b, c`, legacy builds a FORK/JUMP generator:
///   FORK    L2                    (inserted before the entire 'a' subtree)
///   <a>                           (emits into left_start..mid1)
///   call_builtin(bid)             (after 'a', at rparen-ish offset)
///   JUMP end
///   L2:
///   FORK    L3                    (nested fork; previous fork's target patched)
///   <b>
///   call_builtin(bid)
///   JUMP end
///   L3:
///   <c>
///   call_builtin(bid)
///   end:
///
/// Stamp policy: legacy's emits for `call_builtin` / `jump` stamp with
/// `last_tok_offset`, which after comma consumption = `,`.offset. The final
/// tail `call_builtin` stamps after `)` consumption = `)`.offset.
fn emitValueArg1Collecting(
    w: *Walker,
    call_span: ast.Span,
    arg: *const Node,
    bid: types.BuiltinId,
    call_sink: ?*std.ArrayList(u32),
) Walker.Error!void {
    const rparen_off = builtinRparenOff(call_span);

    // Flatten comma tree into linear list of alternatives (top-level commas
    // only — parens break the chain; the AST represents that via wrapping
    // in a paren node, so flattening here is correct).
    var alts = std.ArrayList(*const Node){};
    defer alts.deinit(w.alloc);
    try flattenCommaForBuiltin(w.alloc, &alts, arg);

    // Gather comma offsets between each pair (used as last_tok_offset stamps
    // in the middle of the chain).
    var comma_offs = std.ArrayList(u32){};
    defer comma_offs.deinit(w.alloc);
    {
        var i: usize = 0;
        while (i + 1 < alts.items.len) : (i += 1) {
            const co = scanForSkipWs(w.src, alts.items[i].span.end, ',') orelse alts.items[i].span.end;
            try comma_offs.append(w.alloc, co);
        }
    }

    // Emit first alternative. `left_start` tracks the insertion point for the
    // FORK splice before the first alternative's instrs.
    var left_start: usize = w.raw.items.len;
    try w.walk(alts.items[0]);

    var jump_fixups = std.ArrayList(usize){};
    defer jump_fixups.deinit(w.alloc);

    var prev_fork_pos: ?usize = null;

    var i: usize = 1;
    while (i < alts.items.len) : (i += 1) {
        const comma_off = comma_offs.items[i - 1];

        // Emit call_builtin for the left side before inserting FORK.
        const call_idx: u32 = @intCast(w.raw.items.len);
        try w.emit(.call_builtin, .{ .index = @intFromEnum(bid) }, comma_off);
        if (call_sink) |sink| try sink.append(w.alloc, call_idx);

        // Insert FORK at `left_start`. The call_idx we just pushed shifts
        // by +1 because insertRawInstr shifts everything after left_start.
        try insertRawInstr(w, left_start, .{
            .op = .fork,
            .operand = .{ .index = 0 },
            .src_offset = 0,
        });
        if (call_sink) |sink| {
            const last = &sink.items[sink.items.len - 1];
            last.* += 1;
        }
        if (prev_fork_pos) |pfp| {
            w.raw.items[pfp].operand.index = @intCast(left_start);
        }

        // Emit JUMP past all remaining alternatives.
        const jump_pos = w.raw.items.len;
        try w.emit(.jump, .{ .index = 0 }, comma_off);
        try jump_fixups.append(w.alloc, jump_pos);

        const current_fork_pos = left_start;
        left_start = w.raw.items.len;

        try w.walk(alts.items[i]);

        w.raw.items[current_fork_pos].operand.index = @intCast(left_start);
        prev_fork_pos = current_fork_pos;
    }

    // Tail `call_builtin` — stamped at `)`.offset (legacy consumed `)` via
    // nextToken just before this emit).
    const tail_call_idx: u32 = @intCast(w.raw.items.len);
    try w.emit(.call_builtin, .{ .index = @intFromEnum(bid) }, rparen_off);
    if (call_sink) |sink| try sink.append(w.alloc, tail_call_idx);

    // Backpatch JUMPs to end.
    const end_pos: i64 = @intCast(w.raw.items.len);
    for (jump_fixups.items) |fixup| {
        w.raw.items[fixup].operand.index = end_pos;
    }
}

/// Flatten top-level commas in a subtree into a linear alternative list.
/// Commas inside parens, brackets, braces, pipes, etc. are NOT flattened —
/// they show up as AST nodes other than `.comma`. The AST's `.comma` is
/// left-leaning, matching legacy's left-to-right parse.
fn flattenCommaForBuiltin(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(*const Node),
    node: *const Node,
) error{OutOfMemory}!void {
    switch (node.kind) {
        .comma => |c| {
            try flattenCommaForBuiltin(alloc, out, c.left);
            try flattenCommaForBuiltin(alloc, out, c.right);
        },
        else => {
            try out.append(alloc, node);
        },
    }
}

/// Emit 2-arg math builtin: `pow(a; b)`, `atan2(y; x)`, etc.
/// Legacy `compileTwoArgMath` at `src/query/src/compiler.zig:3832-3858`:
///   save_input                @ lparen
///   <a>                       @ a walk
///   restore_input             @ semi
///   save_input                @ semi
///   <b>                       @ b walk
///   restore_input             @ rparen
///   call_builtin(bid)         @ rparen
fn emitTwoArgMath(
    w: *Walker,
    call_span: ast.Span,
    a: *const Node,
    b: *const Node,
    bid: types.BuiltinId,
) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);
    const semi_off = scanForSkipWs(w.src, a.span.end, ';') orelse a.span.end;

    try w.emit(.save_input, .{ .none = {} }, lparen_off);
    try w.walk(a);
    try w.emit(.restore_input, .{ .none = {} }, semi_off);
    try w.emit(.save_input, .{ .none = {} }, semi_off);
    try w.walk(b);
    try w.emit(.restore_input, .{ .none = {} }, rparen_off);
    try w.emit(.call_builtin, .{ .index = @intFromEnum(bid) }, rparen_off);
}

/// Emit 3-arg math builtin: `fma(x; y; z)`. Legacy `compileThreeArgMath` at
/// `src/query/src/compiler.zig:3992-4023`.
fn emitThreeArgMath(
    w: *Walker,
    call_span: ast.Span,
    args: []const *const Node,
    bid: types.BuiltinId,
) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);
    const semi1_off = scanForSkipWs(w.src, args[0].span.end, ';') orelse args[0].span.end;
    const semi2_off = scanForSkipWs(w.src, args[1].span.end, ';') orelse args[1].span.end;

    try w.emit(.save_input, .{ .none = {} }, lparen_off);
    try w.walk(args[0]);
    try w.emit(.restore_input, .{ .none = {} }, semi1_off);
    try w.emit(.save_input, .{ .none = {} }, semi1_off);
    try w.walk(args[1]);
    try w.emit(.restore_input, .{ .none = {} }, semi2_off);
    try w.emit(.save_input, .{ .none = {} }, semi2_off);
    try w.walk(args[2]);
    try w.emit(.restore_input, .{ .none = {} }, rparen_off);
    try w.emit(.call_builtin, .{ .index = @intFromEnum(bid) }, rparen_off);
}

/// Emit `setpath(PATH; VALUE)`. Legacy `compileSetpath` at
/// `src/query/src/compiler.zig:3801-3828`:
///   save_input                @ lparen
///   <PATH>                    @ PATH walk
///   restore_input             @ semi
///   save_input                @ semi
///   <VALUE>                   @ VALUE walk
///   restore_input             @ rparen
///   call_builtin(setpath)     @ rparen
fn emitSetpath(
    w: *Walker,
    call_span: ast.Span,
    path: *const Node,
    value: *const Node,
) Walker.Error!void {
    try emitTwoArgMath(w, call_span, path, value, .setpath);
}

/// Emit `debug(f)` / `halt_error(n)` — consume arg via parsePipe, then a
/// single `call_builtin`. Legacy `compileDebugArg` / `compileHaltErrorArg`.
fn emitSimpleCall1(
    w: *Walker,
    call_span: ast.Span,
    arg: *const Node,
    bid: types.BuiltinId,
) Walker.Error!void {
    const rparen_off = builtinRparenOff(call_span);
    try w.walk(arg);
    try w.emit(.call_builtin, .{ .index = @intFromEnum(bid) }, rparen_off);
}

/// Emit `error(msg)`. Legacy `compileErrorArg`:
///   <msg>                 @ msg walk
///   pipe                  @ rparen
///   call_builtin(error)   @ rparen
fn emitErrorArg(
    w: *Walker,
    call_span: ast.Span,
    arg: *const Node,
) Walker.Error!void {
    const rparen_off = builtinRparenOff(call_span);
    try w.walk(arg);
    try w.emit(.pipe, .{ .none = {} }, rparen_off);
    try w.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.error_) }, rparen_off);
}

/// Emit `isempty(f)`. Legacy `compileIsempty`:
///   save_input                 @ lparen
///   array_collect_start(end)   @ lparen (backpatched)
///   <f>                        @ f walk
///   yield_output               @ f_last
///   array_collect_end          @ rparen
///   call_builtin(isempty_)     @ rparen
fn emitIsempty(
    w: *Walker,
    call_span: ast.Span,
    arg: *const Node,
) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    try w.emit(.save_input, .{ .none = {} }, lparen_off);

    const start_pos = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, lparen_off);

    try w.walk(arg);
    try w.emit(.yield_output, .{ .none = {} }, w.last_emit_offset);

    const end_pos: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, rparen_off);
    w.raw.items[start_pos].operand = .{ .index = @intCast(end_pos) };

    try w.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.isempty_) }, rparen_off);
}

/// Emit `with_entries(f)`. Legacy `compileWithEntries`:
///   call_builtin(to_entries)      @ lparen
///   pipe                          @ lparen
///   array_collect_start(end)      @ lparen
///   each                          @ lparen
///   <f>                           @ f walk
///   yield_output                  @ f_last
///   array_collect_end             @ rparen
///   pipe                          @ rparen
///   call_builtin(from_entries)    @ rparen
fn emitWithEntries(
    w: *Walker,
    call_span: ast.Span,
    arg: *const Node,
) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    try w.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.to_entries) }, lparen_off);
    try w.emit(.pipe, .{ .none = {} }, lparen_off);

    const start_pos = w.raw.items.len;
    try w.emit(.array_collect_start, .{ .index = 0 }, lparen_off);
    try w.emit(.each, .{ .none = {} }, lparen_off);

    try w.walk(arg);
    try w.emit(.yield_output, .{ .none = {} }, w.last_emit_offset);

    const end_pos: u32 = @intCast(w.raw.items.len);
    try w.emit(.array_collect_end, .{ .none = {} }, rparen_off);
    w.raw.items[start_pos].operand = .{ .index = @intCast(end_pos) };

    try w.emit(.pipe, .{ .none = {} }, rparen_off);
    try w.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.from_entries) },
        rparen_off,
    );
}

/// Emit `in(expr)` — 1-arg in/IN. Legacy `compileIn` at
/// `src/query/src/compiler.zig:4401-4436`. This has a more complex shape
/// than `compileValueArgBuiltin1` because each alternative wraps in a
/// save_input/restore_input envelope with an explicit yield_output.
///
/// 1-alt shape:
///   save_input                   @ lparen
///   <arg>                        @ arg walk
///   call_builtin(in_)            @ rparen
///
/// Multi-alt (`in(a, b)`) shape:
///   save_input (inserted)        (inserted at chain_start, src_offset=0)
///   save_input                   @ lparen
///   <a>                          @ a walk
///   call_builtin(in_)            @ comma
///   yield_output                 @ comma
///   restore_input                @ comma
///   save_input                   @ comma
///   <b>                          @ b walk
///   call_builtin(in_)            @ rparen
fn emitInExpr(
    w: *Walker,
    call_span: ast.Span,
    arg: *const Node,
) Walker.Error!void {
    const lparen_off = scanBuiltinLparen(w.src, call_span);
    const rparen_off = builtinRparenOff(call_span);

    var alts = std.ArrayList(*const Node){};
    defer alts.deinit(w.alloc);
    try flattenCommaForBuiltin(w.alloc, &alts, arg);

    var comma_offs = std.ArrayList(u32){};
    defer comma_offs.deinit(w.alloc);
    {
        var i: usize = 0;
        while (i + 1 < alts.items.len) : (i += 1) {
            const co = scanForSkipWs(w.src, alts.items[i].span.end, ',') orelse alts.items[i].span.end;
            try comma_offs.append(w.alloc, co);
        }
    }

    const chain_start: usize = w.raw.items.len;
    try w.emit(.save_input, .{ .none = {} }, lparen_off);
    try w.walk(alts.items[0]);

    var i: usize = 1;
    while (i < alts.items.len) : (i += 1) {
        const comma_off = comma_offs.items[i - 1];

        // Insert save_input at chain_start before the left subtree.
        try insertRawInstr(w, chain_start, .{
            .op = .save_input,
            .operand = .{ .none = {} },
            .src_offset = 0,
        });

        // Emit call_builtin / yield_output / restore_input for the LEFT side.
        try w.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.in_) }, comma_off);
        try w.emit(.yield_output, .{ .none = {} }, comma_off);
        try w.emit(.restore_input, .{ .none = {} }, comma_off);

        try w.emit(.save_input, .{ .none = {} }, comma_off);
        try w.walk(alts.items[i]);
    }

    try w.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.in_) }, rparen_off);
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
                // Stage 8: update-assign path navigation/mutation opcodes.
                // Legacy fuse: `src/query/src/compiler.zig:7449-7450`.
                .navigate_key, .update_key => .{ .str_ref = .{
                    .offset = r.operand.str_ref.offset,
                    .len = r.operand.str_ref.len,
                } },
                .navigate_index, .update_index => .{ .index = r.operand.index },
                // Stage 9: call_function carries a raw-IP operand that must
                // be remapped through index_map. Mirrors legacy's fuse at
                // `src/query/src/compiler.zig:7394-7398`.
                .call_function => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .return_function => .{ .none = {} },
                // Stage 9: call_filter_arg / def_function / pop_variable
                // carry index operands (param index / var id) — pass through.
                .call_filter_arg, .def_function => .{ .index = r.operand.index },
                // Stage 10a: generator/reducing builtin opcodes. Each `_start`
                // opcode carries a raw-IP exit operand pointing at the end of
                // its scope that must be remapped through `index_map`. Mirrors
                // legacy's fuse at `src/query/src/compiler.zig:7462-7480`.
                .limit_start, .walk_start, .skip_start, .nth_start => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .limit_end, .walk_end, .skip_end => .{ .none = {} },
                // Stage 10a: label_begin carries an exit_ip (remapped) like
                // limit_start. label_end / break_op carry no operand. Mirrors
                // legacy's fuse at `:7454-7460`.
                .label_begin => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .label_end, .break_op => .{ .none = {} },
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
        // Placeholder — caller overwrites with the real prefilter set (or
        // null) after transferring ownership from the walker's harvest list.
        // Matches legacy's fuse at `src/query/src/compiler.zig:7509`.
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

test "walker Stage 12: select(.msg | test(\"lit\")) populates prefilter" {
    if (!regex_mod.enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var result = try compile(alloc, "select(.msg | test(\"err\"))", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    const pf = result.ok.prefilter orelse return error.TestExpectedPrefilter;
    try std.testing.expect(pf.groups.len >= 1);
    try std.testing.expect(pf.groups[0].literals.len >= 1);
    try std.testing.expectEqualStrings("err", pf.groups[0].literals[0]);
}

test "walker Stage 12: non-idiom filter leaves prefilter null" {
    const alloc = std.testing.allocator;
    var result = try compile(alloc, ".foo", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.prefilter == null);
}
