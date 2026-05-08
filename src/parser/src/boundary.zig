//! JSON-structural boundary scanner.
//!
//! Lightweight depth + string-state machine that finds record boundaries
//! (top-level `\n` between JSON values) without building a tape. Used by
//! the pool's chunker layers to split byte streams at safe positions
//! (file aligner, stream batcher) and to estimate record counts. SIMD
//! fast paths are reused from `simd.zig`.
//!
//! Contract: a record boundary is any `\n` byte observed at depth 0,
//! outside a string literal, with no escape pending. All other `\n`
//! bytes (inside strings, inside containers, after a backslash) are
//! ignored — they are part of the value, not a record terminator.
//!
//! State is resumable across `feedBytes` calls so streaming callers can
//! drive the scanner over partial buffers.

const std = @import("std");
const simd = @import("simd.zig");

pub const ScannerState = struct {
    depth: u32 = 0,
    in_string: bool = false,
    escape_pending: bool = false,
};

/// Advance `state` by every byte in `data`, appending the *absolute*
/// offset (`base_offset + i`) of each `\n` byte that occurs at depth 0
/// outside a string with no escape pending.
///
/// Caller owns `out_boundaries` and the `allocator` used to grow it.
pub fn feedBytes(
    state: *ScannerState,
    data: []const u8,
    base_offset: usize,
    out_boundaries: *std.ArrayList(usize),
    allocator: std.mem.Allocator,
) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < data.len) {
        // In-string fast path: bulk-skip safe ASCII content.
        if (state.in_string and !state.escape_pending) {
            const safe = simd.scanStringBody(data[i..]);
            i += safe;
            if (i >= data.len) return;
        }
        // Out-of-string fast path: bulk-skip non-structural bytes.
        if (!state.in_string) {
            const boring = simd.scanStructural(data[i..]);
            i += boring;
            if (i >= data.len) return;
        }

        const b = data[i];
        if (state.in_string) {
            if (state.escape_pending) {
                state.escape_pending = false;
            } else if (b == '\\') {
                state.escape_pending = true;
            } else if (b == '"') {
                state.in_string = false;
            }
            i += 1;
        } else switch (b) {
            '"' => {
                state.in_string = true;
                i += 1;
            },
            '{', '[' => {
                state.depth += 1;
                i += 1;
            },
            '}', ']' => {
                state.depth -|= 1;
                i += 1;
            },
            '\n' => {
                if (state.depth == 0) try out_boundaries.append(allocator, base_offset + i);
                i += 1;
            },
            else => i += 1,
        }
    }
}

/// State-only sweep — advances `state` over `data` without recording any
/// boundaries. Used by the file aligner to bring the scanner up to a
/// chunk midpoint before searching forward.
pub fn advanceState(state: *ScannerState, data: []const u8) void {
    var i: usize = 0;
    while (i < data.len) {
        if (state.in_string and !state.escape_pending) {
            i += simd.scanStringBody(data[i..]);
            if (i >= data.len) return;
        }
        if (!state.in_string) {
            i += simd.scanStructural(data[i..]);
            if (i >= data.len) return;
        }

        const b = data[i];
        if (state.in_string) {
            if (state.escape_pending) {
                state.escape_pending = false;
            } else if (b == '\\') {
                state.escape_pending = true;
            } else if (b == '"') {
                state.in_string = false;
            }
        } else switch (b) {
            '"' => state.in_string = true,
            '{', '[' => state.depth += 1,
            '}', ']' => state.depth -|= 1,
            else => {},
        }
        i += 1;
    }
}

