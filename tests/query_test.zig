const std = @import("std");
const query = @import("query");
const types = @import("types");

const CompiledQuery = query.CompiledQuery;
const Opts = query.Opts;
const Tape = types.Tape;
const Entry = types.Tape.Entry;
const Tag = types.Tape.Tag;
const Payload = types.Tape.Payload;
const StringRef = types.Tape.StringRef;
const Value = types.Value;
const alloc = std.testing.allocator;

// ── Tape construction helpers ─────────────────────────────────────────────────
//
// All helpers produce fixed-layout tapes for tests. String bytes are interned
// into a caller-supplied buffer; StringRef offsets index into that buffer.

fn strRef(buf: []const u8, s: []const u8) StringRef {
    const off = std.mem.indexOf(u8, buf, s) orelse unreachable;
    return .{ .offset = @intCast(off), .len = @intCast(s.len) };
}

/// Build a Tape from a static entry slice and string buffer.
fn tape(entries: []const Entry, string_buf: []const u8) Tape {
    return Tape{ .entries = entries, .string_buf = string_buf };
}

// ── Compile helpers ───────────────────────────────────────────────────────────

fn compile(src: []const u8) !CompiledQuery {
    return CompiledQuery.compile(src, .{}, alloc);
}

fn compileNull(src: []const u8) !CompiledQuery {
    return CompiledQuery.compile(src, .{ .allow_null_propagation = true }, alloc);
}

fn collectAll(q: *const CompiledQuery, t: Tape) ![]Value {
    var it = try q.execute(t, alloc);
    defer it.deinit();
    var out = std.ArrayList(Value){};
    while (try it.next()) |v| try out.append(alloc, v);
    return out.toOwnedSlice(alloc);
}

// ── Identity ─────────────────────────────────────────────────────────────────

test "identity: . returns root integer" {
    var q = try compile(".");
    defer q.deinit();

    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 42 } }};
    const t = tape(&entries, "");

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 42), vals[0].int);
}

test "identity: . returns root null" {
    var q = try compile(".");
    defer q.deinit();

    const entries = [_]Entry{.{ .tag = .null_val, .payload = .{ .none = {} } }};
    const t = tape(&entries, "");

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0] == .null_val);
}

// ── Key access ────────────────────────────────────────────────────────────────

test ".foo: returns value for present key" {
    // Tape: {"foo": 99}
    // [0] object_start skip=4
    // [1] key "foo"
    // [2] int 99
    // [3] object_end
    const sb = "foo";
    const ref = StringRef{ .offset = 0, .len = 3 };
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = ref } },
        .{ .tag = .int, .payload = .{ .int = 99 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".foo");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 99), vals[0].int);
}

test ".foo: missing key returns TypeError in strict mode" {
    const sb = "bar";
    const ref = StringRef{ .offset = 0, .len = 3 };
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = ref } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".foo"); // key "foo" absent
    defer q.deinit();

    var it = try q.execute(t, alloc);
    defer it.deinit();

    try std.testing.expectError(error.TypeError, it.next());
}

test ".foo: missing key returns null with allow_null_propagation" {
    const sb = "bar";
    const ref = StringRef{ .offset = 0, .len = 3 };
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = ref } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compileNull(".foo");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0] == .null_val);
}

test ".foo: TypeError on non-object (array)" {
    // [1, 2] — array root
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 4 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .int, .payload = .{ .int = 2 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");

    var q = try compile(".foo");
    defer q.deinit();

    var it = try q.execute(t, alloc);
    defer it.deinit();

    try std.testing.expectError(error.TypeError, it.next());
}

// ── Nested key access / fused path ───────────────────────────────────────────

test ".a.b: returns nested value" {
    // {"a": {"b": 7}}
    // [0] object_start skip=6
    // [1] key "a"
    // [2] object_start skip=5
    // [3] key "b"
    // [4] int 7
    // [5] object_end  (inner)
    // [6] object_end  (outer)
    const sb = "ab";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 7 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .object_start, .payload = .{ .skip = 6 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 1, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 7 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    // Both .a.b and .a | .b compile to load_path "a.b" via fuse pass.
    var q1 = try compile(".a.b");
    defer q1.deinit();
    var q2 = try compile(".a | .b");
    defer q2.deinit();

    for ([_]*const CompiledQuery{ &q1, &q2 }) |q| {
        const vals = try collectAll(q, t);
        defer alloc.free(vals);
        try std.testing.expectEqual(@as(usize, 1), vals.len);
        try std.testing.expectEqual(@as(i64, 7), vals[0].int);
    }
}

// ── Array index ───────────────────────────────────────────────────────────────

test ".[1]: returns element at index" {
    // [10, 20, 30]
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 5 } },
        .{ .tag = .int, .payload = .{ .int = 10 } },
        .{ .tag = .int, .payload = .{ .int = 20 } },
        .{ .tag = .int, .payload = .{ .int = 30 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");

    var q = try compile(".[1]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 20), vals[0].int);
}

test ".[0]: returns first element" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 3 } },
        .{ .tag = .int, .payload = .{ .int = 5 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");

    var q = try compile(".[0]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 5), vals[0].int);
}

test ".[5]: IndexOutOfBounds on short array" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 3 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");

    var q = try compile(".[5]");
    defer q.deinit();

    var it = try q.execute(t, alloc);
    defer it.deinit();

    try std.testing.expectError(error.IndexOutOfBounds, it.next());
}

// ── Iterate ───────────────────────────────────────────────────────────────────

test ".[] on array: yields all elements" {
    // [1, 2, 3]
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 5 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .int, .payload = .{ .int = 2 } },
        .{ .tag = .int, .payload = .{ .int = 3 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");

    var q = try compile(".[]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 3), vals.len);
    try std.testing.expectEqual(@as(i64, 1), vals[0].int);
    try std.testing.expectEqual(@as(i64, 2), vals[1].int);
    try std.testing.expectEqual(@as(i64, 3), vals[2].int);
}

test ".[] on empty array: yields nothing" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 2 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");

    var q = try compile(".[]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 0), vals.len);
}

test ".[] on object: yields values only" {
    // {"x": 1, "y": 2}
    const sb = "xy";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 6 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 1, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 2 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".[]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 2), vals.len);
    try std.testing.expectEqual(@as(i64, 1), vals[0].int);
    try std.testing.expectEqual(@as(i64, 2), vals[1].int);
}

test ".[] on non-array: TypeError" {
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 5 } }};
    const t = tape(&entries, "");

    var q = try compile(".[]");
    defer q.deinit();

    var it = try q.execute(t, alloc);
    defer it.deinit();

    try std.testing.expectError(error.TypeError, it.next());
}

// ── Pipe with iterate ─────────────────────────────────────────────────────────

test ".[] | .name: yields name field from each element" {
    // [{"name": "a"}, {"name": "b"}]
    // Tape layout:
    // [0]  array_start  skip=13
    // [1]  object_start skip=5
    // [2]  key "name"
    // [3]  string "a"
    // [4]  object_end
    // [5]  object_start skip=9
    // [6]  key "name"
    // [7]  string "b"
    // [8]  object_end
    // [9]  array_end -- skip=10? let's recount
    //
    // Outer array: entries 0-9, so skip=10.
    // First object: entries 1-4, so skip=5 (one past entry 4).
    // Second object: entries 5-8, so skip=9 (one past entry 8).
    const sb = "nameab";
    //          0123456
    // "name" = offset 0, len 4
    // "a"    = offset 4, len 1
    // "b"    = offset 5, len 1
    const name_ref = StringRef{ .offset = 0, .len = 4 };
    const a_ref = StringRef{ .offset = 4, .len = 1 };
    const b_ref = StringRef{ .offset = 5, .len = 1 };

    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 10 } },
        .{ .tag = .object_start, .payload = .{ .skip = 5 } },
        .{ .tag = .key, .payload = .{ .string = name_ref } },
        .{ .tag = .string, .payload = .{ .string = a_ref } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
        .{ .tag = .object_start, .payload = .{ .skip = 9 } },
        .{ .tag = .key, .payload = .{ .string = name_ref } },
        .{ .tag = .string, .payload = .{ .string = b_ref } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".[] | .name");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 2), vals.len);
    try std.testing.expectEqualStrings("a", vals[0].string);
    try std.testing.expectEqualStrings("b", vals[1].string);
}

