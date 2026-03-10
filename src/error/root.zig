const std = @import("std");
const lt = @import("line_table.zig");

// Re-export LineTable as part of public surface.
pub const LineTable = lt.LineTable;

/// Zig error set for native propagation (try / catch / errdefer).
/// Use this as the error type in all zq module function signatures.
/// Build a display Error (see raise/Context) only at the boundary.
pub const ZqError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidUtf8,
    InvalidNumber,
    UnterminatedString,
    DepthLimitExceeded,
    /// An underlying OS call failed (fstat, mmap, read, etc.).
    /// Distinct from UnexpectedEof — the stream is not at a clean end.
    IoError,
    /// Malformed filter expression detected at compile time.
    QuerySyntaxError,
    /// Operation applied to wrong JSON type at runtime.
    TypeError,
    /// Array index beyond array length at runtime.
    IndexOutOfBounds,
    /// Memory allocation failed during operation.
    OutOfMemory,
};

/// All error conditions zq can produce. Mirrors ZqError 1:1.
/// Used only in the display Error struct — not in function signatures.
pub const ErrorKind = enum {
    unexpected_token,
    unexpected_eof,
    invalid_utf8,
    invalid_number,
    unterminated_string,
    depth_limit_exceeded,
    /// An underlying OS call failed (fstat, mmap, read, etc.).
    io_error,
    /// Malformed filter expression detected at compile time.
    query_syntax_error,
    /// Operation applied to wrong JSON type at runtime.
    type_error,
    /// Array index beyond array length at runtime.
    index_out_of_bounds,
    /// Memory allocation failed during operation.
    out_of_memory,
};

/// Rich diagnostic context attached to every user-facing error.
///
/// `snippet` is a non-owning slice into the original source buffer.
/// Caller is responsible for keeping source alive for the duration of
/// the Error's use. This ownership model is shared by all view types
/// in zq: they are windows into caller-owned memory, never copies.
pub const Context = struct {
    line: u64,
    col: u64,
    snippet: []const u8,
};

/// The structured, user-facing error value. Build on the error path only.
pub const Error = struct {
    kind: ErrorKind,
    ctx: Context,
};

/// Convert a propagated ZqError back to its ErrorKind for display.
pub fn kindFromZqError(e: ZqError) ErrorKind {
    return switch (e) {
        error.UnexpectedToken => .unexpected_token,
        error.UnexpectedEof => .unexpected_eof,
        error.InvalidUtf8 => .invalid_utf8,
        error.InvalidNumber => .invalid_number,
        error.UnterminatedString => .unterminated_string,
        error.DepthLimitExceeded => .depth_limit_exceeded,
        error.IoError           => .io_error,
        error.QuerySyntaxError  => .query_syntax_error,
        error.TypeError         => .type_error,
        error.IndexOutOfBounds  => .index_out_of_bounds,
        error.OutOfMemory      => .out_of_memory,
    };
}

/// Scan source and record every '\n' offset for later O(log n) resolution.
/// Call only on the error path — never in the hot loop.
pub fn buildLineTable(source: []const u8, alloc: std.mem.Allocator) !LineTable {
    return lt.build(source, alloc);
}

/// Resolve a byte offset to 1-based (line, col) using a pre-built LineTable.
pub const resolve = lt.resolve;

/// Free resources allocated by buildLineTable.
pub fn deinit(table: LineTable, alloc: std.mem.Allocator) void {
    lt.deinit(table, alloc);
}

/// Assemble and return a display Error. Allocation-free and infallible.
pub fn raise(kind: ErrorKind, ctx: Context) Error {
    return Error{ .kind = kind, .ctx = ctx };
}
