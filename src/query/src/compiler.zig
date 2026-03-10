const std = @import("std");
const ZqError = @import("error").ZqError;
const types = @import("types");
const Instruction = types.Instruction;
const lx = @import("lexer.zig");
const Lexer = lx.Lexer;
const Token = lx.Token;

// ── Public output type ────────────────────────────────────────────────────────

/// Caller owns both slices; free via deinit().
pub const Compiled = struct {
    instructions: []Instruction,
    function_table: []const types.FunctionDef,
    string_buf: []u8,

    pub fn deinit(c: *Compiled, alloc: std.mem.Allocator) void {
        alloc.free(c.instructions);
        alloc.free(c.string_buf);
        // function_table is part of string_buf, no need to free separately
    }
};

// ── Compiler-internal types ───────────────────────────────────────────────────

/// Byte range within the intern buffer. Used during compilation before the
/// buffer is finalized; converted to []const u8 slices in the final pass.
const StrRef = struct { offset: u32, len: u32 };

const RawOp = union {
    str_ref: StrRef,
    index: u32,
    bool: bool,
    int: i64,
    float: f64,
    none: void,
};

const RawInstr = struct {
    op: Instruction.Op,
    operand: RawOp,
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
};

const VariableEntry = struct {
    name: StrRef,
    id: u32,
};

const VariableScope = struct {
    variables: std.ArrayList(VariableEntry),
    parent: ?*VariableScope,
};

const FunctionEntry = struct {
    name: StrRef,
    param_count: u8,
    param_ids: []u32, // Variable IDs for parameters
    body_start_raw: u32, // Raw instruction index where function body starts
    def_func_raw_ip: u32, // Raw instruction index where def_function will be emitted
    body_end_raw: u32, // Raw instruction index where function body ends
    id: u32,

    fn deinit(self: *const FunctionEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.param_ids);
    }
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

