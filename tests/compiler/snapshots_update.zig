//! Snapshot regenerator — Phase 2R / R3 step 9.
//!
//! Reads each `tests/compiler/snapshots/lower/*.txt` file, extracts
//! its `# source:` directive, re-runs the dumper on that filter, and
//! overwrites the file with the freshly-rendered IR text. The
//! regeneration is intended for deliberate IR changes; CI fails on
//! any uncommitted snapshot diff (run `zig build test` after running
//! this to confirm the new output is what you expected).
//!
//! Single source of truth: drives `compiler.dump` directly, the same
//! call the snapshot test uses. No second renderer.
const std = @import("std");
const ast = @import("ast");
const compiler = @import("compiler");

const SNAPSHOT_DIR = "tests/compiler/snapshots/lower";

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var dir = try std.fs.cwd().openDir(SNAPSHOT_DIR, .{ .iterate = true });
    defer dir.close();

    var stdout_buf: std.ArrayList(u8) = .{};
    defer stdout_buf.deinit(alloc);
    const w = stdout_buf.writer(alloc);

    var rewritten: u32 = 0;
    var unchanged: u32 = 0;

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;

        const file_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ SNAPSHOT_DIR, entry.name });
        defer alloc.free(file_path);

        const original = try std.fs.cwd().readFileAlloc(alloc, file_path, std.math.maxInt(usize));
        defer alloc.free(original);

        const filter = extractSource(original) orelse {
            try w.print("SKIP {s}: missing `# source:` directive\n", .{entry.name});
            continue;
        };

        // Take ownership of `filter` bytes — they alias `original`,
        // which is freed after this iteration. Render → dump → diff.
        const filter_owned = try alloc.dupe(u8, filter);
        defer alloc.free(filter_owned);

        var parse_result = ast.parse(filter_owned, alloc);
        defer parse_result.deinit();
        if (parse_result.hasErrors()) {
            try w.print("SKIP {s}: parse error in `{s}`\n", .{ entry.name, filter_owned });
            continue;
        }

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var lowerer = compiler.Lowerer{
            .arena = &arena,
            .src = filter_owned,
            .out = compiler.IR.init(&arena),
            .opts = .{},
        };
        _ = compiler.lowerNode(&lowerer, parse_result.root) catch |e| {
            try w.print("SKIP {s}: lower error `{s}` in `{s}`\n", .{ entry.name, @errorName(e), filter_owned });
            continue;
        };

        var rendered: std.ArrayList(u8) = .{};
        defer rendered.deinit(alloc);
        try compiler.dump(&lowerer.out, parse_result.root, filter_owned, rendered.writer(alloc));

        if (std.mem.eql(u8, rendered.items, original)) {
            unchanged += 1;
            try w.print("UNCHANGED {s}\n", .{entry.name});
            continue;
        }

        try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = rendered.items });
        rewritten += 1;
        try w.print("REWROTE  {s}\n", .{entry.name});
    }

    try w.print("\nsnapshots-update: rewrote={d} unchanged={d}\n", .{ rewritten, unchanged });
    try std.fs.File.stdout().writeAll(stdout_buf.items);
}

/// Read the leading `# source: <filter>` directive (always the first
/// line of the snapshot). Returns null if the file isn't a snapshot.
fn extractSource(snapshot: []const u8) ?[]const u8 {
    const prefix = "# source: ";
    if (!std.mem.startsWith(u8, snapshot, prefix)) return null;
    const after = snapshot[prefix.len..];
    const newline = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
    return after[0..newline];
}
