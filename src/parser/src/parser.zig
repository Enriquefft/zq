const std = @import("std");
const types = @import("types");
const err_mod = @import("error");
const simd = @import("simd.zig");

pub const ZqError = err_mod.ZqError;
pub const Tape = types.Tape;

/// The outcome of a single `feed()` call.
pub const FeedResult = union(enum) {
    /// A complete top-level JSON value was parsed.
    /// `tape` is non-owning; valid until next `reset()` or `deinit()`.
    /// `consumed` is how many bytes of the input chunk were used (≤ input.len).
    /// Caller must pass the unconsumed remainder back on the next feed() call.
    done: struct { tape: Tape, consumed: usize },
    /// Valid so far but incomplete; call `feed()` again with the next chunk.
    need_more,
};

const DEPTH_LIMIT: u32 = 512;

// ── Internal types ────────────────────────────────────────────────────────────

const ContainerKind = enum(u1) { object, array };

const StackEntry = struct {
    kind: ContainerKind,
    /// Index of the *_start entry in tape_buf for skip-backfill.
    tape_idx: u32,
    /// True if we entered want_value/want_key via a comma (not container-open).
    after_comma: bool,
};

const NumSubState = enum(u8) {
    neg, // saw '-', expect digit
    leading_zero, // saw '0'
    int, // digits in integer part
    frac_start, // saw '.', expect at least one digit
    frac, // digits in fractional part
    exp_sign, // saw 'e'/'E'
    exp_start, // saw 'e[+-]', expect digit
    exp, // digits in exponent
};

const KeywordKind = enum(u4) { kw_true, kw_false, kw_null, kw_infinity, kw_nan, kw_neg_infinity, kw_neg_nan, kw_nan_lower, kw_neg_nan_lower };

const StateTag = enum(u8) {
    want_value,
    want_key,
    want_colon,
    after_value,
    in_string,
    in_string_escape,
    in_string_unicode,
    in_number,
    in_keyword,
    top_done,
};

// Zero-data payload for entries that carry no value (true/false/null/end tags).
const PAYLOAD_NONE = types.Tape.Payload{ .skip = 0 };

