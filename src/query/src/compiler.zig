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
    index: i64,
    bool: bool,
    int: i64,
    float: f64,
    none: void,
    slice_args: types.SliceArgs,
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

const PathStep = struct {
    kind: enum { key, index },
    key: StrRef = .{ .offset = 0, .len = 0 },
    index: i64 = 0,
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

// ── Instruction insertion ─────────────────────────────────────────────────────
//
// Retroactively inserts a raw instruction at `pos`, shifting all later
// instructions right by one slot.  Fixes up every jump-target operand and every
// function-table body-range index whose value is ≥ pos so that they still
// address the same (now shifted) instructions.

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
            .jump, .jump_if_false, .array_collect_start, .map_values_start, .alt_check => {
                if (r.operand.index >= p) r.operand.index += 1;
            },
            // try_begin/try_end use 0 as a sentinel (no handler / no jump), so only
            // fix up non-zero indices.
            .try_begin, .try_end => {
                if (r.operand.index > 0 and r.operand.index >= p) r.operand.index += 1;
            },
            else => {},
        }
    }
    // Fix up function-table body ranges.
    for (ctx.function_table.items) |*func| {
        if (func.body_start_raw >= p) func.body_start_raw += 1;
        if (func.body_end_raw >= p) func.body_end_raw += 1;
        if (func.def_func_raw_ip >= p) func.def_func_raw_ip += 1;
    }
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

/// Lookahead: returns true if the token stream starts with a path expression
/// followed by an update-assignment operator (|=, +=, -=, *=, /=, %=, //=).
/// Pure scan — no instructions emitted, lexer position restored via defer.
fn peekIsUpdateAssign(ctx: *Ctx) ZqError!bool {
    const saved_pos = ctx.lex.pos;
    defer ctx.lex.pos = saved_pos;

    const first = try ctx.lex.next();
    if (first.tag != .dot) return false;

    while (true) {
        const t = try ctx.lex.peek();
        switch (t.tag) {
            .ident => {
                _ = try ctx.lex.next();
                const sep = try ctx.lex.peek();
                if (sep.tag == .dot) _ = try ctx.lex.next();
            },
            .lbracket => {
                _ = try ctx.lex.next();
                const inner = try ctx.lex.next();
                switch (inner.tag) {
                    .int_lit, .string_lit => {
                        const close = try ctx.lex.next();
                        if (close.tag != .rbracket) return false;
                        const sep = try ctx.lex.peek();
                        if (sep.tag == .dot) _ = try ctx.lex.next();
                    },
                    else => return false,
                }
            },
            .pipe_eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .double_slash_eq => return true,
            else => return false,
        }
    }
}

/// Parse and emit an update-assignment expression.
/// Called only when peekIsUpdateAssign() returned true.
/// Handles: .path |= f, .path += rhs, .path -= rhs, etc.
fn parseUpdateAssign(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Consume the leading dot
    _ = try ctx.lex.next();

    // Collect path steps
    var path_steps = std.ArrayList(PathStep){};
    defer path_steps.deinit(ctx.alloc);

    while (true) {
        const t = try ctx.lex.peek();
        switch (t.tag) {
            .ident => {
                _ = try ctx.lex.next();
                const ref = try internStr(&ctx.intern, ctx.alloc, t.slice(ctx.src));
                try path_steps.append(ctx.alloc, PathStep{ .kind = .key, .key = ref });
                const sep = try ctx.lex.peek();
                if (sep.tag == .dot) _ = try ctx.lex.next();
            },
            .lbracket => {
                _ = try ctx.lex.next();
                const inner = try ctx.lex.peek();
                switch (inner.tag) {
                    .int_lit => {
                        const tok = try ctx.lex.next();
                        const n = std.fmt.parseInt(i64, tok.slice(ctx.src), 10) catch return error.QuerySyntaxError;
                        if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) return error.QuerySyntaxError;
                        const close = try ctx.lex.next();
                        if (close.tag != .rbracket) return error.QuerySyntaxError;
                        try path_steps.append(ctx.alloc, PathStep{ .kind = .index, .index = n });
                        const sep = try ctx.lex.peek();
                        if (sep.tag == .dot) _ = try ctx.lex.next();
                    },
                    .string_lit => {
                        const tok = try ctx.lex.next();
                        const raw_str = tok.slice(ctx.src);
                        const content = raw_str[1 .. raw_str.len - 1];
                        const ref = try internDecodedStr(&ctx.intern, ctx.alloc, content);
                        const close = try ctx.lex.next();
                        if (close.tag != .rbracket) return error.QuerySyntaxError;
                        try path_steps.append(ctx.alloc, PathStep{ .kind = .key, .key = ref });
                        const sep = try ctx.lex.peek();
                        if (sep.tag == .dot) _ = try ctx.lex.next();
                    },
                    else => return error.QuerySyntaxError,
                }
            },
            .pipe_eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .double_slash_eq => break,
            else => break,
        }
    }

    // Emit navigation: for each path step, save_input then navigate_key/index
    for (path_steps.items) |step| {
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .save_input, .operand = .{ .none = {} } });
        switch (step.kind) {
            .key => try ctx.raw.append(ctx.alloc, RawInstr{
                .op = .navigate_key,
                .operand = .{ .str_ref = step.key },
            }),
            .index => try ctx.raw.append(ctx.alloc, RawInstr{
                .op = .navigate_index,
                .operand = .{ .index = step.index },
            }),
        }
    }

    // Consume the assignment operator
    const assign_tok = try ctx.lex.next();

    // Parse RHS and emit arithmetic wrapper if needed
    switch (assign_tok.tag) {
        .pipe_eq => try parseAlternative(ctx),
        .plus_eq => {
            try parseAlternative(ctx);
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .add, .operand = .{ .none = {} } });
        },
        .minus_eq => {
            try parseAlternative(ctx);
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .sub, .operand = .{ .none = {} } });
        },
        .star_eq => {
            try parseAlternative(ctx);
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .mul, .operand = .{ .none = {} } });
        },
        .slash_eq => {
            try parseAlternative(ctx);
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .div, .operand = .{ .none = {} } });
        },
        .percent_eq => {
            try parseAlternative(ctx);
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .mod, .operand = .{ .none = {} } });
        },
        .double_slash_eq => {
            // .path //= rhs  →  .path |= (. // rhs)
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .alt_start, .operand = .{ .none = {} } });
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .identity, .operand = .{ .none = {} } });
            const check_pos = ctx.raw.items.len;
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .alt_check, .operand = .{ .index = 0 } });
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .restore_input, .operand = .{ .none = {} } });
            try parseAlternative(ctx);
            ctx.raw.items[check_pos].operand = .{ .index = @intCast(ctx.raw.items.len) };
        },
        else => return error.QuerySyntaxError,
    }

    // Emit update instructions in REVERSE path order
    var i = path_steps.items.len;
    while (i > 0) {
        i -= 1;
        const step = path_steps.items[i];
        switch (step.kind) {
            .key => try ctx.raw.append(ctx.alloc, RawInstr{
                .op = .update_key,
                .operand = .{ .str_ref = step.key },
            }),
            .index => try ctx.raw.append(ctx.alloc, RawInstr{
                .op = .update_index,
                .operand = .{ .index = step.index },
            }),
        }
    }
}

