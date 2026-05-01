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
        .big_number => .{ .big_number = tape.getString(entry.payload.string) },
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
            const formatted = types.formatJqFloat(f);
            try buf.appendSlice(alloc, formatted.slice());
        },
        .big_number => |bn| try buf.appendSlice(alloc, bn),
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

// ââ Structural JSON comparison ââââââââââââââââââââââââââââââââââââââââââââââââ

/// Return the numeric value of a Value as f64, or null if not numeric.
fn numericAsF64(v: Value) ?f64 {
    return switch (v) {
        .int => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        else => null,
    };
}

/// Count the number of key-value pairs in an object span.
fn objectLen(span: Value.TapeSpan) usize {
    var count: usize = 0;
    var idx = span.start + 1;
    while (idx < span.end - 1) {
        count += 1;
        idx += 1; // skip key
        idx = skipTapeEntry(span.tape, idx); // skip value
    }
    return count;
}

/// Find the value associated with `key` in an object span.
/// Returns the Value if found, null otherwise.
fn objectGet(span: Value.TapeSpan, key: []const u8) ?Value {
    var idx = span.start + 1;
    while (idx < span.end - 1) {
        const key_ref = span.tape.entries[idx].payload.string;
        const k = span.tape.getString(key_ref);
        idx += 1;
        const val = entryToValue(span.tape, idx);
        idx = skipTapeEntry(span.tape, idx);
        if (std.mem.eql(u8, k, key)) return val;
    }
    return null;
}

/// Deep structural equality matching jq's == semantics:
///   - null, bool: exact tag match
///   - numbers: compare as f64 (so int 2 == float 2.0)
///   - strings: byte-equal (parser has already decoded all escape sequences)
///   - arrays: element-wise recursive
///   - objects: key-order-insensitive (jq's == is unordered for objects)
fn valuesEqual(a: Value, b: Value) bool {
    // Both numeric? Compare as f64.
    if (numericAsF64(a)) |fa| {
        if (numericAsF64(b)) |fb| {
            return fa == fb;
        }
        return false; // a is numeric, b is not
    }
    if (numericAsF64(b) != null) return false; // b is numeric, a is not

    switch (a) {
        .null_val => return b == .null_val,
        .bool_val => |ba| return switch (b) {
            .bool_val => |bb| ba == bb,
            else => false,
        },
        .string => |sa| return switch (b) {
            .string => |sb| std.mem.eql(u8, sa, sb),
            else => false,
        },
        .array => |spa| {
            const spb = switch (b) {
                .array => |s| s,
                else => return false,
            };
            // Compare element by element
            var ia = spa.start + 1;
            var ib = spb.start + 1;
            while (ia < spa.end - 1 and ib < spb.end - 1) {
                const va = entryToValue(spa.tape, ia);
                const vb = entryToValue(spb.tape, ib);
                if (!valuesEqual(va, vb)) return false;
                ia = skipTapeEntry(spa.tape, ia);
                ib = skipTapeEntry(spb.tape, ib);
            }
            // Both must be exhausted simultaneously
            return (ia >= spa.end - 1) and (ib >= spb.end - 1);
        },
        .object => |spa| {
            const spb = switch (b) {
                .object => |s| s,
                else => return false,
            };
            // Object equality is key-order-insensitive (jq behavior).
            // Check same number of keys and every key in a exists in b with equal value.
            if (objectLen(spa) != objectLen(spb)) return false;
            var ia = spa.start + 1;
            while (ia < spa.end - 1) {
                const key_ref = spa.tape.entries[ia].payload.string;
                const key = spa.tape.getString(key_ref);
                ia += 1;
                const va = entryToValue(spa.tape, ia);
                ia = skipTapeEntry(spa.tape, ia);
                const vb = objectGet(spb, key) orelse return false;
                if (!valuesEqual(va, vb)) return false;
            }
            return true;
        },
        .big_number => |abn| return switch (b) {
            .big_number => |bbn| std.mem.eql(u8, abn, bbn),
            else => false,
        },
        // int and float are handled by the numeric fast-path above
        .int => unreachable,
        .float => unreachable,
    }
}

/// Structural JSON equality assertion.
/// Parses both `expected_json` and `actual_json` with the zq Parser,
/// then compares resulting Values structurally (jq == semantics):
///   - Numbers: compared as f64 (so 2 == 2.0 == 20e-1)
///   - Strings: compared after escape decoding (all escape sequences decoded by parser)
///   - Objects: key-order-insensitive (jq == is unordered)
///   - Arrays: ordered, element-wise recursive
pub fn expectJsonEqual(expected_json: []const u8, actual_json: []const u8) !void {
    // Parse both sides, keeping the Tape alive in this frame.
    // Value.TapeSpan.tape is a non-owning pointer into the Parser's internal
    // buffers via the Tape struct on the stack â the Tape must outlive the Value.
    var p_exp = try Parser.init(alloc);
    defer p_exp.deinit();
    const tape_exp = switch (p_exp.feed(expected_json, true) catch {
        std.debug.print("\nexpectJsonEqual: failed to parse expected JSON: {s}\n", .{expected_json});
        return error.TestExpectedEqual;
    }) {
        .done => |d| d.tape,
        .need_more => {
            std.debug.print("\nexpectJsonEqual: expected JSON incomplete: {s}\n", .{expected_json});
            return error.TestExpectedEqual;
        },
    };
    const exp_val = entryToValue(&tape_exp, 0);

    var p_act = try Parser.init(alloc);
    defer p_act.deinit();
    const tape_act = switch (p_act.feed(actual_json, true) catch {
        std.debug.print("\nexpectJsonEqual: failed to parse actual JSON: {s}\n", .{actual_json});
        return error.TestExpectedEqual;
    }) {
        .done => |d| d.tape,
        .need_more => {
            std.debug.print("\nexpectJsonEqual: actual JSON incomplete: {s}\n", .{actual_json});
            return error.TestExpectedEqual;
        },
    };
    const act_val = entryToValue(&tape_act, 0);

    if (!valuesEqual(exp_val, act_val)) {
        std.debug.print("\nexpectJsonEqual mismatch:\n  expected: {s}\n  actual:   {s}\n", .{ expected_json, actual_json });
        return error.TestExpectedEqual;
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

    // jq semantics: yield all successful outputs even when the iterator
    // terminates with a runtime error (e.g. a generator that errors after
    // some values have been produced). On error we stop collecting but
    // return whatever was gathered so far — matching jq's partial-output
    // behaviour. Tests that care about the error signal wrap the filter
    // in `try/catch` and check the catch output explicitly.
    while (it.next() catch null) |val| {
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
