//! Property test for `boundary.feedBytes` — the simdjson-stage-1-style
//! SIMD pipeline must produce bit-for-bit identical output to the
//! scalar reference (`boundary.feedBytesReference`).
//!
//! Coverage:
//!   - 1000 randomized inputs (deterministic seed) covering: escapes,
//!     long strings spanning chunk seams, trailing partial values,
//!     pretty-printed values, deep nesting, raw \n inside strings,
//!     structural bytes inside strings.
//!   - 200 randomized inputs split at random offsets and fed across
//!     two `feedBytes` calls (validates carry: in_string,
//!     escape_pending, depth).
//!   - Directed micro-tests targeting chunk-seam edge cases (byte 63 /
//!     127 / 191): backslash carry, quote carry, even/odd backslash
//!     runs, long string spanning 3 chunks, depth-1 newlines that must
//!     NOT emit, depth-0 newline immediately after `}` at byte 63,
//!     empty residual tail, and residual tail with newline at last
//!     byte.

const std = @import("std");
const parser = @import("parser");
const boundary = parser.boundary;

const SEED: u64 = 0x6f626f756e64;
const ITERATIONS: usize = 1000;
const STREAM_ITERATIONS: usize = 200;
const MAX_LEN: usize = 512;

// ── Generator ─────────────────────────────────────────────────────────────────

/// Generate a single byte stream that exercises the SIMD pipeline's
/// edge cases by construction. Mixes:
///   - structural bytes outside strings (`{}[]`, `\n`)
///   - strings containing `\\`, `\"`, raw `\n`, raw `{}[]`
///   - deep nesting
///   - long strings spanning chunk seams (length forced past byte 63 /
///     127 / 191)
///   - `\` at byte 63 / 127 / 191 (escape carry)
///   - quote at byte 63 / 127 / 191 (in-string carry)
fn generateInput(rng: std.Random, alloc: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(alloc);

    const target_len = rng.intRangeLessThan(usize, 1, MAX_LEN);

    // Plant at least one chunk-seam edge case so we don't rely solely
    // on chance.
    const seam_strategy = rng.uintLessThan(u8, 8);
    switch (seam_strategy) {
        0 => {
            // Pad with structural noise to land at byte 63, then a
            // self-contained empty string (valid JSON).
            try padTo(&buf, alloc, rng, 63);
            try buf.appendSlice(alloc, "\"\"\n");
        },
        1 => {
            // Backslash at byte 63 inside a string.
            try buf.append(alloc, '"');
            try padString(&buf, alloc, rng, 62);
            try buf.append(alloc, '\\');
            try buf.append(alloc, 'n');
            try buf.append(alloc, '"');
        },
        2 => {
            // Quote at byte 63 (closes a string).
            try buf.append(alloc, '"');
            try padString(&buf, alloc, rng, 62);
            try buf.append(alloc, '"');
        },
        3 => {
            // Long string spanning bytes 0..200 (covers seams 63, 127, 191).
            try buf.append(alloc, '"');
            try padString(&buf, alloc, rng, 198);
            try buf.append(alloc, '"');
        },
        4 => {
            // Even-length backslash run at chunk seam.
            try buf.append(alloc, '"');
            try padString(&buf, alloc, rng, 60);
            // Bytes 61, 62, 63, 64 are all backslashes — even-length run
            // straddling the seam. Two pairs of `\\` → no escape carry.
            try buf.appendSlice(alloc, "\\\\\\\\");
            try buf.append(alloc, '"');
        },
        5 => {
            // Odd-length backslash run at chunk seam — escape carries.
            try buf.append(alloc, '"');
            try padString(&buf, alloc, rng, 60);
            try buf.appendSlice(alloc, "\\\\\\");
            try buf.append(alloc, 'n');
            try buf.append(alloc, '"');
        },
        6 => {
            // Pretty-printed object spanning a seam.
            try padTo(&buf, alloc, rng, 50);
            try buf.appendSlice(alloc, "{\n  \"k\": \"value-with-padding-to-cross-seam\",\n  \"n\": 1\n}");
        },
        else => {
            // Compact JSONL — many short records.
            var i: u32 = 0;
            while (i < 12) : (i += 1) {
                try buf.writer(alloc).print("{d}\n", .{i});
            }
        },
    }

    // Pad/extend with random structural-mix content to reach target length.
    while (buf.items.len < target_len) {
        try appendRandomFragment(&buf, alloc, rng);
    }

    return buf.toOwnedSlice(alloc);
}

