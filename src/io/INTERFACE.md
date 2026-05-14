# Module: io

## Purpose
Abstract all data sources (file, stdin, network/socket) behind a unified byte stream.
Handles OS buffering so the parser never waits and never issues syscalls in the hot path.

## Public Interface

### Types

```zig
const err = @import("error"); // named dep; wired in build.zig via io_module.addImport("error", ...)
pub const ZqError = err.ZqError;

pub const SliceView = struct {
    bytes:  []const u8,  // non-owning view into internal buffer; invalid after refill()
    is_eof: bool,
};

pub const Source = struct {
    /// Detects backend via `file.stat()`: regular non-empty files use mmap,
    /// everything else (pipes, sockets, empty files, devices) uses the ring
    /// buffer backend.
    pub fn init(file: std.fs.File, allocator: std.mem.Allocator) ZqError!Source;
    pub fn deinit(s: *Source) void;

    /// Zero-copy view of available bytes. No syscalls.
    pub fn peek(s: *Source) ZqError!SliceView;

    /// Advance read cursor by `len` bytes. No syscalls.
    pub fn consume(s: *Source, len: usize) void;

    /// Only syscall site. Returns true if new data was read, false on clean EOF or backpressure.
    /// std.posix.read handles EINTR internally; all other read failures return error.IoError.
    pub fn refill(s: *Source) ZqError!bool;

    /// For mmap-backed sources, returns the full mapped slice (cursor-independent).
    /// Returns null for ring-backed sources. Consumed by `pool.submit_source` to
    /// route shell-redirect-from-file (`zq < f.json`) through the zero-copy file
    /// path instead of paying the stream IO thread + copy cost.
    pub fn mappedSlice(s: *const Source) ?[]const u8;

    /// For ring-backed sources, returns the underlying `std.fs.File` so the
    /// stream IO thread can `read()` directly into pool-managed input slots.
    /// Returns null for mmap-backed sources.
    pub fn streamFile(s: *const Source) ?std.fs.File;
};

/// mmap-backed view over a regular file. Re-exported from `src/io/root.zig`
/// and used directly by the parallel pool (`submit_file`) when an entire file
/// must stay addressable across worker chunks.
pub const MappedFile = @import("src/mmap.zig").MappedFile;
```

### Functions
| Function | Input → Output | Description |
|----------|----------------|-------------|
| `Source.init` | `std.fs.File, allocator → ZqError!Source` | Detects backend (mmap vs ring), allocates buffer |
| `Source.deinit` | `*Source → void` | Releases mmap region or ring buffer memory |
| `Source.peek` | `*Source → ZqError!SliceView` | Zero-copy view; no syscalls |
| `Source.consume` | `*Source, usize → void` | Advances cursor; pointer arithmetic only |
| `Source.refill` | `*Source → ZqError!bool` | Only syscall point; false on clean EOF/backpressure, error.IoError on failure |
| `Source.mappedSlice` | `*const Source → ?[]const u8` | Full mmap slice if `.mmap`-backed; null for ring. Drives the pool's mmap-vs-stream dispatch in `submit_source` |
| `Source.streamFile` | `*const Source → ?std.fs.File` | Underlying fd if `.ring`-backed; null for mmap. Used by the stream IO thread to read directly into input slots |

### Errors
| ZqError | When |
|---------|------|
| `IoError` | `refill()` read syscall fails (non-EINTR); OOM during ring buffer grow |
| `IoError` | `init()` fstat or mmap fails |

EINTR is handled by std.posix.read and never surfaces. Line/col context is built by the
caller at the display boundary, not here.

## Dependencies
- `src/error/root.zig` — for `ZqError` only
- `std` only — no external dependencies

## Constraints & Invariants
- `peek()` and `consume()` MUST NOT issue syscalls
- `refill()` is the ONLY syscall site in this module
- `SliceView.bytes` is invalid after the next `refill()` call — caller must not retain it
- Backend (mmap vs ring) is chosen at `init` time and is immutable
- Ring buffer grows at most once; thereafter backpressure is signalled via `refill()` returning false
- mmap region is read-only