fn parsePipe(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    if (try peekIsUpdateAssign(ctx)) {
        try parseUpdateAssign(ctx);
        return;
    }
    try parseAlternative(ctx);
    while (true) {
        const t = try ctx.lex.peek();
        if (t.tag != .pipe) break;
        _ = try ctx.lex.next();
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
        try parseAlternative(ctx);
    }
}

/// parseAlternative: `//` (alternative operator / null coalescing).
/// Precedence: lower than `or`/`and`, higher than `|`.
///
/// For `a // b` emits:
///   alt_start             ← push current to if_stack; enable implicit null propagation
///   <a>
///   alt_check → after_b   ← decrement null-prop depth; if truthy keep value and jump;
///                           if falsy discard and fall through to restore_input
///   restore_input         ← restore original input for right-side evaluation
///   <b>
///   after_b:
///
/// For chained `a // b // c` a second alt_start is inserted at chain_start on the
/// second iteration, wrapping the entire left subtree.
fn parseAlternative(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const chain_start: usize = ctx.raw.items.len;
    try parseLogical(ctx);
    while (true) {
        const t = try ctx.lex.peek();
        if (t.tag != .double_slash) break;
        _ = try ctx.lex.next();

        // Insert alt_start before the entire left subtree.
        // insertRawInstr fixes all existing jump targets ≥ chain_start.
        try insertRawInstr(ctx, chain_start, RawInstr{ .op = .alt_start, .operand = .{ .none = {} } });

        // Emit alt_check with a placeholder target (backpatched after parsing right).
        const check_pos = ctx.raw.items.len;
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .alt_check, .operand = .{ .index = 0 } });

        // restore_input fires only on the falsy path so the right expr sees the saved input.
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .restore_input, .operand = .{ .none = {} } });

        // Parse the right expression.
        try parseLogical(ctx);

        // Backpatch alt_check to jump here (one past the right expr).
        ctx.raw.items[check_pos].operand = .{ .index = @intCast(ctx.raw.items.len) };
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

