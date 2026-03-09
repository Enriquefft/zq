const std = @import("std");
const io = @import("io");

const Source = io.Source;
const SliceView = io.SliceView;

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Write `content` to a new temp file, return an open read-only fd.
/// Caller owns the fd and must close it.
fn tmpFileWithContent(dir: std.fs.Dir, name: []const u8, content: []const u8) !std.posix.fd_t {
    const f = try dir.createFile(name, .{ .read = true });
    try f.writeAll(content);
    try f.seekTo(0);
    return f.handle;
}

// ─── mmap backend ─────────────────────────────────────────────────────────────

test "mmap: peek returns full content as single view" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "hello, world";
    const fd = try tmpFileWithContent(tmp.dir, "peek.json", content);
    defer std.posix.close(fd);

    var src = try Source.init(fd, alloc);
    defer src.deinit();

    const view = try src.peek();
    try std.testing.expectEqualSlices(u8, content, view.bytes);
    try std.testing.expect(!view.is_eof); // cursor at 0, not yet consumed
}

test "mmap: consume advances cursor; is_eof set when all bytes consumed" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "abcde";
    const fd = try tmpFileWithContent(tmp.dir, "consume.json", content);
    defer std.posix.close(fd);

    var src = try Source.init(fd, alloc);
    defer src.deinit();

    src.consume(3);
    const view = try src.peek();
    try std.testing.expectEqualSlices(u8, "de", view.bytes);
    try std.testing.expect(!view.is_eof);

    src.consume(2);
    const done = try src.peek();
    try std.testing.expectEqual(@as(usize, 0), done.bytes.len);
    try std.testing.expect(done.is_eof);
}

test "mmap: refill always returns false" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fd = try tmpFileWithContent(tmp.dir, "refill.json", "data");
    defer std.posix.close(fd);

    var src = try Source.init(fd, alloc);
    defer src.deinit();

    try std.testing.expect(!try src.refill());
}

// ─── ring buffer backend ──────────────────────────────────────────────────────

test "ring: peek returns data written to pipe" {
    const alloc = std.testing.allocator;
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[1]);

    const written = try std.posix.write(fds[1], "hello");
    _ = written;

    var src = try Source.init(fds[0], alloc);
    defer src.deinit();

    _ = try src.refill();
    const view = try src.peek();
    try std.testing.expectEqualSlices(u8, "hello", view.bytes);
    try std.testing.expect(!view.is_eof);
}

test "ring: consume + refill cycle drains pipe" {
    const alloc = std.testing.allocator;
    const fds = try std.posix.pipe();

    _ = try std.posix.write(fds[1], "abc");
    std.posix.close(fds[1]); // signal EOF

    var src = try Source.init(fds[0], alloc);
    defer src.deinit();

    _ = try src.refill();

    var view = try src.peek();
    try std.testing.expectEqualSlices(u8, "abc", view.bytes);

    src.consume(2);
    view = try src.peek();
    try std.testing.expectEqualSlices(u8, "c", view.bytes);

    src.consume(1);

    // refill hits EOF
    _ = try src.refill();
    const done = try src.peek();
    try std.testing.expect(done.is_eof);
}

test "ring: is_eof only true when buffer drained and pipe closed" {
    const alloc = std.testing.allocator;
    const fds = try std.posix.pipe();

    _ = try std.posix.write(fds[1], "xy");
    std.posix.close(fds[1]);

    var src = try Source.init(fds[0], alloc);
    defer src.deinit();

    _ = try src.refill();
    var view = try src.peek();
    try std.testing.expect(!view.is_eof); // still has bytes

    src.consume(view.bytes.len);
    _ = try src.refill(); // hits EOF
    view = try src.peek();
    try std.testing.expect(view.is_eof);
}

test "ring: buffer compacts on refill when start > 0" {
    const alloc = std.testing.allocator;
    const fds = try std.posix.pipe();

    _ = try std.posix.write(fds[1], "firstsecond");

    var src = try Source.init(fds[0], alloc);
    defer src.deinit();

    _ = try src.refill();
    src.consume(5); // consume "first", start moves forward

    _ = try std.posix.write(fds[1], "third");
    std.posix.close(fds[1]);
    _ = try src.refill(); // should compact then read "third"

    const view = try src.peek();
    try std.testing.expectEqualSlices(u8, "secondthird", view.bytes);
}
