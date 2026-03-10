const std = @import("std");
const err = @import("error");
const MmapBackend = @import("mmap.zig").MmapBackend;
const RingBuffer = @import("ring.zig").RingBuffer;

pub const ZqError = err.ZqError;

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

        if (stat.kind == .file and size > 0) {
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
};
