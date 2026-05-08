//! CLI flag own-tests.
//!
//! Subprocess harness for the `zq` binary itself. Drives flags whose
//! semantics live in the argv-parser / I/O layer, not in any single
//! library module — they only manifest through the executable. Modeled
//! on `tests/fuzz_regex.zig`'s `runJq` (std.process.Child).
//!
//! Build wiring (`build.zig`): each test below depends on the install
//! artifact via `b.installArtifact(exe)` so the binary exists before the
//! test runs. The path is taken from the test's `b.getInstallPath` and
//! threaded in via `addOptions("build_options", …, "zq_path", …)`.
//!
//! Coverage: --slurpfile, --rawfile, --unbuffered (wave5-cli-flags-12).

const std = @import("std");
const build_options = @import("build_options");

const zq_path: []const u8 = build_options.zq_path;

/// Stable per-test temp-file slot. Tests run sequentially within one
/// process — collisions between concurrent `zig build test` invocations
/// would still be a concern, so we mix in PID + a per-call counter.
var tmp_counter: u32 = 0;

fn tmpPath(buf: []u8, suffix: []const u8) ![]u8 {
    tmp_counter += 1;
    const pid: i32 = if (@import("builtin").os.tag == .linux) std.os.linux.getpid() else 0;
    return std.fmt.bufPrint(buf, "/tmp/zq_cli_{d}_{d}_{s}", .{ pid, tmp_counter, suffix });
}

fn writeTmp(path: []const u8, contents: []const u8) !void {
    var f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    var buf: [4096]u8 = undefined;
    var w = f.writer(&buf);
    try w.interface.writeAll(contents);
    try w.interface.flush();
}

fn deleteTmp(path: []const u8) void {
    std.fs.deleteFileAbsolute(path) catch {};
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(self: *RunResult, alloc: std.mem.Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

/// Spawn `zq` with the given argv (zq_path is prepended). `stdin_input`
/// is fed on stdin; pass `null` to close stdin immediately.
///
/// Failure to spawn is bubbled as an error — the test should treat that
/// as a harness setup problem, not a test failure.
fn runZq(
    alloc: std.mem.Allocator,
    extra_args: []const []const u8,
    stdin_input: ?[]const u8,
) !RunResult {
    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(alloc);
    try argv.append(alloc, zq_path);
    for (extra_args) |a| try argv.append(alloc, a);

    var child = std.process.Child.init(argv.items, alloc);
    child.stdin_behavior = if (stdin_input != null) .Pipe else .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    if (stdin_input) |input| {
        if (child.stdin) |stdin| {
            stdin.writeAll(input) catch {};
            stdin.close();
            child.stdin = null;
        }
    }

    var stdout_buf = std.ArrayList(u8){};
    defer stdout_buf.deinit(alloc);
    var stderr_buf = std.ArrayList(u8){};
    defer stderr_buf.deinit(alloc);

    if (child.stdout) |stdout| {
        const bytes = try stdout.readToEndAlloc(alloc, 16 * 1024 * 1024);
        defer alloc.free(bytes);
        try stdout_buf.appendSlice(alloc, bytes);
    }
    if (child.stderr) |stderr| {
        const bytes = try stderr.readToEndAlloc(alloc, 1 * 1024 * 1024);
        defer alloc.free(bytes);
        try stderr_buf.appendSlice(alloc, bytes);
    }

    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 255,
    };

    return .{
        .stdout = try stdout_buf.toOwnedSlice(alloc),
        .stderr = try stderr_buf.toOwnedSlice(alloc),
        .exit_code = code,
    };
}

// ── --slurpfile ─────────────────────────────────────────────────────────────

test "--slurpfile: single object wraps in 1-elem array" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, "single.json");
    try writeTmp(path, "{\"a\":1}");
    defer deleteTmp(path);

    var r = try runZq(alloc, &.{ "-c", "--slurpfile", "X", path, "--null-input", "$X" }, null);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("[{\"a\":1}]\n", r.stdout);
}

