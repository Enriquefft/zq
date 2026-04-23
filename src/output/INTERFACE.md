# Module: output

## Purpose
Serialize `Value` instances produced by the Query module to an output file descriptor
or a growable byte buffer. Accumulates up to 64 KB in an internal buffer before issuing
`write()` syscalls, reducing OS round-trips from millions to a few dozen on large workloads.

Supports four output formats: pretty-printed JSON (default for TTY), compact JSON,
raw string output, and JSONL (one compact JSON value per newline). TTY detection is
performed once at `init` time and drives the default format selection by callers.

The serialization logic is generic: the same functions power both `Writer` (file-backed
buffered output) and `BufferSink` (growable ArrayList target for worker threads).

---

## Public Interface

### Types

```zig
const err   = @import("error"); // named dep; wired in build.zig
const types = @import("types");

pub const ZqError = err.ZqError;
pub const Value   = types.Value;
pub const Format  = types.Format;

/// ANSI color escape sequences for JSON syntax highlighting.
pub const Color = struct {
    null_color: []const u8,
    bool_color: []const u8,
    number_color: []const u8,
    string_color: []const u8,
    key_color: []const u8,
    reset: []const u8,
};

/// Default color scheme: bold blue keys, green strings, cyan numbers,
/// magenta booleans, bold dark gray nulls. Structural chars uncolored.
pub const default_colors: Color;

/// Serialization options controlling key ordering, indentation, and any
/// scratch allocator required by individual formats (e.g. `sort_keys`).
pub const SerializeOpts = struct {
    sort_keys: bool = false,
    indent: Indent = .{ .spaces = 2 },
    /// Optional scratch allocator. Required by key-sorting paths; `null` is
    /// fine when `sort_keys = false` and no other allocating serializer is used.
    allocator: ?std.mem.Allocator = null,

    pub const Indent = union(enum) {
        spaces: u8,
        tab,
    };
};

/// Adapts an `std.ArrayList(u8)` to the `writeByte`/`writeSlice` interface used
/// by the generic serialization functions. Used by pool workers to serialize
/// values directly into arena-backed byte buffers. Both methods propagate
/// `error{OutOfMemory}` from the underlying list grow.
pub const BufferSink = struct {
    list: *std.ArrayList(u8),
    aa:   std.mem.Allocator,

    pub fn writeByte(self: *BufferSink, byte: u8) error{OutOfMemory}!void;
    pub fn writeSlice(self: *BufferSink, data: []const u8) error{OutOfMemory}!void;
};

pub const Writer = struct {
    /// Create a Writer targeting `file`. TTY detection (`file.isTty()`) is
    /// performed once at init time; the result is cached for `is_tty()`.
    /// `allocator` is stored internally and used by `deinit`.
    pub fn init(file: std.fs.File, allocator: std.mem.Allocator) error{OutOfMemory}!Writer;

    /// Flush any buffered bytes and release the internal buffer.
    /// Safe to call in `defer` immediately after `init`.
    pub fn deinit(w: *Writer) void;

    /// Serialize `val` into the internal buffer in the requested format.
    /// Flushes automatically when the buffer reaches 64 KB.
    /// Returns `error.IoError` if an underlying `write()` syscall fails.
    pub fn write_value(w: *Writer, val: Value, format: Format, color: ?*const Color, opts: SerializeOpts) ZqError!void;

    /// Append pre-serialized bytes directly to the internal buffer.
    /// Used by main.zig to write output from the serialized pool path.
    pub fn writeSlice(w: *Writer, data: []const u8) ZqError!void;

    /// Flush all buffered bytes to the OS.
    /// Returns `error.IoError` if the `write()` syscall fails.
    pub fn flush(w: *Writer) ZqError!void;

    /// True if `file` refers to a terminal device (result cached at init).
    /// Callers may use this to pick a default Format.
    pub fn is_tty(w: *const Writer) bool;
};
```

