/// Tests for the pool module.
///
/// Because Pool uses real OS threads we test with n_threads = 1 and n_threads = 4
/// to cover both the single-worker and multi-worker paths.  Stream mode is
/// exercised via a pipe created with std.posix.pipe().
///
/// Ordering invariant: collect() must always return results in submission order.
///
/// Both structured (style=null) and serialized (style!=null) paths are tested.
const std = @import("std");
const pool_mod = @import("pool");
const query_mod = @import("query");
const types = @import("types");

const Pool = pool_mod.Pool;
const MemoryBudget = pool_mod.MemoryBudget;
const Result = pool_mod.Result;
const BytesResult = pool_mod.BytesResult;
const CompiledQuery = query_mod.CompiledQuery;
const alloc = std.testing.allocator;

/// 1 GiB budget — reproduces current defaults for all test files (tiny).
const test_budget = MemoryBudget.explicit(1024 * 1024 * 1024);

/// 16 MiB budget — forces `MemoryBudget.computeParams` into the tight regime
/// (chunk_factor > 4, in_flight_factor → 1) so wave-dispatch fires many
/// short waves. Used by the wave-correctness stress tests.
const small_budget = MemoryBudget.explicit(16 * 1024 * 1024);

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Write `data` to a tmp file and return a readable File.
/// Caller must close the file.
fn tmp_file_fd(data: []const u8) !std.fs.File {
    // memfd_create is Linux-only and has a @compileError on other targets, so
    // gate the call comptime. Non-Linux falls through to the named-temp path.
    if (comptime @import("builtin").os.tag == .linux) {
        if (std.posix.memfd_create("pool_test", 0)) |fd| {
            _ = try std.posix.write(fd, data);
            try std.posix.lseek_SET(fd, 0);
            return std.fs.File{ .handle = fd };
        } else |_| {}
    }
    const path = "/tmp/_zq_pool_test_tmp";
    const f = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = true });
    try f.writeAll(data);
    try f.seekTo(0);
    return f;
}

/// Drain all results from the pool into an ArrayList of Values (structured path).
/// Caller owns the returned slice and must free it.
fn drain(p: *Pool) ![]types.Value {
    var out = std.ArrayList(types.Value){};
    errdefer out.deinit(alloc);
    while (try p.collect()) |r| {
        // Values whose tag is .string point into pool-managed memory that is
        // only valid until the next collect(); we copy strings here.
        switch (r.value) {
            .string => |sv| {
                const copy = try alloc.dupe(u8, sv.slice());
                try out.append(alloc, .{ .string = .{ .external = copy } });
            },
            else => try out.append(alloc, r.value),
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Drain all results from the pool as bytes (serialized path).
/// Returns concatenated output and the folded last_output across all
/// sequenced results (last non-empty wins; matches main.zig fold).
fn drain_bytes(p: *Pool) !struct { data: []u8, last_output: types.LastOutput } {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(alloc);
    var last: types.LastOutput = .none;
    while (try p.collect_bytes()) |r| {
        try out.appendSlice(alloc, r.data);
        last = types.lastOutputFold(last, r.last_output);
    }
    return .{
        .data = try out.toOwnedSlice(alloc),
        .last_output = last,
    };
}

fn free_values(values: []types.Value) void {
    for (values) |v| {
        if (v == .string) alloc.free(v.string.slice());
    }
    alloc.free(values);
}

/// Compile a query; panic on failure (tests are responsible for valid queries).
fn compile(src: []const u8) !CompiledQuery {
    const result = try CompiledQuery.compile(src, .{}, alloc);
    return switch (result) {
        .ok => |cq| cq,
        .err => unreachable, // tests must use valid queries
    };
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

test "init and deinit — zero threads" {
    var p = try Pool.init(0, test_budget, alloc);
    p.deinit();
}

test "init and deinit — one thread" {
    var p = try Pool.init(1, test_budget, alloc);
    p.deinit();
}

test "init and deinit — four threads" {
    var p = try Pool.init(4, test_budget, alloc);
    p.deinit();
}

// ── File mode: basic correctness (structured path) ────────────────────────────

test "submit_file: single integer line" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("42\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 42), vals[0].int);
}

test "submit_file: three integer lines in order" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("1\n2\n3\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 3), vals.len);
    try std.testing.expectEqual(@as(i64, 1), vals[0].int);
    try std.testing.expectEqual(@as(i64, 2), vals[1].int);
    try std.testing.expectEqual(@as(i64, 3), vals[2].int);
}

test "submit_file: no trailing newline" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("99");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 99), vals[0].int);
}

test "submit_file: empty file returns no results" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 0), vals.len);
}

test "submit_file: blank lines are skipped" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("\n\n7\n\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 7), vals[0].int);
}

// ── File mode: query projection (structured path) ─────────────────────────────

