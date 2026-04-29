// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â datetime (36 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L1886 last(range(365 * 67)|(_1970-03-01T01:02:03Z_|strptime(_%Y..." {
    const results = try h.runFilter(
        "last(range(365 * 67)|(\"1970-03-01T01:02:03Z\"|strptime(\"%Y-%m-%dT%H:%M:%SZ\")|mktime) + (86400 * .)|strftime(\"%Y-%m-%dT%H:%M:%SZ\")|strptime(\"%Y-%m-%dT%H:%M:%SZ\"))",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[2037,1,11,1,2,3,3,41]", results[0]);
}

test "jq:L1891 import _a_ as foo; import _b_ as bar; def fooa: foo::a; [..." {
    const results = try h.runFilter(
        "import \"a\" as foo; import \"b\" as bar; def fooa: foo::a; [fooa, bar::a, bar::b, foo::a]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[\"a\",\"b\",\"c\",\"a\"]", results[0]);
}

test "jq:L1895 import _c_ as foo; [foo::a, foo::c]" {
    const results = try h.runFilter(
        "import \"c\" as foo; [foo::a, foo::c]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[0,\"acmehbah\"]", results[0]);
}

test "jq:L1899 include _c_; [a, c]" {
    const results = try h.runFilter(
        "include \"c\"; [a, c]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[0,\"acmehbah\"]", results[0]);
}