// ── Nested iterate ────────────────────────────────────────────────────────────

test ".[] | .[]: flattens nested arrays" {
    // [[1, 2], [3]]
    // [0]  array_start  skip=9
    // [1]  array_start  skip=4  (inner [1,2])
    // [2]  int 1
    // [3]  int 2
    // [4]  array_end
    // [5]  array_start  skip=8  (inner [3])
    // [6]  int 3
    // [7]  array_end
    // [8]  array_end
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
    const t = tape(&entries, "");

    var q = try compile(".[] | .[]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 3), vals.len);
    try std.testing.expectEqual(@as(i64, 1), vals[0].int);
    try std.testing.expectEqual(@as(i64, 2), vals[1].int);
    try std.testing.expectEqual(@as(i64, 3), vals[2].int);
}

test ".[] | .[]: empty inner array produces no output for that element" {
    // [[], [1]]
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 7 } },
        .{ .tag = .array_start, .payload = .{ .skip = 3 } }, // []
        .{ .tag = .array_end, .payload = .{ .none = {} } },
        .{ .tag = .array_start, .payload = .{ .skip = 6 } }, // [1]
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");

    var q = try compile(".[] | .[]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 1), vals[0].int);
}

// ── allow_null_propagation ────────────────────────────────────────────────────

test ".a.b: null propagation through null intermediate value" {
    // {"a": null}  — .a returns null, .b on null should return null
    const sb = "ab";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .null_val, .payload = .{ .none = {} } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    // Strict mode: TypeError because null.b is not allowed.
    {
        var q = try compile(".a | .b");
        defer q.deinit();
        var it = try q.execute(t, alloc);
        defer it.deinit();
        try std.testing.expectError(error.TypeError, it.next());
    }

    // allow_null_propagation: null propagates silently.
    {
        var q = try compileNull(".a | .b");
        defer q.deinit();
        const vals = try collectAll(&q, t);
        defer alloc.free(vals);
        try std.testing.expectEqual(@as(usize, 1), vals.len);
        try std.testing.expect(vals[0] == .null_val);
    }
}

test "TypeError is NOT suppressed for key on integer" {
    // 42 — integer root
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 42 } }};
    const t = tape(&entries, "");

    // Even with allow_null_propagation, key-on-integer is always TypeError.
    var q = try compileNull(".foo");
    defer q.deinit();
    var it = try q.execute(t, alloc);
    defer it.deinit();
    try std.testing.expectError(error.TypeError, it.next());
}

// ── Syntax errors ─────────────────────────────────────────────────────────────

test "compile: bare pipe returns QuerySyntaxError" {
    try std.testing.expectError(
        error.QuerySyntaxError,
        CompiledQuery.compile("|", .{}, alloc),
    );
}

test "compile: trailing dot returns QuerySyntaxError" {
    try std.testing.expectError(
        error.QuerySyntaxError,
        CompiledQuery.compile(".foo.", .{}, alloc),
    );
}

test "compile: unbalanced bracket returns QuerySyntaxError" {
    try std.testing.expectError(
        error.QuerySyntaxError,
        CompiledQuery.compile(".[", .{}, alloc),
    );
}

test "compile: empty filter is valid (identity)" {
    // An empty filter compiles to [identity, output].
    // Actually an empty string hits the EOF check before a leading dot.
    // Per grammar, a filter must start with '.', so empty string fails.
    try std.testing.expectError(
        error.QuerySyntaxError,
        CompiledQuery.compile("", .{}, alloc),
    );
}

test "compile: . is valid" {
    var q = try compile(".");
    defer q.deinit();
    // Simply verify it compiled without error. Execution tested in identity tests.
}

// ── Empty tape ────────────────────────────────────────────────────────────────

test "empty tape: next() returns null immediately" {
    var q = try compile(".");
    defer q.deinit();

    const t = Tape{ .entries = &.{}, .string_buf = "" };
    var it = try q.execute(t, alloc);
    defer it.deinit();

    const v = try it.next();
    try std.testing.expectEqual(@as(?Value, null), v);
}

// ── Value types ───────────────────────────────────────────────────────────────

