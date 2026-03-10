// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â variables (15 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L498 1 as $x | 2 as $y | [$x,$y,$x]" {
    const results = try h.runFilter(
        "1 as $x | 2 as $y | [$x,$y,$x]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,1]", results[0]);
}

test "jq:L502 [1,2,3][] as $x | [[4,5,6,7][$x]]" {
    const results = try h.runFilter(
        "[1,2,3][] as $x | [[4,5,6,7][$x]]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("[5]", results[0]);
    try std.testing.expectEqualStrings("[6]", results[1]);
    try std.testing.expectEqualStrings("[7]", results[2]);
}

test "jq:L508 42 as $x | . | . | . + 432 | $x + 1" {
    const results = try h.runFilter(
        "42 as $x | . | . | . + 432 | $x + 1",
        "34324",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("43", results[0]);
}

test "jq:L512 1 + 2 as $x | -$x" {
    const results = try h.runFilter(
        "1 + 2 as $x | -$x",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("-3", results[0]);
}

test "jq:L516 _x_ as $x | _a_+_y_ as $y | $x+_,_+$y" {
    const results = try h.runFilter(
        "\"x\" as $x | \"a\"+\"y\" as $y | $x+\",\"+$y",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"x,ay\"", results[0]);
}

test "jq:L520 1 as $x | [$x,$x,$x as $x | $x]" {
    const results = try h.runFilter(
        "1 as $x | [$x,$x,$x as $x | $x]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,1,1]", results[0]);
}

test "jq:L524 [1, {c:3, d:4}] as [$a, {c:$b, b:$c}] | $a, $b, $c" {
    const results = try h.runFilter(
        "[1, {c:3, d:4}] as [$a, {c:$b, b:$c}] | $a, $b, $c",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("3", results[1]);
    try std.testing.expectEqualStrings("null", results[2]);
}

test "jq:L530 . as {as: $kw, _str_: $str, (_e_+_x_+_p_): $exp} | [$kw, ..." {
    const results = try h.runFilter(
        ". as {as: $kw, \"str\": $str, (\"e\"+\"x\"+\"p\"): $exp} | [$kw, $str, $exp]",
        "{\"as\": 1, \"str\": 2, \"exp\": 3}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1, 2, 3]", results[0]);
}

test "jq:L534 .[] as [$a, $b] | [$b, $a]" {
    const results = try h.runFilter(
        ".[] as [$a, $b] | [$b, $a]",
        "[[1], [1, 2, 3]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("[null, 1]", results[0]);
    try std.testing.expectEqualStrings("[2, 1]", results[1]);
}

test "jq:L539 . as $i | . as [$i] | $i" {
    const results = try h.runFilter(
        ". as $i | . as [$i] | $i",
        "[0]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("0", results[0]);
}

test "jq:L543 . as [$i] | . as $i | $i" {
    const results = try h.runFilter(
        ". as [$i] | . as $i | $i",
        "[0]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0]", results[0]);
}

test "jq:L547 . as [] | null" {
    // %%FAIL: filter should not compile
    try h.expectCompileError(". as [] | null");
}

test "jq:L553 . as {} | null" {
    // %%FAIL: filter should not compile
    try h.expectCompileError(". as {} | null");
}

test "jq:L559 . as $foo | [$foo, $bar]" {
    // %%FAIL: filter should not compile
    try h.expectCompileError(". as $foo | [$foo, $bar]");
}

test "jq:L565 . as {(true):$foo} | $foo" {
    // %%FAIL: filter should not compile
    try h.expectCompileError(". as {(true):$foo} | $foo");
}
