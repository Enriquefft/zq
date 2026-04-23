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
const query_mod = @import("query");
const pool_mod = @import("pool");
const types_mod = @import("types");

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

// ─── Prefilter soundness fuzz ─────────────────────────────────────────────────
//
// The prefilter is a per-record "maybe" predicate: false = skip, true = full
// filter. The contract is strict ONE-WAY:
//
//     accept(bytes) = false  ⇒  filter produces no output for that record.
//
// False positives are allowed (records the prefilter keeps that the filter
// rejects). False negatives — records the prefilter drops that the filter
// would have output — silently corrupt the result.
//
// This fuzz harness generates:
//   - A query in the prefilter-eligible idiom select(.FIELD | test("LIT")).
//   - A batch of records, some of which contain the literal raw, some
//     \uXXXX-encoded, some short-escape-encoded, some unrelated.
//
// For each record it verifies:
//   1. Running zq WITH prefilter gates → zq output A.
//   2. Running zq WITHOUT prefilter gates → zq output B.
//   3. Running jq on the same record     → output C.
//   Invariant: A == B == C.
//
// This catches any future regression that re-introduces a false-negative
// path in the prefilter (e.g. new encoding form not handled by the
// backslash-presence check, a walker bug, etc.).

const prefilter_default_iters: u32 = 1000;

fn runWithOptionalPrefilter(
    alloc: std.mem.Allocator,
    cq: *query_mod.CompiledQuery,
    input: []const u8,
    enable_prefilter: bool,
) ![]u8 {
    // Snapshot + temporarily disable the prefilter if requested. We do NOT
    // deinit the prefilter — we just detach it for this run and restore it.
    const saved = cq.prefilter;
    defer cq.prefilter = saved;
    if (!enable_prefilter) cq.prefilter = null;

    const fd = std.posix.memfd_create("zq_fuzz_pf", 0) catch return error.MemfdFailed;
    errdefer std.posix.close(fd);
    _ = try std.posix.write(fd, input);
    try std.posix.lseek_SET(fd, 0);
    var file = std.fs.File{ .handle = fd };
    defer file.close();

    const budget = pool_mod.MemoryBudget.explicit(1024 * 1024 * 1024);
    var p = try pool_mod.Pool.init(1, budget, alloc);
    defer p.deinit();

    try p.submit_file(file, cq, .compact, null, .{}, false, &.{});

    var out = std.ArrayList(u8){};
    errdefer out.deinit(alloc);
    while (try p.collect_bytes()) |r| {
        try out.appendSlice(alloc, r.data);
    }
    return out.toOwnedSlice(alloc);
}

fn genLiteral(gen: *Generator) ![]u8 {
    // Random 2-6 char literal from the genChar alphabet. All are safe to
    // splice directly into both the query pattern and JSON record values.
    const len = gen.rng.uintLessThan(u8, 5) + 2;
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(gen.alloc);
    var i: u8 = 0;
    while (i < len) : (i += 1) {
        // Restrict to ident-safe chars — no regex metas, no JSON escapes needed.
        const pool = "abcdefghijklmnopqrstuvwxyz0123456789";
        try buf.append(gen.alloc, pool[gen.rng.uintLessThan(usize, pool.len)]);
    }
    return buf.toOwnedSlice(gen.alloc);
}

const EncodingMode = enum { raw, uhex, short_escape, unrelated };

fn encodeChar(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, b: u8, mode: EncodingMode) !void {
    switch (mode) {
        .raw => try buf.append(alloc, b),
        .uhex => {
            var tmp: [8]u8 = undefined;
            const enc = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{b}) catch unreachable;
            try buf.appendSlice(alloc, enc);
        },
        .short_escape => {
            // Short-escape the first char only if it has a short form.
            // For printable ascii we simulate one via a preceding benign
            // escape sequence like `\t`: this doesn't alter the decoded
            // string's literal but forces a `\` into the raw record bytes.
            try buf.appendSlice(alloc, "\\t");
            try buf.append(alloc, b);
        },
        .unrelated => unreachable, // handled at record level
    }
}

