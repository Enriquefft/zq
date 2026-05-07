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
/// submit_file() mmap's the entire file and splits it into newline-aligned chunks.
/// Chunk count and in-flight limit are computed adaptively from a MemoryBudget
/// (defaults match the old hardcoded values on >=4 GB systems with typical files).
/// A dedicated feeder thread lazily pushes chunks to the worker queue one at a time,
/// blocking when the in-flight limit is reached.  Workers dequeue one chunk, process
/// every record in it, and post a ChunkResult to the Sequencer.
///
/// Stream mode
/// -----------
/// submit_stream() starts an IO thread that reads complete lines from a Source.
/// Each line becomes its own single-record ChunkResult (chunk_id = line number).
/// Latency-first: no buffering so output appears as each line is processed.
///
/// Memory model
/// ------------
/// Every ChunkResult owns an ArenaAllocator that backs all payload data for that
/// chunk.  Structured path: RecordOutcome slices, OwnedValue copies, strings, tape
/// entries.  Serialized path: one contiguous byte buffer + compact RecordMeta array
/// (8 bytes/record vs ~32 for the old per-record approach).
/// collect()/collect_bytes() frees the arena atomically once the chunk is exhausted.
///
/// Backpressure (file mode)
/// ------------------------
/// An InFlightLimiter caps the number of simultaneously live ChunkResults to
/// in_flight_factor × n_threads (computed from the memory budget).  The feeder
/// acquires a slot before pushing each chunk to the queue; collect()/collect_bytes()
/// releases the slot after freeing the chunk's arena.
/// Peak RSS is proportional to the in-flight limit, not the full file size.
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
/// both modes (file: MAX_IN_FLIGHT_FACTOR×n_threads; stream: QUEUE_CAP+n_threads).
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

/// Global Sparser-prefilter statistics. Incremented (relaxed atomic) from
/// every worker when a record is skipped because its raw bytes failed the
/// literal prescreen. Exposed as a simple counter for tests and benchmarks —
/// the number is informational; no program logic depends on it.
///
/// Reset explicitly by callers that want a per-run count
/// (`prefilter_stats.reset()`). Never reset implicitly.
pub const prefilter_stats = struct {
    pub const Counters = struct {
        skipped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        evaluated: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    };
    pub var counters: Counters = .{};

    pub fn reset() void {
        counters.skipped.store(0, .monotonic);
        counters.evaluated.store(0, .monotonic);
    }

    pub fn skipped() u64 {
        return counters.skipped.load(.monotonic);
    }

    pub fn evaluated() u64 {
        return counters.evaluated.load(.monotonic);
    }
};

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
    /// Out-of-range numeric literal (overflow/underflow for f64).
    /// Backed by the per-chunk arena; dupe of Value.big_number.
    big_number: []u8,
    string: []u8,
    tape_value: OwnedTapeValue,
};

// ── Per-chunk result structures ────────────────────────────────────────────────

/// Compact per-record metadata for the serialized path.
/// 8 bytes per record (vs ~32 for the old RecordOutcome + separate data allocation).
const RecordMeta = struct {
    /// Exclusive byte offset in the chunk's data buffer.
    end_offset: u32,
    /// For -e flag: true if the last value produced was false or null.
    last_was_false_or_null: bool,
    /// If true, error_code is valid and this record produced an error.
    is_error: bool,
    /// @intFromError(ZqError), valid when is_error is true.
    error_code: u16,
    /// Instruction pointer when the error occurred (for diagnostics).
    error_ip: u16 = 0,
};

/// Compile-time guard exported for tests: pins the current `RecordMeta`
/// layout so any new per-record field fails the regression test in
/// `tests/pool_test.zig`. Per-record fields scale linearly with record
/// count; diagnostic side channels (e.g. `user_error_msg`) belong on
/// `ChunkResult` instead — see the per-chunk slot nearby.
pub const record_meta_size_for_test: usize = @sizeOf(RecordMeta);

/// All serialized output for one chunk — one contiguous buffer, no per-record allocations.
const SerializedChunk = struct {
    /// All records' bytes concatenated.
    data: []const u8,
    /// One entry per record.
    records: []const RecordMeta,
};

/// Outcome of processing a single JSONL record within a chunk (structured path only).
const RecordOutcome = union(enum) {
    /// Values produced by the query (structured path).
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
    /// True when this chunk is the LAST partial within its Job's reserved sub-id
    /// range `[seq_base .. seq_base + seq_range_size)`. The Sequencer skips any
    /// trailing unused sub-ids in the range when delivering this chunk so the
    /// dense-id invariant (next_chunk_id advances over delivered + skipped) is
    /// preserved. Single-chunk Jobs (file mode, seq_range_size=1) always set
    /// `end_of_range = true` with sub_id 0.
    end_of_range: bool = true,
    /// Worker-allocated reservation size for this chunk's Job. The Sequencer
    /// uses (seq_base + seq_range_size) to skip unused trailing slots when
    /// `end_of_range` is observed. Must equal Job.seq_range_size.
    seq_range_size: u32 = 1,
    /// Path-specific payload.
    payload: union(enum) {
        /// Structured path: one RecordOutcome per record.
        structured: []RecordOutcome,
        /// Serialized path: one contiguous buffer + compact per-record metadata.
        serialized: SerializedChunk,
    },
    /// Last user-facing error message produced by any record in this chunk.
    /// Non-null only when at least one record raised `error("...")` or a
    /// builtin that populates `ResultIterator.user_error_msg`. Last-write-wins
    /// within a chunk; the message is arena-allocated (lifetime tied to the
    /// chunk) so the collector can surface it to `formatDiagnostic` without
    /// additional copies. The worker is the sole writer (before `post()`),
    /// the collector is the sole reader (after `next_in_order()`), so no
    /// synchronization is required beyond the `post()` release edge.
    user_error_msg: ?[]const u8 = null,
    /// Owns all memory for `payload` and every OwnedValue/serialized byte within.
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
    style: ?types.OutputStyle,
    /// ANSI color configuration. Null means no color output.
    color: ?*const output_mod.Color,
    /// Serialization options (sort_keys, indent).
    opts: output_mod.SerializeOpts,
    /// When true, each line is treated as a raw string instead of being parsed as JSON.
    raw_input: bool,
    /// External variable bindings, shared read-only across all workers.
    external_bindings: []const query_mod.ExternalVarBinding,
    /// Sub-id range reserved for this Job's chunk publications.
    /// File mode: 1 (one ChunkResult per Job, posted with end_of_range=true).
    /// Stream mode: STREAM_SEQ_RANGE (the worker may publish multiple partial
    /// ChunkResults with chunk_ids `seq_base + 0 .. seq_base + sub_id`, then a
    /// final partial with `end_of_range = true` to release any unused slots).
    /// The submitter must arrange chunk_id assignments so that ranges from
    /// distinct Jobs do not overlap.
    seq_range_size: u32 = 1,
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
// the chunk's arena.  This bounds peak RSS to in_flight_factor × chunk_size ×
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

    /// Update the maximum number of in-flight slots.
    /// Called before the feeder starts, so no concurrent acquire() is active.
    fn set_max(self: *InFlightLimiter, new_max: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.max = new_max;
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
//   • File mode:   MAX_IN_FLIGHT_FACTOR × n_threads (upper bound for InFlightLimiter)
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

    /// Pin the total chunk count.  First-writer-wins: subsequent calls (e.g.
    /// from `Pool.deinit` after the IO thread or last worker has already
    /// pinned the value) are ignored so a late shutdown can't shrink the
    /// total below the high-water mark of already-published chunk_ids.
    fn set_total_chunks(s: *Sequencer, total: u64) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        if (s.total_chunks != null) return;
        s.total_chunks = total;
        s.available.broadcast();
    }

    /// Block until the next in-order ChunkResult is available, then return it.
    /// Returns null when all chunks have been delivered.
    ///
    /// When the delivered chunk has `end_of_range = true`, advances
    /// `next_chunk_id` to `seq_base + seq_range_size` so any unused trailing
    /// sub-ids in the Job's reservation are skipped. For non-streaming Jobs
    /// (seq_range_size = 1) this is identical to the simple +1 advance.
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
                if (cr.end_of_range) {
                    // Skip any trailing reserved-but-unused sub-ids in the Job.
                    s.next_chunk_id = cr.seq_base + cr.seq_range_size;
                } else {
                    s.next_chunk_id += 1;
                }
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
    /// Stream-mode partial-flush backpressure: workers call `acquire` for each
    /// partial publish beyond the first to keep peak in-flight memory bounded.
    limiter: *InFlightLimiter,
    /// Shared range allocator — workers `fetchAdd(STREAM_SEQ_RANGE)` mid-Job
    /// to chain a fresh range when the current reservation fills.
    next_seq_range_base: *std.atomic.Value(u64),
    /// Hot-path cooperative shutdown signal observed in the streaming emit
    /// loop.  Set by `Pool.deinit`; read by the worker every value-emit
    /// iteration so consumer-close (closed pipe / SIGTERM) breaks out
    /// promptly even inside an unbounded generator.
    shutdown: *std.atomic.Value(bool),
    /// Active stream-mode Jobs counter; the worker decrements after the
    /// final partial post for each Job.  When the IO thread has signaled
    /// `io_done` and this counter reaches zero, the worker pins
    /// `total_chunks = next_seq_range_base` so a blocked collector unblocks.
    active_stream_jobs: *std.atomic.Value(u64),
    io_done: *std.atomic.Value(bool),
    allocator: std.mem.Allocator,
};

