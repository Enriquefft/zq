// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// One test per jq test case.  Strategy:
//   QuerySyntaxError â SkipZigTest   (filter not yet implemented)
//   Any other error  â test FAILS    (real compatibility gap)
//   Wrong output     â assertion FAILS
//   %%FAIL tests     â expectCompileError()

const std = @import("std");
const parser_mod = @import("parser");
const query_mod = @import("query");
const types = @import("types");
const err_mod = @import("error");

const Parser = parser_mod.Parser;
const CompiledQuery = query_mod.CompiledQuery;
const Value = types.Value;
const Tape = types.Tape;
const alloc = std.testing.allocator;

// ââ Tape helpers ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ

fn entryToValue(tape: *const Tape, idx: u32) Value {
    const entry = tape.entries[idx];
    return switch (entry.tag) {
        .null_val     => .null_val,
        .true_val     => .{ .bool_val = true },
        .false_val    => .{ .bool_val = false },
        .int          => .{ .int    = entry.payload.int },
        .float        => .{ .float  = entry.payload.float },
        .string       => .{ .string = tape.getString(entry.payload.string) },
        .array_start  => .{ .array  = .{ .tape = tape, .start = idx, .end = entry.payload.skip } },
        .object_start => .{ .object = .{ .tape = tape, .start = idx, .end = entry.payload.skip } },
        else          => unreachable,
    };
}

fn skipTapeEntry(tape: *const Tape, idx: u32) u32 {
    const entry = tape.entries[idx];
    return switch (entry.tag) {
        .array_start, .object_start => entry.payload.skip,
        else => idx + 1,
    };
}

// ââ Value â compact JSON (jq-compatible escaping) âââââââââââââââââââââââââââââ

fn serializeValue(buf: *std.ArrayList(u8), val: Value) error{OutOfMemory}!void {
    switch (val) {
        .null_val  => try buf.appendSlice(alloc, "null"),
        .bool_val  => |b| try buf.appendSlice(alloc, if (b) "true" else "false"),
        .int       => |n| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
            try buf.appendSlice(alloc, s);
        },
        .float     => |f| {
            if (std.math.isNan(f) or std.math.isInf(f)) {
                try buf.appendSlice(alloc, "null");
            } else {
                var tmp: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
                try buf.appendSlice(alloc, s);
            }
        },
        .string    => |s| {
            try buf.append(alloc, '"');
            try writeEscaped(buf, s);
            try buf.append(alloc, '"');
        },
        .array     => |span| {
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
        .object    => |span| {
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

/// jq-compatible escaping:
///   - Control chars (0x00-0x1F)  â \uXXXX
///   - Non-ASCII Unicode            â \uXXXX (surrogate pairs for > U+FFFF)
///   - Printable ASCII (â  " or \) â literal
fn writeEscaped(buf: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const byte = s[i];
        if (byte < 0x80) {
            switch (byte) {
                '"'          => try buf.appendSlice(alloc, "\\\""),
                '\\'         => try buf.appendSlice(alloc, "\\\\"),
                0x20, 0x21,
                0x23...0x5B,
                0x5D...0x7E => try buf.append(alloc, byte),
                else        => {
                    var tmp: [6]u8 = undefined;
                    const seq = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{byte}) catch unreachable;
                    try buf.appendSlice(alloc, seq);
                },
            }
            i += 1;
        } else {
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
            const cp = std.unicode.utf8Decode(s[i..][0..seq_len]) catch {
                try buf.appendSlice(alloc, "\\ufffd");
                i += seq_len;
                continue;
            };
            if (cp <= 0xFFFF) {
                var tmp: [6]u8 = undefined;
                const seq = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{cp}) catch unreachable;
                try buf.appendSlice(alloc, seq);
            } else {
                const adjusted = cp - 0x10000;
                const high: u32 = 0xD800 + (adjusted >> 10);
                const low:  u32 = 0xDC00 + (adjusted & 0x3FF);
                var tmp: [12]u8 = undefined;
                const seq = std.fmt.bufPrint(&tmp, "\\u{x:0>4}\\u{x:0>4}", .{ high, low }) catch unreachable;
                try buf.appendSlice(alloc, seq);
            }
            i += seq_len;
        }
    }
}

// ââ Core run helpers ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ

/// Parse input JSON, compile filter, execute, collect serialized results.
/// Returns an owned slice of owned compact-JSON strings.
fn runFilter(filter: []const u8, input_json: []const u8) ![][]const u8 {
    var p = try Parser.init(alloc);
    defer p.deinit();

    const tape = switch (try p.feed(input_json, true)) {
        .done      => |d| d.tape,
        .need_more => return error.ParseIncomplete,
    };

    var q = try CompiledQuery.compile(filter, .{}, alloc);
    defer q.deinit();

    var it = try q.execute(tape, alloc);
    defer it.deinit();

    var result_list = std.ArrayList([]const u8){};
    errdefer {
        for (result_list.items) |s| alloc.free(s);
        result_list.deinit(alloc);
    }

    while (try it.next()) |val| {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(alloc);
        try serializeValue(&buf, val);
        try result_list.append(alloc, try buf.toOwnedSlice(alloc));
    }

    return result_list.toOwnedSlice(alloc);
}

/// Verify that compiling `filter` returns QuerySyntaxError (%%FAIL tests).
fn expectCompileError(filter: []const u8) !void {
    var q = CompiledQuery.compile(filter, .{}, alloc) catch |e| {
        if (e == error.QuerySyntaxError) return;
        return e;
    };
    q.deinit();
    return error.ExpectedCompileError;
}

