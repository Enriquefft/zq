// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat â array_indices (5 tests)
// QuerySyntaxError â test FAILS  (filter not yet implemented â fix it)
// Any other error  â test FAILS  (real compatibility gap)

const std = @import("std");
const h = @import("helpers.zig");

test "jq:L213 try (.foo[-1] = 0) catch ." {
    const results = try h.runFilter(
        "try (.foo[-1] = 0) catch .",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Out of bounds negative array index\"", results[0]);
}

test "jq:L217 try (.foo[-2] = 0) catch ." {
    const results = try h.runFilter(
        "try (.foo[-2] = 0) catch .",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Out of bounds negative array index\"", results[0]);
}

test "jq:L221 .[-1] = 5" {
    const results = try h.runFilter(
        ".[-1] = 5",
        "[0,1,2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,1,5]", results[0]);
}

test "jq:L225 .[-2] = 5" {
    const results = try h.runFilter(
        ".[-2] = 5",
        "[0,1,2]",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[0,5,2]", results[0]);
}

test "jq:L229 try (.[999999999] = 0) catch ." {
    const results = try h.runFilter(
        "try (.[999999999] = 0) catch .",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("\"Array index too large\"", results[0]);
}

test "jq: .[-1] gets last element" {
    const results = try h.runFilter(".[-1]", "[10,20,30]");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("30", results[0]);
}

test "jq: .[-2] gets second-to-last" {
    const results = try h.runFilter(".[-2]", "[10,20,30]");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("20", results[0]);
}

test "jq: .[-4] out of bounds returns null" {
    const results = try h.runFilter(".[-4]", "[10,20,30]");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq: .[5] positive out of bounds returns null" {
    const results = try h.runFilter(".[5]", "[10,20,30]");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq: .[-1] on empty array returns null" {
    const results = try h.runFilter(".[-1]", "[]");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("null", results[0]);
}

test "jq: .[-2:] negative slice" {
    const results = try h.runFilter(".[-2:]", "[10,20,30]");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[20,30]", results[0]);
}
