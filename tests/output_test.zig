const std = @import("std");
const output = @import("output");
const types = @import("types");

const Writer = output.Writer;
const Value = types.Value;
const Format = types.Format;
const Tape = types.Tape;
const Entry = types.Tape.Entry;
const Tag = types.Tape.Tag;
const Payload = types.Tape.Payload;
const StringRef = types.Tape.StringRef;

const alloc = std.testing.allocator;

// ── Tape construction helpers ─────────────────────────────────────────────────

fn makeTape(entries: []const Entry, string_buf: []const u8) Tape {
    return Tape{ .entries = entries, .string_buf = string_buf };
}

fn strRef(buf: []const u8, s: []const u8) StringRef {
    const off = std.mem.indexOf(u8, buf, s) orelse unreachable;
    return .{ .offset = @intCast(off), .len = @intCast(s.len) };
}

// ── Writer round-trip helper ──────────────────────────────────────────────────
//
// Creates a Writer targeting a pipe's write-end, writes a value, flushes,
// then reads the pipe's read-end to obtain the rendered bytes as a slice.
// The caller is responsible for freeing the returned slice.
fn renderValue(val: Value, format: Format) ![]u8 {
    const fds = try std.posix.pipe();

    // Write side: use a Writer, flush, deinit, then close write fd.
    {
        var w = try Writer.init(std.fs.File{ .handle = fds[1] }, alloc);
        errdefer {
            w.deinit();
            std.posix.close(fds[1]);
            std.posix.close(fds[0]);
        }
        try w.write_value(val, format, null, .{});
        // flush is called by deinit; call it explicitly here and close write end.
        try w.flush();
        w.deinit();
    }
    std.posix.close(fds[1]);

    // Read side.
    defer std.posix.close(fds[0]);
    var out = std.ArrayList(u8){};
    errdefer out.deinit(alloc);
    var tmp: [8192]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fds[0], &tmp);
        if (n == 0) break;
        try out.appendSlice(alloc, tmp[0..n]);
    }
    return out.toOwnedSlice(alloc);
}

// ── init / deinit ─────────────────────────────────────────────────────────────

test "init/deinit: stdout writer initializes and deinits cleanly" {
    var w = try Writer.init(std.fs.File.stdout(), alloc);
    defer w.deinit();
    // No assertion needed — absence of crash or memory leak is the invariant.
    _ = w.is_tty();
}

test "is_tty: pipe fd is not a tty" {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var w = try Writer.init(std.fs.File{ .handle = fds[1] }, alloc);
    defer w.deinit();

    try std.testing.expect(!w.is_tty());
}

// ── Scalars: compact ─────────────────────────────────────────────────────────