/// Pin `Sequencer.total_chunks` iff (a) the IO thread has finished pushing
/// Jobs and (b) no stream-mode Jobs are still in-flight — i.e. no further
/// sub-id ranges will ever be claimed.  First-writer-wins inside
/// `set_total_chunks`, so racing callers (last worker vs. IO thread vs.
/// `Pool.deinit`) all converge on the same pinned value.  SSOT for the
/// `(io_done && active_stream_jobs == 0)` invariant — invoked from both
/// worker paths after their final per-Job `fetchSub` and from `io_thread_fn`
/// after `io_done.store`.
fn try_pin_total_chunks(
    sequencer: *Sequencer,
    next_seq_range_base: *std.atomic.Value(u64),
    active_stream_jobs: *std.atomic.Value(u64),
    io_done: *std.atomic.Value(bool),
) void {
    if (io_done.load(.acquire) and active_stream_jobs.load(.acquire) == 0) {
        sequencer.set_total_chunks(next_seq_range_base.load(.monotonic));
    }
}

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
        // INVARIANT: job.data must not be accessed after sequencer.post().
        // Serialized path: output bytes are in the arena, not in job.data.
        // Structured path: own_value() copies all tape spans + strings into the
        // arena before post(); parser.reset() clears the tape after each record.
        // Violating this invariant causes silent disk re-reads, not corruption.
        //
        // MADV_DONTNEED releases the physical pages immediately (Linux only),
        // bounding mmap RSS to O(in_flight × chunk_size) instead of O(file_size).
        defer if (!job.owns_data) madvise_dontneed_chunk(job.data);

        if (job.style) |style| {
            // ── Serialized path: single contiguous buffer + compact metadata ──
            //
            // Stream-mode Jobs may publish multiple partial ChunkResults inside
            // their reserved sub-id range (`seq_base .. seq_base + seq_range_size`).
            // File-mode Jobs always have seq_range_size = 1 → exactly one post.
            //
            // Per-chunk arena: all OwnedValue / serialized-byte memory is
            // allocated here.  Freed atomically by collect_bytes() after the
            // chunk is exhausted.  Each partial flush hands its arena off to
            // the sequencer and starts a fresh one — see partial_flush.
            var state = SerializeJobState{
                .arena = std.heap.ArenaAllocator.init(ctx.allocator),
                .aa = undefined,
                .chunk_buf = std.ArrayList(u8){},
                .meta_list = std.ArrayList(RecordMeta){},
                .chunk_user_error_msg = null,
                .sequencer = ctx.sequencer,
                .limiter = ctx.limiter,
                .next_seq_range_base = ctx.next_seq_range_base,
                .shutdown = ctx.shutdown,
                .pool_alloc = ctx.allocator,
                .style = style,
                .seq_base = job.seq_base,
                .seq_range_size = job.seq_range_size,
                .sub_id = 0,
                // Threshold > 0 only when the Job was reserved with multiple
                // sub-ids (stream mode).  File-mode Jobs run as before with
                // a single arena and a single post.
                .flush_threshold = if (job.seq_range_size > 1) STREAM_FLUSH_THRESHOLD else 0,
            };
            state.aa = state.arena.allocator();

            // Count records first so meta_list can be exactly pre-allocated.
            // This prevents interleaving: meta_list is allocated FIRST (exact,
            // never grows), then chunk_buf is allocated SECOND.  Because
            // chunk_buf is always the arena's last allocation, it can resize
            // in-place when output exceeds input size (e.g. pretty format) —
            // no leaked copies from ArrayList doubling.
            const record_count = blk: {
                if (job.raw_input) {
                    var count = countNewlines(job.data);
                    // Account for a final line without trailing newline.
                    if (job.data.len > 0 and job.data[job.data.len - 1] != '\n') count += 1;
                    break :blk count;
                }
                break :blk parser_mod.boundary.countTopLevelValues(job.data);
            };
            state.meta_list.ensureTotalCapacity(state.aa, record_count) catch {};
            // Pretty-printed compounds expand ~6× input size; compact emits
            // close to input size. raw_strings only changes string scalars
            // (negligible) so the multiplier follows compact vs pretty.
            const buf_estimate: usize = if (style.compact)
                job.data.len
            else
                job.data.len * 6;
            state.chunk_buf.ensureTotalCapacity(state.aa, buf_estimate) catch {};

            const ProcessOne = struct {
                fn call(
                    value_bytes: []const u8,
                    tape: types.Tape,
                    raw: bool,
                    s: *SerializeJobState,
                    p_opt_it: *?query_mod.ResultIterator,
                    p_current_query: *?*const query_mod.CompiledQuery,
                    j: Job,
                    ctx_alloc: std.mem.Allocator,
                ) void {
                    const meta_count_before = s.meta_list.items.len;

                    process_value_serialized(
                        value_bytes,
                        tape,
                        p_opt_it,
                        p_current_query,
                        j.query,
                        ctx_alloc,
                        j.color,
                        j.opts,
                        raw,
                        j.external_bindings,
                        s,
                    );

                    // Capture any VM-side user error message before the iterator
                    // is reset on the next record. Only VM errors (not parse
                    // errors) populate this; `process_value_serialized` leaves
                    // the iterator valid after such an error.
                    var saw_error = false;
                    if (s.meta_list.items.len > meta_count_before) {
                        const last = s.meta_list.items[s.meta_list.items.len - 1];
                        saw_error = last.is_error;
                    }
                    if (saw_error) {
                        if (p_opt_it.*) |*it| {
                            if (it.user_error_msg) |msg| {
                                switch (msg) {
                                    .string => |sv| {
                                        const duped = s.aa.dupe(u8, sv.slice()) catch null;
                                        if (duped) |d| s.chunk_user_error_msg = d;
                                    },
                                    else => {},
                                }
                            }
                        }
                    }
                }
            }.call;

            if (job.raw_input) {
                // ── Raw-input: line-oriented split on \n (jq --raw-input parity) ──
                var remaining: []const u8 = job.data;
                while (remaining.len > 0) {
                    const nl = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
                    const line = stripTrailingCr(remaining[0..nl]);
                    remaining = if (nl < remaining.len) remaining[nl + 1 ..] else &.{};

                    var raw_entry_buf: [1]types.Tape.Entry = undefined;
                    const tape = make_raw_tape(line, &raw_entry_buf);
                    ProcessOne(line, tape, true, &state, &opt_it, &current_query, job, ctx.allocator);
                }
            } else {
                // ── JSON path: structural feed-loop, depth-aware boundary advance ──
                var cursor: usize = 0;
                while (cursor < job.data.len) {
                    cursor += parser_mod.simd.skipWhitespace(job.data[cursor..]);
                    if (cursor >= job.data.len) break;

                    const value_start = cursor;
                    const result = parser.feed(job.data[cursor..], true) catch |e| {
                        const append_err = struct {
                            fn call(s: *SerializeJobState, code: u16) void {
                                const meta = RecordMeta{
                                    .end_offset = @intCast(s.chunk_buf.items.len),
                                    .last_was_false_or_null = false,
                                    .is_error = true,
                                    .error_code = code,
                                };
                                s.meta_list.append(s.aa, meta) catch {};
                            }
                        }.call;
                        append_err(&state, @intFromError(@as(ZqError, @errorCast(e))));
                        parser.reset();
                        // Recover: skip to the next \n (best-effort) and continue.
                        const skip = std.mem.indexOfScalar(u8, job.data[cursor..], '\n') orelse (job.data.len - cursor);
                        cursor += skip;
                        if (cursor < job.data.len) cursor += 1;
                        continue;
                    };
                    switch (result) {
                        .done => |d| {
                            // `processEof` returns consumed=0 when the parser
                            // walked the whole slice and finalized via EOF
                            // (number at end-of-buffer, no terminator).
                            // Advance to end-of-slice in that case.
                            const advance = if (d.consumed == 0) job.data.len - value_start else d.consumed;
                            const value_bytes = job.data[value_start .. value_start + advance];
                            ProcessOne(value_bytes, d.tape, false, &state, &opt_it, &current_query, job, ctx.allocator);
                            parser.reset();
                            cursor = value_start + advance;
                        },
                        .need_more => {
                            // Should not occur post-NIX-001 (chunker aligns on
                            // depth-0 boundaries). Treat defensively as a parse
                            // error and stop processing this chunk.
                            const meta = RecordMeta{
                                .end_offset = @intCast(state.chunk_buf.items.len),
                                .last_was_false_or_null = false,
                                .is_error = true,
                                .error_code = @intFromError(@as(ZqError, error.UnexpectedEof)),
                            };
                            state.meta_list.append(state.aa, meta) catch {};
                            parser.reset();
                            break;
                        },
                    }
                }
            }

            // Final post for this Job (carries `end_of_range = true` so the
            // Sequencer skips any unused trailing sub-ids in the reservation).
            partial_flush(&state, true);

            // Stream-mode Job accounting: this Job will not claim any more
            // ranges.  File-mode Jobs (seq_range_size == 1) are tracked
            // separately by `set_total_chunks` in `file_feeder_fn`.
            if (job.seq_range_size > 1) {
                _ = ctx.active_stream_jobs.fetchSub(1, .acq_rel);
                try_pin_total_chunks(ctx.sequencer, ctx.next_seq_range_base, ctx.active_stream_jobs, ctx.io_done);
            }
        } else {
            // ── Structured path: one RecordOutcome per record ─────────────────
            var arena = std.heap.ArenaAllocator.init(ctx.allocator);
            const aa = arena.allocator();
            var records = std.ArrayList(RecordOutcome){};

            const append_outcome = struct {
                fn call(rs: *std.ArrayList(RecordOutcome), a: std.mem.Allocator, oc: RecordOutcome) void {
                    rs.append(a, oc) catch {
                        rs.append(a, .{ .err = error.IoError }) catch {};
                    };
                }
            }.call;

            if (job.raw_input) {
                var remaining: []const u8 = job.data;
                while (remaining.len > 0) {
                    const nl = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
                    const line = stripTrailingCr(remaining[0..nl]);
                    remaining = if (nl < remaining.len) remaining[nl + 1 ..] else &.{};

                    var raw_entry_buf: [1]types.Tape.Entry = undefined;
                    const tape = make_raw_tape(line, &raw_entry_buf);
                    const outcome = process_value(
                        line,
                        tape,
                        &opt_it,
                        &current_query,
                        job.query,
                        ctx.allocator,
                        aa,
                        true,
                        job.external_bindings,
                    );
                    append_outcome(&records, aa, outcome);
                }
            } else {
                var cursor: usize = 0;
                while (cursor < job.data.len) {
                    cursor += parser_mod.simd.skipWhitespace(job.data[cursor..]);
                    if (cursor >= job.data.len) break;

                    const value_start = cursor;
                    const result = parser.feed(job.data[cursor..], true) catch |e| {
                        append_outcome(&records, aa, .{ .err = @as(ZqError, @errorCast(e)) });
                        parser.reset();
                        const skip = std.mem.indexOfScalar(u8, job.data[cursor..], '\n') orelse (job.data.len - cursor);
                        cursor += skip;
                        if (cursor < job.data.len) cursor += 1;
                        continue;
                    };
                    switch (result) {
                        .done => |d| {
                            const advance = if (d.consumed == 0) job.data.len - value_start else d.consumed;
                            const value_bytes = job.data[value_start .. value_start + advance];
                            const outcome = process_value(
                                value_bytes,
                                d.tape,
                                &opt_it,
                                &current_query,
                                job.query,
                                ctx.allocator,
                                aa,
                                false,
                                job.external_bindings,
                            );
                            append_outcome(&records, aa, outcome);
                            parser.reset();
                            cursor = value_start + advance;
                        },
                        .need_more => {
                            append_outcome(&records, aa, .{ .err = error.UnexpectedEof });
                            parser.reset();
                            break;
                        },
                    }
                }
            }

            const records_slice = records.toOwnedSlice(aa) catch records.items;

            ctx.sequencer.post(ChunkResult{
                .chunk_id = job.chunk_id,
                .seq_base = job.seq_base,
                .end_of_range = true,
                .seq_range_size = job.seq_range_size,
                .payload = .{ .structured = records_slice },
                .arena = arena,
            });

            // Stream-mode Job accounting (structured path mirror of the
            // serialized branch above).  File-mode Jobs (seq_range_size==1)
            // are tracked by `file_feeder_fn` and skip this path.
            if (job.seq_range_size > 1) {
                _ = ctx.active_stream_jobs.fetchSub(1, .acq_rel);
                try_pin_total_chunks(ctx.sequencer, ctx.next_seq_range_base, ctx.active_stream_jobs, ctx.io_done);
            }
        }
    }
}

