const std = @import("std");
const ZqError = @import("error").ZqError;
const types = @import("types");
const Instruction = types.Instruction;
const lx = @import("lexer");
const Lexer = lx.Lexer;
const Token = lx.Token;

// ── Public output type ────────────────────────────────────────────────────────

/// Declaration of an external variable to be pre-declared in the root scope.
pub const ExternalVarDecl = struct {
    name: []const u8,
};

/// Caller owns both slices; free via deinit().
pub const Compiled = struct {
    instructions: []Instruction,
    function_table: []const types.FunctionDef,
    string_buf: []u8,
    external_var_ids: []u32,
    source_map: []u32,

    pub fn deinit(c: *Compiled, alloc: std.mem.Allocator) void {
        alloc.free(c.instructions);
        alloc.free(c.string_buf);
        alloc.free(c.source_map);
        if (c.external_var_ids.len > 0) alloc.free(c.external_var_ids);
        // function_table is part of string_buf, no need to free separately
    }
};

// ── Compiler-internal types ───────────────────────────────────────────────────

/// Byte range within the intern buffer. Used during compilation before the
/// buffer is finalized; converted to []const u8 slices in the final pass.
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

const Ctx = struct {
    src: []const u8,
    lex: Lexer,
    raw: std.ArrayList(RawInstr),
    intern: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    // Variable scope management
    current_scope: *VariableScope,

    // Function definitions
    function_table: std.ArrayList(FunctionEntry),
    next_var_id: u32 = 0,
    next_func_id: u32 = 0,

    // Active filter arg bindings for function body re-parsing
    filter_arg_bindings: std.ArrayList(FilterArgBinding) = std.ArrayList(FilterArgBinding){},

    // When true, function calls are parsed for syntax but not expanded.
    // Used during the initial body parse in parseFunctionDef where we only
    // need to advance the lexer and detect recursion patterns.
    scanning_body: bool = false,

    // Index into function_table of the recursive function currently being expanded.
    // null means we're not inside a recursive expansion. When set, self-references
    // emit call_function instead of trying to expand (which would infinite-loop).
    expanding_recursive_func: ?usize = null,

    // Lexical scoping: defines a "hidden range" in the function table.
    // Functions with index in [func_hidden_start, func_hidden_end) are skipped
    // during lookup. This implements jq's lexical scoping: when re-parsing a
    // function body, definitions made AFTER the function was defined (but before
    // the current re-parse started inner defs) are hidden.
    func_hidden_start: ?usize = null,
    func_hidden_end: ?usize = null,

    // Temporary pattern allocations (freed after compilation)
    pattern_allocs: std.ArrayList([]const Pattern) = std.ArrayList([]const Pattern){},
    pattern_obj_allocs: std.ArrayList([]const ObjectPatternField) = std.ArrayList([]const ObjectPatternField){},
    pattern_raw_allocs: std.ArrayList([]const RawInstr) = std.ArrayList([]const RawInstr){},

    // Label variable IDs for compile-time break validation
    label_var_ids: std.ArrayList(u32) = std.ArrayList(u32){},

    // Length of the PRELUDE string prepended to user source (for $__loc__ line counting).
    prelude_len: u32 = 0,

    // Source offset tracking for error diagnostics
    last_tok_offset: u32 = 0,
    error_offset: u32 = 0,
    error_len: u32 = 0,

    /// Emit a raw instruction with the current source offset.
    fn emit(ctx: *Ctx, op: Instruction.Op, operand: RawOp) error{OutOfMemory}!void {
        try ctx.raw.append(ctx.alloc, .{
            .op = op,
            .operand = operand,
            .src_offset = ctx.last_tok_offset,
        });
    }

    /// Consume the next token and track its source offset.
    fn nextToken(ctx: *Ctx) (ZqError || error{OutOfMemory})!Token {
        const tok = try ctx.lex.next();
        ctx.last_tok_offset = tok.offset;
        return tok;
    }

    /// Record error location and return QuerySyntaxError.
    fn syntaxErr(ctx: *Ctx, offset: u32, len: u32) ZqError {
        ctx.error_offset = offset;
        ctx.error_len = len;
        return error.QuerySyntaxError;
    }

    /// Allocate and track a Pattern slice (freed after compilation).
    fn dupePatterns(ctx: *Ctx, items: []const Pattern) error{OutOfMemory}![]const Pattern {
        const owned = try ctx.alloc.dupe(Pattern, items);
        try ctx.pattern_allocs.append(ctx.alloc, owned);
        return owned;
    }

    /// Allocate and track an ObjectPatternField slice (freed after compilation).
    fn dupeObjFields(ctx: *Ctx, items: []const ObjectPatternField) error{OutOfMemory}![]const ObjectPatternField {
        const owned = try ctx.alloc.dupe(ObjectPatternField, items);
        try ctx.pattern_obj_allocs.append(ctx.alloc, owned);
        return owned;
    }
};

const VariableEntry = struct {
    name: StrRef,
    id: u32,
};

const VariableScope = struct {
    variables: std.ArrayList(VariableEntry),
    parent: ?*VariableScope,
};

/// Describes one parameter of a user-defined function.
const ParamInfo = struct {
    name: StrRef,
    is_filter: bool, // true = filter arg (code), false = value arg ($var)
    var_id: u32, // Variable ID (only meaningful for value args)
};

const FunctionEntry = struct {
    name: StrRef,
    params: []ParamInfo, // Parameter descriptors
    body_raw: []const RawInstr, // Unused at runtime; kept for potential future use
    is_recursive: bool, // true if body references the function itself
    /// Source range of the function body (for re-parsing during expansion).
    body_src_start: u32,
    body_src_end: u32,
    /// For recursive functions: offset within the main instruction stream
    /// where the body was emitted (set during call-site expansion).
    /// 0 means not yet emitted.
    recursive_body_ip: u32,
    /// For recursive functions: the end IP (past return_function).
    recursive_body_end_ip: u32,
    /// Lexical scope snapshot: the function table length at the time this function
    /// was defined. During body re-parsing, only functions with index < this value
    /// are visible, implementing jq's lexical scoping for function references.
    func_table_snapshot: usize,

    fn paramCount(self: *const FunctionEntry) u8 {
        return @intCast(self.params.len);
    }

    fn deinit(self: *const FunctionEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.params);
        if (self.body_raw.len > 0) alloc.free(self.body_raw);
    }
};

const PathStep = struct {
    kind: enum { key, index },
    key: StrRef = .{ .offset = 0, .len = 0 },
    index: i64 = 0,
};

/// Maps a function parameter index to its runtime variable ID at a call site.
const ValueVarBinding = struct {
    param_idx: usize,
    var_id: u32,
};

/// Represents a function call argument at a call site.
/// For filter args, stores the source text range to re-parse at each expansion.
/// For value args, stores pre-compiled instructions.
const CallArg = struct {
    /// Source byte range for re-parsing (used for filter args).
    src_start: u32,
    src_end: u32,
    /// Pre-compiled instructions (used for value args).
    instructions: []const RawInstr,
    is_filter: bool,
};

/// Active filter argument binding during function body re-parsing.
/// When an identifier matches a filter arg name, the compiler re-parses
/// the arg's source range instead of emitting a field access.
const FilterArgBinding = struct {
    name: StrRef,
    src_start: u32,
    src_end: u32,
};

// ── Destructuring pattern types ──────────────────────────────────────────

/// Represents a destructuring pattern for `as` bindings.
/// Used in `expr as PATTERN | body`, `reduce expr as PATTERN (...)`,
/// and `foreach expr as PATTERN (...)`.
const Pattern = union(enum) {
    /// Simple variable binding: `$var`
    simple: u32, // var_id
    /// Array destructuring: `[$a, $b, ...]`
    array: []const Pattern,
    /// Object destructuring: `{key: $var, ...}`
    object: []const ObjectPatternField,
};

const ObjectPatternField = struct {
    key: PatternKey,
    pattern: Pattern,
};

const PatternKey = union(enum) {
    /// Static key from identifier or string literal
    static: StrRef,
    /// Computed key from expression (only in single-phase `as` path).
    /// Stores the raw instructions that compute the key string.
    computed: []const RawInstr,
};

// ── Scope management ─────────────────────────────────────────────────────

/// Create a new variable scope
fn pushScope(ctx: *Ctx, alloc: std.mem.Allocator) (ZqError || error{OutOfMemory})!void {
    const new_scope = try alloc.create(VariableScope);
    errdefer alloc.destroy(new_scope);
    new_scope.* = VariableScope{
        .variables = std.ArrayList(VariableEntry){},
        .parent = ctx.current_scope,
    };
    ctx.current_scope = new_scope;
}

/// Pop the current variable scope
fn popScope(ctx: *Ctx, alloc: std.mem.Allocator) void {
    const old_scope = ctx.current_scope;
    defer alloc.destroy(old_scope);
    old_scope.variables.deinit(alloc);
    ctx.current_scope = old_scope.parent orelse unreachable;
}

/// Declare a variable in the current scope.
/// If a variable with the same name already exists in the current scope,
/// it is shadowed with a new variable ID (matching jq's `as` semantics
/// where rebinding is allowed).
fn declareVariable(ctx: *Ctx, name_ref: StrRef, alloc: std.mem.Allocator) (ZqError || error{OutOfMemory})!u32 {
    const var_id = ctx.next_var_id;
    ctx.next_var_id += 1;

    // Check for duplicate in current scope — shadow by updating the entry.
    for (ctx.current_scope.variables.items) |*var_entry| {
        const existing_name = ctx.intern.items[var_entry.name.offset..][0..var_entry.name.len];
        const new_name = ctx.intern.items[name_ref.offset..][0..name_ref.len];
        if (std.mem.eql(u8, existing_name, new_name)) {
            var_entry.id = var_id;
            return var_id;
        }
    }

    try ctx.current_scope.variables.append(alloc, VariableEntry{
        .name = name_ref,
        .id = var_id,
    });

    return var_id;
}

/// Declare or reuse a variable in the current scope.
/// If a variable with the same name already exists in the current scope,
/// returns its existing var_id without allocating a new one. This is used
/// by `?//` (destructuring alternative) where the same variable name may
/// appear in multiple alternative patterns and must share a single slot.
fn reuseOrDeclareVariable(ctx: *Ctx, name_ref: StrRef, alloc: std.mem.Allocator) (ZqError || error{OutOfMemory})!u32 {
    // Check if the variable already exists in the current scope — reuse it.
    for (ctx.current_scope.variables.items) |var_entry| {
        const existing_name = ctx.intern.items[var_entry.name.offset..][0..var_entry.name.len];
        const new_name = ctx.intern.items[name_ref.offset..][0..name_ref.len];
        if (std.mem.eql(u8, existing_name, new_name)) {
            return var_entry.id;
        }
    }
    // Not found — allocate a new variable.
    return declareVariable(ctx, name_ref, alloc);
}

/// Lookup a variable in the scope chain
fn lookupVariable(ctx: *Ctx, name_ref: StrRef) ?u32 {
    var opt_scope: ?*VariableScope = ctx.current_scope;
    while (opt_scope) |scope| {
        for (scope.variables.items) |var_entry| {
            const existing_name = ctx.intern.items[var_entry.name.offset..][0..var_entry.name.len];
            const lookup_name = ctx.intern.items[name_ref.offset..][0..name_ref.len];
            if (std.mem.eql(u8, existing_name, lookup_name)) {
                return var_entry.id;
            }
        }
        opt_scope = scope.parent;
    }
    return null;
}

// ── Destructuring pattern parsing and emission ──────────────────────────

/// Scan a destructuring pattern from the token stream, declaring all variables.
/// This is the "scan phase" used by reduce/foreach where variables must be
/// declared before the body is parsed. Does NOT support computed keys.
fn scanAndDeclarePattern(ctx: *Ctx) (ZqError || error{OutOfMemory})!Pattern {
    const peek = try ctx.lex.peek();

    switch (peek.tag) {
        .dollar => {
            _ = try ctx.nextToken(); // consume $
            const ident = try ctx.nextToken();
            if (!isVarNameToken(ident.tag)) return ctx.syntaxErr(ident.offset, ident.len);
            const name_ref = try internStr(&ctx.intern, ctx.alloc, ident.slice(ctx.src));
            const var_id = try declareVariable(ctx, name_ref, ctx.alloc);
            return Pattern{ .simple = var_id };
        },
        .lbracket => {
            _ = try ctx.nextToken(); // consume [
            var elements = std.ArrayList(Pattern){};
            defer elements.deinit(ctx.alloc);

            while (true) {
                const next = try ctx.lex.peek();
                if (next.tag == .rbracket) break;
                const elem = try scanAndDeclarePattern(ctx);
                try elements.append(ctx.alloc, elem);
                const after = try ctx.lex.peek();
                if (after.tag == .comma) {
                    _ = try ctx.nextToken();
                }
            }
            _ = try ctx.nextToken(); // consume ]

            if (elements.items.len == 0) {
                return ctx.syntaxErr(peek.offset, peek.len);
            }

            const owned = try ctx.dupePatterns(elements.items);
            return Pattern{ .array = owned };
        },
        .lbrace => {
            _ = try ctx.nextToken(); // consume {
            var fields = std.ArrayList(ObjectPatternField){};
            defer fields.deinit(ctx.alloc);

            while (true) {
                const next = try ctx.lex.peek();
                if (next.tag == .rbrace) break;
                const field = try scanObjectPatternField(ctx);
                try fields.append(ctx.alloc, field);
                const after = try ctx.lex.peek();
                if (after.tag == .comma) {
                    _ = try ctx.nextToken();
                }
            }
            _ = try ctx.nextToken(); // consume }

            if (fields.items.len == 0) {
                return ctx.syntaxErr(peek.offset, peek.len);
            }

            const owned = try ctx.dupeObjFields(fields.items);
            return Pattern{ .object = owned };
        },
        else => {
            return ctx.syntaxErr(peek.offset, peek.len);
        },
    }
}

/// Like scanAndDeclarePattern but reuses existing variables in the current scope
/// instead of shadowing them. Used by `?//` (destructuring alternative) for the
/// second and subsequent patterns, so that shared variable names map to the same
/// var_id across all alternatives.
fn scanAndDeclarePatternReuse(ctx: *Ctx) (ZqError || error{OutOfMemory})!Pattern {
    const peek = try ctx.lex.peek();

    switch (peek.tag) {
        .dollar => {
            _ = try ctx.nextToken(); // consume $
            const ident = try ctx.nextToken();
            if (!isVarNameToken(ident.tag)) return ctx.syntaxErr(ident.offset, ident.len);
            const name_ref = try internStr(&ctx.intern, ctx.alloc, ident.slice(ctx.src));
            const var_id = try reuseOrDeclareVariable(ctx, name_ref, ctx.alloc);
            return Pattern{ .simple = var_id };
        },
        .lbracket => {
            _ = try ctx.nextToken(); // consume [
            var elements = std.ArrayList(Pattern){};
            defer elements.deinit(ctx.alloc);

            while (true) {
                const next = try ctx.lex.peek();
                if (next.tag == .rbracket) break;
                const elem = try scanAndDeclarePatternReuse(ctx);
                try elements.append(ctx.alloc, elem);
                const after = try ctx.lex.peek();
                if (after.tag == .comma) {
                    _ = try ctx.nextToken();
                }
            }
            _ = try ctx.nextToken(); // consume ]

            if (elements.items.len == 0) {
                return ctx.syntaxErr(peek.offset, peek.len);
            }

            const owned = try ctx.dupePatterns(elements.items);
            return Pattern{ .array = owned };
        },
        .lbrace => {
            _ = try ctx.nextToken(); // consume {
            var fields = std.ArrayList(ObjectPatternField){};
            defer fields.deinit(ctx.alloc);

            while (true) {
                const next = try ctx.lex.peek();
                if (next.tag == .rbrace) break;
                const field = try scanObjectPatternFieldReuse(ctx);
                try fields.append(ctx.alloc, field);
                const after = try ctx.lex.peek();
                if (after.tag == .comma) {
                    _ = try ctx.nextToken();
                }
            }
            _ = try ctx.nextToken(); // consume }

            if (fields.items.len == 0) {
                return ctx.syntaxErr(peek.offset, peek.len);
            }

            const owned = try ctx.dupeObjFields(fields.items);
            return Pattern{ .object = owned };
        },
        else => {
            return ctx.syntaxErr(peek.offset, peek.len);
        },
    }
}

/// Like scanObjectPatternField but uses reuseOrDeclareVariable.
fn scanObjectPatternFieldReuse(ctx: *Ctx) (ZqError || error{OutOfMemory})!ObjectPatternField {
    const peek = try ctx.lex.peek();

    if (peek.tag == .dollar) {
        _ = try ctx.nextToken();
        const ident = try ctx.nextToken();
        if (!isVarNameToken(ident.tag)) return ctx.syntaxErr(ident.offset, ident.len);
        const name_ref = try internStr(&ctx.intern, ctx.alloc, ident.slice(ctx.src));
        const var_id = try reuseOrDeclareVariable(ctx, name_ref, ctx.alloc);
        return ObjectPatternField{
            .key = .{ .static = name_ref },
            .pattern = Pattern{ .simple = var_id },
        };
    }

    if (peek.tag == .lparen) {
        return ctx.syntaxErr(peek.offset, peek.len);
    }

    const key_ref = try parseStaticPatternKey(ctx);
    const colon = try ctx.nextToken();
    if (colon.tag != .colon) return ctx.syntaxErr(colon.offset, colon.len);
    const sub_pattern = try scanAndDeclarePatternReuse(ctx);

    return ObjectPatternField{
        .key = .{ .static = key_ref },
        .pattern = sub_pattern,
    };
}

/// Parse a single object pattern field (used by scanAndDeclarePattern).
/// Handles: `key: PATTERN`, `"key": PATTERN`, `$var` (shorthand).
/// Does NOT handle computed keys `(expr): PATTERN`.
fn scanObjectPatternField(ctx: *Ctx) (ZqError || error{OutOfMemory})!ObjectPatternField {
    const peek = try ctx.lex.peek();

    if (peek.tag == .dollar) {
        _ = try ctx.nextToken();
        const ident = try ctx.nextToken();
        if (!isVarNameToken(ident.tag)) return ctx.syntaxErr(ident.offset, ident.len);
        const name_ref = try internStr(&ctx.intern, ctx.alloc, ident.slice(ctx.src));
        const var_id = try declareVariable(ctx, name_ref, ctx.alloc);
        return ObjectPatternField{
            .key = .{ .static = name_ref },
            .pattern = Pattern{ .simple = var_id },
        };
    }

    if (peek.tag == .lparen) {
        return ctx.syntaxErr(peek.offset, peek.len);
    }

    const key_ref = try parseStaticPatternKey(ctx);
    const colon = try ctx.nextToken();
    if (colon.tag != .colon) return ctx.syntaxErr(colon.offset, colon.len);
    const sub_pattern = try scanAndDeclarePattern(ctx);

    return ObjectPatternField{
        .key = .{ .static = key_ref },
        .pattern = sub_pattern,
    };
}

/// Parse a static key name (identifier, keyword, or string literal) and return its interned ref.
fn parseStaticPatternKey(ctx: *Ctx) (ZqError || error{OutOfMemory})!StrRef {
    const tok = try ctx.nextToken();
    if (tok.tag == .string_lit) {
        const raw = tok.slice(ctx.src);
        const content = raw[1 .. raw.len - 1];
        return internDecodedStr(&ctx.intern, ctx.alloc, content);
    }
    if (tok.tag == .ident or tok.tag == .and_kw or tok.tag == .or_kw or
        tok.tag == .not_kw or tok.tag == .true_kw or tok.tag == .false_kw or
        tok.tag == .def_kw or tok.tag == .as_kw or tok.tag == .reduce_kw or
        tok.tag == .if_kw or tok.tag == .then_kw or tok.tag == .elif_kw or
        tok.tag == .else_kw or tok.tag == .end_kw or
        tok.tag == .try_kw or tok.tag == .catch_kw or
        tok.tag == .label_kw or tok.tag == .break_kw)
    {
        return internStr(&ctx.intern, ctx.alloc, tok.slice(ctx.src));
    }
    return ctx.syntaxErr(tok.offset, tok.len);
}

/// Emit bytecode to destructure the current value into pattern variables.
/// The value to destructure should be on the value_stack (just pushed by
/// load_key/load_index/etc, or push_current for iterate elements).
///
/// For a simple pattern, emits capture_variable.
/// For array/object patterns, emits save/restore_input pairs with indexed/keyed
/// extraction wrapped in try/catch for null-on-missing semantics.
fn emitPatternCapture(ctx: *Ctx, pattern: Pattern) (ZqError || error{OutOfMemory})!void {
    switch (pattern) {
        .simple => |var_id| {
            try ctx.emit(.capture_variable, .{ .index = var_id });
        },
        .array => |elements| {
            // The value to destructure is on value_stack. Pop it to current via pipe.
            try ctx.emit(.pipe, .{ .none = {} });

            for (elements, 0..) |elem, idx| {
                try ctx.emit(.save_input, .{ .none = {} });

                // Wrap extraction in fork_try/pop_try for null-on-missing
                const fork_pos = ctx.raw.items.len;
                try ctx.emit(.fork_try, .{ .index = 0 });

                try ctx.emit(.load_index, .{ .index = @intCast(idx) });

                try ctx.emit(.pop_try, .{ .none = {} });

                // Jump past catch handler
                const jump_pos = ctx.raw.items.len;
                try ctx.emit(.jump, .{ .index = 0 });

                // Catch handler: push null to value_stack
                const catch_ip: u32 = @intCast(ctx.raw.items.len);
                ctx.raw.items[fork_pos].operand = .{ .index = catch_ip };
                try ctx.emit(.push_null, .{ .none = {} });

                // Continue label
                const continue_ip: u32 = @intCast(ctx.raw.items.len);
                ctx.raw.items[jump_pos].operand = .{ .index = continue_ip };

                // Recursively capture sub-pattern
                try emitPatternCapture(ctx, elem);

                try ctx.emit(.restore_input, .{ .none = {} });
            }
        },
        .object => |fields| {
            // The value to destructure is on value_stack. Pop it to current via pipe.
            try ctx.emit(.pipe, .{ .none = {} });

            for (fields) |field| {
                try ctx.emit(.save_input, .{ .none = {} });

                switch (field.key) {
                    .static => |key_ref| {
                        const fork_pos = ctx.raw.items.len;
                        try ctx.emit(.fork_try, .{ .index = 0 });

                        try ctx.emit(.load_key, .{ .str_ref = key_ref });

                        try ctx.emit(.pop_try, .{ .none = {} });

                        const jump_pos = ctx.raw.items.len;
                        try ctx.emit(.jump, .{ .index = 0 });

                        const catch_ip: u32 = @intCast(ctx.raw.items.len);
                        ctx.raw.items[fork_pos].operand = .{ .index = catch_ip };
                        try ctx.emit(.push_null, .{ .none = {} });

                        const continue_ip: u32 = @intCast(ctx.raw.items.len);
                        ctx.raw.items[jump_pos].operand = .{ .index = continue_ip };
                    },
                    .computed => |instrs| {
                        const fork_pos = ctx.raw.items.len;
                        try ctx.emit(.fork_try, .{ .index = 0 });

                        // save_input for load_computed (pops base from if_stack)
                        try ctx.emit(.save_input, .{ .none = {} });

                        // Copy the saved key expression instructions
                        for (instrs) |instr_item| {
                            try ctx.raw.append(ctx.alloc, instr_item);
                        }

                        try ctx.emit(.load_computed, .{ .none = {} });
                        // load_computed sets current, push it to value_stack
                        try ctx.emit(.push_current, .{ .none = {} });

                        try ctx.emit(.pop_try, .{ .none = {} });

                        const jump_pos = ctx.raw.items.len;
                        try ctx.emit(.jump, .{ .index = 0 });

                        const catch_ip: u32 = @intCast(ctx.raw.items.len);
                        ctx.raw.items[fork_pos].operand = .{ .index = catch_ip };
                        try ctx.emit(.push_null, .{ .none = {} });

                        const continue_ip: u32 = @intCast(ctx.raw.items.len);
                        ctx.raw.items[jump_pos].operand = .{ .index = continue_ip };
                    },
                }

                try emitPatternCapture(ctx, field.pattern);

                try ctx.emit(.restore_input, .{ .none = {} });
            }
        },
    }
}

/// Emit bytecode to destructure the current value into pattern variables,
/// WITHOUT wrapping index/key lookups in try/catch. If the value's type does
/// not match the pattern structure (e.g., indexing an array on a string),
/// the load_key/load_index will produce a TypeError that propagates to the
/// caller's try_begin/try_end. Used by `?//` (destructuring alternative).
fn emitPatternCaptureStrict(ctx: *Ctx, pattern: Pattern) (ZqError || error{OutOfMemory})!void {
    switch (pattern) {
        .simple => |var_id| {
            try ctx.emit(.capture_variable, .{ .index = var_id });
        },
        .array => |elements| {
            try ctx.emit(.pipe, .{ .none = {} });

            for (elements, 0..) |elem, idx| {
                try ctx.emit(.save_input, .{ .none = {} });

                // No try/catch — let TypeError propagate to outer handler
                try ctx.emit(.load_index, .{ .index = @intCast(idx) });

                try emitPatternCaptureStrict(ctx, elem);

                try ctx.emit(.restore_input, .{ .none = {} });
            }
        },
        .object => |fields| {
            try ctx.emit(.pipe, .{ .none = {} });

            for (fields) |field| {
                try ctx.emit(.save_input, .{ .none = {} });

                switch (field.key) {
                    .static => |key_ref| {
                        // No try/catch — let TypeError propagate to outer handler
                        try ctx.emit(.load_key, .{ .str_ref = key_ref });
                    },
                    .computed => |instrs| {
                        // No try/catch — let TypeError propagate to outer handler
                        try ctx.emit(.save_input, .{ .none = {} });
                        for (instrs) |instr| {
                            try ctx.raw.append(ctx.alloc, instr);
                        }
                        try ctx.emit(.load_computed, .{ .none = {} });
                        try ctx.emit(.push_current, .{ .none = {} });
                    },
                }

                try emitPatternCaptureStrict(ctx, field.pattern);

                try ctx.emit(.restore_input, .{ .none = {} });
            }
        },
    }
}

