// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â field_access (14 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L148 .foo" {
    const results = try h.runFilter(
        ".foo",
        "{\"foo\": 42, \"bar\": 43}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("42", results[0]);
}

test "jq:L152 .foo | .bar" {
    const results = try h.runFilter(
        ".foo | .bar",
        "{\"foo\": {\"bar\": 42}, \"bar\": \"badvalue\"}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("42", results[0]);
}

test "jq:L156 .foo.bar" {
    const results = try h.runFilter(
        ".foo.bar",
        "{\"foo\": {\"bar\": 42}, \"bar\": \"badvalue\"}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("42", results[0]);
}

test "jq:L160 .foo_bar" {
    const results = try h.runFilter(
        ".foo_bar",
        "{\"foo_bar\": 2}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("2", results[0]);
}

test "jq:L164 .[_foo_].bar" {
    const results = try h.runFilter(
        ".[\"foo\"].bar",
        "{\"foo\": {\"bar\": 42}, \"bar\": \"badvalue\"}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("42", results[0]);
}

test "jq:L168 ._foo_._bar_" {
    const results = try h.runFilter(
        ".\"foo\".\"bar\"",
        "{\"foo\": {\"bar\": 20}}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("20", results[0]);
}

test "jq:L172 .e0, .E1, .E-1, .E+1" {
    const results = try h.runFilter(
        ".e0, .E1, .E-1, .E+1",
        "{\"e0\": 1, \"E1\": 2, \"E\": 3}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("1", results[0]);
    try h.expectJsonEqual("2", results[1]);
    try h.expectJsonEqual("2", results[2]);
    try h.expectJsonEqual("4", results[3]);
}

test "jq:L179 [.[]|.foo?]" {
    const results = try h.runFilter(
        "[.[]|.foo?]",
        "[1,[2],{\"foo\":3,\"bar\":4},{},{\"foo\":5}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[3,null,5]", results[0]);
}

test "jq:L183 [.[]|.foo?.bar?]" {
    const results = try h.runFilter(
        "[.[]|.foo?.bar?]",
        "[1,[2],[],{\"foo\":3},{\"foo\":{\"bar\":4}},{}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[4,null]", results[0]);
}

test "jq:L187 [..]" {
    const results = try h.runFilter(
        "[..]",
        "[1,[[2]],{ \"a\":[1]}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[[1,[[2]],{\"a\":[1]}],1,[[2]],[2],2,{\"a\":[1]},[1],1]", results[0]);
}

test "jq:L191 [.[]|.[]?]" {
    const results = try h.runFilter(
        "[.[]|.[]?]",
        "[1,null,[],[1,[2,[[3]]]],[{}],[{\"a\":[1,[2]]}]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[1,[2,[[3]]],{},{\"a\":[1,[2]]}]", results[0]);
}

test "jq:L195 [.[]|.[1:3]?]" {
    const results = try h.runFilter(
        "[.[]|.[1:3]?]",
        "[1,null,true,false,\"abcdef\",{},{\"a\":1,\"b\":2},[],[1,2,3,4,5],[1,2]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[null,\"bc\",[],[2,3],[2]]", results[0]);
}

test "jq:L200 map(try .a[] catch ., try .a.[] catch ., .a[]?, .a.[]?)" {
    const results = try h.runFilter(
        "map(try .a[] catch ., try .a.[] catch ., .a[]?, .a.[]?)",
        "[{\"a\": [1,2]}, {\"a\": 123}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[1,2,1,2,1,2,1,2,\"Cannot iterate over number (123)\",\"Cannot iterate over number (123)\"]", results[0]);
}

test "jq:L205 try [_OK_, (.[] | error)] catch [_KO_, .]" {
    const results = try h.runFilter(
        "try [\"OK\", (.[] | error)] catch [\"KO\", .]",
        "{\"a\":[\"b\"],\"c\":[\"d\"]}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[\"KO\",[\"b\"]]", results[0]);
}
