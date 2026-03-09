const std = @import("std");

pub const MmapBackend = struct {
    data: []align(std.heap.page_size_min) u8,
    cursor: usize,

    pub fn init(fd: std.posix.fd_t, size: usize) !MmapBackend {
        const data = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        );
        return .{ .data = data, .cursor = 0 };
    }

    pub fn deinit(self: *MmapBackend) void {
        std.posix.munmap(self.data);
    }

    pub fn available(self: *const MmapBackend) []const u8 {
        return self.data[self.cursor..];
    }

    pub fn consume(self: *MmapBackend, len: usize) void {
        self.cursor += len;
    }

    pub fn isEof(self: *const MmapBackend) bool {
        return self.cursor >= self.data.len;
    }
};
