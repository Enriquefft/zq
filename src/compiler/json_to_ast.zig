//! Tiny JSON → AST literal converter used by the module-system data
//! import path (Phase 2a). Parses a JSON document into AST literal /
//! constructor nodes so the rest of the lowerer can treat data
//! imports as inline literals.
//!
//! Limitations (intentional for Phase 2a):
//!   - Numbers parse as i64 when integral, f64 otherwise.
//!   - No streaming — caller passes the entire file content.
//!   - Strings honor `\uXXXX`, `\n`, `\t`, `\r`, `\b`, `\f`, `\\`, `\"`,
//!     and `\/` escapes (the standard JSON set).
//!
//! Allocates AST nodes/strings/slices in the caller-provided arena
//! allocator; the resulting tree's lifetime is the arena's.

const std = @import("std");
const ast = @import("ast");

const Node = ast.Node;
const Span = ast.Span;

pub const ParseError = error{
    OutOfMemory,
    InvalidJson,
};

/// Parse `src` as JSON and return a heap-allocated AST tree of literal
/// constructors equivalent to that JSON. The arena owns every node.
pub fn parse(src: []const u8, arena: std.mem.Allocator) ParseError!*Node {
    var p = Parser{ .src = src, .pos = 0, .alloc = arena };
    p.skipWs();
    const root = try p.parseValue();
    p.skipWs();
    // Trailing garbage is tolerated for jq-compat (legacy reads first
    // value); strict mode would `return error.InvalidJson` here.
    return root;
}