/// Append exactly `n` boring out-of-string bytes (whitespace + ASCII
/// letters) to bring the buffer to a deterministic offset.
fn padTo(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, rng: std.Random, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c: u8 = switch (rng.uintLessThan(u8, 4)) {
            0 => ' ',
            1 => 'a' + @as(u8, @intCast(rng.uintLessThan(u8, 26))),
            2 => '0' + @as(u8, @intCast(rng.uintLessThan(u8, 10))),
            else => '\t',
        };
        try buf.append(alloc, c);
    }
}

/// Append `n` safe in-string bytes (no `\`, no `"`, no control chars).
fn padString(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, rng: std.Random, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // 'A'..'Z' — guaranteed safe in-string ASCII.
        const c: u8 = 'A' + @as(u8, @intCast(rng.uintLessThan(u8, 26)));
        try buf.append(alloc, c);
    }
}

/// Append a small random fragment that exercises one of the pipeline
/// branches.
fn appendRandomFragment(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, rng: std.Random) !void {
    switch (rng.uintLessThan(u8, 12)) {
        0 => try buf.appendSlice(alloc, "\n"),
        1 => try buf.appendSlice(alloc, "{}\n"),
        2 => try buf.appendSlice(alloc, "[1,2,3]\n"),
        3 => try buf.appendSlice(alloc, "\"hello\"\n"),
        4 => try buf.appendSlice(alloc, "\"line1\nline2\"\n"),
        5 => try buf.appendSlice(alloc, "\"a\\\\b\"\n"),
        6 => try buf.appendSlice(alloc, "\"a\\\"b\"\n"),
        7 => try buf.appendSlice(alloc, "\"{[}]\"\n"),
        8 => try buf.appendSlice(alloc, "[[[[1]]]]\n"),
        9 => try buf.appendSlice(alloc, "{\n  \"a\": 1\n}\n"),
        10 => try buf.appendSlice(alloc, "{\"a\":\"b\",\"c\":[1,2,{\"d\":\"e\"}]}\n"),
        else => {
            // Trailing partial value (no \n) — number, not string,
            // because dangling `\` outside any string is malformed and
            // diverges from the SIMD pipeline's Langdale-Lemire
            // classification (which treats every `\` as an escape
            // source).
            try buf.appendSlice(alloc, "42");
        },
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "boundary SIMD: matches scalar reference on 1000 random inputs" {
    var prng = std.Random.DefaultPrng.init(SEED);
    const rng = prng.random();
    const alloc = std.testing.allocator;

    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const data = try generateInput(rng, alloc);
        defer alloc.free(data);

        var s_new = boundary.ScannerState{};
        var s_ref = boundary.ScannerState{};
        var bnds_new: std.ArrayList(usize) = .{};
        defer bnds_new.deinit(alloc);
        var bnds_ref: std.ArrayList(usize) = .{};
        defer bnds_ref.deinit(alloc);

        try boundary.feedBytes(&s_new, data, 0, &bnds_new, alloc);
        try boundary.feedBytesReference(&s_ref, data, 0, &bnds_ref, alloc);

        std.testing.expectEqualSlices(usize, bnds_ref.items, bnds_new.items) catch |err| {
            std.debug.print("\nMISMATCH on iteration {d}, input ({d} bytes):\n", .{ i, data.len });
            // Print as hex bytes, 16 per line, with offsets.
            var p: usize = 0;
            while (p < data.len) : (p += 16) {
                const e = @min(p + 16, data.len);
                std.debug.print("  {x:0>4}: ", .{p});
                for (data[p..e]) |c| std.debug.print("{x:0>2} ", .{c});
                std.debug.print("  | ", .{});
                for (data[p..e]) |c| std.debug.print("{c}", .{if (c >= 0x20 and c < 0x7f) c else '.'});
                std.debug.print("\n", .{});
            }
            std.debug.print("ref boundaries: {any}\n", .{bnds_ref.items});
            std.debug.print("new boundaries: {any}\n", .{bnds_new.items});
            return err;
        };
        try std.testing.expectEqual(s_ref.depth, s_new.depth);
        try std.testing.expectEqual(s_ref.in_string, s_new.in_string);
        try std.testing.expectEqual(s_ref.escape_pending, s_new.escape_pending);
    }
}

test "boundary SIMD: matches scalar reference under streaming splits" {
    var prng = std.Random.DefaultPrng.init(SEED ^ 0xa5a5_a5a5);
    const rng = prng.random();
    const alloc = std.testing.allocator;

    var i: usize = 0;
    while (i < STREAM_ITERATIONS) : (i += 1) {
        const data = try generateInput(rng, alloc);
        defer alloc.free(data);

        // Pick a random split point (including 0 and data.len).
        const split = if (data.len == 0) 0 else rng.uintAtMost(usize, data.len);

        var s_new = boundary.ScannerState{};
        var s_ref = boundary.ScannerState{};
        var bnds_new: std.ArrayList(usize) = .{};
        defer bnds_new.deinit(alloc);
        var bnds_ref: std.ArrayList(usize) = .{};
        defer bnds_ref.deinit(alloc);

        try boundary.feedBytes(&s_new, data[0..split], 0, &bnds_new, alloc);
        try boundary.feedBytes(&s_new, data[split..], split, &bnds_new, alloc);

        try boundary.feedBytesReference(&s_ref, data[0..split], 0, &bnds_ref, alloc);
        try boundary.feedBytesReference(&s_ref, data[split..], split, &bnds_ref, alloc);

        std.testing.expectEqualSlices(usize, bnds_ref.items, bnds_new.items) catch |err| {
            std.debug.print("\nMISMATCH on streaming iteration {d}, split={d}, input ({d} bytes):\n", .{ i, split, data.len });
            var p: usize = 0;
            while (p < data.len) : (p += 16) {
                const e = @min(p + 16, data.len);
                std.debug.print("  {x:0>4}: ", .{p});
                for (data[p..e]) |c| std.debug.print("{x:0>2} ", .{c});
                std.debug.print("  | ", .{});
                for (data[p..e]) |c| std.debug.print("{c}", .{if (c >= 0x20 and c < 0x7f) c else '.'});
                std.debug.print("\n", .{});
            }
            std.debug.print("ref boundaries: {any}\n", .{bnds_ref.items});
            std.debug.print("new boundaries: {any}\n", .{bnds_new.items});
            return err;
        };
        try std.testing.expectEqual(s_ref.depth, s_new.depth);
        try std.testing.expectEqual(s_ref.in_string, s_new.in_string);
        try std.testing.expectEqual(s_ref.escape_pending, s_new.escape_pending);
    }
}

// ── Directed micro-tests ─────────────────────────────────────────────────────

fn checkAgainstReference(data: []const u8) !void {
    const alloc = std.testing.allocator;
    var s_new = boundary.ScannerState{};
    var s_ref = boundary.ScannerState{};
    var bnds_new: std.ArrayList(usize) = .{};
    defer bnds_new.deinit(alloc);
    var bnds_ref: std.ArrayList(usize) = .{};
    defer bnds_ref.deinit(alloc);
    try boundary.feedBytes(&s_new, data, 0, &bnds_new, alloc);
    try boundary.feedBytesReference(&s_ref, data, 0, &bnds_ref, alloc);
    try std.testing.expectEqualSlices(usize, bnds_ref.items, bnds_new.items);
    try std.testing.expectEqual(s_ref.depth, s_new.depth);
    try std.testing.expectEqual(s_ref.in_string, s_new.in_string);
    try std.testing.expectEqual(s_ref.escape_pending, s_new.escape_pending);
}

test "directed: backslash at byte 63 (escape carry into next chunk)" {
    // Build: 62 string-content bytes, then `\\n` at bytes 63..64.
    // Byte 63 is the trailing `\` of an unterminated escape sequence —
    // the SIMD pipeline must propagate `escape_pending` across the
    // 64-byte chunk boundary.
    var data: [128]u8 = undefined;
    data[0] = '"';
    @memset(data[1..63], 'A');
    data[63] = '\\';
    data[64] = 'n';
    @memset(data[65..127], 'B');
    data[127] = '"';
    try checkAgainstReference(&data);
}

test "directed: backslash at byte 64 of unterminated escape (carry across split)" {
    // Stream split: feed `"...\` (ending at byte 64 with a \\), then
    // feed `n"` after. The escape must carry across the feedBytes call.
    const alloc = std.testing.allocator;

    var first: [65]u8 = undefined;
    first[0] = '"';
    @memset(first[1..64], 'A');
    first[64] = '\\';

    var s_new = boundary.ScannerState{};
    var s_ref = boundary.ScannerState{};
    var bnds_new: std.ArrayList(usize) = .{};
    defer bnds_new.deinit(alloc);
    var bnds_ref: std.ArrayList(usize) = .{};
    defer bnds_ref.deinit(alloc);

    try boundary.feedBytes(&s_new, &first, 0, &bnds_new, alloc);
    try boundary.feedBytesReference(&s_ref, &first, 0, &bnds_ref, alloc);
    try std.testing.expectEqual(s_ref.in_string, s_new.in_string);
    try std.testing.expectEqual(s_ref.escape_pending, s_new.escape_pending);

    const tail = "n\"\n";
    try boundary.feedBytes(&s_new, tail, first.len, &bnds_new, alloc);
    try boundary.feedBytesReference(&s_ref, tail, first.len, &bnds_ref, alloc);
    try std.testing.expectEqualSlices(usize, bnds_ref.items, bnds_new.items);
    try std.testing.expectEqual(s_ref.depth, s_new.depth);
    try std.testing.expectEqual(s_ref.in_string, s_new.in_string);
    try std.testing.expectEqual(s_ref.escape_pending, s_new.escape_pending);
}

test "directed: quote at byte 63 (in-string carry)" {
    // 62 boring bytes outside string, quote at 63 opens a string, then
    // string content spans into the next 64-byte chunk.
    var data: [128]u8 = undefined;
    @memset(data[0..63], ' ');
    data[63] = '"';
    @memset(data[64..127], 'A');
    data[127] = '"';
    try checkAgainstReference(&data);
}

test "directed: long string spanning 3 chunks with no escapes" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    try buf.append(std.testing.allocator, '"');
    try buf.appendNTimes(std.testing.allocator, 'A', 200);
    try buf.append(std.testing.allocator, '"');
    try buf.append(std.testing.allocator, '\n');
    try checkAgainstReference(buf.items);
}