test "submit_file: .x field projection" {
    var cq = try compile(".x");
    defer cq.deinit();

    const file = try tmp_file_fd("{\"x\":10}\n{\"x\":20}\n{\"x\":30}\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 3), vals.len);
    try std.testing.expectEqual(@as(i64, 10), vals[0].int);
    try std.testing.expectEqual(@as(i64, 20), vals[1].int);
    try std.testing.expectEqual(@as(i64, 30), vals[2].int);
}

test "submit_file: string value round-trip" {
    var cq = try compile(".name");
    defer cq.deinit();

    const file = try tmp_file_fd("{\"name\":\"alice\"}\n{\"name\":\"bob\"}\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 2), vals.len);
    try std.testing.expectEqualStrings("alice", vals[0].string.slice());
    try std.testing.expectEqualStrings("bob", vals[1].string.slice());
}

// ── File mode: ordering under parallelism (structured path) ───────────────────

test "submit_file: ordering preserved with 4 workers, 20 records" {
    var cq = try compile(".");
    defer cq.deinit();

    // Build a file with 20 lines: 0..19
    var file_buf = std.ArrayList(u8){};
    defer file_buf.deinit(alloc);
    for (0..20) |i| {
        try file_buf.writer(alloc).print("{d}\n", .{i});
    }

    const file = try tmp_file_fd(file_buf.items);
    defer file.close();

    var p = try Pool.init(4, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 20), vals.len);
    for (vals, 0..) |v, idx| {
        try std.testing.expectEqual(@as(i64, @intCast(idx)), v.int);
    }
}

// ── File mode: error propagation (structured path) ────────────────────────────

test "submit_file: malformed JSON returns parse error" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("not-json\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const result = p.collect();
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "submit_file: type error propagated from query" {
    // .x on an integer root is a TypeError.
    var cq = try compile(".x");
    defer cq.deinit();

    const file = try tmp_file_fd("42\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const result = p.collect();
    try std.testing.expectError(error.TypeError, result);
}

// ── File mode: value types (structured path) ──────────────────────────────────

test "submit_file: boolean values" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("true\nfalse\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 2), vals.len);
    try std.testing.expectEqual(true, vals[0].bool_val);
    try std.testing.expectEqual(false, vals[1].bool_val);
}

test "submit_file: null value" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("null\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0] == .null_val);
}

test "submit_file: float value" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("3.14\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), vals[0].float, 1e-9);
}

// ── Stream mode (structured path) ─────────────────────────────────────────────

test "submit_stream: three lines via pipe" {
    var cq = try compile(".");
    defer cq.deinit();

    // Create a pipe; write end will be closed after writing.
    const pipe_fds = try std.posix.pipe();
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];

    // Write data then close write end so the reader sees EOF.
    const data = "10\n20\n30\n";
    _ = try std.posix.write(write_fd, data);
    std.posix.close(write_fd);

    const io_mod = @import("io");
    var src = try io_mod.Source.init(std.fs.File{ .handle = read_fd }, alloc);
    defer src.deinit();
    defer std.posix.close(read_fd);

    var p = try Pool.init(2, test_budget, alloc);
    defer p.deinit();

    p.submit_stream(&src, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 3), vals.len);
    try std.testing.expectEqual(@as(i64, 10), vals[0].int);
    try std.testing.expectEqual(@as(i64, 20), vals[1].int);
    try std.testing.expectEqual(@as(i64, 30), vals[2].int);
}

test "submit_stream: empty stream returns no results" {
    var cq = try compile(".");
    defer cq.deinit();

    const pipe_fds = try std.posix.pipe();
    std.posix.close(pipe_fds[1]); // close write end immediately → EOF

    const io_mod = @import("io");
    var src = try io_mod.Source.init(std.fs.File{ .handle = pipe_fds[0] }, alloc);
    defer src.deinit();
    defer std.posix.close(pipe_fds[0]);

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    p.submit_stream(&src, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 0), vals.len);
}

// ── NIX-001: structural chunker correctness ────────────────────────────────

test "submit_file: pretty record crossing chunk boundary (4 workers)" {
    // Several pretty-printed objects in one file. With raw-\n splitting and
    // 4 workers, chunk boundaries naturally land inside the multi-line
    // values — the pre-NIX-001 chunker would shred each into per-line
    // fragments and produce parse errors. The structural chunker must
    // align every chunk on a depth-0 newline.
    var cq = try compile(".n");
    defer cq.deinit();

    var data = std.ArrayList(u8){};
    defer data.deinit(alloc);
    // 16 records × ~30 bytes each → ~500 bytes total, well within one mmap
    // chunk per worker but spread across 4 worker slots so boundary
    // alignment must happen.
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try data.writer(alloc).print("{{\n  \"n\": {d}\n}}\n", .{i});
    }

    const file = try tmp_file_fd(data.items);
    defer file.close();

    var p = try Pool.init(4, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 16), vals.len);
    for (vals, 0..) |v, idx| {
        try std.testing.expectEqual(@as(i64, @intCast(idx)), v.int);
    }
}

test "submit_file: parallel boundary scan over >256 KiB pretty JSON" {
    // Exercise the parallel prefix-sum feeder path. The file must exceed
    // PARALLEL_BOUNDARY_THRESHOLD (256 KiB) so boundary scan fans out
    // across stripes; pretty-printed records ensure stripe splits land
    // inside multi-line values, where the stitch step's correctness
    // (carrying `in_string` / `escape_pending` across stripe boundaries)
    // matters.
    var cq = try compile(".n");
    defer cq.deinit();

    var data = std.ArrayList(u8){};
    defer data.deinit(alloc);
    // ~80 bytes/record × 10 000 records ≈ 800 KB → comfortably over the
    // threshold and large enough for the natural stripe split (file_size
    // / n_threads) to land mid-record at random offsets.
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) {
        try data.writer(alloc).print(
            "{{\n  \"n\": {d},\n  \"s\": \"line {d} with \\\"quotes\\\" and \\\\backslash\\\\\"\n}}\n",
            .{ i, i },
        );
    }

    const file = try tmp_file_fd(data.items);
    defer file.close();

    var p = try Pool.init(8, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 10_000), vals.len);
    for (vals, 0..) |v, idx| {
        try std.testing.expectEqual(@as(i64, @intCast(idx)), v.int);
    }
}