/// Construct a synthetic Tape with a single .string entry that borrows the
/// line bytes directly.  Zero-copy, zero allocation — used for --raw-input.
fn make_raw_tape(line: []const u8, entry_buf: *[1]types.Tape.Entry) types.Tape {
    entry_buf[0] = .{
        .tag = .string,
        .payload = .{ .string = .{ .offset = 0, .len = @intCast(line.len) } },
    };
    return .{
        .entries = entry_buf,
        .string_buf = line,
    };
}

/// Execute the query for a single pre-parsed JSON value (structured path).
///
/// The caller drives `parser.feed` and passes the resulting `tape` plus the
/// `value_bytes` slice that produced it (used for the literal-substring
/// prefilter). The caller is also responsible for `parser.reset()` after
/// this returns — the tape borrows from parser-owned buffers, so it must
/// remain valid through `collect_record_values`.
///
/// `worker_alloc` — used for the persistent ResultIterator's eval stack (GPA).
/// `aa`           — per-chunk arena; used for all OwnedValue copies.
fn process_value(
    value_bytes: []const u8,
    tape: types.Tape,
    opt_it: *?query_mod.ResultIterator,
    current_query: *?*const query_mod.CompiledQuery,
    query: *const query_mod.CompiledQuery,
    worker_alloc: std.mem.Allocator,
    aa: std.mem.Allocator,
    raw_input: bool,
    external_bindings: []const query_mod.ExternalVarBinding,
) RecordOutcome {
    // ── Sparser prefilter ───────────────────────────────────────────────────────
    // Raw-byte literal scan. When present AND the record's bytes fail the
    // scan, skip straight to an empty outcome — the select(...|regex(lit))
    // idiom would have produced no output for this record anyway. The cost
    // we save is a full JSON parse + regex engine run. See src/prefilter/root.zig.
    if (!raw_input) {
        if (query.prefilter) |pf| {
            _ = prefilter_stats.counters.evaluated.fetchAdd(1, .monotonic);
            if (!pf.accept(value_bytes)) {
                _ = prefilter_stats.counters.skipped.fetchAdd(1, .monotonic);
                return .{ .values = &[_]OwnedValue{} };
            }
        }
    }

    // ── Bind or rebind the ResultIterator ──────────────────────────────────────
    if (opt_it.* == null or current_query.* != query) {
        if (opt_it.*) |*it| it.deinit();
        opt_it.* = query.execute(tape, external_bindings, worker_alloc) catch {
            opt_it.* = null;
            current_query.* = null;
            return .{ .err = error.IoError };
        };
        current_query.* = query;
    } else {
        // Same query, new tape: zero-allocation rebind.
        opt_it.*.?.reset(tape, external_bindings);
    }

    // ── Collect values into the chunk arena ────────────────────────────────────
    return collect_record_values(&opt_it.*.?, aa);
}

/// Per-Job mutable state for the serialized path.  Owned by `worker_fn` and
/// passed by pointer through `process_line_serialized` so the per-line drain
/// loop can publish partial ChunkResults when the buffer crosses the
/// `STREAM_FLUSH_THRESHOLD`, then rebind the arena/buffers for the next
/// partial.  See `partial_flush` and `STREAM_SEQ_RANGE`.
const SerializeJobState = struct {
    arena: std.heap.ArenaAllocator,
    aa: std.mem.Allocator,
    chunk_buf: std.ArrayList(u8),
    meta_list: std.ArrayList(RecordMeta),
    chunk_user_error_msg: ?[]const u8,

    // Read-only references to the surrounding worker context.
    sequencer: *Sequencer,
    limiter: *InFlightLimiter,
    /// Shared atomic counter for chaining a fresh sub-id range when this
    /// Job's current reservation fills (infinite-generator support).
    next_seq_range_base: *std.atomic.Value(u64),
    /// Cooperative shutdown signal observed by `process_line_serialized`'s
    /// per-iteration check.
    shutdown: *std.atomic.Value(bool),
    pool_alloc: std.mem.Allocator,
    style: types.OutputStyle,

    // Stream-mode partial-flush configuration for the current Job.
    seq_base: u64,
    seq_range_size: u32,
    sub_id: u32,
    flush_threshold: usize, // 0 disables partial flush
};

