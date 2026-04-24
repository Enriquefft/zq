const std = @import("std");
const nodes = @import("nodes.zig");
const lx = @import("lexer");

const Node = nodes.Node;
const Span = nodes.Span;
const Pattern = nodes.Pattern;
const ObjectPatternField = nodes.ObjectPatternField;
const PatternKey = nodes.PatternKey;
const ParseError = nodes.ParseError;
const ParseResult = nodes.ParseResult;
const Lexer = lx.Lexer;
const Token = lx.Token;

/// Error-tolerant AST parser. Always produces a tree + error list.
pub const Parser = struct {
    lex: Lexer,
    src: []const u8,
    arena: std.heap.ArenaAllocator,
    errors: std.ArrayList(ParseError) = .{},
    alloc: std.mem.Allocator,

    pub fn create(source: []const u8, alloc: std.mem.Allocator) Parser {
        return .{
            .lex = Lexer.init(source),
            .src = source,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .alloc = alloc,
        };
    }

    /// Parse the full filter expression. Never returns an error — always produces a result.
    pub fn parse(source: []const u8, alloc: std.mem.Allocator) ParseResult {
        var p = Parser.create(source, alloc);

        const root = p.parseFilter() catch p.makeError("parse failed", Span.empty());

        // Check for trailing tokens
        if (p.peek()) |tok| {
            if (tok.tag != .eof) {
                p.addError("unexpected token after expression", Span.from(tok.offset, tok.offset + tok.len));
            }
        }

        const errors = p.errors.toOwnedSlice(p.alloc) catch &[_]ParseError{};

        return .{
            .root = root,
            .errors = errors,
            .arena = p.arena,
            .alloc = alloc,
        };
    }

    // ── Token helpers ──────────────────────────────────────────────

    fn peek(p: *Parser) ?Token {
        return p.lex.peek() catch null;
    }

    fn advance(p: *Parser) ?Token {
        const tok = p.lex.next() catch {
            return null;
        };
        return tok;
    }

    fn expect(p: *Parser, tag: Token.Tag) ?Token {
        const tok = p.peek() orelse return null;
        if (tok.tag == tag) {
            return p.advance();
        }
        return null;
    }

    fn expectOrError(p: *Parser, tag: Token.Tag, msg: []const u8) ?Token {
        if (p.expect(tag)) |tok| return tok;
        const tok = p.peek() orelse {
            p.addError(msg, Span.from(@intCast(p.src.len), @intCast(p.src.len)));
            return null;
        };
        p.addError(msg, Span.from(tok.offset, tok.offset + tok.len));
        return null;
    }

    fn tokenSlice(p: *Parser, tok: Token) []const u8 {
        return tok.slice(p.src);
    }

    // ── Error helpers ──────────────────────────────────────────────

    fn addError(p: *Parser, message: []const u8, span: Span) void {
        p.errors.append(p.alloc, .{
            .message = message,
            .span = span,
            .kind = .unexpected_token,
        }) catch {};
    }

    fn makeError(p: *Parser, message: []const u8, span: Span) *Node {
        p.addError(message, span);
        return p.createNode(.{ .error_node = .{ .message = message } }, span);
    }

    fn syncToNextStatement(p: *Parser) void {
        while (true) {
            const tok = p.peek() orelse return;
            switch (tok.tag) {
                .pipe, .semicolon, .rparen, .rbracket, .rbrace, .end_kw, .eof => return,
                else => _ = p.advance(),
            }
        }
    }

    // ── Node allocation ────────────────────────────────────────────

    fn createNode(p: *Parser, kind: Node.Kind, span: Span) *Node {
        const node = p.arena.allocator().create(Node) catch @panic("OOM");
        node.* = .{ .kind = kind, .span = span };
        return node;
    }

    fn allocSlice(p: *Parser, comptime T: type, items: []const T) []const T {
        return p.arena.allocator().dupe(T, items) catch @panic("OOM");
    }

    // ── Grammar rules ──────────────────────────────────────────────
    //
    // Mirrors the compiler's recursive descent:
    //   parseFilter → parsePipe → parseComma → parseAlternative
    //   → parseLogical → parseOr → parseAnd → parseComparison
    //   → parseAdditive → parseMultiplicative → parseUnary → parsePrimary

    fn parseFilter(p: *Parser) error{ParseFailed}!*Node {
        const tok = p.peek() orelse return error.ParseFailed;
        if (tok.tag == .def_kw) {
            return p.parseFunctionDef();
        }
        return p.parsePipe();
    }

    fn parsePipe(p: *Parser) error{ParseFailed}!*Node {
        // First operand: either a strict `.path OP= rhs` (fast path) or a
        // regular comma expression. Matches legacy `parsePipe` at
        // `src/query/src/compiler.zig:2449-2471` which calls
        // `parseCommaOperand` for every operand — assignments bind at the
        // comma-operand level so `.a = .b | .c` is `pipe(assign(.a, .b), .c)`.
        var left: *Node = if (p.peekIsUpdateAssign())
            try p.parseUpdateAssign()
        else
            try p.parseComma();
        while (true) {
            const tok = p.peek() orelse break;
            if (tok.tag != .pipe) break;
            _ = p.advance(); // consume |

            // def after pipe
            const after = p.peek() orelse break;
            if (after.tag == .def_kw) {
                const right = p.parseFunctionDef() catch {
                    p.syncToNextStatement();
                    continue;
                };
                const span = Span.from(left.span.start, right.span.end);
                left = p.createNode(.{ .pipe = .{ .left = left, .right = right } }, span);
                break;
            }

            const right = p.parseComma() catch {
                p.syncToNextStatement();
                continue;
            };
            const span = Span.from(left.span.start, right.span.end);
            left = p.createNode(.{ .pipe = .{ .left = left, .right = right } }, span);
        }
        return left;
    }

    fn parseComma(p: *Parser) error{ParseFailed}!*Node {
        var left = try p.parseCommaOperand();
        while (true) {
            const tok = p.peek() orelse break;
            if (tok.tag != .comma) break;
            _ = p.advance();

            const after = p.peek() orelse break;
            if (after.tag == .def_kw) {
                const right = p.parseFunctionDef() catch break;
                const span = Span.from(left.span.start, right.span.end);
                left = p.createNode(.{ .comma = .{ .left = left, .right = right } }, span);
                break;
            }

            const right = p.parseCommaOperand() catch break;
            const span = Span.from(left.span.start, right.span.end);
            left = p.createNode(.{ .comma = .{ .left = left, .right = right } }, span);
        }
        return left;
    }

    /// Parse one operand of a `,` expression. Mirrors the legacy compiler's
    /// `parseCommaOperand` at `src/query/src/compiler.zig:2477`: assignment
    /// operators (`=`, `|=`, `+=`, ...) bind at this precedence level. The
    /// strict `.path` LHS fast path goes through `parseUpdateAssign`; any
    /// other LHS shape falls through to `parseAlternative` and is wrapped in
    /// an `assign_general` node if a trailing assignment operator remains.
    ///
    /// The legacy `peekIsUpdateAssign` (`:1691`) is depth-aware and accepts
    /// any LHS whose first matching `=`/`|=`/... at depth 0 is an assignment
    /// operator — including paren-grouped LHSs like `(.a, .b) = 1`. The AST
    /// mirrors that over-acceptance via this two-step dispatch (strict
    /// pattern first, fall-through wrap second) without a duplicate scanner.
    fn parseCommaOperand(p: *Parser) error{ParseFailed}!*Node {
        if (p.peekIsUpdateAssign()) {
            return p.parseUpdateAssign();
        }
        const lhs = try p.parseAlternative();
        return p.wrapAssignGeneralIfTrailing(lhs);
    }

    /// If the next token is an assignment operator, consume it, parse the
    /// RHS at alternative precedence, and wrap `lhs` in `assign_general`.
    /// Otherwise return `lhs` unchanged. Called both from
    /// `parseCommaOperand` and `parseObjectFieldValue` so pipe/comma inside
    /// an object value (BUG-005 shape) still recognizes a trailing assign.
    fn wrapAssignGeneralIfTrailing(p: *Parser, lhs: *Node) error{ParseFailed}!*Node {
        const tok = p.peek() orelse return lhs;
        const op: Node.UpdateAssign.AssignOp = switch (tok.tag) {
            .eq_assign => .eq,
            .pipe_eq => .pipe_eq,
            .plus_eq => .plus_eq,
            .minus_eq => .minus_eq,
            .star_eq => .star_eq,
            .slash_eq => .slash_eq,
            .percent_eq => .percent_eq,
            .double_slash_eq => .double_slash_eq,
            else => return lhs,
        };
        const op_offset = tok.offset;
        _ = p.advance(); // consume assignment operator
        const rhs = try p.parseAlternative();
        return p.createNode(.{ .assign_general = .{
            .lhs = lhs,
            .op = op,
            .rhs = rhs,
            .op_offset = op_offset,
        } }, Span.from(lhs.span.start, rhs.span.end));
    }

    fn parseAlternative(p: *Parser) error{ParseFailed}!*Node {
        var left = try p.parseLogical();
        while (true) {
            const tok = p.peek() orelse break;
            if (tok.tag != .double_slash) break;
            _ = p.advance();
            const right = p.parseLogical() catch break;
            const span = Span.from(left.span.start, right.span.end);
            left = p.createNode(.{ .alternative = .{ .left = left, .right = right } }, span);
        }
        return left;
    }

    fn parseLogical(p: *Parser) error{ParseFailed}!*Node {
        const expr = try p.parseOr();

        // Check for `as PATTERN`
        const tok = p.peek() orelse return expr;
        if (tok.tag == .as_kw) {
            _ = p.advance(); // consume 'as'
            const pattern = p.parsePattern() catch return expr;

            // Check for ?// (destructuring alternative)
            if (p.peekIsDestructAlt()) {
                var patterns_list: std.ArrayList(Pattern) = .{};
                patterns_list.append(p.arena.allocator(), pattern) catch return expr;

                // peekIsDestructAlt above already consumed the first `?//`, so
                // the next pattern follows immediately. Parse each subsequent
                // pattern, then check for another `?//` (which consumes it if
                // present). Mirrors legacy's `parseDestructAlt` loop order at
                // `src/query/src/compiler.zig:2705-2710`.
                while (true) {
                    const pat = p.parsePattern() catch break;
                    patterns_list.append(p.arena.allocator(), pat) catch break;
                    if (!p.peekIsDestructAlt()) break;
                }

                // Parse | body
                _ = p.expectOrError(.pipe, "expected '|' after destructuring patterns");
                const body = p.parsePipe() catch return expr;

                const span = Span.from(expr.span.start, body.span.end);
                return p.createNode(.{ .destruct_alt = .{
                    .expr = expr,
                    .patterns = patterns_list.toOwnedSlice(p.arena.allocator()) catch &[_]Pattern{},
                    .body = body,
                } }, span);
            }

            // Parse | body (normal as pattern)
            _ = p.expectOrError(.pipe, "expected '|' after pattern");
            const body = p.parsePipe() catch return expr;

            const span = Span.from(expr.span.start, body.span.end);
            return p.createNode(.{ .as_pattern = .{
                .expr = expr,
                .pattern = pattern,
                .body = body,
            } }, span);
        }
        return expr;
    }

    fn peekIsDestructAlt(p: *Parser) bool {
        const saved = p.lex.pos;
        const t1 = p.lex.next() catch {
            p.lex.pos = saved;
            return false;
        };
        if (t1.tag != .question) {
            p.lex.pos = saved;
            return false;
        }
        const t2 = p.lex.next() catch {
            p.lex.pos = saved;
            return false;
        };
        if (t2.tag != .double_slash) {
            p.lex.pos = saved;
            return false;
        }
        // Consumed ?// — do not restore
        return true;
    }

    fn parseOr(p: *Parser) error{ParseFailed}!*Node {
        var left = try p.parseAnd();
        while (true) {
            const tok = p.peek() orelse break;
            if (tok.tag != .or_kw) break;
            _ = p.advance();
            const right = p.parseAnd() catch break;
            const span = Span.from(left.span.start, right.span.end);
            left = p.createNode(.{ .or_expr = .{ .left = left, .right = right } }, span);
        }
        return left;
    }

    fn parseAnd(p: *Parser) error{ParseFailed}!*Node {
        var left = try p.parseComparison();
        while (true) {
            const tok = p.peek() orelse break;
            if (tok.tag != .and_kw) break;
            _ = p.advance();
            const right = p.parseComparison() catch break;
            const span = Span.from(left.span.start, right.span.end);
            left = p.createNode(.{ .and_expr = .{ .left = left, .right = right } }, span);
        }
        return left;
    }

    fn parseComparison(p: *Parser) error{ParseFailed}!*Node {
        var left = try p.parseAdditive();
        while (true) {
            const tok = p.peek() orelse break;
            const op: Node.Comparison.CmpOp = switch (tok.tag) {
                .eq => .eq,
                .ne => .ne,
                .lt => .lt,
                .le => .le,
                .gt => .gt,
                .ge => .ge,
                else => break,
            };
            _ = p.advance();
            const right = p.parseAdditive() catch break;
            const span = Span.from(left.span.start, right.span.end);
            left = p.createNode(.{ .comparison = .{ .op = op, .left = left, .right = right } }, span);
        }
        return left;
    }

    fn parseAdditive(p: *Parser) error{ParseFailed}!*Node {
        var left = try p.parseMultiplicative();
        while (true) {
            const tok = p.peek() orelse break;
            const op: Node.Arithmetic.ArithOp = switch (tok.tag) {
                .plus => .add,
                .minus => .sub,
                else => break,
            };
            _ = p.advance();
            const right = p.parseMultiplicative() catch break;
            const span = Span.from(left.span.start, right.span.end);
            left = p.createNode(.{ .arithmetic = .{ .op = op, .left = left, .right = right } }, span);
        }
        return left;
    }

    fn parseMultiplicative(p: *Parser) error{ParseFailed}!*Node {
        var left = try p.parseUnary();
        while (true) {
            const tok = p.peek() orelse break;
            const op: Node.Arithmetic.ArithOp = switch (tok.tag) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => break,
            };
            _ = p.advance();
            const right = p.parseUnary() catch break;
            const span = Span.from(left.span.start, right.span.end);
            left = p.createNode(.{ .arithmetic = .{ .op = op, .left = left, .right = right } }, span);
        }
        return left;
    }

    fn parseUnary(p: *Parser) error{ParseFailed}!*Node {
        const tok = p.peek() orelse return error.ParseFailed;
        if (tok.tag == .minus) {
            const start = tok.offset;
            _ = p.advance();
            const operand = try p.parseUnary();
            return p.createNode(.{ .unary_neg = .{ .operand = operand } }, Span.from(start, operand.span.end));
        }
        return p.parsePrimary();
    }

    fn parsePrimary(p: *Parser) error{ParseFailed}!*Node {
        const start_pos = p.lex.pos;
        var node = try p.parsePrimaryInner();

        // Postfix ? operator
        while (true) {
            const tok = p.peek() orelse break;
            if (tok.tag != .question) break;
            _ = p.advance();
            node = p.createNode(.{ .optional = .{ .operand = node } }, Span.from(node.span.start, tok.offset + tok.len));
        }

        // Suffixes: .field, [idx], etc.
        _ = start_pos;
        return p.parseSuffixes(node);
    }

    fn parsePrimaryInner(p: *Parser) error{ParseFailed}!*Node {
        const tok = p.advance() orelse return error.ParseFailed;
        const span = Span.from(tok.offset, tok.offset + tok.len);

        switch (tok.tag) {
            .true_kw => return p.createNode(.{ .literal = .{ .bool_val = true } }, span),
            .false_kw => return p.createNode(.{ .literal = .{ .bool_val = false } }, span),
            .string_lit => {
                const raw = p.tokenSlice(tok);
                const content = raw[1 .. raw.len - 1];
                const decoded = p.decodeString(content);
                return p.createNode(.{ .literal = .{ .string = decoded } }, span);
            },
            .int_lit => {
                const n = std.fmt.parseInt(i64, p.tokenSlice(tok), 10) catch {
                    return p.makeError("invalid integer", span);
                };
                return p.createNode(.{ .literal = .{ .int = n } }, span);
            },
            .float_lit => {
                const f = std.fmt.parseFloat(f64, p.tokenSlice(tok)) catch {
                    return p.makeError("invalid float", span);
                };
                return p.createNode(.{ .literal = .{ .float = f } }, span);
            },
            .minus => {
                // Unary minus in primary position
                const operand = try p.parsePrimary();
                return p.createNode(.{ .unary_neg = .{ .operand = operand } }, Span.from(tok.offset, operand.span.end));
            },
            .ident => {
                return p.parseIdentPrimary(tok);
            },
            .dot => {
                return p.parseDotPrimary(tok);
            },
            .dot_dot => {
                return p.createNode(.recurse, span);
            },
            .lparen => {
                const inner = p.parsePipe() catch {
                    p.syncToNextStatement();
                    return p.makeError("expected expression in parentheses", span);
                };
                if (p.expect(.rparen) == null) {
                    p.addError("expected ')'", Span.from(inner.span.end, inner.span.end));
                }
                return p.createNode(.{ .paren = .{ .operand = inner } }, Span.from(tok.offset, p.lex.pos));
            },
            .dollar => {
                return p.parseVariableRef(tok);
            },
            .lbrace => {
                return p.parseObjectLiteral(tok);
            },
            .if_kw => {
                return p.parseIfExpr(tok);
            },
            .try_kw => {
                return p.parseTryCatch(tok);
            },
            .lbracket => {
                return p.parseArrayConstruct(tok);
            },
            .at => {
                return p.parseFormat(tok);
            },
            .string_part => {
                return p.parseStringInterp(tok, null);
            },
            .reduce_kw => {
                return p.parseReduce(tok);
            },
            .label_kw => {
                return p.parseLabelExpr(tok);
            },
            .break_kw => {
                return p.parseBreakExpr(tok);
            },
            .not_kw => {
                return p.createNode(.{ .builtin_call = .{
                    .name = "not",
                    .args = &[_]*Node{},
                } }, span);
            },
            else => {
                return p.makeError("unexpected token", span);
            },
        }
    }

    fn parseIdentPrimary(p: *Parser, tok: Token) error{ParseFailed}!*Node {
        const name = p.tokenSlice(tok);
        const span = Span.from(tok.offset, tok.offset + tok.len);

        // null keyword
        if (std.mem.eql(u8, name, "null")) {
            return p.createNode(.{ .literal = .{ .null_val = {} } }, span);
        }

        // foreach keyword
        if (std.mem.eql(u8, name, "foreach")) {
            return p.parseForeach(tok);
        }

        // Check for function/builtin call with args
        const next = p.peek() orelse return p.createFieldOrBuiltin(name, span);
        if (next.tag == .lparen) {
            return p.parseCallExpr(name, tok);
        }

        return p.createFieldOrBuiltin(name, span);
    }

    fn createFieldOrBuiltin(p: *Parser, name: []const u8, span: Span) *Node {
        // Check if it's a zero-arg builtin
        if (isZeroArgBuiltin(name)) {
            return p.createNode(.{ .builtin_call = .{
                .name = p.internName(name),
                .args = &[_]*Node{},
            } }, span);
        }
        // Otherwise it's a field access
        return p.createNode(.{ .field_access = .{
            .name = p.internName(name),
        } }, span);
    }

    fn parseCallExpr(p: *Parser, name: []const u8, tok: Token) error{ParseFailed}!*Node {
        _ = p.advance(); // consume (

        var args = std.ArrayList(*Node){};
        const peek_tok = p.peek() orelse return error.ParseFailed;
        if (peek_tok.tag != .rparen) {
            while (true) {
                const arg = p.parsePipe() catch break;
                args.append(p.arena.allocator(), arg) catch break;
                const sep = p.peek() orelse break;
                if (sep.tag == .semicolon) {
                    _ = p.advance();
                } else break;
            }
        }

        if (p.expect(.rparen) == null) {
            p.addError("expected ')'", Span.from(p.lex.pos, p.lex.pos));
        }

        const interned_name = p.internName(name);
        const args_slice = args.toOwnedSlice(p.arena.allocator()) catch &[_]*Node{};
        const end = p.lex.pos;

        if (isBuiltinName(name)) {
            return p.createNode(.{ .builtin_call = .{
                .name = interned_name,
                .args = args_slice,
            } }, Span.from(tok.offset, end));
        }

        return p.createNode(.{ .func_call = .{
            .name = interned_name,
            .args = args_slice,
        } }, Span.from(tok.offset, end));
    }

    fn parseDotPrimary(p: *Parser, tok: Token) error{ParseFailed}!*Node {
        const after = p.peek() orelse {
            return p.createNode(.identity, Span.from(tok.offset, tok.offset + tok.len));
        };

        switch (after.tag) {
            .ident => {
                _ = p.advance();
                const name = p.tokenSlice(after);
                return p.createNode(.{ .field_access = .{
                    .name = p.internName(name),
                } }, Span.from(tok.offset, after.offset + after.len));
            },
            .lbracket => {
                _ = p.advance();
                return p.parseBracket(tok.offset);
            },
            .string_lit => {
                _ = p.advance();
                const raw = p.tokenSlice(after);
                const content = raw[1 .. raw.len - 1];
                return p.createNode(.{ .field_access = .{
                    .name = p.internName(content),
                } }, Span.from(tok.offset, after.offset + after.len));
            },
            else => {
                return p.createNode(.identity, Span.from(tok.offset, tok.offset + tok.len));
            },
        }
    }

    fn parseBracket(p: *Parser, start: u32) error{ParseFailed}!*Node {
        const tok = p.peek() orelse return error.ParseFailed;

        switch (tok.tag) {
            .rbracket => {
                _ = p.advance();
                return p.createNode(.iterate, Span.from(start, tok.offset + tok.len));
            },
            .colon => {
                _ = p.advance();
                return p.parseSliceTail(start, false, 0);
            },
            .int_lit, .minus => {
                const n = p.tryParseInt() orelse return error.ParseFailed;
                const after = p.peek() orelse return error.ParseFailed;
                if (after.tag == .colon) {
                    _ = p.advance();
                    if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) {
                        return p.makeError("index out of range", Span.from(start, p.lex.pos));
                    }
                    return p.parseSliceTail(start, true, @intCast(n));
                }
                const close = p.expectOrError(.rbracket, "expected ']'");
                const end_pos = if (close) |c| c.offset + c.len else p.lex.pos;
                return p.createNode(.{ .index_access = .{ .index = n } }, Span.from(start, end_pos));
            },
            .string_lit => {
                const str_tok = p.advance().?;
                const raw = p.tokenSlice(str_tok);
                const content = raw[1 .. raw.len - 1];
                _ = p.expectOrError(.rbracket, "expected ']'");
                return p.createNode(.{ .field_access = .{
                    .name = p.internName(content),
                } }, Span.from(start, p.lex.pos));
            },
            else => {
                // Computed bracket access .[expr]
                const expr = p.parsePipe() catch return error.ParseFailed;
                _ = p.expectOrError(.rbracket, "expected ']'");
                return p.createNode(.{ .builtin_call = .{
                    .name = "__computed_access",
                    .args = p.allocSlice(*Node, &[_]*Node{expr}),
                } }, Span.from(start, p.lex.pos));
            },
        }
    }

    fn parseSliceTail(p: *Parser, start: u32, has_from: bool, from: i32) error{ParseFailed}!*Node {
        var has_to = false;
        var to: i32 = 0;
        if (p.tryParseInt()) |n| {
            has_to = true;
            if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) {
                return p.makeError("slice index out of range", Span.from(start, p.lex.pos));
            }
            to = @intCast(n);
        }
        _ = p.expectOrError(.rbracket, "expected ']'");
        return p.createNode(.{ .slice = .{
            .has_from = has_from,
            .from = from,
            .has_to = has_to,
            .to = to,
        } }, Span.from(start, p.lex.pos));
    }

    fn tryParseInt(p: *Parser) ?i64 {
        const tok = p.peek() orelse return null;
        if (tok.tag == .int_lit) {
            _ = p.advance();
            return std.fmt.parseInt(i64, p.tokenSlice(tok), 10) catch null;
        }
        if (tok.tag == .minus) {
            const saved = p.lex.pos;
            _ = p.advance();
            const next = p.peek() orelse {
                p.lex.pos = saved;
                return null;
            };
            if (next.tag == .int_lit) {
                _ = p.advance();
                const n = std.fmt.parseInt(i64, p.tokenSlice(next), 10) catch {
                    p.lex.pos = saved;
                    return null;
                };
                return -n;
            }
            p.lex.pos = saved;
            return null;
        }
        return null;
    }

    fn parseVariableRef(p: *Parser, dollar_tok: Token) error{ParseFailed}!*Node {
        const ident = p.advance() orelse return error.ParseFailed;
        if (!isVarNameToken(ident.tag)) {
            return p.makeError("expected variable name after '$'", Span.from(dollar_tok.offset, dollar_tok.offset + dollar_tok.len));
        }
        const name = p.tokenSlice(ident);
        return p.createNode(.{ .variable_ref = .{
            .name = p.internName(name),
        } }, Span.from(dollar_tok.offset, ident.offset + ident.len));
    }

    fn parseObjectLiteral(p: *Parser, brace_tok: Token) error{ParseFailed}!*Node {
        var fields = std.ArrayList(Node.ObjectField){};

        while (true) {
            const peek_tok = p.peek() orelse break;
            if (peek_tok.tag == .rbrace) {
                _ = p.advance();
                break;
            }

            const field = p.parseObjectField() catch {
                p.syncToNextStatement();
                break;
            };
            fields.append(p.arena.allocator(), field) catch break;

            const comma = p.peek() orelse break;
            if (comma.tag == .comma) {
                _ = p.advance();
            }
        }

        const fields_slice = fields.toOwnedSlice(p.arena.allocator()) catch &[_]Node.ObjectField{};
        return p.createNode(.{ .object_construct = .{
            .fields = fields_slice,
        } }, Span.from(brace_tok.offset, p.lex.pos));
    }

    fn parseObjectField(p: *Parser) error{ParseFailed}!Node.ObjectField {
        const start = p.lex.pos;
        // Legacy's `parseObjectLiteral` in `src/query/src/compiler.zig:6836-
        // 6869` dispatches `$var` as a dedicated field shape BEFORE calling
        // `parseObjectKey`. The AST parser mirrors that fork here so the
        // variable-key shapes (`{$x}`, `{$y: 4}`) produce the right node
        // structure without fighting `parseObjectKey`'s `.dollar` branch.
        const first_tok = p.peek() orelse return error.ParseFailed;

        if (first_tok.tag == .dollar) {
            _ = p.advance(); // consume '$'
            const var_tok = p.advance() orelse return error.ParseFailed;
            if (!isVarNameToken(var_tok.tag)) {
                p.addError("expected variable name after '$'", Span.from(var_tok.offset, var_tok.offset + var_tok.len));
                return error.ParseFailed;
            }
            const var_name = p.internName(p.tokenSlice(var_tok));
            const dollar_span = Span.from(first_tok.offset, var_tok.offset + var_tok.len);

            const after_dollar = p.peek();
            const has_colon = if (after_dollar) |t| t.tag == .colon else false;

            // Key shape in the AST for both `{$x}` and `{$x: VALUE}` is
            // `.ident` carrying the variable *name*. The walker detects the
            // `$` prefix by looking at the source byte at the cursor — see
            // `emitObjectField` in `src/ast/compiler.zig`.
            const key: Node.ObjectKey = .{ .ident = var_name };

            if (has_colon) {
                _ = p.advance(); // consume ':'
                const value = try p.parseObjectFieldValue();
                return .{
                    .key = key,
                    .value = value,
                    .span = Span.from(start, value.span.end),
                };
            }

            // Shorthand `{$x}` — synthesized value is the variable reference
            // itself. The walker then emits push_string(name) +
            // load_variable(id) — no replay (legacy compiler.zig:6859-6868).
            const value = p.createNode(.{ .variable_ref = .{
                .name = var_name,
            } }, dollar_span);

            return .{
                .key = key,
                .value = value,
                .span = Span.from(start, value.span.end),
            };
        }

        // Non-dollar key shapes.
        const key_start = p.lex.pos;
        const key = try p.parseObjectKey();

        const after_key = p.peek();
        const has_colon = if (after_key) |t| t.tag == .colon else false;

        if (has_colon) {
            _ = p.advance(); // consume ':'
            const value = try p.parseObjectFieldValue();
            return .{
                .key = key,
                .value = value,
                .span = Span.from(start, value.span.end),
            };
        }

        // No `:` — synthesize the shorthand value. Legacy's per-shape logic
        // (`src/query/src/compiler.zig:6880-6894`):
        //   ident   `{a}`      → value = `.a`   (field_access)
        //   string  `{"a"}`    → value = `."a"` (field_access on decoded name)
        //   (expr)  `{(expr)}` → DYNAMIC shorthand (save_input / replay /
        //                        load_computed) — walker rejects until the
        //                        shorthand-expr path is plumbed through
        //                        (Stage 7 does not need this path; fixtures
        //                        cover only colon-separated computed keys).
        const value: *Node = switch (key) {
            .ident => |name| p.createNode(.{ .field_access = .{
                .name = p.internName(name),
            } }, Span.from(key_start, p.lex.pos)),
            .string => |name| p.createNode(.{ .field_access = .{
                .name = p.internName(name),
            } }, Span.from(key_start, p.lex.pos)),
            .expr => |expr| expr,
        };

        return .{
            .key = key,
            .value = value,
            .span = Span.from(start, value.span.end),
        };
    }

    /// Parse an object-field value. Matches jq's grammar: pipe is allowed, but
    /// `,` is the field separator — NOT a generator. The base is
    /// `parseAlternative` (skipping `parseComma`) so `,` is left for the outer
    /// `parseObjectLiteral` loop to consume.
    fn parseObjectFieldValue(p: *Parser) error{ParseFailed}!*Node {
        if (p.peekIsUpdateAssign()) {
            return p.parseUpdateAssign();
        }

        var left = try p.parseAlternative();
        // Trailing assignment on the first operand (before any `|`). Matches
        // legacy `parseCommaOperand` behavior when the object value begins
        // with a non-`.path` LHS like `{a: (.b, .c) = 1}`.
        left = try p.wrapAssignGeneralIfTrailing(left);
        while (true) {
            const tok = p.peek() orelse break;
            if (tok.tag != .pipe) break;
            _ = p.advance(); // consume |

            const after = p.peek() orelse break;
            if (after.tag == .def_kw) {
                const right = p.parseFunctionDef() catch {
                    p.syncToNextStatement();
                    continue;
                };
                const span = Span.from(left.span.start, right.span.end);
                left = p.createNode(.{ .pipe = .{ .left = left, .right = right } }, span);
                break;
            }

            var right = p.parseAlternative() catch {
                p.syncToNextStatement();
                continue;
            };
            right = try p.wrapAssignGeneralIfTrailing(right);
            const span = Span.from(left.span.start, right.span.end);
            left = p.createNode(.{ .pipe = .{ .left = left, .right = right } }, span);
        }
        return left;
    }

    fn parseObjectKey(p: *Parser) error{ParseFailed}!Node.ObjectKey {
        const tok = p.peek() orelse return error.ParseFailed;

        if (tok.tag == .lparen) {
            _ = p.advance();
            const expr = try p.parseLogical();
            _ = p.expectOrError(.rparen, "expected ')'");
            return .{ .expr = expr };
        }
        if (tok.tag == .string_lit) {
            _ = p.advance();
            const raw = p.tokenSlice(tok);
            const content = raw[1 .. raw.len - 1];
            return .{ .string = p.internName(content) };
        }
        if (isVarNameToken(tok.tag) or tok.tag == .int_lit or tok.tag == .float_lit) {
            _ = p.advance();
            return .{ .ident = p.internName(p.tokenSlice(tok)) };
        }
        _ = p.advance();
        p.addError("expected object key", Span.from(tok.offset, tok.offset + tok.len));
        return error.ParseFailed;
    }

    fn parseIfExpr(p: *Parser, if_tok: Token) error{ParseFailed}!*Node {
        const cond = p.parsePipe() catch return error.ParseFailed;

        if (p.expectOrError(.then_kw, "expected 'then'") == null) {
            return p.makeError("missing 'then'", Span.from(if_tok.offset, p.lex.pos));
        }

        const then_body = p.parsePipe() catch return error.ParseFailed;

        var elifs = std.ArrayList(Node.ElifChain){};
        var else_body: ?*Node = null;

        while (true) {
            const tok = p.peek() orelse break;
            switch (tok.tag) {
                .elif_kw => {
                    _ = p.advance();
                    const elif_cond = p.parsePipe() catch break;
                    _ = p.expectOrError(.then_kw, "expected 'then' after elif condition");
                    const elif_body = p.parsePipe() catch break;
                    elifs.append(p.arena.allocator(), .{
                        .cond = elif_cond,
                        .body = elif_body,
                    }) catch break;
                },
                .else_kw => {
                    _ = p.advance();
                    else_body = p.parsePipe() catch null;
                    _ = p.expectOrError(.end_kw, "expected 'end'");
                    break;
                },
                .end_kw => {
                    _ = p.advance();
                    break;
                },
                else => {
                    p.addError("expected 'elif', 'else', or 'end'", Span.from(tok.offset, tok.offset + tok.len));
                    break;
                },
            }
        }

        const elif_slice = elifs.toOwnedSlice(p.arena.allocator()) catch &[_]Node.ElifChain{};
        return p.createNode(.{ .if_expr = .{
            .cond = cond,
            .then_body = then_body,
            .elif_chains = elif_slice,
            .else_body = else_body,
        } }, Span.from(if_tok.offset, p.lex.pos));
    }

    fn parseTryCatch(p: *Parser, try_tok: Token) error{ParseFailed}!*Node {
        const body = try p.parsePrimary();

        var catch_body: ?*Node = null;
        const tok = p.peek() orelse {
            return p.createNode(.{ .try_catch = .{
                .body = body,
                .catch_body = null,
            } }, Span.from(try_tok.offset, body.span.end));
        };

        if (tok.tag == .catch_kw) {
            _ = p.advance();
            catch_body = p.parsePrimary() catch null;
        }

        const end = if (catch_body) |cb| cb.span.end else body.span.end;
        return p.createNode(.{ .try_catch = .{
            .body = body,
            .catch_body = catch_body,
        } }, Span.from(try_tok.offset, end));
    }

    fn parseArrayConstruct(p: *Parser, bracket_tok: Token) error{ParseFailed}!*Node {
        const peek_tok = p.peek() orelse return error.ParseFailed;
        if (peek_tok.tag == .rbracket) {
            _ = p.advance();
            return p.createNode(.{ .array_construct = .{ .expr = null } }, Span.from(bracket_tok.offset, peek_tok.offset + peek_tok.len));
        }

        const expr = p.parsePipe() catch {
            _ = p.expectOrError(.rbracket, "expected ']'");
            return p.createNode(.{ .array_construct = .{ .expr = null } }, Span.from(bracket_tok.offset, p.lex.pos));
        };

        _ = p.expectOrError(.rbracket, "expected ']'");
        return p.createNode(.{ .array_construct = .{ .expr = expr } }, Span.from(bracket_tok.offset, p.lex.pos));
    }

    fn parseFormat(p: *Parser, at_tok: Token) error{ParseFailed}!*Node {
        const fmt_ident = p.advance() orelse return error.ParseFailed;
        if (fmt_ident.tag != .ident) {
            return p.makeError("expected format name after '@'", Span.from(at_tok.offset, at_tok.offset + at_tok.len));
        }
        const fmt_name = p.tokenSlice(fmt_ident);

        const after = p.peek() orelse {
            return p.createNode(.{ .builtin_call = .{
                .name = p.internFormatName(fmt_name),
                .args = &[_]*Node{},
            } }, Span.from(at_tok.offset, fmt_ident.offset + fmt_ident.len));
        };

        if (after.tag == .string_part) {
            _ = p.advance();
            return p.parseStringInterp(after, fmt_name);
        }
        if (after.tag == .string_lit) {
            _ = p.advance();
            const raw = p.tokenSlice(after);
            const content = raw[1 .. raw.len - 1];
            const decoded = p.decodeString(content);
            return p.createNode(.{ .format_string = .{
                .format = p.internName(fmt_name),
                .parts = p.allocSlice(Node.StringPart, &[_]Node.StringPart{.{ .literal = decoded }}),
            } }, Span.from(at_tok.offset, after.offset + after.len));
        }

        return p.createNode(.{ .builtin_call = .{
            .name = p.internFormatName(fmt_name),
            .args = &[_]*Node{},
        } }, Span.from(at_tok.offset, fmt_ident.offset + fmt_ident.len));
    }

    fn parseStringInterp(p: *Parser, first_part_tok: Token, format: ?[]const u8) error{ParseFailed}!*Node {
        var parts = std.ArrayList(Node.StringPart){};

        // First literal part
        const first_content = p.src[first_part_tok.offset..][0..first_part_tok.len];
        const first_decoded = p.decodeString(first_content);
        parts.append(p.arena.allocator(), .{ .literal = first_decoded }) catch {};

        // Parse interpolation expressions and remaining parts
        while (true) {
            // Parse the interpolated expression
            const expr = p.parsePipe() catch break;
            parts.append(p.arena.allocator(), .{ .expr = expr }) catch break;

            // Expect ) and scan for next string tail
            if (p.expect(.rparen) == null) {
                p.addError("expected ')' in string interpolation", Span.from(p.lex.pos, p.lex.pos));
                break;
            }

            // Use scanStringTail to get the next part
            const tail = p.lex.scanStringTail() catch break;
            const tail_content = p.src[tail.offset..][0..tail.len];
            const tail_decoded = p.decodeString(tail_content);
            parts.append(p.arena.allocator(), .{ .literal = tail_decoded }) catch break;

            if (tail.tag == .string_end) break;
            // string_part means another interpolation follows
        }

        const parts_slice = parts.toOwnedSlice(p.arena.allocator()) catch &[_]Node.StringPart{};

        if (format) |fmt| {
            return p.createNode(.{ .format_string = .{
                .format = p.internName(fmt),
                .parts = parts_slice,
            } }, Span.from(first_part_tok.offset, p.lex.pos));
        }
        return p.createNode(.{ .string_interp = .{
            .parts = parts_slice,
        } }, Span.from(first_part_tok.offset, p.lex.pos));
    }

    fn parseReduce(p: *Parser, reduce_tok: Token) error{ParseFailed}!*Node {
        const expr = try p.parseOr();

        _ = p.expectOrError(.as_kw, "expected 'as'");
        const pattern = p.parsePattern() catch return error.ParseFailed;
        _ = p.expectOrError(.lparen, "expected '('");
        const init = p.parsePipe() catch return error.ParseFailed;
        _ = p.expectOrError(.semicolon, "expected ';'");
        const update = p.parsePipe() catch return error.ParseFailed;
        _ = p.expectOrError(.rparen, "expected ')'");

        return p.createNode(.{ .reduce = .{
            .expr = expr,
            .pattern = pattern,
            .init = init,
            .update = update,
        } }, Span.from(reduce_tok.offset, p.lex.pos));
    }

    fn parseForeach(p: *Parser, tok: Token) error{ParseFailed}!*Node {
        const expr = try p.parseOr();

        _ = p.expectOrError(.as_kw, "expected 'as'");
        const pattern = p.parsePattern() catch return error.ParseFailed;
        _ = p.expectOrError(.lparen, "expected '('");
        const init = p.parsePipe() catch return error.ParseFailed;
        _ = p.expectOrError(.semicolon, "expected ';'");
        const update = p.parsePipe() catch return error.ParseFailed;

        var extract: ?*Node = null;
        const next = p.peek() orelse return error.ParseFailed;
        if (next.tag == .semicolon) {
            _ = p.advance();
            extract = p.parsePipe() catch null;
        }
        _ = p.expectOrError(.rparen, "expected ')'");

        return p.createNode(.{ .foreach = .{
            .expr = expr,
            .pattern = pattern,
            .init = init,
            .update = update,
            .extract = extract,
        } }, Span.from(tok.offset, p.lex.pos));
    }

    fn parseLabelExpr(p: *Parser, label_tok: Token) error{ParseFailed}!*Node {
        _ = p.expectOrError(.dollar, "expected '$' after 'label'");
        const ident = p.advance() orelse return error.ParseFailed;
        if (!isVarNameToken(ident.tag)) {
            return p.makeError("expected label name", Span.from(ident.offset, ident.offset + ident.len));
        }
        _ = p.expectOrError(.pipe, "expected '|' after label name");
        const body = try p.parsePipe();
        return p.createNode(.{ .label_expr = .{
            .name = p.internName(p.tokenSlice(ident)),
            .body = body,
        } }, Span.from(label_tok.offset, body.span.end));
    }

    fn parseBreakExpr(p: *Parser, break_tok: Token) error{ParseFailed}!*Node {
        _ = p.expectOrError(.dollar, "expected '$' after 'break'");
        const ident = p.advance() orelse return error.ParseFailed;
        if (!isVarNameToken(ident.tag)) {
            return p.makeError("expected label name", Span.from(ident.offset, ident.offset + ident.len));
        }
        return p.createNode(.{ .break_expr = .{
            .name = p.internName(p.tokenSlice(ident)),
        } }, Span.from(break_tok.offset, ident.offset + ident.len));
    }

    fn parseFunctionDef(p: *Parser) error{ParseFailed}!*Node {
        const def_tok = p.advance() orelse return error.ParseFailed; // consume 'def'
        const start = def_tok.offset;

        // Function name
        const name_tok = p.advance() orelse return error.ParseFailed;
        if (!isVarNameToken(name_tok.tag) and name_tok.tag != .ident) {
            return p.makeError("expected function name", Span.from(name_tok.offset, name_tok.offset + name_tok.len));
        }
        const name = p.internName(p.tokenSlice(name_tok));

        // Optional parameters
        var params = std.ArrayList(Node.FuncParam){};
        const peek_tok = p.peek() orelse return error.ParseFailed;
        if (peek_tok.tag == .lparen) {
            _ = p.advance();
            while (true) {
                const ptok = p.peek() orelse break;
                if (ptok.tag == .rparen) {
                    _ = p.advance();
                    break;
                }
                if (ptok.tag == .dollar) {
                    _ = p.advance();
                    const pname = p.advance() orelse break;
                    params.append(p.arena.allocator(), .{
                        .name = p.internName(p.tokenSlice(pname)),
                        .is_filter = false,
                        .span = Span.from(ptok.offset, pname.offset + pname.len),
                    }) catch break;
                } else if (isVarNameToken(ptok.tag)) {
                    _ = p.advance();
                    params.append(p.arena.allocator(), .{
                        .name = p.internName(p.tokenSlice(ptok)),
                        .is_filter = true,
                        .span = Span.from(ptok.offset, ptok.offset + ptok.len),
                    }) catch break;
                } else break;

                const sep = p.peek() orelse break;
                if (sep.tag == .semicolon) _ = p.advance();
            }
        }

        _ = p.expectOrError(.colon, "expected ':' after function params");

        const body = p.parseFilter() catch return error.ParseFailed;

        _ = p.expectOrError(.semicolon, "expected ';' after function body");

        const rest = p.parseFilter() catch return error.ParseFailed;

        const params_slice = params.toOwnedSlice(p.arena.allocator()) catch &[_]Node.FuncParam{};
        return p.createNode(.{ .func_def = .{
            .name = name,
            .params = params_slice,
            .body = body,
            .rest = rest,
        } }, Span.from(start, rest.span.end));
    }

    fn parseSuffixes(p: *Parser, node: *Node) error{ParseFailed}!*Node {
        const current = node;
        var ops = std.ArrayList(Node.SuffixOp){};

        while (true) {
            const tok = p.peek() orelse break;
            switch (tok.tag) {
                .dot => {
                    _ = p.advance();
                    const nt = p.peek() orelse {
                        p.addError("trailing dot", Span.from(tok.offset, tok.offset + tok.len));
                        break;
                    };
                    switch (nt.tag) {
                        .ident => {
                            _ = p.advance();
                            ops.append(p.arena.allocator(), .{ .field = p.internName(p.tokenSlice(nt)) }) catch break;
                        },
                        .lbracket => {
                            _ = p.advance();
                            const bracket_node = p.parseBracket(tok.offset) catch break;
                            switch (bracket_node.kind) {
                                .iterate => ops.append(p.arena.allocator(), .iterate) catch break,
                                .index_access => |ia| ops.append(p.arena.allocator(), .{ .index = ia.index }) catch break,
                                .field_access => |fa| ops.append(p.arena.allocator(), .{ .bracket_str = fa.name }) catch break,
                                .slice => |s| ops.append(p.arena.allocator(), .{ .slice = s }) catch break,
                                .builtin_call => |bc| {
                                    if (bc.args.len > 0) {
                                        ops.append(p.arena.allocator(), .{ .bracket_expr = bc.args[0] }) catch break;
                                    }
                                },
                                else => break,
                            }
                        },
                        .string_lit => {
                            _ = p.advance();
                            const raw = p.tokenSlice(nt);
                            const content = raw[1 .. raw.len - 1];
                            ops.append(p.arena.allocator(), .{ .field = p.internName(content) }) catch break;
                        },
                        else => {
                            p.addError("expected field name after '.'", Span.from(tok.offset, tok.offset + tok.len));
                            break;
                        },
                    }
                },
                .lbracket => {
                    _ = p.advance();
                    const bracket_node = p.parseBracket(tok.offset) catch break;
                    switch (bracket_node.kind) {
                        .iterate => ops.append(p.arena.allocator(), .iterate) catch break,
                        .index_access => |ia| ops.append(p.arena.allocator(), .{ .index = ia.index }) catch break,
                        .field_access => |fa| ops.append(p.arena.allocator(), .{ .bracket_str = fa.name }) catch break,
                        .slice => |s| ops.append(p.arena.allocator(), .{ .slice = s }) catch break,
                        .builtin_call => |bc| {
                            if (bc.args.len > 0) {
                                ops.append(p.arena.allocator(), .{ .bracket_expr = bc.args[0] }) catch break;
                            }
                        },
                        else => break,
                    }
                },
                .question => {
                    _ = p.advance();
                    ops.append(p.arena.allocator(), .optional) catch break;
                },
                else => break,
            }
        }

        if (ops.items.len == 0) return current;

        const ops_slice = ops.toOwnedSlice(p.arena.allocator()) catch &[_]Node.SuffixOp{};
        return p.createNode(.{ .suffix = .{
            .base = current,
            .ops = ops_slice,
        } }, Span.from(current.span.start, p.lex.pos));
    }

    fn peekIsUpdateAssign(p: *Parser) bool {
        const saved = p.lex.pos;
        defer p.lex.pos = saved;

        const first = p.lex.next() catch return false;
        if (first.tag != .dot) return false;

        while (true) {
            const t = p.lex.peek() catch return false;
            switch (t.tag) {
                .ident => {
                    _ = p.lex.next() catch return false;
                    const sep = p.lex.peek() catch return false;
                    if (sep.tag == .dot) _ = p.lex.next() catch return false;
                },
                .lbracket => {
                    _ = p.lex.next() catch return false;
                    const inner = p.lex.peek() catch return false;
                    switch (inner.tag) {
                        .int_lit, .string_lit => {
                            _ = p.lex.next() catch return false;
                            const close = p.lex.next() catch return false;
                            if (close.tag != .rbracket) return false;
                            const sep = p.lex.peek() catch return false;
                            if (sep.tag == .dot) _ = p.lex.next() catch return false;
                        },
                        // `.[]` iteration cannot be represented as a static
                        // PathStep sequence — legacy's parseUpdateAssign
                        // (compiler.zig:1801-1806) bails to compilePathExprUpdate
                        // the moment it sees a bare `]`. We do the same here so
                        // the walker's `assign_general` path handles it.
                        .rbracket => return false,
                        else => return false,
                    }
                },
                .eq_assign, .pipe_eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .double_slash_eq => return true,
                else => return false,
            }
        }
    }

    fn parseUpdateAssign(p: *Parser) error{ParseFailed}!*Node {
        const start_tok = p.advance() orelse return error.ParseFailed; // consume .
        var path_steps = std.ArrayList(Node.PathStep){};

        while (true) {
            const t = p.peek() orelse break;
            switch (t.tag) {
                .ident => {
                    _ = p.advance();
                    path_steps.append(p.arena.allocator(), .{
                        .key = p.internName(p.tokenSlice(t)),
                    }) catch break;
                    const sep = p.peek() orelse break;
                    if (sep.tag == .dot) _ = p.advance();
                },
                .lbracket => {
                    _ = p.advance();
                    const inner = p.peek() orelse break;
                    switch (inner.tag) {
                        .int_lit => {
                            _ = p.advance();
                            const n = std.fmt.parseInt(i64, p.tokenSlice(inner), 10) catch break;
                            _ = p.expect(.rbracket);
                            path_steps.append(p.arena.allocator(), .{ .index = n }) catch break;
                            const sep = p.peek() orelse break;
                            if (sep.tag == .dot) _ = p.advance();
                        },
                        .string_lit => {
                            _ = p.advance();
                            const raw = p.tokenSlice(inner);
                            const content = raw[1 .. raw.len - 1];
                            _ = p.expect(.rbracket);
                            path_steps.append(p.arena.allocator(), .{
                                .key = p.internName(content),
                            }) catch break;
                            const sep = p.peek() orelse break;
                            if (sep.tag == .dot) _ = p.advance();
                        },
                        .rbracket => {
                            _ = p.advance();
                            path_steps.append(p.arena.allocator(), .iterate) catch break;
                            const sep = p.peek() orelse break;
                            if (sep.tag == .dot) _ = p.advance();
                        },
                        else => break,
                    }
                },
                .eq_assign, .pipe_eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .double_slash_eq => break,
                else => break,
            }
        }

        const assign_tok = p.advance() orelse return error.ParseFailed;
        const op: Node.UpdateAssign.AssignOp = switch (assign_tok.tag) {
            .pipe_eq => .pipe_eq,
            .eq_assign => .eq,
            .plus_eq => .plus_eq,
            .minus_eq => .minus_eq,
            .star_eq => .star_eq,
            .slash_eq => .slash_eq,
            .percent_eq => .percent_eq,
            .double_slash_eq => .double_slash_eq,
            else => return error.ParseFailed,
        };

        const rhs = try p.parseAlternative();

        const path_slice = path_steps.toOwnedSlice(p.arena.allocator()) catch &[_]Node.PathStep{};
        return p.createNode(.{ .update_assign = .{
            .path = path_slice,
            .op = op,
            .rhs = rhs,
        } }, Span.from(start_tok.offset, rhs.span.end));
    }

    // ── Pattern parsing ────────────────────────────────────────────

    fn parsePattern(p: *Parser) error{ParseFailed}!Pattern {
        const tok = p.peek() orelse return error.ParseFailed;

        switch (tok.tag) {
            .dollar => {
                _ = p.advance();
                const ident = p.advance() orelse return error.ParseFailed;
                if (!isVarNameToken(ident.tag)) return error.ParseFailed;
                return .{ .simple = p.internName(p.tokenSlice(ident)) };
            },
            .lbracket => {
                _ = p.advance();
                var elements = std.ArrayList(Pattern){};
                while (true) {
                    const next = p.peek() orelse break;
                    if (next.tag == .rbracket) break;
                    const elem = try p.parsePattern();
                    elements.append(p.arena.allocator(), elem) catch break;
                    const after = p.peek() orelse break;
                    if (after.tag == .comma) _ = p.advance();
                }
                _ = p.expectOrError(.rbracket, "expected ']'");
                return .{ .array = elements.toOwnedSlice(p.arena.allocator()) catch &[_]Pattern{} };
            },
            .lbrace => {
                _ = p.advance();
                var fields = std.ArrayList(ObjectPatternField){};
                while (true) {
                    const next = p.peek() orelse break;
                    if (next.tag == .rbrace) break;
                    const field = try p.parsePatternField();
                    fields.append(p.arena.allocator(), field) catch break;
                    const after = p.peek() orelse break;
                    if (after.tag == .comma) _ = p.advance();
                }
                _ = p.expectOrError(.rbrace, "expected '}'");
                return .{ .object = fields.toOwnedSlice(p.arena.allocator()) catch &[_]ObjectPatternField{} };
            },
            else => return error.ParseFailed,
        }
    }

    fn parsePatternField(p: *Parser) error{ParseFailed}!ObjectPatternField {
        const tok = p.peek() orelse return error.ParseFailed;

        // Shorthand: $var
        if (tok.tag == .dollar) {
            _ = p.advance();
            const ident = p.advance() orelse return error.ParseFailed;
            if (!isVarNameToken(ident.tag)) return error.ParseFailed;
            const name = p.internName(p.tokenSlice(ident));
            return .{
                .key = .{ .static = name },
                .pattern = .{ .simple = name },
            };
        }

        // Computed key: (expr): pattern
        if (tok.tag == .lparen) {
            _ = p.advance();
            const expr = p.parsePipe() catch return error.ParseFailed;
            _ = p.expectOrError(.rparen, "expected ')'");
            _ = p.expectOrError(.colon, "expected ':'");
            const sub = try p.parsePattern();
            return .{
                .key = .{ .computed = expr },
                .pattern = sub,
            };
        }

        // Static key: name: pattern
        const key_name = try p.parseStaticPatternKey();
        _ = p.expectOrError(.colon, "expected ':'");
        const sub = try p.parsePattern();
        return .{
            .key = .{ .static = key_name },
            .pattern = sub,
        };
    }

    fn parseStaticPatternKey(p: *Parser) error{ParseFailed}![]const u8 {
        const tok = p.advance() orelse return error.ParseFailed;
        if (tok.tag == .string_lit) {
            const raw = p.tokenSlice(tok);
            return p.internName(raw[1 .. raw.len - 1]);
        }
        if (isVarNameToken(tok.tag)) {
            return p.internName(p.tokenSlice(tok));
        }
        return error.ParseFailed;
    }

    // ── String decoding ────────────────────────────────────────────

    fn decodeString(p: *Parser, raw: []const u8) []const u8 {
        // Fast path: no escapes
        if (std.mem.indexOf(u8, raw, "\\") == null) {
            return p.internName(raw);
        }
        var buf = std.ArrayList(u8){};
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] != '\\') {
                buf.append(p.arena.allocator(), raw[i]) catch break;
                i += 1;
                continue;
            }
            i += 1;
            if (i >= raw.len) break;
            switch (raw[i]) {
                '\\' => buf.append(p.arena.allocator(), '\\') catch {},
                '"' => buf.append(p.arena.allocator(), '"') catch {},
                '/' => buf.append(p.arena.allocator(), '/') catch {},
                'n' => buf.append(p.arena.allocator(), '\n') catch {},
                'r' => buf.append(p.arena.allocator(), '\r') catch {},
                't' => buf.append(p.arena.allocator(), '\t') catch {},
                'b' => buf.append(p.arena.allocator(), '\x08') catch {},
                'f' => buf.append(p.arena.allocator(), '\x0C') catch {},
                'u' => {
                    i += 1;
                    if (i + 4 > raw.len) break;
                    const hi = std.fmt.parseInt(u21, raw[i..][0..4], 16) catch break;
                    i += 4;
                    var codepoint: u21 = hi;
                    if (hi >= 0xD800 and hi <= 0xDBFF) {
                        if (i + 6 <= raw.len and raw[i] == '\\' and raw[i + 1] == 'u') {
                            const lo = std.fmt.parseInt(u21, raw[i + 2 ..][0..4], 16) catch break;
                            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                codepoint = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
                                i += 6;
                            }
                        }
                    }
                    var utf8_buf: [4]u8 = undefined;
                    const utf8_len = std.unicode.utf8Encode(@intCast(codepoint), &utf8_buf) catch break;
                    buf.appendSlice(p.arena.allocator(), utf8_buf[0..utf8_len]) catch {};
                    continue;
                },
                else => buf.append(p.arena.allocator(), raw[i]) catch {},
            }
            i += 1;
        }
        return buf.toOwnedSlice(p.arena.allocator()) catch raw;
    }

    // ── Name interning ─────────────────────────────────────────────

    fn internName(p: *Parser, name: []const u8) []const u8 {
        return p.arena.allocator().dupe(u8, name) catch name;
    }

    fn internFormatName(p: *Parser, name: []const u8) []const u8 {
        const buf = p.arena.allocator().alloc(u8, name.len + 1) catch return name;
        buf[0] = '@';
        @memcpy(buf[1..], name);
        return buf;
    }
};

