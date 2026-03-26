/// SIMD scanning primitives for the JSON parser.
///
/// Uses Zig's @Vector which the compiler lowers to the best available
/// SIMD for each target (AVX2, SSE2, NEON, or scalar fallback).
/// No platform-specific code needed.
///
/// Note: Both functions bail out on bytes >= 0x80 (UTF-8 multi-byte),
/// so the SIMD fast path is most effective on ASCII-heavy JSON. For
/// non-ASCII-heavy input, the scalar path in parser.zig handles it.
const std = @import("std");

const VEC_LEN = 32;
const Vec = @Vector(VEC_LEN, u8);
const Mask = std.meta.Int(.unsigned, VEC_LEN); // one bit per vector lane

/// Returns the count of leading bytes that are safe ASCII string content.
/// "Safe" means: not `"`, not `\`, not a control char (< 0x20), and not
/// a high byte (>= 0x80, indicating UTF-8 multi-byte).
///
/// The caller can bulk-append these bytes to string_buf without per-byte checks.
pub fn scanStringBody(data: []const u8) usize {
    var i: usize = 0;

    // Vectorized loop — 32 bytes at a time.
    while (i + VEC_LEN <= data.len) {
        const chunk: Vec = data[i..][0..VEC_LEN].*;

        const quotes: Mask = @bitCast(chunk == @as(Vec, @splat(@as(u8, '"'))));
        const backslashes: Mask = @bitCast(chunk == @as(Vec, @splat(@as(u8, '\\'))));
        const control: Mask = @bitCast(chunk < @as(Vec, @splat(@as(u8, 0x20))));
        const high: Mask = @bitCast(chunk >= @as(Vec, @splat(@as(u8, 0x80))));

        const interesting = quotes | backslashes | control | high;
        if (interesting != 0) {
            return i + @ctz(interesting);
        }
        i += VEC_LEN;
    }

    // Scalar tail — at most VEC_LEN - 1 bytes.
    while (i < data.len) {
        const b = data[i];
        if (b == '"' or b == '\\' or b < 0x20 or b >= 0x80) return i;
        i += 1;
    }
    return i;
}

/// Returns the count of leading JSON whitespace bytes (space, tab, newline, CR).
pub fn skipWhitespace(data: []const u8) usize {
    var i: usize = 0;

    // Vectorized loop — 32 bytes at a time.
    while (i + VEC_LEN <= data.len) {
        const chunk: Vec = data[i..][0..VEC_LEN].*;

        const spaces: Mask = @bitCast(chunk == @as(Vec, @splat(@as(u8, ' '))));
        const tabs: Mask = @bitCast(chunk == @as(Vec, @splat(@as(u8, '\t'))));
        const newlines: Mask = @bitCast(chunk == @as(Vec, @splat(@as(u8, '\n'))));
        const returns: Mask = @bitCast(chunk == @as(Vec, @splat(@as(u8, '\r'))));

        const ws = spaces | tabs | newlines | returns;
        const non_ws = ~ws;
        if (non_ws != 0) {
            return i + @ctz(non_ws);
        }
        i += VEC_LEN;
    }

    // Scalar tail — at most VEC_LEN - 1 bytes.
    while (i < data.len) {
        switch (data[i]) {
            ' ', '\t', '\n', '\r' => i += 1,
            else => return i,
        }
    }
    return i;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "scanStringBody: all safe ASCII" {
    const data = "hello world, this is a test!!!!!0123456789abcdef";
    try testing.expectEqual(data.len, scanStringBody(data));
}

test "scanStringBody: quote at start" {
    try testing.expectEqual(@as(usize, 0), scanStringBody("\"hello"));
}

test "scanStringBody: backslash at start" {
    try testing.expectEqual(@as(usize, 0), scanStringBody("\\nhello"));
}

test "scanStringBody: control char at start" {
    try testing.expectEqual(@as(usize, 0), scanStringBody("\x00hello"));
}

test "scanStringBody: high byte at start" {
    try testing.expectEqual(@as(usize, 0), scanStringBody("\x80hello"));
}

test "scanStringBody: quote mid-vector" {
    // 10 safe bytes then a quote
    try testing.expectEqual(@as(usize, 10), scanStringBody("0123456789\"rest"));
}

test "scanStringBody: quote at vector boundary" {
    // Exactly 32 safe bytes, then a quote
    const data = "01234567890123456789012345678901\"";
    try testing.expectEqual(@as(usize, 32), scanStringBody(data));
}

test "scanStringBody: safe across multiple vectors" {
    // 65 safe bytes (2 full vectors + 1 scalar)
    const data = "A" ** 65;
    try testing.expectEqual(@as(usize, 65), scanStringBody(data));
}

test "scanStringBody: empty input" {
    try testing.expectEqual(@as(usize, 0), scanStringBody(""));
}

test "scanStringBody: exactly 32 safe bytes" {
    const data = "A" ** 32;
    try testing.expectEqual(@as(usize, 32), scanStringBody(data));
}

test "scanStringBody: 31 safe then escape" {
    const data = "A" ** 31 ++ "\\";
    try testing.expectEqual(@as(usize, 31), scanStringBody(data));
}

test "skipWhitespace: all spaces" {
    const data = " " ** 40;
    try testing.expectEqual(@as(usize, 40), skipWhitespace(data));
}

test "skipWhitespace: mixed whitespace" {
    try testing.expectEqual(@as(usize, 4), skipWhitespace(" \t\n\r{"));
}

test "skipWhitespace: no whitespace" {
    try testing.expectEqual(@as(usize, 0), skipWhitespace("hello"));
}

test "skipWhitespace: empty input" {
    try testing.expectEqual(@as(usize, 0), skipWhitespace(""));
}

test "skipWhitespace: large run then non-ws" {
    // 64 spaces + 1 non-ws (2 full vectors + scalar)
    const data = " " ** 64 ++ "{";
    try testing.expectEqual(@as(usize, 64), skipWhitespace(data));
}

test "skipWhitespace: exactly 32 spaces" {
    const data = " " ** 32;
    try testing.expectEqual(@as(usize, 32), skipWhitespace(data));
}
