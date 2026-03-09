# Module: output

## Purpose
Serialize `Value` instances produced by the Query module to an output file descriptor.
Accumulates up to 64 KB in an internal buffer before issuing `write()` syscalls,
reducing OS round-trips from millions to a few dozen on large workloads.

Supports four output formats: pretty-printed JSON (default for TTY), compact JSON,
raw string output, and JSONL (one compact JSON value per newline). TTY detection is
performed once at `init` time and drives the default format selection by callers.

---

## Public Interface

### Types

```zig
const err   = @import("error"); // named dep; wired in build.zig
const types = @import("types");

pub const ZqError = err.ZqError;
pub const Value   = types.Value;
pub const Format  = types.Format;

pub const Writer = struct {
    /// Create a Writer targeting `fd`.
    /// `allocator` is stored internally and used by `deinit`.
    pub fn init(fd: std.posix.fd_t, allocator: std.mem.Allocator) error{OutOfMemory}!Writer;

    /// Flush any buffered bytes and release the internal buffer.
    /// Safe to call in `defer` immediately after `init`.
    pub fn deinit(w: *Writer) void;

    /// Serialize `val` into the internal buffer in the requested format.
    /// Flushes automatically when the buffer reaches 64 KB.
    /// Returns `error.IoError` if an underlying `write()` syscall fails.
    pub fn write_value(w: *Writer, val: Value, format: Format) ZqError!void;

    /// Flush all buffered bytes to the OS.
    /// Returns `error.IoError` if the `write()` syscall fails.
    pub fn flush(w: *Writer) ZqError!void;

    /// True if `fd` refers to a terminal device (isatty).
    /// Callers may use this to pick a default Format.
    pub fn is_tty(w: *const Writer) bool;
};
```

### Functions

| Function          | Signature                                              | Description                                                                       |
|-------------------|--------------------------------------------------------|-----------------------------------------------------------------------------------|
| `Writer.init`     | `fd, Allocator → error{OutOfMemory}!Writer`           | Allocate 64 KB internal buffer; detect TTY via `isatty`.                          |
| `Writer.deinit`   | `*Writer → void`                                       | Flush buffered output and free the internal buffer.                               |
| `Writer.write_value` | `*Writer, Value, Format → ZqError!void`           | Serialize `val` into the buffer; auto-flush when buffer reaches 64 KB.            |
| `Writer.flush`    | `*Writer → ZqError!void`                               | Write all buffered bytes to the OS; reset buffer cursor to zero.                  |
| `Writer.is_tty`   | `*const Writer → bool`                                 | Return TTY detection result cached at `init` time.                                |

### Format Semantics

| Format    | Output                                             |
|-----------|----------------------------------------------------|
| `pretty`  | Indented JSON with 2-space indent and newlines.    |
| `compact` | Single-line JSON with no extra whitespace.         |
| `raw`     | Strings without quotes; all other types as compact JSON. |
| `jsonl`   | Compact JSON followed by a single newline (`\n`). |

### Errors

| ZqError   | When                                                               |
|-----------|--------------------------------------------------------------------|
| `IoError` | `write()` syscall fails (non-EINTR) during `flush` or auto-flush. |

`OutOfMemory` is only possible at `init` time (buffer allocation); it is not part of
`ZqError` and propagates as a standard Zig allocation error.

---

## Dependencies

- `src/error/root.zig` — `ZqError` (`IoError` for write failures)
- `src/types.zig`      — `Value`, `Format`, `Tape`, `Tape.Entry`, `Tape.Tag`

---

## Constraints & Invariants

- **Buffer size is fixed at 64 KB.** Allocated once in `init`; never reallocated.
- **Auto-flush threshold is 64 KB.** `write_value` flushes before appending a value
  that would overflow the buffer, guaranteeing no partial values are split across flush boundaries.
- **`write_value` is the only serialization site.** Format strategy (pretty/compact/raw/jsonl)
  is selected by a single switch inside `write_value`; no format logic leaks to callers.
- **TTY detection is cached.** `isatty` is called once in `init`; `is_tty()` is O(1).
- **`deinit` flushes.** Any buffered bytes not yet written are flushed during `deinit`.
  Write errors during `deinit` flush are silently dropped (destructor contract).
- **Non-owning views.** `Writer` does not own the `Value` or `Tape` memory it reads.
  Callers must keep the originating `Tape` alive for the duration of `write_value`.
- **Not thread-safe.** Each output context (stdout, file) must use its own `Writer`.
- **`ZqError` and `ErrorKind` parity.** No new `ZqError` variants are added; only
  `IoError` (already present) is raised by this module.
