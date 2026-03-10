// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â assignment (19 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L1221 .message = _goodbye_" {
    const results = try h.runFilter(
        ".message = \"goodbye\"",
        "{\"message\": \"hello\"}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"message\": \"goodbye\"}", results[0]);
}

test "jq:L1225 .foo = .bar" {
    const results = try h.runFilter(
        ".foo = .bar",
        "{\"bar\":42}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"foo\":42, \"bar\":42}", results[0]);
}

test "jq:L1229 .foo |= .+1" {
    const results = try h.runFilter(
        ".foo |= .+1",
        "{\"foo\": 42}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"foo\": 43}", results[0]);
}

test "jq:L1233 .[] += 2, .[] *= 2, .[] -= 2, .[] /= 2, .[] %=2" {
    const results = try h.runFilter(
        ".[] += 2, .[] *= 2, .[] -= 2, .[] /= 2, .[] %=2",
        "[1,3,5]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 5), results.len);
    try std.testing.expectEqualStrings("[3,5,7]", results[0]);
    try std.testing.expectEqualStrings("[2,6,10]", results[1]);
    try std.testing.expectEqualStrings("[-1,1,3]", results[2]);
    try std.testing.expectEqualStrings("[0.5, 1.5, 2.5]", results[3]);
    try std.testing.expectEqualStrings("[1,1,1]", results[4]);
}

test "jq:L1241 [.[] % 7]" {
    const results = try h.runFilter(
        "[.[] % 7]",
        "[-7,-6,-5,-4,-3,-2,-1,0,1,2,3,4,5,6,7]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,-6,-5,-4,-3,-2,-1,0,1,2,3,4,5,6,0]", results[0]);
}

test "jq:L1245 .foo += .foo" {
    const results = try h.runFilter(
        ".foo += .foo",
        "{\"foo\":2}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"foo\":4}", results[0]);
}

test "jq:L1249 .[0].a |= {_old_:., _new_:(.+1)}" {
    const results = try h.runFilter(
        ".[0].a |= {\"old\":., \"new\":(.+1)}",
        "[{\"a\":1,\"b\":2}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[{\"a\":{\"old\":1, \"new\":2},\"b\":2}]", results[0]);
}

test "jq:L1253 def inc(x): x |= .+1; inc(.[].a)" {
    const results = try h.runFilter(
        "def inc(x): x |= .+1; inc(.[].a)",
        "[{\"a\":1,\"b\":2},{\"a\":2,\"b\":4},{\"a\":7,\"b\":8}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[{\"a\":2,\"b\":2},{\"a\":3,\"b\":4},{\"a\":8,\"b\":8}]", results[0]);
}

test "jq:L1258 .[] | try (getpath([_a_,0,_b_]) |= 5) catch ." {
    const results = try h.runFilter(
        ".[] | try (getpath([\"a\",0,\"b\"]) |= 5) catch .",
        "[null,{\"b\":0},{\"a\":0},{\"a\":null},{\"a\":[0,1]},{\"a\":{\"b\":1}},{\"a\":[{}]},{\"a\":[{\"c\":3}]}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
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
    const results = try h.runFilter(
        "(.[] | select(. >= 2)) |= empty",
        "[1,5,3,0,7]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,0]", results[0]);
}

test "jq:L1274 .[] |= select(. % 2 == 0)" {
    const results = try h.runFilter(
        ".[] |= select(. % 2 == 0)",
        "[0,1,2,3,4,5]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,2,4]", results[0]);
}

test "jq:L1278 .foo[1,4,2,3] |= empty" {
    const results = try h.runFilter(
        ".foo[1,4,2,3] |= empty",
        "{\"foo\":[0,1,2,3,4,5]}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"foo\":[0,5]}", results[0]);
}

test "jq:L1282 .[2][3] = 1" {
    const results = try h.runFilter(
        ".[2][3] = 1",
        "[4]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[4, null, [null, null, null, 1]]", results[0]);
}

test "jq:L1286 .foo[2].bar = 1" {
    const results = try h.runFilter(
        ".foo[2].bar = 1",
        "{\"foo\":[11], \"bar\":42}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"foo\":[11,null,{\"bar\":1}], \"bar\":42}", results[0]);
}

test "jq:L1290 try ((map(select(.a == 1))[].b) = 10) catch ." {
    const results = try h.runFilter(
        "try ((map(select(.a == 1))[].b) = 10) catch .",
        "[{\"a\":0},{\"a\":1}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid path expression near attempt to iterate through [{\\\"a\\\":1}]\"", results[0]);
}

test "jq:L1294 try ((map(select(.a == 1))[].a) |= .+1) catch ." {
    const results = try h.runFilter(
        "try ((map(select(.a == 1))[].a) |= .+1) catch .",
        "[{\"a\":0},{\"a\":1}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid path expression near attempt to iterate through [{\\\"a\\\":1}]\"", results[0]);
}

test "jq:L1298 def x: .[1,2]; x=10" {
    const results = try h.runFilter(
        "def x: .[1,2]; x=10",
        "[0,1,2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,10,10]", results[0]);
}

test "jq:L1302 try (def x: reverse; x=10) catch ." {
    const results = try h.runFilter(
        "try (def x: reverse; x=10) catch .",
        "[0,1,2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid path expression with result [2,1,0]\"", results[0]);
}

test "jq:L1306 .[] = 1" {
    const results = try h.runFilter(
        ".[] = 1",
        "[1,null,Infinity,-Infinity,NaN,-NaN]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,1,1,1,1,1]", results[0]);
}
