const std = @import("std");
const ZqError = @import("error").ZqError;

pub const Token = struct {
    tag: Tag,
    /// Byte offset of first character in source.
    offset: u32,
    /// Length in bytes.
    len: u32,

    pub const Tag = enum {
        dot, // .
        pipe, // |
        lbracket, // [
        rbracket, // ]
        ident, // [a-zA-Z_][a-zA-Z0-9_]*
        int_lit, // -?[0-9]+
        float_lit, // -?[0-9]+\.[0-9]+([eE][+-]?[0-9]+)?
        eof,

        // Arithmetic operators
        plus, // +
        minus, // -
        star, // *
        slash, // /
        percent, // %

        // Comparison operators
        eq, // ==
        ne, // !=
        lt, // <
        le, // <=
        gt, // >
        ge, // >=

        // Parentheses
        lparen, // (
        rparen, // )
        lbrace, // {
        rbrace, // }

        // Variable/function syntax
        dollar, // $
        colon, // :
        semicolon, // ;
        comma, // ,

        // Keywords
        and_kw, // and
        or_kw, // or
        not_kw, // not
        true_kw, // true
        false_kw, // false
        def_kw, // def
        as_kw, // as
        reduce_kw, // reduce
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
            '.' => {
                l.pos += 1;
                return .{ .tag = .dot, .offset = start, .len = 1 };
            },
            '|' => {
                l.pos += 1;
                return .{ .tag = .pipe, .offset = start, .len = 1 };
            },
            '[' => {
                l.pos += 1;
                return .{ .tag = .lbracket, .offset = start, .len = 1 };
            },
            ']' => {
                l.pos += 1;
                return .{ .tag = .rbracket, .offset = start, .len = 1 };
            },
            '(' => {
                l.pos += 1;
                return .{ .tag = .lparen, .offset = start, .len = 1 };
            },
            ')' => {
                l.pos += 1;
                return .{ .tag = .rparen, .offset = start, .len = 1 };
            },
            '{' => {
                l.pos += 1;
                return .{ .tag = .lbrace, .offset = start, .len = 1 };
            },
            '}' => {
                l.pos += 1;
                return .{ .tag = .rbrace, .offset = start, .len = 1 };
            },
            '+' => {
                l.pos += 1;
                return .{ .tag = .plus, .offset = start, .len = 1 };
            },
            '-' => {
                l.pos += 1;
                if (l.pos >= l.src.len or !std.ascii.isDigit(l.src[l.pos]))
                    return .{ .tag = .minus, .offset = start, .len = 1 };
                return l.scanNumberLiteral(start);
            },
            '*' => {
                l.pos += 1;
                return .{ .tag = .star, .offset = start, .len = 1 };
            },
            '/' => {
                l.pos += 1;
                return .{ .tag = .slash, .offset = start, .len = 1 };
            },
            '%' => {
                l.pos += 1;
                return .{ .tag = .percent, .offset = start, .len = 1 };
            },
            '<' => {
                l.pos += 1;
                if (l.pos < l.src.len and l.src[l.pos] == '=') {
                    l.pos += 1;
                    return .{ .tag = .le, .offset = start, .len = 2 };
                }
                return .{ .tag = .lt, .offset = start, .len = 1 };
            },
            '>' => {
                l.pos += 1;
                if (l.pos < l.src.len and l.src[l.pos] == '=') {
                    l.pos += 1;
                    return .{ .tag = .ge, .offset = start, .len = 2 };
                }
                return .{ .tag = .gt, .offset = start, .len = 1 };
            },
            '=' => {
                l.pos += 1;
                if (l.pos < l.src.len and l.src[l.pos] == '=') {
                    l.pos += 1;
                    return .{ .tag = .eq, .offset = start, .len = 2 };
                }
                return error.QuerySyntaxError;
            },
            '!' => {
                l.pos += 1;
                if (l.pos < l.src.len and l.src[l.pos] == '=') {
                    l.pos += 1;
                    return .{ .tag = .ne, .offset = start, .len = 2 };
                }
                return error.QuerySyntaxError;
            },
            ':' => {
                l.pos += 1;
                return .{ .tag = .colon, .offset = start, .len = 1 };
            },
            ';' => {
                l.pos += 1;
                return .{ .tag = .semicolon, .offset = start, .len = 1 };
            },
            ',' => {
                l.pos += 1;
                return .{ .tag = .comma, .offset = start, .len = 1 };
            },
            '$' => {
                l.pos += 1;
                return .{ .tag = .dollar, .offset = start, .len = 1 };
            },
            'a'...'z', 'A'...'Z', '_' => {
                l.pos += 1;
                while (l.pos < l.src.len and isIdentCont(l.src[l.pos])) l.pos += 1;
                return l.maybeKeyword(start, l.pos - start);
            },
            '0'...'9' => {
                return l.scanNumberLiteral(start);
            },
            else => return error.QuerySyntaxError,
        }
    }

    /// Scan a number literal (integer or float).
    fn scanNumberLiteral(l: *Lexer, start: u32) ZqError!Token {
        // Integer part
        while (l.pos < l.src.len and std.ascii.isDigit(l.src[l.pos])) l.pos += 1;

        // Check for float
        var is_float = false;
        if (l.pos < l.src.len and l.src[l.pos] == '.') {
            is_float = true;
            l.pos += 1;
            // Must have at least one digit after decimal point
            if (l.pos >= l.src.len or !std.ascii.isDigit(l.src[l.pos]))
                return error.QuerySyntaxError;
            while (l.pos < l.src.len and std.ascii.isDigit(l.src[l.pos])) l.pos += 1;
        }

        // Check for exponent
        if (l.pos < l.src.len and (l.src[l.pos] == 'e' or l.src[l.pos] == 'E')) {
            is_float = true;
            l.pos += 1;
            // Optional sign
            if (l.pos < l.src.len and (l.src[l.pos] == '+' or l.src[l.pos] == '-')) l.pos += 1;
            // Must have at least one digit
            if (l.pos >= l.src.len or !std.ascii.isDigit(l.src[l.pos]))
                return error.QuerySyntaxError;
            while (l.pos < l.src.len and std.ascii.isDigit(l.src[l.pos])) l.pos += 1;
        }

        const tag: Token.Tag = if (is_float) .float_lit else .int_lit;
        return .{ .tag = tag, .offset = start, .len = l.pos - start };
    }

    /// Check if an identifier is actually a keyword.
    fn maybeKeyword(l: *Lexer, start: u32, len: u32) ZqError!Token {
        const slice = l.src[start..][0..len];
        const tag: Token.Tag = if (std.mem.eql(u8, slice, "and"))
            .and_kw
        else if (std.mem.eql(u8, slice, "or"))
            .or_kw
        else if (std.mem.eql(u8, slice, "not"))
            .not_kw
        else if (std.mem.eql(u8, slice, "true"))
            .true_kw
        else if (std.mem.eql(u8, slice, "false"))
            .false_kw
        else if (std.mem.eql(u8, slice, "def"))
            .def_kw
        else if (std.mem.eql(u8, slice, "as"))
            .as_kw
        else if (std.mem.eql(u8, slice, "reduce"))
            .reduce_kw
        else
            .ident;

        return .{ .tag = tag, .offset = start, .len = len };
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
