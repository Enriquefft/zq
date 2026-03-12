/// Tests for the C ABI bridge module.
///
/// The exported functions (`zq_compile`, `zq_execute`, `zq_get_result`,
/// `zq_free`) are Zig `export fn` declarations and are callable directly from
/// Zig test code without FFI overhead. All tests exercise the public C surface
/// only — no internal `QueryHandle` fields are accessed.
const std = @import("std");
const c_abi = @import("c_abi");

const zq_compile = c_abi.zq_compile;
const zq_execute = c_abi.zq_execute;
const zq_get_result = c_abi.zq_get_result;
const zq_free = c_abi.zq_free;

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Call zq_execute and return the result as a Zig slice.
/// Asserts that execute returned 0 (success).
fn execute(handle: anytype, input: []const u8) []const u8 {
    const rc = zq_execute(handle, input.ptr, input.len);
    if (rc != 0) std.debug.panic("zq_execute returned {d} for input: {s}", .{ rc, input });
    const ptr = zq_get_result(handle);
    return std.mem.sliceTo(ptr, 0);
}

/// Compile a query, asserting success.
fn mustCompile(query_str: [:0]const u8) *c_abi.QueryHandle {
    return zq_compile(query_str.ptr) orelse
        std.debug.panic("zq_compile failed for: {s}", .{query_str});
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

test "compile and free: basic lifecycle" {
    const h = mustCompile(".");
    zq_free(h);
}

test "compile: invalid query returns null" {
    const result = zq_compile("|");
    try std.testing.expectEqual(@as(?*c_abi.QueryHandle, null), result);
}

test "compile: empty query string returns null" {
    const result = zq_compile("");
    try std.testing.expectEqual(@as(?*c_abi.QueryHandle, null), result);
}

test "compile: trailing dot returns null" {
    const result = zq_compile(".foo.");
    try std.testing.expectEqual(@as(?*c_abi.QueryHandle, null), result);
}

test "compile: unbalanced bracket returns null" {
    const result = zq_compile(".[");
    try std.testing.expectEqual(@as(?*c_abi.QueryHandle, null), result);
}

// ── zq_get_result before execute: empty string ───────────────────────────────

test "get_result before execute: returns empty string" {
    const h = mustCompile(".");
    defer zq_free(h);
    const ptr = zq_get_result(h);
    const s = std.mem.sliceTo(ptr, 0);
    try std.testing.expectEqualStrings("", s);
}

// ── Identity (.) ─────────────────────────────────────────────────────────────

test "identity: integer" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "42");
    try std.testing.expectEqualStrings("42", s);
}

test "identity: negative integer" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "-7");
    try std.testing.expectEqualStrings("-7", s);
}

test "identity: zero" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "0");
    try std.testing.expectEqualStrings("0", s);
}

test "identity: null" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "null");
    try std.testing.expectEqualStrings("null", s);
}

test "identity: true" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "true");
    try std.testing.expectEqualStrings("true", s);
}

test "identity: false" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "false");
    try std.testing.expectEqualStrings("false", s);
}

test "identity: string" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "\"hello\"");
    try std.testing.expectEqualStrings("\"hello\"", s);
}

test "identity: float" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "3.14");
    // Parse the result back to verify round-trip rather than asserting an
    // exact decimal representation.
    const parsed = try std.fmt.parseFloat(f64, s);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), parsed, 1e-9);
}

test "identity: empty object" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "{}");
    try std.testing.expectEqualStrings("{}", s);
}

test "identity: empty array" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "[]");
    try std.testing.expectEqualStrings("[]", s);
}

test "identity: nested object" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "{\"a\":{\"b\":1}}");
    try std.testing.expectEqualStrings("{\"a\":{\"b\":1}}", s);
}

test "identity: array of integers" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "[1,2,3]");
    try std.testing.expectEqualStrings("[1,2,3]", s);
}

// ── Key access (.foo) ─────────────────────────────────────────────────────────

test "key access: present key" {
    const h = mustCompile(".name");
    defer zq_free(h);
    const s = execute(h, "{\"name\":\"alice\"}");
    try std.testing.expectEqualStrings("\"alice\"", s);
}

test "key access: integer value" {
    const h = mustCompile(".count");
    defer zq_free(h);
    const s = execute(h, "{\"count\":99}");
    try std.testing.expectEqualStrings("99", s);
}

test "key access: nested path" {
    const h = mustCompile(".a.b");
    defer zq_free(h);
    const s = execute(h, "{\"a\":{\"b\":7}}");
    try std.testing.expectEqualStrings("7", s);
}

// ── Array index (.[n]) ────────────────────────────────────────────────────────

test "array index: first element" {
    const h = mustCompile(".[0]");
    defer zq_free(h);
    const s = execute(h, "[10,20,30]");
    try std.testing.expectEqualStrings("10", s);
}

