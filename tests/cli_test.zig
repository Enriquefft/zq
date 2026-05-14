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

// ── NIX-010: value-arg slot must survive backtracking generators ────────────
//
// `def f($p): <body referencing $p>; f(<value>)` emitted `pop_variable`
// after the body, clearing the value-arg slot. With a generator anywhere
// in args OR body, the VM backtracks past the pop and subsequent
// `load_variable($p)` reads a cleared slot → "type error at $p".
//
// Fix: extend the suppress-pop predicate (INLINE + RECURSIVE arms in
// `src/compiler/emit.zig`) to OR in the body subtree, not just the args.
// Filter-arg `def f(p)` always worked — filter args are AST-substituted
// at lower, never slot-stored.

test "NIX-010: value-arg survives generator body across backtracks (.[])" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{"def f($p): .[] | $p; f(\"hi\")"}, "[1,2]");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("\"hi\"\n\"hi\"\n", r.stdout);
}

test "NIX-010: value-arg survives to_entries[] body across backtracks" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{"def f($p): to_entries[] | $p; f(\"hi\")"}, "{\"a\":1,\"b\":2}");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("\"hi\"\n\"hi\"\n", r.stdout);
}

test "NIX-010: filter-arg path (control — must keep working)" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{"def f(p): .[] | p; f(\"hi\")"}, "[1,2]");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("\"hi\"\n\"hi\"\n", r.stdout);
}

test "NIX-010: non-generator body still pops (no leak across calls)" {
    const alloc = std.testing.allocator;
    // Two sequential calls with different value-args. If the slot leaked
    // from the first call, the second would see the wrong value.
    var r = try runZq(
        alloc,
        &.{"def f($p): $p + 1; f(10), f(20)"},
        "null",
    );
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("11\n21\n", r.stdout);
}

// ── NIX-011: value-args must be frame-local under recursion ─────────────────
//
// NIX-010 was a symptom-level fix (suppressed pop_variable when body had a
// generator). The deeper bug: value-args were stored in shared
// `variable_store[var_id]` slots, so a recursive call's `capture_variable`
// overwrote the outer's slot BEFORE `call_function` snapshotted it for
// save/restore. Outer's binding got corrupted to inner's value across
// backtracks of the outer's body. nixos-rebuild's `help.sh` filter
// (`recurse($prefix)` walking nested commands) exposed it: outer
// `$prefix` corrupted to `["build"]` on the second iter of top-level
// `to_entries[]`, emitting `"build flake"` instead of `"flake"`.
//
// Fix: value-args live in `CallFrame.args` (frame-local). Body refs emit
// `Op.load_arg(arg_index)` reading `it.current_args[arg_index]`. The
// recursive call site evaluates each arg expression onto `value_stack`;
// VM `.call_function` pops them into the new frame's `args`. No slot
// writes, no save/restore protocol for value-args, no ordering bug class.
//
// Fork-after-yield: a body with internal generators (range, comma,
// to_entries[]) leaves forks on `fork_stack` after the first yield. The
// VM defers the frame pop and uses cascading-yield: subsequent
// `return_function` walks call_stack top-down for the first
// non-returned frame. On a body fork's fire, frames at idx
// 0..saved_call_len-1 reactivate (returned=false; body_vars swapped
// back into variable_store).

test "NIX-011: help.sh repro — recursive UDF preserves outer value-arg" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{
        "-r",
        \\def recurse($prefix):
        \\    to_entries[] |
        \\    ($prefix + [.key]) as $newPrefix |
        \\    (if .value | has("commands") then
        \\      ($newPrefix, (.value.commands | recurse($newPrefix)))
        \\    else $newPrefix end);
        \\.args.commands | recurse([]) | join(" ")
    },
        \\{"args":{"commands":{"build":{"about":"Build","commands":{"all":{"about":"Build all"}}},"flake":{"about":"Flake","commands":{"init":{"about":"Init"}}}}}}
    );
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("build\nbuild all\nflake\nflake init\n", r.stdout);
}