fn genRecord(
    alloc: std.mem.Allocator,
    gen: *Generator,
    literal: []const u8,
    field: []const u8,
    mode: EncodingMode,
) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(alloc);

    try buf.append(alloc, '{');
    try jsonEscapeInto(&buf, alloc, field);
    try buf.append(alloc, ':');

    // Value is a string that either contains the literal (in some encoding)
    // or is unrelated noise.
    switch (mode) {
        .unrelated => {
            // Random 5-10 byte string that DOES NOT contain `literal` as a
            // substring. Generate and retry up to 3 times.
            var tries: u8 = 0;
            while (tries < 3) : (tries += 1) {
                var hay = std.ArrayList(u8){};
                defer hay.deinit(alloc);
                const hlen = gen.rng.uintLessThan(u8, 6) + 5;
                var i: u8 = 0;
                while (i < hlen) : (i += 1) {
                    const pool = "ABCDEFGHIJ0123456789";
                    try hay.append(alloc, pool[gen.rng.uintLessThan(usize, pool.len)]);
                }
                if (std.mem.indexOf(u8, hay.items, literal) == null) {
                    try jsonEscapeInto(&buf, alloc, hay.items);
                    break;
                }
            } else {
                // Worst-case fallback: just emit a fixed non-matching string.
                try jsonEscapeInto(&buf, alloc, "XXXXXX");
            }
        },
        else => {
            // Build a string literal manually: open quote, encode each char
            // of `literal` per `mode`, close quote. We inject surrounding
            // chars too so there's some "noise" around the literal.
            try buf.append(alloc, '"');
            try buf.append(alloc, 'a');
            try buf.append(alloc, 'b');
            for (literal) |c| try encodeChar(&buf, alloc, c, mode);
            try buf.append(alloc, 'y');
            try buf.append(alloc, 'z');
            try buf.append(alloc, '"');
        },
    }
    try buf.append(alloc, '}');
    return buf.toOwnedSlice(alloc);
}

test "prefilter fuzz: with-prefilter == without-prefilter == jq" {
    if (!regex.enabled) return error.SkipZigTest;

    const iter_env = std.posix.getenv("ZQ_FUZZ_ITERS");
    const n: u32 = if (iter_env) |s|
        std.fmt.parseInt(u32, s, 10) catch prefilter_default_iters
    else
        100; // in-test-step default; set ZQ_FUZZ_ITERS=1000 for full run.

    const seed_env = std.posix.getenv("ZQ_FUZZ_SEED");
    const seed: u64 = if (seed_env) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;

    var prng = std.Random.DefaultPrng.init(seed);
    var gen = Generator{ .rng = prng.random(), .alloc = std.testing.allocator };

    var divergences: u32 = 0;
    var checked: u32 = 0;

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const lit = try genLiteral(&gen);
        defer std.testing.allocator.free(lit);
        const field = "k";

        // Build query: select(.k | test("LIT"))
        var q_buf = std.ArrayList(u8){};
        defer q_buf.deinit(std.testing.allocator);
        try q_buf.appendSlice(std.testing.allocator, "select(.k | test(");
        try jsonEscapeInto(&q_buf, std.testing.allocator, lit);
        try q_buf.append(std.testing.allocator, ')');
        try q_buf.append(std.testing.allocator, ')');

        const cres = query_mod.CompiledQuery.compile(q_buf.items, .{}, std.testing.allocator) catch continue;
        var cq = switch (cres) {
            .ok => |c| c,
            .err => continue,
        };
        defer cq.deinit();

        // Generate a batch of records across all encoding modes.
        var record_buf = std.ArrayList(u8){};
        defer record_buf.deinit(std.testing.allocator);
        const modes = [_]EncodingMode{ .raw, .uhex, .short_escape, .unrelated };
        for (modes) |m| {
            const rec = try genRecord(std.testing.allocator, &gen, lit, field, m);
            defer std.testing.allocator.free(rec);
            try record_buf.appendSlice(std.testing.allocator, rec);
            try record_buf.append(std.testing.allocator, '\n');
        }

        // Run with and without prefilter.
        const out_pf = runWithOptionalPrefilter(std.testing.allocator, &cq, record_buf.items, true) catch continue;
        defer std.testing.allocator.free(out_pf);
        const out_no = runWithOptionalPrefilter(std.testing.allocator, &cq, record_buf.items, false) catch continue;
        defer std.testing.allocator.free(out_no);

        // Shell to jq for ground truth.
        const jq_out_raw = runJq(std.testing.allocator, q_buf.items, record_buf.items) catch continue;
        defer std.testing.allocator.free(jq_out_raw);

        // Normalize jq output: append trailing newline if there's any content
        // (zq pool output has one), else leave empty.
        var jq_norm = std.ArrayList(u8){};
        defer jq_norm.deinit(std.testing.allocator);
        if (jq_out_raw.len > 0) {
            try jq_norm.appendSlice(std.testing.allocator, jq_out_raw);
            try jq_norm.append(std.testing.allocator, '\n');
        }

        checked += 1;

        if (!std.mem.eql(u8, out_pf, out_no)) {
            std.debug.print(
                "PREFILTER DIVERGENCE (pf vs no-pf): lit={s} q={s}\n  pf={s}\n  no={s}\n",
                .{ lit, q_buf.items, out_pf, out_no },
            );
            divergences += 1;
            continue;
        }
        if (!std.mem.eql(u8, out_pf, jq_norm.items)) {
            std.debug.print(
                "ZQ vs JQ DIVERGENCE: lit={s} q={s}\n  zq={s}\n  jq={s}\n",
                .{ lit, q_buf.items, out_pf, jq_norm.items },
            );
            divergences += 1;
        }
    }

    std.debug.print(
        "prefilter fuzz: {d}/{d} ran, {d} divergences\n",
        .{ checked, n, divergences },
    );
    try std.testing.expectEqual(@as(u32, 0), divergences);
}
