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
};

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn compile(src: []const u8, alloc: std.mem.Allocator) (ZqError || error{OutOfMemory})!Compiled {
    var ctx = Ctx{
        .src = src,
        .lex = Lexer.init(src),
        .raw = std.ArrayList(RawInstr){},
        .intern = std.ArrayList(u8){},
        .alloc = alloc,
    };
    defer ctx.raw.deinit(alloc);   // always freed; fuse() copies what it needs
    errdefer ctx.intern.deinit(alloc); // freed only on error; toOwnedSlice transfers on success

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
    try parseExpr(ctx);
    while (true) {
        const t = try ctx.lex.peek();
        if (t.tag != .pipe) break;
        _ = try ctx.lex.next();
        try ctx.raw.append(ctx.alloc, RawInstr{ .op = .pipe, .operand = .{ .none = {} } });
        try parseExpr(ctx);
    }
}

fn parseExpr(ctx: *Ctx) (ZqError || error{OutOfMemory})!void {
    const dot = try ctx.lex.next();
    if (dot.tag != .dot) return error.QuerySyntaxError;

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
}

/// Consume any chain of `.ident` or `[...]` suffixes following a primary expression.
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
                .load_index            => .{ .index  = r.operand.index },
                .identity, .iterate, .pipe, .output => .{ .none = {} },
            },
        };
    }

    return Compiled{ .instructions = instructions, .string_buf = string_buf };
}