test "--slurpfile: NDJSON 2+ values yields array of all values" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, "ndjson.json");
    try writeTmp(path, "{\"x\":1}\n{\"x\":2}\n3\n");
    defer deleteTmp(path);

    var r = try runZq(alloc, &.{ "-c", "--slurpfile", "X", path, "--null-input", "$X" }, null);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("[{\"x\":1},{\"x\":2},3]\n", r.stdout);
}

test "--slurpfile: single array file wraps to nested array" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, "arr.json");
    try writeTmp(path, "[1,2,3]");
    defer deleteTmp(path);

    var r = try runZq(alloc, &.{ "-c", "--slurpfile", "X", path, "--null-input", "$X" }, null);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("[[1,2,3]]\n", r.stdout);
}

test "--slurpfile: missing file exits 2 with stderr message" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-c", "--slurpfile", "X", "/tmp/zq_definitely_not_a_file_xyz.json", "--null-input", "." }, null);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 2), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "--slurpfile") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "could not open") != null);
}

test "--slurpfile: invalid JSON exits 2 with stderr message" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, "bad.json");
    try writeTmp(path, "not json at all");
    defer deleteTmp(path);

    var r = try runZq(alloc, &.{ "-c", "--slurpfile", "X", path, "--null-input", "$X" }, null);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 2), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "--slurpfile") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "invalid JSON") != null);
}

test "--slurpfile: collision with --arg, --slurpfile last wins" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, "collision_a.json");
    try writeTmp(path, "{\"k\":1}");
    defer deleteTmp(path);

    var r = try runZq(alloc, &.{ "-c", "--arg", "V", "string-loses", "--slurpfile", "V", path, "--null-input", "$V" }, null);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("[{\"k\":1}]\n", r.stdout);
}

test "--slurpfile: collision with --arg, --arg last wins" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, "collision_b.json");
    try writeTmp(path, "{\"k\":1}");
    defer deleteTmp(path);

    var r = try runZq(alloc, &.{ "-c", "--slurpfile", "V", path, "--arg", "V", "string-wins", "--null-input", "$V" }, null);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("\"string-wins\"\n", r.stdout);
}

// ── --rawfile ───────────────────────────────────────────────────────────────

test "--rawfile: trailing newline preserved" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, "raw.txt");
    try writeTmp(path, "hello world\n");
    defer deleteTmp(path);

    var r = try runZq(alloc, &.{ "-c", "--rawfile", "X", path, "--null-input", "$X" }, null);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("\"hello world\\n\"\n", r.stdout);
}

test "--rawfile: empty file yields empty string" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, "empty.txt");
    try writeTmp(path, "");
    defer deleteTmp(path);

    var r = try runZq(alloc, &.{ "-c", "--rawfile", "X", path, "--null-input", "$X" }, null);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("\"\"\n", r.stdout);
}

test "--rawfile: missing file exits 2" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-c", "--rawfile", "X", "/tmp/zq_definitely_no_rawfile_xyz.txt", "--null-input", "." }, null);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 2), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "--rawfile") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "could not open") != null);
}

test "--rawfile: visible in $ARGS.named alongside --arg" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, "args_named.txt");
    try writeTmp(path, "raw-bytes");
    defer deleteTmp(path);

    var r = try runZq(alloc, &.{ "-c", "--arg", "A", "alpha", "--rawfile", "B", path, "--null-input", "$ARGS.named" }, null);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("{\"A\":\"alpha\",\"B\":\"raw-bytes\"}\n", r.stdout);
}

// ── --unbuffered ────────────────────────────────────────────────────────────

test "--unbuffered: output bytes match unbuffered run for multi-value stream" {
    const alloc = std.testing.allocator;
    const stdin_input = "1\n2\n3\n";
    var r1 = try runZq(alloc, &.{ "-c", ".+10" }, stdin_input);
    defer r1.deinit(alloc);
    var r2 = try runZq(alloc, &.{ "-c", "--unbuffered", ".+10" }, stdin_input);
    defer r2.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r1.exit_code);
    try std.testing.expectEqual(@as(u8, 0), r2.exit_code);
    try std.testing.expectEqualStrings(r1.stdout, r2.stdout);
}

