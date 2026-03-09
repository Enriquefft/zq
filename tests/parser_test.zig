const std = @import("std");
const parser = @import("parser");
const types = @import("types");

const Parser = parser.Parser;
const FeedResult = parser.FeedResult;
const Tape = parser.Tape;

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Parse a complete, single-chunk input and assert .done is returned.
fn parseAll(p: *Parser, input: []const u8) !Tape {
    const result = try p.feed(input, true);
    switch (result) {
        .done => |tape| return tape,
        .need_more => return error.UnexpectedNeedMore,
    }
}

/// Parse, expecting a specific ZqError.
fn expectError(p: *Parser, input: []const u8, expected: anyerror) !void {
    const result = p.feed(input, true);
    try std.testing.expectError(expected, result);
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

test "init and deinit" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
}

test "reset is idempotent" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    p.reset();
    p.reset();
    const tape = try parseAll(&p, "1");
    try std.testing.expectEqual(@as(usize, 1), tape.entries.len);
}

// ── Scalar values ─────────────────────────────────────────────────────────────

test "null value" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "null");
    try std.testing.expectEqual(@as(usize, 1), tape.entries.len);
    try std.testing.expectEqual(types.Tape.Tag.null_val, tape.entries[0].tag);
}

test "true value" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "true");
    try std.testing.expectEqual(@as(usize, 1), tape.entries.len);
    try std.testing.expectEqual(types.Tape.Tag.true_val, tape.entries[0].tag);
}

test "false value" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "false");
    try std.testing.expectEqual(@as(usize, 1), tape.entries.len);
    try std.testing.expectEqual(types.Tape.Tag.false_val, tape.entries[0].tag);
}

test "integer: positive" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "42");
    try std.testing.expectEqual(@as(usize, 1), tape.entries.len);
    try std.testing.expectEqual(types.Tape.Tag.int, tape.entries[0].tag);
    try std.testing.expectEqual(@as(i64, 42), tape.entries[0].payload.int);
}

test "integer: negative" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "-7");
    try std.testing.expectEqual(types.Tape.Tag.int, tape.entries[0].tag);
    try std.testing.expectEqual(@as(i64, -7), tape.entries[0].payload.int);
}

test "integer: zero" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "0");
    try std.testing.expectEqual(types.Tape.Tag.int, tape.entries[0].tag);
    try std.testing.expectEqual(@as(i64, 0), tape.entries[0].payload.int);
}

test "float: decimal" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "3.14");
    try std.testing.expectEqual(types.Tape.Tag.float, tape.entries[0].tag);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), tape.entries[0].payload.float, 1e-10);
}

test "float: exponent" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "1e10");
    try std.testing.expectEqual(types.Tape.Tag.float, tape.entries[0].tag);
    try std.testing.expectApproxEqAbs(@as(f64, 1e10), tape.entries[0].payload.float, 1.0);
}

test "float: negative exponent" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "-2.5E-3");
    try std.testing.expectEqual(types.Tape.Tag.float, tape.entries[0].tag);
    try std.testing.expectApproxEqAbs(@as(f64, -2.5e-3), tape.entries[0].payload.float, 1e-15);
}

test "string: empty" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "\"\"");
    try std.testing.expectEqual(types.Tape.Tag.string, tape.entries[0].tag);
    const s = tape.getString(tape.entries[0].payload.string);
    try std.testing.expectEqualStrings("", s);
}

test "string: hello" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "\"hello\"");
    const s = tape.getString(tape.entries[0].payload.string);
    try std.testing.expectEqualStrings("hello", s);
}

test "string: escape sequences" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "\"\\n\\t\\r\\\\\\/\\\"\"");
    const s = tape.getString(tape.entries[0].payload.string);
    try std.testing.expectEqualStrings("\n\t\r\\/\"", s);
}

test "string: \\uXXXX basic" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    // \u0041 = 'A'
    const tape = try parseAll(&p, "\"\\u0041\"");
    const s = tape.getString(tape.entries[0].payload.string);
    try std.testing.expectEqualStrings("A", s);
}

