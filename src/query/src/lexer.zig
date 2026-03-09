const std = @import("std");
const ZqError = @import("error").ZqError;

pub const Token = struct {
    tag: Tag,
    /// Byte offset of first character in source.
    offset: u32,
    /// Length in bytes.
    len: u32,

    pub const Tag = enum {
        dot,      // .
        pipe,     // |
        lbracket, // [
        rbracket, // ]
        ident,    // [a-zA-Z_][a-zA-Z0-9_]*
        int_lit,  // -?[0-9]+
        eof,
    };

    pub fn slice(tok: Token, src: []const u8) []const u8 {
        return src[tok.offset..][0..tok.len];
    }
};

pub const Lexer = struct {
    src: []const u8,
    pos: u32,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src, .pos = 0 };
    }

    /// Return the next token without consuming it.
    pub fn peek(l: *Lexer) ZqError!Token {
        const saved = l.pos;
        const tok = try l.next();
        l.pos = saved;
        return tok;
    }

    /// Consume and return the next token.
    pub fn next(l: *Lexer) ZqError!Token {
        l.skipWs();
        if (l.pos >= l.src.len)
            return Token{ .tag = .eof, .offset = @intCast(l.pos), .len = 0 };

        const start: u32 = l.pos;
        switch (l.src[l.pos]) {
            '.' => { l.pos += 1; return .{ .tag = .dot,      .offset = start, .len = 1 }; },
            '|' => { l.pos += 1; return .{ .tag = .pipe,     .offset = start, .len = 1 }; },
            '[' => { l.pos += 1; return .{ .tag = .lbracket, .offset = start, .len = 1 }; },
            ']' => { l.pos += 1; return .{ .tag = .rbracket, .offset = start, .len = 1 }; },
            'a'...'z', 'A'...'Z', '_' => {
                l.pos += 1;
                while (l.pos < l.src.len and isIdentCont(l.src[l.pos])) l.pos += 1;
                return .{ .tag = .ident, .offset = start, .len = l.pos - start };
            },
            '0'...'9' => {
                l.pos += 1;
                while (l.pos < l.src.len and std.ascii.isDigit(l.src[l.pos])) l.pos += 1;
                return .{ .tag = .int_lit, .offset = start, .len = l.pos - start };
            },
            '-' => {
                // Negative integer literal; only valid inside bracket context.
                l.pos += 1;
                if (l.pos >= l.src.len or !std.ascii.isDigit(l.src[l.pos]))
                    return error.QuerySyntaxError;
                while (l.pos < l.src.len and std.ascii.isDigit(l.src[l.pos])) l.pos += 1;
                return .{ .tag = .int_lit, .offset = start, .len = l.pos - start };
            },
            else => return error.QuerySyntaxError,
        }
    }

    fn skipWs(l: *Lexer) void {
        while (l.pos < l.src.len) {
            switch (l.src[l.pos]) {
                ' ', '\t', '\r', '\n' => l.pos += 1,
                else => break,
            }
        }
    }

    fn isIdentCont(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }
};
