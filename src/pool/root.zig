/// Worker Pool — parallel JSONL processing with in-order result delivery.
///
/// Two modes:
///   File mode:   submit_file splits the file on newline boundaries and hands
///                byte-range chunks to worker threads.
///   Stream mode: submit_stream starts an IO thread that reads complete lines
///                from a Source and posts them to worker threads.
///
/// In both modes the Sequencer reorders results so collect() returns them in
/// submission order regardless of which worker finishes first.

const std = @import("std");
const err_mod = @import("error");
const io_mod = @import("io");
const parser_mod = @import("parser");
const query_mod = @import("query");
const types = @import("types");

pub const ZqError = err_mod.ZqError;

// ── Result ────────────────────────────────────────────────────────────────────

/// One output record returned by collect().
/// `value.string` (when tag is `.string`) points into pool-managed memory that
/// is valid only until the next collect() or deinit() call.
pub const Result = struct {
    value: types.Value,
};

// ── Internal job type ─────────────────────────────────────────────────────────

/// A unit of work placed in the job queue.
const Job = struct {
    /// Monotonically increasing sequence number assigned at submission time.
    seq: u64,
    /// The record bytes to parse (owned by the job; freed after processing).
    data: []u8,
    /// The compiled query to execute — shared read-only across threads.
    query: *const query_mod.CompiledQuery,
    allocator: std.mem.Allocator,
};

// ── WorkerResult ──────────────────────────────────────────────────────────────

/// The outcome of processing one Job — posted to the Sequencer by workers.
const WorkerResult = struct {
    seq: u64,
    outcome: Outcome,

    const Outcome = union(enum) {
        /// Successfully produced values.  Each OwnedValue has copied any string
        /// bytes so it survives after the worker's Parser is reset.
        values: []OwnedValue,
        /// The record produced a ZqError.
        err: ZqError,
    };
};

/// A Value whose content has been copied into owned memory so it survives
/// beyond the worker Parser reset.
const OwnedValue = union(enum) {
    null_val,
    bool_val: bool,
    int: i64,
    float: f64,
    /// Owned copy of a string slice.
    string: []u8,
    /// Compact JSON serialisation of an object span.
    object_json: []u8,
    /// Compact JSON serialisation of an array span.
    array_json: []u8,

    fn deinit(self: *OwnedValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .object_json => |j| allocator.free(j),
            .array_json => |j| allocator.free(j),
            else => {},
        }
    }
};

fn free_owned_values(values: []OwnedValue, allocator: std.mem.Allocator) void {
    for (values) |*v| v.deinit(allocator);
    allocator.free(values);
}

// ── Thread-safe bounded MPMC job queue ────────────────────────────────────────

const JobQueue = struct {
    mutex: std.Thread.Mutex,
    not_empty: std.Thread.Condition,
    not_full: std.Thread.Condition,
    buf: []?Job,
    head: usize,
    tail: usize,
    count: usize,
    shutdown: bool,
    allocator: std.mem.Allocator,

    fn init(cap: usize, allocator: std.mem.Allocator) error{OutOfMemory}!JobQueue {
        const buf = try allocator.alloc(?Job, cap);
        @memset(buf, null);
        return .{
            .mutex = .{},
            .not_empty = .{},
            .not_full = .{},
            .buf = buf,
            .head = 0,
            .tail = 0,
            .count = 0,
            .shutdown = false,
            .allocator = allocator,
        };
    }

    fn deinit(q: *JobQueue) void {
        // Free any jobs still in the queue (e.g. after early shutdown).
        var i = q.head;
        var c = q.count;
        while (c > 0) : (c -= 1) {
            if (q.buf[i]) |job| job.allocator.free(job.data);
            i = (i + 1) % q.buf.len;
        }
        q.allocator.free(q.buf);
    }

    /// Push a job. Blocks when queue is full. Returns immediately if shutdown.
    fn push(q: *JobQueue, job: Job) void {
        q.mutex.lock();
        defer q.mutex.unlock();
        while (q.count == q.buf.len and !q.shutdown) {
            q.not_full.wait(&q.mutex);
        }
        if (q.shutdown) {
            job.allocator.free(job.data);
            return;
        }
        q.buf[q.tail] = job;
        q.tail = (q.tail + 1) % q.buf.len;
        q.count += 1;
        q.not_empty.signal();
    }

    /// Pop a job. Blocks when queue is empty. Returns null when empty + shutdown.
    fn pop(q: *JobQueue) ?Job {
        q.mutex.lock();
        defer q.mutex.unlock();
        while (q.count == 0 and !q.shutdown) {
            q.not_empty.wait(&q.mutex);
        }
        if (q.count == 0) return null; // shutdown with empty queue
        const job = q.buf[q.head].?;
        q.buf[q.head] = null;
        q.head = (q.head + 1) % q.buf.len;
        q.count -= 1;
        q.not_full.signal();
        return job;
    }

    /// Signal that no more jobs will be pushed. Unblocks all waiting pop() calls.
    fn signal_done(q: *JobQueue) void {
        q.mutex.lock();
        defer q.mutex.unlock();
        q.shutdown = true;
        q.not_empty.broadcast();
        q.not_full.broadcast();
    }
};