test "directed: long string spanning 3 chunks with escape pairs at every seam" {
    // Plant `\\\\` (an escaped-backslash pair) straddling each 64-byte
    // seam. With the even/odd run-start trick, every `\\` pair
    // contributes zero to escape_target_mask (no escape pending after).
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;
    try buf.append(alloc, '"');
    // Pad to byte 62, put `\\\\` at 62..65 (straddles seam 63|64).
    try buf.appendNTimes(alloc, 'A', 61);
    try buf.appendSlice(alloc, "\\\\\\\\");
    // Pad to byte 126, put another `\\\\` at 126..129 (straddles 127|128).
    try buf.appendNTimes(alloc, 'B', 126 - buf.items.len);
    try buf.appendSlice(alloc, "\\\\\\\\");
    // Pad to byte 190, put another `\\\\` at 190..193 (straddles 191|192).
    try buf.appendNTimes(alloc, 'C', 190 - buf.items.len);
    try buf.appendSlice(alloc, "\\\\\\\\");
    try buf.append(alloc, '"');
    try buf.append(alloc, '\n');
    try checkAgainstReference(buf.items);
}

test "directed: depth 1 newline must NOT emit boundary" {
    const data = "[\n1\n,\n2\n]\n";
    try checkAgainstReference(data);
    // Sanity: only one boundary (the trailing \n at depth 0).
    const alloc = std.testing.allocator;
    var s = boundary.ScannerState{};
    var bnds: std.ArrayList(usize) = .{};
    defer bnds.deinit(alloc);
    try boundary.feedBytes(&s, data, 0, &bnds, alloc);
    try std.testing.expectEqual(@as(usize, 1), bnds.items.len);
    try std.testing.expectEqual(data.len - 1, bnds.items[0]);
}

