/// bench-compile: compile-only throughput baseline for the legacy compiler.
///
/// Runs N=1000 timed iterations per filter (50 warm-up iterations discarded).
/// Allocator strategy: per-iteration ArenaAllocator that is reset after each
/// iteration. This keeps peak RSS bounded while accurately reflecting the
/// allocator cost the compiler actually incurs.
///
/// Output: line-oriented TSV to stdout (machine-parseable by bench-runner).
/// Units: nanoseconds (bench-runner converts to µs in the baselines doc).
const std = @import("std");
const builtin = @import("builtin");
const query_mod = @import("query");
const err_mod = @import("error");

const WARMUP: usize = 50;
const N: usize = 1000;
const NFILTERS: usize = 17;

const FilterEntry = struct {
    name: []const u8,
    filter: []const u8,
};

const FILTER_CORPUS: [NFILTERS]FilterEntry = .{
    // ── 10 compat filters (small → large AST) ──────────────────────────────
    .{ .name = "f.field", .filter = ".foo" },
    .{ .name = "f.nested", .filter = ".foo.bar" },
    .{ .name = "f.pipe", .filter = ".foo | .bar" },
    .{ .name = "f.index", .filter = ".[0]" },
    .{ .name = "f.arith", .filter = "1+1" },
    .{ .name = "f.array_ctor", .filter = "[.foo, .bar, .baz]" },
    .{ .name = "f.obj_ctor", .filter = "{a: .foo, b: .bar}" },
    .{ .name = "f.select", .filter = "select(.id > 100)" },
    .{ .name = "f.map_add", .filter = "map(.id) | add" },
    .{ .name = "f.if_else", .filter = "if .x then .y else .z end" },
    // ── 3 user-defined-function filters ─────────────────────────────────────
    .{ .name = "udf.simple", .filter = "def f: . + 1; f" },
    .{ .name = "udf.semicolon", .filter = "def f(a;b): a + b; f(.x;.y)" },
    .{ .name = "udf.higher", .filter = "def is_even: . % 2 == 0; .[] | select(is_even)" },
    // ── 1 regex literal ──────────────────────────────────────────────────────
    .{ .name = "regex.literal", .filter = "test(\"^[a-z]+$\")" },
    // ── 1 dynamic regex ──────────────────────────────────────────────────────
    .{ .name = "regex.dynamic", .filter = "match(.pattern)" },
    // ── 1 reduce/foreach ─────────────────────────────────────────────────────
    .{ .name = "f.reduce", .filter = "reduce range(10) as $i (0; . + $i)" },
    // ── 1 deep pipe + comma chain ────────────────────────────────────────────
    .{ .name = "f.deep_pipe", .filter = ".a | .b | .c | .d, .e, .f, .g" },
};

/// Compute population standard deviation (integer nanoseconds → f64 σ).
fn stdev(samples: []const u64, mean: f64) f64 {
    var sum_sq: f64 = 0.0;
    for (samples) |s| {
        const d = @as(f64, @floatFromInt(s)) - mean;
        sum_sq += d * d;
    }
    return @sqrt(sum_sq / @as(f64, @floatFromInt(samples.len)));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const base_alloc = gpa.allocator();

    // Output buffer — flushed to stdout at end. Avoids per-print syscall overhead.
    var out_buf = std.ArrayList(u8){};
    defer out_buf.deinit(base_alloc);
    try out_buf.ensureTotalCapacity(base_alloc, 8192);

    const ts = std.time.nanoTimestamp();

    // ── Header ────────────────────────────────────────────────────────────────
    try std.fmt.format(out_buf.writer(base_alloc), "# bench-compile run @ {d}\n", .{ts});
    try std.fmt.format(out_buf.writer(base_alloc), "# zig: {s}\n", .{builtin.zig_version_string});
    try std.fmt.format(out_buf.writer(base_alloc), "# iterations: {d}  warmup: {d}  filters: {d}\n", .{ N, WARMUP, NFILTERS });
    try out_buf.appendSlice(base_alloc, "name\tmedian_ns\tp99_ns\tsigma_ns\tmin_ns\tmax_ns\tmean_ns\n");

    var samples: [N]u64 = undefined;

    for (FILTER_CORPUS) |entry| {
        // ── Warm-up ───────────────────────────────────────────────────────────
        for (0..WARMUP) |_| {
            var arena = std.heap.ArenaAllocator.init(base_alloc);
            const alloc = arena.allocator();
            const res = try query_mod.CompiledQuery.compile(entry.filter, .{}, alloc);
            switch (res) {
                .ok => |*cq| {
                    var mq = cq.*;
                    mq.deinit();
                },
                .err => {},
            }
            arena.deinit();
        }

        // ── Check for compile error before measurement ─────────────────────
        {
            var arena = std.heap.ArenaAllocator.init(base_alloc);
            const alloc = arena.allocator();
            const res = try query_mod.CompiledQuery.compile(entry.filter, .{}, alloc);
            const had_err = switch (res) {
                .err => |ce| blk: {
                    var msg_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "{s}: COMPILE-ERROR: {s}\n", .{
                        entry.name,
                        err_mod.kindToString(ce.kind),
                    }) catch entry.name;
                    std.fs.File.stderr().writeAll(msg) catch {};
                    break :blk true;
                },
                .ok => |*cq| blk: {
                    var mq = cq.*;
                    mq.deinit();
                    break :blk false;
                },
            };
            arena.deinit();
            if (had_err) continue;
        }

        // ── Measurement ───────────────────────────────────────────────────────
        for (0..N) |i| {
            var arena = std.heap.ArenaAllocator.init(base_alloc);
            const alloc = arena.allocator();

            var timer = try std.time.Timer.start();
            const res = try query_mod.CompiledQuery.compile(entry.filter, .{}, alloc);
            const elapsed = timer.read();

            switch (res) {
                .ok => |*cq| {
                    var mq = cq.*;
                    mq.deinit();
                },
                .err => {},
            }
            arena.deinit();
            samples[i] = elapsed;
        }

        // ── Statistics ────────────────────────────────────────────────────────
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));

        const median = samples[N / 2]; // N=1000 → samples[500]
        const p99 = samples[989]; // floor(0.99 * 1000) - 1 = 989

        var sum: u64 = 0;
        for (samples) |s| sum += s;
        const mean_f = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(N));
        const sigma = stdev(&samples, mean_f);

        try std.fmt.format(out_buf.writer(base_alloc), "{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
            entry.name,
            median,
            p99,
            @as(u64, @intFromFloat(@round(sigma))),
            samples[0],
            samples[N - 1],
            @as(u64, @intFromFloat(@round(mean_f))),
        });
    }

    try std.fs.File.stdout().writeAll(out_buf.items);
}
