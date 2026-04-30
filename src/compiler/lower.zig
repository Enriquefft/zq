//! AST → IR lowering — Phase 2R / R3.
//!
//! Post-cutover: every AST shape produced by a successful parse has an
//! explicit lowering arm; there is no SKIP fallback to legacy. Internal
//! invariant violations (a new AST variant added without a lowerer, or
//! a `BuiltinClass.not_implemented` reaching dispatch) are encoded as
//! `unreachable` rather than recoverable errors.
//!
//! Plan §3 R3 step 6 enumerates the operator categories; plan §1.3
//! freezes the IR variable-arity contract; spec
//! `src/compiler/IR-FORMAT.md` pins the text-dump shape that
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
const regex_mod = @import("regex");
const types_mod = @import("types");

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
/// allocs. `LowerDiagnostic` encodes user-facing structured diagnostics
/// (kind, offset, len). Post-cutover every AST category lowers, so there
/// is no SKIP marker — invariant violations are `unreachable`.
pub const LowerError = error{
    OutOfMemory,
    /// Surfaces a structured compile diagnostic via `Lowerer.diag`.
    /// Inspect the `Lowerer.compile_err` field on the catch site.
    LowerDiagnostic,
};

/// User-function parameter (cat-9). Mirrors legacy `ParamInfo`
/// (`src/query/src/compiler.zig:223`): `is_filter=true` for filter
/// args (re-substituted at the call-site by re-lowering the caller's
/// AST sub-tree); `is_filter=false` for value args (`$name` syntax —
/// captured into a fresh var_id at the call site, body reads via
/// `load_var`).
pub const ParamInfo = struct {
    name: []const u8,
    is_filter: bool,
    /// Allocated at registration time for value params. Filter params
    /// don't carry a var_id (they re-lower the caller's AST).
    var_id: u32,
};

/// Active filter-arg binding during user-function body re-walk
/// (cat-9). The new compiler stores the AST sub-tree directly
/// instead of the legacy compiler's source-byte range — we have a
/// parsed AST in hand, so re-substitution is structural.
///
/// `bindings_floor_at_capture` records `filter_arg_bindings.items.len`
/// at the time this binding was captured. When the binding is
/// re-substituted, `filter_arg_bindings` is truncated back to that
/// floor so the substituted AST sees only the bindings active at the
/// caller's site (mirrors legacy's lex-pos snapshot at call-site —
/// `src/query/src/compiler.zig:6090`). Without this floor, recursive
/// filter-arg use (e.g. `def id(x): x; id(id(.))`) would loop.
pub const FilterArgBinding = struct {
    name: []const u8,
    arg_ast: *const Node,
    bindings_floor_at_capture: u32,
    /// Snapshot of `var_table` at the time the binding was captured —
    /// i.e. the *caller's* var-name → var-id mapping at the point the
    /// filter-arg expression was passed in. `reLowerFilterArg` swaps
    /// to this table during the re-walk so `$x` references inside the
    /// captured AST resolve against the caller's scope rather than
    /// the callee's (which may have rebound `x` via `as $x` or via a
    /// value param). Mirrors jq's lex-pos snapshot semantics
    /// (parser.y `Expr "as" Patterns '|' Query` + compile.c
    /// `block_bind_subblock`); without this, `def f(x): 1 as $x | x;
    /// 2000 as $x | f($x)` returns 1 instead of 2000.
    var_table_at_capture: std.StringHashMapUnmanaged(u32),
};

/// User-function table entry (cat-9). Owns the params + body AST
/// pointer. Filter-arg substitution is structural: the body AST is
/// re-walked at every call site with bindings active.
///
/// Recursion is detected eagerly via `is_recursive`; the body is
/// pre-lowered into `body_ir_root` lazily on the first call site,
/// with canonical var_ids visible. Subsequent self-calls emit
/// `call_user(fn_id)`; emit translates that into legacy
/// `call_function(body_ip)` and emits the body IR once.
///
/// `func_table_snapshot` records `function_table.items.len` at
/// registration time so inner defs can be hidden during the parent's
/// re-walk via the `func_hidden_*` lex-scoping pair (mirrors legacy
/// `src/query/src/compiler.zig:1010`).
pub const FunctionEntry = struct {
    name: []const u8,
    params: []const ParamInfo,
    body: *const Node,
    is_recursive: bool,
    /// Pre-lowered body IR root for recursive functions. Sentinel
    /// `BODY_IR_NOT_LOWERED` marks "body has not yet been lowered" —
    /// the first `call_user` emit site triggers the lowering.
    body_ir_root: u32,
    func_table_snapshot: u32,
    /// Set true when the entry's lex scope ends (parent's body re-walk
    /// completes). The entry stays in `function_table` so emit's
    /// fn_id-indexed lookups remain valid for any IR `call_user` node
    /// already synthesized, but lookups skip it as if popped. Replaces
    /// the previous truncate-on-defer which broke emit when inner-def
    /// IR survived past the parent's body re-walk (e.g. recursive
    /// outer-def whose body inlines an inner-def call_user that emit
    /// resolves AFTER the defer pops).
    out_of_scope: bool = false,
};

/// Sentinel for `FunctionEntry.body_ir_root` meaning "not yet
/// lowered". Picked to be larger than any plausible IR-array index
/// (the IR is bounded by per-arena allocation). When emit observes
/// this value, it triggers the body lowering (recursive functions
/// only).
pub const BODY_IR_NOT_LOWERED: u32 = std.math.maxInt(u32);

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
    /// Variable-name → variable-id table. External vars are pre-declared
    /// at id 0..N-1 (matching legacy `compile`'s root-scope seeding); each
    /// `as`-pattern variable claims the next id. Categorical scope rules
    /// are deferred — cat-4 only needs flat lookup and stable monotonic
    /// id assignment to mirror the legacy bytecode operands. Backed by
    /// the IR's arena so the entries die with the compile.
    var_table: std.StringHashMapUnmanaged(u32) = .{},
    /// Next variable id to allocate. Mirrors legacy `Ctx.next_var_id`.
    /// Cat-4 only declares vars in `as`-patterns; user-function param
    /// vars (cat-9) and label vars (cat-12) reuse the same counter.
    next_var_id: u32 = 0,
    /// Allocator for the regex pool (cat-11). Must outlive the IR
    /// arena because the pool transfers into the final `Compiled`.
    /// `compile()` wires this to the same allocator that owns
    /// `Compiled`. Snapshot/regen tools wire it to their test
    /// allocator and call `deinitRegexPool()` after the dumper runs.
    pool_alloc: ?std.mem.Allocator = null,
    /// Filter-compile-time regex interner. Lazily initialized on the
    /// first `internRegex` call. Owned by `pool_alloc` (not the IR
    /// arena), so it survives `arena.deinit()` and transfers to
    /// `Compiled`.
    regex_pool: ?regex_mod.RegexPool = null,
    /// Source offset of the last regex pattern interned. Used to
    /// attach a useful caret to a `RegexCompileError` diagnostic.
    last_regex_pattern_offset: u32 = 0,
    last_regex_pattern_len: u32 = 0,

    // ── Cat-9: user-defined functions + recursion + filter args ─────
    /// User-function table. Indexed by `call_user.extra` (fn_id).
    /// Populated at registration sites in `func_def` lowering. Inner
    /// defs are scoped: registered while a parent body is being
    /// re-walked, hidden after the body completes via the
    /// `func_hidden_*` pair, popped after the parent's continuation
    /// finishes lowering.
    function_table: std.ArrayListUnmanaged(FunctionEntry) = .{},
    /// Active filter-arg bindings during user-function body re-walk.
    /// Pushed in `func_call` lowering (caller's AST sub-trees stashed
    /// by name); popped after the body re-walk completes.
    filter_arg_bindings: std.ArrayListUnmanaged(FilterArgBinding) = .{},
    /// Stack of fn_ids whose bodies are currently being inlined. A
    /// `func_call` whose target is on this stack is treated as a
    /// recursive self-call — emit produces `call_user(fn_id)` IR
    /// rather than re-recursing the body. Mirrors legacy
    /// `expanding_recursive_func` (`src/query/src/compiler.zig:99`)
    /// extended to a stack so mutual recursion (a def `f` whose body
    /// calls `g`, whose body calls `f`) works without a textual scan.
    expanding_stack: std.ArrayListUnmanaged(u32) = .{},
    /// Lexical-scoping hidden range. Functions with `fn_id` in
    /// `[func_hidden_start, func_hidden_end)` are skipped during
    /// lookup. Mirrors legacy
    /// `src/query/src/compiler.zig:107-108`.
    func_hidden_start: ?u32 = null,
    func_hidden_end: ?u32 = null,

    // ── Cat-15: label / break tracking ─────────────────────────────
    /// Variable ids that are label bindings (allocated via
    /// `declareLabelVar`). `break $name` validates against this list
    /// so a regular `as` binding can't be the target of a break.
    /// Mirrors legacy `Ctx.label_var_ids`
    /// (`src/query/src/compiler.zig:3641`).
    label_var_ids: std.ArrayListUnmanaged(u32) = .{},

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

    /// Declare a variable, allocating a fresh id. Mirrors legacy
    /// `declareVariable` (`src/query/src/compiler.zig:312`): if a
    /// variable with the same name already exists at the current scope,
    /// the new id SHADOWS the prior one. Cat-4 has no nested scope yet,
    /// so the table is flat.
    pub fn declareVar(self: *Lowerer, name: []const u8) error{OutOfMemory}!u32 {
        const alloc = self.arena.allocator();
        const id = self.next_var_id;
        self.next_var_id += 1;
        try self.var_table.put(alloc, name, id);
        return id;
    }

    /// Reuse an existing variable in the current scope, or allocate a
    /// fresh id if none exists. Mirrors legacy `reuseOrDeclareVariable`
    /// (`src/query/src/compiler.zig:339`); used by `?//` for the
    /// second-and-onwards alternative patterns so that shared variable
    /// names map to the SAME var_id across alternatives.
    fn reuseOrDeclareVar(self: *Lowerer, name: []const u8) error{OutOfMemory}!u32 {
        if (self.var_table.get(name)) |existing| return existing;
        return self.declareVar(name);
    }

    /// Look up a variable id by name. Returns null if the variable is
    /// not declared at any scope visible from the current site. Cat-4
    /// reports the same `query_syntax_error` legacy emits at parse time
    /// (`src/query/src/compiler.zig:6455`) by surfacing
    /// `LowerDiagnostic` on null.
    fn lookupVar(self: *Lowerer, name: []const u8) ?u32 {
        return self.var_table.get(name);
    }

    /// Declare a label variable (cat-15). Allocates a fresh var_id via
    /// `declareVar` and records it in `label_var_ids` so `break $name`
    /// can validate the binding is a label, not a regular `as`. Mirrors
    /// legacy `compileLabel`'s pair of `declareVariable` +
    /// `label_var_ids.append` (`src/query/src/compiler.zig:3638-3641`).
    pub fn declareLabelVar(self: *Lowerer, name: []const u8) error{OutOfMemory}!u32 {
        const id = try self.declareVar(name);
        try self.label_var_ids.append(self.arena.allocator(), id);
        return id;
    }

    /// Look up a label variable by name. Returns the var_id only if
    /// the name resolves AND the resolved var_id was registered as a
    /// label (not a regular `as` binding). Mirrors legacy's
    /// label-vs-regular-binding check at
    /// `src/query/src/compiler.zig:6253-6261`.
    pub fn lookupLabelVar(self: *Lowerer, name: []const u8) ?u32 {
        const id = self.var_table.get(name) orelse return null;
        for (self.label_var_ids.items) |lid| {
            if (lid == id) return id;
        }
        return null;
    }

    /// Intern a regex pattern and return its pool index. Lazily
    /// initializes `regex_pool` on first call. Compile errors
    /// surface as `error.RegexCompileError`; the caller (cat-11
    /// lowering) maps them to `LowerDiagnostic` with
    /// `last_regex_pattern_*` offsets so the top-level compile loop
    /// attaches a useful caret. Mirrors legacy
    /// `Ctx.regex_pool.intern` at
    /// `src/query/src/compiler.zig:3128`.
    pub fn internRegex(self: *Lowerer, pattern: []const u8) RegexInternError!u32 {
        const alloc = self.pool_alloc orelse return error.RegexNotCompiled;
        if (self.regex_pool == null) self.regex_pool = regex_mod.RegexPool.init(alloc);
        return self.regex_pool.?.intern(pattern) catch |e| switch (e) {
            regex_mod.Error.RegexCompileFailed => error.RegexCompileError,
            regex_mod.Error.RegexNotCompiled => error.RegexNotCompiled,
            regex_mod.Error.RegexInternalError => error.RegexCompileError,
            regex_mod.Error.OutOfMemory => error.OutOfMemory,
        };
    }

    /// Take ownership of the regex pool. Returns the populated pool
    /// (or an empty one) and clears the field so `deinitRegexPool` is
    /// a no-op afterwards. Used by `compile()` to transfer the pool
    /// into the final `Compiled` struct.
    pub fn takeRegexPool(self: *Lowerer) regex_mod.RegexPool {
        if (self.regex_pool) |p| {
            self.regex_pool = null;
            return p;
        }
        // No regex builtin was lowered. Return an empty pool keyed
        // to the caller's allocator so `Compiled.deinit` is
        // symmetric. If pool_alloc was never wired, fall back to the
        // page allocator — the empty pool's deinit walks zero
        // entries so any allocator works.
        const alloc = self.pool_alloc orelse std.heap.page_allocator;
        return regex_mod.RegexPool.init(alloc);
    }

    /// Free the regex pool if it was lazily initialized but not
    /// taken. Idempotent — safe to call on an already-taken or
    /// never-allocated Lowerer. The snapshot test and regen tool
    /// rely on this to clean up after lowering without an explicit
    /// transfer.
    pub fn deinitRegexPool(self: *Lowerer) void {
        if (self.regex_pool) |*p| {
            p.deinit();
            self.regex_pool = null;
        }
    }

    /// Look up a user-defined function by name + arity. Searches
    /// backward so the latest registration wins (shadowing). Skips
    /// the hidden range `[func_hidden_start, func_hidden_end)` so
    /// re-walked function bodies see only the functions visible at
    /// definition time. Mirrors legacy `lookupFunction`
    /// (`src/query/src/compiler.zig:1018`).
    fn lookupFunction(self: *Lowerer, name: []const u8, arity: u32) ?u32 {
        var i: u32 = @intCast(self.function_table.items.len);
        while (i > 0) {
            i -= 1;
            const entry = self.function_table.items[i];
            if (entry.out_of_scope) continue;
            if (self.func_hidden_start) |start| if (self.func_hidden_end) |end| {
                if (i >= start and i < end) continue;
            };
            if (entry.params.len == arity and std.mem.eql(u8, entry.name, name)) {
                return i;
            }
        }
        return null;
    }

    /// Returns true if `fn_id` is on the inline-expansion stack — the
    /// call site is therefore inside the body of a function currently
    /// being inlined, and a `call_user(fn_id)` IR node should be
    /// emitted in lieu of recursing into the body again.
    fn isExpanding(self: *const Lowerer, fn_id: u32) bool {
        for (self.expanding_stack.items) |id| {
            if (id == fn_id) return true;
        }
        return false;
    }
};

