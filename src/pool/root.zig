/// Pool — parallel JSONL processing with chunk-level batching and arena-per-chunk memory.
///
/// File mode
/// ---------
/// submit_file() mmap's the entire file and splits it into n_threads × CHUNK_FACTOR
/// byte-range chunks aligned to newline boundaries.  Each worker dequeues one chunk,
/// processes every record in it, and posts a single ChunkResult to the Sequencer.
/// Total Sequencer operations: N_CHUNKS (≤ 64 for 16 threads), not 15M.
///
/// Stream mode
/// -----------
/// submit_stream() starts an IO thread that reads complete lines from a Source.
/// Each line becomes its own single-record ChunkResult (chunk_id = line number).
/// Latency-first: no buffering so output appears as each line is processed.
///
/// Memory model
/// ------------
/// Every ChunkResult owns an ArenaAllocator that backs all RecordOutcome slices,
/// OwnedValue copies, string bytes, and tape-entry copies for that chunk.
/// collect() frees the arena atomically once the chunk's last value is consumed.
/// In the hot path for scalar queries (int/float/bool/null), own_value() allocates
/// nothing — the arena is touched only for strings and object/array tape copies.
///
/// Ordering
/// --------
/// The Sequencer holds a reorder buffer (HashMap<chunk_id → ChunkResult>) and
/// delivers chunks in chunk_id order regardless of worker completion order.
/// collect() maintains a (rec_idx, val_idx) cursor so multi-value queries (e.g.
/// `.[]`) deliver every output value before advancing to the next record.
const std = @import("std");
const err_mod = @import("error");
const io_mod = @import("io");
const parser_mod = @import("parser");
const query_mod = @import("query");
const types = @import("types");

pub const ZqError = err_mod.ZqError;

// ── Public result type ────────────────────────────────────────────────────────

/// One output value returned by collect().
/// Valid until the next collect() or deinit() call.
pub const Result = struct {
    value: types.Value,
};

// ── Internal value representation ─────────────────────────────────────────────

/// Owned copy of an object/array tape span.  All slices are arena-allocated.
/// `tape` is a stable Tape view; &tape remains valid while the arena lives.
const OwnedTapeValue = struct {
    entries: []types.Tape.Entry,
    string_buf: []u8,
    /// Embedded Tape whose slices point into `entries` and `string_buf`.
    /// Taking `&tape` is safe as long as the containing OwnedValue is not moved.
    tape: types.Tape,
    start: u32,
    end: u32,
    is_object: bool,
};

/// An owned copy of a Value that outlives Parser.reset().
/// Scalars carry no arena allocations.  Strings: one dupe.  Objects/arrays: two dupes.
/// All allocations belong to the enclosing ChunkResult's arena.
const OwnedValue = union(enum) {
    null_val,
    bool_val: bool,
    int: i64,
    float: f64,
    string: []u8,
    tape_value: OwnedTapeValue,
};

// ── Per-chunk result structures ────────────────────────────────────────────────

/// Outcome of processing a single JSONL record within a chunk.
const RecordOutcome = union(enum) {
    /// Values produced by the query (may be empty if filter yields nothing).
    values: []OwnedValue,
    /// The record could not be parsed or the query raised a runtime error.
    err: ZqError,
};

/// All results from processing one job/chunk, owned by a single arena.
///
/// The arena is moved into the Sequencer then into Pool._delivering.
/// Moving ArenaAllocator by value is safe: its internal state (page list)
/// lives in the arena's own pages, not in the struct itself.
const ChunkResult = struct {
    /// Ordering key delivered by the Sequencer in ascending order.
    chunk_id: u64,
    /// Global sequence number of records[0] (informational; not used by collect()).
    seq_base: u64,
    /// One entry per non-empty record processed in this chunk.
    records: []RecordOutcome,
    /// Owns all memory for `records` and every OwnedValue within.
    /// Call arena.deinit() once the chunk is exhausted to free everything atomically.
    arena: std.heap.ArenaAllocator,
};

// ── Job ───────────────────────────────────────────────────────────────────────