// ── Public Parser type ────────────────────────────────────────────────────────

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tape_buf: std.ArrayListUnmanaged(types.Tape.Entry),
    string_buf: std.ArrayListUnmanaged(u8),
    stack: std.ArrayListUnmanaged(StackEntry),

    state: StateTag,

    // ── String-parsing fields ─────────────────────────────────────────────
    /// Byte offset in string_buf where the current string started.
    string_start: u32,
    /// True when parsing an object key (emits .key instead of .string).
    string_is_key: bool,
    /// Number of UTF-8 continuation bytes still expected (0 = not mid-sequence).
    utf8_pending: u3,
    /// Lead byte of the current multi-byte UTF-8 sequence (used for overlong/range checks).
    utf8_first: u8,
    /// Hex digits accumulated for a \uXXXX escape (0..3 seen so far).
    unicode_count: u3,
    /// Accumulated codepoint bits from hex digits.
    unicode_accum: u21,
    /// Non-zero while waiting for the \uLow half of a surrogate pair.
    unicode_surrogate: u16,

    // ── Number-parsing fields ─────────────────────────────────────────────
    num_sub: NumSubState,
    num_buf: std.ArrayListUnmanaged(u8),
    num_is_float: bool,

    // ── Keyword-parsing fields ────────────────────────────────────────────
    kw_kind: KeywordKind,
    /// Next expected position within the keyword string (starts at 1).
    kw_pos: u8,

    // ── Lifecycle ─────────────────────────────────────────────────────────

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Parser {
        var tape_buf = try std.ArrayListUnmanaged(types.Tape.Entry).initCapacity(allocator, 256);
        errdefer tape_buf.deinit(allocator);
        var string_buf = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 1024);
        errdefer string_buf.deinit(allocator);
        var stack = try std.ArrayListUnmanaged(StackEntry).initCapacity(allocator, 64);
        errdefer stack.deinit(allocator);
        var num_buf = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 64);
        errdefer num_buf.deinit(allocator);

        return Parser{
            .allocator = allocator,
            .tape_buf = tape_buf,
            .string_buf = string_buf,
            .stack = stack,
            .state = .want_value,
            .string_start = 0,
            .string_is_key = false,
            .utf8_pending = 0,
            .utf8_first = 0,
            .unicode_count = 0,
            .unicode_accum = 0,
            .unicode_surrogate = 0,
            .num_sub = .int,
            .num_buf = num_buf,
            .num_is_float = false,
            .kw_kind = .kw_null,
            .kw_pos = 0,
        };
    }

    pub fn deinit(p: *Parser) void {
        p.tape_buf.deinit(p.allocator);
        p.string_buf.deinit(p.allocator);
        p.stack.deinit(p.allocator);
        p.num_buf.deinit(p.allocator);
    }

    pub fn reset(p: *Parser) void {
        p.tape_buf.clearRetainingCapacity();
        p.string_buf.clearRetainingCapacity();
        p.stack.clearRetainingCapacity();
        p.state = .want_value;
        p.string_start = 0;
        p.string_is_key = false;
        p.utf8_pending = 0;
        p.utf8_first = 0;
        p.unicode_count = 0;
        p.unicode_accum = 0;
        p.unicode_surrogate = 0;
        p.num_buf.clearRetainingCapacity();
        p.num_is_float = false;
        p.kw_pos = 0;
    }

    pub fn feed(
        p: *Parser,
        input: []const u8,
        is_eof: bool,
    ) (ZqError || error{OutOfMemory})!FeedResult {
        var i: usize = 0;
        // Strip a UTF-8 BOM (U+FEFF → 0xEF 0xBB 0xBF) that appears at the
        // very beginning of a JSON stream.  jq silently discards BOM-prefixed
        // input (jq test L48); we mirror that behaviour.  Only strip once —
        // when the tape is still empty (first feed call for this value).
        if (p.tape_buf.items.len == 0 and p.stack.items.len == 0 and
            p.state == .want_value and
            i + 3 <= input.len and
            input[i] == 0xEF and input[i + 1] == 0xBB and input[i + 2] == 0xBF)
        {
            i += 3;
        }
        while (i < input.len) {
            // ── SIMD fast paths ──────────────────────────────
            switch (p.state) {
                .in_string => {
                    // Only safe when not mid-UTF8 sequence or surrogate pair.
                    if (p.utf8_pending == 0 and p.unicode_surrogate == 0) {
                        const safe = simd.scanStringBody(input[i..]);
                        if (safe > 0) {
                            try p.string_buf.appendSlice(p.allocator, input[i..][0..safe]);
                            i += safe;
                            continue;
                        }
                    }
                },
                .want_value, .want_key, .want_colon, .after_value => {
                    const skip = simd.skipWhitespace(input[i..]);
                    i += skip;
                    if (i >= input.len) break;
                },
                else => {},
            }

            // ── Scalar fallback ──────────────────────────────
            try p.processByte(input[i]);
            i += 1;
            if (p.state == .top_done) {
                return .{ .done = .{ .tape = p.makeTape(), .consumed = i } };
            }
        }
        if (is_eof) return p.processEof();
        return .need_more;
    }

    // ── Byte dispatch ─────────────────────────────────────────────────────

    fn processByte(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        switch (p.state) {
            .want_value => try p.onWantValue(byte),
            .want_key => try p.onWantKey(byte),
            .want_colon => try p.onWantColon(byte),
            .after_value => try p.onAfterValue(byte),
            .in_string => try p.onInString(byte),
            .in_string_escape => try p.onInStringEscape(byte),
            .in_string_unicode => try p.onInStringUnicode(byte),
            .in_number => try p.onInNumber(byte),
            .in_keyword => try p.onInKeyword(byte),
            .top_done => try p.onTopDone(byte),
        }
    }

    // ── State handlers ────────────────────────────────────────────────────

    fn onWantValue(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        switch (byte) {
            ' ', '\t', '\n', '\r' => {},
            '{' => {
                if (p.stack.items.len >= DEPTH_LIMIT) return error.DepthLimitExceeded;
                const tape_idx: u32 = @intCast(p.tape_buf.items.len);
                try p.tape_buf.append(p.allocator, .{
                    .tag = .object_start,
                    .payload = .{ .skip = 0 },
                });
                try p.stack.append(p.allocator, StackEntry{
                    .kind = .object,
                    .tape_idx = tape_idx,
                    .after_comma = false,
                });
                p.state = .want_key;
            },
            '[' => {
                if (p.stack.items.len >= DEPTH_LIMIT) return error.DepthLimitExceeded;
                const tape_idx: u32 = @intCast(p.tape_buf.items.len);
                try p.tape_buf.append(p.allocator, .{
                    .tag = .array_start,
                    .payload = .{ .skip = 0 },
                });
                try p.stack.append(p.allocator, StackEntry{
                    .kind = .array,
                    .tape_idx = tape_idx,
                    .after_comma = false,
                });
                // Stay in want_value for the first array element.
            },
            ']' => {
                // Only valid if this is the initial want_value after '[', not after ','.
                if (p.stack.items.len > 0) {
                    const top = p.stack.items[p.stack.items.len - 1];
                    if (top.kind == .array and !top.after_comma) {
                        try p.closeContainer();
                        return;
                    }
                }
                return error.UnexpectedToken;
            },
            '"' => {
                p.string_start = @intCast(p.string_buf.items.len);
                p.string_is_key = false;
                p.utf8_pending = 0;
                p.unicode_surrogate = 0;
                p.state = .in_string;
            },
            '-' => {
                p.num_buf.clearRetainingCapacity();
                try p.num_buf.append(p.allocator, '-');
                p.num_is_float = false;
                p.num_sub = .neg;
                p.state = .in_number;
            },
            '0' => {
                p.num_buf.clearRetainingCapacity();
                try p.num_buf.append(p.allocator, '0');
                p.num_is_float = false;
                p.num_sub = .leading_zero;
                p.state = .in_number;
            },
            '1'...'9' => {
                p.num_buf.clearRetainingCapacity();
                try p.num_buf.append(p.allocator, byte);
                p.num_is_float = false;
                p.num_sub = .int;
                p.state = .in_number;
            },
            't' => {
                p.kw_kind = .kw_true;
                p.kw_pos = 1;
                p.state = .in_keyword;
            },
            'f' => {
                p.kw_kind = .kw_false;
                p.kw_pos = 1;
                p.state = .in_keyword;
            },
            'n' => {
                p.kw_kind = .kw_null;
                p.kw_pos = 1;
                p.state = .in_keyword;
            },
            'I' => {
                p.kw_kind = .kw_infinity;
                p.kw_pos = 1;
                p.state = .in_keyword;
            },
            'N' => {
                p.kw_kind = .kw_nan;
                p.kw_pos = 1;
                p.state = .in_keyword;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn onWantKey(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        switch (byte) {
            ' ', '\t', '\n', '\r' => {},
            '"' => {
                p.string_start = @intCast(p.string_buf.items.len);
                p.string_is_key = true;
                p.utf8_pending = 0;
                p.unicode_surrogate = 0;
                p.state = .in_string;
            },
            '}' => {
                // Only valid if not after a comma (trailing commas are illegal in JSON).
                if (p.stack.items.len > 0) {
                    const top = p.stack.items[p.stack.items.len - 1];
                    if (top.kind == .object and !top.after_comma) {
                        try p.closeContainer();
                        return;
                    }
                }
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn onWantColon(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        switch (byte) {
            ' ', '\t', '\n', '\r' => {},
            ':' => p.state = .want_value,
            else => return error.UnexpectedToken,
        }
    }

    fn onAfterValue(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        switch (byte) {
            ' ', '\t', '\n', '\r' => {},
            ',' => {
                // Stack is always non-empty in after_value (top_done covers the empty case).
                const top = &p.stack.items[p.stack.items.len - 1];
                top.after_comma = true;
                p.state = if (top.kind == .object) .want_key else .want_value;
            },
            '}' => {
                if (p.stack.items[p.stack.items.len - 1].kind != .object)
                    return error.UnexpectedToken;
                try p.closeContainer();
            },
            ']' => {
                if (p.stack.items[p.stack.items.len - 1].kind != .array)
                    return error.UnexpectedToken;
                try p.closeContainer();
            },
            else => return error.UnexpectedToken,
        }
    }

    fn onInString(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        // Surrogate-pair pending: only '\' is acceptable as next byte.
        if (p.unicode_surrogate != 0) {
            if (byte != '\\') return error.InvalidUtf8;
            p.state = .in_string_escape;
            return;
        }

        // Continuation byte expected for a multi-byte UTF-8 sequence.
        if (p.utf8_pending > 0) {
            if (byte & 0xC0 != 0x80) return error.InvalidUtf8;
            // Validate overlong/range on the first continuation byte.
            switch (p.utf8_pending) {
                2 => { // 3-byte seq: validating second byte
                    if (p.utf8_first == 0xE0 and byte < 0xA0) return error.InvalidUtf8;
                    if (p.utf8_first == 0xED and byte > 0x9F) return error.InvalidUtf8;
                },
                3 => { // 4-byte seq: validating second byte
                    if (p.utf8_first == 0xF0 and byte < 0x90) return error.InvalidUtf8;
                    if (p.utf8_first == 0xF4 and byte > 0x8F) return error.InvalidUtf8;
                },
                else => {},
            }
            try p.string_buf.append(p.allocator, byte);
            p.utf8_pending -= 1;
            return;
        }

        switch (byte) {
            0x00...0x1F => return error.InvalidUtf8, // control chars must be escaped
            '"' => try p.finalizeString(),
            '\\' => p.state = .in_string_escape,
            0x80...0xBF => return error.InvalidUtf8, // stray continuation byte
            0xC0, 0xC1 => return error.InvalidUtf8, // overlong 2-byte prefix
            0xC2...0xDF => {
                p.utf8_first = byte;
                p.utf8_pending = 1;
                try p.string_buf.append(p.allocator, byte);
            },
            0xE0...0xEF => {
                p.utf8_first = byte;
                p.utf8_pending = 2;
                try p.string_buf.append(p.allocator, byte);
            },
            0xF0...0xF4 => {
                p.utf8_first = byte;
                p.utf8_pending = 3;
                try p.string_buf.append(p.allocator, byte);
            },
            0xF5...0xFF => return error.InvalidUtf8,
            else => try p.string_buf.append(p.allocator, byte), // ASCII 0x20-0x7E,0x7F
        }
    }

    fn onInStringEscape(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        // While waiting for a low surrogate, only \uXXXX is acceptable.
        if (p.unicode_surrogate != 0 and byte != 'u') return error.InvalidUtf8;

        switch (byte) {
            '"' => {
                try p.string_buf.append(p.allocator, '"');
                p.state = .in_string;
            },
            '\\' => {
                try p.string_buf.append(p.allocator, '\\');
                p.state = .in_string;
            },
            '/' => {
                try p.string_buf.append(p.allocator, '/');
                p.state = .in_string;
            },
            'b' => {
                try p.string_buf.append(p.allocator, 0x08);
                p.state = .in_string;
            },
            'f' => {
                try p.string_buf.append(p.allocator, 0x0C);
                p.state = .in_string;
            },
            'n' => {
                try p.string_buf.append(p.allocator, '\n');
                p.state = .in_string;
            },
            'r' => {
                try p.string_buf.append(p.allocator, '\r');
                p.state = .in_string;
            },
            't' => {
                try p.string_buf.append(p.allocator, '\t');
                p.state = .in_string;
            },
            'u' => {
                p.unicode_count = 0;
                p.unicode_accum = 0;
                p.state = .in_string_unicode;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn onInStringUnicode(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        const nibble: u21 = switch (byte) {
            '0'...'9' => @as(u21, byte - '0'),
            'a'...'f' => @as(u21, byte - 'a' + 10),
            'A'...'F' => @as(u21, byte - 'A' + 10),
            else => return error.InvalidUtf8,
        };
        p.unicode_accum = (p.unicode_accum << 4) | nibble;
        p.unicode_count += 1;
        if (p.unicode_count < 4) return;

        // All four hex digits received.
        const cp16 = p.unicode_accum;
        p.unicode_accum = 0;
        p.unicode_count = 0;

        if (cp16 >= 0xD800 and cp16 <= 0xDBFF) {
            // High surrogate: store and wait for \uLow.
            p.unicode_surrogate = @intCast(cp16);
            p.state = .in_string;
        } else if (cp16 >= 0xDC00 and cp16 <= 0xDFFF) {
            // Low surrogate: must follow a high surrogate.
            if (p.unicode_surrogate == 0) return error.InvalidUtf8;
            const hi: u21 = @as(u21, p.unicode_surrogate) - 0xD800;
            const lo: u21 = cp16 - 0xDC00;
            const codepoint: u21 = 0x10000 + (hi << 10) | lo;
            p.unicode_surrogate = 0;
            try p.encodeUtf8(codepoint);
            p.state = .in_string;
        } else {
            if (p.unicode_surrogate != 0) return error.InvalidUtf8; // unpaired high surrogate
            try p.encodeUtf8(cp16);
            p.state = .in_string;
        }
    }

    fn onInNumber(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        switch (p.num_sub) {
            .neg => switch (byte) {
                '0' => {
                    try p.numAppend(byte);
                    p.num_sub = .leading_zero;
                },
                '1'...'9' => {
                    try p.numAppend(byte);
                    p.num_sub = .int;
                },
                'I' => {
                    // -Infinity: abandon number state, switch to keyword.
                    p.num_buf.clearRetainingCapacity();
                    p.kw_kind = .kw_neg_infinity;
                    p.kw_pos = 1;
                    p.state = .in_keyword;
                },
                'N' => {
                    // -NaN: abandon number state, switch to keyword.
                    p.num_buf.clearRetainingCapacity();
                    p.kw_kind = .kw_neg_nan;
                    p.kw_pos = 1;
                    p.state = .in_keyword;
                },
                'n' => {
                    // -nan (lowercase): abandon number state, switch to keyword.
                    p.num_buf.clearRetainingCapacity();
                    p.kw_kind = .kw_neg_nan_lower;
                    p.kw_pos = 1;
                    p.state = .in_keyword;
                },
                else => return error.InvalidNumber,
            },
            .leading_zero => switch (byte) {
                '.' => {
                    try p.numAppend(byte);
                    p.num_is_float = true;
                    p.num_sub = .frac_start;
                },
                'e', 'E' => {
                    try p.numAppend(byte);
                    p.num_is_float = true;
                    p.num_sub = .exp_sign;
                },
                '0'...'9' => return error.InvalidNumber, // leading zeros forbidden
                else => try p.terminateNumber(byte),
            },
            .int => switch (byte) {
                '0'...'9' => try p.numAppend(byte),
                '.' => {
                    try p.numAppend(byte);
                    p.num_is_float = true;
                    p.num_sub = .frac_start;
                },
                'e', 'E' => {
                    try p.numAppend(byte);
                    p.num_is_float = true;
                    p.num_sub = .exp_sign;
                },
                else => try p.terminateNumber(byte),
            },
            .frac_start => switch (byte) {
                '0'...'9' => {
                    try p.numAppend(byte);
                    p.num_sub = .frac;
                },
                else => return error.InvalidNumber,
            },
            .frac => switch (byte) {
                '0'...'9' => try p.numAppend(byte),
                'e', 'E' => {
                    try p.numAppend(byte);
                    p.num_sub = .exp_sign;
                },
                '.' => return error.InvalidNumber, // second decimal point: 1.2.3
                else => try p.terminateNumber(byte),
            },
            .exp_sign => switch (byte) {
                '+', '-' => {
                    try p.numAppend(byte);
                    p.num_sub = .exp_start;
                },
                '0'...'9' => {
                    try p.numAppend(byte);
                    p.num_sub = .exp;
                },
                else => return error.InvalidNumber,
            },
            .exp_start => switch (byte) {
                '0'...'9' => {
                    try p.numAppend(byte);
                    p.num_sub = .exp;
                },
                else => return error.InvalidNumber,
            },
            .exp => switch (byte) {
                '0'...'9' => try p.numAppend(byte),
                else => try p.terminateNumber(byte),
            },
        }
    }

    fn onInKeyword(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        // Special disambiguation: 'n' in onWantValue starts kw_null.
        // If the second byte is 'a' instead of 'u', switch to kw_nan_lower.
        // jq accepts lowercase "nan" as a NaN literal.
        if (p.kw_kind == .kw_null and p.kw_pos == 1) {
            if (byte == 'a') {
                // 'n' + 'a' → NaN branch (lowercase "nan").
                p.kw_kind = .kw_nan_lower;
                p.kw_pos = 2; // consumed 'n' (pos 0) and 'a' (pos 1), need 'n' (pos 2)
                return;
            }
        }
        const kw = keywordBytes(p.kw_kind);
        if (p.kw_pos >= kw.len or byte != kw[p.kw_pos]) return error.UnexpectedToken;
        p.kw_pos += 1;

        if (p.kw_pos == kw.len) {
            switch (p.kw_kind) {
                .kw_true => try p.tape_buf.append(p.allocator, .{ .tag = .true_val, .payload = PAYLOAD_NONE }),
                .kw_false => try p.tape_buf.append(p.allocator, .{ .tag = .false_val, .payload = PAYLOAD_NONE }),
                .kw_null => try p.tape_buf.append(p.allocator, .{ .tag = .null_val, .payload = PAYLOAD_NONE }),
                .kw_infinity => try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = std.math.inf(f64) } }),
                .kw_nan => try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = std.math.nan(f64) } }),
                .kw_neg_infinity => try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = -std.math.inf(f64) } }),
                .kw_neg_nan => try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = -std.math.nan(f64) } }),
                .kw_nan_lower => try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = std.math.nan(f64) } }),
                .kw_neg_nan_lower => try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = -std.math.nan(f64) } }),
            }
            p.transitionAfterValue();
        }
    }

    fn onTopDone(p: *Parser, byte: u8) ZqError!void {
        _ = p;
        return switch (byte) {
            ' ', '\t', '\n', '\r' => {},
            else => error.UnexpectedToken,
        };
    }

    // ── EOF handling ──────────────────────────────────────────────────────

    fn processEof(p: *Parser) (ZqError || error{OutOfMemory})!FeedResult {
        switch (p.state) {
            .in_string, .in_string_escape, .in_string_unicode => return error.UnterminatedString,

            .want_colon => return error.UnexpectedEof,

            .want_value => {
                // Top-level with no value started: trailing whitespace after
                // the last record.  Not an error — signal no value produced.
                if (p.stack.items.len == 0) return .need_more;
                const top = p.stack.items[p.stack.items.len - 1];
                // After ':' in an object — value is mandatory.
                if (top.kind == .object) return error.UnexpectedEof;
                // After ',' in an array — value is mandatory.
                if (top.after_comma) return error.UnexpectedEof;
                // Otherwise: empty array (just saw '['), safe to auto-close.
                try p.autoClose();
            },

            .want_key => {
                const top = p.stack.items[p.stack.items.len - 1];
                if (top.after_comma) return error.UnexpectedEof;
                try p.autoClose();
            },

            .after_value => try p.autoClose(),

            .in_number => {
                switch (p.num_sub) {
                    .neg, .frac_start, .exp_sign, .exp_start => return error.InvalidNumber,
                    else => {},
                }
                try p.finalizeNumber();
                if (p.state == .after_value) try p.autoClose();
                // else state is top_done: already done.
            },

            .in_keyword => return error.UnexpectedEof,

            .top_done => {},
        }
        return FeedResult{ .done = .{ .tape = p.makeTape(), .consumed = 0 } };
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    fn numAppend(p: *Parser, byte: u8) error{OutOfMemory}!void {
        try p.num_buf.append(p.allocator, byte);
    }

    /// Finalize number on seeing a non-number byte; re-dispatch the byte.
    fn terminateNumber(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        switch (p.num_sub) {
            .neg, .frac_start, .exp_sign, .exp_start => return error.InvalidNumber,
            else => {},
        }
        try p.finalizeNumber();
        try p.processByte(byte);
    }

    fn finalizeNumber(p: *Parser) (ZqError || error{OutOfMemory})!void {
        const num_str = p.num_buf.items;
        if (p.num_is_float) {
            const val = std.fmt.parseFloat(f64, num_str) catch return error.InvalidNumber;
            try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = val } });
        } else {
            // jq uses float64 for all numbers. Integers that cannot be
            // exactly represented in float64 (|n| > 2^53) — including
            // those that exceed i64 entirely (e.g.
            // `123456789012345678901234567890`) — are stored as float
            // to match jq precision semantics. Integer literals that
            // overflow i64 round-trip through `parseFloat`, so the
            // parser stays parity-safe with jq's "all numbers are
            // doubles" model rather than rejecting the input.
            if (std.fmt.parseInt(i64, num_str, 10)) |val| {
                const max_exact: i64 = 1 << 53; // 9007199254740992
                if (val > max_exact or val < -max_exact) {
                    const fval: f64 = @floatFromInt(val);
                    try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = fval } });
                } else {
                    try p.tape_buf.append(p.allocator, .{ .tag = .int, .payload = .{ .int = val } });
                }
            } else |_| {
                const fval = std.fmt.parseFloat(f64, num_str) catch return error.InvalidNumber;
                try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = fval } });
            }
        }
        p.transitionAfterValue();
    }

    fn finalizeString(p: *Parser) (ZqError || error{OutOfMemory})!void {
        if (p.utf8_pending > 0 or p.unicode_surrogate != 0) return error.InvalidUtf8;
        const str_len: u32 = @intCast(p.string_buf.items.len - p.string_start);
        const ref = types.Tape.StringRef{ .offset = p.string_start, .len = str_len };
        const tag: types.Tape.Tag = if (p.string_is_key) .key else .string;
        try p.tape_buf.append(p.allocator, .{ .tag = tag, .payload = .{ .string = ref } });
        if (p.string_is_key) {
            p.state = .want_colon;
        } else {
            p.transitionAfterValue();
        }
    }

    fn encodeUtf8(p: *Parser, codepoint: u21) (ZqError || error{OutOfMemory})!void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidUtf8;
        try p.string_buf.appendSlice(p.allocator, buf[0..len]);
    }

    fn closeContainer(p: *Parser) error{OutOfMemory}!void {
        const entry = p.stack.pop().?;
        const end_idx: u32 = @intCast(p.tape_buf.items.len);
        // skip = index past the end entry (one after it).
        p.tape_buf.items[entry.tape_idx].payload.skip = end_idx + 1;
        const end_tag: types.Tape.Tag = switch (entry.kind) {
            .object => .object_end,
            .array => .array_end,
        };
        try p.tape_buf.append(p.allocator, .{ .tag = end_tag, .payload = PAYLOAD_NONE });
        p.transitionAfterValue();
    }

    /// Close all remaining open containers (Auto-Close on EOF).
    fn autoClose(p: *Parser) error{OutOfMemory}!void {
        while (p.stack.items.len > 0) {
            try p.closeContainer();
        }
    }

    fn transitionAfterValue(p: *Parser) void {
        p.state = if (p.stack.items.len == 0) .top_done else .after_value;
    }

    fn makeTape(p: *const Parser) Tape {
        return Tape{
            .entries = p.tape_buf.items,
            .string_buf = p.string_buf.items,
        };
    }

    fn keywordBytes(kind: KeywordKind) []const u8 {
        return switch (kind) {
            .kw_true => "true",
            .kw_false => "false",
            .kw_null => "null",
            // First byte already consumed by onWantValue or onInNumber .neg case;
            // kw_pos starts at 1, so match from index 1 of the full keyword.
            .kw_infinity, .kw_neg_infinity => "Infinity",
            .kw_nan, .kw_neg_nan => "NaN",
            // kw_nan_lower: 'n' consumed by onWantValue, 'a' consumed by
            // onInKeyword disambiguation; kw_pos=2 so match from index 2 of "nan".
            .kw_nan_lower => "nan",
            // kw_neg_nan_lower: '-' consumed by onWantValue→neg state, 'n' consumed
            // by onInNumber neg branch; kw_pos=1 so match from index 1 of "nan".
            .kw_neg_nan_lower => "nan",
        };
    }
};
