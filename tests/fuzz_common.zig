//! Shared subprocess + escape primitives for the fuzz-* differential harnesses.
//!
//! Both `tests/fuzz_regex.zig` and `tests/fuzz_diff.zig` go through this file
//! so jq invocation, output caps, and JSON-escape semantics stay in lockstep.
//! The first time the cap needs to grow or jq invocation needs `--unbuffered`,
//! the duplication would silently rot — single source of truth.
//!
//! Imported as a relative file (`@import("fuzz_common.zig")`), not a module:
//! callers share the importer's module graph.

const std = @import("std");

// ── Process / environment helpers ─────────────────────────────────────────────

/// Portable current-PID helper. `std.os.linux.getpid()` on Linux (where these
/// harnesses run in CI), fallback to a compile-time zero on other OSes — the
/// fuzz targets gate on Linux features anyway, so non-Linux builds never reach
/// the jq-compare path.
pub fn currentPid() i32 {
    if (@import("builtin").os.tag == .linux) return std.os.linux.getpid();
    return 0;
}

/// Ensure `jq` is invocable on this machine before starting a fuzz run.
/// Without this, a missing jq would make every `runJq*` call return an error
/// which the loop body silently swallows — the test would report 0/0
/// iterations and pass vacuously. That regression already bit us once (M6).
pub fn requireJqOnPath(alloc: std.mem.Allocator) !void {
    var child = std.process.Child.init(
        &.{ std.posix.getenv("ZQ_JQ") orelse "jq", "--version" },
        alloc,
    );
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return error.SkipZigTest;
    const term = child.wait() catch return error.SkipZigTest;
    switch (term) {
        .Exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
}

/// Confirm the zq binary at `zq_path` exists and runs `--help` cleanly.
/// `zig build fuzz-diff` builds zq transitively, but a stale CWD or an
/// out-of-tree invocation could miss it. Skip the test rather than crash.
pub fn requireZqBinary(alloc: std.mem.Allocator, zq_path: []const u8) !void {
    var child = std.process.Child.init(&.{ zq_path, "--help" }, alloc);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return error.SkipZigTest;
    const term = child.wait() catch return error.SkipZigTest;
    switch (term) {
        .Exited => {}, // any exit code is fine; --help variants differ
        else => return error.SkipZigTest,
    }
}

// ── JSON escape helper ────────────────────────────────────────────────────────

pub fn jsonEscapeInto(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try buf.append(alloc, '"');
    for (s) |b| {
        switch (b) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            0...8, 11, 12, 14...31 => {
                var tmp: [8]u8 = undefined;
                const enc = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{b}) catch unreachable;
                try buf.appendSlice(alloc, enc);
            },
            else => try buf.append(alloc, b),
        }
    }
    try buf.append(alloc, '"');
}

// ── jq subprocess helpers ─────────────────────────────────────────────────────

/// Output cap shared by all jq/zq subprocess helpers. 256 KB is generous for
/// the bounded inputs the fuzzers generate (≤4 KB) but tight enough that an
/// actual hit indicates a runaway, not silent truncation. Treat hits as errors.
pub const SUBPROCESS_OUTPUT_CAP: usize = 256 * 1024;

/// Run `jq -c <filter>` with `input` written to a per-PID temp file. Returns
/// stdout trimmed of the trailing newline.
///
/// `tag` distinguishes concurrent harness runs sharing /tmp:
///   tag="regex" → /tmp/zq_fuzz_regex_input_{PID}.json
///   tag="diff"  → /tmp/zq_fuzz_diff_input_{PID}.json
///
/// File-based input matches the pre-lift behavior of `fuzz_regex.zig`. New
/// harnesses should prefer `runJqStdin` (no tmpfile, no /tmp dependency).
pub fn runJq(
    alloc: std.mem.Allocator,
    filter: []const u8,
    input: []const u8,
    tag: []const u8,
) ![]u8 {
    var path_buf: [128]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(
        &path_buf,
        "/tmp/zq_fuzz_{s}_input_{d}.json",
        .{ tag, currentPid() },
    );
    {
        var f = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer f.close();
        var buf: [4096]u8 = undefined;
        var w = f.writer(&buf);
        try w.interface.writeAll(input);
        try w.interface.flush();
    }

    var child = std.process.Child.init(
        &.{ std.posix.getenv("ZQ_JQ") orelse "jq", "-c", filter, tmp_path },
        alloc,
    );
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    if (child.stdout) |stdout| {
        const bytes = try stdout.readToEndAlloc(alloc, SUBPROCESS_OUTPUT_CAP);
        defer alloc.free(bytes);
        try out.appendSlice(alloc, bytes);
    }
    _ = try child.wait();
    const slice = try out.toOwnedSlice(alloc);
    defer alloc.free(slice);
    const trim: usize = if (slice.len > 0 and slice[slice.len - 1] == '\n') 1 else 0;
    return try alloc.dupe(u8, slice[0 .. slice.len - trim]);
}