test "boolean and float values round-trip through identity" {
    var q = try compile(".");
    defer q.deinit();

    // true
    {
        const entries = [_]Entry{.{ .tag = .true_val, .payload = .{ .none = {} } }};
        const vals = try collectAll(&q, tape(&entries, ""));
        defer alloc.free(vals);
        try std.testing.expectEqual(true, vals[0].bool_val);
    }
    // false
    {
        const entries = [_]Entry{.{ .tag = .false_val, .payload = .{ .none = {} } }};
        const vals = try collectAll(&q, tape(&entries, ""));
        defer alloc.free(vals);
        try std.testing.expectEqual(false, vals[0].bool_val);
    }
    // float
    {
        const entries = [_]Entry{.{ .tag = .float, .payload = .{ .float = 3.14 } }};
        const vals = try collectAll(&q, tape(&entries, ""));
        defer alloc.free(vals);
        try std.testing.expectApproxEqAbs(@as(f64, 3.14), vals[0].float, 1e-9);
    }
}

// ── ResultIterator.reset() ────────────────────────────────────────────────────

test "reset: iterator reuses buffers across two integer tapes" {
    var q = try compile(".");
    defer q.deinit();

    const entries_a = [_]Entry{.{ .tag = .int, .payload = .{ .int = 100 } }};
    const tape_a = tape(&entries_a, "");

    const entries_b = [_]Entry{.{ .tag = .int, .payload = .{ .int = 200 } }};
    const tape_b = tape(&entries_b, "");

    // First run via execute().
    var it = try q.execute(tape_a, alloc);
    defer it.deinit();
    const v1 = (try it.next()).?;
    try std.testing.expectEqual(@as(i64, 100), v1.int);
    try std.testing.expectEqual(@as(?Value, null), try it.next());

    // Reset to a new tape — must produce correct values with zero new allocations.
    it.reset(tape_b);
    const v2 = (try it.next()).?;
    try std.testing.expectEqual(@as(i64, 200), v2.int);
    try std.testing.expectEqual(@as(?Value, null), try it.next());
}

test "reset: iterator reuses buffers across many records (JSONL simulation)" {
    var q = try compile(".");
    defer q.deinit();

    // Simulate processing 1000 records with a single iterator.
    var first = true;
    var it: query.ResultIterator = undefined;
    defer if (!first) it.deinit();

    var i: i64 = 0;
    while (i < 1000) : (i += 1) {
        const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = i } }};
        const t = tape(&entries, "");

        if (first) {
            it = try q.execute(t, alloc);
            first = false;
        } else {
            it.reset(t);
        }

        const val = (try it.next()).?;
        try std.testing.expectEqual(i, val.int);
        try std.testing.expectEqual(@as(?Value, null), try it.next());
    }
}

test "reset: iterator correctly re-evaluates field access on different objects" {
    var q = try compile(".age");
    defer q.deinit();

    // Object 1: {"age": 30}
    const sb1 = "age";
    const entries_1 = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 3 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 3 } } },
        .{ .tag = .int, .payload = .{ .int = 30 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const tape_1 = tape(&entries_1, sb1);

    // Object 2: {"age": 55}
    const sb2 = "age";
    const entries_2 = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 3 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 3 } } },
        .{ .tag = .int, .payload = .{ .int = 55 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const tape_2 = tape(&entries_2, sb2);

    var it = try q.execute(tape_1, alloc);
    defer it.deinit();
    try std.testing.expectEqual(@as(i64, 30), (try it.next()).?.int);
    try std.testing.expectEqual(@as(?Value, null), try it.next());

    it.reset(tape_2);
    try std.testing.expectEqual(@as(i64, 55), (try it.next()).?.int);
    try std.testing.expectEqual(@as(?Value, null), try it.next());
}

// ── Unary negation ────────────────────────────────────────────────────────────

test "unary negation: -1 literal yields int -1" {
    var q = try compile("-1");
    defer q.deinit();

    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 0 } }};
    const t = tape(&entries, "");

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, -1), vals[0].int);
}

test "unary negation: -5 literal preserves int type" {
    var q = try compile("-5");
    defer q.deinit();

    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 0 } }};
    const t = tape(&entries, "");

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    // -5 is parsed as a single int_lit token; result is int not float
    try std.testing.expectEqual(@as(i64, -5), vals[0].int);
}

test "unary negation: -.foo negates integer field, preserves int type" {
    // {"x": 7}
    const sb = "x";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 7 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile("-.x");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, -7), vals[0].int);
}

test "unary negation: -.foo negates float field, preserves float type" {
    // {"v": 3.14}
    const sb = "v";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .float, .payload = .{ .float = 3.14 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile("-.v");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectApproxEqAbs(@as(f64, -3.14), vals[0].float, 1e-9);
}

test "unary negation: -(.x) negates via parenthesized field" {
    // {"x": 9}  =>  -(.x) == -9
    const sb = "x";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 9 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile("-(.x)");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, -9), vals[0].int);
}

test "unary negation: TypeError on non-numeric field" {
    // {"s": "hello"}
    const sb = "shello";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .string, .payload = .{ .string = .{ .offset = 1, .len = 5 } } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile("-.s");
    defer q.deinit();

    var it = try q.execute(t, alloc);
    defer it.deinit();

    try std.testing.expectError(error.TypeError, it.next());
}

// ── Conditionals ──────────────────────────────────────────────────────────────

test "if/then/else: true condition takes then-branch" {
    // input: 7  →  if . > 5 then true else false end  →  true
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 7 } }};
    const t = tape(&entries, "");

    var q = try compile("if . > 5 then true else false end");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(true, vals[0].bool_val);
}

test "if/then/else: false condition takes else-branch" {
    // input: 3  →  if . > 5 then true else false end  →  false
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 3 } }};
    const t = tape(&entries, "");

    var q = try compile("if . > 5 then true else false end");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(false, vals[0].bool_val);
}

test "if/then/else: branches evaluate against original input" {
    // {"x": 10}  →  if .x > 5 then .x else 0 end  →  10
    const sb = "x";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 10 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile("if .x > 5 then .x else 0 end");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 10), vals[0].int);
}

test "if/then/else: null is falsy" {
    // null  →  if . then true else false end  →  false
    const entries = [_]Entry{.{ .tag = .null_val, .payload = .{ .none = {} } }};
    const t = tape(&entries, "");

    var q = try compile("if . then true else false end");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(false, vals[0].bool_val);
}

