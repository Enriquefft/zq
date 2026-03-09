const std = @import("std");
const lt = @import("line_table.zig");

// Re-export LineTable as part of public surface.
pub const LineTable = lt.LineTable;

/// All error conditions zq can produce.
pub const ErrorKind = enum {
    unexpected_token,
    unexpected_eof,
    invalid_utf8,
    invalid_number,
    unterminated_string,
    depth_limit_exceeded,
};

/// Rich diagnostic context attached to every error.
pub const Context = struct {
    line: u64,
    col: u64,
    /// Slice into the original source — caller owns source lifetime.
    snippet: []const u8,
};

/// The structured error value returned across the codebase.
pub const Error = struct {
    kind: ErrorKind,
    ctx: Context,
};

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

/// Assemble and return an Error. Allocation-free and infallible.
pub fn raise(kind: ErrorKind, ctx: Context) Error {
    return Error{ .kind = kind, .ctx = ctx };
}
