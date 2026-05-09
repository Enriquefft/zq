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
        .done => |d| return d.tape,
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
    try std.testing.expectEqual(types.Tape.Tag.object_end, tape.entries[1].tag);
    // skip must point past object_end
    try std.testing.expectEqual(@as(u32, 2), tape.entries[0].payload.skip);
}

test "empty array" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const tape = try parseAll(&p, "[]");
    try std.testing.expectEqual(@as(usize, 2), tape.entries.len);
    try std.testing.expectEqual(types.Tape.Tag.array_start, tape.entries[0].tag);
    try std.testing.expectEqual(types.Tape.Tag.array_end, tape.entries[1].tag);
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
    try std.testing.expectEqual(types.Tape.Tag.key, tape.entries[1].tag);
    try std.testing.expectEqualStrings("a", tape.getString(tape.entries[1].payload.string));
    try std.testing.expectEqual(types.Tape.Tag.int, tape.entries[2].tag);
    try std.testing.expectEqual(@as(i64, 1), tape.entries[2].payload.int);
    try std.testing.expectEqual(types.Tape.Tag.object_end, tape.entries[3].tag);
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
    try std.testing.expectEqual(types.Tape.Tag.object_end, tape.entries[2].tag);
    try std.testing.expectEqual(types.Tape.Tag.array_end, tape.entries[3].tag);
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
        .done => |d| {
            const tape = d.tape;
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
        .done => |d| try std.testing.expectEqual(@as(i64, 1234), d.tape.entries[0].payload.int),
        .need_more => return error.UnexpectedNeedMore,
    }
}

test "streaming: string split across chunks" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    _ = try p.feed("\"hel", false);
    const r = try p.feed("lo\"", true);
    switch (r) {
        .done => |d| {
            const tape = d.tape;
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
    try std.testing.expectEqual(types.Tape.Tag.object_end, tape.entries[3].tag);
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
    try std.testing.expectEqual(types.Tape.Tag.array_start, tape.entries[0].tag);
    try std.testing.expectEqual(types.Tape.Tag.object_start, tape.entries[1].tag);
    try std.testing.expectEqual(types.Tape.Tag.object_end, tape.entries[4].tag);
    try std.testing.expectEqual(types.Tape.Tag.array_end, tape.entries[5].tag);
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

test "empty input at EOF returns need_more (streaming compatibility)" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const result = try p.feed("", true);
    try std.testing.expectEqual(FeedResult.need_more, result);
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

// ── SIMD fast-path edge cases ────────────────────────────────────────────────

test "simd: long ASCII string (> 32 bytes)" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const inner = "abcdefghijklmnopqrstuvwxyz0123456789ABCDE";
    const tape = try parseAll(&p, "\"" ++ inner ++ "\"");
    const s = tape.getString(tape.entries[0].payload.string);
    try std.testing.expectEqualStrings(inner, s);
}

test "simd: string exactly 32 bytes" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const inner = "A" ** 32;
    const tape = try parseAll(&p, "\"" ++ inner ++ "\"");
    const s = tape.getString(tape.entries[0].payload.string);
    try std.testing.expectEqualStrings(inner, s);
}

test "simd: string exactly 33 bytes" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const inner = "A" ** 33;
    const tape = try parseAll(&p, "\"" ++ inner ++ "\"");
    const s = tape.getString(tape.entries[0].payload.string);
    try std.testing.expectEqualStrings(inner, s);
}

test "simd: escape at vector boundary (byte 31)" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    // 31 safe bytes, then \n escape
    const inner = "A" ** 31 ++ "\\n" ++ "B" ** 10;
    const tape = try parseAll(&p, "\"" ++ inner ++ "\"");
    const s = tape.getString(tape.entries[0].payload.string);
    try std.testing.expectEqualStrings("A" ** 31 ++ "\n" ++ "B" ** 10, s);
}