test "NIX-011: own-frame value-arg survives recursion" {
    const alloc = std.testing.allocator;
    var r = try runZq(
        alloc,
        &.{"def f($a): if $a<=0 then \"stop\" else f($a-1) end; f(3)"},
        "null",
    );
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("\"stop\"\n", r.stdout);
}

test "NIX-011: self-recursive comma body cascades yield correctly" {
    // `[r(3)]` exercises: comma generator inside body + recursion.
    // Each call yields $n THEN recurses; cascade walks call_stack
    // bottom-up to top-level on each yield. Without cascading-yield,
    // self-recursion's shared body bytecode causes return_function
    // to re-yield the inner frame indefinitely.
    const alloc = std.testing.allocator;
    var r = try runZq(
        alloc,
        &.{ "-c", "def r($n): if $n<=0 then \"end\" else $n, r($n-1) end; [r(3)]" },
        "null",
    );
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("[3,2,1,\"end\"]\n", r.stdout);
}

test "NIX-011: generator in recursive body does not corrupt value-arg" {
    // `range(2) as $i` in body forks twice per call; outer call's
    // $p must remain intact across each iteration of the range.
    const alloc = std.testing.allocator;
    var r = try runZq(
        alloc,
        &.{ "-c", "def f($p): range(2) as $i | if $p==2 then $p else f($p+1) end; [f(0)]" },
        "null",
    );
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    // f(0) -> f(1) twice (i=0, i=1) -> f(2) twice (×2 = 4 emissions of 2),
    // f(1) yields 4 values × 2 iterations = 8 emissions total at f(0).
    try std.testing.expectEqualStrings("[2,2,2,2,2,2,2,2]\n", r.stdout);
}

// ── NIX-009: dotted-key access via fused chain returns null ─────────────────
//
// `.x["a.b"]` and `.x | .["a.b"]` and `.x."a.b"` all became `load_path`
// after fuse, whose payload encoded the chain as a dot-joined string
// `"x.a.b"` and was split back on `.` at execute time — silently
// re-routing the second access through key `"a"` then `"b"`. Direct
// single-leaf bracket access never hit fuse, so it stayed correct.
//
// Fix: the fuse pass treats any `load_field` whose key contains `.`
// as a chain-breaker. Dotted-key chains regress to per-leaf
// `load_field`; the common case (no dots) is unchanged.

test "NIX-009: .x[\"a.b\"] returns the dotted-key value" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-c", ".x[\"a.b\"]" }, "{\"x\":{\"a.b\":1}}");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("1\n", r.stdout);
}

test "NIX-009: .x | .[\"a.b\"] (piped) returns the dotted-key value" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-c", ".x | .[\"a.b\"]" }, "{\"x\":{\"a.b\":1}}");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("1\n", r.stdout);
}

test "NIX-009: .x.\"a.b\" (string-key suffix) returns the dotted-key value" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-c", ".x.\"a.b\"" }, "{\"x\":{\"a.b\":1}}");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("1\n", r.stdout);
}

test "NIX-009: dotted key adjacent to plain keys still resolves both halves" {
    const alloc = std.testing.allocator;
    // `.outer."a.b".inner` — split point is the dotted segment; the
    // plain segments around it must still chain correctly.
    var r = try runZq(
        alloc,
        &.{ "-c", ".outer.\"a.b\".inner" },
        "{\"outer\":{\"a.b\":{\"inner\":42}}}",
    );
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("42\n", r.stdout);
}

test "NIX-009: common case .a.b.c (no dots in keys) still resolves" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-c", ".a.b.c" }, "{\"a\":{\"b\":{\"c\":42}}}");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("42\n", r.stdout);
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

// ── -e exit-status: jq 1.8.1 spec parity (NIX-008) ─────────────────────────

test "-e: filter produces no output yields EXIT_NO_OUTPUT (4)" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-e", ".[] | .signatures.[] | select(startswith(\"cache2.\"))" }, "{\"a\":{\"signatures\":[\"cache1.x\"]}}\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 4), r.exit_code);
    try std.testing.expectEqualStrings("", r.stdout);
}

test "-e: last output null yields EXIT_FALSE (1)" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-e", ".a" }, "{\"a\":null}\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
}

