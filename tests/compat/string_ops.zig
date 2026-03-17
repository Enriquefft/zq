// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â string_ops (34 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L1742 {_k_: {_a_: 1, _b_: 2}} * ." {
    const results = try h.runFilter(
        "{\"k\": {\"a\": 1, \"b\": 2}} * .",
        "{\"k\": {\"a\": 0,\"c\": 3}}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"k\":{\"a\":0,\"b\":2,\"c\":3}}", results[0]);
}

test "jq:L1746 {_k_: {_a_: 1, _b_: 2}, _hello_: {_x_: 1}} * ." {
    const results = try h.runFilter(
        "{\"k\": {\"a\": 1, \"b\": 2}, \"hello\": {\"x\": 1}} * .",
        "{\"k\": {\"a\": 0,\"c\": 3}, \"hello\": 1}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"k\":{\"a\":0,\"b\":2,\"c\":3},\"hello\":1}", results[0]);
}

test "jq:L1750 {_k_: {_a_: 1, _b_: 2}, _hello_: 1} * ." {
    const results = try h.runFilter(
        "{\"k\": {\"a\": 1, \"b\": 2}, \"hello\": 1} * .",
        "{\"k\": {\"a\": 0,\"c\": 3}, \"hello\": {\"x\": 1}}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"k\":{\"a\":0,\"b\":2,\"c\":3},\"hello\":{\"x\":1}}", results[0]);
}