const Parser = struct {
    src: []const u8,
    pos: usize,
    alloc: std.mem.Allocator,

    fn skipWs(p: *Parser) void {
        while (p.pos < p.src.len) {
            switch (p.src[p.pos]) {
                ' ', '\t', '\r', '\n' => p.pos += 1,
                else => break,
            }
        }
    }

    fn peek(p: *Parser) ?u8 {
        if (p.pos >= p.src.len) return null;
        return p.src[p.pos];
    }

    fn parseValue(p: *Parser) ParseError!*Node {
        p.skipWs();
        const c = p.peek() orelse return error.InvalidJson;
        return switch (c) {
            '{' => p.parseObject(),
            '[' => p.parseArray(),
            '"' => p.parseString(),
            't', 'f' => p.parseBool(),
            'n' => p.parseNull(),
            '-', '0'...'9' => p.parseNumber(),
            else => error.InvalidJson,
        };
    }

    fn parseObject(p: *Parser) ParseError!*Node {
        p.pos += 1; // skip '{'
        var fields = std.ArrayList(Node.ObjectField){};
        p.skipWs();
        if (p.peek() == @as(u8, '}')) {
            p.pos += 1;
            const node = try p.alloc.create(Node);
            node.* = .{ .kind = .{ .object_construct = .{
                .fields = fields.toOwnedSlice(p.alloc) catch &[_]Node.ObjectField{},
            } }, .span = Span.empty() };
            return node;
        }
        while (true) {
            p.skipWs();
            if (p.peek() != @as(u8, '"')) return error.InvalidJson;
            const key_str = try p.scanStringContent();
            p.skipWs();
            if (p.peek() != @as(u8, ':')) return error.InvalidJson;
            p.pos += 1;
            p.skipWs();
            const value = try p.parseValue();
            try fields.append(p.alloc, .{
                .key = .{ .string = key_str },
                .value = value,
                .span = Span.empty(),
            });
            p.skipWs();
            const sep = p.peek() orelse return error.InvalidJson;
            if (sep == ',') {
                p.pos += 1;
                continue;
            }
            if (sep == '}') {
                p.pos += 1;
                break;
            }
            return error.InvalidJson;
        }
        const node = try p.alloc.create(Node);
        node.* = .{ .kind = .{ .object_construct = .{
            .fields = fields.toOwnedSlice(p.alloc) catch &[_]Node.ObjectField{},
        } }, .span = Span.empty() };
        return node;
    }

    fn parseArray(p: *Parser) ParseError!*Node {
        p.pos += 1; // skip '['
        var elems = std.ArrayList(*Node){};
        p.skipWs();
        if (p.peek() == @as(u8, ']')) {
            p.pos += 1;
            const node = try p.alloc.create(Node);
            node.* = .{ .kind = .{ .array_construct = .{ .expr = null } }, .span = Span.empty() };
            return node;
        }
        while (true) {
            p.skipWs();
            const val = try p.parseValue();
            try elems.append(p.alloc, val);
            p.skipWs();
            const sep = p.peek() orelse return error.InvalidJson;
            if (sep == ',') {
                p.pos += 1;
                continue;
            }
            if (sep == ']') {
                p.pos += 1;
                break;
            }
            return error.InvalidJson;
        }
        // Build a left-associated comma chain.
        var inner: *Node = elems.items[0];
        var i: usize = 1;
        while (i < elems.items.len) : (i += 1) {
            const c = try p.alloc.create(Node);
            c.* = .{ .kind = .{ .comma = .{ .left = inner, .right = elems.items[i] } }, .span = Span.empty() };
            inner = c;
        }
        const node = try p.alloc.create(Node);
        node.* = .{ .kind = .{ .array_construct = .{ .expr = inner } }, .span = Span.empty() };
        return node;
    }

    fn parseString(p: *Parser) ParseError!*Node {
        const s = try p.scanStringContent();
        const node = try p.alloc.create(Node);
        node.* = .{ .kind = .{ .literal = .{ .string = s } }, .span = Span.empty() };
        return node;
    }

    fn parseBool(p: *Parser) ParseError!*Node {
        const node = try p.alloc.create(Node);
        if (std.mem.startsWith(u8, p.src[p.pos..], "true")) {
            p.pos += 4;
            node.* = .{ .kind = .{ .literal = .{ .bool_val = true } }, .span = Span.empty() };
            return node;
        }
        if (std.mem.startsWith(u8, p.src[p.pos..], "false")) {
            p.pos += 5;
            node.* = .{ .kind = .{ .literal = .{ .bool_val = false } }, .span = Span.empty() };
            return node;
        }
        return error.InvalidJson;
    }

    fn parseNull(p: *Parser) ParseError!*Node {
        if (!std.mem.startsWith(u8, p.src[p.pos..], "null")) return error.InvalidJson;
        p.pos += 4;
        const node = try p.alloc.create(Node);
        node.* = .{ .kind = .{ .literal = .{ .null_val = {} } }, .span = Span.empty() };
        return node;
    }

    fn parseNumber(p: *Parser) ParseError!*Node {
        const start = p.pos;
        if (p.peek() == @as(u8, '-')) p.pos += 1;
        while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) : (p.pos += 1) {}
        var is_float = false;
        if (p.pos < p.src.len and p.src[p.pos] == '.') {
            is_float = true;
            p.pos += 1;
            while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) : (p.pos += 1) {}
        }
        if (p.pos < p.src.len and (p.src[p.pos] == 'e' or p.src[p.pos] == 'E')) {
            is_float = true;
            p.pos += 1;
            if (p.pos < p.src.len and (p.src[p.pos] == '+' or p.src[p.pos] == '-')) p.pos += 1;
            while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) : (p.pos += 1) {}
        }
        const slice = p.src[start..p.pos];
        const node = try p.alloc.create(Node);
        if (is_float) {
            const f = std.fmt.parseFloat(f64, slice) catch return error.InvalidJson;
            node.* = .{ .kind = .{ .literal = .{ .float = f } }, .span = Span.empty() };
        } else {
            const n = std.fmt.parseInt(i64, slice, 10) catch return error.InvalidJson;
            node.* = .{ .kind = .{ .literal = .{ .int = n } }, .span = Span.empty() };
        }
        return node;
    }

    fn scanStringContent(p: *Parser) ParseError![]const u8 {
        if (p.peek() != @as(u8, '"')) return error.InvalidJson;
        p.pos += 1;
        var buf = std.ArrayList(u8){};
        while (p.pos < p.src.len) {
            const c = p.src[p.pos];
            if (c == '"') {
                p.pos += 1;
                return buf.toOwnedSlice(p.alloc) catch return error.OutOfMemory;
            }
            if (c == '\\') {
                p.pos += 1;
                if (p.pos >= p.src.len) return error.InvalidJson;
                switch (p.src[p.pos]) {
                    '"' => try buf.append(p.alloc, '"'),
                    '\\' => try buf.append(p.alloc, '\\'),
                    '/' => try buf.append(p.alloc, '/'),
                    'n' => try buf.append(p.alloc, '\n'),
                    'r' => try buf.append(p.alloc, '\r'),
                    't' => try buf.append(p.alloc, '\t'),
                    'b' => try buf.append(p.alloc, '\x08'),
                    'f' => try buf.append(p.alloc, '\x0C'),
                    'u' => {
                        p.pos += 1;
                        if (p.pos + 4 > p.src.len) return error.InvalidJson;
                        const hi = std.fmt.parseInt(u21, p.src[p.pos..][0..4], 16) catch return error.InvalidJson;
                        p.pos += 4;
                        var codepoint: u21 = hi;
                        if (hi >= 0xD800 and hi <= 0xDBFF) {
                            if (p.pos + 6 <= p.src.len and p.src[p.pos] == '\\' and p.src[p.pos + 1] == 'u') {
                                const lo = std.fmt.parseInt(u21, p.src[p.pos + 2 ..][0..4], 16) catch return error.InvalidJson;
                                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                    codepoint = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
                                    p.pos += 6;
                                }
                            }
                        }
                        var utf8_buf: [4]u8 = undefined;
                        const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return error.InvalidJson;
                        try buf.appendSlice(p.alloc, utf8_buf[0..utf8_len]);
                        continue;
                    },
                    else => return error.InvalidJson,
                }
                p.pos += 1;
                continue;
            }
            try buf.append(p.alloc, c);
            p.pos += 1;
        }
        return error.InvalidJson;
    }
};