/// Publish the current accumulated chunk_buf + meta_list as a ChunkResult,
/// then (unless `is_final`) reset the arena/buffers for the next partial.
///
/// Three flush kinds:
///  - `is_final = true`:                end_of_range = true; Job is done.
///  - mid-range  (sub_id + 1 < range):  end_of_range = false; bump sub_id.
///  - range-end  (sub_id + 1 == range): end_of_range = true; chain a fresh
///                                      range via `next_seq_range_base`
///                                      (re-base seq_base, reset sub_id = 0).
///
/// Range chaining unblocks infinite generators: a worker can publish an
/// arbitrary number of partials without ever exceeding STREAM_SEQ_RANGE
/// in-flight per range.
fn partial_flush(state: *SerializeJobState, is_final: bool) void {
    const data_slice = state.chunk_buf.items;
    const meta_slice = state.meta_list.items;

    // The current range is exhausted iff the partial we're about to post
    // occupies the last sub-id slot in `[seq_base, seq_base+seq_range_size)`.
    // Setting `end_of_range = true` releases the slot to the Sequencer and
    // (for non-final flushes) signals that the next partial belongs to a
    // brand-new range.
    const range_full = state.sub_id + 1 >= state.seq_range_size;
    const end_of_range = is_final or range_full;

    state.sequencer.post(ChunkResult{
        .chunk_id = state.seq_base + state.sub_id,
        .seq_base = state.seq_base,
        .end_of_range = end_of_range,
        .seq_range_size = state.seq_range_size,
        .payload = .{ .serialized = .{
            .data = data_slice,
            .records = meta_slice,
        } },
        .user_error_msg = state.chunk_user_error_msg,
        .arena = state.arena,
    });

    if (is_final) return;

    // Reserve the next slot's in-flight allowance before we resume work, so
    // the limiter properly bounds peak memory across partials within a Job.
    // On shutdown we still allocate a fresh arena so the worker's defer loop
    // remains balanced; subsequent flushes will just observe the shutdown.
    _ = state.limiter.acquire();

    if (range_full) {
        // Chain into a brand-new range — the only way an unbounded generator
        // can keep publishing without an in-memory cap.
        state.seq_base = state.next_seq_range_base.fetchAdd(state.seq_range_size, .monotonic);
        state.sub_id = 0;
    } else {
        state.sub_id += 1;
    }

    state.arena = std.heap.ArenaAllocator.init(state.pool_alloc);
    state.aa = state.arena.allocator();
    state.chunk_buf = std.ArrayList(u8){};
    state.meta_list = std.ArrayList(RecordMeta){};
    state.chunk_user_error_msg = null;
}

/// Execute the query for a single pre-parsed JSON value (serialized path).
///
/// The caller drives `parser.feed` and passes the resulting `tape` plus the
/// `value_bytes` slice that produced it (used for the literal-substring
/// prefilter). The caller is also responsible for `parser.reset()` after
/// this returns — the tape borrows from parser-owned buffers and must
/// remain valid through serialization.
///
/// Instead of copying values via own_value(), serializes each value directly
/// into the shared chunk buffer while the tape is still valid.  Appends one
/// or more `RecordMeta` entries to `state.meta_list` — multiple entries when
/// partial flushes split the per-line iterator drain across ChunkResults.
///
/// When `state.flush_threshold` is non-zero, the per-value loop checks the
/// buffer size after each newline boundary and calls `partial_flush` when
/// the threshold is crossed.  This is the unblocker for infinite generators
/// (`repeat(.+1)`, etc.) — see bugs.md #143.
fn process_value_serialized(
    value_bytes: []const u8,
    tape: types.Tape,
    opt_it: *?query_mod.ResultIterator,
    current_query: *?*const query_mod.CompiledQuery,
    query: *const query_mod.CompiledQuery,
    worker_alloc: std.mem.Allocator,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    raw_input: bool,
    external_bindings: []const query_mod.ExternalVarBinding,
    state: *SerializeJobState,
) void {
    var start: u32 = @intCast(state.chunk_buf.items.len);

    const append_meta = struct {
        fn call(s: *SerializeJobState, meta: RecordMeta) void {
            s.meta_list.append(s.aa, meta) catch {
                s.meta_list.append(s.aa, .{
                    .end_offset = @intCast(s.chunk_buf.items.len),
                    .last_was_false_or_null = false,
                    .is_error = true,
                    .error_code = @intFromError(@as(ZqError, error.IoError)),
                }) catch {};
            };
        }
    }.call;

    // ── Sparser prefilter ───────────────────────────────────────────────────────
    if (!raw_input) {
        if (query.prefilter) |pf| {
            _ = prefilter_stats.counters.evaluated.fetchAdd(1, .monotonic);
            if (!pf.accept(value_bytes)) {
                _ = prefilter_stats.counters.skipped.fetchAdd(1, .monotonic);
                append_meta(state, .{
                    .end_offset = start,
                    .last_was_false_or_null = false,
                    .is_error = false,
                    .error_code = 0,
                });
                return;
            }
        }
    }

    // ── Bind or rebind the ResultIterator ──────────────────────────────────────
    if (opt_it.* == null or current_query.* != query) {
        if (opt_it.*) |*it| it.deinit();
        opt_it.* = query.execute(tape, external_bindings, worker_alloc) catch {
            opt_it.* = null;
            current_query.* = null;
            append_meta(state, .{
                .end_offset = start,
                .last_was_false_or_null = false,
                .is_error = true,
                .error_code = @intFromError(@as(ZqError, error.IoError)),
            });
            return;
        };
        current_query.* = query;
    } else {
        opt_it.*.?.reset(tape, external_bindings);
    }

    // ── Serialize values directly into the shared chunk buffer ────────────────
    var last_was_false_or_null = false;
    while (true) {
        // Cooperative shutdown observation: required so an infinite generator
        // (e.g. `repeat(.+1)` piped through `head -100`) lets the worker exit
        // promptly when `Pool.deinit` sets the flag.  Without this, `t.join()`
        // would hang on the tight value-emit loop.  Discard any in-flight
        // chunk_buf — the consumer is gone.
        if (state.shutdown.load(.acquire)) {
            state.chunk_buf.shrinkRetainingCapacity(start);
            return;
        }

        const maybe = opt_it.*.?.next() catch |e| {
            state.chunk_buf.shrinkRetainingCapacity(start);
            append_meta(state, .{
                .end_offset = start,
                .last_was_false_or_null = false,
                .is_error = true,
                .error_code = @intFromError(e),
                .error_ip = @intCast(opt_it.*.?.last_error_ip),
            });
            return;
        };
        const val = maybe orelse break;

        // BufferSink uses the current arena's chunk_buf — re-bind every
        // iteration so a partial_flush mid-loop picks up the fresh buffer.
        var sink = output_mod.BufferSink{ .list = &state.chunk_buf, .aa = state.aa };

        output_mod.serialize(&sink, val, state.style, color, opts) catch {
            state.chunk_buf.shrinkRetainingCapacity(start);
            append_meta(state, .{
                .end_offset = start,
                .last_was_false_or_null = false,
                .is_error = true,
                .error_code = @intFromError(@as(ZqError, error.IoError)),
            });
            return;
        };

        // Append inter-value newline unless --join-output suppresses it.
        if (!state.style.join) {
            sink.writeByte('\n') catch {
                state.chunk_buf.shrinkRetainingCapacity(start);
                append_meta(state, .{
                    .end_offset = start,
                    .last_was_false_or_null = false,
                    .is_error = true,
                    .error_code = @intFromError(@as(ZqError, error.IoError)),
                });
                return;
            };
        }

        last_was_false_or_null = switch (val) {
            .null_val => true,
            .bool_val => |b| !b,
            else => false,
        };

        // Partial flush check: at a record-boundary-safe point (just emitted
        // a complete value + trailing newline), check if we should publish
        // the accumulated buffer to unblock downstream consumers.  Fires
        // whenever the threshold is crossed in stream mode (threshold > 0).
        // When the current sub-id range is exhausted, `partial_flush`
        // atomically chains a fresh range from the shared
        // `next_seq_range_base` so an infinite generator can publish
        // unbounded partials.
        if (state.flush_threshold > 0 and
            state.chunk_buf.items.len >= state.flush_threshold)
        {
            // Append a partial-record meta covering everything written for
            // this line so far, then flush.  The next partial will start a
            // new meta entry with start = 0 in the fresh chunk_buf.
            append_meta(state, .{
                .end_offset = @intCast(state.chunk_buf.items.len),
                .last_was_false_or_null = false,
                .is_error = false,
                .error_code = 0,
            });
            partial_flush(state, false);
            // After flush, chunk_buf is fresh+empty; the rest of this line's
            // output continues into the new partial starting at offset 0.
            start = 0;
        }
    }

    append_meta(state, .{
        .end_offset = @intCast(state.chunk_buf.items.len),
        .last_was_false_or_null = last_was_false_or_null,
        .is_error = false,
        .error_code = 0,
    });
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
        .big_number => |bn| .{ .big_number = try aa.dupe(u8, bn) },
        .string => |sv| .{ .string = try aa.dupe(u8, sv.slice()) },
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
    /// Shared range allocator — the IO thread's per-Job `fetchAdd` returns the
    /// `seq_base` for that Job; workers may also `fetchAdd` mid-Job to chain
    /// new ranges when an in-progress Job exhausts its current reservation.
    next_seq_range_base: *std.atomic.Value(u64),
    /// Tracks Jobs in-flight; incremented on push, decremented by the worker
    /// after the Job's final partial post.  Used together with `io_done` to
    /// pin the Sequencer's `total_chunks` once no further ranges can be
    /// claimed.
    active_stream_jobs: *std.atomic.Value(u64),
    /// Set by the IO thread once all Jobs have been pushed.  Worker observes
    /// the (`io_done`, `active_stream_jobs == 0`) transition to pin total.
    io_done: *std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    style: ?types.OutputStyle,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    raw_input: bool,
    external_bindings: []const query_mod.ExternalVarBinding,
    batch_size: usize,
};

