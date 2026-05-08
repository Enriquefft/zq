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

// ── Parallel prefix-sum support ──────────────────────────────────────────────

/// Categorical input/output state for a stripe summary. Index encoding:
///   0 = outside string
///   1 = inside string, no escape pending
///   2 = inside string, escape pending
///
/// `depth` itself is not categorical (unbounded), so it is composed
/// additively across stripes via `Stripe.depth_delta`.
pub const Cat = enum(u2) {
    oos = 0,
    is_no_esc = 1,
    is_esc = 2,

    fn fromState(s: ScannerState) Cat {
        if (!s.in_string) return .oos;
        return if (s.escape_pending) .is_esc else .is_no_esc;
    }
};

/// Per-stripe pass-1 summary. For each of the 3 categorical input states,
/// records the terminal categorical state and the *signed* depth delta
/// accumulated over the stripe. The delta is signed (i64) rather than the
/// saturating `u32` of `ScannerState`: parallel composition requires
/// additivity, which `-|=` would break when an early-stripe excursion
/// would dip below zero from a `depth=0` starting point but stays
/// non-negative when started from the real (positive) carry.
pub const Stripe = struct {
    terminal: [3]Cat,
    depth_delta: [3]i64,
};

/// Run the scanner over `data` from each of the 3 categorical starting
/// states (`oos`, `is_no_esc`, `is_esc`) with depth tracked as a signed
/// counter (no saturation). Returns the per-input terminal categorical
/// state and depth delta. Pure function of `data`. Used by the parallel
/// boundary-scan feeder to drive the serial stitch step.
pub fn summarizeStripe(data: []const u8) Stripe {
    var out: Stripe = undefined;
    inline for ([_]Cat{ .oos, .is_no_esc, .is_esc }, 0..) |start, idx| {
        const r = summarizeFrom(start, data);
        out.terminal[idx] = r.cat;
        out.depth_delta[idx] = r.depth_delta;
    }
    return out;
}

const SummaryResult = struct { cat: Cat, depth_delta: i64 };

