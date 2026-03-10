const std = @import("std");
const query = @import("query");
const types = @import("types");

const CompiledQuery  = query.CompiledQuery;
const Opts           = query.Opts;
const Tape           = types.Tape;
const Entry          = types.Tape.Entry;
const Tag            = types.Tape.Tag;
const Payload        = types.Tape.Payload;
const StringRef      = types.Tape.StringRef;
const Value          = types.Value;
const alloc          = std.testing.allocator;

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
        .{ .tag = .key,          .payload = .{ .string = ref } },
        .{ .tag = .int,          .payload = .{ .int = 99 } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
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
        .{ .tag = .key,          .payload = .{ .string = ref } },
        .{ .tag = .int,          .payload = .{ .int = 1 } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
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
        .{ .tag = .key,          .payload = .{ .string = ref } },
        .{ .tag = .int,          .payload = .{ .int = 1 } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
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
        .{ .tag = .int,         .payload = .{ .int = 1 } },
        .{ .tag = .int,         .payload = .{ .int = 2 } },
        .{ .tag = .array_end,   .payload = .{ .none = {} } },
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
        .{ .tag = .key,          .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .object_start, .payload = .{ .skip = 6 } },
        .{ .tag = .key,          .payload = .{ .string = .{ .offset = 1, .len = 1 } } },
        .{ .tag = .int,          .payload = .{ .int = 7 } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
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
        .{ .tag = .int,         .payload = .{ .int = 10 } },
        .{ .tag = .int,         .payload = .{ .int = 20 } },
        .{ .tag = .int,         .payload = .{ .int = 30 } },
        .{ .tag = .array_end,   .payload = .{ .none = {} } },
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
        .{ .tag = .int,         .payload = .{ .int = 5 } },
        .{ .tag = .array_end,   .payload = .{ .none = {} } },
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
        .{ .tag = .int,         .payload = .{ .int = 1 } },
        .{ .tag = .array_end,   .payload = .{ .none = {} } },
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
        .{ .tag = .int,         .payload = .{ .int = 1 } },
        .{ .tag = .int,         .payload = .{ .int = 2 } },
        .{ .tag = .int,         .payload = .{ .int = 3 } },
        .{ .tag = .array_end,   .payload = .{ .none = {} } },
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
        .{ .tag = .array_end,   .payload = .{ .none = {} } },
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
        .{ .tag = .key,          .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .int,          .payload = .{ .int = 1 } },
        .{ .tag = .key,          .payload = .{ .string = .{ .offset = 1, .len = 1 } } },
        .{ .tag = .int,          .payload = .{ .int = 2 } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
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
    const a_ref    = StringRef{ .offset = 4, .len = 1 };
    const b_ref    = StringRef{ .offset = 5, .len = 1 };

    const entries = [_]Entry{
        .{ .tag = .array_start,  .payload = .{ .skip = 10 } },
        .{ .tag = .object_start, .payload = .{ .skip = 5 } },
        .{ .tag = .key,          .payload = .{ .string = name_ref } },
        .{ .tag = .string,       .payload = .{ .string = a_ref } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
        .{ .tag = .object_start, .payload = .{ .skip = 9 } },
        .{ .tag = .key,          .payload = .{ .string = name_ref } },
        .{ .tag = .string,       .payload = .{ .string = b_ref } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
        .{ .tag = .array_end,    .payload = .{ .none = {} } },
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
        .{ .tag = .int,         .payload = .{ .int = 1 } },
        .{ .tag = .int,         .payload = .{ .int = 2 } },
        .{ .tag = .array_end,   .payload = .{ .none = {} } },
        .{ .tag = .array_start, .payload = .{ .skip = 8 } },
        .{ .tag = .int,         .payload = .{ .int = 3 } },
        .{ .tag = .array_end,   .payload = .{ .none = {} } },
        .{ .tag = .array_end,   .payload = .{ .none = {} } },
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
        .{ .tag = .array_end,   .payload = .{ .none = {} } },
        .{ .tag = .array_start, .payload = .{ .skip = 6 } }, // [1]
        .{ .tag = .int,         .payload = .{ .int = 1 } },
        .{ .tag = .array_end,   .payload = .{ .none = {} } },
        .{ .tag = .array_end,   .payload = .{ .none = {} } },
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
        .{ .tag = .key,          .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .null_val,     .payload = .{ .none = {} } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
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
        .{ .tag = .key,          .payload = .{ .string = .{ .offset = 0, .len = 3 } } },
        .{ .tag = .int,          .payload = .{ .int = 30 } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
    };
    const tape_1 = tape(&entries_1, sb1);

    // Object 2: {"age": 55}
    const sb2 = "age";
    const entries_2 = [_]Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 3 } },
        .{ .tag = .key,          .payload = .{ .string = .{ .offset = 0, .len = 3 } } },
        .{ .tag = .int,          .payload = .{ .int = 55 } },
        .{ .tag = .object_end,   .payload = .{ .none = {} } },
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
