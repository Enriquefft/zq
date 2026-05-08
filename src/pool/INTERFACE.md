# Module: pool

## Purpose
Manage a fixed set of worker threads, distribute parse+query work across them, and
guarantee that `collect()`/`collect_bytes()` returns results in the same order that
work was submitted. This is the orchestration layer that stitches together `io`,
`parser`, `query`, and `output` for parallel execution over JSONL files and streams.

Two execution paths are supported:

- **Structured path** (`style = null`): Workers execute queries and copy values into
  arena-backed OwnedValues. Use `collect()` to retrieve typed `Value` results. Best
  for queries that produce complex values (objects/arrays) that need post-processing.

- **Serialized path** (`style != null`): Workers execute queries and serialize values
  directly into arena-backed byte buffers while the tape is still valid. Use
  `collect_bytes()` to retrieve pre-serialized output. Drastically reduces memory for
  per-record queries (`.id`, `select()`, `{a,b}`): arena holds only serialized bytes
  instead of full OwnedValue copies.

Two execution modes are supported:

- **File mode** (`submit_file`): The file is split into byte-range chunks by scanning
  for newline boundaries. Workers steal chunks from a shared queue, each owning its own
  `Parser` instance. Chunk boundaries are aligned to complete JSON records so no record
  is ever split across workers.

- **Stream mode** (`submit_stream`): A dedicated IO thread reads complete lines from a
  `Source` and posts them into a shared line queue. Worker threads dequeue lines, parse,
  execute the query, and post ordered results to the sequencer.

In both modes, the **sequencer** holds results out-of-order in a reorder buffer and
releases them to `collect()`/`collect_bytes()` only in submission order.

### Adaptive chunk sizing

`MemoryBudget` detects available system memory (+ Linux cgroup limits) and adapts
chunk count, in-flight limit, and stream batch size so peak RSS stays within a memory
budget. On >=4 GB machines with typical files, parameters are identical to the previous
hardcoded defaults (no regression). On constrained systems (containers, small VMs),
it gracefully reduces concurrency to avoid OOM.

---

## Public Interface

### Types