/// Parse a destructuring pattern AND emit the capture bytecode in one pass.
/// Used by `parseLogical` for `expr as PATTERN | body` where body comes after
/// the pattern. Supports computed keys `(expr): $var`.
fn parseAndEmitPattern(ctx: *Ctx) (ZqError || error{OutOfMemory})!Pattern {
    const peek = try ctx.lex.peek();

    switch (peek.tag) {
        .dollar => {
            _ = try ctx.nextToken();
            const ident = try ctx.nextToken();
            if (!isVarNameToken(ident.tag)) return ctx.syntaxErr(ident.offset, ident.len);
            const name_ref = try internStr(&ctx.intern, ctx.alloc, ident.slice(ctx.src));
            const var_id = try declareVariable(ctx, name_ref, ctx.alloc);
            try ctx.emit(.capture_variable, .{ .index = var_id });
            return Pattern{ .simple = var_id };
        },
        .lbracket => {
            _ = try ctx.nextToken(); // consume [
            var elements = std.ArrayList(Pattern){};
            defer elements.deinit(ctx.alloc);

            while (true) {
                const next = try ctx.lex.peek();
                if (next.tag == .rbracket) break;
                const elem = try scanAndDeclarePatternWithComputed(ctx);
                try elements.append(ctx.alloc, elem);
                const after = try ctx.lex.peek();
                if (after.tag == .comma) {
                    _ = try ctx.nextToken();
                }
            }
            _ = try ctx.nextToken(); // consume ]

            if (elements.items.len == 0) {
                return ctx.syntaxErr(peek.offset, peek.len);
            }

            const owned = try ctx.dupePatterns(elements.items);
            const pattern = Pattern{ .array = owned };
            try emitPatternCapture(ctx, pattern);
            return pattern;
        },
        .lbrace => {
            _ = try ctx.nextToken(); // consume {
            var fields = std.ArrayList(ObjectPatternField){};
            defer fields.deinit(ctx.alloc);

            while (true) {
                const next = try ctx.lex.peek();
                if (next.tag == .rbrace) break;
                const field = try scanObjectPatternFieldWithComputed(ctx);
                try fields.append(ctx.alloc, field);
                const after = try ctx.lex.peek();
                if (after.tag == .comma) {
                    _ = try ctx.nextToken();
                }
            }
            _ = try ctx.nextToken(); // consume }

            if (fields.items.len == 0) {
                return ctx.syntaxErr(peek.offset, peek.len);
            }

            const owned = try ctx.dupeObjFields(fields.items);
            const pattern = Pattern{ .object = owned };
            try emitPatternCapture(ctx, pattern);
            return pattern;
        },
        else => {
            return ctx.syntaxErr(peek.offset, peek.len);
        },
    }
}

/// Like scanAndDeclarePattern but supports computed keys.
fn scanAndDeclarePatternWithComputed(ctx: *Ctx) (ZqError || error{OutOfMemory})!Pattern {
    const peek = try ctx.lex.peek();

    switch (peek.tag) {
        .dollar => {
            _ = try ctx.nextToken();
            const ident = try ctx.nextToken();
            if (!isVarNameToken(ident.tag)) return ctx.syntaxErr(ident.offset, ident.len);
            const name_ref = try internStr(&ctx.intern, ctx.alloc, ident.slice(ctx.src));
            const var_id = try declareVariable(ctx, name_ref, ctx.alloc);
            return Pattern{ .simple = var_id };
        },
        .lbracket => {
            _ = try ctx.nextToken();
            var elements = std.ArrayList(Pattern){};
            defer elements.deinit(ctx.alloc);

            while (true) {
                const next = try ctx.lex.peek();
                if (next.tag == .rbracket) break;
                const elem = try scanAndDeclarePatternWithComputed(ctx);
                try elements.append(ctx.alloc, elem);
                const after = try ctx.lex.peek();
                if (after.tag == .comma) {
                    _ = try ctx.nextToken();
                }
            }
            _ = try ctx.nextToken();

            if (elements.items.len == 0) {
                return ctx.syntaxErr(peek.offset, peek.len);
            }

            const owned = try ctx.dupePatterns(elements.items);
            return Pattern{ .array = owned };
        },
        .lbrace => {
            _ = try ctx.nextToken();
            var fields = std.ArrayList(ObjectPatternField){};
            defer fields.deinit(ctx.alloc);

            while (true) {
                const next = try ctx.lex.peek();
                if (next.tag == .rbrace) break;
                const field = try scanObjectPatternFieldWithComputed(ctx);
                try fields.append(ctx.alloc, field);
                const after = try ctx.lex.peek();
                if (after.tag == .comma) {
                    _ = try ctx.nextToken();
                }
            }
            _ = try ctx.nextToken();

            if (fields.items.len == 0) {
                return ctx.syntaxErr(peek.offset, peek.len);
            }

            const owned = try ctx.dupeObjFields(fields.items);
            return Pattern{ .object = owned };
        },
        else => {
            return ctx.syntaxErr(peek.offset, peek.len);
        },
    }
}

/// Parse an object pattern field, supporting computed keys `(expr): PATTERN`.
fn scanObjectPatternFieldWithComputed(ctx: *Ctx) (ZqError || error{OutOfMemory})!ObjectPatternField {
    const peek = try ctx.lex.peek();

    if (peek.tag == .dollar) {
        _ = try ctx.nextToken();
        const ident = try ctx.nextToken();
        if (!isVarNameToken(ident.tag)) return ctx.syntaxErr(ident.offset, ident.len);
        const name_ref = try internStr(&ctx.intern, ctx.alloc, ident.slice(ctx.src));
        const var_id = try declareVariable(ctx, name_ref, ctx.alloc);
        return ObjectPatternField{
            .key = .{ .static = name_ref },
            .pattern = Pattern{ .simple = var_id },
        };
    }

    if (peek.tag == .lparen) {
        _ = try ctx.nextToken(); // consume (

        // Compile the key expression into the raw buffer temporarily
        const start: u32 = @intCast(ctx.raw.items.len);
        try parsePipe(ctx);
        const end: u32 = @intCast(ctx.raw.items.len);

        // Validate: {(true):$foo} should fail at compile time because
        // true is a boolean, not a valid key expression for destructuring.
        if (end - start == 1) {
            const only_instr = ctx.raw.items[start];
            if (only_instr.op == .push_bool) {
                return ctx.syntaxErr(peek.offset, peek.len);
            }
        }

        // Save the instructions and truncate the raw buffer so the key expression
        // doesn't appear in the normal instruction stream.
        const saved_instrs = try ctx.alloc.dupe(RawInstr, ctx.raw.items[start..end]);
        // Track for cleanup (use pattern_raw_allocs)
        try ctx.pattern_raw_allocs.append(ctx.alloc, saved_instrs);
        ctx.raw.items.len = start;

        const rparen = try ctx.nextToken();
        if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

        const colon = try ctx.nextToken();
        if (colon.tag != .colon) return ctx.syntaxErr(colon.offset, colon.len);

        const sub_pattern = try scanAndDeclarePatternWithComputed(ctx);

        return ObjectPatternField{
            .key = .{ .computed = saved_instrs },
            .pattern = sub_pattern,
        };
    }

    const key_ref = try parseStaticPatternKey(ctx);
    const colon = try ctx.nextToken();
    if (colon.tag != .colon) return ctx.syntaxErr(colon.offset, colon.len);
    const sub_pattern = try scanAndDeclarePatternWithComputed(ctx);

    return ObjectPatternField{
        .key = .{ .static = key_ref },
        .pattern = sub_pattern,
    };
}

/// Collect all variable IDs from a pattern (for pop_variable cleanup).
fn collectPatternVarIds(pattern: Pattern, list: *std.ArrayList(u32), alloc: std.mem.Allocator) error{OutOfMemory}!void {
    switch (pattern) {
        .simple => |var_id| {
            try list.append(alloc, var_id);
        },
        .array => |elements| {
            for (elements) |elem| {
                try collectPatternVarIds(elem, list, alloc);
            }
        },
        .object => |fields| {
            for (fields) |field| {
                try collectPatternVarIds(field.pattern, list, alloc);
            }
        },
    }
}

// ── Function management ──────────────────────────────────────────────────

/// Register a user-defined function. `params` and `body_raw` are duped.
fn registerFunction(
    ctx: *Ctx,
    name_ref: StrRef,
    params: []const ParamInfo,
    body_raw: []const RawInstr,
    is_recursive: bool,
    body_src_start: u32,
    body_src_end: u32,
    alloc: std.mem.Allocator,
) error{OutOfMemory}!void {
    const params_copy = try alloc.dupe(ParamInfo, params);
    // Only store body_raw for recursive functions (needed for call_function target).
    // Non-recursive functions re-parse from source during expansion.
    const body_copy = if (is_recursive) try alloc.dupe(RawInstr, body_raw) else &[_]RawInstr{};

    try ctx.function_table.append(alloc, FunctionEntry{
        .name = name_ref,
        .params = params_copy,
        .body_raw = body_copy,
        .is_recursive = is_recursive,
        .body_src_start = body_src_start,
        .body_src_end = body_src_end,
        .recursive_body_ip = 0,
        .recursive_body_end_ip = 0,
        .func_table_snapshot = ctx.function_table.items.len,
    });
}

/// Lookup a function by name AND arity. Searches backward so the latest
/// definition (shadowing) wins. Returns the index into function_table.
/// Respects the hidden range [func_hidden_start, func_hidden_end) for
/// lexical scoping during function body re-parsing.
fn lookupFunction(ctx: *Ctx, name_ref: StrRef, arity: u8) ?usize {
    const lookup_name = ctx.intern.items[name_ref.offset..][0..name_ref.len];
    var i: usize = ctx.function_table.items.len;
    while (i > 0) {
        i -= 1;
        // Lexical scoping: skip functions in the hidden range.
        if (ctx.func_hidden_start) |start| {
            if (ctx.func_hidden_end) |end| {
                if (i >= start and i < end) continue;
            }
        }
        const func = &ctx.function_table.items[i];
        const func_name = ctx.intern.items[func.name.offset..][0..func.name.len];
        if (std.mem.eql(u8, func_name, lookup_name) and func.paramCount() == arity) {
            return i;
        }
    }
    return null;
}

/// Check if a function body contains a self-reference (recursive call).
fn bodyIsSelfReferencing(ctx: *Ctx, name_ref: StrRef, arity: u8, body: []const RawInstr) bool {
    const func_name = ctx.intern.items[name_ref.offset..][0..name_ref.len];
    for (body) |instr| {
        if (instr.op == .call_function) {
            // The operand.index is used as a tag: -1 means "self-call" set during parsing
            if (instr.operand.index == -1) return true;
        } else if (instr.op == .call_filter_arg) {
            // Filter arg references are not self-calls
            continue;
        } else if (instr.op == .load_key) {
            // Check for bare ident that matches function name with arity 0
            if (arity == 0) {
                const key_name = ctx.intern.items[instr.operand.str_ref.offset..][0..instr.operand.str_ref.len];
                if (std.mem.eql(u8, key_name, func_name)) {
                    // This could be a field access, not a function call.
                    // We can't distinguish at this level, so we conservatively
                    // don't flag load_key as self-reference.
                }
            }
        }
    }
    return false;
}

/// Inline-expand a function body into ctx.raw by re-parsing the body source
/// with filter argument bindings active. This ensures that pipe-after-generator
/// patterns are handled correctly by parsePipe's distribution logic.
fn expandFunctionCall(ctx: *Ctx, func_idx: usize, call_args: []const CallArg) (ZqError || error{OutOfMemory})!void {
    const func = &ctx.function_table.items[func_idx];

    // For value args ($param), evaluate the arg expression and capture_variable.
    var value_var_ids = std.ArrayList(ValueVarBinding){};
    defer value_var_ids.deinit(ctx.alloc);

    for (func.params, 0..) |param, pi| {
        if (!param.is_filter) {
            // Value arg: emit the argument expression, then capture_variable
            if (pi < call_args.len) {
                const ca = &call_args[pi];
                for (ca.instructions) |instr| {
                    try ctx.raw.append(ctx.alloc, instr);
                }
            }
            const new_var_id = ctx.next_var_id;
            ctx.next_var_id += 1;
            try ctx.emit(.capture_variable, .{ .index = new_var_id });
            try value_var_ids.append(ctx.alloc, .{ .param_idx = pi, .var_id = new_var_id });
        }
    }

    if (func.is_recursive) {
        // Recursive function: emit body once, use call_function for self-calls.
        if (func.recursive_body_ip == 0) {
            const jump_pos = ctx.raw.items.len;
            try ctx.emit(.jump, .{ .index = 0 });

            const body_start_ip: u32 = @intCast(ctx.raw.items.len);
            func.recursive_body_ip = body_start_ip;

            // Re-parse body from source with expanding_recursive_func set so that
            // self-references emit call_function instead of trying to expand.
            const saved_expanding = ctx.expanding_recursive_func;
            ctx.expanding_recursive_func = func_idx;
            try reParseBodyWithBindings(ctx, func, call_args, &value_var_ids);
            ctx.expanding_recursive_func = saved_expanding;

            try ctx.emit(.return_function, .{ .none = {} });
            const body_end_ip: u32 = @intCast(ctx.raw.items.len);
            func.recursive_body_end_ip = body_end_ip;

            ctx.raw.items[jump_pos].operand = .{ .index = @intCast(body_end_ip) };
            try ctx.emit(.call_function, .{ .index = @intCast(body_start_ip) });
        } else {
            try ctx.emit(.call_function, .{ .index = @intCast(func.recursive_body_ip) });
        }
    } else {
        // Non-recursive: re-parse the body from source with filter arg bindings active.
        try reParseBodyWithBindings(ctx, func, call_args, &value_var_ids);
    }

    // Pop value arg variables
    for (value_var_ids.items) |vv| {
        try ctx.emit(.pop_variable, .{ .index = vv.var_id });
    }
}

/// Re-parse a function body from source with filter arg bindings active.
/// This ensures that pipe-after-generator patterns are correctly handled.
fn reParseBodyWithBindings(
    ctx: *Ctx,
    func: *const FunctionEntry,
    call_args: []const CallArg,
    value_var_ids: *const std.ArrayList(ValueVarBinding),
) (ZqError || error{OutOfMemory})!void {
    // Push filter arg bindings so parsePrimaryInner can resolve them.
    const bindings_start = ctx.filter_arg_bindings.items.len;
    for (func.params, 0..) |param, pi| {
        if (param.is_filter and pi < call_args.len) {
            try ctx.filter_arg_bindings.append(ctx.alloc, FilterArgBinding{
                .name = param.name,
                .src_start = call_args[pi].src_start,
                .src_end = call_args[pi].src_end,
            });
        }
    }

    // Declare value arg variables in a new scope.
    try pushScope(ctx, ctx.alloc);
    for (value_var_ids.items) |vv| {
        const param = func.params[vv.param_idx];
        const var_id = try declareVariable(ctx, param.name, ctx.alloc);
        // We already emitted capture_variable with vv.var_id, but need to
        // ensure body references resolve to the same var_id.
        // Update the scope entry to use the pre-allocated var_id.
        for (ctx.current_scope.variables.items) |*ve| {
            if (ve.id == var_id) {
                ve.id = vv.var_id;
                break;
            }
        }
    }

    // Save and redirect lexer to the body source range.
    const saved_lex_pos = ctx.lex.pos;
    ctx.lex.pos = func.body_src_start;

    // Save function table length to scope inner defs.
    const func_table_save = ctx.function_table.items.len;

    // Set up lexical scoping: hide functions defined after this function but
    // before the current re-parse. This ensures the body sees only functions
    // that existed at definition time (jq's lexical scoping).
    const saved_hidden_start = ctx.func_hidden_start;
    const saved_hidden_end = ctx.func_hidden_end;
    if (func.func_table_snapshot < func_table_save) {
        ctx.func_hidden_start = func.func_table_snapshot;
        ctx.func_hidden_end = func_table_save;
    }

    // Re-parse the body.
    try parseFilter(ctx);

    // Restore lexical scoping state.
    ctx.func_hidden_start = saved_hidden_start;
    ctx.func_hidden_end = saved_hidden_end;

    // Restore lexer position.
    ctx.lex.pos = saved_lex_pos;

    // Remove inner defs from function table (they're scoped to this expansion).
    while (ctx.function_table.items.len > func_table_save) {
        const inner = ctx.function_table.pop().?;
        inner.deinit(ctx.alloc);
    }

    // Pop the scope.
    popScope(ctx, ctx.alloc);

    // Pop filter arg bindings.
    ctx.filter_arg_bindings.items.len = bindings_start;
}

// ── Token classification ──────────────────────────────────────────────────────

/// Returns true if the token tag is valid as a variable name after `$`.
/// Keywords are allowed as variable names in jq (e.g. `$if`, `$reduce`).
fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

/// Check if a source range is a simple identifier that matches an active filter arg binding.
/// If so, returns the binding's original source range (for pass-through propagation).
fn resolveFilterArgPassthrough(ctx: *Ctx, src_start: u32, src_end: u32) ?*const FilterArgBinding {
    if (src_start >= src_end) return null;
    const arg_text = std.mem.trim(u8, ctx.src[src_start..src_end], " \t\r\n");
    if (arg_text.len == 0) return null;
    if (!isIdentStart(arg_text[0])) return null;
    for (arg_text[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    }
    // It's a simple identifier. Check against active filter arg bindings (innermost first).
    var bk: usize = ctx.filter_arg_bindings.items.len;
    while (bk > 0) {
        bk -= 1;
        const binding = &ctx.filter_arg_bindings.items[bk];
        const bname = ctx.intern.items[binding.name.offset..][0..binding.name.len];
        if (std.mem.eql(u8, bname, arg_text)) {
            // Recursively resolve: the binding itself might point to another pass-through.
            if (resolveFilterArgPassthrough(ctx, binding.src_start, binding.src_end)) |inner| {
                return inner;
            }
            return binding;
        }
    }
    return null;
}

fn isVarNameToken(tag: Token.Tag) bool {
    return tag == .ident or tag == .and_kw or tag == .or_kw or
        tag == .not_kw or tag == .true_kw or tag == .false_kw or
        tag == .def_kw or tag == .as_kw or tag == .reduce_kw or
        tag == .if_kw or tag == .then_kw or tag == .elif_kw or
        tag == .else_kw or tag == .end_kw or tag == .try_kw or
        tag == .catch_kw or tag == .label_kw or tag == .break_kw;
}

// ── Instruction insertion ─────────────────────────────────────────────────────
//
// Retroactively inserts a raw instruction at `pos`, shifting all later
// instructions right by one slot.  Fixes up every jump-target operand and every
// function-table body-range index whose value is ≥ pos so that they still
// address the same (now shifted) instructions.

/// Rebase instruction-pointer operands in a buffer of raw instructions.
/// Used when EXPR instructions are compiled at one position in the raw stream
/// but later moved to a different position (e.g. reduce/foreach reorder INIT
/// before EXPR). All internal jump/fork/ACE targets are adjusted by `offset`.
fn rebaseExprBuf(buf: []RawInstr, offset: i64) void {
    for (buf) |*r| {
        switch (r.op) {
            .jump, .jump_if_false, .array_collect_start, .limit_start, .fork, .call_function => {
                r.operand.index += offset;
            },
            .fork_try, .fork_alt, .label_begin => {
                if (r.operand.index > 0) r.operand.index += offset;
            },
            else => {},
        }
    }
}

fn insertRawInstr(ctx: *Ctx, pos: usize, instr: RawInstr) error{OutOfMemory}!void {
    // Grow the buffer by one slot (appended dummy is overwritten below).
    try ctx.raw.append(ctx.alloc, .{ .op = .identity, .operand = .{ .none = {} } });
    // Shift items at [pos..len-2] one slot to the right.
    var i = ctx.raw.items.len - 1;
    while (i > pos) : (i -= 1) {
        ctx.raw.items[i] = ctx.raw.items[i - 1];
    }
    ctx.raw.items[pos] = instr;
    // Fix up jump targets whose value is at or past the insertion point.
    const p = @as(u32, @intCast(pos));
    for (ctx.raw.items) |*r| {
        switch (r.op) {
            .jump, .jump_if_false, .array_collect_start, .limit_start, .fork => {
                if (r.operand.index >= p) r.operand.index += 1;
            },
            // fork_try/fork_alt/label_begin use 0 as a sentinel (no handler / unpatched),
            // so only fix up non-zero indices.
            .fork_try, .fork_alt, .label_begin => {
                if (r.operand.index > 0 and r.operand.index >= p) r.operand.index += 1;
            },
            else => {},
        }
    }
    // Fix up recursive function body IPs in the function table.
    for (ctx.function_table.items) |*func| {
        if (func.recursive_body_ip > 0 and func.recursive_body_ip >= p) func.recursive_body_ip += 1;
        if (func.recursive_body_end_ip > 0 and func.recursive_body_end_ip >= p) func.recursive_body_end_ip += 1;
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

const err_mod = @import("error");

pub const CompileResult = union(enum) {
    ok: Compiled,
    err: err_mod.CompileError,
};

/// Standard library functions compiled as a prelude before the user's query.
/// Kept in a single string to avoid allocations; must end with ";" so the
/// trailing user query is valid jq.
const PRELUDE =
    \\def skip($n; g): if $n < 0 then error("skip doesn't support negative count") else foreach g as $x ($n; . - 1; if . < 0 then $x else empty end) end;
    \\def nth($n; g): if $n < 0 then error("nth doesn't support negative count") else last(limit($n + 1; g)) end;
    \\def add(f): reduce f as $x (null; . + $x);
    \\def walk(f): . as $in | if type == "array" then map(walk(f)) | f elif type == "object" then with_entries(.value |= walk(f)) | f else f end;
    \\def pick(f): . as $in | reduce path(f) as $p (null; setpath($p; $in | getpath($p)));
    \\def INDEX(stream; idx_expr): reduce stream as $row ({}; . + {(($row | idx_expr) | tostring): $row});
    \\def INDEX(idx_expr): INDEX(.[]; idx_expr);
    \\def IN(s): . as $x | first((s == $x), false);
    \\def IN(source; s): first((source == s), false);
    \\def JOIN(idx; f): [., (f | tostring) as $k | if idx | has($k) then idx[$k] else null end];
    \\def combinations: if length == 0 then [] else . as $dot | .[0][] as $x | ([$dot[1:]] | combinations) as $rest | [$x] + $rest end;
    \\def combinations(n): [limit(n; repeat(.))] | combinations;
    \\def splits(re): . / re | .[];
    \\def splits(re; flags): . / re | .[];
    \\def scan(re): match(re) | .string;
    \\def capture(re): match(re) | .captures | map(select(.name != null) | {(.name): .string}) | add;
    \\def finites: .[] | select(isinfinite | not) | select(isnan | not);
    \\def todate: strftime("%Y-%m-%dT%H:%M:%SZ");
    \\def fromdate: strptime("%Y-%m-%dT%H:%M:%SZ") | mktime;
    \\def todateiso8601: todate;
    \\def fromdateiso8601: fromdate;
    \\def dateadd(f;x): . + x * f | . + 0;
    \\def datesub(f;x): . - x * f | . + 0;
    \\def modulemeta: {"version": 0, "deps": [], "defs": []};
    \\
;

pub fn compile(src: []const u8, external_vars: []const ExternalVarDecl, alloc: std.mem.Allocator) error{OutOfMemory}!CompileResult {
    // Prepend standard library definitions so user queries can call skip/nth/add(f).
    const full_src = try std.mem.concat(alloc, u8, &.{ PRELUDE, src });
    defer alloc.free(full_src);
    const prelude_len: u32 = @intCast(PRELUDE.len);

    const scope = try alloc.create(VariableScope);
    scope.* = VariableScope{
        .variables = std.ArrayList(VariableEntry){},
        .parent = null,
    };

    var ctx = Ctx{
        .src = full_src,
        .lex = Lexer.init(full_src),
        .raw = std.ArrayList(RawInstr){},
        .intern = std.ArrayList(u8){},
        .alloc = alloc,
        .current_scope = scope,
        .function_table = std.ArrayList(FunctionEntry){},
        .next_var_id = 0,
        .next_func_id = 0,
        .prelude_len = prelude_len,
    };
    defer ctx.raw.deinit(alloc); // always freed; fuse() copies what it needs
    defer {
        // Cleanup function table (free param_ids for each function)
        for (ctx.function_table.items) |*func| {
            func.deinit(alloc);
        }
        ctx.function_table.deinit(alloc);
    }
    defer ctx.label_var_ids.deinit(alloc);
    defer ctx.filter_arg_bindings.deinit(alloc);
    defer {
        // Cleanup pattern allocations
        for (ctx.pattern_allocs.items) |slice| alloc.free(slice);
        ctx.pattern_allocs.deinit(alloc);
        for (ctx.pattern_obj_allocs.items) |slice| alloc.free(slice);
        ctx.pattern_obj_allocs.deinit(alloc);
        for (ctx.pattern_raw_allocs.items) |slice| alloc.free(slice);
        ctx.pattern_raw_allocs.deinit(alloc);
    }
    // Freed unless fuse() consumes it (via toOwnedSlice). Covers both Zig
    // errors (OOM) and early `.err` CompileResult returns.
    var intern_consumed = false;
    defer if (!intern_consumed) ctx.intern.deinit(alloc);
    defer {
        // Cleanup scope chain (both success and error paths)
        var s: ?*VariableScope = ctx.current_scope;
        while (s) |scope_ptr| {
            scope_ptr.variables.deinit(alloc);
            const parent = scope_ptr.parent;
            alloc.destroy(scope_ptr);
            s = parent;
        }
    }

    // Pre-allocate the intern buffer. With function body re-parsing, the same
    // source identifiers may be interned multiple times (once per expansion),
    // so we allocate generously to minimize reallocations. StrRef uses offsets
    // (not pointers), so reallocation is safe for correctness.
    try ctx.intern.ensureTotalCapacity(alloc, full_src.len * 8 + 256);

    // Pre-declare external variables in root scope
    var ext_var_ids = try alloc.alloc(u32, external_vars.len);
    var ext_var_ids_consumed = false;
    defer if (!ext_var_ids_consumed) alloc.free(ext_var_ids);
    for (external_vars, 0..) |ev, i| {
        const name_ref = try internStr(&ctx.intern, alloc, ev.name);
        ext_var_ids[i] = declareVariable(&ctx, name_ref, alloc) catch |e| {
            switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .err = .{
                    .kind = err_mod.kindFromZqError(@as(err_mod.ZqError, @errorCast(e))),
                    .offset = 0,
                    .len = 0,
                } },
            }
        };
    }

    // Subtract the prelude length from error offsets so they reference positions
    // in the user's original query string, not the prepended full_src.
    const adjOff = struct {
        fn f(off: u32, plen: u32) u32 {
            return if (off >= plen) off - plen else 0;
        }
    }.f;

    parseFilter(&ctx) catch |e| {
        switch (e) {
            error.QuerySyntaxError => return .{ .err = .{
                .kind = .query_syntax_error,
                .offset = adjOff(ctx.error_offset, prelude_len),
                .len = ctx.error_len,
            } },
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .err = .{
                .kind = err_mod.kindFromZqError(@as(err_mod.ZqError, @errorCast(e))),
                .offset = adjOff(@intCast(@min(ctx.lex.pos, if (full_src.len > 0) full_src.len - 1 else 0)), prelude_len),
                .len = 0,
            } },
        }
    };

    const tail = ctx.lex.next() catch |e| {
        switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .err = .{
                .kind = err_mod.kindFromZqError(@as(err_mod.ZqError, @errorCast(e))),
                .offset = adjOff(@intCast(@min(ctx.lex.pos, if (full_src.len > 0) full_src.len - 1 else 0)), prelude_len),
                .len = 0,
            } },
        }
    };
    if (tail.tag != .eof) return .{ .err = .{
        .kind = .query_syntax_error,
        .offset = adjOff(tail.offset, prelude_len),
        .len = tail.len,
    } };

    // Append implicit yield_output if not already present.
    const needs_output = ctx.raw.items.len == 0 or
        ctx.raw.items[ctx.raw.items.len - 1].op != .yield_output;
    if (needs_output) {
        try ctx.emit(.yield_output, .{ .none = {} });
    }

    var compiled = try fuse(ctx.raw.items, &ctx.function_table, &ctx.intern, alloc);
    intern_consumed = true; // fuse() took ownership via toOwnedSlice
    compiled.external_var_ids = ext_var_ids;
    ext_var_ids_consumed = true;
    return .{ .ok = compiled };
}