test "compact: null" {
    const s = try renderValue(.null_val, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("null", s);
}

test "compact: true" {
    const s = try renderValue(.{ .bool_val = true }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("true", s);
}

test "compact: false" {
    const s = try renderValue(.{ .bool_val = false }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("false", s);
}

test "compact: integer zero" {
    const s = try renderValue(.{ .int = 0 }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("0", s);
}

test "compact: positive integer" {
    const s = try renderValue(.{ .int = 42 }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("42", s);
}

test "compact: negative integer" {
    const s = try renderValue(.{ .int = -99 }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("-99", s);
}

test "compact: i64 min boundary" {
    const s = try renderValue(.{ .int = std.math.minInt(i64) }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("-9223372036854775808", s);
}

test "compact: i64 max boundary" {
    const s = try renderValue(.{ .int = std.math.maxInt(i64) }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("9223372036854775807", s);
}

test "compact: float 3.14" {
    const s = try renderValue(.{ .float = 3.14 }, .compact);
    defer alloc.free(s);
    // The exact representation varies; parse back and check round-trip.
    const parsed = try std.fmt.parseFloat(f64, s);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), parsed, 1e-9);
}

test "compact: float 0.0" {
    const s = try renderValue(.{ .float = 0.0 }, .compact);
    defer alloc.free(s);
    const parsed = try std.fmt.parseFloat(f64, s);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), parsed, 1e-15);
}

test "compact: float infinity renders as clamped DBL_MAX" {
    // jq clamps ±Inf to ±DBL_MAX before formatting (jv_print.c). Previously
    // zq emitted "null" here, diverging from jq's non-decnum behaviour.
    const s = try renderValue(.{ .float = std.math.inf(f64) }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("1.7976931348623157e+308", s);
}

test "compact: float -infinity renders as clamped -DBL_MAX" {
    const s = try renderValue(.{ .float = -std.math.inf(f64) }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("-1.7976931348623157e+308", s);
}

test "compact: float nan renders as null" {
    const s = try renderValue(.{ .float = std.math.nan(f64) }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("null", s);
}

test "compact: empty string" {
    const s = try renderValue(.{ .string = "" }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"\"", s);
}

test "compact: simple string" {
    const s = try renderValue(.{ .string = "hello" }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"hello\"", s);
}

test "compact: string with double quote" {
    const s = try renderValue(.{ .string = "say \"hi\"" }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\"", s);
}

test "compact: string with backslash" {
    const s = try renderValue(.{ .string = "a\\b" }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"a\\\\b\"", s);
}

test "compact: string with newline" {
    const s = try renderValue(.{ .string = "line1\nline2" }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"line1\\nline2\"", s);
}

test "compact: string with tab" {
    const s = try renderValue(.{ .string = "a\tb" }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"a\\tb\"", s);
}

test "compact: string with carriage return" {
    const s = try renderValue(.{ .string = "a\rb" }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"a\\rb\"", s);
}

test "compact: string with control character (0x01)" {
    const s = try renderValue(.{ .string = "\x01" }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"\\u0001\"", s);
}

test "compact: string with backspace (0x08)" {
    const s = try renderValue(.{ .string = "\x08" }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"\\b\"", s);
}

test "compact: string with form feed (0x0C)" {
    const s = try renderValue(.{ .string = "\x0C" }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"\\f\"", s);
}

// ── Arrays: compact ───────────────────────────────────────────────────────────

test "compact: empty array" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 2 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, "");
    const val = Value{ .array = .{ .tape = &t, .start = 0, .end = 2 } };
    const s = try renderValue(val, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("[]", s);
}

test "compact: array of integers" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 5 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .int, .payload = .{ .int = 2 } },
        .{ .tag = .int, .payload = .{ .int = 3 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, "");
    const val = Value{ .array = .{ .tape = &t, .start = 0, .end = 5 } };
    const s = try renderValue(val, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("[1,2,3]", s);
}

test "compact: array of mixed types" {
    const sb = "hi";
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 6 } },
        .{ .tag = .null_val, .payload = .{ .none = {} } },
        .{ .tag = .true_val, .payload = .{ .none = {} } },
        .{ .tag = .int, .payload = .{ .int = 7 } },
        .{ .tag = .string, .payload = .{ .string = .{ .offset = 0, .len = 2 } } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, sb);
    const val = Value{ .array = .{ .tape = &t, .start = 0, .end = 6 } };
    const s = try renderValue(val, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("[null,true,7,\"hi\"]", s);
}

test "compact: nested array" {
    // [[1, 2], [3]]
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 9 } },
        .{ .tag = .array_start, .payload = .{ .skip = 5 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .int, .payload = .{ .int = 2 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
        .{ .tag = .array_start, .payload = .{ .skip = 8 } },
        .{ .tag = .int, .payload = .{ .int = 3 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, "");
    const val = Value{ .array = .{ .tape = &t, .start = 0, .end = 9 } };
    const s = try renderValue(val, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("[[1,2],[3]]", s);
}

// ── Objects: compact ──────────────────────────────────────────────────────────

test "compact: empty object" {
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 2 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, "");
    const val = Value{ .object = .{ .tape = &t, .start = 0, .end = 2 } };
    const s = try renderValue(val, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("{}", s);
}

test "compact: object with one key" {
    // {"foo": 99}
    const sb = "foo";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 3 } } },
        .{ .tag = .int, .payload = .{ .int = 99 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, sb);
    const val = Value{ .object = .{ .tape = &t, .start = 0, .end = 4 } };
    const s = try renderValue(val, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("{\"foo\":99}", s);
}

test "compact: object with multiple keys" {
    // {"a": 1, "b": true}
    const sb = "ab";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 6 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 1, .len = 1 } } },
        .{ .tag = .true_val, .payload = .{ .none = {} } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, sb);
    const val = Value{ .object = .{ .tape = &t, .start = 0, .end = 6 } };
    const s = try renderValue(val, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":true}", s);
}

test "compact: nested object" {
    // {"x": {"y": 2}}
    const sb = "xy";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 7 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .object_start, .payload = .{ .skip = 6 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 1, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 2 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, sb);
    const val = Value{ .object = .{ .tape = &t, .start = 0, .end = 7 } };
    const s = try renderValue(val, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("{\"x\":{\"y\":2}}", s);
}

// ── Pretty format ─────────────────────────────────────────────────────────────

test "pretty: null scalar" {
    const s = try renderValue(.null_val, .pretty);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("null", s);
}

test "pretty: integer scalar" {
    const s = try renderValue(.{ .int = 5 }, .pretty);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("5", s);
}

test "pretty: string scalar" {
    const s = try renderValue(.{ .string = "hi" }, .pretty);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"hi\"", s);
}

test "pretty: empty array" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 2 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, "");
    const val = Value{ .array = .{ .tape = &t, .start = 0, .end = 2 } };
    const s = try renderValue(val, .pretty);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("[]", s);
}

test "pretty: empty object" {
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 2 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, "");
    const val = Value{ .object = .{ .tape = &t, .start = 0, .end = 2 } };
    const s = try renderValue(val, .pretty);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("{}", s);
}

test "pretty: array of integers has newlines and 2-space indent" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 4 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .int, .payload = .{ .int = 2 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, "");
    const val = Value{ .array = .{ .tape = &t, .start = 0, .end = 4 } };
    const s = try renderValue(val, .pretty);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("[\n  1,\n  2\n]", s);
}

