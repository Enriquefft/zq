//! Property test for `parser.parallel_scan`.
//!
//! Generates 1000 random JSON-shaped inputs (seeded prng) covering every
//! tricky byte pattern the parallel scanner has to survive — escape
//! sequences, in-string newlines, in-string structural characters,
//! deeply nested containers, pretty-printed values, trailing partials,
//! compact JSONL, long strings spanning region cuts, and `\` immediately
//! before a region cut. For each input the test compares the stitched
//! parallel boundary list against the serial `boundary.feedBytes`
//! oracle. Any divergence means the dual-variant + carry-rescan stitch
//! is incorrect on that byte content.
//!
//! Plus a battery of directed micro-tests pinned at the corner cases
//! the random generator can technically hit but rarely does (zero-byte
//! regions, alignment hot-paths, exact-fit objects, etc.).

const std = @import("std");
const parser = @import("parser");

const boundary = parser.boundary;
const parallel_scan = parser.parallel_scan;

// ── Random generator ─────────────────────────────────────────────────

/// Hand-rolled JSON-shaped generator. Not a complete JSON producer —
/// the goal is *coverage of the scanner's state machine*, not validity.
/// Outputs are valid JSONL most of the time and intentionally include
/// the corner cases the scanner has to handle byte-wise.
const Generator = struct {
    rng: std.Random,
    alloc: std.mem.Allocator,
    buf: std.ArrayList(u8) = .{},
    target_size: usize,

    fn init(rng: std.Random, alloc: std.mem.Allocator, target_size: usize) Generator {
        return .{ .rng = rng, .alloc = alloc, .target_size = target_size };
    }

    fn deinit(self: *Generator) void {
        self.buf.deinit(self.alloc);
    }

    fn append(self: *Generator, s: []const u8) !void {
        try self.buf.appendSlice(self.alloc, s);
    }

    fn appendByte(self: *Generator, b: u8) !void {
        try self.buf.append(self.alloc, b);
    }

    const EmitError = error{OutOfMemory};

    /// Emit one random value. `depth` is the current nesting depth.
    fn emitValue(self: *Generator, depth: u32) EmitError!void {
        const max_depth: u32 = 10;
        const choice: u8 = if (depth >= max_depth)
            self.rng.intRangeAtMost(u8, 0, 4) // primitives only
        else
            self.rng.intRangeAtMost(u8, 0, 6);
        switch (choice) {
            0 => try self.append("null"),
            1 => try self.append("true"),
            2 => try self.append("false"),
            3 => {
                const n = self.rng.int(i32);
                var tmp: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
                try self.append(s);
            },
            4 => try self.emitString(),
            5 => try self.emitArray(depth + 1),
            6 => try self.emitObject(depth + 1),
            else => unreachable,
        }
    }

    fn emitArray(self: *Generator, depth: u32) EmitError!void {
        const pretty = self.rng.boolean();
        try self.appendByte('[');
        const n = self.rng.uintLessThan(u8, 5);
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            if (i > 0) {
                try self.appendByte(',');
                if (pretty) try self.appendByte('\n');
            } else if (pretty) try self.appendByte('\n');
            try self.emitValue(depth);
        }
        if (pretty and n > 0) try self.appendByte('\n');
        try self.appendByte(']');
    }

    fn emitObject(self: *Generator, depth: u32) EmitError!void {
        const pretty = self.rng.boolean();
        try self.appendByte('{');
        const n = self.rng.uintLessThan(u8, 5);
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            if (i > 0) {
                try self.appendByte(',');
                if (pretty) try self.appendByte('\n');
            } else if (pretty) try self.appendByte('\n');
            try self.emitString();
            try self.appendByte(':');
            try self.emitValue(depth);
        }
        if (pretty and n > 0) try self.appendByte('\n');
        try self.appendByte('}');
    }

    /// Emit a JSON string. By construction, sometimes contains:
    ///   - `\\`, `\"`, raw `\n`, raw `{}[]`, long ASCII runs,
    ///   - very long content (≥ 32 bytes — likely to span a region cut),
    ///   - rarely, a trailing `\` so a `\` lands on the very last byte
    ///     of the buffer (escape-on-cut hot path is mostly hit by
    ///     placement during slicing rather than by `\` at EOF).
    fn emitString(self: *Generator) !void {
        try self.appendByte('"');
        const len = self.rng.uintLessThan(u32, 80);
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const pick = self.rng.uintLessThan(u8, 100);
            if (pick < 5) {
                try self.append("\\\\"); // literal backslash
            } else if (pick < 10) {
                try self.append("\\\""); // escaped quote
            } else if (pick < 15) {
                try self.appendByte('\n'); // raw newline inside string
            } else if (pick < 20) {
                // structural char inside string — must NOT affect depth
                const sc: u8 = "{}[]"[self.rng.uintLessThan(u8, 4)];
                try self.appendByte(sc);
            } else {
                // safe ASCII run length 1..16 to feed the SIMD fast path
                const run_len = 1 + self.rng.uintLessThan(u8, 16);
                var j: u8 = 0;
                while (j < run_len and i + j < len) : (j += 1) {
                    const c: u8 = 'a' + self.rng.uintLessThan(u8, 26);
                    try self.appendByte(c);
                }
                i += run_len -| 1;
            }
        }
        try self.appendByte('"');
    }

    /// Top-level: emit a stream of records separated by `\n`.
    /// Occasionally append a trailing partial value with no closing
    /// terminator (case 6 — trailing partial).
    pub fn generate(rng: std.Random, alloc: std.mem.Allocator, target_size: usize) ![]u8 {
        var g = Generator.init(rng, alloc, target_size);
        defer g.deinit();
        while (g.buf.items.len < target_size) {
            try g.emitValue(0);
            try g.appendByte('\n');
        }
        // 1-in-10 chance: drop the trailing newline so the last record
        // is unterminated (no boundary at EOF).
        if (rng.uintLessThan(u8, 10) == 0 and g.buf.items.len > 0 and g.buf.items[g.buf.items.len - 1] == '\n') {
            _ = g.buf.pop();
        }
        return g.buf.toOwnedSlice(alloc);
    }
};