/// Zero-argument builtins: emitted as call_builtin(id) with no parens consumed.
fn zeroArgBuiltinId(name: []const u8) ?types.BuiltinId {
    if (std.mem.eql(u8, name, "length")) return .length;
    if (std.mem.eql(u8, name, "keys")) return .keys;
    if (std.mem.eql(u8, name, "keys_unsorted")) return .keys_unsorted;
    if (std.mem.eql(u8, name, "values")) return .values_sel;
    if (std.mem.eql(u8, name, "type")) return .type_;
    if (std.mem.eql(u8, name, "empty")) return .empty;
    if (std.mem.eql(u8, name, "tostring")) return .tostring;
    if (std.mem.eql(u8, name, "tonumber")) return .tonumber;
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

    // Type selectors (Group A)
    if (std.mem.eql(u8, name, "arrays")) return .arrays;
    if (std.mem.eql(u8, name, "objects")) return .objects_sel;
    if (std.mem.eql(u8, name, "strings")) return .strings_sel;
    if (std.mem.eql(u8, name, "numbers")) return .numbers_sel;
    if (std.mem.eql(u8, name, "booleans")) return .booleans_sel;
    if (std.mem.eql(u8, name, "nulls")) return .nulls_sel;
    if (std.mem.eql(u8, name, "scalars")) return .scalars_sel;
    if (std.mem.eql(u8, name, "iterables")) return .iterables_sel;

    // Math builtins (Group B)
    if (std.mem.eql(u8, name, "floor")) return .floor;
    if (std.mem.eql(u8, name, "ceil")) return .ceil;
    if (std.mem.eql(u8, name, "round")) return .round;
    if (std.mem.eql(u8, name, "sqrt")) return .sqrt;
    if (std.mem.eql(u8, name, "fabs")) return .fabs;
    if (std.mem.eql(u8, name, "nan")) return .nan_val;
    if (std.mem.eql(u8, name, "infinite")) return .infinite_val;
    if (std.mem.eql(u8, name, "isnan")) return .isnan_val;
    if (std.mem.eql(u8, name, "isinfinite")) return .isinfinite_val;
    if (std.mem.eql(u8, name, "isnormal")) return .isnormal_val;
    if (std.mem.eql(u8, name, "log2")) return .log2_;
    if (std.mem.eql(u8, name, "log")) return .log_;
    if (std.mem.eql(u8, name, "exp")) return .exp_;
    if (std.mem.eql(u8, name, "exp2")) return .exp2_;
    if (std.mem.eql(u8, name, "sin")) return .sin_;
    if (std.mem.eql(u8, name, "cos")) return .cos_;
    if (std.mem.eql(u8, name, "atan")) return .atan_;
    if (std.mem.eql(u8, name, "tan")) return .tan_;
    if (std.mem.eql(u8, name, "asin")) return .asin_;
    if (std.mem.eql(u8, name, "acos")) return .acos_;
    if (std.mem.eql(u8, name, "sinh")) return .sinh_;
    if (std.mem.eql(u8, name, "cosh")) return .cosh_;
    if (std.mem.eql(u8, name, "tanh")) return .tanh_;
    if (std.mem.eql(u8, name, "significand")) return .significand;
    if (std.mem.eql(u8, name, "exponent")) return .exponent_;
    if (std.mem.eql(u8, name, "logb")) return .logb_;
    if (std.mem.eql(u8, name, "abs")) return .abs;

    // String builtins (Group C) — zero-arg
    if (std.mem.eql(u8, name, "ascii_downcase")) return .ascii_downcase;
    if (std.mem.eql(u8, name, "ascii_upcase")) return .ascii_upcase;
    if (std.mem.eql(u8, name, "explode")) return .explode;
    if (std.mem.eql(u8, name, "implode")) return .implode;
    if (std.mem.eql(u8, name, "tojson")) return .tojson;
    if (std.mem.eql(u8, name, "fromjson")) return .fromjson;
    if (std.mem.eql(u8, name, "toboolean")) return .toboolean;
    if (std.mem.eql(u8, name, "ascii")) return .ascii_val;

    // Misc builtins (Group D) — zero-arg
    if (std.mem.eql(u8, name, "utf8bytelength")) return .utf8bytelength;
    if (std.mem.eql(u8, name, "transpose")) return .transpose;
    if (std.mem.eql(u8, name, "builtins")) return .builtins_list;
    if (std.mem.eql(u8, name, "have_decnum")) return .have_decnum;

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
        std.mem.eql(u8, name, "pow") or
        // String arg builtins (Group C)
        std.mem.eql(u8, name, "ltrimstr") or
        std.mem.eql(u8, name, "rtrimstr") or
        std.mem.eql(u8, name, "startswith") or
        std.mem.eql(u8, name, "endswith") or
        std.mem.eql(u8, name, "split") or
        std.mem.eql(u8, name, "join") or
        // Misc arg builtins (Group D)
        std.mem.eql(u8, name, "map_values") or
        std.mem.eql(u8, name, "isempty") or
        std.mem.eql(u8, name, "bsearch") or
        std.mem.eql(u8, name, "add");
}

/// Compile a `map(f)` expression.
/// Desugars to: array_collect_start | iterate | <f> | output | array_collect_end
fn compileMap(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Consume opening paren
    _ = try ctx.lex.next();

    // Emit array_collect_start with placeholder end_ip
    const start_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_start, .operand = .{ .index = 0 } });

    // Emit iterate: iterates over current value
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .iterate, .operand = .{ .none = {} } });

    // Parse the mapping expression (full filter to support pipes/alternatives)
    try parsePipe(ctx);

    // Emit output to collect each element
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .output, .operand = .{ .none = {} } });

    // Consume closing paren
    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;

    // Emit array_collect_end and backpatch start
    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_end, .operand = .{ .none = {} } });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };
}

/// Compile `map_values(f)`: apply f to each value, preserving object keys.
/// Uses map_values_start/end opcodes so the VM can reconstruct objects at runtime.
fn compileMapValues(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('

    const start_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .map_values_start, .operand = .{ .index = 0 } });

    // Iterate over elements/values
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .iterate, .operand = .{ .none = {} } });

    // Parse the mapping expression (full filter)
    try parsePipe(ctx);

    // Collect each output
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .output, .operand = .{ .none = {} } });

    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;

    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .map_values_end, .operand = .{ .none = {} } });
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
    _ = try ctx.lex.next();

    // save_input so we can restore the original for output
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .save_input, .operand = .{ .none = {} } });

    // Parse the predicate expression
    try parseLogical(ctx);

    // Consume closing paren
    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;

    // jump_if_false → skip (placeholder)
    const jif_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .jump_if_false, .operand = .{ .index = 0 } });

    // Truthy path: restore_input (gives original value as output)
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .restore_input, .operand = .{ .none = {} } });

    // jump → done (placeholder)
    const jmp_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .jump, .operand = .{ .index = 0 } });

    // skip: restore_input then call_builtin(empty)
    const skip_ip: u32 = @intCast(ctx.raw.items.len);
    ctx.raw.items[jif_pos].operand = .{ .index = skip_ip };
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .restore_input, .operand = .{ .none = {} } });
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.empty) },
    });

    // done:
    const done_ip: u32 = @intCast(ctx.raw.items.len);
    ctx.raw.items[jmp_pos].operand = .{ .index = done_ip };
}

/// Compile `has(expr)`: compile expr (pushes key), then call_builtin(has).
fn compileHas(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('
    try parseLogical(ctx);
    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.has) },
    });
}

/// Compile `in(expr)`: save_input, compile expr (pushes object), call_builtin(in_).
fn compileIn(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .save_input, .operand = .{ .none = {} } });
    try parseLogical(ctx);
    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.in_) },
    });
}