// ── Parser ────────────────────────────────────────────────────────────────────

fn parseFilter(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Check for `def` keyword — function definitions can appear before any expression.
    // In jq, `def f: body; expr` means: define f, then evaluate expr.
    // `def` can also appear inline: `expr | def f: body; more_expr`.
    const peek = try ctx.lex.peek();
    if (peek.tag == .def_kw) {
        _ = try ctx.nextToken(); // consume 'def'
        try parseFunctionDef(ctx);
        return;
    }

    try parsePipe(ctx);
}

/// Lookahead: returns true if the token stream starts with a path expression
/// followed by an update-assignment operator (|=, +=, -=, *=, /=, %=, //=).
/// Pure scan — no instructions emitted, lexer position restored via defer.
fn peekIsUpdateAssign(ctx: *Ctx) ZqError!bool {
    const saved_pos = ctx.lex.pos;
    defer ctx.lex.pos = saved_pos;

    const first = try ctx.nextToken();
    if (first.tag != .dot) return false;

    while (true) {
        const t = try ctx.lex.peek();
        switch (t.tag) {
            .ident => {
                _ = try ctx.nextToken();
                const sep = try ctx.lex.peek();
                if (sep.tag == .dot) _ = try ctx.nextToken();
            },
            .lbracket => {
                _ = try ctx.nextToken();
                const inner = try ctx.lex.peek();
                switch (inner.tag) {
                    .int_lit, .string_lit => {
                        _ = try ctx.nextToken();
                        const close = try ctx.nextToken();
                        if (close.tag != .rbracket) return false;
                        const sep = try ctx.lex.peek();
                        if (sep.tag == .dot) _ = try ctx.nextToken();
                    },
                    .rbracket => {
                        // .[] — iterate update
                        _ = try ctx.nextToken();
                        const sep = try ctx.lex.peek();
                        if (sep.tag == .dot) _ = try ctx.nextToken();
                    },
                    else => return false,
                }
            },
            .eq_assign, .pipe_eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .double_slash_eq => return true,
            else => return false,
        }
    }
}

/// Parse and emit an update-assignment expression.
/// Called only when peekIsUpdateAssign() returned true.
/// Handles: .path = rhs, .path |= f, .path += rhs, .path -= rhs, etc.
///
/// For `|=`: RHS is evaluated against the navigated value (current .path value).
/// For `=`: RHS is evaluated against the original input (before navigation).
/// For `+=`, `-=`, etc.: navigated_value OP rhs, where rhs is evaluated against original input.
fn parseUpdateAssign(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Consume the leading dot
    _ = try ctx.nextToken();

    // Collect path steps
    var path_steps = std.ArrayList(PathStep){};
    defer path_steps.deinit(ctx.alloc);

    while (true) {
        const t = try ctx.lex.peek();
        switch (t.tag) {
            .ident => {
                _ = try ctx.nextToken();
                const ref = try internStr(&ctx.intern, ctx.alloc, t.slice(ctx.src));
                try path_steps.append(ctx.alloc, PathStep{ .kind = .key, .key = ref });
                const sep = try ctx.lex.peek();
                if (sep.tag == .dot) _ = try ctx.nextToken();
            },
            .lbracket => {
                _ = try ctx.nextToken();
                const inner = try ctx.lex.peek();
                switch (inner.tag) {
                    .int_lit => {
                        const tok = try ctx.nextToken();
                        const n = std.fmt.parseInt(i64, tok.slice(ctx.src), 10) catch return ctx.syntaxErr(ctx.last_tok_offset, 0);
                        if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) return ctx.syntaxErr(ctx.last_tok_offset, 0);
                        const close = try ctx.nextToken();
                        if (close.tag != .rbracket) return ctx.syntaxErr(close.offset, close.len);
                        try path_steps.append(ctx.alloc, PathStep{ .kind = .index, .index = n });
                        const sep = try ctx.lex.peek();
                        if (sep.tag == .dot) _ = try ctx.nextToken();
                    },
                    .string_lit => {
                        const tok = try ctx.nextToken();
                        const raw_str = tok.slice(ctx.src);
                        const content = raw_str[1 .. raw_str.len - 1];
                        const ref = try internDecodedStr(&ctx.intern, ctx.alloc, content);
                        const close = try ctx.nextToken();
                        if (close.tag != .rbracket) return ctx.syntaxErr(close.offset, close.len);
                        try path_steps.append(ctx.alloc, PathStep{ .kind = .key, .key = ref });
                        const sep = try ctx.lex.peek();
                        if (sep.tag == .dot) _ = try ctx.nextToken();
                    },
                    else => return ctx.syntaxErr(ctx.last_tok_offset, 0),
                }
            },
            .eq_assign, .pipe_eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .double_slash_eq => break,
            else => break,
        }
    }

    // Consume the assignment operator
    const assign_tok = try ctx.nextToken();
    ctx.last_tok_offset = assign_tok.offset;

    switch (assign_tok.tag) {
        .pipe_eq => {
            // |= : navigate first, evaluate RHS against navigated value
            try emitNavigation(ctx, path_steps.items);
            try parseAlternative(ctx);
            try emitUpdateChain(ctx, path_steps.items);
        },
        .eq_assign => {
            // = : evaluate RHS against original input FIRST, then navigate
            try parseAlternative(ctx);
            try emitNavigation(ctx, path_steps.items);
            try emitUpdateChain(ctx, path_steps.items);
        },
        .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq => {
            // Compound assignment: navigated_value OP rhs(original_input)
            // 1. Save original input in temp variable
            const tmp_var_id = ctx.next_var_id;
            ctx.next_var_id += 1;
            try ctx.emit(.push_current, .{ .none = {} });
            try ctx.emit(.capture_variable, .{ .index = tmp_var_id });

            // 2. Navigate to target
            try emitNavigation(ctx, path_steps.items);

            // 3. Push navigated value (left operand for arithmetic)
            try ctx.emit(.push_current, .{ .none = {} });

            // 4. Restore original input as current for RHS evaluation
            try ctx.emit(.load_variable, .{ .index = tmp_var_id });
            try ctx.emit(.pipe, .{ .none = {} });

            // 5. Evaluate RHS against original input
            try parseAlternative(ctx);

            // 6. Apply arithmetic: left=navigated, right=rhs_result
            const arith_op: Instruction.Op = switch (assign_tok.tag) {
                .plus_eq => .add,
                .minus_eq => .sub,
                .star_eq => .mul,
                .slash_eq => .div,
                .percent_eq => .mod,
                else => unreachable,
            };
            try ctx.emit(arith_op, .{ .none = {} });

            // 7. Update chain
            try emitUpdateChain(ctx, path_steps.items);
        },
        .double_slash_eq => {
            // //= : .path //= rhs → if .path is truthy keep it, else set to rhs(original)
            // Save original input in temp variable
            const tmp_var_id = ctx.next_var_id;
            ctx.next_var_id += 1;
            try ctx.emit(.push_current, .{ .none = {} });
            try ctx.emit(.capture_variable, .{ .index = tmp_var_id });

            // Navigate
            try emitNavigation(ctx, path_steps.items);

            // Use alternative: . // rhs via fork_alt
            const fork_alt_pos = ctx.raw.items.len;
            try ctx.emit(.fork_alt, .{ .index = 0 }); // backpatch to right side
            // The current value from navigation is in `current`. Check truthiness.
            try ctx.emit(.push_current, .{ .none = {} });
            const jif_pos = ctx.raw.items.len;
            try ctx.emit(.jump_if_false, .{ .index = 0 }); // backpatch to falsy
            // Truthy: pop_try and re-push value for downstream.
            try ctx.emit(.pop_try, .{ .none = {} });
            try ctx.emit(.push_current, .{ .none = {} });
            const jump_end_pos = ctx.raw.items.len;
            try ctx.emit(.jump, .{ .index = 0 }); // backpatch to end
            // Falsy: backtrack to try next output from left side
            ctx.raw.items[jif_pos].operand = .{ .index = @intCast(ctx.raw.items.len) };
            try ctx.emit(.backtrack, .{ .none = {} });
            // Right side
            const right_ip: u32 = @intCast(ctx.raw.items.len);
            ctx.raw.items[fork_alt_pos].operand = .{ .index = right_ip };
            // Restore original for RHS
            try ctx.emit(.load_variable, .{ .index = tmp_var_id });
            try ctx.emit(.pipe, .{ .none = {} });
            try parseAlternative(ctx);
            ctx.raw.items[jump_end_pos].operand = .{ .index = @intCast(ctx.raw.items.len) };

            // Update chain
            try emitUpdateChain(ctx, path_steps.items);
        },
        else => return ctx.syntaxErr(assign_tok.offset, assign_tok.len),
    }
}

/// Emit navigation instructions for a path: save_input + navigate_key/index for each step.
fn emitNavigation(ctx: *Ctx, steps: []const PathStep) error{OutOfMemory}!void {
    for (steps) |step| {
        try ctx.emit(.save_input, .{ .none = {} });
        switch (step.kind) {
            .key => try ctx.emit(.navigate_key, .{ .str_ref = step.key }),
            .index => try ctx.emit(.navigate_index, .{ .index = step.index }),
        }
    }
}

/// Emit update instructions in reverse path order.
fn emitUpdateChain(ctx: *Ctx, steps: []const PathStep) error{OutOfMemory}!void {
    var i = steps.len;
    while (i > 0) {
        i -= 1;
        const step = steps[i];
        switch (step.kind) {
            .key => try ctx.emit(.update_key, .{ .str_ref = step.key }),
            .index => try ctx.emit(.update_index, .{ .index = step.index }),
        }
    }
}

fn parsePipe(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    if (try peekIsUpdateAssign(ctx)) {
        try parseUpdateAssign(ctx);
        return;
    }
    try parseComma(ctx);

    // Handle `expr as PATTERN` — moves from parseLogical to parsePipe so that
    // the entire comma expression (not just the last element) is the generator.
    // jq semantics: each value produced by `expr` is bound to PATTERN and
    // `body` evaluates once per value.  Using scanAndDeclarePatternWithComputed
    // also fixes computed-key destructuring (e.g. `as {("a"+"b"): $v}`).
    {
        const t2 = try ctx.lex.peek();
        if (t2.tag == .as_kw) {
            _ = try ctx.nextToken(); // consume 'as'
            const first_pattern = try scanAndDeclarePatternWithComputed(ctx);
            if (try peekIsDestructAlt(ctx)) {
                try parseDestructAlt(ctx, first_pattern);
            } else {
                try emitPatternCapture(ctx, first_pattern);
            }
            // Fall through: the `| body` pipe is consumed by the while loop below.
        }
    }

    while (true) {
        const t = try ctx.lex.peek();
        if (t.tag != .pipe) break;
        _ = try ctx.nextToken();

        // If the right side starts with `def`, delegate to parseFilter which
        // handles function definitions. This supports `expr | def f: body; cont`.
        const after_pipe = try ctx.lex.peek();
        if (after_pipe.tag == .def_kw) {
            try ctx.emit(.pipe, .{ .none = {} });
            _ = try ctx.nextToken(); // consume 'def'
            try parseFunctionDef(ctx);
            break;
        }

        // With fork/backtrack, pipe simply passes the value through.
        // No distribution needed — generators naturally backtrack.
        try ctx.emit(.pipe, .{ .none = {} });
        try parseComma(ctx);

        // Each pipe segment may itself be followed by `as PATTERN`, e.g.
        // `a | b as $x | c`.  Handle it here so the full right-hand comma
        // expression is the generator (not just its last logical operand).
        {
            const t2 = try ctx.lex.peek();
            if (t2.tag == .as_kw) {
                _ = try ctx.nextToken(); // consume 'as'
                const first_pattern = try scanAndDeclarePatternWithComputed(ctx);
                if (try peekIsDestructAlt(ctx)) {
                    try parseDestructAlt(ctx, first_pattern);
                } else {
                    try emitPatternCapture(ctx, first_pattern);
                }
                // Fall through: `| body` consumed by next iteration.
            }
        }
    }
}

/// parseComma: `,` generator operator.
/// Produces all outputs of the left expression, then all outputs of the right.
/// Precedence: higher than `|`, lower than `//`.
///
/// For `a, b` emits:
///   save_input
///   <a>
///   output
///   restore_input
///   save_input
///   <b>
///   output
///   restore_input
///
/// The final restore_input ensures the original input is available for
/// any downstream pipe. The outputs are consumed by the output instruction.
///
/// On execution, the fork pushes a backtrack point. When the first path
/// completes and backtracks, execution resumes at L_b for the second path.
fn parseComma(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    var jump_fixups = std.ArrayList(usize){};
    defer jump_fixups.deinit(ctx.alloc);

    var left_start: usize = ctx.raw.items.len;
    try parseAlternative(ctx);

    // Track the position of the previous FORK so we can fix its target after
    // the next insertRawInstr (which auto-adjusts it one past the new FORK,
    // but we want it to point AT the new FORK for correct chaining).
    var prev_fork_pos: ?usize = null;

    while (true) {
        const t = try ctx.lex.peek();
        if (t.tag != .comma) break;
        _ = try ctx.nextToken();

        // Insert FORK before the left subtree — target placeholder.
        try insertRawInstr(ctx, left_start, RawInstr{ .op = .fork, .operand = .{ .index = 0 } });

        // Fix previous FORK: insertRawInstr auto-adjusted its target from
        // left_start to left_start+1 (because the old branch start shifted),
        // but we want it to point AT left_start (this new FORK) for correct
        // chaining: backtracking to the previous FORK should land on this FORK
        // which sets up the next branch's forkpoint.
        if (prev_fork_pos) |pfp| {
            ctx.raw.items[pfp].operand.index = @intCast(left_start);
        }

        // Emit JUMP to end (placeholder, will be backpatched).
        const jump_pos = ctx.raw.items.len;
        try ctx.emit(.jump, .{ .index = 0 });
        try jump_fixups.append(ctx.alloc, jump_pos);

        // Save this FORK position for backpatching AFTER parsing the right side.
        const current_fork_pos = left_start;

        // Parse the right expression.
        left_start = ctx.raw.items.len;
        const after_comma = try ctx.lex.peek();
        if (after_comma.tag == .def_kw) {
            _ = try ctx.nextToken(); // consume 'def'
            try parseFunctionDef(ctx);
        } else {
            try parseAlternative(ctx);
        }

        // Backpatch FORK target to the start of the right side.
        // Done AFTER parsing so inner insertRawInstr calls don't shift it.
        ctx.raw.items[current_fork_pos].operand.index = @intCast(left_start);
        prev_fork_pos = current_fork_pos;
    }

    // Backpatch all JUMP targets to point past the end.
    const end_pos: i64 = @intCast(ctx.raw.items.len);
    for (jump_fixups.items) |fixup| {
        ctx.raw.items[fixup].operand.index = end_pos;
    }
}

/// parseAlternative: `//` (alternative operator / null coalescing).
/// Precedence: lower than `or`/`and`, higher than `|`.
///
/// For `a // b` emits:
///   fork_alt L_right       ← error/exhaustion → try right side
///   <a>
///   pipe                   ← move result to current
///   push_current           ← dup for truthiness check
///   jump_if_false L_falsy
///   pop_try                ← committed: left produced truthy value
///   push_current           ← re-push value for downstream
///   jump L_end
///   L_falsy:
///   backtrack              ← falsy output: try next <a> output
///   L_right:
///   <b>
///   L_end:
fn parseAlternative(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const chain_start: usize = ctx.raw.items.len;
    try parseLogical(ctx);
    while (true) {
        const t = try ctx.lex.peek();
        if (t.tag != .double_slash) break;
        _ = try ctx.nextToken();

        // Insert fork_alt before the entire left subtree.
        try insertRawInstr(ctx, chain_start, RawInstr{ .op = .fork_alt, .operand = .{ .index = 0 } });

        // Move left result to current (handles both value_stack and current cases).
        try ctx.emit(.pipe, .{ .none = {} });

        // Truthiness check: dup current and check.
        try ctx.emit(.push_current, .{ .none = {} });
        const jif_pos = ctx.raw.items.len;
        try ctx.emit(.jump_if_false, .{ .index = 0 });

        // Truthy: pop_try and re-push value for downstream.
        try ctx.emit(.pop_try, .{ .none = {} });
        try ctx.emit(.push_current, .{ .none = {} });
        const jump_end_pos = ctx.raw.items.len;
        try ctx.emit(.jump, .{ .index = 0 });

        // Falsy: backtrack to try next left-side output.
        ctx.raw.items[jif_pos].operand = .{ .index = @intCast(ctx.raw.items.len) };
        try ctx.emit(.backtrack, .{ .none = {} });

        // Right side: fork_alt points here.
        const right_ip: u32 = @intCast(ctx.raw.items.len);
        ctx.raw.items[chain_start].operand = .{ .index = right_ip };

        // Parse the right expression.
        try parseLogical(ctx);

        // Backpatch jump to end.
        ctx.raw.items[jump_end_pos].operand = .{ .index = @intCast(ctx.raw.items.len) };
    }
}

/// parseLogical: `or`, `and` (lowest precedence)
fn parseLogical(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try parseOr(ctx);
    // Note: `as PATTERN` is handled at parsePipe level, not here, so that the
    // entire comma expression is the generator (correct jq semantics).
}

/// Returns true if the next two tokens are `?` followed by `//`,
/// forming the `?//` destructuring alternative operator.
/// Consumes both tokens if matched; otherwise restores the lexer position.
fn peekIsDestructAlt(ctx: *Ctx) ZqError!bool {
    const saved_pos = ctx.lex.pos;
    const t1 = try ctx.lex.next();
    if (t1.tag != .question) {
        ctx.lex.pos = saved_pos;
        return false;
    }
    const t2 = try ctx.lex.next();
    if (t2.tag != .double_slash) {
        ctx.lex.pos = saved_pos;
        return false;
    }
    // Consumed `?//` — do NOT restore position.
    return true;
}

/// Parse and compile a `?//` (destructuring alternative) chain.
/// Called after the first pattern has been scanned and the first `?//` consumed.
///
/// Grammar: `expr as P1 ?// P2 ?// ... ?// Pn | body`
///
/// Semantics: evaluate `expr`, try to match against P1. If P1 fails (type
/// error during destructuring), try P2, and so on. If all patterns fail,
/// the expression produces empty (no output). Variables from ALL patterns
/// are in scope in `body`; variables from non-matching patterns remain null.
///
/// Desugars to:
///   push_null + capture_variable for each declared var (null-initialize)
///   save_input                   (preserve expr result for each attempt)
///   try_begin(catch_ip = P2)
///     <strict capture P1>
///   try_end(0)
///   restore_input                (clean up saved input on success)
///   jump(body)
///   P2: restore_input
///   try_begin(catch_ip = P3)
///     <strict capture P2>
///   try_end(0)
///   restore_input
///   jump(body)
///   ...
///   Pn: restore_input
///   try_begin(catch_ip = empty)
///     <strict capture Pn>
///   try_end(0)
///   restore_input
///   jump(body)
///   empty: restore_input
///   call_builtin(empty)
///   body: ...
fn parseDestructAlt(ctx: *Ctx, first_pattern: Pattern) (ZqError || error{OutOfMemory})!void {
    // Collect all patterns in the chain.
    var patterns = std.ArrayList(Pattern){};
    defer patterns.deinit(ctx.alloc);
    try patterns.append(ctx.alloc, first_pattern);

    // Scan remaining patterns, reusing variable names from the first.
    while (true) {
        const pat = try scanAndDeclarePatternReuse(ctx);
        try patterns.append(ctx.alloc, pat);
        // Check for another `?//`
        if (!(try peekIsDestructAlt(ctx))) break;
    }

    // Collect all unique var_ids across all patterns.
    var all_var_ids = std.ArrayList(u32){};
    defer all_var_ids.deinit(ctx.alloc);
    for (patterns.items) |pat| {
        try collectPatternVarIds(pat, &all_var_ids, ctx.alloc);
    }

    // Null-initialize all variables so non-matching patterns produce null.
    for (all_var_ids.items) |var_id| {
        try ctx.emit(.push_null, .{ .none = {} });
        try ctx.emit(.capture_variable, .{ .index = var_id });
    }

    // The expr result is on the value stack. We need to save it for each attempt.
    // Pipe it to current, then save_input for the first pattern attempt.
    try ctx.emit(.pipe, .{ .none = {} });
    try ctx.emit(.save_input, .{ .none = {} });

    // Track jump positions that need backpatching to the body start.
    var jump_to_body = std.ArrayList(usize){};
    defer jump_to_body.deinit(ctx.alloc);

    for (patterns.items, 0..) |pat, i| {
        const is_last = (i == patterns.items.len - 1);

        if (i > 0) {
            // Catch target for the previous pattern's try_begin lands here.
            // Restore input to get expr result back as current.
            try ctx.emit(.restore_input, .{ .none = {} });
            // Re-save for the next attempt (or for cleanup after last).
            try ctx.emit(.save_input, .{ .none = {} });
        }

        // Wrap strict capture in fork_try/pop_try.
        const fork_try_pos = ctx.raw.items.len;
        try ctx.emit(.fork_try, .{ .index = 0 });

        // Push current to value_stack so emitPatternCaptureStrict can pipe it.
        try ctx.emit(.push_current, .{ .none = {} });

        // Emit strict pattern capture (errors propagate to fork_try's catch).
        try emitPatternCaptureStrict(ctx, pat);

        try ctx.emit(.pop_try, .{ .none = {} });

        // Success path: restore saved input (clean up if_stack), jump to body.
        try ctx.emit(.restore_input, .{ .none = {} });
        const jmp_pos = ctx.raw.items.len;
        try ctx.emit(.jump, .{ .index = 0 });
        try jump_to_body.append(ctx.alloc, jmp_pos);

        // Backpatch fork_try: catch_ip = next instruction (next pattern's restore or empty handler).
        const catch_ip: u32 = @intCast(ctx.raw.items.len);
        ctx.raw.items[fork_try_pos].operand = .{ .index = catch_ip };

        if (is_last) {
            // All patterns failed — restore input and produce empty.
            try ctx.emit(.restore_input, .{ .none = {} });
            try ctx.emit(.backtrack, .{ .none = {} });
        }
    }

    // Body starts here — backpatch all jump-to-body positions.
    const body_ip: u32 = @intCast(ctx.raw.items.len);
    for (jump_to_body.items) |jmp_pos| {
        ctx.raw.items[jmp_pos].operand = .{ .index = body_ip };
    }
}

