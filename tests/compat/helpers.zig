// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// Shared utilities for all compat test sections.
// Each section file does:  const h = @import("helpers.zig");

const std = @import("std");
const parser_mod = @import("parser");
const query_mod = @import("query");
const types = @import("types");

const Parser = parser_mod.Parser;
const CompiledQuery = query_mod.CompiledQuery;
const Value = types.Value;
const Tape = types.Tape;

pub const alloc = std.testing.allocator;

// ââ Tape helpers ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ

pub fn entryToValue(tape: *const Tape, idx: u32) Value {
    const entry = tape.entries[idx];
    return switch (entry.tag) {
        .null_val => .null_val,
        .true_val => .{ .bool_val = true },
        .false_val => .{ .bool_val = false },
        .int => .{ .int = entry.payload.int },
        .float => .{ .float = entry.payload.float },
        .string => .{ .string = tape.getString(entry.payload.string) },
        .array_start => .{ .array = .{ .tape = tape, .start = idx, .end = entry.payload.skip } },
        .object_start => .{ .object = .{ .tape = tape, .start = idx, .end = entry.payload.skip } },
        else => unreachable,
    };
}

pub fn skipTapeEntry(tape: *const Tape, idx: u32) u32 {
    const entry = tape.entries[idx];
    return switch (entry.tag) {
        .array_start, .object_start => entry.payload.skip,
        else => idx + 1,
    };
}

// ââ Value â compact JSON ââââââââââââââââââââââââââââââââââââââââââââââââââââââ

pub fn serializeValue(buf: *std.ArrayList(u8), val: Value) error{OutOfMemory}!void {
    switch (val) {
        .null_val => try buf.appendSlice(alloc, "null"),
        .bool_val => |b| try buf.appendSlice(alloc, if (b) "true" else "false"),
        .int => |n| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
            try buf.appendSlice(alloc, s);
        },
        .float => |f| {
            if (std.math.isNan(f) or std.math.isInf(f)) {
                try buf.appendSlice(alloc, "null");
            } else {
                var tmp: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
                try buf.appendSlice(alloc, s);
            }
        },
        .string => |s| {
            try buf.append(alloc, '"');
            try writeEscaped(buf, s);
            try buf.append(alloc, '"');
        },
        .array => |span| {
            try buf.append(alloc, '[');
            const tape = span.tape;
            var idx = span.start + 1;
            var first = true;
            while (idx < span.end - 1) {
                if (!first) try buf.append(alloc, ',');
                first = false;
                try serializeValue(buf, entryToValue(tape, idx));
                idx = skipTapeEntry(tape, idx);
            }
            try buf.append(alloc, ']');
        },
        .object => |span| {
            try buf.append(alloc, '{');
            const tape = span.tape;
            var idx = span.start + 1;
            var first = true;
            while (idx < span.end - 1) {
                const key_ref = tape.entries[idx].payload.string;
                const key_str = tape.getString(key_ref);
                if (!first) try buf.append(alloc, ',');
                first = false;
                try buf.append(alloc, '"');
                try writeEscaped(buf, key_str);
                try buf.appendSlice(alloc, "\":");
                idx += 1;
                try serializeValue(buf, entryToValue(tape, idx));
                idx = skipTapeEntry(tape, idx);
            }
            try buf.append(alloc, '}');
        },
    }
}

/// jq-compatible escaping: uses standard JSON escape sequences (\n, \t, \r, \b, \f)
/// for common control characters, \uXXXX for other control characters, and outputs
/// valid multi-byte UTF-8 sequences as literal bytes (matching jq's output format).
pub fn writeEscaped(buf: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const byte = s[i];
        if (byte < 0x80) {
            switch (byte) {
                '"' => try buf.appendSlice(alloc, "\\\""),
                '\\' => try buf.appendSlice(alloc, "\\\\"),
                '\n' => try buf.appendSlice(alloc, "\\n"),
                '\t' => try buf.appendSlice(alloc, "\\t"),
                '\r' => try buf.appendSlice(alloc, "\\r"),
                0x08 => try buf.appendSlice(alloc, "\\b"),
                0x0C => try buf.appendSlice(alloc, "\\f"),
                0x20, 0x21, 0x23...0x5B, 0x5D...0x7E => try buf.append(alloc, byte),
                else => {
                    var tmp: [6]u8 = undefined;
                    const seq = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{byte}) catch unreachable;
                    try buf.appendSlice(alloc, seq);
                },
            }
            i += 1;
        } else {
            // Non-ASCII: output valid UTF-8 sequences as literal bytes (jq behavior).
            const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
                try buf.appendSlice(alloc, "\\ufffd");
                i += 1;
                continue;
            };
            if (i + seq_len > s.len) {
                try buf.appendSlice(alloc, "\\ufffd");
                i += 1;
                continue;
            }
            _ = std.unicode.utf8Decode(s[i..][0..seq_len]) catch {
                try buf.appendSlice(alloc, "\\ufffd");
                i += seq_len;
                continue;
            };
            // Valid UTF-8 sequence: output as literal bytes
            try buf.appendSlice(alloc, s[i..][0..seq_len]);
            i += seq_len;
        }
    }
}

// ââ Core runners ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ

/// Parse input JSON, compile filter, execute, collect serialized results.
/// Caller owns the returned slice and each string within it.
pub fn runFilter(filter: []const u8, input_json: []const u8) ![][]const u8 {
    var p = try Parser.init(alloc);
    defer p.deinit();

    const tape = switch (try p.feed(input_json, true)) {
        .done => |d| d.tape,
        .need_more => return error.ParseIncomplete,
    };

    const result = try CompiledQuery.compile(filter, .{}, alloc);
    var q = switch (result) {
        .ok => |cq| cq,
        .err => return error.QuerySyntaxError,
    };
    defer q.deinit();

    var it = try q.execute(tape, &.{}, alloc);
    defer it.deinit();

    var result_list = std.ArrayList([]const u8){};
    errdefer {
        for (result_list.items) |s| alloc.free(s);
        result_list.deinit(alloc);
    }

    while (it.next() catch return error.QueryRuntimeError) |val| {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(alloc);
        try serializeValue(&buf, val);
        try result_list.append(alloc, try buf.toOwnedSlice(alloc));
    }

    return result_list.toOwnedSlice(alloc);
}

/// Verify that compiling `filter` returns a compile error (%%FAIL tests).
pub fn expectCompileError(filter: []const u8) !void {
    const result = try CompiledQuery.compile(filter, .{}, alloc);
    switch (result) {
        .ok => |cq| {
            var q = cq;
            q.deinit();
            return error.ExpectedCompileError;
        },
        .err => return,
    }
}
