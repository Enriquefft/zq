const std = @import("std");
const ast = @import("ast");
const protocol = @import("../protocol.zig");

/// Semantic token types (must match legend declared in initialize).
pub const token_types = [_][]const u8{
    "keyword",
    "function",
    "variable",
    "string",
    "number",
    "operator",
    "property",
    "type",
};

/// Semantic token modifiers.
pub const token_modifiers = [_][]const u8{
    "declaration",
    "builtin",
};

const RawToken = struct {
    line: u32,
    char: u32,
    length: u32,
    token_type: u32,
    modifiers: u32,
};

/// Generate semantic tokens from an AST.
pub fn encode(root: *const ast.Node, source: []const u8, alloc: std.mem.Allocator) []u32 {
    var tokens = std.ArrayList(RawToken){};
    defer tokens.deinit(alloc);

    collectTokens(root, source, &tokens, alloc);

    // Sort by position
    std.mem.sort(RawToken, tokens.items, {}, lessThan);

    // Delta-encode
    var encoded = std.ArrayList(u32){};
    var prev_line: u32 = 0;
    var prev_char: u32 = 0;

    for (tokens.items) |tok| {
        const delta_line = tok.line - prev_line;
        const delta_char = if (delta_line == 0) tok.char - prev_char else tok.char;

        encoded.append(alloc, delta_line) catch continue;
        encoded.append(alloc, delta_char) catch continue;
        encoded.append(alloc, tok.length) catch continue;
        encoded.append(alloc, tok.token_type) catch continue;
        encoded.append(alloc, tok.modifiers) catch continue;

        prev_line = tok.line;
        prev_char = tok.char;
    }

    return encoded.toOwnedSlice(alloc) catch &[_]u32{};
}

fn lessThan(_: void, a: RawToken, b: RawToken) bool {
    if (a.line != b.line) return a.line < b.line;
    return a.char < b.char;
}

fn collectTokens(node: *const ast.Node, source: []const u8, tokens: *std.ArrayList(RawToken), alloc: std.mem.Allocator) void {
    switch (node.kind) {
        .builtin_call => |bc| {
            addToken(tokens, source, node.span, protocol.SemanticTokenTypes.function, 1 << protocol.SemanticTokenModifiers.builtin, alloc);
            for (bc.args) |arg| collectTokens(arg, source, tokens, alloc);
        },
        .func_call => |fc| {
            addToken(tokens, source, node.span, protocol.SemanticTokenTypes.function, 0, alloc);
            for (fc.args) |arg| collectTokens(arg, source, tokens, alloc);
        },
        .func_def => |fd| {
            addToken(tokens, source, node.span, protocol.SemanticTokenTypes.keyword, 0, alloc); // 'def' keyword
            collectTokens(fd.body, source, tokens, alloc);
            collectTokens(fd.rest, source, tokens, alloc);
        },
        .variable_ref => {
            addToken(tokens, source, node.span, protocol.SemanticTokenTypes.variable, 0, alloc);
        },
        .literal => |lit| {
            const tt: u32 = switch (lit) {
                .string => protocol.SemanticTokenTypes.string,
                .int, .float, .big_number => protocol.SemanticTokenTypes.number,
                .bool_val, .null_val => protocol.SemanticTokenTypes.keyword,
            };
            addToken(tokens, source, node.span, tt, 0, alloc);
        },
        .field_access => {
            addToken(tokens, source, node.span, protocol.SemanticTokenTypes.property, 0, alloc);
        },
        .pipe => |pipe| {
            collectTokens(pipe.left, source, tokens, alloc);
            collectTokens(pipe.right, source, tokens, alloc);
        },
        .comma => |comma| {
            collectTokens(comma.left, source, tokens, alloc);
            collectTokens(comma.right, source, tokens, alloc);
        },
        .alternative, .or_expr, .and_expr => |bin| {
            collectTokens(bin.left, source, tokens, alloc);
            collectTokens(bin.right, source, tokens, alloc);
        },
        .comparison => |cmp| {
            collectTokens(cmp.left, source, tokens, alloc);
            collectTokens(cmp.right, source, tokens, alloc);
        },
        .arithmetic => |arith| {
            collectTokens(arith.left, source, tokens, alloc);
            collectTokens(arith.right, source, tokens, alloc);
        },
        .unary_neg, .paren, .optional => |un| collectTokens(un.operand, source, tokens, alloc),
        .if_expr => |ie| {
            collectTokens(ie.cond, source, tokens, alloc);
            collectTokens(ie.then_body, source, tokens, alloc);
            if (ie.else_body) |eb| collectTokens(eb, source, tokens, alloc);
        },
        .try_catch => |tc| {
            collectTokens(tc.body, source, tokens, alloc);
            if (tc.catch_body) |cb| collectTokens(cb, source, tokens, alloc);
        },
        .array_construct => |ac| {
            if (ac.expr) |expr| collectTokens(expr, source, tokens, alloc);
        },
        .object_construct => |oc| {
            for (oc.fields) |field| {
                switch (field.key) {
                    .expr => |expr| collectTokens(expr, source, tokens, alloc),
                    else => {},
                }
                collectTokens(field.value, source, tokens, alloc);
            }
        },
        .suffix => |suf| collectTokens(suf.base, source, tokens, alloc),
        .as_pattern => |ap| {
            collectTokens(ap.expr, source, tokens, alloc);
            collectTokens(ap.body, source, tokens, alloc);
        },
        .reduce => |red| {
            collectTokens(red.expr, source, tokens, alloc);
            collectTokens(red.init, source, tokens, alloc);
            collectTokens(red.update, source, tokens, alloc);
        },
        .foreach => |fe| {
            collectTokens(fe.expr, source, tokens, alloc);
            collectTokens(fe.init, source, tokens, alloc);
            collectTokens(fe.update, source, tokens, alloc);
            if (fe.extract) |ext| collectTokens(ext, source, tokens, alloc);
        },
        .update_assign => |ua| collectTokens(ua.rhs, source, tokens, alloc),
        else => {},
    }
}

fn addToken(tokens: *std.ArrayList(RawToken), source: []const u8, span: ast.Span, token_type: u32, modifiers: u32, alloc: std.mem.Allocator) void {
    const pos = protocol.byteOffsetToPosition(source, span.start);
    const length = span.end - span.start;
    tokens.append(alloc, .{
        .line = pos.line,
        .char = pos.character,
        .length = length,
        .token_type = token_type,
        .modifiers = modifiers,
    }) catch {};
}
