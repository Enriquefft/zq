// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â user_functions (63 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L784 def f: . + 1; def g: def g: . + 100; f | g | f; (f | g), g" {
    const results = try h.runFilter(
        "def f: . + 1; def g: def g: . + 100; f | g | f; (f | g), g",
        "3.0",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try h.expectJsonEqual("106.0", results[0]);
    try h.expectJsonEqual("105.0", results[1]);
}

test "jq:L789 def f: (1000,2000); f" {
    const results = try h.runFilter(
        "def f: (1000,2000); f",
        "123412345",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try h.expectJsonEqual("1000", results[0]);
    try h.expectJsonEqual("2000", results[1]);
}

test "jq:L794 def f(a;b;c;d;e;f): [a+1,b,c,d,e,f]; f(.[0];.[1];.[0];.[0..." {
    const results = try h.runFilter(
        "def f(a;b;c;d;e;f): [a+1,b,c,d,e,f]; f(.[0];.[1];.[0];.[0];.[0];.[0])",
        "[1,2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[2,2,1,1,1,1]", results[0]);
}

test "jq:L798 def f: 1; def g: f, def f: 2; def g: 3; f, def f: g; f, g..." {
    const results = try h.runFilter(
        "def f: 1; def g: f, def f: 2; def g: 3; f, def f: g; f, g; def f: 4; [f, def f: g; def g: 5; f, g]+[f,g]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[4,1,2,3,3,5,4,1,2,3,3]", results[0]);
}

test "jq:L803 def a: 0; . | a" {
    const results = try h.runFilter(
        "def a: 0; . | a",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("0", results[0]);
}

test "jq:L808 def f(a;b;c;d;e;f;g;h;i;j): [j,i,h,g,f,e,d,c,b,a]; f(.[0]..." {
    const results = try h.runFilter(
        "def f(a;b;c;d;e;f;g;h;i;j): [j,i,h,g,f,e,d,c,b,a]; f(.[0];.[1];.[2];.[3];.[4];.[5];.[6];.[7];.[8];.[9])",
        "[0,1,2,3,4,5,6,7,8,9]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[9,8,7,6,5,4,3,2,1,0]", results[0]);
}

test "jq:L812 ([1,2] + [4,5])" {
    const results = try h.runFilter(
        "([1,2] + [4,5])",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[1,2,4,5]", results[0]);
}

test "jq:L816 true" {
    const results = try h.runFilter(
        "true",
        "[1]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L820 null,1,null" {
    const results = try h.runFilter(
        "null,1,null",
        "\"hello\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try h.expectJsonEqual("null", results[0]);
    try h.expectJsonEqual("1", results[1]);
    try h.expectJsonEqual("null", results[2]);
}

test "jq:L826 [1,2,3]" {
    const results = try h.runFilter(
        "[1,2,3]",
        "[5,6]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[1,2,3]", results[0]);
}

test "jq:L830 [.[]|floor]" {
    const results = try h.runFilter(
        "[.[]|floor]",
        "[-1.1,1.1,1.9]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[-2,1,1]", results[0]);
}

test "jq:L834 [.[]|sqrt]" {
    const results = try h.runFilter(
        "[.[]|sqrt]",
        "[4,9]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[2,3]", results[0]);
}

test "jq:L838 (add / length) as $m | map((. - $m) as $d | $d * $d) | ad..." {
    const results = try h.runFilter(
        "(add / length) as $m | map((. - $m) as $d | $d * $d) | add / length | sqrt",
        "[2,4,4,4,5,5,7,9]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("2", results[0]);
}

test "jq:L847 atan * 4 * 1000000|floor / 1000000" {
    const results = try h.runFilter(
        "atan * 4 * 1000000|floor / 1000000",
        "1",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("3.141592", results[0]);
}

test "jq:L851 [(3.141592 / 2) * (range(0;20) / 20)|cos * 1000000|floor ..." {
    const results = try h.runFilter(
        "[(3.141592 / 2) * (range(0;20) / 20)|cos * 1000000|floor / 1000000]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[1,0.996917,0.987688,0.972369,0.951056,0.923879,0.891006,0.85264,0.809017,0.760406,0.707106,0.649448,0.587785,0.522498,0.45399,0.382683,0.309017,0.233445,0.156434,0.078459]", results[0]);
}

test "jq:L855 [(3.141592 / 2) * (range(0;20) / 20)|sin * 1000000|floor ..." {
    const results = try h.runFilter(
        "[(3.141592 / 2) * (range(0;20) / 20)|sin * 1000000|floor / 1000000]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[0,0.078459,0.156434,0.233445,0.309016,0.382683,0.45399,0.522498,0.587785,0.649447,0.707106,0.760405,0.809016,0.85264,0.891006,0.923879,0.951056,0.972369,0.987688,0.996917]", results[0]);
}

test "jq:L860 def f(x): x | x; f([.], . + [42])" {
    const results = try h.runFilter(
        "def f(x): x | x; f([.], . + [42])",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("[[[1,2,3]]]", results[0]);
    try h.expectJsonEqual("[[1,2,3],42]", results[1]);
    try h.expectJsonEqual("[[1,2,3,42]]", results[2]);
    try h.expectJsonEqual("[1,2,3,42,42]", results[3]);
}

test "jq:L868 def f: .+1; def g: f; def f: .+100; def f(a):a+.+11; [(g|..." {
    const results = try h.runFilter(
        "def f: .+1; def g: f; def f: .+100; def f(a):a+.+11; [(g|f(20)), f]",
        "1",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[33,101]", results[0]);
}

test "jq:L873 def id(x):x; 2000 as $x | def f(x):1 as $x | id([$x, x, x..." {
    const results = try h.runFilter(
        "def id(x):x; 2000 as $x | def f(x):1 as $x | id([$x, x, x]); def g(x): 100 as $x | f($x,$x+x); g($x)",
        "\"more testing\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[1,100,2100.0,100,2100.0]", results[0]);
}

test "jq:L878 def x(a;b): a as $a | b as $b | $a + $b; def y($a;$b): $a..." {
    const results = try h.runFilter(
        "def x(a;b): a as $a | b as $b | $a + $b; def y($a;$b): $a + $b; def check(a;b): [x(a;b)] == [y(a;b)]; check(.[];.[]*2)",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L884 [[20,10][1,0] as $x | def f: (100,200) as $y | def g: [$x..." {
    const results = try h.runFilter(
        "[[20,10][1,0] as $x | def f: (100,200) as $y | def g: [$x + $y, .]; . + $x | g; f[0] | [f][0][1] | f]",
        "999999999",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[[110.0,130.0],[210.0,130.0],[110.0,230.0],[210.0,230.0],[120.0,160.0],[220.0,160.0],[120.0,260.0],[220.0,260.0]]", results[0]);
}

test "jq:L889 def fac: if . == 1 then 1 else . * (. - 1 | fac) end; [.[..." {
    const results = try h.runFilter(
        "def fac: if . == 1 then 1 else . * (. - 1 | fac) end; [.[] | fac]",
        "[1,2,3,4]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[1,2,6,24]", results[0]);
}

test "jq:L899 reduce .[] as $x (0; . + $x)" {
    const results = try h.runFilter(
        "reduce .[] as $x (0; . + $x)",
        "[1,2,4]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("7", results[0]);
}

test "jq:L903 reduce .[] as [$i, {j:$j}] (0; . + $i - $j)" {
    const results = try h.runFilter(
        "reduce .[] as [$i, {j:$j}] (0; . + $i - $j)",
        "[[2,{\"j\":1}], [5,{\"j\":3}], [6,{\"j\":4}]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("5", results[0]);
}

test "jq:L907 reduce [[1,2,10], [3,4,10]][] as [$i,$j] (0; . + $i * $j)" {
    const results = try h.runFilter(
        "reduce [[1,2,10], [3,4,10]][] as [$i,$j] (0; . + $i * $j)",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("14", results[0]);
}

test "jq:L911 [-reduce -.[] as $x (0; . + $x)]" {
    const results = try h.runFilter(
        "[-reduce -.[] as $x (0; . + $x)]",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[6]", results[0]);
}

test "jq:L915 [reduce .[] / .[] as $i (0; . + $i)]" {
    const results = try h.runFilter(
        "[reduce .[] / .[] as $i (0; . + $i)]",
        "[1,2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[4.5]", results[0]);
}

test "jq:L919 reduce .[] as $x (0; . + $x) as $x | $x" {
    const results = try h.runFilter(
        "reduce .[] as $x (0; . + $x) as $x | $x",
        "[1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("6", results[0]);
}

test "jq:L924 reduce . as $n (.; .)" {
    const results = try h.runFilter(
        "reduce . as $n (.; .)",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("null", results[0]);
}

test "jq:L929 . as {$a, b: [$c, {$d}]} | [$a, $c, $d]" {
    const results = try h.runFilter(
        ". as {$a, b: [$c, {$d}]} | [$a, $c, $d]",
        "{\"a\":1, \"b\":[2,{\"d\":3}]}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[1,2,3]", results[0]);
}

test "jq:L933 . as {$a, $b:[$c, $d]}| [$a, $b, $c, $d]" {
    const results = try h.runFilter(
        ". as {$a, $b:[$c, $d]}| [$a, $b, $c, $d]",
        "{\"a\":1, \"b\":[2,{\"d\":3}]}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[1,[2,{\"d\":3}],2,{\"d\":3}]", results[0]);
}

test "jq:L938 .[] | . as {$a, b: [$c, {$d}]} ?// [$a, {$b}, $e] ?// $f ..." {
    const results = try h.runFilter(
        ".[] | . as {$a, b: [$c, {$d}]} ?// [$a, {$b}, $e] ?// $f | [$a, $b, $c, $d, $e, $f]",
        "[{\"a\":1, \"b\":[2,{\"d\":3}]}, [4, {\"b\":5, \"c\":6}, 7, 8, 9], \"foo\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try h.expectJsonEqual("[1,null,2,3,null,null]", results[0]);
    try h.expectJsonEqual("[4,5,null,null,7,null]", results[1]);
    try h.expectJsonEqual("[null,null,null,null,null,\"foo\"]", results[2]);
}

test "jq:L945 .[] | . as {a:$a} ?// {a:$a} ?// {a:$a} | $a" {
    const results = try h.runFilter(
        ".[] | . as {a:$a} ?// {a:$a} ?// {a:$a} | $a",
        "[[3],[4],[5],6]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:L949 .[] as {a:$a} ?// {a:$a} ?// {a:$a} | $a" {
    const results = try h.runFilter(
        ".[] as {a:$a} ?// {a:$a} ?// {a:$a} | $a",
        "[[3],[4],[5],6]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:L953 [[3],[4],[5],6][] | . as {a:$a} ?// {a:$a} ?// {a:$a} | $a" {
    const results = try h.runFilter(
        "[[3],[4],[5],6][] | . as {a:$a} ?// {a:$a} ?// {a:$a} | $a",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:L957 [[3],[4],[5],6] | .[] as {a:$a} ?// {a:$a} ?// {a:$a} | $a" {
    const results = try h.runFilter(
        "[[3],[4],[5],6] | .[] as {a:$a} ?// {a:$a} ?// {a:$a} | $a",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:L961 .[] | . as {a:$a} ?// {a:$a} ?// $a | $a" {
    const results = try h.runFilter(
        ".[] | . as {a:$a} ?// {a:$a} ?// $a | $a",
        "[[3],[4],[5],6]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("[3]", results[0]);
    try h.expectJsonEqual("[4]", results[1]);
    try h.expectJsonEqual("[5]", results[2]);
    try h.expectJsonEqual("6", results[3]);
}

test "jq:L968 .[] as {a:$a} ?// {a:$a} ?// $a | $a" {
    const results = try h.runFilter(
        ".[] as {a:$a} ?// {a:$a} ?// $a | $a",
        "[[3],[4],[5],6]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("[3]", results[0]);
    try h.expectJsonEqual("[4]", results[1]);
    try h.expectJsonEqual("[5]", results[2]);
    try h.expectJsonEqual("6", results[3]);
}

test "jq:L975 [[3],[4],[5],6][] | . as {a:$a} ?// {a:$a} ?// $a | $a" {
    const results = try h.runFilter(
        "[[3],[4],[5],6][] | . as {a:$a} ?// {a:$a} ?// $a | $a",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("[3]", results[0]);
    try h.expectJsonEqual("[4]", results[1]);
    try h.expectJsonEqual("[5]", results[2]);
    try h.expectJsonEqual("6", results[3]);
}

test "jq:L982 [[3],[4],[5],6] | .[] as {a:$a} ?// {a:$a} ?// $a | $a" {
    const results = try h.runFilter(
        "[[3],[4],[5],6] | .[] as {a:$a} ?// {a:$a} ?// $a | $a",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("[3]", results[0]);
    try h.expectJsonEqual("[4]", results[1]);
    try h.expectJsonEqual("[5]", results[2]);
    try h.expectJsonEqual("6", results[3]);
}

test "jq:L989 .[] | . as {a:$a} ?// $a ?// {a:$a} | $a" {
    const results = try h.runFilter(
        ".[] | . as {a:$a} ?// $a ?// {a:$a} | $a",
        "[[3],[4],[5],6]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("[3]", results[0]);
    try h.expectJsonEqual("[4]", results[1]);
    try h.expectJsonEqual("[5]", results[2]);
    try h.expectJsonEqual("6", results[3]);
}

test "jq:L996 .[] as {a:$a} ?// $a ?// {a:$a} | $a" {
    const results = try h.runFilter(
        ".[] as {a:$a} ?// $a ?// {a:$a} | $a",
        "[[3],[4],[5],6]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("[3]", results[0]);
    try h.expectJsonEqual("[4]", results[1]);
    try h.expectJsonEqual("[5]", results[2]);
    try h.expectJsonEqual("6", results[3]);
}

test "jq:L1003 [[3],[4],[5],6][] | . as {a:$a} ?// $a ?// {a:$a} | $a" {
    const results = try h.runFilter(
        "[[3],[4],[5],6][] | . as {a:$a} ?// $a ?// {a:$a} | $a",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("[3]", results[0]);
    try h.expectJsonEqual("[4]", results[1]);
    try h.expectJsonEqual("[5]", results[2]);
    try h.expectJsonEqual("6", results[3]);
}

test "jq:L1010 [[3],[4],[5],6] | .[] as {a:$a} ?// $a ?// {a:$a} | $a" {
    const results = try h.runFilter(
        "[[3],[4],[5],6] | .[] as {a:$a} ?// $a ?// {a:$a} | $a",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("[3]", results[0]);
    try h.expectJsonEqual("[4]", results[1]);
    try h.expectJsonEqual("[5]", results[2]);
    try h.expectJsonEqual("6", results[3]);
}

test "jq:L1017 .[] | . as $a ?// {a:$a} ?// {a:$a} | $a" {
    const results = try h.runFilter(
        ".[] | . as $a ?// {a:$a} ?// {a:$a} | $a",
        "[[3],[4],[5],6]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("[3]", results[0]);
    try h.expectJsonEqual("[4]", results[1]);
    try h.expectJsonEqual("[5]", results[2]);
    try h.expectJsonEqual("6", results[3]);
}

test "jq:L1024 .[] as $a ?// {a:$a} ?// {a:$a} | $a" {
    const results = try h.runFilter(
        ".[] as $a ?// {a:$a} ?// {a:$a} | $a",
        "[[3],[4],[5],6]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("[3]", results[0]);
    try h.expectJsonEqual("[4]", results[1]);
    try h.expectJsonEqual("[5]", results[2]);
    try h.expectJsonEqual("6", results[3]);
}

test "jq:L1031 [[3],[4],[5],6][] | . as $a ?// {a:$a} ?// {a:$a} | $a" {
    const results = try h.runFilter(
        "[[3],[4],[5],6][] | . as $a ?// {a:$a} ?// {a:$a} | $a",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("[3]", results[0]);
    try h.expectJsonEqual("[4]", results[1]);
    try h.expectJsonEqual("[5]", results[2]);
    try h.expectJsonEqual("6", results[3]);
}

test "jq:L1038 [[3],[4],[5],6] | .[] as $a ?// {a:$a} ?// {a:$a} | $a" {
    const results = try h.runFilter(
        "[[3],[4],[5],6] | .[] as $a ?// {a:$a} ?// {a:$a} | $a",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("[3]", results[0]);
    try h.expectJsonEqual("[4]", results[1]);
    try h.expectJsonEqual("[5]", results[2]);
    try h.expectJsonEqual("6", results[3]);
}

test "jq:L1045 . as $dot|any($dot[];not)" {
    const results = try h.runFilter(
        ". as $dot|any($dot[];not)",
        "[1,2,3,4,true,false,1,2,3,4,5]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L1049 . as $dot|any($dot[];not)" {
    const results = try h.runFilter(
        ". as $dot|any($dot[];not)",
        "[1,2,3,4,true]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("false", results[0]);
}

test "jq:L1053 . as $dot|all($dot[];.)" {
    const results = try h.runFilter(
        ". as $dot|all($dot[];.)",
        "[1,2,3,4,true,false,1,2,3,4,5]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("false", results[0]);
}

test "jq:L1057 . as $dot|all($dot[];.)" {
    const results = try h.runFilter(
        ". as $dot|all($dot[];.)",
        "[1,2,3,4,true]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L1062 any(true, error; .)" {
    const results = try h.runFilter(
        "any(true, error; .)",
        "\"badness\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L1066 all(false, error; .)" {
    const results = try h.runFilter(
        "all(false, error; .)",
        "\"badness\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("false", results[0]);
}

test "jq:L1070 any(not)" {
    const results = try h.runFilter(
        "any(not)",
        "[]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("false", results[0]);
}

test "jq:L1074 all(not)" {
    const results = try h.runFilter(
        "all(not)",
        "[]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L1078 any(not)" {
    const results = try h.runFilter(
        "any(not)",
        "[false]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L1082 all(not)" {
    const results = try h.runFilter(
        "all(not)",
        "[false]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L1086 [any,all]" {
    const results = try h.runFilter(
        "[any,all]",
        "[]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[false,true]", results[0]);
}

test "jq:L1090 [any,all]" {
    const results = try h.runFilter(
        "[any,all]",
        "[true]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[true,true]", results[0]);
}

test "jq:L1094 [any,all]" {
    const results = try h.runFilter(
        "[any,all]",
        "[false]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[false,false]", results[0]);
}

test "jq:L1098 [any,all]" {
    const results = try h.runFilter(
        "[any,all]",
        "[true,false]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[true,false]", results[0]);
}

test "jq:L1102 [any,all]" {
    const results = try h.runFilter(
        "[any,all]",
        "[null,null,true]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[true,false]", results[0]);
}
