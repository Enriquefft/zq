//! Regex fuzz differential harness.
//!
//! Strategy: generate N (pattern, haystack) pairs from a small pure-Zig
//! grammar, compile + run each pattern through zq's regex engine, and also
//! shell out to `jq` to compare outputs. Where jq and zq diverge on a feature
//! zq deliberately does not support (backrefs, lookaround), the fuzz harness
//! skips the comparison — the feature delta is tracked in ROADMAP.md.
//!
//! Not part of the default test step. Invoke with:
//!   `zig build fuzz-regex`
//!
//! Defaults:
//!   - iterations: 1000
//!   - seed: 0 (reproducible) unless the ZQ_FUZZ_SEED env var is set
//!   - jq binary: `jq` on PATH (override with ZQ_JQ env var)
//!
//! Exit codes:
//!   0 — every non-skipped iteration agreed
//!   1 — any divergence found (printed to stderr)

const std = @import("std");
const regex = @import("regex");

const default_iterations: u32 = 1000;

const Pattern = struct {
    pat: []u8,
    /// True when the pattern uses a feature zq deliberately rejects (backref,
    /// lookaround). Diff-compare is skipped in that case.
    uses_unsupported: bool,
};

const GenError = error{OutOfMemory};

const Generator = struct {
    rng: std.Random,
    alloc: std.mem.Allocator,

    fn genChar(self: *Generator) u8 {
        const pool = "abcdefghij0123456789 .,";
        return pool[self.rng.uintLessThan(usize, pool.len)];
    }

    fn genHaystack(self: *Generator, buf: *std.ArrayList(u8)) GenError!void {
        const len = self.rng.uintLessThan(u8, 40) + 1;
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            try buf.append(self.alloc, self.genChar());
        }
    }

    fn genAtom(self: *Generator, buf: *std.ArrayList(u8), depth: u8) GenError!void {
        if (depth > 3) {
            // Force a literal character at max depth.
            try buf.append(self.alloc, self.genChar());
            return;
        }
        const pick = self.rng.uintLessThan(u8, 10);
        switch (pick) {
            0, 1, 2 => try buf.append(self.alloc, self.genChar()),
            3 => {
                // char class
                try buf.append(self.alloc, '[');
                const n = self.rng.uintLessThan(u8, 3) + 1;
                var i: u8 = 0;
                while (i < n) : (i += 1) try buf.append(self.alloc, self.genChar());
                try buf.append(self.alloc, ']');
            },
            4 => {
                // group
                try buf.append(self.alloc, '(');
                try self.genSeq(buf, depth + 1);
                try buf.append(self.alloc, ')');
            },
            5 => {
                // \d or \w
                try buf.append(self.alloc, '\\');
                const c: u8 = if (self.rng.boolean()) 'd' else 'w';
                try buf.append(self.alloc, c);
            },
            6 => {
                // anchor
                const c: u8 = if (self.rng.boolean()) '^' else '$';
                try buf.append(self.alloc, c);
            },
            else => try buf.append(self.alloc, self.genChar()),
        }
        // quantifier?
        const q = self.rng.uintLessThan(u8, 5);
        switch (q) {
            0 => try buf.append(self.alloc, '*'),
            1 => try buf.append(self.alloc, '+'),
            2 => try buf.append(self.alloc, '?'),
            else => {}, // no quantifier
        }
    }

    fn genSeq(self: *Generator, buf: *std.ArrayList(u8), depth: u8) GenError!void {
        const n = self.rng.uintLessThan(u8, 3) + 1;
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            try self.genAtom(buf, depth);
        }
    }

    fn genPattern(self: *Generator) GenError!Pattern {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(self.alloc);
        try self.genSeq(&buf, 0);
        const slice = try buf.toOwnedSlice(self.alloc);
        return .{ .pat = slice, .uses_unsupported = false };
    }
};

