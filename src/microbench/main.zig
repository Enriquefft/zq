//! Per-stage microbench harness — Phase 0 of the research roadmap.
//!
//! Measures five production pipeline phases in isolation:
//!   parse      — parser.feed(line)  : bytes → Tape
//!   lookup     — query.execute(tape): bind tape, allocate eval stack
//!   predicate  — iterator.next()    : run VM to first result
//!   serialize  — output.serialize   : Value → JSON bytes
//!   coord      — full per-record loop (parse+lookup+predicate+serialize+reset)
//!
//! Single source of truth: drives the same `parser.Parser` /
//! `query.CompiledQuery` / `output.serialize` that production uses; never
//! forks hot code into a bench-only variant.
//!
//! Gated build step (`zig build microbench`). Emits NDJSON (schema
//! `zq.microbench.v2`) to stdout, one object per phase. Stderr is reserved
//! for status/warnings.
//!
//! See `src/microbench/DESIGN.md` for methodology, schema, CLI, and
//! invariants.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const parser_mod = @import("parser");
const query_mod = @import("query");
const output_mod = @import("output");
const types = @import("types");

const Phase = enum {
    parse,
    lookup,
    predicate,
    serialize,
    coord,

    fn name(self: Phase) []const u8 {
        return switch (self) {
            .parse => "parse",
            .lookup => "lookup",
            .predicate => "predicate",
            .serialize => "serialize",
            .coord => "coord",
        };
    }

    fn fromString(s: []const u8) ?Phase {
        if (std.mem.eql(u8, s, "parse")) return .parse;
        if (std.mem.eql(u8, s, "lookup")) return .lookup;
        if (std.mem.eql(u8, s, "predicate")) return .predicate;
        if (std.mem.eql(u8, s, "serialize")) return .serialize;
        if (std.mem.eql(u8, s, "coord")) return .coord;
        return null;
    }
};

const Config = struct {
    dataset: ?[]const u8 = null,
    inline_record: ?[]const u8 = null,
    filter: []const u8 = ".id",
    iterations: u32 = 10_000,
    warmup: u32 = 1_000,
    phases: std.EnumSet(Phase) = std.EnumSet(Phase).initFull(),
    format: types.Format = .compact,
};

// ── Statistical summary ───────────────────────────────────────────────────────

const Stats = struct {
    mean: f64,
    p50: u64,
    p90: u64,
    p99: u64,
    min: u64,
    max: u64,
    total: u64,
};

/// Compute order statistics on `samples` after subtracting `overhead_ns` per
/// sample. Sorts `samples` in place (ascending). Negative results clamp to 0.
fn summarize(samples: []u64, overhead_ns: u64) Stats {
    for (samples) |*s| {
        s.* = if (s.* > overhead_ns) s.* - overhead_ns else 0;
    }
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    var total: u128 = 0;
    for (samples) |s| total += s;
    const n = samples.len;
    const mean: f64 = if (n == 0) 0 else @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(n));
    return .{
        .mean = mean,
        .p50 = samples[n / 2],
        .p90 = samples[(n * 90) / 100],
        .p99 = samples[(n * 99) / 100],
        .min = samples[0],
        .max = samples[n - 1],
        .total = @intCast(total),
    };
}

/// Measure counter-read overhead: N empty `reset; read` pairs. Returns the
/// median — the robust estimator against interrupts. Runs entirely in
/// user-space; no allocations, no syscalls beyond the initial `Timer.start`.
fn measureOverhead(samples: []u64) !u64 {
    var timer = try std.time.Timer.start();
    for (samples) |*s| {
        timer.reset();
        s.* = timer.read();
    }
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[samples.len / 2];
}

// ── Per-phase measurement ─────────────────────────────────────────────────────