test "array index: second element" {
    const h = mustCompile(".[1]");
    defer zq_free(h);
    const s = execute(h, "[10,20,30]");
    try std.testing.expectEqualStrings("20", s);
}

// ── Iterator (.[] → multiple results) ────────────────────────────────────────

test "iterate: array yields multiple values separated by newline" {
    const h = mustCompile(".[]");
    defer zq_free(h);
    const s = execute(h, "[1,2,3]");
    // Multiple results are JSONL-separated (one per line).
    try std.testing.expectEqualStrings("1\n2\n3", s);
}

test "iterate: empty array yields empty result" {
    const h = mustCompile(".[]");
    defer zq_free(h);
    const s = execute(h, "[]");
    try std.testing.expectEqualStrings("", s);
}

test "iterate: object yields values only" {
    const h = mustCompile(".[]");
    defer zq_free(h);
    // Single-key object — one result, no newline separator.
    const s = execute(h, "{\"x\":42}");
    try std.testing.expectEqualStrings("42", s);
}

test "pipe with iterate: .[] | .name" {
    const h = mustCompile(".[] | .name");
    defer zq_free(h);
    const s = execute(h, "[{\"name\":\"a\"},{\"name\":\"b\"}]");
    try std.testing.expectEqualStrings("\"a\"\n\"b\"", s);
}

// ── Result buffer reuse across multiple executions ────────────────────────────

test "reuse: same handle executed multiple times" {
    const h = mustCompile(".x");
    defer zq_free(h);

    const s1 = execute(h, "{\"x\":1}");
    try std.testing.expectEqualStrings("1", s1);

    const s2 = execute(h, "{\"x\":2}");
    try std.testing.expectEqualStrings("2", s2);

    const s3 = execute(h, "{\"x\":3}");
    try std.testing.expectEqualStrings("3", s3);
}

test "reuse: result shrinks correctly between executions" {
    const h = mustCompile(".");
    defer zq_free(h);

    // Large value first.
    const s1 = execute(h, "[1,2,3,4,5,6,7,8,9,10]");
    try std.testing.expectEqualStrings("[1,2,3,4,5,6,7,8,9,10]", s1);

    // Small value second — result must reflect the new value only.
    const s2 = execute(h, "1");
    try std.testing.expectEqualStrings("1", s2);
}

// ── Error codes ───────────────────────────────────────────────────────────────

test "execute error -1: malformed JSON" {
    const h = mustCompile(".");
    defer zq_free(h);
    const rc = zq_execute(h, "not-json".ptr, "not-json".len);
    try std.testing.expectEqual(@as(c_int, -1), rc);
}

test "execute error -1: unterminated string" {
    const h = mustCompile(".");
    defer zq_free(h);
    const input = "\"unterminated";
    const rc = zq_execute(h, input.ptr, input.len);
    try std.testing.expectEqual(@as(c_int, -1), rc);
}

test "execute error -1: empty input" {
    const h = mustCompile(".");
    defer zq_free(h);
    const rc = zq_execute(h, "".ptr, 0);
    try std.testing.expectEqual(@as(c_int, -1), rc);
}

test "execute error -2: TypeError — key on non-object" {
    const h = mustCompile(".foo");
    defer zq_free(h);
    const rc = zq_execute(h, "42".ptr, "42".len);
    try std.testing.expectEqual(@as(c_int, -2), rc);
}

test "execute error -2: TypeError — key on array" {
    const h = mustCompile(".foo");
    defer zq_free(h);
    const rc = zq_execute(h, "[1,2]".ptr, "[1,2]".len);
    try std.testing.expectEqual(@as(c_int, -2), rc);
}

test "execute success: out-of-bounds index returns null" {
    const h = mustCompile(".[5]");
    defer zq_free(h);
    const rc = zq_execute(h, "[1]".ptr, "[1]".len);
    // Out-of-bounds read is jq-compatible: returns null, not an error.
    try std.testing.expectEqual(@as(c_int, 0), rc);
}

test "execute error -2: TypeError — iterate non-array" {
    const h = mustCompile(".[]");
    defer zq_free(h);
    const rc = zq_execute(h, "42".ptr, "42".len);
    try std.testing.expectEqual(@as(c_int, -2), rc);
}

// ── Result pointer validity after error ───────────────────────────────────────

test "get_result after failed execute: returns previous result" {
    const h = mustCompile(".");
    defer zq_free(h);

    // First execute succeeds.
    const s1 = execute(h, "99");
    try std.testing.expectEqualStrings("99", s1);

    // Second execute fails (malformed JSON).
    const rc = zq_execute(h, "bad".ptr, "bad".len);
    try std.testing.expectEqual(@as(c_int, -1), rc);

    // Result buffer should still hold the previous successful result.
    const ptr = zq_get_result(h);
    const s2 = std.mem.sliceTo(ptr, 0);
    try std.testing.expectEqualStrings("99", s2);
}

