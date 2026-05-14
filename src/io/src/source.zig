const std = @import("std");
const builtin = @import("builtin");
const err = @import("error");
const MmapBackend = @import("mmap.zig").MmapBackend;
const RingBuffer = @import("ring.zig").RingBuffer;

pub const ZqError = err.ZqError;

// `GetFileType` and `FILE_TYPE_DISK` are not surfaced by Zig 0.15.2's
// `std.os.windows.kernel32` / `std.os.windows`. Declare the minimum locally;
// kernel32.dll is loaded in every Win32 process so no extra linkage needed.
// The constant value is from `<fileapi.h>` (`FILE_TYPE_DISK = 0x0001`).
const win = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetFileType(hFile: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.DWORD;
    const FILE_TYPE_DISK: std.os.windows.DWORD = 0x0001;
} else struct {};

pub const SliceView = struct {
    bytes: []const u8,
    is_eof: bool,
};

const Backend = union(enum) {
    mmap: MmapBackend,
    ring: RingBuffer,
};

pub const Source = struct {
    backend: Backend,

    /// Detects whether file is a regular file (uses mmap) or a stream (uses ring buffer).
    pub fn init(file: std.fs.File, allocator: std.mem.Allocator) ZqError!Source {
        const stat = file.stat() catch return error.IoError;
        const size: usize = @intCast(stat.size);

        // Windows pipes and consoles still report `stat.kind == .file`
        // because `File.stat` only inspects FILE_ATTRIBUTE_DIRECTORY and
        // REPARSE bits. `CreateFileMappingW` then fails on a pipe handle
        // and the mmap path errors out. Compose with `GetFileType ==
        // FILE_TYPE_DISK` — the authoritative "real disk file" predicate
        // — so pipes/consoles fall through to the ring backend on Windows
        // while preserving the directory rejection from `stat.kind`.
        const is_regular_file = stat.kind == .file and
            (builtin.os.tag != .windows or
                win.GetFileType(file.handle) == win.FILE_TYPE_DISK);

        if (is_regular_file and size > 0) {
            const m = MmapBackend.init(file, size) catch return error.IoError;
            return .{ .backend = .{ .mmap = m } };
        } else {
            const r = RingBuffer.init(file, allocator) catch return error.IoError;
            return .{ .backend = .{ .ring = r } };
        }
    }

    pub fn deinit(s: *Source) void {
        switch (s.backend) {
            .mmap => |*m| m.deinit(),
            .ring => |*r| r.deinit(),
        }
    }

    /// Zero-copy view of available bytes. No syscalls.
    pub fn peek(s: *Source) ZqError!SliceView {
        return switch (s.backend) {
            .mmap => |*m| .{ .bytes = m.available(), .is_eof = m.isEof() },
            .ring => |*r| .{ .bytes = r.available(), .is_eof = r.isEof() },
        };
    }

    /// Advance the read cursor by `len` bytes. No syscalls.
    pub fn consume(s: *Source, len: usize) void {
        switch (s.backend) {
            .mmap => |*m| m.consume(len),
            .ring => |*r| r.consume(len),
        }
    }

    /// Only syscall site. Returns true if new data was read, false on clean EOF or backpressure.
    /// Returns error.IoError on read failure.
    pub fn refill(s: *Source) ZqError!bool {
        return switch (s.backend) {
            .mmap => false,
            .ring => |*r| r.refill(),
        };
    }

    /// If backed by mmap, returns the full mapped slice (independent of the
    /// peek/consume cursor). Returns null for streaming (ring) sources.
    /// Used by callers that want to feed the entire mapping into a
    /// parallel-chunked processor instead of the streaming IO thread.
    pub fn mappedSlice(s: *const Source) ?[]const u8 {
        return switch (s.backend) {
            .mmap => |m| m.mapped.data,
            .ring => null,
        };
    }

    /// If backed by a streaming ring buffer, returns the underlying file
    /// handle so callers can read directly from the fd (bypassing the ring's
    /// internal buffer). Returns null for mmap sources.
    /// Used by the stream IO thread to read directly into pool-managed input
    /// slots (`InputSlotPool` in `src/pool/root.zig`), eliminating the
    /// previous ring buffer → intermediate-batch → heap-dupe copy path.
    pub fn streamFile(s: *const Source) ?std.fs.File {
        return switch (s.backend) {
            .mmap => null,
            .ring => |r| r.file,
        };
    }
};