test "-e: last output false yields EXIT_FALSE (1)" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-e", ".a" }, "{\"a\":false}\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
}

test "-e: last output truthy yields EXIT_OK (0)" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-e", ".a" }, "{\"a\":[1]}\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
}

test "-e: mixed output, last is truthy, yields EXIT_OK (0)" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-e", ".[]" }, "[null, false, 1]\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
}

test "-e: mixed output, last is null, yields EXIT_FALSE (1)" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{ "-e", ".[]" }, "[1, null]\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
}

test "-e absent: empty output is still EXIT_OK (0)" {
    const alloc = std.testing.allocator;
    var r = try runZq(alloc, &.{".b"}, "{\"a\":1}\n");
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
}

// ── stdin dispatch parity (Phase 1: submit_source) ──────────────────────────
//
// Regression guard for the source-backend-aware dispatch that routes a
// regular-file stdin (e.g. `zq … < f.json`) through the same mmap-backed
// parallel chunker as `zq f.json`, instead of the streaming IO thread.
// All three invocations — file arg, shell `<` redirect, and `cat | zq` pipe —
// must produce byte-identical stdout for the same query.

/// Run a shell pipeline (`/bin/sh -c …`) and capture stdout/stderr/exit code.
fn runShell(alloc: std.mem.Allocator, script: []const u8) !RunResult {
    var child = std.process.Child.init(&.{ "/bin/sh", "-c", script }, alloc);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout_buf = std.ArrayList(u8){};
    defer stdout_buf.deinit(alloc);
    var stderr_buf = std.ArrayList(u8){};
    defer stderr_buf.deinit(alloc);

    if (child.stdout) |stdout| {
        const bytes = try stdout.readToEndAlloc(alloc, 64 * 1024 * 1024);
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

test "stdin dispatch parity: file arg, < redirect, and cat | pipe agree" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, "dispatch.jsonl");
    defer deleteTmp(path);

    var contents = std.ArrayList(u8){};
    defer contents.deinit(alloc);
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        try contents.writer(alloc).print("{{\"id\":{d},\"v\":\"x\"}}\n", .{i});
    }
    try writeTmp(path, contents.items);

    var r_file = try runZq(alloc, &.{ ".id", path }, null);
    defer r_file.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r_file.exit_code);

    var script_redir_buf: [256]u8 = undefined;
    const script_redir = try std.fmt.bufPrint(&script_redir_buf, "{s} '.id' < {s}", .{ zq_path, path });
    var r_redir = try runShell(alloc, script_redir);
    defer r_redir.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r_redir.exit_code);

    var script_pipe_buf: [256]u8 = undefined;
    const script_pipe = try std.fmt.bufPrint(&script_pipe_buf, "cat {s} | {s} '.id'", .{ path, zq_path });
    var r_pipe = try runShell(alloc, script_pipe);
    defer r_pipe.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r_pipe.exit_code);

    try std.testing.expectEqualStrings(r_file.stdout, r_redir.stdout);
    try std.testing.expectEqualStrings(r_file.stdout, r_pipe.stdout);
}

test "stdin dispatch parity: pretty-printed multi-line records" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, "pretty.json");
    defer deleteTmp(path);

    var contents = std.ArrayList(u8){};
    defer contents.deinit(alloc);
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        try contents.writer(alloc).print(
            \\{{
            \\  "id": {d},
            \\  "nested": {{
            \\    "v": "x"
            \\  }}
            \\}}
            \\
        , .{i});
    }
    try writeTmp(path, contents.items);

    var r_file = try runZq(alloc, &.{ ".id", path }, null);
    defer r_file.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), r_file.exit_code);

    var script_redir_buf: [256]u8 = undefined;
    const script_redir = try std.fmt.bufPrint(&script_redir_buf, "{s} '.id' < {s}", .{ zq_path, path });
    var r_redir = try runShell(alloc, script_redir);
    defer r_redir.deinit(alloc);

    try std.testing.expectEqual(@as(u8, 0), r_redir.exit_code);
    try std.testing.expectEqualStrings(r_file.stdout, r_redir.stdout);
}
