// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â paths (24 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L1110 path(.foo[0,1])" {
    const results = try h.runFilter(
        "path(.foo[0,1])",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("[\"foo\", 0]", results[0]);
    try std.testing.expectEqualStrings("[\"foo\", 1]", results[1]);
}

test "jq:L1115 path(.[] | select(.>3))" {
    const results = try h.runFilter(
        "path(.[] | select(.>3))",
        "[1,5,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1]", results[0]);
}

test "jq:L1119 path(.)" {
    const results = try h.runFilter(
        "path(.)",
        "42",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L1123 try path(.a | map(select(.b == 0))) catch ." {
    const results = try h.runFilter(
        "try path(.a | map(select(.b == 0))) catch .",
        "{\"a\":[{\"b\":0}]}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid path expression with result [{\\\"b\\\":0}]\"", results[0]);
}

test "jq:L1127 try path(.a | map(select(.b == 0)) | .[0]) catch ." {
    const results = try h.runFilter(
        "try path(.a | map(select(.b == 0)) | .[0]) catch .",
        "{\"a\":[{\"b\":0}]}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid path expression near attempt to access element 0 of [{\\\"b\\\":0}]\"", results[0]);
}

test "jq:L1131 try path(.a | map(select(.b == 0)) | .c) catch ." {
    const results = try h.runFilter(
        "try path(.a | map(select(.b == 0)) | .c) catch .",
        "{\"a\":[{\"b\":0}]}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid path expression near attempt to access element \\\"c\\\" of [{\\\"b\\\":0}]\"", results[0]);
}

test "jq:L1135 try path(.a | map(select(.b == 0)) | .[]) catch ." {
    const results = try h.runFilter(
        "try path(.a | map(select(.b == 0)) | .[]) catch .",
        "{\"a\":[{\"b\":0}]}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Invalid path expression near attempt to iterate through [{\\\"b\\\":0}]\"", results[0]);
}

test "jq:L1139 path(.a[path(.b)[0]])" {
    const results = try h.runFilter(
        "path(.a[path(.b)[0]])",
        "{\"a\":{\"b\":0}}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\",\"b\"]", results[0]);
}

test "jq:L1143 [paths]" {
    const results = try h.runFilter(
        "[paths]",
        "[1,[[],{\"a\":2}]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[0],[1],[1,0],[1,1],[1,1,\"a\"]]", results[0]);
}

test "jq:L1147 [_foo_,1] as $p | getpath($p), setpath($p; 20), delpaths(..." {
    const results = try h.runFilter(
        "[\"foo\",1] as $p | getpath($p), setpath($p; 20), delpaths([$p])",
        "{\"bar\": 42, \"foo\": [\"a\", \"b\", \"c\", \"d\"]}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("\"b\"", results[0]);
    try std.testing.expectEqualStrings("{\"bar\": 42, \"foo\": [\"a\", 20, \"c\", \"d\"]}", results[1]);
    try std.testing.expectEqualStrings("{\"bar\": 42, \"foo\": [\"a\", \"c\", \"d\"]}", results[2]);
}

test "jq:L1153 map(getpath([2])), map(setpath([2]; 42)), map(delpaths([[..." {
    const results = try h.runFilter(
        "map(getpath([2])), map(setpath([2]; 42)), map(delpaths([[2]]))",
        "[[0], [0,1], [0,1,2]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("[null, null, 2]", results[0]);
    try std.testing.expectEqualStrings("[[0,null,42], [0,1,42], [0,1,42]]", results[1]);
    try std.testing.expectEqualStrings("[[0], [0,1], [0,1]]", results[2]);
}

test "jq:L1159 map(delpaths([[0,_foo_]]))" {
    const results = try h.runFilter(
        "map(delpaths([[0,\"foo\"]]))",
        "[[{\"foo\":2, \"x\":1}], [{\"bar\":2}]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[{\"x\":1}], [{\"bar\":2}]]", results[0]);
}

test "jq:L1163 [_foo_,1] as $p | getpath($p), setpath($p; 20), delpaths(..." {
    const results = try h.runFilter(
        "[\"foo\",1] as $p | getpath($p), setpath($p; 20), delpaths([$p])",
        "{\"bar\":false}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
    try std.testing.expectEqualStrings("{\"bar\":false, \"foo\": [null, 20]}", results[1]);
    try std.testing.expectEqualStrings("{\"bar\":false}", results[2]);
}

test "jq:L1169 delpaths([[-200]])" {
    const results = try h.runFilter(
        "delpaths([[-200]])",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L1173 try delpaths(0) catch ." {
    const results = try h.runFilter(
        "try delpaths(0) catch .",
        "{}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Paths must be specified as an array\"", results[0]);
}

test "jq:L1177 del(.), del(empty), del((.foo,.bar,.baz) | .[2,3,0]), del..." {
    const results = try h.runFilter(
        "del(.), del(empty), del((.foo,.bar,.baz) | .[2,3,0]), del(.foo[0], .bar[0], .foo, .baz.bar[0].x)",
        "{\"foo\": [0,1,2,3,4], \"bar\": [0,1]}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
    try std.testing.expectEqualStrings("{\"foo\": [0,1,2,3,4], \"bar\": [0,1]}", results[1]);
    try std.testing.expectEqualStrings("{\"foo\": [1,4], \"bar\": [1]}", results[2]);
    try std.testing.expectEqualStrings("{\"bar\": [1]}", results[3]);
}

test "jq:L1184 del(.[1], .[-6], .[2], .[-3:9])" {
    const results = try h.runFilter(
        "del(.[1], .[-6], .[2], .[-3:9])",
        "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0, 3, 5, 6, 9]", results[0]);
}

test "jq:L1188 del(.[nan])" {
    const results = try h.runFilter(
        "del(.[nan])",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L1192 del(.[nan,nan])" {
    const results = try h.runFilter(
        "del(.[nan,nan])",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3]", results[0]);
}

test "jq:L1197 setpath([-1]; 1)" {
    const results = try h.runFilter(
        "setpath([-1]; 1)",
        "[0]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1]", results[0]);
}

test "jq:L1201 pick(.a.b.c)" {
    const results = try h.runFilter(
        "pick(.a.b.c)",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\":{\"b\":{\"c\":null}}}", results[0]);
}

test "jq:L1205 pick(first)" {
    const results = try h.runFilter(
        "pick(first)",
        "[1,2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1]", results[0]);
}

test "jq:L1209 pick(first|first)" {
    const results = try h.runFilter(
        "pick(first|first)",
        "[[10,20],30]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[10]]", results[0]);
}

test "jq:L1214 try pick(last) catch ." {
    const results = try h.runFilter(
        "try pick(last) catch .",
        "[1,2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Out of bounds negative array index\"", results[0]);
}