// ── Null termination ──────────────────────────────────────────────────────────

test "result is null-terminated: byte after content is zero" {
    const h = mustCompile(".");
    defer zq_free(h);
    _ = execute(h, "42");
    const ptr = zq_get_result(h);
    const s = std.mem.sliceTo(ptr, 0);
    // The byte immediately past the content must be the null terminator.
    try std.testing.expectEqual(@as(u8, 0), ptr[s.len]);
}

// ── C string boundary: zero-length input ─────────────────────────────────────

test "execute: zero-length input returns parse error" {
    const h = mustCompile(".");
    defer zq_free(h);
    const rc = zq_execute(h, "x".ptr, 0); // ptr irrelevant when len=0
    // An empty slice is invalid JSON.
    try std.testing.expectEqual(@as(c_int, -1), rc);
}

// ── String escaping survives the round-trip ───────────────────────────────────

test "string escaping: special characters survive round-trip" {
    const h = mustCompile(".");
    defer zq_free(h);
    // The parser decodes \n inside the string; the C ABI re-encodes it.
    const s = execute(h, "\"line1\\nline2\"");
    try std.testing.expectEqualStrings("\"line1\\nline2\"", s);
}

test "string escaping: backslash survives round-trip" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "\"a\\\\b\"");
    try std.testing.expectEqualStrings("\"a\\\\b\"", s);
}

// ── Auto-close: truncated JSON is recovered ────────────────────────────────────

test "auto-close: truncated object is recovered" {
    const h = mustCompile(".");
    defer zq_free(h);
    // {"a":1  <- no closing brace; parser auto-closes.
    const s = execute(h, "{\"a\":1");
    try std.testing.expectEqualStrings("{\"a\":1}", s);
}

test "auto-close: truncated array is recovered" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "[1,2");
    try std.testing.expectEqualStrings("[1,2]", s);
}

// ── Large output: result buffer growth ───────────────────────────────────────

test "large output: result buffer grows as needed" {
    const h = mustCompile(".");
    defer zq_free(h);

    // Build an array large enough to exceed the initial 4 KB result buffer.
    var input = std.ArrayList(u8){};
    defer input.deinit(std.testing.allocator);
    try input.append(std.testing.allocator, '[');
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        if (i > 0) try input.append(std.testing.allocator, ',');
        try input.appendSlice(std.testing.allocator, "12345678");
    }
    try input.append(std.testing.allocator, ']');

    const rc = zq_execute(h, input.items.ptr, input.items.len);
    try std.testing.expectEqual(@as(c_int, 0), rc);

    const ptr = zq_get_result(h);
    const s = std.mem.sliceTo(ptr, 0);
    // The result must be at least as long as the input (compact = input length).
    try std.testing.expect(s.len >= 8000);
    // Must start with '[' and end with ']'.
    try std.testing.expectEqual(@as(u8, '['), s[0]);
    try std.testing.expectEqual(@as(u8, ']'), s[s.len - 1]);
}

// ── Pipe combinator ───────────────────────────────────────────────────────────

test "pipe: .a | .b" {
    const h = mustCompile(".a | .b");
    defer zq_free(h);
    const s = execute(h, "{\"a\":{\"b\":99}}");
    try std.testing.expectEqualStrings("99", s);
}

// ── Float special values ──────────────────────────────────────────────────────

test "float: regular float round-trips" {
    const h = mustCompile(".");
    defer zq_free(h);
    // Use a float small enough that the serialiser stays within its 64-byte
    // fixed buffer.  Verify the round-trip rather than the exact representation.
    const s = execute(h, "2.718281828");
    const parsed = try std.fmt.parseFloat(f64, s);
    try std.testing.expectApproxEqAbs(@as(f64, 2.718281828), parsed, 1e-9);
}

// ── Multiple handles are independent ─────────────────────────────────────────

test "two handles are independent" {
    const h1 = mustCompile(".x");
    defer zq_free(h1);
    const h2 = mustCompile(".y");
    defer zq_free(h2);

    const s1 = execute(h1, "{\"x\":1,\"y\":2}");
    const s2 = execute(h2, "{\"x\":1,\"y\":2}");

    try std.testing.expectEqualStrings("1", s1);
    try std.testing.expectEqualStrings("2", s2);
}

// ── Whitespace tolerance ──────────────────────────────────────────────────────

test "execute: whitespace around value is accepted" {
    const h = mustCompile(".");
    defer zq_free(h);
    const s = execute(h, "  42  ");
    try std.testing.expectEqualStrings("42", s);
}

test "execute: whitespace inside object is accepted" {
    const h = mustCompile(".k");
    defer zq_free(h);
    const s = execute(h, " { \"k\" : 1 } ");
    try std.testing.expectEqualStrings("1", s);
}