```zig
const std   = @import("std");
const err   = @import("error");
const io    = @import("io");
const query = @import("query");
const types = @import("types");

pub const ZqError = err.ZqError;

/// Global Sparser-prefilter counters. Exposed as a namespace (not a type);
/// bumped with relaxed atomics from every worker. Informational only — no
/// program logic depends on the numbers. Callers that want a per-run count
/// must invoke `reset()` explicitly.
pub const prefilter_stats = struct {
    pub fn reset() void;
    pub fn skipped() u64;     // records skipped by the raw-byte prescreen
    pub fn evaluated() u64;   // records that ran the full query
};

/// A single output value together with its submission sequence number.
/// Values are views into internally-owned Tape memory; they are valid until
/// the next call to collect() or deinit().
pub const Result = struct {
    value: types.Value,
};

/// Pre-serialized bytes for one record, returned by collect_bytes().
/// Valid until the next call to collect_bytes() or deinit().
/// `last_output` carries the tri-state SSOT used to compute the `-e` exit code
/// per jq 1.8.1: `.none` (no value emitted by this record), `.false_or_null`
/// (final emitted value was `false`/`null`), or `.truthy`. The CLI folds
/// per-record values across the sequenced stream via `types.lastOutputFold`
/// ("last non-empty wins") and maps the terminal tag to exit 4 / 1 / 0.
pub const BytesResult = struct {
    data:        []const u8,
    last_output: types.LastOutput,
};

/// Adaptive memory budget for chunk sizing.
/// Detects system memory or accepts an explicit limit.
pub const MemoryBudget = struct {
    budget_bytes: u64,

    /// Detect available system memory and apply cgroup limits.
    /// Falls back to 1 GiB if detection fails.
    pub fn detect() MemoryBudget;

    /// Create a budget with an explicit byte limit (for tests / --memory-limit).
    pub fn explicit(bytes: u64) MemoryBudget;

    pub const ChunkParams = struct {
        chunk_factor: usize,
        in_flight_factor: usize,
        stream_batch_size: usize,
    };

    /// Compute chunk parameters given file size, thread count, and output style.
    pub fn computeParams(self, file_size: u64, n_threads: usize, style: ?types.OutputStyle) ChunkParams;
};

/// A fixed-size worker pool.  Create once, submit work, drain with collect()
/// or collect_bytes().
pub const Pool = struct {
    pub fn init(n_threads: usize, budget: MemoryBudget, allocator: std.mem.Allocator) error{OutOfMemory}!Pool;
    pub fn deinit(p: *Pool) void;

    /// Submit a regular file for parallel processing.
    ///
    /// `style`: null → structured path (use `collect()`), non-null → serialized
    /// path (use `collect_bytes()`). `color`, `opts`, `raw_input`, and
    /// `external_bindings` are forwarded to each worker so the serialized path
    /// can render final bytes directly.
    pub fn submit_file(
        p:                 *Pool,
        file:              std.fs.File,
        cq:                *const query.CompiledQuery,
        style:             ?types.OutputStyle,
        color:             ?*const output.Color,
        opts:              output.SerializeOpts,
        raw_input:         bool,
        external_bindings: []const query.ExternalVarBinding,
    ) ZqError!void;

    /// Submit a streaming source for pipeline processing.
    ///
    /// Parameters match `submit_file` with the exception that the source is an
    /// `io.Source` (stdin, pipe, …) instead of a regular file. The dedicated
    /// IO thread reads complete lines and dispatches them to workers.
    pub fn submit_stream(
        p:                 *Pool,
        src:               *io.Source,
        cq:                *const query.CompiledQuery,
        style:             ?types.OutputStyle,
        color:             ?*const output.Color,
        opts:              output.SerializeOpts,
        raw_input:         bool,
        external_bindings: []const query.ExternalVarBinding,
    ) void;

    /// Return the next result in submission order (structured path).
    pub fn collect(p: *Pool) ZqError!?Result;

    /// Return pre-serialized bytes for the next record (serialized path).
    /// Skips empty records (e.g. select(false)).
    pub fn collect_bytes(p: *Pool) ZqError!?BytesResult;
};
```

### Functions

| Function              | Signature                                                                        | Description                                                                             |
|-----------------------|----------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| `MemoryBudget.detect` | `→ MemoryBudget`                                                                 | Detect system memory + cgroup limits; budget = min(total, cgroup) / 2.                 |
| `MemoryBudget.explicit`| `u64 → MemoryBudget`                                                            | Explicit budget for tests and future `--memory-limit` flag.                            |
| `MemoryBudget.computeParams` | `MemoryBudget, u64, usize, ?OutputStyle → ChunkParams`                    | Compute adaptive chunk_factor, in_flight_factor, stream_batch_size.                    |
| `Pool.init`           | `usize, MemoryBudget, Allocator → error{OutOfMemory}!Pool`                      | Allocate all internal state and spawn N worker threads.                                 |
| `Pool.deinit`         | `*Pool → void`                                                                   | Stop all workers, join threads, free memory.                                            |
| `Pool.submit_file`    | `*Pool, File, *const CompiledQuery, ?OutputStyle, ?*const Color, SerializeOpts, bool, []const ExternalVarBinding → ZqError!void` | Read file, split into adaptive chunks, enqueue for parallel processing. |
| `Pool.submit_stream`  | `*Pool, *Source, *const CompiledQuery, ?OutputStyle, ?*const Color, SerializeOpts, bool, []const ExternalVarBinding → void`      | Attach stream; IO thread reads lines and feeds workers in pipeline mode. |
| `Pool.collect`        | `*Pool → ZqError!?Result`                                                        | Return next in-order result; null when exhausted; error on per-record failure.          |
| `Pool.collect_bytes`  | `*Pool → ZqError!?BytesResult`                                                   | Return next in-order pre-serialized bytes; null when exhausted; skips empty records.    |
| `record_meta_size_for_test` | `usize` (comptime constant)                                                | `@sizeOf(RecordMeta)` — exported so the regression test in `tests/pool_test.zig` can pin the layout. Any new per-record field changes this value and fails the test intentionally. |
| `readCgroupFile`      | `[]const u8 → ?u64`                                                              | Read a cgroup memory-limit file at `path`. Returns `null` if the file is absent, contains `"max"`, or cannot be parsed. Stack-allocated; no heap allocation. |

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
| `RegexCompileError`| Worker query: dynamic regex pattern rejected by the engine at runtime.                  |
| `RegexNotCompiled` | Worker query: regex builtin invoked but build was compiled with `-Dregex=false`.       |
| `RegexInternalError`| Worker query: regex engine raised a runtime/shim error.                                |
| `UserError`        | Worker query: filter invoked the `error` builtin.                                       |
| `OutOfMemory`      | `init` only; internal structure allocation.                                             |