/// A pre-allocated rig holding every production object the phases need. Built
/// once, mutated in place per sample.
const Rig = struct {
    allocator: std.mem.Allocator,
    cq: *query_mod.CompiledQuery,
    parser: parser_mod.Parser,
    records: []const []const u8,
    record_idx: usize = 0,

    /// Persistent serialize buffer — cleared (not freed) between samples so
    /// the first iteration pays the allocation cost and the rest reuse.
    serialize_buf: std.ArrayList(u8),

    fn init(
        allocator: std.mem.Allocator,
        cq: *query_mod.CompiledQuery,
        records: []const []const u8,
    ) !Rig {
        var parser = try parser_mod.Parser.init(allocator);
        errdefer parser.deinit();

        var serialize_buf = std.ArrayList(u8){};
        try serialize_buf.ensureTotalCapacity(allocator, 4096);

        return .{
            .allocator = allocator,
            .cq = cq,
            .parser = parser,
            .records = records,
            .serialize_buf = serialize_buf,
        };
    }

    fn deinit(r: *Rig) void {
        r.parser.deinit();
        r.serialize_buf.deinit(r.allocator);
    }

    fn nextRecord(r: *Rig) []const u8 {
        const line = r.records[r.record_idx];
        r.record_idx = (r.record_idx + 1) % r.records.len;
        return line;
    }
};

/// parse phase: parser.feed(line, true) on a fresh parser state.
/// After each sample the parser is reset — matches production's per-record cycle.
fn measureParse(rig: *Rig, samples: []u64) !void {
    rig.parser.reset();
    var timer = try std.time.Timer.start();
    for (samples) |*slot| {
        const line = rig.nextRecord();
        timer.reset();
        const fr = try rig.parser.feed(line, true);
        slot.* = timer.read();
        // Guard: the fixture must be a complete JSON value per line.
        switch (fr) {
            .done => {},
            .need_more => return error.IncompleteRecord,
        }
        rig.parser.reset();
    }
}

/// lookup phase: CompiledQuery.execute(tape, …) — allocates eval stack,
/// binds tape, clears iterator state. Does NOT run the VM.
fn measureLookup(rig: *Rig, samples: []u64) !void {
    rig.parser.reset();
    var timer = try std.time.Timer.start();
    for (samples) |*slot| {
        const line = rig.nextRecord();
        const fr = try rig.parser.feed(line, true);
        const tape = switch (fr) {
            .done => |d| d.tape,
            .need_more => return error.IncompleteRecord,
        };
        timer.reset();
        var it = try rig.cq.execute(tape, &.{}, rig.allocator);
        slot.* = timer.read();
        it.deinit();
        rig.parser.reset();
    }
}

/// predicate phase: iterator.next() — runs the VM to produce the first value.
/// Uses a reused iterator rebound via reset() — matches production hot path.
fn measurePredicate(rig: *Rig, samples: []u64) !void {
    rig.parser.reset();
    const first_line = rig.nextRecord();
    const first_fr = try rig.parser.feed(first_line, true);
    const first_tape = switch (first_fr) {
        .done => |d| d.tape,
        .need_more => return error.IncompleteRecord,
    };
    var it = try rig.cq.execute(first_tape, &.{}, rig.allocator);
    defer it.deinit();
    _ = try it.next();
    rig.parser.reset();

    var timer = try std.time.Timer.start();
    for (samples) |*slot| {
        const line = rig.nextRecord();
        const fr = try rig.parser.feed(line, true);
        const tape = switch (fr) {
            .done => |d| d.tape,
            .need_more => return error.IncompleteRecord,
        };
        it.reset(tape, &.{});
        timer.reset();
        _ = try it.next();
        slot.* = timer.read();
        rig.parser.reset();
    }
}

/// serialize phase: output.serialize(sink, value, format, …).
/// Buffer is `clearRetainingCapacity`-reset per sample.
fn measureSerialize(rig: *Rig, samples: []u64, format: types.Format) !void {
    // Pre-produce one value to serialize. We re-use the *same* Value every
    // sample so we're timing serialization, not value production.
    rig.parser.reset();
    const line = rig.nextRecord();
    const fr = try rig.parser.feed(line, true);
    const tape = switch (fr) {
        .done => |d| d.tape,
        .need_more => return error.IncompleteRecord,
    };
    var it = try rig.cq.execute(tape, &.{}, rig.allocator);
    defer it.deinit();
    const val = (try it.next()) orelse return error.FilterProducedNothing;

    var sink = output_mod.BufferSink{ .list = &rig.serialize_buf, .aa = rig.allocator };
    const opts = output_mod.SerializeOpts{};

    var timer = try std.time.Timer.start();
    for (samples) |*slot| {
        rig.serialize_buf.clearRetainingCapacity();
        timer.reset();
        try output_mod.serialize(&sink, val, format, null, opts);
        slot.* = timer.read();
    }
}