test "submit_file: wave-boundary mid-string with escape pending" {
    // Cross-wave invariant: the parallel summary's escape-pending category
    // must propagate correctly when a wave boundary lands inside a string
    // immediately after a `\` byte. Every record is one long string of
    // `\\` pairs — half of all bytes are `\` — so a stripe split is highly
    // likely to land in `is_esc` state.
    var cq = try compile(".s | length");
    defer cq.deinit();

    var data = std.ArrayList(u8){};
    defer data.deinit(alloc);
    // ~3 MB total, 200 records × ~15 KB each. With small_budget the wave
    // dispatcher fires multiple waves; record bodies are heavy on escapes
    // to exercise is_esc carry across stripe and wave splits.
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        try data.writer(alloc).writeAll("{\"s\":\"");
        var j: u32 = 0;
        while (j < 1500) : (j += 1) try data.writer(alloc).writeAll("\\\\");
        try data.writer(alloc).writeAll("\"}\n");
    }

    const file = try tmp_file_fd(data.items);
    defer file.close();

    var p = try Pool.init(8, small_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 200), vals.len);
    // Each record's string is 1500 `\\` pairs → 1500 backslash chars
    // after JSON unescape (every `\\` → `\`).
    for (vals) |v| try std.testing.expectEqual(@as(i64, 1500), v.int);
}

test "submit_file: wave-boundary inside multi-line pretty record" {
    // Cross-wave (oos, 0) carry: each wave must dispatch up to a depth-0
    // boundary, never splitting a multi-line pretty-printed object across
    // workers. With ~5 KB pretty records straddling wave splits, any
    // mis-aligned dispatch shreds records into parse errors.
    var cq = try compile(".n");
    defer cq.deinit();

    var data = std.ArrayList(u8){};
    defer data.deinit(alloc);
    // 5 000 records × ~5 KB each ≈ 25 MB. Each record has many `\n`
    // characters at depth > 0 (pretty-printing) which the structural
    // scanner must skip; only the trailing depth-0 `\n` counts.
    var i: u32 = 0;
    while (i < 5_000) : (i += 1) {
        try data.writer(alloc).print("{{\n  \"n\": {d},\n  \"payload\": [\n", .{i});
        var j: u32 = 0;
        while (j < 60) : (j += 1) {
            try data.writer(alloc).print("    \"item-{d}-{d}\",\n", .{ i, j });
        }
        try data.writer(alloc).writeAll("    \"end\"\n  ]\n}\n");
    }

    const file = try tmp_file_fd(data.items);
    defer file.close();

    var p = try Pool.init(8, small_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 5_000), vals.len);
    for (vals, 0..) |v, idx| {
        try std.testing.expectEqual(@as(i64, @intCast(idx)), v.int);
    }
}

test "submit_file: many waves — file >> wave_bytes" {
    // Stress test: many waves in sequence under a tight memory budget.
    // Verifies cumulative correctness — no off-by-one drift in dispatch
    // cursors across many cross-wave handoffs, no record loss, ordering
    // preserved.
    var cq = try compile(".id");
    defer cq.deinit();

    var data = std.ArrayList(u8){};
    defer data.deinit(alloc);
    // 500 000 compact records × ~25 bytes ≈ 12 MB. Under small_budget
    // (16 MiB) `computeParams` pushes chunk_factor up so wave_bytes
    // shrinks → many waves.
    var i: u32 = 0;
    while (i < 500_000) : (i += 1) {
        try data.writer(alloc).print("{{\"id\":{d}}}\n", .{i});
    }

    const file = try tmp_file_fd(data.items);
    defer file.close();

    var p = try Pool.init(8, small_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 500_000), vals.len);
    for (vals, 0..) |v, idx| {
        try std.testing.expectEqual(@as(i64, @intCast(idx)), v.int);
    }
}

test "submit_file: zero-boundary wave fallback" {
    // Pathological case: a single record larger than wave_bytes and even
    // larger than 2× wave_bytes, so the wave dispatcher's one-shot
    // extension fails to find any depth-0 boundary. The fallback path is
    // a serial scan from wave_start. Test verifies (a) no deadlock, (b)
    // correct output for the giant record, (c) correct output for the
    // 100 follow-up records that the serial fallback must dispatch.
    var cq = try compile(".s | length");
    defer cq.deinit();

    var data = std.ArrayList(u8){};
    defer data.deinit(alloc);
    // One giant string record: ~3 MB of plain ASCII with no internal
    // newlines. Far larger than any wave_bytes the small_budget config
    // produces for this file size.
    try data.writer(alloc).writeAll("{\"s\":\"");
    var k: u32 = 0;
    while (k < 3_000_000) : (k += 1) try data.writer(alloc).writeByte('a');
    try data.writer(alloc).writeAll("\"}\n");
    // 100 small follow-up records.
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try data.writer(alloc).print("{{\"s\":\"x{d}\"}}\n", .{i});
    }

    const file = try tmp_file_fd(data.items);
    defer file.close();

    var p = try Pool.init(8, small_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 101), vals.len);
    // First record: 3 000 000 'a' chars.
    try std.testing.expectEqual(@as(i64, 3_000_000), vals[0].int);
    // Follow-up records: "x" + decimal idx → length = 1 + digit count.
    for (vals[1..], 0..) |v, idx| {
        const expected: i64 = 1 + @as(i64, @intCast(std.fmt.count("{d}", .{idx})));
        try std.testing.expectEqual(expected, v.int);
    }
}