// ── Sequencer — reorder buffer for in-order delivery ──────────────────────────

const Sequencer = struct {
    mutex: std.Thread.Mutex,
    available: std.Thread.Condition,
    pending: std.AutoHashMap(u64, WorkerResult),
    /// The sequence number collect() is waiting for next.
    next_seq: u64,
    /// Total records submitted; null until all submissions are done.
    total: ?u64,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Sequencer {
        return .{
            .mutex = .{},
            .available = .{},
            .pending = std.AutoHashMap(u64, WorkerResult).init(allocator),
            .next_seq = 0,
            .total = null,
            .allocator = allocator,
        };
    }

    fn deinit(s: *Sequencer) void {
        var it = s.pending.valueIterator();
        while (it.next()) |wr| {
            if (wr.outcome == .values) free_owned_values(wr.outcome.values, s.allocator);
        }
        s.pending.deinit();
    }

    /// Called by worker threads — may arrive out of order.
    fn post(s: *Sequencer, result: WorkerResult) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        s.pending.put(result.seq, result) catch {
            // OOM: convert to an IoError so collect() surfaces it.
            var r = result;
            if (r.outcome == .values) {
                free_owned_values(r.outcome.values, s.allocator);
                r.outcome = .{ .err = error.IoError };
            }
            s.pending.put(result.seq, r) catch {};
        };
        s.available.signal();
    }

    /// Called once, after the last job has been pushed.
    fn set_total(s: *Sequencer, total: u64) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        s.total = total;
        s.available.broadcast();
    }

    /// Blocking — return the next in-sequence WorkerResult, or null when done.
    fn next_in_order(s: *Sequencer) ?WorkerResult {
        s.mutex.lock();
        defer s.mutex.unlock();
        while (true) {
            if (s.total) |tot| {
                if (s.next_seq >= tot) return null;
            }
            if (s.pending.getPtr(s.next_seq)) |wr| {
                const result = wr.*;
                _ = s.pending.remove(s.next_seq);
                s.next_seq += 1;
                return result;
            }
            s.available.wait(&s.mutex);
        }
    }
};

// ── Worker thread ─────────────────────────────────────────────────────────────

const WorkerCtx = struct {
    queue: *JobQueue,
    sequencer: *Sequencer,
    allocator: std.mem.Allocator,
};

fn worker_fn(ctx: WorkerCtx) void {
    // Each worker owns its own Parser instance.
    var parser = parser_mod.Parser.init(ctx.allocator) catch {
        while (ctx.queue.pop()) |job| job.allocator.free(job.data);
        return;
    };
    defer parser.deinit();

    while (ctx.queue.pop()) |job| {
        defer job.allocator.free(job.data);
        const outcome = process_record(&parser, job.query, job.data, ctx.allocator);
        ctx.sequencer.post(.{ .seq = job.seq, .outcome = outcome });
    }
}