/// Declare a variable in the current scope
fn declareVariable(ctx: *Ctx, name_ref: StrRef, alloc: std.mem.Allocator) (ZqError || error{OutOfMemory})!u32 {
    // Check for duplicate in current scope
    for (ctx.current_scope.variables.items) |var_entry| {
        const existing_name = ctx.intern.items[var_entry.name.offset..][0..var_entry.name.len];
        const new_name = ctx.intern.items[name_ref.offset..][0..name_ref.len];
        if (std.mem.eql(u8, existing_name, new_name)) {
            return error.QuerySyntaxError; // Variable already declared in this scope
        }
    }

    const var_id = ctx.next_var_id;
    ctx.next_var_id += 1;

    try ctx.current_scope.variables.append(alloc, VariableEntry{
        .name = name_ref,
        .id = var_id,
    });

    return var_id;
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

// ── Function management ──────────────────────────────────────────────────

/// Define a function in the function table
fn defineFunctionWithBody(ctx: *Ctx, name_ref: StrRef, param_ids: []u32, body_start_raw: u32, body_end_raw: u32, def_func_raw_ip: u32, alloc: std.mem.Allocator) error{OutOfMemory}!u32 {
    const func_id = ctx.next_func_id;
    ctx.next_func_id += 1;

    // Copy param_ids since they need to outlive the current parsing scope
    const param_copy = try alloc.dupe(u32, param_ids);

    try ctx.function_table.append(alloc, FunctionEntry{
        .name = name_ref,
        .param_count = @intCast(param_ids.len),
        .param_ids = param_copy,
        .body_start_raw = body_start_raw,
        .def_func_raw_ip = def_func_raw_ip,
        .body_end_raw = body_end_raw,
        .id = func_id,
    });

    return func_id;
}

/// Lookup a function by name
fn lookupFunction(ctx: *Ctx, name_ref: StrRef) ?u32 {
    for (ctx.function_table.items) |func| {
        const func_name = ctx.intern.items[func.name.offset..][0..func.name.len];
        const lookup_name = ctx.intern.items[name_ref.offset..][0..name_ref.len];
        if (std.mem.eql(u8, func_name, lookup_name)) {
            return func.id;
        }
    }
    return null;
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn compile(src: []const u8, alloc: std.mem.Allocator) (ZqError || error{OutOfMemory})!Compiled {
    const scope = try alloc.create(VariableScope);
    scope.* = VariableScope{
        .variables = std.ArrayList(VariableEntry){},
        .parent = null,
    };

    var ctx = Ctx{
        .src = src,
        .lex = Lexer.init(src),
        .raw = std.ArrayList(RawInstr){},
        .intern = std.ArrayList(u8){},
        .alloc = alloc,
        .current_scope = scope,
        .function_table = std.ArrayList(FunctionEntry){},
        .next_var_id = 0,
        .next_func_id = 0,
    };
    defer ctx.raw.deinit(alloc); // always freed; fuse() copies what it needs
    defer {
        // Cleanup function table (free param_ids for each function)
        for (ctx.function_table.items) |*func| {
            func.deinit(alloc);
        }
        ctx.function_table.deinit(alloc);
    }
    errdefer ctx.intern.deinit(alloc); // freed only on error; toOwnedSlice transfers on success
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

    // Pre-allocate: the intern buffer is bounded by 2× source length (keys + dot
    // separators in fused paths). This prevents any reallocation during parsing,
    // which would otherwise invalidate StrRef offsets that reference live slices.
    try ctx.intern.ensureTotalCapacity(alloc, src.len * 2 + 16);

    try parseFilter(&ctx);

    const tail = try ctx.lex.next();
    if (tail.tag != .eof) return error.QuerySyntaxError;

    // Append implicit OP_OUTPUT if not already present.
    const needs_output = ctx.raw.items.len == 0 or
        ctx.raw.items[ctx.raw.items.len - 1].op != .output;
    if (needs_output) {
        try ctx.raw.append(alloc, RawInstr{ .op = .output, .operand = .{ .none = {} } });
    }

    return fuse(ctx.raw.items, &ctx.function_table, &ctx.intern, alloc);
}

// ── Parser ────────────────────────────────────────────────────────────────────

fn parseFilter(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Parse function definitions at the top level before the main expression
    // Function definitions in jq are: def name(params): body;
    // They can appear multiple times before the main query
    while (true) {
        const peek = try ctx.lex.peek();
        if (peek.tag == .def_kw) {
            // Parse function definition
            try parseFunctionDef(ctx);
        } else {
            // Not a function definition, start parsing the main expression
            break;
        }
    }

    try parsePipe(ctx);
}

fn parsePipe(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try parseLogical(ctx);
    while (true) {
        const t = try ctx.lex.peek();
        if (t.tag != .pipe) break;
        _ = try ctx.lex.next();
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
        try parseLogical(ctx);
    }
}

/// parseLogical: `or`, `and` (lowest precedence)
/// Also handles `expr as $var` suffix
fn parseLogical(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try parseOr(ctx);

    // Check for `as $var` suffix
    const t = try ctx.lex.peek();
    if (t.tag == .as_kw) {
        _ = try ctx.lex.next();
        const dollar = try ctx.lex.next();
        if (dollar.tag != .dollar) return error.QuerySyntaxError;
        const ident = try ctx.lex.next();
        if (ident.tag != .ident) return error.QuerySyntaxError;

        const name_ref = try internStr(&ctx.intern, ctx.alloc, ident.slice(ctx.src));
        const var_id = try declareVariable(ctx, name_ref, ctx.alloc);

        // Emit capture instruction
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .capture_variable, .operand = .{ .index = var_id } });
    }
}

fn parseOr(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try parseAnd(ctx);
    while (true) {
        const t = try ctx.lex.peek();
        if (t.tag != .or_kw) break;
        _ = try ctx.lex.next();
        try parseAnd(ctx);
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .or_op, .operand = .{ .none = {} } });
    }
}