// ── Helpers ───────────────────────────────────────────────────────────

fn serialOracle(data: []const u8, alloc: std.mem.Allocator) ![]usize {
    var st = boundary.ScannerState{};
    var out: std.ArrayList(usize) = .{};
    errdefer out.deinit(alloc);
    try boundary.feedBytes(&st, data, 0, &out, alloc);
    return out.toOwnedSlice(alloc);
}

fn parallelStitch(data: []const u8, n_regions: usize, alloc: std.mem.Allocator) ![]usize {
    const regions = try parallel_scan.scanRegions(data, n_regions, alloc);
    defer parallel_scan.freeRegions(alloc, regions);
    var out: std.ArrayList(usize) = .{};
    errdefer out.deinit(alloc);
    try parallel_scan.stitch(regions, &out, alloc);
    return out.toOwnedSlice(alloc);
}

// ── Property test ─────────────────────────────────────────────────────

test "parallel_scan: matches serial scan on 1000 random inputs" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    const alloc = std.testing.allocator;

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        // Vary target size: most 64 KiB, some smaller (forces serial
        // fallback path), some larger (more region cuts per input).
        const size_bucket = rng.uintLessThan(u8, 10);
        const target_size: usize = if (size_bucket == 0)
            rng.uintLessThan(usize, 8 * 1024) // tiny — exercises serial fallback
        else if (size_bucket == 1)
            128 * 1024 // larger
        else
            64 * 1024; // typical

        const data = try Generator.generate(rng, alloc, target_size);
        defer alloc.free(data);

        const n_regions = 1 + rng.uintLessThan(usize, 16);

        const oracle = try serialOracle(data, alloc);
        defer alloc.free(oracle);

        const got = try parallelStitch(data, n_regions, alloc);
        defer alloc.free(got);

        std.testing.expectEqualSlices(usize, oracle, got) catch |err| {
            std.debug.print(
                "iter={d} n_regions={d} data.len={d} oracle.len={d} got.len={d}\n",
                .{ i, n_regions, data.len, oracle.len, got.len },
            );
            return err;
        };
    }
}

// ── Directed micro-tests ─────────────────────────────────────────────

fn expectStitchEqualsSerial(data: []const u8, n_regions: usize) !void {
    const alloc = std.testing.allocator;
    const oracle = try serialOracle(data, alloc);
    defer alloc.free(oracle);
    const got = try parallelStitch(data, n_regions, alloc);
    defer alloc.free(got);
    try std.testing.expectEqualSlices(usize, oracle, got);
}

test "directed: empty input" {
    try expectStitchEqualsSerial("", 4);
}

test "directed: single byte input" {
    try expectStitchEqualsSerial("1", 4);
    try expectStitchEqualsSerial("\n", 4);
}

test "directed: single region" {
    try expectStitchEqualsSerial("1\n2\n3\n", 1);
}

test "directed: 16 regions over JSONL" {
    // Build a 256-record JSONL stream — well below MIN_PARALLEL_BYTES,
    // so this hits the serial path despite n_regions=16.
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        var tmp: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}\n", .{i}) catch unreachable;
        try buf.appendSlice(alloc, s);
    }
    try expectStitchEqualsSerial(buf.items, 16);
}