const Job = struct {
    /// Byte range to process.
    /// File mode: slice into Pool._mmap (not owned).
    /// Stream mode: heap-duped line (owned when owns_data = true).
    data: []const u8,
    /// Sequence number of the first record in this job (first non-empty line).
    seq_base: u64,
    /// Sequencer ordering key.
    /// File mode: 0 .. n_actual_chunks - 1.
    /// Stream mode: same as seq_base (one chunk per line).
    chunk_id: u64,
    /// Compiled query — shared read-only across all workers.
    query: *const query_mod.CompiledQuery,
    /// When true the worker must free `data` with `allocator` after processing.
    owns_data: bool,
    allocator: std.mem.Allocator,
};

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
        var i = q.head;
        var c = q.count;
        while (c > 0) : (c -= 1) {
            if (q.buf[i]) |job| if (job.owns_data) job.allocator.free(job.data);
            i = (i + 1) % q.buf.len;
        }
        q.allocator.free(q.buf);
    }

    /// Enqueue a job.  Blocks when the queue is full.  No-op (drops) after shutdown.
    fn push(q: *JobQueue, job: Job) void {
        q.mutex.lock();
        defer q.mutex.unlock();
        while (q.count == q.buf.len and !q.shutdown) q.not_full.wait(&q.mutex);
        if (q.shutdown) {
            if (job.owns_data) job.allocator.free(job.data);
            return;
        }
        q.buf[q.tail] = job;
        q.tail = (q.tail + 1) % q.buf.len;
        q.count += 1;
        q.not_empty.signal();
    }

    /// Dequeue a job.  Blocks when empty.  Returns null when empty + shutdown.
    fn pop(q: *JobQueue) ?Job {
        q.mutex.lock();
        defer q.mutex.unlock();
        while (q.count == 0 and !q.shutdown) q.not_empty.wait(&q.mutex);
        if (q.count == 0) return null;
        const job = q.buf[q.head].?;
        q.buf[q.head] = null;
        q.head = (q.head + 1) % q.buf.len;
        q.count -= 1;
        q.not_full.signal();
        return job;
    }

    /// Signal that no more jobs will be pushed.  Unblocks all waiting pop() callers.
    fn signal_done(q: *JobQueue) void {
        q.mutex.lock();
        defer q.mutex.unlock();
        q.shutdown = true;
        q.not_empty.broadcast();
        q.not_full.broadcast();
    }
};

// ── Sequencer — chunk-level reorder buffer ─────────────────────────────────────
//
// Workers post ChunkResults out-of-order.  The Sequencer delivers them in
// chunk_id order.  With N_CHUNKS ≤ 64 the HashMap never exceeds 64 entries —
// orders of magnitude cheaper than the previous per-record (15M-entry) approach.

