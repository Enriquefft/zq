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
        dot_dot, // ..
        pipe, // |
        lbracket, // [
        rbracket, // ]
        ident, // [a-zA-Z_][a-zA-Z0-9_]*
        int_lit, // [0-9]+
        float_lit, // [0-9]+\.[0-9]+([eE][+-]?[0-9]+)?
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

        // Conditional keywords
        if_kw, // if
        then_kw, // then
        elif_kw, // elif
        else_kw, // else
        end_kw, // end

        // String literal
        string_lit, // "..."

        // Format string support
        at, // @
        string_part, // string segment ending at \( interpolation
        string_end, // final string segment after last ) of interpolation

        // Alternative operator
        double_slash, // //

        // Try-catch keywords
        try_kw, // try
        catch_kw, // catch

        // Label/break keywords
        label_kw, // label
        break_kw, // break

        // Optional operator
        question, // ?

        // Assignment operators
        eq_assign, // = (plain assignment)
        pipe_eq, // |=
        plus_eq, // +=
        minus_eq, // -=
        star_eq, // *=
        slash_eq, // /=
        percent_eq, // %=
        double_slash_eq, // //=
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
                if (l.pos < l.src.len and l.src[l.pos] == '.') {
                    l.pos += 1;
                    return .{ .tag = .dot_dot, .offset = start, .len = 2 };
                }
                // Leading-dot float literal (e.g. `.5`, `.00005`) — jq accepts
                // these as float literals, not `.` followed by an index.
                if (l.pos < l.src.len and std.ascii.isDigit(l.src[l.pos])) {
                    while (l.pos < l.src.len and std.ascii.isDigit(l.src[l.pos]))
                        l.pos += 1;
                    if (l.pos < l.src.len and (l.src[l.pos] == 'e' or l.src[l.pos] == 'E')) {
                        l.pos += 1;
                        if (l.pos < l.src.len and (l.src[l.pos] == '+' or l.src[l.pos] == '-'))
                            l.pos += 1;
                        if (l.pos >= l.src.len or !std.ascii.isDigit(l.src[l.pos]))
                            return error.QuerySyntaxError;
                        while (l.pos < l.src.len and std.ascii.isDigit(l.src[l.pos]))
                            l.pos += 1;
                    }
                    return .{ .tag = .float_lit, .offset = start, .len = l.pos - start };
                }
                return .{ .tag = .dot, .offset = start, .len = 1 };
            },
            '|' => {
                l.pos += 1;
                if (l.pos < l.src.len and l.src[l.pos] == '=') {
                    l.pos += 1;
                    return .{ .tag = .pipe_eq, .offset = start, .len = 2 };
                }
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
                if (l.pos < l.src.len and l.src[l.pos] == '=') {
                    l.pos += 1;
                    return .{ .tag = .plus_eq, .offset = start, .len = 2 };
                }
                return .{ .tag = .plus, .offset = start, .len = 1 };
            },
            '-' => {
                l.pos += 1;
                if (l.pos < l.src.len and l.src[l.pos] == '=') {
                    l.pos += 1;
                    return .{ .tag = .minus_eq, .offset = start, .len = 2 };
                }
                return .{ .tag = .minus, .offset = start, .len = 1 };
            },
            '*' => {
                l.pos += 1;
                if (l.pos < l.src.len and l.src[l.pos] == '=') {
                    l.pos += 1;
                    return .{ .tag = .star_eq, .offset = start, .len = 2 };
                }
                return .{ .tag = .star, .offset = start, .len = 1 };
            },
            '/' => {
                l.pos += 1;
                if (l.pos < l.src.len and l.src[l.pos] == '/') {
                    l.pos += 1;
                    if (l.pos < l.src.len and l.src[l.pos] == '=') {
                        l.pos += 1;
                        return .{ .tag = .double_slash_eq, .offset = start, .len = 3 };
                    }
                    return .{ .tag = .double_slash, .offset = start, .len = 2 };
                }
                if (l.pos < l.src.len and l.src[l.pos] == '=') {
                    l.pos += 1;
                    return .{ .tag = .slash_eq, .offset = start, .len = 2 };
                }
                return .{ .tag = .slash, .offset = start, .len = 1 };
            },
            '%' => {
                l.pos += 1;
                if (l.pos < l.src.len and l.src[l.pos] == '=') {
                    l.pos += 1;
                    return .{ .tag = .percent_eq, .offset = start, .len = 2 };
                }
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
                return .{ .tag = .eq_assign, .offset = start, .len = 1 };
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
            '?' => {
                l.pos += 1;
                return .{ .tag = .question, .offset = start, .len = 1 };
            },
            '"' => {
                l.pos += 1; // skip opening quote
                const content_start = l.pos;
                while (l.pos < l.src.len and l.src[l.pos] != '"') {
                    if (l.src[l.pos] == '\\') {
                        l.pos += 1; // skip backslash
                        if (l.pos >= l.src.len) return error.QuerySyntaxError;
                        if (l.src[l.pos] == '(') {
                            // String interpolation: return string_part for content before \(
                            // Content is from after opening " to before the backslash
                            const content_len = l.pos - 1 - content_start;
                            l.pos += 1; // skip past '('
                            return .{ .tag = .string_part, .offset = content_start, .len = content_len };
                        }
                    }
                    l.pos += 1;
                }
                if (l.pos >= l.src.len) return error.QuerySyntaxError; // unterminated string
                l.pos += 1; // skip closing quote
                return .{ .tag = .string_lit, .offset = start, .len = l.pos - start };
            },
            '@' => {
                l.pos += 1;
                return .{ .tag = .at, .offset = start, .len = 1 };
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
        else if (std.mem.eql(u8, slice, "if"))
            .if_kw
        else if (std.mem.eql(u8, slice, "then"))
            .then_kw
        else if (std.mem.eql(u8, slice, "elif"))
            .elif_kw
        else if (std.mem.eql(u8, slice, "else"))
            .else_kw
        else if (std.mem.eql(u8, slice, "end"))
            .end_kw
        else if (std.mem.eql(u8, slice, "try"))
            .try_kw
        else if (std.mem.eql(u8, slice, "catch"))
            .catch_kw
        else if (std.mem.eql(u8, slice, "label"))
            .label_kw
        else if (std.mem.eql(u8, slice, "break"))
            .break_kw
        else
            .ident;

        return .{ .tag = tag, .offset = start, .len = len };
    }

    /// Called by the compiler after consuming `)` of a string interpolation.
    /// Scans from current position for more string content until either
    /// another \( (returns string_part) or closing " (returns string_end).
    pub fn scanStringTail(l: *Lexer) ZqError!Token {
        const content_start = l.pos;
        while (l.pos < l.src.len and l.src[l.pos] != '"') {
            if (l.src[l.pos] == '\\') {
                l.pos += 1; // skip backslash
                if (l.pos >= l.src.len) return error.QuerySyntaxError;
                if (l.src[l.pos] == '(') {
                    // Another interpolation: return string_part for content before \(
                    const content_len = l.pos - 1 - content_start;
                    l.pos += 1; // skip past '('
                    return .{ .tag = .string_part, .offset = content_start, .len = content_len };
                }
            }
            l.pos += 1;
        }
        if (l.pos >= l.src.len) return error.QuerySyntaxError; // unterminated string
        // Found closing quote
        const content_len = l.pos - content_start;
        l.pos += 1; // skip closing quote
        return .{ .tag = .string_end, .offset = content_start, .len = content_len };
    }

    fn skipWs(l: *Lexer) void {
        while (l.pos < l.src.len) {
            switch (l.src[l.pos]) {
                ' ', '\t', '\r', '\n' => l.pos += 1,
                // jq line comments: `#` to end of line. No block comments.
                '#' => {
                    l.pos += 1;
                    while (l.pos < l.src.len and l.src[l.pos] != '\n') : (l.pos += 1) {}
                },
                else => break,
            }
        }
    }

    fn isIdentCont(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }
};