---

## Dependencies

- `src/error/root.zig`  — `ZqError` for propagation
- `src/types.zig`       — `Value`, `Tape`, `OutputStyle`
- `src/io/root.zig`     — `Source`, `SliceView`, `MappedFile` (mmap-backed file chunks)
- `src/parser/root.zig` — `Parser`, `FeedResult`
- `src/query/root.zig`  — `CompiledQuery`, `ResultIterator`, `ExternalVarBinding`
- `src/output/root.zig` — `Color`, `SerializeOpts`, `BufferSink`, `serialize()` (serialized path)
- `src/regex/root.zig`  — indirect via `query`; every Regex error variant can surface here
- `src/ast/root.zig`    — indirect via `query` prefilter harvester at compile time

---

## Constraints & Invariants

- **Each worker owns its own Parser.** `Parser` is not thread-safe; the pool allocates
  one per thread.
- **`CompiledQuery` is read-only and shared.** `execute()` is safe to call concurrently
  from multiple threads on the same `CompiledQuery`.
- **collect()/collect_bytes() is single-caller.** Only one thread may call these at a time.
  The pool does not synchronize multiple callers.
- **Results are returned in submission order.** The sequencer holds out-of-order results
  in a bounded reorder buffer and blocks until the next in-sequence result is ready.
- **`SliceView.bytes` must not be retained across `refill()`.** Workers copy line bytes
  into owned buffers before calling `refill()` or advancing the source.
- **`Result.value` is valid only until the next collect() or deinit() call.** Tape
  memory is reused across records; callers must consume or copy values before calling
  collect() again.
- **`BytesResult.data` is valid only until the next collect_bytes() or deinit() call.**
  Data points into the arena of the current chunk; freed when advancing past the chunk.
- **`submit_file` and `submit_stream` must not be called after collect()/collect_bytes()
  returns null.** The pool is single-use after drain.
- **`n_threads = 0` is valid** and means the calling thread executes all work inline
  (useful for testing and single-core environments). All invariants still hold.
- **Serialized path memory savings**: For per-record scalar queries, arena holds only
  serialized bytes (e.g. "42\n" = 3 bytes) instead of OwnedValue structs + tape copies.
  Peak RSS: 403 MB for a 1.3 GB file with `.id` (0.31x input).
- **Adaptive sizing is transparent.** On >=4 GB machines with files that fit in budget,
  parameters are identical to the previous hardcoded defaults (chunk_factor=4,
  in_flight_factor=2, stream_batch_size=256K). Only constrained environments see changes.
- **`job.data` must not be accessed after `sequencer.post()`.** File-mode workers call
  `madvise(MADV_DONTNEED)` on the mmap chunk immediately after posting, releasing
  physical pages from RSS. The invariant holds because: (a) the serialized path stores
  output bytes in the arena, never pointers into `job.data`; (b) the structured path
  calls `own_value()` to deep-copy all tape spans and strings into the arena, and
  `parser.reset()` after each record. Violating this invariant causes silent disk
  re-reads (performance regression), not data corruption. Linux-only; no-op elsewhere.