test "jq:L8 true" {
    const results = runFilter(
        "true",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L12 false" {
    const results = runFilter(
        "false",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L16 null" {
    const results = runFilter(
        "null",
        "42",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq:L20 1" {
    const results = runFilter(
        "1",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L25 -1" {
    const results = runFilter(
        "-1",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("-1", results[0]);
}

test "jq:L31 {}" {
    const results = runFilter(
        "{}",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{}", results[0]);
}

test "jq:L35 []" {
    const results = runFilter(
        "[]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L39 {x:-1},{x:-.},{x:-.|abs}" {
    const results = runFilter(
        "{x:-1},{x:-.},{x:-.|abs}",
        "1",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("{\"x\":-1}", results[0]);
    try std.testing.expectEqualStrings("{\"x\":-1}", results[1]);
    try std.testing.expectEqualStrings("{\"x\":1}", results[2]);
}

test "jq:L48 ." {
    const results = runFilter(
        ".",
        "﻿\"byte order mark\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"byte order mark\"", results[0]);
}

test "jq:L54 _Aa_r_n_t_b_f_u03bc_" {
    const results = runFilter(
        "\"Aa\\r\\n\\t\\b\\f\\u03bc\"",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Aa\\u000d\\u000a\\u0009\\u0008\\u000c\\u03bc\"", results[0]);
}

test "jq:L58 ." {
    const results = runFilter(
        ".",
        "\"Aa\\r\\n\\t\\b\\f\\u03bc\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Aa\\u000d\\u000a\\u0009\\u0008\\u000c\\u03bc\"", results[0]);
}

test "jq:L62 _u_vw_" {
    // %%FAIL: filter should not compile
    try expectCompileError("\"u\\vw\"");
}

test "jq:L68 _inter_(_pol_ + _ation_)_" {
    const results = runFilter(
        "\"inter\\(\"pol\" + \"ation\")\"",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"interpolation\"", results[0]);
}

test "jq:L72 @text,@json,([1,.]|@csv,@tsv),@html,(@uri|.,@urid),@sh,(@..." {
    const results = runFilter(
        "@text,@json,([1,.]|@csv,@tsv),@html,(@uri|.,@urid),@sh,(@base64|.,@base64d)",
        "\"!()<>&'\\\"\\t\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 10), results.len);
    try std.testing.expectEqualStrings("\"!()<>&'\\\"\\t\"", results[0]);
    try std.testing.expectEqualStrings("\"\\\"!()<>&'\\\\\\\"\\\\t\\\"\"", results[1]);
    try std.testing.expectEqualStrings("\"1,\\\"!()<>&'\\\"\\\"\\t\\\"\"", results[2]);
    try std.testing.expectEqualStrings("\"1\\t!()<>&'\\\"\\\\t\"", results[3]);
    try std.testing.expectEqualStrings("\"!()&lt;&gt;&amp;&apos;&quot;\\t\"", results[4]);
    try std.testing.expectEqualStrings("\"%21%28%29%3C%3E%26%27%22%09\"", results[5]);
    try std.testing.expectEqualStrings("\"!()<>&'\\\"\\t\"", results[6]);
    try std.testing.expectEqualStrings("\"'!()<>&'\\\\''\\\"\\t'\"", results[7]);
    try std.testing.expectEqualStrings("\"ISgpPD4mJyIJ\"", results[8]);
    try std.testing.expectEqualStrings("\"!()<>&'\\\"\\t\"", results[9]);
}

test "jq:L86 @base64" {
    const results = runFilter(
        "@base64",
        "\"foóbar\\n\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Zm/Ds2Jhcgo=\"", results[0]);
}

test "jq:L90 @base64d" {
    const results = runFilter(
        "@base64d",
        "\"Zm/Ds2Jhcgo=\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"foóbar\\n\"", results[0]);
}

test "jq:L94 @uri" {
    const results = runFilter(
        "@uri",
        "\"\\u03bc\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"%CE%BC\"", results[0]);
}

test "jq:L98 @urid" {
    const results = runFilter(
        "@urid",
        "\"%CE%BC\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"\\u03bc\"", results[0]);
}

test "jq:L102 @html _<b>_(.)</b>_" {
    const results = runFilter(
        "@html \"<b>\\(.)</b>\"",
        "\"<script>hax</script>\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"<b>&lt;script&gt;hax&lt;/script&gt;</b>\"", results[0]);
}

test "jq:L106 [.[]|tojson|fromjson]" {
    const results = runFilter(
        "[.[]|tojson|fromjson]",
        "[\"foo\", 1, [\"a\", 1, \"b\", 2, {\"foo\":\"bar\"}]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"foo\",1,[\"a\",1,\"b\",2,{\"foo\":\"bar\"}]]", results[0]);
}

test "jq:L114 {a: 1}" {
    const results = runFilter(
        "{a: 1}",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":1}", results[0]);
}

test "jq:L118 {a,b,(.d):.a,e:.b}" {
    const results = runFilter(
        "{a,b,(.d):.a,e:.b}",
        "{\"a\":1, \"b\":2, \"c\":3, \"d\":\"c\"}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":1, \"b\":2, \"c\":1, \"e\":2}", results[0]);
}

test "jq:L122 {_a_,b,_a$_(1+1)_}" {
    const results = runFilter(
        "{\"a\",b,\"a$\\(1+1)\"}",
        "{\"a\":1, \"b\":2, \"c\":3, \"a$2\":4}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":1, \"b\":2, \"a$2\":4}", results[0]);
}

test "jq:L126 {(0):1}" {
    // %%FAIL: filter should not compile
    try expectCompileError("{(0):1}");
}

test "jq:L132 {1+2:3}" {
    // %%FAIL: filter should not compile
    try expectCompileError("{1+2:3}");
}

test "jq:L138 {non_const:., (0):1}" {
    // %%FAIL: filter should not compile
    try expectCompileError("{non_const:., (0):1}");
}

test "jq:L148 .foo" {
    const results = runFilter(
        ".foo",
        "{\"foo\": 42, \"bar\": 43}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("42", results[0]);
}

test "jq:L152 .foo | .bar" {
    const results = runFilter(
        ".foo | .bar",
        "{\"foo\": {\"bar\": 42}, \"bar\": \"badvalue\"}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("42", results[0]);
}

test "jq:L156 .foo.bar" {
    const results = runFilter(
        ".foo.bar",
        "{\"foo\": {\"bar\": 42}, \"bar\": \"badvalue\"}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("42", results[0]);
}

test "jq:L160 .foo_bar" {
    const results = runFilter(
        ".foo_bar",
        "{\"foo_bar\": 2}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("2", results[0]);
}

test "jq:L164 .[_foo_].bar" {
    const results = runFilter(
        ".[\"foo\"].bar",
        "{\"foo\": {\"bar\": 42}, \"bar\": \"badvalue\"}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("42", results[0]);
}

test "jq:L168 ._foo_._bar_" {
    const results = runFilter(
        ".\"foo\".\"bar\"",
        "{\"foo\": {\"bar\": 20}}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("20", results[0]);
}

test "jq:L172 .e0, .E1, .E-1, .E+1" {
    const results = runFilter(
        ".e0, .E1, .E-1, .E+1",
        "{\"e0\": 1, \"E1\": 2, \"E\": 3}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("2", results[1]);
    try std.testing.expectEqualStrings("2", results[2]);
    try std.testing.expectEqualStrings("4", results[3]);
}

test "jq:L179 [.[]|.foo?]" {
    const results = runFilter(
        "[.[]|.foo?]",
        "[1,[2],{\"foo\":3,\"bar\":4},{},{\"foo\":5}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[3,null,5]", results[0]);
}

test "jq:L183 [.[]|.foo?.bar?]" {
    const results = runFilter(
        "[.[]|.foo?.bar?]",
        "[1,[2],[],{\"foo\":3},{\"foo\":{\"bar\":4}},{}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[4,null]", results[0]);
}

test "jq:L187 [..]" {
    const results = runFilter(
        "[..]",
        "[1,[[2]],{ \"a\":[1]}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[1,[[2]],{\"a\":[1]}],1,[[2]],[2],2,{\"a\":[1]},[1],1]", results[0]);
}

test "jq:L191 [.[]|.[]?]" {
    const results = runFilter(
        "[.[]|.[]?]",
        "[1,null,[],[1,[2,[[3]]]],[{}],[{\"a\":[1,[2]]}]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,[2,[[3]]],{},{\"a\":[1,[2]]}]", results[0]);
}

test "jq:L195 [.[]|.[1:3]?]" {
    const results = runFilter(
        "[.[]|.[1:3]?]",
        "[1,null,true,false,\"abcdef\",{},{\"a\":1,\"b\":2},[],[1,2,3,4,5],[1,2]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,\"bc\",[],[2,3],[2]]", results[0]);
}

test "jq:L200 map(try .a[] catch ., try .a.[] catch ., .a[]?, .a.[]?)" {
    const results = runFilter(
        "map(try .a[] catch ., try .a.[] catch ., .a[]?, .a.[]?)",
        "[{\"a\": [1,2]}, {\"a\": 123}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,1,2,1,2,1,2,\"Cannot iterate over number (123)\",\"Cannot iterate over number (123)\"]", results[0]);
}

test "jq:L205 try [_OK_, (.[] | error)] catch [_KO_, .]" {
    const results = runFilter(
        "try [\"OK\", (.[] | error)] catch [\"KO\", .]",
        "{\"a\":[\"b\"],\"c\":[\"d\"]}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"KO\",[\"b\"]]", results[0]);
}

test "jq:L213 try (.foo[-1] = 0) catch ." {
    const results = runFilter(
        "try (.foo[-1] = 0) catch .",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Out of bounds negative array index\"", results[0]);
}

test "jq:L217 try (.foo[-2] = 0) catch ." {
    const results = runFilter(
        "try (.foo[-2] = 0) catch .",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Out of bounds negative array index\"", results[0]);
}

test "jq:L221 .[-1] = 5" {
    const results = runFilter(
        ".[-1] = 5",
        "[0,1,2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,5]", results[0]);
}

test "jq:L225 .[-2] = 5" {
    const results = runFilter(
        ".[-2] = 5",
        "[0,1,2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,5,2]", results[0]);
}

test "jq:L229 try (.[999999999] = 0) catch ." {
    const results = runFilter(
        "try (.[999999999] = 0) catch .",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Array index too large\"", results[0]);
}

test "jq:L237 .[]" {
    const results = runFilter(
        ".[]",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("2", results[1]);
    try std.testing.expectEqualStrings("3", results[2]);
}

test "jq:L243 1,1" {
    const results = runFilter(
        "1,1",
        "[]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("1", results[1]);
}

test "jq:L248 1,." {
    const results = runFilter(
        "1,.",
        "[]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("[]", results[1]);
}

test "jq:L253 [.]" {
    const results = runFilter(
        "[.]",
        "[2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[2]]", results[0]);
}

test "jq:L257 [[2]]" {
    const results = runFilter(
        "[[2]]",
        "[3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[2]]", results[0]);
}

test "jq:L261 [{}]" {
    const results = runFilter(
        "[{}]",
        "[2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[{}]", results[0]);
}

test "jq:L265 [.[]]" {
    const results = runFilter(
        "[.[]]",
        "[\"a\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\"]", results[0]);
}

test "jq:L269 [(.,1),((.,.[]),(2,3))]" {
    const results = runFilter(
        "[(.,1),((.,.[]),(2,3))]",
        "[\"a\",\"b\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[\"a\",\"b\"],1,[\"a\",\"b\"],\"a\",\"b\",2,3]", results[0]);
}

test "jq:L273 [([5,5][]),.,.[]]" {
    const results = runFilter(
        "[([5,5][]),.,.[]]",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[5,5,[1,2,3],1,2,3]", results[0]);
}

test "jq:L277 {x: (1,2)},{x:3} | .x" {
    const results = runFilter(
        "{x: (1,2)},{x:3} | .x",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("2", results[1]);
    try std.testing.expectEqualStrings("3", results[2]);
}

test "jq:L283 [.[-4,-3,-2,-1,0,1,2,3]]" {
    const results = runFilter(
        "[.[-4,-3,-2,-1,0,1,2,3]]",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,1,2,3,1,2,3,null]", results[0]);
}

test "jq:L287 [range(0;10)]" {
    const results = runFilter(
        "[range(0;10)]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,3,4,5,6,7,8,9]", results[0]);
}

test "jq:L291 [range(0,1;3,4)]" {
    const results = runFilter(
        "[range(0,1;3,4)]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2, 0,1,2,3, 1,2, 1,2,3]", results[0]);
}

test "jq:L295 [range(0;10;3)]" {
    const results = runFilter(
        "[range(0;10;3)]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,3,6,9]", results[0]);
}

test "jq:L299 [range(0;10;-1)]" {
    const results = runFilter(
        "[range(0;10;-1)]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L303 [range(0;-5;-1)]" {
    const results = runFilter(
        "[range(0;-5;-1)]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,-1,-2,-3,-4]", results[0]);
}

test "jq:L307 [range(0,1;4,5;1,2)]" {
    const results = runFilter(
        "[range(0,1;4,5;1,2)]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,3,0,2, 0,1,2,3,4,0,2,4, 1,2,3,1,3, 1,2,3,4,1,3]", results[0]);
}

test "jq:L311 [while(.<100; .*2)]" {
    const results = runFilter(
        "[while(.<100; .*2)]",
        "1",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,4,8,16,32,64]", results[0]);
}

test "jq:L315 [(label $here | .[] | if .>1 then break $here else . end)..." {
    const results = runFilter(
        "[(label $here | .[] | if .>1 then break $here else . end), \"hi!\"]",
        "[0,1,2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,\"hi!\"]", results[0]);
}

test "jq:L319 [(label $here | .[] | if .>1 then break $here else . end)..." {
    const results = runFilter(
        "[(label $here | .[] | if .>1 then break $here else . end), \"hi!\"]",
        "[0,2,1]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,\"hi!\"]", results[0]);
}

test "jq:L323 . as $foo | break $foo" {
    // %%FAIL: filter should not compile
    try expectCompileError(". as $foo | break $foo");
}

test "jq:L329 [.[]|[.,1]|until(.[0] < 1; [.[0] - 1, .[1] * .[0]])|.[1]]" {
    const results = runFilter(
        "[.[]|[.,1]|until(.[0] < 1; [.[0] - 1, .[1] * .[0]])|.[1]]",
        "[1,2,3,4,5]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,6,24,120]", results[0]);
}

test "jq:L333 [label $out | foreach .[] as $item ([3, null]; if .[0] < ..." {
    const results = runFilter(
        "[label $out | foreach .[] as $item ([3, null]; if .[0] < 1 then break $out else [.[0] -1, $item] end; .[1])]",
        "[11,22,33,44,55,66,77,88,99]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[11,22,33]", results[0]);
}

test "jq:L337 [foreach range(5) as $item (0; $item)]" {
    const results = runFilter(
        "[foreach range(5) as $item (0; $item)]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,3,4]", results[0]);
}

test "jq:L341 [foreach .[] as [$i, $j] (0; . + $i - $j)]" {
    const results = runFilter(
        "[foreach .[] as [$i, $j] (0; . + $i - $j)]",
        "[[2,1], [5,3], [6,4]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,3,5]", results[0]);
}

test "jq:L345 [foreach .[] as {a:$a} (0; . + $a; -.)]" {
    const results = runFilter(
        "[foreach .[] as {a:$a} (0; . + $a; -.)]",
        "[{\"a\":1}, {\"b\":2}, {\"a\":3, \"b\":4}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[-1, -1, -4]", results[0]);
}

test "jq:L349 [-foreach -.[] as $x (0; . + $x)]" {
    const results = runFilter(
        "[-foreach -.[] as $x (0; . + $x)]",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,3,6]", results[0]);
}

test "jq:L353 [foreach .[] / .[] as $i (0; . + $i)]" {
    const results = runFilter(
        "[foreach .[] / .[] as $i (0; . + $i)]",
        "[1,2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,3,3.5,4.5]", results[0]);
}

test "jq:L357 [foreach .[] as $x (0; . + $x) as $x | $x]" {
    const results = runFilter(
        "[foreach .[] as $x (0; . + $x) as $x | $x]",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,3,6]", results[0]);
}

test "jq:L361 [limit(3; .[])]" {
    const results = runFilter(
        "[limit(3; .[])]",
        "[11,22,33,44,55,66,77,88,99]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[11,22,33]", results[0]);
}

test "jq:L365 [limit(0; error)]" {
    const results = runFilter(
        "[limit(0; error)]",
        "\"badness\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L369 [limit(1; 1, error)]" {
    const results = runFilter(
        "[limit(1; 1, error)]",
        "\"badness\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1]", results[0]);
}

test "jq:L373 try limit(-1; error) catch ." {
    const results = runFilter(
        "try limit(-1; error) catch .",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"limit doesn't support negative count\"", results[0]);
}

test "jq:L377 [skip(3; .[])]" {
    const results = runFilter(
        "[skip(3; .[])]",
        "[1,2,3,4,5,6,7,8,9]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[4,5,6,7,8,9]", results[0]);
}

test "jq:L381 [skip(0,2,3,4; .[])]" {
    const results = runFilter(
        "[skip(0,2,3,4; .[])]",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3,3]", results[0]);
}

test "jq:L385 [skip(3; .[])]" {
    const results = runFilter(
        "[skip(3; .[])]",
        "[]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L389 try skip(-1; error) catch ." {
    const results = runFilter(
        "try skip(-1; error) catch .",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"skip doesn't support negative count\"", results[0]);
}

test "jq:L393 nth(1; 0,1,error(_foo_))" {
    const results = runFilter(
        "nth(1; 0,1,error(\"foo\"))",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L397 [first(range(.)), last(range(.))]" {
    const results = runFilter(
        "[first(range(.)), last(range(.))]",
        "10",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,9]", results[0]);
}

test "jq:L401 [first(range(.)), last(range(.))]" {
    const results = runFilter(
        "[first(range(.)), last(range(.))]",
        "0",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L405 [nth(0,5,9,10,15; range(.)), try nth(-1; range(.)) catch .]" {
    const results = runFilter(
        "[nth(0,5,9,10,15; range(.)), try nth(-1; range(.)) catch .]",
        "10",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,5,9,\"nth doesn't support negative indices\"]", results[0]);
}

test "jq:L410 first(1,error(_foo_))" {
    const results = runFilter(
        "first(1,error(\"foo\"))",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L420 [limit(5,7; range(9))]" {
    const results = runFilter(
        "[limit(5,7; range(9))]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,3,4,0,1,2,3,4,5,6]", results[0]);
}

test "jq:L425 [nth(5,7; range(9;0;-1))]" {
    const results = runFilter(
        "[nth(5,7; range(9;0;-1))]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[4,2]", results[0]);
}

test "jq:L430 [range(0,1,2;4,3,2;2,3)]" {
    const results = runFilter(
        "[range(0,1,2;4,3,2;2,3)]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,2,0,3,0,2,0,0,0,1,3,1,1,1,1,1,2,2,2,2]", results[0]);
}

test "jq:L435 [range(3,5)]" {
    const results = runFilter(
        "[range(3,5)]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,0,1,2,3,4]", results[0]);
}

test "jq:L440 [(index(_,_,_|_), rindex(_,_,_|_)), indices(_,_,_|_)]" {
    const results = runFilter(
        "[(index(\",\",\"|\"), rindex(\",\",\"|\")), indices(\",\",\"|\")]",
        "\"a,b|c,d,e||f,g,h,|,|,i,j\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,3,22,19,[1,5,7,12,14,16,18,20,22],[3,9,10,17,19]]", results[0]);
}

test "jq:L445 join(_,_,_/_)" {
    const results = runFilter(
        "join(\",\",\"/\")",
        "[\"a\",\"b\",\"c\",\"d\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("\"a,b,c,d\"", results[0]);
    try std.testing.expectEqualStrings("\"a/b/c/d\"", results[1]);
}

test "jq:L450 [.[]|join(_a_)]" {
    const results = runFilter(
        "[.[]|join(\"a\")]",
        "[[],[\"\"],[\"\",\"\"],[\"\",\"\",\"\"]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"\",\"\",\"a\",\"aa\"]", results[0]);
}

test "jq:L455 flatten(3,2,1)" {
    const results = runFilter(
        "flatten(3,2,1)",
        "[0, [1], [[2]], [[[3]]]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("[0,1,2,3]", results[0]);
    try std.testing.expectEqualStrings("[0,1,2,[3]]", results[1]);
    try std.testing.expectEqualStrings("[0,1,[2],[[3]]]", results[2]);
}

test "jq:L466 [.[3:2], .[-5:4], .[:-2], .[-2:], .[3:3][1:], .[10:]]" {
    const results = runFilter(
        "[.[3:2], .[-5:4], .[:-2], .[-2:], .[3:3][1:], .[10:]]",
        "[0,1,2,3,4,5,6]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[], [2,3], [0,1,2,3,4], [5,6], [], []]", results[0]);
}

test "jq:L470 [.[3:2], .[-5:4], .[:-2], .[-2:], .[3:3][1:], .[10:]]" {
    const results = runFilter(
        "[.[3:2], .[-5:4], .[:-2], .[-2:], .[3:3][1:], .[10:]]",
        "\"abcdefghi\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"\",\"\",\"abcdefg\",\"hi\",\"\",\"\"]", results[0]);
}

test "jq:L474 del(.[2:4],.[0],.[-2:])" {
    const results = runFilter(
        "del(.[2:4],.[0],.[-2:])",
        "[0,1,2,3,4,5,6,7]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,4,5]", results[0]);
}

test "jq:L478 .[2:4] = ([], [_a_,_b_], [_a_,_b_,_c_])" {
    const results = runFilter(
        ".[2:4] = ([], [\"a\",\"b\"], [\"a\",\"b\",\"c\"])",
        "[0,1,2,3,4,5,6,7]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("[0,1,4,5,6,7]", results[0]);
    try std.testing.expectEqualStrings("[0,1,\"a\",\"b\",4,5,6,7]", results[1]);
    try std.testing.expectEqualStrings("[0,1,\"a\",\"b\",\"c\",4,5,6,7]", results[2]);
}

test "jq:L490 reduce range(65540;65536;-1) as $i ([]; .[$i] = $i)|.[655..." {
    const results = runFilter(
        "reduce range(65540;65536;-1) as $i ([]; .[$i] = $i)|.[65536:]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,65537,65538,65539,65540]", results[0]);
}

test "jq:L498 1 as $x | 2 as $y | [$x,$y,$x]" {
    const results = runFilter(
        "1 as $x | 2 as $y | [$x,$y,$x]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,1]", results[0]);
}

test "jq:L502 [1,2,3][] as $x | [[4,5,6,7][$x]]" {
    const results = runFilter(
        "[1,2,3][] as $x | [[4,5,6,7][$x]]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("[5]", results[0]);
    try std.testing.expectEqualStrings("[6]", results[1]);
    try std.testing.expectEqualStrings("[7]", results[2]);
}

test "jq:L508 42 as $x | . | . | . + 432 | $x + 1" {
    const results = runFilter(
        "42 as $x | . | . | . + 432 | $x + 1",
        "34324",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("43", results[0]);
}

test "jq:L512 1 + 2 as $x | -$x" {
    const results = runFilter(
        "1 + 2 as $x | -$x",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("-3", results[0]);
}

test "jq:L516 _x_ as $x | _a_+_y_ as $y | $x+_,_+$y" {
    const results = runFilter(
        "\"x\" as $x | \"a\"+\"y\" as $y | $x+\",\"+$y",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"x,ay\"", results[0]);
}

test "jq:L520 1 as $x | [$x,$x,$x as $x | $x]" {
    const results = runFilter(
        "1 as $x | [$x,$x,$x as $x | $x]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,1,1]", results[0]);
}

test "jq:L524 [1, {c:3, d:4}] as [$a, {c:$b, b:$c}] | $a, $b, $c" {
    const results = runFilter(
        "[1, {c:3, d:4}] as [$a, {c:$b, b:$c}] | $a, $b, $c",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("3", results[1]);
    try std.testing.expectEqualStrings("null", results[2]);
}

test "jq:L530 . as {as: $kw, _str_: $str, (_e_+_x_+_p_): $exp} | [$kw, ..." {
    const results = runFilter(
        ". as {as: $kw, \"str\": $str, (\"e\"+\"x\"+\"p\"): $exp} | [$kw, $str, $exp]",
        "{\"as\": 1, \"str\": 2, \"exp\": 3}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1, 2, 3]", results[0]);
}

test "jq:L534 .[] as [$a, $b] | [$b, $a]" {
    const results = runFilter(
        ".[] as [$a, $b] | [$b, $a]",
        "[[1], [1, 2, 3]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("[null, 1]", results[0]);
    try std.testing.expectEqualStrings("[2, 1]", results[1]);
}

test "jq:L539 . as $i | . as [$i] | $i" {
    const results = runFilter(
        ". as $i | . as [$i] | $i",
        "[0]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("0", results[0]);
}

test "jq:L543 . as [$i] | . as $i | $i" {
    const results = runFilter(
        ". as [$i] | . as $i | $i",
        "[0]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0]", results[0]);
}

test "jq:L547 . as [] | null" {
    // %%FAIL: filter should not compile
    try expectCompileError(". as [] | null");
}

test "jq:L553 . as {} | null" {
    // %%FAIL: filter should not compile
    try expectCompileError(". as {} | null");
}

test "jq:L559 . as $foo | [$foo, $bar]" {
    // %%FAIL: filter should not compile
    try expectCompileError(". as $foo | [$foo, $bar]");
}

test "jq:L565 . as {(true):$foo} | $foo" {
    // %%FAIL: filter should not compile
    try expectCompileError(". as {(true):$foo} | $foo");
}

test "jq:L577 1+1" {
    const results = runFilter(
        "1+1",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("2", results[0]);
}

test "jq:L581 1+1" {
    const results = runFilter(
        "1+1",
        "\"wtasdf\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("2.0", results[0]);
}

test "jq:L585 2-1" {
    const results = runFilter(
        "2-1",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L589 2-(-1)" {
    const results = runFilter(
        "2-(-1)",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("3", results[0]);
}

test "jq:L593 1e+0+0.001e3" {
    const results = runFilter(
        "1e+0+0.001e3",
        "\"I wonder what this will be?\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("20e-1", results[0]);
}

test "jq:L597 .+4" {
    const results = runFilter(
        ".+4",
        "15",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("19.0", results[0]);
}

test "jq:L601 .+null" {
    const results = runFilter(
        ".+null",
        "{\"a\":42}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":42}", results[0]);
}

test "jq:L605 null+." {
    const results = runFilter(
        "null+.",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq:L609 .a+.b" {
    const results = runFilter(
        ".a+.b",
        "{\"a\":42}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("42", results[0]);
}

test "jq:L613 [1,2,3] + [.]" {
    const results = runFilter(
        "[1,2,3] + [.]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3,null]", results[0]);
}

test "jq:L617 {_a_:1} + {_b_:2} + {_c_:3}" {
    const results = runFilter(
        "{\"a\":1} + {\"b\":2} + {\"c\":3}",
        "\"asdfasdf\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":1, \"b\":2, \"c\":3}", results[0]);
}

test "jq:L621 _asdf_ + _jkl;_ + . + . + ." {
    const results = runFilter(
        "\"asdf\" + \"jkl;\" + . + . + .",
        "\"some string\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"asdfjkl;some stringsome stringsome string\"", results[0]);
}

test "jq:L625 __u0000_u0020_u0000_ + ." {
    const results = runFilter(
        "\"\\u0000\\u0020\\u0000\" + .",
        "\"\\u0000\\u0020\\u0000\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"\\u0000 \\u0000\\u0000 \\u0000\"", results[0]);
}

test "jq:L629 42 - ." {
    const results = runFilter(
        "42 - .",
        "11",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("31", results[0]);
}

test "jq:L633 [1,2,3,4,1] - [.,3]" {
    const results = runFilter(
        "[1,2,3,4,1] - [.,3]",
        "1",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[2,4]", results[0]);
}

test "jq:L637 [-1 as $x | 1,$x]" {
    const results = runFilter(
        "[-1 as $x | 1,$x]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,-1]", results[0]);
}

test "jq:L641 [10 * 20, 20 / .]" {
    const results = runFilter(
        "[10 * 20, 20 / .]",
        "4",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[200, 5]", results[0]);
}

test "jq:L645 1 + 2 * 2 + 10 / 2" {
    const results = runFilter(
        "1 + 2 * 2 + 10 / 2",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("10", results[0]);
}

test "jq:L649 [16 / 4 / 2, 16 / 4 * 2, 16 - 4 - 2, 16 - 4 + 2]" {
    const results = runFilter(
        "[16 / 4 / 2, 16 / 4 * 2, 16 - 4 - 2, 16 - 4 + 2]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[2, 8, 10, 14]", results[0]);
}

test "jq:L653 1e-19 + 1e-20 - 5e-21" {
    const results = runFilter(
        "1e-19 + 1e-20 - 5e-21",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1.05e-19", results[0]);
}

test "jq:L657 1 / 1e-17" {
    const results = runFilter(
        "1 / 1e-17",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1e+17", results[0]);
}

test "jq:L661 9E999999999, 9999999999E999999990, 1E-999999999, 0.000000..." {
    const results = runFilter(
        "9E999999999, 9999999999E999999990, 1E-999999999, 0.000000001E-999999990",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("9E+999999999", results[0]);
    try std.testing.expectEqualStrings("9.999999999E+999999999", results[1]);
    try std.testing.expectEqualStrings("1E-999999999", results[2]);
    try std.testing.expectEqualStrings("1E-999999999", results[3]);
}

test "jq:L668 5E500000000 > 5E-5000000000, 10000E500000000 > 10000E-500..." {
    const results = runFilter(
        "5E500000000 > 5E-5000000000, 10000E500000000 > 10000E-5000000000",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
    try std.testing.expectEqualStrings("true", results[1]);
}

test "jq:L674 (1e999999999, 10e999999999) > (1e-1147483646, 0.1e-114748..." {
    const results = runFilter(
        "(1e999999999, 10e999999999) > (1e-1147483646, 0.1e-1147483646)",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
    try std.testing.expectEqualStrings("true", results[1]);
    try std.testing.expectEqualStrings("true", results[2]);
    try std.testing.expectEqualStrings("true", results[3]);
}

test "jq:L681 25 % 7" {
    const results = runFilter(
        "25 % 7",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("4", results[0]);
}

test "jq:L685 49732 % 472" {
    const results = runFilter(
        "49732 % 472",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("172", results[0]);
}

test "jq:L689 [(infinite, -infinite) % (1, -1, infinite)]" {
    const results = runFilter(
        "[(infinite, -infinite) % (1, -1, infinite)]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,0,0,0,0,-1]", results[0]);
}

test "jq:L693 [nan % 1, 1 % nan | isnan]" {
    const results = runFilter(
        "[nan % 1, 1 % nan | isnan]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,true]", results[0]);
}

test "jq:L697 1 + tonumber + (_10_ | tonumber)" {
    const results = runFilter(
        "1 + tonumber + (\"10\" | tonumber)",
        "4",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("15", results[0]);
}

test "jq:L701 _123_u0000456_ | try tonumber catch ." {
    const results = runFilter(
        "\"123\\u0000456\" | try tonumber catch .",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"string (\\\"123\\\\u0000456\\\") cannot be parsed as a number\"", results[0]);
}

test "jq:L705 map(toboolean)" {
    const results = runFilter(
        "map(toboolean)",
        "[\"false\",\"true\",false,true]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false,true,false,true]", results[0]);
}

test "jq:L709 .[] | try toboolean catch ." {
    const results = runFilter(
        ".[] | try toboolean catch .",
        "[null,0,\"tru\",\"truee\",\"fals\",\"falsee\",[],{}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 8), results.len);
    try std.testing.expectEqualStrings("\"null (null) cannot be parsed as a boolean\"", results[0]);
    try std.testing.expectEqualStrings("\"number (0) cannot be parsed as a boolean\"", results[1]);
    try std.testing.expectEqualStrings("\"string (\\\"tru\\\") cannot be parsed as a boolean\"", results[2]);
    try std.testing.expectEqualStrings("\"string (\\\"truee\\\") cannot be parsed as a boolean\"", results[3]);
    try std.testing.expectEqualStrings("\"string (\\\"fals\\\") cannot be parsed as a boolean\"", results[4]);
    try std.testing.expectEqualStrings("\"string (\\\"falsee\\\") cannot be parsed as a boolean\"", results[5]);
    try std.testing.expectEqualStrings("\"array ([]) cannot be parsed as a boolean\"", results[6]);
    try std.testing.expectEqualStrings("\"object ({}) cannot be parsed as a boolean\"", results[7]);
}

test "jq:L720 _true_u0000x_, _false_u0000_ | try toboolean catch ." {
    const results = runFilter(
        "\"true\\u0000x\", \"false\\u0000\" | try toboolean catch .",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("\"string (\\\"true\\\\u0000x\\\") cannot be parsed as a boolean\"", results[0]);
    try std.testing.expectEqualStrings("\"string (\\\"false\\\\u0000\\\") cannot be parsed as a boolean\"", results[1]);
}

test "jq:L725 [{_a_:42},.object,10,.num,false,true,null,_b_,[1,4]] | .[..." {
    const results = runFilter(
        "[{\"a\":42},.object,10,.num,false,true,null,\"b\",[1,4]] | .[] as $x | [$x == .[]]",
        "{\"object\": {\"a\":42}, \"num\":10.0}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 9), results.len);
    try std.testing.expectEqualStrings("[true,  true,  false, false, false, false, false, false, false]", results[0]);
    try std.testing.expectEqualStrings("[true,  true,  false, false, false, false, false, false, false]", results[1]);
    try std.testing.expectEqualStrings("[false, false, true,  true,  false, false, false, false, false]", results[2]);
    try std.testing.expectEqualStrings("[false, false, true,  true,  false, false, false, false, false]", results[3]);
    try std.testing.expectEqualStrings("[false, false, false, false, true,  false, false, false, false]", results[4]);
    try std.testing.expectEqualStrings("[false, false, false, false, false, true,  false, false, false]", results[5]);
    try std.testing.expectEqualStrings("[false, false, false, false, false, false, true,  false, false]", results[6]);
    try std.testing.expectEqualStrings("[false, false, false, false, false, false, false, true,  false]", results[7]);
    try std.testing.expectEqualStrings("[false, false, false, false, false, false, false, false, true ]", results[8]);
}

test "jq:L737 [.[] | length]" {
    const results = runFilter(
        "[.[] | length]",
        "[[], {}, [1,2], {\"a\":42}, \"asdf\", \"\\u03bc\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0, 0, 2, 1, 4, 1]", results[0]);
}

test "jq:L741 utf8bytelength" {
    const results = runFilter(
        "utf8bytelength",
        "\"asdf\\u03bc\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("6", results[0]);
}

test "jq:L745 [.[] | try utf8bytelength catch .]" {
    const results = runFilter(
        "[.[] | try utf8bytelength catch .]",
        "[[], {}, [1,2], 55, true, false]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"array ([]) only strings have UTF-8 byte length\",\"object ({}) only strings have UTF-8 byte length\",\"array ([1,2]) only strings have UTF-8 byte length\",\"number (55) only strings have UTF-8 byte length\",\"boolean (true) only strings have UTF-8 byte length\",\"boolean (false) only strings have UTF-8 byte length\"]", results[0]);
}

test "jq:L750 map(keys)" {
    const results = runFilter(
        "map(keys)",
        "[{}, {\"abcd\":1,\"abc\":2,\"abcde\":3}, {\"x\":1, \"z\": 3, \"y\":2}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[], [\"abc\",\"abcd\",\"abcde\"], [\"x\",\"y\",\"z\"]]", results[0]);
}

test "jq:L754 [1,2,empty,3,empty,4]" {
    const results = runFilter(
        "[1,2,empty,3,empty,4]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3,4]", results[0]);
}

test "jq:L758 map(add)" {
    const results = runFilter(
        "map(add)",
        "[[], [1,2,3], [\"a\",\"b\",\"c\"], [[3],[4,5],[6]], [{\"a\":1}, {\"b\":2}, {\"a\":3}]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null, 6, \"abc\", [3,4,5,6], {\"a\":3, \"b\": 2}]", results[0]);
}

test "jq:L762 map_values(.+1)" {
    const results = runFilter(
        "map_values(.+1)",
        "[0,1,2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L766 [add(null), add(range(range(10))), add(empty), add(10,ran..." {
    const results = runFilter(
        "[add(null), add(range(range(10))), add(empty), add(10,range(10))]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,120,null,55]", results[0]);
}

test "jq:L771 .sum = add(.arr[])" {
    const results = runFilter(
        ".sum = add(.arr[])",
        "{\"arr\":[]}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"arr\":[],\"sum\":null}", results[0]);
}

test "jq:L775 add({(.[]):1}) | keys" {
    const results = runFilter(
        "add({(.[]):1}) | keys",
        "[\"a\",\"a\",\"b\",\"a\",\"d\",\"b\",\"d\",\"a\",\"d\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\",\"b\",\"d\"]", results[0]);
}

test "jq:L784 def f: . + 1; def g: def g: . + 100; f | g | f; (f | g), g" {
    const results = runFilter(
        "def f: . + 1; def g: def g: . + 100; f | g | f; (f | g), g",
        "3.0",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("106.0", results[0]);
    try std.testing.expectEqualStrings("105.0", results[1]);
}

test "jq:L789 def f: (1000,2000); f" {
    const results = runFilter(
        "def f: (1000,2000); f",
        "123412345",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("1000", results[0]);
    try std.testing.expectEqualStrings("2000", results[1]);
}

test "jq:L794 def f(a;b;c;d;e;f): [a+1,b,c,d,e,f]; f(.[0];.[1];.[0];.[0..." {
    const results = runFilter(
        "def f(a;b;c;d;e;f): [a+1,b,c,d,e,f]; f(.[0];.[1];.[0];.[0];.[0];.[0])",
        "[1,2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[2,2,1,1,1,1]", results[0]);
}

test "jq:L798 def f: 1; def g: f, def f: 2; def g: 3; f, def f: g; f, g..." {
    const results = runFilter(
        "def f: 1; def g: f, def f: 2; def g: 3; f, def f: g; f, g; def f: 4; [f, def f: g; def g: 5; f, g]+[f,g]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[4,1,2,3,3,5,4,1,2,3,3]", results[0]);
}

test "jq:L803 def a: 0; . | a" {
    const results = runFilter(
        "def a: 0; . | a",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("0", results[0]);
}

test "jq:L808 def f(a;b;c;d;e;f;g;h;i;j): [j,i,h,g,f,e,d,c,b,a]; f(.[0]..." {
    const results = runFilter(
        "def f(a;b;c;d;e;f;g;h;i;j): [j,i,h,g,f,e,d,c,b,a]; f(.[0];.[1];.[2];.[3];.[4];.[5];.[6];.[7];.[8];.[9])",
        "[0,1,2,3,4,5,6,7,8,9]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[9,8,7,6,5,4,3,2,1,0]", results[0]);
}

test "jq:L812 ([1,2] + [4,5])" {
    const results = runFilter(
        "([1,2] + [4,5])",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,4,5]", results[0]);
}

test "jq:L816 true" {
    const results = runFilter(
        "true",
        "[1]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L820 null,1,null" {
    const results = runFilter(
        "null,1,null",
        "\"hello\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
    try std.testing.expectEqualStrings("1", results[1]);
    try std.testing.expectEqualStrings("null", results[2]);
}

test "jq:L826 [1,2,3]" {
    const results = runFilter(
        "[1,2,3]",
        "[5,6]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L830 [.[]|floor]" {
    const results = runFilter(
        "[.[]|floor]",
        "[-1.1,1.1,1.9]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[-2, 1, 1]", results[0]);
}

test "jq:L834 [.[]|sqrt]" {
    const results = runFilter(
        "[.[]|sqrt]",
        "[4,9]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[2,3]", results[0]);
}

test "jq:L838 (add / length) as $m | map((. - $m) as $d | $d * $d) | ad..." {
    const results = runFilter(
        "(add / length) as $m | map((. - $m) as $d | $d * $d) | add / length | sqrt",
        "[2,4,4,4,5,5,7,9]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("2", results[0]);
}

test "jq:L847 atan * 4 * 1000000|floor / 1000000" {
    const results = runFilter(
        "atan * 4 * 1000000|floor / 1000000",
        "1",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("3.141592", results[0]);
}

test "jq:L851 [(3.141592 / 2) * (range(0;20) / 20)|cos * 1000000|floor ..." {
    const results = runFilter(
        "[(3.141592 / 2) * (range(0;20) / 20)|cos * 1000000|floor / 1000000]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,0.996917,0.987688,0.972369,0.951056,0.923879,0.891006,0.85264,0.809017,0.760406,0.707106,0.649448,0.587785,0.522498,0.45399,0.382683,0.309017,0.233445,0.156434,0.078459]", results[0]);
}

test "jq:L855 [(3.141592 / 2) * (range(0;20) / 20)|sin * 1000000|floor ..." {
    const results = runFilter(
        "[(3.141592 / 2) * (range(0;20) / 20)|sin * 1000000|floor / 1000000]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,0.078459,0.156434,0.233445,0.309016,0.382683,0.45399,0.522498,0.587785,0.649447,0.707106,0.760405,0.809016,0.85264,0.891006,0.923879,0.951056,0.972369,0.987688,0.996917]", results[0]);
}

test "jq:L860 def f(x): x | x; f([.], . + [42])" {
    const results = runFilter(
        "def f(x): x | x; f([.], . + [42])",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[[[1,2,3]]]", results[0]);
    try std.testing.expectEqualStrings("[[1,2,3],42]", results[1]);
    try std.testing.expectEqualStrings("[[1,2,3,42]]", results[2]);
    try std.testing.expectEqualStrings("[1,2,3,42,42]", results[3]);
}

test "jq:L868 def f: .+1; def g: f; def f: .+100; def f(a):a+.+11; [(g|..." {
    const results = runFilter(
        "def f: .+1; def g: f; def f: .+100; def f(a):a+.+11; [(g|f(20)), f]",
        "1",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[33,101]", results[0]);
}

test "jq:L873 def id(x):x; 2000 as $x | def f(x):1 as $x | id([$x, x, x..." {
    const results = runFilter(
        "def id(x):x; 2000 as $x | def f(x):1 as $x | id([$x, x, x]); def g(x): 100 as $x | f($x,$x+x); g($x)",
        "\"more testing\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,100,2100.0,100,2100.0]", results[0]);
}

test "jq:L878 def x(a;b): a as $a | b as $b | $a + $b; def y($a;$b): $a..." {
    const results = runFilter(
        "def x(a;b): a as $a | b as $b | $a + $b; def y($a;$b): $a + $b; def check(a;b): [x(a;b)] == [y(a;b)]; check(.[];.[]*2)",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L884 [[20,10][1,0] as $x | def f: (100,200) as $y | def g: [$x..." {
    const results = runFilter(
        "[[20,10][1,0] as $x | def f: (100,200) as $y | def g: [$x + $y, .]; . + $x | g; f[0] | [f][0][1] | f]",
        "999999999",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[110.0, 130.0], [210.0, 130.0], [110.0, 230.0], [210.0, 230.0], [120.0, 160.0], [220.0, 160.0], [120.0, 260.0], [220.0, 260.0]]", results[0]);
}

test "jq:L889 def fac: if . == 1 then 1 else . * (. - 1 | fac) end; [.[..." {
    const results = runFilter(
        "def fac: if . == 1 then 1 else . * (. - 1 | fac) end; [.[] | fac]",
        "[1,2,3,4]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,6,24]", results[0]);
}

test "jq:L899 reduce .[] as $x (0; . + $x)" {
    const results = runFilter(
        "reduce .[] as $x (0; . + $x)",
        "[1,2,4]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("7", results[0]);
}

test "jq:L903 reduce .[] as [$i, {j:$j}] (0; . + $i - $j)" {
    const results = runFilter(
        "reduce .[] as [$i, {j:$j}] (0; . + $i - $j)",
        "[[2,{\"j\":1}], [5,{\"j\":3}], [6,{\"j\":4}]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("5", results[0]);
}

test "jq:L907 reduce [[1,2,10], [3,4,10]][] as [$i,$j] (0; . + $i * $j)" {
    const results = runFilter(
        "reduce [[1,2,10], [3,4,10]][] as [$i,$j] (0; . + $i * $j)",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("14", results[0]);
}

test "jq:L911 [-reduce -.[] as $x (0; . + $x)]" {
    const results = runFilter(
        "[-reduce -.[] as $x (0; . + $x)]",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[6]", results[0]);
}

test "jq:L915 [reduce .[] / .[] as $i (0; . + $i)]" {
    const results = runFilter(
        "[reduce .[] / .[] as $i (0; . + $i)]",
        "[1,2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[4.5]", results[0]);
}

test "jq:L919 reduce .[] as $x (0; . + $x) as $x | $x" {
    const results = runFilter(
        "reduce .[] as $x (0; . + $x) as $x | $x",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("6", results[0]);
}

test "jq:L924 reduce . as $n (.; .)" {
    const results = runFilter(
        "reduce . as $n (.; .)",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq:L929 . as {$a, b: [$c, {$d}]} | [$a, $c, $d]" {
    const results = runFilter(
        ". as {$a, b: [$c, {$d}]} | [$a, $c, $d]",
        "{\"a\":1, \"b\":[2,{\"d\":3}]}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L933 . as {$a, $b:[$c, $d]}| [$a, $b, $c, $d]" {
    const results = runFilter(
        ". as {$a, $b:[$c, $d]}| [$a, $b, $c, $d]",
        "{\"a\":1, \"b\":[2,{\"d\":3}]}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,[2,{\"d\":3}],2,{\"d\":3}]", results[0]);
}

test "jq:L938 .[] | . as {$a, b: [$c, {$d}]} ?// [$a, {$b}, $e] ?// $f ..." {
    const results = runFilter(
        ".[] | . as {$a, b: [$c, {$d}]} ?// [$a, {$b}, $e] ?// $f | [$a, $b, $c, $d, $e, $f]",
        "[{\"a\":1, \"b\":[2,{\"d\":3}]}, [4, {\"b\":5, \"c\":6}, 7, 8, 9], \"foo\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("[1, null, 2, 3, null, null]", results[0]);
    try std.testing.expectEqualStrings("[4, 5, null, null, 7, null]", results[1]);
    try std.testing.expectEqualStrings("[null, null, null, null, null, \"foo\"]", results[2]);
}

test "jq:L945 .[] | . as {a:$a} ?// {a:$a} ?// {a:$a} | $a" {
    const results = runFilter(
        ".[] | . as {a:$a} ?// {a:$a} ?// {a:$a} | $a",
        "[[3],[4],[5],6]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:L949 .[] as {a:$a} ?// {a:$a} ?// {a:$a} | $a" {
    const results = runFilter(
        ".[] as {a:$a} ?// {a:$a} ?// {a:$a} | $a",
        "[[3],[4],[5],6]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:L953 [[3],[4],[5],6][] | . as {a:$a} ?// {a:$a} ?// {a:$a} | $a" {
    const results = runFilter(
        "[[3],[4],[5],6][] | . as {a:$a} ?// {a:$a} ?// {a:$a} | $a",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:L957 [[3],[4],[5],6] | .[] as {a:$a} ?// {a:$a} ?// {a:$a} | $a" {
    const results = runFilter(
        "[[3],[4],[5],6] | .[] as {a:$a} ?// {a:$a} ?// {a:$a} | $a",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:L961 .[] | . as {a:$a} ?// {a:$a} ?// $a | $a" {
    const results = runFilter(
        ".[] | . as {a:$a} ?// {a:$a} ?// $a | $a",
        "[[3],[4],[5],6]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[3]", results[0]);
    try std.testing.expectEqualStrings("[4]", results[1]);
    try std.testing.expectEqualStrings("[5]", results[2]);
    try std.testing.expectEqualStrings("6", results[3]);
}

test "jq:L968 .[] as {a:$a} ?// {a:$a} ?// $a | $a" {
    const results = runFilter(
        ".[] as {a:$a} ?// {a:$a} ?// $a | $a",
        "[[3],[4],[5],6]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[3]", results[0]);
    try std.testing.expectEqualStrings("[4]", results[1]);
    try std.testing.expectEqualStrings("[5]", results[2]);
    try std.testing.expectEqualStrings("6", results[3]);
}

test "jq:L975 [[3],[4],[5],6][] | . as {a:$a} ?// {a:$a} ?// $a | $a" {
    const results = runFilter(
        "[[3],[4],[5],6][] | . as {a:$a} ?// {a:$a} ?// $a | $a",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[3]", results[0]);
    try std.testing.expectEqualStrings("[4]", results[1]);
    try std.testing.expectEqualStrings("[5]", results[2]);
    try std.testing.expectEqualStrings("6", results[3]);
}

test "jq:L982 [[3],[4],[5],6] | .[] as {a:$a} ?// {a:$a} ?// $a | $a" {
    const results = runFilter(
        "[[3],[4],[5],6] | .[] as {a:$a} ?// {a:$a} ?// $a | $a",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[3]", results[0]);
    try std.testing.expectEqualStrings("[4]", results[1]);
    try std.testing.expectEqualStrings("[5]", results[2]);
    try std.testing.expectEqualStrings("6", results[3]);
}

test "jq:L989 .[] | . as {a:$a} ?// $a ?// {a:$a} | $a" {
    const results = runFilter(
        ".[] | . as {a:$a} ?// $a ?// {a:$a} | $a",
        "[[3],[4],[5],6]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[3]", results[0]);
    try std.testing.expectEqualStrings("[4]", results[1]);
    try std.testing.expectEqualStrings("[5]", results[2]);
    try std.testing.expectEqualStrings("6", results[3]);
}

test "jq:L996 .[] as {a:$a} ?// $a ?// {a:$a} | $a" {
    const results = runFilter(
        ".[] as {a:$a} ?// $a ?// {a:$a} | $a",
        "[[3],[4],[5],6]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[3]", results[0]);
    try std.testing.expectEqualStrings("[4]", results[1]);
    try std.testing.expectEqualStrings("[5]", results[2]);
    try std.testing.expectEqualStrings("6", results[3]);
}

test "jq:L1003 [[3],[4],[5],6][] | . as {a:$a} ?// $a ?// {a:$a} | $a" {
    const results = runFilter(
        "[[3],[4],[5],6][] | . as {a:$a} ?// $a ?// {a:$a} | $a",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[3]", results[0]);
    try std.testing.expectEqualStrings("[4]", results[1]);
    try std.testing.expectEqualStrings("[5]", results[2]);
    try std.testing.expectEqualStrings("6", results[3]);
}

test "jq:L1010 [[3],[4],[5],6] | .[] as {a:$a} ?// $a ?// {a:$a} | $a" {
    const results = runFilter(
        "[[3],[4],[5],6] | .[] as {a:$a} ?// $a ?// {a:$a} | $a",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[3]", results[0]);
    try std.testing.expectEqualStrings("[4]", results[1]);
    try std.testing.expectEqualStrings("[5]", results[2]);
    try std.testing.expectEqualStrings("6", results[3]);
}

test "jq:L1017 .[] | . as $a ?// {a:$a} ?// {a:$a} | $a" {
    const results = runFilter(
        ".[] | . as $a ?// {a:$a} ?// {a:$a} | $a",
        "[[3],[4],[5],6]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[3]", results[0]);
    try std.testing.expectEqualStrings("[4]", results[1]);
    try std.testing.expectEqualStrings("[5]", results[2]);
    try std.testing.expectEqualStrings("6", results[3]);
}

test "jq:L1024 .[] as $a ?// {a:$a} ?// {a:$a} | $a" {
    const results = runFilter(
        ".[] as $a ?// {a:$a} ?// {a:$a} | $a",
        "[[3],[4],[5],6]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[3]", results[0]);
    try std.testing.expectEqualStrings("[4]", results[1]);
    try std.testing.expectEqualStrings("[5]", results[2]);
    try std.testing.expectEqualStrings("6", results[3]);
}

test "jq:L1031 [[3],[4],[5],6][] | . as $a ?// {a:$a} ?// {a:$a} | $a" {
    const results = runFilter(
        "[[3],[4],[5],6][] | . as $a ?// {a:$a} ?// {a:$a} | $a",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[3]", results[0]);
    try std.testing.expectEqualStrings("[4]", results[1]);
    try std.testing.expectEqualStrings("[5]", results[2]);
    try std.testing.expectEqualStrings("6", results[3]);
}

test "jq:L1038 [[3],[4],[5],6] | .[] as $a ?// {a:$a} ?// {a:$a} | $a" {
    const results = runFilter(
        "[[3],[4],[5],6] | .[] as $a ?// {a:$a} ?// {a:$a} | $a",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[3]", results[0]);
    try std.testing.expectEqualStrings("[4]", results[1]);
    try std.testing.expectEqualStrings("[5]", results[2]);
    try std.testing.expectEqualStrings("6", results[3]);
}

test "jq:L1045 . as $dot|any($dot[];not)" {
    const results = runFilter(
        ". as $dot|any($dot[];not)",
        "[1,2,3,4,true,false,1,2,3,4,5]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L1049 . as $dot|any($dot[];not)" {
    const results = runFilter(
        ". as $dot|any($dot[];not)",
        "[1,2,3,4,true]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L1053 . as $dot|all($dot[];.)" {
    const results = runFilter(
        ". as $dot|all($dot[];.)",
        "[1,2,3,4,true,false,1,2,3,4,5]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L1057 . as $dot|all($dot[];.)" {
    const results = runFilter(
        ". as $dot|all($dot[];.)",
        "[1,2,3,4,true]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L1062 any(true, error; .)" {
    const results = runFilter(
        "any(true, error; .)",
        "\"badness\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L1066 all(false, error; .)" {
    const results = runFilter(
        "all(false, error; .)",
        "\"badness\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L1070 any(not)" {
    const results = runFilter(
        "any(not)",
        "[]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L1074 all(not)" {
    const results = runFilter(
        "all(not)",
        "[]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L1078 any(not)" {
    const results = runFilter(
        "any(not)",
        "[false]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L1082 all(not)" {
    const results = runFilter(
        "all(not)",
        "[false]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L1086 [any,all]" {
    const results = runFilter(
        "[any,all]",
        "[]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false,true]", results[0]);
}

test "jq:L1090 [any,all]" {
    const results = runFilter(
        "[any,all]",
        "[true]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,true]", results[0]);
}

test "jq:L1094 [any,all]" {
    const results = runFilter(
        "[any,all]",
        "[false]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false,false]", results[0]);
}

test "jq:L1098 [any,all]" {
    const results = runFilter(
        "[any,all]",
        "[true,false]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false]", results[0]);
}

test "jq:L1102 [any,all]" {
    const results = runFilter(
        "[any,all]",
        "[null,null,true]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false]", results[0]);
}

test "jq:L1110 path(.foo[0,1])" {
    const results = runFilter(
        "path(.foo[0,1])",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("[\"foo\", 0]", results[0]);
    try std.testing.expectEqualStrings("[\"foo\", 1]", results[1]);
}

test "jq:L1115 path(.[] | select(.>3))" {
    const results = runFilter(
        "path(.[] | select(.>3))",
        "[1,5,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1]", results[0]);
}

test "jq:L1119 path(.)" {
    const results = runFilter(
        "path(.)",
        "42",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L1123 try path(.a | map(select(.b == 0))) catch ." {
    const results = runFilter(
        "try path(.a | map(select(.b == 0))) catch .",
        "{\"a\":[{\"b\":0}]}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid path expression with result [{\\\"b\\\":0}]\"", results[0]);
}

test "jq:L1127 try path(.a | map(select(.b == 0)) | .[0]) catch ." {
    const results = runFilter(
        "try path(.a | map(select(.b == 0)) | .[0]) catch .",
        "{\"a\":[{\"b\":0}]}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid path expression near attempt to access element 0 of [{\\\"b\\\":0}]\"", results[0]);
}

test "jq:L1131 try path(.a | map(select(.b == 0)) | .c) catch ." {
    const results = runFilter(
        "try path(.a | map(select(.b == 0)) | .c) catch .",
        "{\"a\":[{\"b\":0}]}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid path expression near attempt to access element \\\"c\\\" of [{\\\"b\\\":0}]\"", results[0]);
}

test "jq:L1135 try path(.a | map(select(.b == 0)) | .[]) catch ." {
    const results = runFilter(
        "try path(.a | map(select(.b == 0)) | .[]) catch .",
        "{\"a\":[{\"b\":0}]}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid path expression near attempt to iterate through [{\\\"b\\\":0}]\"", results[0]);
}

test "jq:L1139 path(.a[path(.b)[0]])" {
    const results = runFilter(
        "path(.a[path(.b)[0]])",
        "{\"a\":{\"b\":0}}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\",\"b\"]", results[0]);
}

test "jq:L1143 [paths]" {
    const results = runFilter(
        "[paths]",
        "[1,[[],{\"a\":2}]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[0],[1],[1,0],[1,1],[1,1,\"a\"]]", results[0]);
}

test "jq:L1147 [_foo_,1] as $p | getpath($p), setpath($p; 20), delpaths(..." {
    const results = runFilter(
        "[\"foo\",1] as $p | getpath($p), setpath($p; 20), delpaths([$p])",
        "{\"bar\": 42, \"foo\": [\"a\", \"b\", \"c\", \"d\"]}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("\"b\"", results[0]);
    try std.testing.expectEqualStrings("{\"bar\": 42, \"foo\": [\"a\", 20, \"c\", \"d\"]}", results[1]);
    try std.testing.expectEqualStrings("{\"bar\": 42, \"foo\": [\"a\", \"c\", \"d\"]}", results[2]);
}

test "jq:L1153 map(getpath([2])), map(setpath([2]; 42)), map(delpaths([[..." {
    const results = runFilter(
        "map(getpath([2])), map(setpath([2]; 42)), map(delpaths([[2]]))",
        "[[0], [0,1], [0,1,2]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("[null, null, 2]", results[0]);
    try std.testing.expectEqualStrings("[[0,null,42], [0,1,42], [0,1,42]]", results[1]);
    try std.testing.expectEqualStrings("[[0], [0,1], [0,1]]", results[2]);
}

test "jq:L1159 map(delpaths([[0,_foo_]]))" {
    const results = runFilter(
        "map(delpaths([[0,\"foo\"]]))",
        "[[{\"foo\":2, \"x\":1}], [{\"bar\":2}]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[{\"x\":1}], [{\"bar\":2}]]", results[0]);
}

test "jq:L1163 [_foo_,1] as $p | getpath($p), setpath($p; 20), delpaths(..." {
    const results = runFilter(
        "[\"foo\",1] as $p | getpath($p), setpath($p; 20), delpaths([$p])",
        "{\"bar\":false}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
    try std.testing.expectEqualStrings("{\"bar\":false, \"foo\": [null, 20]}", results[1]);
    try std.testing.expectEqualStrings("{\"bar\":false}", results[2]);
}

test "jq:L1169 delpaths([[-200]])" {
    const results = runFilter(
        "delpaths([[-200]])",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L1173 try delpaths(0) catch ." {
    const results = runFilter(
        "try delpaths(0) catch .",
        "{}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Paths must be specified as an array\"", results[0]);
}

test "jq:L1177 del(.), del(empty), del((.foo,.bar,.baz) | .[2,3,0]), del..." {
    const results = runFilter(
        "del(.), del(empty), del((.foo,.bar,.baz) | .[2,3,0]), del(.foo[0], .bar[0], .foo, .baz.bar[0].x)",
        "{\"foo\": [0,1,2,3,4], \"bar\": [0,1]}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
    try std.testing.expectEqualStrings("{\"foo\": [0,1,2,3,4], \"bar\": [0,1]}", results[1]);
    try std.testing.expectEqualStrings("{\"foo\": [1,4], \"bar\": [1]}", results[2]);
    try std.testing.expectEqualStrings("{\"bar\": [1]}", results[3]);
}

test "jq:L1184 del(.[1], .[-6], .[2], .[-3:9])" {
    const results = runFilter(
        "del(.[1], .[-6], .[2], .[-3:9])",
        "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0, 3, 5, 6, 9]", results[0]);
}

test "jq:L1188 del(.[nan])" {
    const results = runFilter(
        "del(.[nan])",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L1192 del(.[nan,nan])" {
    const results = runFilter(
        "del(.[nan,nan])",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L1197 setpath([-1]; 1)" {
    const results = runFilter(
        "setpath([-1]; 1)",
        "[0]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1]", results[0]);
}

test "jq:L1201 pick(.a.b.c)" {
    const results = runFilter(
        "pick(.a.b.c)",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":{\"b\":{\"c\":null}}}", results[0]);
}

test "jq:L1205 pick(first)" {
    const results = runFilter(
        "pick(first)",
        "[1,2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1]", results[0]);
}

test "jq:L1209 pick(first|first)" {
    const results = runFilter(
        "pick(first|first)",
        "[[10,20],30]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[10]]", results[0]);
}

test "jq:L1214 try pick(last) catch ." {
    const results = runFilter(
        "try pick(last) catch .",
        "[1,2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Out of bounds negative array index\"", results[0]);
}

test "jq:L1221 .message = _goodbye_" {
    const results = runFilter(
        ".message = \"goodbye\"",
        "{\"message\": \"hello\"}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"message\": \"goodbye\"}", results[0]);
}

test "jq:L1225 .foo = .bar" {
    const results = runFilter(
        ".foo = .bar",
        "{\"bar\":42}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"foo\":42, \"bar\":42}", results[0]);
}

test "jq:L1229 .foo |= .+1" {
    const results = runFilter(
        ".foo |= .+1",
        "{\"foo\": 42}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"foo\": 43}", results[0]);
}

test "jq:L1233 .[] += 2, .[] *= 2, .[] -= 2, .[] /= 2, .[] %=2" {
    const results = runFilter(
        ".[] += 2, .[] *= 2, .[] -= 2, .[] /= 2, .[] %=2",
        "[1,3,5]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 5), results.len);
    try std.testing.expectEqualStrings("[3,5,7]", results[0]);
    try std.testing.expectEqualStrings("[2,6,10]", results[1]);
    try std.testing.expectEqualStrings("[-1,1,3]", results[2]);
    try std.testing.expectEqualStrings("[0.5, 1.5, 2.5]", results[3]);
    try std.testing.expectEqualStrings("[1,1,1]", results[4]);
}

test "jq:L1241 [.[] % 7]" {
    const results = runFilter(
        "[.[] % 7]",
        "[-7,-6,-5,-4,-3,-2,-1,0,1,2,3,4,5,6,7]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,-6,-5,-4,-3,-2,-1,0,1,2,3,4,5,6,0]", results[0]);
}

test "jq:L1245 .foo += .foo" {
    const results = runFilter(
        ".foo += .foo",
        "{\"foo\":2}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"foo\":4}", results[0]);
}

test "jq:L1249 .[0].a |= {_old_:., _new_:(.+1)}" {
    const results = runFilter(
        ".[0].a |= {\"old\":., \"new\":(.+1)}",
        "[{\"a\":1,\"b\":2}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[{\"a\":{\"old\":1, \"new\":2},\"b\":2}]", results[0]);
}

test "jq:L1253 def inc(x): x |= .+1; inc(.[].a)" {
    const results = runFilter(
        "def inc(x): x |= .+1; inc(.[].a)",
        "[{\"a\":1,\"b\":2},{\"a\":2,\"b\":4},{\"a\":7,\"b\":8}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[{\"a\":2,\"b\":2},{\"a\":3,\"b\":4},{\"a\":8,\"b\":8}]", results[0]);
}

test "jq:L1258 .[] | try (getpath([_a_,0,_b_]) |= 5) catch ." {
    const results = runFilter(
        ".[] | try (getpath([\"a\",0,\"b\"]) |= 5) catch .",
        "[null,{\"b\":0},{\"a\":0},{\"a\":null},{\"a\":[0,1]},{\"a\":{\"b\":1}},{\"a\":[{}]},{\"a\":[{\"c\":3}]}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 8), results.len);
    try std.testing.expectEqualStrings("{\"a\":[{\"b\":5}]}", results[0]);
    try std.testing.expectEqualStrings("{\"b\":0,\"a\":[{\"b\":5}]}", results[1]);
    try std.testing.expectEqualStrings("\"Cannot index number with number (0)\"", results[2]);
    try std.testing.expectEqualStrings("{\"a\":[{\"b\":5}]}", results[3]);
    try std.testing.expectEqualStrings("\"Cannot index number with string (\\\"b\\\")\"", results[4]);
    try std.testing.expectEqualStrings("\"Cannot index object with number (0)\"", results[5]);
    try std.testing.expectEqualStrings("{\"a\":[{\"b\":5}]}", results[6]);
    try std.testing.expectEqualStrings("{\"a\":[{\"c\":3,\"b\":5}]}", results[7]);
}

test "jq:L1270 (.[] | select(. >= 2)) |= empty" {
    const results = runFilter(
        "(.[] | select(. >= 2)) |= empty",
        "[1,5,3,0,7]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,0]", results[0]);
}

test "jq:L1274 .[] |= select(. % 2 == 0)" {
    const results = runFilter(
        ".[] |= select(. % 2 == 0)",
        "[0,1,2,3,4,5]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,2,4]", results[0]);
}

test "jq:L1278 .foo[1,4,2,3] |= empty" {
    const results = runFilter(
        ".foo[1,4,2,3] |= empty",
        "{\"foo\":[0,1,2,3,4,5]}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"foo\":[0,5]}", results[0]);
}

test "jq:L1282 .[2][3] = 1" {
    const results = runFilter(
        ".[2][3] = 1",
        "[4]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[4, null, [null, null, null, 1]]", results[0]);
}

test "jq:L1286 .foo[2].bar = 1" {
    const results = runFilter(
        ".foo[2].bar = 1",
        "{\"foo\":[11], \"bar\":42}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"foo\":[11,null,{\"bar\":1}], \"bar\":42}", results[0]);
}

test "jq:L1290 try ((map(select(.a == 1))[].b) = 10) catch ." {
    const results = runFilter(
        "try ((map(select(.a == 1))[].b) = 10) catch .",
        "[{\"a\":0},{\"a\":1}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid path expression near attempt to iterate through [{\\\"a\\\":1}]\"", results[0]);
}

test "jq:L1294 try ((map(select(.a == 1))[].a) |= .+1) catch ." {
    const results = runFilter(
        "try ((map(select(.a == 1))[].a) |= .+1) catch .",
        "[{\"a\":0},{\"a\":1}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid path expression near attempt to iterate through [{\\\"a\\\":1}]\"", results[0]);
}

test "jq:L1298 def x: .[1,2]; x=10" {
    const results = runFilter(
        "def x: .[1,2]; x=10",
        "[0,1,2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,10,10]", results[0]);
}

test "jq:L1302 try (def x: reverse; x=10) catch ." {
    const results = runFilter(
        "try (def x: reverse; x=10) catch .",
        "[0,1,2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid path expression with result [2,1,0]\"", results[0]);
}

test "jq:L1306 .[] = 1" {
    const results = runFilter(
        ".[] = 1",
        "[1,null,Infinity,-Infinity,NaN,-NaN]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,1,1,1,1,1]", results[0]);
}

test "jq:L1314 [.[] | if .foo then _yep_ else _nope_ end]" {
    const results = runFilter(
        "[.[] | if .foo then \"yep\" else \"nope\" end]",
        "[{\"foo\":0},{\"foo\":1},{\"foo\":[]},{\"foo\":true},{\"foo\":false},{\"foo\":null},{\"foo\":\"foo\"},{}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"yep\",\"yep\",\"yep\",\"yep\",\"nope\",\"nope\",\"yep\",\"nope\"]", results[0]);
}

test "jq:L1318 [.[] | if .baz then _strange_ elif .foo then _yep_ else _..." {
    const results = runFilter(
        "[.[] | if .baz then \"strange\" elif .foo then \"yep\" else \"nope\" end]",
        "[{\"foo\":0},{\"foo\":1},{\"foo\":[]},{\"foo\":true},{\"foo\":false},{\"foo\":null},{\"foo\":\"foo\"},{}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"yep\",\"yep\",\"yep\",\"yep\",\"nope\",\"nope\",\"yep\",\"nope\"]", results[0]);
}

test "jq:L1322 [if 1,null,2 then 3 else 4 end]" {
    const results = runFilter(
        "[if 1,null,2 then 3 else 4 end]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[3,4,3]", results[0]);
}

test "jq:L1326 [if empty then 3 else 4 end]" {
    const results = runFilter(
        "[if empty then 3 else 4 end]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L1330 [if 1 then 3,4 else 5 end]" {
    const results = runFilter(
        "[if 1 then 3,4 else 5 end]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[3,4]", results[0]);
}

test "jq:L1334 [if null then 3 else 5,6 end]" {
    const results = runFilter(
        "[if null then 3 else 5,6 end]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[5,6]", results[0]);
}

test "jq:L1338 [if true then 3 end]" {
    const results = runFilter(
        "[if true then 3 end]",
        "7",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[3]", results[0]);
}

test "jq:L1342 [if false then 3 end]" {
    const results = runFilter(
        "[if false then 3 end]",
        "7",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[7]", results[0]);
}

test "jq:L1346 [if false then 3 else . end]" {
    const results = runFilter(
        "[if false then 3 else . end]",
        "7",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[7]", results[0]);
}

test "jq:L1350 [if false then 3 elif false then 4 end]" {
    const results = runFilter(
        "[if false then 3 elif false then 4 end]",
        "7",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[7]", results[0]);
}

test "jq:L1354 [if false then 3 elif false then 4 else . end]" {
    const results = runFilter(
        "[if false then 3 elif false then 4 else . end]",
        "7",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[7]", results[0]);
}

test "jq:L1358 [-if true then 1 else 2 end]" {
    const results = runFilter(
        "[-if true then 1 else 2 end]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[-1]", results[0]);
}

test "jq:L1362 {x: if true then 1 else 2 end}" {
    const results = runFilter(
        "{x: if true then 1 else 2 end}",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"x\":1}", results[0]);
}

test "jq:L1366 if true then [.] else . end []" {
    const results = runFilter(
        "if true then [.] else . end []",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq:L1370 [.[] | [.foo[] // .bar]]" {
    const results = runFilter(
        "[.[] | [.foo[] // .bar]]",
        "[{\"foo\":[1,2], \"bar\": 42}, {\"foo\":[1], \"bar\": null}, {\"foo\":[null,false,3], \"bar\": 18}, {\"foo\":[], \"bar\":42}, {\"foo\": [null,false,null], \"bar\": 41}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[1,2], [1], [3], [42], [41]]", results[0]);
}

test "jq:L1374 .[] //= .[0]" {
    const results = runFilter(
        ".[] //= .[0]",
        "[\"hello\",true,false,[false],null]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"hello\",true,\"hello\",[false],\"hello\"]", results[0]);
}

test "jq:L1378 .[] | [.[0] and .[1], .[0] or .[1]]" {
    const results = runFilter(
        ".[] | [.[0] and .[1], .[0] or .[1]]",
        "[[true,[]], [false,1], [42,null], [null,false]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[true,true]", results[0]);
    try std.testing.expectEqualStrings("[false,true]", results[1]);
    try std.testing.expectEqualStrings("[false,true]", results[2]);
    try std.testing.expectEqualStrings("[false,false]", results[3]);
}

test "jq:L1385 [.[] | not]" {
    const results = runFilter(
        "[.[] | not]",
        "[1,0,false,null,true,\"hello\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false,false,true,true,false,false]", results[0]);
}

test "jq:L1390 [10 > 0, 10 > 10, 10 > 20, 10 < 0, 10 < 10, 10 < 20]" {
    const results = runFilter(
        "[10 > 0, 10 > 10, 10 > 20, 10 < 0, 10 < 10, 10 < 20]",
        "{}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false,false,false,false,true]", results[0]);
}

test "jq:L1394 [10 >= 0, 10 >= 10, 10 >= 20, 10 <= 0, 10 <= 10, 10 <= 20]" {
    const results = runFilter(
        "[10 >= 0, 10 >= 10, 10 >= 20, 10 <= 0, 10 <= 10, 10 <= 20]",
        "{}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,true,false,false,true,true]", results[0]);
}

test "jq:L1399 [ 10 == 10, 10 != 10, 10 != 11, 10 == 11]" {
    const results = runFilter(
        "[ 10 == 10, 10 != 10, 10 != 11, 10 == 11]",
        "{}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false,true,false]", results[0]);
}

test "jq:L1403 [_hello_ == _hello_, _hello_ != _hello_, _hello_ == _worl..." {
    const results = runFilter(
        "[\"hello\" == \"hello\", \"hello\" != \"hello\", \"hello\" == \"world\", \"hello\" != \"world\" ]",
        "{}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false,false,true]", results[0]);
}

test "jq:L1407 [[1,2,3] == [1,2,3], [1,2,3] != [1,2,3], [1,2,3] == [4,5,..." {
    const results = runFilter(
        "[[1,2,3] == [1,2,3], [1,2,3] != [1,2,3], [1,2,3] == [4,5,6], [1,2,3] != [4,5,6]]",
        "{}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false,false,true]", results[0]);
}

test "jq:L1411 [{_foo_:42} == {_foo_:42},{_foo_:42} != {_foo_:42}, {_foo..." {
    const results = runFilter(
        "[{\"foo\":42} == {\"foo\":42},{\"foo\":42} != {\"foo\":42}, {\"foo\":42} != {\"bar\":42}, {\"foo\":42} == {\"bar\":42}]",
        "{}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false,true,false]", results[0]);
}

test "jq:L1416 [{_foo_:[1,2,{_bar_:18},_world_]} == {_foo_:[1,2,{_bar_:1..." {
    const results = runFilter(
        "[{\"foo\":[1,2,{\"bar\":18},\"world\"]} == {\"foo\":[1,2,{\"bar\":18},\"world\"]},{\"foo\":[1,2,{\"bar\":18},\"world\"]} == {\"foo\":[1,2,{\"bar\":19},\"world\"]}]",
        "{}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false]", results[0]);
}

test "jq:L1421 [(_foo_ | contains(_foo_)), (_foobar_ | contains(_foo_)),..." {
    const results = runFilter(
        "[(\"foo\" | contains(\"foo\")), (\"foobar\" | contains(\"foo\")), (\"foo\" | contains(\"foobar\"))]",
        "{}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true, true, false]", results[0]);
}

test "jq:L1426 [contains(__), contains(__u0000_)]" {
    const results = runFilter(
        "[contains(\"\"), contains(\"\\u0000\")]",
        "\"\\u0000\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true, true]", results[0]);
}

test "jq:L1430 [contains(__), contains(_a_), contains(_ab_), contains(_c..." {
    const results = runFilter(
        "[contains(\"\"), contains(\"a\"), contains(\"ab\"), contains(\"c\"), contains(\"d\")]",
        "\"ab\\u0000cd\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true, true, true, true, true]", results[0]);
}

test "jq:L1434 [contains(_cd_), contains(_b_u0000_), contains(_ab_u0000_)]" {
    const results = runFilter(
        "[contains(\"cd\"), contains(\"b\\u0000\"), contains(\"ab\\u0000\")]",
        "\"ab\\u0000cd\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true, true, true]", results[0]);
}

test "jq:L1438 [contains(_b_u0000c_), contains(_b_u0000cd_), contains(_b..." {
    const results = runFilter(
        "[contains(\"b\\u0000c\"), contains(\"b\\u0000cd\"), contains(\"b\\u0000cd\")]",
        "\"ab\\u0000cd\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true, true, true]", results[0]);
}

test "jq:L1442 [contains(_@_), contains(__u0000@_), contains(__u0000what_)]" {
    const results = runFilter(
        "[contains(\"@\"), contains(\"\\u0000@\"), contains(\"\\u0000what\")]",
        "\"ab\\u0000cd\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false, false, false]", results[0]);
}

test "jq:L1448 [.[]|try if . == 0 then error(_foo_) elif . == 1 then .a ..." {
    const results = runFilter(
        "[.[]|try if . == 0 then error(\"foo\") elif . == 1 then .a elif . == 2 then empty else . end catch .]",
        "[0,1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"foo\",\"Cannot index number with string (\\\"a\\\")\",3]", results[0]);
}

test "jq:L1452 [.[]|(.a, .a)?]" {
    const results = runFilter(
        "[.[]|(.a, .a)?]",
        "[null,true,{\"a\":1}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,null,1,1]", results[0]);
}

test "jq:L1456 [[.[]|[.a,.a]]?]" {
    const results = runFilter(
        "[[.[]|[.a,.a]]?]",
        "[null,true,{\"a\":1}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L1460 [if error then 1 else 2 end?]" {
    const results = runFilter(
        "[if error then 1 else 2 end?]",
        "\"foo\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L1464 try error(0) // 1" {
    const results = runFilter(
        "try error(0) // 1",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L1468 1, try error(2), 3" {
    const results = runFilter(
        "1, try error(2), 3",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("3", results[1]);
}

test "jq:L1473 1 + try 2 catch 3 + 4" {
    const results = runFilter(
        "1 + try 2 catch 3 + 4",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("7", results[0]);
}

test "jq:L1477 [-try .]" {
    const results = runFilter(
        "[-try .]",
        "1",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[-1]", results[0]);
}

test "jq:L1481 try -.? catch ." {
    const results = runFilter(
        "try -.? catch .",
        "\"foo\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"string (\\\"foo\\\") cannot be negated\"", results[0]);
}

test "jq:L1485 {x: try 1, y: try error catch 2, z: if true then 3 end}" {
    const results = runFilter(
        "{x: try 1, y: try error catch 2, z: if true then 3 end}",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"x\":1,\"y\":2,\"z\":3}", results[0]);
}

test "jq:L1489 {x: 1 + 2, y: false or true, z: null // 3}" {
    const results = runFilter(
        "{x: 1 + 2, y: false or true, z: null // 3}",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"x\":3,\"y\":true,\"z\":3}", results[0]);
}

test "jq:L1493 .[] | try error catch ." {
    const results = runFilter(
        ".[] | try error catch .",
        "[1,null,2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("null", results[1]);
    try std.testing.expectEqualStrings("2", results[2]);
}

test "jq:L1499 try error(__($__loc__)_) catch ." {
    const results = runFilter(
        "try error(\"\\($__loc__)\") catch .",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"{\\\"file\\\":\\\"<top-level>\\\",\\\"line\\\":1}\"", results[0]);
}

test "jq:L1504 [.[]|startswith(_foo_)]" {
    const results = runFilter(
        "[.[]|startswith(\"foo\")]",
        "[\"fo\", \"foo\", \"barfoo\", \"foobar\", \"barfoob\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false, true, false, true, false]", results[0]);
}

test "jq:L1508 [.[]|endswith(_foo_)]" {
    const results = runFilter(
        "[.[]|endswith(\"foo\")]",
        "[\"fo\", \"foo\", \"barfoo\", \"foobar\", \"barfoob\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false, true, true, false, false]", results[0]);
}

test "jq:L1512 [.[] | split(_, _)]" {
    const results = runFilter(
        "[.[] | split(\", \")]",
        "[\"a,b, c, d, e,f\",\", a,b, c, d, e,f, \"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[\"a,b\",\"c\",\"d\",\"e,f\"],[\"\",\"a,b\",\"c\",\"d\",\"e,f\",\"\"]]", results[0]);
}

test "jq:L1516 split(__)" {
    const results = runFilter(
        "split(\"\")",
        "\"abc\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\",\"b\",\"c\"]", results[0]);
}

test "jq:L1520 [.[]|ltrimstr(_foo_)]" {
    const results = runFilter(
        "[.[]|ltrimstr(\"foo\")]",
        "[\"fo\", \"foo\", \"barfoo\", \"foobar\", \"afoo\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"fo\",\"\",\"barfoo\",\"bar\",\"afoo\"]", results[0]);
}

test "jq:L1524 [.[]|rtrimstr(_foo_)]" {
    const results = runFilter(
        "[.[]|rtrimstr(\"foo\")]",
        "[\"fo\", \"foo\", \"barfoo\", \"foobar\", \"foob\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"fo\",\"\",\"bar\",\"foobar\",\"foob\"]", results[0]);
}

test "jq:L1528 [.[]|trimstr(_foo_)]" {
    const results = runFilter(
        "[.[]|trimstr(\"foo\")]",
        "[\"fo\", \"foo\", \"barfoo\", \"foobarfoo\", \"foob\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"fo\",\"\",\"bar\",\"bar\",\"b\"]", results[0]);
}

test "jq:L1532 [.[]|ltrimstr(__)]" {
    const results = runFilter(
        "[.[]|ltrimstr(\"\")]",
        "[\"a\", \"xx\", \"\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\", \"xx\", \"\"]", results[0]);
}

test "jq:L1536 [.[]|rtrimstr(__)]" {
    const results = runFilter(
        "[.[]|rtrimstr(\"\")]",
        "[\"a\", \"xx\", \"\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\", \"xx\", \"\"]", results[0]);
}

test "jq:L1540 [.[]|trimstr(__)]" {
    const results = runFilter(
        "[.[]|trimstr(\"\")]",
        "[\"a\", \"xx\", \"\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\", \"xx\", \"\"]", results[0]);
}

test "jq:L1544 [(index(_,_), rindex(_,_)), indices(_,_)]" {
    const results = runFilter(
        "[(index(\",\"), rindex(\",\")), indices(\",\")]",
        "\"a,bc,def,ghij,klmno\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,13,[1,4,8,13]]", results[0]);
}

test "jq:L1548 [ index(_aba_), rindex(_aba_), indices(_aba_) ]" {
    const results = runFilter(
        "[ index(\"aba\"), rindex(\"aba\"), indices(\"aba\") ]",
        "\"xababababax\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,7,[1,3,5,7]]", results[0]);
}

test "jq:L1554 map(trim), map(ltrim), map(rtrim)" {
    const results = runFilter(
        "map(trim), map(ltrim), map(rtrim)",
        "[\" \\n\\t\\r\\f\\u000b\", \"\",\"  \", \"a\", \" a \", \"abc\", \"  abc  \", \"  abc\", \"abc  \"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("[\"\", \"\", \"\", \"a\", \"a\", \"abc\", \"abc\", \"abc\", \"abc\"]", results[0]);
    try std.testing.expectEqualStrings("[\"\", \"\", \"\", \"a\", \"a \", \"abc\", \"abc  \", \"abc\", \"abc  \"]", results[1]);
    try std.testing.expectEqualStrings("[\"\", \"\", \"\", \"a\", \" a\", \"abc\", \"  abc\", \"  abc\", \"abc\"]", results[2]);
}

test "jq:L1560 trim, ltrim, rtrim" {
    const results = runFilter(
        "trim, ltrim, rtrim",
        "\"\\u0009\\u000A\\u000B\\u000C\\u000D\\u0020\\u0085\\u00A0\\u1680\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006\\u2007\\u2008\\u2009\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000abc\\u0009\\u000A\\u000B\\u000C\\u000D\\u0020\\u0085\\u00A0\\u1680\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006\\u2007\\u2008\\u2009\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("\"abc\"", results[0]);
    try std.testing.expectEqualStrings("\"abc\\u0009\\u000A\\u000B\\u000C\\u000D\\u0020\\u0085\\u00A0\\u1680\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006\\u2007\\u2008\\u2009\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\"", results[1]);
    try std.testing.expectEqualStrings("\"\\u0009\\u000A\\u000B\\u000C\\u000D\\u0020\\u0085\\u00A0\\u1680\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006\\u2007\\u2008\\u2009\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000abc\"", results[2]);
}

test "jq:L1566 try trim catch ., try ltrim catch ., try rtrim catch ." {
    const results = runFilter(
        "try trim catch ., try ltrim catch ., try rtrim catch .",
        "123",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("\"trim input must be a string\"", results[0]);
    try std.testing.expectEqualStrings("\"trim input must be a string\"", results[1]);
    try std.testing.expectEqualStrings("\"trim input must be a string\"", results[2]);
}

test "jq:L1572 indices(1)" {
    const results = runFilter(
        "indices(1)",
        "[0,1,1,2,3,4,1,5]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,6]", results[0]);
}

test "jq:L1576 indices([1,2])" {
    const results = runFilter(
        "indices([1,2])",
        "[0,1,2,3,1,4,2,5,1,2,6,7]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,8]", results[0]);
}

test "jq:L1580 indices([1,2])" {
    const results = runFilter(
        "indices([1,2])",
        "[1]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L1584 indices(_, _)" {
    const results = runFilter(
        "indices(\", \")",
        "\"a,b, cd,e, fgh, ijkl\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[3,9,14]", results[0]);
}

test "jq:L1588 index(_!_)" {
    const results = runFilter(
        "index(\"!\")",
        "\"здравствуй мир!\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("14", results[0]);
}

test "jq:L1592 .[:rindex(_x_)]" {
    const results = runFilter(
        ".[:rindex(\"x\")]",
        "\"正xyz\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"正\"", results[0]);
}

test "jq:L1596 indices(_o_)" {
    const results = runFilter(
        "indices(\"o\")",
        "\"🇬🇧oo\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[2,3]", results[0]);
}

test "jq:L1600 indices(_o_)" {
    const results = runFilter(
        "indices(\"o\")",
        "\"ƒoo\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2]", results[0]);
}

test "jq:L1604 [.[]|split(_,_)]" {
    const results = runFilter(
        "[.[]|split(\",\")]",
        "[\"a, bc, def, ghij, jklmn, a,b, c,d, e,f\", \"a,b,c,d, e,f,g,h\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[\"a\",\" bc\",\" def\",\" ghij\",\" jklmn\",\" a\",\"b\",\" c\",\"d\",\" e\",\"f\"],[\"a\",\"b\",\"c\",\"d\",\" e\",\"f\",\"g\",\"h\"]]", results[0]);
}

test "jq:L1608 [.[]|split(_, _)]" {
    const results = runFilter(
        "[.[]|split(\", \")]",
        "[\"a, bc, def, ghij, jklmn, a,b, c,d, e,f\", \"a,b,c,d, e,f,g,h\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[\"a\",\"bc\",\"def\",\"ghij\",\"jklmn\",\"a,b\",\"c,d\",\"e,f\"],[\"a,b,c,d\",\"e,f,g,h\"]]", results[0]);
}

test "jq:L1612 [.[] * 3]" {
    const results = runFilter(
        "[.[] * 3]",
        "[\"a\", \"ab\", \"abc\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"aaa\", \"ababab\", \"abcabcabc\"]", results[0]);
}

test "jq:L1616 [.[] * _abc_]" {
    const results = runFilter(
        "[.[] * \"abc\"]",
        "[-1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 3.7, 10.0]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,null,\"\",\"\",\"abc\",\"abc\",\"abcabcabc\",\"abcabcabcabcabcabcabcabcabcabc\"]", results[0]);
}

test "jq:L1620 [. * (nan,-nan)]" {
    const results = runFilter(
        "[. * (nan,-nan)]",
        "\"abc\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,null]", results[0]);
}

test "jq:L1624 . * 100000 | [.[:10],.[-10:]]" {
    const results = runFilter(
        ". * 100000 | [.[:10],.[-10:]]",
        "\"abc\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"abcabcabca\",\"cabcabcabc\"]", results[0]);
}

test "jq:L1628 . * 1000000000" {
    const results = runFilter(
        ". * 1000000000",
        "\"\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"\"", results[0]);
}

test "jq:L1632 try (. * 1000000000) catch ." {
    const results = runFilter(
        "try (. * 1000000000) catch .",
        "\"abc\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Repeat string result too long\"", results[0]);
}

test "jq:L1636 [.[] / _,_]" {
    const results = runFilter(
        "[.[] / \",\"]",
        "[\"a, bc, def, ghij, jklmn, a,b, c,d, e,f\", \"a,b,c,d, e,f,g,h\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[\"a\",\" bc\",\" def\",\" ghij\",\" jklmn\",\" a\",\"b\",\" c\",\"d\",\" e\",\"f\"],[\"a\",\"b\",\"c\",\"d\",\" e\",\"f\",\"g\",\"h\"]]", results[0]);
}

test "jq:L1640 [.[] / _, _]" {
    const results = runFilter(
        "[.[] / \", \"]",
        "[\"a, bc, def, ghij, jklmn, a,b, c,d, e,f\", \"a,b,c,d, e,f,g,h\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[\"a\",\"bc\",\"def\",\"ghij\",\"jklmn\",\"a,b\",\"c,d\",\"e,f\"],[\"a,b,c,d\",\"e,f,g,h\"]]", results[0]);
}

test "jq:L1644 map(.[1] as $needle | .[0] | contains($needle))" {
    const results = runFilter(
        "map(.[1] as $needle | .[0] | contains($needle))",
        "[[[],[]], [[1,2,3], [1,2]], [[1,2,3], [3,1]], [[1,2,3], [4]], [[1,2,3], [1,4]]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true, true, true, false, false]", results[0]);
}

test "jq:L1648 map(.[1] as $needle | .[0] | contains($needle))" {
    const results = runFilter(
        "map(.[1] as $needle | .[0] | contains($needle))",
        "[[[\"foobar\", \"foobaz\"], [\"baz\", \"bar\"]], [[\"foobar\", \"foobaz\"], [\"foo\"]], [[\"foobar\", \"foobaz\"], [\"blap\"]]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true, true, false]", results[0]);
}

test "jq:L1652 [({foo: 12, bar:13} | contains({foo: 12})), ({foo: 12} | ..." {
    const results = runFilter(
        "[({foo: 12, bar:13} | contains({foo: 12})), ({foo: 12} | contains({})), ({foo: 12, bar:13} | contains({baz:14}))]",
        "{}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true, true, false]", results[0]);
}

test "jq:L1656 {foo: {baz: 12, blap: {bar: 13}}, bar: 14} | contains({ba..." {
    const results = runFilter(
        "{foo: {baz: 12, blap: {bar: 13}}, bar: 14} | contains({bar: 14, foo: {blap: {}}})",
        "{}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L1660 {foo: {baz: 12, blap: {bar: 13}}, bar: 14} | contains({ba..." {
    const results = runFilter(
        "{foo: {baz: 12, blap: {bar: 13}}, bar: 14} | contains({bar: 14, foo: {blap: {bar: 14}}})",
        "{}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L1664 sort" {
    const results = runFilter(
        "sort",
        "[42,[2,5,3,11],10,{\"a\":42,\"b\":2},{\"a\":42},true,2,[2,6],\"hello\",null,[2,5,6],{\"a\":[],\"b\":1},\"abc\",\"ab\",[3,10],{},false,\"abcd\",null]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,null,false,true,2,10,42,\"ab\",\"abc\",\"abcd\",\"hello\",[2,5,3,11],[2,5,6],[2,6],[3,10],{},{\"a\":42},{\"a\":42,\"b\":2},{\"a\":[],\"b\":1}]", results[0]);
}

test "jq:L1668 (sort_by(.b) | sort_by(.a)), sort_by(.a, .b), sort_by(.b,..." {
    const results = runFilter(
        "(sort_by(.b) | sort_by(.a)), sort_by(.a, .b), sort_by(.b, .c), group_by(.b), group_by(.a + .b - .c == 2)",
        "[{\"a\": 1, \"b\": 4, \"c\": 14}, {\"a\": 4, \"b\": 1, \"c\": 3}, {\"a\": 1, \"b\": 4, \"c\": 3}, {\"a\": 0, \"b\": 2, \"c\": 43}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 5), results.len);
    try std.testing.expectEqualStrings("[{\"a\": 0, \"b\": 2, \"c\": 43}, {\"a\": 1, \"b\": 4, \"c\": 14}, {\"a\": 1, \"b\": 4, \"c\": 3}, {\"a\": 4, \"b\": 1, \"c\": 3}]", results[0]);
    try std.testing.expectEqualStrings("[{\"a\": 0, \"b\": 2, \"c\": 43}, {\"a\": 1, \"b\": 4, \"c\": 14}, {\"a\": 1, \"b\": 4, \"c\": 3}, {\"a\": 4, \"b\": 1, \"c\": 3}]", results[1]);
    try std.testing.expectEqualStrings("[{\"a\": 4, \"b\": 1, \"c\": 3}, {\"a\": 0, \"b\": 2, \"c\": 43}, {\"a\": 1, \"b\": 4, \"c\": 3}, {\"a\": 1, \"b\": 4, \"c\": 14}]", results[2]);
    try std.testing.expectEqualStrings("[[{\"a\": 4, \"b\": 1, \"c\": 3}], [{\"a\": 0, \"b\": 2, \"c\": 43}], [{\"a\": 1, \"b\": 4, \"c\": 14}, {\"a\": 1, \"b\": 4, \"c\": 3}]]", results[3]);
    try std.testing.expectEqualStrings("[[{\"a\": 1, \"b\": 4, \"c\": 14}, {\"a\": 0, \"b\": 2, \"c\": 43}], [{\"a\": 4, \"b\": 1, \"c\": 3}, {\"a\": 1, \"b\": 4, \"c\": 3}]]", results[4]);
}

test "jq:L1676 unique" {
    const results = runFilter(
        "unique",
        "[1,2,5,3,5,3,1,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3,5]", results[0]);
}

test "jq:L1680 unique" {
    const results = runFilter(
        "unique",
        "[]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L1684 [min, max, min_by(.[1]), max_by(.[1]), min_by(.[2]), max_..." {
    const results = runFilter(
        "[min, max, min_by(.[1]), max_by(.[1]), min_by(.[2]), max_by(.[2])]",
        "[[4,2,\"a\"],[3,1,\"a\"],[2,4,\"a\"],[1,3,\"a\"]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[1,3,\"a\"],[4,2,\"a\"],[3,1,\"a\"],[2,4,\"a\"],[4,2,\"a\"],[1,3,\"a\"]]", results[0]);
}

test "jq:L1688 [min,max,min_by(.),max_by(.)]" {
    const results = runFilter(
        "[min,max,min_by(.),max_by(.)]",
        "[]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,null,null,null]", results[0]);
}

test "jq:L1692 .foo[.baz]" {
    const results = runFilter(
        ".foo[.baz]",
        "{\"foo\":{\"bar\":4},\"baz\":\"bar\"}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("4", results[0]);
}

test "jq:L1696 .[] | .error = _no, it's OK_" {
    const results = runFilter(
        ".[] | .error = \"no, it's OK\"",
        "[{\"error\":true}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"error\": \"no, it's OK\"}", results[0]);
}

test "jq:L1700 [{a:1}] | .[] | .a=999" {
    const results = runFilter(
        "[{a:1}] | .[] | .a=999",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\": 999}", results[0]);
}

test "jq:L1704 to_entries" {
    const results = runFilter(
        "to_entries",
        "{\"a\": 1, \"b\": 2}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[{\"key\":\"a\", \"value\":1}, {\"key\":\"b\", \"value\":2}]", results[0]);
}

test "jq:L1708 from_entries" {
    const results = runFilter(
        "from_entries",
        "[{\"key\":\"a\", \"value\":1}, {\"Key\":\"b\", \"Value\":2}, {\"name\":\"c\", \"value\":3}, {\"Name\":\"d\", \"Value\":4}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\": 1, \"b\": 2, \"c\": 3, \"d\": 4}", results[0]);
}

test "jq:L1712 with_entries(.key |= _KEY__ + .)" {
    const results = runFilter(
        "with_entries(.key |= \"KEY_\" + .)",
        "{\"a\": 1, \"b\": 2}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"KEY_a\": 1, \"KEY_b\": 2}", results[0]);
}

test "jq:L1716 map(has(_foo_))" {
    const results = runFilter(
        "map(has(\"foo\"))",
        "[{\"foo\": 42}, {}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true, false]", results[0]);
}

test "jq:L1720 map(has(2))" {
    const results = runFilter(
        "map(has(2))",
        "[[0,1], [\"a\",\"b\",\"c\"]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false, true]", results[0]);
}

test "jq:L1724 has(nan)" {
    const results = runFilter(
        "has(nan)",
        "[0,1,2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L1728 keys" {
    const results = runFilter(
        "keys",
        "[42,3,35]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2]", results[0]);
}

test "jq:L1732 [][.]" {
    const results = runFilter(
        "[][.]",
        "1000000000000000000",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq:L1736 map([1,2][0:.])" {
    const results = runFilter(
        "map([1,2][0:.])",
        "[-1, 1, 2, 3, 1000000000000000000]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[1], [1], [1,2], [1,2], [1,2]]", results[0]);
}

test "jq:L1742 {_k_: {_a_: 1, _b_: 2}} * ." {
    const results = runFilter(
        "{\"k\": {\"a\": 1, \"b\": 2}} * .",
        "{\"k\": {\"a\": 0,\"c\": 3}}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"k\": {\"a\": 0, \"b\": 2, \"c\": 3}}", results[0]);
}

test "jq:L1746 {_k_: {_a_: 1, _b_: 2}, _hello_: {_x_: 1}} * ." {
    const results = runFilter(
        "{\"k\": {\"a\": 1, \"b\": 2}, \"hello\": {\"x\": 1}} * .",
        "{\"k\": {\"a\": 0,\"c\": 3}, \"hello\": 1}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"k\": {\"a\": 0, \"b\": 2, \"c\": 3}, \"hello\": 1}", results[0]);
}

test "jq:L1750 {_k_: {_a_: 1, _b_: 2}, _hello_: 1} * ." {
    const results = runFilter(
        "{\"k\": {\"a\": 1, \"b\": 2}, \"hello\": 1} * .",
        "{\"k\": {\"a\": 0,\"c\": 3}, \"hello\": {\"x\": 1}}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"k\": {\"a\": 0, \"b\": 2, \"c\": 3}, \"hello\": {\"x\": 1}}", results[0]);
}

test "jq:L1754 {_a_: {_b_: 1}, _c_: {_d_: 2}, _e_: 5} * ." {
    const results = runFilter(
        "{\"a\": {\"b\": 1}, \"c\": {\"d\": 2}, \"e\": 5} * .",
        "{\"a\": {\"b\": 2}, \"c\": {\"d\": 3, \"f\": 9}}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\": {\"b\": 2}, \"c\": {\"d\": 3, \"f\": 9}, \"e\": 5}", results[0]);
}

test "jq:L1758 [.[]|arrays]" {
    const results = runFilter(
        "[.[]|arrays]",
        "[1,2,\"foo\",[],[3,[]],{},true,false,null]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[],[3,[]]]", results[0]);
}

test "jq:L1762 [.[]|objects]" {
    const results = runFilter(
        "[.[]|objects]",
        "[1,2,\"foo\",[],[3,[]],{},true,false,null]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[{}]", results[0]);
}

test "jq:L1766 [.[]|iterables]" {
    const results = runFilter(
        "[.[]|iterables]",
        "[1,2,\"foo\",[],[3,[]],{},true,false,null]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[],[3,[]],{}]", results[0]);
}

test "jq:L1770 [.[]|scalars]" {
    const results = runFilter(
        "[.[]|scalars]",
        "[1,2,\"foo\",[],[3,[]],{},true,false,null]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,\"foo\",true,false,null]", results[0]);
}

test "jq:L1774 [.[]|values]" {
    const results = runFilter(
        "[.[]|values]",
        "[1,2,\"foo\",[],[3,[]],{},true,false,null]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,\"foo\",[],[3,[]],{},true,false]", results[0]);
}

test "jq:L1778 [.[]|booleans]" {
    const results = runFilter(
        "[.[]|booleans]",
        "[1,2,\"foo\",[],[3,[]],{},true,false,null]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false]", results[0]);
}

test "jq:L1782 [.[]|nulls]" {
    const results = runFilter(
        "[.[]|nulls]",
        "[1,2,\"foo\",[],[3,[]],{},true,false,null]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null]", results[0]);
}

test "jq:L1786 flatten" {
    const results = runFilter(
        "flatten",
        "[0, [1], [[2]], [[[3]]]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0, 1, 2, 3]", results[0]);
}

test "jq:L1790 flatten(0)" {
    const results = runFilter(
        "flatten(0)",
        "[0, [1], [[2]], [[[3]]]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0, [1], [[2]], [[[3]]]]", results[0]);
}

test "jq:L1794 flatten(2)" {
    const results = runFilter(
        "flatten(2)",
        "[0, [1], [[2]], [[[3]]]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0, 1, 2, [3]]", results[0]);
}

test "jq:L1798 flatten(2)" {
    const results = runFilter(
        "flatten(2)",
        "[0, [1, [2]], [1, [[3], 2]]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0, 1, 2, 1, [3], 2]", results[0]);
}

test "jq:L1802 try flatten(-1) catch ." {
    const results = runFilter(
        "try flatten(-1) catch .",
        "[0, [1], [[2]], [[[3]]]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"flatten depth must not be negative\"", results[0]);
}

test "jq:L1806 transpose" {
    const results = runFilter(
        "transpose",
        "[[1], [2,3]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[1,2],[null,3]]", results[0]);
}

test "jq:L1810 transpose" {
    const results = runFilter(
        "transpose",
        "[]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L1814 ascii_upcase" {
    const results = runFilter(
        "ascii_upcase",
        "\"useful but not for é\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"USEFUL BUT NOT FOR é\"", results[0]);
}

test "jq:L1818 bsearch(0,1,2,3,4)" {
    const results = runFilter(
        "bsearch(0,1,2,3,4)",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 5), results.len);
    try std.testing.expectEqualStrings("-1", results[0]);
    try std.testing.expectEqualStrings("0", results[1]);
    try std.testing.expectEqualStrings("1", results[2]);
    try std.testing.expectEqualStrings("2", results[3]);
    try std.testing.expectEqualStrings("-4", results[4]);
}

test "jq:L1826 bsearch({x:1})" {
    const results = runFilter(
        "bsearch({x:1})",
        "[{ \"x\": 0 },{ \"x\": 1 },{ \"x\": 2 }]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L1830 try [_OK_, bsearch(0)] catch [_KO_,.]" {
    const results = runFilter(
        "try [\"OK\", bsearch(0)] catch [\"KO\",.]",
        "\"aa\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"KO\",\"string (\\\"aa\\\") cannot be searched from\"]", results[0]);
}

test "jq:L1834 strftime(_%Y-%m-%dT%H:%M:%SZ_)" {
    const results = runFilter(
        "strftime(\"%Y-%m-%dT%H:%M:%SZ\")",
        "[2015,2,5,23,51,47,4,63]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"2015-03-05T23:51:47Z\"", results[0]);
}

test "jq:L1838 strftime(_%A, %B %d, %Y_)" {
    const results = runFilter(
        "strftime(\"%A, %B %d, %Y\")",
        "1435677542.822351",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Tuesday, June 30, 2015\"", results[0]);
}

test "jq:L1842 strftime(_%Y-%m-%dT%H:%M:%SZ_)" {
    const results = runFilter(
        "strftime(\"%Y-%m-%dT%H:%M:%SZ\")",
        "[2024,2,15]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"2024-03-15T00:00:00Z\"", results[0]);
}

test "jq:L1846 mktime" {
    const results = runFilter(
        "mktime",
        "[2024,8,21]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1726876800", results[0]);
}

test "jq:L1850 gmtime" {
    const results = runFilter(
        "gmtime",
        "1425599507",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[2015,2,5,23,51,47,4,63]", results[0]);
}

test "jq:L1854 gmtime[5]" {
    const results = runFilter(
        "gmtime[5]",
        "1425599507.25",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("47.25", results[0]);
}

test "jq:L1859 try strftime(_%Y-%m-%dT%H:%M:%SZ_) catch ." {
    const results = runFilter(
        "try strftime(\"%Y-%m-%dT%H:%M:%SZ\") catch .",
        "[\"a\",1,2,3,4,5,6,7]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"strftime/1 requires parsed datetime inputs\"", results[0]);
}

test "jq:L1863 try strflocaltime(_%Y-%m-%dT%H:%M:%SZ_) catch ." {
    const results = runFilter(
        "try strflocaltime(\"%Y-%m-%dT%H:%M:%SZ\") catch .",
        "[\"a\",1,2,3,4,5,6,7]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"strflocaltime/1 requires parsed datetime inputs\"", results[0]);
}

test "jq:L1867 try mktime catch ." {
    const results = runFilter(
        "try mktime catch .",
        "[\"a\",1,2,3,4,5,6,7]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"mktime requires parsed datetime inputs\"", results[0]);
}

test "jq:L1872 try [_OK_, strftime([])] catch [_KO_, .]" {
    const results = runFilter(
        "try [\"OK\", strftime([])] catch [\"KO\", .]",
        "0",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"KO\",\"strftime/1 requires a string format\"]", results[0]);
}

test "jq:L1876 try [_OK_, strflocaltime({})] catch [_KO_, .]" {
    const results = runFilter(
        "try [\"OK\", strflocaltime({})] catch [\"KO\", .]",
        "0",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"KO\",\"strflocaltime/1 requires a string format\"]", results[0]);
}

test "jq:L1880 [strptime(_%Y-%m-%dT%H:%M:%SZ_)|(.,mktime)]" {
    const results = runFilter(
        "[strptime(\"%Y-%m-%dT%H:%M:%SZ\")|(.,mktime)]",
        "\"2015-03-05T23:51:47Z\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[2015,2,5,23,51,47,4,63],1425599507]", results[0]);
}

test "jq:L1886 last(range(365 * 67)|(_1970-03-01T01:02:03Z_|strptime(_%Y..." {
    const results = runFilter(
        "last(range(365 * 67)|(\"1970-03-01T01:02:03Z\"|strptime(\"%Y-%m-%dT%H:%M:%SZ\")|mktime) + (86400 * .)|strftime(\"%Y-%m-%dT%H:%M:%SZ\")|strptime(\"%Y-%m-%dT%H:%M:%SZ\"))",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[2037,1,11,1,2,3,3,41]", results[0]);
}

test "jq:L1891 import _a_ as foo; import _b_ as bar; def fooa: foo::a; [..." {
    const results = runFilter(
        "import \"a\" as foo; import \"b\" as bar; def fooa: foo::a; [fooa, bar::a, bar::b, foo::a]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\",\"b\",\"c\",\"a\"]", results[0]);
}

test "jq:L1895 import _c_ as foo; [foo::a, foo::c]" {
    const results = runFilter(
        "import \"c\" as foo; [foo::a, foo::c]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,\"acmehbah\"]", results[0]);
}

test "jq:L1899 include _c_; [a, c]" {
    const results = runFilter(
        "include \"c\"; [a, c]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,\"acmehbah\"]", results[0]);
}

test "jq:L1903 import _data_ as $e; import _data_ as $d; [$d[].this,$e[]..." {
    const results = runFilter(
        "import \"data\" as $e; import \"data\" as $d; [$d[].this,$e[].that,$d::d[].this,$e::e[].that]|join(\";\")",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"is a test;is too;is a test;is too\"", results[0]);
}

test "jq:L1908 import _data_ as $a; import _data_ as $b; def f: {$a, $b}; f" {
    const results = runFilter(
        "import \"data\" as $a; import \"data\" as $b; def f: {$a, $b}; f",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":[{\"this\":\"is a test\",\"that\":\"is too\"}],\"b\":[{\"this\":\"is a test\",\"that\":\"is too\"}]}", results[0]);
}

test "jq:L1912 include _shadow1_; e" {
    const results = runFilter(
        "include \"shadow1\"; e",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("2", results[0]);
}

test "jq:L1916 include _shadow1_; include _shadow2_; e" {
    const results = runFilter(
        "include \"shadow1\"; include \"shadow2\"; e",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("3", results[0]);
}

test "jq:L1920 import _shadow1_ as f; import _shadow2_ as f; import _sha..." {
    const results = runFilter(
        "import \"shadow1\" as f; import \"shadow2\" as f; import \"shadow1\" as e; [e::e, f::e]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[2,3]", results[0]);
}

test "jq:L1924 module (.+1); 0" {
    // %%FAIL: filter should not compile
    try expectCompileError("module (.+1); 0");
}

test "jq:L1930 module []; 0" {
    // %%FAIL: filter should not compile
    try expectCompileError("module []; 0");
}

test "jq:L1936 include _a_ (.+1); 0" {
    // %%FAIL: filter should not compile
    try expectCompileError("include \"a\" (.+1); 0");
}

test "jq:L1942 include _a_ []; 0" {
    // %%FAIL: filter should not compile
    try expectCompileError("include \"a\" []; 0");
}

test "jq:L1948 include __ _; 0" {
    // %%FAIL: filter should not compile
    try expectCompileError("include \"\\ \"; 0");
}

test "jq:L1954 include __(a)_; 0" {
    // %%FAIL: filter should not compile
    try expectCompileError("include \"\\(a)\"; 0");
}

test "jq:L1960 modulemeta" {
    const results = runFilter(
        "modulemeta",
        "\"c\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"whatever\":null,\"deps\":[{\"as\":\"foo\",\"is_data\":false,\"relpath\":\"a\"},{\"search\":\"./\",\"as\":\"d\",\"is_data\":false,\"relpath\":\"d\"},{\"search\":\"./\",\"as\":\"d2\",\"is_data\":false,\"relpath\":\"d\"},{\"search\":\"./../lib/jq\",\"as\":\"e\",\"is_data\":false,\"relpath\":\"e\"},{\"search\":\"./../lib/jq\",\"as\":\"f\",\"is_data\":false,\"relpath\":\"f\"},{\"as\":\"d\",\"is_data\":true,\"relpath\":\"data\"}],\"defs\":[\"a/0\",\"c/0\"]}", results[0]);
}

test "jq:L1964 modulemeta | .deps | length" {
    const results = runFilter(
        "modulemeta | .deps | length",
        "\"c\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("6", results[0]);
}

test "jq:L1968 modulemeta | .defs | length" {
    const results = runFilter(
        "modulemeta | .defs | length",
        "\"c\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("2", results[0]);
}

test "jq:L1972 import _syntaxerror_ as e; ." {
    // %%FAIL: filter should not compile
    try expectCompileError("import \"syntaxerror\" as e; .");
}

test "jq:L1978 %::wat" {
    // %%FAIL: filter should not compile
    try expectCompileError("%::wat");
}

test "jq:L1984 import _test_bind_order_ as check; check::check" {
    const results = runFilter(
        "import \"test_bind_order\" as check; check::check",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L1988 try -. catch ." {
    const results = runFilter(
        "try -. catch .",
        "\"very-long-long-long-long-string\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"string (\\\"very-long-long-long-long...\\\") cannot be negated\"", results[0]);
}

test "jq:L1992 try (.-.) catch ." {
    const results = runFilter(
        "try (.-.) catch .",
        "\"very-long-long-long-long-string\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"string (\\\"very-long-long-long-long...\\\") and string (\\\"very-long-long-long-long...\\\") cannot be subtracted\"", results[0]);
}

test "jq:L1996 _x_ * range(0; 12; 2) + ___ * 8 | try -. catch ." {
    const results = runFilter(
        "\"x\" * range(0; 12; 2) + \"☆\" * 8 | try -. catch .",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 6), results.len);
    try std.testing.expectEqualStrings("\"string (\\\"☆☆☆☆☆☆☆☆\\\") cannot be negated\"", results[0]);
    try std.testing.expectEqualStrings("\"string (\\\"xx☆☆☆☆☆☆☆☆\\\") cannot be negated\"", results[1]);
    try std.testing.expectEqualStrings("\"string (\\\"xxxx☆☆☆☆☆☆...\\\") cannot be negated\"", results[2]);
    try std.testing.expectEqualStrings("\"string (\\\"xxxxxx☆☆☆☆☆☆...\\\") cannot be negated\"", results[3]);
    try std.testing.expectEqualStrings("\"string (\\\"xxxxxxxx☆☆☆☆☆...\\\") cannot be negated\"", results[4]);
    try std.testing.expectEqualStrings("\"string (\\\"xxxxxxxxxx☆☆☆☆...\\\") cannot be negated\"", results[5]);
}

test "jq:L2005 try (. + _x_) catch . == if have_decnum then _number (123..." {
    const results = runFilter(
        "try (. + \"x\") catch . == if have_decnum then \"number (12345678901234567890123456...) and string (\\\"x\\\") cannot be added\" else \"number (12345678901234568000000000...) and string (\\\"x\\\") cannot be added\" end",
        "123456789012345678901234567890",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2009 join(_,_)" {
    const results = runFilter(
        "join(\",\")",
        "[\"1\",2,true,false,3.4]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"1,2,true,false,3.4\"", results[0]);
}

test "jq:L2013 .[] | join(_,_)" {
    const results = runFilter(
        ".[] | join(\",\")",
        "[[], [null], [null,null], [null,null,null]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("\"\"", results[0]);
    try std.testing.expectEqualStrings("\"\"", results[1]);
    try std.testing.expectEqualStrings("\",\"", results[2]);
    try std.testing.expectEqualStrings("\",,\"", results[3]);
}

test "jq:L2020 .[] | join(_,_)" {
    const results = runFilter(
        ".[] | join(\",\")",
        "[[\"a\",null], [null,\"a\"]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("\"a,\"", results[0]);
    try std.testing.expectEqualStrings("\",a\"", results[1]);
}

test "jq:L2025 try join(_,_) catch ." {
    const results = runFilter(
        "try join(\",\") catch .",
        "[\"1\",\"2\",{\"a\":{\"b\":{\"c\":33}}}]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"string (\\\"1,2,\\\") and object ({\\\"a\\\":{\\\"b\\\":{\\\"c\\\":33}}}) cannot be added\"", results[0]);
}

test "jq:L2029 try join(_,_) catch ." {
    const results = runFilter(
        "try join(\",\") catch .",
        "[\"1\",\"2\",[3,4,5]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"string (\\\"1,2,\\\") and array ([3,4,5]) cannot be added\"", results[0]);
}

test "jq:L2033 {if:0,and:1,or:2,then:3,else:4,elif:5,end:6,as:7,def:8,re..." {
    const results = runFilter(
        "{if:0,and:1,or:2,then:3,else:4,elif:5,end:6,as:7,def:8,reduce:9,foreach:10,try:11,catch:12,label:13,import:14,include:15,module:16}",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"if\":0,\"and\":1,\"or\":2,\"then\":3,\"else\":4,\"elif\":5,\"end\":6,\"as\":7,\"def\":8,\"reduce\":9,\"foreach\":10,\"try\":11,\"catch\":12,\"label\":13,\"import\":14,\"include\":15,\"module\":16}", results[0]);
}

test "jq:L2037 try (1/.) catch ." {
    const results = runFilter(
        "try (1/.) catch .",
        "0",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"number (1) and number (0) cannot be divided because the divisor is zero\"", results[0]);
}

test "jq:L2041 try (1/0) catch ." {
    const results = runFilter(
        "try (1/0) catch .",
        "0",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"number (1) and number (0) cannot be divided because the divisor is zero\"", results[0]);
}

test "jq:L2045 try (0/0) catch ." {
    const results = runFilter(
        "try (0/0) catch .",
        "0",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"number (0) and number (0) cannot be divided because the divisor is zero\"", results[0]);
}

test "jq:L2049 try (1%.) catch ." {
    const results = runFilter(
        "try (1%.) catch .",
        "0",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"number (1) and number (0) cannot be divided (remainder) because the divisor is zero\"", results[0]);
}

test "jq:L2053 try (1%0) catch ." {
    const results = runFilter(
        "try (1%0) catch .",
        "0",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"number (1) and number (0) cannot be divided (remainder) because the divisor is zero\"", results[0]);
}

test "jq:L2058 [range(-52;52;1)] as $powers | [$powers[]|pow(2;.)|log2|r..." {
    const results = runFilter(
        "[range(-52;52;1)] as $powers | [$powers[]|pow(2;.)|log2|round] == $powers",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2062 [range(-99/2;99/2;1)] as $orig | [$orig[]|pow(2;.)|log2] ..." {
    const results = runFilter(
        "[range(-99/2;99/2;1)] as $orig | [$orig[]|pow(2;.)|log2] as $back | ($orig|keys)[]|. as $k | (($orig|.[$k])-($back|.[$k]))|if . < 0 then . * -1 else . end|select(.>.00005)",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:L2065 {" {
    // %%FAIL: filter should not compile
    try expectCompileError("{");
}

test "jq:L2071 }" {
    // %%FAIL: filter should not compile
    try expectCompileError("}");
}

test "jq:L2077 (.[{}] = 0)?" {
    const results = runFilter(
        "(.[{}] = 0)?",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:L2080 INDEX(range(5)|[., _foo_(.)_]; .[0])" {
    const results = runFilter(
        "INDEX(range(5)|[., \"foo\\(.)\"]; .[0])",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"0\":[0,\"foo0\"],\"1\":[1,\"foo1\"],\"2\":[2,\"foo2\"],\"3\":[3,\"foo3\"],\"4\":[4,\"foo4\"]}", results[0]);
}

test "jq:L2084 JOIN({_0_:[0,_abc_],_1_:[1,_bcd_],_2_:[2,_def_],_3_:[3,_e..." {
    const results = runFilter(
        "JOIN({\"0\":[0,\"abc\"],\"1\":[1,\"bcd\"],\"2\":[2,\"def\"],\"3\":[3,\"efg\"],\"4\":[4,\"fgh\"]}; .[0]|tostring)",
        "[[5,\"foo\"],[3,\"bar\"],[1,\"foobar\"]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[[5,\"foo\"],null],[[3,\"bar\"],[3,\"efg\"]],[[1,\"foobar\"],[1,\"bcd\"]]]", results[0]);
}

test "jq:L2088 range(5;10)|IN(range(10))" {
    const results = runFilter(
        "range(5;10)|IN(range(10))",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 5), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
    try std.testing.expectEqualStrings("true", results[1]);
    try std.testing.expectEqualStrings("true", results[2]);
    try std.testing.expectEqualStrings("true", results[3]);
    try std.testing.expectEqualStrings("true", results[4]);
}

test "jq:L2096 range(5;13)|IN(range(0;10;3))" {
    const results = runFilter(
        "range(5;13)|IN(range(0;10;3))",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 8), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
    try std.testing.expectEqualStrings("true", results[1]);
    try std.testing.expectEqualStrings("false", results[2]);
    try std.testing.expectEqualStrings("false", results[3]);
    try std.testing.expectEqualStrings("true", results[4]);
    try std.testing.expectEqualStrings("false", results[5]);
    try std.testing.expectEqualStrings("false", results[6]);
    try std.testing.expectEqualStrings("false", results[7]);
}

test "jq:L2107 range(10;12)|IN(range(10))" {
    const results = runFilter(
        "range(10;12)|IN(range(10))",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
    try std.testing.expectEqualStrings("false", results[1]);
}

test "jq:L2112 IN(range(10;20); range(10))" {
    const results = runFilter(
        "IN(range(10;20); range(10))",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L2116 IN(range(5;20); range(10))" {
    const results = runFilter(
        "IN(range(5;20); range(10))",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2121 (.a as $x | .b) = _b_" {
    const results = runFilter(
        "(.a as $x | .b) = \"b\"",
        "{\"a\":null,\"b\":null}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":null,\"b\":\"b\"}", results[0]);
}

test "jq:L2126 (.. | select(type == _object_ and has(_b_) and (.b | type..." {
    const results = runFilter(
        "(.. | select(type == \"object\" and has(\"b\") and (.b | type) == \"array\")|.b) |= .[0]",
        "{\"a\": {\"b\": [1, {\"b\": 3}]}}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\": {\"b\": 1}}", results[0]);
}

test "jq:L2130 isempty(empty)" {
    const results = runFilter(
        "isempty(empty)",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2134 isempty(range(3))" {
    const results = runFilter(
        "isempty(range(3))",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L2138 isempty(1,error(_foo_))" {
    const results = runFilter(
        "isempty(1,error(\"foo\"))",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L2143 index(__)" {
    const results = runFilter(
        "index(\"\")",
        "\"\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq:L2148 builtins|length > 10" {
    const results = runFilter(
        "builtins|length > 10",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2152 _-1_|IN(builtins[] / _/_|.[1])" {
    const results = runFilter(
        "\"-1\"|IN(builtins[] / \"/\"|.[1])",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L2156 all(builtins[] / _/_; .[1]|tonumber >= 0)" {
    const results = runFilter(
        "all(builtins[] / \"/\"; .[1]|tonumber >= 0)",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2160 builtins|any(.[:1] == ___)" {
    const results = runFilter(
        "builtins|any(.[:1] == \"_\")",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L2181 map(. == 1)" {
    const results = runFilter(
        "map(. == 1)",
        "[1, 1.0, 1.000, 100e-2, 1e+0, 0.0001e4]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true, true, true, true, true, true]", results[0]);
}

test "jq:L2187 .[0] | tostring | . == if have_decnum then _1391186036643..." {
    const results = runFilter(
        ".[0] | tostring | . == if have_decnum then \"13911860366432393\" else \"13911860366432392\" end",
        "[13911860366432393]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2191 .x | tojson | . == if have_decnum then _13911860366432393..." {
    const results = runFilter(
        ".x | tojson | . == if have_decnum then \"13911860366432393\" else \"13911860366432392\" end",
        "{\"x\":13911860366432393}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2195 (13911860366432393 == 13911860366432392) | . == if have_d..." {
    const results = runFilter(
        "(13911860366432393 == 13911860366432392) | . == if have_decnum then false else true end",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2202 . - 10" {
    const results = runFilter(
        ". - 10",
        "13911860366432393",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("13911860366432382", results[0]);
}

test "jq:L2206 .[0] - 10" {
    const results = runFilter(
        ".[0] - 10",
        "[13911860366432393]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("13911860366432382", results[0]);
}

test "jq:L2210 .x - 10" {
    const results = runFilter(
        ".x - 10",
        "{\"x\":13911860366432393}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("13911860366432382", results[0]);
}

test "jq:L2215 -. | tojson == if have_decnum then _-13911860366432393_ e..." {
    const results = runFilter(
        "-. | tojson == if have_decnum then \"-13911860366432393\" else \"-13911860366432392\" end",
        "13911860366432393",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2219 -. | tojson == if have_decnum then _0.1234567890123456789..." {
    const results = runFilter(
        "-. | tojson == if have_decnum then \"0.12345678901234567890123456789\" else \"0.12345678901234568\" end",
        "-0.12345678901234567890123456789",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2223 [1E+1000,-1E+1000 | tojson] == if have_decnum then [_1E+1..." {
    const results = runFilter(
        "[1E+1000,-1E+1000 | tojson] == if have_decnum then [\"1E+1000\",\"-1E+1000\"] else [\"1.7976931348623157e+308\",\"-1.7976931348623157e+308\"] end",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2227 . |= try . catch ." {
    const results = runFilter(
        ". |= try . catch .",
        "1",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L2232 .[] as $n | $n+0 | [., tostring, . == $n]" {
    const results = runFilter(
        ".[] as $n | $n+0 | [., tostring, . == $n]",
        "[-9007199254740993, -9007199254740992, 9007199254740992, 9007199254740993, 13911860366432393]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 5), results.len);
    try std.testing.expectEqualStrings("[-9007199254740992,\"-9007199254740992\",true]", results[0]);
    try std.testing.expectEqualStrings("[-9007199254740992,\"-9007199254740992\",true]", results[1]);
    try std.testing.expectEqualStrings("[9007199254740992,\"9007199254740992\",true]", results[2]);
    try std.testing.expectEqualStrings("[9007199254740992,\"9007199254740992\",true]", results[3]);
    try std.testing.expectEqualStrings("[13911860366432392,\"13911860366432392\",true]", results[4]);
}

test "jq:L2241 abs" {
    const results = runFilter(
        "abs",
        "\"abc\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"abc\"", results[0]);
}

test "jq:L2245 map(abs)" {
    const results = runFilter(
        "map(abs)",
        "[-0, 0, -10, -1.1]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,0,10,1.1]", results[0]);
}

test "jq:L2249 map(fabs)" {
    const results = runFilter(
        "map(fabs)",
        "[-0, 0, -10, -1.1]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,0,10,1.1]", results[0]);
}

test "jq:L2253 map(abs == length) | unique" {
    const results = runFilter(
        "map(abs == length) | unique",
        "[-10, -1.1, -1e-1, 1000000000000000002]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true]", results[0]);
}

test "jq:L2258 map(abs)" {
    const results = runFilter(
        "map(abs)",
        "[0.1,1000000000000000002]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1e-1, 1000000000000000002]", results[0]);
}

test "jq:L2262 [1E+1000,-1E+1000 | abs | tojson] | unique == if have_dec..." {
    const results = runFilter(
        "[1E+1000,-1E+1000 | abs | tojson] | unique == if have_decnum then [\"1E+1000\"] else [\"1.7976931348623157e+308\"] end",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2266 [1E+1000,-1E+1000 | length | tojson] | unique == if have_..." {
    const results = runFilter(
        "[1E+1000,-1E+1000 | length | tojson] | unique == if have_decnum then [\"1E+1000\"] else [\"1.7976931348623157e+308\"] end",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2272 123 as $label | $label" {
    const results = runFilter(
        "123 as $label | $label",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("123", results[0]);
}

test "jq:L2276 [ label $if | range(10) | ., (select(. == 5) | break $if) ]" {
    const results = runFilter(
        "[ label $if | range(10) | ., (select(. == 5) | break $if) ]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,3,4,5]", results[0]);
}

test "jq:L2280 reduce .[] as $then (4 as $else | $else; . as $elif | . +..." {
    const results = runFilter(
        "reduce .[] as $then (4 as $else | $else; . as $elif | . + $then * $elif)",
        "[1,2,3]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("96", results[0]);
}

test "jq:L2284 1 as $foreach | 2 as $and | 3 as $or | { $foreach, $and, ..." {
    const results = runFilter(
        "1 as $foreach | 2 as $and | 3 as $or | { $foreach, $and, $or, a }",
        "{\"a\":4,\"b\":5}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"foreach\":1,\"and\":2,\"or\":3,\"a\":4}", results[0]);
}

test "jq:L2288 [ foreach .[] as $try (1 as $catch | $catch - 1; . + $try..." {
    const results = runFilter(
        "[ foreach .[] as $try (1 as $catch | $catch - 1; . + $try; .) ]",
        "[10,9,8,7]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[10,19,27,34]", results[0]);
}

test "jq:L2295 { a, $__loc__, c }" {
    const results = runFilter(
        "{ a, $__loc__, c }",
        "{\"a\":[1,2,3],\"b\":\"foo\",\"c\":{\"hi\":\"hey\"}}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":[1,2,3],\"__loc__\":{\"file\":\"<top-level>\",\"line\":1},\"c\":{\"hi\":\"hey\"}}", results[0]);
}

test "jq:L2299 1 as $x | _2_ as $y | _3_ as $z | { $x, as, $y: 4, ($z): ..." {
    const results = runFilter(
        "1 as $x | \"2\" as $y | \"3\" as $z | { $x, as, $y: 4, ($z): 5, if: 6, foo: 7 }",
        "{\"as\":8}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"x\":1,\"as\":8,\"2\":4,\"3\":5,\"if\":6,\"foo\":7}", results[0]);
}

test "jq:L2306 fromjson | isnan" {
    const results = runFilter(
        "fromjson | isnan",
        "\"nan\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2310 tojson | fromjson" {
    const results = runFilter(
        "tojson | fromjson",
        "{\"a\":nan}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":null}", results[0]);
}

test "jq:L2315 .[] | try (fromjson | isnan) catch ." {
    const results = runFilter(
        ".[] | try (fromjson | isnan) catch .",
        "[\"NaN\",\"-NaN\",\"NaN1\",\"NaN10\",\"NaN100\",\"NaN1000\",\"NaN10000\",\"NaN100000\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 8), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
    try std.testing.expectEqualStrings("true", results[1]);
    try std.testing.expectEqualStrings("\"Invalid numeric literal at EOF at line 1, column 4 (while parsing 'NaN1')\"", results[2]);
    try std.testing.expectEqualStrings("\"Invalid numeric literal at EOF at line 1, column 5 (while parsing 'NaN10')\"", results[3]);
    try std.testing.expectEqualStrings("\"Invalid numeric literal at EOF at line 1, column 6 (while parsing 'NaN100')\"", results[4]);
    try std.testing.expectEqualStrings("\"Invalid numeric literal at EOF at line 1, column 7 (while parsing 'NaN1000')\"", results[5]);
    try std.testing.expectEqualStrings("\"Invalid numeric literal at EOF at line 1, column 8 (while parsing 'NaN10000')\"", results[6]);
    try std.testing.expectEqualStrings("\"Invalid numeric literal at EOF at line 1, column 9 (while parsing 'NaN100000')\"", results[7]);
}

test "jq:L2328 try input catch ." {
    const results = runFilter(
        "try input catch .",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"break\"", results[0]);
}

test "jq:L2332 debug" {
    const results = runFilter(
        "debug",
        "1",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L2337 _foo_ | try ((try . catch _caught too much_) | error) cat..." {
    const results = runFilter(
        "\"foo\" | try ((try . catch \"caught too much\") | error) catch \"caught just right\"",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"caught just right\"", results[0]);
}

test "jq:L2341 .[]|(try (if .==_hi_ then . else error end) catch empty) ..." {
    const results = runFilter(
        ".[]|(try (if .==\"hi\" then . else error end) catch empty) | \"\\(.) there!\"",
        "[\"hi\",\"ho\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"hi there!\"", results[0]);
}

test "jq:L2345 try ([_hi_,_ho_]|.[]|(try . catch (if .==_ho_ then _BROKE..." {
    const results = runFilter(
        "try ([\"hi\",\"ho\"]|.[]|(try . catch (if .==\"ho\" then \"BROKEN\"|error else empty end)) | if .==\"ho\" then error else \"\\(.) there!\" end) catch \"caught outside \\(.)\"",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("\"hi there!\"", results[0]);
    try std.testing.expectEqualStrings("\"caught outside ho\"", results[1]);
}

test "jq:L2350 .[]|(try . catch (if .==_ho_ then _BROKEN_|error else emp..." {
    const results = runFilter(
        ".[]|(try . catch (if .==\"ho\" then \"BROKEN\"|error else empty end)) | if .==\"ho\" then error else \"\\(.) there!\" end",
        "[\"hi\",\"ho\"]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"hi there!\"", results[0]);
}

test "jq:L2354 try (try error catch _inner catch _(.)_) catch _outer cat..." {
    const results = runFilter(
        "try (try error catch \"inner catch \\(.)\") catch \"outer catch \\(.)\"",
        "\"foo\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"inner catch foo\"", results[0]);
}

test "jq:L2358 try ((try error catch _inner catch _(.)_)|error) catch _o..." {
    const results = runFilter(
        "try ((try error catch \"inner catch \\(.)\")|error) catch \"outer catch \\(.)\"",
        "\"foo\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"outer catch inner catch foo\"", results[0]);
}

test "jq:L2363 first(.?,.?)" {
    const results = runFilter(
        "first(.?,.?)",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq:L2368 {foo: _bar_} | .foo |= .?" {
    const results = runFilter(
        "{foo: \"bar\"} | .foo |= .?",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"foo\": \"bar\"}", results[0]);
}

test "jq:L2373 . |= try 2" {
    const results = runFilter(
        ". |= try 2",
        "1",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("2", results[0]);
}

test "jq:L2377 . |= try 2 catch 3" {
    const results = runFilter(
        ". |= try 2 catch 3",
        "1",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("2", results[0]);
}

test "jq:L2381 .[] |= try tonumber" {
    const results = runFilter(
        ".[] |= try tonumber",
        "[\"1\", \"2a\", \"3\", \" 4\", \"5 \", \"6.7\", \".89\", \"-876\", \"+5.43\", 21]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1, 3, 6.7, 0.89, -876, 5.43, 21]", results[0]);
}

test "jq:L2386 any(keys[]|tostring?;true)" {
    const results = runFilter(
        "any(keys[]|tostring?;true)",
        "{\"a\":\"1\",\"b\":\"2\",\"c\":\"3\"}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2394 implode|explode" {
    const results = runFilter(
        "implode|explode",
        "[-1,0,1,2,3,1114111,1114112,55295,55296,57343,57344,1.1,1.9]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[65533,0,1,2,3,1114111,65533,55295,65533,65533,57344,1,1]", results[0]);
}

test "jq:L2398 map(try implode catch .)" {
    const results = runFilter(
        "map(try implode catch .)",
        "[123,[\"a\"],[nan]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"implode input must be an array\",\"string (\\\"a\\\") can't be imploded, unicode codepoint needs to be numeric\",\"number (null) can't be imploded, unicode codepoint needs to be numeric\"]", results[0]);
}

test "jq:L2402 try 0[implode] catch ." {
    const results = runFilter(
        "try 0[implode] catch .",
        "[]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Cannot index number with string (\\\"\\\")\"", results[0]);
}

test "jq:L2407 walk(.)" {
    const results = runFilter(
        "walk(.)",
        "{\"x\":0}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"x\":0}", results[0]);
}

test "jq:L2411 walk(1)" {
    const results = runFilter(
        "walk(1)",
        "{\"x\":0}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L2416 [walk(.,1)]" {
    const results = runFilter(
        "[walk(.,1)]",
        "{\"x\":0}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[{\"x\":0},1]", results[0]);
}

test "jq:L2421 walk(select(IN({}, []) | not))" {
    const results = runFilter(
        "walk(select(IN({}, []) | not))",
        "{\"a\":1,\"b\":[]}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":1}", results[0]);
}

test "jq:L2426 [range(10)] | .[1.2:3.5]" {
    const results = runFilter(
        "[range(10)] | .[1.2:3.5]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L2430 [range(10)] | .[1.5:3.5]" {
    const results = runFilter(
        "[range(10)] | .[1.5:3.5]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L2434 [range(10)] | .[1.7:3.5]" {
    const results = runFilter(
        "[range(10)] | .[1.7:3.5]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L2438 [range(10)] | .[1.7:4294967295]" {
    const results = runFilter(
        "[range(10)] | .[1.7:4294967295]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3,4,5,6,7,8,9]", results[0]);
}

test "jq:L2442 [range(10)] | .[1.7:-4294967296]" {
    const results = runFilter(
        "[range(10)] | .[1.7:-4294967296]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L2446 [[range(10)] | .[1.1,1.5,1.7]]" {
    const results = runFilter(
        "[[range(10)] | .[1.1,1.5,1.7]]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,1,1]", results[0]);
}

test "jq:L2450 [range(5)] | .[1.1] = 5" {
    const results = runFilter(
        "[range(5)] | .[1.1] = 5",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,5,2,3,4]", results[0]);
}

test "jq:L2454 [range(3)] | .[nan:1]" {
    const results = runFilter(
        "[range(3)] | .[nan:1]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0]", results[0]);
}

test "jq:L2458 [range(3)] | .[1:nan]" {
    const results = runFilter(
        "[range(3)] | .[1:nan]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2]", results[0]);
}

test "jq:L2462 [range(3)] | .[nan]" {
    const results = runFilter(
        "[range(3)] | .[nan]",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq:L2466 try ([range(3)] | .[nan] = 9) catch ." {
    const results = runFilter(
        "try ([range(3)] | .[nan] = 9) catch .",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Cannot set array element at NaN index\"", results[0]);
}

test "jq:L2470 try (_foobar_ | .[1.5:3.5] = _xyz_) catch ." {
    const results = runFilter(
        "try (\"foobar\" | .[1.5:3.5] = \"xyz\") catch .",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Cannot update string slices\"", results[0]);
}

test "jq:L2474 try ([range(10)] | .[1.5:3.5] = [_xyz_]) catch ." {
    const results = runFilter(
        "try ([range(10)] | .[1.5:3.5] = [\"xyz\"]) catch .",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,\"xyz\",4,5,6,7,8,9]", results[0]);
}

test "jq:L2478 try (_foobar_ | .[1.5]) catch ." {
    const results = runFilter(
        "try (\"foobar\" | .[1.5]) catch .",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Cannot index string with number (1.5)\"", results[0]);
}

test "jq:L2485 try [_ok_, setpath([1]; 1)] catch [_ko_, .]" {
    const results = runFilter(
        "try [\"ok\", setpath([1]; 1)] catch [\"ko\", .]",
        "{\"hi\":\"hello\"}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"ko\",\"Cannot index object with number (1)\"]", results[0]);
}

test "jq:L2489 try fromjson catch ." {
    const results = runFilter(
        "try fromjson catch .",
        "\"{'a': 123}\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid string literal; expected \\\", but got ' at line 1, column 5 (while parsing '{'a': 123}')\"", results[0]);
}

test "jq:L2495 try ltrimstr(1) catch _x_, try rtrimstr(1) catch _x_ | _ok_" {
    const results = runFilter(
        "try ltrimstr(1) catch \"x\", try rtrimstr(1) catch \"x\" | \"ok\"",
        "\"hi\"",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("\"ok\"", results[0]);
    try std.testing.expectEqualStrings("\"ok\"", results[1]);
}

test "jq:L2500 try ltrimstr(_x_) catch _x_, try rtrimstr(_x_) catch _x_ ..." {
    const results = runFilter(
        "try ltrimstr(\"x\") catch \"x\", try rtrimstr(\"x\") catch \"x\" | \"ok\"",
        "{\"hey\":[]}",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("\"ok\"", results[0]);
    try std.testing.expectEqualStrings("\"ok\"", results[1]);
}

test "jq:L2507 .[] as [$x, $y] | try [_ok_, ($x | ltrimstr($y))] catch [..." {
    const results = runFilter(
        ".[] as [$x, $y] | try [\"ok\", ($x | ltrimstr($y))] catch [\"ko\", .]",
        "[[\"hi\",1],[1,\"hi\"],[\"hi\",\"hi\"],[1,1]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[\"ko\",\"startswith() requires string inputs\"]", results[0]);
    try std.testing.expectEqualStrings("[\"ko\",\"startswith() requires string inputs\"]", results[1]);
    try std.testing.expectEqualStrings("[\"ok\",\"\"]", results[2]);
    try std.testing.expectEqualStrings("[\"ko\",\"startswith() requires string inputs\"]", results[3]);
}

test "jq:L2514 .[] as [$x, $y] | try [_ok_, ($x | rtrimstr($y))] catch [..." {
    const results = runFilter(
        ".[] as [$x, $y] | try [\"ok\", ($x | rtrimstr($y))] catch [\"ko\", .]",
        "[[\"hi\",1],[1,\"hi\"],[\"hi\",\"hi\"],[1,1]]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[\"ko\",\"endswith() requires string inputs\"]", results[0]);
    try std.testing.expectEqualStrings("[\"ko\",\"endswith() requires string inputs\"]", results[1]);
    try std.testing.expectEqualStrings("[\"ok\",\"\"]", results[2]);
    try std.testing.expectEqualStrings("[\"ko\",\"endswith() requires string inputs\"]", results[3]);
}

test "jq:L2524 try [_OK_, setpath([[1]]; 1)] catch [_KO_, .]" {
    const results = runFilter(
        "try [\"OK\", setpath([[1]]; 1)] catch [\"KO\", .]",
        "[]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"KO\",\"Cannot update field at array index of array\"]", results[0]);
}

test "jq:L2529 foreach .[] as $x (0, 1; . + $x)" {
    const results = runFilter(
        "foreach .[] as $x (0, 1; . + $x)",
        "[1, 2]",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("3", results[1]);
    try std.testing.expectEqualStrings("2", results[2]);
    try std.testing.expectEqualStrings("4", results[3]);
}

test "jq:L2539 strflocaltime(__ | ., @uri)" {
    const results = runFilter(
        "strflocaltime(\"\" | ., @uri)",
        "0",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("\"\"", results[0]);
    try std.testing.expectEqualStrings("\"\"", results[1]);
}

test "jq:L2549 reduce range(9999) as $_ ([];[.]) | tojson | fromjson | f..." {
    const results = runFilter(
        "reduce range(9999) as $_ ([];[.]) | tojson | fromjson | flatten",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L2554 reduce range(10000) as $_ ([];[.]) | tojson | try (fromjs..." {
    const results = runFilter(
        "reduce range(10000) as $_ ([];[.]) | tojson | try (fromjson) catch . | (contains(\"<skipped: too deep>\") | not) and contains(\"Exceeds depth limit for parsing\")",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2559 reduce range(10001) as $_ ([];[.]) | tojson | contains(_<..." {
    const results = runFilter(
        "reduce range(10001) as $_ ([];[.]) | tojson | contains(\"<skipped: too deep>\")",
        "null",
    ) catch |e| switch (e) {
        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented
        else => return e, // real failure: wrong type, bad input, etc.
    };
    defer { for (results) |s| alloc.free(s); alloc.free(results); }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

