const std = @import("std");
const parser_mod = @import("parser");
const build_options = @import("build_options");

const Parser = parser_mod.Parser;
const FeedResult = parser_mod.FeedResult;

fn openTestSuiteDir() !std.fs.Dir {
    return std.fs.openDirAbsolute(build_options.test_suite_dir, .{ .iterate = true });
}

test "JSONTestSuite: y_* files parse successfully" {
    var dir = try openTestSuiteDir();
    defer dir.close();

    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "y_")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const data = try dir.readFileAlloc(std.testing.allocator, entry.name, 1024 * 1024);
        defer std.testing.allocator.free(data);

        var p = try Parser.init(std.testing.allocator);
        defer p.deinit();

        const result = try p.feed(data, true);
        switch (result) {
            .done => {},
            .need_more => {
                std.debug.print("FAIL: y_* file returned need_more: {s}\n", .{entry.name});
                return error.UnexpectedNeedMore;
            },
        }
        count += 1;
    }

    if (count < 90) {
        std.debug.print("Only found {} y_* files, expected >= 90\n", .{count});
        return error.InsufficientTestFiles;
    }
}

test "JSONTestSuite: i_* files do not crash" {
    var dir = try openTestSuiteDir();
    defer dir.close();

    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "i_")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const data = try dir.readFileAlloc(std.testing.allocator, entry.name, 1024 * 1024);
        defer std.testing.allocator.free(data);

        var p = try Parser.init(std.testing.allocator);
        defer p.deinit();

        _ = p.feed(data, true) catch {};
        count += 1;
    }

    if (count < 30) {
        std.debug.print("Only found {} i_* files, expected >= 30\n", .{count});
        return error.InsufficientTestFiles;
    }
}