test "directed: depth-0 newline immediately after `}` at byte 63" {
    // Build: pretty object whose closing `}` lands at byte 62 and
    // record-terminator `\n` at byte 63 (last byte of chunk 0).
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;
    try buf.append(alloc, '{');
    try buf.appendNTimes(alloc, ' ', 60);
    try buf.append(alloc, '}');
    try buf.append(alloc, '\n');
    // buf now: 1 + 60 + 1 + 1 = 63 bytes — newline at byte 62, not 63.
    // Adjust by adding one more space.
    buf.clearRetainingCapacity();
    try buf.append(alloc, '{');
    try buf.appendNTimes(alloc, ' ', 61);
    try buf.append(alloc, '}');
    try buf.append(alloc, '\n');
    try std.testing.expectEqual(@as(usize, 64), buf.items.len);
    try std.testing.expectEqual(@as(u8, '\n'), buf.items[63]);
    try checkAgainstReference(buf.items);
}

test "directed: even-length backslash run at chunk seam" {
    // 4 backslashes (`\\\\` in source) straddling byte 63|64. Even
    // length → no escape carry, no escape target inside the run.
    var data: [128]u8 = undefined;
    data[0] = '"';
    @memset(data[1..62], 'A');
    data[62] = '\\';
    data[63] = '\\';
    data[64] = '\\';
    data[65] = '\\';
    @memset(data[66..127], 'B');
    data[127] = '"';
    try checkAgainstReference(&data);
}

