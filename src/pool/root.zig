/// Pool — parallel JSONL processing with chunk-level batching and arena-per-chunk memory.
///
/// Two execution paths
/// -------------------
/// **Structured path** (format = null): Workers execute queries and copy values into
/// arena-backed OwnedValues via own_value(). collect() returns typed Value results.
///
/// **Serialized path** (format != null): Workers execute queries and serialize values
/// directly into arena-backed byte buffers while the tape is still valid. No own_value()
/// needed — the arena holds only the serialized bytes. collect_bytes() returns raw bytes.
/// This path drastically reduces memory for per-record queries (.id, select(), {a,b}).
///
/// File mode
/// ---------
/// submit_file() mmap's the entire file and splits it into n_threads × CHUNK_FACTOR
/// byte-range chunks aligned to newline boundaries.  A dedicated feeder thread lazily
/// pushes chunks to the worker queue one at a time, blocking when too many are in-flight.
/// Workers dequeue one chunk, process every record in it, and post a ChunkResult to the
/// Sequencer.  Total Sequencer operations: N_CHUNKS (≤ 64 for 16 threads), not 15M.
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
/// OwnedValue copies (structured path) or serialized bytes (serialized path),
/// string bytes, and tape-entry copies for that chunk.
/// collect()/collect_bytes() frees the arena atomically once the chunk is exhausted.
///
/// Backpressure (file mode)
/// ------------------------
/// An InFlightLimiter caps the number of simultaneously live ChunkResults to
/// IN_FLIGHT_FACTOR × n_threads.  The feeder acquires a slot before pushing each
/// chunk to the queue; collect()/collect_bytes() releases the slot after freeing
/// the chunk's arena.
/// Peak RSS ≈ IN_FLIGHT_FACTOR × chunk_size × n_threads, not the full file size.
///
/// Ordering
/// --------
/// The Sequencer holds a fixed-size ring buffer (capacity = QUEUE_CAP + n_threads
/// slots) indexed by chunk_id % capacity.  Workers write directly into their
/// assigned slot; collect()/collect_bytes() reads the slot for next_chunk_id,
/// clears it, then advances.  No HashMap, no dynamic allocation in the reorder
/// hot path.
///
/// Capacity is sized to the maximum spread of simultaneously live chunk IDs for
/// both modes (file: IN_FLIGHT_FACTOR×n_threads; stream: QUEUE_CAP+n_threads).
/// The ring invariant — no two live chunks share a slot — is enforced by the
/// InFlightLimiter (file) and JobQueue capacity (stream).
/// collect() maintains a (rec_idx, val_idx) cursor so multi-value queries (e.g.
/// `.[]`) deliver every output value before advancing to the next record.
const std = @import("std");
const err_mod = @import("error");
const io_mod = @import("io");
const output_mod = @import("output");
const parser_mod = @import("parser");
const query_mod = @import("query");
const types = @import("types");

pub const ZqError = err_mod.ZqError;

// ── Public result types ───────────────────────────────────────────────────────

/// One output value returned by collect() (structured path).
/// Valid until the next collect() or deinit() call.
pub const Result = struct {
    value: types.Value,
};

/// Pre-serialized bytes for one record, returned by collect_bytes() (serialized path).
/// Valid until the next collect_bytes() or deinit() call.
pub const BytesResult = struct {
    data: []const u8,
    last_was_false_or_null: bool,
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

// ── Per-record serialized output ──────────────────────────────────────────────

/// Pre-serialized output for a single JSONL record, arena-allocated.
const SerializedRecord = struct {
    data: []const u8,
    last_was_false_or_null: bool,
};

// ── Per-chunk result structures ────────────────────────────────────────────────

/// Outcome of processing a single JSONL record within a chunk.
const RecordOutcome = union(enum) {
    /// Values produced by the query (structured path).
    values: []OwnedValue,
    /// Pre-serialized bytes (serialized path).
    serialized: SerializedRecord,
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
    /// Owns all memory for `records` and every OwnedValue/serialized byte within.
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
    /// When non-null, workers use the serialized path: serialize values directly
    /// into byte buffers instead of copying them via own_value().
    format: ?types.Format,
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

// ── InFlightLimiter — backpressure between feeder and collect() ───────────────
//
// Caps how many ChunkResults are simultaneously alive (either being processed by
// a worker or sitting in the Sequencer awaiting collect()).  The feeder calls
// acquire() before enqueuing each chunk; collect() calls release() after freeing
// the chunk's arena.  This bounds peak RSS to IN_FLIGHT_FACTOR × chunk_size ×
// n_threads instead of the full file size.

const InFlightLimiter = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    count: usize,
    max: usize,
    shutdown: bool,

    fn init(max_slots: usize) InFlightLimiter {
        return .{
            .mutex = .{},
            .cond = .{},
            .count = 0,
            .max = max_slots,
            .shutdown = false,
        };
    }

    /// Block until a slot is available, then claim it.
    /// Returns false when the limiter has been shut down; the caller must not
    /// process any more chunks.
    fn acquire(self: *InFlightLimiter) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.count >= self.max and !self.shutdown) self.cond.wait(&self.mutex);
        if (self.shutdown) return false;
        self.count += 1;
        return true;
    }

    /// Release one slot and wake a waiting producer.
    fn release(self: *InFlightLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count > 0) self.count -= 1;
        self.cond.signal();
    }

    /// Broadcast shutdown so all blocked acquire() calls return false immediately.
    fn signal_shutdown(self: *InFlightLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.shutdown = true;
        self.cond.broadcast();
    }
};