test "simd: UTF-8 multibyte at vector boundary" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    // 31 ASCII bytes, then a 2-byte UTF-8 char (é = C3 A9)
    const inner = "A" ** 31 ++ "\xC3\xA9";
    const tape = try parseAll(&p, "\"" ++ inner ++ "\"");
    const s = tape.getString(tape.entries[0].payload.string);
    try std.testing.expectEqualStrings(inner, s);
}

test "simd: large whitespace run before value" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    // 70 spaces then a value
    const input = " " ** 70 ++ "42";
    const tape = try parseAll(&p, input);
    try std.testing.expectEqual(types.Tape.Tag.int, tape.entries[0].tag);
    try std.testing.expectEqual(@as(i64, 42), tape.entries[0].payload.int);
}

test "simd: mixed whitespace types" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const input = " \t\n\r \t\n\r \t\n\r \t\n\r \t\n\r \t\n\r \t\n\r \t\n\r true";
    const tape = try parseAll(&p, input);
    try std.testing.expectEqual(types.Tape.Tag.true_val, tape.entries[0].tag);
}

test "simd: whitespace in object with long keys and values" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const input = "  {  \"" ++ "k" ** 40 ++ "\"  :  \"" ++ "v" ** 40 ++ "\"  }  ";
    const tape = try parseAll(&p, input);
    try std.testing.expectEqual(@as(usize, 4), tape.entries.len);
    const k = tape.getString(tape.entries[1].payload.string);
    const v = tape.getString(tape.entries[2].payload.string);
    try std.testing.expectEqualStrings("k" ** 40, k);
    try std.testing.expectEqualStrings("v" ** 40, v);
}

test "simd: repeated parse/reset with long strings" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();

    for (0..10) |round| {
        _ = round;
        const tape = try parseAll(&p, "\"" ++ "x" ** 100 ++ "\"");
        const s = tape.getString(tape.entries[0].payload.string);
        try std.testing.expectEqualStrings("x" ** 100, s);
        p.reset();
    }
}

test "simd: all-whitespace input returns need_more" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    const result = try p.feed(" " ** 64, true);
    try std.testing.expectEqual(FeedResult.need_more, result);
}

test "simd: cross-chunk string scanning" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    // Start a string in chunk 1, finish in chunk 2.
    // 34 safe ASCII bytes split across two feed() calls.
    const r1 = try p.feed("\"" ++ "A" ** 34, false);
    try std.testing.expectEqual(FeedResult.need_more, r1);
    const r2 = try p.feed("B" ** 34 ++ "\"", true);
    switch (r2) {
        .done => |d| {
            const s = d.tape.getString(d.tape.entries[0].payload.string);
            try std.testing.expectEqualStrings("A" ** 34 ++ "B" ** 34, s);
        },
        .need_more => return error.UnexpectedNeedMore,
    }
}

test "simd: surrogate guard prevents scanning during surrogate pair" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    // \uD83D\uDC08 = U+1F408 (cat emoji). The surrogate guard must prevent
    // SIMD scanning between the high and low surrogate escapes.
    const tape = try parseAll(&p, "\"\\uD83D\\uDC08\"");
    const s = tape.getString(tape.entries[0].payload.string);
    try std.testing.expectEqualStrings("\xF0\x9F\x90\x88", s);
}

test "simd: string of only escape sequences" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    // Every byte is a backslash or escape char — SIMD returns 0 each time.
    const tape = try parseAll(&p, "\"\\\\\\n\\t\\r\"");
    const s = tape.getString(tape.entries[0].payload.string);
    try std.testing.expectEqualStrings("\\\n\t\r", s);
}

test "simd: UTF-8 continuation bytes across feed chunks" {
    var p = try Parser.init(std.testing.allocator);
    defer p.deinit();
    // 3-byte UTF-8 char (€ = E2 82 AC) split: lead byte in chunk 1, continuations in chunk 2.
    // The utf8_pending guard must prevent SIMD scanning on the continuation bytes.
    const r1 = try p.feed("\"abc\xE2", false);
    try std.testing.expectEqual(FeedResult.need_more, r1);
    const r2 = try p.feed("\x82\xAC\"", true);
    switch (r2) {
        .done => |d| {
            const s = d.tape.getString(d.tape.entries[0].payload.string);
            try std.testing.expectEqualStrings("abc\xE2\x82\xAC", s);
        },
        .need_more => return error.UnexpectedNeedMore,
    }
}

