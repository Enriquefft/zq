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
    /// User-raised error via the `error` builtin.
    UserError,
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
    /// User-raised error via the `error` builtin.
    user_error,
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
        error.IoError => .io_error,
        error.QuerySyntaxError => .query_syntax_error,
        error.TypeError => .type_error,
        error.IndexOutOfBounds => .index_out_of_bounds,
        error.OutOfMemory => .out_of_memory,
        error.UserError => .user_error,
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

/// Structured compile-time error with source location.
pub const CompileError = struct {
    kind: ErrorKind,
    offset: u32,
    len: u32,
};

/// Convert an ErrorKind to a human-readable string.
pub fn kindToString(kind: ErrorKind) []const u8 {
    return switch (kind) {
        .unexpected_token => "unexpected token",
        .unexpected_eof => "unexpected end of input",
        .invalid_utf8 => "invalid UTF-8",
        .invalid_number => "invalid number",
        .unterminated_string => "unterminated string",
        .depth_limit_exceeded => "depth limit exceeded",
        .io_error => "I/O error",
        .query_syntax_error => "query syntax error",
        .type_error => "type error",
        .index_out_of_bounds => "index out of bounds",
        .out_of_memory => "out of memory",
        .user_error => "user error",
    };
}

/// Extract the source line containing the given byte offset.
fn extractLine(source: []const u8, offset: u32) []const u8 {
    if (source.len == 0) return "";
    const off: usize = @min(offset, source.len - 1);

    // Find line start (byte after previous '\n', or 0).
    var start: usize = off;
    while (start > 0 and source[start - 1] != '\n') start -= 1;

    // Find line end (next '\n' or end of source).
    var end: usize = off;
    while (end < source.len and source[end] != '\n') end += 1;

    return source[start..end];
}

/// Output format for diagnostic messages.
pub const DiagnosticFormat = enum { text, json };

/// Format a diagnostic message with source context and caret underline.
/// Only called on the error path — allocates a LineTable then frees it.
pub fn formatDiagnostic(
    writer: anytype,
    filter_src: []const u8,
    kind: ErrorKind,
    offset: u32,
    len: u32,
    input_preview: ?[]const u8,
    user_message: ?[]const u8,
    alloc: std.mem.Allocator,
    format: DiagnosticFormat,
) void {
    const table = buildLineTable(filter_src, alloc) catch {
        // Fallback: bare error message if OOM
        switch (format) {
            .text => writer.print("zq: {s}\n", .{kindToString(kind)}) catch {},
            .json => writer.print("{{\"error\":\"{s}\"}}\n", .{@tagName(kind)}) catch {},
        }
        return;
    };
    defer deinit(table, alloc);
    const loc = resolve(table, offset);

    switch (format) {
        .text => {
            // Header: "zq: type error at line 1, col 8"
            writer.print("zq: {s} at line {d}, col {d}\n", .{ kindToString(kind), loc.line, loc.col }) catch {};

            // Source line
            const line_content = extractLine(filter_src, offset);
            writer.print("  {s}\n", .{line_content}) catch {};

            // Caret/tilde underline
            const col_spaces = if (loc.col > 0) @as(usize, @intCast(loc.col - 1)) else 0;
            writer.writeByteNTimes(' ', 2 + col_spaces) catch {};
            writer.writeByte('^') catch {};
            if (len > 1) writer.writeByteNTimes('~', len - 1) catch {};
            writer.writeByte('\n') catch {};

            // Error kind description
            writer.print("  {s}\n", .{kindToString(kind)}) catch {};

            // User error message if available
            if (user_message) |msg| {
                writer.print("  message: {s}\n", .{msg}) catch {};
            }

            // Input context if available
            if (input_preview) |preview| {
                writer.print("  input was: {s}\n", .{preview}) catch {};
            }
        },
        .json => {
            // JSON error object
            writer.print("{{\"error\":\"{s}\",\"line\":{d},\"col\":{d},\"offset\":{d},\"len\":{d}", .{
                @tagName(kind), loc.line, loc.col, offset, len,
            }) catch {};

            // Filter source
            writer.print(",\"filter\":\"", .{}) catch {};
            writeJsonEscaped(writer, filter_src);
            writer.print("\"", .{}) catch {};

            // User message
            if (user_message) |msg| {
                writer.print(",\"message\":\"", .{}) catch {};
                writeJsonEscaped(writer, msg);
                writer.print("\"", .{}) catch {};
            }

            // Human-readable description
            writer.print(",\"description\":\"{s}\"", .{kindToString(kind)}) catch {};

            // Input preview
            if (input_preview) |preview| {
                writer.print(",\"input_preview\":\"", .{}) catch {};
                writeJsonEscaped(writer, preview);
                writer.print("\"", .{}) catch {};
            }

            writer.print("}}\n", .{}) catch {};
        },
    }
}

/// Write a string with JSON escaping to a writer.
fn writeJsonEscaped(writer: anytype, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => writer.print("\\\"", .{}) catch {},
            '\\' => writer.print("\\\\", .{}) catch {},
            '\n' => writer.print("\\n", .{}) catch {},
            '\r' => writer.print("\\r", .{}) catch {},
            '\t' => writer.print("\\t", .{}) catch {},
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                writer.print("\\u{x:0>4}", .{c}) catch {};
            },
            0x08 => writer.print("\\b", .{}) catch {},
            0x0C => writer.print("\\f", .{}) catch {},
            else => writer.writeByte(c) catch {},
        }
    }
}
