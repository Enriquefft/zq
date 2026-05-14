const std = @import("std");
const builtin = @import("builtin");

// Windows file-mapping APIs are not wrapped in std.os.windows — declare them directly.
const win32 = struct {
    extern "kernel32" fn CreateFileMappingW(
        hFile: std.os.windows.HANDLE,
        lpFileMappingAttributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
        flProtect: std.os.windows.DWORD,
        dwMaximumSizeHigh: std.os.windows.DWORD,
        dwMaximumSizeLow: std.os.windows.DWORD,
        lpName: ?std.os.windows.LPCWSTR,
    ) callconv(.winapi) ?std.os.windows.HANDLE;

    extern "kernel32" fn MapViewOfFile(
        hFileMappingObject: std.os.windows.HANDLE,
        dwDesiredAccess: std.os.windows.DWORD,
        dwFileOffsetHigh: std.os.windows.DWORD,
        dwFileOffsetLow: std.os.windows.DWORD,
        dwNumberOfBytesToMap: usize,
    ) callconv(.winapi) ?std.os.windows.LPVOID;

    extern "kernel32" fn UnmapViewOfFile(
        lpBaseAddress: std.os.windows.LPCVOID,
    ) callconv(.winapi) std.os.windows.BOOL;
};

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
            const mapping = win32.CreateFileMappingW(
                file.handle,
                null,
                std.os.windows.PAGE_READONLY,
                0,
                0,
                null,
            ) orelse return error.IoError;
            errdefer std.os.windows.CloseHandle(mapping);
            const ptr = win32.MapViewOfFile(
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
            // POSIX hint: workers walk the mapping sequentially, so the kernel
            // can prefetch aggressively and reclaim already-read pages.
            // Composes with the per-chunk MADV_DONTNEED issued by the worker
            // pool after each chunk completes. Best-effort: failure is ignored
            // (madvise is purely advisory and never affects correctness).
            // Supported on Linux/macOS/BSD; skip Solaris-derived posix_madvise
            // surfaces zig does not yet expose.
            switch (builtin.os.tag) {
                .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => {
                    std.posix.madvise(data.ptr, data.len, std.posix.MADV.SEQUENTIAL) catch {};
                },
                else => {},
            }
            return .{ .data = data, ._win_mapping = {} };
        }
    }

    pub fn deinit(self: *MappedFile) void {
        if (builtin.os.tag == .windows) {
            _ = win32.UnmapViewOfFile(@ptrCast(self.data.ptr));
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