const Sequencer = struct {
    mutex: std.Thread.Mutex,
    available: std.Thread.Condition,
    pending: std.AutoHashMap(u64, ChunkResult),
    /// chunk_id that collect() expects next.
    next_chunk_id: u64,
    /// Total chunks submitted; null until all submissions are complete.
    total_chunks: ?u64,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Sequencer {
        return .{
            .mutex = .{},
            .available = .{},
            .pending = std.AutoHashMap(u64, ChunkResult).init(allocator),
            .next_chunk_id = 0,
            .total_chunks = null,
            .allocator = allocator,
        };
    }

    fn deinit(s: *Sequencer) void {
        // Free arenas for any chunks that were never consumed.
        var it = s.pending.valueIterator();
        while (it.next()) |cr| cr.arena.deinit();
        s.pending.deinit();
    }

    fn post(s: *Sequencer, result: ChunkResult) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        s.pending.put(result.chunk_id, result) catch {
            // OOM storing the result — free the arena immediately to avoid a leak.
            var r = result;
            r.arena.deinit();
        };
        s.available.signal();
    }

    fn set_total_chunks(s: *Sequencer, total: u64) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        s.total_chunks = total;
        s.available.broadcast();
    }

    /// Block until the next in-order ChunkResult is available, then return it.
    /// Returns null when all chunks have been delivered.
    fn next_in_order(s: *Sequencer) ?ChunkResult {
        s.mutex.lock();
        defer s.mutex.unlock();
        while (true) {
            if (s.total_chunks) |tot| {
                if (s.next_chunk_id >= tot) return null;
            }
            if (s.pending.getPtr(s.next_chunk_id)) |cr| {
                const result = cr.*;
                _ = s.pending.remove(s.next_chunk_id);
                s.next_chunk_id += 1;
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
    // One parser per worker, reused across all chunks via reset().
    var parser = parser_mod.Parser.init(ctx.allocator) catch {
        while (ctx.queue.pop()) |job| if (job.owns_data) job.allocator.free(job.data);
        return;
    };
    defer parser.deinit();

    // Persistent ResultIterator: initialised once on the first record, then
    // reset() on every subsequent record — zero alloc/free cycles after the first.
    // Uses ctx.allocator (GPA) so its eval stack survives across chunks.
    var opt_it: ?query_mod.ResultIterator = null;
    var current_query: ?*const query_mod.CompiledQuery = null;
    defer if (opt_it) |*it| it.deinit();

    while (ctx.queue.pop()) |job| {
        defer if (job.owns_data) job.allocator.free(job.data);

        // Per-chunk arena: all OwnedValue memory is allocated here.
        // Freed atomically by collect() after the chunk is exhausted.
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        const aa = arena.allocator();

        // Accumulate RecordOutcomes using the arena allocator.
        var records = std.ArrayList(RecordOutcome){};

        var remaining: []const u8 = job.data;
        while (remaining.len > 0) {
            const nl = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
            const line = std.mem.trimRight(u8, remaining[0..nl], " \t\r");
            remaining = if (nl < remaining.len) remaining[nl + 1 ..] else &.{};
            if (line.len == 0) continue;

            const outcome = process_line(
                line,
                &parser,
                &opt_it,
                &current_query,
                job.query,
                ctx.allocator, // for the persistent iterator's eval stack
                aa, // for this record's OwnedValues
            );

            records.append(aa, outcome) catch {
                // If we can't store the outcome, emit an error entry.
                // All prior arena allocations for this outcome stay in aa and
                // will be freed when the chunk's arena is deinited.
                records.append(aa, .{ .err = error.IoError }) catch {};
            };
        }

        const records_slice = records.toOwnedSlice(aa) catch records.items;

        ctx.sequencer.post(ChunkResult{
            .chunk_id = job.chunk_id,
            .seq_base = job.seq_base,
            .records = records_slice,
            .arena = arena, // ownership transferred; do not use `aa` after this
        });
    }
}

/// Parse and execute the query for a single JSONL line.
///
/// `worker_alloc` — used for the persistent ResultIterator's eval stack (GPA).
/// `aa`           — per-chunk arena; used for all OwnedValue copies.
///
/// Parser is reset inside this function after values are copied into `aa`.
fn process_line(
    line: []const u8,
    parser: *parser_mod.Parser,
    opt_it: *?query_mod.ResultIterator,
    current_query: *?*const query_mod.CompiledQuery,
    query: *const query_mod.CompiledQuery,
    worker_alloc: std.mem.Allocator,
    aa: std.mem.Allocator,
) RecordOutcome {
    // ── Parse ──────────────────────────────────────────────────────────────────
    const feed_result = parser.feed(line, true) catch |e| {
        parser.reset();
        return .{ .err = @as(ZqError, @errorCast(e)) };
    };
    const tape = switch (feed_result) {
        .done => |d| d.tape,
        .need_more => {
            parser.reset();
            return .{ .err = error.UnexpectedEof };
        },
    };

    // ── Bind or rebind the ResultIterator ──────────────────────────────────────
    if (opt_it.* == null or current_query.* != query) {
        if (opt_it.*) |*it| it.deinit();
        opt_it.* = query.execute(tape, worker_alloc) catch {
            parser.reset();
            opt_it.* = null;
            current_query.* = null;
            return .{ .err = error.IoError };
        };
        current_query.* = query;
    } else {
        // Same query, new tape: zero-allocation rebind.
        opt_it.*.?.reset(tape);
    }

    // ── Collect values into the chunk arena ────────────────────────────────────
    // collect_record_values() drains the iterator and copies every Value into aa.
    // Parser.reset() is called AFTER collection so the tape remains valid during
    // the copy.
    const outcome = collect_record_values(&opt_it.*.?, aa);
    parser.reset();
    return outcome;
}

/// Drain the iterator and copy all values into `aa`.
/// On any error the partial list is abandoned (freed with the arena on chunk deinit).
fn collect_record_values(
    it: *query_mod.ResultIterator,
    aa: std.mem.Allocator,
) RecordOutcome {
    var list = std.ArrayList(OwnedValue){};
    while (true) {
        const maybe = it.next() catch |e| return .{ .err = e };
        const val = maybe orelse break;
        const owned = own_value(val, aa) catch return .{ .err = error.IoError };
        list.append(aa, owned) catch return .{ .err = error.IoError };
    }
    const slice = list.toOwnedSlice(aa) catch list.items;
    return .{ .values = slice };
}

/// Copy a non-owning Value into arena-backed memory so it survives Parser.reset().
///
/// Scalars (null, bool, int, float): zero allocations.
/// Strings: one arena allocation (byte copy).
/// Objects/arrays: two arena allocations (tape entries + string_buf).
fn own_value(val: types.Value, aa: std.mem.Allocator) error{OutOfMemory}!OwnedValue {
    return switch (val) {
        .null_val => .null_val,
        .bool_val => |b| .{ .bool_val = b },
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = try aa.dupe(u8, s) },
        .object => |span| blk: {
            const entries = try aa.dupe(types.Tape.Entry, span.tape.entries);
            const string_buf = try aa.dupe(u8, span.tape.string_buf);
            break :blk .{ .tape_value = .{
                .entries = entries,
                .string_buf = string_buf,
                .tape = .{ .entries = entries, .string_buf = string_buf },
                .start = span.start,
                .end = span.end,
                .is_object = true,
            } };
        },
        .array => |span| blk: {
            const entries = try aa.dupe(types.Tape.Entry, span.tape.entries);
            const string_buf = try aa.dupe(u8, span.tape.string_buf);
            break :blk .{ .tape_value = .{
                .entries = entries,
                .string_buf = string_buf,
                .tape = .{ .entries = entries, .string_buf = string_buf },
                .start = span.start,
                .end = span.end,
                .is_object = false,
            } };
        },
    };
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
    // In stream mode chunk_id == seq_base (one record per chunk).
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
                        .data = data,
                        .seq_base = seq,
                        .chunk_id = seq,
                        .query = ctx.query,
                        .owns_data = true,
                        .allocator = ctx.allocator,
                    });
                    seq += 1;
                }
                line_buf.clearRetainingCapacity();
            }
        }

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
                ctx.sequencer.set_total_chunks(seq);
                ctx.queue.signal_done();
                return;
            };
            ctx.queue.push(.{
                .data = data,
                .seq_base = seq,
                .chunk_id = seq,
                .query = ctx.query,
                .owns_data = true,
                .allocator = ctx.allocator,
            });
            seq += 1;
        }
    }

    ctx.sequencer.set_total_chunks(seq);
    ctx.queue.signal_done();
}

