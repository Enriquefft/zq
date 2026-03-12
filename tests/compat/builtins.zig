// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â builtins (44 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L577 1+1" {
    const results = try h.runFilter(
        "1+1",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("2", results[0]);
}

test "jq:L581 1+1" {
    const results = try h.runFilter(
        "1+1",
        "\"wtasdf\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("2", results[0]);
}

test "jq:L585 2-1" {
    const results = try h.runFilter(
        "2-1",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L589 2-(-1)" {
    const results = try h.runFilter(
        "2-(-1)",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("3", results[0]);
}

test "jq:L593 1e+0+0.001e3" {
    const results = try h.runFilter(
        "1e+0+0.001e3",
        "\"I wonder what this will be?\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("2", results[0]);
}

test "jq:L597 .+4" {
    const results = try h.runFilter(
        ".+4",
        "15",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("19", results[0]);
}

test "jq:L601 .+null" {
    const results = try h.runFilter(
        ".+null",
        "{\"a\":42}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":42}", results[0]);
}

test "jq:L605 null+." {
    const results = try h.runFilter(
        "null+.",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq:L609 .a+.b" {
    const results = try h.runFilter(
        ".a+.b",
        "{\"a\":42}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("42", results[0]);
}

test "jq:L613 [1,2,3] + [.]" {
    const results = try h.runFilter(
        "[1,2,3] + [.]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3,null]", results[0]);
}

test "jq:L617 {_a_:1} + {_b_:2} + {_c_:3}" {
    const results = try h.runFilter(
        "{\"a\":1} + {\"b\":2} + {\"c\":3}",
        "\"asdfasdf\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":2,\"c\":3}", results[0]);
}

test "jq:L621 _asdf_ + _jkl;_ + . + . + ." {
    const results = try h.runFilter(
        "\"asdf\" + \"jkl;\" + . + . + .",
        "\"some string\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"asdfjkl;some stringsome stringsome string\"", results[0]);
}

test "jq:L625 __u0000_u0020_u0000_ + ." {
    const results = try h.runFilter(
        "\"\\u0000\\u0020\\u0000\" + .",
        "\"\\u0000\\u0020\\u0000\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"\\u0000 \\u0000\\u0000 \\u0000\"", results[0]);
}

test "jq:L629 42 - ." {
    const results = try h.runFilter(
        "42 - .",
        "11",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("31", results[0]);
}

test "jq:L633 [1,2,3,4,1] - [.,3]" {
    const results = try h.runFilter(
        "[1,2,3,4,1] - [.,3]",
        "1",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[2,4]", results[0]);
}

test "jq:L637 [-1 as $x | 1,$x]" {
    const results = try h.runFilter(
        "[-1 as $x | 1,$x]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,-1]", results[0]);
}

test "jq:L641 [10 * 20, 20 / .]" {
    const results = try h.runFilter(
        "[10 * 20, 20 / .]",
        "4",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[200, 5]", results[0]);
}

test "jq:L645 1 + 2 * 2 + 10 / 2" {
    const results = try h.runFilter(
        "1 + 2 * 2 + 10 / 2",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("10", results[0]);
}

test "jq:L649 [16 / 4 / 2, 16 / 4 * 2, 16 - 4 - 2, 16 - 4 + 2]" {
    const results = try h.runFilter(
        "[16 / 4 / 2, 16 / 4 * 2, 16 - 4 - 2, 16 - 4 + 2]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[2, 8, 10, 14]", results[0]);
}

test "jq:L653 1e-19 + 1e-20 - 5e-21" {
    const results = try h.runFilter(
        "1e-19 + 1e-20 - 5e-21",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("0.000000000000000000105", results[0]);
}

test "jq:L657 1 / 1e-17" {
    const results = try h.runFilter(
        "1 / 1e-17",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("100000000000000000", results[0]);
}

test "jq:L661 9E999999999, 9999999999E999999990, 1E-999999999, 0.000000..." {
    const results = try h.runFilter(
        "9E999999999, 9999999999E999999990, 1E-999999999, 0.000000001E-999999990",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("9E+999999999", results[0]);
    try std.testing.expectEqualStrings("9.999999999E+999999999", results[1]);
    try std.testing.expectEqualStrings("1E-999999999", results[2]);
    try std.testing.expectEqualStrings("1E-999999999", results[3]);
}

test "jq:L668 5E500000000 > 5E-5000000000, 10000E500000000 > 10000E-500..." {
    const results = try h.runFilter(
        "5E500000000 > 5E-5000000000, 10000E500000000 > 10000E-5000000000",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
    try std.testing.expectEqualStrings("true", results[1]);
}

test "jq:L674 (1e999999999, 10e999999999) > (1e-1147483646, 0.1e-114748..." {
    const results = try h.runFilter(
        "(1e999999999, 10e999999999) > (1e-1147483646, 0.1e-1147483646)",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
    try std.testing.expectEqualStrings("true", results[1]);
    try std.testing.expectEqualStrings("true", results[2]);
    try std.testing.expectEqualStrings("true", results[3]);
}

test "jq:L681 25 % 7" {
    const results = try h.runFilter(
        "25 % 7",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("4", results[0]);
}

test "jq:L685 49732 % 472" {
    const results = try h.runFilter(
        "49732 % 472",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("172", results[0]);
}

test "jq:L689 [(infinite, -infinite) % (1, -1, infinite)]" {
    const results = try h.runFilter(
        "[(infinite, -infinite) % (1, -1, infinite)]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,0,0,0,0,-1]", results[0]);
}

test "jq:L693 [nan % 1, 1 % nan | isnan]" {
    const results = try h.runFilter(
        "[nan % 1, 1 % nan | isnan]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true,true]", results[0]);
}

test "jq:L697 1 + tonumber + (_10_ | tonumber)" {
    const results = try h.runFilter(
        "1 + tonumber + (\"10\" | tonumber)",
        "4",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("15", results[0]);
}

test "jq:L701 _123_u0000456_ | try tonumber catch ." {
    const results = try h.runFilter(
        "\"123\\u0000456\" | try tonumber catch .",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"string (\\\"123\\\\u0000456\\\") cannot be parsed as a number\"", results[0]);
}

test "jq:L705 map(toboolean)" {
    const results = try h.runFilter(
        "map(toboolean)",
        "[\"false\",\"true\",false,true]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false,true,false,true]", results[0]);
}

test "jq:L709 .[] | try toboolean catch ." {
    const results = try h.runFilter(
        ".[] | try toboolean catch .",
        "[null,0,\"tru\",\"truee\",\"fals\",\"falsee\",[],{}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 8), results.len);
    try std.testing.expectEqualStrings("\"null (null) cannot be parsed as a boolean\"", results[0]);
    try std.testing.expectEqualStrings("\"number (0) cannot be parsed as a boolean\"", results[1]);
    try std.testing.expectEqualStrings("\"string (\\\"tru\\\") cannot be parsed as a boolean\"", results[2]);
    try std.testing.expectEqualStrings("\"string (\\\"truee\\\") cannot be parsed as a boolean\"", results[3]);
    try std.testing.expectEqualStrings("\"string (\\\"fals\\\") cannot be parsed as a boolean\"", results[4]);
    try std.testing.expectEqualStrings("\"string (\\\"falsee\\\") cannot be parsed as a boolean\"", results[5]);
    try std.testing.expectEqualStrings("\"array ([]) cannot be parsed as a boolean\"", results[6]);
    try std.testing.expectEqualStrings("\"object ({}) cannot be parsed as a boolean\"", results[7]);
}

test "jq:L720 _true_u0000x_, _false_u0000_ | try toboolean catch ." {
    const results = try h.runFilter(
        "\"true\\u0000x\", \"false\\u0000\" | try toboolean catch .",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("\"string (\\\"true\\\\u0000x\\\") cannot be parsed as a boolean\"", results[0]);
    try std.testing.expectEqualStrings("\"string (\\\"false\\\\u0000\\\") cannot be parsed as a boolean\"", results[1]);
}

test "jq:L725 [{_a_:42},.object,10,.num,false,true,null,_b_,[1,4]] | .[..." {
    const results = try h.runFilter(
        "[{\"a\":42},.object,10,.num,false,true,null,\"b\",[1,4]] | .[] as $x | [$x == .[]]",
        "{\"object\": {\"a\":42}, \"num\":10.0}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 9), results.len);
    try std.testing.expectEqualStrings("[true,  true,  false, false, false, false, false, false, false]", results[0]);
    try std.testing.expectEqualStrings("[true,  true,  false, false, false, false, false, false, false]", results[1]);
    try std.testing.expectEqualStrings("[false, false, true,  true,  false, false, false, false, false]", results[2]);
    try std.testing.expectEqualStrings("[false, false, true,  true,  false, false, false, false, false]", results[3]);
    try std.testing.expectEqualStrings("[false, false, false, false, true,  false, false, false, false]", results[4]);
    try std.testing.expectEqualStrings("[false, false, false, false, false, true,  false, false, false]", results[5]);
    try std.testing.expectEqualStrings("[false, false, false, false, false, false, true,  false, false]", results[6]);
    try std.testing.expectEqualStrings("[false, false, false, false, false, false, false, true,  false]", results[7]);
    try std.testing.expectEqualStrings("[false, false, false, false, false, false, false, false, true ]", results[8]);
}

test "jq:L737 [.[] | length]" {
    const results = try h.runFilter(
        "[.[] | length]",
        "[[], {}, [1,2], {\"a\":42}, \"asdf\", \"\\u03bc\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,0,2,1,4,1]", results[0]);
}

test "jq:L741 utf8bytelength" {
    const results = try h.runFilter(
        "utf8bytelength",
        "\"asdf\\u03bc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("6", results[0]);
}

test "jq:L745 [.[] | try utf8bytelength catch .]" {
    const results = try h.runFilter(
        "[.[] | try utf8bytelength catch .]",
        "[[], {}, [1,2], 55, true, false]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"array ([]) only strings have UTF-8 byte length\",\"object ({}) only strings have UTF-8 byte length\",\"array ([1,2]) only strings have UTF-8 byte length\",\"number (55) only strings have UTF-8 byte length\",\"boolean (true) only strings have UTF-8 byte length\",\"boolean (false) only strings have UTF-8 byte length\"]", results[0]);
}

test "jq:L750 map(keys)" {
    const results = try h.runFilter(
        "map(keys)",
        "[{}, {\"abcd\":1,\"abc\":2,\"abcde\":3}, {\"x\":1, \"z\": 3, \"y\":2}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[],[\"abc\",\"abcd\",\"abcde\"],[\"x\",\"y\",\"z\"]]", results[0]);
}

test "jq:L754 [1,2,empty,3,empty,4]" {
    const results = try h.runFilter(
        "[1,2,empty,3,empty,4]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3,4]", results[0]);
}

test "jq:L758 map(add)" {
    const results = try h.runFilter(
        "map(add)",
        "[[], [1,2,3], [\"a\",\"b\",\"c\"], [[3],[4,5],[6]], [{\"a\":1}, {\"b\":2}, {\"a\":3}]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,6,\"abc\",[3,4,5,6],{\"a\":3,\"b\":2}]", results[0]);
}

test "jq:L762 map_values(.+1)" {
    const results = try h.runFilter(
        "map_values(.+1)",
        "[0,1,2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L766 [add(null), add(range(range(10))), add(empty), add(10,ran..." {
    const results = try h.runFilter(
        "[add(null), add(range(range(10))), add(empty), add(10,range(10))]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,120,null,55]", results[0]);
}

test "jq:L771 .sum = add(.arr[])" {
    const results = try h.runFilter(
        ".sum = add(.arr[])",
        "{\"arr\":[]}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"arr\":[],\"sum\":null}", results[0]);
}

test "jq:L775 add({(.[]):1}) | keys" {
    const results = try h.runFilter(
        "add({(.[]):1}) | keys",
        "[\"a\",\"a\",\"b\",\"a\",\"d\",\"b\",\"d\",\"a\",\"d\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\",\"b\",\"d\"]", results[0]);
}