### Functions

| Function          | Signature                                              | Description                                                                       |
|-------------------|--------------------------------------------------------|-----------------------------------------------------------------------------------|
| `serialize`       | `anytype, Value, Format, ?*const Color, SerializeOpts → !void` | Serialize `val` into any sink with `writeByte`/`writeSlice` methods.      |
| `Writer.init`     | `std.fs.File, Allocator → error{OutOfMemory}!Writer`  | Allocate 64 KB internal buffer; cache `file.isTty()`.                             |
| `Writer.deinit`   | `*Writer → void`                                       | Flush buffered output and free the internal buffer.                               |
| `Writer.write_value` | `*Writer, Value, Format, ?*const Color, SerializeOpts → ZqError!void` | Serialize `val` into the buffer; auto-flush when buffer reaches 64 KB. |
| `Writer.writeSlice`  | `*Writer, []const u8 → ZqError!void`              | Append pre-serialized bytes to the buffer; auto-flush as needed.                  |
| `Writer.flush`    | `*Writer → ZqError!void`                               | Write all buffered bytes to the OS; reset buffer cursor to zero.                  |
| `Writer.is_tty`   | `*const Writer → bool`                                 | Return TTY detection result cached at `init` time.                                |

### Format Semantics

| Format    | Output                                                                         |
|-----------|--------------------------------------------------------------------------------|
| `pretty`  | Indented JSON (default 2-space; configurable via `SerializeOpts.indent`).      |
| `compact` | Single-line JSON with no extra whitespace.                                     |
| `raw`     | Strings without quotes; all other types as compact JSON.                       |
| `jsonl`   | Compact JSON followed by a single newline (`\n`).                              |
| `join`    | Same serializer as `raw`; used by the `@join` path to avoid adding a newline.  |

### Errors

| Error              | When                                                                                                         |
|--------------------|--------------------------------------------------------------------------------------------------------------|
| `IoError`          | `Writer` path: `writeAll()` syscall fails during `flush` or auto-flush.                                      |
| `OutOfMemory`      | `Writer.init` buffer allocation; `BufferSink.writeByte` / `writeSlice` when the underlying list cannot grow. |

`BufferSink` is used by pool workers whose arena can run out, so both its
methods propagate `error{OutOfMemory}` on every call — not only at init.

---

## Dependencies

- `src/error/root.zig` — `ZqError` (`IoError` for write failures)
- `src/types.zig`      — `Value`, `Format`, `Tape`, `Tape.Entry`, `Tape.Tag`

---

## Constraints & Invariants

- **Buffer size is fixed at 64 KB.** Allocated once in `init`; never reallocated.
- **Auto-flush threshold is 64 KB.** `write_value` flushes before appending a value
  that would overflow the buffer, guaranteeing no partial values are split across flush boundaries.
- **Serialization is generic.** The same `serializeValueCompact`/`serializeValuePretty`/etc.
  functions are used by both `Writer` (file-backed) and `BufferSink` (growable buffer).
  They are parameterized on `anytype` requiring `writeByte`/`writeSlice` methods.
- **`serialize()` is the public entry point** for non-Writer targets.
- **`Writer.writeSlice()` is public** for writing pre-serialized byte data.
- **TTY detection is cached.** `isatty` is called once in `init`; `is_tty()` is O(1).
- **`deinit` flushes.** Any buffered bytes not yet written are flushed during `deinit`.
  Write errors during `deinit` flush are silently dropped (destructor contract).
- **Non-owning views.** `Writer` does not own the `Value` or `Tape` memory it reads.
  Callers must keep the originating `Tape` alive for the duration of `write_value`.
- **Not thread-safe.** Each output context (stdout, file) must use its own `Writer`.
  `BufferSink` is also not thread-safe; each worker creates its own.
- **`ZqError` and `ErrorKind` parity.** No new `ZqError` variants are added; only
  `IoError` (already present) is raised by this module.