test "string: surrogate pair (emoji)" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    // \uD83D\uDC08 = 🐈 (cat, U+1F408)
    const tape = try parseAll(&p, "\"\\uD83D\\uDC08\"");
    const s = tape.getString(tape.entries[0].payload.string);
    // U+1F408 encoded as UTF-8: F0 9F 90 88
    try std.testing.expectEqualStrings("\xF0\x9F\x90\x88", s);
}

test "string: raw UTF-8 (multibyte)" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "\"caf\xC3\xA9\""); // café
    const s = tape.getString(tape.entries[0].payload.string);
    try std.testing.expectEqualStrings("caf\xC3\xA9", s);
}

// ── Containers ────────────────────────────────────────────────────────────────

test "empty object" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "{}");
    try std.testing.expectEqual(@as(usize, 2), tape.entries.len);
    try std.testing.expectEqual(types.Tape.Tag.object_start, tape.entries[0].tag);
    try std.testing.expectEqual(types.Tape.Tag.object_end,   tape.entries[1].tag);
    // skip must point past object_end
    try std.testing.expectEqual(@as(u32, 2), tape.entries[0].payload.skip);
}

test "empty array" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "[]");
    try std.testing.expectEqual(@as(usize, 2), tape.entries.len);
    try std.testing.expectEqual(types.Tape.Tag.array_start, tape.entries[0].tag);
    try std.testing.expectEqual(types.Tape.Tag.array_end,   tape.entries[1].tag);
    try std.testing.expectEqual(@as(u32, 2), tape.entries[0].payload.skip);
}

test "object with one key-value pair" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    // {"a":1}
    // tape: [object_start(skip=4), key("a"), int(1), object_end]
    const tape = try parseAll(&p, "{\"a\":1}");
    try std.testing.expectEqual(@as(usize, 4), tape.entries.len);
    try std.testing.expectEqual(types.Tape.Tag.object_start, tape.entries[0].tag);
    try std.testing.expectEqual(@as(u32, 4), tape.entries[0].payload.skip);
    try std.testing.expectEqual(types.Tape.Tag.key,          tape.entries[1].tag);
    try std.testing.expectEqualStrings("a", tape.getString(tape.entries[1].payload.string));
    try std.testing.expectEqual(types.Tape.Tag.int,          tape.entries[2].tag);
    try std.testing.expectEqual(@as(i64, 1), tape.entries[2].payload.int);
    try std.testing.expectEqual(types.Tape.Tag.object_end,   tape.entries[3].tag);
}

test "array with three integers" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    // [1,2,3]
    // tape: [array_start(skip=5), int(1), int(2), int(3), array_end]
    const tape = try parseAll(&p, "[1,2,3]");
    try std.testing.expectEqual(@as(usize, 5), tape.entries.len);
    try std.testing.expectEqual(types.Tape.Tag.array_start, tape.entries[0].tag);
    try std.testing.expectEqual(@as(u32, 5), tape.entries[0].payload.skip);
    try std.testing.expectEqual(@as(i64, 1), tape.entries[1].payload.int);
    try std.testing.expectEqual(@as(i64, 2), tape.entries[2].payload.int);
    try std.testing.expectEqual(@as(i64, 3), tape.entries[3].payload.int);
    try std.testing.expectEqual(types.Tape.Tag.array_end, tape.entries[4].tag);
}

test "nested object inside array" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    // [{}]
    // tape: [array_start(skip=4), object_start(skip=3), object_end, array_end]
    const tape = try parseAll(&p, "[{}]");
    try std.testing.expectEqual(@as(usize, 4), tape.entries.len);
    try std.testing.expectEqual(@as(u32, 4), tape.entries[0].payload.skip);
    try std.testing.expectEqual(types.Tape.Tag.object_start, tape.entries[1].tag);
    try std.testing.expectEqual(@as(u32, 3), tape.entries[1].payload.skip);
    try std.testing.expectEqual(types.Tape.Tag.object_end,   tape.entries[2].tag);
    try std.testing.expectEqual(types.Tape.Tag.array_end,    tape.entries[3].tag);
}

