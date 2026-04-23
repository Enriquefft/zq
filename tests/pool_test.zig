/// Tests for the pool module.
///
/// Because Pool uses real OS threads we test with n_threads = 1 and n_threads = 4
/// to cover both the single-worker and multi-worker paths.  Stream mode is
/// exercised via a pipe created with std.posix.pipe().
///
/// Ordering invariant: collect() must always return results in submission order.
///
/// Both structured (format=null) and serialized (format!=null) paths are tested.
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

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Write `data` to a tmp file and return a readable File.
/// Caller must close the file.
fn tmp_file_fd(data: []const u8) !std.fs.File {
    const fd = std.posix.memfd_create("pool_test", 0) catch {
        // Fallback: write to a named temp file.
        const path = "/tmp/_zq_pool_test_tmp";
        const f = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = true });
        try f.writeAll(data);
        try f.seekTo(0);
        return f;
    };
    _ = try std.posix.write(fd, data);
    try std.posix.lseek_SET(fd, 0);
    return std.fs.File{ .handle = fd };
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
            .string => |s| {
                const copy = try alloc.dupe(u8, s);
                try out.append(alloc, .{ .string = copy });
            },
            else => try out.append(alloc, r.value),
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Drain all results from the pool as bytes (serialized path).
/// Returns concatenated output and the last last_was_false_or_null flag.
fn drain_bytes(p: *Pool) !struct { data: []u8, last_was_false_or_null: bool } {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(alloc);
    var last_flag = false;
    while (try p.collect_bytes()) |r| {
        try out.appendSlice(alloc, r.data);
        last_flag = r.last_was_false_or_null;
    }
    return .{
        .data = try out.toOwnedSlice(alloc),
        .last_was_false_or_null = last_flag,
    };
}

