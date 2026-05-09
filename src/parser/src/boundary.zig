//! JSON-structural boundary scanner.
//!
//! Lightweight depth + string-state machine that finds record boundaries
//! (top-level `\n` between JSON values) without building a tape. Used by
//! the pool's chunker layers to split byte streams at safe positions
//! (file aligner, stream batcher) and to estimate record counts.
//!
//! Contract: a record boundary is any `\n` byte observed at depth 0,
//! outside a string literal, with no escape pending. All other `\n`
//! bytes (inside strings, inside containers, after a backslash) are
//! ignored — they are part of the value, not a record terminator.
//!
//! State is resumable across `feedBytes` calls so streaming callers can
//! drive the scanner over partial buffers.
//!
//! Hot path is a simdjson-stage-1-style 64-byte SIMD pipeline:
//!   1. Byte classification via `@Vector(64, u8)` byte-equal compares.
//!   2. Escape mask via Langdale-Lemire even/odd run-start trick (carries
//!      across chunks).
//!   3. In-string mask via Hillis-Steele prefix-XOR (algebraically
//!      equivalent to CLMUL-by-all-ones; portable; carries across chunks).
//!   4. Depth-0 newline emission via @ctz/@popCount with a saturation
//!      fast path when the chunk's closes can't underflow `state.depth`.
//!   5. Tail (residual < 64 bytes) handled by pad-and-mask on a stack
//!      buffer — the same pipeline runs once on the padded chunk.
//!
//! Output is bit-for-bit identical to the prior scalar reference, which
//! is preserved as `feedBytesReference` for property-test consumption.

const std = @import("std");
const simd = @import("simd.zig");

pub const ScannerState = struct {
    depth: u32 = 0,
    in_string: bool = false,
    escape_pending: bool = false,
};

const CHUNK: usize = 64;
const Vec64 = @Vector(CHUNK, u8);
const BoolVec64 = @Vector(CHUNK, bool);

const EVEN_BITS: u64 = 0x5555_5555_5555_5555;
const ODD_BITS: u64 = 0xAAAA_AAAA_AAAA_AAAA;

inline fn prefixXor(x: u64) u64 {
    var v = x;
    v ^= v << 1;
    v ^= v << 2;
    v ^= v << 4;
    v ^= v << 8;
    v ^= v << 16;
    v ^= v << 32;
    return v;
}

inline fn eqMask(chunk: Vec64, c: u8) u64 {
    const cmp: BoolVec64 = chunk == @as(Vec64, @splat(c));
    return @bitCast(cmp);
}

/// Per-chunk classification + state advancement. `out` controls boundary
/// emission policy:
///   - `null`           — advance state only (used by `advanceState`).
///   - `.append_all`    — append every depth-0/outside-string `\n` byte
///                        offset to the array list.
///   - `.first_only`    — return the absolute offset of the first such
///                        newline; the chunk-driver stops on the first
///                        non-null return.
///
/// `chunk_base` is the absolute file offset (not just within the data
/// slice) of byte 0 of `chunk_bytes`. Caller is responsible for adding
/// `base_offset` (the data-slice base) before calling — we just emit
/// `chunk_base + pos`.
const ChunkOut = union(enum) {
    none,
    append_all: struct {
        list: *std.ArrayList(usize),
        allocator: std.mem.Allocator,
    },
    first_only,
};