test "jq:L1903 import _data_ as $e; import _data_ as $d; [$d[].this,$e[]..." {
    const results = try h.runFilter(
        "import \"data\" as $e; import \"data\" as $d; [$d[].this,$e[].that,$d::d[].this,$e::e[].that]|join(\";\")",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("\"is a test;is too;is a test;is too\"", results[0]);
}

test "jq:L1908 import _data_ as $a; import _data_ as $b; def f: {$a, $b}; f" {
    const results = try h.runFilter(
        "import \"data\" as $a; import \"data\" as $b; def f: {$a, $b}; f",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("{\"a\":[{\"this\":\"is a test\",\"that\":\"is too\"}],\"b\":[{\"this\":\"is a test\",\"that\":\"is too\"}]}", results[0]);
}

test "jq:L1912 include _shadow1_; e" {
    const results = try h.runFilter(
        "include \"shadow1\"; e",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("2", results[0]);
}

test "jq:L1916 include _shadow1_; include _shadow2_; e" {
    const results = try h.runFilter(
        "include \"shadow1\"; include \"shadow2\"; e",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("3", results[0]);
}

test "jq:L1920 import _shadow1_ as f; import _shadow2_ as f; import _sha..." {
    const results = try h.runFilter(
        "import \"shadow1\" as f; import \"shadow2\" as f; import \"shadow1\" as e; [e::e, f::e]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("[2,3]", results[0]);
}

test "jq:L1924 module (.+1); 0" {
    // %%FAIL: filter should not compile
    try h.expectCompileError("module (.+1); 0");
}

test "jq:L1930 module []; 0" {
    // %%FAIL: filter should not compile
    try h.expectCompileError("module []; 0");
}

test "jq:L1936 include _a_ (.+1); 0" {
    // %%FAIL: filter should not compile
    try h.expectCompileError("include \"a\" (.+1); 0");
}

test "jq:L1942 include _a_ []; 0" {
    // %%FAIL: filter should not compile
    try h.expectCompileError("include \"a\" []; 0");
}

test "jq:L1948 include __ _; 0" {
    // %%FAIL: filter should not compile
    try h.expectCompileError("include \"\\ \"; 0");
}

test "jq:L1954 include __(a)_; 0" {
    // %%FAIL: filter should not compile
    try h.expectCompileError("include \"\\(a)\"; 0");
}

test "jq:L1960 modulemeta" {
    const results = try h.runFilter(
        "modulemeta",
        "\"c\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("{\"whatever\":null,\"deps\":[{\"as\":\"foo\",\"is_data\":false,\"relpath\":\"a\"},{\"search\":\"./\",\"as\":\"d\",\"is_data\":false,\"relpath\":\"d\"},{\"search\":\"./\",\"as\":\"d2\",\"is_data\":false,\"relpath\":\"d\"},{\"search\":\"./../lib/jq\",\"as\":\"e\",\"is_data\":false,\"relpath\":\"e\"},{\"search\":\"./../lib/jq\",\"as\":\"f\",\"is_data\":false,\"relpath\":\"f\"},{\"as\":\"d\",\"is_data\":true,\"relpath\":\"data\"}],\"defs\":[\"a/0\",\"c/0\"]}", results[0]);
}

test "jq:L1964 modulemeta | .deps | length" {
    const results = try h.runFilter(
        "modulemeta | .deps | length",
        "\"c\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("6", results[0]);
}

test "jq:L1968 modulemeta | .defs | length" {
    const results = try h.runFilter(
        "modulemeta | .defs | length",
        "\"c\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("2", results[0]);
}

test "jq:L1972 import _syntaxerror_ as e; ." {
    // %%FAIL: filter should not compile
    try h.expectCompileError("import \"syntaxerror\" as e; .");
}

test "jq:L1978 %::wat" {
    // %%FAIL: filter should not compile
    try h.expectCompileError("%::wat");
}

test "jq:L1984 import _test_bind_order_ as check; check::check" {
    const results = try h.runFilter(
        "import \"test_bind_order\" as check; check::check",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L1988 try -. catch ." {
    const results = try h.runFilter(
        "try -. catch .",
        "\"very-long-long-long-long-string\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("\"string (\\\"very-long-long-long-long...\\\") cannot be negated\"", results[0]);
}

test "jq:L1992 try (.-.) catch ." {
    const results = try h.runFilter(
        "try (.-.) catch .",
        "\"very-long-long-long-long-string\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("\"string (\\\"very-long-long-long-long...\\\") and string (\\\"very-long-long-long-long...\\\") cannot be subtracted\"", results[0]);
}

test "jq:L1996 _x_ * range(0; 12; 2) + ___ * 8 | try -. catch ." {
    const results = try h.runFilter(
        "\"x\" * range(0; 12; 2) + \"☆\" * 8 | try -. catch .",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 6), results.len);
    try h.expectJsonEqual("\"string (\\\"☆☆☆☆☆☆☆☆\\\") cannot be negated\"", results[0]);
    try h.expectJsonEqual("\"string (\\\"xx☆☆☆☆☆☆☆☆\\\") cannot be negated\"", results[1]);
    try h.expectJsonEqual("\"string (\\\"xxxx☆☆☆☆☆☆...\\\") cannot be negated\"", results[2]);
    try h.expectJsonEqual("\"string (\\\"xxxxxx☆☆☆☆☆☆...\\\") cannot be negated\"", results[3]);
    try h.expectJsonEqual("\"string (\\\"xxxxxxxx☆☆☆☆☆...\\\") cannot be negated\"", results[4]);
    try h.expectJsonEqual("\"string (\\\"xxxxxxxxxx☆☆☆☆...\\\") cannot be negated\"", results[5]);
}

test "jq:L2005 try (. + _x_) catch . == if have_decnum then _number (123..." {
    const results = try h.runFilter(
        "try (. + \"x\") catch . == if have_decnum then \"number (12345678901234567890123456...) and string (\\\"x\\\") cannot be added\" else \"number (12345678901234568000000000...) and string (\\\"x\\\") cannot be added\" end",
        "123456789012345678901234567890",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("true", results[0]);
}

test "jq:L2009 join(_,_)" {
    const results = try h.runFilter(
        "join(\",\")",
        "[\"1\",2,true,false,3.4]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("\"1,2,true,false,3.4\"", results[0]);
}

test "jq:L2013 .[] | join(_,_)" {
    const results = try h.runFilter(
        ".[] | join(\",\")",
        "[[], [null], [null,null], [null,null,null]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try h.expectJsonEqual("\"\"", results[0]);
    try h.expectJsonEqual("\"\"", results[1]);
    try h.expectJsonEqual("\",\"", results[2]);
    try h.expectJsonEqual("\",,\"", results[3]);
}

test "jq:L2020 .[] | join(_,_)" {
    const results = try h.runFilter(
        ".[] | join(\",\")",
        "[[\"a\",null], [null,\"a\"]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try h.expectJsonEqual("\"a,\"", results[0]);
    try h.expectJsonEqual("\",a\"", results[1]);
}

test "jq:L2025 try join(_,_) catch ." {
    const results = try h.runFilter(
        "try join(\",\") catch .",
        "[\"1\",\"2\",{\"a\":{\"b\":{\"c\":33}}}]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("\"string (\\\"1,2,\\\") and object ({\\\"a\\\":{\\\"b\\\":{\\\"c\\\":33}}}) cannot be added\"", results[0]);
}

test "jq:L2029 try join(_,_) catch ." {
    const results = try h.runFilter(
        "try join(\",\") catch .",
        "[\"1\",\"2\",[3,4,5]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("\"string (\\\"1,2,\\\") and array ([3,4,5]) cannot be added\"", results[0]);
}

test "jq:L2033 {if:0,and:1,or:2,then:3,else:4,elif:5,end:6,as:7,def:8,re..." {
    const results = try h.runFilter(
        "{if:0,and:1,or:2,then:3,else:4,elif:5,end:6,as:7,def:8,reduce:9,foreach:10,try:11,catch:12,label:13,import:14,include:15,module:16}",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("{\"if\":0,\"and\":1,\"or\":2,\"then\":3,\"else\":4,\"elif\":5,\"end\":6,\"as\":7,\"def\":8,\"reduce\":9,\"foreach\":10,\"try\":11,\"catch\":12,\"label\":13,\"import\":14,\"include\":15,\"module\":16}", results[0]);
}

test "jq:L2037 try (1/.) catch ." {
    const results = try h.runFilter(
        "try (1/.) catch .",
        "0",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("\"number (1) and number (0) cannot be divided because the divisor is zero\"", results[0]);
}

test "jq:L2041 try (1/0) catch ." {
    const results = try h.runFilter(
        "try (1/0) catch .",
        "0",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("\"number (1) and number (0) cannot be divided because the divisor is zero\"", results[0]);
}

test "jq:L2045 try (0/0) catch ." {
    const results = try h.runFilter(
        "try (0/0) catch .",
        "0",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("\"number (0) and number (0) cannot be divided because the divisor is zero\"", results[0]);
}

test "jq:L2049 try (1%.) catch ." {
    const results = try h.runFilter(
        "try (1%.) catch .",
        "0",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("\"number (1) and number (0) cannot be divided (remainder) because the divisor is zero\"", results[0]);
}

test "jq:L2053 try (1%0) catch ." {
    const results = try h.runFilter(
        "try (1%0) catch .",
        "0",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try h.expectJsonEqual("\"number (1) and number (0) cannot be divided (remainder) because the divisor is zero\"", results[0]);
}