fn parseAnd(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try parseComparison(ctx);
    while (true) {
        const t = try ctx.lex.peek();
        if (t.tag != .and_kw) break;
        _ = try ctx.lex.next();
        try parseComparison(ctx);
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .and_op, .operand = .{ .none = {} } });
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
        _ = try ctx.lex.next();
        try parseAdditive(ctx);
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = op, .operand = .{ .none = {} } });
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
        _ = try ctx.lex.next();
        try parseMultiplicative(ctx);
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = op, .operand = .{ .none = {} } });
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
        _ = try ctx.lex.next();
        try parseUnary(ctx);
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = op, .operand = .{ .none = {} } });
    }
}

/// parseUnary: `not`, unary `-`
fn parseUnary(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const t = try ctx.lex.peek();
    if (t.tag == .not_kw) {
        _ = try ctx.lex.next();
        try parseUnary(ctx);
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .not, .operand = .{ .none = {} } });
    } else if (t.tag == .minus) {
        _ = try ctx.lex.next();
        // Recursively parse the operand, then emit negate.
        // Note: `-1` (no space) is handled by the lexer as a single int_lit token,
        // so this branch only fires for `-.foo`, `-(expr)`, `- 1` (with space), etc.
        try parseUnary(ctx);
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .negate, .operand = .{ .none = {} } });
    } else {
        try parsePrimary(ctx);
    }
}

/// Check if an identifier is a built-in function name
fn isBuiltinFunction(name: []const u8) bool {
    // Common jq built-in functions
    const builtins = [_][]const u8{
        "map",       "select",     "reduce",       "range",        "foreach",        "walk",
        "keys",      "values",     "to_entries",   "from_entries", "add",            "sub",
        "mul",       "div",        "mod",          "length",       "utf8bytelength", "explode",
        "split",     "join",       "min",          "max",          "any",            "all",
        "first",     "last",       "nth",          "type",         "has",            "paths",
        "del",       "setpath",    "with_entries", "limit",        "sort",           "sort_by",
        "group_by",  "unique",     "unique_by",    "map_values",   "index",          "rindex",
        "inside",    "startswith", "endswith",     "contains",     "test",           "match",
        "capture",   "matches",    "splitn",       "inputs",       "env",            "tonumber",
        "tostreams", "tostring",
    };

    for (builtins) |builtin| {
        if (std.mem.eql(u8, name, builtin)) {
            return true;
        }
    }
    return false;
}

/// parsePrimary: literals, identifiers (with .field, [index]), `(` expr `)`, `$var`, `def name:`, `func(...)`
fn parsePrimary(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const t = try ctx.lex.next();
    switch (t.tag) {
        .true_kw => {
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_bool, .operand = .{ .bool = true } });
        },
        .false_kw => {
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_bool, .operand = .{ .bool = false } });
        },
        .int_lit => {
            const n = std.fmt.parseInt(i64, t.slice(ctx.src), 10) catch return error.QuerySyntaxError;
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_int, .operand = .{ .int = n } });
        },
        .float_lit => {
            const f = std.fmt.parseFloat(f64, t.slice(ctx.src)) catch return error.QuerySyntaxError;
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_float, .operand = .{ .float = f } });
        },
        .ident => {
            // Check if this is a built-in function or function call
            const peek = try ctx.lex.peek();
            const ident_name = t.slice(ctx.src);

            // Built-in functions: map, select, reduce, etc.
            // These are handled specially in jq
            if (peek.tag == .lparen or isBuiltinFunction(ident_name)) {
                // Function call
                try parseFunctionCall(ctx, t);
            } else {
                // Field access
                const ref = try internStr(&ctx.intern, ctx.alloc, ident_name);
                try ctx.raw.append(ctx.alloc, RawInstr{ .op = .load_key, .operand = .{ .str_ref = ref } });
                try parseSuffixes(ctx);
            }
        },
        .dot => {
            const after = try ctx.lex.peek();
            switch (after.tag) {
                .ident => {
                    _ = try ctx.lex.next();
                    const ref = try internStr(&ctx.intern, ctx.alloc, after.slice(ctx.src));
                    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .load_key, .operand = .{ .str_ref = ref } });
                    try parseSuffixes(ctx);
                },
                .lbracket => {
                    _ = try ctx.lex.next();
                    try parseBracket(ctx);
                    try parseSuffixes(ctx);
                },
                else => {
                    // Bare dot — identity.
                    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .identity, .operand = .{ .none = {} } });
                },
            }
        },
        .lparen => {
            try parseLogical(ctx);
            const close = try ctx.lex.next();
            if (close.tag != .rparen) return error.QuerySyntaxError;
        },
        .dollar => {
            // Variable reference: $var
            try parseVariableReference(ctx);
        },
        .lbrace => {
            // Object literal
            try parseObjectLiteral(ctx);
        },
        else => return error.QuerySyntaxError,
    }
}

