// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â literals (20 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L8 true" {
    const results = try h.runFilter(
        "true",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("true", results[0]);
}

test "jq:L12 false" {
    const results = try h.runFilter(
        "false",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("false", results[0]);
}

test "jq:L16 null" {
    const results = try h.runFilter(
        "null",
        "42",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq:L20 1" {
    const results = try h.runFilter(
        "1",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
}

test "jq:L25 -1" {
    const results = try h.runFilter(
        "-1",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("-1", results[0]);
}

test "jq:L31 {}" {
    const results = try h.runFilter(
        "{}",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("{}", results[0]);
}

test "jq:L35 []" {
    const results = try h.runFilter(
        "[]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[]", results[0]);
}

test "jq:L39 {x:-1},{x:-.},{x:-.|abs}" {
    const results = try h.runFilter(
        "{x:-1},{x:-.},{x:-.|abs}",
        "1",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("{\"x\":-1}", results[0]);
    try std.testing.expectEqualStrings("{\"x\":-1}", results[1]);
    try std.testing.expectEqualStrings("{\"x\":1}", results[2]);
}

test "jq:L48 ." {
    const results = try h.runFilter(
        ".",
        "﻿\"byte order mark\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"byte order mark\"", results[0]);
}

test "jq:L54 _Aa_r_n_t_b_f_u03bc_" {
    const results = try h.runFilter(
        "\"Aa\\r\\n\\t\\b\\f\\u03bc\"",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Aa\\u000d\\u000a\\u0009\\u0008\\u000c\\u03bc\"", results[0]);
}

test "jq:L58 ." {
    const results = try h.runFilter(
        ".",
        "\"Aa\\r\\n\\t\\b\\f\\u03bc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Aa\\u000d\\u000a\\u0009\\u0008\\u000c\\u03bc\"", results[0]);
}

test "jq:L62 _u_vw_" {
    // %%FAIL: filter should not compile
    try h.expectCompileError("\"u\\vw\"");
}

test "jq:L68 _inter_(_pol_ + _ation_)_" {
    const results = try h.runFilter(
        "\"inter\\(\"pol\" + \"ation\")\"",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"interpolation\"", results[0]);
}

test "jq:L72 @text,@json,([1,.]|@csv,@tsv),@html,(@uri|.,@urid),@sh,(@..." {
    const results = try h.runFilter(
        "@text,@json,([1,.]|@csv,@tsv),@html,(@uri|.,@urid),@sh,(@base64|.,@base64d)",
        "\"!()<>&'\\\"\\t\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 10), results.len);
    try std.testing.expectEqualStrings("\"!()<>&'\\\"\\t\"", results[0]);
    try std.testing.expectEqualStrings("\"\\\"!()<>&'\\\\\\\"\\\\t\\\"\"", results[1]);
    try std.testing.expectEqualStrings("\"1,\\\"!()<>&'\\\"\\\"\\t\\\"\"", results[2]);
    try std.testing.expectEqualStrings("\"1\\t!()<>&'\\\"\\\\t\"", results[3]);
    try std.testing.expectEqualStrings("\"!()&lt;&gt;&amp;&apos;&quot;\\t\"", results[4]);
    try std.testing.expectEqualStrings("\"%21%28%29%3C%3E%26%27%22%09\"", results[5]);
    try std.testing.expectEqualStrings("\"!()<>&'\\\"\\t\"", results[6]);
    try std.testing.expectEqualStrings("\"'!()<>&'\\\\''\\\"\\t'\"", results[7]);
    try std.testing.expectEqualStrings("\"ISgpPD4mJyIJ\"", results[8]);
    try std.testing.expectEqualStrings("\"!()<>&'\\\"\\t\"", results[9]);
}

test "jq:L86 @base64" {
    const results = try h.runFilter(
        "@base64",
        "\"foóbar\\n\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Zm/Ds2Jhcgo=\"", results[0]);
}

test "jq:L90 @base64d" {
    const results = try h.runFilter(
        "@base64d",
        "\"Zm/Ds2Jhcgo=\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"foóbar\\n\"", results[0]);
}

test "jq:L94 @uri" {
    const results = try h.runFilter(
        "@uri",
        "\"\\u03bc\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"%CE%BC\"", results[0]);
}

test "jq:L98 @urid" {
    const results = try h.runFilter(
        "@urid",
        "\"%CE%BC\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"\\u03bc\"", results[0]);
}

test "jq:L102 @html _<b>_(.)</b>_" {
    const results = try h.runFilter(
        "@html \"<b>\\(.)</b>\"",
        "\"<script>hax</script>\"",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"<b>&lt;script&gt;hax&lt;/script&gt;</b>\"", results[0]);
}

test "jq:L106 [.[]|tojson|fromjson]" {
    const results = try h.runFilter(
        "[.[]|tojson|fromjson]",
        "[\"foo\", 1, [\"a\", 1, \"b\", 2, {\"foo\":\"bar\"}]]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"foo\",1,[\"a\",1,\"b\",2,{\"foo\":\"bar\"}]]", results[0]);
}
