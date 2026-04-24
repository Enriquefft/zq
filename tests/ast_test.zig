const std = @import("std");
const ast = @import("ast");

const testing = std.testing;
const Node = ast.Node;

fn parse(source: []const u8) ast.ParseResult {
    return ast.parse(source, testing.allocator);
}

// ── Basic expressions ────────────────────────────────────────────────────

test "parse identity" {
    var result = parse(".");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    try testing.expect(result.root.kind == .identity);
}

test "parse recurse" {
    var result = parse("..");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    try testing.expect(result.root.kind == .recurse);
}

test "parse field access" {
    var result = parse(".foo");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .field_access => |fa| try testing.expectEqualStrings("foo", fa.name),
        else => return error.TestUnexpectedResult,
    }
}

test "parse integer literal" {
    var result = parse("42");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .literal => |lit| switch (lit) {
            .int => |v| try testing.expectEqual(@as(i64, 42), v),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse string literal" {
    var result = parse("\"hello\"");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .literal => |lit| switch (lit) {
            .string => |s| try testing.expectEqualStrings("hello", s),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse null literal" {
    var result = parse("null");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .literal => |lit| switch (lit) {
            .null_val => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse boolean literals" {
    {
        var result = parse("true");
        defer result.deinit();
        try testing.expect(!result.hasErrors());
        switch (result.root.kind) {
            .literal => |lit| switch (lit) {
                .bool_val => |v| try testing.expect(v),
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        }
    }
    {
        var result = parse("false");
        defer result.deinit();
        try testing.expect(!result.hasErrors());
        switch (result.root.kind) {
            .literal => |lit| switch (lit) {
                .bool_val => |v| try testing.expect(!v),
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

// ── Pipes and commas ─────────────────────────────────────────────────────

test "parse pipe" {
    var result = parse(". | .foo");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    try testing.expect(result.root.kind == .pipe);
}

test "parse comma" {
    var result = parse(".foo, .bar");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    try testing.expect(result.root.kind == .comma);
}

// ── Operators ────────────────────────────────────────────────────────────

test "parse arithmetic" {
    var result = parse(".a + .b");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .arithmetic => |arith| try testing.expect(arith.op == .add),
        else => return error.TestUnexpectedResult,
    }
}

test "parse comparison" {
    var result = parse(".a == .b");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .comparison => |cmp| try testing.expect(cmp.op == .eq),
        else => return error.TestUnexpectedResult,
    }
}

test "parse alternative" {
    var result = parse(".a // .b");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    try testing.expect(result.root.kind == .alternative);
}

// ── Control flow ─────────────────────────────────────────────────────────

test "parse if-then-end" {
    var result = parse("if . then .a end");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    try testing.expect(result.root.kind == .if_expr);
}

test "parse if-then-else-end" {
    var result = parse("if . then .a else .b end");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .if_expr => |ie| try testing.expect(ie.else_body != null),
        else => return error.TestUnexpectedResult,
    }
}

test "parse try-catch" {
    var result = parse("try .a catch .b");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .try_catch => |tc| try testing.expect(tc.catch_body != null),
        else => return error.TestUnexpectedResult,
    }
}

// ── Constructors ─────────────────────────────────────────────────────────

test "parse empty array" {
    var result = parse("[]");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .array_construct => |ac| try testing.expect(ac.expr == null),
        else => return error.TestUnexpectedResult,
    }
}

test "parse array construct" {
    var result = parse("[.[] | . + 1]");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .array_construct => |ac| try testing.expect(ac.expr != null),
        else => return error.TestUnexpectedResult,
    }
}

test "parse object construct" {
    var result = parse("{a: .b, c: .d}");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .object_construct => |oc| try testing.expectEqual(@as(usize, 2), oc.fields.len),
        else => return error.TestUnexpectedResult,
    }
}

// BUG-005 defect 1: pipe inside object-field value was rejected by both
// parsers because `parseObjectField` dispatched to `parseAlternative` (which
// only handles `//`), never to `parsePipe`. Mirrors jq's grammar where the
// value slot accepts pipe but `,` remains the field separator.
test "parse object construct: pipe in field value" {
    var result = parse("{a: 1 | length}");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .object_construct => |oc| {
            try testing.expectEqual(@as(usize, 1), oc.fields.len);
            try testing.expect(oc.fields[0].value.kind == .pipe);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse object construct: pipe in field value followed by second field" {
    var result = parse("{a: .x | length, b: 2}");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .object_construct => |oc| {
            try testing.expectEqual(@as(usize, 2), oc.fields.len);
            try testing.expect(oc.fields[0].value.kind == .pipe);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse object construct: comma still separates fields (not a generator)" {
    var result = parse("{a: 1, b: 2}");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .object_construct => |oc| {
            try testing.expectEqual(@as(usize, 2), oc.fields.len);
            // Neither value folds `,` into a comma node.
            try testing.expect(oc.fields[0].value.kind != .comma);
            try testing.expect(oc.fields[1].value.kind != .comma);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse object construct: Nix mdbook anchors filter parses" {
    // Reduced from the filter that broke `nixos-rebuild switch` (mdbook
    // `anchors` preprocessor): `content: .Chapter.content | transformer,`
    // was rejected with `query syntax error` before the fix.
    var result = parse("{content: .Chapter.content | length}");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .object_construct => |oc| {
            try testing.expectEqual(@as(usize, 1), oc.fields.len);
            try testing.expect(oc.fields[0].value.kind == .pipe);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ── Variable reference ───────────────────────────────────────────────────

test "parse variable ref" {
    var result = parse("$x");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .variable_ref => |vr| try testing.expectEqualStrings("x", vr.name),
        else => return error.TestUnexpectedResult,
    }
}

// ── Function definitions ─────────────────────────────────────────────────

test "parse function def" {
    var result = parse("def double: . * 2; double");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .func_def => |fd| {
            try testing.expectEqualStrings("double", fd.name);
            try testing.expectEqual(@as(usize, 0), fd.params.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse function def with params" {
    var result = parse("def f(x): x; f(1)");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .func_def => |fd| {
            try testing.expectEqualStrings("f", fd.name);
            try testing.expectEqual(@as(usize, 1), fd.params.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ── Parenthesized expression ─────────────────────────────────────────────

test "parse paren" {
    var result = parse("(. + 1)");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    try testing.expect(result.root.kind == .paren);
}

// ── Error recovery ───────────────────────────────────────────────────────

test "error recovery: missing end" {
    var result = parse("if . then .a");
    defer result.deinit();
    try testing.expect(result.hasErrors());
    // Should still produce an AST node
    try testing.expect(result.root.kind == .if_expr or result.root.kind == .error_node);
}

test "error recovery: unexpected token" {
    var result = parse(".) invalid");
    defer result.deinit();
    try testing.expect(result.hasErrors());
}

test "error recovery: unterminated string" {
    var result = parse("\"hello");
    defer result.deinit();
    // Should produce a result (possibly with errors) rather than crash
    _ = result.root;
}

// ── Reduce/foreach ───────────────────────────────────────────────────────

test "parse reduce" {
    var result = parse("reduce .[] as $x (0; . + $x)");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    try testing.expect(result.root.kind == .reduce);
}

// ── Builtin calls ────────────────────────────────────────────────────────

test "parse zero-arg builtin" {
    var result = parse("length");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .builtin_call => |bc| try testing.expectEqualStrings("length", bc.name),
        else => return error.TestUnexpectedResult,
    }
}

test "parse builtin with args" {
    var result = parse("map(. + 1)");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    switch (result.root.kind) {
        .builtin_call => |bc| {
            try testing.expectEqualStrings("map", bc.name);
            try testing.expectEqual(@as(usize, 1), bc.args.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ── Spans ────────────────────────────────────────────────────────────────

test "spans are valid" {
    var result = parse(".foo | .bar");
    defer result.deinit();
    try testing.expect(!result.hasErrors());
    try testing.expect(result.root.span.start < result.root.span.end);
    try testing.expect(result.root.span.end <= 11); // source length
}
