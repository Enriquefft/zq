const std = @import("std");
const builtin = @import("builtin");

/// Cross-platform memory-mapped read-only file region.
///
/// On POSIX targets uses mmap(2)/munmap(2).
/// On Windows uses CreateFileMapping/MapViewOfFile/UnmapViewOfFile.
pub const MappedFile = struct {
    data: []const u8,
    _win_mapping: if (builtin.os.tag == .windows) std.os.windows.HANDLE else void,

    pub fn init(file: std.fs.File, size: usize) !MappedFile {
        if (builtin.os.tag == .windows) {
            const FILE_MAP_READ: std.os.windows.DWORD = 0x0004;
            const mapping = std.os.windows.CreateFileMappingW(
                file.handle,
                null,
                std.os.windows.PAGE_READONLY,
                0,
                0,
                null,
            ) orelse return error.IoError;
            errdefer std.os.windows.CloseHandle(mapping);
            const ptr = std.os.windows.MapViewOfFile(
                mapping,
                FILE_MAP_READ,
                0,
                0,
                size,
            ) orelse return error.IoError;
            return .{
                .data = @as([*]const u8, @ptrCast(ptr))[0..size],
                ._win_mapping = mapping,
            };
        } else {
            const data = try std.posix.mmap(
                null,
                size,
                std.posix.PROT.READ,
                .{ .TYPE = .PRIVATE },
                file.handle,
                0,
            );
            return .{ .data = data, ._win_mapping = {} };
        }
    }

    pub fn deinit(self: *MappedFile) void {
        if (builtin.os.tag == .windows) {
            _ = std.os.windows.UnmapViewOfFile(@ptrCast(self.data.ptr));
            std.os.windows.CloseHandle(self._win_mapping);
        } else {
            std.posix.munmap(@alignCast(@constCast(self.data)));
        }
    }
};

pub const MmapBackend = struct {
    mapped: MappedFile,
    cursor: usize,

    pub fn init(file: std.fs.File, size: usize) !MmapBackend {
        return .{ .mapped = try MappedFile.init(file, size), .cursor = 0 };
    }

    pub fn deinit(self: *MmapBackend) void {
        self.mapped.deinit();
    }

    pub fn available(self: *const MmapBackend) []const u8 {
        return self.mapped.data[self.cursor..];
    }

    pub fn consume(self: *MmapBackend, len: usize) void {
        self.cursor += len;
    }

    pub fn isEof(self: *const MmapBackend) bool {
        return self.cursor >= self.mapped.data.len;
    }
};