/// Parse `data`, execute the query, and return a WorkerResult Outcome.
fn process_record(
    parser: *parser_mod.Parser,
    cq: *const query_mod.CompiledQuery,
    data: []const u8,
    allocator: std.mem.Allocator,
) WorkerResult.Outcome {
    defer parser.reset();

    // parser.feed returns (ZqError || error{OutOfMemory})!FeedResult.
    // We map OutOfMemory to IoError so our error set stays ZqError.
    const feed_result = parser.feed(data, true) catch |e| switch (e) {
        error.OutOfMemory => return .{ .err = error.IoError },
        else => return .{ .err = @as(ZqError, @errorCast(e)) },
    };
    const tape = switch (feed_result) {
        .done => |t| t,
        .need_more => return .{ .err = error.UnexpectedEof },
    };

    var it = cq.execute(tape, allocator) catch return .{ .err = error.IoError };
    defer it.deinit();

    var values = std.ArrayList(OwnedValue){};
    while (true) {
        const maybe_val = it.next() catch |e| {
            for (values.items) |*v| v.deinit(allocator);
            values.deinit(allocator);
            return .{ .err = e };
        };
        const val = maybe_val orelse break;
        const owned = own_value(val, tape, allocator) catch {
            for (values.items) |*v| v.deinit(allocator);
            values.deinit(allocator);
            return .{ .err = error.IoError };
        };
        values.append(allocator, owned) catch {
            var tmp = owned;
            tmp.deinit(allocator);
            for (values.items) |*v| v.deinit(allocator);
            values.deinit(allocator);
            return .{ .err = error.IoError };
        };
    }

    const slice = values.toOwnedSlice(allocator) catch {
        for (values.items) |*v| v.deinit(allocator);
        values.deinit(allocator);
        return .{ .err = error.IoError };
    };
    return .{ .values = slice };
}