fn parseOr(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try parseAnd(ctx);
    while (true) {
        const t = try ctx.lex.peek();
        if (t.tag != .or_kw) break;
        _ = try ctx.nextToken();
        try parseAnd(ctx);
        try ctx.emit(.or_op, .{ .none = {} });
    }
}

fn parseAnd(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try parseComparison(ctx);
    while (true) {
        const t = try ctx.lex.peek();
        if (t.tag != .and_kw) break;
        _ = try ctx.nextToken();
        try parseComparison(ctx);
        try ctx.emit(.and_op, .{ .none = {} });
    }
}

/// parseComparison: `==`, `!=`, `<`, `<=`, `>`, `>=`
fn parseComparison(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try parseAdditive(ctx);
    while (true) {
        const t = try ctx.lex.peek();
        const op: Instruction.Op = switch (t.tag) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => break,
        };
        _ = try ctx.nextToken();
        try parseAdditive(ctx);
        try ctx.emit(op, .{ .none = {} });
    }
}

/// parseAdditive: `+`, `-`
fn parseAdditive(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try parseMultiplicative(ctx);
    while (true) {
        const t = try ctx.lex.peek();
        const op: Instruction.Op = switch (t.tag) {
            .plus => .add,
            .minus => .sub,
            else => break,
        };
        _ = try ctx.nextToken();
        try parseMultiplicative(ctx);
        try ctx.emit(op, .{ .none = {} });
    }
}

/// parseMultiplicative: `*`, `/`, `%`
fn parseMultiplicative(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try parseUnary(ctx);
    while (true) {
        const t = try ctx.lex.peek();
        const op: Instruction.Op = switch (t.tag) {
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            else => break,
        };
        _ = try ctx.nextToken();
        try parseUnary(ctx);
        try ctx.emit(op, .{ .none = {} });
    }
}

/// parseUnary: unary `-`
/// Note: `not` is handled as a zero-arg builtin in parsePrimary, not as a prefix operator.
/// In jq, `not` is always a postfix filter: `expr | not`, not a prefix `not expr`.
fn parseUnary(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const t = try ctx.lex.peek();
    if (t.tag == .minus) {
        _ = try ctx.nextToken();
        // Recursively parse the operand, then emit negate.
        // Note: `-1` (no space) is handled by the lexer as a single int_lit token,
        // so this branch only fires for `-.foo`, `-(expr)`, `- 1` (with space), etc.
        try parseUnary(ctx);
        try ctx.emit(.negate, .{ .none = {} });
    } else {
        try parsePrimary(ctx);
    }
}

/// Zero-argument builtins: emitted as call_builtin(id) with no parens consumed.
fn zeroArgBuiltinId(name: []const u8) ?types.BuiltinId {
    if (std.mem.eql(u8, name, "length")) return .length;
    if (std.mem.eql(u8, name, "keys")) return .keys;
    if (std.mem.eql(u8, name, "keys_unsorted")) return .keys_unsorted;
    if (std.mem.eql(u8, name, "values")) return .values;
    if (std.mem.eql(u8, name, "type")) return .type_;
    if (std.mem.eql(u8, name, "empty")) return .empty;
    if (std.mem.eql(u8, name, "tostring")) return .tostring;
    if (std.mem.eql(u8, name, "tonumber")) return .tonumber;
    if (std.mem.eql(u8, name, "toboolean")) return .toboolean;
    if (std.mem.eql(u8, name, "utf8bytelength")) return .utf8bytelength;
    if (std.mem.eql(u8, name, "trim")) return .trim_;
    if (std.mem.eql(u8, name, "ltrim")) return .ltrim_;
    if (std.mem.eql(u8, name, "rtrim")) return .rtrim_;
    if (std.mem.eql(u8, name, "error")) return .error_;
    if (std.mem.eql(u8, name, "add")) return .add;
    if (std.mem.eql(u8, name, "sort")) return .sort;
    if (std.mem.eql(u8, name, "reverse")) return .reverse;
    // flatten is handled as both zero-arg and one-arg; caller must check for parens
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

    // Math builtins (zero-arg)
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
    if (std.mem.eql(u8, name, "significand")) return .significand_;
    if (std.mem.eql(u8, name, "logb")) return .logb_;
    if (std.mem.eql(u8, name, "j0")) return .j0_;
    if (std.mem.eql(u8, name, "j1")) return .j1_;
    if (std.mem.eql(u8, name, "lgamma")) return .lgamma_;
    if (std.mem.eql(u8, name, "tgamma")) return .tgamma_;

    // Type-check filter builtins (zero-arg)
    if (std.mem.eql(u8, name, "arrays")) return .arrays_;
    if (std.mem.eql(u8, name, "objects")) return .objects_;
    if (std.mem.eql(u8, name, "strings")) return .strings_;
    if (std.mem.eql(u8, name, "numbers")) return .numbers_;
    if (std.mem.eql(u8, name, "booleans")) return .booleans_;
    if (std.mem.eql(u8, name, "nulls")) return .nulls_;
    if (std.mem.eql(u8, name, "scalars")) return .scalars_;
    if (std.mem.eql(u8, name, "normals")) return .normals_;
    if (std.mem.eql(u8, name, "iterables")) return .iterables_;

    // String builtins
    if (std.mem.eql(u8, name, "ascii_downcase")) return .ascii_downcase;
    if (std.mem.eql(u8, name, "ascii_upcase")) return .ascii_upcase;
    if (std.mem.eql(u8, name, "ascii")) return .ascii_;
    if (std.mem.eql(u8, name, "explode")) return .explode_;
    if (std.mem.eql(u8, name, "implode")) return .implode_;

    // Array utility builtins (zero-arg)
    if (std.mem.eql(u8, name, "transpose")) return .transpose_;

    // JSON builtins
    if (std.mem.eql(u8, name, "tojson")) return .tojson;
    if (std.mem.eql(u8, name, "fromjson")) return .fromjson;

    // Misc builtins
    // Note: `not` is handled as .not_kw in the lexer, emitting Op.not directly.
    if (std.mem.eql(u8, name, "builtins")) return .builtins_;
    if (std.mem.eql(u8, name, "debug")) return .debug_;
    if (std.mem.eql(u8, name, "stderr")) return .stderr_;
    if (std.mem.eql(u8, name, "input")) return .input_;
    if (std.mem.eql(u8, name, "inputs")) return .inputs_;
    if (std.mem.eql(u8, name, "env")) return .env_;
    if (std.mem.eql(u8, name, "halt")) return .halt_;
    if (std.mem.eql(u8, name, "halt_error")) return .halt_error_;

    // Date/time builtins (zero-arg)
    if (std.mem.eql(u8, name, "now")) return .now_;
    if (std.mem.eql(u8, name, "gmtime")) return .gmtime_;
    if (std.mem.eql(u8, name, "mktime")) return .mktime_;

    return null;
}

/// Arg-taking builtins: name requires parens and special argument handling.
fn isArgBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "map") or
        std.mem.eql(u8, name, "select") or
        std.mem.eql(u8, name, "has") or
        std.mem.eql(u8, name, "in") or
        std.mem.eql(u8, name, "range") or
        std.mem.eql(u8, name, "flatten") or
        std.mem.eql(u8, name, "contains") or
        std.mem.eql(u8, name, "inside") or
        std.mem.eql(u8, name, "indices") or
        std.mem.eql(u8, name, "index") or
        std.mem.eql(u8, name, "rindex") or
        std.mem.eql(u8, name, "sort_by") or
        std.mem.eql(u8, name, "group_by") or
        std.mem.eql(u8, name, "min_by") or
        std.mem.eql(u8, name, "max_by") or
        std.mem.eql(u8, name, "unique_by") or
        std.mem.eql(u8, name, "with_entries") or
        std.mem.eql(u8, name, "any") or
        std.mem.eql(u8, name, "all") or
        std.mem.eql(u8, name, "first") or
        std.mem.eql(u8, name, "last") or
        std.mem.eql(u8, name, "limit") or
        std.mem.eql(u8, name, "del") or
        std.mem.eql(u8, name, "while") or
        std.mem.eql(u8, name, "until") or
        std.mem.eql(u8, name, "repeat") or
        std.mem.eql(u8, name, "getpath") or
        std.mem.eql(u8, name, "setpath") or
        std.mem.eql(u8, name, "delpaths") or
        std.mem.eql(u8, name, "pow") or
        std.mem.eql(u8, name, "atan2") or
        std.mem.eql(u8, name, "remainder") or
        std.mem.eql(u8, name, "hypot") or
        std.mem.eql(u8, name, "scalb") or
        std.mem.eql(u8, name, "scalbln") or
        std.mem.eql(u8, name, "ldexp") or
        std.mem.eql(u8, name, "fma") or
        std.mem.eql(u8, name, "drem") or
        std.mem.eql(u8, name, "map_values") or
        std.mem.eql(u8, name, "isempty") or
        std.mem.eql(u8, name, "debug") or
        std.mem.eql(u8, name, "halt_error") or
        std.mem.eql(u8, name, "split") or
        std.mem.eql(u8, name, "join") or
        std.mem.eql(u8, name, "startswith") or
        std.mem.eql(u8, name, "endswith") or
        std.mem.eql(u8, name, "ltrimstr") or
        std.mem.eql(u8, name, "rtrimstr") or
        std.mem.eql(u8, name, "trimstr") or
        std.mem.eql(u8, name, "test") or
        std.mem.eql(u8, name, "match") or
        std.mem.eql(u8, name, "sub") or
        std.mem.eql(u8, name, "gsub") or
        std.mem.eql(u8, name, "bsearch") or
        std.mem.eql(u8, name, "strftime") or
        std.mem.eql(u8, name, "strptime") or
        std.mem.eql(u8, name, "error");
}

/// Compile a single-arg value builtin that must support generator expressions (commas)
/// in its argument. For `builtin(a,b,c)`, emits:
///   save_input; <a>; call_builtin(bid); output; restore_input;
///   save_input; <b>; call_builtin(bid); output; restore_input;
///   <c>; call_builtin(bid)
/// The final alternative does NOT get save/output/restore because the result
/// flows naturally into whatever follows.
///
/// Each comma-separated alternative is parsed with `parseAlternative` (handles `//`
/// but not `,`). The `call_builtin` is emitted per-alternative so that each value
/// independently drives the builtin (e.g. `range(3,5)` → range(3) then range(5)).
fn compileValueArgBuiltin1(ctx: *Ctx, bid: types.BuiltinId) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // Use fork/backtrack model for generator args: each comma alternative
    // becomes a fork branch that evaluates the arg and calls the builtin.
    // Structure: FORK L2, <arg1>, call_builtin, JUMP end, L2: <arg2>, call_builtin, end:
    var jump_fixups = std.ArrayList(usize){};
    defer jump_fixups.deinit(ctx.alloc);
    var left_start: usize = ctx.raw.items.len;
    try parseAlternative(ctx);
    var prev_fork_pos: ?usize = null;

    while (true) {
        const t = try ctx.lex.peek();
        if (t.tag != .comma) break;
        _ = try ctx.nextToken(); // consume ','

        // Emit call_builtin for the left side before inserting FORK
        try ctx.emit(.call_builtin, .{ .index = @intFromEnum(bid) });

        // Insert FORK before the left branch
        try insertRawInstr(ctx, left_start, RawInstr{ .op = .fork, .operand = .{ .index = 0 } });
        if (prev_fork_pos) |pfp| {
            ctx.raw.items[pfp].operand.index = @intCast(left_start);
        }

        // Emit JUMP past remaining alternatives
        const jump_pos = ctx.raw.items.len;
        try ctx.emit(.jump, .{ .index = 0 });
        try jump_fixups.append(ctx.alloc, jump_pos);

        const current_fork_pos = left_start;
        left_start = ctx.raw.items.len;

        // Parse next alternative
        try parseAlternative(ctx);

        // Backpatch FORK target to where the next alternative starts
        ctx.raw.items[current_fork_pos].operand.index = @intCast(left_start);
        prev_fork_pos = current_fork_pos;
    }

    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // Emit call_builtin for the last (or only) alternative
    try ctx.emit(.call_builtin, .{ .index = @intFromEnum(bid) });

    // Backpatch all JUMPs to end
    const end_pos: i64 = @intCast(ctx.raw.items.len);
    for (jump_fixups.items) |fixup| {
        ctx.raw.items[fixup].operand.index = end_pos;
    }
}

/// Parse a single semicolon-delimited argument that may contain commas (generators).
/// Collects the generator outputs into an array using array_collect_start/end.
/// This is used for multi-arg builtins like `range(a;b)` where each arg may be
/// a generator expression (e.g. `range(0,1;3,4)` for Cartesian product).
fn parseArgToArray(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const start_pos = ctx.raw.items.len;
    try ctx.emit(.array_collect_start, .{ .index = 0 });

    // Parse the full pipe expression (includes commas which generate multiple values)
    try parsePipe(ctx);

    // Each generated value needs to be collected
    try ctx.emit(.yield_output, .{ .none = {} });

    // End collection
    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.emit(.array_collect_end, .{ .none = {} });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };
}

/// Compile a `map(f)` expression.
/// Desugars to: array_collect_start | iterate | <f> | output | array_collect_end
fn compileMap(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Consume opening paren
    _ = try ctx.nextToken();

    // Emit array_collect_start with placeholder end_ip
    const start_pos = ctx.raw.items.len;
    try ctx.emit(.array_collect_start, .{ .index = 0 });

    // Emit iterate: iterates over current value
    try ctx.emit(.each, .{ .none = {} });

    // Parse the mapping expression (use parsePipe to support commas/pipes in filter args)
    try parsePipe(ctx);

    // Emit output to collect each element
    try ctx.emit(.yield_output, .{ .none = {} });

    // Consume closing paren
    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // Emit array_collect_end and backpatch start
    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.emit(.array_collect_end, .{ .none = {} });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };
}

/// Compile a `select(f)` expression.
/// Desugars to:
///   save_input
///   <f>
///   jump_if_false(skip)
///   restore_input
///   jump(done)
/// skip:
///   restore_input
///   call_builtin(empty)
/// done:
fn compileSelect(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Consume opening paren
    _ = try ctx.nextToken();

    // save_input so we can restore the original for output
    try ctx.emit(.save_input, .{ .none = {} });

    // Parse the predicate expression (use parsePipe to support commas/pipes in filter args)
    try parsePipe(ctx);

    // Consume closing paren
    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // jump_if_false → skip (placeholder)
    const jif_pos = ctx.raw.items.len;
    try ctx.emit(.jump_if_false, .{ .index = 0 });

    // Truthy path: restore_input (gives original value as output)
    try ctx.emit(.restore_input, .{ .none = {} });

    // jump → done (placeholder)
    const jmp_pos = ctx.raw.items.len;
    try ctx.emit(.jump, .{ .index = 0 });

    // skip: restore_input then call_builtin(empty)
    const skip_ip: u32 = @intCast(ctx.raw.items.len);
    ctx.raw.items[jif_pos].operand = .{ .index = skip_ip };
    try ctx.emit(.restore_input, .{ .none = {} });
    try ctx.emit(.backtrack, .{ .none = {} });

    // done:
    const done_ip: u32 = @intCast(ctx.raw.items.len);
    ctx.raw.items[jmp_pos].operand = .{ .index = done_ip };
}

/// Compile `while(cond; update)` — output current value while cond is true,
/// apply update each iteration.
///
/// Bytecode layout:
/// loop_top:
///   save_input                    ; save current for condition evaluation
///   <cond>                        ; evaluate condition, result on stack
///   jump_if_false -> loop_exit    ; if false, exit loop
///   restore_input                 ; true path: restore original value
///   output                        ; emit current value as output
///   <update>                      ; apply update to current value
///   pipe                          ; transfer update result to current
///   jump -> loop_top              ; loop back to re-check condition
/// loop_exit:
///   restore_input                 ; false path: clean up save_input from if_stack
///   call_builtin(empty)           ; produce no output on exit (stop the generator)
fn compileWhile(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // loop_top:
    const loop_top: u32 = @intCast(ctx.raw.items.len);

    // save_input
    try ctx.emit(.save_input, .{ .none = {} });

    // <cond>
    try parsePipe(ctx);

    // expect ';'
    const semi = try ctx.nextToken();
    if (semi.tag != .semicolon) return ctx.syntaxErr(semi.offset, semi.len);

    // jump_if_false -> loop_exit (placeholder)
    const jif_pos = ctx.raw.items.len;
    try ctx.emit(.jump_if_false, .{ .index = 0 });

    // restore_input (true path)
    try ctx.emit(.restore_input, .{ .none = {} });

    // output — emit current value
    try ctx.emit(.yield_output, .{ .none = {} });

    // <update>
    try parsePipe(ctx);

    // expect ')'
    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // pipe — transfer update result to current
    try ctx.emit(.pipe, .{ .none = {} });

    // jump -> loop_top
    try ctx.emit(.jump, .{ .index = loop_top });

    // loop_exit:
    const loop_exit: u32 = @intCast(ctx.raw.items.len);
    ctx.raw.items[jif_pos].operand = .{ .index = loop_exit };

    // restore_input (false path — balance the save_input)
    try ctx.emit(.restore_input, .{ .none = {} });

    // backtrack — produce no output on exit
    try ctx.emit(.backtrack, .{ .none = {} });
}

/// Compile `until(cond; update)` — apply update until cond is true, output
/// only the final value.
///
/// Bytecode layout:
/// loop_top:
///   save_input                    ; save current for condition evaluation
///   <cond>                        ; evaluate condition
///   jump_if_false -> loop_body    ; if false (not done yet), continue looping
///   restore_input                 ; true path: condition met, exit with current value
///   jump -> loop_done             ; skip to done
/// loop_body:
///   restore_input                 ; false path: restore value for update
///   <update>                      ; apply update
///   pipe                          ; transfer result to current
///   jump -> loop_top              ; loop back
/// loop_done:
///   push_current                  ; put final value on stack for downstream use
fn compileUntil(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // loop_top:
    const loop_top: u32 = @intCast(ctx.raw.items.len);

    // save_input
    try ctx.emit(.save_input, .{ .none = {} });

    // <cond>
    try parsePipe(ctx);

    // expect ';'
    const semi = try ctx.nextToken();
    if (semi.tag != .semicolon) return ctx.syntaxErr(semi.offset, semi.len);

    // jump_if_false -> loop_body (placeholder)
    const jif_pos = ctx.raw.items.len;
    try ctx.emit(.jump_if_false, .{ .index = 0 });

    // True path: condition met — restore and exit
    try ctx.emit(.restore_input, .{ .none = {} });

    // jump -> loop_done (placeholder)
    const jmp_done_pos = ctx.raw.items.len;
    try ctx.emit(.jump, .{ .index = 0 });

    // loop_body:
    const loop_body: u32 = @intCast(ctx.raw.items.len);
    ctx.raw.items[jif_pos].operand = .{ .index = loop_body };

    // restore_input (false path)
    try ctx.emit(.restore_input, .{ .none = {} });

    // <update>
    try parsePipe(ctx);

    // expect ')'
    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // pipe — transfer result to current
    try ctx.emit(.pipe, .{ .none = {} });

    // jump -> loop_top
    try ctx.emit(.jump, .{ .index = loop_top });

    // loop_done:
    const loop_done: u32 = @intCast(ctx.raw.items.len);
    ctx.raw.items[jmp_done_pos].operand = .{ .index = loop_done };

    // push_current — make the final value available on the value stack
    try ctx.emit(.push_current, .{ .none = {} });
}

/// Compile `repeat(f)` — apply f infinitely, outputting each result.
/// The loop is infinite; callers terminate it with `limit`, `first`, or `try-catch`.
///
/// Bytecode layout:
/// loop_top:
///   output                        ; emit current value
///   <f>                           ; apply f to current value
///   pipe                          ; transfer result to current
///   jump -> loop_top              ; infinite loop
fn compileRepeat(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // loop_top:
    const loop_top: u32 = @intCast(ctx.raw.items.len);

    // output — emit current value
    try ctx.emit(.yield_output, .{ .none = {} });

    // <f>
    try parsePipe(ctx);

    // expect ')'
    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // pipe — transfer result to current
    try ctx.emit(.pipe, .{ .none = {} });

    // jump -> loop_top
    try ctx.emit(.jump, .{ .index = loop_top });
}

/// Compile `reduce EXPR as $var (INIT; UPDATE)`.
///
/// Semantics: evaluate EXPR to produce a stream of values, then fold them
/// left-to-right with an accumulator starting at INIT.  For each element
/// $var, the UPDATE expression is evaluated with the current accumulator
/// as input and its output becomes the new accumulator.  The final
/// accumulator is the result.
///
/// Bytecode layout:
///   save_input                   # preserve original input for INIT
///   array_collect_start(ACE1)    # collect EXPR outputs
///   <EXPR>
///   output
///   ACE1: array_collect_end      # pushes collected array
///   capture_variable($arr)       # save in hidden variable
///   restore_input                # current = original input
///   <INIT>
///   capture_variable($acc)       # save init value
///   load_variable($arr)          # push collected array
///   pipe                         # current = collected array
///   array_collect_start(ACE2)    # inner collect drives loop
///   iterate                      # IterFrame over collected array
///   capture_variable($var)       # bind current element
///   load_variable($acc)          # push accumulator
///   pipe                         # current = accumulator
///   <UPDATE>
///   capture_variable($acc)       # save updated accumulator
///   output                       # triggers IterFrame advance
///   ACE2: array_collect_end      # throwaway array
///   pipe                         # discard throwaway
///   load_variable($acc)          # push final accumulator
///   pop_variable($var)
///   pop_variable($acc)
///   pop_variable($arr)
/// Compile `label $name | BODY`.
///
/// Bytecode layout:
///   label_begin(exit_ip)          — generates break token, pushes LabelFrame
///   capture_variable($name)       — stores break token in $name
///   pipe                          — begin body
///   <BODY>
///   exit_ip:                      — handleBreak jumps here on break
///
/// No label_end or pop_variable is emitted because iterate loops would
/// re-execute them on every pass, prematurely clearing the label frame
/// and break token variable.
fn compileLabel(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Consume `$name`
    const dollar = try ctx.nextToken();
    if (dollar.tag != .dollar) return ctx.syntaxErr(dollar.offset, dollar.len);
    const name_tok = try ctx.nextToken();
    if (!isVarNameToken(name_tok.tag)) return ctx.syntaxErr(name_tok.offset, name_tok.len);

    // Declare the label variable in a new scope
    try pushScope(ctx, ctx.alloc);
    const name_ref = try internStr(&ctx.intern, ctx.alloc, name_tok.slice(ctx.src));
    const var_id = try declareVariable(ctx, name_ref, ctx.alloc);

    // Register as a label variable so `break` can verify at compile time
    try ctx.label_var_ids.append(ctx.alloc, var_id);

    // label_begin(exit_ip) — exit_ip backpatched below
    const label_begin_ip = ctx.raw.items.len;
    try ctx.emit(.label_begin, .{ .index = 0 });

    // capture_variable($name) — store break token
    try ctx.emit(.capture_variable, .{ .index = var_id });

    // Consume `|`
    const pipe_tok = try ctx.nextToken();
    if (pipe_tok.tag != .pipe) return ctx.syntaxErr(pipe_tok.offset, pipe_tok.len);

    // pipe
    try ctx.emit(.pipe, .{ .none = {} });

    // <BODY>
    try parsePipe(ctx);

    // Backpatch label_begin's exit_ip to the instruction after the body.
    // We do NOT emit label_end or pop_variable here because when the body
    // contains iterators (.[], range, etc.), the iterate loop re-executes
    // all instructions from resume_ip through instructions.len. Emitting
    // label_end/pop_variable would cause them to fire on every iteration,
    // prematurely clearing the label frame and break token variable.
    // The label frame is cleaned up by handleBreak (on break) or left on
    // the stack (harmless — reset() clears everything between records).
    ctx.raw.items[label_begin_ip].operand = .{ .index = @intCast(ctx.raw.items.len) };

    popScope(ctx, ctx.alloc);
}

/// Compile `setpath(PATH; VALUE)`.
/// Emits: save_input, <PATH>, restore_input, save_input, <VALUE>, call_builtin(setpath)
/// VM pops value, pops path from value_stack, uses current (restored original) as base.
fn compileSetpath(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // Save original input, eval PATH
    try ctx.emit(.save_input, .{ .none = {} });
    try parsePipe(ctx);

    // Consume ';'
    const semi = try ctx.nextToken();
    if (semi.tag != .semicolon) return ctx.syntaxErr(semi.offset, semi.len);

    // Restore original input for VALUE eval
    try ctx.emit(.restore_input, .{ .none = {} });
    try ctx.emit(.save_input, .{ .none = {} });

    // Eval VALUE
    try parsePipe(ctx);

    // Consume ')'
    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // Restore original input as current for setpath
    try ctx.emit(.restore_input, .{ .none = {} });

    // call_builtin(setpath) — pops value and path from stack, uses current as base
    try ctx.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.setpath) });
}

