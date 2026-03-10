// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â regression (28 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L2416 [walk(.,1)]" {
    const results = try h.runFilter(
        "[walk(.,1)]",
        "{\"x\":0}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[{\"x\":0},1]", results[0]);
}

test "jq:L2421 walk(select(IN({}, []) | not))" {
    const results = try h.runFilter(
        "walk(select(IN({}, []) | not))",
        "{\"a\":1,\"b\":[]}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":1}", results[0]);
}

test "jq:L2426 [range(10)] | .[1.2:3.5]" {
    const results = try h.runFilter(
        "[range(10)] | .[1.2:3.5]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L2430 [range(10)] | .[1.5:3.5]" {
    const results = try h.runFilter(
        "[range(10)] | .[1.5:3.5]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L2434 [range(10)] | .[1.7:3.5]" {
    const results = try h.runFilter(
        "[range(10)] | .[1.7:3.5]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L2438 [range(10)] | .[1.7:4294967295]" {
    const results = try h.runFilter(
        "[range(10)] | .[1.7:4294967295]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3,4,5,6,7,8,9]", results[0]);
}

test "jq:L2442 [range(10)] | .[1.7:-4294967296]" {
    const results = try h.runFilter(
        "[range(10)] | .[1.7:-4294967296]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L2446 [[range(10)] | .[1.1,1.5,1.7]]" {
    const results = try h.runFilter(
        "[[range(10)] | .[1.1,1.5,1.7]]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,1,1]", results[0]);
}

test "jq:L2450 [range(5)] | .[1.1] = 5" {
    const results = try h.runFilter(
        "[range(5)] | .[1.1] = 5",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,5,2,3,4]", results[0]);
}

test "jq:L2454 [range(3)] | .[nan:1]" {
    const results = try h.runFilter(
        "[range(3)] | .[nan:1]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0]", results[0]);
}

test "jq:L2458 [range(3)] | .[1:nan]" {
    const results = try h.runFilter(
        "[range(3)] | .[1:nan]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2]", results[0]);
}

test "jq:L2462 [range(3)] | .[nan]" {
    const results = try h.runFilter(
        "[range(3)] | .[nan]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq:L2466 try ([range(3)] | .[nan] = 9) catch ." {
    const results = try h.runFilter(
        "try ([range(3)] | .[nan] = 9) catch .",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Cannot set array element at NaN index\"", results[0]);
}

test "jq:L2470 try (_foobar_ | .[1.5:3.5] = _xyz_) catch ." {
    const results = try h.runFilter(
        "try (\"foobar\" | .[1.5:3.5] = \"xyz\") catch .",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Cannot update string slices\"", results[0]);
}

test "jq:L2474 try ([range(10)] | .[1.5:3.5] = [_xyz_]) catch ." {
    const results = try h.runFilter(
        "try ([range(10)] | .[1.5:3.5] = [\"xyz\"]) catch .",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,\"xyz\",4,5,6,7,8,9]", results[0]);
}

test "jq:L2478 try (_foobar_ | .[1.5]) catch ." {
    const results = try h.runFilter(
        "try (\"foobar\" | .[1.5]) catch .",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Cannot index string with number (1.5)\"", results[0]);
}

test "jq:L2485 try [_ok_, setpath([1]; 1)] catch [_ko_, .]" {
    const results = try h.runFilter(
        "try [\"ok\", setpath([1]; 1)] catch [\"ko\", .]",
        "{\"hi\":\"hello\"}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"ko\",\"Cannot index object with number (1)\"]", results[0]);
}

test "jq:L2489 try fromjson catch ." {
    const results = try h.runFilter(
        "try fromjson catch .",
        "\"{'a': 123}\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid string literal; expected \\\", but got ' at line 1, column 5 (while parsing '{'a': 123}')\"", results[0]);
}

test "jq:L2495 try ltrimstr(1) catch _x_, try rtrimstr(1) catch _x_ | _ok_" {
    const results = try h.runFilter(
        "try ltrimstr(1) catch \"x\", try rtrimstr(1) catch \"x\" | \"ok\"",
        "\"hi\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("\"ok\"", results[0]);
    try std.testing.expectEqualStrings("\"ok\"", results[1]);
}

test "jq:L2500 try ltrimstr(_x_) catch _x_, try rtrimstr(_x_) catch _x_ ..." {
    const results = try h.runFilter(
        "try ltrimstr(\"x\") catch \"x\", try rtrimstr(\"x\") catch \"x\" | \"ok\"",
        "{\"hey\":[]}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("\"ok\"", results[0]);
    try std.testing.expectEqualStrings("\"ok\"", results[1]);
}

test "jq:L2507 .[] as [$x, $y] | try [_ok_, ($x | ltrimstr($y))] catch [..." {
    const results = try h.runFilter(
        ".[] as [$x, $y] | try [\"ok\", ($x | ltrimstr($y))] catch [\"ko\", .]",
        "[[\"hi\",1],[1,\"hi\"],[\"hi\",\"hi\"],[1,1]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[\"ko\",\"startswith() requires string inputs\"]", results[0]);
    try std.testing.expectEqualStrings("[\"ko\",\"startswith() requires string inputs\"]", results[1]);
    try std.testing.expectEqualStrings("[\"ok\",\"\"]", results[2]);
    try std.testing.expectEqualStrings("[\"ko\",\"startswith() requires string inputs\"]", results[3]);
}

test "jq:L2514 .[] as [$x, $y] | try [_ok_, ($x | rtrimstr($y))] catch [..." {
    const results = try h.runFilter(
        ".[] as [$x, $y] | try [\"ok\", ($x | rtrimstr($y))] catch [\"ko\", .]",
        "[[\"hi\",1],[1,\"hi\"],[\"hi\",\"hi\"],[1,1]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[\"ko\",\"endswith() requires string inputs\"]", results[0]);
    try std.testing.expectEqualStrings("[\"ko\",\"endswith() requires string inputs\"]", results[1]);
    try std.testing.expectEqualStrings("[\"ok\",\"\"]", results[2]);
    try std.testing.expectEqualStrings("[\"ko\",\"endswith() requires string inputs\"]", results[3]);
}

test "jq:L2524 try [_OK_, setpath([[1]]; 1)] catch [_KO_, .]" {
    const results = try h.runFilter(
        "try [\"OK\", setpath([[1]]; 1)] catch [\"KO\", .]",
        "[]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"KO\",\"Cannot update field at array index of array\"]", results[0]);
}

test "jq:L2529 foreach .[] as $x (0, 1; . + $x)" {
    const results = try h.runFilter(
        "foreach .[] as $x (0, 1; . + $x)",
        "[1, 2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("3", results[1]);
    try std.testing.expectEqualStrings("2", results[2]);
    try std.testing.expectEqualStrings("4", results[3]);
}

test "jq:L2539 strflocaltime(__ | ., @uri)" {
    const results = try h.runFilter(
        "strflocaltime(\"\" | ., @uri)",
        "0",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("\"\"", results[0]);
    try std.testing.expectEqualStrings("\"\"", results[1]);
}

test "jq:L2549 reduce range(9999) as $_ ([];[.]) | tojson | fromjson | f..." {
    const results = try h.runFilter(
        "reduce range(9999) as $_ ([];[.]) | tojson | fromjson | flatten",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L2554 reduce range(10000) as $_ ([];[.]) | tojson | try (fromjs..." {
    const results = try h.runFilter(
        "reduce range(10000) as $_ ([];[.]) | tojson | try (fromjson) catch . | (contains(\"<skipped: too deep>\") | not) and contains(\"Exceeds depth limit for parsing\")",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2559 reduce range(10001) as $_ ([];[.]) | tojson | contains(_<..." {
    const results = try h.runFilter(
        "reduce range(10001) as $_ ([];[.]) | tojson | contains(\"<skipped: too deep>\")",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}