/// Copy a non-owning Value into an OwnedValue that survives Parser.reset().
fn own_value(
    val: types.Value,
    tape: types.Tape,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!OwnedValue {
    return switch (val) {
        .null_val => .null_val,
        .bool_val => |b| .{ .bool_val = b },
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .object => |span| .{ .object_json = try serialise_span(tape, span.start, span.end, allocator) },
        .array => |span| .{ .array_json = try serialise_span(tape, span.start, span.end, allocator) },
    };
}

// ── JSON serialiser for Tape spans ────────────────────────────────────────────

fn serialise_span(
    tape: types.Tape,
    start: u32,
    end: u32,
    allocator: std.mem.Allocator,
) error{OutOfMemory}![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    const max_depth: usize = 512;
    var comma_needed = try allocator.alloc(bool, max_depth + 1);
    defer allocator.free(comma_needed);
    @memset(comma_needed, false);

    var depth: usize = 0;
    var in_key: bool = false;
    var i: u32 = start;

    while (i < end) : (i += 1) {
        const entry = tape.entries[i];
        switch (entry.tag) {
            .object_start => {
                if (depth > 0 and !in_key) {
                    if (comma_needed[depth]) try buf.append(allocator, ',');
                    comma_needed[depth] = false;
                }
                try buf.append(allocator, '{');
                depth += 1;
                if (depth <= max_depth) comma_needed[depth] = false;
                in_key = false;
            },
            .object_end => {
                depth -= 1;
                try buf.append(allocator, '}');
                if (depth > 0) comma_needed[depth] = true;
                in_key = false;
            },
            .array_start => {
                if (depth > 0 and !in_key) {
                    if (comma_needed[depth]) try buf.append(allocator, ',');
                    comma_needed[depth] = false;
                }
                try buf.append(allocator, '[');
                depth += 1;
                if (depth <= max_depth) comma_needed[depth] = false;
                in_key = false;
            },
            .array_end => {
                depth -= 1;
                try buf.append(allocator, ']');
                if (depth > 0) comma_needed[depth] = true;
                in_key = false;
            },
            .key => {
                if (depth > 0 and comma_needed[depth]) try buf.append(allocator, ',');
                if (depth > 0) comma_needed[depth] = false;
                const s = tape.getString(entry.payload.string);
                try append_json_string(&buf, allocator, s);
                try buf.append(allocator, ':');
                in_key = true;
            },
            .string => {
                if (depth > 0 and !in_key and comma_needed[depth]) try buf.append(allocator, ',');
                if (depth > 0 and !in_key) comma_needed[depth] = false;
                const s = tape.getString(entry.payload.string);
                try append_json_string(&buf, allocator, s);
                if (depth > 0) comma_needed[depth] = true;
                in_key = false;
            },
            .int => {
                if (depth > 0 and !in_key and comma_needed[depth]) try buf.append(allocator, ',');
                if (depth > 0 and !in_key) comma_needed[depth] = false;
                const s = try std.fmt.allocPrint(allocator, "{d}", .{entry.payload.int});
                defer allocator.free(s);
                try buf.appendSlice(allocator, s);
                if (depth > 0) comma_needed[depth] = true;
                in_key = false;
            },
            .float => {
                if (depth > 0 and !in_key and comma_needed[depth]) try buf.append(allocator, ',');
                if (depth > 0 and !in_key) comma_needed[depth] = false;
                const s = try std.fmt.allocPrint(allocator, "{d}", .{entry.payload.float});
                defer allocator.free(s);
                try buf.appendSlice(allocator, s);
                if (depth > 0) comma_needed[depth] = true;
                in_key = false;
            },
            .true_val => {
                if (depth > 0 and !in_key and comma_needed[depth]) try buf.append(allocator, ',');
                if (depth > 0 and !in_key) comma_needed[depth] = false;
                try buf.appendSlice(allocator, "true");
                if (depth > 0) comma_needed[depth] = true;
                in_key = false;
            },
            .false_val => {
                if (depth > 0 and !in_key and comma_needed[depth]) try buf.append(allocator, ',');
                if (depth > 0 and !in_key) comma_needed[depth] = false;
                try buf.appendSlice(allocator, "false");
                if (depth > 0) comma_needed[depth] = true;
                in_key = false;
            },
            .null_val => {
                if (depth > 0 and !in_key and comma_needed[depth]) try buf.append(allocator, ',');
                if (depth > 0 and !in_key) comma_needed[depth] = false;
                try buf.appendSlice(allocator, "null");
                if (depth > 0) comma_needed[depth] = true;
                in_key = false;
            },
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn append_json_string(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    s: []const u8,
) error{OutOfMemory}!void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            // Other ASCII control characters (excluding \n=0x0A, \r=0x0D, \t=0x09).
            0x00...0x08, 0x0B...0x0C, 0x0E...0x1F => {
                const hex = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
                defer allocator.free(hex);
                try buf.appendSlice(allocator, hex);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

// ── IO thread for stream mode ──────────────────────────────────────────────────

const IoCtx = struct {
    src: *io_mod.Source,
    query: *const query_mod.CompiledQuery,
    queue: *JobQueue,
    sequencer: *Sequencer,
    allocator: std.mem.Allocator,
};

fn io_thread_fn(ctx: IoCtx) void {
    var seq: u64 = 0;
    var line_buf = std.ArrayList(u8){};
    defer line_buf.deinit(ctx.allocator);

    loop: while (true) {
        const view = ctx.src.peek() catch break :loop;

        if (view.bytes.len == 0) {
            if (view.is_eof) break :loop;
            _ = ctx.src.refill() catch break :loop;
            continue;
        }

        // Find newlines within the available view.
        var consumed_offset: usize = 0;
        var scan: usize = 0;
        while (scan < view.bytes.len) : (scan += 1) {
            if (view.bytes[scan] == '\n') {
                line_buf.appendSlice(ctx.allocator, view.bytes[consumed_offset..scan]) catch break :loop;
                consumed_offset = scan + 1;

                const trimmed = std.mem.trimRight(u8, line_buf.items, " \t\r");
                if (trimmed.len > 0) {
                    const data = ctx.allocator.dupe(u8, trimmed) catch break :loop;
                    ctx.queue.push(.{
                        .seq = seq,
                        .data = data,
                        .query = ctx.query,
                        .allocator = ctx.allocator,
                    });
                    seq += 1;
                }
                line_buf.clearRetainingCapacity();
            }
        }

        // Buffer the tail (bytes after the last newline, or all bytes if no newline).
        line_buf.appendSlice(ctx.allocator, view.bytes[consumed_offset..]) catch break :loop;
        ctx.src.consume(view.bytes.len);

        if (view.is_eof) break :loop;
        _ = ctx.src.refill() catch break :loop;
    }

    // Flush any remaining bytes as the final record (no trailing newline).
    {
        const trimmed = std.mem.trimRight(u8, line_buf.items, " \t\r");
        if (trimmed.len > 0) {
            const data = ctx.allocator.dupe(u8, trimmed) catch {
                ctx.sequencer.set_total(seq);
                ctx.queue.signal_done();
                return;
            };
            ctx.queue.push(.{
                .seq = seq,
                .data = data,
                .query = ctx.query,
                .allocator = ctx.allocator,
            });
            seq += 1;
        }
    }

    ctx.sequencer.set_total(seq);
    ctx.queue.signal_done();
}

// ── SharedCtx — heap-allocated, ref-counted pool state ────────────────────────
//
// Pool is returned by value from init(), so Queue and Sequencer cannot live
// inside Pool directly (their addresses would move with the value).  We heap-
// allocate them in SharedCtx and keep a pointer in Pool.

const SharedCtx = struct {
    queue: JobQueue,
    sequencer: Sequencer,
    allocator: std.mem.Allocator,
    /// Starts at 1 (for the Pool) + n_workers.  Each thread decrements on exit.
    /// When it reaches zero the last exiter frees SharedCtx.
    ref_count: std.atomic.Value(usize),
};

fn worker_thread_entry(shared: *SharedCtx) void {
    const ctx = WorkerCtx{
        .queue = &shared.queue,
        .sequencer = &shared.sequencer,
        .allocator = shared.allocator,
    };
    worker_fn(ctx);
    release_shared(shared, shared.allocator);
}

fn release_shared(shared: *SharedCtx, allocator: std.mem.Allocator) void {
    if (shared.ref_count.fetchSub(1, .acq_rel) == 1) {
        shared.queue.deinit();
        shared.sequencer.deinit();
        allocator.destroy(shared);
    }
}

// ── Pool ──────────────────────────────────────────────────────────────────────

const QUEUE_CAP: usize = 256;

pub const Pool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    io_thread: ?std.Thread,
    /// Sequence counter for file-mode and inline-mode submissions.
    seq_counter: u64,
    /// Heap-allocated, ref-counted state shared with worker threads.
    _shared: *SharedCtx,
    /// OwnedValues from the previous collect() call. Freed at the start of the
    /// next collect() call so that Result.value.string remains valid between calls.
    _prev_values: ?[]OwnedValue,

    pub fn init(n_threads: usize, allocator: std.mem.Allocator) error{OutOfMemory}!Pool {
        const shared = try allocator.create(SharedCtx);
        errdefer allocator.destroy(shared);

        var queue = try JobQueue.init(QUEUE_CAP, allocator);
        errdefer queue.deinit();

        var sequencer = try Sequencer.init(allocator);
        errdefer sequencer.deinit();

        shared.* = .{
            .queue = queue,
            .sequencer = sequencer,
            .allocator = allocator,
            .ref_count = std.atomic.Value(usize).init(1 + n_threads),
        };

        const threads = try allocator.alloc(std.Thread, n_threads);
        errdefer allocator.free(threads);

        var spawned: usize = 0;
        errdefer {
            shared.queue.signal_done();
            for (threads[0..spawned]) |t| t.join();
        }

        for (threads) |*t| {
            t.* = std.Thread.spawn(.{}, worker_thread_entry, .{shared}) catch {
                return error.OutOfMemory;
            };
            spawned += 1;
        }

        return Pool{
            .allocator = allocator,
            .threads = threads,
            .io_thread = null,
            .seq_counter = 0,
            ._shared = shared,
            ._prev_values = null,
        };
    }

    pub fn deinit(p: *Pool) void {
        // Free any values held from the last collect() call.
        if (p._prev_values) |vs| free_owned_values(vs, p.allocator);
        p._shared.queue.signal_done();
        if (p.io_thread) |t| t.join();
        for (p.threads) |t| t.join();
        p.allocator.free(p.threads);
        // Release the pool's reference to SharedCtx.
        release_shared(p._shared, p.allocator);
    }

    /// Submit a regular file for parallel processing.
    pub fn submit_file(
        p: *Pool,
        fd: std.posix.fd_t,
        cq: *const query_mod.CompiledQuery,
    ) ZqError!void {
        var source = io_mod.Source.init(fd, p.allocator) catch return error.IoError;
        defer source.deinit();

        var line_buf = std.ArrayList(u8){};
        defer line_buf.deinit(p.allocator);

        outer: while (true) {
            const view = source.peek() catch return error.IoError;

            if (view.bytes.len == 0) {
                if (view.is_eof) break :outer;
                _ = source.refill() catch return error.IoError;
                continue;
            }

            var consumed_offset: usize = 0;
            var scan: usize = 0;
            while (scan < view.bytes.len) : (scan += 1) {
                if (view.bytes[scan] == '\n') {
                    line_buf.appendSlice(p.allocator, view.bytes[consumed_offset..scan]) catch return error.IoError;
                    consumed_offset = scan + 1;

                    const trimmed = std.mem.trimRight(u8, line_buf.items, " \t\r");
                    if (trimmed.len > 0) {
                        const data = p.allocator.dupe(u8, trimmed) catch return error.IoError;
                        p._shared.queue.push(.{
                            .seq = p.seq_counter,
                            .data = data,
                            .query = cq,
                            .allocator = p.allocator,
                        });
                        p.seq_counter += 1;
                    }
                    line_buf.clearRetainingCapacity();
                }
            }
            line_buf.appendSlice(p.allocator, view.bytes[consumed_offset..]) catch return error.IoError;
            source.consume(view.bytes.len);

            if (view.is_eof) break :outer;
            _ = source.refill() catch return error.IoError;
        }

        // Flush trailing line without newline.
        const trimmed = std.mem.trimRight(u8, line_buf.items, " \t\r");
        if (trimmed.len > 0) {
            const data = p.allocator.dupe(u8, trimmed) catch return error.IoError;
            p._shared.queue.push(.{
                .seq = p.seq_counter,
                .data = data,
                .query = cq,
                .allocator = p.allocator,
            });
            p.seq_counter += 1;
        }

        p._shared.sequencer.set_total(p.seq_counter);
        p._shared.queue.signal_done();
    }

    /// Submit a streaming source (stdin, pipe, …) for pipeline processing.
    pub fn submit_stream(
        p: *Pool,
        src: *io_mod.Source,
        cq: *const query_mod.CompiledQuery,
    ) void {
        const ctx_ptr = p.allocator.create(IoCtx) catch {
            p._shared.sequencer.set_total(0);
            p._shared.queue.signal_done();
            return;
        };
        ctx_ptr.* = .{
            .src = src,
            .query = cq,
            .queue = &p._shared.queue,
            .sequencer = &p._shared.sequencer,
            .allocator = p.allocator,
        };

        p.io_thread = std.Thread.spawn(.{}, struct {
            fn run(c: *IoCtx) void {
                const alloc = c.allocator;
                io_thread_fn(c.*);
                alloc.destroy(c);
            }
        }.run, .{ctx_ptr}) catch {
            p.allocator.destroy(ctx_ptr);
            p._shared.sequencer.set_total(0);
            p._shared.queue.signal_done();
            return;
        };
    }

    /// Return the next in-order result or null when all records are consumed.
    ///
    /// The returned Result.value is valid until the next collect() or deinit() call.
    pub fn collect(p: *Pool) ZqError!?Result {
        // Free values from the previous call now that the caller is done with them.
        if (p._prev_values) |vs| {
            free_owned_values(vs, p.allocator);
            p._prev_values = null;
        }

        while (true) {
            const wr = p._shared.sequencer.next_in_order() orelse return null;
            switch (wr.outcome) {
                .err => |e| return e,
                .values => |vs| {
                    if (vs.len == 0) {
                        // Query yielded no output for this record; free and try next.
                        free_owned_values(vs, p.allocator);
                        continue;
                    }
                    // Keep vs alive until next collect()/deinit(); return first value.
                    p._prev_values = vs;
                    return Result{ .value = owned_to_value(vs[0]) };
                },
            }
        }
    }
};

// ── Value conversion ──────────────────────────────────────────────────────────

fn owned_to_value(ov: OwnedValue) types.Value {
    return switch (ov) {
        .null_val => .null_val,
        .bool_val => |b| .{ .bool_val = b },
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        // Both string and serialised JSON are returned as .string.
        .string => |s| .{ .string = s },
        .object_json => |j| .{ .string = j },
        .array_json => |j| .{ .string = j },
    };
}
