// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â object_construction (6 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L114 {a: 1}" {
    const results = try h.runFilter(
        "{a: 1}",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":1}", results[0]);
}

test "jq:L118 {a,b,(.d):.a,e:.b}" {
    const results = try h.runFilter(
        "{a,b,(.d):.a,e:.b}",
        "{\"a\":1, \"b\":2, \"c\":3, \"d\":\"c\"}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":1, \"b\":2, \"c\":1, \"e\":2}", results[0]);
}

test "jq:L122 {_a_,b,_a$_(1+1)_}" {
    const results = try h.runFilter(
        "{\"a\",b,\"a$\\(1+1)\"}",
        "{\"a\":1, \"b\":2, \"c\":3, \"a$2\":4}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":1, \"b\":2, \"a$2\":4}", results[0]);
}

test "jq:L126 {(0):1}" {
    // %%FAIL: filter should not compile
    try h.expectCompileError("{(0):1}");
}

test "jq:L132 {1+2:3}" {
    // %%FAIL: filter should not compile
    try h.expectCompileError("{1+2:3}");
}

test "jq:L138 {non_const:., (0):1}" {
    // %%FAIL: filter should not compile
    try h.expectCompileError("{non_const:., (0):1}");
}