fn io_thread_fn(ctx: IoCtx) void {
    if (ctx.raw_input) {
        io_thread_raw_lines(ctx);
    } else {
        io_thread_json_boundaries(ctx);
    }

    // No more Jobs will be pushed.  Workers may still claim additional ranges
    // (infinite generator chaining) for in-flight Jobs, so we don't pin
    // `total_chunks` here — the worker that finishes the LAST in-flight Job
    // pins it (or `Pool.deinit` does, on early shutdown).  We do still need
    // to handle the empty-input case where no Jobs are in-flight: pin total
    // immediately so a collector blocked on `next_in_order` returns null.
    ctx.io_done.store(true, .release);
    ctx.queue.signal_done();
    try_pin_total_chunks(ctx.sequencer, ctx.next_seq_range_base, ctx.active_stream_jobs, ctx.io_done);
}

/// Raw-input batcher: each input line becomes one record. Identical to the
/// pre-NIX-001 behaviour — `\n` is the only relevant byte, no JSON state.
fn io_thread_raw_lines(ctx: IoCtx) void {
    // partial_line: holds bytes of an incomplete line spanning RingBuffer boundaries.
    var partial_line = std.ArrayList(u8){};
    defer partial_line.deinit(ctx.allocator);

    // batch_buf: accumulates complete newline-terminated lines until batch_size threshold.
    var batch_buf = std.ArrayList(u8){};
    defer batch_buf.deinit(ctx.allocator);

    loop: while (true) {
        const view = ctx.src.peek() catch break :loop;

        if (view.bytes.len == 0) {
            if (view.is_eof) {
                // EOF: flush partial line into batch, then flush batch.
                flushPartialToBatch(&partial_line, &batch_buf, ctx.allocator, true) catch break :loop;
                flushBatch(&batch_buf, ctx);
                break :loop;
            }
            // No data available but not EOF (pipe stall): flush for latency.
            if (batch_buf.items.len > 0 or partial_line.items.len > 0) {
                flushPartialToBatch(&partial_line, &batch_buf, ctx.allocator, true) catch break :loop;
                flushBatch(&batch_buf, ctx);
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
                if (batch_buf.items.len >= ctx.batch_size) {
                    flushBatch(&batch_buf, ctx);
                }
            }
        }

        // Remainder after last newline goes into partial_line.
        if (consumed_offset < view.bytes.len) {
            partial_line.appendSlice(ctx.allocator, view.bytes[consumed_offset..]) catch break :loop;
        }
        ctx.src.consume(view.bytes.len);

        if (view.is_eof) {
            flushPartialToBatch(&partial_line, &batch_buf, ctx.allocator, true) catch break :loop;
            flushBatch(&batch_buf, ctx);
            break :loop;
        }
        _ = ctx.src.refill() catch break :loop;
    }
}

/// JSON-input batcher: persistent boundary scanner across views. Each
/// flushed batch contains zero or more complete top-level values separated
/// by `\n` (synthesized when the input lacks one). Records are never split
/// across batches — the in-flight bytes accumulate in `carry` until the
/// scanner observes a depth-0 / outside-string `\n`. The pipe-stall flush
/// only fires when no record is in flight (carry empty + at clean state).
fn io_thread_json_boundaries(ctx: IoCtx) void {
    var scanner = parser_mod.boundary.ScannerState{};

    // carry: bytes inside the currently in-flight record (no boundary observed yet).
    var carry = std.ArrayList(u8){};
    defer carry.deinit(ctx.allocator);

    // batch_buf: accumulates complete records (each `\n`-terminated) until batch_size.
    var batch_buf = std.ArrayList(u8){};
    defer batch_buf.deinit(ctx.allocator);

    // Reused per-iteration to avoid per-feed allocations.
    var bnds = std.ArrayList(usize){};
    defer bnds.deinit(ctx.allocator);

    loop: while (true) {
        const view = ctx.src.peek() catch break :loop;

        if (view.bytes.len == 0) {
            if (view.is_eof) {
                // Flush any in-flight bytes as the final record (synthetic \n).
                if (carry.items.len > 0) {
                    batch_buf.appendSlice(ctx.allocator, carry.items) catch break :loop;
                    batch_buf.append(ctx.allocator, '\n') catch break :loop;
                    carry.clearRetainingCapacity();
                }
                flushBatch(&batch_buf, ctx);
                break :loop;
            }
            // Pipe stall: only flush at a clean record boundary so workers
            // never see a chunk whose final record is truncated.
            if (carry.items.len == 0 and scanner.depth == 0 and !scanner.in_string and batch_buf.items.len > 0) {
                flushBatch(&batch_buf, ctx);
            }
            _ = ctx.src.refill() catch break :loop;
            continue;
        }

        bnds.clearRetainingCapacity();
        parser_mod.boundary.feedBytes(&scanner, view.bytes, 0, &bnds, ctx.allocator) catch break :loop;

        var consumed_offset: usize = 0;
        for (bnds.items) |off| {
            // Drain carry first so the record bytes appear contiguous.
            if (carry.items.len > 0) {
                batch_buf.appendSlice(ctx.allocator, carry.items) catch break :loop;
                carry.clearRetainingCapacity();
            }
            batch_buf.appendSlice(ctx.allocator, view.bytes[consumed_offset..off]) catch break :loop;
            batch_buf.append(ctx.allocator, '\n') catch break :loop;
            consumed_offset = off + 1;

            if (batch_buf.items.len >= ctx.batch_size) {
                flushBatch(&batch_buf, ctx);
            }
        }

        // Remainder belongs to an in-progress record — accumulate.
        if (consumed_offset < view.bytes.len) {
            carry.appendSlice(ctx.allocator, view.bytes[consumed_offset..]) catch break :loop;
        }
        ctx.src.consume(view.bytes.len);

        if (view.is_eof) {
            if (carry.items.len > 0) {
                batch_buf.appendSlice(ctx.allocator, carry.items) catch break :loop;
                batch_buf.append(ctx.allocator, '\n') catch break :loop;
                carry.clearRetainingCapacity();
            }
            flushBatch(&batch_buf, ctx);
            break :loop;
        }
        _ = ctx.src.refill() catch break :loop;
    }
}

/// Flush the accumulated batch as a single Job.  Acquires an in-flight slot
/// for backpressure, dupes the buffer, and pushes to the worker queue.
///
/// Each stream-mode Job claims `STREAM_SEQ_RANGE` consecutive sub-ids by
/// `fetchAdd`-ing on the shared `next_seq_range_base`.  Workers may also
/// `fetchAdd` on the same counter mid-Job to chain a fresh range when the
/// current reservation fills (infinite generators), so the IO thread and
/// workers share one allocation space.  The Sequencer skips unused trailing
/// sub-ids when it observes `end_of_range`.
fn flushBatch(batch_buf: *std.ArrayList(u8), ctx: IoCtx) void {
    if (batch_buf.items.len == 0) return;
    if (!ctx.limiter.acquire()) return; // shutdown
    const data = ctx.allocator.dupe(u8, batch_buf.items) catch return;
    const base = ctx.next_seq_range_base.fetchAdd(STREAM_SEQ_RANGE, .monotonic);
    _ = ctx.active_stream_jobs.fetchAdd(1, .monotonic);
    ctx.queue.push(.{
        .data = data,
        .seq_base = base,
        .chunk_id = base,
        .query = ctx.query,
        .owns_data = true,
        .allocator = ctx.allocator,
        .style = ctx.style,
        .color = ctx.color,
        .opts = ctx.opts,
        .raw_input = ctx.raw_input,
        .external_bindings = ctx.external_bindings,
        .seq_range_size = STREAM_SEQ_RANGE,
    });
    batch_buf.clearRetainingCapacity();
}