/// Compile `range(n)`, `range(from;to)`, or `range(from;to;by)`.
fn compileRange(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('

    // Parse first argument
    try parseLogical(ctx);

    // Check for semicolons
    const t1 = try ctx.lex.peek();
    if (t1.tag == .rparen) {
        _ = try ctx.lex.next();
        try ctx.raw.append(ctx.alloc, RawInstr{
            .op = .call_builtin,
            .operand = .{ .index = @intFromEnum(types.BuiltinId.range) },
        });
        return;
    }
    if (t1.tag != .semicolon) return error.QuerySyntaxError;
    _ = try ctx.lex.next(); // consume ';'

    // Parse second argument
    try parseLogical(ctx);

    const t2 = try ctx.lex.peek();
    if (t2.tag == .rparen) {
        _ = try ctx.lex.next();
        try ctx.raw.append(ctx.alloc, RawInstr{
            .op = .call_builtin,
            .operand = .{ .index = @intFromEnum(types.BuiltinId.range2) },
        });
        return;
    }
    if (t2.tag != .semicolon) return error.QuerySyntaxError;
    _ = try ctx.lex.next(); // consume ';'

    // Parse third argument
    try parseLogical(ctx);

    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.range3) },
    });
}

// ── Tier 2 arg-taking builtins ──────────────────────────────────────────────

/// Compile `flatten(n)`: compile arg (pushes depth), then call_builtin(flatten_n).
fn compileFlattenN(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('
    try parseLogical(ctx);
    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.flatten_n) },
    });
}

/// Compile `contains(b)`: compile arg (pushes b), then call_builtin(contains).
fn compileContains(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('
    try parseLogical(ctx);
    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.contains) },
    });
}

/// Compile `inside(b)`: compile arg (pushes b), then call_builtin(inside).
fn compileInside(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('
    try parseLogical(ctx);
    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.inside) },
    });
}

/// Compile `indices(s)`: compile arg, then call_builtin(indices).
fn compileIndices(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('
    try parseLogical(ctx);
    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.indices) },
    });
}

/// Compile `index(s)`: compile arg, then call_builtin(index_).
fn compileIndex(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('
    try parseLogical(ctx);
    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.index_) },
    });
}

/// Compile `rindex(s)`: compile arg, then call_builtin(rindex).
fn compileRindex(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('
    try parseLogical(ctx);
    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.rindex) },
    });
}

/// Compile filter-arg builtins (sort_by, group_by, min_by, max_by, unique_by).
/// Pattern: save_input, array_collect_start, iterate, <f>, output, array_collect_end, call_builtin(X)
fn compileFilterArgBuiltin(ctx: *Ctx, bid: types.BuiltinId) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('

    // Save original array so we can pair elements with keys
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .save_input, .operand = .{ .none = {} } });

    // Collect keys: [.[] | f]
    const start_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_start, .operand = .{ .index = 0 } });
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .iterate, .operand = .{ .none = {} } });

    // Parse the filter expression
    try parseLogical(ctx);

    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .output, .operand = .{ .none = {} } });

    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;

    // array_collect_end
    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_end, .operand = .{ .none = {} } });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };

    // call_builtin — pops keys array from value_stack, original array from if_stack
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(bid) },
    });
}

/// Compile `with_entries(f)`: desugar to `to_entries | map(f) | from_entries`.
fn compileWithEntries(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('

    // to_entries
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.to_entries) },
    });
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });

    // map(f): array_collect_start, iterate, <f>, output, array_collect_end
    const start_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_start, .operand = .{ .index = 0 } });
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .iterate, .operand = .{ .none = {} } });

    // Parse the filter expression
    try parseLogical(ctx);

    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .output, .operand = .{ .none = {} } });

    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;

    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_end, .operand = .{ .none = {} } });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };

    // from_entries
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.from_entries) },
    });
}

/// Compile `any(f)` or `all(f)` with 1 or 2 args.
/// 1 arg: desugar to `[.[] | f] | any/all`
/// 2 args: desugar to `[gen | cond] | any/all`
fn compileAnyAll(ctx: *Ctx, bid: types.BuiltinId) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('

    // Collect outputs: array_collect_start
    const start_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_start, .operand = .{ .index = 0 } });

    // Parse first arg (either the filter f, or the generator gen)
    try parseLogical(ctx);

    // Check for semicolon (2-arg form: any(gen;cond))
    const semi = try ctx.lex.peek();
    if (semi.tag == .semicolon) {
        _ = try ctx.lex.next(); // consume ';'
        // First arg was the generator. Pipe into it, then parse cond.
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
        try parseLogical(ctx);
    } else {
        // 1-arg form: desugar to [.[] | f]
        // We need to insert iterate before the filter. Use insertRawInstr.
        // Actually, we need: iterate, <f>. The filter is already emitted.
        // Insert iterate before the filter.
        try insertRawInstr(ctx, start_pos + 1, RawInstr{ .op = .iterate, .operand = .{ .none = {} } });
    }

    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .output, .operand = .{ .none = {} } });

    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;

    // array_collect_end
    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_end, .operand = .{ .none = {} } });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };

    // pipe + call any/all
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(bid) },
    });
}

/// Compile `first(f)`: desugar to `[f] | .[0]`.
/// Actually, more efficient: just collect first output. For now, use `[f] | .[0]`.
fn compileFirst(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('

    // Collect [f]
    const start_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_start, .operand = .{ .index = 0 } });

    try parsePipe(ctx);

    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .output, .operand = .{ .none = {} } });

    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;

    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_end, .operand = .{ .none = {} } });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };

    // .[0]
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .load_index, .operand = .{ .index = 0 } });
}

/// Compile `last(f)`: desugar to `[f] | .[-1]`.
fn compileLast(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('

    // Collect [f]
    const start_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_start, .operand = .{ .index = 0 } });

    try parsePipe(ctx);

    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .output, .operand = .{ .none = {} } });

    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;

    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_end, .operand = .{ .none = {} } });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };

    // .[-1]
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .load_index, .operand = .{ .index = -1 } });
}