/// Compile a two-arg math builtin: `pow(a;b)`, `atan2(y;x)`, etc.
/// Pattern: save_input, eval a, restore_input, save_input, eval b, restore_input, call_builtin
fn compileTwoArgMath(ctx: *Ctx, bid: types.BuiltinId) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // Save original input, eval first arg
    try ctx.emit(.save_input, .{ .none = {} });
    try parsePipe(ctx);

    // Consume ';'
    const semi = try ctx.nextToken();
    if (semi.tag != .semicolon) return ctx.syntaxErr(semi.offset, semi.len);

    // Restore original input for second arg eval
    try ctx.emit(.restore_input, .{ .none = {} });
    try ctx.emit(.save_input, .{ .none = {} });

    // Eval second arg
    try parsePipe(ctx);

    // Consume ')'
    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // Restore original input as current
    try ctx.emit(.restore_input, .{ .none = {} });

    // call_builtin — pops two args from stack
    try ctx.emit(.call_builtin, .{ .index = @intFromEnum(bid) });
}

/// Compile a three-arg math builtin: `fma(x;y;z)`.
fn compileThreeArgMath(ctx: *Ctx, bid: types.BuiltinId) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // Save original input, eval first arg
    try ctx.emit(.save_input, .{ .none = {} });
    try parsePipe(ctx);

    // Consume ';'
    var semi = try ctx.nextToken();
    if (semi.tag != .semicolon) return ctx.syntaxErr(semi.offset, semi.len);

    // Restore original input for second arg
    try ctx.emit(.restore_input, .{ .none = {} });
    try ctx.emit(.save_input, .{ .none = {} });
    try parsePipe(ctx);

    // Consume ';'
    semi = try ctx.nextToken();
    if (semi.tag != .semicolon) return ctx.syntaxErr(semi.offset, semi.len);

    // Restore original input for third arg
    try ctx.emit(.restore_input, .{ .none = {} });
    try ctx.emit(.save_input, .{ .none = {} });
    try parsePipe(ctx);

    // Consume ')'
    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    try ctx.emit(.restore_input, .{ .none = {} });
    try ctx.emit(.call_builtin, .{ .index = @intFromEnum(bid) });
}

/// Compile `map_values(f)`: for arrays [.[] | f], for objects {keys, mapped values}.
/// Desugar to: [.[] | f] for arrays, or .keys as $k | .values | map(f) | ... for objects
/// Actually simplest: same as map but uses map_values builtin to reconstruct with keys.
/// For now: emit as a filter-arg builtin like sort_by.
fn compileMapValues(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try compileFilterArgBuiltin(ctx, .map_values_);
}

/// Compile `isempty(f)`: returns true if f produces no outputs.
/// Desugar: `first(f | false, true) // true` — but simpler with a dedicated builtin.
/// We'll use: save_input, array_collect_start, <f>, output, array_collect_end,
/// call_builtin(isempty_) which checks if collected array is empty.
fn compileIsempty(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // Use limit(1;f) approach: collect into array, check if empty
    try ctx.emit(.save_input, .{ .none = {} });

    const start_pos = ctx.raw.items.len;
    try ctx.emit(.array_collect_start, .{ .index = 0 });

    try parsePipe(ctx);

    try ctx.emit(.yield_output, .{ .none = {} });

    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.emit(.array_collect_end, .{ .none = {} });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };

    try ctx.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.isempty_) });
}

/// Compile `debug(msg)` with an argument — just pass through current value (ignore arg).
fn compileDebugArg(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('
    try parsePipe(ctx);
    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);
    // Just pass through current value — debug is a no-op for now
    try ctx.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.debug_) });
}

/// Compile `halt_error(code)` with an argument.
fn compileHaltErrorArg(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('
    try parsePipe(ctx);
    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);
    try ctx.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.halt_error_) });
}

/// error(msg) — compile as: msg | pipe | error
/// Evaluates the message expression, makes it the current value, then errors.
fn compileErrorArg(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('
    try parsePipe(ctx);
    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);
    try ctx.emit(.pipe, .{ .none = {} });
    try ctx.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.error_) });
}

fn compileReduce(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Allocate hidden variable IDs: one to save original input, one for accumulator
    const saved_input_id = ctx.next_var_id;
    ctx.next_var_id += 1;
    const acc_id = ctx.next_var_id;
    ctx.next_var_id += 1;

    // Save original input into a variable (survives INIT generator backtracks,
    // unlike save_input/restore_input which uses if_stack).
    try ctx.emit(.push_current, .{ .none = {} });
    try ctx.emit(.capture_variable, .{ .index = saved_input_id });

    // <EXPR> — parsed with parseOr (stops before `as` keyword).
    // Compiled here (source order) but emitted into a temporary buffer,
    // then spliced into the final position after INIT.
    const expr_start = ctx.raw.items.len;
    try parseOr(ctx);
    const expr_end = ctx.raw.items.len;

    // Consume `as PATTERN`
    const as_tok = try ctx.nextToken();
    if (as_tok.tag != .as_kw) return ctx.syntaxErr(as_tok.offset, as_tok.len);

    // Declare pattern variables in a new scope
    try pushScope(ctx, ctx.alloc);
    const pattern = try scanAndDeclarePattern(ctx);

    // Consume `(`
    const lparen = try ctx.nextToken();
    if (lparen.tag != .lparen) return ctx.syntaxErr(lparen.offset, lparen.len);

    // Save the EXPR instructions and remove them from the raw stream.
    // They'll be re-inserted after INIT so the bytecode order is:
    // INIT → capture_acc → load_saved → pipe → fork → EXPR → loop body
    var expr_buf = std.ArrayList(RawInstr){};
    defer expr_buf.deinit(ctx.alloc);
    try expr_buf.appendSlice(ctx.alloc, ctx.raw.items[expr_start..expr_end]);
    ctx.raw.items.len = expr_start;

    // <INIT> — parsed with parsePipe
    try parsePipe(ctx);

    // capture_variable($acc) — save init value
    try ctx.emit(.capture_variable, .{ .index = acc_id });

    // Restore original input for EXPR via hidden variable
    try ctx.emit(.load_variable, .{ .index = saved_input_id });
    try ctx.emit(.pipe, .{ .none = {} });

    // fork L_done — sentinel: when EXPR exhausts, jump to L_done
    const fork_pos = ctx.raw.items.len;
    try ctx.emit(.fork, .{ .index = 0 }); // placeholder, backpatched below

    // <EXPR> — re-insert the saved EXPR instructions, adjusting internal IPs
    {
        const new_start = ctx.raw.items.len;
        const offset: i64 = @as(i64, @intCast(new_start)) - @as(i64, @intCast(expr_start));
        rebaseExprBuf(expr_buf.items, offset);
        try ctx.raw.appendSlice(ctx.alloc, expr_buf.items);
    }

    // Bind EXPR output to pattern variables. The EXPR result may be on
    // value_stack (e.g., -.[] pushes negated value) or as current (e.g., .[]
    // sets current directly). emitPatternCapture handles both via
    // capture_variable's fallback-to-current semantics.
    try emitPatternCapture(ctx, pattern);

    // load_variable($acc) — push accumulator
    try ctx.emit(.load_variable, .{ .index = acc_id });

    // pipe — current = accumulator
    try ctx.emit(.pipe, .{ .none = {} });

    // Consume `;`
    const semi = try ctx.nextToken();
    if (semi.tag != .semicolon) return ctx.syntaxErr(semi.offset, semi.len);

    // <UPDATE> — parsed with parsePipe
    try parsePipe(ctx);

    // capture_variable($acc) — save updated accumulator
    try ctx.emit(.capture_variable, .{ .index = acc_id });

    // backtrack — advance EXPR to next value (or exhaust → sentinel fires)
    try ctx.emit(.backtrack, .{ .none = {} });

    // Consume `)`
    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // L_done: backpatch fork target
    const l_done: u32 = @intCast(ctx.raw.items.len);
    ctx.raw.items[fork_pos].operand = .{ .index = l_done };

    // load_variable($acc) — push final accumulator as result
    try ctx.emit(.load_variable, .{ .index = acc_id });

    // Cleanup: pop pattern variables and $acc. $saved_input is intentionally
    // NOT popped — if INIT is a generator (e.g. 0,1), the comma fork
    // backtracks after pop_variables run, and load_variable($saved_input)
    // must still find the saved value on the second INIT pass.
    {
        var pvar_ids = std.ArrayList(u32){};
        defer pvar_ids.deinit(ctx.alloc);
        try collectPatternVarIds(pattern, &pvar_ids, ctx.alloc);
        var pi = pvar_ids.items.len;
        while (pi > 0) {
            pi -= 1;
            try ctx.emit(.pop_variable, .{ .index = pvar_ids.items[pi] });
        }
    }
    try ctx.emit(.pop_variable, .{ .index = acc_id });

    popScope(ctx, ctx.alloc);
}

/// Compile `foreach EXPR as $var (INIT; UPDATE)` (2-arg) or
/// `foreach EXPR as $var (INIT; UPDATE; EXTRACT)` (3-arg).
///
/// Semantics: for each value produced by EXPR, fold with accumulator
/// starting at INIT.  Output the accumulator (or EXTRACT applied to it)
/// after each UPDATE step.  INIT may itself be a generator; each init
/// value runs the full fold independently (via INIT's own fork mechanism).
///
/// Bytecode layout (2-arg form):
///   push_current
///   capture_variable($saved)     # save original input to variable
///   <INIT>
///   capture_variable($acc)
///   load_variable($saved)
///   pipe                         # current = original input
///   array_collect_start(ACE)     # collect foreach outputs
///   fork L_done                  # sentinel: EXPR exhaustion
///     <EXPR>                     # generators push their own forkpoints
///     push_current
///     emitPatternCapture($var)
///     load_variable($acc)
///     pipe
///     <UPDATE>
///     capture_variable($acc)
///     load_variable($acc)
///     yield_output               # buffer intermediate acc in ACE
///     backtrack                  # advance EXPR via fork stack
///   L_done:
///   ACE: array_collect_end       # build array of intermediate values
///   pipe
///   each                         # iterate as generator for downstream
///   pop vars
///
/// For 3-arg form, the output section becomes:
///     capture_variable($acc)
///     load_variable($acc)
///     pipe
///     <EXTRACT>
///     yield_output
///     backtrack
fn compileForeach(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Allocate hidden variable IDs: one to save original input, one for accumulator
    const saved_input_id = ctx.next_var_id;
    ctx.next_var_id += 1;
    const acc_id = ctx.next_var_id;
    ctx.next_var_id += 1;

    // Save original input into a variable (survives INIT generator backtracks,
    // unlike save_input/restore_input which uses if_stack).
    try ctx.emit(.push_current, .{ .none = {} });
    try ctx.emit(.capture_variable, .{ .index = saved_input_id });

    // <EXPR> — parsed with parseOr (stops before `as`).
    // Compiled here (source order) but saved to a buffer, then spliced
    // into the final position after INIT.
    const expr_start = ctx.raw.items.len;
    try parseOr(ctx);
    const expr_end = ctx.raw.items.len;

    // Consume `as PATTERN`
    const as_tok = try ctx.nextToken();
    if (as_tok.tag != .as_kw) return ctx.syntaxErr(as_tok.offset, as_tok.len);

    // Declare pattern variables in a new scope
    try pushScope(ctx, ctx.alloc);
    const pattern = try scanAndDeclarePattern(ctx);

    // Consume `(`
    const lparen = try ctx.nextToken();
    if (lparen.tag != .lparen) return ctx.syntaxErr(lparen.offset, lparen.len);

    // Save the EXPR instructions and remove them from the raw stream.
    var expr_buf = std.ArrayList(RawInstr){};
    defer expr_buf.deinit(ctx.alloc);
    try expr_buf.appendSlice(ctx.alloc, ctx.raw.items[expr_start..expr_end]);
    ctx.raw.items.len = expr_start;

    // <INIT> — parsed with parsePipe
    try parsePipe(ctx);

    // capture_variable($acc) — save init value
    try ctx.emit(.capture_variable, .{ .index = acc_id });

    // Restore original input for EXPR via hidden variable
    try ctx.emit(.load_variable, .{ .index = saved_input_id });
    try ctx.emit(.pipe, .{ .none = {} });

    // Consume `;`
    const semi = try ctx.nextToken();
    if (semi.tag != .semicolon) return ctx.syntaxErr(semi.offset, semi.len);

    // array_collect_start(ACE) — collect foreach intermediate outputs
    const ace_start = ctx.raw.items.len;
    try ctx.emit(.array_collect_start, .{ .index = 0 });

    // fork L_done — sentinel: when EXPR exhausts, jump to L_done
    const fork_pos = ctx.raw.items.len;
    try ctx.emit(.fork, .{ .index = 0 }); // placeholder, backpatched below

    // <EXPR> — re-insert the saved EXPR instructions, adjusting internal IPs
    {
        const new_start = ctx.raw.items.len;
        const offset: i64 = @as(i64, @intCast(new_start)) - @as(i64, @intCast(expr_start));
        rebaseExprBuf(expr_buf.items, offset);
        try ctx.raw.appendSlice(ctx.alloc, expr_buf.items);
    }

    // Bind EXPR output to pattern variables (no push_current — the EXPR
    // result may be on value_stack or as current; emitPatternCapture handles both).
    try emitPatternCapture(ctx, pattern);

    // load_variable($acc) — push accumulator
    try ctx.emit(.load_variable, .{ .index = acc_id });

    // pipe — current = accumulator
    try ctx.emit(.pipe, .{ .none = {} });

    // <UPDATE> — parsed with parsePipe
    try parsePipe(ctx);

    // capture_variable($acc) — save updated accumulator
    try ctx.emit(.capture_variable, .{ .index = acc_id });

    // Check for 3-arg form (`;` EXTRACT) or 2-arg form (`)`)
    const after_update = try ctx.lex.peek();
    if (after_update.tag == .semicolon) {
        // 3-arg form: consume `;` and parse EXTRACT
        _ = try ctx.nextToken();

        // load_variable($acc)
        try ctx.emit(.load_variable, .{ .index = acc_id });

        // pipe
        try ctx.emit(.pipe, .{ .none = {} });

        // <EXTRACT>
        try parsePipe(ctx);

        // yield_output -> ACE buffer
        try ctx.emit(.yield_output, .{ .none = {} });
    } else {
        // 2-arg form: output accumulator directly
        try ctx.emit(.load_variable, .{ .index = acc_id });

        // yield_output -> ACE buffer
        try ctx.emit(.yield_output, .{ .none = {} });
    }

    // backtrack — advance EXPR to next value (or exhaust → sentinel fires)
    try ctx.emit(.backtrack, .{ .none = {} });

    // Consume `)`
    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // L_done: backpatch fork target
    const l_done: u32 = @intCast(ctx.raw.items.len);
    ctx.raw.items[fork_pos].operand = .{ .index = l_done };

    // ACE: array_collect_end — build array of intermediate values
    const ace_end: u32 = @intCast(ctx.raw.items.len);
    try ctx.emit(.array_collect_end, .{ .none = {} });
    ctx.raw.items[ace_start].operand = .{ .index = ace_end };

    // pipe — current = collected outputs array
    try ctx.emit(.pipe, .{ .none = {} });

    // Cleanup: pop pattern variables and $acc BEFORE the `each` generator,
    // so they're only cleared once (not per-element). $saved_input is
    // intentionally NOT popped — if INIT is a generator, the comma fork
    // backtracks after `each` exhausts and needs $saved_input intact.
    {
        var pvar_ids = std.ArrayList(u32){};
        defer pvar_ids.deinit(ctx.alloc);
        try collectPatternVarIds(pattern, &pvar_ids, ctx.alloc);
        var pi = pvar_ids.items.len;
        while (pi > 0) {
            pi -= 1;
            try ctx.emit(.pop_variable, .{ .index = pvar_ids.items[pi] });
        }
    }
    try ctx.emit(.pop_variable, .{ .index = acc_id });

    // each — iterate collected outputs as a generator for downstream
    try ctx.emit(.each, .{ .none = {} });

    popScope(ctx, ctx.alloc);
}

/// Compile `has(expr)`: supports generator expressions (commas) in arg.
fn compileHas(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try compileValueArgBuiltin1(ctx, .has);
}

/// Compile `in(expr)`: save_input, compile expr (pushes object), call_builtin(in_).
fn compileIn(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // in(expr) needs save_input before arg, so handle commas manually
    const chain_start: usize = ctx.raw.items.len;
    try ctx.emit(.save_input, .{ .none = {} });
    try parseAlternative(ctx);

    while (true) {
        const t = try ctx.lex.peek();
        if (t.tag != .comma) break;
        _ = try ctx.nextToken(); // consume ','

        // Insert save_input before the entire left subtree
        try insertRawInstr(ctx, chain_start, RawInstr{ .op = .save_input, .operand = .{ .none = {} } });

        // Emit call_builtin for the left side
        try ctx.emit(
            .call_builtin,
            .{ .index = @intFromEnum(types.BuiltinId.in_) },
        );
        try ctx.emit(.yield_output, .{ .none = {} });
        try ctx.emit(.restore_input, .{ .none = {} });

        // For next alternative, save_input again
        try ctx.emit(.save_input, .{ .none = {} });
        try parseAlternative(ctx);
    }

    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);
    try ctx.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.in_) },
    );
}

/// Compile `range(n)`, `range(from;to)`, or `range(from;to;by)`.
/// Supports generator expressions (commas) in all argument positions.
/// - range(3,5) → range(3), then range(5) → outputs 0,1,2,0,1,2,3,4
/// - range(0,1;3,4) → Cartesian product: range(0;3), range(0;4), range(1;3), range(1;4)
fn compileRange(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Don't consume '(' here — dispatch handles it

    // Peek ahead to check if this is single-arg (no semicolons)
    // We need to speculatively parse the first arg, then check for ';' or ')'
    // For single-arg, use compileValueArgBuiltin1 which handles commas manually
    // For multi-arg, use parseArgToArray for Cartesian product

    // Save lexer state to detect form
    const saved_lex = ctx.lex;
    const saved_raw_len = ctx.raw.items.len;

    // Parse with a simple lookahead: skip tokens until we find ';' or ')' at depth 0
    var depth: u32 = 1; // We consumed '(' already by the caller... wait, no
    // Actually the caller dispatches here and we consume '(' below
    _ = try ctx.nextToken(); // consume '('
    depth = 1;

    // Lookahead: scan to find whether first arg ends with ';' or ')'
    const lex_after_lparen = ctx.lex;
    var has_semicolon = false;
    blk: while (true) {
        const tok = try ctx.nextToken();
        switch (tok.tag) {
            .lparen, .lbracket, .lbrace => depth += 1,
            .rparen => {
                depth -= 1;
                if (depth == 0) break :blk;
            },
            .rbracket, .rbrace => {
                if (depth > 1) depth -= 1;
            },
            .semicolon => {
                if (depth == 1) {
                    has_semicolon = true;
                    break :blk;
                }
            },
            .eof => return ctx.syntaxErr(ctx.last_tok_offset, 0),
            else => {},
        }
    }

    // Restore lexer to just after '('
    ctx.lex = lex_after_lparen;
    ctx.raw.items.len = saved_raw_len;
    _ = saved_lex; // unused but documents intent

    if (!has_semicolon) {
        // Single-arg form: range(n)
        // Use parseArgToArray to collect all generator values, then range1_gen processes them.
        // This handles both simple range(5) and generator range(3,5).
        try parseArgToArray(ctx);
        try ctx.emit(.pipe, .{ .none = {} });

        const rparen = try ctx.nextToken();
        if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

        // range1_gen returns a flat array of all range outputs; iterate to produce individual values
        try ctx.emit(
            .call_builtin,
            .{ .index = @intFromEnum(types.BuiltinId.range1_gen) },
        );
        try ctx.emit(.pipe, .{ .none = {} });
        try ctx.emit(.each, .{ .none = {} });
        return;
    }

    // Multi-arg form: collect each arg into an array for Cartesian product
    // Parse first arg into array
    try parseArgToArray(ctx);
    try ctx.emit(.pipe, .{ .none = {} });

    // Save first array
    try ctx.emit(.save_input, .{ .none = {} });

    const s1 = try ctx.nextToken(); // consume ';'
    if (s1.tag != .semicolon) return ctx.syntaxErr(s1.offset, s1.len);

    // Parse second arg into array
    try parseArgToArray(ctx);
    try ctx.emit(.pipe, .{ .none = {} });

    // Check for third arg
    const t2 = try ctx.lex.peek();
    if (t2.tag == .rparen) {
        _ = try ctx.nextToken();
        // 2-arg form: call_builtin(range2_gen) with [from_array] on if_stack, [to_array] as current
        // Returns a flat array of all results; iterate to produce individual values
        try ctx.emit(
            .call_builtin,
            .{ .index = @intFromEnum(types.BuiltinId.range2_gen) },
        );
        try ctx.emit(.pipe, .{ .none = {} });
        try ctx.emit(.each, .{ .none = {} });
        return;
    }
    if (t2.tag != .semicolon) return ctx.syntaxErr(t2.offset, t2.len);
    _ = try ctx.nextToken(); // consume ';'

    // Save second array
    try ctx.emit(.save_input, .{ .none = {} });

    // Parse third arg into array
    try parseArgToArray(ctx);
    try ctx.emit(.pipe, .{ .none = {} });

    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // 3-arg form: call_builtin(range3_gen) with [from_array, to_array] on if_stack, [by_array] as current
    // Returns a flat array of all results; iterate to produce individual values
    try ctx.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.range3_gen) },
    );
    try ctx.emit(.pipe, .{ .none = {} });
    try ctx.emit(.each, .{ .none = {} });
}

// ── Tier 2 arg-taking builtins ──────────────────────────────────────────────

/// Compile `flatten(n)`: supports generator expressions (commas) in arg.
/// `flatten(3,2,1)` → flatten(3), then flatten(2), then flatten(1) → three outputs
fn compileFlattenN(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try compileValueArgBuiltin1(ctx, .flatten_n);
}

/// Compile `contains(b)`: supports generator expressions (commas) in arg.
fn compileContains(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try compileValueArgBuiltin1(ctx, .contains);
}

/// Compile `inside(b)`: supports generator expressions (commas) in arg.
fn compileInside(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try compileValueArgBuiltin1(ctx, .inside);
}

/// Compile `indices(s)`: supports generator expressions (commas) in arg.
fn compileIndices(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try compileValueArgBuiltin1(ctx, .indices);
}

/// Compile `index(s)`: supports generator expressions (commas) in arg.
fn compileIndex(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try compileValueArgBuiltin1(ctx, .index_);
}

/// Compile `rindex(s)`: supports generator expressions (commas) in arg.
fn compileRindex(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try compileValueArgBuiltin1(ctx, .rindex);
}

/// Compile filter-arg builtins (sort_by, group_by, min_by, max_by, unique_by).
/// Pattern: save_input, array_collect_start, iterate, <f>, output, array_collect_end, call_builtin(X)
fn compileFilterArgBuiltin(ctx: *Ctx, bid: types.BuiltinId) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // Save original array so we can pair elements with keys
    try ctx.emit(.save_input, .{ .none = {} });

    // Collect keys: [.[] | f]
    const start_pos = ctx.raw.items.len;
    try ctx.emit(.array_collect_start, .{ .index = 0 });
    try ctx.emit(.each, .{ .none = {} });

    // Parse the filter expression (use parsePipe to support commas/pipes in filter args)
    try parsePipe(ctx);

    try ctx.emit(.yield_output, .{ .none = {} });

    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // array_collect_end
    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.emit(.array_collect_end, .{ .none = {} });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };

    // call_builtin — pops keys array from value_stack, original array from if_stack
    try ctx.emit(
        .call_builtin,
        .{ .index = @intFromEnum(bid) },
    );
}

/// Compile `with_entries(f)`: desugar to `to_entries | map(f) | from_entries`.
fn compileWithEntries(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // to_entries
    try ctx.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.to_entries) },
    );
    try ctx.emit(.pipe, .{ .none = {} });

    // map(f): array_collect_start, iterate, <f>, output, array_collect_end
    const start_pos = ctx.raw.items.len;
    try ctx.emit(.array_collect_start, .{ .index = 0 });
    try ctx.emit(.each, .{ .none = {} });

    // Parse the filter expression (use parsePipe to support commas/pipes in filter args)
    try parsePipe(ctx);

    try ctx.emit(.yield_output, .{ .none = {} });

    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.emit(.array_collect_end, .{ .none = {} });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };

    // from_entries
    try ctx.emit(.pipe, .{ .none = {} });
    try ctx.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.from_entries) },
    );
}

/// Compile `any(f)` or `all(f)` with 1 or 2 args.
/// 1 arg: desugar to `[.[] | f] | any/all`
/// 2 args: desugar to `[gen | cond] | any/all`
fn compileAnyAll(ctx: *Ctx, bid: types.BuiltinId) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // Collect outputs: array_collect_start
    const start_pos = ctx.raw.items.len;
    try ctx.emit(.array_collect_start, .{ .index = 0 });

    // Parse first arg using parsePipe (supports commas/pipes, e.g., $dot[])
    try parsePipe(ctx);

    // Check for semicolon (2-arg form: any(gen;cond))
    const semi = try ctx.lex.peek();
    if (semi.tag == .semicolon) {
        _ = try ctx.nextToken(); // consume ';'
        // First arg was the generator. Pipe into it, then parse cond.
        try ctx.emit(.pipe, .{ .none = {} });
        try parsePipe(ctx);
    } else {
        // 1-arg form: desugar to [.[] | f]
        // We need to insert iterate before the filter. Use insertRawInstr.
        // Actually, we need: iterate, <f>. The filter is already emitted.
        // Insert iterate before the filter.
        try insertRawInstr(ctx, start_pos + 1, RawInstr{ .op = .each, .operand = .{ .none = {} } });
    }

    try ctx.emit(.yield_output, .{ .none = {} });

    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // array_collect_end
    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.emit(.array_collect_end, .{ .none = {} });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };

    // pipe + call any/all
    try ctx.emit(.pipe, .{ .none = {} });
    try ctx.emit(
        .call_builtin,
        .{ .index = @intFromEnum(bid) },
    );
}