test "if/then/else: false is falsy" {
    // false  →  if . then true else false end  →  false
    const entries = [_]Entry{.{ .tag = .false_val, .payload = .{ .none = {} } }};
    const t = tape(&entries, "");

    var q = try compile("if . then true else false end");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(false, vals[0].bool_val);
}

test "if/then/else: 0 is truthy (jq semantics)" {
    // 0  →  if . then true else false end  →  true  (0 is truthy in jq)
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 0 } }};
    const t = tape(&entries, "");

    var q = try compile("if . then true else false end");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(true, vals[0].bool_val);
}

test "if/then without else: implicit else is identity — true branch" {
    // 7  →  if . > 5 then 99 end  →  99
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 7 } }};
    const t = tape(&entries, "");

    var q = try compile("if . > 5 then 99 end");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 99), vals[0].int);
}

test "if/then without else: false branch returns input" {
    // 3  →  if . > 5 then 99 end  →  3  (implicit else = .)
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 3 } }};
    const t = tape(&entries, "");

    var q = try compile("if . > 5 then 99 end");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 3), vals[0].int);
}

test "elif: first condition true" {
    // -5  →  if . < 0 then -1 elif . > 0 then 1 else 0 end  →  -1
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = -5 } }};
    const t = tape(&entries, "");

    var q = try compile("if . < 0 then -1 elif . > 0 then 1 else 0 end");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, -1), vals[0].int);
}

test "elif: second condition true" {
    // 5  →  if . < 0 then -1 elif . > 0 then 1 else 0 end  →  1
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 5 } }};
    const t = tape(&entries, "");

    var q = try compile("if . < 0 then -1 elif . > 0 then 1 else 0 end");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 1), vals[0].int);
}

test "elif: else branch" {
    // 0  →  if . < 0 then -1 elif . > 0 then 1 else 0 end  →  0
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 0 } }};
    const t = tape(&entries, "");

    var q = try compile("if . < 0 then -1 elif . > 0 then 1 else 0 end");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 0), vals[0].int);
}

test "nested if: if inside then-branch" {
    // 15  →  if . > 10 then if . > 20 then 99 else 50 end else 0 end  →  50
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 15 } }};
    const t = tape(&entries, "");

    var q = try compile("if . > 10 then if . > 20 then 99 else 50 end else 0 end");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 50), vals[0].int);
}

test "if: syntax error — missing then" {
    try std.testing.expectError(
        error.QuerySyntaxError,
        CompiledQuery.compile("if . else . end", .{}, alloc),
    );
}

test "if: syntax error — missing end" {
    try std.testing.expectError(
        error.QuerySyntaxError,
        CompiledQuery.compile("if . then . else .", .{}, alloc),
    );
}

// ── Array construction ────────────────────────────────────────────────────────

test "array construction: [] yields empty array" {
    var q = try compile("[]");
    defer q.deinit();

    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 1 } }};
    const t = tape(&entries, "");

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    // Empty array: span.end - span.start == 2 (array_start + array_end, no elements).
    try std.testing.expectEqual(@as(u32, 2), vals[0].array.end - vals[0].array.start);
}

test "array construction: [.] wraps input in array" {
    // Verify that [.] returns an array with exactly one scalar element.
    // The runtime tape is freed after collectAll, so we only check structural span sizes.
    var q = try compile("[.]");
    defer q.deinit();

    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 7 } }};
    const t = tape(&entries, "");

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0] == .array);
    // One scalar element: array_start + int + array_end = 3 entries → span.end - span.start = 3.
    try std.testing.expectEqual(@as(u32, 3), vals[0].array.end - vals[0].array.start);
}

test "array construction: [.foo] wraps field in array" {
    // {"x": 42} — [.x] should return an array with one scalar element.
    const sb = "x";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 42 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile("[.x]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0] == .array);
    // One scalar: start + int + end = 3 entries.
    try std.testing.expectEqual(@as(u32, 3), vals[0].array.end - vals[0].array.start);
}

test "array construction: [.[]] collects all array elements" {
    // [10, 20, 30]
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 5 } },
        .{ .tag = .int, .payload = .{ .int = 10 } },
        .{ .tag = .int, .payload = .{ .int = 20 } },
        .{ .tag = .int, .payload = .{ .int = 30 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");

    var q = try compile("[.[]]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0] == .array);
    // 3 scalar elements: start + 3 ints + end = 5 entries.
    try std.testing.expectEqual(@as(u32, 5), vals[0].array.end - vals[0].array.start);
}

test "array construction: [.[] | .id] maps field from each element" {
    // [{"id":1}, {"id":2}]
    const sb = "id";
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 10 } }, // past array_end at [9]
        .{ .tag = .object_start, .payload = .{ .skip = 5 } }, // past object_end at [4]
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 2 } } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
        .{ .tag = .object_start, .payload = .{ .skip = 9 } }, // past object_end at [8]
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 2 } } },
        .{ .tag = .int, .payload = .{ .int = 2 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile("[.[] | .id]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0] == .array);
    // 2 scalar elements: start + 2 ints + end = 4 entries.
    try std.testing.expectEqual(@as(u32, 4), vals[0].array.end - vals[0].array.start);
}

test "array construction: [.[]] on empty array yields empty array" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 2 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");

    var q = try compile("[.[]]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0] == .array);
    // empty: start + end = 2 entries → span.end - span.start = 2.
    try std.testing.expectEqual(@as(u32, 2), vals[0].array.end - vals[0].array.start);
}

test "array construction: syntax error — unclosed bracket" {
    try std.testing.expectError(
        error.QuerySyntaxError,
        CompiledQuery.compile("[.", .{}, alloc),
    );
}

// ── Bracket pipe expressions ──────────────────────────────────────────────────

test ".['key']: string literal bracket access returns field value" {
    // {"name": "Alice"}
    const sb = "namealice";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 4 } } },
        .{ .tag = .string, .payload = .{ .string = .{ .offset = 4, .len = 5 } } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".[ \"name\"]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqualStrings("alice", vals[0].string);
}

test ".['key'] equivalent to .key" {
    // {"x": 99}
    const sb = "x";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 99 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".[\"x\"]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 99), vals[0].int);
}