/// Append any remaining partial line (without trailing newline) to the batch
/// buffer, so it is included in the final flush.
fn flushPartialToBatch(
    partial_line: *std.ArrayList(u8),
    batch_buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    raw_input: bool,
) error{OutOfMemory}!void {
    const trimmed = if (raw_input)
        stripTrailingCr(partial_line.items)
    else
        std.mem.trimRight(u8, partial_line.items, " \t\r");
    // In raw_input mode, an empty partial is valid (empty string) only if there
    // were actual bytes before trimming — an empty partial_line means no data
    // was buffered (the previous line ended with \n), not an empty input line.
    if (trimmed.len > 0 or (raw_input and partial_line.items.len > 0)) {
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
    style: ?types.OutputStyle,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    raw_input: bool,
    external_bindings: []const query_mod.ExternalVarBinding,
};

fn file_feeder_fn(ctx: FileFeedCtx) void {
    const data = ctx.data;
    const file_size = data.len;
    var chunk_start: usize = 0;
    var chunk_id: u64 = 0;

    // Persistent JSON-structural scanner state walks the file once
    // sequentially. Each chunk_end is a depth-0/outside-string newline,
    // so multi-line pretty-printed values are never split across workers.
    // Scanner only reads — workers still MADV_DONTNEED their chunks on
    // post(), preserving the bounded-RSS invariant.
    var scanner = parser_mod.boundary.ScannerState{};
    var scan_cursor: usize = 0;

    for (0..ctx.n_chunks) |i| {
        // Once a previous chunk has consumed past EOF (record boundary
        // landed at file_size for a no-trailing-newline final value), no
        // remaining chunks are reachable.
        if (chunk_start >= file_size) break;

        const ideal_end_raw = if (i + 1 == ctx.n_chunks)
            file_size
        else
            (i + 1) * file_size / ctx.n_chunks;
        // A previous chunk's `findNextRecordEnd` can advance past the next
        // ideal split. Clamp so each chunk strictly follows the prior one.
        const ideal_end = @max(ideal_end_raw, chunk_start);

        // Catch scanner up to ideal_end without recording boundaries.
        if (ideal_end > scan_cursor) {
            parser_mod.boundary.advanceState(&scanner, data[scan_cursor..ideal_end]);
            scan_cursor = ideal_end;
        }

        const chunk_end: usize = if (ideal_end >= file_size)
            file_size
        else
            parser_mod.boundary.findNextRecordEnd(&scanner, data, ideal_end, file_size);
        scan_cursor = chunk_end;

        const chunk = data[chunk_start..chunk_end];
        chunk_start = chunk_end;

        if (chunk.len == 0) continue;
        if (!ctx.raw_input and !hasNonEmptyLine(chunk)) continue;

        // Block until a slot is available.  Returns false on shutdown (deinit).
        if (!ctx.limiter.acquire()) break;

        ctx.queue.push(.{
            .data = chunk,
            .seq_base = chunk_id,
            .chunk_id = chunk_id,
            .query = ctx.query,
            .owns_data = false,
            .allocator = ctx.allocator,
            .style = ctx.style,
            .color = ctx.color,
            .opts = ctx.opts,
            .raw_input = ctx.raw_input,
            .external_bindings = ctx.external_bindings,
            .seq_range_size = 1,
        });
        chunk_id += 1;
    }

    // Always inform the Sequencer of the final total and stop workers,
    // even when we exit early due to shutdown.
    ctx.sequencer.set_total_chunks(chunk_id);
    ctx.queue.signal_done();
}

/// Count newline bytes using SIMD (AVX2 on x86-64, NEON on aarch64).
/// Zig's @Vector compiles to the best available instruction set.
fn countNewlines(data: []const u8) usize {
    const Vec = @Vector(32, u8);
    const nl: Vec = @splat('\n');
    var total: usize = 0;
    var i: usize = 0;

    while (i + 32 <= data.len) : (i += 32) {
        const chunk: Vec = data[i..][0..32].*;
        const matches = chunk == nl;
        total += @popCount(@as(u32, @bitCast(matches)));
    }

    // Scalar tail — at most 31 bytes
    for (data[i..]) |b| total += @intFromBool(b == '\n');

    return total;
}

/// Strip at most one trailing '\r' (CRLF line ending).
fn stripTrailingCr(s: []const u8) []const u8 {
    return if (s.len > 0 and s[s.len - 1] == '\r') s[0 .. s.len - 1] else s;
}

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

/// Release physical pages for a processed file-mode mmap chunk (Linux only).
///
/// Inward-aligns to page boundaries so pages shared with adjacent chunks are
/// left untouched. Only middle (fully-owned) pages are freed.
fn madvise_dontneed_chunk(data: []const u8) void {
    if (comptime @import("builtin").os.tag != .linux) return;
    const page = std.heap.pageSize();
    const addr = @intFromPtr(data.ptr);
    const start = std.mem.alignForward(usize, addr, page);
    const end = std.mem.alignBackward(usize, addr + data.len, page);
    if (end <= start) return;
    std.posix.madvise(
        @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(start)),
        end - start,
        std.posix.MADV.DONTNEED,
    ) catch {};
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
    /// Stream-mode global range allocator.  Both the IO thread (per Job) and
    /// workers (when an in-progress Job exhausts its current range) atomically
    /// claim the next `STREAM_SEQ_RANGE` consecutive sub-ids from this counter,
    /// so chunk_id ranges are unique across both producers.  An infinite
    /// generator can therefore publish unbounded partial ChunkResults by
    /// chaining new ranges as the previous one fills.
    next_seq_range_base: std.atomic.Value(u64),
    /// Hot-path cooperative shutdown signal observed by the streaming emit
    /// loop in `process_line_serialized`.  Set by `Pool.deinit` before any
    /// other shutdown signal so a worker stuck in a tight value-emit loop
    /// (infinite generator + closed consumer) can break out promptly.
    shutdown: std.atomic.Value(bool),
    /// Number of stream-mode Jobs currently in-flight (queued or being
    /// processed by a worker).  Incremented by the IO thread on push,
    /// decremented by the worker after the Job's final partial post.
    /// Used together with `io_done` to determine when no further sub-ids
    /// will ever be claimed, so the Sequencer's `total_chunks` can be
    /// pinned to the final value of `next_seq_range_base`.
    active_stream_jobs: std.atomic.Value(u64),
    /// Set by the IO thread (stream mode) once it has finished pushing all
    /// Jobs.  Combined with `active_stream_jobs == 0` this is the canonical
    /// "no more ranges will ever be claimed" point — the worker (or IO thread
    /// if all Jobs are already drained) that observes this transition pins
    /// `total_chunks = next_seq_range_base`.
    io_done: std.atomic.Value(bool),
};