// ── Alignment detector ───────────────────────────────────────────────────────

const findValueStart = parser.findValueStart;
const tryAlignChunk = parser.tryAlignChunk;
const AlignResult = parser.AlignResult;

test "findValueStart: empty input returns null" {
    try std.testing.expectEqual(@as(?usize, null), findValueStart("", 0));
}

test "findValueStart: from past end returns null" {
    try std.testing.expectEqual(@as(?usize, null), findValueStart("xy", 5));
}

test "findValueStart: skips leading whitespace" {
    try std.testing.expectEqual(@as(?usize, 3), findValueStart("   {}", 0));
}

test "findValueStart: from middle skips whitespace" {
    try std.testing.expectEqual(@as(?usize, 5), findValueStart("{}\n  1", 2));
}

test "findValueStart: all whitespace returns null" {
    try std.testing.expectEqual(@as(?usize, null), findValueStart("   \n\t  ", 0));
}

test "tryAlignChunk: aligned-at-zero" {
    const r = tryAlignChunk("{\"a\":1}", 0, "");
    try std.testing.expectEqual(AlignResult{ .aligned_at = 0 }, r);
}

test "tryAlignChunk: mid-record-rescue picks newline-confirmed boundary" {
    // Layout (offsets):
    //  0..6 : {"a":1}        7:\n
    //  8..14: {"b":2}       15:\n
    // 16..22: {"c":3}
    // hint_start = 11 (mid {"b":2}). The only confirmable boundary lives at
    // offset 15 (end of {"b":2}), but that's > hint_start. Walk back: no
    // earlier \n. Empty lookback → in_progress (chunk owner is the prior).
    const data = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}";
    const r = tryAlignChunk(data, 11, "");
    try std.testing.expectEqual(AlignResult.in_progress, r);
}

test "tryAlignChunk: rescue picks next-value start when value ends before hint" {
    // hint_start = 16 (start of {"c":3}). The \n at 15 has value_start=16
    // == hint_start, so the value_start-equals-hint_start branch fires and
    // we return aligned_at(16).
    const data = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}";
    const r = tryAlignChunk(data, 16, "");
    try std.testing.expectEqual(AlignResult{ .aligned_at = 16 }, r);
}

test "tryAlignChunk: rescue past in-string newline" {
    // Raw \n inside a JSON string is invalid per RFC 8259 — the parser
    // rejects any fragment fed across it, so the in-string \n at 11 cannot
    // be used as a boundary candidate.
    //  0..18: {"s":"line1\nline2"}    19:\n    20..26: {"x":1}
    const data = "{\"s\":\"line1\nline2\"}\n{\"x\":1}";
    // hint_start=22. Walk-back: \n=19 → confirmed end_abs=27 > 22 and
    // value_start (20) != 22 → reject. \n=11 → probe rejects (parser sees
    // raw \n → InvalidUtf8). No earlier \n. → in_progress.
    const r = tryAlignChunk(data, 22, "");
    try std.testing.expectEqual(AlignResult.in_progress, r);
}

test "tryAlignChunk: in-string newline rescued when chunk anchored on real boundary" {
    // Same shape; hint_start=20 lands exactly on the structural boundary.
    // \n at 19 → value_start=20 == hint_start → aligned_at(20).
    const data = "{\"s\":\"line1\nline2\"}\n{\"x\":1}";
    const r = tryAlignChunk(data, 20, "");
    try std.testing.expectEqual(AlignResult{ .aligned_at = 20 }, r);
}