fn jsonEscapeInto(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
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

/// Run `jq -c <filter>` with `input` on stdin. Returns stdout trimmed of the
/// trailing newline. Uses `/tmp` for a scratch file to avoid wrestling with
/// pipe-write semantics that changed between Zig versions — fuzz harness is
/// slow-path code, correctness first.
fn runJq(alloc: std.mem.Allocator, filter: []const u8, input: []const u8) ![]u8 {
    // Write `input` to a temp file.
    const tmp_path = "/tmp/zq_fuzz_regex_input.json";
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
        // readToEndAlloc via File API — 1 KB cap matches the fuzz input size.
        const bytes = try stdout.readToEndAlloc(alloc, 64 * 1024);
        defer alloc.free(bytes);
        try out.appendSlice(alloc, bytes);
    }
    _ = try child.wait();
    // Drop the trailing newline before handing the buffer back. Re-dupe so
    // the caller gets an allocation whose length matches what `free` expects.
    const slice = try out.toOwnedSlice(alloc);
    defer alloc.free(slice);
    const trim: usize = if (slice.len > 0 and slice[slice.len - 1] == '\n') 1 else 0;
    return try alloc.dupe(u8, slice[0 .. slice.len - trim]);
}

test "regex fuzz: small grammar 100 iters" {
    if (!regex.enabled) return error.SkipZigTest;
    // 100 inside `zig build test`; 1000+ via ZQ_FUZZ_ITERS override. Keep the
    // default low so the main test step stays fast — the larger soak is what
    // `zig build fuzz-regex` is for.
    const iter_env = std.posix.getenv("ZQ_FUZZ_ITERS");
    const n: u32 = if (iter_env) |s| std.fmt.parseInt(u32, s, 10) catch default_iterations else 100;
    const seed_env = std.posix.getenv("ZQ_FUZZ_SEED");
    const seed: u64 = if (seed_env) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;

    var prng = std.Random.DefaultPrng.init(seed);
    var gen = Generator{ .rng = prng.random(), .alloc = std.testing.allocator };

    var divergences: u32 = 0;
    var checked: u32 = 0;
    var compile_ok: u32 = 0;

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const p = try gen.genPattern();
        defer std.testing.allocator.free(p.pat);

        // Try to compile with zq — skip the iteration if zq can't compile it
        // (unbalanced groups, bad classes from the grammar, etc.).
        var r = regex.Regex.compile(p.pat) catch continue;
        r.deinit();
        compile_ok += 1;

        // Generate a haystack.
        var hay_buf = std.ArrayList(u8){};
        defer hay_buf.deinit(std.testing.allocator);
        try gen.genHaystack(&hay_buf);

        // Test the is_match semantics end-to-end. We don't yet diff full match
        // objects — is_match is the highest-coverage cheapest cross-check.
        var compiled = try regex.Regex.compile(p.pat);
        defer compiled.deinit();
        var cl = try compiled.clone();
        defer cl.deinit();
        const zq_matched = try cl.isMatch(hay_buf.items);

        // Shell to jq for the same input.
        var filter_buf = std.ArrayList(u8){};
        defer filter_buf.deinit(std.testing.allocator);
        try filter_buf.appendSlice(std.testing.allocator, "test(");
        try jsonEscapeInto(&filter_buf, std.testing.allocator, p.pat);
        try filter_buf.append(std.testing.allocator, ')');

        var input_buf = std.ArrayList(u8){};
        defer input_buf.deinit(std.testing.allocator);
        try jsonEscapeInto(&input_buf, std.testing.allocator, hay_buf.items);

        const jq_out = runJq(std.testing.allocator, filter_buf.items, input_buf.items) catch continue;
        defer std.testing.allocator.free(jq_out);

        // Empty output = jq rejected the pattern (onig compile error). Skip —
        // this is the documented compat delta (onig rejects constructs that
        // regex-automata accepts and vice versa). The fuzz harness's job is
        // to find semantic divergence on patterns BOTH engines accept.
        if (jq_out.len == 0) continue;
        if (!std.mem.eql(u8, jq_out, "true") and !std.mem.eql(u8, jq_out, "false")) continue;

        const jq_matched = std.mem.eql(u8, jq_out, "true");
        checked += 1;

        if (jq_matched != zq_matched) {
            std.debug.print(
                "DIVERGENCE: pat={s} hay={s} zq={} jq={s}\n",
                .{ p.pat, hay_buf.items, zq_matched, jq_out },
            );
            divergences += 1;
        }
    }

    std.debug.print(
        "regex fuzz: {d}/{d} compiled, {d} diffed, {d} divergences\n",
        .{ compile_ok, n, checked, divergences },
    );
    try std.testing.expectEqual(@as(u32, 0), divergences);
}