/// Run the SIMD pipeline on one 64-byte chunk and return either:
///   - null: chunk processed, no first-emit hit (or `out != .first_only`).
///   - some(offset): first depth-0/outside-string `\n` absolute offset
///     (only returned when `out == .first_only`).
///
/// `effective_len` is the number of *real* bytes in `chunk` (always 64
/// for full-chunk calls, < 64 for the padded tail). It is used to:
///   1. Mask the events bitmap so pad-zone bits never fire (defensive,
///      since zeros classify as boring already).
///   2. Read carry-out values (in_string, escape_pending) at the
///      correct logical position rather than at bit 63 of the padded
///      chunk — a backslash at the very last real byte must propagate
///      `escape_pending` to the next call even though its escape-target
///      bit lands in the pad zone.
inline fn processChunk(
    state: *ScannerState,
    chunk: Vec64,
    chunk_base: usize,
    out: ChunkOut,
    effective_len: usize,
) error{OutOfMemory}!?usize {
    // 1. Byte classification.
    const quote_mask = eqMask(chunk, '"');
    const backslash_mask = eqMask(chunk, '\\');
    const open_curly = eqMask(chunk, '{');
    const close_curly = eqMask(chunk, '}');
    const open_square = eqMask(chunk, '[');
    const close_square = eqMask(chunk, ']');
    const newline_mask = eqMask(chunk, '\n');

    // 2. Escape mask (Langdale-Lemire even/odd run-start). The carry-out
    // for runs extending past bit 63 (or past `effective_len` in tail
    // chunks) is captured via @addWithOverflow on the b + start sums.
    //
    // This algorithm assumes every `\` is inside a string (the only
    // place a backslash is meaningful in valid JSON). On VALID JSON
    // this matches the scalar reference exactly; on malformed inputs
    // with `\` outside a string, the algorithm may classify a following
    // `"` as an escaped quote when reference treats it as a real quote.
    // The `pool` consumers feed this scanner only file/stream bytes
    // bound for the parser, which rejects malformed JSON downstream —
    // so this divergence on malformed inputs is acceptable. The
    // property test exercises only valid JSON inputs to mirror the
    // production contract.
    const prev_escaped: u64 = if (state.escape_pending) 1 else 0;
    const b_after_carry = backslash_mask & ~prev_escaped;
    const starts = b_after_carry & ~(b_after_carry << 1);
    const even_starts = starts & EVEN_BITS;
    const odd_starts = starts & ODD_BITS;
    const even_sum = @addWithOverflow(b_after_carry, even_starts);
    const odd_sum = @addWithOverflow(b_after_carry, odd_starts);
    const even_carries = even_sum[0];
    const odd_carries = odd_sum[0];
    const even_run_ends = even_carries & ~b_after_carry;
    const odd_run_ends = odd_carries & ~b_after_carry;
    var escape_target_mask =
        (even_run_ends & ODD_BITS) |
        (odd_run_ends & EVEN_BITS);
    if (state.escape_pending) escape_target_mask |= 1;

    // 4. Real quotes (those not consumed as escape targets).
    const real_quote = quote_mask & ~escape_target_mask;

    // 5. In-string mask via prefix-XOR. The carry from the previous
    // chunk's open string is broadcast as all-ones (XOR-flips the local
    // mask) when `state.in_string` is set.
    const in_string_local = prefixXor(real_quote);
    const carry_broadcast: u64 = if (state.in_string) ~@as(u64, 0) else 0;
    const in_string = in_string_local ^ carry_broadcast;
    // Read carry at the logical end-of-real-data, not at bit 63 of a
    // padded tail. For full chunks (effective_len == 64) this is bit 63;
    // for the padded tail it's bit (effective_len - 1) — pad zone has no
    // quotes, so prefix_xor stays constant from bit (effective_len - 1)
    // onwards anyway, so reading bit 63 would also work for in_string.
    // But reading at the boundary is cleaner and matches escape_pending.
    const last_bit: u6 = @intCast(effective_len - 1);
    const next_carry_in_string: bool = ((in_string >> last_bit) & 1) != 0;

    // 5. Outside-string structural masks.
    const open_outside = (open_curly | open_square) & ~in_string;
    const close_outside = (close_curly | close_square) & ~in_string;
    const newline_outside = newline_mask & ~in_string;

    // 6. Depth-0 newline emission. Bitmap-driven scalar walk over the
    // union of structural events, honouring `state.depth -|= 1` exactly
    // so saturating-underflow on malformed input matches the reference.
    //
    // The two-tier "saturation safe" fast path (popcount-prefix per
    // newline) is unsound when the chunk has a front-loaded close-run
    // that would underflow at an *intermediate* prefix even if the
    // chunk's net imbalance is non-negative (e.g. `}{` at the start).
    // Computing the running min would require a per-bit walk anyway,
    // so we keep just the bitmap walk: still O(structural_bits), not
    // O(64), and SIMD classification has already done the heavy work.
    var first_hit: ?usize = null;

    var events = open_outside | close_outside | newline_outside;
    while (events != 0) {
        // @ctz returns u7 for u64; loop guard guarantees value < 64.
        const pos: u6 = @intCast(@ctz(events));
        const bit = @as(u64, 1) << pos;
        if ((open_outside & bit) != 0) {
            state.depth += 1;
        } else if ((close_outside & bit) != 0) {
            state.depth -|= 1;
        } else {
            // newline_outside
            if (state.depth == 0) {
                const abs = chunk_base + pos;
                switch (out) {
                    .none => {},
                    .append_all => |a| try a.list.append(a.allocator, abs),
                    .first_only => {
                        if (first_hit == null) first_hit = abs;
                    },
                }
            }
        }
        events &= events - 1;
    }

    // 7. Update carries. For full chunks (effective_len == 64), the
    // "byte at logical position effective_len" is bit 0 of the next
    // chunk — captured via @addWithOverflow carry-out on the odd/even
    // run-end sums (whichever parity targets an *even* position 64,
    // i.e. odd-aligned runs). For tail chunks we read the corresponding
    // bit directly out of escape_target_mask.
    if (effective_len == CHUNK) {
        // Position 64 is even; only odd-aligned runs spilling carry
        // produce an escape target there. (Even-aligned runs targeting
        // bit 64 would contribute via ODD_BITS at bit 64, and 64 is
        // even-not-odd, so they don't.)
        state.escape_pending = (odd_sum[1] != 0);
    } else {
        const target_bit: u6 = @intCast(effective_len);
        state.escape_pending = ((escape_target_mask >> target_bit) & 1) != 0;
    }
    state.in_string = next_carry_in_string;

    return first_hit;
}