/// Starting from `from`, advance `state` over `data[from..end]` until a
/// depth-0/outside-string `\n` is consumed; return the position one past
/// that newline. Returns `end` if no record-aligned newline exists in
/// the range. Mutates `state` to reflect bytes consumed.
pub fn findNextRecordEnd(
    state: *ScannerState,
    data: []const u8,
    from: usize,
    end: usize,
) usize {
    std.debug.assert(from <= end);
    std.debug.assert(end <= data.len);

    var i: usize = from;
    while (i < end) {
        if (state.in_string and !state.escape_pending) {
            const safe = simd.scanStringBody(data[i..end]);
            i += safe;
            if (i >= end) return end;
        }
        if (!state.in_string) {
            const boring = simd.scanStructural(data[i..end]);
            i += boring;
            if (i >= end) return end;
        }

        const b = data[i];
        if (state.in_string) {
            if (state.escape_pending) {
                state.escape_pending = false;
            } else if (b == '\\') {
                state.escape_pending = true;
            } else if (b == '"') {
                state.in_string = false;
            }
            i += 1;
        } else switch (b) {
            '"' => {
                state.in_string = true;
                i += 1;
            },
            '{', '[' => {
                state.depth += 1;
                i += 1;
            },
            '}', ']' => {
                state.depth -|= 1;
                i += 1;
            },
            '\n' => {
                i += 1;
                if (state.depth == 0) return i;
            },
            else => i += 1,
        }
    }
    return end;
}