/// Compile `first(f)`: desugar to `[f] | .[0]`.
/// Actually, more efficient: just collect first output. For now, use `[f] | .[0]`.
fn compileFirst(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Desugar first(f) to limit(1; f) — stops after first output, doesn't evaluate rest.
    _ = try ctx.nextToken(); // consume '('

    // Push n=1 for limit_start.
    try ctx.emit(.push_int, .{ .int = 1 });

    // limit_start: pops n from value_stack, sets up streaming counter.
    const limit_ip: u32 = @intCast(ctx.raw.items.len);
    try ctx.emit(.limit_start, .{ .index = 0 }); // backpatch exit_ip

    // Parse body expression f.
    try parsePipe(ctx);

    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // Emit output inside the limit scope.
    try ctx.emit(.yield_output, .{ .none = {} });

    // exit_ip points past the inner output (end of the limit scope).
    ctx.raw.items[limit_ip].operand = .{ .index = @intCast(ctx.raw.items.len) };
}

/// Compile `last(f)`: desugar to `[f] | .[-1]`.
fn compileLast(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // Collect [f]
    const start_pos = ctx.raw.items.len;
    try ctx.emit(.array_collect_start, .{ .index = 0 });

    try parsePipe(ctx);

    try ctx.emit(.yield_output, .{ .none = {} });

    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.emit(.array_collect_end, .{ .none = {} });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };

    // .[-1]
    try ctx.emit(.pipe, .{ .none = {} });
    try ctx.emit(.load_index, .{ .index = -1 });
}

/// Compile `limit(n;f)`: streaming implementation using limit_start/limit_end opcodes.
/// `limit(5,7; range(9))` → first 5 of range(9), then first 7 of range(9)
/// Each n value sets up a streaming limit scope that counts outputs and stops early.
fn compileLimit(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // Save original input to a variable
    const input_var = ctx.next_var_id;
    ctx.next_var_id += 1;
    try pushScope(ctx, ctx.alloc);
    try ctx.emit(.push_current, .{ .none = {} });
    try ctx.emit(.capture_variable, .{ .index = input_var });

    // Collect n values into array (handles generators like 5,7)
    try parseArgToArray(ctx);
    try ctx.emit(.pipe, .{ .none = {} });

    // Iterate over n values
    try ctx.emit(.each, .{ .none = {} });

    // Push current n to value_stack for limit_start
    try ctx.emit(.push_current, .{ .none = {} });
    // Set current to original input for body evaluation
    try ctx.emit(.load_variable, .{ .index = input_var });
    try ctx.emit(.pipe, .{ .none = {} });

    const semi = try ctx.nextToken();
    if (semi.tag != .semicolon) return ctx.syntaxErr(semi.offset, semi.len);

    // limit_start: pops n from value_stack, sets up streaming counter
    const limit_ip: u32 = @intCast(ctx.raw.items.len);
    try ctx.emit(.limit_start, .{ .index = 0 }); // backpatch exit_ip

    // Parse body expression f
    try parsePipe(ctx);

    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    // Emit output inside the limit scope — the limit counter in the output handler
    // will decrement for each value and stop evaluation when exhausted.
    try ctx.emit(.yield_output, .{ .none = {} });

    // exit_ip points past the inner output (end of the limit scope).
    // Used by limit_start for n=0 (skip body) and by the output handler
    // for scope membership checks.
    ctx.raw.items[limit_ip].operand = .{ .index = @intCast(ctx.raw.items.len) };

    popScope(ctx, ctx.alloc);
}

/// Compile `del(.key)` or `del(.[n])`: static single-level path deletion.
fn compileDel(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.nextToken(); // consume '('

    // Parse the path expression inside del()
    const path_tok = try ctx.nextToken();
    if (path_tok.tag != .dot) return ctx.syntaxErr(path_tok.offset, path_tok.len);

    const next_tok = try ctx.lex.peek();
    switch (next_tok.tag) {
        .ident => {
            // del(.key) — push key string, call_builtin(del)
            const ident = try ctx.nextToken();
            const ref = try internStr(&ctx.intern, ctx.alloc, ident.slice(ctx.src));
            try ctx.emit(.push_string, .{ .str_ref = ref });
        },
        .lbracket => {
            // del(.[n]) or del(.["key"])
            _ = try ctx.nextToken(); // consume '['
            const inner = try ctx.lex.peek();
            switch (inner.tag) {
                .int_lit => {
                    const tok = try ctx.nextToken();
                    const n = std.fmt.parseInt(i64, tok.slice(ctx.src), 10) catch return ctx.syntaxErr(ctx.last_tok_offset, 0);
                    try ctx.emit(.push_int, .{ .int = n });
                },
                .string_lit => {
                    const tok = try ctx.nextToken();
                    const raw_str = tok.slice(ctx.src);
                    const content = raw_str[1 .. raw_str.len - 1];
                    const ref = try internDecodedStr(&ctx.intern, ctx.alloc, content);
                    try ctx.emit(.push_string, .{ .str_ref = ref });
                },
                .minus => {
                    _ = try ctx.nextToken(); // consume '-'
                    const num_tok = try ctx.nextToken();
                    if (num_tok.tag != .int_lit) return ctx.syntaxErr(num_tok.offset, num_tok.len);
                    const n = std.fmt.parseInt(i64, num_tok.slice(ctx.src), 10) catch return ctx.syntaxErr(ctx.last_tok_offset, 0);
                    try ctx.emit(.push_int, .{ .int = -n });
                },
                else => return ctx.syntaxErr(ctx.last_tok_offset, 0),
            }
            const close = try ctx.nextToken();
            if (close.tag != .rbracket) return ctx.syntaxErr(close.offset, close.len);
        },
        else => return ctx.syntaxErr(ctx.last_tok_offset, 0),
    }

    const rparen = try ctx.nextToken();
    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

    try ctx.emit(
        .call_builtin,
        .{ .index = @intFromEnum(types.BuiltinId.del) },
    );
}

/// Map a format name (after @) to its BuiltinId.
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

/// Compile string interpolation: "prefix\(expr)mid\(expr)suffix"
/// `first_part` is the raw content of the first string_part token (before first \().
/// `format_bid` is the optional format builtin to apply to each interpolated expression.
///
/// The generated bytecode:
///   push_string "prefix"       <- first literal segment
///   save_input                  <- save current for interpolated expression
///   <expr>                      <- interpolated expression (sees original input)
///   [call_builtin(format_bid)]  <- optional format conversion
///   call_builtin(tostring)      <- convert to string
///   add                         <- concatenate
///   restore_input               <- restore original input
///   push_string "mid"           <- next literal segment
///   add                         <- concatenate
///   ...repeat for more interpolations...
///   push_string "suffix"        <- final literal segment
///   add                         <- concatenate
fn compileStringInterpolation(ctx: *Ctx, first_part_raw: []const u8, format_bid: ?types.BuiltinId) (ZqError || error{OutOfMemory})!void {
    // Push the first literal segment
    const first_ref = try internDecodedStr(&ctx.intern, ctx.alloc, first_part_raw);
    try ctx.emit(.push_string, .{ .str_ref = first_ref });

    while (true) {
        // Save input so interpolated expression sees the enclosing context's input
        try ctx.emit(.save_input, .{ .none = {} });

        // Parse the interpolated expression (between \( and ))
        try parsePipe(ctx);

        // Transfer expression result from value stack to current
        try ctx.emit(.pipe, .{ .none = {} });

        // Apply format if present
        if (format_bid) |bid| {
            try ctx.emit(
                .call_builtin,
                .{ .index = @intFromEnum(bid) },
            );
            try ctx.emit(.pipe, .{ .none = {} });
        }

        // Convert to string
        try ctx.emit(
            .call_builtin,
            .{ .index = @intFromEnum(types.BuiltinId.tostring) },
        );

        // Concatenate with accumulated string
        try ctx.emit(.add, .{ .none = {} });

        // Consume the closing ')' of the interpolation
        const rparen = try ctx.nextToken();
        if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

        // Restore original input for the next segment
        try ctx.emit(.restore_input, .{ .none = {} });

        // Scan the tail of the string
        const tail = try ctx.lex.scanStringTail();

        if (tail.tag == .string_end) {
            // Final segment — push it and concatenate
            const tail_raw = ctx.src[tail.offset..][0..tail.len];
            if (tail_raw.len > 0) {
                const tail_ref = try internDecodedStr(&ctx.intern, ctx.alloc, tail_raw);
                try ctx.emit(.push_string, .{ .str_ref = tail_ref });
                try ctx.emit(.add, .{ .none = {} });
            }
            break;
        } else if (tail.tag == .string_part) {
            // Mid segment — push it and concatenate, then continue loop
            const mid_raw = ctx.src[tail.offset..][0..tail.len];
            if (mid_raw.len > 0) {
                const mid_ref = try internDecodedStr(&ctx.intern, ctx.alloc, mid_raw);
                try ctx.emit(.push_string, .{ .str_ref = mid_ref });
                try ctx.emit(.add, .{ .none = {} });
            }
            // Continue to parse next interpolation
        } else {
            return ctx.syntaxErr(ctx.last_tok_offset, 0);
        }
    }
}

/// parsePrimary: literals, identifiers (with .field, [index]), `(` expr `)`, `$var`, `def name:`, `func(...)`
fn parsePrimary(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const start = ctx.raw.items.len;
    try parsePrimaryInner(ctx);
    // Postfix ? operator: wraps the preceding primary expression in fork_try/pop_try
    while (true) {
        const peek = try ctx.lex.peek();
        if (peek.tag != .question) break;
        _ = try ctx.nextToken();
        try insertRawInstr(ctx, start, .{ .op = .fork_try, .operand = .{ .index = 0 }, .src_offset = ctx.last_tok_offset });
        try ctx.emit(.pop_try, .{ .none = {} });
    }
}

fn parsePrimaryInner(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const t = try ctx.nextToken();
    switch (t.tag) {
        .true_kw => {
            try ctx.emit(.push_bool, .{ .bool = true });
        },
        .false_kw => {
            try ctx.emit(.push_bool, .{ .bool = false });
        },
        .string_lit => {
            const raw_str = t.slice(ctx.src);
            // Strip surrounding double-quotes, then decode JSON escape sequences.
            const content = raw_str[1 .. raw_str.len - 1];
            const ref = try internDecodedStr(&ctx.intern, ctx.alloc, content);
            try ctx.emit(.push_string, .{ .str_ref = ref });
        },
        .int_lit => {
            const n = std.fmt.parseInt(i64, t.slice(ctx.src), 10) catch return ctx.syntaxErr(ctx.last_tok_offset, 0);
            try ctx.emit(.push_int, .{ .int = n });
        },
        .float_lit => {
            const f = std.fmt.parseFloat(f64, t.slice(ctx.src)) catch return ctx.syntaxErr(ctx.last_tok_offset, 0);
            try ctx.emit(.push_float, .{ .float = f });
        },
        .minus => {
            // Unary minus as a primary expression (e.g. catch -1, or -1 in object values).
            try parsePrimary(ctx);
            try ctx.emit(.negate, .{ .none = {} });
        },
        .ident => {
            const ident_name = t.slice(ctx.src);
            const peek = try ctx.lex.peek();

            // `null` is a soft keyword: emit push_null when used as a standalone value.
            if (std.mem.eql(u8, ident_name, "null")) {
                try ctx.emit(.push_null, .{ .none = {} });
                return;
            }

            // `foreach` is not a lexer keyword — dispatch by ident name.
            if (std.mem.eql(u8, ident_name, "foreach")) {
                try compileForeach(ctx);
                return;
            }

            // Builtins that can be zero-arg OR one-arg: check for '(' first.
            // If followed by '(', fall through to arg-builtin dispatch.
            // BUT: user-defined functions shadow builtins when called with matching arity.
            if (peek.tag == .lparen and isArgBuiltin(ident_name)) {
                // Will be handled by the arg-builtin dispatch below
            } else if (peek.tag == .lparen and zeroArgBuiltinId(ident_name) != null) {
                // A zero-arg builtin followed by '(' — could be chaining (e.g., `add(...)`)
                // OR a user-defined function call shadowing the builtin.
                // Check for user-defined function first (jq allows shadowing builtins).
                const maybe_name_ref = try internStr(&ctx.intern, ctx.alloc, ident_name);
                // Quick arity scan
                const sp = ctx.lex.pos;
                _ = try ctx.lex.next(); // skip '('
                var sc: u8 = 0;
                var pd: u32 = 1;
                var hc = false;
                while (pd > 0) {
                    const tok = try ctx.lex.next();
                    switch (tok.tag) {
                        .lparen => pd += 1,
                        .rparen => pd -= 1,
                        .semicolon => {
                            if (pd == 1) sc += 1;
                            hc = true;
                        },
                        .eof => break,
                        else => hc = true,
                    }
                }
                const ac: u8 = if (hc) sc + 1 else 0;
                ctx.lex.pos = sp;
                if (lookupFunction(ctx, maybe_name_ref, ac) != null) {
                    // User function shadows the builtin — fall through to user function dispatch below.
                } else {
                    // No user function — treat as zero-arg builtin (the `(` is chaining).
                    const bid = zeroArgBuiltinId(ident_name).?;
                    const start = ctx.raw.items.len;
                    try ctx.emit(.call_builtin, .{ .index = @intFromEnum(bid) });
                    try parseSuffixes(ctx, start);
                    return;
                }
            } else if (zeroArgBuiltinId(ident_name)) |bid| {
                // Zero-arg builtins: length, keys, values, type, empty, tostring, tonumber, error, add, keys_unsorted
                // These do NOT consume parens even if followed by '(' (which would be chaining).
                const start = ctx.raw.items.len;
                try ctx.emit(
                    .call_builtin,
                    .{ .index = @intFromEnum(bid) },
                );
                try parseSuffixes(ctx, start);
                return;
            }

            // Arg-taking builtins: require '(' and consume it
            if (peek.tag == .lparen and isArgBuiltin(ident_name)) {
                if (std.mem.eql(u8, ident_name, "map")) {
                    try compileMap(ctx);
                } else if (std.mem.eql(u8, ident_name, "select")) {
                    try compileSelect(ctx);
                } else if (std.mem.eql(u8, ident_name, "has")) {
                    try compileHas(ctx);
                } else if (std.mem.eql(u8, ident_name, "in")) {
                    try compileIn(ctx);
                } else if (std.mem.eql(u8, ident_name, "range")) {
                    try compileRange(ctx);
                } else if (std.mem.eql(u8, ident_name, "flatten")) {
                    try compileFlattenN(ctx);
                } else if (std.mem.eql(u8, ident_name, "contains")) {
                    try compileContains(ctx);
                } else if (std.mem.eql(u8, ident_name, "inside")) {
                    try compileInside(ctx);
                } else if (std.mem.eql(u8, ident_name, "indices")) {
                    try compileIndices(ctx);
                } else if (std.mem.eql(u8, ident_name, "index")) {
                    try compileIndex(ctx);
                } else if (std.mem.eql(u8, ident_name, "rindex")) {
                    try compileRindex(ctx);
                } else if (std.mem.eql(u8, ident_name, "sort_by")) {
                    try compileFilterArgBuiltin(ctx, .sort_by);
                } else if (std.mem.eql(u8, ident_name, "group_by")) {
                    try compileFilterArgBuiltin(ctx, .group_by);
                } else if (std.mem.eql(u8, ident_name, "min_by")) {
                    try compileFilterArgBuiltin(ctx, .min_by);
                } else if (std.mem.eql(u8, ident_name, "max_by")) {
                    try compileFilterArgBuiltin(ctx, .max_by);
                } else if (std.mem.eql(u8, ident_name, "unique_by")) {
                    try compileFilterArgBuiltin(ctx, .unique_by);
                } else if (std.mem.eql(u8, ident_name, "with_entries")) {
                    try compileWithEntries(ctx);
                } else if (std.mem.eql(u8, ident_name, "any")) {
                    try compileAnyAll(ctx, .any);
                } else if (std.mem.eql(u8, ident_name, "all")) {
                    try compileAnyAll(ctx, .all);
                } else if (std.mem.eql(u8, ident_name, "first")) {
                    try compileFirst(ctx);
                } else if (std.mem.eql(u8, ident_name, "last")) {
                    try compileLast(ctx);
                } else if (std.mem.eql(u8, ident_name, "limit")) {
                    try compileLimit(ctx);
                } else if (std.mem.eql(u8, ident_name, "del")) {
                    try compileDel(ctx);
                } else if (std.mem.eql(u8, ident_name, "while")) {
                    try compileWhile(ctx);
                } else if (std.mem.eql(u8, ident_name, "until")) {
                    try compileUntil(ctx);
                } else if (std.mem.eql(u8, ident_name, "repeat")) {
                    try compileRepeat(ctx);
                } else if (std.mem.eql(u8, ident_name, "getpath")) {
                    try compileValueArgBuiltin1(ctx, .getpath);
                } else if (std.mem.eql(u8, ident_name, "setpath")) {
                    try compileSetpath(ctx);
                } else if (std.mem.eql(u8, ident_name, "delpaths")) {
                    try compileValueArgBuiltin1(ctx, .delpaths);
                } else if (std.mem.eql(u8, ident_name, "pow")) {
                    try compileTwoArgMath(ctx, .pow_);
                } else if (std.mem.eql(u8, ident_name, "atan2")) {
                    try compileTwoArgMath(ctx, .atan2_);
                } else if (std.mem.eql(u8, ident_name, "remainder")) {
                    try compileTwoArgMath(ctx, .remainder_);
                } else if (std.mem.eql(u8, ident_name, "hypot")) {
                    try compileTwoArgMath(ctx, .hypot_);
                } else if (std.mem.eql(u8, ident_name, "scalb")) {
                    try compileTwoArgMath(ctx, .scalb_);
                } else if (std.mem.eql(u8, ident_name, "scalbln")) {
                    try compileTwoArgMath(ctx, .scalbln_);
                } else if (std.mem.eql(u8, ident_name, "ldexp")) {
                    try compileTwoArgMath(ctx, .ldexp_);
                } else if (std.mem.eql(u8, ident_name, "fma")) {
                    try compileThreeArgMath(ctx, .fma_);
                } else if (std.mem.eql(u8, ident_name, "drem")) {
                    try compileTwoArgMath(ctx, .drem_);
                } else if (std.mem.eql(u8, ident_name, "map_values")) {
                    try compileMapValues(ctx);
                } else if (std.mem.eql(u8, ident_name, "isempty")) {
                    try compileIsempty(ctx);
                } else if (std.mem.eql(u8, ident_name, "debug")) {
                    try compileDebugArg(ctx);
                } else if (std.mem.eql(u8, ident_name, "halt_error")) {
                    try compileHaltErrorArg(ctx);
                } else if (std.mem.eql(u8, ident_name, "split")) {
                    try compileValueArgBuiltin1(ctx, .split_);
                } else if (std.mem.eql(u8, ident_name, "join")) {
                    try compileValueArgBuiltin1(ctx, .join_);
                } else if (std.mem.eql(u8, ident_name, "startswith")) {
                    try compileValueArgBuiltin1(ctx, .startswith_);
                } else if (std.mem.eql(u8, ident_name, "endswith")) {
                    try compileValueArgBuiltin1(ctx, .endswith_);
                } else if (std.mem.eql(u8, ident_name, "ltrimstr")) {
                    try compileValueArgBuiltin1(ctx, .ltrimstr_);
                } else if (std.mem.eql(u8, ident_name, "rtrimstr")) {
                    try compileValueArgBuiltin1(ctx, .rtrimstr_);
                } else if (std.mem.eql(u8, ident_name, "trimstr")) {
                    try compileValueArgBuiltin1(ctx, .trimstr_);
                } else if (std.mem.eql(u8, ident_name, "strftime")) {
                    try compileValueArgBuiltin1(ctx, .strftime_);
                } else if (std.mem.eql(u8, ident_name, "strptime")) {
                    try compileValueArgBuiltin1(ctx, .strptime_);
                } else if (std.mem.eql(u8, ident_name, "strflocaltime")) {
                    try compileValueArgBuiltin1(ctx, .strflocaltime_);
                } else if (std.mem.eql(u8, ident_name, "test")) {
                    try compileValueArgBuiltin1(ctx, .test_);
                } else if (std.mem.eql(u8, ident_name, "match")) {
                    try compileValueArgBuiltin1(ctx, .match_);
                } else if (std.mem.eql(u8, ident_name, "sub")) {
                    try compileTwoArgMath(ctx, .sub_);
                } else if (std.mem.eql(u8, ident_name, "gsub")) {
                    try compileTwoArgMath(ctx, .gsub_);
                } else if (std.mem.eql(u8, ident_name, "bsearch")) {
                    try compileValueArgBuiltin1(ctx, .bsearch_);
                } else if (std.mem.eql(u8, ident_name, "error")) {
                    try compileErrorArg(ctx);
                }
                return;
            }

            // Zero-arg first/last: no parens needed
            if (std.mem.eql(u8, ident_name, "first")) {
                try ctx.emit(.load_index, .{ .index = 0 });
                return;
            }
            if (std.mem.eql(u8, ident_name, "last")) {
                try ctx.emit(.load_index, .{ .index = -1 });
                return;
            }

            // User-defined function call with arguments
            if (peek.tag == .lparen) {
                const name_ref = try internStr(&ctx.intern, ctx.alloc, ident_name);

                // Count arguments by scanning for `;` separators at paren depth 1.
                // arity = number of `;` + 1 (if any content), or 0 for empty `()`.
                const saved_pos = ctx.lex.pos;
                _ = try ctx.lex.next(); // skip '('
                var semicolons: u8 = 0;
                var paren_depth: u32 = 1;
                var has_content = false;
                while (paren_depth > 0) {
                    const scan = try ctx.lex.next();
                    switch (scan.tag) {
                        .lparen => paren_depth += 1,
                        .rparen => paren_depth -= 1,
                        .semicolon => {
                            if (paren_depth == 1) semicolons += 1;
                            has_content = true;
                        },
                        .eof => break,
                        else => has_content = true,
                    }
                }
                const arity_count: u8 = if (has_content) semicolons + 1 else 0;
                ctx.lex.pos = saved_pos;

                // When scanning a function body, don't expand calls — just parse
                // the arguments syntactically and emit a placeholder load_key.
                if (ctx.scanning_body) {
                    if (lookupFunction(ctx, name_ref, arity_count) != null) {
                        _ = try ctx.nextToken(); // consume '('
                        if (arity_count > 0) {
                            var ai: u8 = 0;
                            while (ai < arity_count) : (ai += 1) {
                                try parsePipe(ctx);
                                if (ai + 1 < arity_count) {
                                    const sep = try ctx.nextToken();
                                    if (sep.tag != .semicolon) return ctx.syntaxErr(sep.offset, sep.len);
                                }
                            }
                        }
                        const rp = try ctx.nextToken();
                        if (rp.tag != .rparen) return ctx.syntaxErr(rp.offset, rp.len);
                        // Emit placeholder — the actual expansion happens during reParseBodyWithBindings.
                        try ctx.emit(.load_key, .{ .str_ref = name_ref });
                        return;
                    }
                    // Not a known function — fall through to field access.
                    return ctx.syntaxErr(t.offset, t.len);
                }

                if (lookupFunction(ctx, name_ref, arity_count)) |func_idx| {
                    _ = try ctx.nextToken(); // consume '('
                    const func = &ctx.function_table.items[func_idx];

                    // Parse each argument into a CallArg.
                    // For filter args: save source position range for re-parsing.
                    // For value args: save pre-compiled instructions.
                    var call_args = std.ArrayList(CallArg){};
                    defer {
                        for (call_args.items) |ca| {
                            if (ca.instructions.len > 0) ctx.alloc.free(ca.instructions);
                        }
                        call_args.deinit(ctx.alloc);
                    }

                    if (arity_count > 0) {
                        var ai: u8 = 0;
                        while (ai < arity_count) : (ai += 1) {
                            const is_filter = if (ai < func.params.len) func.params[ai].is_filter else true;

                            if (is_filter) {
                                // Filter arg: record source positions, parse to validate
                                // and advance the lexer, then discard the instructions.
                                //
                                // Special case: if the arg is a single identifier that matches
                                // an active filter arg binding, propagate the original source
                                // range to avoid infinite re-parse loops in nested calls.
                                const src_start = ctx.lex.pos;
                                const raw_start: u32 = @intCast(ctx.raw.items.len);
                                try parsePipe(ctx);
                                const src_end = ctx.lex.pos;
                                ctx.raw.items.len = raw_start;

                                // Check if this arg is a simple filter arg pass-through.
                                var resolved_start = src_start;
                                var resolved_end = src_end;
                                if (resolveFilterArgPassthrough(ctx, src_start, src_end)) |binding| {
                                    resolved_start = binding.src_start;
                                    resolved_end = binding.src_end;
                                }

                                try call_args.append(ctx.alloc, CallArg{
                                    .src_start = resolved_start,
                                    .src_end = resolved_end,
                                    .instructions = &.{},
                                    .is_filter = true,
                                });
                            } else {
                                // Value arg: compile and keep the instructions
                                const raw_start: u32 = @intCast(ctx.raw.items.len);
                                try parsePipe(ctx);
                                const raw_end: u32 = @intCast(ctx.raw.items.len);

                                const arg_instrs = try ctx.alloc.dupe(RawInstr, ctx.raw.items[raw_start..raw_end]);
                                ctx.raw.items.len = raw_start;

                                try call_args.append(ctx.alloc, CallArg{
                                    .src_start = 0,
                                    .src_end = 0,
                                    .instructions = arg_instrs,
                                    .is_filter = false,
                                });
                            }

                            if (ai + 1 < arity_count) {
                                const sep_tok = try ctx.nextToken();
                                if (sep_tok.tag != .semicolon) return ctx.syntaxErr(sep_tok.offset, sep_tok.len);
                            }
                        }
                    }

                    const rparen = try ctx.nextToken();
                    if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);

                    try expandFunctionCall(ctx, func_idx, call_args.items);
                    return;
                }
                // Not a user function — fall through to field access.
                // (The `(` will be consumed as part of a different construct,
                // e.g. chaining. Actually, an unknown ident followed by ( is
                // a syntax error in jq if it's not a builtin or def.)
                return ctx.syntaxErr(t.offset, t.len);
            }

            // Check for active filter arg binding (used during function body re-parsing).
            // If matched, re-parse the arg's source range instead of emitting load_key.
            {
                var matched_binding = false;
                // Search bindings backward so innermost scope wins.
                var bk: usize = ctx.filter_arg_bindings.items.len;
                while (bk > 0) {
                    bk -= 1;
                    const binding = &ctx.filter_arg_bindings.items[bk];
                    const bname = ctx.intern.items[binding.name.offset..][0..binding.name.len];
                    if (std.mem.eql(u8, bname, ident_name)) {
                        // Re-parse the filter arg source range. Temporarily hide
                        // the matched binding and any bindings after it to prevent
                        // infinite recursion when the arg source contains identifiers
                        // that match these same bindings (e.g., id(x):x called with [x]).
                        const saved_bindings_len = ctx.filter_arg_bindings.items.len;
                        ctx.filter_arg_bindings.items.len = bk;
                        const saved_lex_pos = ctx.lex.pos;
                        ctx.lex.pos = binding.src_start;
                        try parsePipe(ctx);
                        ctx.lex.pos = saved_lex_pos;
                        ctx.filter_arg_bindings.items.len = saved_bindings_len;
                        matched_binding = true;
                        break;
                    }
                }
                if (matched_binding) return;
            }

            // Check for zero-arg user-defined function
            if (!ctx.scanning_body) {
                // First check: recursive self-call. The function being expanded may be
                // in the hidden range (lexical scoping), so check by name directly
                // before calling lookupFunction which respects the hidden range.
                if (ctx.expanding_recursive_func) |expanding_idx| {
                    const exp_func = &ctx.function_table.items[expanding_idx];
                    const exp_name = ctx.intern.items[exp_func.name.offset..][0..exp_func.name.len];
                    if (std.mem.eql(u8, exp_name, ident_name) and exp_func.paramCount() == 0) {
                        try ctx.emit(.call_function, .{ .index = @intCast(exp_func.recursive_body_ip) });
                        return;
                    }
                }

                const name_ref = try internStr(&ctx.intern, ctx.alloc, ident_name);
                if (lookupFunction(ctx, name_ref, 0)) |func_idx| {
                    // Zero-arg user function call — inline expand
                    const empty_args: []const CallArg = &.{};
                    try expandFunctionCall(ctx, func_idx, empty_args);
                    return;
                }
            }

            // Plain identifier → field access
            const ref = try internStr(&ctx.intern, ctx.alloc, ident_name);
            const start = ctx.raw.items.len;
            try ctx.emit(.load_key, .{ .str_ref = ref });
            try parseSuffixes(ctx, start);
        },
        .dot => {
            const after = try ctx.lex.peek();
            switch (after.tag) {
                .ident => {
                    _ = try ctx.nextToken();
                    const ref = try internStr(&ctx.intern, ctx.alloc, after.slice(ctx.src));
                    const start = ctx.raw.items.len;
                    try ctx.emit(.load_key, .{ .str_ref = ref });
                    try parseSuffixes(ctx, start);
                },
                .lbracket => {
                    _ = try ctx.nextToken();
                    const start = ctx.raw.items.len;
                    try parseBracket(ctx);
                    try parseSuffixes(ctx, start);
                },
                .string_lit => {
                    // ."foo" — quoted field access
                    _ = try ctx.nextToken();
                    const str_content = extractStringContent(after.slice(ctx.src));
                    const ref = try internStr(&ctx.intern, ctx.alloc, str_content);
                    const start = ctx.raw.items.len;
                    try ctx.emit(.load_key, .{ .str_ref = ref });
                    try parseSuffixes(ctx, start);
                },
                else => {
                    // Bare dot — push the current value onto the stack.
                    // Using push_current ensures the value is available for binary operators
                    // (arithmetic, comparison) regardless of evaluation order.
                    try ctx.emit(.push_current, .{ .none = {} });
                },
            }
        },
        .dot_dot => {
            // Recursive descent operator: .. equivalent to def recurse: ., (.[]? | recurse);
            try ctx.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.recurse) });
        },
        .lparen => {
            const paren_start = ctx.raw.items.len;
            try parsePipe(ctx);
            const close = try ctx.nextToken();
            if (close.tag != .rparen) return ctx.syntaxErr(close.offset, close.len);
            try parseSuffixes(ctx, paren_start);
        },
        .dollar => {
            // Variable reference: $var, possibly followed by suffixes like [], .field, [0]
            const var_start = ctx.raw.items.len;
            try parseVariableReference(ctx);
            try parseSuffixes(ctx, var_start);
        },
        .lbrace => {
            // Object literal
            const obj_start = ctx.raw.items.len;
            try parseObjectLiteral(ctx);
            try parseSuffixes(ctx, obj_start);
        },
        .if_kw => {
            // Conditional: if COND then THEN [elif COND then THEN]* [else ELSE] end
            const if_start = ctx.raw.items.len;
            try parseIfBody(ctx);
            try parseSuffixes(ctx, if_start);
        },
        .try_kw => {
            // try EXPR [catch EXPR]
            try parseTryCatch(ctx);
        },
        .lbracket => {
            // Array construction: [expr] — collect all outputs of expr into an array.
            const arr_start = ctx.raw.items.len;
            try parseArrayConstruct(ctx);
            try parseSuffixes(ctx, arr_start);
        },
        .at => {
            // Format string: @text, @json, @html "...\(...)...", etc.
            const fmt_ident = try ctx.nextToken();
            if (fmt_ident.tag != .ident) return ctx.syntaxErr(fmt_ident.offset, fmt_ident.len);
            const fmt_name = fmt_ident.slice(ctx.src);
            const bid = formatBuiltinId(fmt_name) orelse return ctx.syntaxErr(ctx.last_tok_offset, 0);

            // Check if followed by a string with interpolation (format string interpolation)
            const after = try ctx.lex.peek();
            if (after.tag == .string_part) {
                // Format string interpolation: @html "<b>\(.)</b>"
                const str_tok = try ctx.nextToken();
                const raw_content = ctx.src[str_tok.offset..][0..str_tok.len];
                try compileStringInterpolation(ctx, raw_content, bid);
            } else if (after.tag == .string_lit) {
                // Format with plain string (no interpolations) — just push the literal
                const str_tok = try ctx.nextToken();
                const raw_str = str_tok.slice(ctx.src);
                const content = raw_str[1 .. raw_str.len - 1];
                const ref = try internDecodedStr(&ctx.intern, ctx.alloc, content);
                try ctx.emit(.push_string, .{ .str_ref = ref });
            } else {
                // Standalone format: @text, @json, etc. — apply to current value
                try ctx.emit(
                    .call_builtin,
                    .{ .index = @intFromEnum(bid) },
                );
            }
        },
        .string_part => {
            // String interpolation without format: "hello \(.name)"
            const raw_content = ctx.src[t.offset..][0..t.len];
            try compileStringInterpolation(ctx, raw_content, null);
        },
        .reduce_kw => {
            try compileReduce(ctx);
        },
        .label_kw => {
            try compileLabel(ctx);
        },
        .break_kw => {
            // `break $name` — load break token and trigger non-local exit
            const dollar = try ctx.nextToken();
            if (dollar.tag != .dollar) return ctx.syntaxErr(dollar.offset, dollar.len);
            const name_tok = try ctx.nextToken();
            if (!isVarNameToken(name_tok.tag)) return ctx.syntaxErr(name_tok.offset, name_tok.len);
            const name_ref = try internStr(&ctx.intern, ctx.alloc, name_tok.slice(ctx.src));
            const var_id = lookupVariable(ctx, name_ref) orelse return ctx.syntaxErr(name_tok.offset, name_tok.len);
            // Verify this is a label variable, not a regular `as` binding
            var is_label_var = false;
            for (ctx.label_var_ids.items) |lid| {
                if (lid == var_id) {
                    is_label_var = true;
                    break;
                }
            }
            if (!is_label_var) return ctx.syntaxErr(name_tok.offset, name_tok.len);
            try ctx.emit(.load_variable, .{ .index = var_id });
            try ctx.emit(.break_op, .{ .none = {} });
        },
        .not_kw => {
            // `not` is a zero-arg builtin filter in jq (always postfix: `expr | not`)
            // When used as a standalone expression, it negates the current input.
            try ctx.emit(.not, .{ .none = {} });
        },
        else => return ctx.syntaxErr(ctx.last_tok_offset, 0),
    }
}

