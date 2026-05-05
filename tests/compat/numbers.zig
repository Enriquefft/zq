// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â numbers (29 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L2058 [range(-52;52;1)] as $powers | [$powers[]|pow(2;.)|log2|r..." {
    const results = try h.runFilter(
        "[range(-52;52;1)] as $powers | [$powers[]|pow(2;.)|log2|round] == $powers",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L2062 [range(-99/2;99/2;1)] as $orig | [$orig[]|pow(2;.)|log2] ..." {
    const results = try h.runFilter(
        "[range(-99/2;99/2;1)] as $orig | [$orig[]|pow(2;.)|log2] as $back | ($orig|keys)[]|. as $k | (($orig|.[$k])-($back|.[$k]))|if . < 0 then . * -1 else . end|select(.>.00005)",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:L2065 {" {
    // %%FAIL: filter should not compile
    try h.expectCompileError("{");
}

test "jq:L2071 }" {
    // %%FAIL: filter should not compile
    try h.expectCompileError("}");
}

test "jq:L2077 (.[{}] = 0)?" {
    const results = try h.runFilter(
        "(.[{}] = 0)?",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "jq:L2080 INDEX(range(5)|[., _foo_(.)_]; .[0])" {
    const results = try h.runFilter(
        "INDEX(range(5)|[., \"foo\\(.)\"]; .[0])",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("{\"0\":[0,\"foo0\"],\"1\":[1,\"foo1\"],\"2\":[2,\"foo2\"],\"3\":[3,\"foo3\"],\"4\":[4,\"foo4\"]}", results[0]);
}

test "jq:L2084 JOIN({_0_:[0,_abc_],_1_:[1,_bcd_],_2_:[2,_def_],_3_:[3,_e..." {
    const results = try h.runFilter(
        "JOIN({\"0\":[0,\"abc\"],\"1\":[1,\"bcd\"],\"2\":[2,\"def\"],\"3\":[3,\"efg\"],\"4\":[4,\"fgh\"]}; .[0]|tostring)",
        "[[5,\"foo\"],[3,\"bar\"],[1,\"foobar\"]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[[[5,\"foo\"],null],[[3,\"bar\"],[3,\"efg\"]],[[1,\"foobar\"],[1,\"bcd\"]]]", results[0]);
}

test "jq:L2088 range(5;10)|IN(range(10))" {
    const results = try h.runFilter(
        "range(5;10)|IN(range(10))",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 5), results.len);
    try h.expectJsonEqual("true", results[0]);
    try h.expectJsonEqual("true", results[1]);
    try h.expectJsonEqual("true", results[2]);
    try h.expectJsonEqual("true", results[3]);
    try h.expectJsonEqual("true", results[4]);
}

test "jq:L2096 range(5;13)|IN(range(0;10;3))" {
    const results = try h.runFilter(
        "range(5;13)|IN(range(0;10;3))",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 8), results.len);
    try h.expectJsonEqual("false", results[0]);
    try h.expectJsonEqual("true", results[1]);
    try h.expectJsonEqual("false", results[2]);
    try h.expectJsonEqual("false", results[3]);
    try h.expectJsonEqual("true", results[4]);
    try h.expectJsonEqual("false", results[5]);
    try h.expectJsonEqual("false", results[6]);
    try h.expectJsonEqual("false", results[7]);
}

test "jq:L2107 range(10;12)|IN(range(10))" {
    const results = try h.runFilter(
        "range(10;12)|IN(range(10))",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try h.expectJsonEqual("false", results[0]);
    try h.expectJsonEqual("false", results[1]);
}

test "jq:L2112 IN(range(10;20); range(10))" {
    const results = try h.runFilter(
        "IN(range(10;20); range(10))",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("false", results[0]);
}

test "jq:L2116 IN(range(5;20); range(10))" {
    const results = try h.runFilter(
        "IN(range(5;20); range(10))",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L2121 (.a as $x | .b) = _b_" {
    const results = try h.runFilter(
        "(.a as $x | .b) = \"b\"",
        "{\"a\":null,\"b\":null}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("{\"a\":null,\"b\":\"b\"}", results[0]);
}

test "jq:L2126 (.. | select(type == _object_ and has(_b_) and (.b | type..." {
    const results = try h.runFilter(
        "(.. | select(type == \"object\" and has(\"b\") and (.b | type) == \"array\")|.b) |= .[0]",
        "{\"a\": {\"b\": [1, {\"b\": 3}]}}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("{\"a\":{\"b\":1}}", results[0]);
}

test "jq:L2130 isempty(empty)" {
    const results = try h.runFilter(
        "isempty(empty)",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L2134 isempty(range(3))" {
    const results = try h.runFilter(
        "isempty(range(3))",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("false", results[0]);
}

test "jq:L2138 isempty(1,error(_foo_))" {
    const results = try h.runFilter(
        "isempty(1,error(\"foo\"))",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("false", results[0]);
}

test "jq:L2143 index(__)" {
    const results = try h.runFilter(
        "index(\"\")",
        "\"\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("null", results[0]);
}

test "jq:L2148 builtins|length > 10" {
    const results = try h.runFilter(
        "builtins|length > 10",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L2152 _-1_|IN(builtins[] / _/_|.[1])" {
    const results = try h.runFilter(
        "\"-1\"|IN(builtins[] / \"/\"|.[1])",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("false", results[0]);
}

test "jq:L2156 all(builtins[] / _/_; .[1]|tonumber >= 0)" {
    const results = try h.runFilter(
        "all(builtins[] / \"/\"; .[1]|tonumber >= 0)",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L2160 builtins|any(.[:1] == ___)" {
    const results = try h.runFilter(
        "builtins|any(.[:1] == \"_\")",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("false", results[0]);
}

test "jq:L2181 map(. == 1)" {
    const results = try h.runFilter(
        "map(. == 1)",
        "[1, 1.0, 1.000, 100e-2, 1e+0, 0.0001e4]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[true,true,true,true,true,true]", results[0]);
}

test "jq:L2187 .[0] | tostring | . == if have_decnum then _1391186036643..." {
    const results = try h.runFilter(
        ".[0] | tostring | . == if have_decnum then \"13911860366432393\" else \"13911860366432392\" end",
        "[13911860366432393]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L2191 .x | tojson | . == if have_decnum then _13911860366432393..." {
    const results = try h.runFilter(
        ".x | tojson | . == if have_decnum then \"13911860366432393\" else \"13911860366432392\" end",
        "{\"x\":13911860366432393}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L2195 (13911860366432393 == 13911860366432392) | . == if have_d..." {
    if (!@import("zq_features.zig").have_decnum) return error.SkipZigTest;
    const results = try h.runFilter(
        "(13911860366432393 == 13911860366432392) | . == if have_decnum then false else true end",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L2202 . - 10" {
    const results = try h.runFilter(
        ". - 10",
        "13911860366432393",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("13911860366432382", results[0]);
}

test "jq:L2206 .[0] - 10" {
    const results = try h.runFilter(
        ".[0] - 10",
        "[13911860366432393]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("13911860366432382", results[0]);
}

test "jq:L2210 .x - 10" {
    const results = try h.runFilter(
        ".x - 10",
        "{\"x\":13911860366432393}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("13911860366432382", results[0]);
}
