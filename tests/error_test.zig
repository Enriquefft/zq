const std = @import("std");
const err = @import("error");

// ── raise ─────────────────────────────────────────────────────────────────────

test "raise: assembles error without allocation" {
    const ctx = err.Context{ .line = 1, .col = 5, .snippet = "foo" };
    const e = err.raise(.unexpected_token, ctx);
    try std.testing.expectEqual(err.ErrorKind.unexpected_token, e.kind);
    try std.testing.expectEqual(@as(u64, 1), e.ctx.line);
    try std.testing.expectEqual(@as(u64, 5), e.ctx.col);
    try std.testing.expectEqualStrings("foo", e.ctx.snippet);
}

test "raise: all ErrorKind variants round-trip" {
    const kinds = [_]err.ErrorKind{
        .unexpected_token,
        .unexpected_eof,
        .invalid_utf8,
        .invalid_number,
        .unterminated_string,
        .depth_limit_exceeded,
    };
    const ctx = err.Context{ .line = 1, .col = 1, .snippet = "" };
    for (kinds) |k| {
        const e = err.raise(k, ctx);
        try std.testing.expectEqual(k, e.kind);
    }
}

// ── buildLineTable ────────────────────────────────────────────────────────────

test "buildLineTable: empty source produces no newlines" {
    const alloc = std.testing.allocator;
    const table = try err.buildLineTable("", alloc);
    defer err.deinit(table, alloc);
    try std.testing.expectEqual(@as(usize, 0), table.newlines.len);
}

test "buildLineTable: single line with no newline" {
    const alloc = std.testing.allocator;
    const table = try err.buildLineTable("hello world", alloc);
    defer err.deinit(table, alloc);
    try std.testing.expectEqual(@as(usize, 0), table.newlines.len);
}

test "buildLineTable: counts newlines correctly" {
    const alloc = std.testing.allocator;
    const table = try err.buildLineTable("abc\ndef\nghi", alloc);
    defer err.deinit(table, alloc);
    try std.testing.expectEqual(@as(usize, 2), table.newlines.len);
    try std.testing.expectEqual(@as(u64, 3), table.newlines[0]);
    try std.testing.expectEqual(@as(u64, 7), table.newlines[1]);
}

test "buildLineTable: leading newline" {
    const alloc = std.testing.allocator;
    const table = try err.buildLineTable("\nabc", alloc);
    defer err.deinit(table, alloc);
    try std.testing.expectEqual(@as(usize, 1), table.newlines.len);
    try std.testing.expectEqual(@as(u64, 0), table.newlines[0]);
}

test "buildLineTable: trailing newline" {
    const alloc = std.testing.allocator;
    const table = try err.buildLineTable("abc\n", alloc);
    defer err.deinit(table, alloc);
    try std.testing.expectEqual(@as(usize, 1), table.newlines.len);
    try std.testing.expectEqual(@as(u64, 3), table.newlines[0]);
}

test "buildLineTable: consecutive newlines" {
    const alloc = std.testing.allocator;
    const table = try err.buildLineTable("a\n\nb", alloc);
    defer err.deinit(table, alloc);
    try std.testing.expectEqual(@as(usize, 2), table.newlines.len);
    try std.testing.expectEqual(@as(u64, 1), table.newlines[0]);
    try std.testing.expectEqual(@as(u64, 2), table.newlines[1]);
}

// ── resolve ───────────────────────────────────────────────────────────────────

test "resolve: first byte of single-line source" {
    const alloc = std.testing.allocator;
    const table = try err.buildLineTable("hello", alloc);
    defer err.deinit(table, alloc);
    const pos = err.resolve(table, 0);
    try std.testing.expectEqual(@as(u64, 1), pos.line);
    try std.testing.expectEqual(@as(u64, 1), pos.col);
}

test "resolve: last byte of single-line source" {
    const alloc = std.testing.allocator;
    const table = try err.buildLineTable("hello", alloc);
    defer err.deinit(table, alloc);
    const pos = err.resolve(table, 4);
    try std.testing.expectEqual(@as(u64, 1), pos.line);
    try std.testing.expectEqual(@as(u64, 5), pos.col);
}

test "resolve: first byte of second line" {
    const alloc = std.testing.allocator;
    // "abc\ndef\nghi" — 'a'=0,'b'=1,'c'=2,'\n'=3,'d'=4,'e'=5,'f'=6,'\n'=7,'g'=8,'h'=9,'i'=10
    const table = try err.buildLineTable("abc\ndef\nghi", alloc);
    defer err.deinit(table, alloc);
    const pos = err.resolve(table, 4); // 'd'
    try std.testing.expectEqual(@as(u64, 2), pos.line);
    try std.testing.expectEqual(@as(u64, 1), pos.col);
}

test "resolve: mid-column on second line" {
    const alloc = std.testing.allocator;
    const table = try err.buildLineTable("abc\ndef\nghi", alloc);
    defer err.deinit(table, alloc);
    const pos = err.resolve(table, 5); // 'e'
    try std.testing.expectEqual(@as(u64, 2), pos.line);
    try std.testing.expectEqual(@as(u64, 2), pos.col);
}

test "resolve: first byte of third line" {
    const alloc = std.testing.allocator;
    const table = try err.buildLineTable("abc\ndef\nghi", alloc);
    defer err.deinit(table, alloc);
    const pos = err.resolve(table, 8); // 'g'
    try std.testing.expectEqual(@as(u64, 3), pos.line);
    try std.testing.expectEqual(@as(u64, 1), pos.col);
}

test "resolve: newline character is last col of its own line" {
    const alloc = std.testing.allocator;
    const table = try err.buildLineTable("abc\ndef", alloc);
    defer err.deinit(table, alloc);
    const pos = err.resolve(table, 3); // '\n'
    try std.testing.expectEqual(@as(u64, 1), pos.line);
    try std.testing.expectEqual(@as(u64, 4), pos.col);
}

test "resolve: consecutive newlines — empty middle line" {
    const alloc = std.testing.allocator;
    // "a\n\nb": offsets 0='a', 1='\n', 2='\n', 3='b'
    const table = try err.buildLineTable("a\n\nb", alloc);
    defer err.deinit(table, alloc);

    const p0 = err.resolve(table, 0); // 'a'
    try std.testing.expectEqual(@as(u64, 1), p0.line);
    try std.testing.expectEqual(@as(u64, 1), p0.col);

    const p2 = err.resolve(table, 2); // second '\n' — empty line 2
    try std.testing.expectEqual(@as(u64, 2), p2.line);
    try std.testing.expectEqual(@as(u64, 1), p2.col);

    const p3 = err.resolve(table, 3); // 'b'
    try std.testing.expectEqual(@as(u64, 3), p3.line);
    try std.testing.expectEqual(@as(u64, 1), p3.col);
}

test "resolve: offset 0 on source starting with newline" {
    const alloc = std.testing.allocator;
    const table = try err.buildLineTable("\nabc", alloc);
    defer err.deinit(table, alloc);
    const pos = err.resolve(table, 0); // '\n' itself
    try std.testing.expectEqual(@as(u64, 1), pos.line);
    try std.testing.expectEqual(@as(u64, 1), pos.col);
}
