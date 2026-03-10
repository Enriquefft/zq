// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â conditionals (18 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L1314 [.[] | if .foo then _yep_ else _nope_ end]" {
    const results = try h.runFilter(
        "[.[] | if .foo then \"yep\" else \"nope\" end]",
        "[{\"foo\":0},{\"foo\":1},{\"foo\":[]},{\"foo\":true},{\"foo\":false},{\"foo\":null},{\"foo\":\"foo\"},{}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"yep\",\"yep\",\"yep\",\"yep\",\"nope\",\"nope\",\"yep\",\"nope\"]", results[0]);
}

test "jq:L1318 [.[] | if .baz then _strange_ elif .foo then _yep_ else _..." {
    const results = try h.runFilter(
        "[.[] | if .baz then \"strange\" elif .foo then \"yep\" else \"nope\" end]",
        "[{\"foo\":0},{\"foo\":1},{\"foo\":[]},{\"foo\":true},{\"foo\":false},{\"foo\":null},{\"foo\":\"foo\"},{}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"yep\",\"yep\",\"yep\",\"yep\",\"nope\",\"nope\",\"yep\",\"nope\"]", results[0]);
}

test "jq:L1322 [if 1,null,2 then 3 else 4 end]" {
    const results = try h.runFilter(
        "[if 1,null,2 then 3 else 4 end]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[3,4,3]", results[0]);
}

test "jq:L1326 [if empty then 3 else 4 end]" {
    const results = try h.runFilter(
        "[if empty then 3 else 4 end]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L1330 [if 1 then 3,4 else 5 end]" {
    const results = try h.runFilter(
        "[if 1 then 3,4 else 5 end]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[3,4]", results[0]);
}

test "jq:L1334 [if null then 3 else 5,6 end]" {
    const results = try h.runFilter(
        "[if null then 3 else 5,6 end]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[5,6]", results[0]);
}

test "jq:L1338 [if true then 3 end]" {
    const results = try h.runFilter(
        "[if true then 3 end]",
        "7",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[3]", results[0]);
}

test "jq:L1342 [if false then 3 end]" {
    const results = try h.runFilter(
        "[if false then 3 end]",
        "7",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[7]", results[0]);
}

test "jq:L1346 [if false then 3 else . end]" {
    const results = try h.runFilter(
        "[if false then 3 else . end]",
        "7",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[7]", results[0]);
}

test "jq:L1350 [if false then 3 elif false then 4 end]" {
    const results = try h.runFilter(
        "[if false then 3 elif false then 4 end]",
        "7",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[7]", results[0]);
}

test "jq:L1354 [if false then 3 elif false then 4 else . end]" {
    const results = try h.runFilter(
        "[if false then 3 elif false then 4 else . end]",
        "7",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[7]", results[0]);
}

test "jq:L1358 [-if true then 1 else 2 end]" {
    const results = try h.runFilter(
        "[-if true then 1 else 2 end]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[-1]", results[0]);
}

test "jq:L1362 {x: if true then 1 else 2 end}" {
    const results = try h.runFilter(
        "{x: if true then 1 else 2 end}",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"x\":1}", results[0]);
}

test "jq:L1366 if true then [.] else . end []" {
    const results = try h.runFilter(
        "if true then [.] else . end []",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq:L1370 [.[] | [.foo[] // .bar]]" {
    const results = try h.runFilter(
        "[.[] | [.foo[] // .bar]]",
        "[{\"foo\":[1,2], \"bar\": 42}, {\"foo\":[1], \"bar\": null}, {\"foo\":[null,false,3], \"bar\": 18}, {\"foo\":[], \"bar\":42}, {\"foo\": [null,false,null], \"bar\": 41}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[1,2], [1], [3], [42], [41]]", results[0]);
}

test "jq:L1374 .[] //= .[0]" {
    const results = try h.runFilter(
        ".[] //= .[0]",
        "[\"hello\",true,false,[false],null]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"hello\",true,\"hello\",[false],\"hello\"]", results[0]);
}

test "jq:L1378 .[] | [.[0] and .[1], .[0] or .[1]]" {
    const results = try h.runFilter(
        ".[] | [.[0] and .[1], .[0] or .[1]]",
        "[[true,[]], [false,1], [42,null], [null,false]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("[true,true]", results[0]);
    try std.testing.expectEqualStrings("[false,true]", results[1]);
    try std.testing.expectEqualStrings("[false,true]", results[2]);
    try std.testing.expectEqualStrings("[false,false]", results[3]);
}

test "jq:L1385 [.[] | not]" {
    const results = try h.runFilter(
        "[.[] | not]",
        "[1,0,false,null,true,\"hello\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false,false,true,true,false,false]", results[0]);
}