test "directed: odd-length backslash run at chunk seam" {
    // 3 backslashes straddling byte 63|64, then `n` as escape target.
    var data: [128]u8 = undefined;
    data[0] = '"';
    @memset(data[1..62], 'A');
    data[62] = '\\';
    data[63] = '\\';
    data[64] = '\\';
    data[65] = 'n';
    @memset(data[66..127], 'B');
    data[127] = '"';
    try checkAgainstReference(&data);
}

test "directed: streaming split mid-escape" {
    const alloc = std.testing.allocator;
    const first = "\"abc\\";
    const second = "n\"\n";

    var s_new = boundary.ScannerState{};
    var s_ref = boundary.ScannerState{};
    var bnds_new: std.ArrayList(usize) = .{};
    defer bnds_new.deinit(alloc);
    var bnds_ref: std.ArrayList(usize) = .{};
    defer bnds_ref.deinit(alloc);

    try boundary.feedBytes(&s_new, first, 0, &bnds_new, alloc);
    try boundary.feedBytes(&s_new, second, first.len, &bnds_new, alloc);
    try boundary.feedBytesReference(&s_ref, first, 0, &bnds_ref, alloc);
    try boundary.feedBytesReference(&s_ref, second, first.len, &bnds_ref, alloc);

    try std.testing.expectEqualSlices(usize, bnds_ref.items, bnds_new.items);
    try std.testing.expectEqual(s_ref.depth, s_new.depth);
    try std.testing.expectEqual(s_ref.in_string, s_new.in_string);
    try std.testing.expectEqual(s_ref.escape_pending, s_new.escape_pending);
}

test "directed: empty residual tail (data.len multiple of 64)" {
    // 128 bytes (exactly two chunks, no tail).
    var data: [128]u8 = undefined;
    data[0] = '{';
    @memset(data[1..63], ' ');
    data[63] = '}';
    data[64] = '\n';
    data[65] = '{';
    @memset(data[66..127], ' ');
    data[127] = '}';
    try std.testing.expectEqual(@as(usize, 128), data.len);
    try checkAgainstReference(&data);
}

test "directed: residual tail with newline at last byte" {
    // 67 bytes: one full chunk (64) + tail of 3 ending in `\n`.
    var data: [67]u8 = undefined;
    data[0] = '{';
    @memset(data[1..63], ' ');
    data[63] = '}';
    data[64] = ' ';
    data[65] = ' ';
    data[66] = '\n';
    try checkAgainstReference(&data);
}

test "directed: depth 0 newline at byte 0 of input" {
    // Edge: the very first byte is a record-terminating newline. The
    // SIMD path computes lt = (1<<0) - 1 = 0, so opens_lt = closes_lt
    // = 0, and depth = state.depth + 0 - 0. Must emit when depth = 0.
    try checkAgainstReference("\n{\"a\":1}\n");
}

test "directed: deeply nested then closed" {
    try checkAgainstReference("[[[[[[[[[[1]]]]]]]]]]\n");
}

test "directed: backslash-quote in string then close" {
    try checkAgainstReference("\"foo\\\"bar\"\n");
}