/// Compile `limit(n;f)`: currently collects all outputs of f into an array.
/// TODO: Implement proper early termination via limit_start/limit_end opcodes.
/// Without dynamic slicing or early-termination opcodes, this collects all outputs
/// of f and returns them as an array. Callers like `first(f)` desugar to
/// `[f] | .[0]` which avoids needing limit entirely.
fn compileLimit(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('

    // Parse n (currently unused — full limit needs dynamic slicing or new opcodes)
    try parseLogical(ctx);

    const semi = try ctx.lex.next();
    if (semi.tag != .semicolon) return error.QuerySyntaxError;

    // Discard n from the value stack
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });

    // Collect [f]
    const start_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_start, .operand = .{ .index = 0 } });

    try parsePipe(ctx);

    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .output, .operand = .{ .none = {} } });

    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;

    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_end, .operand = .{ .none = {} } });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };
}

/// Compile `del(.key)` or `del(.[n])`: static single-level path deletion.
fn compileDel(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('

    // Parse the path expression inside del()
    const path_tok = try ctx.lex.next();
    if (path_tok.tag != .dot) return error.QuerySyntaxError;

    const next_tok = try ctx.lex.peek();
    switch (next_tok.tag) {
        .ident => {
            // del(.key) — push key string, call_builtin(del)
            const ident = try ctx.lex.next();
            const ref = try internStr(&ctx.intern, ctx.alloc, ident.slice(ctx.src));
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_string, .operand = .{ .str_ref = ref } });
        },
        .lbracket => {
            // del(.[n]) or del(.["key"])
            _ = try ctx.lex.next(); // consume '['
            const inner = try ctx.lex.peek();
            switch (inner.tag) {
                .int_lit => {
                    const tok = try ctx.lex.next();
                    const n = std.fmt.parseInt(i64, tok.slice(ctx.src), 10) catch return error.QuerySyntaxError;
                    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_int, .operand = .{ .int = n } });
                },
                .string_lit => {
                    const tok = try ctx.lex.next();
                    const raw_str = tok.slice(ctx.src);
                    const content = raw_str[1 .. raw_str.len - 1];
                    const ref = try internDecodedStr(&ctx.intern, ctx.alloc, content);
                    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_string, .operand = .{ .str_ref = ref } });
                },
                .minus => {
                    _ = try ctx.lex.next(); // consume '-'
                    const num_tok = try ctx.lex.next();
                    if (num_tok.tag != .int_lit) return error.QuerySyntaxError;
                    const n = std.fmt.parseInt(i64, num_tok.slice(ctx.src), 10) catch return error.QuerySyntaxError;
                    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_int, .operand = .{ .int = -n } });
                },
                else => return error.QuerySyntaxError,
            }
            const close = try ctx.lex.next();
            if (close.tag != .rbracket) return error.QuerySyntaxError;
        },
        else => return error.QuerySyntaxError,
    }

    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;

    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.del) },
    });
}

/// Compile a simple arg-taking builtin: `name(expr)`.
/// Parses `(expr)`, then emits `call_builtin(bid)`.
fn compileSimpleArgBuiltin(ctx: *Ctx, bid: types.BuiltinId) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('
    try parsePipe(ctx);
    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(bid) },
    });
}

/// Compile `add(f)`: collect all outputs of f into an array, then add.
/// Desugars to: [f] | add
fn compileAddWithArg(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('

    // Emit array_collect_start with placeholder end_ip
    const start_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_start, .operand = .{ .index = 0 } });

    // Parse the generator expression (handles comma-separated generators)
    try parsePipe(ctx);

    // Consume closing paren
    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;

    // Emit output to collect each element
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .output, .operand = .{ .none = {} } });

    // Emit array_collect_end and backpatch start
    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_end, .operand = .{ .none = {} } });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };

    // Pipe to add
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.add) },
    });
}

/// Compile `isempty(f)`: true if f produces no output, false otherwise.
/// Desugars to: [f | false] | length == 0
fn compileIsempty(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('

    // Emit array_collect_start
    const collect_start_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_start, .operand = .{ .index = 0 } });

    // Parse the inner filter f
    try parsePipe(ctx);

    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;

    // Emit: pipe, push_bool(false), output — produces false for each output of f
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_bool, .operand = .{ .bool = false } });
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .output, .operand = .{ .none = {} } });

    // Emit array_collect_end
    const collect_end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_end, .operand = .{ .none = {} } });
    ctx.raw.items[collect_start_pos].operand = .{ .index = collect_end_pos };

    // Pipe to check: length == 0
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.length) },
    });
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_int, .operand = .{ .int = 0 } });
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .eq, .operand = .{ .none = {} } });
}