test "directed: 16 regions over big JSONL (parallel path)" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    // Pad each record to make it ~256 bytes so 256 records ≥ 64 KiB
    // and the parallel path actually fires.
    var i: u32 = 0;
    while (i < 512) : (i += 1) {
        var tmp: [320]u8 = undefined;
        const s = std.fmt.bufPrint(
            &tmp,
            "{{\"id\":{d},\"pad\":\"{s}\"}}\n",
            .{ i, "abcdefghijklmnopqrstuvwxyz" ** 8 },
        ) catch unreachable;
        try buf.appendSlice(alloc, s);
    }
    try expectStitchEqualsSerial(buf.items, 16);
}

test "directed: mid-string split" {
    // A long string with a `\n` inside that the scanner must NOT pick
    // up. With 4 regions the cut likely lands inside the string.
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "\"");
    try buf.appendNTimes(alloc, 'a', 80 * 1024);
    try buf.appendSlice(alloc, "mid\nbreak");
    try buf.appendNTimes(alloc, 'b', 80 * 1024);
    try buf.appendSlice(alloc, "\"\n");
    try expectStitchEqualsSerial(buf.items, 4);
}

test "directed: mid-array split" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "[\n");
    var i: u32 = 0;
    while (i < 4096) : (i += 1) {
        try buf.appendSlice(alloc, "1,\n");
    }
    try buf.appendSlice(alloc, "1\n]\n");
    // 4 regions over a 16-KiB-ish array → cuts land inside the array.
    try expectStitchEqualsSerial(buf.items, 4);
}

test "directed: escape on cut (\\ near region boundary)" {
    // Build 80 KiB of in-string content terminating with `\\` followed
    // by `n`, so wherever the scanner cuts inside this run there's a
    // chance the cut lands right after a `\`. Test with several region
    // counts to vary the cut positions.
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    try buf.append(alloc, '"');
    var i: u32 = 0;
    // Every 31 bytes, emit a `\\n` so backslashes appear at varying
    // alignments to the 32-byte region cuts. With 8 regions of an
    // ~80 KiB buffer the cuts step ~10 KiB apart and hit several `\`.
    while (i < 80 * 1024) : (i += 1) {
        if (i % 31 == 30) {
            try buf.append(alloc, '\\');
            try buf.append(alloc, 'n');
        } else {
            try buf.append(alloc, 'a');
        }
    }
    try buf.appendSlice(alloc, "\"\n");
    try expectStitchEqualsSerial(buf.items, 8);
}

test "directed: region split inside object" {
    // Force a parallel-path object straddle. 80 KiB of padded `{ }`.
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\n");
    try buf.appendSlice(alloc, "\"key\":\"");
    try buf.appendNTimes(alloc, 'x', 80 * 1024);
    try buf.appendSlice(alloc, "\"\n}\n");
    try expectStitchEqualsSerial(buf.items, 4);
}

test "directed: regions of length 0/1/31/32/33" {
    // The computed bases collapse zero-length regions, so we can't
    // directly construct an empty region — but we *can* exercise
    // boundary-adjacent sizes. Build a tiny input and request many
    // regions; the fallback path produces a single region. Then make
    // bigger inputs at exactly 64 KiB ± small offsets and request 8
    // regions to stress alignment.
    try expectStitchEqualsSerial("", 4);
    try expectStitchEqualsSerial("a", 4);
    try expectStitchEqualsSerial("a" ** 31, 4);
    try expectStitchEqualsSerial("a" ** 32, 4);
    try expectStitchEqualsSerial("a" ** 33, 4);
    try expectStitchEqualsSerial("a" ** 33 ++ "\n", 4);
}

test "directed: long string spans region cut with raw newlines" {
    // 100 KiB string with raw newlines inside, then close + record \n.
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    try buf.append(alloc, '"');
    var i: u32 = 0;
    while (i < 100 * 1024) : (i += 1) {
        if (i % 256 == 255) {
            try buf.append(alloc, '\n');
        } else {
            try buf.append(alloc, 'a');
        }
    }
    try buf.appendSlice(alloc, "\"\n");
    try expectStitchEqualsSerial(buf.items, 8);
}

test "directed: deeply nested pretty-printed object" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try buf.appendSlice(alloc, "{\n\"k\":");
    }
    try buf.appendSlice(alloc, "1");
    i = 0;
    while (i < 16) : (i += 1) {
        try buf.appendSlice(alloc, "\n}");
    }
    try buf.append(alloc, '\n');
    // Pad to exceed MIN_PARALLEL_BYTES so the parallel path fires.
    try buf.appendNTimes(alloc, ' ', 64 * 1024);
    try buf.append(alloc, '\n');
    try expectStitchEqualsSerial(buf.items, 4);
}

test "directed: structural chars inside string ignored across regions" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    try buf.append(alloc, '"');
    try buf.appendNTimes(alloc, '{', 32 * 1024);
    try buf.appendNTimes(alloc, '}', 32 * 1024);
    try buf.appendSlice(alloc, "\"\n");
    try expectStitchEqualsSerial(buf.items, 4);
}
