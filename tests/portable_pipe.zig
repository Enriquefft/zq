//! Cross-platform anonymous pipe helper for tests.
//!
//! `std.posix.pipe()` is unimplementable on Windows-gnu in Zig 0.15.2:
//! the mingw-w64 CRT exports `_pipe(fds, size, mode)` (3 args, MS naming),
//! not the POSIX `pipe(fds)` symbol the stdlib's wrapper resolves to.
//! Linking libc does not help — the symbol simply isn't there.
//!
//! On Windows we route through `std.os.windows.CreatePipe`, which wraps the
//! NT `NtCreateNamedPipeFile` syscall and returns inheritable HANDLEs.
//! `std.posix.read`/`std.posix.close` already special-case Windows HANDLEs
//! (via `windows.ReadFile`/`CloseHandle`), so callers see the same
//! `[2]fd_t` API on every platform.

const std = @import("std");
const builtin = @import("builtin");

pub fn pipe() ![2]std.posix.fd_t {
    if (builtin.os.tag == .windows) {
        const sattr = std.os.windows.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(std.os.windows.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = null,
            .bInheritHandle = 0,
        };
        var rd: std.os.windows.HANDLE = undefined;
        var wr: std.os.windows.HANDLE = undefined;
        try std.os.windows.CreatePipe(&rd, &wr, &sattr);
        return .{ rd, wr };
    }
    return std.posix.pipe();
}