// ── Token classification helpers ────────────────────────────────────

fn isVarNameToken(tag: Token.Tag) bool {
    return tag == .ident or tag == .and_kw or tag == .or_kw or
        tag == .not_kw or tag == .true_kw or tag == .false_kw or
        tag == .def_kw or tag == .as_kw or tag == .reduce_kw or
        tag == .if_kw or tag == .then_kw or tag == .elif_kw or
        tag == .else_kw or tag == .end_kw or tag == .try_kw or
        tag == .catch_kw or tag == .label_kw or tag == .break_kw;
}

fn isZeroArgBuiltin(name: []const u8) bool {
    const builtins = [_][]const u8{
        "length",     "keys",         "keys_unsorted", "values",         "type",
        "empty",      "tostring",     "tonumber",      "error",          "add",
        "sort",       "reverse",      "flatten",       "min",            "max",
        "to_entries", "from_entries", "any",           "all",            "unique",
        "paths",      "leaf_paths",   "not",           "builtins",       "debug",
        "stderr",     "input",        "inputs",        "env",            "halt",
        "abs",        "floor",        "ceil",          "round",          "sqrt",
        "fabs",       "nan",          "infinite",      "isinfinite",     "isnan",
        "isnormal",   "exp",          "exp2",          "exp10",          "log",
        "log2",       "log10",        "cbrt",          "sin",            "cos",
        "tan",        "asin",         "acos",          "atan",           "rint",
        "nearbyint",  "trunc",        "significand",   "logb",           "j0",
        "j1",         "lgamma",       "tgamma",        "ascii_downcase", "ascii_upcase",
        "ascii",      "explode",      "implode",       "tojson",         "fromjson",
        "transpose",  "first",        "last",          "not",
    };
    for (builtins) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

fn isBuiltinName(name: []const u8) bool {
    if (isZeroArgBuiltin(name)) return true;
    // Kept in sync with legacy `isArgBuiltin` at
    // `src/query/src/compiler.zig:2995-3066`. Every name legacy treats as a
    // builtin (not a user function) when called with args must appear here,
    // so the AST emits `.builtin_call` instead of `.func_call`.
    const arg_builtins = [_][]const u8{
        "map",       "select",       "has",      "in",         "range",
        "flatten",   "contains",     "inside",   "indices",    "index",
        "rindex",    "sort_by",      "group_by", "min_by",     "max_by",
        "unique_by", "with_entries", "any",      "all",        "first",
        "last",      "limit",        "del",      "while",      "until",
        "repeat",    "getpath",      "setpath",  "delpaths",   "pow",
        "atan2",     "remainder",    "hypot",    "scalb",      "scalbln",
        "ldexp",     "fma",          "drem",     "map_values", "isempty",
        "debug",     "halt_error",   "split",    "join",       "startswith",
        "endswith",  "ltrimstr",     "rtrimstr", "trimstr",    "test",
        "match",     "sub",          "gsub",     "capture",    "scan",
        "splits",    "bsearch",      "strftime", "strptime",   "strflocaltime",
        "error",     "skip",         "nth",      "INDEX",      "IN",
        "JOIN",      "walk",         "path",     "pick",
    };
    for (arg_builtins) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}