fn summarizeFrom(start: Cat, data: []const u8) SummaryResult {
    var in_string = (start != .oos);
    var escape_pending = (start == .is_esc);
    var depth: i64 = 0;
    var i: usize = 0;
    while (i < data.len) {
        if (in_string and !escape_pending) {
            i += simd.scanStringBody(data[i..]);
            if (i >= data.len) break;
        }
        if (!in_string) {
            i += simd.scanStructural(data[i..]);
            if (i >= data.len) break;
        }

        const b = data[i];
        if (in_string) {
            if (escape_pending) {
                escape_pending = false;
            } else if (b == '\\') {
                escape_pending = true;
            } else if (b == '"') {
                in_string = false;
            }
        } else switch (b) {
            '"' => in_string = true,
            '{', '[' => depth += 1,
            '}', ']' => depth -= 1,
            else => {},
        }
        i += 1;
    }

    const cat: Cat = if (!in_string) .oos else if (escape_pending) .is_esc else .is_no_esc;
    return .{ .cat = cat, .depth_delta = depth };
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

// ── Stripe summary tests (parallel boundary scan) ───────────────────────────

test "summarizeStripe: empty stripe is identity for all starts" {
    const s = summarizeStripe("");
    try testing.expectEqual(Cat.oos, s.terminal[@intFromEnum(Cat.oos)]);
    try testing.expectEqual(Cat.is_no_esc, s.terminal[@intFromEnum(Cat.is_no_esc)]);
    try testing.expectEqual(Cat.is_esc, s.terminal[@intFromEnum(Cat.is_esc)]);
    for (s.depth_delta) |d| try testing.expectEqual(@as(i64, 0), d);
}

test "summarizeStripe: pure JSONL terminal stays oos with zero depth delta" {
    const s = summarizeStripe("1\n2\n3\n");
    try testing.expectEqual(Cat.oos, s.terminal[@intFromEnum(Cat.oos)]);
    try testing.expectEqual(@as(i64, 0), s.depth_delta[@intFromEnum(Cat.oos)]);
}

test "summarizeStripe: open brace from oos start lifts depth by one" {
    const s = summarizeStripe("{\"a\": 1");
    try testing.expectEqual(Cat.oos, s.terminal[@intFromEnum(Cat.oos)]);
    try testing.expectEqual(@as(i64, 1), s.depth_delta[@intFromEnum(Cat.oos)]);
}

test "summarizeStripe: starting in_string ignores braces inside" {
    // Starting in_string at offset 0, "{" is literal, "}" is literal. No
    // depth change until the closing quote at offset 1.
    const s = summarizeStripe("{}\":1");
    // From oos start: `{` opens (+1), `}` closes (0), then `"` opens string,
    // `:` and `1` inside string. Terminal is in_string with delta 0.
    try testing.expectEqual(Cat.is_no_esc, s.terminal[@intFromEnum(Cat.oos)]);
    try testing.expectEqual(@as(i64, 0), s.depth_delta[@intFromEnum(Cat.oos)]);
    // From is_no_esc start: `{` literal, `}` literal, `"` closes string,
    // `:` and `1` outside string. Terminal is oos with depth 0.
    try testing.expectEqual(Cat.oos, s.terminal[@intFromEnum(Cat.is_no_esc)]);
    try testing.expectEqual(@as(i64, 0), s.depth_delta[@intFromEnum(Cat.is_no_esc)]);
}

test "summarizeStripe: signed depth delta survives apparent over-close" {
    // A close-then-reopen sequence dips depth below the from-zero baseline.
    // Saturating arithmetic would lose information; signed tracking keeps
    // the additivity needed for the parallel stitch.
    const s = summarizeStripe("}{");
    try testing.expectEqual(Cat.oos, s.terminal[@intFromEnum(Cat.oos)]);
    try testing.expectEqual(@as(i64, 0), s.depth_delta[@intFromEnum(Cat.oos)]);

    const s2 = summarizeStripe("}}{");
    try testing.expectEqual(@as(i64, -1), s2.depth_delta[@intFromEnum(Cat.oos)]);
}

test "summarizeStripe: escape pending start consumes next byte then resumes string" {
    // Starting is_esc, the very first byte clears escape and stays in
    // string. After that a `"` closes the string normally.
    const s = summarizeStripe("n\"");
    try testing.expectEqual(Cat.oos, s.terminal[@intFromEnum(Cat.is_esc)]);
    try testing.expectEqual(@as(i64, 0), s.depth_delta[@intFromEnum(Cat.is_esc)]);
}

test "summarizeStripe: matches advanceState terminal for oos start" {
    // Cross-check: the categorical+signed-depth summary from oos start
    // must agree with `advanceState` on terminal in_string/escape_pending
    // (and on terminal depth, modulo saturation, when the input never
    // dips below zero from oos).
    const data = "[1,2,{\"a\":\"hi\\n\",\"b\":[3,\"x\\\"y\"]}]\n";
    const s = summarizeStripe(data);

    var ref = ScannerState{};
    advanceState(&ref, data);
    const ref_cat = Cat.fromState(ref);
    try testing.expectEqual(ref_cat, s.terminal[@intFromEnum(Cat.oos)]);
    try testing.expectEqual(@as(i64, @intCast(ref.depth)), s.depth_delta[@intFromEnum(Cat.oos)]);
}

test "summarizeStripe: composes across split equal to whole" {
    const whole = "{\"a\":\"x\\n\",\"b\":1}\n{\"c\":2}\n";
    const split: usize = 7; // mid-string, mid-escape arrangement
    const left = whole[0..split];
    const right = whole[split..];

    const s_l = summarizeStripe(left);
    const s_r = summarizeStripe(right);

    // Compose as the parallel stitch would.
    const cat_l = s_l.terminal[@intFromEnum(Cat.oos)];
    const depth_l = s_l.depth_delta[@intFromEnum(Cat.oos)];
    const cat_after = s_r.terminal[@intFromEnum(cat_l)];
    const depth_after = depth_l + s_r.depth_delta[@intFromEnum(cat_l)];

    const s_whole = summarizeStripe(whole);
    try testing.expectEqual(s_whole.terminal[@intFromEnum(Cat.oos)], cat_after);
    try testing.expectEqual(s_whole.depth_delta[@intFromEnum(Cat.oos)], depth_after);
}