test "multiple key-value pairs" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "{\"x\":1,\"y\":2}");
    try std.testing.expectEqual(@as(usize, 6), tape.entries.len);
    try std.testing.expectEqual(types.Tape.Tag.object_start, tape.entries[0].tag);
    try std.testing.expectEqualStrings("x", tape.getString(tape.entries[1].payload.string));
    try std.testing.expectEqual(@as(i64, 1), tape.entries[2].payload.int);
    try std.testing.expectEqualStrings("y", tape.getString(tape.entries[3].payload.string));
    try std.testing.expectEqual(@as(i64, 2), tape.entries[4].payload.int);
    try std.testing.expectEqual(types.Tape.Tag.object_end, tape.entries[5].tag);
}

// ── Whitespace ────────────────────────────────────────────────────────────────

test "whitespace around value" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "  42  ");
    try std.testing.expectEqual(@as(i64, 42), tape.entries[0].payload.int);
}

test "whitespace inside object" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, " { \"k\" : 1 } ");
    try std.testing.expectEqual(@as(usize, 4), tape.entries.len);
}

// ── Streaming (multi-chunk) ───────────────────────────────────────────────────

test "streaming: need_more then done" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const r1 = try p.feed("{\"a\":", false);
    try std.testing.expectEqual(FeedResult.need_more, r1);
    const r2 = try p.feed("1}", true);
    switch (r2) {
        .done => |tape| {
            try std.testing.expectEqual(@as(usize, 4), tape.entries.len);
            try std.testing.expectEqual(@as(i64, 1), tape.entries[2].payload.int);
        },
        .need_more => return error.UnexpectedNeedMore,
    }
}

test "streaming: number split across chunks" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    _ = try p.feed("12", false);
    const r = try p.feed("34", true);
    switch (r) {
        .done => |tape| try std.testing.expectEqual(@as(i64, 1234), tape.entries[0].payload.int),
        .need_more => return error.UnexpectedNeedMore,
    }
}

test "streaming: string split across chunks" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    _ = try p.feed("\"hel", false);
    const r = try p.feed("lo\"", true);
    switch (r) {
        .done => |tape| {
            const s = tape.getString(tape.entries[0].payload.string);
            try std.testing.expectEqualStrings("hello", s);
        },
        .need_more => return error.UnexpectedNeedMore,
    }
}

// ── reset() reuse ─────────────────────────────────────────────────────────────

test "reset: reuse parser for second record" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();

    const tape1 = try parseAll(&p, "1");
    try std.testing.expectEqual(@as(i64, 1), tape1.entries[0].payload.int);

    p.reset();

    const tape2 = try parseAll(&p, "2");
    try std.testing.expectEqual(@as(i64, 2), tape2.entries[0].payload.int);
}

test "reset: string_buf reused without growth" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();

    _ = try parseAll(&p, "\"first\"");
    p.reset();
    const tape = try parseAll(&p, "\"second\"");
    const s = tape.getString(tape.entries[0].payload.string);
    try std.testing.expectEqualStrings("second", s);
}

// ── Auto-Close ────────────────────────────────────────────────────────────────

test "auto-close: truncated object with value" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    // {"a":1  <- truncated; should auto-close to {"a":1}
    const tape = try parseAll(&p, "{\"a\":1");
    try std.testing.expectEqual(@as(usize, 4), tape.entries.len);
    try std.testing.expectEqual(types.Tape.Tag.object_start, tape.entries[0].tag);
    try std.testing.expectEqual(types.Tape.Tag.object_end,   tape.entries[3].tag);
}

test "auto-close: empty object" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "{");
    try std.testing.expectEqual(@as(usize, 2), tape.entries.len);
    try std.testing.expectEqual(types.Tape.Tag.object_end, tape.entries[1].tag);
}

test "auto-close: empty array" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "[");
    try std.testing.expectEqual(@as(usize, 2), tape.entries.len);
    try std.testing.expectEqual(types.Tape.Tag.array_end, tape.entries[1].tag);
}