/// Parse a variable reference: $var
fn parseVariableReference(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const ident = try ctx.lex.next();
    if (ident.tag != .ident) return error.QuerySyntaxError;

    const name_ref = try internStr(&ctx.intern, ctx.alloc, ident.slice(ctx.src));
    const var_id = lookupVariable(ctx, name_ref) orelse return error.QuerySyntaxError;

    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .load_variable, .operand = .{ .index = var_id } });
}

/// Parse a function definition: def name(params): body
fn parseFunctionDef(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Function name
    const name_tok = try ctx.lex.next();
    if (name_tok.tag != .ident) return error.QuerySyntaxError;
    const name_ref = try internStr(&ctx.intern, ctx.alloc, name_tok.slice(ctx.src));

    // Parameters: (param1; param2; ...)
    const lparen = try ctx.lex.next();
    if (lparen.tag != .lparen) return error.QuerySyntaxError;

    // First pass: collect parameter names
    var param_names = std.ArrayList(StrRef){};
    defer param_names.deinit(ctx.alloc);

    while (true) {
        const param_tok = try ctx.lex.peek();
        if (param_tok.tag == .rparen) {
            _ = try ctx.lex.next();
            break;
        }

        // Parse parameter name
        const param_name = try ctx.lex.next();
        if (param_name.tag != .ident) return error.QuerySyntaxError;

        const param_ref = try internStr(&ctx.intern, ctx.alloc, param_name.slice(ctx.src));
        try param_names.append(ctx.alloc, param_ref);

        // Check for more parameters or end of list
        const next_tok = try ctx.lex.peek();
        if (next_tok.tag == .semicolon) {
            _ = try ctx.lex.next();
        } else if (next_tok.tag != .rparen) {
            return error.QuerySyntaxError;
        }
    }

    // Colon before function body
    const colon = try ctx.lex.next();
    if (colon.tag != .colon) return error.QuerySyntaxError;

    // Create a new scope for function body
    try pushScope(ctx, ctx.alloc);

    // Declare all parameters in the new scope and collect their IDs
    var param_ids = std.ArrayList(u32){};
    defer param_ids.deinit(ctx.alloc);

    for (param_names.items) |param_ref| {
        const param_id = try declareVariable(ctx, param_ref, ctx.alloc);
        try param_ids.append(ctx.alloc, param_id);
    }

    // Track where function body starts
    const body_start = @as(u32, @intCast(ctx.raw.items.len));

    // Parse function body
    try parseLogical(ctx);

    // Define the function with body_start (position of def_function, will be resolved later)
    const def_func_pos = @as(u32, @intCast(ctx.raw.items.len));
    const body_end = @as(u32, @intCast(ctx.raw.items.len + 1)); // Position after def_function
    const func_id = try defineFunctionWithBody(ctx, name_ref, param_ids.items, body_start, body_end, def_func_pos, ctx.alloc);

    // Emit def_function instruction (will be resolved at compile time)
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .def_function, .operand = .{ .index = func_id } });

    // Pop the parameter scope (will also emit pop_variable for each parameter)
    for (param_ids.items) |param_id| {
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pop_variable, .operand = .{ .index = param_id } });
    }
    popScope(ctx, ctx.alloc);
}