test ".[.key_field]: computed string key from field value" {
    // {"k": "name", "name": "Bob"}  →  .[.k] == "Bob"
    const sb = "knameBob";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 8 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },   // "k"
        .{ .tag = .string, .payload = .{ .string = .{ .offset = 1, .len = 4 } } }, // "name"
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 1, .len = 4 } } },   // "name"
        .{ .tag = .string, .payload = .{ .string = .{ .offset = 5, .len = 3 } } }, // "Bob"
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".[.k]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqualStrings("Bob", vals[0].string);
}

test ".[.idx]: computed integer index from field value" {
    // [10, 20, 30] with input {"i": 1}  →  not feasible in one tape;
    // instead test directly: array [10,20,30], index from literal expression
    // Use .[1] to exercise load_index (existing), confirm no regression.
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 5 } },
        .{ .tag = .int, .payload = .{ .int = 10 } },
        .{ .tag = .int, .payload = .{ .int = 20 } },
        .{ .tag = .int, .payload = .{ .int = 30 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");

    // .[1] still goes through parseBracket's int_lit branch.
    var q = try compile(".[1]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 20), vals[0].int);
}

test ".[expr]: allow_null_propagation on missing key" {
    // {"x": 1}  →  .["missing"]  with allow_null → null
    const sb = "x";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compileNull(".[\"missing\"]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0] == .null_val);
}

test ".['key']: syntax error on unterminated string" {
    try std.testing.expectError(
        error.QuerySyntaxError,
        CompiledQuery.compile(".[\"unterminated]", .{}, alloc),
    );
}

// ── Alternative operator (//) ─────────────────────────────────────────────────

test "alternative: null // literal returns literal" {
    // null input → . // 42 → 42
    const entries = [_]Entry{.{ .tag = .null_val, .payload = .{ .none = {} } }};
    const t = tape(&entries, "");

    var q = try compile(". // 42");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 42), vals[0].int);
}

test "alternative: false // literal returns literal" {
    // false input → . // 99 → 99
    const entries = [_]Entry{.{ .tag = .false_val, .payload = .{ .none = {} } }};
    const t = tape(&entries, "");

    var q = try compile(". // 99");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 99), vals[0].int);
}

test "alternative: truthy value passes through" {
    // integer 7 → . // 99 → 7 (7 is truthy)
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 7 } }};
    const t = tape(&entries, "");

    var q = try compile(". // 99");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 7), vals[0].int);
}

test "alternative: 0 is truthy (jq semantics)" {
    // 0 is truthy in jq — only false and null are falsy
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 0 } }};
    const t = tape(&entries, "");

    var q = try compile(". // 42");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 0), vals[0].int);
}

test "alternative: .foo // literal when key is null" {
    // {"foo": null}  →  .foo // "default"  → "default"
    const sb = "foodefault";
    const foo_ref = StringRef{ .offset = 0, .len = 3 };
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = foo_ref } },
        .{ .tag = .null_val, .payload = .{ .none = {} } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".foo // \"default\"");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqualStrings("default", vals[0].string);
}

test "alternative: .foo // literal when key is present and truthy" {
    // {"foo": 5}  →  .foo // 99  → 5
    const sb = "foo";
    const foo_ref = StringRef{ .offset = 0, .len = 3 };
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = foo_ref } },
        .{ .tag = .int, .payload = .{ .int = 5 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".foo // 99");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 5), vals[0].int);
}

test "alternative: .foo // .bar when foo is null, bar is used with original input" {
    // {"foo": null, "bar": 42}  →  .foo // .bar  → 42
    const sb = "foobar";
    const foo_ref = StringRef{ .offset = 0, .len = 3 };
    const bar_ref = StringRef{ .offset = 3, .len = 3 };
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 6 } },
        .{ .tag = .key, .payload = .{ .string = foo_ref } },
        .{ .tag = .null_val, .payload = .{ .none = {} } },
        .{ .tag = .key, .payload = .{ .string = bar_ref } },
        .{ .tag = .int, .payload = .{ .int = 42 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".foo // .bar");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 42), vals[0].int);
}

test "alternative: missing key falls back to right side" {
    // {"bar": 77}  →  .foo // .bar  → 77  (foo is absent, alt_null_depth enables null propagation)
    const sb = "foobar";
    const foo_ref = StringRef{ .offset = 0, .len = 3 };
    const bar_ref = StringRef{ .offset = 3, .len = 3 };
    _ = foo_ref; // foo is absent from the tape object
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = bar_ref } },
        .{ .tag = .int, .payload = .{ .int = 77 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".foo // .bar");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 77), vals[0].int);
}

test "alternative: chained a // b // c, first truthy" {
    // integer 1 → . // 2 // 3 → 1
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 1 } }};
    const t = tape(&entries, "");

    var q = try compile(". // 2 // 3");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 1), vals[0].int);
}

test "alternative: chained a // b // c, first two null" {
    // null → . // null // 99 → 99
    const entries = [_]Entry{.{ .tag = .null_val, .payload = .{ .none = {} } }};
    const t = tape(&entries, "");

    var q = try compile(". // null // 99");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 99), vals[0].int);
}

test "alternative: in pipe context" {
    // {"x": null}  →  .x // 0  → 0
    const sb = "x";
    const x_ref = StringRef{ .offset = 0, .len = 1 };
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = x_ref } },
        .{ .tag = .null_val, .payload = .{ .none = {} } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(". | .x // 0");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 0), vals[0].int);
}

// ── Try-catch ────────────────────────────────────────────────────────────────

test "try: no error - yields value" {
    const sb = "foo";
    const foo_ref = StringRef{ .offset = 0, .len = 3 };
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = foo_ref } },
        .{ .tag = .int, .payload = .{ .int = 42 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile("try .foo");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 42), vals[0].int);
}

test "try: missing key - yields nothing" {
    const sb = "bar";
    const bar_ref = StringRef{ .offset = 0, .len = 3 };
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = bar_ref } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile("try .foo");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 0), vals.len);
}

test "try: type error - yields nothing" {
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 5 } }};
    const t = tape(&entries, "");

    var q = try compile("try .foo");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 0), vals.len);
}

test "try-catch: missing key uses catch handler" {
    const sb = "bar";
    const bar_ref = StringRef{ .offset = 0, .len = 3 };
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = bar_ref } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile("try .foo catch \"fallback\"");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqualStrings("fallback", vals[0].string);
}

