//! Property test for the projection-plan + pure-predicate-pushdown path
//! introduced in Commit 1.
//!
//! Invariant under test: for every random pure-scalar selective query
//! the harvester accepts, the parallel zq pipeline (in-process Pool,
//! threads ∈ {1, 2, 4, 8}) must produce byte-identical output to the
//! serial jq oracle. The in-process Pool variant exercises the actual
//! production code path (`feedPlanned`'s top-of-record evaluator) — no
//! subprocess, no CLI mediation — so a bleed-through bug or a chunk-
//! seam ordering defect surfaces here as a stdout diff against jq.
//!
//! Why this test exists. The byte-identity-vs-master invariant on the
//! no-plan parse loop was walked back to a runtime ratio gate (see
//! `benchmarks/scenarios/06_narrow_records.sh`). That moves the load-
//! bearing assertion for the *plan-aware* path here: any record that
//! the harvester drops at the parser boundary in the default build but
//! that jq emits is a false negative; any record the harvester keeps
//! that jq drops is a false positive. Both classes are caught by the
//! byte-eq assertion below.
//!
//! Coverage targets, named explicitly:
//!
//!   1. Random `id`-keyed JSONL × random pure-scalar comparison
//!      `select(.id OP N) | <projection>`. OP rotates over
//!      eq/ne/lt/le/gt/ge so the harvester's `PredicateOp` mapping is
//!      exercised at all six points; the literal is drawn from a small
//!      table of integers the generator hits with non-trivial
//!      probability (forcing both kept and dropped records in the same
//!      chunk).
//!
//!   2. The "dropped-then-kept-on-same-chunk" bleed-through case.
//!      This is the regression risk specific to predicate pushdown:
//!      `feedPlanned` must restore the parser's tape pointers between
//!      records inside one chunk so a record that fails the predicate
//!      cannot leak any tape slots into the next record's evaluation
//!      window. We construct inputs whose record-id sequence is
//!      `drop, drop, drop, ..., keep` and the inverse, then run them
//!      at every supported thread count.
//!
//!   3. Threads {1, 2, 4, 8}. Single-thread is the simplest schedule
//!      (no chunk boundaries cross records). Multi-thread schedules
//!      introduce mid-record chunk seams that the boundary scanner
//!      must split safely while preserving submission-order delivery.
//!      All four counts must produce identical bytes.
//!
//! Determinism. The test uses a fixed seed and a fixed iteration
//! count. A divergence prints `seed=N iter=K` so a single failure can
//! be reproduced with `ZQ_PROJ_SEED=N ZQ_PROJ_ITERS=K+1`. Subprocess
//! infrastructure (jq) is shared with `fuzz_common.zig`.

const std = @import("std");
const fc = @import("fuzz_common.zig");
const pool_mod = @import("pool");
const query_mod = @import("query");
const types = @import("types");

const Pool = pool_mod.Pool;
const MemoryBudget = pool_mod.MemoryBudget;
const CompiledQuery = query_mod.CompiledQuery;

const default_iterations: u32 = 200;
const default_seed: u64 = 0;

const THREADS = [_]usize{ 1, 2, 4, 8 };

// 1 GiB pool budget — matches `tests/pool_test.zig`. Big enough that the
// budget never trips for the bounded inputs we generate, so divergences
// are query-correctness bugs not memory-pressure spills.
const TEST_BUDGET = MemoryBudget.explicit(1024 * 1024 * 1024);

// ── Generators ────────────────────────────────────────────────────────────────
//
// Two complementary generators sit behind the harness:
//
//   * `genJsonl`  — emits a sequence of `{"id": N, "k": "<word>", ...}`
//                   records. The `id` distribution is uniform over a
//                   small range so any threshold drawn from the same
//                   range partitions the input non-trivially. The
//                   record count is also drawn so very-short and
//                   chunk-spanning inputs both occur.
//   * `genQuery`  — emits a `select(.id OP N) | <projection>` filter
//                   that the harvester accepts. `<projection>` is one
//                   of `.`, `.id`, or `.name`, all of which produce
//                   well-typed jq output regardless of which records
//                   pass the predicate.
//
// Both consume the same RNG so seed/iter pairs reproduce both halves.

const KEY_DICT = [_][]const u8{ "alice", "bob", "carol", "dave", "eve" };
const ID_RANGE: u32 = 50; // ids drawn from 0..50 (inclusive low, exclusive high)

// Literals chosen to hit the ID range non-trivially. `0` and `49` cause
// degenerate true/false predicates under some operators (forcing the
// drop-everything and keep-everything code paths); the middle values
// force mixed-pass partitions.
const LITERALS = [_]i32{ 0, 1, 10, 25, 40, 49 };