/// coord phase: full per-record loop exactly as `process_line_serialized`
/// (without the pool's chunk arena / prefilter path). Times
/// parse→lookup→predicate→serialize→reset end-to-end per record.
fn measureCoord(rig: *Rig, samples: []u64, format: types.Format) !void {
    // Establish the persistent iterator using the first record, matching
    // production's "init-once, reset-per-record" model.
    rig.parser.reset();
    const first_line = rig.nextRecord();
    const first_fr = try rig.parser.feed(first_line, true);
    const first_tape = switch (first_fr) {
        .done => |d| d.tape,
        .need_more => return error.IncompleteRecord,
    };
    var it = try rig.cq.execute(first_tape, &.{}, rig.allocator);
    defer it.deinit();
    _ = try it.next();
    rig.parser.reset();

    var sink = output_mod.BufferSink{ .list = &rig.serialize_buf, .aa = rig.allocator };
    const opts = output_mod.SerializeOpts{};

    var timer = try std.time.Timer.start();
    for (samples) |*slot| {
        const line = rig.nextRecord();
        rig.serialize_buf.clearRetainingCapacity();
        timer.reset();
        const fr = try rig.parser.feed(line, true);
        const tape = switch (fr) {
            .done => |d| d.tape,
            .need_more => return error.IncompleteRecord,
        };
        it.reset(tape, &.{});
        while (try it.next()) |v| {
            try output_mod.serialize(&sink, v, format, null, opts);
        }
        rig.parser.reset();
        slot.* = timer.read();
    }
}

// ── NDJSON emitter ────────────────────────────────────────────────────────────

const RunMeta = struct {
    dataset: []const u8,
    record_count: usize,
    filter: []const u8,
    format: types.Format,
    iterations: u32,
    warmup: u32,
    overhead_ns: u64,
    zq_rev: []const u8,
    timestamp_utc: []const u8,
};

fn emitRow(
    w: anytype,
    phase: Phase,
    meta: RunMeta,
    stats: Stats,
) !void {
    // Fields are emitted in the schema-documented order for grep-friendly
    // diffs between runs. Strings are JSON-escaped for `"` and `\`; every
    // field in our fixture set is ASCII so no unicode path is exercised.
    try w.writeAll("{\"schema\":\"zq.microbench.v2\",\"phase\":\"");
    try w.writeAll(phase.name());
    try w.writeAll("\",\"zq_rev\":\"");
    try writeJsonString(w, meta.zq_rev);
    try w.writeAll("\",\"zig_version\":\"");
    try writeJsonString(w, builtin.zig_version_string);
    try w.writeAll("\",\"os\":\"");
    try w.writeAll(@tagName(builtin.os.tag));
    try w.writeAll("\",\"arch\":\"");
    try w.writeAll(@tagName(builtin.cpu.arch));
    try w.writeAll("\",\"cpu_model\":\"");
    try writeJsonString(w, builtin.cpu.model.name);
    try w.writeAll("\",\"dataset\":\"");
    try writeJsonString(w, meta.dataset);
    try w.writeAll("\",\"record_count\":");
    try writeU64(w, meta.record_count);
    try w.writeAll(",\"filter\":\"");
    try writeJsonString(w, meta.filter);
    try w.writeAll("\",\"format\":\"");
    try w.writeAll(@tagName(meta.format));
    try w.writeAll("\",\"iterations\":");
    try writeU64(w, meta.iterations);
    try w.writeAll(",\"warmup\":");
    try writeU64(w, meta.warmup);
    try w.writeAll(",\"overhead_ns\":");
    try writeU64(w, meta.overhead_ns);
    try w.writeAll(",\"ns_mean\":");
    try writeF64(w, stats.mean);
    try w.writeAll(",\"ns_p50\":");
    try writeU64(w, stats.p50);
    try w.writeAll(",\"ns_p90\":");
    try writeU64(w, stats.p90);
    try w.writeAll(",\"ns_p99\":");
    try writeU64(w, stats.p99);
    try w.writeAll(",\"ns_min\":");
    try writeU64(w, stats.min);
    try w.writeAll(",\"ns_max\":");
    try writeU64(w, stats.max);
    try w.writeAll(",\"total_ns\":");
    try writeU64(w, stats.total);
    try w.writeAll(",\"timestamp_utc\":\"");
    try writeJsonString(w, meta.timestamp_utc);
    try w.writeAll("\"}\n");
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                var buf: [6]u8 = undefined;
                const seq = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try w.writeAll(seq);
            },
            else => try w.writeAll(&[_]u8{c}),
        }
    }
}