/// Errors surfaced by `internRegex`. Mirrors the legacy compiler's
/// regex-compile error path at `src/query/src/compiler.zig:3128-3133`.
pub const RegexInternError = error{
    OutOfMemory,
    RegexCompileError,
    RegexNotCompiled,
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
                .big_number => |bn| {
                    try ctx.out.extra_data.append(alloc, @intFromEnum(ir.LiteralKind.big_number));
                    const offset: u32 = @intCast(ctx.out.string_buf.items.len);
                    try ctx.out.string_buf.appendSlice(alloc, bn);
                    try ctx.out.extra_data.append(alloc, offset);
                    try ctx.out.extra_data.append(alloc, @intCast(bn.len));
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
        // `mktime`, `arrays`, `strings`) reach the AST as `field_access`
        // because the AST parser uses a narrower zero-arg-builtin list
        // than the legacy compiler. A leading `.` in the source span is
        // the structural marker that this is a true field access;
        // absent that, the ident may be:
        //   (a) a filter-arg binding (cat-9 — re-substitutes the
        //       caller's AST sub-tree),
        //   (b) a zero-arg user-defined function call (cat-9 —
        //       inline-expand or recursive emit),
        //   (c) a zero-arg builtin owned by cat-10 (route through the
        //       builtin classifier — emits `call_builtin`),
        //   (d) unknown ident — defer to legacy via NotImplemented.
        //
        // Cat-9 lookup MUST run before cat-10's builtin classifier so
        // user defs shadow builtin names per legacy semantics.
        .field_access => |fa| {
            const is_dot_field = sp.start < ctx.src.len and ctx.src[sp.start] == '.';
            if (!is_dot_field) {
                // ── Cat-9 — bare-ident resolution ─────────────────
                // 1. Active filter-arg binding: re-walk the binding's
                //    AST sub-tree under the floor of bindings active
                //    at the binding's capture site (avoids infinite
                //    recursion on `def id(x): x; id(id(.))`).
                if (lookupFilterArgBinding(ctx, fa.name)) |binding_idx| {
                    return reLowerFilterArg(ctx, binding_idx);
                }
                // 2. Zero-arg user-defined function call. If a
                //    function with the same name and arity 0 is
                //    visible AND it is currently being inline-expanded
                //    (on `expanding_stack`), emit a self-reference
                //    `call_user`. Otherwise inline-expand at the call
                //    site. The recursion check bypasses the hidden
                //    range so a function which hides itself during
                //    inner-def expansion can still self-call.
                if (lookupRecursiveSelf(ctx, fa.name, 0)) |fn_id| {
                    return synthCallUser(ctx, fn_id, &.{}, sp.start, sp.len);
                }
                if (ctx.lookupFunction(fa.name, 0)) |fn_id| {
                    return inlineUserCall(ctx, fn_id, &.{}, sp.start, sp.len);
                }
                // 3. Cat-10 zero-arg builtin classifier. The legacy
                //    compiler dispatches the same names through
                //    `zeroArgBuiltinId` at
                //    `src/query/src/compiler.zig:5771`.
                if (classifyBuiltin(fa.name, 0) == .zero_arg) {
                    const extra_idx_b = try ctx.internString(fa.name);
                    return ctx.pushNode(.{
                        .op = .call_builtin,
                        .extra = extra_idx_b,
                        .src_start = sp.start,
                        .src_len = sp.len,
                    });
                }
                // 4. Plain identifier → field access. Mirrors legacy
                //    fall-through at `src/query/src/compiler.zig:6128-6131`:
                //    after binding/UDF/builtin lookup misses, a bare
                //    identifier compiles to `load_key <name>`, equivalent
                //    to writing `.<name>` against the current input. Same
                //    IR shape as the dot-field branch below.
                const extra_idx_id = try ctx.internString(fa.name);
                return ctx.pushNode(.{
                    .op = .load_field,
                    .extra = extra_idx_id,
                    .src_start = sp.start,
                    .src_len = sp.len,
                });
            }
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
        .slice => |sl| return lowerSliceNode(ctx, sl, sp),

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
                    .bracket_expr => |key_node| {
                        const op_idx = try lowerSuffixBracketExpr(ctx, key_node, sf.base.span);
                        cur = try lowerSuffixPipe(ctx, cur, op_idx, sf.base.span);
                    },
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

        // ── Parens `(expr)` (category 6) ────────────────────────────
        // Transparent passthrough — the AST records `paren` for
        // source-position fidelity (parens shift error spans), but the
        // IR has no concept of grouping. Recurse into the operand and
        // re-emit its IR shape unchanged.
        .paren => |un| return lowerNode(ctx, un.operand),

        // ── try BODY [catch HANDLER] (category 6) ──────────────────
        // Catch-handler attachment design (option C — variable):
        //   * No handler: `try_` unary, `children[0]` = body. Same shape
        //     as cat-2's postfix `?` so emit can reuse the bracket
        //     ladder verbatim.
        //   * With handler: `try_` variable-arity span = [body, handler]
        //     with `span_len == 2`. Emit dispatches on `span_len` to
        //     produce the legacy `fork_try ; <body> ; pop_try ; jump
        //     end ; <handler> ; end:` ladder.
        // The `extra` slot stays unused — encoding the marker via
        // `span_len` keeps the Node struct cache-friendly without an
        // auxiliary discriminator (plan §1.3 row 5).
        .try_catch => |tc| {
            const body = try lowerNode(ctx, tc.body);
            if (tc.catch_body) |handler_ast| {
                const handler = try lowerNode(ctx, handler_ast);
                const alloc = ctx.arena.allocator();
                const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
                try ctx.out.extra_children.append(alloc, body);
                try ctx.out.extra_children.append(alloc, handler);
                return ctx.pushNode(.{
                    .op = .try_,
                    .span_start = span_start,
                    .span_len = 2,
                    .src_start = sp.start,
                    .src_len = sp.len,
                });
            }
            return ctx.pushNode(.{
                .op = .try_,
                .children = .{ body, 0 },
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── if cond then A [elif c then B]* [else C] end (cat-6) ────
        // elif chains desugar to nested `if` IR nodes at lowering time
        // (the plan only names one IR `if_` op). The implicit-else
        // case (no `else` clause) materializes as `identity` — matches
        // legacy `parseIfBody` (`src/query/src/compiler.zig:6390`).
        .if_expr => |ifx| {
            const cond = try lowerNode(ctx, ifx.cond);
            const then_body = try lowerNode(ctx, ifx.then_body);
            const else_idx = try lowerIfElseChain(ctx, &ifx, 0, sp.start, sp.len);
            const alloc = ctx.arena.allocator();
            const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
            try ctx.out.extra_children.append(alloc, cond);
            try ctx.out.extra_children.append(alloc, then_body);
            try ctx.out.extra_children.append(alloc, else_idx);
            return ctx.pushNode(.{
                .op = .if_,
                .span_start = span_start,
                .span_len = 3,
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
        //
        // Cat-9 priority: a user-defined function whose name happens
        // to collide with a builtin name (e.g. `def add($x): ...; add(5)`)
        // reaches the AST as `builtin_call` because the AST parser's
        // `isBuiltinName` table doesn't know about runtime user defs.
        // Dispatch to `lookupFunction` FIRST so the UDF wins; fall back
        // to cat-10's `lowerBuiltinCall` classifier otherwise. Mirrors
        // legacy `parsePrimaryInner`'s lookup order
        // (`src/query/src/compiler.zig:5991`).
        //
        // Cat-10 owns the wider alphabet; cat-1 + cat-6 already own
        // `not`/`type`/`path` and route through the same classifier.
        // The classifier dispatches by (name, arity) to one of the
        // call-shape buckets registered in `BuiltinClass`. Post-cutover
        // every builtin recognised by the AST parser routes to a real
        // class; an unrecognised (name, arity) tuple is a parser bug,
        // not a user-facing error.
        .builtin_call => |bc| {
            const arity: u32 = @intCast(bc.args.len);
            // 1. User-defined function lookup first. Recursive self-call
            //    (target on expanding_stack) emits `call_user`; otherwise
            //    inline-expand. Mirrors the `func_call` arm below.
            if (lookupRecursiveSelf(ctx, bc.name, arity)) |fn_id| {
                var lowered_args: std.ArrayListUnmanaged(u32) = .{};
                defer lowered_args.deinit(ctx.arena.allocator());
                const entry_for_args = ctx.function_table.items[fn_id];
                for (entry_for_args.params, 0..) |param, pi| {
                    if (param.is_filter) continue;
                    const arg_idx = try lowerNode(ctx, bc.args[pi]);
                    try lowered_args.append(ctx.arena.allocator(), arg_idx);
                }
                return synthCallUser(ctx, fn_id, lowered_args.items, sp.start, sp.len);
            }
            if (ctx.lookupFunction(bc.name, arity)) |fn_id| {
                return inlineUserCall(ctx, fn_id, bc.args, sp.start, sp.len);
            }
            // `__computed_access(expr)` is the parser's synthesized
            // shape for a standalone `.[expr]` (no preceding suffix
            // chain — see `src/ast/parser.zig:680-684`). Route to the
            // same `computed_index` SemOp the SuffixOp.bracket_expr
            // arm produces so emit's two-var capture pattern is the
            // single source of truth for both shapes. Plan §3.5 row P27.
            if (bc.args.len == 1 and std.mem.eql(u8, bc.name, "__computed_access")) {
                return lowerSuffixBracketExpr(ctx, bc.args[0], .{ .start = sp.start, .end = sp.start + sp.len });
            }
            // 2. Fall through to cat-10's builtin classifier (handles
            //    `not`/`type`/`path` plus the wider alphabet).
            return lowerBuiltinCall(ctx, &bc, sp.start, sp.len);
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
            // Two-phase lowering — see `array_construct` for the
            // rationale. Lower every (key, value) pair first into a
            // local buffer, then append to `extra_children` in one
            // contiguous run so the variadic span stays adjacent.
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
        //
        // Cat-7 buffering fix (cat-4 epoch): same scratch-buffer
        // strategy as `obj_ctor` above — recursive lowering of nested
        // constructor elements grows `extra_children`, which would
        // pollute our contiguous span if we appended per-element.
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
        //
        // Cat-7 buffering fix (cat-4 epoch): same scratch-buffer
        // strategy — expr parts may recurse into more complex shapes
        // that grow `extra_children`, so we collect indices in scratch
        // before publishing the parent span.
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
        // The `format` field of the AST node is the bare format name
        // (e.g. `"base64"`, no leading `@` — parser `internName` at
        // `parser.zig:1048`/`:1093`). Lowering validates the name
        // against the legacy registry and stamps `(offset, len)` into
        // `extra_data`; emit decodes it back to a `BuiltinId` via
        // `formatBuiltinId` (single source of truth — see
        // `emit.zig:1110`). Unknown names raise a
        // `query_syntax_error` LowerDiagnostic mirroring legacy
        // `parsePrimary`'s `formatBuiltinId(...) orelse syntaxErr`
        // at `compiler.zig:6210`.
        //
        // Special case: a single literal part with NO interpolations
        // emits as a bare `push_string` (legacy
        // `src/query/src/compiler.zig:6219-6225`). The IR records this
        // as `format(span_len=1, child=load_const(...))` and emit
        // detects the shape.
        .format_string => |fs| {
            // Validate format name eagerly — unknown formats are a
            // compile error, not a backend gap. The bare name reaches
            // us via `internName`; strip a leading `@` defensively for
            // shape parity with the standalone `@fmt` AST.
            const fmt_bare = if (fs.format.len > 0 and fs.format[0] == '@') fs.format[1..] else fs.format;
            if (!isKnownFormatName(fmt_bare)) {
                // Mirror legacy parser-time `syntaxErr(last_tok_offset, 0)`
                // at `compiler.zig:6210`. `last_tok_offset` is the
                // offset of the just-consumed format ident, which sits
                // exactly one byte past the `@` (the `at_tok` start).
                // The `format_string` AST span starts at the `@` token,
                // so we add 1 to land on the ident byte.
                ctx.compile_err = .{
                    .kind = .query_syntax_error,
                    .offset = sp.start + 1,
                    .len = 0,
                };
                return error.LowerDiagnostic;
            }
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

        // ── Variable load `$name` (category 4) ─────────────────────
        // Resolve the name to a var_id at lower-time so emit can stamp
        // the `load_variable` operand directly. Legacy emits the same
        // shape via `parseVariableReference`
        // (`src/query/src/compiler.zig:6442`).
        //
        // Magic var `$__loc__` is jq's compile-time location object —
        // legacy `emitLocObject` (`src/query/src/compiler.zig:6461`)
        // expands it inline as `{"file":"<top-level>","line":1}`. Mirror
        // that here by synthesising an `obj_ctor` IR node with two
        // (key, value) pairs of `load_const` literals — emit then
        // produces the same `object_construct_start ... object_key ...
        // object_construct_end` ladder as a hand-written object literal.
        // No new bytecode shape introduced; reuses cat-7 obj-ctor emit.
        .variable_ref => |vr| {
            if (std.mem.eql(u8, vr.name, "__loc__")) {
                const alloc = ctx.arena.allocator();
                // (k0, v0) = ("file", "<top-level>")
                const k0_idx = try synthLoadConstString(ctx, "file", sp.start, sp.len);
                const v0_idx = try synthLoadConstString(ctx, "<top-level>", sp.start, sp.len);
                // (k1, v1) = ("line", 1)
                const k1_idx = try synthLoadConstString(ctx, "line", sp.start, sp.len);
                const v1_idx = try synthLoadConstInt(ctx, 1, sp.start, sp.len);
                // Pairs land in `extra_children` interleaved (k, v, k, v)
                // — same invariant as the `.object_construct` arm so
                // emit's existing obj_ctor walker picks them up.
                const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
                try ctx.out.extra_children.append(alloc, k0_idx);
                try ctx.out.extra_children.append(alloc, v0_idx);
                try ctx.out.extra_children.append(alloc, k1_idx);
                try ctx.out.extra_children.append(alloc, v1_idx);
                return ctx.pushNode(.{
                    .op = .obj_ctor,
                    .span_start = span_start,
                    .span_len = 4,
                    .src_start = sp.start,
                    .src_len = sp.len,
                });
            }
            const var_id = ctx.lookupVar(vr.name) orelse {
                ctx.compile_err = .{
                    .kind = .query_syntax_error,
                    .offset = sp.start,
                    .len = 0,
                };
                return error.LowerDiagnostic;
            };
            const alloc = ctx.arena.allocator();
            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            const offset: u32 = @intCast(ctx.out.string_buf.items.len);
            try ctx.out.string_buf.appendSlice(alloc, vr.name);
            try ctx.out.extra_data.append(alloc, offset);
            try ctx.out.extra_data.append(alloc, @intCast(vr.name.len));
            try ctx.out.extra_data.append(alloc, var_id);
            return ctx.pushNode(.{
                .op = .load_var,
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── `expr as PATTERN | body` (category 4) ───────────────────
        // Legacy emits the LHS, then `capture_variable` / destructure
        // ladder, then the user's `|` `pipe` op, then `body`. The
        // crucial invariant: `body` MUST run against the input that was
        // `current` BEFORE `expr` evaluated — for the simple `.as`
        // case `capture_variable` only pops the value stack (or current
        // when the stack is empty) without modifying current, so legacy
        // never inserts a `pipe` op between `expr` and `capture` (which
        // would clobber current with `expr`'s result). The naive
        // `pipe(expr, pipe(destructure, body))` IR shape inserts that
        // exact stray `pipe` op — breaking patterns like
        // `"foo" as $k | .[$k]` which need original input.
        //
        // Use the dedicated `as_bind` SemOp so emit produces
        // `<expr> ; <destructure ladder> ; pipe ; <body>` mirroring
        // legacy `parseLogical` (`compiler.zig:2499-2517`) followed by
        // `parsePipe`'s trailing `pipe` op for the user-written `|`.
        // Variables are declared BEFORE the body is lowered so `$x`
        // references inside `body` resolve correctly.
        .as_pattern => |ap| {
            const expr_idx = try lowerNode(ctx, ap.expr);
            try declarePatternVars(ctx, ap.pattern);
            const dx_idx = try lowerPattern(ctx, ap.pattern, ap.expr.span);
            const body_idx = try lowerNode(ctx, ap.body);

            const alloc = ctx.arena.allocator();
            const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
            try ctx.out.extra_children.append(alloc, expr_idx);
            try ctx.out.extra_children.append(alloc, dx_idx);
            try ctx.out.extra_children.append(alloc, body_idx);
            return ctx.pushNode(.{
                .op = .as_bind,
                .span_start = span_start,
                .span_len = 3,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── `expr as P1 ?// P2 ?// … | body` (category 4) ──────────
        // Legacy desugars to a fork-try chain that null-initialises
        // every unique variable across all patterns, then attempts
        // each pattern strictly (no per-element null-on-missing). On
        // the first match control jumps to the body; on total failure,
        // `backtrack` produces empty
        // (`src/query/src/compiler.zig:2549-2654`).
        //
        // The new pipeline expresses the same flow as
        // `pipe(expr, pipe(destructure(alt_bind, [P1, P2, …]), body))`
        // — emit consults the `alt_bind` discriminant to produce the
        // exact ladder. Patterns 2..N reuse var_ids declared by P1
        // when the names match, mirroring legacy
        // `scanAndDeclarePatternReuse`.
        .destruct_alt => |da| {
            const expr_idx = try lowerNode(ctx, da.expr);

            // Phase 1: declare all pattern variables in source order.
            // P1 declares fresh ids; P2..N reuse on name match (the
            // strict-match contract from legacy).
            if (da.patterns.len > 0) {
                try declarePatternVars(ctx, da.patterns[0]);
                for (da.patterns[1..]) |alt_pat| {
                    try declarePatternVarsReuse(ctx, alt_pat);
                }
            }

            // Phase 2: lower each pattern as its own destructure
            // subtree. The outer `destructure(alt_bind)` records the
            // per-alternative pattern roots in `extra_children`.
            // Buffer indices in scratch first because recursive
            // `lowerPattern` calls themselves grow `extra_children`
            // (nested array/object patterns) — interleaving would
            // pollute the parent's span.
            const alloc = ctx.arena.allocator();
            var scratch: std.ArrayListUnmanaged(u32) = .{};
            defer scratch.deinit(alloc);
            for (da.patterns) |alt_pat| {
                const pat_idx = try lowerPattern(ctx, alt_pat, da.expr.span);
                try scratch.append(alloc, pat_idx);
            }
            const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
            try ctx.out.extra_children.appendSlice(alloc, scratch.items);
            const span_len: u32 = @intCast(da.patterns.len);

            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            try ctx.out.extra_data.append(alloc, @intFromEnum(ir.PatternKind.alt_bind));

            const dx_idx = try ctx.pushNode(.{
                .op = .destructure,
                .span_start = span_start,
                .span_len = span_len,
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });

            const body_idx = try lowerNode(ctx, da.body);
            const inner_pipe = try ctx.pushNode(.{
                .op = .pipe,
                .children = .{ dx_idx, body_idx },
                .src_start = sp.start,
                .src_len = sp.len,
            });
            return ctx.pushNode(.{
                .op = .pipe,
                .children = .{ expr_idx, inner_pipe },
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── User-defined function definition (cat-9) ────────────────
        // `def name(params): body; rest`. The def itself produces NO
        // IR node — it's purely a binding/scoping construct. The body
        // AST pointer is registered for later re-walk (every call site
        // re-lowers the body with bindings active); the `rest`
        // continuation is what flows into the IR.
        //
        // Inner defs (registered while a body is re-walked) are popped
        // from `function_table` and re-hidden via the `func_hidden_*`
        // pair after the parent's `rest` finishes lowering, so call
        // sites in sibling code don't see them (lexical scoping).
        // Mirrors legacy's `parseFunctionDef` body handling at
        // `src/query/src/compiler.zig:6489`.
        .func_def => |fd| return lowerFuncDef(ctx, &fd, sp.start, sp.len),

        // ── User-defined function call (cat-9) ──────────────────────
        // `name(arg1; arg2; ...)`. Resolve by name + arity; for
        // recursive self-references (target fn_id is on the
        // inline-expansion stack) emit `call_user(fn_id)` IR — emit
        // produces `call_function(body_ip)` against a body emitted
        // once per recursive function. Otherwise re-walk the body AST
        // inline with bindings active for the caller's value/filter
        // args. Mirrors legacy's `expandFunctionCall` at
        // `src/query/src/compiler.zig:1066`.
        .func_call => |fc| {
            const arity: u32 = @intCast(fc.args.len);
            const fn_id = ctx.lookupFunction(fc.name, arity) orelse {
                ctx.compile_err = .{
                    .kind = .query_syntax_error,
                    .offset = sp.start,
                    .len = 0,
                };
                return error.LowerDiagnostic;
            };
            // Self-recursive call inside inline expansion: emit
            // `call_user(fn_id, value_args)` IR. Value args are lowered
            // here (each call captures into the function's canonical
            // var_ids at emit time); filter args are recorded as
            // bindings against the caller's AST so the body's
            // load_var/field_access references resolve through them.
            if (ctx.isExpanding(fn_id)) {
                return synthRecursiveCall(ctx, fn_id, fc.args, sp.start, sp.len);
            }
            return inlineUserCall(ctx, fn_id, fc.args, sp.start, sp.len);
        },

        // ── Cat-15 — `label $name | <body>` ─────────────────────────
        // Allocates a fresh var_id for the label binding, registers it
        // as a label var (so `break $name` validates), then lowers the
        // body with `$name` visible in the var_table. The body lowers
        // first into `children[0]`; emit handles the patch-table
        // bracketing (label_begin + capture_variable + body + exit_ip
        // backpatch) using the var_id stored in `extra_data`.
        //
        // The label binding scope ends after lowering the body — pop
        // the var_table entry to mirror legacy's `popScope`
        // (`compiler.zig:3670`). Subsequent siblings won't see `$name`.
        .label_expr => |le| {
            const alloc = ctx.arena.allocator();

            // Snapshot var_table state so the binding pops after the
            // body is lowered. Mirrors legacy popScope semantics.
            const saved_var_table = ctx.var_table;
            var fresh_var_table: std.StringHashMapUnmanaged(u32) = .{};
            var it = saved_var_table.iterator();
            while (it.next()) |kv| {
                try fresh_var_table.put(alloc, kv.key_ptr.*, kv.value_ptr.*);
            }
            ctx.var_table = fresh_var_table;
            defer {
                ctx.var_table.deinit(alloc);
                ctx.var_table = saved_var_table;
            }

            const var_id = try ctx.declareLabelVar(le.name);
            const body_idx = try lowerNode(ctx, le.body);

            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            try ctx.out.extra_data.append(alloc, var_id);

            return ctx.pushNode(.{
                .op = .label,
                .children = .{ body_idx, 0 },
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Cat-15 — `break $name` ─────────────────────────────────
        // Looks up the label var by name; surfaces a structured compile
        // diagnostic if no such label is in scope. Emit produces
        // `load_variable($name) ; break_op` at the saved var_id.
        .break_expr => |be| {
            const var_id = ctx.lookupLabelVar(be.name) orelse {
                // Mirrors legacy's syntax-error class for undefined
                // label refs (`compiler.zig:6252`/`:6261`).
                ctx.compile_err = .{
                    .kind = .query_syntax_error,
                    .offset = sp.start,
                    .len = sp.len,
                };
                return error.LowerDiagnostic;
            };
            const alloc = ctx.arena.allocator();
            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            try ctx.out.extra_data.append(alloc, var_id);
            return ctx.pushNode(.{
                .op = .break_,
                .extra = extra_idx,
                .src_start = sp.start,
                .src_len = sp.len,
            });
        },

        // ── Cat-14 — `reduce EXPR as PATTERN (INIT; UPDATE)` ────────
        // Allocates two hidden var_ids (saved_input + accumulator) at
        // lower time so the emitter can stamp `capture_variable` /
        // `load_variable` operands directly. Pattern variables are
        // declared INSIDE a fresh scope so they pop after lowering and
        // don't leak into siblings — mirrors legacy `pushScope` /
        // `popScope` (`compiler.zig:3989,4078`).
        //
        // IR layout (`extra_children` span = 4):
        //   [expr_idx, pattern_idx, init_idx, update_idx]
        //   extra_data slot 0: saved_input_id
        //   extra_data slot 1: acc_id
        //
        // Init does NOT see pattern vars (lowered before declaration);
        // update DOES (lowered after). Mirrors legacy `compileReduce`
        // (`src/query/src/compiler.zig:3965`).
        .reduce => |rd| return lowerReduce(ctx, &rd, sp.start, sp.len),

        // ── Cat-14 — `foreach EXPR as PATTERN (INIT; UPDATE [; EXTRACT])` ──
        // Same shape as reduce plus an optional extract clause. Span
        // length discriminates 2-arg (4) from 3-arg (5) form. Mirrors
        // legacy `compileForeach` (`src/query/src/compiler.zig:4121`).
        //
        // IR layout (`extra_children` span = 4 or 5):
        //   [expr_idx, pattern_idx, init_idx, update_idx (, extract_idx)]
        //   extra_data slot 0: saved_input_id
        //   extra_data slot 1: acc_id
        .foreach => |fe| return lowerForeach(ctx, &fe, sp.start, sp.len),

        // ── Catch-all (Phase 7 — Wave 1.1 final closure) ───────────
        //
        // INVARIANT: every `ast.Node.Kind` union variant that the parser
        // can emit on a successful (`!hasErrors()`) parse has an explicit
        // arm above. Reaching this `else =>` would mean the AST surface
        // grew a new variant without a corresponding lowering — that is a
        // compiler bug, so we mark it `unreachable`.
        //
        // Coverage proof — explicit arms above cover every variant of
        // `ast.Node.Kind` (`src/ast/nodes.zig:22-92`):
        //
        //   pipe, comma, func_def, alternative, or_expr, and_expr,
        //   comparison, arithmetic, unary_neg, as_pattern, destruct_alt,
        //   identity, recurse, field_access, index_access, iterate, slice,
        //   literal, paren, variable_ref, optional, array_construct,
        //   object_construct, string_interp, format_string, builtin_call,
        //   func_call, if_expr, try_catch, reduce, foreach, label_expr,
        //   break_expr, update_assign, assign_general, suffix.
        //
        // The 36th variant — `error_node` (`src/ast/nodes.zig:91`) — is
        // emitted by `parser.makeError` (`src/ast/parser.zig:100-103`),
        // and EVERY `makeError` call also pushes an entry into
        // `parse_result.errors` via `addError`. The `compile()` driver at
        // `src/compiler/root.zig:74-85` returns `.err` BEFORE invoking
        // `lowerNode` whenever `parse_result.hasErrors()` is true, so an
        // `error_node` cannot reach this switch in practice.
        //
        // Why each Wave 1.1 phase mattered (closing the prior fallthroughs
        // that this catch-all used to absorb):
        //
        //   * Phase-1 identifier-binding   — bare ident → load_field
        //                                    (3ef77e0, 2026-04-27).
        //   * Phase-2 variable-binding     — `$__loc__` magic var
        //                                    (8f34cf0, 2026-04-27).
        //   * Phase-3 regex-validation +   — test/match/scan/sub/gsub
        //              regex-dynamic         arity + dynamic comma-pat
        //                                    (b0dd3f7, 2026-04-27).
        //   * Phase-4 format-builtin       — `@fmt` codegen for unknown
        //                                    format names
        //                                    (da33639, 2026-04-27).
        //   * Phase-5 builtin-classifier + — extended classifyBuiltin
        //              builtin-dispatch      coverage / nameToBuiltinId
        //                                    (140cc0c, 2026-04-27).
        //   * Phase-6 destructure alt_bind — alt_bind in object/array
        //                                    destructure strict context
        //                                    (f48ebcf, 2026-04-27).
        //
        // RUNTIME RAISES STILL PRESENT (out of scope for the catch-all
        // closure — they are explicit, exhaustive arms, not fallthroughs):
        //
        //   * `lowerBuiltinCall` `.not_implemented` arm
        //     (`lower.zig` `BuiltinClass` exhaustive switch) — known
        //     builtin name/arity pairs that route through legacy.
        //   * `emit.zig:725 / :1839 / :2002` — pattern-strict alt_bind /
        //     unknown @fmt at emit / `nameToBuiltinId` fallback. Each is
        //     a named arm of an exhaustive switch, not a catch-all.
        //
        // Those four sites are tracked as Wave-3-mini SKIP markers;
        // the dispatcher falls back to legacy
        // when they fire. The invariant for THIS arm — "if all explicit
        // AST-tag arms are non-fallthrough, the catch-all is unreachable"
        // — holds independently of those.
        else => unreachable,
    }
}

// ─── Cat-10: builtin calls ──────────────────────────────────────────
//
// Category-10 covers the wider builtin alphabet (everything beyond
// `not`/`type`/`path` already owned by earlier categories). The lowering
// strategy groups builtins by call-shape so the IR + emission paths stay
// shared across many names rather than per-builtin one-offs:
//
//   * `zero_arg`     — leaf `call_builtin(name)`. Emit as
//                      `call_builtin(bid)`. Covers `length`, `keys`,
//                      `keys_unsorted`, `values`, `empty`, `tostring`,
//                      `tonumber`, math zero-args, etc.
//   * `value_arg1`   — `<arg> ; call_builtin(bid)` (no save/restore).
//                      Mirrors legacy `compileValueArgBuiltin1`'s
//                      simple-no-comma path.
//   * `filter_arg1`  — `save_input ; array_collect_start ; each ; <f> ;
//                      yield_output ; array_collect_end ;
//                      call_builtin(bid)`. Mirrors legacy
//                      `compileFilterArgBuiltin`.
//   * `math2`        — `save_input ; <a> ; restore_input ; save_input ;
//                      <b> ; restore_input ; call_builtin(bid)`. Mirrors
//                      legacy `compileTwoArgMath` / `compileSetpath`.
//   * `math3`        — same as math2 with three save/restore cycles.
//                      Mirrors legacy `compileThreeArgMath`.
//
// IR shape (single-source per plan §1.3 row 5: `call_builtin | span →
// args + extra → fn id`):
//   * `Node.extra` indexes into `extra_data`: 2 slots (offset, len) for
//     the builtin name, decoded back through `string_buf`.
//   * `Node.span_start/span_len` indexes into `extra_children`: each slot
//     is the IR-node index of one positional argument, in source order.
//
// Post-cutover every builtin the AST parser accepts has a dedicated
// class arm in `classifyBuiltin`. The legacy SKIP path is gone; the
// `not_implemented` enum tag remains only as an invariant sentinel —
// reaching it from dispatch is a parser/lower-table desync and is
// treated as `unreachable` at the call sites.
pub const BuiltinClass = enum {
    /// AST → unary `not` SemOp (cat-1).
    not,
    /// AST → unary `path_begin` SemOp (cat-6 — owns `path()`).
    path,
    /// 0-arg builtin → leaf `call_builtin(name)`.
    zero_arg,
    /// 1-arg value builtin (no save/restore around the arg).
    value_arg1,
    /// 1-arg filter-arg builtin (`map`-shaped: array_collect + each).
    filter_arg1,
    /// 2-arg math/path builtin (save/restore bracketed eval).
    math2,
    /// 3-arg math builtin (`fma`).
    math3,
    /// 1-arg regex builtin (`test`, `match`, `capture`, `scan`,
    /// `splits`). May absorb an optional 2nd literal flag string at
    /// the AST surface — flags are decoded at lower time, so the IR
    /// sees a literal-pattern collapsed shape (span_len = 0) or a
    /// dynamic-pattern shape (span_len = 1) plus a packed
    /// `(pool_idx, n_flag)` payload.
    regex1,
    /// 2-arg regex builtin (`sub`, `gsub`). May absorb an optional
    /// 3rd literal flag string. The replacement arg always lowers
    /// to a child IR node.
    regex2,
    /// Cat-13 — `range(n)` (1-arity). Generator-arg in position 1.
    /// Emits `[arg] | range1_gen | each` per
    /// `compileRange` (`compiler.zig:4366-4382`). Single arg lowers
    /// to a single IR child; the per-iteration array+each bracket
    /// is synthesized at emit time.
    range_gen1,
    /// Cat-13 — `range(from; to)` (2-arity). Generator-args in
    /// positions 1+2; emits per-arg array_collect with save_input
    /// bridging the two arrays, then `range2_gen | each`. Mirrors
    /// `compileRange` (`compiler.zig:4385-4412`).
    range_gen2,
    /// Cat-13 — `range(from; to; by)` (3-arity). Generator-args in
    /// positions 1+2+3. Mirrors `compileRange`
    /// (`compiler.zig:4413-4434`).
    range_gen3,
    /// Cat-13 — `limit(n; f)` / `skip(n; f)` / `nth(n; f)`. All
    /// share a scope+capture+iterate-over-n shape with a
    /// streaming `*_start` opcode bracketing the body. The name is
    /// re-read at emit time to pick `limit_start` /
    /// `skip_start` / `nth_start`. Mirrors `compileLimit`
    /// (`compiler.zig:4684`), `compileSkip` (`:4874`),
    /// `compileNth` (`:4924`).
    limit_skip_nth,
    /// Cat-13 — `first(f)` (1-arity). Desugars to `limit(1; f)` —
    /// no scope/var capture because n is a hardcoded literal.
    /// Mirrors `compileFirst` (`compiler.zig:4633`).
    first_arg1,
    /// Cat-13 — `last(f)` (1-arity). Desugars to `[f] | .[-1]`.
    /// Mirrors `compileLast` (`compiler.zig:4658`).
    last_arg1,
    /// Cat-17 — standalone `@fmt` form (e.g. `@base64`, `@json`).
    /// Arrives as `BuiltinCall { name = "@<fmt>", args = [] }` from
    /// the parser (`parseFormat` at `parser.zig:1031-1036`,
    /// `:1053-1056`). Emits a single `call_builtin(format_bid)` per
    /// legacy `compiler.zig:6227-6232`. The leading `@` in the name
    /// is the lowering+emit dispatch key; emit strips it before
    /// consulting `formatBuiltinId`.
    format_apply,
    /// Cat-15 — `while(cond; update)` / `until(cond; update)`. Both
    /// 2-arity loop forms share a (cond + update) shape with a
    /// `loop_top` jump target. Emit picks `while_` vs `until_` SemOp
    /// from the name. Mirrors legacy `compileWhile`
    /// (`compiler.zig:3428`) and `compileUntil` (`:3495`). The IR
    /// uses dedicated SemOps `while_` / `until_` rather than reusing
    /// `call_builtin` because the bytecode shape carries
    /// patch-table jumps that don't reduce to a flat builtin call.
    while_until_2arg,
    /// Cat-13 — `repeat(f)` (1-arity). Streaming infinite generator
    /// matching jq's `def repeat(exp): def _r: exp, _r; _r;`. Lowers
    /// as a single-child `call_builtin`-shaped IR node; emit
    /// brackets the body with `repeat_start` / `repeat_end` so the
    /// VM's RepeatFrame captures the original input and re-enters
    /// the body each time the body's generator chain exhausts.
    /// Termination relies on an enclosing `limit` (matching jq's
    /// `limit(N; repeat(f))` idiom); without one the loop runs
    /// forever — matching jq's bare `repeat` semantics.
    repeat_arg1,
    /// Cat-16 — `error(msg)` 1-arity. Legacy `compileErrorArg`
    /// (`compiler.zig:3956`) emits `<msg> ; pipe ; call_builtin(error_)`.
    /// The pipe is required because legacy first evaluates `msg` onto
    /// the value stack, then transfers it to current via `pipe`, so
    /// the VM's `error_` handler reads the message from the current
    /// value (not the value stack). Mirrors that legacy shape exactly.
    /// Distinct from `value_arg1` because value_arg1 emits no pipe.
    error_arg1,
    /// Cat-16 — `index(s)` / `rindex(s)` / `indices(s)` 1-arity. Same
    /// IR shape as `value_arg1` (single arg child + `call_builtin`),
    /// but classified separately because legacy
    /// `compileValueArgBuiltin1Collecting` accepts comma-arg generator
    /// forms (`indices("a", "b")`) — the new compiler relies on the
    /// `comma` SemOp's natural fork/jump emission to produce
    /// per-iteration calls when the arg is a comma-chain. The
    /// dedicated class lets `nameToBuiltinId` map these names to
    /// their bids in the 1-arity branch without growing
    /// `isValueArg1Builtin` (which would also expose them to other
    /// classifier consumers that aren't ready for generator args).
    /// Mirrors legacy `compileIndices` / `compileIndex` / `compileRindex`
    /// (`compiler.zig:4456-4468`).
    value_arg1_gen,
    /// Cat-16 — `del(path_expr)` 1-arity. Lowers as a single-child
    /// `call_builtin` IR node; the path-collect pipeline is
    /// synthesized at emit time. Mirrors legacy `compileDel`
    /// (`compiler.zig:5529`) byte-for-byte: `push_current ;
    /// capture_variable($orig) ; array_collect_start ; path_begin ;
    /// <body> ; path_end ; yield_output ; array_collect_end ;
    /// capture_variable($paths) ; load_variable($orig) ; pipe ;
    /// load_variable($paths) ; call_builtin(delpaths)`. No new SemOp
    /// required — every primitive in this sequence already has an
    /// IR-side counterpart, and emit-time hidden-var allocation via
    /// `Emitter.allocVar` matches legacy's `next_var_id` allocation
    /// order (orig before paths).
    del_path,
    /// P5 — `map(f)` 1-arity. Lowers as a single-child `call_builtin`
    /// IR node; the array-collect-each-yield bracket is synthesized at
    /// emit time. Mirrors legacy `compileMap` (`compiler.zig:3338`)
    /// byte-for-byte: `array_collect_start <end_ip> ; each ; <f> ;
    /// yield_output ; array_collect_end`. Distinct from `filter_arg1`
    /// because there is no leading `save_input` and no trailing
    /// `call_builtin(bid)` — `map` never invokes a runtime builtin;
    /// the array-collect bracket alone produces the result.
    map_arg1,
    /// P5 — `select(f)` 1-arity. Lowers as a single-child
    /// `call_builtin` IR node; the save/restore + jump bracket is
    /// synthesized at emit time. Mirrors legacy `compileSelect`
    /// (`compiler.zig:3376`) byte-for-byte: `save_input ; <f> ;
    /// jump_if_false skip ; restore_input ; jump done ;
    /// skip: restore_input ; backtrack ; done:`.
    select_arg1,
    /// Cat-18 — `any(f)` (1-arity). Desugars to
    ///   [first(.[] | if f then true else empty end)] | if . == [] then false else .[0] end
    /// Array-wrap ensures limit's exit via `ip=instructions.len` lands
    /// inside an array_collect frame rather than triggering `fork_alt` RHS.
    any_desugar1,
    /// Cat-18 — `any(g;f)` (2-arity). Desugars to
    ///   [first(g | if f then true else empty end)] | if . == [] then false else .[0] end
    any_desugar2,
    /// Cat-18 — `all(f)` (1-arity). Desugars to
    ///   [first(.[] | if f then empty else false end)] | if . == [] then true else .[0] end
    all_desugar1,
    /// Cat-18 — `all(g;f)` (2-arity). Desugars to
    ///   [first(g | if f then empty else false end)] | if . == [] then true else .[0] end
    all_desugar2,
    /// Cat-19 — `pick(f)` (1-arity). Desugars to the canonical jq prelude form:
    ///   . as $v | reduce path(f) as $p (null; setpath($p; $v | getpath($p)))
    /// Synthesizes AST nodes for the full reduce expression and recurses via
    /// lowerNode — no new VM opcode required; path/reduce/setpath/getpath are
    /// already supported IR primitives.
    pick_desugar1,
    /// Names that lower-time cannot handle in this phase.
    not_implemented,
};

/// Classify a builtin call by its (name, arity) tuple. The classifier is
/// the single source of truth shared by lowering and emission — emit's
/// `call_builtin` arm decides the bytecode pattern by re-running this
/// classifier on the dumped name + IR span_len. Names not handled here
/// surface `not_implemented` so the harness routes the query to legacy.
pub fn classifyBuiltin(name: []const u8, arity: usize) BuiltinClass {
    // Owned by other categories — early-out before consulting the tables.
    if (arity == 0 and std.mem.eql(u8, name, "not")) return .not;
    if (arity == 1 and std.mem.eql(u8, name, "path")) return .path;

    // Cat-17 — standalone `@fmt` form. Parser emits `BuiltinCall {
    // name = "@<fmt>", args = [] }` for `@base64` / `@json` / etc.
    // when not followed by a string literal (`parser.zig:1031-1036`,
    // `:1053-1056`). Dispatched before the generic name tables to
    // avoid mis-routing through `not_implemented`.
    if (arity == 0 and isFormatApplyName(name)) return .format_apply;

    // Regex builtins (cat-11). Dispatch by name alone, regardless of
    // arity. Lowering may produce span_len ∈ {0, 1, 2} depending on
    // literal/dynamic pattern + 1-arg/2-arg form, so a uniform arity
    // check would mis-route. The synthesized internal name `match__g`
    // (from `match("pat";"g")`) is treated as regex1 too.
    if (isRegex1BuiltinName(name)) return .regex1;
    if (isRegex2BuiltinName(name)) return .regex2;

    // Cat-13 generator-arg builtins. Each shape is name+arity
    // gated; the legacy compiler hand-writes the bytecode for each,
    // so the new compiler picks a class per (name, arity) tuple and
    // re-runs the same selection at emit time. Listed before the
    // generic arity tables because some names overlap (e.g. `first`
    // is also in `isZeroArgBuiltin`, but the 1-arity form is owned
    // here).
    if (std.mem.eql(u8, name, "range")) {
        if (arity == 1) return .range_gen1;
        if (arity == 2) return .range_gen2;
        if (arity == 3) return .range_gen3;
        return .not_implemented;
    }
    if (arity == 2 and isLimitSkipNthBuiltin(name)) return .limit_skip_nth;
    if (arity == 1 and std.mem.eql(u8, name, "first")) return .first_arg1;
    if (arity == 1 and std.mem.eql(u8, name, "last")) return .last_arg1;
    if (arity == 1 and std.mem.eql(u8, name, "repeat")) return .repeat_arg1;
    // Cat-15 control-flow loop builtins. Both share the same
    // (cond; update) shape; emit picks the SemOp + bytecode pattern by
    // name. Routed before the generic arity tables because `while`
    // and `until` are not in any of the math/value/filter buckets.
    if (arity == 2 and isWhileUntilBuiltin(name)) return .while_until_2arg;
    // Cat-16 — `error(msg)` 1-arity, `index/rindex/indices(s)`
    // 1-arity, `del(path_expr)` 1-arity. Each has a dedicated emit
    // shape (pipe-before-call for error; comma-tolerant value-arg
    // for index family; path-collect pipeline for del). Routed
    // before the generic arity tables because the 0-arity `error`
    // is owned by `zero_arg` (added to `isZeroArgBuiltin`), and
    // del/index are not in any other bucket.
    if (arity == 1 and std.mem.eql(u8, name, "error")) return .error_arg1;
    if (arity == 1 and isIndexFamilyBuiltin(name)) return .value_arg1_gen;
    if (arity == 1 and std.mem.eql(u8, name, "del")) return .del_path;
    // P5 — `map(f)` / `select(f)` 1-arity. Both have dedicated emit
    // shapes (array-collect-each-yield for map; save/restore + jump
    // for select) that don't reduce to a flat `call_builtin`. Routed
    // before the generic arity tables because neither name appears in
    // `isValueArg1Builtin` or `isFilterArg1Builtin`.
    if (arity == 1 and std.mem.eql(u8, name, "map")) return .map_arg1;
    if (arity == 1 and std.mem.eql(u8, name, "select")) return .select_arg1;
    // 0-arity `first` / `last` desugar to `.[0]` / `.[-1]` — see
    // legacy `compiler.zig:5930-5937`. They reach AST as a
    // `BuiltinCall` because the AST parser lists both names in
    // `isZeroArgBuiltin` (`src/ast/parser.zig:1601`). Lowered
    // straight into `load_index` so the IR mirrors the runtime
    // shape exactly.
    if (arity == 0 and std.mem.eql(u8, name, "first")) return .first_arg1;
    if (arity == 0 and std.mem.eql(u8, name, "last")) return .last_arg1;

    // Cat-19 — `pick(f)` (1-arity). Pure AST desugar to the jq canonical
    // prelude form; no VM opcode required. Routed before the generic
    // arity tables because `pick` does not appear in any value/filter
    // bucket and must not fall through to `.not_implemented`.
    if (arity == 1 and std.mem.eql(u8, name, "pick")) return .pick_desugar1;

    // Cat-18 — `any(f)` / `any(g;f)` / `all(f)` / `all(g;f)`.
    // Dispatched before the generic 0-arity table because the 0-arity
    // `any`/`all` on arrays are VM native builtins (`zero_arg`), while
    // the 1-arity and 2-arity forms must desugar via `lowerAnyAllDesugar`.
    if (std.mem.eql(u8, name, "any")) {
        if (arity == 1) return .any_desugar1;
        if (arity == 2) return .any_desugar2;
    }
    if (std.mem.eql(u8, name, "all")) {
        if (arity == 1) return .all_desugar1;
        if (arity == 2) return .all_desugar2;
    }

    if (arity == 0) {
        if (isZeroArgBuiltin(name)) return .zero_arg;
        return .not_implemented;
    }
    if (arity == 1 and isValueArg1Builtin(name)) return .value_arg1;
    if (arity == 1 and isFilterArg1Builtin(name)) return .filter_arg1;
    if (arity == 2 and isMath2Builtin(name)) return .math2;
    if (arity == 3 and isMath3Builtin(name)) return .math3;
    return .not_implemented;
}

/// Recognize `limit` / `skip` / `nth` (cat-13). All three share the
/// same `(n; f)` shape — n collected into an array, captured input
/// re-loaded for the body, streaming `*_start` opcode bracketing the
/// body. Emit re-reads the name to pick the right opcode.
pub fn isLimitSkipNthBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "limit") or
        std.mem.eql(u8, name, "skip") or
        std.mem.eql(u8, name, "nth");
}

/// Recognize a standalone `@fmt` builtin call name (cat-17). The
/// parser emits these as `BuiltinCall { name = "@<fmt>", args = [] }`
/// via `internFormatName` (`parser.zig:1582-1587`). Acceptance is
/// gated on the leading `@` plus a known format suffix — keeps
/// arbitrary `@whatever` from silently routing through this class.
pub fn isFormatApplyName(name: []const u8) bool {
    if (name.len < 2 or name[0] != '@') return false;
    return isKnownFormatName(name[1..]);
}

/// SSOT registry of legal `@fmt` suffixes. Mirrors legacy
/// `formatBuiltinId` (`src/query/src/compiler.zig:5573-5585`) and
/// emit-side `formatBuiltinId` (`src/compiler/emit.zig:1110`); all
/// three lists must stay in lockstep. Used by lowering to reject
/// unknown formats with a `query_syntax_error` (mirroring legacy's
/// parse-time `syntaxErr` at `compiler.zig:6210`) so emit can rely
/// on `formatBuiltinId` returning a value for any IR `format` /
/// `format_apply` node it sees.
pub fn isKnownFormatName(bare: []const u8) bool {
    return std.mem.eql(u8, bare, "text") or
        std.mem.eql(u8, bare, "json") or
        std.mem.eql(u8, bare, "csv") or
        std.mem.eql(u8, bare, "tsv") or
        std.mem.eql(u8, bare, "html") or
        std.mem.eql(u8, bare, "uri") or
        std.mem.eql(u8, bare, "urid") or
        std.mem.eql(u8, bare, "sh") or
        std.mem.eql(u8, bare, "base64") or
        std.mem.eql(u8, bare, "base64d");
}

/// Recognize `while` / `until` (cat-15). Both share the same
/// `(cond; update)` shape — backward-jump iteration with one
/// jump_if_false fork. Emit picks the bytecode pattern (and the
/// `while_` vs `until_` SemOp at lower time) by name.
pub fn isWhileUntilBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "while") or
        std.mem.eql(u8, name, "until");
}

/// Recognize `index` / `rindex` / `indices` (cat-16). All three are
/// 1-arity value-arg builtins legacy compiles via
/// `compileValueArgBuiltin1` (`compiler.zig:4456-4468`). The new
/// compiler routes them through `value_arg1_gen` so the comma-arg
/// generator form works through the natural `comma` SemOp emission
/// (FORK left | JUMP | right; call_builtin runs once per yielded arg
/// after the comma's pipe). Each bid is mapped in
/// `nameToBuiltinId` (1-arity branch).
pub fn isIndexFamilyBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "index") or
        std.mem.eql(u8, name, "rindex") or
        std.mem.eql(u8, name, "indices");
}

/// Recognize 1-arg regex builtin names (cat-11). The internal
/// generator variant `match__g` is recognized as well so the IR's
/// synthesized name from `match("pat";"g")` flows through the same
/// dispatch.
pub fn isRegex1BuiltinName(name: []const u8) bool {
    return std.mem.eql(u8, name, "test") or
        std.mem.eql(u8, name, "match") or
        std.mem.eql(u8, name, "match__g") or
        std.mem.eql(u8, name, "capture") or
        std.mem.eql(u8, name, "scan") or
        std.mem.eql(u8, name, "splits");
}

/// Recognize 2-arg regex builtin names (`sub`, `gsub`). The 3-arg
/// form `sub(pat;repl;"g")` lowers to `gsub_` at compile time —
/// single source of truth, one bid per distinct VM behavior.
pub fn isRegex2BuiltinName(name: []const u8) bool {
    return std.mem.eql(u8, name, "sub") or
        std.mem.eql(u8, name, "gsub");
}

/// Names accepted as zero-arg builtin calls. Mirrors legacy
/// `zeroArgBuiltinId` (`src/query/src/compiler.zig:2749`) — every name
/// whose 0-arg form maps to a single `call_builtin(bid)` instruction.
/// Names with both 0-arg and N-arg forms (e.g. `add`, `flatten`) appear
/// here AND in the appropriate higher-arity helper.
fn isZeroArgBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "length") or
        std.mem.eql(u8, name, "keys") or
        std.mem.eql(u8, name, "keys_unsorted") or
        std.mem.eql(u8, name, "values") or
        std.mem.eql(u8, name, "type") or
        std.mem.eql(u8, name, "empty") or
        std.mem.eql(u8, name, "tostring") or
        std.mem.eql(u8, name, "tonumber") or
        // Cat-16 — `error` 0-arity. Legacy maps it through
        // `zeroArgBuiltinId` (`compiler.zig:2758`) → `BuiltinId.error_`.
        // The 1-arity form `error(msg)` is owned by `error_arg1` because
        // it requires a value-pipe before `call_builtin(error_)`.
        std.mem.eql(u8, name, "error") or
        std.mem.eql(u8, name, "add") or
        std.mem.eql(u8, name, "sort") or
        std.mem.eql(u8, name, "reverse") or
        std.mem.eql(u8, name, "flatten") or
        std.mem.eql(u8, name, "min") or
        std.mem.eql(u8, name, "max") or
        std.mem.eql(u8, name, "to_entries") or
        std.mem.eql(u8, name, "from_entries") or
        std.mem.eql(u8, name, "unique") or
        std.mem.eql(u8, name, "paths") or
        std.mem.eql(u8, name, "leaf_paths") or
        std.mem.eql(u8, name, "tojson") or
        std.mem.eql(u8, name, "fromjson") or
        std.mem.eql(u8, name, "transpose") or
        std.mem.eql(u8, name, "ascii_downcase") or
        std.mem.eql(u8, name, "ascii_upcase") or
        std.mem.eql(u8, name, "ascii") or
        std.mem.eql(u8, name, "explode") or
        std.mem.eql(u8, name, "implode") or
        std.mem.eql(u8, name, "abs") or
        std.mem.eql(u8, name, "floor") or
        std.mem.eql(u8, name, "ceil") or
        std.mem.eql(u8, name, "round") or
        std.mem.eql(u8, name, "sqrt") or
        std.mem.eql(u8, name, "fabs") or
        std.mem.eql(u8, name, "nan") or
        std.mem.eql(u8, name, "infinite") or
        std.mem.eql(u8, name, "isinfinite") or
        std.mem.eql(u8, name, "isnan") or
        std.mem.eql(u8, name, "isnormal") or
        std.mem.eql(u8, name, "have_decnum") or
        std.mem.eql(u8, name, "have_literal_numbers") or
        std.mem.eql(u8, name, "exp") or
        std.mem.eql(u8, name, "exp2") or
        std.mem.eql(u8, name, "exp10") or
        std.mem.eql(u8, name, "log") or
        std.mem.eql(u8, name, "log2") or
        std.mem.eql(u8, name, "log10") or
        std.mem.eql(u8, name, "cbrt") or
        std.mem.eql(u8, name, "sin") or
        std.mem.eql(u8, name, "cos") or
        std.mem.eql(u8, name, "tan") or
        std.mem.eql(u8, name, "asin") or
        std.mem.eql(u8, name, "acos") or
        std.mem.eql(u8, name, "atan") or
        std.mem.eql(u8, name, "rint") or
        std.mem.eql(u8, name, "nearbyint") or
        std.mem.eql(u8, name, "trunc") or
        std.mem.eql(u8, name, "significand") or
        std.mem.eql(u8, name, "logb") or
        std.mem.eql(u8, name, "j0") or
        std.mem.eql(u8, name, "j1") or
        std.mem.eql(u8, name, "lgamma") or
        std.mem.eql(u8, name, "tgamma") or
        std.mem.eql(u8, name, "arrays") or
        std.mem.eql(u8, name, "objects") or
        std.mem.eql(u8, name, "strings") or
        std.mem.eql(u8, name, "numbers") or
        std.mem.eql(u8, name, "booleans") or
        std.mem.eql(u8, name, "nulls") or
        std.mem.eql(u8, name, "scalars") or
        std.mem.eql(u8, name, "normals") or
        std.mem.eql(u8, name, "iterables") or
        std.mem.eql(u8, name, "builtins") or
        std.mem.eql(u8, name, "stderr") or
        std.mem.eql(u8, name, "input") or
        std.mem.eql(u8, name, "inputs") or
        std.mem.eql(u8, name, "env") or
        std.mem.eql(u8, name, "halt") or
        std.mem.eql(u8, name, "toboolean") or
        std.mem.eql(u8, name, "utf8bytelength") or
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
        std.mem.eql(u8, name, "recurse") or
        // 0-arity `any`/`all` — VM native builtins (root.zig:4111-4140).
        // The 1-arity and 2-arity forms desugar via `lowerAnyAllDesugar`
        // and never reach `isZeroArgBuiltin`.
        std.mem.eql(u8, name, "any") or
        std.mem.eql(u8, name, "all");
}

/// Names accepted as 1-arg value-arg builtins. Mirrors the
/// `compileValueArgBuiltin1` dispatch sites in
/// `src/query/src/compiler.zig:5839-5908`. Excludes the regex family
/// (`test`, `match`, `sub`, `gsub`, `capture`, `scan`, `splits`) — those
/// require regex-pool packing into `call_builtin`'s operand and surface
/// as `not_implemented` until a dedicated regex category lands.
fn isValueArg1Builtin(name: []const u8) bool {
    return std.mem.eql(u8, name, "split") or
        std.mem.eql(u8, name, "join") or
        std.mem.eql(u8, name, "startswith") or
        std.mem.eql(u8, name, "endswith") or
        std.mem.eql(u8, name, "ltrimstr") or
        std.mem.eql(u8, name, "rtrimstr") or
        std.mem.eql(u8, name, "trimstr") or
        std.mem.eql(u8, name, "getpath") or
        std.mem.eql(u8, name, "delpaths") or
        std.mem.eql(u8, name, "bsearch") or
        std.mem.eql(u8, name, "strftime") or
        std.mem.eql(u8, name, "strptime") or
        std.mem.eql(u8, name, "strflocaltime") or
        std.mem.eql(u8, name, "flatten") or
        std.mem.eql(u8, name, "has") or
        std.mem.eql(u8, name, "contains") or
        std.mem.eql(u8, name, "inside");
}

/// Names accepted as 1-arg filter-arg builtins. Mirrors legacy
/// `compileFilterArgBuiltin` callers and `compileMapValues`.
///
/// `add` is overloaded: the 0-arity form (`[1,2] | add`) lives in
/// `isZeroArgBuiltin` and dispatches as a flat `call_builtin(add)`; the
/// 1-arity form `add(f)` collects the filter's outputs into an array
/// (filter-arg shape) and folds via `+`, so it routes through the
/// filter_arg1 emit path with a dedicated special-case (see
/// `emit.zig` filter_arg1 arm).
fn isFilterArg1Builtin(name: []const u8) bool {
    return std.mem.eql(u8, name, "sort_by") or
        std.mem.eql(u8, name, "group_by") or
        std.mem.eql(u8, name, "min_by") or
        std.mem.eql(u8, name, "max_by") or
        std.mem.eql(u8, name, "unique_by") or
        std.mem.eql(u8, name, "map_values") or
        std.mem.eql(u8, name, "add");
}

/// Names accepted as 2-arg math/path builtins (legacy
/// `compileTwoArgMath` + `compileSetpath`).
fn isMath2Builtin(name: []const u8) bool {
    return std.mem.eql(u8, name, "pow") or
        std.mem.eql(u8, name, "atan2") or
        std.mem.eql(u8, name, "remainder") or
        std.mem.eql(u8, name, "hypot") or
        std.mem.eql(u8, name, "scalb") or
        std.mem.eql(u8, name, "scalbln") or
        std.mem.eql(u8, name, "ldexp") or
        std.mem.eql(u8, name, "drem") or
        std.mem.eql(u8, name, "setpath");
}

/// Names accepted as 3-arg math builtins (only `fma` today).
fn isMath3Builtin(name: []const u8) bool {
    return std.mem.eql(u8, name, "fma");
}

/// Lower a `BuiltinCall` AST node into the IR. Walks the (name, arity)
/// classifier, lowers each arg first (post-order), then emits a single
/// SemOp with the args wired into `extra_children` and the name interned
/// into `string_buf` via `extra_data`. The class is rediscovered at emit
/// time from name + span_len — no extra discriminant slot.
fn lowerBuiltinCall(
    ctx: *Lowerer,
    bc: *const ast.Node.BuiltinCall,
    src_start: u32,
    src_len: u32,
) LowerError!u32 {
    // Cat-17 — standalone `@<unknown>`. Parser stamps `@` prefix on
    // format builtin names via `internFormatName`. An unknown suffix
    // is a compile error, not a backend gap — mirror legacy
    // `parsePrimary`'s `formatBuiltinId(...) orelse syntaxErr` at
    // `compiler.zig:6210`. Legacy reports the error at the format
    // ident token (one byte past the `@`), so `src_start + 1` lands
    // there. Reject before classifyBuiltin so unknowns don't fall
    // through the generic name tables.
    if (bc.args.len == 0 and bc.name.len >= 2 and bc.name[0] == '@' and !isKnownFormatName(bc.name[1..])) {
        ctx.compile_err = .{
            .kind = .query_syntax_error,
            .offset = src_start + 1,
            .len = 0,
        };
        return error.LowerDiagnostic;
    }

    const class = classifyBuiltin(bc.name, bc.args.len);
    switch (class) {
        .not => return ctx.pushNode(.{
            .op = .not,
            .src_start = src_start,
            .src_len = src_len,
        }),
        .path => {
            const body = try lowerNode(ctx, bc.args[0]);
            return ctx.pushNode(.{
                .op = .path_begin,
                .children = .{ body, 0 },
                .src_start = src_start,
                .src_len = src_len,
            });
        },
        .zero_arg => {
            const extra_idx = try ctx.internString(bc.name);
            return ctx.pushNode(.{
                .op = .call_builtin,
                .extra = extra_idx,
                .src_start = src_start,
                .src_len = src_len,
            });
        },
        .format_apply => {
            // Cat-17 — standalone `@fmt`. Reuse the `call_builtin`
            // SemOp: name carries the leading `@` so emit's
            // `emitCallBuiltin` re-classifies via `classifyBuiltin`,
            // strips the `@`, and dispatches to `formatBuiltinId`.
            // No args, no IR children — same shape as `zero_arg`.
            // Mirrors legacy `compiler.zig:6227-6232`.
            const extra_idx = try ctx.internString(bc.name);
            return ctx.pushNode(.{
                .op = .call_builtin,
                .extra = extra_idx,
                .src_start = src_start,
                .src_len = src_len,
            });
        },
        .value_arg1, .filter_arg1, .math2, .math3, .range_gen1, .range_gen2, .range_gen3, .limit_skip_nth, .first_arg1, .last_arg1, .error_arg1, .value_arg1_gen, .del_path, .map_arg1, .select_arg1, .repeat_arg1 => {
            // Lower every arg first into a scratch buffer — recursive
            // lowering of nested calls (or ctors) writes to
            // `extra_children`, so building our span via direct append
            // would interleave foreign entries. Bulk-append at the end
            // keeps the parent's `(span_start, span_len)` slice
            // contiguous (same pattern as `obj_ctor` / `arr_ctor`).
            //
            // Cat-13 (range/limit/skip/nth/first/last) share the same
            // shape: the IR carries the args verbatim; the
            // bracketing opcode pattern (array_collect, save_input,
            // limit_start, ...) is synthesized at emit time from the
            // (name, arity) tuple via `classifyBuiltin`.
            //
            // Cat-16 (error_arg1, value_arg1_gen, del_path) share the
            // same single-`call_builtin`-with-children IR shape; emit
            // dispatches the legacy bytecode pattern from the
            // classifier-rediscovered class (pipe-before-call,
            // arg-then-call, or path-collect synthesis respectively).
            const alloc = ctx.arena.allocator();
            var arg_idxs: std.ArrayListUnmanaged(u32) = .{};
            defer arg_idxs.deinit(alloc);
            for (bc.args) |arg_ast| {
                const arg_idx = try lowerNode(ctx, arg_ast);
                try arg_idxs.append(alloc, arg_idx);
            }
            const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
            try ctx.out.extra_children.appendSlice(alloc, arg_idxs.items);
            const span_len: u32 = @intCast(arg_idxs.items.len);
            const extra_idx = try ctx.internString(bc.name);
            return ctx.pushNode(.{
                .op = .call_builtin,
                .span_start = span_start,
                .span_len = span_len,
                .extra = extra_idx,
                .src_start = src_start,
                .src_len = src_len,
            });
        },
        .while_until_2arg => {
            // Cat-15 — `while(cond; update)` / `until(cond; update)`.
            // Both 2-arg loop builtins lower to dedicated SemOps:
            // `while_` / `until_` carry `children[0]=cond`,
            // `children[1]=update`. The patch-table jumps that wire
            // `loop_top` / `loop_exit` are emitted at emit time from
            // the SemOp tag (mirrors legacy `compileWhile`/`compileUntil`).
            std.debug.assert(bc.args.len == 2);
            const cond_idx = try lowerNode(ctx, bc.args[0]);
            const update_idx = try lowerNode(ctx, bc.args[1]);
            const op: ir.Op = if (std.mem.eql(u8, bc.name, "while"))
                .while_
            else
                .until_;
            return ctx.pushNode(.{
                .op = op,
                .children = .{ cond_idx, update_idx },
                .src_start = src_start,
                .src_len = src_len,
            });
        },
        .regex1 => return lowerRegexBuiltin1(ctx, bc, src_start, src_len),
        .regex2 => return lowerRegexBuiltin2(ctx, bc, src_start, src_len),
        // Cat-18 — `any(f)` / `any(g;f)` / `all(f)` / `all(g;f)`.
        // Desugared via AST synthesis + recursive lowerNode call.
        .any_desugar1, .any_desugar2, .all_desugar1, .all_desugar2 => |cls| {
            return lowerAnyAllDesugar(ctx, bc, cls, src_start, src_len);
        },
        // Cat-19 — `pick(f)` (1-arity). Desugared to the jq canonical
        // prelude form via AST synthesis + recursive lowerNode call.
        .pick_desugar1 => {
            return lowerPickDesugar(ctx, bc, src_start, src_len);
        },
        // Post-cutover: every builtin name the AST parser accepts has
        // a real class arm above. `.not_implemented` only escapes
        // `classifyBuiltin` for an unknown (name, arity) tuple, which
        // is a parser/lower-table desync — a compiler bug, not a
        // runtime SKIP.
        .not_implemented => unreachable,
    }
}

// ── Regex builtin lowering (cat-11) ──────────────────────────────────────────
//
// Single source of truth for regex pattern interning + flag decoding.
// Mirrors legacy `compileRegexBuiltin1` and `compileRegexBuiltin2` at
// `src/query/src/compiler.zig:3059-3147` and `:3742-3864`.
//
// Pattern classification (literal vs dynamic) drives two emission shapes:
//
// 1. Literal pattern (string-literal arg). The decoded pattern bytes
//    (with optional inline `(?<flags>)` prefix derived from a literal
//    flag string) are interned into the lowerer's `regex_pool`; the
//    resulting `u32` index is packed into `extra_data` slots 2..3 along
//    with the `n_flag` bit. The IR's variadic span carries only the
//    auxiliary args (replacement for `sub`/`gsub`); the regex pattern
//    itself does NOT reach the value stack — emit's `regex1`/`regex2`
//    bytecode pattern reads the pool index from the operand directly.
//
// 2. Dynamic pattern (any non-literal expression). The pattern is
//    lowered as a regular IR child and pushed onto the value stack at
//    runtime; `regex_pool_idx == REGEX_POOL_DYNAMIC` tells the VM to
//    consult its per-iterator `LruCache` instead of the compile-time
//    pool. Cat-11 only supports literal flags (3-arg sub/gsub flag
//    arg); dynamic flag strings surface as `RegexCompileError`.
//
// 3-arg regex builtins (`sub(pat;repl;"g")`, `match("pat";"g")`)
// dispatch to the global-mode internal variants `gsub_` / `match_g_`
// at lower time — single source of truth, one bid per distinct VM
// behavior. The IR carries the substituted name (`match__g`); emit's
// `nameToBuiltinId` recognizes the synthesized name and routes to
// `.match_g_`.

/// Lower a 1-arg regex builtin (`test`, `match`, `capture`, `scan`,
/// `splits`). AST shape: `BuiltinCall { args = [pat] }` or
/// `BuiltinCall { args = [pat, flag_string_lit] }` for the 2-arg
/// flag form. The optional flag string is absorbed at lower time;
/// non-literal flag strings surface as `RegexCompileError` (matches
/// legacy strictness — runtime-built flags are out of scope).
fn lowerRegexBuiltin1(
    ctx: *Lowerer,
    bc: *const ast.Node.BuiltinCall,
    src_start: u32,
    src_len: u32,
) LowerError!u32 {
    // [Phase-3] regex-validation. Legacy `compileRegexBuiltin1`
    // (`src/query/src/compiler.zig:3057`) probes for `(literal;`
    // and falls through to `compileRegexBuiltinSlow` (`:3226`); both
    // arms eventually error via `syntaxErr` when the arg shape is
    // wrong. Mirror that with a `query_syntax_error` LowerDiagnostic
    // anchored at the call span so wrong-arity calls become compile
    // errors instead of routing to the legacy backend.
    if (bc.args.len < 1 or bc.args.len > 2) {
        ctx.compile_err = .{
            .kind = .query_syntax_error,
            .offset = src_start,
            .len = src_len,
        };
        return error.LowerDiagnostic;
    }

    var flag_body: ?[]const u8 = null;
    if (bc.args.len == 2) {
        flag_body = extractStringLiteral(bc.args[1]) orelse {
            return regexLiteralFlagError(ctx, bc.args[1]);
        };
    }

    return lowerRegexBuiltinCommon(
        ctx,
        bc.name,
        bc.args[0],
        flag_body,
        &.{}, // 1-arg form has no replacement arg
        src_start,
        src_len,
    );
}

/// Lower a 2- or 3-arg regex builtin (`sub`, `gsub`). The replacement
/// arg always lowers to a child IR node; the regex pattern follows
/// the same literal/dynamic dichotomy as 1-arg builtins.
fn lowerRegexBuiltin2(
    ctx: *Lowerer,
    bc: *const ast.Node.BuiltinCall,
    src_start: u32,
    src_len: u32,
) LowerError!u32 {
    // [Phase-3] regex-validation. Legacy `compileRegexBuiltin2`
    // (`src/query/src/compiler.zig:3742`) requires `(pat ; repl)` or
    // `(pat ; repl ; "flags")` and reports `syntaxErr` on any other
    // arity once the second `parsePipe` returns. Mirror with a
    // `query_syntax_error` LowerDiagnostic at the call span.
    if (bc.args.len < 2 or bc.args.len > 3) {
        ctx.compile_err = .{
            .kind = .query_syntax_error,
            .offset = src_start,
            .len = src_len,
        };
        return error.LowerDiagnostic;
    }

    var flag_body: ?[]const u8 = null;
    if (bc.args.len == 3) {
        flag_body = extractStringLiteral(bc.args[2]) orelse {
            return regexLiteralFlagError(ctx, bc.args[2]);
        };
    }

    // [Phase-3] regex-dynamic. Replacement lowers as a regular value
    // child; comma-arg generators (`sub("a"; "b","c")`) lower into the
    // standard `fork ; b ; jump ; c` shape. Emit brackets the entire
    // repl child with `save_input` / `restore_input` so backtracking
    // re-enters the second branch with the original input restored —
    // identical bytecode shape to legacy's `parsePipe` inside the
    // bracket (`src/query/src/compiler.zig:3799`).
    const repl_idx = try lowerNode(ctx, bc.args[1]);

    return lowerRegexBuiltinCommon(
        ctx,
        bc.name,
        bc.args[0],
        flag_body,
        &.{repl_idx},
        src_start,
        src_len,
    );
}

/// Surface a `RegexCompileError` LowerDiagnostic anchored at `node`'s
/// span. Used when the optional flag arg of a 2-arg regex builtin or
/// the 3rd arg of `sub`/`gsub` is not a string literal — same
/// rejection as legacy at `src/query/src/compiler.zig:3824`.
fn regexLiteralFlagError(ctx: *Lowerer, node: *const Node) LowerError {
    ctx.last_regex_pattern_offset = node.span.start;
    ctx.last_regex_pattern_len = if (node.span.end >= node.span.start)
        node.span.end - node.span.start
    else
        0;
    ctx.compile_err = .{
        .kind = .regex_compile_error,
        .offset = ctx.last_regex_pattern_offset,
        .len = ctx.last_regex_pattern_len,
    };
    return error.LowerDiagnostic;
}

/// Shared lowering for 1- and 2-arg regex builtins. Interns the
/// pattern (with optional inline flag prefix) into the regex pool,
/// applies the `match_g_` / `gsub_` dispatch substitution if `g` is
/// set, and writes a 4-slot `extra_data` payload `(name_off, name_len,
/// pool_idx, n_flag)`. Emit's `regex1`/`regex2` cases read these
/// slots; the variadic span carries only the auxiliary args
/// (replacement for sub/gsub) plus an optional dynamic-pattern arg.
fn lowerRegexBuiltinCommon(
    ctx: *Lowerer,
    src_name: []const u8,
    pat_node: *const Node,
    flag_body: ?[]const u8,
    extra_args: []const u32,
    src_start: u32,
    src_len: u32,
) LowerError!u32 {
    var has_g = false;
    var has_n = false;
    var inline_buf: [8]u8 = undefined;
    var inline_flags: []const u8 = &.{};

    if (flag_body) |fb| {
        const decoded = decodeRegexFlags(fb, &inline_buf) catch {
            return regexLiteralFlagError(ctx, pat_node);
        };
        inline_flags = decoded.inline_flags;
        has_g = decoded.has_g;
        has_n = decoded.has_n;
    }

    // Substitute name when the `g` flag selects an internal variant:
    //   match("pat";"g")  → name "match__g" → emit BuiltinId.match_g_
    //   sub(pat;repl;"g") → name "gsub"     → emit BuiltinId.gsub_
    //   gsub(...; "g")    → name "gsub"     → unchanged (already global)
    // Single source of truth: one bid per distinct VM behavior.
    var effective_name = src_name;
    if (has_g) {
        if (std.mem.eql(u8, src_name, "match")) effective_name = "match__g";
        if (std.mem.eql(u8, src_name, "sub")) effective_name = "gsub";
    }

    // Pattern classification: literal → intern into pool; dynamic →
    // push the lowered key onto the value stack and use the
    // `REGEX_POOL_DYNAMIC` sentinel so the VM reads the pattern off
    // the stack at runtime. Mirrors legacy `compileRegexBuiltin1`
    // fast/slow split (`src/query/src/compiler.zig:3056-3097`) and
    // `compileRegexBuiltin2` (`:3742`). Cat-18 reaches both arms;
    // emit's `regex1`/`regex2` handlers consume the pattern from the
    // span when `pool_idx == REGEX_POOL_DYNAMIC`.
    const pat_literal = extractStringLiteral(pat_node);
    var pool_idx: u32 = types_mod.REGEX_POOL_DYNAMIC;
    if (pat_literal) |lit| {
        // Build the final key: optional `(?<flags>)` prefix + decoded
        // pattern bytes. Mirrors legacy `compileRegexBuiltin1FastLiteral`
        // and `compileRegexBuiltin2`'s 3-arg form key construction.
        const alloc = ctx.arena.allocator();
        var key_buf: std.ArrayListUnmanaged(u8) = .{};
        defer key_buf.deinit(alloc);
        if (inline_flags.len > 0) {
            try key_buf.appendSlice(alloc, "(?");
            try key_buf.appendSlice(alloc, inline_flags);
            try key_buf.append(alloc, ')');
        }
        try key_buf.appendSlice(alloc, lit);

        ctx.last_regex_pattern_offset = pat_node.span.start;
        ctx.last_regex_pattern_len = if (pat_node.span.end >= pat_node.span.start)
            pat_node.span.end - pat_node.span.start
        else
            0;

        pool_idx = ctx.internRegex(key_buf.items) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.RegexCompileError, error.RegexNotCompiled => {
                ctx.compile_err = .{
                    .kind = if (e == error.RegexNotCompiled) .regex_not_compiled else .regex_compile_error,
                    .offset = ctx.last_regex_pattern_offset,
                    .len = ctx.last_regex_pattern_len,
                };
                return error.LowerDiagnostic;
            },
        };
    }

    // Build the variadic span. For dynamic patterns the pattern arg
    // reaches the value stack; for literal patterns the regex pool
    // index supplies the regex and only `extra_args` (replacement, if
    // any) participate.
    const alloc = ctx.arena.allocator();
    var span_buf: std.ArrayListUnmanaged(u32) = .{};
    defer span_buf.deinit(alloc);

    if (pool_idx == types_mod.REGEX_POOL_DYNAMIC) {
        // [Phase-3] regex-dynamic. Dynamic pattern lowers as a regular
        // child. Comma-arg generators (`test("a","b")`,
        // `sub("a","b"; repl)`) lower into the standard
        // `fork ; a ; jump ; b` shape; emit's `regex1` / `regex2` cases
        // push the resulting key onto the value stack and call_builtin
        // consumes it. On backtrack from the call's output the fork
        // re-enters the second branch and re-runs call_builtin —
        // identical shape to legacy's `parsePipe` slow path
        // (`src/query/src/compiler.zig:3789`, `:3226`).
        const pat_idx = try lowerNode(ctx, pat_node);
        try span_buf.append(alloc, pat_idx);
    }
    try span_buf.appendSlice(alloc, extra_args);

    const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
    try ctx.out.extra_children.appendSlice(alloc, span_buf.items);
    const span_len: u32 = @intCast(span_buf.items.len);

    // 4-slot payload: `internString` writes (name_off, name_len);
    // append (pool_idx, n_flag).
    const extra_idx = try ctx.internString(effective_name);
    try ctx.out.extra_data.append(alloc, pool_idx);
    try ctx.out.extra_data.append(alloc, if (has_n) @as(u32, 1) else 0);

    return ctx.pushNode(.{
        .op = .call_builtin,
        .span_start = span_start,
        .span_len = span_len,
        .extra = extra_idx,
        .src_start = src_start,
        .src_len = src_len,
    });
}

/// Decoded regex flag string. `inline_flags` is the subset that maps
/// to a `(?<flags>)` inline group prepended to the pattern; `has_g`
/// and `has_n` are surfaced separately because they affect bid/operand
/// selection (not the pattern bytes).
const RegexFlagDecode = struct {
    inline_flags: []const u8,
    has_g: bool,
    has_n: bool,
};

/// Decode a regex flag string into the legacy flag-prefix tuple.
/// Recognized flag letters (`i`, `x`, `m`, `s`) → `inline_flags`;
/// `g` → `has_g`; `n` → `has_n`. Unknown letters →
/// `error.RegexCompileError`. Mirrors `emitFlagPrefix` at
/// `src/query/src/compiler.zig:3179`.
fn decodeRegexFlags(flag_body: []const u8, scratch: []u8) error{RegexCompileError}!RegexFlagDecode {
    var inline_len: usize = 0;
    var has_g = false;
    var has_n = false;
    for (flag_body) |ch| {
        switch (ch) {
            'i', 'x', 'm', 's' => {
                if (inline_len >= scratch.len) return error.RegexCompileError;
                scratch[inline_len] = ch;
                inline_len += 1;
            },
            'g' => has_g = true,
            'n' => has_n = true,
            else => return error.RegexCompileError,
        }
    }
    return .{
        .inline_flags = scratch[0..inline_len],
        .has_g = has_g,
        .has_n = has_n,
    };
}

/// Extract a string-literal value from an AST node, or null if the
/// node isn't a `.literal { .string = … }`. Used for regex-pattern
/// and flag-arg detection. The returned slice aliases the parser's
/// arena — caller must not mutate it.
fn extractStringLiteral(node: *const Node) ?[]const u8 {
    return switch (node.kind) {
        .literal => |lit| switch (lit) {
            .string => |s| s,
            else => null,
        },
        else => null,
    };
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

/// Append a `computed_index` node for a SuffixOp `.bracket_expr`. The
/// key expression is lowered first; the parent SemOp carries it as
/// `children[0]`. Emit synthesizes the legacy two-var capture pattern
/// (base + key) around the key emission so generator-form keys
/// (`[1,2,3] | .[(0,2)]`) re-run the per-iteration `load_computed` for
/// every yielded key. Plan §3.5 row P27 / cat-18.
fn lowerSuffixBracketExpr(ctx: *Lowerer, key_node: *Node, span: ast.Span) LowerError!u32 {
    const key_idx = try lowerNode(ctx, key_node);
    const sp = .{ .start = span.start, .len = if (span.end >= span.start) span.end - span.start else 0 };
    return ctx.pushNode(.{
        .op = .computed_index,
        .children = .{ key_idx, 0 },
        .src_start = sp.start,
        .src_len = sp.len,
    });
}

/// Append a `slice` node for a SuffixOp `.slice`.
fn lowerSuffixSlice(ctx: *Lowerer, sl: ast.Node.Slice, span: ast.Span) LowerError!u32 {
    const sp = .{ .start = span.start, .len = if (span.end >= span.start) span.end - span.start else 0 };
    return lowerSliceNode(ctx, sl, sp);
}

/// Shared lowering for the two slice-shaped AST nodes (`.slice` at
/// `lowerNode` and `.suffix.slice` at `lowerSuffixSlice`). When either
/// bound carries a non-null `from_expr` / `to_expr`, route through
/// `computed_slice` and lower the bound expressions as `children[0..2]`.
/// Otherwise emit the legacy `slice` op with literal bounds.
///
/// Flag layout in extra_data slot 2 (4 bits):
///   bit 0 — has_from
///   bit 1 — has_to
///   bit 2 — has_from_expr  (children[0] valid)
///   bit 3 — has_to_expr    (children[1] valid)
fn lowerSliceNode(ctx: *Lowerer, sl: ast.Node.Slice, sp: anytype) LowerError!u32 {
    const alloc = ctx.arena.allocator();
    const has_from_expr = sl.from_expr != null;
    const has_to_expr = sl.to_expr != null;
    const is_computed = has_from_expr or has_to_expr;

    var children: [2]u32 = .{ 0, 0 };
    if (has_from_expr) children[0] = try lowerNode(ctx, sl.from_expr.?);
    if (has_to_expr) children[1] = try lowerNode(ctx, sl.to_expr.?);

    const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
    const from_u: u32 = @bitCast(sl.from);
    const to_u: u32 = @bitCast(sl.to);
    try ctx.out.extra_data.append(alloc, from_u);
    try ctx.out.extra_data.append(alloc, to_u);
    const flags: u32 =
        (@as(u32, @intFromBool(sl.has_from))) |
        (@as(u32, @intFromBool(sl.has_to)) << 1) |
        (@as(u32, @intFromBool(has_from_expr)) << 2) |
        (@as(u32, @intFromBool(has_to_expr)) << 3);
    try ctx.out.extra_data.append(alloc, flags);

    return ctx.pushNode(.{
        .op = if (is_computed) .computed_slice else .slice,
        .children = children,
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
///
/// Computed `(expr):` keys are validated: jq rejects keys that are
/// provably non-string at compile time (e.g. `{(0):1}`). Latent under
/// `-Dcompile=new` pre-cutover — the dispatcher at
/// `src/query/root.zig:108` catches `.err` and falls back to legacy,
/// masking this rejection. Activates naturally at R5 cutover when the
/// dispatcher fallback is removed.
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
        .expr => |expr| {
            if (isProvablyNonStringKey(expr)) {
                ctx.compile_err = .{
                    .kind = .query_syntax_error,
                    .offset = expr.span.start,
                    .len = if (expr.span.end >= expr.span.start) expr.span.end - expr.span.start else 0,
                };
                return error.LowerDiagnostic;
            }
            return lowerNode(ctx, expr);
        },
    }
}

/// Compile-time check: returns `true` when `node` is provably a non-string
/// at evaluation time. Used by object-key validation to reject `{(0):1}`
/// and similar at compile time, matching jq's `parser.y` constant-key check.
/// Conservative: returns `false` for any input-dependent or string-typed
/// expression (so `{(.x):1}` and `{("foo"):1}` correctly continue to lower).
fn isProvablyNonStringKey(node: *const Node) bool {
    return switch (node.kind) {
        .literal => |lit| switch (lit) {
            .string => false,
            .int, .float, .bool_val, .null_val, .big_number => true,
        },
        .paren => |p| isProvablyNonStringKey(p.operand),
        // Arithmetic on numbers yields numbers; unary negate on a number
        // yields a number. Boolean ops and comparisons yield booleans
        // unconditionally — non-string regardless of operand types.
        .arithmetic => |b| isProvablyNonStringKey(b.left) and isProvablyNonStringKey(b.right),
        .unary_neg => |u| isProvablyNonStringKey(u.operand),
        .comparison, .and_expr, .or_expr => true,
        else => false,
    };
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

/// Synthesize a `load_const(int)` IR node carrying the i64 `n`. Mirrors
/// the literal-arm encoding in `lowerNode` (extra slot 0 = LiteralKind,
/// 1 = lo32, 2 = hi32). Used by the `$__loc__` magic-var lowering to
/// stamp the `"line": 1` value.
fn synthLoadConstInt(
    ctx: *Lowerer,
    n: i64,
    src_start: u32,
    src_len: u32,
) error{OutOfMemory}!u32 {
    const alloc = ctx.arena.allocator();
    const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
    try ctx.out.extra_data.append(alloc, @intFromEnum(ir.LiteralKind.int));
    const u: u64 = @bitCast(n);
    try ctx.out.extra_data.append(alloc, @truncate(u));
    try ctx.out.extra_data.append(alloc, @truncate(u >> 32));
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
    const child_idx = try lowerNode(ctx, node);
    const alloc = ctx.arena.allocator();
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

/// Walk an AST destructure pattern declaring every `simple` variable
/// in the order they appear. Mirrors legacy `scanAndDeclarePattern`
/// (`src/query/src/compiler.zig:373`): variables are allocated fresh
/// ids monotonically. Object computed keys do not declare vars (the
/// expression is evaluated at runtime); only the leaf `simple`
/// patterns claim ids.
fn declarePatternVars(ctx: *Lowerer, pat: ast.Pattern) error{OutOfMemory}!void {
    switch (pat) {
        .simple => |name| {
            _ = try ctx.declareVar(name);
        },
        .array => |elems| {
            for (elems) |sub| try declarePatternVars(ctx, sub);
        },
        .object => |fields| {
            for (fields) |fld| try declarePatternVars(ctx, fld.pattern);
        },
    }
}

/// Walk an AST destructure pattern declaring vars with `reuseOrDeclare`
/// semantics. Used for the second-and-onwards alternatives in a `?//`
/// chain — names that already exist (declared by P1) MUST share the
/// same var_id so legacy's null-initialisation contract is preserved.
/// Mirrors `scanAndDeclarePatternReuse`
/// (`src/query/src/compiler.zig:443`).
fn declarePatternVarsReuse(ctx: *Lowerer, pat: ast.Pattern) error{OutOfMemory}!void {
    switch (pat) {
        .simple => |name| {
            _ = try ctx.reuseOrDeclareVar(name);
        },
        .array => |elems| {
            for (elems) |sub| try declarePatternVarsReuse(ctx, sub);
        },
        .object => |fields| {
            for (fields) |fld| try declarePatternVarsReuse(ctx, fld.pattern);
        },
    }
}

/// Lower an AST `Pattern` into a single IR `destructure` node. The
/// caller is responsible for declaring pattern variables FIRST (via
/// `declarePatternVars` / `declarePatternVarsReuse`) so that lookups
/// inside object-pattern computed keys resolve correctly.
///
/// Per-kind layout in the IR:
///   .simple → `destructure(kind=as)` with var-name + var_id in extra_data
///   .array  → `destructure(kind=array)` with sub-pattern roots in span
///   .object → `destructure(kind=object)` with (key, sub-pattern) pairs in span
fn lowerPattern(
    ctx: *Lowerer,
    pat: ast.Pattern,
    parent_span: ast.Span,
) LowerError!u32 {
    const sp_start: u32 = parent_span.start;
    const sp_len: u32 = if (parent_span.end >= parent_span.start)
        parent_span.end - parent_span.start
    else
        0;
    const alloc = ctx.arena.allocator();

    switch (pat) {
        .simple => |name| {
            // Variables are declared by the caller; lookup must succeed.
            const var_id = ctx.lookupVar(name) orelse unreachable;
            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            try ctx.out.extra_data.append(alloc, @intFromEnum(ir.PatternKind.as));
            const offset: u32 = @intCast(ctx.out.string_buf.items.len);
            try ctx.out.string_buf.appendSlice(alloc, name);
            try ctx.out.extra_data.append(alloc, offset);
            try ctx.out.extra_data.append(alloc, @intCast(name.len));
            try ctx.out.extra_data.append(alloc, var_id);
            return ctx.pushNode(.{
                .op = .destructure,
                .extra = extra_idx,
                .src_start = sp_start,
                .src_len = sp_len,
            });
        },
        .array => |elems| {
            // Empty `as []` is a compile error at the legacy parser
            // (`src/query/src/compiler.zig:402`); mirror the diagnostic.
            // VM-semantics contract requires the same `query_syntax_error`
            // kind on rejected queries (plan §1.2 row 3).
            if (elems.len == 0) {
                ctx.compile_err = .{
                    .kind = .query_syntax_error,
                    .offset = sp_start,
                    .len = sp_len,
                };
                return error.LowerDiagnostic;
            }
            // Lower every sub-pattern FIRST and stash the resulting
            // node indices on the stack. The recursive `lowerPattern`
            // calls grow `extra_children` themselves (when their own
            // sub-patterns are non-leaf) — appending child indices
            // mid-iteration would interleave foreign entries into our
            // contiguous span. Building a temporary scratch list and
            // then bulk-appending keeps the parent span tight.
            var scratch: std.ArrayListUnmanaged(u32) = .{};
            defer scratch.deinit(alloc);
            for (elems) |sub| {
                const sub_idx = try lowerPattern(ctx, sub, parent_span);
                try scratch.append(alloc, sub_idx);
            }
            const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
            try ctx.out.extra_children.appendSlice(alloc, scratch.items);
            const span_len: u32 = @intCast(elems.len);
            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            try ctx.out.extra_data.append(alloc, @intFromEnum(ir.PatternKind.array));
            return ctx.pushNode(.{
                .op = .destructure,
                .span_start = span_start,
                .span_len = span_len,
                .extra = extra_idx,
                .src_start = sp_start,
                .src_len = sp_len,
            });
        },
        .object => |fields| {
            // Empty `as {}` is a compile error at the legacy parser
            // (`src/query/src/compiler.zig:425`); mirror the diagnostic.
            if (fields.len == 0) {
                ctx.compile_err = .{
                    .kind = .query_syntax_error,
                    .offset = sp_start,
                    .len = sp_len,
                };
                return error.LowerDiagnostic;
            }
            // Same buffering strategy as `.array` above — build the
            // (key, sub-pattern) pair list in a scratch buffer first,
            // then bulk-append. Recursive lowerPatternKey / lowerPattern
            // calls may grow `extra_children` for nested patterns or
            // computed-key sub-expressions.
            var scratch: std.ArrayListUnmanaged(u32) = .{};
            defer scratch.deinit(alloc);
            for (fields) |fld| {
                const key_idx = try lowerPatternKey(ctx, fld.key, parent_span);
                const sub_idx = try lowerPattern(ctx, fld.pattern, parent_span);
                try scratch.append(alloc, key_idx);
                try scratch.append(alloc, sub_idx);
            }
            const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
            try ctx.out.extra_children.appendSlice(alloc, scratch.items);
            const span_len: u32 = @intCast(2 * fields.len);
            const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
            try ctx.out.extra_data.append(alloc, @intFromEnum(ir.PatternKind.object));
            return ctx.pushNode(.{
                .op = .destructure,
                .span_start = span_start,
                .span_len = span_len,
                .extra = extra_idx,
                .src_start = sp_start,
                .src_len = sp_len,
            });
        },
    }
}

/// Lower an object-pattern key (static name or `(expr)`). Static keys
/// synthesise a `load_const(string)` so the destructure-emit ladder can
/// pop a literal from the value stack uniformly with the computed-key
/// case. Mirrors legacy `parseAndEmitPattern` for object fields
/// (`src/query/src/compiler.zig:899-955`) without duplicating the
/// emission code.
fn lowerPatternKey(
    ctx: *Lowerer,
    key: ast.PatternKey,
    parent_span: ast.Span,
) LowerError!u32 {
    const sp_start: u32 = parent_span.start;
    const sp_len: u32 = if (parent_span.end >= parent_span.start)
        parent_span.end - parent_span.start
    else
        0;
    switch (key) {
        .static => |name| return synthLoadConstString(ctx, name, sp_start, sp_len),
        .computed => |expr| {
            if (isProvablyNonStringKey(expr)) {
                ctx.compile_err = .{
                    .kind = .query_syntax_error,
                    .offset = expr.span.start,
                    .len = if (expr.span.end >= expr.span.start) expr.span.end - expr.span.start else 0,
                };
                return error.LowerDiagnostic;
            }
            return lowerNode(ctx, expr);
        },
    }
}

// ── Cat-18 — `any` / `all` desugar ──────────────────────────────────
//
// `any(f)` and `all(f)` desugar to a canonical short-circuit form that
// avoids the `first(...) // fallback` anti-pattern. When `limit_start`
// exits via `ip = instructions.len` (the exhaustion path), any `fork_alt`
// frame on the fork stack fires its RHS spuriously. Wrapping `first()`
// inside `[...]` (array_collect) redirects `yield_output` into the
// collect frame so the limit truncation never reaches `fork_alt`.
//
// any(f)    → [first(.[] | if f then true  else empty end)] | if . == [] then false else .[0] end
// any(g;f)  → [first(g   | if f then true  else empty end)] | if . == [] then false else .[0] end
// all(f)    → [first(.[] | if f then empty else false end)] | if . == [] then true  else .[0] end
// all(g;f)  → [first(g   | if f then empty else false end)] | if . == [] then true  else .[0] end

fn lowerAnyAllDesugar(
    ctx: *Lowerer,
    bc: *const ast.Node.BuiltinCall,
    cls: BuiltinClass,
    src_start: u32,
    src_len: u32,
) LowerError!u32 {
    _ = src_start;
    _ = src_len;
    const alloc = ctx.arena.allocator();

    const is_any = (cls == .any_desugar1 or cls == .any_desugar2);
    // gen_node: generator expression
    //   1-arity: `.[]` (iterate)
    //   2-arity: bc.args[0]
    const gen_node: *ast.Node = switch (cls) {
        .any_desugar1, .all_desugar1 => blk: {
            const n = try alloc.create(ast.Node);
            n.* = .{ .kind = .iterate, .span = ast.Span.empty() };
            break :blk n;
        },
        .any_desugar2, .all_desugar2 => bc.args[0],
        else => unreachable,
    };

    // pred_node: predicate filter
    //   1-arity: bc.args[0]
    //   2-arity: bc.args[1]
    const pred_node: *ast.Node = switch (cls) {
        .any_desugar1, .all_desugar1 => bc.args[0],
        .any_desugar2, .all_desugar2 => bc.args[1],
        else => unreachable,
    };

    // true_lit / false_lit / empty_call
    const true_lit = try alloc.create(ast.Node);
    true_lit.* = .{ .kind = .{ .literal = .{ .bool_val = true } }, .span = ast.Span.empty() };
    const false_lit = try alloc.create(ast.Node);
    false_lit.* = .{ .kind = .{ .literal = .{ .bool_val = false } }, .span = ast.Span.empty() };
    const empty_call = try alloc.create(ast.Node);
    empty_call.* = .{ .kind = .{ .builtin_call = .{ .name = "empty", .args = &.{} } }, .span = ast.Span.empty() };

    // inner_if:
    //   any: if pred then true  else empty end
    //   all: if pred then empty else false end
    const inner_then: *ast.Node = if (is_any) true_lit else empty_call;
    const inner_else: *ast.Node = if (is_any) empty_call else false_lit;
    const inner_if = try alloc.create(ast.Node);
    inner_if.* = .{
        .kind = .{ .if_expr = .{
            .cond = pred_node,
            .then_body = inner_then,
            .elif_chains = &.{},
            .else_body = inner_else,
        } },
        .span = ast.Span.empty(),
    };

    // pipe_node: gen | inner_if
    const pipe_node = try alloc.create(ast.Node);
    pipe_node.* = .{
        .kind = .{ .pipe = .{ .left = gen_node, .right = inner_if } },
        .span = ast.Span.empty(),
    };

    // first_node: builtin_call "first" [pipe_node]
    const first_args = try alloc.alloc(*ast.Node, 1);
    first_args[0] = pipe_node;
    const first_node = try alloc.create(ast.Node);
    first_node.* = .{
        .kind = .{ .builtin_call = .{ .name = "first", .args = first_args } },
        .span = ast.Span.empty(),
    };

    // arr_node: [first_node]  (array_construct)
    const arr_node = try alloc.create(ast.Node);
    arr_node.* = .{
        .kind = .{ .array_construct = .{ .expr = first_node } },
        .span = ast.Span.empty(),
    };

    // outer_if condition: . == []
    const identity_node = try alloc.create(ast.Node);
    identity_node.* = .{ .kind = .identity, .span = ast.Span.empty() };
    const empty_arr = try alloc.create(ast.Node);
    empty_arr.* = .{ .kind = .{ .array_construct = .{ .expr = null } }, .span = ast.Span.empty() };
    const cmp_node = try alloc.create(ast.Node);
    cmp_node.* = .{
        .kind = .{ .comparison = .{ .op = .eq, .left = identity_node, .right = empty_arr } },
        .span = ast.Span.empty(),
    };

    // .[0] for the else branch
    const idx_node = try alloc.create(ast.Node);
    idx_node.* = .{
        .kind = .{ .suffix = .{
            .base = blk: {
                const id = try alloc.create(ast.Node);
                id.* = .{ .kind = .identity, .span = ast.Span.empty() };
                break :blk id;
            },
            .ops = blk: {
                const ops = try alloc.alloc(ast.Node.SuffixOp, 1);
                ops[0] = .{ .index = 0 };
                break :blk ops;
            },
        } },
        .span = ast.Span.empty(),
    };

    // fallback: false (any) or true (all)
    const fallback: *ast.Node = if (is_any) false_lit else true_lit;

    // outer_if: if . == [] then fallback else .[0] end
    const outer_if = try alloc.create(ast.Node);
    outer_if.* = .{
        .kind = .{ .if_expr = .{
            .cond = cmp_node,
            .then_body = fallback,
            .elif_chains = &.{},
            .else_body = idx_node,
        } },
        .span = ast.Span.empty(),
    };

    // root: arr_node | outer_if
    const root_node = try alloc.create(ast.Node);
    root_node.* = .{
        .kind = .{ .pipe = .{ .left = arr_node, .right = outer_if } },
        .span = ast.Span.empty(),
    };

    return lowerNode(ctx, root_node);
}

// ── Cat-19 — `pick(f)` desugar ───────────────────────────────────────────────
//
// Canonical jq prelude:
//   def pick(f): . as $v | reduce path(f) as $p (null; setpath($p; $v | getpath($p)));
//
// Synthesizes the full AST tree and recurses via lowerNode. Uses only
// AST node kinds already supported by the lowerer: as_pattern, reduce,
// path_begin (builtin_call "path"), variable_ref, builtin_call "setpath"/
// "getpath", literal null, identity, pipe. No new VM opcode is required.
fn lowerPickDesugar(
    ctx: *Lowerer,
    bc: *const ast.Node.BuiltinCall,
    src_start: u32,
    src_len: u32,
) LowerError!u32 {
    _ = src_start;
    _ = src_len;
    const alloc = ctx.arena.allocator();

    // f is bc.args[0] — the path-generating filter
    const f_node: *ast.Node = bc.args[0];

    // identity: .
    const identity_node = try alloc.create(ast.Node);
    identity_node.* = .{ .kind = .identity, .span = ast.Span.empty() };

    // null literal for reduce init
    const null_lit = try alloc.create(ast.Node);
    null_lit.* = .{ .kind = .{ .literal = .null_val }, .span = ast.Span.empty() };

    // $v — variable references used in the reduce body
    const v_ref_for_getpath = try alloc.create(ast.Node);
    v_ref_for_getpath.* = .{ .kind = .{ .variable_ref = .{ .name = "$v" } }, .span = ast.Span.empty() };

    // $p — variable reference used as the setpath arg and inside getpath
    const p_ref_setpath_arg = try alloc.create(ast.Node);
    p_ref_setpath_arg.* = .{ .kind = .{ .variable_ref = .{ .name = "$p" } }, .span = ast.Span.empty() };

    const p_ref_getpath_arg = try alloc.create(ast.Node);
    p_ref_getpath_arg.* = .{ .kind = .{ .variable_ref = .{ .name = "$p" } }, .span = ast.Span.empty() };

    // getpath($p) — 1-arg value builtin: $v | getpath($p)
    const getpath_args = try alloc.alloc(*ast.Node, 1);
    getpath_args[0] = p_ref_getpath_arg;
    const getpath_call = try alloc.create(ast.Node);
    getpath_call.* = .{
        .kind = .{ .builtin_call = .{ .name = "getpath", .args = getpath_args } },
        .span = ast.Span.empty(),
    };

    // $v | getpath($p)
    const vref_pipe_getpath = try alloc.create(ast.Node);
    vref_pipe_getpath.* = .{
        .kind = .{ .pipe = .{ .left = v_ref_for_getpath, .right = getpath_call } },
        .span = ast.Span.empty(),
    };

    // setpath($p; $v | getpath($p)) — 2-arg math builtin
    const setpath_args = try alloc.alloc(*ast.Node, 2);
    setpath_args[0] = p_ref_setpath_arg;
    setpath_args[1] = vref_pipe_getpath;
    const setpath_call = try alloc.create(ast.Node);
    setpath_call.* = .{
        .kind = .{ .builtin_call = .{ .name = "setpath", .args = setpath_args } },
        .span = ast.Span.empty(),
    };

    // path(f) — the generator expression for the reduce
    const path_args = try alloc.alloc(*ast.Node, 1);
    path_args[0] = f_node;
    const path_call = try alloc.create(ast.Node);
    path_call.* = .{
        .kind = .{ .builtin_call = .{ .name = "path", .args = path_args } },
        .span = ast.Span.empty(),
    };

    // reduce path(f) as $p (null; setpath($p; $v | getpath($p)))
    const reduce_node = try alloc.create(ast.Node);
    reduce_node.* = .{
        .kind = .{ .reduce = .{
            .expr = path_call,
            .pattern = .{ .simple = "$p" },
            .init = null_lit,
            .update = setpath_call,
        } },
        .span = ast.Span.empty(),
    };

    // . as $v | <reduce>
    const root_node = try alloc.create(ast.Node);
    root_node.* = .{
        .kind = .{ .as_pattern = .{
            .expr = identity_node,
            .pattern = .{ .simple = "$v" },
            .body = reduce_node,
        } },
        .span = ast.Span.empty(),
    };

    return lowerNode(ctx, root_node);
}

// ── Cat-14 — `reduce` / `foreach` lowering ────────────────────────
//
// Both ops share the same skeleton: allocate two hidden var_ids
// (saved_input + accumulator), lower expr WITHOUT the pattern in scope,
// open a fresh var-scope, declare pattern vars, lower init (which
// runs BEFORE the pattern is visible — but legacy lets init see the
// pattern in scope to match the strict-mode invariant; see legacy line
// 4005 / 4159 where parsePipe runs after pushScope+scanAndDeclarePattern,
// but init never references the pattern in practice — the legacy parser
// allows it syntactically and we mirror that here). Then lower update
// (and for foreach optionally extract) with pattern visible.
//
// The pattern destructure node is built via `lowerPattern` so the
// emit-side `emitPatternAs/Array/Object` ladders are reused unchanged.
//
// Var-scope discipline mirrors the cat-15 `label` arm: snapshot
// `var_table`, run a fresh shallow-copy under it, then restore on
// exit so pattern bindings don't leak to siblings.
fn lowerReduce(
    ctx: *Lowerer,
    rd: *const ast.Node.Reduce,
    sp_start: u32,
    sp_len: u32,
) LowerError!u32 {
    const alloc = ctx.arena.allocator();

    // Hidden var ids — bumped raw, never registered in var_table.
    const saved_input_id = ctx.next_var_id;
    ctx.next_var_id += 1;
    const acc_id = ctx.next_var_id;
    ctx.next_var_id += 1;

    // Lower expr BEFORE opening the pattern scope — expr cannot
    // reference pattern vars (parser disallows; we mirror).
    const expr_idx = try lowerNode(ctx, rd.expr);

    // Lower init BEFORE opening the pattern scope. Legacy parses init
    // AFTER pushScope+scanAndDeclarePattern but init never references
    // pattern vars in practice; lowering it here keeps the var-scope
    // surface narrow.
    const init_idx = try lowerNode(ctx, rd.init);

    // Snapshot var_table so pattern vars pop after lowering.
    const saved_var_table = ctx.var_table;
    var fresh_var_table: std.StringHashMapUnmanaged(u32) = .{};
    var it = saved_var_table.iterator();
    while (it.next()) |kv| {
        try fresh_var_table.put(alloc, kv.key_ptr.*, kv.value_ptr.*);
    }
    ctx.var_table = fresh_var_table;
    defer {
        ctx.var_table.deinit(alloc);
        ctx.var_table = saved_var_table;
    }

    try declarePatternVars(ctx, rd.pattern);
    const pattern_idx = try lowerPattern(ctx, rd.pattern, rd.expr.span);

    const update_idx = try lowerNode(ctx, rd.update);

    // Build span: [expr, pattern, init, update].
    const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
    try ctx.out.extra_children.append(alloc, expr_idx);
    try ctx.out.extra_children.append(alloc, pattern_idx);
    try ctx.out.extra_children.append(alloc, init_idx);
    try ctx.out.extra_children.append(alloc, update_idx);

    const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
    try ctx.out.extra_data.append(alloc, saved_input_id);
    try ctx.out.extra_data.append(alloc, acc_id);

    return ctx.pushNode(.{
        .op = .reduce,
        .span_start = span_start,
        .span_len = 4,
        .extra = extra_idx,
        .src_start = sp_start,
        .src_len = sp_len,
    });
}

fn lowerForeach(
    ctx: *Lowerer,
    fe: *const ast.Node.Foreach,
    sp_start: u32,
    sp_len: u32,
) LowerError!u32 {
    const alloc = ctx.arena.allocator();

    const saved_input_id = ctx.next_var_id;
    ctx.next_var_id += 1;
    const acc_id = ctx.next_var_id;
    ctx.next_var_id += 1;

    const expr_idx = try lowerNode(ctx, fe.expr);
    const init_idx = try lowerNode(ctx, fe.init);

    const saved_var_table = ctx.var_table;
    var fresh_var_table: std.StringHashMapUnmanaged(u32) = .{};
    var it = saved_var_table.iterator();
    while (it.next()) |kv| {
        try fresh_var_table.put(alloc, kv.key_ptr.*, kv.value_ptr.*);
    }
    ctx.var_table = fresh_var_table;
    defer {
        ctx.var_table.deinit(alloc);
        ctx.var_table = saved_var_table;
    }

    try declarePatternVars(ctx, fe.pattern);
    const pattern_idx = try lowerPattern(ctx, fe.pattern, fe.expr.span);

    const update_idx = try lowerNode(ctx, fe.update);
    const has_extract = fe.extract != null;
    const extract_idx: u32 = if (fe.extract) |ex| try lowerNode(ctx, ex) else 0;

    const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
    try ctx.out.extra_children.append(alloc, expr_idx);
    try ctx.out.extra_children.append(alloc, pattern_idx);
    try ctx.out.extra_children.append(alloc, init_idx);
    try ctx.out.extra_children.append(alloc, update_idx);
    if (has_extract) {
        try ctx.out.extra_children.append(alloc, extract_idx);
    }
    const span_len: u32 = if (has_extract) 5 else 4;

    const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
    try ctx.out.extra_data.append(alloc, saved_input_id);
    try ctx.out.extra_data.append(alloc, acc_id);

    return ctx.pushNode(.{
        .op = .foreach,
        .span_start = span_start,
        .span_len = span_len,
        .extra = extra_idx,
        .src_start = sp_start,
        .src_len = sp_len,
    });
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

/// Synthesize the else-position node for an `if`-chain at lowering time.
/// `chain_idx` is the next elif slot to consume. Returns the IR-array
/// index of the lowered else-arm:
///   * if there are remaining elif slots: build a nested `if_` node
///     that consumes the next elif and recurses on chain_idx + 1.
///   * else if `else_body` is set: lower it directly.
///   * else: synthesize an `identity` node (matches legacy implicit-else
///     `parseIfBody` line 6390 — `.` flowing the current input through).
///
/// `parent_start`/`parent_len` carry the outer if's source span so each
/// nested `if_` inherits the same byte coverage — legacy emits the
/// entire chain under one `if`'s IP range, keeping source-position
/// parity trivial across the elif desugar.
fn lowerIfElseChain(
    ctx: *Lowerer,
    ifx: *const ast.Node.IfExpr,
    chain_idx: usize,
    parent_start: u32,
    parent_len: u32,
) LowerError!u32 {
    if (chain_idx < ifx.elif_chains.len) {
        const elif = ifx.elif_chains[chain_idx];
        const cond = try lowerNode(ctx, elif.cond);
        const then_body = try lowerNode(ctx, elif.body);
        const else_idx = try lowerIfElseChain(ctx, ifx, chain_idx + 1, parent_start, parent_len);
        const alloc = ctx.arena.allocator();
        const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
        try ctx.out.extra_children.append(alloc, cond);
        try ctx.out.extra_children.append(alloc, then_body);
        try ctx.out.extra_children.append(alloc, else_idx);
        return ctx.pushNode(.{
            .op = .if_,
            .span_start = span_start,
            .span_len = 3,
            .src_start = parent_start,
            .src_len = parent_len,
        });
    }
    if (ifx.else_body) |eb| {
        return lowerNode(ctx, eb);
    }
    // Implicit else → identity. Matches legacy `parseIfBody`
    // (`src/query/src/compiler.zig:6390`).
    return ctx.pushNode(.{
        .op = .identity,
        .src_start = parent_start,
        .src_len = parent_len,
    });
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

// ── Cat-9: user-defined functions + recursion + filter args ──────────────────

/// Lower a `def name(params): body; rest` form. The def itself
/// produces no IR node — only the `rest` continuation does. The body
/// is registered with the entry; non-recursive call sites re-lower it
/// inline (with bindings active), recursive call sites emit
/// `call_user` IR that emit translates to `call_function(body_ip)`.
fn lowerFuncDef(
    ctx: *Lowerer,
    fd: *const ast.Node.FuncDef,
    src_start: u32,
    src_len: u32,
) LowerError!u32 {
    _ = src_start;
    _ = src_len;
    const alloc = ctx.arena.allocator();

    // Build the param table. Value params claim a fresh canonical
    // var_id at registration time so the body, lowered once for
    // recursive functions, can reference them via load_var. Filter
    // params don't carry a var_id — they re-substitute the caller's
    // AST sub-tree at call time.
    var params: std.ArrayListUnmanaged(ParamInfo) = .{};
    defer params.deinit(alloc);
    for (fd.params) |p| {
        if (p.is_filter) {
            try params.append(alloc, .{
                .name = p.name,
                .is_filter = true,
                .var_id = 0, // unused
            });
        } else {
            const var_id = ctx.next_var_id;
            ctx.next_var_id += 1;
            try params.append(alloc, .{
                .name = p.name,
                .is_filter = false,
                .var_id = var_id,
            });
        }
    }

    // Detect direct self-recursion via an AST scan. Mutual recursion
    // (def f: g; def g: f) flips on at expansion time via
    // `expanding_stack` regardless of this flag.
    const is_recursive = bodyReferencesSelf(fd.body, fd.name, @intCast(fd.params.len));

    // Snapshot the function-table length for inner-def lex scoping —
    // any defs registered while THIS function's body is re-walked
    // will live above this snapshot and get hidden when we re-enter
    // the body (mirrors legacy's `func_table_snapshot` at compiler.zig:1010).
    const func_table_snapshot: u32 = @intCast(ctx.function_table.items.len);

    const params_owned = try alloc.dupe(ParamInfo, params.items);
    try ctx.function_table.append(alloc, .{
        .name = fd.name,
        .params = params_owned,
        .body = fd.body,
        .is_recursive = is_recursive,
        .body_ir_root = BODY_IR_NOT_LOWERED,
        .func_table_snapshot = func_table_snapshot,
    });

    // Lower the continuation. The function entry stays in scope for
    // the entirety of `rest` (legacy lex pos progresses past `;` and
    // continues parsing the same input — the def's scope reaches the
    // end of its enclosing scope).
    const rest_idx = try lowerNode(ctx, fd.rest);

    // Close the def's lexical scope. Mirrors inlineUserCall:3464-3469
    // for the analogous inner-def case: the def is visible only within
    // `rest`, so on return the def itself plus any siblings registered
    // during rest's lowering are out of scope for the enclosing expr.
    {
        var k: usize = func_table_snapshot;
        while (k < ctx.function_table.items.len) : (k += 1) {
            ctx.function_table.items[k].out_of_scope = true;
        }
    }

    return rest_idx;
}

/// Inline-expand a non-recursive user-function call at the call site.
/// Produces a single `call_user` IR node carrying the lowered value
/// args + the per-call-site lowered body. Emit translates this into
/// the legacy bytecode shape `<arg_0> ; capture_variable v_0 ; ... ;
/// <body> ; pop_variable v_n ; ...`.
///
/// The body is re-lowered HERE with filter-arg bindings active; the
/// body IR is fresh per call site (filter args are textually
/// substituted, so different call sites produce different bodies).
/// Filter args therefore have no IR representation — they're consumed
/// during body re-walk.
///
/// IR layout for non-recursive call_user (`is_inline=true`):
///   span = [value_arg_0, value_arg_1, ..., body_idx]
///   span_len = num_value_args + 1
///   extra_data = [fn_id, name_off, name_len, IS_INLINE_TRUE]
///
/// IR layout for recursive call_user (set by `synthCallUser`):
///   span = [value_arg_0, value_arg_1, ...]
///   span_len = num_value_args
///   extra_data = [fn_id, name_off, name_len, IS_INLINE_FALSE]
fn inlineUserCall(
    ctx: *Lowerer,
    fn_id: u32,
    args: []const *Node,
    src_start: u32,
    src_len: u32,
) LowerError!u32 {
    const alloc = ctx.arena.allocator();
    const entry = ctx.function_table.items[fn_id];
    const params = entry.params;
    std.debug.assert(params.len == args.len);

    // Phase 1 — lower value args at the OUTER scope so their
    // references (vars, filter-arg bindings) resolve against the
    // caller's site, not the callee's.
    var value_arg_idxs: std.ArrayListUnmanaged(u32) = .{};
    defer value_arg_idxs.deinit(alloc);
    for (params, args) |param, arg_ast| {
        if (param.is_filter) continue;
        const arg_idx = try lowerNode(ctx, arg_ast);
        try value_arg_idxs.append(alloc, arg_idx);
    }

    // Phase 2 — push filter-arg bindings + scope-hide-range. Save
    // restore-points so the lowering state returns clean after the
    // body re-walk.
    const saved_bindings_len: u32 = @intCast(ctx.filter_arg_bindings.items.len);
    const saved_hidden_start = ctx.func_hidden_start;
    const saved_hidden_end = ctx.func_hidden_end;
    const saved_var_table = ctx.var_table;

    for (params, args) |param, arg_ast| {
        if (!param.is_filter) continue;
        // Snapshot caller's var_table at capture so the filter-arg
        // re-walk later resolves `$x` against the caller's scope, not
        // the callee's (which may rebind `x` via `as $x` or value
        // params — see `FilterArgBinding.var_table_at_capture` doc).
        var captured_vars: std.StringHashMapUnmanaged(u32) = .{};
        var src_it = saved_var_table.iterator();
        while (src_it.next()) |kv| {
            try captured_vars.put(alloc, kv.key_ptr.*, kv.value_ptr.*);
        }
        try ctx.filter_arg_bindings.append(alloc, .{
            .name = param.name,
            .arg_ast = arg_ast,
            .bindings_floor_at_capture = saved_bindings_len,
            .var_table_at_capture = captured_vars,
        });
    }

    // Hide functions registered between this function's def time and
    // the current snapshot — they're not lex-visible from the body.
    const hidden_end: u32 = @intCast(ctx.function_table.items.len);
    if (entry.func_table_snapshot < hidden_end) {
        ctx.func_hidden_start = entry.func_table_snapshot;
        ctx.func_hidden_end = hidden_end;
    }

    // Declare value-arg variables in a fresh var_table layer so they
    // resolve to canonical var_ids during body re-walk.
    var fresh_var_table: std.StringHashMapUnmanaged(u32) = .{};
    var it = saved_var_table.iterator();
    while (it.next()) |kv| {
        try fresh_var_table.put(alloc, kv.key_ptr.*, kv.value_ptr.*);
    }
    for (params) |param| {
        if (param.is_filter) continue;
        try fresh_var_table.put(alloc, param.name, param.var_id);
    }
    ctx.var_table = fresh_var_table;

    // Push expanding stack so any self-ref inside body emits call_user.
    // Gate: only push when the function is *known* recursive (detected
    // pre-walk by `bodyReferencesSelf`). For non-recursive defs, leaving
    // the stack untouched lets `lookupFunction` resolve `f` inside the
    // body to whatever the lex scope has at that point — matching jq's
    // shadowing rule where a same-named def declared between siblings
    // takes precedence.
    const did_push_expanding = ctx.function_table.items[fn_id].is_recursive;
    if (did_push_expanding) try ctx.expanding_stack.append(alloc, fn_id);

    const func_table_save: u32 = @intCast(ctx.function_table.items.len);

    const body_idx = try lowerNode(ctx, entry.body);

    // Record the lowered body IR root for recursive functions on the
    // FIRST inline expansion (mutual / self recursion detected during
    // body re-walk via `expanding_stack` flips `is_recursive`).
    if (ctx.function_table.items[fn_id].is_recursive and
        ctx.function_table.items[fn_id].body_ir_root == BODY_IR_NOT_LOWERED)
    {
        ctx.function_table.items[fn_id].body_ir_root = body_idx;
    }

    // Cleanup state. Mark inner-def entries as out_of_scope rather
    // than popping — IR `call_user` nodes synthesized inside this
    // body re-walk reference these fn_ids and emit resolves them
    // later via `function_table[fn_id]`. Truncating would invalidate
    // those indices. `lookupFunction` skips oos entries so subsequent
    // lex lookups behave as if popped.
    {
        var k: u32 = func_table_save;
        const cur_len: u32 = @intCast(ctx.function_table.items.len);
        while (k < cur_len) : (k += 1) {
            ctx.function_table.items[k].out_of_scope = true;
        }
    }
    if (did_push_expanding) _ = ctx.expanding_stack.pop();
    ctx.var_table.deinit(alloc);
    ctx.var_table = saved_var_table;
    ctx.func_hidden_start = saved_hidden_start;
    ctx.func_hidden_end = saved_hidden_end;
    ctx.filter_arg_bindings.items.len = saved_bindings_len;

    // Phase 3 — synthesize a single call_user IR node with the body
    // appended to the value-args span. Emit reads the IS_INLINE flag
    // and renders the legacy `<arg>; capture_variable; ...; <body>;
    // pop_variable; ...` ladder without intervening pipes — current
    // is preserved for the body to consume the OUTER input.
    return synthCallUserInline(ctx, fn_id, value_arg_idxs.items, body_idx, src_start, src_len);
}

/// Synthesize a non-recursive `call_user` IR node: span carries
/// `[value_args..., body_idx]`, extra_data flags `is_inline=true`
/// so emit uses the inline-expansion ladder rather than
/// `call_function(body_ip)`. See `synthCallUser` for the recursive
/// variant.
fn synthCallUserInline(
    ctx: *Lowerer,
    fn_id: u32,
    value_arg_idxs: []const u32,
    body_idx: u32,
    src_start: u32,
    src_len: u32,
) error{OutOfMemory}!u32 {
    const alloc = ctx.arena.allocator();
    const entry = ctx.function_table.items[fn_id];

    const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
    try ctx.out.extra_children.appendSlice(alloc, value_arg_idxs);
    try ctx.out.extra_children.append(alloc, body_idx);
    const span_len: u32 = @intCast(value_arg_idxs.len + 1);

    const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
    try ctx.out.extra_data.append(alloc, fn_id);
    const name_offset: u32 = @intCast(ctx.out.string_buf.items.len);
    try ctx.out.string_buf.appendSlice(alloc, entry.name);
    try ctx.out.extra_data.append(alloc, name_offset);
    try ctx.out.extra_data.append(alloc, @intCast(entry.name.len));
    try ctx.out.extra_data.append(alloc, CALL_USER_INLINE);

    return ctx.pushNode(.{
        .op = .call_user,
        .span_start = span_start,
        .span_len = span_len,
        .extra = extra_idx,
        .src_start = src_start,
        .src_len = src_len,
    });
}

/// Inline/recursive-call discriminant stored in the 4th slot of a
/// `call_user` IR node's extra-data payload. Plan-§1.3-row-5 keeps
/// the full enum namespace in `ir.zig`; we use plain u32 constants
/// here because the discriminant has only two values and the SSOT
/// stays trivially auditable.
const CALL_USER_INLINE: u32 = 1;
const CALL_USER_RECURSIVE: u32 = 0;

/// Lower a self-recursive function call to `call_user(fn_id, value_args)`.
/// Value args are lowered here (the call site's scope sees them) and
/// recorded in the IR span; filter args are referenced inside the
/// already-lowered recursive body via the `filter_arg_bindings` stack
/// — when the body calls itself, the body's references to the
/// recursive function's filter params still resolve through the
/// bindings active at the inline-expansion call site (legacy's
/// equivalent: filter-arg references in the body persist as
/// `call_filter_arg` ops, which the recursive body's emit sees only
/// at the top expansion's binding context).
fn synthRecursiveCall(
    ctx: *Lowerer,
    fn_id: u32,
    args: []const *Node,
    src_start: u32,
    src_len: u32,
) LowerError!u32 {
    const alloc = ctx.arena.allocator();
    const entry = ctx.function_table.items[fn_id];
    std.debug.assert(entry.params.len == args.len);

    // Lower value args at the call site. Filter args don't lower into
    // IR here — they're substituted textually when the body's
    // bare-ident refs match a binding name at body-walk time. Since
    // the body of a recursive function is lowered once at the OUTER
    // expansion of that function, filter arg substitution happens
    // there and the recursive body has the substitutions baked in.
    var value_arg_idxs: std.ArrayListUnmanaged(u32) = .{};
    defer value_arg_idxs.deinit(alloc);
    for (entry.params, args) |param, arg_ast| {
        if (param.is_filter) continue;
        const arg_idx = try lowerNode(ctx, arg_ast);
        try value_arg_idxs.append(alloc, arg_idx);
    }

    return synthCallUser(ctx, fn_id, value_arg_idxs.items, src_start, src_len);
}

/// Synthesize a `call_user(fn_id, span=value_args)` IR node. The
/// variable-arity span carries the lowered value-arg IR-node indices
/// in source order; the `extra_data` payload encodes:
///
///   extra_data[extra + 0]   = fn_id (entry index — emit consults the
///                              function-table slice passed in to read
///                              body_ir_root + canonical var_ids)
///   extra_data[extra + 1]   = name_offset (into IR string_buf)
///   extra_data[extra + 2]   = name_len
///
/// Body lookup happens at emit time against the Lowerer's
/// `function_table` snapshot, which is passed through to emit. This
/// keeps the IR free of pointer-back-references and lets emit cache
/// per-fn body_ip across multiple call_user sites.
fn synthCallUser(
    ctx: *Lowerer,
    fn_id: u32,
    value_arg_idxs: []const u32,
    src_start: u32,
    src_len: u32,
) error{OutOfMemory}!u32 {
    const alloc = ctx.arena.allocator();
    // Encountering a `call_user` at lower time means the target
    // function IS recursive (directly via self-call detection on
    // `expanding_stack`, or indirectly via mutual recursion). Mark
    // it so emit asserts pass and the body-emission ladder fires.
    // The `is_recursive` AST scan in `lowerFuncDef` is a cheap
    // fast-path; this site is the canonical detector.
    ctx.function_table.items[fn_id].is_recursive = true;
    const entry = ctx.function_table.items[fn_id];

    const span_start: u32 = @intCast(ctx.out.extra_children.items.len);
    try ctx.out.extra_children.appendSlice(alloc, value_arg_idxs);
    const span_len: u32 = @intCast(value_arg_idxs.len);

    const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
    try ctx.out.extra_data.append(alloc, fn_id);
    const name_offset: u32 = @intCast(ctx.out.string_buf.items.len);
    try ctx.out.string_buf.appendSlice(alloc, entry.name);
    try ctx.out.extra_data.append(alloc, name_offset);
    try ctx.out.extra_data.append(alloc, @intCast(entry.name.len));
    try ctx.out.extra_data.append(alloc, CALL_USER_RECURSIVE);

    return ctx.pushNode(.{
        .op = .call_user,
        .span_start = span_start,
        .span_len = span_len,
        .extra = extra_idx,
        .src_start = src_start,
        .src_len = src_len,
    });
}

/// Synthesize a `destructure(as, name, var_id)` IR node — the same
/// shape lowering produces for `expr as $name | ...`. Used to wire
/// value-arg captures during inline expansion of user-function calls
/// (cat-9). Mirrors the simple-as branch of `lowerPattern`.
fn synthDestructureAs(
    ctx: *Lowerer,
    name: []const u8,
    var_id: u32,
    src_start: u32,
    src_len: u32,
) error{OutOfMemory}!u32 {
    const alloc = ctx.arena.allocator();
    const extra_idx: u32 = @intCast(ctx.out.extra_data.items.len);
    try ctx.out.extra_data.append(alloc, @intFromEnum(ir.PatternKind.as));
    const offset: u32 = @intCast(ctx.out.string_buf.items.len);
    try ctx.out.string_buf.appendSlice(alloc, name);
    try ctx.out.extra_data.append(alloc, offset);
    try ctx.out.extra_data.append(alloc, @intCast(name.len));
    try ctx.out.extra_data.append(alloc, var_id);
    return ctx.pushNode(.{
        .op = .destructure,
        .extra = extra_idx,
        .src_start = src_start,
        .src_len = src_len,
    });
}

/// Look up an active filter-arg binding by name. Searches backward so
/// the innermost binding wins (lex-scope). Returns the binding index
/// in `filter_arg_bindings` so callers can read both the AST and the
/// `bindings_floor_at_capture` for re-substitution.
fn lookupFilterArgBinding(ctx: *const Lowerer, name: []const u8) ?u32 {
    var i: u32 = @intCast(ctx.filter_arg_bindings.items.len);
    while (i > 0) {
        i -= 1;
        const binding = ctx.filter_arg_bindings.items[i];
        if (std.mem.eql(u8, binding.name, name)) return i;
    }
    return null;
}

/// Re-lower the AST sub-tree captured for filter-arg `binding_idx`.
/// The bindings stack is temporarily truncated to the binding's
/// `bindings_floor_at_capture` so the substituted sub-tree sees only
/// the bindings active at its capture site — preventing infinite
/// recursion on `def id(x): x; id(id(.))`. Mirrors legacy
/// `compiler.zig:6086-6101`.
fn reLowerFilterArg(ctx: *Lowerer, binding_idx: u32) LowerError!u32 {
    const binding = ctx.filter_arg_bindings.items[binding_idx];
    const saved_len: u32 = @intCast(ctx.filter_arg_bindings.items.len);
    ctx.filter_arg_bindings.items.len = binding.bindings_floor_at_capture;
    // Swap to the var_table snapshot taken at the binding's capture
    // site — `$x` (and bare-ident shadows of `$x`) references inside
    // the captured AST must resolve against the caller's scope, not
    // the callee's. Restore the callee's table after the re-walk.
    const saved_var_table = ctx.var_table;
    ctx.var_table = binding.var_table_at_capture;
    const result = try lowerNode(ctx, binding.arg_ast);
    ctx.var_table = saved_var_table;
    ctx.filter_arg_bindings.items.len = saved_len;
    return result;
}

/// Look up a function by name + arity that is currently being
/// inline-expanded — i.e., on the `expanding_stack`. Bypasses the
/// hidden range so a function which lex-hides itself during inner-def
/// expansion can still self-call. Returns null if no such expanding
/// function matches; the caller falls back to the regular
/// `lookupFunction` (which respects hiding).
fn lookupRecursiveSelf(ctx: *const Lowerer, name: []const u8, arity: u32) ?u32 {
    var i: usize = ctx.expanding_stack.items.len;
    const tlen: u32 = @intCast(ctx.function_table.items.len);
    while (i > 0) {
        i -= 1;
        const fn_id = ctx.expanding_stack.items[i];
        if (fn_id >= tlen) continue;
        const entry = ctx.function_table.items[fn_id];
        if (entry.params.len == arity and std.mem.eql(u8, entry.name, name)) {
            // Shadow guard: an inner def with the same (name, arity)
            // registered AFTER this expanding entry shadows it lex-
            // ically. Without this check, a recursive outer def whose
            // body contains `def <same-name>: …;` would incorrectly
            // self-call from inside the inner body. Skip oos so a
            // sibling inner-def already torn down doesn't shadow.
            var j: u32 = fn_id + 1;
            var shadowed = false;
            while (j < tlen) : (j += 1) {
                const e2 = ctx.function_table.items[j];
                if (e2.out_of_scope) continue;
                // Mirror lookupFunction:350-352: defs inside the active
                // hidden range are not lex-visible at this lookup, so
                // they cannot shadow.
                if (ctx.func_hidden_start) |hs|
                    if (ctx.func_hidden_end) |he|
                        if (j >= hs and j < he) continue;
                if (e2.params.len == arity and std.mem.eql(u8, e2.name, name)) {
                    shadowed = true;
                    break;
                }
            }
            if (!shadowed) return fn_id;
        }
    }
    return null;
}

/// Walk an AST sub-tree looking for a self-reference matching
/// `(name, arity)`. Inner `def` bodies are skipped — their refs are
/// scoped to themselves. Used by `lowerFuncDef` to set
/// `is_recursive` eagerly so emit can pre-allocate a body_ip slot
/// for the recursive function's body (mirrors the post-pass scan in
/// legacy `compiler.zig:6628`).
fn bodyReferencesSelf(node: *const Node, name: []const u8, arity: u32) bool {
    switch (node.kind) {
        .func_call => |fc| {
            if (std.mem.eql(u8, fc.name, name) and fc.args.len == arity) return true;
            for (fc.args) |a| if (bodyReferencesSelf(a, name, arity)) return true;
            return false;
        },
        .field_access => |fa| {
            if (arity == 0 and std.mem.eql(u8, fa.name, name)) return true;
            return false;
        },
        // Inner defs introduce a new scope — their bodies' refs to
        // the SAME name address themselves (or the parent if the inner
        // def shadows it the outer def — but legacy doesn't detect
        // that here either). We descend only into `rest`, not body.
        .func_def => |fd| return bodyReferencesSelf(fd.rest, name, arity),
        .pipe => |bp| return bodyReferencesSelf(bp.left, name, arity) or bodyReferencesSelf(bp.right, name, arity),
        .comma => |bc| return bodyReferencesSelf(bc.left, name, arity) or bodyReferencesSelf(bc.right, name, arity),
        .arithmetic => |bn| return bodyReferencesSelf(bn.left, name, arity) or bodyReferencesSelf(bn.right, name, arity),
        .comparison => |bn| return bodyReferencesSelf(bn.left, name, arity) or bodyReferencesSelf(bn.right, name, arity),
        .and_expr => |bn| return bodyReferencesSelf(bn.left, name, arity) or bodyReferencesSelf(bn.right, name, arity),
        .or_expr => |bn| return bodyReferencesSelf(bn.left, name, arity) or bodyReferencesSelf(bn.right, name, arity),
        .alternative => |bn| return bodyReferencesSelf(bn.left, name, arity) or bodyReferencesSelf(bn.right, name, arity),
        .unary_neg => |un| return bodyReferencesSelf(un.operand, name, arity),
        .optional => |un| return bodyReferencesSelf(un.operand, name, arity),
        .paren => |un| return bodyReferencesSelf(un.operand, name, arity),
        .if_expr => |ifx| {
            if (bodyReferencesSelf(ifx.cond, name, arity)) return true;
            if (bodyReferencesSelf(ifx.then_body, name, arity)) return true;
            for (ifx.elif_chains) |elif| {
                if (bodyReferencesSelf(elif.cond, name, arity)) return true;
                if (bodyReferencesSelf(elif.body, name, arity)) return true;
            }
            if (ifx.else_body) |eb| if (bodyReferencesSelf(eb, name, arity)) return true;
            return false;
        },
        .try_catch => |tc| {
            if (bodyReferencesSelf(tc.body, name, arity)) return true;
            if (tc.catch_body) |cb| if (bodyReferencesSelf(cb, name, arity)) return true;
            return false;
        },
        .as_pattern => |ap| return bodyReferencesSelf(ap.expr, name, arity) or bodyReferencesSelf(ap.body, name, arity),
        .destruct_alt => |da| return bodyReferencesSelf(da.expr, name, arity) or bodyReferencesSelf(da.body, name, arity),
        .reduce => |rd| return bodyReferencesSelf(rd.expr, name, arity) or bodyReferencesSelf(rd.init, name, arity) or bodyReferencesSelf(rd.update, name, arity),
        .foreach => |fe| {
            if (bodyReferencesSelf(fe.expr, name, arity)) return true;
            if (bodyReferencesSelf(fe.init, name, arity)) return true;
            if (bodyReferencesSelf(fe.update, name, arity)) return true;
            if (fe.extract) |e| if (bodyReferencesSelf(e, name, arity)) return true;
            return false;
        },
        .builtin_call => |bc| {
            for (bc.args) |a| if (bodyReferencesSelf(a, name, arity)) return true;
            return false;
        },
        .object_construct => |oc| {
            for (oc.fields) |fld| {
                switch (fld.key) {
                    .ident, .string => {},
                    .expr => |e| if (bodyReferencesSelf(e, name, arity)) return true,
                }
                if (bodyReferencesSelf(fld.value, name, arity)) return true;
            }
            return false;
        },
        .array_construct => |ac| {
            if (ac.expr) |e| if (bodyReferencesSelf(e, name, arity)) return true;
            return false;
        },
        .string_interp => |si| {
            for (si.parts) |part| {
                switch (part) {
                    .literal => {},
                    .expr => |e| if (bodyReferencesSelf(e, name, arity)) return true,
                }
            }
            return false;
        },
        .format_string => |fs| {
            for (fs.parts) |part| {
                switch (part) {
                    .literal => {},
                    .expr => |e| if (bodyReferencesSelf(e, name, arity)) return true,
                }
            }
            return false;
        },
        .suffix => |sf| {
            return bodyReferencesSelf(sf.base, name, arity);
        },
        .update_assign => |ua| return bodyReferencesSelf(ua.rhs, name, arity),
        .assign_general => |ag| return bodyReferencesSelf(ag.lhs, name, arity) or bodyReferencesSelf(ag.rhs, name, arity),
        else => return false,
    }
}