const OPS = [_][]const u8{ "==", "!=", "<", "<=", ">", ">=" };
const PROJECTIONS = [_][]const u8{ ".", ".id", ".name" };

const MIN_RECORDS: u32 = 1;
const MAX_RECORDS: u32 = 80;

/// Generate a JSONL byte stream. Returns owned bytes; caller frees.
/// Each record is `{"id":N,"name":"<word>"}` with N drawn uniformly
/// from [0, ID_RANGE). The integer `id` is the only field the
/// harvester's predicate touches, so all randomness in the records
/// outside `.id` is incidental coverage.
fn genJsonl(rng: std.Random, alloc: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(alloc);

    const n = rng.intRangeAtMost(u32, MIN_RECORDS, MAX_RECORDS);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const id = rng.uintLessThan(u32, ID_RANGE);
        const name = KEY_DICT[rng.uintLessThan(usize, KEY_DICT.len)];
        try buf.writer(alloc).print("{{\"id\":{d},\"name\":\"{s}\"}}\n", .{ id, name });
    }
    return buf.toOwnedSlice(alloc);
}

/// Generate the bleed-through stress shape: a long run of records that
/// will FAIL the predicate followed by a single record that will PASS,
/// then a single record that will FAIL after the kept one. This is the
/// dropped-then-kept-on-same-chunk class — a `feedPlanned` that fails
/// to reset its tape window between records leaks the dropped tail
/// into the kept record's evaluator and produces a wrong answer.
///
/// `op`/`literal` parameterize the predicate the caller will run over
/// this input; we shape the records so the predicate splits them as
/// described regardless of which OP is in play. Implementation: for
/// every OP we can construct a "pass" id and a "fail" id by picking
/// values relative to the literal (eq/ne use literal; lt/le/gt/ge
/// pick endpoints).
fn genBleedThrough(
    rng: std.Random,
    alloc: std.mem.Allocator,
    op: []const u8,
    literal: i32,
) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(alloc);

    const pass_id: i32 = passingIdFor(op, literal);
    const fail_id: i32 = failingIdFor(op, literal);

    // Length parameter: enough records to cross at least one chunk
    // seam at sane budget settings, but bounded so the test stays
    // fast. The exact value isn't load-bearing — the failure mode
    // (tape bleed) is shape-dependent, not size-dependent.
    const head_len: u32 = rng.intRangeAtMost(u32, 8, 32);
    const tail_len: u32 = rng.intRangeAtMost(u32, 1, 8);

    // Run of failing records.
    var i: u32 = 0;
    while (i < head_len) : (i += 1) {
        try buf.writer(alloc).print("{{\"id\":{d},\"name\":\"x\"}}\n", .{fail_id});
    }
    // Single passing record.
    try buf.writer(alloc).print("{{\"id\":{d},\"name\":\"hit\"}}\n", .{pass_id});
    // Run of failing records after the kept one.
    i = 0;
    while (i < tail_len) : (i += 1) {
        try buf.writer(alloc).print("{{\"id\":{d},\"name\":\"y\"}}\n", .{fail_id});
    }
    return buf.toOwnedSlice(alloc);
}

/// Pick an `id` that passes `select(.id OP literal)`. The harness
/// asserts this by construction; if the predicate is unsatisfiable
/// over the int domain we fall back to a value that passes for the
/// largest fraction of OPs. For the OPs in play this is always
/// satisfiable — `eq` passes at `literal`, the rest pass at one
/// endpoint of the i32 range we draw from.
fn passingIdFor(op: []const u8, literal: i32) i32 {
    if (std.mem.eql(u8, op, "==")) return literal;
    if (std.mem.eql(u8, op, "!=")) return literal +% 1;
    if (std.mem.eql(u8, op, "<")) return literal - 1;
    if (std.mem.eql(u8, op, "<=")) return literal;
    if (std.mem.eql(u8, op, ">")) return literal + 1;
    if (std.mem.eql(u8, op, ">=")) return literal;
    unreachable;
}

/// Symmetric counterpart of `passingIdFor` — pick an id that fails
/// `select(.id OP literal)`. Used by the bleed-through generator.
fn failingIdFor(op: []const u8, literal: i32) i32 {
    if (std.mem.eql(u8, op, "==")) return literal +% 1;
    if (std.mem.eql(u8, op, "!=")) return literal;
    if (std.mem.eql(u8, op, "<")) return literal;
    if (std.mem.eql(u8, op, "<=")) return literal + 1;
    if (std.mem.eql(u8, op, ">")) return literal;
    if (std.mem.eql(u8, op, ">=")) return literal - 1;
    unreachable;
}

