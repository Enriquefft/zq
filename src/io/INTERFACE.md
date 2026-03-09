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
    pub fn init(fd: std.posix.fd_t, allocator: std.mem.Allocator) ZqError!Source;
    pub fn deinit(s: *Source) void;

    /// Zero-copy view of available bytes. No syscalls.
    pub fn peek(s: *Source) ZqError!SliceView;

    /// Advance read cursor by `len` bytes. No syscalls.
    pub fn consume(s: *Source, len: usize) void;

    /// Only syscall site. Returns true if new data was read, false on clean EOF or backpressure.
    /// std.posix.read handles EINTR internally; all other read failures return error.IoError.
    pub fn refill(s: *Source) ZqError!bool;
};
```

### Functions
| Function | Input → Output | Description |
|----------|----------------|-------------|
| `Source.init` | `fd, allocator → ZqError!Source` | Detects backend (mmap vs ring), allocates buffer |
| `Source.deinit` | `*Source → void` | Releases mmap region or ring buffer memory |
| `Source.peek` | `*Source → ZqError!SliceView` | Zero-copy view; no syscalls |
| `Source.consume` | `*Source, usize → void` | Advances cursor; pointer arithmetic only |
| `Source.refill` | `*Source → ZqError!bool` | Only syscall point; false on clean EOF/backpressure, error.IoError on failure |

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