/// Parse a function call: func(arg1; arg2; ...) or builtin(expr)
fn parseFunctionCall(ctx: *Ctx, name_tok: Token) (ZqError || error{OutOfMemory})!void {
    const ident_name = name_tok.slice(ctx.src);

    // Check if this is a built-in function
    if (isBuiltinFunction(ident_name)) {
        // Built-in function: consume opening paren
        _ = try ctx.lex.next();

        // Parse the expression for built-in function
        // Built-in functions like map take a single expression in parentheses
        // For simplicity, we'll just emit iterate for map
        try parseLogical(ctx);

        // Expect closing paren
        const rparen = try ctx.lex.next();
        if (rparen.tag != .rparen) return error.QuerySyntaxError;

        // For now, map just iterates - proper implementation needed
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .iterate, .operand = .{ .none = {} } });
    } else {
        // User-defined function
        const name_ref = try internStr(&ctx.intern, ctx.alloc, ident_name);
        const func_id = lookupFunction(ctx, name_ref) orelse return error.QuerySyntaxError;

        // Consume opening paren
        _ = try ctx.lex.next();

        // Parse arguments
        var arg_count: usize = 0;
        while (true) {
            const next_tok = try ctx.lex.peek();
            if (next_tok.tag == .rparen) {
                _ = try ctx.lex.next();
                break;
            }

            // Parse argument expression
            try parseLogical(ctx);
            arg_count += 1;

            // Check for more arguments or end of list
            const sep_tok = try ctx.lex.peek();
            if (sep_tok.tag == .semicolon) {
                _ = try ctx.lex.next();
            } else if (sep_tok.tag != .rparen) {
                return error.QuerySyntaxError;
            }
        }

        // Emit call_function instruction
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .call_function, .operand = .{ .index = func_id } });
    }
}

/// Parse an object literal: {key1: value1, key2: value2, ...}
fn parseObjectLiteral(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .object_construct_start, .operand = .{ .none = {} } });

    while (true) {
        const peek = try ctx.lex.peek();
        if (peek.tag == .rbrace) {
            _ = try ctx.lex.next();
            break;
        }

        // Parse key (literal or dynamic)
        try parseObjectKey(ctx);

        // Parse colon
        const colon = try ctx.lex.next();
        if (colon.tag != .colon) return error.QuerySyntaxError;

        // Parse value expression
        // The VM's object_key handler will get the value from stack or current
        try parseLogical(ctx);

        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .object_key, .operand = .{ .none = {} } });

        // Check for comma
        const comma = try ctx.lex.peek();
        if (comma.tag == .comma) {
            _ = try ctx.lex.next();
        }
    }

    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .object_construct_end, .operand = .{ .none = {} } });
}

/// Parse an object key: ident or string literal, or parenthesized expression for dynamic keys
fn parseObjectKey(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const peek = try ctx.lex.peek();

    if (peek.tag == .lparen) {
        // Dynamic key: {(.expr): value}
        _ = try ctx.lex.next();
        try parseLogical(ctx); // Evaluate key expression

        const rparen = try ctx.lex.next();
        if (rparen.tag != .rparen) return error.QuerySyntaxError;
    } else if (peek.tag == .ident or peek.tag == .int_lit or peek.tag == .float_lit or
        peek.tag == .true_kw or peek.tag == .false_kw)
    {
        // Literal key - push as string value for object construction
        const key = try ctx.lex.next();
        const ref = try internStr(&ctx.intern, ctx.alloc, key.slice(ctx.src));
        // Push string value directly to stack for object construction
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_string, .operand = .{ .str_ref = ref } });
    } else {
        return error.QuerySyntaxError;
    }
}