/// Compile `pow(base; exp)`: two semicolon-separated args.
fn compilePow(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    _ = try ctx.lex.next(); // consume '('
    try parsePipe(ctx); // parse base
    const semi = try ctx.lex.next();
    if (semi.tag != .semicolon) return error.QuerySyntaxError;
    try parsePipe(ctx); // parse exponent
    const rparen = try ctx.lex.next();
    if (rparen.tag != .rparen) return error.QuerySyntaxError;
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .call_builtin,
        .operand = .{ .index = @intFromEnum(types.BuiltinId.pow_) },
    });
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
        .string_lit => {
            const raw_str = t.slice(ctx.src);
            // Strip surrounding double-quotes, then decode JSON escape sequences.
            const content = raw_str[1 .. raw_str.len - 1];
            const ref = try internDecodedStr(&ctx.intern, ctx.alloc, content);
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_string, .operand = .{ .str_ref = ref } });
        },
        .int_lit => {
            const n = std.fmt.parseInt(i64, t.slice(ctx.src), 10) catch return error.QuerySyntaxError;
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_int, .operand = .{ .int = n } });
        },
        .float_lit => {
            const f = std.fmt.parseFloat(f64, t.slice(ctx.src)) catch return error.QuerySyntaxError;
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_float, .operand = .{ .float = f } });
        },
        .minus => {
            // Unary minus as a primary expression (e.g. catch -1, or -1 in object values).
            try parsePrimary(ctx);
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .negate, .operand = .{ .none = {} } });
        },
        .ident => {
            const ident_name = t.slice(ctx.src);
            const peek = try ctx.lex.peek();

            // `null` is a soft keyword: emit push_null when used as a standalone value.
            if (std.mem.eql(u8, ident_name, "null")) {
                try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_null, .operand = .{ .none = {} } });
                return;
            }

            // Builtins that can be zero-arg OR one-arg: check for '(' first.
            // If followed by '(', fall through to arg-builtin dispatch.
            if (peek.tag == .lparen and isArgBuiltin(ident_name)) {
                // Will be handled by the arg-builtin dispatch below
            } else if (zeroArgBuiltinId(ident_name)) |bid| {
                // Zero-arg builtins: length, keys, values, type, empty, tostring, tonumber, error, add, keys_unsorted
                // These do NOT consume parens even if followed by '(' (which would be chaining).
                try ctx.raw.append(ctx.alloc, RawInstr{
                    .op = .call_builtin,
                    .operand = .{ .index = @intFromEnum(bid) },
                });
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
                } else if (std.mem.eql(u8, ident_name, "pow")) {
                    try compilePow(ctx);
                } else if (std.mem.eql(u8, ident_name, "ltrimstr")) {
                    try compileSimpleArgBuiltin(ctx, .ltrimstr);
                } else if (std.mem.eql(u8, ident_name, "rtrimstr")) {
                    try compileSimpleArgBuiltin(ctx, .rtrimstr);
                } else if (std.mem.eql(u8, ident_name, "startswith")) {
                    try compileSimpleArgBuiltin(ctx, .startswith);
                } else if (std.mem.eql(u8, ident_name, "endswith")) {
                    try compileSimpleArgBuiltin(ctx, .endswith);
                } else if (std.mem.eql(u8, ident_name, "split")) {
                    try compileSimpleArgBuiltin(ctx, .split_);
                } else if (std.mem.eql(u8, ident_name, "join")) {
                    try compileSimpleArgBuiltin(ctx, .join_);
                } else if (std.mem.eql(u8, ident_name, "map_values")) {
                    try compileMapValues(ctx);
                } else if (std.mem.eql(u8, ident_name, "isempty")) {
                    try compileIsempty(ctx);
                } else if (std.mem.eql(u8, ident_name, "bsearch")) {
                    try compileSimpleArgBuiltin(ctx, .bsearch);
                } else if (std.mem.eql(u8, ident_name, "add")) {
                    try compileAddWithArg(ctx);
                }
                return;
            }

            // Zero-arg first/last: no parens needed
            if (std.mem.eql(u8, ident_name, "first")) {
                try ctx.raw.append(ctx.alloc, RawInstr{ .op = .load_index, .operand = .{ .index = 0 } });
                return;
            }
            if (std.mem.eql(u8, ident_name, "last")) {
                try ctx.raw.append(ctx.alloc, RawInstr{ .op = .load_index, .operand = .{ .index = -1 } });
                return;
            }

            // User-defined function call
            if (peek.tag == .lparen) {
                const name_ref = try internStr(&ctx.intern, ctx.alloc, ident_name);
                const func_id = lookupFunction(ctx, name_ref) orelse return error.QuerySyntaxError;
                _ = try ctx.lex.next(); // consume '('
                var arg_count: usize = 0;
                while (true) {
                    const next_tok = try ctx.lex.peek();
                    if (next_tok.tag == .rparen) {
                        _ = try ctx.lex.next();
                        break;
                    }
                    try parseLogical(ctx);
                    arg_count += 1;
                    const sep_tok = try ctx.lex.peek();
                    if (sep_tok.tag == .semicolon) {
                        _ = try ctx.lex.next();
                    } else if (sep_tok.tag != .rparen) {
                        return error.QuerySyntaxError;
                    }
                }
                try ctx.raw.append(ctx.alloc, RawInstr{ .op = .call_function, .operand = .{ .index = func_id } });
                return;
            }

            // Plain identifier → field access
            const ref = try internStr(&ctx.intern, ctx.alloc, ident_name);
            const start = ctx.raw.items.len;
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .load_key, .operand = .{ .str_ref = ref } });
            try parseSuffixes(ctx, start);
        },
        .dot => {
            const after = try ctx.lex.peek();
            switch (after.tag) {
                .ident => {
                    _ = try ctx.lex.next();
                    const ref = try internStr(&ctx.intern, ctx.alloc, after.slice(ctx.src));
                    const start = ctx.raw.items.len;
                    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .load_key, .operand = .{ .str_ref = ref } });
                    try parseSuffixes(ctx, start);
                },
                .lbracket => {
                    _ = try ctx.lex.next();
                    const start = ctx.raw.items.len;
                    try parseBracket(ctx);
                    try parseSuffixes(ctx, start);
                },
                else => {
                    // Bare dot — push the current value onto the stack.
                    // Using push_current ensures the value is available for binary operators
                    // (arithmetic, comparison) regardless of evaluation order.
                    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_current, .operand = .{ .none = {} } });
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
        .if_kw => {
            // Conditional: if COND then THEN [elif COND then THEN]* [else ELSE] end
            try parseIfBody(ctx);
        },
        .try_kw => {
            // try EXPR [catch EXPR]
            try parseTryCatch(ctx);
        },
        .lbracket => {
            // Array construction: [expr] — collect all outputs of expr into an array.
            try parseArrayConstruct(ctx);
        },
        else => return error.QuerySyntaxError,
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
///   try_begin(catch_ip=0)    ← 0 = suppress on error
///   <EXPR>
///   try_end(after_ip=0)      ← 0 = no handler to skip; ip+1
///
/// Emits for `try EXPR catch HDLR`:
///   try_begin(catch_ip=N)    ← N = first instruction of HDLR
///   <EXPR>
///   try_end(after_ip=M)      ← M = first instruction past HDLR
///   N: <HDLR>                ← handler receives error string as `current`
///   M: (next instruction)
fn parseTryCatch(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    // Emit try_begin with placeholder catch_ip (backpatched if catch is present).
    const try_begin_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .try_begin, .operand = .{ .index = 0 } });

    // Parse the try body at primary level so that `|` is left to the outer pipe.
    try parsePrimary(ctx);

    const t = try ctx.lex.peek();
    if (t.tag == .catch_kw) {
        _ = try ctx.lex.next(); // consume 'catch'

        // Emit try_end with placeholder after_ip (backpatched after parsing handler).
        const try_end_pos = ctx.raw.items.len;
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .try_end, .operand = .{ .index = 0 } });

        // Backpatch try_begin to point at the first instruction of the handler.
        const catch_ip: u32 = @intCast(ctx.raw.items.len);
        ctx.raw.items[try_begin_pos].operand = .{ .index = catch_ip };

        // Parse the catch handler at primary level.
        try parsePrimary(ctx);

        // Backpatch try_end to jump past the handler.
        ctx.raw.items[try_end_pos].operand = .{ .index = @intCast(ctx.raw.items.len) };
    } else {
        // No catch: try_end with sentinel 0 means "no jump, ip+1".
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .try_end, .operand = .{ .index = 0 } });
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
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .save_input, .operand = .{ .none = {} } });

    // Parse condition (stops at 'then').
    try parsePipe(ctx);

    // Expect 'then'.
    const then_tok = try ctx.lex.next();
    if (then_tok.tag != .then_kw) return error.QuerySyntaxError;

    // Emit conditional jump with a placeholder target (backpatched below).
    const jif_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .jump_if_false, .operand = .{ .index = 0 } });

    // Restore input before the then-branch.
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .restore_input, .operand = .{ .none = {} } });

    // Parse then-body (stops at elif/else/end).
    try parsePipe(ctx);

    // Unconditional jump to skip the else-branch (placeholder backpatched below).
    const jmp_pos = ctx.raw.items.len;
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .jump, .operand = .{ .index = 0 } });

    // Backpatch jump_if_false to point here (start of else-branch).
    ctx.raw.items[jif_pos].operand = .{ .index = @intCast(ctx.raw.items.len) };

    // Restore input before the else-branch.
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .restore_input, .operand = .{ .none = {} } });

    // Parse elif / else / end.
    const next_tok = try ctx.lex.peek();
    switch (next_tok.tag) {
        .elif_kw => {
            _ = try ctx.lex.next(); // consume 'elif'
            // Recursively compile the elif as a nested if body.
            try parseIfBody(ctx);
        },
        .else_kw => {
            _ = try ctx.lex.next(); // consume 'else'
            try parsePipe(ctx); // parse else-body
            const end_tok = try ctx.lex.next();
            if (end_tok.tag != .end_kw) return error.QuerySyntaxError;
        },
        .end_kw => {
            _ = try ctx.lex.next(); // consume 'end'
            // Implicit else: `.` — identity, passes current through.
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .identity, .operand = .{ .none = {} } });
        },
        else => return error.QuerySyntaxError,
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
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_start, .operand = .{ .index = 0 } });

    const peek = try ctx.lex.peek();
    if (peek.tag != .rbracket) {
        // Parse the inner expression (generator).
        try parsePipe(ctx);
        // Emit an explicit output inside the collect scope. The VM intercepts
        // this in collect mode: instead of yielding, it buffers the value.
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .output, .operand = .{ .none = {} } });
    }

    // Consume the closing `]`.
    const close = try ctx.lex.next();
    if (close.tag != .rbracket) return error.QuerySyntaxError;

    // Emit array_collect_end and backpatch start.
    const end_pos: u32 = @intCast(ctx.raw.items.len);
    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .array_collect_end, .operand = .{ .none = {} } });
    ctx.raw.items[start_pos].operand = .{ .index = end_pos };
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
    } else if (peek.tag == .string_lit) {
        // Quoted string key: strip surrounding double-quotes, decode escape sequences.
        const key = try ctx.lex.next();
        const raw = key.slice(ctx.src);
        const content = raw[1 .. raw.len - 1];
        const ref = try internDecodedStr(&ctx.intern, ctx.alloc, content);
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .push_string, .operand = .{ .str_ref = ref } });
    } else if (peek.tag == .ident or peek.tag == .int_lit or peek.tag == .float_lit or
        peek.tag == .true_kw or peek.tag == .false_kw or
        peek.tag == .if_kw or peek.tag == .then_kw or peek.tag == .elif_kw or
        peek.tag == .else_kw or peek.tag == .end_kw or peek.tag == .and_kw or
        peek.tag == .or_kw or peek.tag == .not_kw or peek.tag == .def_kw or
        peek.tag == .as_kw or peek.tag == .reduce_kw)
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
                _ = try ctx.lex.next();
                const nt = try ctx.lex.peek();
                switch (nt.tag) {
                    .ident => {
                        _ = try ctx.lex.next();
                        // Emit pipe between successive suffix elements so each element
                        // sees the previous element's result in it.current.
                        if (had_suffix) {
                            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
                            segment_start = ctx.raw.items.len;
                        }
                        had_suffix = true;
                        const ref = try internStr(&ctx.intern, ctx.alloc, nt.slice(ctx.src));
                        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .load_key, .operand = .{ .str_ref = ref } });
                    },
                    .lbracket => {
                        _ = try ctx.lex.next();
                        if (had_suffix) {
                            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
                            segment_start = ctx.raw.items.len;
                        }
                        had_suffix = true;
                        try parseBracket(ctx);
                    },
                    .dollar => {
                        // .$var - variable reference
                        _ = try ctx.lex.next();
                        if (had_suffix) {
                            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
                            segment_start = ctx.raw.items.len;
                        }
                        had_suffix = true;
                        try parseVariableReference(ctx);
                    },
                    else => return error.QuerySyntaxError, // trailing dot
                }
            },
            .lbracket => {
                _ = try ctx.lex.next();
                if (had_suffix) {
                    try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
                    segment_start = ctx.raw.items.len;
                }
                had_suffix = true;
                try parseBracket(ctx);
            },
            .question => {
                _ = try ctx.lex.next();
                // Retroactively wrap the preceding segment in try_begin / try_end
                // (no catch handler — errors are suppressed silently).
                // insertRawInstr shifts all existing jump targets past segment_start.
                try insertRawInstr(ctx, segment_start, RawInstr{ .op = .try_begin, .operand = .{ .index = 0 } });
                try ctx.raw.append(ctx.alloc, RawInstr{ .op = .try_end, .operand = .{ .index = 0 } });
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
fn tryParseIndexInt(ctx: *Ctx) (ZqError || error{OutOfMemory})!?i64 {
    const peek = try ctx.lex.peek();
    if (peek.tag == .int_lit) {
        const tok = try ctx.lex.next();
        return std.fmt.parseInt(i64, tok.slice(ctx.src), 10) catch return error.QuerySyntaxError;
    }
    if (peek.tag == .minus) {
        // Peek one more token to see if it's an int_lit (unary minus in index context)
        _ = try ctx.lex.next(); // consume minus
        const after = try ctx.lex.peek();
        if (after.tag == .int_lit) {
            const tok = try ctx.lex.next();
            const n = std.fmt.parseInt(i64, tok.slice(ctx.src), 10) catch return error.QuerySyntaxError;
            return -n;
        }
        // Not a number after minus — this is a syntax error in index context
        return error.QuerySyntaxError;
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
        if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) return error.QuerySyntaxError;
        to = @intCast(n);
    }
    const close = try ctx.lex.next();
    if (close.tag != .rbracket) return error.QuerySyntaxError;
    try ctx.raw.append(ctx.alloc, RawInstr{
        .op = .slice,
        .operand = .{ .slice_args = types.SliceArgs{
            .from = from,
            .to = to,
            .has_from = has_from,
            .has_to = has_to,
        } },
    });
}