/// Conservative count of complete top-level values in a fully-buffered
/// slice. Used as an `ensureTotalCapacity` upper bound for `meta_list`.
///
/// Counts each depth-0/outside-string `\n` as one record boundary, plus
/// one if the slice ends mid-value (no trailing newline). Worst case is
/// a slight over-allocation, which is fine for arena pre-sizing.
pub fn countTopLevelValues(data: []const u8) usize {
    var state = ScannerState{};
    var count: usize = 0;
    var i: usize = 0;
    var saw_content_since_last_boundary = false;

    while (i < data.len) {
        if (state.in_string and !state.escape_pending) {
            const safe = simd.scanStringBody(data[i..]);
            if (safe > 0) saw_content_since_last_boundary = true;
            i += safe;
            if (i >= data.len) break;
        }
        if (!state.in_string) {
            const boring = simd.scanStructural(data[i..]);
            // Boring bytes outside strings can be whitespace; only count as
            // content if any non-whitespace appeared. Conservative: bump
            // the flag whenever we advance, since this only affects the
            // tail-of-value count and over-counting is acceptable.
            if (boring > 0) saw_content_since_last_boundary = true;
            i += boring;
            if (i >= data.len) break;
        }

        const b = data[i];
        if (state.in_string) {
            saw_content_since_last_boundary = true;
            if (state.escape_pending) {
                state.escape_pending = false;
            } else if (b == '\\') {
                state.escape_pending = true;
            } else if (b == '"') {
                state.in_string = false;
            }
            i += 1;
        } else switch (b) {
            '"' => {
                state.in_string = true;
                saw_content_since_last_boundary = true;
                i += 1;
            },
            '{', '[' => {
                state.depth += 1;
                saw_content_since_last_boundary = true;
                i += 1;
            },
            '}', ']' => {
                state.depth -|= 1;
                saw_content_since_last_boundary = true;
                i += 1;
            },
            '\n' => {
                if (state.depth == 0 and saw_content_since_last_boundary) {
                    count += 1;
                    saw_content_since_last_boundary = false;
                }
                i += 1;
            },
            else => {
                if (b != ' ' and b != '\t' and b != '\r') saw_content_since_last_boundary = true;
                i += 1;
            },
        }
    }

    // Tail value with no trailing newline at depth 0.
    if (saw_content_since_last_boundary and state.depth == 0 and !state.in_string) {
        count += 1;
    }
    return count;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn scanAll(data: []const u8, allocator: std.mem.Allocator) ![]const usize {
    var state = ScannerState{};
    var bnds = std.ArrayList(usize){};
    errdefer bnds.deinit(allocator);
    try feedBytes(&state, data, 0, &bnds, allocator);
    return bnds.toOwnedSlice(allocator);
}

test "scanAll: empty input zero boundaries" {
    const bnds = try scanAll("", testing.allocator);
    defer testing.allocator.free(bnds);
    try testing.expectEqual(@as(usize, 0), bnds.len);
}

test "scanAll: compact JSONL three lines three boundaries" {
    const bnds = try scanAll("1\n2\n3\n", testing.allocator);
    defer testing.allocator.free(bnds);
    try testing.expectEqualSlices(usize, &.{ 1, 3, 5 }, bnds);
}

test "scanAll: pretty object spans three lines one boundary" {
    const data = "{\n  \"a\": 1\n}\n";
    const bnds = try scanAll(data, testing.allocator);
    defer testing.allocator.free(bnds);
    try testing.expectEqual(@as(usize, 1), bnds.len);
    try testing.expectEqual(data.len - 1, bnds[0]);
}

test "scanAll: string with literal newline emits no boundary" {
    // A string that contains a raw \n byte (e.g. inside a multi-line
    // string literal). The newline lives inside the string and must
    // not be treated as a record terminator.
    const data = "\"line1\nline2\"\n";
    const bnds = try scanAll(data, testing.allocator);
    defer testing.allocator.free(bnds);
    try testing.expectEqual(@as(usize, 1), bnds.len);
    try testing.expectEqual(data.len - 1, bnds[0]);
}

test "scanAll: structural chars inside string ignored" {
    const data = "{\"a\":\"{[}]\"}\n";
    const bnds = try scanAll(data, testing.allocator);
    defer testing.allocator.free(bnds);
    try testing.expectEqual(@as(usize, 1), bnds.len);
    try testing.expectEqual(data.len - 1, bnds[0]);
}

test "scanAll: escape pending preserves through feedBytes split" {
    // Emulate a stream split: feed "{\"a\":\"x\\" then "n\"}\n".
    // The trailing \\ must leave escape_pending set; the next call's
    // 'n' is consumed as the escape target, not as a string-closer.
    var state = ScannerState{};
    var bnds = std.ArrayList(usize){};
    defer bnds.deinit(testing.allocator);

    try feedBytes(&state, "{\"a\":\"x\\", 0, &bnds, testing.allocator);
    try testing.expect(state.in_string);
    try testing.expect(state.escape_pending);

    try feedBytes(&state, "n\"}\n", 8, &bnds, testing.allocator);
    try testing.expect(!state.in_string);
    try testing.expect(!state.escape_pending);
    try testing.expectEqual(@as(usize, 1), bnds.items.len);
    try testing.expectEqual(@as(usize, 11), bnds.items[0]);
}

test "scanAll: escaped backslash before quote terminates string" {
    // Input: "ab\\" closes after 4 string-content bytes (a, b, \\, \\).
    // The closing " is the literal at offset 5. Next \n at offset 6 is
    // a record boundary. Without correct \\ handling, the scanner would
    // think the trailing \" is escaped and never close the string.
    const data = "\"ab\\\\\"\n";
    const bnds = try scanAll(data, testing.allocator);
    defer testing.allocator.free(bnds);
    try testing.expectEqual(@as(usize, 1), bnds.len);
    try testing.expectEqual(data.len - 1, bnds[0]);
}

test "scanAll: unterminated string at EOF terminates without hang" {
    // Defensive: malformed unterminated string must not infinite-loop
    // and must not emit phantom boundaries. The parser will reject this
    // input separately; the scanner just stays sane.
    const data = "{\"oops: 1\n";
    const bnds = try scanAll(data, testing.allocator);
    defer testing.allocator.free(bnds);
    // Still in_string at EOF → the \n was inside a string → no boundaries.
    try testing.expectEqual(@as(usize, 0), bnds.len);
}

test "countTopLevelValues: matches scanAll count plus tail value" {
    // 3 newline-terminated values: count = 3.
    try testing.expectEqual(@as(usize, 3), countTopLevelValues("1\n2\n3\n"));
    // 3 values, last with no trailing newline: count = 3.
    try testing.expectEqual(@as(usize, 3), countTopLevelValues("1\n2\n3"));
    // Pretty single value: count = 1.
    try testing.expectEqual(@as(usize, 1), countTopLevelValues("{\n  \"a\": 1\n}\n"));
    // Empty / whitespace-only: count = 0.
    try testing.expectEqual(@as(usize, 0), countTopLevelValues(""));
    try testing.expectEqual(@as(usize, 0), countTopLevelValues("\n\n  \n"));
}

test "findNextRecordEnd: aligns past mid-value newline inside string" {
    var state = ScannerState{};
    // "abc\nxyz" is one string value containing a literal \n at offset 4.
    // findNextRecordEnd starting at offset 0 must walk past the in-string
    // \n and return the offset of the *trailing* record-terminator \n.
    const data = "\"abc\nxyz\"\n42\n";
    const end = findNextRecordEnd(&state, data, 0, data.len);
    try testing.expectEqual(@as(usize, 10), end);
    try testing.expect(!state.in_string);
    try testing.expectEqual(@as(u32, 0), state.depth);
}
