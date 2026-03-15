// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// NOTE: Tests L1421-L1442 have expected outputs patched from the generated
// values.  jq's test file (jq.test) inconsistently uses spaces after commas
// in some expected outputs (e.g. "[true, true, false]"), but jq -c actually
// produces compact JSON without spaces ("[true,true,false]").  Our serializer
// matches jq -c, so the expectations are corrected here.  Verified against
// jq 1.8.1.
//
// jq compat â comparisons (13 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L1390 [10 > 0, 10 > 10, 10 > 20, 10 < 0, 10 < 10, 10 < 20]" {
    const results = try h.runFilter(
        "[10 > 0, 10 > 10, 10 > 20, 10 < 0, 10 < 10, 10 < 20]",
        "{}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false,false,false,false,true]", results[0]);
}

test "jq:L1394 [10 >= 0, 10 >= 10, 10 >= 20, 10 <= 0, 10 <= 10, 10 <= 20]" {
    const results = try h.runFilter(
        "[10 >= 0, 10 >= 10, 10 >= 20, 10 <= 0, 10 <= 10, 10 <= 20]",
        "{}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,true,false,false,true,true]", results[0]);
}

test "jq:L1399 [ 10 == 10, 10 != 10, 10 != 11, 10 == 11]" {
    const results = try h.runFilter(
        "[ 10 == 10, 10 != 10, 10 != 11, 10 == 11]",
        "{}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false,true,false]", results[0]);
}

test "jq:L1403 [_hello_ == _hello_, _hello_ != _hello_, _hello_ == _worl..." {
    const results = try h.runFilter(
        "[\"hello\" == \"hello\", \"hello\" != \"hello\", \"hello\" == \"world\", \"hello\" != \"world\" ]",
        "{}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false,false,true]", results[0]);
}

test "jq:L1407 [[1,2,3] == [1,2,3], [1,2,3] != [1,2,3], [1,2,3] == [4,5,..." {
    const results = try h.runFilter(
        "[[1,2,3] == [1,2,3], [1,2,3] != [1,2,3], [1,2,3] == [4,5,6], [1,2,3] != [4,5,6]]",
        "{}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false,false,true]", results[0]);
}

test "jq:L1411 [{_foo_:42} == {_foo_:42},{_foo_:42} != {_foo_:42}, {_foo..." {
    const results = try h.runFilter(
        "[{\"foo\":42} == {\"foo\":42},{\"foo\":42} != {\"foo\":42}, {\"foo\":42} != {\"bar\":42}, {\"foo\":42} == {\"bar\":42}]",
        "{}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false,true,false]", results[0]);
}

test "jq:L1416 [{_foo_:[1,2,{_bar_:18},_world_]} == {_foo_:[1,2,{_bar_:1..." {
    const results = try h.runFilter(
        "[{\"foo\":[1,2,{\"bar\":18},\"world\"]} == {\"foo\":[1,2,{\"bar\":18},\"world\"]},{\"foo\":[1,2,{\"bar\":18},\"world\"]} == {\"foo\":[1,2,{\"bar\":19},\"world\"]}]",
        "{}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false]", results[0]);
}

test "jq:L1421 [(_foo_ | contains(_foo_)), (_foobar_ | contains(_foo_)),..." {
    const results = try h.runFilter(
        "[(\"foo\" | contains(\"foo\")), (\"foobar\" | contains(\"foo\")), (\"foo\" | contains(\"foobar\"))]",
        "{}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,true,false]", results[0]);
}

test "jq:L1426 [contains(__), contains(__u0000_)]" {
    const results = try h.runFilter(
        "[contains(\"\"), contains(\"\\u0000\")]",
        "\"\\u0000\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,true]", results[0]);
}

test "jq:L1430 [contains(__), contains(_a_), contains(_ab_), contains(_c..." {
    const results = try h.runFilter(
        "[contains(\"\"), contains(\"a\"), contains(\"ab\"), contains(\"c\"), contains(\"d\")]",
        "\"ab\\u0000cd\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,true,true,true,true]", results[0]);
}

test "jq:L1434 [contains(_cd_), contains(_b_u0000_), contains(_ab_u0000_)]" {
    const results = try h.runFilter(
        "[contains(\"cd\"), contains(\"b\\u0000\"), contains(\"ab\\u0000\")]",
        "\"ab\\u0000cd\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,true,true]", results[0]);
}

test "jq:L1438 [contains(_b_u0000c_), contains(_b_u0000cd_), contains(_b..." {
    const results = try h.runFilter(
        "[contains(\"b\\u0000c\"), contains(\"b\\u0000cd\"), contains(\"b\\u0000cd\")]",
        "\"ab\\u0000cd\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,true,true]", results[0]);
}

test "jq:L1442 [contains(_@_), contains(__u0000@_), contains(__u0000what_)]" {
    const results = try h.runFilter(
        "[contains(\"@\"), contains(\"\\u0000@\"), contains(\"\\u0000what\")]",
        "\"ab\\u0000cd\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false,false,false]", results[0]);
}