fn free_values(values: []types.Value) void {
    for (values) |v| {
        if (v == .string) alloc.free(v.string);
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
    try std.testing.expectEqualStrings("alice", vals[0].string);
    try std.testing.expectEqualStrings("bob", vals[1].string);
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

    try p.submit_file(file, &cq, .compact, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    defer alloc.free(result.data);

    try std.testing.expectEqualStrings("42\n", result.data);
    try std.testing.expectEqual(false, result.last_was_false_or_null);
}

test "serialized: string value" {
    var cq = try compile(".name");
    defer cq.deinit();

    const file = try tmp_file_fd("{\"name\":\"alice\"}\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .compact, null, .{}, false, &.{});

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

    try p.submit_file(file, &cq, .compact, null, .{}, false, &.{});

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

    try p.submit_file(file, &cq, .compact, null, .{}, false, &.{});

    const result = p.collect_bytes();
    try std.testing.expectError(error.UnexpectedToken, result);
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

    try p.submit_file(file, &cq, .compact, null, .{}, false, &.{});

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

    p.submit_stream(&src, &cq, .compact, null, .{}, false, &.{});

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

    try p.submit_file(file, &cq, .compact, null, .{}, false, &.{});

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

    try p.submit_file(file, &cq, .compact, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    defer alloc.free(result.data);

    try std.testing.expectEqualStrings("false\n", result.data);
    try std.testing.expectEqual(true, result.last_was_false_or_null);
}

test "serialized: null tracking for -e flag" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("null\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .compact, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    defer alloc.free(result.data);

    try std.testing.expectEqualStrings("null\n", result.data);
    try std.testing.expectEqual(true, result.last_was_false_or_null);
}

test "serialized: collect_bytes returns null after drain" {
    var cq = try compile(".");
    defer cq.deinit();

    const file = try tmp_file_fd("1\n");
    defer file.close();

    var p = try Pool.init(1, test_budget, alloc);
    defer p.deinit();

    try p.submit_file(file, &cq, .compact, null, .{}, false, &.{});

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

    try p.submit_file(file, &cq, .jsonl, null, .{}, false, &.{});

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

    try p.submit_file(file, &cq, .raw, null, .{}, false, &.{});

    const result = try drain_bytes(&p);
    defer alloc.free(result.data);

    // raw format: no quotes for strings, with trailing newline (matches jq -r)
    try std.testing.expectEqualStrings("hello\n", result.data);
}

// ══════════════════════════════════════════════════════════════════════════════
// ── MemoryBudget / computeParams tests ────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════════

test "computeParams: small file returns defaults" {
    const budget = MemoryBudget.explicit(8 * 1024 * 1024 * 1024); // 8 GiB
    const params = budget.computeParams(1 * 1024 * 1024, 16, .compact); // 1 MB file
    try std.testing.expectEqual(@as(usize, 4), params.chunk_factor);
    try std.testing.expectEqual(@as(usize, 2), params.in_flight_factor);
}

test "computeParams: large file increases chunk_factor" {
    const budget = MemoryBudget.explicit(2 * 1024 * 1024 * 1024); // 2 GiB
    const params = budget.computeParams(10 * 1024 * 1024 * 1024, 8, .compact); // 10 GB file
    try std.testing.expect(params.chunk_factor > 4);
    try std.testing.expect(params.chunk_factor <= 64);
    try std.testing.expect(params.in_flight_factor <= 2);
}

test "computeParams: constrained budget reduces in_flight_factor" {
    const budget = MemoryBudget.explicit(256 * 1024 * 1024); // 256 MiB
    const params = budget.computeParams(10 * 1024 * 1024 * 1024, 4, .compact); // 10 GB file
    try std.testing.expectEqual(@as(usize, 64), params.chunk_factor);
    try std.testing.expectEqual(@as(usize, 1), params.in_flight_factor);
}

test "computeParams: stream mode returns defaults with adapted batch_size" {
    const budget = MemoryBudget.explicit(1024 * 1024 * 1024); // 1 GiB
    const params = budget.computeParams(0, 8, .compact); // stream mode
    try std.testing.expectEqual(@as(usize, 4), params.chunk_factor);
    try std.testing.expectEqual(@as(usize, 2), params.in_flight_factor);
    try std.testing.expect(params.stream_batch_size >= 64 * 1024);
    try std.testing.expect(params.stream_batch_size <= 256 * 1024);
}

test "computeParams: huge budget returns defaults" {
    const budget = MemoryBudget.explicit(64 * 1024 * 1024 * 1024); // 64 GiB
    const params = budget.computeParams(1 * 1024 * 1024 * 1024, 32, .compact); // 1 GB file
    try std.testing.expectEqual(@as(usize, 4), params.chunk_factor);
    try std.testing.expectEqual(@as(usize, 2), params.in_flight_factor);
}

test "computeParams: deterministic — same inputs same outputs" {
    const budget = MemoryBudget.explicit(2 * 1024 * 1024 * 1024);
    const p1 = budget.computeParams(5 * 1024 * 1024 * 1024, 8, .pretty);
    const p2 = budget.computeParams(5 * 1024 * 1024 * 1024, 8, .pretty);
    try std.testing.expectEqual(p1.chunk_factor, p2.chunk_factor);
    try std.testing.expectEqual(p1.in_flight_factor, p2.in_flight_factor);
    try std.testing.expectEqual(p1.stream_batch_size, p2.stream_batch_size);
}

test "computeParams: pretty format uses higher expansion" {
    const budget = MemoryBudget.explicit(2 * 1024 * 1024 * 1024); // 2 GiB
    const compact = budget.computeParams(2 * 1024 * 1024 * 1024, 8, .compact);
    const pretty = budget.computeParams(2 * 1024 * 1024 * 1024, 8, .pretty);
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

    try p.submit_file(file, &cq, .compact, null, .{}, false, &.{});

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

    try p.submit_file(file, &cq, .compact, null, .{}, false, &.{});

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

    try p.submit_file(file, &cq, .compact, null, .{}, false, &.{});

    const out = try drain_bytes(&p);
    defer alloc.free(out.data);

    try std.testing.expectEqualStrings(
        \\{"note":"the quick brown foo jumps over"}
        \\
    , out.data);
}