fn worker_thread_entry(shared: *SharedCtx) void {
    worker_fn(.{
        .queue = &shared.queue,
        .sequencer = &shared.sequencer,
        .limiter = &shared.limiter,
        .next_seq_range_base = &shared.next_seq_range_base,
        .shutdown = &shared.shutdown,
        .active_stream_jobs = &shared.active_stream_jobs,
        .io_done = &shared.io_done,
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

/// Default chunks per thread — more chunks than threads allows the OS scheduler
/// to balance load when records have uneven parse/query cost.
const DEFAULT_CHUNK_FACTOR: usize = 4;

/// Default stream-mode batch size in bytes.  The IO thread accumulates complete
/// lines until this threshold is reached, then pushes the batch as a single Job.
/// At ~300 B/record this yields ~850 records/batch, reducing millions of jobs
/// to a few thousand — same order of magnitude as file mode's chunk count.
const DEFAULT_STREAM_BATCH_SIZE: usize = 256 * 1024; // 256 KiB

/// Stream-mode partial-flush threshold (per Job).  When a single record's
/// iterator emits more than this many bytes into the chunk buffer, the worker
/// publishes a partial ChunkResult and starts a fresh arena.  This bounds
/// per-Job memory and unblocks downstream consumers for infinite generators
/// (e.g. `repeat(.+1)` piped through `head`).  See bugs.md #143.
const STREAM_FLUSH_THRESHOLD: usize = 64 * 1024;

/// Stream-mode sub-id reservation per Job.  Each stream-mode Job reserves
/// `STREAM_SEQ_RANGE` consecutive chunk-ids `[seq_base .. seq_base + N)` so
/// the worker can publish up to N-1 partial ChunkResults plus one final
/// `end_of_range` ChunkResult.  Distinct Jobs are assigned non-overlapping
/// ranges by `io_thread_fn`.  Ranges that finish before exhausting their
/// allotment leave trailing slots empty; the Sequencer skips them when it
/// observes `end_of_range = true` on the last published chunk.
const STREAM_SEQ_RANGE: u32 = 8;

/// Default file-mode backpressure: max simultaneously-live ChunkResults per
/// thread.  With 2× n_threads slots, each worker can have one chunk being
/// processed and one buffered in the Sequencer, keeping all cores busy while
/// bounding RSS.
const DEFAULT_IN_FLIGHT_FACTOR: usize = 2;

/// Upper bound for in_flight_factor.  The Sequencer ring is sized for this
/// value so that reducing in_flight_factor at runtime never exceeds capacity.
const MAX_IN_FLIGHT_FACTOR: usize = 2;

/// Thread stack size. Workers need at most ~512 KB (parser depth 512 ×
/// ~200 B per frame for serialize recursion); 2 MiB provides 4× safety margin.
/// Default Zig stack is 16 MiB; with 16 threads that wastes ~224 MiB.
const THREAD_STACK_SIZE: usize = 2 * 1024 * 1024;

// ── MemoryBudget — adaptive chunk sizing ──────────────────────────────────────
//
// Detects available system memory (or accepts an explicit limit) and computes
// chunk_factor / in_flight_factor / stream_batch_size so that peak RSS stays
// within a memory budget.  On >=4 GB machines with typical files, all parameters
// match the current hardcoded defaults (no regression).

pub const MemoryBudget = struct {
    budget_bytes: u64,

    const DEFAULT_BUDGET: u64 = 1024 * 1024 * 1024; // 1 GiB fallback
    const MIN_CHUNK_BYTES: u64 = 64 * 1024; // 64 KiB minimum chunk size
    const MIN_STREAM_BATCH: u64 = 64 * 1024; // 64 KiB
    const MAX_STREAM_BATCH: u64 = 256 * 1024; // 256 KiB

    /// Detect available system memory and apply cgroup limits (Linux).
    /// Falls back to DEFAULT_BUDGET (1 GiB) if detection fails.
    pub fn detect() MemoryBudget {
        var total: u64 = std.process.totalSystemMemory() catch DEFAULT_BUDGET * 2;

        if (comptime @import("builtin").os.tag == .linux) {
            if (detectCgroupLimit()) |cgroup_limit| {
                total = @min(total, cgroup_limit);
            }
        }

        return .{ .budget_bytes = total / 2 };
    }

    /// Create a budget with an explicit byte limit (for tests and --memory-limit).
    pub fn explicit(bytes: u64) MemoryBudget {
        return .{ .budget_bytes = bytes };
    }

    pub const ChunkParams = struct {
        chunk_factor: usize,
        in_flight_factor: usize,
        stream_batch_size: usize,
    };

    /// Compute chunk parameters given file size, thread count, and output style.
    ///
    /// For files that fit in budget after expansion, returns the current defaults.
    /// For larger files or constrained budgets, increases chunk_factor (smaller
    /// chunks, fewer in-flight bytes) and may reduce in_flight_factor to 1.
    /// For streams (file_size == 0), computes an appropriate batch size.
    pub fn computeParams(self: MemoryBudget, file_size: u64, n_threads: usize, style: ?types.OutputStyle) ChunkParams {
        const n_eff: u64 = @max(1, n_threads);

        // Stream mode: compute batch size from budget
        if (file_size == 0) {
            const expansion = formatExpansion(style);
            const batch = std.math.clamp(
                self.budget_bytes / (n_eff * 2 * expansion),
                MIN_STREAM_BATCH,
                MAX_STREAM_BATCH,
            );
            return .{
                .chunk_factor = DEFAULT_CHUNK_FACTOR,
                .in_flight_factor = DEFAULT_IN_FLIGHT_FACTOR,
                .stream_batch_size = @intCast(batch),
            };
        }

        // File mode: check if expanded file fits in budget
        const expansion = formatExpansion(style);
        const file_expanded = file_size *| expansion; // saturating multiply

        if (file_expanded <= self.budget_bytes) {
            return .{
                .chunk_factor = DEFAULT_CHUNK_FACTOR,
                .in_flight_factor = DEFAULT_IN_FLIGHT_FACTOR,
                .stream_batch_size = DEFAULT_STREAM_BATCH_SIZE,
            };
        }

        // Over budget: increase chunk_factor to reduce in-flight bytes
        // chunk_factor = ceil(2 * file_expanded / budget)
        const numerator = 2 *| file_expanded;
        var chunk_factor: u64 = (numerator + self.budget_bytes - 1) / self.budget_bytes;
        chunk_factor = std.math.clamp(chunk_factor, DEFAULT_CHUNK_FACTOR, 64);

        // Enforce minimum chunk size to avoid scheduling overhead
        const chunk_bytes = file_size / (n_eff * chunk_factor);
        if (chunk_bytes < MIN_CHUNK_BYTES and chunk_factor > DEFAULT_CHUNK_FACTOR) {
            // Reduce chunk_factor so chunks stay above MIN_CHUNK_BYTES
            const max_chunks = file_size / (n_eff * MIN_CHUNK_BYTES);
            chunk_factor = std.math.clamp(max_chunks, DEFAULT_CHUNK_FACTOR, 64);
        }

        // Check if in_flight_factor=2 still fits
        var in_flight: u64 = DEFAULT_IN_FLIGHT_FACTOR;
        const in_flight_bytes = (DEFAULT_IN_FLIGHT_FACTOR * n_eff * file_expanded) / (n_eff * chunk_factor);
        if (in_flight_bytes > self.budget_bytes) {
            in_flight = 1;
        }

        return .{
            .chunk_factor = @intCast(chunk_factor),
            .in_flight_factor = @intCast(in_flight),
            .stream_batch_size = DEFAULT_STREAM_BATCH_SIZE,
        };
    }

    /// Estimate output expansion factor for a given style.
    /// Pretty-printed compounds expand ~6×; compact stays close to input (≈2×
    /// after escapes/whitespace). Structured path (null) sits between.
    fn formatExpansion(style: ?types.OutputStyle) u64 {
        const s = style orelse return 3; // structured path
        return if (s.compact) 2 else 6;
    }
};

/// Read a cgroup memory limit file.  Returns null if the file doesn't exist,
/// contains "max", or can't be parsed.  Uses a stack buffer — no allocation.
pub fn readCgroupFile(path: []const u8) ?u64 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    var buf: [32]u8 = undefined;
    const n = file.read(&buf) catch return null;
    if (n == 0) return null;
    // Trim trailing whitespace/newline
    var end = n;
    while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == ' ')) end -= 1;
    const content = buf[0..end];
    // "max" means unlimited
    if (std.mem.eql(u8, content, "max")) return null;
    return std.fmt.parseInt(u64, content, 10) catch null;
}

/// Detect the effective cgroup memory limit (Linux only).
/// Checks cgroup v2 first, then falls back to cgroup v1.
fn detectCgroupLimit() ?u64 {
    // cgroup v2
    if (readCgroupFile("/sys/fs/cgroup/memory.max")) |limit| return limit;
    // cgroup v1 fallback
    return readCgroupFile("/sys/fs/cgroup/memory/memory.limit_in_bytes");
}

