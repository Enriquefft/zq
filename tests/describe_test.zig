const std = @import("std");
const describe = @import("describe");
const parser_mod = @import("parser");

const alloc = std.testing.allocator;

fn inferSchema(inputs: []const []const u8, max_depth: u32) !describe.SchemaInferrer {
    var inferrer = describe.SchemaInferrer.init(alloc, max_depth);
    errdefer inferrer.deinit();

    var parser = try parser_mod.Parser.init(alloc);
    defer parser.deinit();

    for (inputs) |input| {
        const result = try parser.feed(input, true);
        const tape = switch (result) {
            .done => |d| d.tape,
            .need_more => return error.ParseIncomplete,
            // `.dropped` only flows from `feedPlanned`; this is plain `feed`.
            .dropped => unreachable,
        };
        try inferrer.feedTape(tape);
        parser.reset();
    }
    return inferrer;
}

fn serializeCompact(inferrer: *const describe.SchemaInferrer, sort_keys: bool) ![]u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(alloc);
    try inferrer.serialize(buf.writer(alloc), sort_keys);
    return try buf.toOwnedSlice(alloc);
}

// ── Single scalar types ──────────────────────────────────────────────────────

test "describe: null" {
    var inf = try inferSchema(&.{"null"}, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"type\":\"null\",\"count\":1}", out);
}

test "describe: boolean" {
    var inf = try inferSchema(&.{"true"}, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"type\":\"boolean\",\"count\":1}", out);
}

test "describe: number (int)" {
    var inf = try inferSchema(&.{"42"}, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"type\":\"number\",\"count\":1}", out);
}

test "describe: number (float)" {
    var inf = try inferSchema(&.{"3.14"}, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"type\":\"number\",\"count\":1}", out);
}

test "describe: string" {
    var inf = try inferSchema(&.{"\"hello\""}, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"type\":\"string\",\"count\":1}", out);
}

// ── Homogeneous object records ───────────────────────────────────────────────

test "describe: simple object" {
    var inf = try inferSchema(&.{"{\"id\":1,\"name\":\"alice\"}"}, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, true);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"fields\":{\"id\":\"number\",\"name\":\"string\"},\"count\":1}",
        out,
    );
}

// ── Mixed-type fields ────────────────────────────────────────────────────────

test "describe: mixed types" {
    var inf = try inferSchema(&.{ "{\"id\":1}", "{\"id\":\"abc\"}" }, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"fields\":{\"id\":[\"number\",\"string\"]},\"count\":2}",
        out,
    );
}

// ── Nested objects ───────────────────────────────────────────────────────────

test "describe: nested objects" {
    var inf = try inferSchema(&.{"{\"addr\":{\"street\":\"Main\",\"zip\":\"12345\"}}"}, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, true);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"fields\":{\"addr\":{\"type\":\"object\",\"fields\":{\"street\":\"string\",\"zip\":\"string\"}}},\"count\":1}",
        out,
    );
}

// ── Arrays ───────────────────────────────────────────────────────────────────

test "describe: array with uniform elements" {
    var inf = try inferSchema(&.{"[1,2,3]"}, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":\"array\",\"elements\":\"number\",\"count\":1}",
        out,
    );
}

test "describe: array with mixed elements" {
    var inf = try inferSchema(&.{"[1,\"two\",true]"}, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":\"array\",\"elements\":[\"boolean\",\"number\",\"string\"],\"count\":1}",
        out,
    );
}

test "describe: object with array field" {
    var inf = try inferSchema(&.{"{\"tags\":[\"a\",\"b\"]}"}, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"fields\":{\"tags\":{\"type\":\"array\",\"elements\":\"string\"}},\"count\":1}",
        out,
    );
}

// ── Optional fields ─────────────────────────────────────────────────────────

test "describe: optional fields" {
    var inf = try inferSchema(&.{ "{\"id\":1}", "{\"id\":2,\"extra\":\"x\"}" }, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, true);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"fields\":{\"extra\":{\"type\":\"string\",\"optional\":true},\"id\":\"number\"},\"count\":2}",
        out,
    );
}

// ── Empty input ──────────────────────────────────────────────────────────────

test "describe: empty input" {
    var inf = describe.SchemaInferrer.init(alloc, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"type\":\"empty\",\"count\":0}", out);
}

// ── Empty objects/arrays ─────────────────────────────────────────────────────

test "describe: empty object" {
    var inf = try inferSchema(&.{"{}"}, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"type\":\"object\",\"count\":1}", out);
}

test "describe: empty array" {
    var inf = try inferSchema(&.{"[]"}, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"type\":\"array\",\"count\":1}", out);
}

// ── Depth cap behavior ───────────────────────────────────────────────────────

test "describe: depth cap stops recursion" {
    var inf = try inferSchema(&.{"{\"a\":{\"b\":{\"c\":1}}}"}, 1);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"fields\":{\"a\":\"object\"},\"count\":1}",
        out,
    );
}

test "describe: depth 0 means unlimited" {
    var inf = try inferSchema(&.{"{\"a\":{\"b\":{\"c\":1}}}"}, 0);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"fields\":{\"a\":{\"type\":\"object\",\"fields\":{\"b\":{\"type\":\"object\",\"fields\":{\"c\":\"number\"}}}}},\"count\":1}",
        out,
    );
}

// ── Multiple files merged schema ─────────────────────────────────────────────

test "describe: multiple records merged" {
    var inf = try inferSchema(&.{
        "{\"id\":1,\"name\":\"alice\"}",
        "{\"id\":2,\"name\":\"bob\",\"age\":30}",
    }, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, true);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"fields\":{\"age\":{\"type\":\"number\",\"optional\":true},\"id\":\"number\",\"name\":\"string\"},\"count\":2}",
        out,
    );
}

// ── Wide objects ─────────────────────────────────────────────────────────────

test "describe: wide object" {
    var inf = try inferSchema(&.{"{\"a\":1,\"b\":2,\"c\":3,\"d\":4,\"e\":5,\"f\":6,\"g\":7,\"h\":8}"}, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, true);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"fields\":{\"a\":\"number\",\"b\":\"number\",\"c\":\"number\",\"d\":\"number\",\"e\":\"number\",\"f\":\"number\",\"g\":\"number\",\"h\":\"number\"},\"count\":1}",
        out,
    );
}

// ── Mixed top-level types ────────────────────────────────────────────────────

test "describe: mixed top-level types" {
    var inf = try inferSchema(&.{ "42", "\"hello\"", "null" }, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":[\"null\",\"number\",\"string\"],\"count\":3}",
        out,
    );
}

// ── Full example from plan ───────────────────────────────────────────────────

test "describe: full plan example" {
    var inf = try inferSchema(&.{"{\"id\":1,\"name\":\"alice\",\"address\":{\"street\":\"Main\",\"zip\":\"00000\"},\"tags\":[\"a\"]}"}, 12);
    defer inf.deinit();
    const out = try serializeCompact(&inf, false);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"fields\":{\"id\":\"number\",\"name\":\"string\",\"address\":{\"type\":\"object\",\"fields\":{\"street\":\"string\",\"zip\":\"string\"}},\"tags\":{\"type\":\"array\",\"elements\":\"string\"}},\"count\":1}",
        out,
    );
}
