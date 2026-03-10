// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â try_catch (69 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L1448 [.[]|try if . == 0 then error(_foo_) elif . == 1 then .a ..." {
    const results = try h.runFilter(
        "[.[]|try if . == 0 then error(\"foo\") elif . == 1 then .a elif . == 2 then empty else . end catch .]",
        "[0,1,2,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"foo\",\"Cannot index number with string (\\\"a\\\")\",3]", results[0]);
}

test "jq:L1452 [.[]|(.a, .a)?]" {
    const results = try h.runFilter(
        "[.[]|(.a, .a)?]",
        "[null,true,{\"a\":1}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,null,1,1]", results[0]);
}

test "jq:L1456 [[.[]|[.a,.a]]?]" {
    const results = try h.runFilter(
        "[[.[]|[.a,.a]]?]",
        "[null,true,{\"a\":1}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L1460 [if error then 1 else 2 end?]" {
    const results = try h.runFilter(
        "[if error then 1 else 2 end?]",
        "\"foo\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L1464 try error(0) // 1" {
    const results = try h.runFilter(
        "try error(0) // 1",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L1468 1, try error(2), 3" {
    const results = try h.runFilter(
        "1, try error(2), 3",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("3", results[1]);
}

test "jq:L1473 1 + try 2 catch 3 + 4" {
    const results = try h.runFilter(
        "1 + try 2 catch 3 + 4",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("7", results[0]);
}

test "jq:L1477 [-try .]" {
    const results = try h.runFilter(
        "[-try .]",
        "1",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[-1]", results[0]);
}

test "jq:L1481 try -.? catch ." {
    const results = try h.runFilter(
        "try -.? catch .",
        "\"foo\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"string (\\\"foo\\\") cannot be negated\"", results[0]);
}

test "jq:L1485 {x: try 1, y: try error catch 2, z: if true then 3 end}" {
    const results = try h.runFilter(
        "{x: try 1, y: try error catch 2, z: if true then 3 end}",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"x\":1,\"y\":2,\"z\":3}", results[0]);
}

test "jq:L1489 {x: 1 + 2, y: false or true, z: null // 3}" {
    const results = try h.runFilter(
        "{x: 1 + 2, y: false or true, z: null // 3}",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"x\":3,\"y\":true,\"z\":3}", results[0]);
}

test "jq:L1493 .[] | try error catch ." {
    const results = try h.runFilter(
        ".[] | try error catch .",
        "[1,null,2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("null", results[1]);
    try std.testing.expectEqualStrings("2", results[2]);
}

test "jq:L1499 try error(__($__loc__)_) catch ." {
    const results = try h.runFilter(
        "try error(\"\\($__loc__)\") catch .",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"{\\\"file\\\":\\\"<top-level>\\\",\\\"line\\\":1}\"", results[0]);
}

test "jq:L1504 [.[]|startswith(_foo_)]" {
    const results = try h.runFilter(
        "[.[]|startswith(\"foo\")]",
        "[\"fo\", \"foo\", \"barfoo\", \"foobar\", \"barfoob\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false, true, false, true, false]", results[0]);
}

test "jq:L1508 [.[]|endswith(_foo_)]" {
    const results = try h.runFilter(
        "[.[]|endswith(\"foo\")]",
        "[\"fo\", \"foo\", \"barfoo\", \"foobar\", \"barfoob\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false, true, true, false, false]", results[0]);
}

test "jq:L1512 [.[] | split(_, _)]" {
    const results = try h.runFilter(
        "[.[] | split(\", \")]",
        "[\"a,b, c, d, e,f\",\", a,b, c, d, e,f, \"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[\"a,b\",\"c\",\"d\",\"e,f\"],[\"\",\"a,b\",\"c\",\"d\",\"e,f\",\"\"]]", results[0]);
}

test "jq:L1516 split(__)" {
    const results = try h.runFilter(
        "split(\"\")",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\",\"b\",\"c\"]", results[0]);
}

test "jq:L1520 [.[]|ltrimstr(_foo_)]" {
    const results = try h.runFilter(
        "[.[]|ltrimstr(\"foo\")]",
        "[\"fo\", \"foo\", \"barfoo\", \"foobar\", \"afoo\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"fo\",\"\",\"barfoo\",\"bar\",\"afoo\"]", results[0]);
}

test "jq:L1524 [.[]|rtrimstr(_foo_)]" {
    const results = try h.runFilter(
        "[.[]|rtrimstr(\"foo\")]",
        "[\"fo\", \"foo\", \"barfoo\", \"foobar\", \"foob\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"fo\",\"\",\"bar\",\"foobar\",\"foob\"]", results[0]);
}

test "jq:L1528 [.[]|trimstr(_foo_)]" {
    const results = try h.runFilter(
        "[.[]|trimstr(\"foo\")]",
        "[\"fo\", \"foo\", \"barfoo\", \"foobarfoo\", \"foob\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"fo\",\"\",\"bar\",\"bar\",\"b\"]", results[0]);
}

test "jq:L1532 [.[]|ltrimstr(__)]" {
    const results = try h.runFilter(
        "[.[]|ltrimstr(\"\")]",
        "[\"a\", \"xx\", \"\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\", \"xx\", \"\"]", results[0]);
}

test "jq:L1536 [.[]|rtrimstr(__)]" {
    const results = try h.runFilter(
        "[.[]|rtrimstr(\"\")]",
        "[\"a\", \"xx\", \"\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\", \"xx\", \"\"]", results[0]);
}

test "jq:L1540 [.[]|trimstr(__)]" {
    const results = try h.runFilter(
        "[.[]|trimstr(\"\")]",
        "[\"a\", \"xx\", \"\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"a\", \"xx\", \"\"]", results[0]);
}

test "jq:L1544 [(index(_,_), rindex(_,_)), indices(_,_)]" {
    const results = try h.runFilter(
        "[(index(\",\"), rindex(\",\")), indices(\",\")]",
        "\"a,bc,def,ghij,klmno\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,13,[1,4,8,13]]", results[0]);
}

test "jq:L1548 [ index(_aba_), rindex(_aba_), indices(_aba_) ]" {
    const results = try h.runFilter(
        "[ index(\"aba\"), rindex(\"aba\"), indices(\"aba\") ]",
        "\"xababababax\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,7,[1,3,5,7]]", results[0]);
}

test "jq:L1554 map(trim), map(ltrim), map(rtrim)" {
    const results = try h.runFilter(
        "map(trim), map(ltrim), map(rtrim)",
        "[\" \\n\\t\\r\\f\\u000b\", \"\",\"  \", \"a\", \" a \", \"abc\", \"  abc  \", \"  abc\", \"abc  \"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("[\"\", \"\", \"\", \"a\", \"a\", \"abc\", \"abc\", \"abc\", \"abc\"]", results[0]);
    try std.testing.expectEqualStrings("[\"\", \"\", \"\", \"a\", \"a \", \"abc\", \"abc  \", \"abc\", \"abc  \"]", results[1]);
    try std.testing.expectEqualStrings("[\"\", \"\", \"\", \"a\", \" a\", \"abc\", \"  abc\", \"  abc\", \"abc\"]", results[2]);
}

test "jq:L1560 trim, ltrim, rtrim" {
    const results = try h.runFilter(
        "trim, ltrim, rtrim",
        "\"\\u0009\\u000A\\u000B\\u000C\\u000D\\u0020\\u0085\\u00A0\\u1680\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006\\u2007\\u2008\\u2009\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000abc\\u0009\\u000A\\u000B\\u000C\\u000D\\u0020\\u0085\\u00A0\\u1680\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006\\u2007\\u2008\\u2009\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("\"abc\"", results[0]);
    try std.testing.expectEqualStrings("\"abc\\u0009\\u000A\\u000B\\u000C\\u000D\\u0020\\u0085\\u00A0\\u1680\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006\\u2007\\u2008\\u2009\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\"", results[1]);
    try std.testing.expectEqualStrings("\"\\u0009\\u000A\\u000B\\u000C\\u000D\\u0020\\u0085\\u00A0\\u1680\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006\\u2007\\u2008\\u2009\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000abc\"", results[2]);
}

test "jq:L1566 try trim catch ., try ltrim catch ., try rtrim catch ." {
    const results = try h.runFilter(
        "try trim catch ., try ltrim catch ., try rtrim catch .",
        "123",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("\"trim input must be a string\"", results[0]);
    try std.testing.expectEqualStrings("\"trim input must be a string\"", results[1]);
    try std.testing.expectEqualStrings("\"trim input must be a string\"", results[2]);
}

test "jq:L1572 indices(1)" {
    const results = try h.runFilter(
        "indices(1)",
        "[0,1,1,2,3,4,1,5]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,6]", results[0]);
}

test "jq:L1576 indices([1,2])" {
    const results = try h.runFilter(
        "indices([1,2])",
        "[0,1,2,3,1,4,2,5,1,2,6,7]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,8]", results[0]);
}

test "jq:L1580 indices([1,2])" {
    const results = try h.runFilter(
        "indices([1,2])",
        "[1]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L1584 indices(_, _)" {
    const results = try h.runFilter(
        "indices(\", \")",
        "\"a,b, cd,e, fgh, ijkl\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[3,9,14]", results[0]);
}

test "jq:L1588 index(_!_)" {
    const results = try h.runFilter(
        "index(\"!\")",
        "\"здравствуй мир!\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("14", results[0]);
}

test "jq:L1592 .[:rindex(_x_)]" {
    const results = try h.runFilter(
        ".[:rindex(\"x\")]",
        "\"正xyz\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"正\"", results[0]);
}

test "jq:L1596 indices(_o_)" {
    const results = try h.runFilter(
        "indices(\"o\")",
        "\"🇬🇧oo\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[2,3]", results[0]);
}

test "jq:L1600 indices(_o_)" {
    const results = try h.runFilter(
        "indices(\"o\")",
        "\"ƒoo\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2]", results[0]);
}

test "jq:L1604 [.[]|split(_,_)]" {
    const results = try h.runFilter(
        "[.[]|split(\",\")]",
        "[\"a, bc, def, ghij, jklmn, a,b, c,d, e,f\", \"a,b,c,d, e,f,g,h\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[\"a\",\" bc\",\" def\",\" ghij\",\" jklmn\",\" a\",\"b\",\" c\",\"d\",\" e\",\"f\"],[\"a\",\"b\",\"c\",\"d\",\" e\",\"f\",\"g\",\"h\"]]", results[0]);
}

test "jq:L1608 [.[]|split(_, _)]" {
    const results = try h.runFilter(
        "[.[]|split(\", \")]",
        "[\"a, bc, def, ghij, jklmn, a,b, c,d, e,f\", \"a,b,c,d, e,f,g,h\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[\"a\",\"bc\",\"def\",\"ghij\",\"jklmn\",\"a,b\",\"c,d\",\"e,f\"],[\"a,b,c,d\",\"e,f,g,h\"]]", results[0]);
}

test "jq:L1612 [.[] * 3]" {
    const results = try h.runFilter(
        "[.[] * 3]",
        "[\"a\", \"ab\", \"abc\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"aaa\", \"ababab\", \"abcabcabc\"]", results[0]);
}

test "jq:L1616 [.[] * _abc_]" {
    const results = try h.runFilter(
        "[.[] * \"abc\"]",
        "[-1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 3.7, 10.0]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,null,\"\",\"\",\"abc\",\"abc\",\"abcabcabc\",\"abcabcabcabcabcabcabcabcabcabc\"]", results[0]);
}

test "jq:L1620 [. * (nan,-nan)]" {
    const results = try h.runFilter(
        "[. * (nan,-nan)]",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,null]", results[0]);
}

test "jq:L1624 . * 100000 | [.[:10],.[-10:]]" {
    const results = try h.runFilter(
        ". * 100000 | [.[:10],.[-10:]]",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"abcabcabca\",\"cabcabcabc\"]", results[0]);
}

test "jq:L1628 . * 1000000000" {
    const results = try h.runFilter(
        ". * 1000000000",
        "\"\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"\"", results[0]);
}

test "jq:L1632 try (. * 1000000000) catch ." {
    const results = try h.runFilter(
        "try (. * 1000000000) catch .",
        "\"abc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Repeat string result too long\"", results[0]);
}

test "jq:L1636 [.[] / _,_]" {
    const results = try h.runFilter(
        "[.[] / \",\"]",
        "[\"a, bc, def, ghij, jklmn, a,b, c,d, e,f\", \"a,b,c,d, e,f,g,h\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[\"a\",\" bc\",\" def\",\" ghij\",\" jklmn\",\" a\",\"b\",\" c\",\"d\",\" e\",\"f\"],[\"a\",\"b\",\"c\",\"d\",\" e\",\"f\",\"g\",\"h\"]]", results[0]);
}

test "jq:L1640 [.[] / _, _]" {
    const results = try h.runFilter(
        "[.[] / \", \"]",
        "[\"a, bc, def, ghij, jklmn, a,b, c,d, e,f\", \"a,b,c,d, e,f,g,h\"]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[\"a\",\"bc\",\"def\",\"ghij\",\"jklmn\",\"a,b\",\"c,d\",\"e,f\"],[\"a,b,c,d\",\"e,f,g,h\"]]", results[0]);
}

test "jq:L1644 map(.[1] as $needle | .[0] | contains($needle))" {
    const results = try h.runFilter(
        "map(.[1] as $needle | .[0] | contains($needle))",
        "[[[],[]], [[1,2,3], [1,2]], [[1,2,3], [3,1]], [[1,2,3], [4]], [[1,2,3], [1,4]]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true, true, true, false, false]", results[0]);
}

test "jq:L1648 map(.[1] as $needle | .[0] | contains($needle))" {
    const results = try h.runFilter(
        "map(.[1] as $needle | .[0] | contains($needle))",
        "[[[\"foobar\", \"foobaz\"], [\"baz\", \"bar\"]], [[\"foobar\", \"foobaz\"], [\"foo\"]], [[\"foobar\", \"foobaz\"], [\"blap\"]]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true, true, false]", results[0]);
}

test "jq:L1652 [({foo: 12, bar:13} | contains({foo: 12})), ({foo: 12} | ..." {
    const results = try h.runFilter(
        "[({foo: 12, bar:13} | contains({foo: 12})), ({foo: 12} | contains({})), ({foo: 12, bar:13} | contains({baz:14}))]",
        "{}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true, true, false]", results[0]);
}

test "jq:L1656 {foo: {baz: 12, blap: {bar: 13}}, bar: 14} | contains({ba..." {
    const results = try h.runFilter(
        "{foo: {baz: 12, blap: {bar: 13}}, bar: 14} | contains({bar: 14, foo: {blap: {}}})",
        "{}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L1660 {foo: {baz: 12, blap: {bar: 13}}, bar: 14} | contains({ba..." {
    const results = try h.runFilter(
        "{foo: {baz: 12, blap: {bar: 13}}, bar: 14} | contains({bar: 14, foo: {blap: {bar: 14}}})",
        "{}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L1664 sort" {
    const results = try h.runFilter(
        "sort",
        "[42,[2,5,3,11],10,{\"a\":42,\"b\":2},{\"a\":42},true,2,[2,6],\"hello\",null,[2,5,6],{\"a\":[],\"b\":1},\"abc\",\"ab\",[3,10],{},false,\"abcd\",null]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,null,false,true,2,10,42,\"ab\",\"abc\",\"abcd\",\"hello\",[2,5,3,11],[2,5,6],[2,6],[3,10],{},{\"a\":42},{\"a\":42,\"b\":2},{\"a\":[],\"b\":1}]", results[0]);
}

test "jq:L1668 (sort_by(.b) | sort_by(.a)), sort_by(.a, .b), sort_by(.b,..." {
    const results = try h.runFilter(
        "(sort_by(.b) | sort_by(.a)), sort_by(.a, .b), sort_by(.b, .c), group_by(.b), group_by(.a + .b - .c == 2)",
        "[{\"a\": 1, \"b\": 4, \"c\": 14}, {\"a\": 4, \"b\": 1, \"c\": 3}, {\"a\": 1, \"b\": 4, \"c\": 3}, {\"a\": 0, \"b\": 2, \"c\": 43}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 5), results.len);
    try std.testing.expectEqualStrings("[{\"a\": 0, \"b\": 2, \"c\": 43}, {\"a\": 1, \"b\": 4, \"c\": 14}, {\"a\": 1, \"b\": 4, \"c\": 3}, {\"a\": 4, \"b\": 1, \"c\": 3}]", results[0]);
    try std.testing.expectEqualStrings("[{\"a\": 0, \"b\": 2, \"c\": 43}, {\"a\": 1, \"b\": 4, \"c\": 14}, {\"a\": 1, \"b\": 4, \"c\": 3}, {\"a\": 4, \"b\": 1, \"c\": 3}]", results[1]);
    try std.testing.expectEqualStrings("[{\"a\": 4, \"b\": 1, \"c\": 3}, {\"a\": 0, \"b\": 2, \"c\": 43}, {\"a\": 1, \"b\": 4, \"c\": 3}, {\"a\": 1, \"b\": 4, \"c\": 14}]", results[2]);
    try std.testing.expectEqualStrings("[[{\"a\": 4, \"b\": 1, \"c\": 3}], [{\"a\": 0, \"b\": 2, \"c\": 43}], [{\"a\": 1, \"b\": 4, \"c\": 14}, {\"a\": 1, \"b\": 4, \"c\": 3}]]", results[3]);
    try std.testing.expectEqualStrings("[[{\"a\": 1, \"b\": 4, \"c\": 14}, {\"a\": 0, \"b\": 2, \"c\": 43}], [{\"a\": 4, \"b\": 1, \"c\": 3}, {\"a\": 1, \"b\": 4, \"c\": 3}]]", results[4]);
}

test "jq:L1676 unique" {
    const results = try h.runFilter(
        "unique",
        "[1,2,5,3,5,3,1,3]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,2,3,5]", results[0]);
}

test "jq:L1680 unique" {
    const results = try h.runFilter(
        "unique",
        "[]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L1684 [min, max, min_by(.[1]), max_by(.[1]), min_by(.[2]), max_..." {
    const results = try h.runFilter(
        "[min, max, min_by(.[1]), max_by(.[1]), min_by(.[2]), max_by(.[2])]",
        "[[4,2,\"a\"],[3,1,\"a\"],[2,4,\"a\"],[1,3,\"a\"]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[1,3,\"a\"],[4,2,\"a\"],[3,1,\"a\"],[2,4,\"a\"],[4,2,\"a\"],[1,3,\"a\"]]", results[0]);
}

test "jq:L1688 [min,max,min_by(.),max_by(.)]" {
    const results = try h.runFilter(
        "[min,max,min_by(.),max_by(.)]",
        "[]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[null,null,null,null]", results[0]);
}

test "jq:L1692 .foo[.baz]" {
    const results = try h.runFilter(
        ".foo[.baz]",
        "{\"foo\":{\"bar\":4},\"baz\":\"bar\"}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("4", results[0]);
}

test "jq:L1696 .[] | .error = _no, it's OK_" {
    const results = try h.runFilter(
        ".[] | .error = \"no, it's OK\"",
        "[{\"error\":true}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"error\": \"no, it's OK\"}", results[0]);
}

test "jq:L1700 [{a:1}] | .[] | .a=999" {
    const results = try h.runFilter(
        "[{a:1}] | .[] | .a=999",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\": 999}", results[0]);
}

test "jq:L1704 to_entries" {
    const results = try h.runFilter(
        "to_entries",
        "{\"a\": 1, \"b\": 2}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[{\"key\":\"a\", \"value\":1}, {\"key\":\"b\", \"value\":2}]", results[0]);
}

test "jq:L1708 from_entries" {
    const results = try h.runFilter(
        "from_entries",
        "[{\"key\":\"a\", \"value\":1}, {\"Key\":\"b\", \"Value\":2}, {\"name\":\"c\", \"value\":3}, {\"Name\":\"d\", \"Value\":4}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"a\": 1, \"b\": 2, \"c\": 3, \"d\": 4}", results[0]);
}

test "jq:L1712 with_entries(.key |= _KEY__ + .)" {
    const results = try h.runFilter(
        "with_entries(.key |= \"KEY_\" + .)",
        "{\"a\": 1, \"b\": 2}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{\"KEY_a\": 1, \"KEY_b\": 2}", results[0]);
}

test "jq:L1716 map(has(_foo_))" {
    const results = try h.runFilter(
        "map(has(\"foo\"))",
        "[{\"foo\": 42}, {}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[true, false]", results[0]);
}

test "jq:L1720 map(has(2))" {
    const results = try h.runFilter(
        "map(has(2))",
        "[[0,1], [\"a\",\"b\",\"c\"]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[false, true]", results[0]);
}

test "jq:L1724 has(nan)" {
    const results = try h.runFilter(
        "has(nan)",
        "[0,1,2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L1728 keys" {
    const results = try h.runFilter(
        "keys",
        "[42,3,35]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,2]", results[0]);
}

test "jq:L1732 [][.]" {
    const results = try h.runFilter(
        "[][.]",
        "1000000000000000000",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq:L1736 map([1,2][0:.])" {
    const results = try h.runFilter(
        "map([1,2][0:.])",
        "[-1, 1, 2, 3, 1000000000000000000]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[1], [1], [1,2], [1,2], [1,2]]", results[0]);
}
