// Hand-written compat tests for `repeat(f)`. Mirrors jq's
// `def repeat(exp): def _r: exp, _r; _r;` semantics: each iteration
// re-evaluates `exp` against the original input — no accumulation
// across iterations. Termination is delegated to an enclosing
// `limit/2`; without one the loop runs forever (so every test below
// wraps `repeat` in `limit`).
//
// Reference outputs verified against jq 1.8.1.

const std = @import("std");
const h = @import("helpers.zig");

test "repeat: limit(3; repeat(.+1)) on 0 → 1,1,1" {
    const results = try h.runFilter("limit(3; repeat(.+1))", "0");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("1", results[1]);
    try std.testing.expectEqualStrings("1", results[2]);
}

test "repeat: limit(0; repeat(.)) yields nothing" {
    const results = try h.runFilter("limit(0; repeat(.))", "0");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "repeat: [limit(5; repeat(.*2))] on 1 → [2,2,2,2,2]" {
    const results = try h.runFilter("[limit(5; repeat(.*2))]", "1");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[2,2,2,2,2]", results[0]);
}

test "repeat: closure capture with $base" {
    const results = try h.runFilter(
        "1 as $base | [limit(3; repeat($base))]",
        "null",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,1,1]", results[0]);
}

test "repeat: pipe inside repeat body" {
    // `. | . + 1` is just `.+1` — each iter restores `.` to the input.
    const results = try h.runFilter("[limit(4; repeat(. | . + 1))]", "0");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[1,1,1,1]", results[0]);
}

test "repeat: identity body yields the input forever" {
    const results = try h.runFilter("[limit(4; repeat(.))]", "42");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[42,42,42,42]", results[0]);
}

test "repeat: multi-yield body — comma yields both per iteration" {
    // `(., .+1)` yields two values per iteration; limit counts each one.
    // Iter 1 (input 5): yields 5, 6. Iter 2 (input 5): yields 5, 6 again.
    // Iter 3: yields 5 only (limit truncates after 5 outputs).
    const results = try h.runFilter("[limit(5; repeat(., .+1))]", "5");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[5,6,5,6,5]", results[0]);
}

test "repeat: nested limits — outer truncates first" {
    // Inner `limit(10; ...)` would allow 10, but the outer `limit(2; ...)`
    // wraps it with a count of 2. Result: 2 outputs of value 7.
    const results = try h.runFilter("[limit(2; limit(10; repeat(.+7)))]", "0");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[7,7]", results[0]);
}

test "repeat: input is a non-trivial value (object access)" {
    // The body re-reads `.x` against the captured input each iter.
    const results = try h.runFilter(
        "[limit(3; repeat(.x))]",
        "{\"x\":\"hello\"}",
    );
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[\"hello\",\"hello\",\"hello\"]", results[0]);
}

test "repeat: body inside an array constructor — saved_collect_len cleanup" {
    // The body itself contains an inner `[...]`. Each iteration must start
    // with a clean collect-stack depth — otherwise the inner array would
    // accumulate across iterations and corrupt subsequent yields.
    const results = try h.runFilter("[limit(3; repeat([.,.]))]", "9");
    defer {
        for (results) |s| h.alloc.free(s);
        h.alloc.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("[[9,9],[9,9],[9,9]]", results[0]);
}