/// Generate a `select(.id OP N) | <projection>` filter the harvester
/// accepts. Owned bytes; caller frees.
fn genQuery(rng: std.Random, alloc: std.mem.Allocator) !struct {
    src: []u8,
    op: []const u8,
    literal: i32,
} {
    const op = OPS[rng.uintLessThan(usize, OPS.len)];
    const literal = LITERALS[rng.uintLessThan(usize, LITERALS.len)];
    const projection = PROJECTIONS[rng.uintLessThan(usize, PROJECTIONS.len)];

    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(alloc);
    try buf.writer(alloc).print("select(.id {s} {d}) | {s}", .{ op, literal, projection });
    return .{
        .src = try buf.toOwnedSlice(alloc),
        .op = op,
        .literal = literal,
    };
}

// ── Pool harness ──────────────────────────────────────────────────────────────

/// Run `cq` against `input` through the in-process Pool with `n_threads`
/// workers. Returns owned stdout bytes (compact serialized output, the
/// shape `jq -c` produces — byte-comparable to the oracle).
///
/// memfd_create on Linux gives us a filesystem-free way to feed bytes
/// into `submit_file`, matching `tests/pool_test.zig`. Non-Linux falls
/// back to a per-PID temp file.
fn runZqPool(
    alloc: std.mem.Allocator,
    cq: *const CompiledQuery,
    input: []const u8,
    n_threads: usize,
) ![]u8 {
    const file = try tmpFileFd(input);
    defer file.close();

    var p = try Pool.init(n_threads, TEST_BUDGET, alloc);
    defer p.deinit();

    try p.submit_file(file, cq, .{ .compact = true }, null, .{}, false, &.{});

    var out = std.ArrayList(u8){};
    errdefer out.deinit(alloc);
    while (try p.collect_bytes()) |r| {
        try out.appendSlice(alloc, r.data);
    }
    // jq -c trims its trailing newline in `runJqStdin`; strip ours
    // symmetrically so the byte-eq assertion compares like-with-like.
    var slice = try out.toOwnedSlice(alloc);
    if (slice.len > 0 and slice[slice.len - 1] == '\n') {
        const trimmed = try alloc.dupe(u8, slice[0 .. slice.len - 1]);
        alloc.free(slice);
        slice = trimmed;
    }
    return slice;
}

fn tmpFileFd(data: []const u8) !std.fs.File {
    if (comptime @import("builtin").os.tag == .linux) {
        if (std.posix.memfd_create("zq_proj_property", 0)) |fd| {
            _ = try std.posix.write(fd, data);
            try std.posix.lseek_SET(fd, 0);
            return std.fs.File{ .handle = fd };
        } else |_| {}
    }
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buf,
        "/tmp/zq_proj_property_{d}.json",
        .{fc.currentPid()},
    );
    const f = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = true });
    try f.writeAll(data);
    try f.seekTo(0);
    return f;
}

fn compileQuery(src: []const u8) !CompiledQuery {
    const result = try CompiledQuery.compile(src, .{}, std.testing.allocator);
    return switch (result) {
        .ok => |cq| cq,
        .err => unreachable, // generator must produce valid filters
    };
}

// ── Diff helper ───────────────────────────────────────────────────────────────

/// Compare zq's pool output to jq's subprocess output. Returns null on
/// match, an owned diagnostic string on mismatch (caller frees with the
/// same allocator). The diagnostic includes both outputs trimmed so the
/// failure trace is compact but actionable.
fn diffOrNull(
    alloc: std.mem.Allocator,
    label: []const u8,
    jq_stdout: []const u8,
    zq_stdout: []const u8,
) !?[]u8 {
    if (std.mem.eql(u8, jq_stdout, zq_stdout)) return null;
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(alloc);
    try buf.writer(alloc).print(
        "[{s}] zq != jq\n  jq=<<<{s}>>>\n  zq=<<<{s}>>>",
        .{ label, jq_stdout, zq_stdout },
    );
    return try buf.toOwnedSlice(alloc);
}

fn parseIters() u32 {
    const env = std.posix.getenv("ZQ_PROJ_ITERS") orelse return default_iterations;
    return std.fmt.parseInt(u32, env, 10) catch default_iterations;
}

fn parseSeed() u64 {
    const env = std.posix.getenv("ZQ_PROJ_SEED") orelse return default_seed;
    return std.fmt.parseInt(u64, env, 10) catch default_seed;
}

// ── Test entry: random selective queries × random JSONL × thread sweep ────────

