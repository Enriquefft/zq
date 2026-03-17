// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â unary_negation (17 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L2215 -. | tojson == if have_decnum then _-13911860366432393_ e..." {
    const results = try h.runFilter(
        "-. | tojson == if have_decnum then \"-13911860366432393\" else \"-13911860366432392\" end",
        "13911860366432393",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2219 -. | tojson == if have_decnum then _0.1234567890123456789..." {
    const results = try h.runFilter(
        "-. | tojson == if have_decnum then \"0.12345678901234567890123456789\" else \"0.12345678901234568\" end",
        "-0.12345678901234567890123456789",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2223 [1E+1000,-1E+1000 | tojson] == if have_decnum then [_1E+1..." {
    const results = try h.runFilter(
        "[1E+1000,-1E+1000 | tojson] == if have_decnum then [\"1E+1000\",\"-1E+1000\"] else [\"1.7976931348623157e+308\",\"-1.7976931348623157e+308\"] end",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2227 . |= try . catch ." {
    const results = try h.runFilter(
        ". |= try . catch .",
        "1",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L2232 .[] as $n | $n+0 | [., tostring, . == $n]" {
    const results = try h.runFilter(
        ".[] as $n | $n+0 | [., tostring, . == $n]",
        "[-9007199254740993, -9007199254740992, 9007199254740992, 9007199254740993, 13911860366432393]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 5), results.len);
    try std.testing.expectEqualStrings("[-9007199254740992,\"-9007199254740992\",true]", results[0]);
    try std.testing.expectEqualStrings("[-9007199254740992,\"-9007199254740992\",true]", results[1]);
    try std.testing.expectEqualStrings("[9007199254740992,\"9007199254740992\",true]", results[2]);
    try std.testing.expectEqualStrings("[9007199254740992,\"9007199254740992\",true]", results[3]);
    try std.testing.expectEqualStrings("[13911860366432392,\"13911860366432392\",true]", results[4]);
}

test "jq:L2241 abs" {
    const results = try h.runFilter(
        "abs",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"abc\"", results[0]);
}

test "jq:L2245 map(abs)" {
    const results = try h.runFilter(
        "map(abs)",
        "[-0, 0, -10, -1.1]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,0,10,1.1]", results[0]);
}

test "jq:L2249 map(fabs)" {
    const results = try h.runFilter(
        "map(fabs)",
        "[-0, 0, -10, -1.1]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,0,10,1.1]", results[0]);
}

test "jq:L2253 map(abs == length) | unique" {
    const results = try h.runFilter(
        "map(abs == length) | unique",
        "[-10, -1.1, -1e-1, 1000000000000000002]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true]", results[0]);
}

test "jq:L2258 map(abs)" {
    const results = try h.runFilter(
        "map(abs)",
        "[0.1,1000000000000000002]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1e-1,1000000000000000002]", results[0]);
}

test "jq:L2262 [1E+1000,-1E+1000 | abs | tojson] | unique == if have_dec..." {
    const results = try h.runFilter(
        "[1E+1000,-1E+1000 | abs | tojson] | unique == if have_decnum then [\"1E+1000\"] else [\"1.7976931348623157e+308\"] end",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2266 [1E+1000,-1E+1000 | length | tojson] | unique == if have_..." {
    const results = try h.runFilter(
        "[1E+1000,-1E+1000 | length | tojson] | unique == if have_decnum then [\"1E+1000\"] else [\"1.7976931348623157e+308\"] end",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L2272 123 as $label | $label" {
    const results = try h.runFilter(
        "123 as $label | $label",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("123", results[0]);
}

test "jq:L2276 [ label $if | range(10) | ., (select(. == 5) | break $if) ]" {
    const results = try h.runFilter(
        "[ label $if | range(10) | ., (select(. == 5) | break $if) ]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,3,4,5]", results[0]);
}

test "jq:L2280 reduce .[] as $then (4 as $else | $else; . as $elif | . +..." {
    const results = try h.runFilter(
        "reduce .[] as $then (4 as $else | $else; . as $elif | . + $then * $elif)",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("96", results[0]);
}

test "jq:L2284 1 as $foreach | 2 as $and | 3 as $or | { $foreach, $and, ..." {
    const results = try h.runFilter(
        "1 as $foreach | 2 as $and | 3 as $or | { $foreach, $and, $or, a }",
        "{\"a\":4,\"b\":5}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"foreach\":1,\"and\":2,\"or\":3,\"a\":4}", results[0]);
}

test "jq:L2288 [ foreach .[] as $try (1 as $catch | $catch - 1; . + $try..." {
    const results = try h.runFilter(
        "[ foreach .[] as $try (1 as $catch | $catch - 1; . + $try; .) ]",
        "[10,9,8,7]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[10,19,27,34]", results[0]);
}