pub const Pool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    io_thread: ?std.Thread,
    _shared: *SharedCtx,
    _budget: MemoryBudget,

    // File-mode mmap lifetime management.
    // Non-null between submit_file() and the point in deinit() where threads join.
    // Workers hold read-only slices into this mapping; it must outlive all threads.
    _mmap: ?io_mod.MappedFile,

    // collect() cursor — maintains position across calls so multi-value queries
    // (e.g. `.[]`) deliver every output value before advancing to the next record.
    _delivering: ?ChunkResult, // chunk currently being consumed
    _rec_idx: usize, // index into _delivering.records[]
    _val_idx: usize, // index into _delivering.records[_rec_idx].values[]

    /// Output style for this pool run. null = structured path, non-null = serialized path.
    _style: ?types.OutputStyle,

    /// Instruction pointer of the last error (for diagnostics).
    last_error_ip: u32 = 0,

    /// User-facing message for the last error (for diagnostics).
    /// Points into the offending chunk's arena, valid until the next
    /// collect()/collect_bytes() call advances past that chunk. Populated
    /// by collect_bytes() whenever the chunk slot carries a message.
    last_user_error_msg: ?[]const u8 = null,

    pub fn init(n_threads: usize, budget: MemoryBudget, allocator: std.mem.Allocator) error{OutOfMemory}!Pool {
        const shared = try allocator.create(SharedCtx);
        errdefer allocator.destroy(shared);

        var queue = try JobQueue.init(QUEUE_CAP, allocator);
        errdefer queue.deinit();

        // Ring capacity must exceed the maximum spread of simultaneously live
        // chunk IDs across both operating modes.  Stream-mode Jobs reserve
        // `STREAM_SEQ_RANGE` sub-ids each, so the spread is multiplied by the
        // reservation size:
        //   • File mode:   MAX_IN_FLIGHT_FACTOR × n_threads
        //                  (upper bound for limiter, seq_range_size = 1)
        //   • Stream mode: (QUEUE_CAP + n_threads) × STREAM_SEQ_RANGE
        //                  (queue depth + workers, each holding one range)
        // Taking the max covers both; the allocation is at most a few KB.
        //
        // Worker-chained ranges (infinite-generator support) DO NOT widen this
        // bound: a worker only `fetchAdd`s a fresh range AFTER successfully
        // acquiring a limiter slot, so at any moment the total live-post count
        // remains capped by `max_in_flight = in_flight_factor × n_threads`.
        // Live chunk-ids stay within a window of (max_in_flight + a few range
        // boundaries), which is far below the configured capacity.
        const n_eff = @max(1, n_threads);
        const stream_spread = (QUEUE_CAP + n_eff) * STREAM_SEQ_RANGE;
        const seq_capacity = @max(MAX_IN_FLIGHT_FACTOR * n_eff, stream_spread);
        var sequencer = try Sequencer.init(seq_capacity, allocator);
        errdefer sequencer.deinit();

        // Init limiter with upper bound; submit_file/submit_stream will set_max
        // to the actual computed in_flight_factor before starting the feeder.
        const max_in_flight = MAX_IN_FLIGHT_FACTOR * @max(1, n_threads);
        shared.* = .{
            .queue = queue,
            .sequencer = sequencer,
            .limiter = InFlightLimiter.init(max_in_flight),
            .allocator = allocator,
            .ref_count = std.atomic.Value(usize).init(1 + n_threads),
            .next_seq_range_base = std.atomic.Value(u64).init(0),
            .shutdown = std.atomic.Value(bool).init(false),
            .active_stream_jobs = std.atomic.Value(u64).init(0),
            .io_done = std.atomic.Value(bool).init(false),
        };

        const threads = try allocator.alloc(std.Thread, n_threads);
        errdefer allocator.free(threads);

        var spawned: usize = 0;
        errdefer {
            shared.queue.signal_done();
            for (threads[0..spawned]) |t| t.join();
        }

        for (threads) |*t| {
            t.* = std.Thread.spawn(.{ .stack_size = THREAD_STACK_SIZE }, worker_thread_entry, .{shared}) catch {
                return error.OutOfMemory;
            };
            spawned += 1;
        }

        return Pool{
            .allocator = allocator,
            .threads = threads,
            .io_thread = null,
            ._shared = shared,
            ._budget = budget,
            ._mmap = null,
            ._delivering = null,
            ._rec_idx = 0,
            ._val_idx = 0,
            ._style = null,
        };
    }

    pub fn deinit(p: *Pool) void {
        // Set the cooperative shutdown flag FIRST so any worker stuck in a
        // tight value-emit loop (infinite generator) sees it on its next
        // per-iteration check and breaks out promptly — required for
        // `t.join()` below to return when the consumer has closed mid-stream.
        p._shared.shutdown.store(true, .release);
        // Unblock the feeder if it is stalled on limiter.acquire(), then stop
        // all workers.  Order matters: limiter shutdown first so the feeder can
        // wake up and call queue.signal_done() (or we call it below if it doesn't).
        p._shared.limiter.signal_shutdown();
        p._shared.queue.signal_done();
        // Workers exiting on shutdown won't reach the Job-completion path that
        // pins `total_chunks` for stream mode, so wake any blocked collector
        // by pinning it here.  Using next_seq_range_base.load() as the value
        // is conservative: collect() will return null once next_chunk_id
        // catches up, which happens as soon as the queue drains.
        p._shared.sequencer.set_total_chunks(p._shared.next_seq_range_base.load(.monotonic));
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
    /// the mapping into newline-aligned chunks and enqueues them one at a time,
    /// blocking when the in-flight limit is reached.  Chunk count and in-flight
    /// limit are computed adaptively from the memory budget.
    /// collect()/collect_bytes() releases each slot when it frees a chunk's arena,
    /// so peak RSS is proportional to the in-flight limit, not the full file size.
    ///
    /// When `style` is non-null, workers use the serialized path: values are
    /// serialized directly into byte buffers. Use collect_bytes() to consume.
    /// When `style` is null, workers use the structured path. Use collect().
    pub fn submit_file(
        p: *Pool,
        file: std.fs.File,
        cq: *const query_mod.CompiledQuery,
        style: ?types.OutputStyle,
        color: ?*const output_mod.Color,
        opts: output_mod.SerializeOpts,
        raw_input: bool,
        external_bindings: []const query_mod.ExternalVarBinding,
    ) ZqError!void {
        p._style = style;
        const stat = file.stat() catch return error.IoError;
        const file_size = @as(usize, @intCast(stat.size));

        if (file_size == 0) {
            p._shared.sequencer.set_total_chunks(0);
            p._shared.queue.signal_done();
            return;
        }

        p._mmap = io_mod.MappedFile.init(file, file_size) catch return error.IoError;
        const n_threads = @max(1, p.threads.len);
        const params = p._budget.computeParams(file_size, n_threads, style);
        const n_chunks = n_threads * params.chunk_factor;
        p._shared.limiter.set_max(params.in_flight_factor * @max(1, n_threads));

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
            .style = style,
            .color = color,
            .opts = opts,
            .raw_input = raw_input,
            .external_bindings = external_bindings,
        };

        p.io_thread = std.Thread.spawn(.{ .stack_size = THREAD_STACK_SIZE }, struct {
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
    /// When `style` is non-null, workers use the serialized path.
    /// When null, workers use the structured path.
    pub fn submit_stream(
        p: *Pool,
        src: *io_mod.Source,
        cq: *const query_mod.CompiledQuery,
        style: ?types.OutputStyle,
        color: ?*const output_mod.Color,
        opts: output_mod.SerializeOpts,
        raw_input: bool,
        external_bindings: []const query_mod.ExternalVarBinding,
    ) void {
        p._style = style;
        const params = p._budget.computeParams(0, p.threads.len, style);
        p._shared.limiter.set_max(params.in_flight_factor * @max(1, p.threads.len));
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
            .next_seq_range_base = &p._shared.next_seq_range_base,
            .active_stream_jobs = &p._shared.active_stream_jobs,
            .io_done = &p._shared.io_done,
            .allocator = p.allocator,
            .style = style,
            .color = color,
            .opts = opts,
            .raw_input = raw_input,
            .external_bindings = external_bindings,
            .batch_size = params.stream_batch_size,
        };

        p.io_thread = std.Thread.spawn(.{ .stack_size = THREAD_STACK_SIZE }, struct {
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

            switch (p._delivering.?.payload) {
                .structured => |recs| {
                    // ── Chunk exhausted — free its arena and fetch the next ──────
                    if (p._rec_idx >= recs.len) {
                        p._delivering.?.arena.deinit();
                        p._shared.limiter.release();
                        p._delivering = null;
                        continue;
                    }

                    // ── Dispatch on the current record's outcome ────────────────
                    switch (recs[p._rec_idx]) {
                        .err => |e| {
                            p._rec_idx += 1;
                            p._val_idx = 0;
                            return e;
                        },
                        .values => |vs| {
                            if (p._val_idx < vs.len) {
                                const result = Result{
                                    .value = owned_to_value(&vs[p._val_idx]),
                                };
                                p._val_idx += 1;
                                return result;
                            }
                            p._rec_idx += 1;
                            p._val_idx = 0;
                        },
                    }
                },
                .serialized => {
                    // Wrong path — free and continue to next chunk.
                    p._delivering.?.arena.deinit();
                    p._shared.limiter.release();
                    p._delivering = null;
                    continue;
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

            switch (p._delivering.?.payload) {
                .serialized => |ser| {
                    // ── Chunk exhausted — free its arena and fetch the next ──────
                    if (p._rec_idx >= ser.records.len) {
                        p._delivering.?.arena.deinit();
                        p._shared.limiter.release();
                        p._delivering = null;
                        continue;
                    }

                    const meta = ser.records[p._rec_idx];
                    const rec_start: u32 = if (p._rec_idx == 0) 0 else ser.records[p._rec_idx - 1].end_offset;
                    p._rec_idx += 1;
                    p._val_idx = 0;

                    if (meta.is_error) {
                        p.last_error_ip = meta.error_ip;
                        // Surface the chunk's user error message (if any) so
                        // the caller can pass it to `formatDiagnostic`. The
                        // string is arena-backed; it stays valid until the
                        // caller advances past this chunk (at which point the
                        // arena is freed). Callers must consume it before the
                        // next collect_bytes() call.
                        p.last_user_error_msg = p._delivering.?.user_error_msg;
                        return @as(ZqError, @errorCast(@errorFromInt(meta.error_code)));
                    }

                    const data = ser.data[rec_start..meta.end_offset];
                    // Skip empty records (e.g. select(false) produces no output).
                    if (data.len == 0) continue;

                    return BytesResult{
                        .data = data,
                        .last_was_false_or_null = meta.last_was_false_or_null,
                    };
                },
                .structured => {
                    // Wrong path — free and continue to next chunk.
                    p._delivering.?.arena.deinit();
                    p._shared.limiter.release();
                    p._delivering = null;
                    continue;
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
        .big_number => |bn| .{ .big_number = bn },
        .string => |s| .{ .string = .{ .external = s } },
        .tape_value => blk: {
            const tv = &ov.tape_value;
            break :blk if (tv.is_object)
                types.Value{ .object = .{ .tape = &tv.tape, .start = tv.start, .end = tv.end } }
            else
                types.Value{ .array = .{ .tape = &tv.tape, .start = tv.start, .end = tv.end } };
        },
    };
}