fn writeU64(w: anytype, v: anytype) !void {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
    try w.writeAll(s);
}

fn writeF64(w: anytype, v: f64) !void {
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d:.2}", .{v});
    try w.writeAll(s);
}

// ── CLI ───────────────────────────────────────────────────────────────────────

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !Config {
    var cfg = Config{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--dataset")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            cfg.dataset = argv[i];
        } else if (std.mem.eql(u8, a, "--inline")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            cfg.inline_record = argv[i];
        } else if (std.mem.eql(u8, a, "--filter")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            cfg.filter = argv[i];
        } else if (std.mem.eql(u8, a, "--iterations")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            cfg.iterations = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--warmup")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            cfg.warmup = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--format")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            if (std.mem.eql(u8, argv[i], "compact")) cfg.format = .compact else if (std.mem.eql(u8, argv[i], "jsonl")) cfg.format = .jsonl else if (std.mem.eql(u8, argv[i], "pretty")) cfg.format = .pretty else if (std.mem.eql(u8, argv[i], "raw")) cfg.format = .raw else return error.InvalidFormat;
        } else if (std.mem.eql(u8, a, "--phases")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            var set = std.EnumSet(Phase).initEmpty();
            var it = std.mem.splitScalar(u8, argv[i], ',');
            while (it.next()) |name| {
                const p = Phase.fromString(std.mem.trim(u8, name, " ")) orelse return error.InvalidPhase;
                set.insert(p);
            }
            cfg.phases = set;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            return error.HelpRequested;
        } else {
            return error.UnknownArg;
        }
    }
    if (cfg.dataset == null and cfg.inline_record == null) {
        return error.NoInput;
    }
    _ = allocator;
    return cfg;
}