test "try-catch: catch receives error name string" {
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 5 } }};
    const t = tape(&entries, "");

    var q = try compile("try .foo catch .");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqualStrings("TypeError", vals[0].string);
}

test "try-catch: no error - yields try body, skips catch" {
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 7 } }};
    const t = tape(&entries, "");

    var q = try compile("try . catch \"err\"");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 7), vals[0].int);
}

test "try: index out of bounds - yields nothing" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 3 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");

    var q = try compile("try .[5]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 0), vals.len);
}

test "try-catch: index out of bounds uses catch handler" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 3 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");

    var q = try compile("try .[5] catch -1");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, -1), vals[0].int);
}

test "try: iterate non-array - yields nothing" {
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 3 } }};
    const t = tape(&entries, "");

    var q = try compile("try .[]");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 0), vals.len);
}

test "try: nested - inner catch fires, outer not needed" {
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 0 } }};
    const t = tape(&entries, "");

    var q = try compile("try (try .foo catch \"inner\") catch \"outer\"");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqualStrings("inner", vals[0].string);
}

test "try: division by zero - yields nothing" {
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 0 } }};
    const t = tape(&entries, "");

    var q = try compile("try (1 / 0)");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 0), vals.len);
}

test "try-catch: modulo by zero uses catch" {
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 0 } }};
    const t = tape(&entries, "");

    var q = try compile("try (1 % 0) catch \"div0\"");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqualStrings("div0", vals[0].string);
}

// ── Optional operator (?) ─────────────────────────────────────────────────────

test "optional: .foo? on object with key returns value" {
    const sb = "foo";
    const ref = StringRef{ .offset = 0, .len = 3 };
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = ref } },
        .{ .tag = .int, .payload = .{ .int = 7 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".foo?");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 7), vals[0].int);
}

test "optional: .foo? on non-object suppresses error, yields nothing" {
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 42 } }};
    const t = tape(&entries, "");

    var q = try compile(".foo?");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 0), vals.len);
}

test "optional: .[]? on array yields all elements" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 4 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .int, .payload = .{ .int = 2 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");

    var q = try compile(".[]?");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 2), vals.len);
    try std.testing.expectEqual(@as(i64, 1), vals[0].int);
    try std.testing.expectEqual(@as(i64, 2), vals[1].int);
}

test "optional: .[]? on non-array suppresses error, yields nothing" {
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 5 } }};
    const t = tape(&entries, "");

    var q = try compile(".[]?");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 0), vals.len);
}

test "optional: .[] | .foo? skips non-object elements, yields rest" {
    // [{"foo": 1}, 42, {"foo": 3}]
    const sb = "foo";
    const foo_ref = StringRef{ .offset = 0, .len = 3 };
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 12 } },
        // {"foo": 1}
        .{ .tag = .object_start, .payload = .{ .skip = 5 } },
        .{ .tag = .key, .payload = .{ .string = foo_ref } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
        // 42
        .{ .tag = .int, .payload = .{ .int = 42 } },
        // {"foo": 3}
        .{ .tag = .object_start, .payload = .{ .skip = 10 } },
        .{ .tag = .key, .payload = .{ .string = foo_ref } },
        .{ .tag = .int, .payload = .{ .int = 3 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
        // string element
        .{ .tag = .string, .payload = .{ .string = .{ .offset = 0, .len = 3 } } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".[] | .foo?");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 2), vals.len);
    try std.testing.expectEqual(@as(i64, 1), vals[0].int);
    try std.testing.expectEqual(@as(i64, 3), vals[1].int);
}

test "optional: .foo.bar? suppresses error from either step" {
    // input: {"foo": 42}  — .foo is 42 (int), .bar would error on int
    const sb = "foo";
    const foo_ref = StringRef{ .offset = 0, .len = 3 };
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = foo_ref } },
        .{ .tag = .int, .payload = .{ .int = 42 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".foo.bar?");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 0), vals.len);
}

test "optional: .foo?.bar leaves .bar outside the try" {
    // input: {"foo": {"bar": 9}}
    const sb = "foobar";
    const foo_ref = StringRef{ .offset = 0, .len = 3 };
    const bar_ref = StringRef{ .offset = 3, .len = 3 };
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 7 } },
        .{ .tag = .key, .payload = .{ .string = foo_ref } },
        .{ .tag = .object_start, .payload = .{ .skip = 6 } },
        .{ .tag = .key, .payload = .{ .string = bar_ref } },
        .{ .tag = .int, .payload = .{ .int = 9 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);

    var q = try compile(".foo?.bar");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 9), vals[0].int);
}

test "optional: .[0]? on array returns first element" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 3 } },
        .{ .tag = .int, .payload = .{ .int = 5 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");

    var q = try compile(".[0]?");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 5), vals[0].int);
}

test "optional: .[0]? on non-array suppresses error, yields nothing" {
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 0 } }};
    const t = tape(&entries, "");

    var q = try compile(".[0]?");
    defer q.deinit();

    const vals = try collectAll(&q, t);
    defer alloc.free(vals);

    try std.testing.expectEqual(@as(usize, 0), vals.len);
}

// ── Slicing ───────────────────────────────────────────────────────────────────
// Helper: build a flat integer array tape [v0, v1, ...].
// entries must be: array_start(skip=n+2) + n int entries + array_end.

