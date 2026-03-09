const std = @import("std");

pub const LineTable = struct {
    /// Sorted ascending: byte offset of each '\n' in source.
    newlines: []const u64,
    source: []const u8,
};

/// Scan source once and record every '\n' offset.
/// Caller must call deinit when done.
pub fn build(source: []const u8, alloc: std.mem.Allocator) !LineTable {
    var list = std.ArrayList(u64){};
    errdefer list.deinit(alloc);

    for (source, 0..) |byte, i| {
        if (byte == '\n') {
            try list.append(alloc, @intCast(i));
        }
    }

    return LineTable{
        .newlines = try list.toOwnedSlice(alloc),
        .source = source,
    };
}

/// Binary search newlines to compute 1-based line and col for a byte offset.
///
/// Strategy: count how many newlines appear strictly before `offset` (lower_bound).
/// That count is the 0-based line index; line_start is the byte after the
/// preceding newline (or 0 for the first line).
pub fn resolve(table: LineTable, offset: u64) struct { line: u64, col: u64 } {
    const newlines = table.newlines;

    // lower_bound: find count of newlines with position < offset
    var lo: usize = 0;
    var hi: usize = newlines.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (newlines[mid] < offset) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    // lo == number of newlines before `offset` == 0-based line index

    const line: u64 = @intCast(lo + 1); // 1-based
    const line_start: u64 = if (lo == 0) 0 else newlines[lo - 1] + 1;
    const col: u64 = offset - line_start + 1; // 1-based

    return .{ .line = line, .col = col };
}

pub fn deinit(table: LineTable, alloc: std.mem.Allocator) void {
    alloc.free(table.newlines);
}
