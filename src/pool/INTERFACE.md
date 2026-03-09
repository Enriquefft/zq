# Module: pool

## Purpose
Manage a fixed set of worker threads, distribute parse+query work across them, and
guarantee that `collect()` returns results in the same order that work was submitted.
This is the orchestration layer that stitches together `io`, `parser`, and `query` for
parallel execution over JSONL files and streams.

Two execution modes are supported:

- **File mode** (`submit_file`): The file is split into byte-range chunks by scanning
  for newline boundaries. Workers steal chunks from a shared queue, each owning its own
  `Parser` instance. Chunk boundaries are aligned to complete JSON records so no record
  is ever split across workers.

- **Stream mode** (`submit_stream`): A dedicated IO thread reads complete lines from a
  `Source` and posts them into a shared line queue. Worker threads dequeue lines, parse,
  execute the query, and post ordered results to the sequencer.

In both modes, the **sequencer** holds results out-of-order in a reorder buffer and
releases them to `collect()` only in submission order.

---

## Public Interface

### Types

```zig
const std   = @import("std");
const err   = @import("error");
const io    = @import("io");
const query = @import("query");

pub const ZqError = err.ZqError;

/// A single output value together with its submission sequence number.
/// Values are views into internally-owned Tape memory; they are valid until
/// the next call to collect() or deinit().
pub const Result = struct {
    /// The output value produced by executing the query against one JSON record.
    /// `value.string` (and object/array spans) point into pool-managed tape memory.
    value: types.Value,
};

/// A fixed-size worker pool.  Create once, submit work, drain with collect().
pub const Pool = struct {
    /// Allocate thread-local Parser instances, shared job queue, sequencer, and
    /// result buffer.  Spawns `n_threads` OS threads immediately.
    ///
    /// Returns OutOfMemory if internal structures cannot be allocated.
    /// The allocator is stored internally and used by deinit().
    pub fn init(n_threads: usize, allocator: std.mem.Allocator) error{OutOfMemory}!Pool;

    /// Signal all workers to stop, join every thread, and free all memory.
    /// Blocks until all threads have exited.  Safe to call in defer.
    pub fn deinit(p: *Pool) void;

    /// Submit a regular file for parallel processing.
    ///
    /// The file descriptor must remain valid until collect() returns null.
    /// The pool reads the file, splits it on newline boundaries, and distributes
    /// byte-range chunks to worker threads.
    ///
    /// `query` must outlive the pool (it is immutable and shared across threads).
    pub fn submit_file(
        p:     *Pool,
        fd:    std.posix.fd_t,
        cq:    *const query.CompiledQuery,
    ) ZqError!void;

    /// Submit a streaming source (stdin, socket, …) for pipeline processing.
    ///
    /// A dedicated IO thread reads complete newline-terminated records from `src`
    /// and distributes them to worker threads.  `src` must remain valid until
    /// collect() returns null.
    ///
    /// `query` must outlive the pool.
    pub fn submit_stream(
        p:   *Pool,
        src: *io.Source,
        cq:  *const query.CompiledQuery,
    ) void;

    /// Return the next result in submission order.
    ///
    /// Blocks until the next in-order result is available or all work is done.
    /// Returns null when all submitted records have been processed.
    /// Returns an error if a worker encountered a parse or query error on a record.
    ///
    /// The returned Result is valid until the next call to collect() or deinit().
    pub fn collect(p: *Pool) ZqError!?Result;
};
```

### Functions

| Function            | Signature                                                          | Description                                                                             |
|---------------------|--------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| `Pool.init`         | `usize, Allocator → error{OutOfMemory}!Pool`                       | Allocate all internal state and spawn N worker threads.                                 |
| `Pool.deinit`       | `*Pool → void`                                                     | Stop all workers, join threads, free memory.                                            |
| `Pool.submit_file`  | `*Pool, fd_t, *const CompiledQuery → ZqError!void`                 | Read file, split into newline-aligned chunks, enqueue for parallel processing.          |
| `Pool.submit_stream`| `*Pool, *Source, *const CompiledQuery → void`                      | Attach stream; IO thread reads lines and feeds workers in pipeline mode.                |
| `Pool.collect`      | `*Pool → ZqError!?Result`                                          | Return next in-order result; null when exhausted; error on per-record failure.          |

### Errors

| Error              | When                                                                                    |
|--------------------|-----------------------------------------------------------------------------------------|
| `IoError`          | `submit_file`: file cannot be read or stat'd; worker IO failure.                        |
| `UnexpectedToken`  | Worker parser: malformed JSON in a record.                                              |
| `UnexpectedEof`    | Worker parser: record truncated at an unrecoverable position.                           |
| `InvalidUtf8`      | Worker parser: invalid UTF-8 sequence in a string.                                      |
| `InvalidNumber`    | Worker parser: malformed number literal.                                                |
| `UnterminatedString`| Worker parser: unterminated string at stream EOF.                                      |
| `DepthLimitExceeded`| Worker parser: JSON nesting exceeds 512 levels.                                        |
| `TypeError`        | Worker query: operation applied to wrong JSON type.                                     |
| `IndexOutOfBounds` | Worker query: array index beyond bounds.                                                |
| `QuerySyntaxError` | Not raised at runtime; only from CompiledQuery.compile before submit.                   |
| `OutOfMemory`      | `init` only; internal structure allocation.                                             |

---

## Dependencies

- `src/error/root.zig`  — `ZqError` for propagation
- `src/types.zig`       — `Value`, `Tape`
- `src/io/root.zig`     — `Source`, `SliceView`
- `src/parser/root.zig` — `Parser`, `FeedResult`
- `src/query/root.zig`  — `CompiledQuery`, `ResultIterator`

---

## Constraints & Invariants

- **Each worker owns its own Parser.** `Parser` is not thread-safe; the pool allocates
  one per thread.
- **`CompiledQuery` is read-only and shared.** `execute()` is safe to call concurrently
  from multiple threads on the same `CompiledQuery`.
- **collect() is single-caller.** Only one thread may call collect() at a time.
  The pool does not synchronize multiple callers.
- **Results are returned in submission order.** The sequencer holds out-of-order results
  in a bounded reorder buffer and blocks until the next in-sequence result is ready.
- **`SliceView.bytes` must not be retained across `refill()`.** Workers copy line bytes
  into owned buffers before calling `refill()` or advancing the source.
- **`Result.value` is valid only until the next collect() or deinit() call.** Tape
  memory is reused across records; callers must consume or copy values before calling
  collect() again.
- **`submit_file` and `submit_stream` must not be called after collect() returns null.**
  The pool is single-use after drain.
- **`n_threads = 0` is valid** and means the calling thread executes all work inline
  (useful for testing and single-core environments). All invariants still hold.