test "tryAlignChunk: rescue inside multi-line pretty object" {
    // Pretty-printed object spans three lines (offsets 0..21). Trailing
    // \n at 22 closes the record; next record at 23..29.
    //  0:{ 1:\n 2:sp 3:sp 4:" 5:a 6:" 7:: 8:sp 9:1 10:, 11:\n
    // 12:sp 13:sp 14:" 15:b 16:" 17:: 18:sp 19:2 20:\n 21:} 22:\n
    // 23:{ 24:" 25:x 26:" 27:: 28:1 29:}
    const data = "{\n  \"a\": 1,\n  \"b\": 2\n}\n{\"x\":1}";
    // hint_start=28 (mid {"x":1}). Walk-back: every interior \n probe fails
    // because the parser interprets fragments like `  "b"` as a complete
    // top-level string but the trailing-byte sanity check rejects `:`.
    // Final result: in_progress (the record at 23..29 is owned by the prior
    // chunk because hint_start lies inside it).
    const r = tryAlignChunk(data, 28, "");
    try std.testing.expectEqual(AlignResult.in_progress, r);
}

test "tryAlignChunk: rescue inside multi-line pretty object hits trailing terminator" {
    // Same shape; hint_start=23 lands AT the next record's first byte. The
    // \n at 22 has value_start=23 == hint_start → aligned_at(23).
    const data = "{\n  \"a\": 1,\n  \"b\": 2\n}\n{\"x\":1}";
    const r = tryAlignChunk(data, 23, "");
    try std.testing.expectEqual(AlignResult{ .aligned_at = 23 }, r);
}

test "tryAlignChunk: escape pending boundary" {
    // String containing an escaped backslash (`\\`) followed by 'n' — no
    // raw newline in the string, only the structural \n at offset 14.
    //  0:{ 1:" 2:s 3:" 4:: 5:" 6:f 7:o 8:o 9:\ 10:\ 11:n 12:" 13:}
    // 14:\n 15..21: {"x":1}
    const data = "{\"s\":\"foo\\\\n\"}\n{\"x\":1}";
    // hint_start=17 (mid {"x":1}). \n at 14 → value_start=15. confirmed
    // end_abs=22 > 17 and value_start != 17 → reject. No earlier \n. →
    // in_progress (chunk owner is the prior chunk).
    const r = tryAlignChunk(data, 17, "");
    try std.testing.expectEqual(AlignResult.in_progress, r);
}

test "tryAlignChunk: in_progress when no newline and empty lookback" {
    // No \n in data[0..hint_start], no lookback → in_progress.
    const data = "{\"abcdefghijk\":1}";
    const r = tryAlignChunk(data, 8, "");
    try std.testing.expectEqual(AlignResult.in_progress, r);
}

test "tryAlignChunk: empty whitespace-only input" {
    const r = tryAlignChunk("   \n\t ", 3, "");
    try std.testing.expectEqual(AlignResult.empty, r);
}

test "tryAlignChunk: lookback supplies missing newline path" {
    // data has no \n in [0..hint_start]; lookback ends with a record
    // boundary. Algorithm falls back to lookback path.
    const lookback = "{\"a\":1}\n";
    const data = "{\"b\":2}\n{\"c\":3}";
    const r = tryAlignChunk(data, 5, lookback);
    // Lookback ends at the `\n` terminating the prior record, so data[0]
    // is a fresh value boundary. hint_start=5 lands inside the first
    // record `{"b":2}` (offsets 0..6) but no other worker is parsing it
    // (the prior chunk ended at the lookback `\n`). The current chunk
    // therefore owns the record from offset 0. → aligned_at(0).
    try std.testing.expectEqual(AlignResult{ .aligned_at = 0 }, r);
}

test "tryAlignChunk: hint_start=0 with lookback confirms boundary at data[0]" {
    // Worker contract from commit 3: every chunk past the first calls
    // tryAlignChunk(data, 0, lookback). Lookback ends with `}\n` — the
    // prior record's terminator. data starts a fresh top-level value, so
    // the function must consult the parser via lookback and confirm
    // data[0] as a fresh boundary.
    const lookback = "{\"a\":1}\n";
    const data = "{\"b\":2}";
    const r = tryAlignChunk(data, 0, lookback);
    try std.testing.expectEqual(AlignResult{ .aligned_at = 0 }, r);
}

