//! Parser-owned chunk-alignment detector.
//!
//! Workers receive byte ranges from the feeder and need to find a
//! guaranteed top-level JSON value boundary at-or-before their starting
//! offset. This module is the single source of truth for that decision:
//! it drives the production parser's state machine to confirm that a
//! candidate `\n` is actually a between-records terminator (and not, say,
//! a literal newline inside a JSON string).
//!
//! Public surface:
//!   - `LOOKBACK_BYTES` — fixed 4 KiB lookback budget.
//!   - `findValueStart(data, from)` — first byte that could begin a
//!     top-level value at-or-after `from` (skips JSON whitespace).
//!   - `tryAlignChunk(data, hint_start, lookback)` — produces an
//!     `AlignResult` with the confirmed boundary index, `in_progress`
//!     when the lookback budget was exhausted, or `empty` for
//!     whitespace-only input.

const std = @import("std");
const simd = @import("simd.zig");
const parser_mod = @import("parser.zig");

const Parser = parser_mod.Parser;
const FeedResult = parser_mod.FeedResult;

pub const LOOKBACK_BYTES: usize = 4 * 1024;

pub const AlignResult = union(enum) {
    aligned_at: usize,
    in_progress,
    empty,
};

pub fn findValueStart(data: []const u8, from: usize) ?usize {
    if (from >= data.len) return null;
    const skip = simd.skipWhitespace(data[from..]);
    const idx = from + skip;
    if (idx >= data.len) return null;
    return idx;
}

pub fn tryAlignChunk(
    data: []const u8,
    hint_start: usize,
    lookback: []const u8,
) AlignResult {
    // Empty lookback at offset 0 = first chunk of input by definition.
    if (hint_start == 0 and lookback.len == 0) return .{ .aligned_at = 0 };

    if (hint_start > data.len) {
        return if (findValueStart(data, 0) == null) .empty else .in_progress;
    }

    var search_end: usize = hint_start;
    while (search_end > 0) {
        const nl_rel = std.mem.lastIndexOfScalar(u8, data[0..search_end], '\n') orelse break;
        const value_start = nl_rel + 1;
        switch (probeFromAfterNewline(data, value_start)) {
            .confirmed => |end_abs| {
                if (end_abs <= hint_start) {
                    if (findValueStart(data, end_abs)) |start_abs| {
                        return .{ .aligned_at = start_abs };
                    }
                    return .{ .aligned_at = end_abs };
                }
                // Value at `value_start` extends past hint_start. Only acceptable
                // when the value starts exactly at hint_start (chunk owns it).
                if (value_start == hint_start) return .{ .aligned_at = hint_start };
            },
            .need_more, .rejected => {},
        }
        search_end = nl_rel;
    }

    // No usable `\n` inside `data[0..hint_start]`. Walk the lookback's last `\n`
    // back through the boundary into `data` to confirm the spanning value.
    if (lookback.len > 0) {
        const lookback_used = if (lookback.len > LOOKBACK_BYTES)
            lookback[lookback.len - LOOKBACK_BYTES ..]
        else
            lookback;

        var lb_search_end: usize = lookback_used.len;
        while (lb_search_end > 0) {
            const nl_lb = std.mem.lastIndexOfScalar(u8, lookback_used[0..lb_search_end], '\n') orelse break;
            switch (probeAcrossLookback(lookback_used, nl_lb + 1, data)) {
                .confirmed_in_data => |consumed_in_data| {
                    if (consumed_in_data <= hint_start) {
                        if (findValueStart(data, consumed_in_data)) |start_abs| {
                            return .{ .aligned_at = start_abs };
                        }
                        return .{ .aligned_at = consumed_in_data };
                    }
                    if (hint_start == 0) {
                        if (findValueStart(data, consumed_in_data)) |start_abs| {
                            return .{ .aligned_at = start_abs };
                        }
                        return .{ .aligned_at = consumed_in_data };
                    }
                    // Spanning value extends past hint_start. The value started
                    // in the lookback (before data[0]), so hint_start is mid-record.
                    // The previous chunk-owner covers it; we have nothing to align to.
                },
                .confirmed_in_lookback => {
                    if (findValueStart(data, 0)) |start_abs| {
                        if (hint_start == 0 or start_abs <= hint_start) return .{ .aligned_at = start_abs };
                    }
                },
                .need_more, .rejected => {},
            }
            lb_search_end = nl_lb;
        }
    }

    if (findValueStart(data, 0) == null and !hasNonWhitespace(lookback)) return .empty;
    return .in_progress;
}