test "jq:L1754 {_a_: {_b_: 1}, _c_: {_d_: 2}, _e_: 5} * ." {
    const results = try h.runFilter(
        "{\"a\": {\"b\": 1}, \"c\": {\"d\": 2}, \"e\": 5} * .",
        "{\"a\": {\"b\": 2}, \"c\": {\"d\": 3, \"f\": 9}}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":{\"b\":2},\"c\":{\"d\":3,\"f\":9},\"e\":5}", results[0]);
}

test "jq:L1758 [.[]|arrays]" {
    const results = try h.runFilter(
        "[.[]|arrays]",
        "[1,2,\"foo\",[],[3,[]],{},true,false,null]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[],[3,[]]]", results[0]);
}

test "jq:L1762 [.[]|objects]" {
    const results = try h.runFilter(
        "[.[]|objects]",
        "[1,2,\"foo\",[],[3,[]],{},true,false,null]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[{}]", results[0]);
}

test "jq:L1766 [.[]|iterables]" {
    const results = try h.runFilter(
        "[.[]|iterables]",
        "[1,2,\"foo\",[],[3,[]],{},true,false,null]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[],[3,[]],{}]", results[0]);
}

test "jq:L1770 [.[]|scalars]" {
    const results = try h.runFilter(
        "[.[]|scalars]",
        "[1,2,\"foo\",[],[3,[]],{},true,false,null]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,\"foo\",true,false,null]", results[0]);
}

test "jq:L1774 [.[]|values]" {
    const results = try h.runFilter(
        "[.[]|values]",
        "[1,2,\"foo\",[],[3,[]],{},true,false,null]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,\"foo\",[],[3,[]],{},true,false]", results[0]);
}

test "jq:L1778 [.[]|booleans]" {
    const results = try h.runFilter(
        "[.[]|booleans]",
        "[1,2,\"foo\",[],[3,[]],{},true,false,null]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,false]", results[0]);
}

test "jq:L1782 [.[]|nulls]" {
    const results = try h.runFilter(
        "[.[]|nulls]",
        "[1,2,\"foo\",[],[3,[]],{},true,false,null]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null]", results[0]);
}

test "jq:L1786 flatten" {
    const results = try h.runFilter(
        "flatten",
        "[0, [1], [[2]], [[[3]]]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,3]", results[0]);
}

test "jq:L1790 flatten(0)" {
    const results = try h.runFilter(
        "flatten(0)",
        "[0, [1], [[2]], [[[3]]]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,[1],[[2]],[[[3]]]]", results[0]);
}

test "jq:L1794 flatten(2)" {
    const results = try h.runFilter(
        "flatten(2)",
        "[0, [1], [[2]], [[[3]]]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,[3]]", results[0]);
}

test "jq:L1798 flatten(2)" {
    const results = try h.runFilter(
        "flatten(2)",
        "[0, [1, [2]], [1, [[3], 2]]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,1,[3],2]", results[0]);
}

test "jq:L1802 try flatten(-1) catch ." {
    const results = try h.runFilter(
        "try flatten(-1) catch .",
        "[0, [1], [[2]], [[[3]]]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"flatten depth must not be negative\"", results[0]);
}

test "jq:L1806 transpose" {
    const results = try h.runFilter(
        "transpose",
        "[[1], [2,3]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[1,2],[null,3]]", results[0]);
}

test "jq:L1810 transpose" {
    const results = try h.runFilter(
        "transpose",
        "[]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L1814 ascii_upcase" {
    const results = try h.runFilter(
        "ascii_upcase",
        "\"useful but not for é\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"USEFUL BUT NOT FOR é\"", results[0]);
}

test "jq:L1818 bsearch(0,1,2,3,4)" {
    const results = try h.runFilter(
        "bsearch(0,1,2,3,4)",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 5), results.len);
    try std.testing.expectEqualStrings("-1", results[0]);
    try std.testing.expectEqualStrings("0", results[1]);
    try std.testing.expectEqualStrings("1", results[2]);
    try std.testing.expectEqualStrings("2", results[3]);
    try std.testing.expectEqualStrings("-4", results[4]);
}

test "jq:L1826 bsearch({x:1})" {
    const results = try h.runFilter(
        "bsearch({x:1})",
        "[{ \"x\": 0 },{ \"x\": 1 },{ \"x\": 2 }]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L1830 try [_OK_, bsearch(0)] catch [_KO_,.]" {
    const results = try h.runFilter(
        "try [\"OK\", bsearch(0)] catch [\"KO\",.]",
        "\"aa\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"KO\",\"string (\\\"aa\\\") cannot be searched from\"]", results[0]);
}

test "jq:L1834 strftime(_%Y-%m-%dT%H:%M:%SZ_)" {
    const results = try h.runFilter(
        "strftime(\"%Y-%m-%dT%H:%M:%SZ\")",
        "[2015,2,5,23,51,47,4,63]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"2015-03-05T23:51:47Z\"", results[0]);
}

test "jq:L1838 strftime(_%A, %B %d, %Y_)" {
    const results = try h.runFilter(
        "strftime(\"%A, %B %d, %Y\")",
        "1435677542.822351",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Tuesday,June 30,2015\"", results[0]);
}

test "jq:L1842 strftime(_%Y-%m-%dT%H:%M:%SZ_)" {
    const results = try h.runFilter(
        "strftime(\"%Y-%m-%dT%H:%M:%SZ\")",
        "[2024,2,15]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"2024-03-15T00:00:00Z\"", results[0]);
}

test "jq:L1846 mktime" {
    const results = try h.runFilter(
        "mktime",
        "[2024,8,21]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1726876800", results[0]);
}

test "jq:L1850 gmtime" {
    const results = try h.runFilter(
        "gmtime",
        "1425599507",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[2015,2,5,23,51,47,4,63]", results[0]);
}

test "jq:L1854 gmtime[5]" {
    const results = try h.runFilter(
        "gmtime[5]",
        "1425599507.25",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("47.25", results[0]);
}

test "jq:L1859 try strftime(_%Y-%m-%dT%H:%M:%SZ_) catch ." {
    const results = try h.runFilter(
        "try strftime(\"%Y-%m-%dT%H:%M:%SZ\") catch .",
        "[\"a\",1,2,3,4,5,6,7]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"strftime/1 requires parsed datetime inputs\"", results[0]);
}

test "jq:L1863 try strflocaltime(_%Y-%m-%dT%H:%M:%SZ_) catch ." {
    const results = try h.runFilter(
        "try strflocaltime(\"%Y-%m-%dT%H:%M:%SZ\") catch .",
        "[\"a\",1,2,3,4,5,6,7]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"strflocaltime/1 requires parsed datetime inputs\"", results[0]);
}

test "jq:L1867 try mktime catch ." {
    const results = try h.runFilter(
        "try mktime catch .",
        "[\"a\",1,2,3,4,5,6,7]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"mktime requires parsed datetime inputs\"", results[0]);
}

test "jq:L1872 try [_OK_, strftime([])] catch [_KO_, .]" {
    const results = try h.runFilter(
        "try [\"OK\", strftime([])] catch [\"KO\", .]",
        "0",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"KO\",\"strftime/1 requires a string format\"]", results[0]);
}

test "jq:L1876 try [_OK_, strflocaltime({})] catch [_KO_, .]" {
    const results = try h.runFilter(
        "try [\"OK\", strflocaltime({})] catch [\"KO\", .]",
        "0",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"KO\",\"strflocaltime/1 requires a string format\"]", results[0]);
}

test "jq:L1880 [strptime(_%Y-%m-%dT%H:%M:%SZ_)|(.,mktime)]" {
    const results = try h.runFilter(
        "[strptime(\"%Y-%m-%dT%H:%M:%SZ\")|(.,mktime)]",
        "\"2015-03-05T23:51:47Z\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[2015,2,5,23,51,47,4,63],1425599507]", results[0]);
}