test "--unbuffered: file pool path produces correct output" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, "stream.json");
    try writeTmp(path, "1\n2\n3\n");
    defer deleteTmp(path);

    var r = try runZq(alloc, &.{ "-c", "--unbuffered", ".+100", path }, null);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("101\n102\n103\n", r.stdout);
}

test "--unbuffered: short flag rejected (no -u alias yet)" {
    // Locks in the contract that --unbuffered is long-only — adding a
    // short alias is a deliberate compat decision, not a silent extension.
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-u", "-c", "." }, "null\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 2), r.exit_code);
}

// ── NIX-001: pretty-printed (multi-line) top-level JSON values ──────────────
//
// Default-mode invocation routes both stdin and file-arg paths through the
// pool, whose chunker splits on raw '\n' without tracking JSON structural
// context. Pretty-printed inputs (any JSON written across multiple lines)
// are shredded into per-line fragments and fail to parse.
//
// Compact single-line baseline is also asserted as a regression guard so any
// fix preserves existing JSONL behavior.

test "NIX-001: pretty-printed object via stdin parses as one value" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-c", ".a" }, "{\n  \"a\": 1\n}\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("1\n", r.stdout);
    try std.testing.expectEqualStrings("", r.stderr);
}

test "NIX-001: pretty-printed array via stdin parses as one value" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-c", "length" }, "[\n  1,\n  2\n]\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("2\n", r.stdout);
    try std.testing.expectEqualStrings("", r.stderr);
}

test "NIX-001: pretty-printed object via file arg parses as one value" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, "pretty.json");
    try writeTmp(path, "{\n  \"a\": 1\n}\n");
    defer deleteTmp(path);

    var r = try runZq(alloc, &.{ "-c", ".a", path }, null);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("1\n", r.stdout);
    try std.testing.expectEqualStrings("", r.stderr);
}

test "NIX-001: nested pretty-printed object via stdin (closure-info shape)" {
    // Mirrors structuredAttrs JSON shape that nixpkgs feeds to jq via
    // $NIX_ATTRS_JSON_FILE — nested array of objects with an inner reference
    // list. Filter is a simplified slice of the closure-info filter.
    const alloc = std.testing.allocator;
    const input =
        \\{
        \\  "closure": [
        \\    {
        \\      "path": "/nix/store/aaa",
        \\      "narHash": "sha256-x",
        \\      "narSize": 100,
        \\      "references": ["/nix/store/bbb"]
        \\    }
        \\  ]
        \\}
        \\
    ;
    var r = try runZq(alloc, &.{ "-c", ".closure | length" }, input);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("1\n", r.stdout);
    try std.testing.expectEqualStrings("", r.stderr);
}

test "NIX-001: compact JSONL baseline still works (regression guard)" {
    // Sanity: any fix to the pretty-print path must preserve JSONL behavior.
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-c", "." }, "1\n2\n3\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("1\n2\n3\n", r.stdout);
}

test "NIX-001: concatenated pretty values parse as multiple records" {
    // Two pretty-printed top-level values back-to-back; chunker must
    // recognize the depth-0 boundary between them.
    const alloc = std.testing.allocator;
    const input =
        \\{
        \\  "a": 1
        \\}
        \\{
        \\  "a": 2
        \\}
        \\
    ;
    var r = try runZq(alloc, &.{ "-c", ".a" }, input);
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("1\n2\n", r.stdout);
}

test "NIX-001: --raw-input on multi-line input still splits on \\n" {
    // Raw-input mode is line-oriented by definition; the JSON-aware
    // chunker must NOT collapse multi-line raw input into one record.
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-R", "-c", "." }, "alpha\nbeta\ngamma\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("\"alpha\"\n\"beta\"\n\"gamma\"\n", r.stdout);
}