// ── Sequencer — ring-buffer reorder buffer ────────────────────────────────────
//
// Workers post ChunkResults out-of-order.  The Sequencer delivers them in
// chunk_id order using a fixed-size ring buffer indexed by chunk_id % capacity.
//
// Capacity = QUEUE_CAP + n_threads, which upper-bounds the spread of live chunk
// IDs in both modes:
//   • File mode:   IN_FLIGHT_FACTOR × n_threads (enforced by InFlightLimiter)
//   • Stream mode: QUEUE_CAP + n_threads (jobs queued + jobs being processed)
//
// Because the spread is always < capacity, no two live chunks share the same
// slot index.  post() is a direct array write; next_in_order() is a direct read.
// Zero dynamic allocation after init.

const Sequencer = struct {
    mutex: std.Thread.Mutex,
    available: std.Thread.Condition,
    /// Pre-allocated ring of chunk-result slots, indexed by chunk_id % slots.len.
    slots: []?ChunkResult,
    /// chunk_id that collect() expects next.
    next_chunk_id: u64,
    /// Total chunks submitted; null until all submissions are complete.
    total_chunks: ?u64,
    allocator: std.mem.Allocator,

    fn init(capacity: usize, allocator: std.mem.Allocator) error{OutOfMemory}!Sequencer {
        const slots = try allocator.alloc(?ChunkResult, capacity);
        @memset(slots, null);
        return .{
            .mutex = .{},
            .available = .{},
            .slots = slots,
            .next_chunk_id = 0,
            .total_chunks = null,
            .allocator = allocator,
        };
    }

    fn deinit(s: *Sequencer) void {
        // Free arenas for any chunks that were never consumed by collect().
        for (s.slots) |*maybe| {
            if (maybe.*) |*cr| cr.arena.deinit();
        }
        s.allocator.free(s.slots);
    }

    /// Write a completed ChunkResult into its ring slot.
    ///
    /// Invariant: slot[chunk_id % capacity] is always null on entry.
    /// Guaranteed by InFlightLimiter (file mode) and QUEUE_CAP (stream mode):
    /// the number of simultaneously live chunks never exceeds `capacity`.
    fn post(s: *Sequencer, result: ChunkResult) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        const idx = result.chunk_id % s.slots.len;
        std.debug.assert(s.slots[idx] == null);
        s.slots[idx] = result;
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
            const idx = s.next_chunk_id % s.slots.len;
            if (s.slots[idx]) |cr| {
                s.slots[idx] = null;
                s.next_chunk_id += 1;
                return cr;
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

        // Per-chunk arena: all OwnedValue / serialized-byte memory is allocated here.
        // Freed atomically by collect()/collect_bytes() after the chunk is exhausted.
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

            const outcome = if (job.format) |fmt|
                process_line_serialized(
                    line,
                    &parser,
                    &opt_it,
                    &current_query,
                    job.query,
                    ctx.allocator,
                    aa,
                    fmt,
                )
            else
                process_line(
                    line,
                    &parser,
                    &opt_it,
                    &current_query,
                    job.query,
                    ctx.allocator,
                    aa,
                );

            records.append(aa, outcome) catch {
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

/// Parse and execute the query for a single JSONL line (structured path).
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

/// Parse and execute the query for a single JSONL line (serialized path).
///
/// Instead of copying values via own_value(), serializes each value directly
/// into an arena-backed byte buffer while the tape is still valid.
fn process_line_serialized(
    line: []const u8,
    parser: *parser_mod.Parser,
    opt_it: *?query_mod.ResultIterator,
    current_query: *?*const query_mod.CompiledQuery,
    query: *const query_mod.CompiledQuery,
    worker_alloc: std.mem.Allocator,
    aa: std.mem.Allocator,
    format: types.Format,
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
        opt_it.*.?.reset(tape);
    }

    // ── Serialize values directly into a byte buffer ──────────────────────────
    var buf = std.ArrayList(u8){};
    var sink = output_mod.BufferSink{ .list = &buf, .aa = aa };
    var last_was_false_or_null = false;
    while (true) {
        const maybe = opt_it.*.?.next() catch |e| {
            parser.reset();
            return .{ .err = e };
        };
        const val = maybe orelse break;

        // Serialize the value using the output module's generic serialize.
        output_mod.serialize(&sink, val, format) catch {
            parser.reset();
            return .{ .err = error.IoError };
        };

        // Append newline for pretty/compact formats (matches main.zig behavior).
        if (format == .pretty or format == .compact) {
            sink.writeByte('\n') catch {
                parser.reset();
                return .{ .err = error.IoError };
            };
        }

        last_was_false_or_null = switch (val) {
            .null_val => true,
            .bool_val => |b| !b,
            else => false,
        };
    }

    parser.reset();

    const data = buf.toOwnedSlice(aa) catch buf.items;

    return .{ .serialized = .{
        .data = data,
        .last_was_false_or_null = last_was_false_or_null,
    } };
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
    limiter: *InFlightLimiter,
    allocator: std.mem.Allocator,
    format: ?types.Format,
};

fn io_thread_fn(ctx: IoCtx) void {
    var chunk_id: u64 = 0;

    // partial_line: holds bytes of an incomplete line spanning RingBuffer boundaries.
    var partial_line = std.ArrayList(u8){};
    defer partial_line.deinit(ctx.allocator);

    // batch_buf: accumulates complete newline-terminated lines until STREAM_BATCH_SIZE.
    var batch_buf = std.ArrayList(u8){};
    defer batch_buf.deinit(ctx.allocator);

    loop: while (true) {
        const view = ctx.src.peek() catch break :loop;

        if (view.bytes.len == 0) {
            if (view.is_eof) {
                // EOF: flush partial line into batch, then flush batch.
                flushPartialToBatch(&partial_line, &batch_buf, ctx.allocator) catch break :loop;
                flushBatch(&batch_buf, &chunk_id, ctx);
                break :loop;
            }
            // No data available but not EOF (pipe stall): flush for latency.
            if (batch_buf.items.len > 0 or partial_line.items.len > 0) {
                flushPartialToBatch(&partial_line, &batch_buf, ctx.allocator) catch break :loop;
                flushBatch(&batch_buf, &chunk_id, ctx);
            }
            _ = ctx.src.refill() catch break :loop;
            continue;
        }

        // Scan view for newlines, appending complete lines to batch_buf.
        var consumed_offset: usize = 0;
        var scan: usize = 0;
        while (scan < view.bytes.len) : (scan += 1) {
            if (view.bytes[scan] == '\n') {
                // Complete line: partial_line (if any) + view[consumed_offset..scan] + '\n'
                if (partial_line.items.len > 0) {
                    partial_line.appendSlice(ctx.allocator, view.bytes[consumed_offset..scan]) catch break :loop;
                    batch_buf.appendSlice(ctx.allocator, partial_line.items) catch break :loop;
                    partial_line.clearRetainingCapacity();
                } else {
                    batch_buf.appendSlice(ctx.allocator, view.bytes[consumed_offset..scan]) catch break :loop;
                }
                batch_buf.append(ctx.allocator, '\n') catch break :loop;
                consumed_offset = scan + 1;

                // Flush when batch reaches threshold.
                if (batch_buf.items.len >= STREAM_BATCH_SIZE) {
                    flushBatch(&batch_buf, &chunk_id, ctx);
                }
            }
        }

        // Remainder after last newline goes into partial_line.
        if (consumed_offset < view.bytes.len) {
            partial_line.appendSlice(ctx.allocator, view.bytes[consumed_offset..]) catch break :loop;
        }
        ctx.src.consume(view.bytes.len);

        if (view.is_eof) {
            flushPartialToBatch(&partial_line, &batch_buf, ctx.allocator) catch break :loop;
            flushBatch(&batch_buf, &chunk_id, ctx);
            break :loop;
        }
        _ = ctx.src.refill() catch break :loop;
    }

    ctx.sequencer.set_total_chunks(chunk_id);
    ctx.queue.signal_done();
}

/// Flush the accumulated batch as a single Job.  Acquires an in-flight slot
/// for backpressure, dupes the buffer, and pushes to the worker queue.
fn flushBatch(batch_buf: *std.ArrayList(u8), chunk_id: *u64, ctx: IoCtx) void {
    if (batch_buf.items.len == 0) return;
    if (!ctx.limiter.acquire()) return; // shutdown
    const data = ctx.allocator.dupe(u8, batch_buf.items) catch return;
    ctx.queue.push(.{
        .data = data,
        .seq_base = chunk_id.*,
        .chunk_id = chunk_id.*,
        .query = ctx.query,
        .owns_data = true,
        .allocator = ctx.allocator,
        .format = ctx.format,
    });
    chunk_id.* += 1;
    batch_buf.clearRetainingCapacity();
}

/// Append any remaining partial line (without trailing newline) to the batch
/// buffer, so it is included in the final flush.
fn flushPartialToBatch(
    partial_line: *std.ArrayList(u8),
    batch_buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) error{OutOfMemory}!void {
    const trimmed = std.mem.trimRight(u8, partial_line.items, " \t\r");
    if (trimmed.len > 0) {
        try batch_buf.appendSlice(allocator, trimmed);
        try batch_buf.append(allocator, '\n');
    }
    partial_line.clearRetainingCapacity();
}

// ── File feeder thread ────────────────────────────────────────────────────────
//
// Iterates the mmap lazily: computes chunk boundaries on demand, acquires an
// in-flight slot from the limiter (blocking when max is reached), then enqueues
// the chunk to the worker queue.  This is the sole mechanism controlling how
// many arenas are simultaneously live for file-mode processing.

const FileFeedCtx = struct {
    data: []const u8,
    n_chunks: usize,
    query: *const query_mod.CompiledQuery,
    queue: *JobQueue,
    sequencer: *Sequencer,
    limiter: *InFlightLimiter,
    allocator: std.mem.Allocator,
    format: ?types.Format,
};

fn file_feeder_fn(ctx: FileFeedCtx) void {
    const data = ctx.data;
    const file_size = data.len;
    var chunk_start: usize = 0;
    var chunk_id: u64 = 0;

    for (0..ctx.n_chunks) |i| {
        const ideal_end = if (i + 1 == ctx.n_chunks)
            file_size
        else
            (i + 1) * file_size / ctx.n_chunks;

        // Align to newline so no record is split across chunks.
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
        if (!hasNonEmptyLine(chunk)) continue;

        // Block until a slot is available.  Returns false on shutdown (deinit).
        if (!ctx.limiter.acquire()) break;

        ctx.queue.push(.{
            .data = chunk,
            .seq_base = chunk_id,
            .chunk_id = chunk_id,
            .query = ctx.query,
            .owns_data = false,
            .allocator = ctx.allocator,
            .format = ctx.format,
        });
        chunk_id += 1;
    }

    // Always inform the Sequencer of the final total and stop workers,
    // even when we exit early due to shutdown.
    ctx.sequencer.set_total_chunks(chunk_id);
    ctx.queue.signal_done();
}

/// Return true if `data` contains at least one non-blank line.
fn hasNonEmptyLine(data: []const u8) bool {
    var rem = data;
    while (rem.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rem, '\n') orelse rem.len;
        const line = std.mem.trimRight(u8, rem[0..nl], " \t\r");
        if (line.len > 0) return true;
        rem = if (nl < rem.len) rem[nl + 1 ..] else &.{};
    }
    return false;
}

// ── SharedCtx — heap-allocated, ref-counted pool state ────────────────────────
//
// Pool is returned by value from init(), so JobQueue and Sequencer cannot live
// inside Pool directly (their addresses would move with the value copy).  We
// heap-allocate them in SharedCtx and keep a stable pointer in Pool.

const SharedCtx = struct {
    queue: JobQueue,
    sequencer: Sequencer,
    /// Backpressure limiter for file mode.  Feeder acquires before each chunk;
    /// collect()/collect_bytes() releases after each arena free.
    limiter: InFlightLimiter,
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

/// Stream-mode queue capacity.  The IO thread blocks on push() when full,
/// providing natural backpressure for streaming workloads.
const QUEUE_CAP: usize = 256;

/// Chunks per thread — more chunks than threads allows the OS scheduler to
/// balance load when records have uneven parse/query cost.
const CHUNK_FACTOR: usize = 4;

/// Stream-mode batch size in bytes.  The IO thread accumulates complete lines
/// until this threshold is reached, then pushes the batch as a single Job.
/// At ~300 B/record this yields ~850 records/batch, reducing millions of jobs
/// to a few thousand — same order of magnitude as file mode's chunk count.
const STREAM_BATCH_SIZE: usize = 256 * 1024; // 256 KiB

/// File-mode backpressure: max simultaneously-live ChunkResults per thread.
/// With 2× n_threads slots, each worker can have one chunk being processed and
/// one buffered in the Sequencer, keeping all cores busy while bounding RSS.
const IN_FLIGHT_FACTOR: usize = 2;

pub const Pool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    io_thread: ?std.Thread,
    _shared: *SharedCtx,

    // File-mode mmap lifetime management.
    // Non-null between submit_file() and the point in deinit() where threads join.
    // Workers hold read-only slices into this mapping; it must outlive all threads.
    _mmap: ?io_mod.MappedFile,

    // collect() cursor — maintains position across calls so multi-value queries
    // (e.g. `.[]`) deliver every output value before advancing to the next record.
    _delivering: ?ChunkResult, // chunk currently being consumed
    _rec_idx: usize, // index into _delivering.records[]
    _val_idx: usize, // index into _delivering.records[_rec_idx].values[]

    /// Output format for this pool run. null = structured path, non-null = serialized path.
    _format: ?types.Format,

    pub fn init(n_threads: usize, allocator: std.mem.Allocator) error{OutOfMemory}!Pool {
        const shared = try allocator.create(SharedCtx);
        errdefer allocator.destroy(shared);

        var queue = try JobQueue.init(QUEUE_CAP, allocator);
        errdefer queue.deinit();

        // Ring capacity must exceed the maximum spread of simultaneously live
        // chunk IDs across both operating modes:
        //   • File mode:   IN_FLIGHT_FACTOR × n_threads  (capped by InFlightLimiter)
        //   • Stream mode: QUEUE_CAP + n_threads          (queue depth + workers)
        // Taking the max covers both; the allocation is at most a few KB.
        const n_eff = @max(1, n_threads);
        const seq_capacity = @max(IN_FLIGHT_FACTOR * n_eff, QUEUE_CAP + n_eff);
        var sequencer = try Sequencer.init(seq_capacity, allocator);
        errdefer sequencer.deinit();

        const max_in_flight = IN_FLIGHT_FACTOR * @max(1, n_threads);
        shared.* = .{
            .queue = queue,
            .sequencer = sequencer,
            .limiter = InFlightLimiter.init(max_in_flight),
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
            ._format = null,
        };
    }

    pub fn deinit(p: *Pool) void {
        // Unblock the feeder if it is stalled on limiter.acquire(), then stop
        // all workers.  Order matters: limiter shutdown first so the feeder can
        // wake up and call queue.signal_done() (or we call it below if it doesn't).
        p._shared.limiter.signal_shutdown();
        p._shared.queue.signal_done();
        if (p.io_thread) |t| t.join();
        // Join workers BEFORE unmapping — workers may still read mmap memory.
        for (p.threads) |t| t.join();
        p.allocator.free(p.threads);
        release_shared(p._shared, p.allocator);
        // Unmap only after all threads have exited.
        if (p._mmap) |*m| m.deinit();
        // Free any partially-consumed chunk that collect()/collect_bytes() hadn't exhausted.
        if (p._delivering) |*cr| cr.arena.deinit();
    }

    /// Submit a regular file for parallel processing.
    ///
    /// The file is memory-mapped once.  A dedicated feeder thread lazily splits
    /// the mapping into at most n_threads × CHUNK_FACTOR newline-aligned chunks
    /// and enqueues them one at a time, blocking when IN_FLIGHT_FACTOR × n_threads
    /// chunks are already in-flight.  collect()/collect_bytes() releases each slot
    /// when it frees a chunk's arena, so peak RSS is proportional to the in-flight
    /// limit, not the full file size.
    ///
    /// When `format` is non-null, workers use the serialized path: values are
    /// serialized directly into byte buffers. Use collect_bytes() to consume.
    /// When `format` is null, workers use the structured path. Use collect().
    pub fn submit_file(
        p: *Pool,
        file: std.fs.File,
        cq: *const query_mod.CompiledQuery,
        format: ?types.Format,
    ) ZqError!void {
        p._format = format;
        const stat = file.stat() catch return error.IoError;
        const file_size = @as(usize, @intCast(stat.size));

        if (file_size == 0) {
            p._shared.sequencer.set_total_chunks(0);
            p._shared.queue.signal_done();
            return;
        }

        p._mmap = io_mod.MappedFile.init(file, file_size) catch return error.IoError;
        const n_threads = @max(1, p.threads.len);
        const n_chunks = n_threads * CHUNK_FACTOR;

        const ctx_ptr = p.allocator.create(FileFeedCtx) catch {
            // Unmap before returning so _mmap doesn't dangle.
            p._mmap.?.deinit();
            p._mmap = null;
            p._shared.sequencer.set_total_chunks(0);
            p._shared.queue.signal_done();
            return error.IoError;
        };
        ctx_ptr.* = .{
            .data = p._mmap.?.data,
            .n_chunks = n_chunks,
            .query = cq,
            .queue = &p._shared.queue,
            .sequencer = &p._shared.sequencer,
            .limiter = &p._shared.limiter,
            .allocator = p.allocator,
            .format = format,
        };

        p.io_thread = std.Thread.spawn(.{}, struct {
            fn run(c: *FileFeedCtx) void {
                const alloc = c.allocator;
                file_feeder_fn(c.*);
                alloc.destroy(c);
            }
        }.run, .{ctx_ptr}) catch {
            p.allocator.destroy(ctx_ptr);
            p._mmap.?.deinit();
            p._mmap = null;
            p._shared.sequencer.set_total_chunks(0);
            p._shared.queue.signal_done();
            return error.IoError;
        };
    }

    /// Submit a streaming source (stdin, pipe, …) for pipeline processing.
    ///
    /// A dedicated IO thread reads complete newline-terminated lines from `src`
    /// and posts them to worker threads.  Each line is an independent chunk
    /// (chunk_id == seq_base) so the Sequencer delivers results line-by-line.
    ///
    /// When `format` is non-null, workers use the serialized path.
    /// When null, workers use the structured path.
    pub fn submit_stream(
        p: *Pool,
        src: *io_mod.Source,
        cq: *const query_mod.CompiledQuery,
        format: ?types.Format,
    ) void {
        p._format = format;
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
            .limiter = &p._shared.limiter,
            .allocator = p.allocator,
            .format = format,
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

    /// Return the next result in submission order (structured path).
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
            if (p._rec_idx >= p._delivering.?.records.len) {
                p._delivering.?.arena.deinit();
                p._shared.limiter.release();
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
                .serialized => {
                    // Wrong path: collect() is for the structured path.
                    // Advance past this record.
                    p._rec_idx += 1;
                    p._val_idx = 0;
                },
            }
        }
    }

    /// Return pre-serialized bytes for the next record in submission order
    /// (serialized path).
    ///
    /// Blocks until the next in-order record is available or all work is done.
    /// Returns null when all submitted records have been processed.
    /// Returns an error if a worker encountered a parse or query error on a record.
    ///
    /// Lifetime: the returned data is valid until the NEXT call to collect_bytes()
    /// or deinit().
    pub fn collect_bytes(p: *Pool) ZqError!?BytesResult {
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
            if (p._rec_idx >= p._delivering.?.records.len) {
                p._delivering.?.arena.deinit();
                p._shared.limiter.release();
                p._delivering = null;
                continue;
            }

            // ── Dispatch on the current record's outcome ─────────────────────────
            switch (p._delivering.?.records[p._rec_idx]) {
                .err => |e| {
                    p._rec_idx += 1;
                    p._val_idx = 0;
                    return e;
                },
                .serialized => |sr| {
                    p._rec_idx += 1;
                    p._val_idx = 0;
                    // Skip empty records (e.g. select(false) produces no output).
                    if (sr.data.len == 0) continue;
                    return BytesResult{
                        .data = sr.data,
                        .last_was_false_or_null = sr.last_was_false_or_null,
                    };
                },
                .values => {
                    // Wrong path: collect_bytes() is for the serialized path.
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
