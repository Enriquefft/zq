//! Regex latency probe.
//!
//! A minimal per-call timing harness — NOT the full microbench suite (Phase 0
//! roadmap rebuilds that). Prints median nanoseconds for the three pattern
//! classes the regex plan lists explicit targets for:
//!
//!   Literal "foo"           target: 30–80 ns
//!   Alternation "foo|bar|…"  target: 80–200 ns
//!   Named capture "(?<y>\\d{4})"  target: 300 ns – 1 µs
//!
//! Invoke with: `zig build bench-regex` (added alongside fuzz-regex).
//!
//! Methodology:
//!   - N = 10_000 iterations per pattern after a 1_000-iteration warmup.
//!   - `Timer.read()` between iterations; sort and take the median.
//!   - No I/O, no allocations inside the hot loop — the clone is built once
//!     and reused. This mirrors the production per-worker clone model.

const std = @import("std");
const regex = @import("regex");

const warmup: u32 = 1_000;
const samples: u32 = 10_000;

fn bench(name: []const u8, pattern: []const u8, hay: []const u8) !void {
    if (!regex.enabled) return error.SkipZigTest;
    var r = try regex.Regex.compile(pattern);
    defer r.deinit();
    var cl = try r.clone();
    defer cl.deinit();

    // Warmup: exercises the internal Pool<Cache> path so later samples don't
    // include one-off initialization.
    var i: u32 = 0;
    while (i < warmup) : (i += 1) {
        _ = try cl.isMatch(hay);
    }

    var times = try std.testing.allocator.alloc(u64, samples);
    defer std.testing.allocator.free(times);

    var timer = try std.time.Timer.start();
    i = 0;
    while (i < samples) : (i += 1) {
        timer.reset();
        _ = try cl.isMatch(hay);
        times[i] = timer.read();
    }
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    const median = times[samples / 2];
    const p99 = times[(samples * 99) / 100];
    std.debug.print("{s:<24} median={d} ns  p99={d} ns  pattern={s}\n", .{ name, median, p99, pattern });
}

test "regex bench: latency probe" {
    if (!regex.enabled) return error.SkipZigTest;
    try bench("literal", "foo", "the quick brown foo jumps over");
    try bench("alternation", "foo|bar|baz|qux", "the quick brown qux jumps over");
    try bench("named_capture", "(?<year>\\d{4})", "year=2026 is the answer");
    try bench("anchored_prefix", "^GET ", "GET /path HTTP/1.1");
    try bench("class_plus", "[a-z]+", "the quick brown fox");
}

// ── Sparser prefilter: low-selectivity scenario (Phase F target) ──────────────
//
// The real Sparser win is skipping the JSON PARSE for records that can't
// possibly match. A per-record prefilter that runs alongside the full
// regex engine is not the win — the win is skipping everything else
// (parse, value lookup, value coercion, serialize) when the literal is
// absent. This bench simulates that by measuring:
//
//   (A) Full path:      parse JSON → project field → regex-match → maybe-emit.
//   (B) Prefilter path: raw-byte literal scan → if miss, SKIP entirely.
//
// We time (A) on a miss, (B) on a miss, and the prefilter-scan cost alone,
// to make the parse-avoidance benefit explicit.

const parser_mod = @import("parser");
const query_mod = @import("query");

test "regex bench: prefilter skips parse for non-matching records" {
    if (!regex.enabled) return error.SkipZigTest;

    // A representative low-selectivity JSONL record. 100k of these with 1%
    // containing "/v1/login" is a realistic request-log workload.
    const record: []const u8 =
        \\{"t":"2026-04-22T12:00:00Z","service":"cart","endpoint":"/v1/items","status":200,"latency_ms":42}
    ;

    const src = "select(.endpoint | test(\"/v1/login\"))";
    const alloc = std.testing.allocator;
    const compile_result = try query_mod.CompiledQuery.compile(src, .{}, alloc);
    var cq = switch (compile_result) {
        .ok => |c| c,
        .err => return error.SkipZigTest,
    };
    defer cq.deinit();
    try std.testing.expect(cq.prefilter != null);

    // (A) Full path. We time the work `process_line` actually does on a miss:
    //   parser.feed → execute/reset → it.next() → parser.reset
    //
    // Production reuses the ResultIterator across records (see
    // `src/pool/root.zig: process_line` — the iterator is allocated on the
    // first record and `.reset(tape, bindings)`-rebound thereafter). Earlier
    // versions of this bench built a fresh iterator per iteration, which
    // over-counted the full-path cost by several-fold. The fix: init once,
    // reset in the loop — matches the real hot path.
    var parser = try parser_mod.Parser.init(alloc);
    defer parser.deinit();

    const iters: u32 = 50_000;

    // Build the iterator against the first tape; immediately reset() rebinds
    // it per iteration. Do NOT call parser.reset() between `execute` and the
    // first `reset(tape, ...)` below — the tape buffer must stay live.
    const first_fr = parser.feed(record, true) catch unreachable;
    const first_tape = switch (first_fr) {
        .done => |d| d.tape,
        .need_more => unreachable,
    };
    var it = try cq.execute(first_tape, &.{}, alloc);
    defer it.deinit();
    _ = try it.next();
    parser.reset();

    // Warmup: exercise the hot path without the allocator ever expanding.
    var w: u32 = 0;
    while (w < warmup) : (w += 1) {
        const fr = parser.feed(record, true) catch unreachable;
        const tape = switch (fr) {
            .done => |d| d.tape,
            .need_more => unreachable,
        };
        it.reset(tape, &.{});
        _ = try it.next();
        parser.reset();
    }

    var times_full = try alloc.alloc(u64, iters);
    defer alloc.free(times_full);
    var timer = try std.time.Timer.start();
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        timer.reset();
        const fr = parser.feed(record, true) catch unreachable;
        const tape = switch (fr) {
            .done => |d| d.tape,
            .need_more => unreachable,
        };
        it.reset(tape, &.{});
        _ = try it.next();
        parser.reset();
        times_full[i] = timer.read();
    }

    // (B) Prefilter path — raw-byte scan only (skips parse + query).
    var times_pre = try alloc.alloc(u64, iters);
    defer alloc.free(times_pre);
    i = 0;
    while (i < iters) : (i += 1) {
        timer.reset();
        _ = cq.prefilter.?.accept(record);
        times_pre[i] = timer.read();
    }

    std.mem.sort(u64, times_full, {}, std.sort.asc(u64));
    std.mem.sort(u64, times_pre, {}, std.sort.asc(u64));

    const med_full = times_full[iters / 2];
    const med_pre = times_pre[iters / 2];
    const speedup: f64 = @as(f64, @floatFromInt(med_full)) / @as(f64, @floatFromInt(@max(med_pre, 1)));

    std.debug.print("\nSparser prefilter impact on miss path ({} iters, iterator reused)\n", .{iters});
    std.debug.print("  full parse+query: median={d} ns  p99={d} ns\n", .{ med_full, times_full[(iters * 99) / 100] });
    std.debug.print("  prefilter skip:   median={d} ns  p99={d} ns\n", .{ med_pre, times_pre[(iters * 99) / 100] });
    std.debug.print("  skip is {d:.1}x faster per record\n", .{speedup});

    // Target: at least 5x — the whole point of the prefilter is the parse
    // avoidance, which ought to dwarf a memchr. Flag (don't fail) if the
    // machine is too slow to hit the target.
    if (speedup < 5.0) {
        std.debug.print("  WARNING: prefilter speedup below 5x target\n", .{});
    }
}