// ── D1 SSOT pin: predicate ↔ VM-handler coupling for path-assign RHS ────────
//
// `subtreeRebindsCurrent` (src/compiler/emit.zig) whitelists IR ops whose VM
// handlers provably push their result and leave it.current untouched, letting
// path-assign emit the no-wrap fast path. The whitelist mirrors VM-handler
// semantics with no compile-time coupling, so a future handler change that
// re-introduces it.current rebinding for any of these ops would silently
// break fast-path codegen with no failing test elsewhere. These three pin
// the load_path / load_index / load_variable arms of the invariant.

test "D1 pin: .foo = .bar.baz (load_path RHS) preserves outer object" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-c", ".foo = .bar.baz" }, "{\"bar\":{\"baz\":42}}");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("{\"bar\":{\"baz\":42},\"foo\":42}\n", r.stdout);
}

test "D1 pin: .[5] = .[0] (load_index RHS) preserves outer array" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-c", ".[5] = .[0]" }, "[10,20,30,40,50,60]");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("[10,20,30,40,50,10]\n", r.stdout);
}

test "D1 pin: .foo = $X (load_variable RHS) preserves outer object" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-c", "--arg", "X", "99", ".foo = $X" }, "{}");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("{\"foo\":\"99\"}\n", r.stdout);
}

// ── NIX-008: missing filter defaults to identity ────────────────────────────
//
// jq treats `jq` (no positional, no -f) as identity. zq used to error with
// "no filter provided" (rc=2), breaking 4 nix-functional-tests. The CLI now
// resolves a missing filter to ".".

test "NIX-008: no filter defaults to identity" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{"-c"}, "{\"a\":1}");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("{\"a\":1}\n", r.stdout);
}

test "NIX-008: --sort-keys with no filter still defaults to identity" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-c", "--sort-keys" }, "{\"b\":2,\"a\":1}");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":2}\n", r.stdout);
}

// ── Output style composition (-r / -c / -j) ─────────────────────────────────
//
// Pre-OutputStyle, `-r -c` clobbered each other (last write wins on the same
// `Format` enum field). After the refactor, the three axes are independent
// and freely composable. These tests pin both the bug regressions and the
// well-defined behavior of every reachable combination.

test "style: -r on string strips quotes" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-r", "." }, "\"x\"");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("x\n", r.stdout);
}

test "style: -r -c on string still strips quotes (Bug 1 regression)" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-r", "-c", "." }, "\"x\"");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("x\n", r.stdout);
}

test "style: -rc fused short flags on string strips quotes" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-rc", "." }, "\"x\"");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("x\n", r.stdout);
}

test "style: -cr fused (reverse order) on string strips quotes" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-cr", "." }, "\"x\"");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("x\n", r.stdout);
}

test "style: -r on array stays pretty (Bug 2 regression)" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-r", "." }, "[1,2]");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("[\n  1,\n  2\n]\n", r.stdout);
}

test "style: -r -c on array forces compact" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-r", "-c", "." }, "[1,2]");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("[1,2]\n", r.stdout);
}

test "style: -j on multiple strings concatenates without separator" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-j", "." }, "\"x\"\n\"y\"\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("xy", r.stdout);
}

test "style: -jr is idempotent with -rj (raw implied by join)" {
    const alloc = std.testing.allocator;
    var r1 = try runZq(alloc, &.{ "-jr", "." }, "\"x\"");
    defer r1.deinit(alloc);
    var r2 = try runZq(alloc, &.{ "-rj", "." }, "\"x\"");
    defer r2.deinit(alloc);
    try std.testing.expectEqualStrings("x", r1.stdout);
    try std.testing.expectEqualStrings("x", r2.stdout);
}

test "style: -j on non-string emits compact body without separator" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-j", "." }, "1\n2\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    // -j sets raw_strings, but pretty for non-strings; multi-value with -j has no
    // separator. Two top-level pretty integers concatenate as "12".
    try std.testing.expectEqualStrings("12", r.stdout);
}

test "style: -rrr is idempotent with -r" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-rrr", "." }, "\"x\"");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("x\n", r.stdout);
}

test "style: -j -c on arrays concatenates compact bodies (8th cube cell)" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-j", "-c", "." }, "[1,2]\n[3,4]\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("[1,2][3,4]", r.stdout);
}