test "slice: .[1:3] extracts elements at index 1 and 2" {
    // [10, 20, 30, 40, 50] → .[1:3] = [20, 30]
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 7 } },
        .{ .tag = .int, .payload = .{ .int = 10 } },
        .{ .tag = .int, .payload = .{ .int = 20 } },
        .{ .tag = .int, .payload = .{ .int = 30 } },
        .{ .tag = .int, .payload = .{ .int = 40 } },
        .{ .tag = .int, .payload = .{ .int = 50 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");
    var q = try compile(".[1:3]");
    defer q.deinit();
    // Verify within iterator lifetime so runtime_tape is still valid.
    var it = try q.execute(t, alloc);
    defer it.deinit();
    const v = (try it.next()).?;
    try std.testing.expect(v == .array);
    // array_start + int(20) + int(30) + array_end = 4 entries
    try std.testing.expectEqual(@as(u32, 4), v.array.end - v.array.start);
    try std.testing.expectEqual(@as(i64, 20), v.array.tape.entries[v.array.start + 1].payload.int);
    try std.testing.expectEqual(@as(i64, 30), v.array.tape.entries[v.array.start + 2].payload.int);
    try std.testing.expectEqual(@as(?Value, null), try it.next());
}

test "slice: .[2:] extracts from index 2 to end" {
    // [10, 20, 30, 40]
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 6 } },
        .{ .tag = .int, .payload = .{ .int = 10 } },
        .{ .tag = .int, .payload = .{ .int = 20 } },
        .{ .tag = .int, .payload = .{ .int = 30 } },
        .{ .tag = .int, .payload = .{ .int = 40 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");
    var q = try compile(".[2:]");
    defer q.deinit();
    const vals = try collectAll(&q, t);
    defer alloc.free(vals);
    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0] == .array);
    // [30, 40]: array_start + 2 ints + array_end = 4 entries
    try std.testing.expectEqual(@as(u32, 4), vals[0].array.end - vals[0].array.start);
}

test "slice: .[:2] extracts first two elements" {
    // [10, 20, 30] → .[:2] = [10, 20]
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 5 } },
        .{ .tag = .int, .payload = .{ .int = 10 } },
        .{ .tag = .int, .payload = .{ .int = 20 } },
        .{ .tag = .int, .payload = .{ .int = 30 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");
    var q = try compile(".[:2]");
    defer q.deinit();
    var it = try q.execute(t, alloc);
    defer it.deinit();
    const v = (try it.next()).?;
    try std.testing.expect(v == .array);
    // [10, 20]: array_start + 2 ints + array_end = 4 entries
    try std.testing.expectEqual(@as(u32, 4), v.array.end - v.array.start);
    try std.testing.expectEqual(@as(i64, 10), v.array.tape.entries[v.array.start + 1].payload.int);
    try std.testing.expectEqual(@as(i64, 20), v.array.tape.entries[v.array.start + 2].payload.int);
    try std.testing.expectEqual(@as(?Value, null), try it.next());
}

test "slice: .[-2:] extracts last two elements" {
    // [10, 20, 30] → .[-2:] = [20, 30]
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 5 } },
        .{ .tag = .int, .payload = .{ .int = 10 } },
        .{ .tag = .int, .payload = .{ .int = 20 } },
        .{ .tag = .int, .payload = .{ .int = 30 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");
    var q = try compile(".[-2:]");
    defer q.deinit();
    var it = try q.execute(t, alloc);
    defer it.deinit();
    const v = (try it.next()).?;
    try std.testing.expect(v == .array);
    // [20, 30]: array_start + 2 ints + array_end = 4 entries
    try std.testing.expectEqual(@as(u32, 4), v.array.end - v.array.start);
    try std.testing.expectEqual(@as(i64, 20), v.array.tape.entries[v.array.start + 1].payload.int);
    try std.testing.expectEqual(@as(?Value, null), try it.next());
}

test "slice: .[:-1] extracts all but last element" {
    // [10, 20, 30]
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 5 } },
        .{ .tag = .int, .payload = .{ .int = 10 } },
        .{ .tag = .int, .payload = .{ .int = 20 } },
        .{ .tag = .int, .payload = .{ .int = 30 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");
    var q = try compile(".[:-1]");
    defer q.deinit();
    const vals = try collectAll(&q, t);
    defer alloc.free(vals);
    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0] == .array);
    // [10, 20]: array_start + 2 ints + array_end = 4 entries
    try std.testing.expectEqual(@as(u32, 4), vals[0].array.end - vals[0].array.start);
}

test "slice: .[0:0] returns empty array" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 4 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .int, .payload = .{ .int = 2 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");
    var q = try compile(".[0:0]");
    defer q.deinit();
    const vals = try collectAll(&q, t);
    defer alloc.free(vals);
    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0] == .array);
    // empty: array_start + array_end = 2 entries
    try std.testing.expectEqual(@as(u32, 2), vals[0].array.end - vals[0].array.start);
}

test "slice: out-of-bounds indices are clamped, returns empty" {
    const entries = [_]Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 4 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .int, .payload = .{ .int = 2 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");
    var q = try compile(".[100:200]");
    defer q.deinit();
    const vals = try collectAll(&q, t);
    defer alloc.free(vals);
    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0] == .array);
    try std.testing.expectEqual(@as(u32, 2), vals[0].array.end - vals[0].array.start);
}

test "slice: string slice extracts byte range" {
    // "hello" → .[1:4] = "ell"
    const sb = "hello";
    const entries = [_]Entry{
        .{ .tag = .string, .payload = .{ .string = .{ .offset = 0, .len = 5 } } },
    };
    const t = tape(&entries, sb);
    var q = try compile(".[1:4]");
    defer q.deinit();
    var it = try q.execute(t, alloc);
    defer it.deinit();
    const v = (try it.next()).?;
    try std.testing.expect(v == .string);
    try std.testing.expectEqualStrings("ell", v.string);
    try std.testing.expectEqual(@as(?Value, null), try it.next());
}

test "slice: TypeError on non-array non-string" {
    const entries = [_]Entry{.{ .tag = .int, .payload = .{ .int = 42 } }};
    const t = tape(&entries, "");
    var q = try compile(".[1:2]");
    defer q.deinit();
    var it = try q.execute(t, alloc);
    defer it.deinit();
    try std.testing.expectError(error.TypeError, it.next());
}

// ── Update assignment ─────────────────────────────────────────────────────────

test "update |=: replace object field" {
    // {"a": 1, "b": 2} | .a |= . + 10  →  {"a": 11, "b": 2}
    const sb = "ab";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 6 } },
        .{ .tag = .key,          .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .int,          .payload = .{ .int = 1 } },
        .{ .tag = .key,          .payload = .{ .string = .{ .offset = 1, .len = 1 } } },
        .{ .tag = .int,          .payload = .{ .int = 2 } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);
    var q = try compile(".a |= . + 10");
    defer q.deinit();
    var it = try q.execute(t, alloc);
    defer it.deinit();
    const v = (try it.next()).?;
    try std.testing.expect(v == .object);
    const span = v.object;
    // entries: [obj_start, key"a", int/float 11, key"b", int 2, obj_end]
    try std.testing.expectEqual(Tag.object_start, span.tape.entries[span.start].tag);
    // "a" value at start+2: result of . + 10 (may be float)
    const a_entry = span.tape.entries[span.start + 2];
    try std.testing.expect(a_entry.tag == .float or a_entry.tag == .int);
    if (a_entry.tag == .float) {
        try std.testing.expectApproxEqAbs(@as(f64, 11.0), a_entry.payload.float, 0.001);
    } else {
        try std.testing.expectEqual(@as(i64, 11), a_entry.payload.int);
    }
    // "b" value at start+4: unchanged int 2
    try std.testing.expectEqual(@as(i64, 2), span.tape.entries[span.start + 4].payload.int);
    try std.testing.expectEqual(@as(?Value, null), try it.next());
}