/// Parse a `try EXPR [catch EXPR]` expression (the `try` keyword has already been
/// consumed by parsePrimary).
///
/// jq semantics:
///   - `try EXPR`            — evaluate EXPR; if error, suppress (produce no output).
///   - `try EXPR catch HDLR` — evaluate EXPR; if error, evaluate HDLR with the error
///                             message (a string) as its input.
///
/// Both EXPR and HDLR are parsed at the "primary" level so that `try .foo | .bar`
/// correctly parses as `(try .foo) | .bar`, matching jq's term-level precedence.
///
/// Emits for `try EXPR` (no catch):
///   fork_try(0)              ← 0 = suppress on error
///   <EXPR>
///   pop_try
///
/// Emits for `try EXPR catch HDLR`:
///   fork_try(catch_ip)       ← push try_handler forkpoint
///   <EXPR>
///   pop_try                  ← remove try_handler from fork stack
///   jump L_past              ← skip handler
///   L_handler: <HDLR>        ← handler receives error string as `current`
///   L_past: (next instruction)
fn parseTryCatch(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Emit fork_try with placeholder catch_ip (backpatched if catch is present).
    const fork_try_pos = ctx.raw.items.len;
    try ctx.emit(.fork_try, .{ .index = 0 });

    // Parse the try body at primary level so that `|` is left to the outer pipe.
    try parsePrimary(ctx);

    const t = try ctx.lex.peek();
    if (t.tag == .catch_kw) {
        _ = try ctx.nextToken(); // consume 'catch'

        try ctx.emit(.pop_try, .{ .none = {} });

        // Emit jump with placeholder (backpatched after parsing handler).
        const jump_pos = ctx.raw.items.len;
        try ctx.emit(.jump, .{ .index = 0 });

        // Backpatch fork_try to point at the first instruction of the handler.
        const catch_ip: u32 = @intCast(ctx.raw.items.len);
        ctx.raw.items[fork_try_pos].operand = .{ .index = catch_ip };

        // Parse the catch handler at primary level.
        try parsePrimary(ctx);

        // Backpatch jump to past the handler.
        ctx.raw.items[jump_pos].operand = .{ .index = @intCast(ctx.raw.items.len) };
    } else {
        // No catch: suppress mode.
        try ctx.emit(.pop_try, .{ .none = {} });
    }
}

/// Parse the body of an `if` or `elif` expression (the `if`/`elif` keyword has
/// already been consumed by the caller).
///
/// Emits:
///   save_input
///   <COND>
///   jump_if_false → else-branch
///   restore_input
///   <THEN>
///   jump → end
///   restore_input   ← else-branch entry
///   (<ELSE> | parseIfBody for elif | identity for implicit else)
fn parseIfBody(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Save the current input so both branches can evaluate against it.
    try ctx.emit(.save_input, .{ .none = {} });

    // Parse condition (stops at 'then').
    try parsePipe(ctx);

    // Expect 'then'.
    const then_tok = try ctx.nextToken();
    if (then_tok.tag != .then_kw) return ctx.syntaxErr(then_tok.offset, then_tok.len);

    // Emit conditional jump with a placeholder target (backpatched below).
    const jif_pos = ctx.raw.items.len;
    try ctx.emit(.jump_if_false, .{ .index = 0 });

    // Restore input before the then-branch.
    try ctx.emit(.restore_input, .{ .none = {} });

    // Parse then-body (stops at elif/else/end).
    try parsePipe(ctx);

    // Unconditional jump to skip the else-branch (placeholder backpatched below).
    const jmp_pos = ctx.raw.items.len;
    try ctx.emit(.jump, .{ .index = 0 });

    // Backpatch jump_if_false to point here (start of else-branch).
    ctx.raw.items[jif_pos].operand = .{ .index = @intCast(ctx.raw.items.len) };

    // Restore input before the else-branch.
    try ctx.emit(.restore_input, .{ .none = {} });

    // Parse elif / else / end.
    const next_tok = try ctx.lex.peek();
    switch (next_tok.tag) {
        .elif_kw => {
            _ = try ctx.nextToken(); // consume 'elif'
            // Recursively compile the elif as a nested if body.
            try parseIfBody(ctx);
        },
        .else_kw => {
            _ = try ctx.nextToken(); // consume 'else'
            try parsePipe(ctx); // parse else-body
            const end_tok = try ctx.nextToken();
            if (end_tok.tag != .end_kw) return ctx.syntaxErr(end_tok.offset, end_tok.len);
        },
        .end_kw => {
            _ = try ctx.nextToken(); // consume 'end'
            // Implicit else: `.` — identity, passes current through.
            try ctx.emit(.identity, .{ .none = {} });
        },
        else => return ctx.syntaxErr(ctx.last_tok_offset, 0),
    }

    // Backpatch unconditional jump to point here (past the entire else block).
    ctx.raw.items[jmp_pos].operand = .{ .index = @intCast(ctx.raw.items.len) };
}

/// Parse an array construction expression: [expr] or [].
/// The opening `[` has already been consumed by parsePrimary.
///
/// Emits:
///   array_collect_start   operand.index = IP of array_collect_end
///   [<expr> output]       only when inner expression is non-empty
///   array_collect_end
///
/// The VM's output handler is intercepted in collect mode: instead of yielding
/// a value, it appends to the active collect frame and advances iteration.
/// array_collect_end finalizes the frame into an array Value.
fn parseArrayConstruct(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Emit array_collect_start with placeholder end_ip (backpatched below).
    const start_pos = ctx.raw.items.len;
    try ctx.emit(.array_collect_start, .{ .index = 0 });

    const peek = try ctx.lex.peek();
    if (peek.tag != .rbracket) {
        // Save input so each comma-separated expression sees the original value.
        try ctx.emit(.save_input, .{ .none = {} });
        try parsePipe(ctx);
        try ctx.emit(.yield_output, .{ .none = {} });
        while ((try ctx.lex.peek()).tag == .comma) {
            _ = try ctx.nextToken(); // consume comma
            try ctx.emit(.restore_input, .{ .none = {} });
            try ctx.emit(.save_input, .{ .none = {} });
            try parsePipe(ctx);
            try ctx.emit(.yield_output, .{ .none = {} });
        }
        try ctx.emit(.restore_input, .{ .none = {} });
    }

    // Consume the closing `]`.
    const close = try ctx.nextToken();
    if (close.tag != .rbracket) return ctx.syntaxErr(close.offset, close.len);

    // Emit array_collect_end and backpatch start.
    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.emit(.array_collect_end, .{ .none = {} });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };
}

/// Emit bytecode for $__loc__: constructs {"file":"<top-level>","line":N}.
/// tok_offset is the source offset of the `$__loc__` token (in full_src including prelude).
fn emitLocObject(ctx: *Ctx, tok_offset: u32) error{OutOfMemory}!void {
    // Compute 1-based line number in user source (excluding prelude).
    const user_offset: usize = if (tok_offset >= ctx.prelude_len)
        tok_offset - ctx.prelude_len
    else
        0;
    var line: i64 = 1;
    const user_src = ctx.src[ctx.prelude_len..];
    var i: usize = 0;
    while (i < @min(user_offset, user_src.len)) : (i += 1) {
        if (user_src[i] == '\n') line += 1;
    }
    try ctx.emit(.object_construct_start, .{ .none = {} });
    const file_key_ref = try internStr(&ctx.intern, ctx.alloc, "file");
    try ctx.emit(.push_string, .{ .str_ref = file_key_ref });
    const file_val_ref = try internStr(&ctx.intern, ctx.alloc, "<top-level>");
    try ctx.emit(.push_string, .{ .str_ref = file_val_ref });
    try ctx.emit(.object_key, .{ .none = {} });
    const line_key_ref = try internStr(&ctx.intern, ctx.alloc, "line");
    try ctx.emit(.push_string, .{ .str_ref = line_key_ref });
    try ctx.emit(.push_int, .{ .int = line });
    try ctx.emit(.object_key, .{ .none = {} });
    try ctx.emit(.object_construct_end, .{ .none = {} });
}

/// Parse a variable reference: $var
fn parseVariableReference(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const ident = try ctx.nextToken();
    if (!isVarNameToken(ident.tag)) return ctx.syntaxErr(ident.offset, ident.len);

    const name = ident.slice(ctx.src);
    if (std.mem.eql(u8, name, "__loc__")) {
        return try emitLocObject(ctx, ident.offset);
    }

    const name_ref = try internStr(&ctx.intern, ctx.alloc, name);
    const var_id = lookupVariable(ctx, name_ref) orelse return ctx.syntaxErr(ctx.last_tok_offset, 0);

    try ctx.emit(.load_variable, .{ .index = var_id });
}

/// Parse a function definition: def name(params): body
/// Parse a `def name(params): body; continuation` expression.
/// The `def` keyword has already been consumed by the caller.
///
/// Parses the function definition and registers it in the function table,
/// then parses the continuation expression (the code that follows the `;`).
/// The body is parsed into a separate instruction buffer, not the main stream.
fn parseFunctionDef(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Function name — accept identifiers AND keywords (jq allows `def if: ...`)
    const name_tok = try ctx.nextToken();
    if (!isVarNameToken(name_tok.tag) and name_tok.tag != .ident)
        return ctx.syntaxErr(name_tok.offset, name_tok.len);
    const name_ref = try internStr(&ctx.intern, ctx.alloc, name_tok.slice(ctx.src));

    // Parse optional parameters: (param1; param2; ...)
    // No parens = zero-arg function
    var params = std.ArrayList(ParamInfo){};
    defer params.deinit(ctx.alloc);

    const peek = try ctx.lex.peek();
    if (peek.tag == .lparen) {
        _ = try ctx.nextToken(); // consume '('
        while (true) {
            const ptok = try ctx.lex.peek();
            if (ptok.tag == .rparen) {
                _ = try ctx.nextToken();
                break;
            }

            if (ptok.tag == .dollar) {
                // Value parameter: $name
                _ = try ctx.nextToken(); // consume '$'
                const pname = try ctx.nextToken();
                if (!isVarNameToken(pname.tag)) return ctx.syntaxErr(pname.offset, pname.len);
                const pname_ref = try internStr(&ctx.intern, ctx.alloc, pname.slice(ctx.src));
                const var_id = ctx.next_var_id;
                ctx.next_var_id += 1;
                try params.append(ctx.alloc, ParamInfo{
                    .name = pname_ref,
                    .is_filter = false,
                    .var_id = var_id,
                });
            } else if (isVarNameToken(ptok.tag)) {
                // Filter parameter: name (no $)
                const pname = try ctx.nextToken();
                const pname_ref = try internStr(&ctx.intern, ctx.alloc, pname.slice(ctx.src));
                try params.append(ctx.alloc, ParamInfo{
                    .name = pname_ref,
                    .is_filter = true,
                    .var_id = 0, // unused for filter args
                });
            } else {
                return ctx.syntaxErr(ptok.offset, ptok.len);
            }

            // Check for ';' separator or ')' end
            const sep = try ctx.lex.peek();
            if (sep.tag == .semicolon) {
                _ = try ctx.nextToken();
            } else if (sep.tag != .rparen) {
                return ctx.syntaxErr(sep.offset, sep.len);
            }
        }
    }

    // Consume ':'
    const colon = try ctx.nextToken();
    if (colon.tag != .colon) return ctx.syntaxErr(colon.offset, colon.len);

    // Record the body source start (lexer position after ':').
    const body_src_start = ctx.lex.pos;

    // Parse body into a SEPARATE raw instruction buffer to:
    // 1. Advance the lexer past the body
    // 2. Detect recursion (for zero-arg functions)
    // 3. Store body_raw for recursive functions (needed for call_function)
    const saved_raw = ctx.raw;
    ctx.raw = std.ArrayList(RawInstr){};

    // Enable scanning mode: function calls in the body are parsed for syntax
    // but NOT expanded. This avoids infinite recursion when nested functions
    // share filter param names. Actual expansion happens via reParseBodyWithBindings.
    const saved_scanning_body = ctx.scanning_body;
    ctx.scanning_body = true;

    // Create a scope for the function body and declare parameters
    try pushScope(ctx, ctx.alloc);

    for (params.items) |*param| {
        if (param.is_filter) {
            const pvar_id = try declareVariable(ctx, param.name, ctx.alloc);
            param.var_id = pvar_id;
        } else {
            _ = try declareVariable(ctx, param.name, ctx.alloc);
        }
    }

    // Save function table length to detect inner defs that shadow this function.
    const func_table_start = ctx.function_table.items.len;

    // Parse the function body (use parseFilter to support nested defs)
    try parseFilter(ctx);

    // Record body source end position.
    const body_src_end = ctx.lex.pos;

    // Extract the body instructions
    var body_raw = ctx.raw;
    ctx.raw = saved_raw;

    // Restore scanning mode
    ctx.scanning_body = saved_scanning_body;

    // Pop the body scope
    popScope(ctx, ctx.alloc);

    // Post-process: replace filter param references with call_filter_arg.
    // This is only needed for recursive functions (which use body_raw directly).
    var processed_body = std.ArrayList(RawInstr){};
    defer processed_body.deinit(ctx.alloc);

    for (body_raw.items) |instr| {
        var replaced = false;
        if (instr.op == .load_key) {
            const key = ctx.intern.items[instr.operand.str_ref.offset..][0..instr.operand.str_ref.len];
            for (params.items, 0..) |param, pi| {
                if (param.is_filter) {
                    const pname = ctx.intern.items[param.name.offset..][0..param.name.len];
                    if (std.mem.eql(u8, key, pname)) {
                        try processed_body.append(ctx.alloc, RawInstr{
                            .op = .call_filter_arg,
                            .operand = .{ .index = @intCast(pi) },
                            .src_offset = instr.src_offset,
                        });
                        replaced = true;
                        break;
                    }
                }
            }
        }
        if (!replaced) {
            try processed_body.append(ctx.alloc, instr);
        }
    }
    body_raw.deinit(ctx.alloc);

    // Check for self-reference (recursion) BEFORE removing inner defs.
    const arity: u8 = @intCast(params.items.len);
    var is_recursive = false;
    const func_name = ctx.intern.items[name_ref.offset..][0..name_ref.len];
    if (arity == 0) {
        // Check if any inner def shadows this function name (same name, same arity).
        // If so, load_key references in the body are NOT self-references.
        var shadowed_by_inner = false;
        for (ctx.function_table.items[func_table_start..]) |inner_func| {
            const inner_name = ctx.intern.items[inner_func.name.offset..][0..inner_func.name.len];
            if (std.mem.eql(u8, inner_name, func_name) and inner_func.paramCount() == arity) {
                shadowed_by_inner = true;
                break;
            }
        }
        if (!shadowed_by_inner) {
            for (processed_body.items) |instr| {
                if (instr.op == .load_key) {
                    const key = ctx.intern.items[instr.operand.str_ref.offset..][0..instr.operand.str_ref.len];
                    if (std.mem.eql(u8, key, func_name)) {
                        is_recursive = true;
                        break;
                    }
                }
            }
        }
    }

    // Remove inner defs registered during the body scan.
    // These are scoped to the body and will be re-registered during actual expansion.
    while (ctx.function_table.items.len > func_table_start) {
        const inner = ctx.function_table.pop().?;
        inner.deinit(ctx.alloc);
    }

    // Register the function with body source range.
    try registerFunction(ctx, name_ref, params.items, processed_body.items, is_recursive, body_src_start, body_src_end, ctx.alloc);

    // Consume ';'
    const semi = try ctx.nextToken();
    if (semi.tag != .semicolon) return ctx.syntaxErr(semi.offset, semi.len);

    // Parse the continuation expression (code after the def)
    try parseFilter(ctx);
}