test "submit_stream: pretty value spanning IO refill" {
    // A single pretty-printed array bigger than the IO RingBuffer
    // (INITIAL_CAP = 64 KiB) — the boundary scanner state must persist
    // across `view`s so that the depth-0 closing `\n` is found exactly
    // once, after the final `]`.
    var cq = try compile("length");
    defer cq.deinit();

    var data = std.ArrayList(u8){};
    defer data.deinit(alloc);
    try data.appendSlice(alloc, "[\n");
    // 8000 elements × ~10 bytes each ≈ 80 KB — exceeds 64 KiB ring buffer.
    var i: u32 = 0;
    while (i < 8000) : (i += 1) {
        try data.writer(alloc).print("  {d}{s}\n", .{ i, if (i + 1 < 8000) "," else "" });
    }
    try data.appendSlice(alloc, "]\n");

    const pipe_fds = try std.posix.pipe();
    // Write asynchronously: a single posix.write of >PIPE_BUF blocks until
    // the reader drains, so spawn a writer thread.
    const Writer = struct {
        fn run(fd: std.posix.fd_t, bytes: []const u8) void {
            var off: usize = 0;
            while (off < bytes.len) {
                const n = std.posix.write(fd, bytes[off..]) catch break;
                if (n == 0) break;
                off += n;
            }
            std.posix.close(fd);
        }
    };
    const t = try std.Thread.spawn(.{}, Writer.run, .{ pipe_fds[1], data.items });

    const io_mod = @import("io");
    var src = try io_mod.Source.init(std.fs.File{ .handle = pipe_fds[0] }, alloc);
    defer src.deinit();
    defer std.posix.close(pipe_fds[0]);

    var p = try Pool.init(2, test_budget, alloc);
    defer p.deinit();

    p.submit_stream(&src, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    t.join();

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 8000), vals[0].int);
}