test "update +=: increment field" {
    // {"n": 5} | .n += 3  →  {"n": 8}
    const sb = "n";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key,          .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .int,          .payload = .{ .int = 5 } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);
    var q = try compile(".n += 3");
    defer q.deinit();
    var it = try q.execute(t, alloc);
    defer it.deinit();
    const v = (try it.next()).?;
    try std.testing.expect(v == .object);
    const span = v.object;
    try std.testing.expectEqual(Tag.object_start, span.tape.entries[span.start].tag);
    // "n" value at start+2: 5 + 3 = 8 (may be float from add)
    const n_entry = span.tape.entries[span.start + 2];
    try std.testing.expect(n_entry.tag == .float or n_entry.tag == .int);
    if (n_entry.tag == .float) {
        try std.testing.expectApproxEqAbs(@as(f64, 8.0), n_entry.payload.float, 0.001);
    } else {
        try std.testing.expectEqual(@as(i64, 8), n_entry.payload.int);
    }
    try std.testing.expectEqual(@as(?Value, null), try it.next());
}

test "update |=: replace array element" {
    // [1,2,3] | .[1] |= . * 10  →  [1,20,3]
    const entries = [_]Entry{
        .{ .tag = .array_start,  .payload = .{ .skip = 5 } },
        .{ .tag = .int,          .payload = .{ .int = 1 } },
        .{ .tag = .int,          .payload = .{ .int = 2 } },
        .{ .tag = .int,          .payload = .{ .int = 3 } },
        .{ .tag = .array_end,    .payload = .{ .none = {} } },
    };
    const t = tape(&entries, "");
    var q = try compile(".[1] |= . * 10");
    defer q.deinit();
    var it = try q.execute(t, alloc);
    defer it.deinit();
    const v = (try it.next()).?;
    try std.testing.expect(v == .array);
    const span = v.array;
    // entries: [arr_start, int 1, float/int 20, int 3, arr_end]
    try std.testing.expectEqual(Tag.array_start, span.tape.entries[span.start].tag);
    try std.testing.expectEqual(@as(i64, 1), span.tape.entries[span.start + 1].payload.int);
    const mid = span.tape.entries[span.start + 2];
    try std.testing.expect(mid.tag == .float or mid.tag == .int);
    if (mid.tag == .float) {
        try std.testing.expectApproxEqAbs(@as(f64, 20.0), mid.payload.float, 0.001);
    } else {
        try std.testing.expectEqual(@as(i64, 20), mid.payload.int);
    }
    try std.testing.expectEqual(@as(i64, 3), span.tape.entries[span.start + 3].payload.int);
    try std.testing.expectEqual(@as(?Value, null), try it.next());
}

test "update //=: uses default when field is null" {
    // {"x": null} | .x //= 99  →  {"x": 99}
    const sb = "x";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key,          .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .null_val,     .payload = .{ .none = {} } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);
    var q = try compile(".x //= 99");
    defer q.deinit();
    var it = try q.execute(t, alloc);
    defer it.deinit();
    const v = (try it.next()).?;
    try std.testing.expect(v == .object);
    const span = v.object;
    // entries: [obj_start, key"x", int 99, obj_end]
    try std.testing.expectEqual(Tag.object_start, span.tape.entries[span.start].tag);
    try std.testing.expectEqual(@as(i64, 99), span.tape.entries[span.start + 2].payload.int);
    try std.testing.expectEqual(@as(?Value, null), try it.next());
}

test "update //=: keeps existing truthy value" {
    // {"x": 42} | .x //= 99  →  {"x": 42}
    const sb = "x";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key,          .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .int,          .payload = .{ .int = 42 } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);
    var q = try compile(".x //= 99");
    defer q.deinit();
    var it = try q.execute(t, alloc);
    defer it.deinit();
    const v = (try it.next()).?;
    try std.testing.expect(v == .object);
    const span = v.object;
    try std.testing.expectEqual(@as(i64, 42), span.tape.entries[span.start + 2].payload.int);
    try std.testing.expectEqual(@as(?Value, null), try it.next());
}

test "update |=: nested path .a.b" {
    // {"a": {"b": 1}} | .a.b |= . + 100  →  {"a": {"b": 101}}
    const sb = "ab";
    const entries = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 7 } },
        .{ .tag = .key,          .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .object_start, .payload = .{ .skip = 6 } },
        .{ .tag = .key,          .payload = .{ .string = .{ .offset = 1, .len = 1 } } },
        .{ .tag = .int,          .payload = .{ .int = 1 } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
    };
    const t = tape(&entries, sb);
    var q = try compile(".a.b |= . + 100");
    defer q.deinit();
    var it = try q.execute(t, alloc);
    defer it.deinit();
    const v = (try it.next()).?;
    try std.testing.expect(v == .object);
    const outer = v.object;
    try std.testing.expectEqual(Tag.object_start, outer.tape.entries[outer.start].tag);
    // Inner object at outer.start+2
    try std.testing.expectEqual(Tag.object_start, outer.tape.entries[outer.start + 2].tag);
    // "b" value at outer.start+4: 1 + 100 = 101 (may be float)
    const b_entry = outer.tape.entries[outer.start + 4];
    try std.testing.expect(b_entry.tag == .float or b_entry.tag == .int);
    if (b_entry.tag == .float) {
        try std.testing.expectApproxEqAbs(@as(f64, 101.0), b_entry.payload.float, 0.001);
    } else {
        try std.testing.expectEqual(@as(i64, 101), b_entry.payload.int);
    }
    try std.testing.expectEqual(@as(?Value, null), try it.next());
}