/// Parse an object literal: {key1: value1, key2: value2, ...}
/// Supports:
///   {ident}            — shorthand for {"ident": .ident}
///   {"str"}            — shorthand for {"str": .str} (static strings only)
///   {ident: expr}      — explicit key-value
///   {(.expr): expr}    — computed key
///   {k: a | b}         — pipe is allowed inside object values
fn parseObjectLiteral(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try ctx.emit(.object_construct_start, .{ .none = {} });

    while (true) {
        const peek = try ctx.lex.peek();
        if (peek.tag == .rbrace) {
            _ = try ctx.nextToken();
            break;
        }

        // Handle {$var} and {$var: value} shorthand.
        if (peek.tag == .dollar) {
            _ = try ctx.nextToken(); // consume '$'
            const var_tok = try ctx.nextToken();
            if (!isVarNameToken(var_tok.tag)) return ctx.syntaxErr(var_tok.offset, var_tok.len);
            const var_name = var_tok.slice(ctx.src);

            const after_dollar = try ctx.lex.peek();
            if (std.mem.eql(u8, var_name, "__loc__")) {
                // {$__loc__} shorthand — key = "__loc__", value = $__loc__ object
                const key_ref = try internStr(&ctx.intern, ctx.alloc, "__loc__");
                try ctx.emit(.push_string, .{ .str_ref = key_ref });
                try emitLocObject(ctx, var_tok.offset);
                try ctx.emit(.object_key, .{ .none = {} });
            } else {
                const name_ref = try internStr(&ctx.intern, ctx.alloc, var_name);
                const var_id = lookupVariable(ctx, name_ref) orelse return ctx.syntaxErr(var_tok.offset, var_tok.len);

                if (after_dollar.tag == .colon) {
                    // {$var: value} — use value of $var as dynamic key (convert to string).
                    // Save current input, compute string key from $var, restore for value expr.
                    _ = try ctx.nextToken(); // consume ':'
                    try ctx.emit(.save_input, .{ .none = {} });
                    try ctx.emit(.load_variable, .{ .index = var_id });
                    try ctx.emit(.pipe, .{ .none = {} });
                    try ctx.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.tostring) });
                    try ctx.emit(.restore_input, .{ .none = {} });
                    try parseObjectValue(ctx);
                } else {
                    // {$var} shorthand — key = "var_name", value = $var
                    const key_ref = try internStr(&ctx.intern, ctx.alloc, var_name);
                    try ctx.emit(.push_string, .{ .str_ref = key_ref });
                    try ctx.emit(.load_variable, .{ .index = var_id });
                }
                try ctx.emit(.object_key, .{ .none = {} });
            }
        } else {
            // Parse key; returns the static key ref for shorthand use (null for computed keys).
            const key_ref = try parseObjectKey(ctx);

            const after_key = try ctx.lex.peek();
            if (after_key.tag == .colon) {
                _ = try ctx.nextToken(); // consume ':'
                // Parse value expression; `|` is allowed so {x: -.|abs} works.
                try parseObjectValue(ctx);
            } else if ((after_key.tag == .comma or after_key.tag == .rbrace) and key_ref != null) {
                // Shorthand: {ident} or {"str"} — expand to {"key": .key}
                // The key string is already on the stack from parseObjectKey.
                // Emit .key_name as the value (accesses current input's field).
                try ctx.emit(.load_key, .{ .str_ref = key_ref.? });
            } else {
                return ctx.syntaxErr(after_key.offset, after_key.len);
            }

            try ctx.emit(.object_key, .{ .none = {} });
        }

        // Check for comma
        const comma = try ctx.lex.peek();
        if (comma.tag == .comma) {
            _ = try ctx.nextToken();
        }
    }

    try ctx.emit(.object_construct_end, .{ .none = {} });
}

/// Parse an object value expression: `alternative` optionally followed by `| alternative`
/// repetitions (restricted pipe — does not consume `,` or `as`).
/// This allows `{x: -.|abs}` where the pipe continues inside the value expression.
fn parseObjectValue(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try parseAlternative(ctx);
    while (true) {
        const t = try ctx.lex.peek();
        if (t.tag != .pipe) break;
        _ = try ctx.nextToken();
        try ctx.emit(.pipe, .{ .none = {} });
        try parseAlternative(ctx);
    }
}

/// Parse an object key: ident or string literal, or parenthesized expression for dynamic keys.
/// Returns the static StrRef for the key when the key is a plain identifier or static string
/// (so the caller can use it for shorthand expansion).  Returns null for computed keys.
fn parseObjectKey(ctx: *Ctx) (ZqError || error{OutOfMemory})!?StrRef {
    const peek = try ctx.lex.peek();

    if (peek.tag == .lparen) {
        // Dynamic key: {(.expr): value}
        _ = try ctx.nextToken();
        try parseLogical(ctx); // Evaluate key expression

        const rparen = try ctx.nextToken();
        if (rparen.tag != .rparen) return ctx.syntaxErr(rparen.offset, rparen.len);
        return null; // computed — no static key ref for shorthand
    } else if (peek.tag == .string_lit) {
        // Quoted string key: strip surrounding double-quotes, decode escape sequences.
        const key = try ctx.nextToken();
        const raw = key.slice(ctx.src);
        const content = raw[1 .. raw.len - 1];
        const ref = try internDecodedStr(&ctx.intern, ctx.alloc, content);
        try ctx.emit(.push_string, .{ .str_ref = ref });
        return ref; // static string — available for shorthand
    } else if (peek.tag == .ident or peek.tag == .int_lit or peek.tag == .float_lit or
        peek.tag == .true_kw or peek.tag == .false_kw or
        peek.tag == .if_kw or peek.tag == .then_kw or peek.tag == .elif_kw or
        peek.tag == .else_kw or peek.tag == .end_kw or peek.tag == .and_kw or
        peek.tag == .or_kw or peek.tag == .not_kw or peek.tag == .def_kw or
        peek.tag == .as_kw or peek.tag == .reduce_kw or
        peek.tag == .label_kw or peek.tag == .break_kw)
    {
        // Identifier or keyword used as key name.
        const key = try ctx.nextToken();
        const ref = try internStr(&ctx.intern, ctx.alloc, key.slice(ctx.src));
        try ctx.emit(.push_string, .{ .str_ref = ref });
        return ref; // static — available for shorthand
    } else {
        return ctx.syntaxErr(ctx.last_tok_offset, 0);
    }
}

/// Consume any chain of `.ident`, `[...]`, or `$var` suffixes following a primary expression.
/// Parse zero or more postfix suffixes (.field, [index], .[key], ?) after a
/// primary expression. `start_pos` is the raw-instruction index of the first
/// instruction emitted for the preceding primary expression; it is the insertion
/// point used when `?` retroactively wraps the preceding segment in try/end.
///
/// `?` applies to the segment since the last `?` (or since `start_pos`):
///   .foo.bar?   → try_begin, load_key "foo", load_key "bar", try_end
///   .foo?.bar   → try_begin, load_key "foo", try_end, load_key "bar"
///   .foo?.bar?  → try_begin, load_key "foo", try_end, try_begin, load_key "bar", try_end
fn parseSuffixes(ctx: *Ctx, start_pos: usize) (ZqError || error{OutOfMemory})!void {
    // segment_start: raw-instruction index where the current try-scope began.
    // Resets to ctx.raw.items.len after each `?` so the next `?` only wraps
    // what came after the previous one.
    var segment_start: usize = start_pos;
    // Track whether we have already emitted at least one element (the initial
    // primary element counts, so we start with true if start_pos < current len).
    // A pipe is emitted before each subsequent element so it receives the
    // previous element's result in it.current.
    // The pipe is emitted BEFORE updating segment_start so that `?` wraps only
    // the element itself, not the pipe (keeping pipe outside any try block).
    var had_suffix: bool = ctx.raw.items.len > start_pos;
    while (true) {
        const t = try ctx.lex.peek();
        switch (t.tag) {
            .dot => {
                _ = try ctx.nextToken();
                const nt = try ctx.lex.peek();
                switch (nt.tag) {
                    .ident => {
                        _ = try ctx.nextToken();
                        // Emit pipe between successive suffix elements so each element
                        // sees the previous element's result in it.current.
                        if (had_suffix) {
                            try ctx.emit(.pipe, .{ .none = {} });
                            segment_start = ctx.raw.items.len;
                        }
                        had_suffix = true;
                        const ref = try internStr(&ctx.intern, ctx.alloc, nt.slice(ctx.src));
                        try ctx.emit(.load_key, .{ .str_ref = ref });
                    },
                    .lbracket => {
                        _ = try ctx.nextToken();
                        if (had_suffix) {
                            try ctx.emit(.pipe, .{ .none = {} });
                            segment_start = ctx.raw.items.len;
                        }
                        had_suffix = true;
                        try parseBracket(ctx);
                    },
                    .string_lit => {
                        // ."foo" — quoted field access in suffix position
                        _ = try ctx.nextToken();
                        if (had_suffix) {
                            try ctx.emit(.pipe, .{ .none = {} });
                            segment_start = ctx.raw.items.len;
                        }
                        had_suffix = true;
                        const str_content = extractStringContent(nt.slice(ctx.src));
                        const ref = try internStr(&ctx.intern, ctx.alloc, str_content);
                        try ctx.emit(.load_key, .{ .str_ref = ref });
                    },
                    .dollar => {
                        // .$var - variable reference
                        _ = try ctx.nextToken();
                        if (had_suffix) {
                            try ctx.emit(.pipe, .{ .none = {} });
                            segment_start = ctx.raw.items.len;
                        }
                        had_suffix = true;
                        try parseVariableReference(ctx);
                    },
                    else => return ctx.syntaxErr(ctx.last_tok_offset, 0), // trailing dot
                }
            },
            .lbracket => {
                _ = try ctx.nextToken();
                if (had_suffix) {
                    try ctx.emit(.pipe, .{ .none = {} });
                    segment_start = ctx.raw.items.len;
                }
                had_suffix = true;
                try parseBracket(ctx);
            },
            .question => {
                _ = try ctx.nextToken();
                // Retroactively wrap the preceding segment in fork_try / pop_try
                // (no catch handler — errors are suppressed silently).
                // insertRawInstr shifts all existing jump targets past segment_start.
                try insertRawInstr(ctx, segment_start, RawInstr{ .op = .fork_try, .operand = .{ .index = 0 } });
                try ctx.emit(.pop_try, .{ .none = {} });
                // The next `?` (if any) only wraps what comes after this try_end.
                segment_start = ctx.raw.items.len;
                // After a ?, the next suffix element starts a new segment but still
                // follows a previous suffix, so keep had_suffix = true.
            },
            else => break,
        }
    }
}

/// Parse an optional integer (possibly negative: `-` followed by int_lit) used
/// in slice/index contexts. Returns the integer value if present, or null.
/// Float literals are accepted and truncated to integers (jq compat: .[1.2:3.5] == .[1:3]).
fn tryParseIndexInt(ctx: *Ctx) (ZqError || error{OutOfMemory})!?i64 {
    const peek = try ctx.lex.peek();
    if (peek.tag == .int_lit) {
        const tok = try ctx.nextToken();
        return std.fmt.parseInt(i64, tok.slice(ctx.src), 10) catch return ctx.syntaxErr(ctx.last_tok_offset, 0);
    }
    if (peek.tag == .float_lit) {
        // jq truncates float slice indices to integers
        const tok = try ctx.nextToken();
        const f = std.fmt.parseFloat(f64, tok.slice(ctx.src)) catch return ctx.syntaxErr(ctx.last_tok_offset, 0);
        return @intFromFloat(@trunc(f));
    }
    if (peek.tag == .minus) {
        // Peek one more token to see if it's an int_lit/float_lit (unary minus in index context)
        _ = try ctx.nextToken(); // consume minus
        const after = try ctx.lex.peek();
        if (after.tag == .int_lit) {
            const tok = try ctx.nextToken();
            const n = std.fmt.parseInt(i64, tok.slice(ctx.src), 10) catch return ctx.syntaxErr(ctx.last_tok_offset, 0);
            return -n;
        }
        if (after.tag == .float_lit) {
            const tok = try ctx.nextToken();
            const f = std.fmt.parseFloat(f64, tok.slice(ctx.src)) catch return ctx.syntaxErr(ctx.last_tok_offset, 0);
            return -@as(i64, @intFromFloat(@trunc(f)));
        }
        // Not a number after minus — this is a syntax error in index context
        return ctx.syntaxErr(ctx.last_tok_offset, 0);
    }
    return null;
}

/// Parse the tail of a slice expression after `:` has been consumed.
/// `has_from` / `from` carry the already-parsed left bound (if any).
/// Emits a single `slice` instruction and consumes the closing `]`.
fn parseSliceTail(ctx: *Ctx, has_from: bool, from: i32) (ZqError || error{OutOfMemory})!void {
    var has_to = false;
    var to: i32 = 0;
    if (try tryParseIndexInt(ctx)) |n| {
        has_to = true;
        // Clamp out-of-range values (e.g. 4294967295 or -4294967296) to i32 bounds.
        to = @intCast(std.math.clamp(n, std.math.minInt(i32), std.math.maxInt(i32)));
    }
    const close = try ctx.nextToken();
    if (close.tag != .rbracket) return ctx.syntaxErr(close.offset, close.len);
    try ctx.emit(.slice, .{ .slice_args = types.SliceArgs{
        .from = from,
        .to = to,
        .has_from = has_from,
        .has_to = has_to,
    } });
}

/// Returns true if `tag` is the start of a static slice bound (int/float/minus) or `]`.
fn isStaticSliceBoundOrEnd(tag: Token.Tag) bool {
    return tag == .int_lit or tag == .float_lit or tag == .minus or tag == .rbracket;
}

/// Parse the body of `[...]` (the opening `[` has already been consumed).
fn parseBracket(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const t = try ctx.lex.peek();
    switch (t.tag) {
        .rbracket => {
            _ = try ctx.nextToken();
            try ctx.emit(.each, .{ .none = {} });
        },
        .colon => {
            // .[:n] or .[:] or .[:expr] — slice with no left bound
            _ = try ctx.nextToken(); // consume ':'
            const to_peek = try ctx.lex.peek();
            if (isStaticSliceBoundOrEnd(to_peek.tag)) {
                try parseSliceTail(ctx, false, 0);
            } else {
                // Computed to-bound: .[:expr]
                try ctx.emit(.save_input, .{ .none = {} });
                try parsePipe(ctx);
                const close = try ctx.nextToken();
                if (close.tag != .rbracket) return ctx.syntaxErr(close.offset, close.len);
                try ctx.emit(.slice_computed, .{ .slice_args = types.SliceArgs{
                    .from = 0, .to = 0, .has_from = false, .has_to = true,
                } });
            }
        },
        .int_lit, .float_lit, .minus => {
            const n = (try tryParseIndexInt(ctx)) orelse return ctx.syntaxErr(ctx.last_tok_offset, 0);
            const after = try ctx.lex.peek();
            if (after.tag == .colon) {
                _ = try ctx.nextToken(); // consume ':'
                const to_peek = try ctx.lex.peek();
                if (isStaticSliceBoundOrEnd(to_peek.tag)) {
                    // Static slice: .[n:m], .[n:], .[n:float]
                    const n_clamped: i32 = @intCast(std.math.clamp(n, std.math.minInt(i32), std.math.maxInt(i32)));
                    try parseSliceTail(ctx, true, n_clamped);
                } else {
                    // Computed to-bound: .[n:expr]
                    try ctx.emit(.save_input, .{ .none = {} });
                    try ctx.emit(.push_int, .{ .int = n });
                    try parsePipe(ctx);
                    const close = try ctx.nextToken();
                    if (close.tag != .rbracket) return ctx.syntaxErr(close.offset, close.len);
                    try ctx.emit(.slice_computed, .{ .slice_args = types.SliceArgs{
                        .from = 0, .to = 0, .has_from = true, .has_to = true,
                    } });
                }
            } else {
                // .[n] — index access (negative allowed)
                if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) return ctx.syntaxErr(ctx.last_tok_offset, 0);
                const close = try ctx.nextToken();
                if (close.tag != .rbracket) return ctx.syntaxErr(close.offset, close.len);
                try ctx.emit(
                    .load_index,
                    .{ .index = n },
                );
            }
        },
        .string_lit => {
            const tok = try ctx.nextToken();
            const raw_str = tok.slice(ctx.src);
            // Strip the surrounding double-quotes and decode escape sequences.
            const content = raw_str[1 .. raw_str.len - 1];
            const ref = try internDecodedStr(&ctx.intern, ctx.alloc, content);
            const close = try ctx.nextToken();
            if (close.tag != .rbracket) return ctx.syntaxErr(close.offset, close.len);
            try ctx.emit(.load_key, .{ .str_ref = ref });
        },
        else => {
            // Computed access .[expr] or computed slice .[expr:expr].
            // Save base to if_stack, evaluate from-expr, then check for ':'.
            try ctx.emit(.save_input, .{ .none = {} });
            try parsePipe(ctx);
            const after_expr = try ctx.lex.peek();
            if (after_expr.tag == .colon) {
                _ = try ctx.nextToken(); // consume ':'
                // .[expr:...] — computed slice. Evaluate optional to-expr.
                const to_peek = try ctx.lex.peek();
                var has_to = false;
                if (to_peek.tag != .rbracket) {
                    try parsePipe(ctx);
                    has_to = true;
                }
                const close = try ctx.nextToken();
                if (close.tag != .rbracket) return ctx.syntaxErr(close.offset, close.len);
                try ctx.emit(.slice_computed, .{ .slice_args = types.SliceArgs{
                    .from = 0, .to = 0, .has_from = true, .has_to = has_to,
                } });
            } else {
                const close = try ctx.nextToken();
                if (close.tag != .rbracket) return ctx.syntaxErr(close.offset, close.len);
                try ctx.emit(.load_computed, .{ .none = {} });
            }
        },
    }
}

// ── String interning ──────────────────────────────────────────────────────────

/// Extract the content of a string literal token, stripping surrounding quotes.
/// Input: `"foo"` → output: `foo`.
fn extractStringContent(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn internStr(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}!StrRef {
    const off: u32 = @intCast(buf.items.len);
    try buf.appendSlice(alloc, s);
    return .{ .offset = off, .len = @intCast(s.len) };
}

/// Intern a JSON string literal after decoding its escape sequences.
/// `raw` must NOT include the surrounding double-quote characters.
/// Handles: \\, \", \/, \n, \r, \t, \b, \f, \uXXXX (including surrogates).
fn internDecodedStr(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, raw: []const u8) (ZqError || error{OutOfMemory})!StrRef {
    const off: u32 = @intCast(buf.items.len);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            try buf.append(alloc, raw[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= raw.len) return error.QuerySyntaxError;
        switch (raw[i]) {
            '\\' => {
                try buf.append(alloc, '\\');
                i += 1;
            },
            '"' => {
                try buf.append(alloc, '"');
                i += 1;
            },
            '/' => {
                try buf.append(alloc, '/');
                i += 1;
            },
            'n' => {
                try buf.append(alloc, '\n');
                i += 1;
            },
            'r' => {
                try buf.append(alloc, '\r');
                i += 1;
            },
            't' => {
                try buf.append(alloc, '\t');
                i += 1;
            },
            'b' => {
                try buf.append(alloc, '\x08');
                i += 1;
            },
            'f' => {
                try buf.append(alloc, '\x0C');
                i += 1;
            },
            'u' => {
                i += 1;
                if (i + 4 > raw.len) return error.QuerySyntaxError;
                const hi = std.fmt.parseInt(u21, raw[i..][0..4], 16) catch return error.QuerySyntaxError;
                i += 4;
                var codepoint: u21 = hi;
                // Handle UTF-16 surrogate pairs.
                if (hi >= 0xD800 and hi <= 0xDBFF) {
                    if (i + 6 > raw.len or raw[i] != '\\' or raw[i + 1] != 'u')
                        return error.QuerySyntaxError;
                    const lo = std.fmt.parseInt(u21, raw[i + 2 ..][0..4], 16) catch return error.QuerySyntaxError;
                    if (lo < 0xDC00 or lo > 0xDFFF) return error.QuerySyntaxError;
                    codepoint = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
                    i += 6;
                }
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(@intCast(codepoint), &utf8_buf) catch return error.QuerySyntaxError;
                try buf.appendSlice(alloc, utf8_buf[0..utf8_len]);
            },
            else => return error.QuerySyntaxError,
        }
    }
    const len: u32 = @intCast(buf.items.len - off);
    return .{ .offset = off, .len = len };
}

/// Append a dot-joined path from `keys` into `buf`, reading key bytes from `src`.
/// `src` must be a snapshot of `buf.items` taken BEFORE this call; no realloc
/// may occur between the snapshot and this call (guaranteed by pre-allocation).
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

// ── Fuse pass ─────────────────────────────────────────────────────────────────
//
// Collapse consecutive OP_LOAD_KEY instructions separated only by OP_PIPE into
// a single OP_LOAD_PATH "a.b.c". This halves interpreter overhead for common
// chained field access patterns (.a | .b | .c → one instruction).
//
// OP_ITERATE and all other instructions break the fusion chain.

fn fuse(
    raw: []const RawInstr,
    _: *std.ArrayList(FunctionEntry),
    intern: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
) error{OutOfMemory}!Compiled {
    var fused = std.ArrayList(RawInstr){};
    defer fused.deinit(alloc);

    // Parallel source offset tracking for diagnostics
    var fused_src_offsets = std.ArrayList(u32){};
    defer fused_src_offsets.deinit(alloc);

    // Track mapping from raw instruction index to fused instruction index
    var index_map = std.ArrayList(u32){};
    defer index_map.deinit(alloc);
    try index_map.ensureTotalCapacity(alloc, raw.len + 1);

    var i: usize = 0;
    while (i < raw.len) {
        // Record mapping for current raw instruction
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
                keys.items[0] // single key — reuse existing ref
            else blk: {
                // Capture intern.items before appending to avoid slice aliasing.
                const src_snap = intern.items;
                break :blk try internPath(intern, alloc, keys.items, src_snap);
            };

            const op: Instruction.Op = if (keys.items.len == 1) .load_key else .load_path;
            try fused.append(alloc, RawInstr{ .op = op, .operand = .{ .str_ref = ref } });
            try fused_src_offsets.append(alloc, raw[i].src_offset);

            // Fill index_map for the consumed pipe+load_key pairs so that any
            // raw instruction index (e.g. a jump or array_collect_start end_ip)
            // pointing past this chain resolves to the correct fused index.
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

    // Sentinel: backpatched operands can point one past the last raw instruction
    // (e.g. limit_start exit_ip, label_begin exit_ip). Map to one past fused end.
    index_map.appendAssumeCapacity(@intCast(fused.items.len));

    // Intern buffer is now complete. Finalize and convert to []Instruction.
    const string_buf = try intern.toOwnedSlice(alloc);
    errdefer alloc.free(string_buf);

    const instructions = try alloc.alloc(Instruction, fused.items.len);
    errdefer alloc.free(instructions);

    for (fused.items, instructions) |r, *out| {
        out.* = Instruction{
            .op = r.op,
            .operand = switch (r.op) {
                .load_key, .load_path => .{ .str_ref = .{ .offset = r.operand.str_ref.offset, .len = r.operand.str_ref.len } },
                .push_string => .{ .str_ref = .{
                    .offset = r.operand.str_ref.offset,
                    .len = r.operand.str_ref.len,
                } },
                .load_index, .capture_variable, .load_variable, .pop_variable, .def_function, .call_filter_arg => .{ .index = r.operand.index },
                // call_function operand is a jump target IP that needs remapping.
                .call_function => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .return_function => .{ .none = {} },
                .load_computed => .{ .none = {} },
                .push_bool => .{ .bool = r.operand.bool },
                .push_int => .{ .int = r.operand.int },
                .push_float => .{ .float = r.operand.float },
                .push_null => .{ .none = {} },
                .push_current => .{ .none = {} },
                .identity => .{ .none = {} },
                .pipe => .{ .none = {} },
                .add => .{ .none = {} },
                .sub => .{ .none = {} },
                .mul => .{ .none = {} },
                .div => .{ .none = {} },
                .mod => .{ .none = {} },
                .eq => .{ .none = {} },
                .ne => .{ .none = {} },
                .lt => .{ .none = {} },
                .le => .{ .none = {} },
                .gt => .{ .none = {} },
                .ge => .{ .none = {} },
                .and_op => .{ .none = {} },
                .or_op => .{ .none = {} },
                .not => .{ .none = {} },
                .negate => .{ .none = {} },
                .object_construct_start => .{ .none = {} },
                .object_key => .{ .none = {} },
                .object_construct_end => .{ .none = {} },
                // Conditional branching: remap raw instruction index → fused index.
                .jump, .jump_if_false => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .save_input => .{ .none = {} },
                .restore_input => .{ .none = {} },
                // Array construction: remap end_ip raw → fused index.
                .array_collect_start => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .array_collect_end => .{ .none = {} },
                // Fork-based try/alt: remap non-zero index operands (0 = sentinel).
                .fork_try, .fork_alt => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = if (r.operand.index > 0) index_map.items[idx_usize] else 0;
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .pop_try => .{ .none = {} },
                .slice => .{ .slice_args = r.operand.slice_args },
                .navigate_key, .update_key => .{ .str_ref = .{ .offset = r.operand.str_ref.offset, .len = r.operand.str_ref.len } },
                .navigate_index, .update_index => .{ .index = r.operand.index },
                // call_builtin: operand is BuiltinId encoded as index; pass through as-is.
                .call_builtin => .{ .index = r.operand.index },
                // Label/break: label_begin carries exit_ip that needs remapping.
                .label_begin => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .label_end => .{ .none = {} },
                .break_op => .{ .none = {} },
                // Limit: limit_start carries exit_ip that needs remapping.
                .limit_start => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .limit_end => .{ .none = {} },
                // Fork stack opcodes: fork carries backtrack IP that needs remapping.
                .fork => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .backtrack => .{ .none = {} },
                .each => .{ .none = {} },
                .yield_output => .{ .none = {} },
            },
        };
    }

    // Function bodies are inline-expanded at compile time; the VM function table
    // is empty (kept for interface compatibility).
    const function_defs = try alloc.alloc(types.FunctionDef, 0);

    const source_map = try fused_src_offsets.toOwnedSlice(alloc);
    errdefer alloc.free(source_map);

    return Compiled{ .instructions = instructions, .function_table = function_defs, .string_buf = string_buf, .external_var_ids = &.{}, .source_map = source_map };
}