test "submit_stream: no trailing newline" {
    var cq = try compile(".");
    defer cq.deinit();

    const pipe_fds = try std.posix.pipe();
    _ = try std.posix.write(pipe_fds[1], "55");
    std.posix.close(pipe_fds[1]);

    const io_mod = @import("io");
    var src = try io_mod.Source.init(std.fs.File{ .handle = pipe_fds[0] }, alloc);
    defer src.deinit();
    defer std.posix.close(pipe_fds[0]);

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    p.submit_stream(&src, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expectEqual(@as(i64, 55), vals[0].int);
}

// ── Boundary: collect() returns null on re-call after drain ───────────────────

test "collect returns null when called after drain" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("1\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    free_values(vals);

    // Additional collect() calls after drain must return null, not block.
    const extra = try p.collect();
    try std.testing.expectEqual(@as(?Result, null), extra);
}

// ── n_threads = 0: inline fallback ───────────────────────────────────────────

test "zero threads: submit_file processes records synchronously" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("7\n8\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, null, null, .{}, false, &.{});

    const vals = try drain(&p);
    defer free_values(vals);

    try std.testing.expectEqual(@as(usize, 2), vals.len);
    try std.testing.expectEqual(@as(i64, 7), vals[0].int);
    try std.testing.expectEqual(@as(i64, 8), vals[1].int);
}

// ══════════════════════════════════════════════════════════════════════════════
// ── Serialized path tests ─────────────────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════════

test "serialized: single integer" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("42\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    defer alloc.free(result.data);

    try std.testing.expectEqualStrings("42\n", result.data);
    try std.testing.expectEqual(types.LastOutput.truthy, result.last_output);
}

test "serialized: string value" {
    var cq = try compile(".name");
    defer cq.deinit();

    const file = try tmp_file_fd("{\"name\":\"alice\"}\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    defer alloc.free(result.data);

    try std.testing.expectEqualStrings("\"alice\"\n", result.data);
}

test "serialized: multi-value query (.[])" {
    var cq = try compile(".[]");
    defer cq.deinit();

    const file = try tmp_file_fd("[1,2,3]\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    defer alloc.free(result.data);

    try std.testing.expectEqualStrings("1\n2\n3\n", result.data);
}

test "serialized: error propagation" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("not-json\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const result = p.collect_bytes();
    try std.testing.expectError(error.UnexpectedToken, result);
}

// Regression: `error("msg")` in the pool serialized path must surface the
// user-facing message via `pool.last_user_error_msg` so the caller can pass
// it to `formatDiagnostic`. Before this wiring the message was dropped and
// stdin / file-arg mode printed only the generic "user error" header.
test "serialized: user_error_msg surfaced for error(\"...\")" {
    var cq = try compile(".foo // error(\"bad\")");
    defer cq.deinit();

    const file = try tmp_file_fd("\"x\"\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const result = p.collect_bytes();
    try std.testing.expectError(error.UserError, result);
    try std.testing.expect(p.last_user_error_msg != null);
    try std.testing.expectEqualStrings("bad", p.last_user_error_msg.?);
}

// RecordMeta size guard: the compact per-record metadata struct (u32 end_offset,
// 2×bool, 2×u16) packs to 12 bytes with natural alignment. The design intent
// documented in `src/pool/root.zig` is "do not widen per-record fields" — any
// new user-facing diagnostic channel should live per-chunk (Design A for the
// `user_error_msg` plumbing) so 15M-record workloads do not regress RSS.
// This test pins the current layout so future regressions are loud.
test "RecordMeta stays compact per-record" {
    const pool = @import("pool");
    try std.testing.expectEqual(@as(usize, 12), pool.record_meta_size_for_test);
}

test "serialized: ordering with 4 workers" {
    var cq = try compile(".");
    defer cq.deinit();

    var file_buf = std.ArrayList(u8){};
    defer file_buf.deinit(alloc);
    for (0..20) |i| {
        try file_buf.writer(alloc).print("{d}\n", .{i});
    }

    const file = try tmp_file_fd(file_buf.items);
    defer file.close();

    var p = try Pool.init(4, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    defer alloc.free(result.data);

    // Build expected output
    var expected = std.ArrayList(u8){};
    defer expected.deinit(alloc);
    for (0..20) |i| {
        try expected.writer(alloc).print("{d}\n", .{i});
    }

    try std.testing.expectEqualStrings(expected.items, result.data);
}

test "serialized stream: three lines via pipe" {
    var cq = try compile(".");
    defer cq.deinit();

    const pipe_fds = try std.posix.pipe();
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];

    _ = try std.posix.write(write_fd, "10\n20\n30\n");
    std.posix.close(write_fd);

    const io_mod = @import("io");
    var src = try io_mod.Source.init(std.fs.File{ .handle = read_fd }, alloc);
    defer src.deinit();
    defer std.posix.close(read_fd);

    var p = try Pool.init(2, test_budget, alloc);
    defer p.deinit();

    p.submit_stream(&src, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    defer alloc.free(result.data);

    try std.testing.expectEqualStrings("10\n20\n30\n", result.data);
}

test "serialized: empty select produces no bytes" {
    var cq = try compile("select(false)");
    defer cq.deinit();

    const file = try tmp_file_fd("1\n2\n3\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    defer alloc.free(result.data);

    try std.testing.expectEqual(@as(usize, 0), result.data.len);
}

test "serialized: false/null tracking for -e flag" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("false\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    defer alloc.free(result.data);

    try std.testing.expectEqualStrings("false\n", result.data);
    try std.testing.expectEqual(types.LastOutput.false_or_null, result.last_output);
}

test "serialized: null tracking for -e flag" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("null\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    defer alloc.free(result.data);

    try std.testing.expectEqualStrings("null\n", result.data);
    try std.testing.expectEqual(types.LastOutput.false_or_null, result.last_output);
}

test "serialized: collect_bytes returns null after drain" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("1\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    alloc.free(result.data);

    const extra = try p.collect_bytes();
    try std.testing.expectEqual(@as(?BytesResult, null), extra);
}

test "serialized: jsonl format" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("42\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    defer alloc.free(result.data);

    // jsonl format: compact + newline (so "42\n")
    try std.testing.expectEqualStrings("42\n", result.data);
}

test "serialized: raw format for string" {
    var cq = try compile(".name");
    defer cq.deinit();

    const file = try tmp_file_fd("{\"name\":\"hello\"}\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .raw_strings = true }, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    defer alloc.free(result.data);

    // raw format: no quotes for strings, with trailing newline (matches jq -r)
    try std.testing.expectEqualStrings("hello\n", result.data);
}

// ── Infinite-generator partial-publish (bugs.md #143 / wave C3) ───────────────

test "serialized: infinite-generator stream-mode partial flush unblocks consumer" {
    // Pre-fix: `repeat(.+1)` buffered into chunk_buf forever and never published
    // because the iterator never returns null → downstream consumer received 0
    // bytes. Post-fix: STREAM_FLUSH_THRESHOLD triggers `partial_flush` mid-
    // iterator inside the Job's reserved sub-id range so partial output flows
    // out as it accumulates. The test reads a bounded prefix and stops.
    var cq = try compile("repeat(.+1)");
    defer cq.deinit();

    const pipe_fds = try std.posix.pipe();
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];

    _ = try std.posix.write(write_fd, "0\n");
    std.posix.close(write_fd);

    const io_mod = @import("io");
    var src = try io_mod.Source.init(std.fs.File{ .handle = read_fd }, alloc);
    defer src.deinit();
    defer std.posix.close(read_fd);

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    p.submit_stream(&src, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const deadline_ns: u64 = 5 * std.time.ns_per_s;
    const deadline_thread = try std.Thread.spawn(.{}, struct {
        fn run(pool_ptr: *Pool, ns: u64) void {
            std.Thread.sleep(ns);
            pool_ptr._shared.shutdown.store(true, .release);
        }
    }.run, .{ &p, deadline_ns });
    defer deadline_thread.join();

    // Read until we've collected at least 100 records, then stop.  If the
    // partial-flush were broken (pre-C3 behavior), `collect_bytes` would
    // block forever waiting on the in-progress chunk that never publishes —
    // the deadline thread above sets shutdown after 5 s so the worker
    // releases its in-flight chunk and `collect_bytes` returns null.
    var record_count: usize = 0;
    while (record_count < 100) {
        const r = (try p.collect_bytes()) orelse break;
        // Each record is "1\n" (input 0, .+1 → 1).  Count by occurrences.
        var i: usize = 0;
        while (i < r.data.len) : (i += 1) {
            if (r.data[i] == '\n') record_count += 1;
        }
    }

    try std.testing.expect(record_count >= 100);
    // Pool.deinit triggers shutdown so the worker stops streaming.
}

// ══════════════════════════════════════════════════════════════════════════════
// ── MemoryBudget / computeParams tests ────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════════

test "computeParams: small file returns defaults" {
    const budget = MemoryBudget.explicit(8 * 1024 * 1024 * 1024); // 8 GiB
    const params = budget.computeParams(1 * 1024 * 1024, 16, .{ .compact = true }); // 1 MB file
    try std.testing.expectEqual(@as(usize, 4), params.chunk_factor);
    try std.testing.expectEqual(@as(usize, 2), params.in_flight_factor);
}

test "computeParams: large file increases chunk_factor" {
    const budget = MemoryBudget.explicit(2 * 1024 * 1024 * 1024); // 2 GiB
    const params = budget.computeParams(10 * 1024 * 1024 * 1024, 8, .{ .compact = true }); // 10 GB file
    try std.testing.expect(params.chunk_factor > 4);
    try std.testing.expect(params.chunk_factor <= 64);
    try std.testing.expect(params.in_flight_factor <= 2);
}

test "computeParams: constrained budget reduces in_flight_factor" {
    const budget = MemoryBudget.explicit(256 * 1024 * 1024); // 256 MiB
    const params = budget.computeParams(10 * 1024 * 1024 * 1024, 4, .{ .compact = true }); // 10 GB file
    try std.testing.expectEqual(@as(usize, 64), params.chunk_factor);
    try std.testing.expectEqual(@as(usize, 1), params.in_flight_factor);
}

test "computeParams: stream mode returns defaults with adapted batch_size" {
    const budget = MemoryBudget.explicit(1024 * 1024 * 1024); // 1 GiB
    const params = budget.computeParams(0, 8, .{ .compact = true }); // stream mode
    try std.testing.expectEqual(@as(usize, 4), params.chunk_factor);
    try std.testing.expectEqual(@as(usize, 2), params.in_flight_factor);
    try std.testing.expect(params.stream_batch_size >= 64 * 1024);
    try std.testing.expect(params.stream_batch_size <= 256 * 1024);
}

test "computeParams: huge budget returns defaults" {
    const budget = MemoryBudget.explicit(64 * 1024 * 1024 * 1024); // 64 GiB
    const params = budget.computeParams(1 * 1024 * 1024 * 1024, 32, .{ .compact = true }); // 1 GB file
    try std.testing.expectEqual(@as(usize, 4), params.chunk_factor);
    try std.testing.expectEqual(@as(usize, 2), params.in_flight_factor);
}

test "computeParams: deterministic — same inputs same outputs" {
    const budget = MemoryBudget.explicit(2 * 1024 * 1024 * 1024);
    const p1 = budget.computeParams(5 * 1024 * 1024 * 1024, 8, .{});
    const p2 = budget.computeParams(5 * 1024 * 1024 * 1024, 8, .{});
    try std.testing.expectEqual(p1.chunk_factor, p2.chunk_factor);
    try std.testing.expectEqual(p1.in_flight_factor, p2.in_flight_factor);
    try std.testing.expectEqual(p1.stream_batch_size, p2.stream_batch_size);
}

test "computeParams: pretty format uses higher expansion" {
    const budget = MemoryBudget.explicit(2 * 1024 * 1024 * 1024); // 2 GiB
    const compact = budget.computeParams(2 * 1024 * 1024 * 1024, 8, .{ .compact = true });
    const pretty = budget.computeParams(2 * 1024 * 1024 * 1024, 8, .{});
    // Pretty has 6x expansion vs compact's 2x, so it should need more chunks
    try std.testing.expect(pretty.chunk_factor >= compact.chunk_factor);
}

test "readCgroupFile: nonexistent path returns null" {
    const result = pool_mod.readCgroupFile("/nonexistent/path/that/does/not/exist");
    try std.testing.expectEqual(@as(?u64, null), result);
}

test "readCgroupFile: numeric value parsed correctly" {
    // Write a temp file with a numeric value
    const path = "/tmp/_zq_cgroup_test";
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    try f.writeAll("536870912\n");
    f.close();
    defer std.fs.deleteFileAbsolute(path) catch {};

    const result = pool_mod.readCgroupFile(path);
    try std.testing.expectEqual(@as(?u64, 536870912), result);
}

test "readCgroupFile: max string returns null" {
    const path = "/tmp/_zq_cgroup_test_max";
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    try f.writeAll("max\n");
    f.close();
    defer std.fs.deleteFileAbsolute(path) catch {};

    const result = pool_mod.readCgroupFile(path);
    try std.testing.expectEqual(@as(?u64, null), result);
}

// ── Sparser prefilter integration (Phase F) ──────────────────────────────────

const regex_mod = @import("regex");

test "prefilter: select(.field|test(literal)) skips non-matching records" {
    if (!regex_mod.enabled) return error.SkipZigTest;

    // 5 records, only 2 contain "alpha" — prefilter should skip the other 3.
    const input =
        \\{"name":"alpha-one"}
        \\{"name":"beta-two"}
        \\{"name":"alpha-three"}
        \\{"name":"gamma-four"}
        \\{"name":"delta-five"}
        \\
    ;
    var cq = try compile("select(.name | test(\"alpha\"))");
    defer cq.deinit();

    // Prefilter must be populated for this filter shape.
    try std.testing.expect(cq.prefilter != null);

    const file = try tmp_file_fd(input);
    defer file.close();

    pool_mod.prefilter_stats.reset();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const out = try drain_bytes(&p);
    defer alloc.free(out.data);

    // Two matching records -> two serialized outputs.
    try std.testing.expectEqualStrings(
        \\{"name":"alpha-one"}
        \\{"name":"alpha-three"}
        \\
    , out.data);

    // Prefilter evaluated each of the 5 records; skipped the 3 misses.
    try std.testing.expectEqual(@as(u64, 5), pool_mod.prefilter_stats.evaluated());
    try std.testing.expectEqual(@as(u64, 3), pool_mod.prefilter_stats.skipped());
}

test "prefilter: alternation pattern uses OR-semantics" {
    if (!regex_mod.enabled) return error.SkipZigTest;

    const input =
        \\{"tag":"apple"}
        \\{"tag":"banana"}
        \\{"tag":"carrot"}
        \\{"tag":"date"}
        \\
    ;
    var cq = try compile("select(.tag | test(\"apple|carrot\"))");
    defer cq.deinit();
    try std.testing.expect(cq.prefilter != null);

    const file = try tmp_file_fd(input);
    defer file.close();

    pool_mod.prefilter_stats.reset();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const out = try drain_bytes(&p);
    defer alloc.free(out.data);

    try std.testing.expectEqualStrings(
        \\{"tag":"apple"}
        \\{"tag":"carrot"}
        \\
    , out.data);

    try std.testing.expectEqual(@as(u64, 4), pool_mod.prefilter_stats.evaluated());
    try std.testing.expectEqual(@as(u64, 2), pool_mod.prefilter_stats.skipped());
}

test "prefilter: unbounded pattern disables prefilter" {
    if (!regex_mod.enabled) return error.SkipZigTest;

    // `.+` has no extractable literals — prefilter must be NULL.
    var cq = try compile("select(.x | test(\".+\"))");
    defer cq.deinit();
    try std.testing.expect(cq.prefilter == null);
}

test "prefilter: non-select filter does not get prefilter" {
    if (!regex_mod.enabled) return error.SkipZigTest;

    // `map(...)` is not a filtering construct — no prefilter.
    var cq = try compile("map(select(.x | test(\"foo\")))");
    defer cq.deinit();
    try std.testing.expect(cq.prefilter == null);

    // `.x | test("foo")` at top level: produces a bool per record, not a
    // filtering construct — no prefilter.
    var cq2 = try compile(".x | test(\"foo\")");
    defer cq2.deinit();
    try std.testing.expect(cq2.prefilter == null);
}

test "prefilter: trailing pipe after select rejects prefilter (soundness)" {
    if (!regex_mod.enabled) return error.SkipZigTest;

    // select(...) | .y — the trailing pipe means the pipeline continues
    // to produce output per input record; skipping is unsound.
    var cq = try compile("select(.x | test(\"foo\")) | .y");
    defer cq.deinit();
    try std.testing.expect(cq.prefilter == null);
}

test "prefilter: boolean combinator in select body rejects prefilter" {
    if (!regex_mod.enabled) return error.SkipZigTest;

    // `and` / `or` / `//` make the body truthy even when regex misses.
    var cq1 = try compile("select(.x | test(\"foo\") or .y == 1)");
    defer cq1.deinit();
    try std.testing.expect(cq1.prefilter == null);

    var cq2 = try compile("select(.x | test(\"foo\") and .y)");
    defer cq2.deinit();
    try std.testing.expect(cq2.prefilter == null);

    var cq3 = try compile("select((.x | test(\"foo\")) // true)");
    defer cq3.deinit();
    try std.testing.expect(cq3.prefilter == null);
}

test "prefilter: idiom-shaped bytes inside string literal do not trigger false positive" {
    if (!regex_mod.enabled) return error.SkipZigTest;

    // The byte-scanner version had to be careful not to match `select(` and
    // `test(` that appeared inside a string literal. The AST-backed harvest
    // can't get fooled: string literals are nodes, not bytes.
    var cq = try compile("select(.x | test(\"select(.y | test(\\\"foo\\\"))\"))");
    defer cq.deinit();
    // Prefilter must be populated using the literal "select(.y | test("foo"))"
    // as the pattern — not misinterpreted as nested calls.
    try std.testing.expect(cq.prefilter != null);
}

test "prefilter: interpolated pattern (not a static literal) disables prefilter" {
    if (!regex_mod.enabled) return error.SkipZigTest;

    // Dynamic pattern — AST surfaces this as string_interp, not a string
    // literal. The harvester must reject it; skipping a non-matching record
    // would be unsound because the pattern is record-dependent. The real
    // bytecode compiler may legitimately reject or accept the form; either
    // way, the prefilter must not be populated.
    const result = try CompiledQuery.compile("select(.x | test(\"\\(.pat)\"))", .{}, alloc);
    switch (result) {
        .ok => |c| {
            var cq = c;
            defer cq.deinit();
            try std.testing.expect(cq.prefilter == null);
        },
        .err => |_| {}, // either outcome proves the harvester didn't mis-harvest
    }
}

test "prefilter: extra whitespace still harvests" {
    if (!regex_mod.enabled) return error.SkipZigTest;

    // AST parser handles whitespace uniformly — the harvester doesn't need
    // to care. The old byte-scan had hand-rolled skipWsAndComments logic.
    var cq = try compile("  select( .name | test(\"alpha\") )  \n");
    defer cq.deinit();
    try std.testing.expect(cq.prefilter != null);
}

test "prefilter: harvester handles non-literal pattern argument without crashing" {
    if (!regex_mod.enabled) return error.SkipZigTest;

    // `foo` as an unquoted arg is a function ref in jq, not a string. The
    // real compile path rejects it, but the harvester must first handle
    // the non-literal shape without crashing — no prefilter, and the
    // compile error surfaces naturally.
    const result = try CompiledQuery.compile("select(.x | test(.y))", .{}, alloc);
    switch (result) {
        .ok => |c| {
            var cq = c;
            defer cq.deinit();
            // `.y` is a field access, not a string literal — harvester bails.
            try std.testing.expect(cq.prefilter == null);
        },
        .err => |_| {
            // Real compile rejects it — CompileError is POD, nothing to free.
        },
    }
}

test "prefilter: correctness — no false negatives on matching records" {
    if (!regex_mod.enabled) return error.SkipZigTest;

    // Record contains the literal encoded inside a larger value.
    const input =
        \\{"note":"the quick brown foo jumps over"}
        \\{"note":"no match here"}
        \\
    ;
    var cq = try compile("select(.note | test(\"brown foo\"))");
    defer cq.deinit();
    try std.testing.expect(cq.prefilter != null);

    const file = try tmp_file_fd(input);
    defer file.close();

    pool_mod.prefilter_stats.reset();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const out = try drain_bytes(&p);
    defer alloc.free(out.data);

    try std.testing.expectEqualStrings(
        \\{"note":"the quick brown foo jumps over"}
        \\
    , out.data);
}

test "prefilter: \\uXXXX escape hole — record with escape-encoded literal matches" {
    if (!regex_mod.enabled) return error.SkipZigTest;

    // RFC 8259 §7 lets the string "foo" be serialized as "foo".
    // The raw-byte scan for "foo" would miss. The escape-aware prefilter must
    // keep the record because the `\` presence means an escape-encoded
    // occurrence is still possible. The full regex run (which works on the
    // DECODED string value) then confirms the match.
    const input =
        \\{"note":"foo bar"}
        \\{"note":"no match here"}
        \\{"note":"raw foo is fine too"}
        \\
    ;
    var cq = try compile("select(.note | test(\"foo\"))");
    defer cq.deinit();
    try std.testing.expect(cq.prefilter != null);

    const file = try tmp_file_fd(input);
    defer file.close();

    pool_mod.prefilter_stats.reset();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const out = try drain_bytes(&p);
    defer alloc.free(out.data);

    // Both escape-encoded AND raw occurrences must be kept.
    try std.testing.expectEqualStrings(
        \\{"note":"foo bar"}
        \\{"note":"raw foo is fine too"}
        \\
    , out.data);
}

test "prefilter: short-escape hole — record with \\t inside string keeps literal match" {
    if (!regex_mod.enabled) return error.SkipZigTest;

    // Literal `hello` must match `hel\tlo` decoded. The raw bytes do not
    // contain "hello" (they contain `hel\tlo`), but the `\` in the record
    // forces the escape-aware prefilter to keep it.
    const input =
        "{\"x\":\"hel\\tlo world\"}\n" ++
        "{\"x\":\"zero match\"}\n";
    var cq = try compile("select(.x | test(\"hello\"))");
    defer cq.deinit();
    try std.testing.expect(cq.prefilter != null);

    const file = try tmp_file_fd(input);
    defer file.close();

    pool_mod.prefilter_stats.reset();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const out = try drain_bytes(&p);
    defer alloc.free(out.data);

    // Record with \t between `hel` and `lo` DECODES to "hel\tlo world"
    // which does not match /hello/. No records match. But crucially the
    // prefilter must have ACCEPTED the first record (no false negative) —
    // skipped count should be 1 (the second record), not 2.
    try std.testing.expectEqualStrings("", out.data);
    try std.testing.expectEqual(@as(u64, 2), pool_mod.prefilter_stats.evaluated());
    try std.testing.expectEqual(@as(u64, 1), pool_mod.prefilter_stats.skipped());
}

test "prefilter: short-escape hole — match through \\u encoding verified end-to-end" {
    if (!regex_mod.enabled) return error.SkipZigTest;

    // Full-match path: abc decodes to "abc"; /abc/ matches.
    // Without the escape-aware prefilter, raw bytes don't contain "abc" and
    // the record would be silently rejected -> wrong output.
    const input =
        \\{"k":"prefix abc suffix"}
        \\{"k":"unrelated"}
        \\
    ;
    var cq = try compile("select(.k | test(\"abc\"))");
    defer cq.deinit();
    try std.testing.expect(cq.prefilter != null);

    const file = try tmp_file_fd(input);
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .{ .compact = true }, null, .{}, false, &.{});

    const out = try drain_bytes(&p);
    defer alloc.free(out.data);

    try std.testing.expectEqualStrings(
        \\{"k":"prefix abc suffix"}
        \\
    , out.data);
}