test "auto-close: truncated nested" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    // [{"a":1  <- both containers should be closed
    const tape = try parseAll(&p, "[{\"a\":1");
    try std.testing.expectEqual(@as(usize, 6), tape.entries.len);
    try std.testing.expectEqual(types.Tape.Tag.array_start,  tape.entries[0].tag);
    try std.testing.expectEqual(types.Tape.Tag.object_start, tape.entries[1].tag);
    try std.testing.expectEqual(types.Tape.Tag.object_end,   tape.entries[4].tag);
    try std.testing.expectEqual(types.Tape.Tag.array_end,    tape.entries[5].tag);
}

test "auto-close: number at EOF inside container" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "[42");
    try std.testing.expectEqual(@as(usize, 3), tape.entries.len);
    try std.testing.expectEqual(@as(i64, 42), tape.entries[1].payload.int);
    try std.testing.expectEqual(types.Tape.Tag.array_end, tape.entries[2].tag);
}

// ── Error cases ───────────────────────────────────────────────────────────────

test "error: unterminated string" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "\"abc", error.UnterminatedString);
}

test "error: unterminated string with escape" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "\"abc\\", error.UnterminatedString);
}

test "error: unexpected eof — empty input" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "", error.UnexpectedEof);
}

test "error: unexpected eof — after colon" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "{\"a\":", error.UnexpectedEof);
}

test "error: unexpected eof — after comma in array" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "[1,", error.UnexpectedEof);
}

test "error: unexpected eof — after comma in object" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "{\"a\":1,", error.UnexpectedEof);
}

test "error: unexpected eof — mid keyword" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "nul", error.UnexpectedEof);
}

test "error: unexpected token — trailing comma in object" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "{\"a\":1,}", error.UnexpectedToken);
}

test "error: unexpected token — trailing comma in array" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "[1,]", error.UnexpectedToken);
}

test "error: unexpected token — number as key" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "{1}", error.UnexpectedToken);
}

test "error: unexpected token — empty array with comma" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "[,]", error.UnexpectedToken);
}

test "error: invalid number — leading zeros" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "01", error.InvalidNumber);
}

test "error: invalid number — double minus" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "--1", error.InvalidNumber);
}

test "error: invalid number — double dot" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "1.2.3", error.InvalidNumber);
}

test "error: invalid number — bare minus at eof" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "-", error.InvalidNumber);
}

test "error: invalid number — exponent without digits" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "1e", error.InvalidNumber);
}

test "error: invalid UTF-8 — stray continuation byte" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "\"\x80\"", error.InvalidUtf8);
}

test "error: invalid UTF-8 — overlong 2-byte" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "\"\xC0\x80\"", error.InvalidUtf8);
}

test "error: unmatched closing bracket" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "]", error.UnexpectedToken);
}

test "error: mismatched brackets" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    try expectError(&p, "[}", error.UnexpectedToken);
}

// ── Depth limit ───────────────────────────────────────────────────────────────

test "depth limit: 512 levels accepted" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const depth = 512;
    var input = try std.testing.allocator.alloc(u8, depth * 2);
    defer std.testing.allocator.free(input);
    for (0..depth) |i| input[i] = '[';
    for (0..depth) |i| input[depth + i] = ']';
    const result = try p.feed(input, true);
    switch (result) {
        .done => {},
        .need_more => return error.UnexpectedNeedMore,
    }
}

test "depth limit: 513 levels rejected" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const depth = 513;
    var input = try std.testing.allocator.alloc(u8, depth);
    defer std.testing.allocator.free(input);
    for (0..depth) |i| input[i] = '[';
    try std.testing.expectError(error.DepthLimitExceeded, p.feed(input, false));
}

// ── getString helper ──────────────────────────────────────────────────────────

test "tape.getString resolves StringRef" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "{\"key\":\"val\"}");
    // entries: [object_start, key("key"), string("val"), object_end]
    try std.testing.expectEqual(@as(usize, 4), tape.entries.len);
    const k = tape.getString(tape.entries[1].payload.string);
    const v = tape.getString(tape.entries[2].payload.string);
    try std.testing.expectEqualStrings("key", k);
    try std.testing.expectEqualStrings("val", v);
}
