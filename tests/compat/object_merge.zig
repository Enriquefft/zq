// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â object_merge (24 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L2295 { a, $__loc__, c }" {
    const results = try h.runFilter(
        "{ a, $__loc__, c }",
        "{\"a\":[1,2,3],\"b\":\"foo\",\"c\":{\"hi\":\"hey\"}}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":[1,2,3],\"__loc__\":{\"file\":\"<top-level>\",\"line\":1},\"c\":{\"hi\":\"hey\"}}", results[0]);
}

test "jq:L2299 1 as $x | _2_ as $y | _3_ as $z | { $x, as, $y: 4, ($z): ..." {
    const results = try h.runFilter(
        "1 as $x | \"2\" as $y | \"3\" as $z | { $x, as, $y: 4, ($z): 5, if: 6, foo: 7 }",
        "{\"as\":8}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"x\":1,\"as\":8,\"2\":4,\"3\":5,\"if\":6,\"foo\":7}", results[0]);
}

test "jq:L2306 fromjson | isnan" {
    const results = try h.runFilter(
        "fromjson | isnan",
        "\"nan\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2310 tojson | fromjson" {
    const results = try h.runFilter(
        "tojson | fromjson",
        "{\"a\":nan}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":null}", results[0]);
}

test "jq:L2315 .[] | try (fromjson | isnan) catch ." {
    const results = try h.runFilter(
        ".[] | try (fromjson | isnan) catch .",
        "[\"NaN\",\"-NaN\",\"NaN1\",\"NaN10\",\"NaN100\",\"NaN1000\",\"NaN10000\",\"NaN100000\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
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
    const results = try h.runFilter(
        "try input catch .",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"break\"", results[0]);
}

test "jq:L2332 debug" {
    const results = try h.runFilter(
        "debug",
        "1",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L2337 _foo_ | try ((try . catch _caught too much_) | error) cat..." {
    const results = try h.runFilter(
        "\"foo\" | try ((try . catch \"caught too much\") | error) catch \"caught just right\"",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"caught just right\"", results[0]);
}

test "jq:L2341 .[]|(try (if .==_hi_ then . else error end) catch empty) ..." {
    const results = try h.runFilter(
        ".[]|(try (if .==\"hi\" then . else error end) catch empty) | \"\\(.) there!\"",
        "[\"hi\",\"ho\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"hi there!\"", results[0]);
}

test "jq:L2345 try ([_hi_,_ho_]|.[]|(try . catch (if .==_ho_ then _BROKE..." {
    const results = try h.runFilter(
        "try ([\"hi\",\"ho\"]|.[]|(try . catch (if .==\"ho\" then \"BROKEN\"|error else empty end)) | if .==\"ho\" then error else \"\\(.) there!\" end) catch \"caught outside \\(.)\"",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("\"hi there!\"", results[0]);
    try std.testing.expectEqualStrings("\"caught outside ho\"", results[1]);
}

test "jq:L2350 .[]|(try . catch (if .==_ho_ then _BROKEN_|error else emp..." {
    const results = try h.runFilter(
        ".[]|(try . catch (if .==\"ho\" then \"BROKEN\"|error else empty end)) | if .==\"ho\" then error else \"\\(.) there!\" end",
        "[\"hi\",\"ho\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"hi there!\"", results[0]);
}

test "jq:L2354 try (try error catch _inner catch _(.)_) catch _outer cat..." {
    const results = try h.runFilter(
        "try (try error catch \"inner catch \\(.)\") catch \"outer catch \\(.)\"",
        "\"foo\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"inner catch foo\"", results[0]);
}

test "jq:L2358 try ((try error catch _inner catch _(.)_)|error) catch _o..." {
    const results = try h.runFilter(
        "try ((try error catch \"inner catch \\(.)\")|error) catch \"outer catch \\(.)\"",
        "\"foo\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"outer catch inner catch foo\"", results[0]);
}

test "jq:L2363 first(.?,.?)" {
    const results = try h.runFilter(
        "first(.?,.?)",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq:L2368 {foo: _bar_} | .foo |= .?" {
    const results = try h.runFilter(
        "{foo: \"bar\"} | .foo |= .?",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"foo\": \"bar\"}", results[0]);
}

test "jq:L2373 . |= try 2" {
    const results = try h.runFilter(
        ". |= try 2",
        "1",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("2", results[0]);
}

test "jq:L2377 . |= try 2 catch 3" {
    const results = try h.runFilter(
        ". |= try 2 catch 3",
        "1",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("2", results[0]);
}

test "jq:L2381 .[] |= try tonumber" {
    const results = try h.runFilter(
        ".[] |= try tonumber",
        "[\"1\", \"2a\", \"3\", \" 4\", \"5 \", \"6.7\", \".89\", \"-876\", \"+5.43\", 21]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1, 3, 6.7, 0.89, -876, 5.43, 21]", results[0]);
}

test "jq:L2386 any(keys[]|tostring?;true)" {
    const results = try h.runFilter(
        "any(keys[]|tostring?;true)",
        "{\"a\":\"1\",\"b\":\"2\",\"c\":\"3\"}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2394 implode|explode" {
    const results = try h.runFilter(
        "implode|explode",
        "[-1,0,1,2,3,1114111,1114112,55295,55296,57343,57344,1.1,1.9]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[65533,0,1,2,3,1114111,65533,55295,65533,65533,57344,1,1]", results[0]);
}

test "jq:L2398 map(try implode catch .)" {
    const results = try h.runFilter(
        "map(try implode catch .)",
        "[123,[\"a\"],[nan]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"implode input must be an array\",\"string (\\\"a\\\") can't be imploded, unicode codepoint needs to be numeric\",\"number (null) can't be imploded, unicode codepoint needs to be numeric\"]", results[0]);
}

test "jq:L2402 try 0[implode] catch ." {
    const results = try h.runFilter(
        "try 0[implode] catch .",
        "[]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Cannot index number with string (\\\"\\\")\"", results[0]);
}

test "jq:L2407 walk(.)" {
    const results = try h.runFilter(
        "walk(.)",
        "{\"x\":0}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"x\":0}", results[0]);
}

test "jq:L2411 walk(1)" {
    const results = try h.runFilter(
        "walk(1)",
        "{\"x\":0}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}
