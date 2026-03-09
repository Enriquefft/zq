const std = @import("std");
const ZqError = @import("error").ZqError;

const INITIAL_CAP: usize = 65536; // 64 KiB

pub const RingBuffer = struct {
    buf: []u8,
    start: usize,
    end: usize,
    fd: std.posix.fd_t,
    allocator: std.mem.Allocator,
    eof: bool,
    grown: bool,

    pub fn init(fd: std.posix.fd_t, allocator: std.mem.Allocator) !RingBuffer {
        const buf = try allocator.alloc(u8, INITIAL_CAP);
        return .{
            .buf = buf,
            .start = 0,
            .end = 0,
            .fd = fd,
            .allocator = allocator,
            .eof = false,
            .grown = false,
        };
    }

    pub fn deinit(self: *RingBuffer) void {
        self.allocator.free(self.buf);
    }

    pub fn available(self: *const RingBuffer) []const u8 {
        return self.buf[self.start..self.end];
    }

    pub fn consume(self: *RingBuffer, len: usize) void {
        self.start += len;
    }

    pub fn isEof(self: *const RingBuffer) bool {
        return self.eof and self.start >= self.end;
    }

    /// Only syscall site. Compacts unconsumed data to front, grows buffer at most
    /// once, then reads from fd.
    /// Returns true if new data was read, false on clean EOF or backpressure.
    /// Returns error.IoError on read failure (EINTR is retried internally).
    pub fn refill(self: *RingBuffer) ZqError!bool {
        if (self.eof) return false;

        // Compact: shift unconsumed bytes to the front of the buffer.
        if (self.start > 0) {
            const unconsumed = self.end - self.start;
            std.mem.copyForwards(u8, self.buf, self.buf[self.start..self.end]);
            self.start = 0;
            self.end = unconsumed;
        }

        // Grow at most once. If already grown and still full, signal backpressure.
        if (self.end == self.buf.len) {
            if (self.grown) return false;
            const new_buf = self.allocator.realloc(self.buf, self.buf.len * 2) catch return error.IoError;
            self.buf = new_buf;
            self.grown = true;
        }

        // std.posix.read handles EINTR internally; all remaining errors are fatal.
        const n = std.posix.read(self.fd, self.buf[self.end..]) catch return error.IoError;

        if (n == 0) {
            self.eof = true;
            return false;
        }
        self.end += n;
        return true;
    }
};
