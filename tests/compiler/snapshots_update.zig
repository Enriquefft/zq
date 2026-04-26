//! Snapshot regenerator — Phase 2R / R3 step 9.
//!
//! Reads each `tests/compiler/snapshots/{lower,fuse}/*.txt` file,
//! extracts its `# source:` directive, re-runs the dumper on that
//! filter, and overwrites the file with the freshly-rendered IR text.
//! The regeneration is intended for deliberate IR changes; CI fails
//! on any uncommitted snapshot diff (run `zig build test` after
//! running this to confirm the new output is what you expected).
//!
//! Single source of truth: drives `compiler.dump` (lower/) and
//! `compiler.dumpIR` (fuse/) directly, the same calls the snapshot
//! tests use. No second renderer per directory.
const std = @import("std");
const ast = @import("ast");
const compiler = @import("compiler");

const LOWER_DIR = "tests/compiler/snapshots/lower";
const FUSE_DIR = "tests/compiler/snapshots/fuse";

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var stdout_buf: std.ArrayList(u8) = .{};
    defer stdout_buf.deinit(alloc);
    const w = stdout_buf.writer(alloc);

    const lower_stats = try regenLowerDir(alloc, w);
    const fuse_stats = try regenFuseDir(alloc, w);

    try w.print(
        "\nsnapshots-update: lower(rewrote={d} unchanged={d}) fuse(rewrote={d} unchanged={d})\n",
        .{ lower_stats.rewritten, lower_stats.unchanged, fuse_stats.rewritten, fuse_stats.unchanged },
    );
    try std.fs.File.stdout().writeAll(stdout_buf.items);
}

const Stats = struct { rewritten: u32, unchanged: u32 };

/// Regenerate `tests/compiler/snapshots/lower/*.txt`. Each fixture's
/// post-lower IR is rendered via the AST-walking `compiler.dump` and
/// byte-compared against the on-disk text.
fn regenLowerDir(alloc: std.mem.Allocator, w: anytype) !Stats {
    var dir = try std.fs.cwd().openDir(LOWER_DIR, .{ .iterate = true });
    defer dir.close();

    var rewritten: u32 = 0;
    var unchanged: u32 = 0;

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;

        const file_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ LOWER_DIR, entry.name });
        defer alloc.free(file_path);

        const original = try std.fs.cwd().readFileAlloc(alloc, file_path, std.math.maxInt(usize));
        defer alloc.free(original);

        const filter = extractSource(original) orelse {
            try w.print("SKIP lower/{s}: missing `# source:` directive\n", .{entry.name});
            continue;
        };
        const filter_owned = try alloc.dupe(u8, filter);
        defer alloc.free(filter_owned);

        var parse_result = ast.parse(filter_owned, alloc);
        defer parse_result.deinit();
        if (parse_result.hasErrors()) {
            try w.print("SKIP lower/{s}: parse error in `{s}`\n", .{ entry.name, filter_owned });
            continue;
        }

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var lowerer = compiler.Lowerer{
            .arena = &arena,
            .src = filter_owned,
            .out = compiler.IR.init(&arena),
            .opts = .{},
            .pool_alloc = alloc,
        };
        defer lowerer.deinitRegexPool();
        _ = compiler.lowerNode(&lowerer, parse_result.root) catch |e| {
            try w.print("SKIP lower/{s}: lower error `{s}` in `{s}`\n", .{ entry.name, @errorName(e), filter_owned });
            continue;
        };

        var rendered: std.ArrayList(u8) = .{};
        defer rendered.deinit(alloc);
        try compiler.dump(&lowerer.out, parse_result.root, filter_owned, rendered.writer(alloc));

        if (std.mem.eql(u8, rendered.items, original)) {
            unchanged += 1;
            try w.print("UNCHANGED lower/{s}\n", .{entry.name});
            continue;
        }
        try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = rendered.items });
        rewritten += 1;
        try w.print("REWROTE   lower/{s}\n", .{entry.name});
    }
    return .{ .rewritten = rewritten, .unchanged = unchanged };
}

/// Regenerate `tests/compiler/snapshots/fuse/*.txt`. Each fixture
/// renders the IR before AND after fuse via the IR-walking
/// `compiler.dumpIR`, bracketed by `# before` / `# after` directives
/// (spec §8). Driven by the same `compiler.fuse` entry the production
/// pipeline calls.
fn regenFuseDir(alloc: std.mem.Allocator, w: anytype) !Stats {
    var dir = std.fs.cwd().openDir(FUSE_DIR, .{ .iterate = true }) catch |e| switch (e) {
        // Directory absent → no fuse fixtures to regen yet. Mirrors the
        // "directory exists only after R3 scaffolding" note in spec §11.
        error.FileNotFound => return .{ .rewritten = 0, .unchanged = 0 },
        else => return e,
    };
    defer dir.close();

    var rewritten: u32 = 0;
    var unchanged: u32 = 0;

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;

        const file_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ FUSE_DIR, entry.name });
        defer alloc.free(file_path);

        const original = try std.fs.cwd().readFileAlloc(alloc, file_path, std.math.maxInt(usize));
        defer alloc.free(original);

        const filter = extractSource(original) orelse {
            try w.print("SKIP fuse/{s}: missing `# source:` directive\n", .{entry.name});
            continue;
        };
        const filter_owned = try alloc.dupe(u8, filter);
        defer alloc.free(filter_owned);

        var parse_result = ast.parse(filter_owned, alloc);
        defer parse_result.deinit();
        if (parse_result.hasErrors()) {
            try w.print("SKIP fuse/{s}: parse error in `{s}`\n", .{ entry.name, filter_owned });
            continue;
        }

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var lowerer = compiler.Lowerer{
            .arena = &arena,
            .src = filter_owned,
            .out = compiler.IR.init(&arena),
            .opts = .{},
            .pool_alloc = alloc,
        };
        defer lowerer.deinitRegexPool();
        _ = compiler.lowerNode(&lowerer, parse_result.root) catch |e| {
            try w.print("SKIP fuse/{s}: lower error `{s}` in `{s}`\n", .{ entry.name, @errorName(e), filter_owned });
            continue;
        };

        var rendered: std.ArrayList(u8) = .{};
        defer rendered.deinit(alloc);
        const rw = rendered.writer(alloc);
        try rw.print("# source: {s}\n", .{filter_owned});
        try rw.writeAll("# before\n");
        try compiler.dumpIR(&lowerer.out, rw);
        try rw.writeAll("# after\n");
        const fuse_out = compiler.fuse(lowerer.out) catch |e| {
            try w.print("SKIP fuse/{s}: fuse error `{s}` in `{s}`\n", .{ entry.name, @errorName(e), filter_owned });
            continue;
        };
        try compiler.dumpIR(&fuse_out.ir, rw);

        if (std.mem.eql(u8, rendered.items, original)) {
            unchanged += 1;
            try w.print("UNCHANGED fuse/{s}\n", .{entry.name});
            continue;
        }
        try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = rendered.items });
        rewritten += 1;
        try w.print("REWROTE   fuse/{s}\n", .{entry.name});
    }
    return .{ .rewritten = rewritten, .unchanged = unchanged };
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