test "tryAlignChunk: hint_start=0 with lookback rejects when data[0] is mid-value" {
    // Lookback is the start of a pretty-printed object (`{` then `\n`
    // and indent), with NO real record terminator. data continues that
    // object's value, closes it, then `\n` introduces a new record.
    //
    // Walk-back from the only `\n` (lookback offset 1): probe feeds
    // `lookback[2..]` = `  ` (whitespace) → need_more, then feeds data
    // (`1\n}\n{"x":2}`) → parser parses `1` and stops at top_done with
    // consumed=1. trailingLooksTopLevel(data, 1) skips whitespace and
    // finds `}` — a structural mid-record byte — so the probe rejects.
    // No earlier `\n` in lookback. → in_progress.
    const lookback = "{\n  ";
    const data = "1\n}\n{\"x\":2}";
    const r = tryAlignChunk(data, 0, lookback);
    try std.testing.expectEqual(AlignResult.in_progress, r);
}

test "tryAlignChunk: hint_start=0 with lookback containing in-string \\n" {
    // Lookback ends with a literal raw \n inside an unterminated string
    // (invalid per RFC 8259). The probe feeds data fresh (lb_start ==
    // lookback.len), data starts with `l` which is not a valid top-level
    // value-start byte → parser errors → probe rejects this `\n`. No
    // earlier `\n` exists in lookback. → in_progress.
    const lookback = "{\"s\":\"line1\n";
    const data = "line2\"}\n{\"x\":1}";
    const r = tryAlignChunk(data, 0, lookback);
    try std.testing.expectEqual(AlignResult.in_progress, r);
}

test "tryAlignChunk: lookback parses key string but trailing : rejects boundary" {
    // Lookback is the start of a pretty-printed object (`{\n`) followed by
    // two-space indent and a key `"a":`. The only `\n` is at lookback offset
    // 1 → lb_start=2. Feeding `lookback[2..]` = `  "a":` to a fresh parser
    // skips whitespace, parses `"a"` as a top-level string, returns
    // `.done{consumed=5}`. The byte at `lookback[2+5..]` is `:` — a
    // structural mid-record connector. Without the trailing-byte check the
    // probe would falsely confirm; the new check rejects. No earlier `\n`.
    // → in_progress.
    const lookback = "{\n  \"a\":";
    const data = " 1\n}\n{\"x\":2}";
    const r = tryAlignChunk(data, 0, lookback);
    try std.testing.expectEqual(AlignResult.in_progress, r);
}

test "tryAlignChunk: lookback parses array element but trailing , rejects boundary" {
    // Array open then first element `1,` then `\n` then second element `42 `
    // (trailing space terminates the number for the parser). The only `\n`
    // sits at lookback offset 3 → lb_start=4. Feeding `lookback[4..]` = `42 `
    // returns `.done{consumed=3}` — the parser saw `42` followed by a
    // top-level whitespace-only tail. The new check then walks the empty
    // lookback tail (lookback[7..] = "") into data, finds `,` first, and
    // rejects. No earlier `\n`. → in_progress.
    const lookback = "[1,\n42 ";
    const data = ", 43]\n{\"x\":2}";
    const r = tryAlignChunk(data, 0, lookback);
    try std.testing.expectEqual(AlignResult.in_progress, r);
}

test "tryAlignChunk: lookback value with trailing whitespace stays aligned" {
    // Lookback = `\n{"a":1}   ` (record sep, complete value, trailing space).
    // `\n` at lookback offset 0 → lb_start=1. Feed `{"a":1}   ` → parser
    // hits top_done at the closing `}`, returns `.done{consumed=7}`. New
    // check walks `lookback[8..]` = `   ` (whitespace), then continues into
    // data = `{"b":2}` and finds `{` — a top-level value start. Acceptance
    // path. → confirmed_in_lookback → aligned_at(0).
    const lookback = "\n{\"a\":1}   ";
    const data = "{\"b\":2}";
    const r = tryAlignChunk(data, 0, lookback);
    try std.testing.expectEqual(AlignResult{ .aligned_at = 0 }, r);
}
