//! Byte → character offset conversion for jq-compat `match` / `capture` /
//! `scan` results.
//!
//! jq defines `offset` on a match object as the **character count** (Unicode
//! scalars) from the start of the input to the match start — NOT a byte offset
//! and not a UTF-16 unit. `regex-automata` returns byte offsets. This module
//! does the conversion via a UTF-8 prefix scan.
//!
//! # Char counting
//!
//! "Character" in jq means a Unicode code point (scalar). For valid UTF-8,
//! each code point begins with a byte that is NOT a continuation byte
//! (`(b & 0xC0) != 0x80`). We count those bytes in the prefix `[0, byte)`.
//! Invalid UTF-8 is a programmer error (regex matches are always on well-
//! formed input or behavior is undefined) but we handle it gracefully by
//! still counting leading bytes — never panic.
//!
//! # Caching for scan
//!
//! `scan` yields N matches on the same haystack with monotonically-increasing
//! byte offsets. Recomputing the char count from 0 each time is O(N²) in
//! total cost. `OffsetCursor` memoizes `(last_byte, last_char)` and advances
//! forward — O(input length) amortized across all match offsets in one scan.

const std = @import("std");

/// True if byte `b` is a UTF-8 continuation byte (10xxxxxx).
inline fn isContinuationByte(b: u8) bool {
    return (b & 0xC0) == 0x80;
}

/// Count characters (Unicode scalars) in `hay[0..byte_offset]` from scratch.
/// `byte_offset` is clamped to `hay.len`.
pub fn byteToChar(hay: []const u8, byte_offset: usize) usize {
    const end = @min(byte_offset, hay.len);
    var chars: usize = 0;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (!isContinuationByte(hay[i])) chars += 1;
    }
    return chars;
}

/// Forward-only byte→char cursor. Amortizes prefix scan across repeated
/// lookups on the same haystack (scan, iterNext). A caller that needs to go
/// backward should `reset` first.
pub const OffsetCursor = struct {
    hay: []const u8,
    /// Last byte offset asked about. `char` is `byteToChar(hay, byte)`.
    byte: usize = 0,
    char: usize = 0,

    pub fn init(hay: []const u8) OffsetCursor {
        return .{ .hay = hay };
    }

    pub fn reset(self: *OffsetCursor) void {
        self.byte = 0;
        self.char = 0;
    }

    /// Translate `byte_offset` to its character count. Efficient when called
    /// with monotonically non-decreasing offsets; falls back to full rescan
    /// if the caller goes backward.
    pub fn charAt(self: *OffsetCursor, byte_offset: usize) usize {
        const target = @min(byte_offset, self.hay.len);
        if (target < self.byte) {
            // Caller moved backward — rescan from zero. Not expected in scan
            // but correctness matters more than optimality.
            self.byte = 0;
            self.char = 0;
        }
        var i = self.byte;
        var c = self.char;
        while (i < target) : (i += 1) {
            if (!isContinuationByte(self.hay[i])) c += 1;
        }
        self.byte = target;
        self.char = c;
        return c;
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "byteToChar: ASCII" {
    try std.testing.expectEqual(@as(usize, 0), byteToChar("hello", 0));
    try std.testing.expectEqual(@as(usize, 3), byteToChar("hello", 3));
    try std.testing.expectEqual(@as(usize, 5), byteToChar("hello", 5));
    // clamp to len
    try std.testing.expectEqual(@as(usize, 5), byteToChar("hello", 99));
}

test "byteToChar: multi-byte UTF-8" {
    // "café" = c, a, f, é(2 bytes: 0xC3 0xA9) → 4 chars, 5 bytes.
    // We count lead (non-continuation) bytes in the prefix, so at any byte
    // offset on a valid char boundary the result equals the char count.
    const s = "café";
    try std.testing.expectEqual(@as(usize, 5), s.len);
    try std.testing.expectEqual(@as(usize, 0), byteToChar(s, 0));
    try std.testing.expectEqual(@as(usize, 3), byteToChar(s, 3));
    // At offset 5 (end of "é") — 4 complete chars.
    try std.testing.expectEqual(@as(usize, 4), byteToChar(s, 5));
}

test "byteToChar: 4-byte codepoints (emoji)" {
    // "🙂" = 0xF0 0x9F 0x99 0x82 → 1 char, 4 bytes.
    const s = "a🙂b";
    try std.testing.expectEqual(@as(usize, 0), byteToChar(s, 0));
    try std.testing.expectEqual(@as(usize, 1), byteToChar(s, 1));
    // At offset 5 (end of "🙂") — 2 chars.
    try std.testing.expectEqual(@as(usize, 2), byteToChar(s, 5));
    try std.testing.expectEqual(@as(usize, 3), byteToChar(s, 6));
}

test "OffsetCursor: monotonic forward is amortized" {
    const s = "a🙂b🙂c";
    var cur = OffsetCursor.init(s);
    // Bytes: 'a'=0..1, '🙂'=1..5, 'b'=5..6, '🙂'=6..10, 'c'=10..11.
    try std.testing.expectEqual(@as(usize, 0), cur.charAt(0));
    try std.testing.expectEqual(@as(usize, 1), cur.charAt(1));
    try std.testing.expectEqual(@as(usize, 2), cur.charAt(5));
    try std.testing.expectEqual(@as(usize, 3), cur.charAt(6));
    try std.testing.expectEqual(@as(usize, 4), cur.charAt(10));
    try std.testing.expectEqual(@as(usize, 5), cur.charAt(11));
}

test "OffsetCursor: backward rescans correctly" {
    const s = "abc";
    var cur = OffsetCursor.init(s);
    try std.testing.expectEqual(@as(usize, 2), cur.charAt(2));
    try std.testing.expectEqual(@as(usize, 1), cur.charAt(1));
    try std.testing.expectEqual(@as(usize, 3), cur.charAt(3));
}