test "pretty: object with one key" {
    const sb = "k";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 42 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, sb);
    const val = Value{ .object = .{ .tape = &t, .start = 0, .end = 4 } };
    const s = try renderValue(val, .pretty);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("{\n  \"k\": 42\n}", s);
}

test "pretty: nested object indents correctly" {
    // {"a": {"b": 1}}
    const sb = "ab";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 7 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .object_start, .payload = .{ .skip = 6 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 1, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, sb);
    const val = Value{ .object = .{ .tape = &t, .start = 0, .end = 7 } };
    const s = try renderValue(val, .pretty);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("{\n  \"a\": {\n    \"b\": 1\n  }\n}", s);
}

// ── Raw format ────────────────────────────────────────────────────────────────

test "raw: string omits quotes" {
    const s = try renderValue(.{ .string = "hello world" }, .raw);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("hello world", s);
}

test "raw: empty string produces empty output" {
    const s = try renderValue(.{ .string = "" }, .raw);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("", s);
}

test "raw: null renders as compact null (not empty)" {
    const s = try renderValue(.null_val, .raw);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("null", s);
}

test "raw: integer renders as compact JSON" {
    const s = try renderValue(.{ .int = -5 }, .raw);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("-5", s);
}

test "raw: bool renders as compact JSON" {
    const s = try renderValue(.{ .bool_val = true }, .raw);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("true", s);
}

test "raw: string with newline is emitted literally (no escape)" {
    const s = try renderValue(.{ .string = "a\nb" }, .raw);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("a\nb", s);
}

// ── JSONL format ──────────────────────────────────────────────────────────────

test "jsonl: null ends with newline" {
    const s = try renderValue(.null_val, .jsonl);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("null\n", s);
}

test "jsonl: integer ends with newline" {
    const s = try renderValue(.{ .int = 7 }, .jsonl);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("7\n", s);
}

test "jsonl: string ends with newline (quoted)" {
    const s = try renderValue(.{ .string = "x" }, .jsonl);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"x\"\n", s);
}

test "jsonl: array ends with newline (compact)" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 3 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, "");
    const val = Value{ .array = .{ .tape = &t, .start = 0, .end = 3 } };
    const s = try renderValue(val, .jsonl);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("[1]\n", s);
}

// ── Multiple values written sequentially ─────────────────────────────────────

test "multiple writes: compact values accumulate in buffer" {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);

    var w = try Writer.init(std.fs.File{ .handle = fds[1] }, alloc);

    try w.write_value(.{ .int = 1 }, .compact, null, .{});
    try w.write_value(.{ .int = 2 }, .compact, null, .{});
    try w.write_value(.{ .int = 3 }, .compact, null, .{});
    try w.flush();
    w.deinit();
    std.posix.close(fds[1]);

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    var tmp: [64]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fds[0], &tmp);
        if (n == 0) break;
        try out.appendSlice(alloc, tmp[0..n]);
    }
    try std.testing.expectEqualStrings("123", out.items);
}

test "multiple writes: jsonl values each have their own newline" {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);

    var w = try Writer.init(std.fs.File{ .handle = fds[1] }, alloc);

    try w.write_value(.{ .int = 10 }, .jsonl, null, .{});
    try w.write_value(.{ .int = 20 }, .jsonl, null, .{});
    try w.flush();
    w.deinit();
    std.posix.close(fds[1]);

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    var tmp: [64]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fds[0], &tmp);
        if (n == 0) break;
        try out.appendSlice(alloc, tmp[0..n]);
    }
    try std.testing.expectEqualStrings("10\n20\n", out.items);
}

// ── flush idempotency ─────────────────────────────────────────────────────────

test "flush: flushing empty buffer is a no-op" {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var w = try Writer.init(std.fs.File{ .handle = fds[1] }, alloc);
    defer w.deinit();

    // Flush with nothing buffered should not error.
    try w.flush();
    try w.flush();
}

// ── String escape boundary cases ──────────────────────────────────────────────

test "compact: all JSON-required escapes appear correctly" {
    // Build a string containing every character that must be escaped.
    const input = "\"\\\n\r\t\x08\x0C";
    const s = try renderValue(.{ .string = input }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"\\\"\\\\\\n\\r\\t\\b\\f\"", s);
}

test "compact: high-ASCII (>= 0x80) is emitted verbatim (UTF-8 passthrough)" {
    // UTF-8 bytes above 0x7F are not escaped by the JSON spec; we pass them through.
    const input = "\xC3\xA9"; // U+00E9 'é' in UTF-8
    const s = try renderValue(.{ .string = input }, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"\xC3\xA9\"", s);
}

// ── Object key escaping ───────────────────────────────────────────────────────

test "compact: object key with special characters is escaped" {
    const sb = "k\"e";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 3 } } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = makeTape(&entries, sb);
    const val = Value{ .object = .{ .tape = &t, .start = 0, .end = 4 } };
    const s = try renderValue(val, .compact);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("{\"k\\\"e\":1}", s);
}