const ProbeResult = union(enum) {
    confirmed: usize,
    need_more,
    rejected,
};

const ProbeAcrossResult = union(enum) {
    confirmed_in_lookback,
    confirmed_in_data: usize,
    need_more,
    rejected,
};

fn probeFromAfterNewline(data: []const u8, start: usize) ProbeResult {
    if (start >= data.len) return .need_more;

    var p = Parser.init(std.heap.page_allocator) catch return .rejected;
    defer p.deinit();

    // is_eof=false: the parser's auto-close-on-EOF behaviour synthesises
    // phantom container closes on truncated input, which would produce
    // false-positive boundaries here.
    const r = p.feed(data[start..], false) catch return .rejected;
    return switch (r) {
        .done => |d| {
            const end_abs = start + d.consumed;
            if (!trailingLooksTopLevel(data[end_abs..], "")) return .rejected;
            return .{ .confirmed = end_abs };
        },
        .need_more => .need_more,
    };
}

fn probeAcrossLookback(lookback: []const u8, lb_start: usize, data: []const u8) ProbeAcrossResult {
    if (lb_start > lookback.len) return .rejected;

    var p = Parser.init(std.heap.page_allocator) catch return .rejected;
    defer p.deinit();

    if (lb_start < lookback.len) {
        const r1 = p.feed(lookback[lb_start..], false) catch return .rejected;
        switch (r1) {
            // Tail of lookback after the parsed value, then data, must not
            // begin with a structural mid-record byte — otherwise the value
            // we parsed was a key/element of an enclosing structure.
            .done => |d| {
                if (!trailingLooksTopLevel(lookback[lb_start + d.consumed ..], data)) return .rejected;
                return .confirmed_in_lookback;
            },
            .need_more => {},
        }

        const r2 = p.feed(data, false) catch return .rejected;
        return switch (r2) {
            .done => |d| {
                if (!trailingLooksTopLevel(data[d.consumed..], "")) return .rejected;
                return .{ .confirmed_in_data = d.consumed };
            },
            .need_more => .need_more,
        };
    }

    // Candidate `\n` is the last byte of lookback: nothing to feed before
    // data. Parser sees data fresh — if it parses cleanly the `\n` was a
    // real value terminator and data[0] is a fresh value boundary.
    const r = p.feed(data, false) catch return .rejected;
    return switch (r) {
        .done => |d| {
            if (!trailingLooksTopLevel(data[d.consumed..], "")) return .rejected;
            return .confirmed_in_lookback;
        },
        .need_more => .need_more,
    };
}

/// After the parser reports `.done`, the next non-whitespace byte across
/// `prefix ++ rest` must either be missing or be a top-level value-start
/// byte. If it's a structural mid-record byte (`:`, `,`, `}`, `]`), the
/// parser was fooled by a syntactically valid mid-record fragment (e.g.
/// the key string of an object) and the boundary is bogus.
fn trailingLooksTopLevel(prefix: []const u8, rest: []const u8) bool {
    if (findValueStart(prefix, 0)) |idx| return isTopLevelStart(prefix[idx]);
    const idx = findValueStart(rest, 0) orelse return true;
    return isTopLevelStart(rest[idx]);
}

fn isTopLevelStart(b: u8) bool {
    return switch (b) {
        '{', '[', '"', '-', '0'...'9', 't', 'f', 'n', 'I', 'N' => true,
        else => false,
    };
}

fn hasNonWhitespace(data: []const u8) bool {
    for (data) |b| switch (b) {
        ' ', '\t', '\n', '\r' => {},
        else => return true,
    };
    return false;
}
