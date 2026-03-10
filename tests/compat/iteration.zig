// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â iteration (55 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L237 .[]" {
    const results = try h.runFilter(
        ".[]",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("2", results[1]);
    try std.testing.expectEqualStrings("3", results[2]);
}

test "jq:L243 1,1" {
    const results = try h.runFilter(
        "1,1",
        "[]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("1", results[1]);
}

test "jq:L248 1,." {
    const results = try h.runFilter(
        "1,.",
        "[]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("[]", results[1]);
}

test "jq:L253 [.]" {
    const results = try h.runFilter(
        "[.]",
        "[2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[2]]", results[0]);
}

test "jq:L257 [[2]]" {
    const results = try h.runFilter(
        "[[2]]",
        "[3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[2]]", results[0]);
}

test "jq:L261 [{}]" {
    const results = try h.runFilter(
        "[{}]",
        "[2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[{}]", results[0]);
}

test "jq:L265 [.[]]" {
    const results = try h.runFilter(
        "[.[]]",
        "[\"a\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\"]", results[0]);
}

test "jq:L269 [(.,1),((.,.[]),(2,3))]" {
    const results = try h.runFilter(
        "[(.,1),((.,.[]),(2,3))]",
        "[\"a\",\"b\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[\"a\",\"b\"],1,[\"a\",\"b\"],\"a\",\"b\",2,3]", results[0]);
}

test "jq:L273 [([5,5][]),.,.[]]" {
    const results = try h.runFilter(
        "[([5,5][]),.,.[]]",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[5,5,[1,2,3],1,2,3]", results[0]);
}

test "jq:L277 {x: (1,2)},{x:3} | .x" {
    const results = try h.runFilter(
        "{x: (1,2)},{x:3} | .x",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("2", results[1]);
    try std.testing.expectEqualStrings("3", results[2]);
}

test "jq:L283 [.[-4,-3,-2,-1,0,1,2,3]]" {
    const results = try h.runFilter(
        "[.[-4,-3,-2,-1,0,1,2,3]]",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,1,2,3,1,2,3,null]", results[0]);
}

test "jq:L287 [range(0;10)]" {
    const results = try h.runFilter(
        "[range(0;10)]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,3,4,5,6,7,8,9]", results[0]);
}

test "jq:L291 [range(0,1;3,4)]" {
    const results = try h.runFilter(
        "[range(0,1;3,4)]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2, 0,1,2,3, 1,2, 1,2,3]", results[0]);
}

test "jq:L295 [range(0;10;3)]" {
    const results = try h.runFilter(
        "[range(0;10;3)]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,3,6,9]", results[0]);
}

test "jq:L299 [range(0;10;-1)]" {
    const results = try h.runFilter(
        "[range(0;10;-1)]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L303 [range(0;-5;-1)]" {
    const results = try h.runFilter(
        "[range(0;-5;-1)]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,-1,-2,-3,-4]", results[0]);
}

test "jq:L307 [range(0,1;4,5;1,2)]" {
    const results = try h.runFilter(
        "[range(0,1;4,5;1,2)]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,3,0,2, 0,1,2,3,4,0,2,4, 1,2,3,1,3, 1,2,3,4,1,3]", results[0]);
}

test "jq:L311 [while(.<100; .*2)]" {
    const results = try h.runFilter(
        "[while(.<100; .*2)]",
        "1",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,4,8,16,32,64]", results[0]);
}

test "jq:L315 [(label $here | .[] | if .>1 then break $here else . end)..." {
    const results = try h.runFilter(
        "[(label $here | .[] | if .>1 then break $here else . end), \"hi!\"]",
        "[0,1,2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,\"hi!\"]", results[0]);
}

test "jq:L319 [(label $here | .[] | if .>1 then break $here else . end)..." {
    const results = try h.runFilter(
        "[(label $here | .[] | if .>1 then break $here else . end), \"hi!\"]",
        "[0,2,1]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,\"hi!\"]", results[0]);
}

test "jq:L323 . as $foo | break $foo" {
    // %%FAIL: filter should not compile
    try h.expectCompileError(". as $foo | break $foo");
}

test "jq:L329 [.[]|[.,1]|until(.[0] < 1; [.[0] - 1, .[1] * .[0]])|.[1]]" {
    const results = try h.runFilter(
        "[.[]|[.,1]|until(.[0] < 1; [.[0] - 1, .[1] * .[0]])|.[1]]",
        "[1,2,3,4,5]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,6,24,120]", results[0]);
}

test "jq:L333 [label $out | foreach .[] as $item ([3, null]; if .[0] < ..." {
    const results = try h.runFilter(
        "[label $out | foreach .[] as $item ([3, null]; if .[0] < 1 then break $out else [.[0] -1, $item] end; .[1])]",
        "[11,22,33,44,55,66,77,88,99]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[11,22,33]", results[0]);
}

test "jq:L337 [foreach range(5) as $item (0; $item)]" {
    const results = try h.runFilter(
        "[foreach range(5) as $item (0; $item)]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,3,4]", results[0]);
}

test "jq:L341 [foreach .[] as [$i, $j] (0; . + $i - $j)]" {
    const results = try h.runFilter(
        "[foreach .[] as [$i, $j] (0; . + $i - $j)]",
        "[[2,1], [5,3], [6,4]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,3,5]", results[0]);
}

test "jq:L345 [foreach .[] as {a:$a} (0; . + $a; -.)]" {
    const results = try h.runFilter(
        "[foreach .[] as {a:$a} (0; . + $a; -.)]",
        "[{\"a\":1}, {\"b\":2}, {\"a\":3, \"b\":4}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[-1, -1, -4]", results[0]);
}

test "jq:L349 [-foreach -.[] as $x (0; . + $x)]" {
    const results = try h.runFilter(
        "[-foreach -.[] as $x (0; . + $x)]",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,3,6]", results[0]);
}

test "jq:L353 [foreach .[] / .[] as $i (0; . + $i)]" {
    const results = try h.runFilter(
        "[foreach .[] / .[] as $i (0; . + $i)]",
        "[1,2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,3,3.5,4.5]", results[0]);
}

test "jq:L357 [foreach .[] as $x (0; . + $x) as $x | $x]" {
    const results = try h.runFilter(
        "[foreach .[] as $x (0; . + $x) as $x | $x]",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,3,6]", results[0]);
}

test "jq:L361 [limit(3; .[])]" {
    const results = try h.runFilter(
        "[limit(3; .[])]",
        "[11,22,33,44,55,66,77,88,99]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[11,22,33]", results[0]);
}

test "jq:L365 [limit(0; error)]" {
    const results = try h.runFilter(
        "[limit(0; error)]",
        "\"badness\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L369 [limit(1; 1, error)]" {
    const results = try h.runFilter(
        "[limit(1; 1, error)]",
        "\"badness\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1]", results[0]);
}

test "jq:L373 try limit(-1; error) catch ." {
    const results = try h.runFilter(
        "try limit(-1; error) catch .",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"limit doesn't support negative count\"", results[0]);
}

test "jq:L377 [skip(3; .[])]" {
    const results = try h.runFilter(
        "[skip(3; .[])]",
        "[1,2,3,4,5,6,7,8,9]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[4,5,6,7,8,9]", results[0]);
}

test "jq:L381 [skip(0,2,3,4; .[])]" {
    const results = try h.runFilter(
        "[skip(0,2,3,4; .[])]",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3,3]", results[0]);
}

test "jq:L385 [skip(3; .[])]" {
    const results = try h.runFilter(
        "[skip(3; .[])]",
        "[]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L389 try skip(-1; error) catch ." {
    const results = try h.runFilter(
        "try skip(-1; error) catch .",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"skip doesn't support negative count\"", results[0]);
}

test "jq:L393 nth(1; 0,1,error(_foo_))" {
    const results = try h.runFilter(
        "nth(1; 0,1,error(\"foo\"))",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L397 [first(range(.)), last(range(.))]" {
    const results = try h.runFilter(
        "[first(range(.)), last(range(.))]",
        "10",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,9]", results[0]);
}

test "jq:L401 [first(range(.)), last(range(.))]" {
    const results = try h.runFilter(
        "[first(range(.)), last(range(.))]",
        "0",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L405 [nth(0,5,9,10,15; range(.)), try nth(-1; range(.)) catch .]" {
    const results = try h.runFilter(
        "[nth(0,5,9,10,15; range(.)), try nth(-1; range(.)) catch .]",
        "10",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,5,9,\"nth doesn't support negative indices\"]", results[0]);
}

test "jq:L410 first(1,error(_foo_))" {
    const results = try h.runFilter(
        "first(1,error(\"foo\"))",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L420 [limit(5,7; range(9))]" {
    const results = try h.runFilter(
        "[limit(5,7; range(9))]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,3,4,0,1,2,3,4,5,6]", results[0]);
}

test "jq:L425 [nth(5,7; range(9;0;-1))]" {
    const results = try h.runFilter(
        "[nth(5,7; range(9;0;-1))]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[4,2]", results[0]);
}

test "jq:L430 [range(0,1,2;4,3,2;2,3)]" {
    const results = try h.runFilter(
        "[range(0,1,2;4,3,2;2,3)]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,2,0,3,0,2,0,0,0,1,3,1,1,1,1,1,2,2,2,2]", results[0]);
}

test "jq:L435 [range(3,5)]" {
    const results = try h.runFilter(
        "[range(3,5)]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2,0,1,2,3,4]", results[0]);
}

test "jq:L440 [(index(_,_,_|_), rindex(_,_,_|_)), indices(_,_,_|_)]" {
    const results = try h.runFilter(
        "[(index(\",\",\"|\"), rindex(\",\",\"|\")), indices(\",\",\"|\")]",
        "\"a,b|c,d,e||f,g,h,|,|,i,j\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,3,22,19,[1,5,7,12,14,16,18,20,22],[3,9,10,17,19]]", results[0]);
}

test "jq:L445 join(_,_,_/_)" {
    const results = try h.runFilter(
        "join(\",\",\"/\")",
        "[\"a\",\"b\",\"c\",\"d\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("\"a,b,c,d\"", results[0]);
    try std.testing.expectEqualStrings("\"a/b/c/d\"", results[1]);
}

test "jq:L450 [.[]|join(_a_)]" {
    const results = try h.runFilter(
        "[.[]|join(\"a\")]",
        "[[],[\"\"],[\"\",\"\"],[\"\",\"\",\"\"]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"\",\"\",\"a\",\"aa\"]", results[0]);
}

test "jq:L455 flatten(3,2,1)" {
    const results = try h.runFilter(
        "flatten(3,2,1)",
        "[0, [1], [[2]], [[[3]]]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("[0,1,2,3]", results[0]);
    try std.testing.expectEqualStrings("[0,1,2,[3]]", results[1]);
    try std.testing.expectEqualStrings("[0,1,[2],[[3]]]", results[2]);
}

test "jq:L466 [.[3:2], .[-5:4], .[:-2], .[-2:], .[3:3][1:], .[10:]]" {
    const results = try h.runFilter(
        "[.[3:2], .[-5:4], .[:-2], .[-2:], .[3:3][1:], .[10:]]",
        "[0,1,2,3,4,5,6]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[], [2,3], [0,1,2,3,4], [5,6], [], []]", results[0]);
}

test "jq:L470 [.[3:2], .[-5:4], .[:-2], .[-2:], .[3:3][1:], .[10:]]" {
    const results = try h.runFilter(
        "[.[3:2], .[-5:4], .[:-2], .[-2:], .[3:3][1:], .[10:]]",
        "\"abcdefghi\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"\",\"\",\"abcdefg\",\"hi\",\"\",\"\"]", results[0]);
}

test "jq:L474 del(.[2:4],.[0],.[-2:])" {
    const results = try h.runFilter(
        "del(.[2:4],.[0],.[-2:])",
        "[0,1,2,3,4,5,6,7]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,4,5]", results[0]);
}

test "jq:L478 .[2:4] = ([], [_a_,_b_], [_a_,_b_,_c_])" {
    const results = try h.runFilter(
        ".[2:4] = ([], [\"a\",\"b\"], [\"a\",\"b\",\"c\"])",
        "[0,1,2,3,4,5,6,7]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("[0,1,4,5,6,7]", results[0]);
    try std.testing.expectEqualStrings("[0,1,\"a\",\"b\",4,5,6,7]", results[1]);
    try std.testing.expectEqualStrings("[0,1,\"a\",\"b\",\"c\",4,5,6,7]", results[2]);
}

test "jq:L490 reduce range(65540;65536;-1) as $i ([]; .[$i] = $i)|.[655..." {
    const results = try h.runFilter(
        "reduce range(65540;65536;-1) as $i ([]; .[$i] = $i)|.[65536:]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,65537,65538,65539,65540]", results[0]);
}