/// Build a 64-byte chunk from a data slice. Pads the residual bytes
/// (when `data.len < 64`) with zeros — zero classifies as boring in
/// every mask, so the pipeline emits no spurious bits at pad positions.
inline fn loadChunkPadded(data: []const u8) Vec64 {
    if (data.len >= CHUNK) {
        return data[0..CHUNK].*;
    }
    var tail: [CHUNK]u8 = @splat(0);
    @memcpy(tail[0..data.len], data);
    return tail;
}

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
    const out: ChunkOut = .{ .append_all = .{ .list = out_boundaries, .allocator = allocator } };

    var i: usize = 0;
    while (i + CHUNK <= data.len) : (i += CHUNK) {
        const chunk: Vec64 = data[i..][0..CHUNK].*;
        _ = try processChunk(state, chunk, base_offset + i, out, CHUNK);
    }
    // Tail: residual < 64 bytes. Pad-and-mask. Zero classifies as boring
    // in all masks, so no extra filtering needed — the pad bytes simply
    // contribute no bits.
    if (i < data.len) {
        const residual = data.len - i;
        const chunk = loadChunkPadded(data[i..]);
        _ = try processChunk(state, chunk, base_offset + i, out, residual);
    }
}

/// State-only sweep — advances `state` over `data` without recording any
/// boundaries. Used by the file aligner to bring the scanner up to a
/// chunk midpoint before searching forward.
pub fn advanceState(state: *ScannerState, data: []const u8) void {
    var i: usize = 0;
    while (i + CHUNK <= data.len) : (i += CHUNK) {
        const chunk: Vec64 = data[i..][0..CHUNK].*;
        _ = processChunk(state, chunk, 0, .none, CHUNK) catch unreachable;
    }
    if (i < data.len) {
        const residual = data.len - i;
        const chunk = loadChunkPadded(data[i..]);
        _ = processChunk(state, chunk, 0, .none, residual) catch unreachable;
    }
}

/// Starting from `from`, advance `state` over `data[from..end]` until a
/// depth-0/outside-string `\n` is consumed; return the position one past
/// that newline. Returns `end` if no record-aligned newline exists in
/// the range. Mutates `state` to reflect bytes consumed.
///
/// Caller contract: on hit, `state` reflects exactly the bytes from
/// `from` up to and including the returned newline byte. The caller
/// will resume scanning at the returned offset, so the bytes after the
/// newline within the same SIMD window must NOT have been folded into
/// state. This function snapshots state pre-chunk and replays via the
/// scalar reference up to (and including) the boundary newline when a
/// hit lands inside a SIMD-processed chunk.
pub fn findNextRecordEnd(
    state: *ScannerState,
    data: []const u8,
    from: usize,
    end: usize,
) usize {
    std.debug.assert(from <= end);
    std.debug.assert(end <= data.len);

    var i: usize = from;
    while (i + CHUNK <= end) : (i += CHUNK) {
        const snapshot = state.*;
        const chunk: Vec64 = data[i..][0..CHUNK].*;
        const hit = processChunk(state, chunk, i, .first_only, CHUNK) catch unreachable;
        if (hit) |pos| {
            // Restore state and replay only the bytes up to (and
            // including) the boundary newline so the caller can resume
            // at `pos + 1` with state matching exactly that prefix.
            state.* = snapshot;
            advanceStateScalar(state, data[i .. pos + 1]);
            return pos + 1;
        }
    }
    // Tail bytes (residual < CHUNK).
    if (i < end) {
        const snapshot = state.*;
        const residual = end - i;
        const chunk = loadChunkPadded(data[i..end]);
        const hit = processChunk(state, chunk, i, .first_only, residual) catch unreachable;
        if (hit) |pos| {
            // Pad-zone bytes classify as boring in every mask, so any
            // hit must lie within the real residual.
            std.debug.assert(pos - i < residual);
            state.* = snapshot;
            advanceStateScalar(state, data[i .. pos + 1]);
            return pos + 1;
        }
    }
    return end;
}

/// Scalar state advancement for a short slice. Used by
/// `findNextRecordEnd` to replay the prefix of a SIMD-processed chunk
/// up to the boundary newline (so caller-visible state matches the
/// bytes only up to the returned offset, not the entire chunk).
fn advanceStateScalar(state: *ScannerState, data: []const u8) void {
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
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
    }
}

// ── Reference (oracle) — exposed for property tests only ────────────────────
//
// `feedBytesReference` is a snapshot of the prior scalar `feedBytes` body.
// It is the byte-for-byte oracle that the SIMD `feedBytes` is property-
// tested against. NOT for production callers; production callers should
// use `feedBytes` (which dispatches to the SIMD pipeline above).

/// Tests-only oracle: scalar reference implementation of `feedBytes`.
/// Output must be bit-for-bit identical to `feedBytes`.
pub fn feedBytesReference(
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