// ── SharedCtx — heap-allocated, ref-counted pool state ────────────────────────
//
// Pool is returned by value from init(), so JobQueue and Sequencer cannot live
// inside Pool directly (their addresses would move with the value copy).  We
// heap-allocate them in SharedCtx and keep a stable pointer in Pool.

const SharedCtx = struct {
    queue: JobQueue,
    sequencer: Sequencer,
    allocator: std.mem.Allocator,
    /// Starts at 1 (for the Pool) + n_workers.  Each exiting thread decrements.
    /// The last to decrement frees SharedCtx.
    ref_count: std.atomic.Value(usize),
};

fn worker_thread_entry(shared: *SharedCtx) void {
    worker_fn(.{
        .queue = &shared.queue,
        .sequencer = &shared.sequencer,
        .allocator = shared.allocator,
    });
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

/// Queue capacity: CHUNK_FACTOR × max sensible thread count gives comfortable
/// headroom so submit_file() rarely blocks while workers drain the queue.
const QUEUE_CAP: usize = 256;

/// Chunks per thread — more chunks than threads allows the OS scheduler to
/// balance load when records have uneven parse/query cost.
const CHUNK_FACTOR: usize = 4;

pub const Pool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    io_thread: ?std.Thread,
    _shared: *SharedCtx,

    // File-mode mmap lifetime management.
    // Non-null between submit_file() and the point in deinit() where threads join.
    // Workers hold read-only slices into this mapping; it must outlive all threads.
    _mmap: ?[]u8,

    // collect() cursor — maintains position across calls so multi-value queries
    // (e.g. `.[]`) deliver every output value before advancing to the next record.
    _delivering: ?ChunkResult, // chunk currently being consumed
    _rec_idx: usize, // index into _delivering.records[]
    _val_idx: usize, // index into _delivering.records[_rec_idx].values[]

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
            ._shared = shared,
            ._mmap = null,
            ._delivering = null,
            ._rec_idx = 0,
            ._val_idx = 0,
        };
    }

    pub fn deinit(p: *Pool) void {
        p._shared.queue.signal_done();
        if (p.io_thread) |t| t.join();
        // Join workers BEFORE unmapping — workers may still read mmap memory.
        for (p.threads) |t| t.join();
        p.allocator.free(p.threads);
        release_shared(p._shared, p.allocator);
        // Unmap only after all threads have exited.
        if (p._mmap) |m| std.posix.munmap(@alignCast(m));
        // Free any partially-consumed chunk that collect() hadn't exhausted.
        if (p._delivering) |*cr| cr.arena.deinit();
    }

    /// Submit a regular file for parallel processing.
    ///
    /// The file is memory-mapped once.  The mapping is split into at most
    /// n_threads × CHUNK_FACTOR byte-range chunks, each aligned to newline
    /// boundaries so records are never split across workers.
    ///
    /// Only non-empty chunks (at least one non-blank line) are enqueued.
    /// The Sequencer is told exactly how many chunks to expect so collect()
    /// returns null as soon as all work is done.
    pub fn submit_file(
        p: *Pool,
        fd: std.posix.fd_t,
        cq: *const query_mod.CompiledQuery,
    ) ZqError!void {
        const stat = std.posix.fstat(fd) catch return error.IoError;
        const file_size = @as(usize, @intCast(stat.size));

        if (file_size == 0) {
            p._shared.sequencer.set_total_chunks(0);
            p._shared.queue.signal_done();
            return;
        }

        const mmap = std.posix.mmap(
            null,
            file_size,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        ) catch return error.IoError;
        p._mmap = @as([]u8, mmap);

        const data: []const u8 = mmap;
        const n_threads = @max(1, p.threads.len);
        const n_chunks = n_threads * CHUNK_FACTOR;

        // chunk_id counts only non-empty chunks (those we actually enqueue).
        var chunk_id: u64 = 0;
        var total_records: u64 = 0;
        var chunk_start: usize = 0;

        for (0..n_chunks) |i| {
            const ideal_end = if (i + 1 == n_chunks)
                file_size
            else
                (i + 1) * file_size / n_chunks;

            // Advance to the next newline so no record is split.
            const chunk_end: usize = if (ideal_end >= file_size)
                file_size
            else blk: {
                var pos = ideal_end;
                while (pos < file_size and data[pos] != '\n') pos += 1;
                break :blk if (pos < file_size) pos + 1 else file_size;
            };

            const chunk = data[chunk_start..chunk_end];
            chunk_start = chunk_end;
            if (chunk.len == 0) continue;

            // Count non-empty records for set_total_records bookkeeping (seq_base).
            // This O(N) pass is cache-sequential and auto-vectorised in ReleaseFast.
            var record_count: u64 = 0;
            {
                var rem = chunk;
                while (rem.len > 0) {
                    const nl = std.mem.indexOfScalar(u8, rem, '\n') orelse rem.len;
                    const line = std.mem.trimRight(u8, rem[0..nl], " \t\r");
                    if (line.len > 0) record_count += 1;
                    rem = if (nl < rem.len) rem[nl + 1 ..] else &.{};
                }
            }
            if (record_count == 0) continue;

            p._shared.queue.push(.{
                .data = chunk,
                .seq_base = total_records,
                .chunk_id = chunk_id,
                .query = cq,
                .owns_data = false,
                .allocator = p.allocator,
            });
            total_records += record_count;
            chunk_id += 1;
        }

        p._shared.sequencer.set_total_chunks(chunk_id);
        p._shared.queue.signal_done();
    }

    /// Submit a streaming source (stdin, pipe, …) for pipeline processing.
    ///
    /// A dedicated IO thread reads complete newline-terminated lines from `src`
    /// and posts them to worker threads.  Each line is an independent chunk
    /// (chunk_id == seq_base) so the Sequencer delivers results line-by-line.
    pub fn submit_stream(
        p: *Pool,
        src: *io_mod.Source,
        cq: *const query_mod.CompiledQuery,
    ) void {
        const ctx_ptr = p.allocator.create(IoCtx) catch {
            p._shared.sequencer.set_total_chunks(0);
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
            p._shared.sequencer.set_total_chunks(0);
            p._shared.queue.signal_done();
            return;
        };
    }

    /// Return the next result in submission order.
    ///
    /// Blocks until the next in-order value is available or all work is done.
    /// Returns null when all submitted records have been processed.
    /// Returns an error if a worker encountered a parse or query error on a record.
    ///
    /// Lifetime: the returned Result.value is valid until the NEXT call to collect()
    /// or deinit().  Tape/string pointers point into the current chunk's arena, which
    /// is freed at the beginning of the call that advances past the chunk's last value.
    ///
    /// Multi-value queries: if the query yields N values for a record, collect() is
    /// called N times to retrieve them all before advancing to the next record.
    pub fn collect(p: *Pool) ZqError!?Result {
        while (true) {
            // ── Fetch next chunk if we have none ────────────────────────────────
            if (p._delivering == null) {
                const maybe = p._shared.sequencer.next_in_order();
                if (maybe == null) return null;
                p._delivering = maybe;
                p._rec_idx = 0;
                p._val_idx = 0;
            }

            // ── Chunk exhausted — free its arena and loop to fetch the next ─────
            // Safety: the arena is freed HERE, at the start of this call.  The
            // caller is done with the value returned in the PREVIOUS call (the
            // contract states "valid until next collect() call").
            if (p._rec_idx >= p._delivering.?.records.len) {
                p._delivering.?.arena.deinit();
                p._delivering = null;
                continue;
            }

            // ── Dispatch on the current record's outcome ─────────────────────────
            switch (p._delivering.?.records[p._rec_idx]) {
                .err => |e| {
                    // Advance past this record; caller sees the error this call.
                    p._rec_idx += 1;
                    p._val_idx = 0;
                    return e;
                },
                .values => |vs| {
                    if (p._val_idx < vs.len) {
                        // Return this value; cursor stays on the same record.
                        const result = Result{
                            .value = owned_to_value(&vs[p._val_idx]),
                        };
                        p._val_idx += 1;
                        return result;
                    }
                    // All values for this record consumed; advance to next record.
                    p._rec_idx += 1;
                    p._val_idx = 0;
                },
            }
        }
    }
};

// ── Value conversion ──────────────────────────────────────────────────────────

/// Convert an arena-backed OwnedValue to a types.Value for the caller.
///
/// For objects/arrays, takes a pointer so that &ov.tape_value.tape yields a
/// stable address into the arena.  The returned Value is valid while the
/// OwnedValue's enclosing ChunkResult arena is alive.
fn owned_to_value(ov: *const OwnedValue) types.Value {
    return switch (ov.*) {
        .null_val => .null_val,
        .bool_val => |b| .{ .bool_val = b },
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = s },
        .tape_value => blk: {
            const tv = &ov.tape_value;
            break :blk if (tv.is_object)
                types.Value{ .object = .{ .tape = &tv.tape, .start = tv.start, .end = tv.end } }
            else
                types.Value{ .array = .{ .tape = &tv.tape, .start = tv.start, .end = tv.end } };
        },
    };
}