/// Consume any chain of `.ident`, `[...]`, or `$var` suffixes following a primary expression.
fn parseSuffixes(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    while (true) {
        const t = try ctx.lex.peek();
        switch (t.tag) {
            .dot => {
                _ = try ctx.lex.next();
                const nt = try ctx.lex.peek();
                switch (nt.tag) {
                    .ident => {
                        _ = try ctx.lex.next();
                        const ref = try internStr(&ctx.intern, ctx.alloc, nt.slice(ctx.src));
                        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .load_key, .operand = .{ .str_ref = ref } });
                    },
                    .lbracket => {
                        _ = try ctx.lex.next();
                        try parseBracket(ctx);
                    },
                    .dollar => {
                        // .$var - variable reference
                        _ = try ctx.lex.next();
                        try parseVariableReference(ctx);
                    },
                    else => return error.QuerySyntaxError, // trailing dot
                }
            },
            .lbracket => {
                _ = try ctx.lex.next();
                try parseBracket(ctx);
            },
            else => break,
        }
    }
}

/// Parse the body of `[...]` (the opening `[` has already been consumed).
fn parseBracket(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const t = try ctx.lex.next();
    switch (t.tag) {
        .rbracket => {
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .iterate, .operand = .{ .none = {} } });
        },
        .int_lit => {
            const n = std.fmt.parseInt(i64, t.slice(ctx.src), 10) catch return error.QuerySyntaxError;
            if (n < 0 or n > std.math.maxInt(u32)) return error.QuerySyntaxError;
            const close = try ctx.lex.next();
            if (close.tag != .rbracket) return error.QuerySyntaxError;
            try ctx.raw.append(ctx.alloc, RawInstr{
                .op = .load_index,
                .operand = .{ .index = @intCast(n) },
            });
        },
        else => return error.QuerySyntaxError,
    }
}

// ── String interning ──────────────────────────────────────────────────────────

fn internStr(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}!StrRef {
    const off: u32 = @intCast(buf.items.len);
    try buf.appendSlice(alloc, s);
    return .{ .offset = off, .len = @intCast(s.len) };
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
    function_table: *std.ArrayList(FunctionEntry),
    intern: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
) error{OutOfMemory}!Compiled {
    var fused = std.ArrayList(RawInstr){};
    defer fused.deinit(alloc);

    // Track mapping from raw instruction index to fused instruction index
    var index_map = std.ArrayList(u32){};
    defer index_map.deinit(alloc);
    try index_map.ensureTotalCapacity(alloc, raw.len);

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
            i = j;
        } else {
            try fused.append(alloc, raw[i]);
            i += 1;
        }
    }

    // Intern buffer is now complete. Finalize and convert to []Instruction.
    const string_buf = try intern.toOwnedSlice(alloc);
    errdefer alloc.free(string_buf);

    const instructions = try alloc.alloc(Instruction, fused.items.len);
    errdefer alloc.free(instructions);

    for (fused.items, instructions) |r, *out| {
        out.* = Instruction{
            .op = r.op,
            .operand = switch (r.op) {
                .load_key, .load_path => .{ .string = string_buf[r.operand.str_ref.offset..][0..r.operand.str_ref.len] },
                .push_string => .{ .str_ref = .{
                    .offset = r.operand.str_ref.offset,
                    .len = r.operand.str_ref.len,
                } },
                .load_index, .capture_variable, .load_variable, .pop_variable, .def_function, .call_function => .{ .index = r.operand.index },
                .push_bool => .{ .bool = r.operand.bool },
                .push_int => .{ .int = r.operand.int },
                .push_float => .{ .float = r.operand.float },
                .push_null => .{ .none = {} },
                .push_current => .{ .none = {} },
                .identity => .{ .none = {} },
                .iterate => .{ .none = {} },
                .pipe => .{ .none = {} },
                .output => .{ .none = {} },
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
            },
        };
    }

    // Create function table for VM
    const function_defs = try alloc.alloc(types.FunctionDef, function_table.items.len);
    for (function_table.items, function_defs) |func, *def| {
        // Map raw instruction indices to fused instruction indices
        const fused_body_start = index_map.items[func.body_start_raw];
        const fused_body_end = index_map.items[func.body_end_raw];

        def.* = types.FunctionDef{
            .body_ip = fused_body_start,
            .body_end = fused_body_end,
            .param_count = func.param_count,
        };
    }

    return Compiled{ .instructions = instructions, .function_table = function_defs, .string_buf = string_buf };
}
