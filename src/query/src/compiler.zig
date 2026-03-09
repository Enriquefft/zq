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
    string_buf: []u8,

    pub fn deinit(c: *Compiled, alloc: std.mem.Allocator) void {
        alloc.free(c.instructions);
        alloc.free(c.string_buf);
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
    body_ip: u32, // Will be set by the fuse pass
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
fn defineFunction(ctx: *Ctx, name_ref: StrRef, param_ids: []u32, alloc: std.mem.Allocator) error{OutOfMemory}!u32 {
    const func_id = ctx.next_func_id;
    ctx.next_func_id += 1;

    // Copy param_ids since they need to outlive the current parsing scope
    const param_copy = try alloc.dupe(u32, param_ids);

    try ctx.function_table.append(alloc, FunctionEntry{
        .name = name_ref,
        .param_count = @intCast(param_ids.len),
        .param_ids = param_copy,
        .body_ip = 0, // Will be set during fuse pass
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
    defer ctx.raw.deinit(alloc);   // always freed; fuse() copies what it needs
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

    return fuse(ctx.raw.items, &ctx.intern, alloc);
}

// ── Parser ────────────────────────────────────────────────────────────────────

fn parseFilter(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
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

/// parseUnary: `not`, `-`
fn parseUnary(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const t = try ctx.lex.peek();
    if (t.tag == .not_kw) {
        _ = try ctx.lex.next();
        try parseUnary(ctx);
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .not, .operand = .{ .none = {} } });
    } else if (t.tag == .minus) {
        _ = try ctx.lex.next();
        // Check if this is a negative number literal
        const next = try ctx.lex.peek();
        if (next.tag == .int_lit or next.tag == .float_lit) {
            try parsePrimary(ctx);
            // The literal parser already handles the negative sign
        } else {
            // This is a unary minus operator
            try parseUnary(ctx);
            // Negate by pushing -1 and multiplying
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_int, .operand = .{ .int = -1 } });
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .mul, .operand = .{ .none = {} } });
        }
    } else {
        try parsePrimary(ctx);
    }
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
            // Check if this is a function call
            const peek = try ctx.lex.peek();
            if (peek.tag == .lparen) {
                // Function call
                try parseFunctionCall(ctx, t);
            } else {
                // Field access
                const ref = try internStr(&ctx.intern, ctx.alloc, t.slice(ctx.src));
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
        .def_kw => {
            // Function definition
            try parseFunctionDef(ctx);
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

    // Parse function body
    try parseLogical(ctx);

    // Define the function
    const func_id = try defineFunction(ctx, name_ref, param_ids.items, ctx.alloc);

    // Emit def_function instruction (will be resolved at compile time)
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .def_function, .operand = .{ .index = func_id } });

    // Pop the parameter scope (will also emit pop_variable for each parameter)
    for (param_ids.items) |param_id| {
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pop_variable, .operand = .{ .index = param_id } });
    }
    popScope(ctx, ctx.alloc);
}

/// Parse a function call: func(arg1; arg2; ...)
fn parseFunctionCall(ctx: *Ctx, name_tok: Token) (ZqError || error{OutOfMemory})!void {
    const name_ref = try internStr(&ctx.intern, ctx.alloc, name_tok.slice(ctx.src));
    const func_id = lookupFunction(ctx, name_ref) orelse return error.QuerySyntaxError;
    const func = &ctx.function_table.items[func_id];

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

    // Check argument count matches parameter count
    if (arg_count != func.param_count) {
        return error.QuerySyntaxError;
    }

    // Emit call_function instruction
    // Note: For simplicity, we'll use inline expansion approach
    // where function bodies are substituted at compile time
    // For now, just emit a placeholder
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .call_function, .operand = .{ .index = func_id } });
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
    intern: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
) error{OutOfMemory}!Compiled {
    var fused = std.ArrayList(RawInstr){};
    defer fused.deinit(alloc);

    var i: usize = 0;
    while (i < raw.len) {
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
                .load_index, .capture_variable, .load_variable, .pop_variable, .def_function, .call_function => .{ .index = r.operand.index },
                .push_bool => .{ .bool = r.operand.bool },
                .push_int => .{ .int = r.operand.int },
                .push_float => .{ .float = r.operand.float },
                .identity, .iterate, .pipe, .output,
                .add, .sub, .mul, .div, .mod,
                .eq, .ne, .lt, .le, .gt, .ge,
                .and_op, .or_op, .not => .{ .none = {} },
            },
        };
    }

    return Compiled{ .instructions = instructions, .string_buf = string_buf };
}