fn printHelp() void {
    const msg =
        \\zq microbench — per-stage latency probe
        \\
        \\Usage: zig build microbench -Dprofile=true -- [options]
        \\
        \\Options:
        \\  --dataset <path>        JSONL file; each line is one record
        \\  --inline '<json>'       Single-record smoke fixture (exclusive with --dataset)
        \\  --filter <expr>         Filter source (default: ".id")
        \\  --iterations N          Sample count (default: 10000)
        \\  --warmup N              Warmup iterations (default: 1000)
        \\  --phases parse,lookup,… Subset to run (default: all five)
        \\  --format compact|jsonl|pretty|raw   (default: compact)
        \\  --help, -h              This message
        \\
    ;
    std.fs.File.stderr().writeAll(msg) catch {};
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const cfg = parseArgs(allocator, argv) catch |e| {
        if (e == error.HelpRequested) {
            printHelp();
            return;
        }
        printHelp();
        std.fs.File.stderr().writeAll("\nerror: invalid arguments\n") catch {};
        return e;
    };

    // Load records into memory. `dataset_path` is what ends up in the NDJSON
    // row — either the user-supplied file or the sentinel `<inline>`.
    var owned_data: ?[]u8 = null;
    defer if (owned_data) |d| allocator.free(d);

    var records_list = std.ArrayList([]const u8){};
    defer records_list.deinit(allocator);

    const dataset_path: []const u8 = blk: {
        if (cfg.dataset) |p| {
            const f = try std.fs.cwd().openFile(p, .{});
            defer f.close();
            const data = try f.readToEndAlloc(allocator, 1 << 30);
            owned_data = data;
            var it = std.mem.splitScalar(u8, data, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len > 0) try records_list.append(allocator, trimmed);
            }
            break :blk p;
        } else {
            try records_list.append(allocator, cfg.inline_record.?);
            break :blk "<inline>";
        }
    };

    if (records_list.items.len == 0) {
        std.fs.File.stderr().writeAll("error: dataset produced zero records\n") catch {};
        return error.EmptyDataset;
    }

    // Compile the filter once. A compile error aborts before any measurement.
    const compile_result = try query_mod.CompiledQuery.compile(cfg.filter, .{}, allocator);
    var cq = switch (compile_result) {
        .ok => |c| c,
        .err => |ce| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: filter failed to compile at offset {d}\n", .{ce.offset}) catch "error: filter failed to compile\n";
            std.fs.File.stderr().writeAll(msg) catch {};
            return error.CompileFailed;
        },
    };
    defer cq.deinit();

    // Build measurement rig.
    var rig = try Rig.init(allocator, &cq, records_list.items);
    defer rig.deinit();

    // Counter-overhead calibration: reuse a scratch buffer large enough for
    // the largest configured sample count.
    const sample_buf_len: usize = cfg.iterations;
    const samples = try allocator.alloc(u64, sample_buf_len);
    defer allocator.free(samples);
    const overhead_samples = try allocator.alloc(u64, 1024);
    defer allocator.free(overhead_samples);
    const overhead_ns = try measureOverhead(overhead_samples);

    // Shared run metadata.
    const ts = formatTimestamp(std.time.timestamp());
    const meta = RunMeta{
        .dataset = dataset_path,
        .record_count = records_list.items.len,
        .filter = cfg.filter,
        .format = cfg.format,
        .iterations = cfg.iterations,
        .warmup = cfg.warmup,
        .overhead_ns = overhead_ns,
        .zq_rev = build_options.version,
        .timestamp_utc = ts[0..],
    };

    // Stdout sink — buffered locally so NDJSON rows don't interleave with
    // stderr status. Flushed explicitly at the end.
    var out_buf = std.ArrayList(u8){};
    defer out_buf.deinit(allocator);
    try out_buf.ensureTotalCapacity(allocator, 4096);
    const out_w = BufWriter{ .list = &out_buf, .aa = allocator };

    // Run each requested phase.
    inline for (@typeInfo(Phase).@"enum".fields) |field| {
        const phase: Phase = @enumFromInt(field.value);
        if (cfg.phases.contains(phase)) {
            try runPhase(&rig, phase, cfg, samples, meta, out_w);
        }
    }

    try std.fs.File.stdout().writeAll(out_buf.items);
}

/// ArrayList-backed writer that satisfies the `writeAll` API used by emitRow.
const BufWriter = struct {
    list: *std.ArrayList(u8),
    aa: std.mem.Allocator,
    pub fn writeAll(self: BufWriter, data: []const u8) error{OutOfMemory}!void {
        try self.list.appendSlice(self.aa, data);
    }
};

fn runPhase(
    rig: *Rig,
    phase: Phase,
    cfg: Config,
    samples: []u64,
    meta: RunMeta,
    w: BufWriter,
) !void {
    // Warmup. Reuses the same measurement routine but with a throwaway
    // slice so branch predictors / iterator-stack allocations settle.
    if (cfg.warmup > 0) {
        const warmup_samples = try rig.allocator.alloc(u64, cfg.warmup);
        defer rig.allocator.free(warmup_samples);
        try dispatchMeasure(rig, phase, cfg, warmup_samples);
    }
    // Measurement pass.
    try dispatchMeasure(rig, phase, cfg, samples);
    const stats = summarize(samples, meta.overhead_ns);
    try emitRow(w, phase, meta, stats);
}

fn dispatchMeasure(rig: *Rig, phase: Phase, cfg: Config, samples: []u64) !void {
    switch (phase) {
        .parse => try measureParse(rig, samples),
        .lookup => try measureLookup(rig, samples),
        .predicate => try measurePredicate(rig, samples),
        .serialize => try measureSerialize(rig, samples, cfg.format),
        .coord => try measureCoord(rig, samples, cfg.format),
    }
}

// ── Timestamp helper ──────────────────────────────────────────────────────────

/// Format a Unix timestamp as ISO-8601 UTC seconds (e.g. "2026-04-23T12:00:00Z").
/// Fixed-width buffer so no allocations during the measurement window.
fn formatTimestamp(ts: i64) [20]u8 {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var out: [20]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
    return out;
}