/// ProcessOutput: stdout + stderr + exit_code from a subprocess invocation.
/// Caller owns both byte slices; free with the same allocator passed to the
/// helper that produced this struct.
pub const ProcessOutput = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: *ProcessOutput, alloc: std.mem.Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

/// Run `jq -c <filter>` piping `input` over stdin. Returns ProcessOutput with
/// stdout (trimmed of trailing newline), stderr (raw), and exit code.
///
/// Preferred over `runJq` for new harnesses — no tmpfile, no /tmp collision
/// class, and matches how real users invoke jq. `runJq` is retained for
/// `fuzz_regex.zig` byte-eq with its pre-lift behavior.
pub fn runJqStdin(
    alloc: std.mem.Allocator,
    filter: []const u8,
    input: []const u8,
) !ProcessOutput {
    var child = std.process.Child.init(
        // `--` terminates option parsing so filters that start with `-`
        // (e.g. `-10`) aren't mis-parsed as CLI flags.
        &.{ std.posix.getenv("ZQ_JQ") orelse "jq", "-c", "--", filter },
        alloc,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    return collectChildOutput(alloc, &child, input);
}

/// Run zq binary at `zq_path` with `filter` as a single positional arg, piping
/// `input` over stdin. Returns ProcessOutput. Caller owns stdout + stderr.
pub fn runZqSubprocess(
    alloc: std.mem.Allocator,
    zq_path: []const u8,
    filter: []const u8,
    input: []const u8,
) !ProcessOutput {
    var child = std.process.Child.init(
        &.{ zq_path, "-c", "--", filter },
        alloc,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    return collectChildOutput(alloc, &child, input);
}

fn collectChildOutput(
    alloc: std.mem.Allocator,
    child: *std.process.Child,
    input: []const u8,
) !ProcessOutput {
    // Feed stdin. Closing stdin signals EOF to the child. WriteFailed (the
    // single error returned by the 0.15 writer interface) collapses every
    // io-level failure including broken-pipe — swallow it; the child's
    // non-zero exit code surfaces real errors to the caller.
    if (child.stdin) |*stdin_file| {
        var buf: [4096]u8 = undefined;
        var w = stdin_file.writer(&buf);
        w.interface.writeAll(input) catch {};
        w.interface.flush() catch {};
        stdin_file.close();
        child.stdin = null;
    }

    var stdout_buf = std.ArrayList(u8){};
    errdefer stdout_buf.deinit(alloc);
    var stderr_buf = std.ArrayList(u8){};
    errdefer stderr_buf.deinit(alloc);

    if (child.stdout) |stdout| {
        const bytes = try stdout.readToEndAlloc(alloc, SUBPROCESS_OUTPUT_CAP);
        defer alloc.free(bytes);
        try stdout_buf.appendSlice(alloc, bytes);
    }
    if (child.stderr) |stderr| {
        const bytes = try stderr.readToEndAlloc(alloc, SUBPROCESS_OUTPUT_CAP);
        defer alloc.free(bytes);
        try stderr_buf.appendSlice(alloc, bytes);
    }

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        else => 255,
    };

    // Trim trailing newline from stdout to match runJq's normalization.
    const stdout_slice = try stdout_buf.toOwnedSlice(alloc);
    const stderr_slice = try stderr_buf.toOwnedSlice(alloc);
    const trim: usize = if (stdout_slice.len > 0 and stdout_slice[stdout_slice.len - 1] == '\n') 1 else 0;
    const trimmed_stdout = if (trim == 0) stdout_slice else blk: {
        const dup = try alloc.dupe(u8, stdout_slice[0 .. stdout_slice.len - trim]);
        alloc.free(stdout_slice);
        break :blk dup;
    };
    return .{
        .stdout = trimmed_stdout,
        .stderr = stderr_slice,
        .exit_code = exit_code,
    };
}