test "projection property: random pure-scalar select matches jq across thread counts" {
    const alloc = std.testing.allocator;
    try fc.requireJqOnPath(alloc);

    const n: u32 = parseIters();
    const seed: u64 = parseSeed();

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var checked: u32 = 0;
    var iter: u32 = 0;
    while (iter < n) : (iter += 1) {
        const q = try genQuery(rng, alloc);
        defer alloc.free(q.src);
        const input = try genJsonl(rng, alloc);
        defer alloc.free(input);

        var jq = try fc.runJqStdin(alloc, q.src, input);
        defer jq.deinit(alloc);

        // jq's exit is non-zero only on parse/compile error, which the
        // generator avoids by construction. If it ever happens, surface
        // it loudly — the generator has a bug.
        if (jq.exit_code != 0) {
            std.debug.print(
                "jq rejected harness-generated filter at seed={d} iter={d}: filter={s}\n",
                .{ seed, iter, q.src },
            );
            return error.GeneratorEmittedInvalidFilter;
        }

        var cq = try compileQuery(q.src);
        defer cq.deinit();

        for (THREADS) |nt| {
            const zq_out = try runZqPool(alloc, &cq, input, nt);
            defer alloc.free(zq_out);

            var label_buf: [32]u8 = undefined;
            const label = try std.fmt.bufPrint(&label_buf, "threads={d}", .{nt});

            if (try diffOrNull(alloc, label, jq.stdout, zq_out)) |diag| {
                defer alloc.free(diag);
                std.debug.print(
                    \\projection property FAIL at seed={d} iter={d}
                    \\  filter: {s}
                    \\  input ({d} bytes): {s}
                    \\  diff: {s}
                    \\  reproduce: ZQ_PROJ_SEED={d} ZQ_PROJ_ITERS={d}
                    \\
                ,
                    .{ seed, iter, q.src, input.len, input, diag, seed, iter + 1 },
                );
                return error.ProjectionDivergence;
            }
            checked += 1;
        }
    }

    // Vacuous-pass guard. Every iteration must have run all four
    // thread counts; if `checked` doesn't equal `n * 4`, something
    // short-circuited and the harness is reporting nothing.
    try std.testing.expectEqual(@as(u32, n) * @as(u32, THREADS.len), checked);
}

// ── Test entry: bleed-through stress (drop, ..., drop, keep, drop, ..., drop)

test "projection property: bleed-through stress matches jq across thread counts" {
    const alloc = std.testing.allocator;
    try fc.requireJqOnPath(alloc);

    const seed: u64 = parseSeed() ^ 0xb1eedfeed;
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    // One sweep over every (op, literal, projection) the harvester
    // accepts. This is small (6 × 6 × 3 = 108) and exhaustive — every
    // accepted predicate shape gets at least one bleed-through trial.
    var checked: u32 = 0;
    for (OPS) |op| {
        for (LITERALS) |literal| {
            for (PROJECTIONS) |proj| {
                var fbuf = std.ArrayList(u8){};
                defer fbuf.deinit(alloc);
                try fbuf.writer(alloc).print(
                    "select(.id {s} {d}) | {s}",
                    .{ op, literal, proj },
                );
                const filter = fbuf.items;

                const input = try genBleedThrough(rng, alloc, op, literal);
                defer alloc.free(input);

                var jq = try fc.runJqStdin(alloc, filter, input);
                defer jq.deinit(alloc);
                if (jq.exit_code != 0) {
                    std.debug.print(
                        "jq rejected bleed-through filter: {s}\n",
                        .{filter},
                    );
                    return error.GeneratorEmittedInvalidFilter;
                }

                var cq = try compileQuery(filter);
                defer cq.deinit();

                for (THREADS) |nt| {
                    const zq_out = try runZqPool(alloc, &cq, input, nt);
                    defer alloc.free(zq_out);

                    var label_buf: [48]u8 = undefined;
                    const label = try std.fmt.bufPrint(
                        &label_buf,
                        "bleed op={s} lit={d} threads={d}",
                        .{ op, literal, nt },
                    );

                    if (try diffOrNull(alloc, label, jq.stdout, zq_out)) |diag| {
                        defer alloc.free(diag);
                        std.debug.print(
                            \\bleed-through FAIL
                            \\  filter: {s}
                            \\  input ({d} bytes): {s}
                            \\  diff: {s}
                            \\
                        ,
                            .{ filter, input.len, input, diag },
                        );
                        return error.ProjectionDivergence;
                    }
                    checked += 1;
                }
            }
        }
    }

    // 6 ops × 6 literals × 3 projections × 4 thread counts = 432 cases.
    try std.testing.expectEqual(@as(u32, 6 * 6 * 3 * 4), checked);
}