/// Parse the body of `[...]` (the opening `[` has already been consumed).
fn parseBracket(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const t = try ctx.lex.peek();
    switch (t.tag) {
        .rbracket => {
            _ = try ctx.lex.next();
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .iterate, .operand = .{ .none = {} } });
        },
        .colon => {
            // .[:n] or .[:] — slice with no left bound
            _ = try ctx.lex.next(); // consume ':'
            try parseSliceTail(ctx, false, 0);
        },
        .int_lit, .minus => {
            const n = (try tryParseIndexInt(ctx)) orelse return error.QuerySyntaxError;
            const after = try ctx.lex.peek();
            if (after.tag == .colon) {
                // .[n:...] — slice with left bound (negative allowed)
                _ = try ctx.lex.next(); // consume ':'
                if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) return error.QuerySyntaxError;
                try parseSliceTail(ctx, true, @intCast(n));
            } else {
                // .[n] — index access (negative allowed)
                if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) return error.QuerySyntaxError;
                const close = try ctx.lex.next();
                if (close.tag != .rbracket) return error.QuerySyntaxError;
                try ctx.raw.append(ctx.alloc, RawInstr{
                    .op = .load_index,
                    .operand = .{ .index = n },
                });
            }
        },
        .string_lit => {
            const tok = try ctx.lex.next();
            const raw_str = tok.slice(ctx.src);
            // Strip the surrounding double-quotes and decode escape sequences.
            const content = raw_str[1 .. raw_str.len - 1];
            const ref = try internDecodedStr(&ctx.intern, ctx.alloc, content);
            const close = try ctx.lex.next();
            if (close.tag != .rbracket) return error.QuerySyntaxError;
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .load_key, .operand = .{ .str_ref = ref } });
        },
        else => {
            // Computed access .[expr]: save base to if_stack, evaluate expr,
            // then load_computed pops base and applies current/top-of-stack as key.
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .save_input, .operand = .{ .none = {} } });
            try parsePipe(ctx);
            const close = try ctx.lex.next();
            if (close.tag != .rbracket) return error.QuerySyntaxError;
            try ctx.raw.append(ctx.alloc, RawInstr{ .op = .load_computed, .operand = .{ .none = {} } });
        },
    }
}

// ── String interning ──────────────────────────────────────────────────────────

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
                .load_computed => .{ .none = {} },
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
                // map_values construction: remap end_ip raw → fused index.
                .map_values_start => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .map_values_end => .{ .none = {} },
                // Alternative operator: remap jump target raw → fused index.
                .alt_start => .{ .none = {} },
                .alt_check => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = index_map.items[idx_usize];
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                // Try-catch: remap non-zero index operands (0 = sentinel, no jump).
                .try_begin => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = if (r.operand.index > 0) index_map.items[idx_usize] else 0;
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .try_end => blk: {
                    const idx_usize: usize = @intCast(r.operand.index);
                    const fused_idx = if (r.operand.index > 0) index_map.items[idx_usize] else 0;
                    break :blk .{ .index = @as(i64, @intCast(fused_idx)) };
                },
                .slice => .{ .slice_args = r.operand.slice_args },
                .navigate_key, .update_key => .{ .string = string_buf[r.operand.str_ref.offset..][0..r.operand.str_ref.len] },
                .navigate_index, .update_index => .{ .index = r.operand.index },
                // call_builtin: operand is BuiltinId encoded as index; pass through as-is.
                .call_builtin => .{ .index = r.operand.index },
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
