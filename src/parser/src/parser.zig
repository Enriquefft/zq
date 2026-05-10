const std = @import("std");
const types = @import("types");
const err_mod = @import("error");
const simd = @import("simd.zig");
const projection_plan_mod = @import("projection_plan");

pub const ZqError = err_mod.ZqError;
pub const Tape = types.Tape;
pub const ProjectionPlan = projection_plan_mod.ProjectionPlan;

/// Per-parser side-table of plan navigation state. Held *outside* the
/// `Parser` struct so the no-plan parse path's struct layout stays
/// byte-identical to the pre-Commit-1 `Parser` (Zig's auto field
/// reordering shifts every field's offset whenever a new field is
/// appended, regardless of position in source). The pool worker that
/// owns the `Parser` allocates one of these alongside the parser when
/// `CompiledQuery.projection_plan != null` and threads it through
/// `feedPlanned` per call.
///
/// Lifetime: caller-owned. Reset (zero state) on every top-level value
/// reset; deinit drops the heap-allocated `plan_stack` slice.
pub const PlanState = struct {
    /// Active plan-node index. Matched by `feedGeneric` against
    /// `plan.root` at the start of each top-level value.
    plan_cursor: u32,
    /// Per-depth saved plan cursor — pushed on container-open, popped
    /// on container-close. Sized to the parser's `DEPTH_LIMIT` so it
    /// never re-allocates during a single parse.
    plan_stack: []u32,
    /// Snapshot of `tape_buf.items.len` at the start of the current
    /// top-level value. Used to roll the tape back when a plan-aware
    /// predicate rejects the value.
    top_value_tape_start: usize,
    /// Snapshot of `string_buf.items.len` at the start of the current
    /// top-level value. Mirrors `top_value_tape_start` so string
    /// interns allocated inside a dropped record can be reclaimed.
    top_value_string_start: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!PlanState {
        const stack = try allocator.alloc(u32, DEPTH_LIMIT);
        @memset(stack, 0);
        return .{
            .plan_cursor = 0,
            .plan_stack = stack,
            .top_value_tape_start = 0,
            .top_value_string_start = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(s: *PlanState) void {
        s.allocator.free(s.plan_stack);
    }

    pub fn reset(s: *PlanState) void {
        s.plan_cursor = 0;
        s.top_value_tape_start = 0;
        s.top_value_string_start = 0;
    }
};

/// Bundled plan context passed into `feedGeneric` when the caller
/// has a projection plan. Kept as a small struct (two pointers) so
/// `feedPlanned` can pass a single value into the comptime-specialized
/// generic — the `PlanT` type parameter then carries the layout, and
/// `void` selects the no-plan specialization.
const PlanCtx = struct {
    plan: *const ProjectionPlan,
    state: *PlanState,
};

/// The outcome of a single `feed()` call.
pub const FeedResult = union(enum) {
    /// A complete top-level JSON value was parsed.
    /// `tape` is non-owning; valid until next `reset()` or `deinit()`.
    /// `consumed` is how many bytes of the input chunk were used (≤ input.len).
    /// Caller must pass the unconsumed remainder back on the next feed() call.
    done: struct { tape: Tape, consumed: usize },
    /// Valid so far but incomplete; call `feed()` again with the next chunk.
    need_more,
    /// A complete top-level JSON value was parsed but rejected by the
    /// pure-scalar select() predicate threaded in via `feedPlanned`.
    /// The parser has rolled the tape and string-buf back to the
    /// snapshot taken at the start of the value, so `tape` is empty
    /// and the caller may continue feeding the next record. Only the
    /// `feedPlanned` path can return this variant — `feed` (no plan)
    /// never produces it.
    dropped: struct { consumed: usize },
};

const DEPTH_LIMIT: u32 = 512;

// ── Internal types ────────────────────────────────────────────────────────────

const ContainerKind = enum(u1) { object, array };

const StackEntry = struct {
    kind: ContainerKind,
    /// Index of the *_start entry in tape_buf for skip-backfill.
    tape_idx: u32,
    /// True if we entered want_value/want_key via a comma (not container-open).
    after_comma: bool,
};

const NumSubState = enum(u8) {
    neg, // saw '-', expect digit
    leading_zero, // saw '0'
    int, // digits in integer part
    frac_start, // saw '.', expect at least one digit
    frac, // digits in fractional part
    exp_sign, // saw 'e'/'E'
    exp_start, // saw 'e[+-]', expect digit
    exp, // digits in exponent
};

const KeywordKind = enum(u4) { kw_true, kw_false, kw_null, kw_infinity, kw_nan, kw_neg_infinity, kw_neg_nan, kw_nan_lower, kw_neg_nan_lower };

const StateTag = enum(u8) {
    want_value,
    want_key,
    want_colon,
    after_value,
    in_string,
    in_string_escape,
    in_string_unicode,
    in_number,
    in_keyword,
    top_done,
};

// Zero-data payload for entries that carry no value (true/false/null/end tags).
const PAYLOAD_NONE = types.Tape.Payload{ .skip = 0 };

// ── Public Parser type ────────────────────────────────────────────────────────

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tape_buf: std.ArrayListUnmanaged(types.Tape.Entry),
    string_buf: std.ArrayListUnmanaged(u8),
    stack: std.ArrayListUnmanaged(StackEntry),

    state: StateTag,

    // ── String-parsing fields ─────────────────────────────────────────────
    /// Byte offset in string_buf where the current string started.
    string_start: u32,
    /// True when parsing an object key (emits .key instead of .string).
    string_is_key: bool,
    /// Number of UTF-8 continuation bytes still expected (0 = not mid-sequence).
    utf8_pending: u3,
    /// Lead byte of the current multi-byte UTF-8 sequence (used for overlong/range checks).
    utf8_first: u8,
    /// Hex digits accumulated for a \uXXXX escape (0..3 seen so far).
    unicode_count: u3,
    /// Accumulated codepoint bits from hex digits.
    unicode_accum: u21,
    /// Non-zero while waiting for the \uLow half of a surrogate pair.
    unicode_surrogate: u16,

    // ── Number-parsing fields ─────────────────────────────────────────────
    num_sub: NumSubState,
    num_buf: std.ArrayListUnmanaged(u8),
    num_is_float: bool,

    // ── Keyword-parsing fields ────────────────────────────────────────────
    kw_kind: KeywordKind,
    /// Next expected position within the keyword string (starts at 1).
    kw_pos: u8,

    // ── Lifecycle ─────────────────────────────────────────────────────────

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Parser {
        var tape_buf = try std.ArrayListUnmanaged(types.Tape.Entry).initCapacity(allocator, 256);
        errdefer tape_buf.deinit(allocator);
        var string_buf = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 1024);
        errdefer string_buf.deinit(allocator);
        var stack = try std.ArrayListUnmanaged(StackEntry).initCapacity(allocator, 64);
        errdefer stack.deinit(allocator);
        var num_buf = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 64);
        errdefer num_buf.deinit(allocator);

        return Parser{
            .allocator = allocator,
            .tape_buf = tape_buf,
            .string_buf = string_buf,
            .stack = stack,
            .state = .want_value,
            .string_start = 0,
            .string_is_key = false,
            .utf8_pending = 0,
            .utf8_first = 0,
            .unicode_count = 0,
            .unicode_accum = 0,
            .unicode_surrogate = 0,
            .num_sub = .int,
            .num_buf = num_buf,
            .num_is_float = false,
            .kw_kind = .kw_null,
            .kw_pos = 0,
        };
    }

    pub fn deinit(p: *Parser) void {
        p.tape_buf.deinit(p.allocator);
        p.string_buf.deinit(p.allocator);
        p.stack.deinit(p.allocator);
        p.num_buf.deinit(p.allocator);
    }

    pub fn reset(p: *Parser) void {
        p.tape_buf.clearRetainingCapacity();
        p.string_buf.clearRetainingCapacity();
        p.stack.clearRetainingCapacity();
        p.state = .want_value;
        p.string_start = 0;
        p.string_is_key = false;
        p.utf8_pending = 0;
        p.utf8_first = 0;
        p.unicode_count = 0;
        p.unicode_accum = 0;
        p.unicode_surrogate = 0;
        p.num_buf.clearRetainingCapacity();
        p.num_is_float = false;
        p.kw_pos = 0;
    }

    /// Plan-agnostic feed entry point. Trampoline over
    /// `feedGeneric(void, {}, ...)` — the comptime `PlanT == void`
    /// specialization elides every plan-aware code path before LLVM
    /// sees the body. `void` is zero-sized: the `plan_ctx` parameter
    /// generates no stack slot, no register, no machine code.
    ///
    /// Note on byte-identity vs master: `feed`'s emitted body is NOT
    /// byte-identical to master's pre-Commit-1 `feed`. Master inlined
    /// `processEof`, `autoClose`, `finalizeNumber`, and `makeTape`
    /// directly into `feed` (single-callsite inlining heuristic).
    /// Once `feedPlanned` exists in the same translation unit, those
    /// helpers have two callers and LLVM keeps them as out-of-line
    /// functions. The hot loop machine code is structurally
    /// equivalent (same SIMD, same dispatch); the cold tail is
    /// shared via call instead of inlined. The runtime invariant
    /// guarding this — narrow-records throughput within 2% of master —
    /// is enforced by the bench regression CI gate, not by
    /// instruction-level identity.
    pub fn feed(
        p: *Parser,
        input: []const u8,
        is_eof: bool,
    ) (ZqError || error{OutOfMemory})!FeedResult {
        return p.feedGeneric(void, {}, input, is_eof);
    }

    /// Plan-aware feed entry point. Drives the same byte dispatch
    /// loop as `feed` and, on every top-level-value completion,
    /// evaluates the harvested pure-scalar predicate (when the plan
    /// carries one). When the predicate is false, the tape and
    /// string-buf are rolled back to the snapshot taken at the start
    /// of the value and the parser returns `FeedResult.dropped` —
    /// downstream stages (VM dispatch, output serialization) never
    /// see the dropped record.
    ///
    /// Trampoline over `feedGeneric(PlanCtx, .{...}, ...)`. The
    /// generic carries a single source of truth for the byte dispatch
    /// loop; both `feed` and `feedPlanned` resolve to specializations
    /// of the same body via comptime type-erasure (`PlanT == void`
    /// vs `PlanT == PlanCtx`).
    pub fn feedPlanned(
        p: *Parser,
        plan: *const ProjectionPlan,
        plan_state: *PlanState,
        input: []const u8,
        is_eof: bool,
    ) (ZqError || error{OutOfMemory})!FeedResult {
        const ctx: PlanCtx = .{ .plan = plan, .state = plan_state };
        return p.feedGeneric(PlanCtx, ctx, input, is_eof);
    }

    /// Comptime-specialized parse loop. `PlanT == void` selects the
    /// no-plan code path (used by `feed`); `PlanT == PlanCtx` selects
    /// the plan-aware path (used by `feedPlanned`).
    ///
    /// Comptime-erasure rationale: the parameter is a comptime *type*
    /// (`PlanT`), not a comptime *value*. `void` is zero-sized, so
    /// the `plan_ctx` parameter occupies neither stack nor register
    /// in the no-plan specialization. `if (PlanT == void)` is a
    /// comptime-known branch that the compiler eliminates before
    /// code-gen, so the two specializations have entirely separate
    /// IR and the no-plan body never sees plan-aware locals.
    ///
    /// Single source of truth for the byte dispatch loop: both
    /// specializations share the same source body verbatim, gated
    /// only at the boundaries (snapshot init, top-of-record
    /// finalization, EOF handling). The differential property test in
    /// `tests/projection_property_test.zig` asserts both
    /// specializations produce byte-identical output relative to jq,
    /// catching any divergence between the two paths.
    fn feedGeneric(
        p: *Parser,
        comptime PlanT: type,
        plan_ctx: PlanT,
        input: []const u8,
        is_eof: bool,
    ) (ZqError || error{OutOfMemory})!FeedResult {
        // Two physically separate bodies, gated by a comptime-known
        // type comparison. Zig folds `if (PlanT == void)` at semantic-
        // analysis time and only the chosen arm is lowered to IR; the
        // other arm's locals never enter LLVM's frame layout, which
        // is the difference between this shape and the prior nested-
        // `if (PlanT != void)` per-step shape (where dead-arm locals
        // still allocated stack slots).
        if (PlanT == void) {
            var i: usize = 0;
            // Strip a UTF-8 BOM (U+FEFF → 0xEF 0xBB 0xBF) that appears at
            // the very beginning of a JSON stream.  jq silently discards
            // BOM-prefixed input (jq test L48); we mirror that behaviour.
            // Only strip once — when the tape is still empty (first feed
            // call for this value).
            if (p.tape_buf.items.len == 0 and p.stack.items.len == 0 and
                p.state == .want_value and
                i + 3 <= input.len and
                input[i] == 0xEF and input[i + 1] == 0xBB and input[i + 2] == 0xBF)
            {
                i += 3;
            }
            while (i < input.len) {
                // ── SIMD fast paths ──────────────────────────────
                switch (p.state) {
                    .in_string => {
                        if (p.utf8_pending == 0 and p.unicode_surrogate == 0) {
                            const safe = simd.scanStringBody(input[i..]);
                            if (safe > 0) {
                                try p.string_buf.appendSlice(p.allocator, input[i..][0..safe]);
                                i += safe;
                                continue;
                            }
                        }
                    },
                    .want_value, .want_key, .want_colon, .after_value => {
                        const skip = simd.skipWhitespace(input[i..]);
                        i += skip;
                        if (i >= input.len) break;
                    },
                    else => {},
                }
                // ── Scalar fallback ──────────────────────────────
                try p.processByte(input[i]);
                i += 1;
                if (p.state == .top_done) {
                    return .{ .done = .{ .tape = p.makeTape(), .consumed = i } };
                }
            }
            if (is_eof) return p.processEof();
            return .need_more;
        } else {
            // Plan-aware initialization: snapshot tape + string-buf
            // cursors at the start of every top-level value so a
            // failing predicate can roll the buffers back. Done only
            // when the parser is fresh (no buffered tape entries / no
            // open container). When the call resumes mid-value (the
            // prior call returned `need_more`), the existing snapshot
            // is preserved.
            if (p.tape_buf.items.len == 0 and p.stack.items.len == 0 and
                p.state == .want_value)
            {
                plan_ctx.state.top_value_tape_start = p.tape_buf.items.len;
                plan_ctx.state.top_value_string_start = p.string_buf.items.len;
                plan_ctx.state.plan_cursor = plan_ctx.plan.root;
            }
            var i: usize = 0;
            if (p.tape_buf.items.len == 0 and p.stack.items.len == 0 and
                p.state == .want_value and
                i + 3 <= input.len and
                input[i] == 0xEF and input[i + 1] == 0xBB and input[i + 2] == 0xBF)
            {
                i += 3;
            }
            while (i < input.len) {
                switch (p.state) {
                    .in_string => {
                        if (p.utf8_pending == 0 and p.unicode_surrogate == 0) {
                            const safe = simd.scanStringBody(input[i..]);
                            if (safe > 0) {
                                try p.string_buf.appendSlice(p.allocator, input[i..][0..safe]);
                                i += safe;
                                continue;
                            }
                        }
                    },
                    .want_value, .want_key, .want_colon, .after_value => {
                        const skip = simd.skipWhitespace(input[i..]);
                        i += skip;
                        if (i >= input.len) break;
                    },
                    else => {},
                }
                try p.processByte(input[i]);
                i += 1;
                if (p.state == .top_done) {
                    return finalizePlannedRecord(p, plan_ctx.plan, plan_ctx.state, i);
                }
            }
            if (is_eof) {
                const eof_result = try p.processEof();
                switch (eof_result) {
                    .done => |d| return finalizePlannedRecord(p, plan_ctx.plan, plan_ctx.state, d.consumed),
                    .need_more => return .need_more,
                    .dropped => unreachable,
                }
            }
            return .need_more;
        }
    }

    /// Apply predicate evaluation + tape/string-buf rollback at the
    /// boundary of a finalized top-level value. Returns the
    /// appropriate `FeedResult` variant — `.done` if the predicate
    /// passes (or no predicate exists), `.dropped` otherwise.
    fn finalizePlannedRecord(
        p: *Parser,
        plan: *const ProjectionPlan,
        plan_state: *PlanState,
        consumed: usize,
    ) FeedResult {
        if (plan.predicate) |pred| {
            const tape_window_start = plan_state.top_value_tape_start;
            const passed = evalPredicate(
                p.tape_buf.items[tape_window_start..],
                p.string_buf.items,
                plan,
                pred,
            );
            if (!passed) {
                p.tape_buf.shrinkRetainingCapacity(plan_state.top_value_tape_start);
                p.string_buf.shrinkRetainingCapacity(plan_state.top_value_string_start);
                return .{ .dropped = .{ .consumed = consumed } };
            }
        }
        return .{ .done = .{ .tape = p.makeTape(), .consumed = consumed } };
    }

    // ── Byte dispatch ─────────────────────────────────────────────────────

    fn processByte(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        switch (p.state) {
            .want_value => try p.onWantValue(byte),
            .want_key => try p.onWantKey(byte),
            .want_colon => try p.onWantColon(byte),
            .after_value => try p.onAfterValue(byte),
            .in_string => try p.onInString(byte),
            .in_string_escape => try p.onInStringEscape(byte),
            .in_string_unicode => try p.onInStringUnicode(byte),
            .in_number => try p.onInNumber(byte),
            .in_keyword => try p.onInKeyword(byte),
            .top_done => try p.onTopDone(byte),
        }
    }

    // ── State handlers ────────────────────────────────────────────────────

    fn onWantValue(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        switch (byte) {
            ' ', '\t', '\n', '\r' => {},
            '{' => {
                if (p.stack.items.len >= DEPTH_LIMIT) return error.DepthLimitExceeded;
                const tape_idx: u32 = @intCast(p.tape_buf.items.len);
                try p.tape_buf.append(p.allocator, .{
                    .tag = .object_start,
                    .payload = .{ .skip = 0 },
                });
                try p.stack.append(p.allocator, StackEntry{
                    .kind = .object,
                    .tape_idx = tape_idx,
                    .after_comma = false,
                });
                p.state = .want_key;
            },
            '[' => {
                if (p.stack.items.len >= DEPTH_LIMIT) return error.DepthLimitExceeded;
                const tape_idx: u32 = @intCast(p.tape_buf.items.len);
                try p.tape_buf.append(p.allocator, .{
                    .tag = .array_start,
                    .payload = .{ .skip = 0 },
                });
                try p.stack.append(p.allocator, StackEntry{
                    .kind = .array,
                    .tape_idx = tape_idx,
                    .after_comma = false,
                });
                // Stay in want_value for the first array element.
            },
            ']' => {
                // Only valid if this is the initial want_value after '[', not after ','.
                if (p.stack.items.len > 0) {
                    const top = p.stack.items[p.stack.items.len - 1];
                    if (top.kind == .array and !top.after_comma) {
                        try p.closeContainer();
                        return;
                    }
                }
                return error.UnexpectedToken;
            },
            '"' => {
                p.string_start = @intCast(p.string_buf.items.len);
                p.string_is_key = false;
                p.utf8_pending = 0;
                p.unicode_surrogate = 0;
                p.state = .in_string;
            },
            '-' => {
                p.num_buf.clearRetainingCapacity();
                try p.num_buf.append(p.allocator, '-');
                p.num_is_float = false;
                p.num_sub = .neg;
                p.state = .in_number;
            },
            '0' => {
                p.num_buf.clearRetainingCapacity();
                try p.num_buf.append(p.allocator, '0');
                p.num_is_float = false;
                p.num_sub = .leading_zero;
                p.state = .in_number;
            },
            '1'...'9' => {
                p.num_buf.clearRetainingCapacity();
                try p.num_buf.append(p.allocator, byte);
                p.num_is_float = false;
                p.num_sub = .int;
                p.state = .in_number;
            },
            't' => {
                p.kw_kind = .kw_true;
                p.kw_pos = 1;
                p.state = .in_keyword;
            },
            'f' => {
                p.kw_kind = .kw_false;
                p.kw_pos = 1;
                p.state = .in_keyword;
            },
            'n' => {
                p.kw_kind = .kw_null;
                p.kw_pos = 1;
                p.state = .in_keyword;
            },
            'I' => {
                p.kw_kind = .kw_infinity;
                p.kw_pos = 1;
                p.state = .in_keyword;
            },
            'N' => {
                p.kw_kind = .kw_nan;
                p.kw_pos = 1;
                p.state = .in_keyword;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn onWantKey(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        switch (byte) {
            ' ', '\t', '\n', '\r' => {},
            '"' => {
                p.string_start = @intCast(p.string_buf.items.len);
                p.string_is_key = true;
                p.utf8_pending = 0;
                p.unicode_surrogate = 0;
                p.state = .in_string;
            },
            '}' => {
                // Only valid if not after a comma (trailing commas are illegal in JSON).
                if (p.stack.items.len > 0) {
                    const top = p.stack.items[p.stack.items.len - 1];
                    if (top.kind == .object and !top.after_comma) {
                        try p.closeContainer();
                        return;
                    }
                }
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn onWantColon(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        switch (byte) {
            ' ', '\t', '\n', '\r' => {},
            ':' => p.state = .want_value,
            else => return error.UnexpectedToken,
        }
    }

    fn onAfterValue(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        switch (byte) {
            ' ', '\t', '\n', '\r' => {},
            ',' => {
                // Stack is always non-empty in after_value (top_done covers the empty case).
                const top = &p.stack.items[p.stack.items.len - 1];
                top.after_comma = true;
                p.state = if (top.kind == .object) .want_key else .want_value;
            },
            '}' => {
                if (p.stack.items[p.stack.items.len - 1].kind != .object)
                    return error.UnexpectedToken;
                try p.closeContainer();
            },
            ']' => {
                if (p.stack.items[p.stack.items.len - 1].kind != .array)
                    return error.UnexpectedToken;
                try p.closeContainer();
            },
            else => return error.UnexpectedToken,
        }
    }

    fn onInString(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        // Surrogate-pair pending: only '\' is acceptable as next byte.
        if (p.unicode_surrogate != 0) {
            if (byte != '\\') return error.InvalidUtf8;
            p.state = .in_string_escape;
            return;
        }

        // Continuation byte expected for a multi-byte UTF-8 sequence.
        if (p.utf8_pending > 0) {
            if (byte & 0xC0 != 0x80) return error.InvalidUtf8;
            // Validate overlong/range on the first continuation byte.
            switch (p.utf8_pending) {
                2 => { // 3-byte seq: validating second byte
                    if (p.utf8_first == 0xE0 and byte < 0xA0) return error.InvalidUtf8;
                    if (p.utf8_first == 0xED and byte > 0x9F) return error.InvalidUtf8;
                },
                3 => { // 4-byte seq: validating second byte
                    if (p.utf8_first == 0xF0 and byte < 0x90) return error.InvalidUtf8;
                    if (p.utf8_first == 0xF4 and byte > 0x8F) return error.InvalidUtf8;
                },
                else => {},
            }
            try p.string_buf.append(p.allocator, byte);
            p.utf8_pending -= 1;
            return;
        }

        switch (byte) {
            0x00...0x1F => return error.InvalidUtf8, // control chars must be escaped
            '"' => try p.finalizeString(),
            '\\' => p.state = .in_string_escape,
            0x80...0xBF => return error.InvalidUtf8, // stray continuation byte
            0xC0, 0xC1 => return error.InvalidUtf8, // overlong 2-byte prefix
            0xC2...0xDF => {
                p.utf8_first = byte;
                p.utf8_pending = 1;
                try p.string_buf.append(p.allocator, byte);
            },
            0xE0...0xEF => {
                p.utf8_first = byte;
                p.utf8_pending = 2;
                try p.string_buf.append(p.allocator, byte);
            },
            0xF0...0xF4 => {
                p.utf8_first = byte;
                p.utf8_pending = 3;
                try p.string_buf.append(p.allocator, byte);
            },
            0xF5...0xFF => return error.InvalidUtf8,
            else => try p.string_buf.append(p.allocator, byte), // ASCII 0x20-0x7E,0x7F
        }
    }

    fn onInStringEscape(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        // While waiting for a low surrogate, only \uXXXX is acceptable.
        if (p.unicode_surrogate != 0 and byte != 'u') return error.InvalidUtf8;

        switch (byte) {
            '"' => {
                try p.string_buf.append(p.allocator, '"');
                p.state = .in_string;
            },
            '\\' => {
                try p.string_buf.append(p.allocator, '\\');
                p.state = .in_string;
            },
            '/' => {
                try p.string_buf.append(p.allocator, '/');
                p.state = .in_string;
            },
            'b' => {
                try p.string_buf.append(p.allocator, 0x08);
                p.state = .in_string;
            },
            'f' => {
                try p.string_buf.append(p.allocator, 0x0C);
                p.state = .in_string;
            },
            'n' => {
                try p.string_buf.append(p.allocator, '\n');
                p.state = .in_string;
            },
            'r' => {
                try p.string_buf.append(p.allocator, '\r');
                p.state = .in_string;
            },
            't' => {
                try p.string_buf.append(p.allocator, '\t');
                p.state = .in_string;
            },
            'u' => {
                p.unicode_count = 0;
                p.unicode_accum = 0;
                p.state = .in_string_unicode;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn onInStringUnicode(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        const nibble: u21 = switch (byte) {
            '0'...'9' => @as(u21, byte - '0'),
            'a'...'f' => @as(u21, byte - 'a' + 10),
            'A'...'F' => @as(u21, byte - 'A' + 10),
            else => return error.InvalidUtf8,
        };
        p.unicode_accum = (p.unicode_accum << 4) | nibble;
        p.unicode_count += 1;
        if (p.unicode_count < 4) return;

        // All four hex digits received.
        const cp16 = p.unicode_accum;
        p.unicode_accum = 0;
        p.unicode_count = 0;

        if (cp16 >= 0xD800 and cp16 <= 0xDBFF) {
            // High surrogate: store and wait for \uLow.
            p.unicode_surrogate = @intCast(cp16);
            p.state = .in_string;
        } else if (cp16 >= 0xDC00 and cp16 <= 0xDFFF) {
            // Low surrogate: must follow a high surrogate.
            if (p.unicode_surrogate == 0) return error.InvalidUtf8;
            const hi: u21 = @as(u21, p.unicode_surrogate) - 0xD800;
            const lo: u21 = cp16 - 0xDC00;
            const codepoint: u21 = 0x10000 + (hi << 10) | lo;
            p.unicode_surrogate = 0;
            try p.encodeUtf8(codepoint);
            p.state = .in_string;
        } else {
            if (p.unicode_surrogate != 0) return error.InvalidUtf8; // unpaired high surrogate
            try p.encodeUtf8(cp16);
            p.state = .in_string;
        }
    }

    fn onInNumber(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        switch (p.num_sub) {
            .neg => switch (byte) {
                '0' => {
                    try p.numAppend(byte);
                    p.num_sub = .leading_zero;
                },
                '1'...'9' => {
                    try p.numAppend(byte);
                    p.num_sub = .int;
                },
                'I' => {
                    // -Infinity: abandon number state, switch to keyword.
                    p.num_buf.clearRetainingCapacity();
                    p.kw_kind = .kw_neg_infinity;
                    p.kw_pos = 1;
                    p.state = .in_keyword;
                },
                'N' => {
                    // -NaN: abandon number state, switch to keyword.
                    p.num_buf.clearRetainingCapacity();
                    p.kw_kind = .kw_neg_nan;
                    p.kw_pos = 1;
                    p.state = .in_keyword;
                },
                'n' => {
                    // -nan (lowercase): abandon number state, switch to keyword.
                    p.num_buf.clearRetainingCapacity();
                    p.kw_kind = .kw_neg_nan_lower;
                    p.kw_pos = 1;
                    p.state = .in_keyword;
                },
                else => return error.InvalidNumber,
            },
            .leading_zero => switch (byte) {
                '.' => {
                    try p.numAppend(byte);
                    p.num_is_float = true;
                    p.num_sub = .frac_start;
                },
                'e', 'E' => {
                    try p.numAppend(byte);
                    p.num_is_float = true;
                    p.num_sub = .exp_sign;
                },
                '0'...'9' => return error.InvalidNumber, // leading zeros forbidden
                else => try p.terminateNumber(byte),
            },
            .int => switch (byte) {
                '0'...'9' => try p.numAppend(byte),
                '.' => {
                    try p.numAppend(byte);
                    p.num_is_float = true;
                    p.num_sub = .frac_start;
                },
                'e', 'E' => {
                    try p.numAppend(byte);
                    p.num_is_float = true;
                    p.num_sub = .exp_sign;
                },
                else => try p.terminateNumber(byte),
            },
            .frac_start => switch (byte) {
                '0'...'9' => {
                    try p.numAppend(byte);
                    p.num_sub = .frac;
                },
                else => return error.InvalidNumber,
            },
            .frac => switch (byte) {
                '0'...'9' => try p.numAppend(byte),
                'e', 'E' => {
                    try p.numAppend(byte);
                    p.num_sub = .exp_sign;
                },
                '.' => return error.InvalidNumber, // second decimal point: 1.2.3
                else => try p.terminateNumber(byte),
            },
            .exp_sign => switch (byte) {
                '+', '-' => {
                    try p.numAppend(byte);
                    p.num_sub = .exp_start;
                },
                '0'...'9' => {
                    try p.numAppend(byte);
                    p.num_sub = .exp;
                },
                else => return error.InvalidNumber,
            },
            .exp_start => switch (byte) {
                '0'...'9' => {
                    try p.numAppend(byte);
                    p.num_sub = .exp;
                },
                else => return error.InvalidNumber,
            },
            .exp => switch (byte) {
                '0'...'9' => try p.numAppend(byte),
                else => try p.terminateNumber(byte),
            },
        }
    }

    fn onInKeyword(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        // Special disambiguation: 'n' in onWantValue starts kw_null.
        // If the second byte is 'a' instead of 'u', switch to kw_nan_lower.
        // jq accepts lowercase "nan" as a NaN literal.
        if (p.kw_kind == .kw_null and p.kw_pos == 1) {
            if (byte == 'a') {
                // 'n' + 'a' → NaN branch (lowercase "nan").
                p.kw_kind = .kw_nan_lower;
                p.kw_pos = 2; // consumed 'n' (pos 0) and 'a' (pos 1), need 'n' (pos 2)
                return;
            }
        }
        const kw = keywordBytes(p.kw_kind);
        if (p.kw_pos >= kw.len or byte != kw[p.kw_pos]) return error.UnexpectedToken;
        p.kw_pos += 1;

        if (p.kw_pos == kw.len) {
            switch (p.kw_kind) {
                .kw_true => try p.tape_buf.append(p.allocator, .{ .tag = .true_val, .payload = PAYLOAD_NONE }),
                .kw_false => try p.tape_buf.append(p.allocator, .{ .tag = .false_val, .payload = PAYLOAD_NONE }),
                .kw_null => try p.tape_buf.append(p.allocator, .{ .tag = .null_val, .payload = PAYLOAD_NONE }),
                .kw_infinity => try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = std.math.inf(f64) } }),
                .kw_nan => try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = std.math.nan(f64) } }),
                .kw_neg_infinity => try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = -std.math.inf(f64) } }),
                .kw_neg_nan => try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = -std.math.nan(f64) } }),
                .kw_nan_lower => try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = std.math.nan(f64) } }),
                .kw_neg_nan_lower => try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = -std.math.nan(f64) } }),
            }
            p.transitionAfterValue();
        }
    }

    fn onTopDone(p: *Parser, byte: u8) ZqError!void {
        _ = p;
        return switch (byte) {
            ' ', '\t', '\n', '\r' => {},
            else => error.UnexpectedToken,
        };
    }

    // ── EOF handling ──────────────────────────────────────────────────────

    fn processEof(p: *Parser) (ZqError || error{OutOfMemory})!FeedResult {
        switch (p.state) {
            .in_string, .in_string_escape, .in_string_unicode => return error.UnterminatedString,

            .want_colon => return error.UnexpectedEof,

            .want_value => {
                // Top-level with no value started: trailing whitespace after
                // the last record.  Not an error — signal no value produced.
                if (p.stack.items.len == 0) return .need_more;
                const top = p.stack.items[p.stack.items.len - 1];
                // After ':' in an object — value is mandatory.
                if (top.kind == .object) return error.UnexpectedEof;
                // After ',' in an array — value is mandatory.
                if (top.after_comma) return error.UnexpectedEof;
                // Otherwise: empty array (just saw '['), safe to auto-close.
                try p.autoClose();
            },

            .want_key => {
                const top = p.stack.items[p.stack.items.len - 1];
                if (top.after_comma) return error.UnexpectedEof;
                try p.autoClose();
            },

            .after_value => try p.autoClose(),

            .in_number => {
                switch (p.num_sub) {
                    .neg, .frac_start, .exp_sign, .exp_start => return error.InvalidNumber,
                    else => {},
                }
                try p.finalizeNumber();
                if (p.state == .after_value) try p.autoClose();
                // else state is top_done: already done.
            },

            .in_keyword => return error.UnexpectedEof,

            .top_done => {},
        }
        return FeedResult{ .done = .{ .tape = p.makeTape(), .consumed = 0 } };
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    fn numAppend(p: *Parser, byte: u8) error{OutOfMemory}!void {
        try p.num_buf.append(p.allocator, byte);
    }

    /// Finalize number on seeing a non-number byte; re-dispatch the byte.
    fn terminateNumber(p: *Parser, byte: u8) (ZqError || error{OutOfMemory})!void {
        switch (p.num_sub) {
            .neg, .frac_start, .exp_sign, .exp_start => return error.InvalidNumber,
            else => {},
        }
        try p.finalizeNumber();
        try p.processByte(byte);
    }

    fn finalizeNumber(p: *Parser) (ZqError || error{OutOfMemory})!void {
        const num_str = p.num_buf.items;
        if (p.num_is_float) {
            const val = std.fmt.parseFloat(f64, num_str) catch return error.InvalidNumber;
            try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = val } });
        } else {
            // jq uses float64 for all numbers. Integers that cannot be
            // exactly represented in float64 (|n| > 2^53) — including
            // those that exceed i64 entirely (e.g.
            // `123456789012345678901234567890`) — are stored as float
            // to match jq precision semantics. Integer literals that
            // overflow i64 round-trip through `parseFloat`, so the
            // parser stays parity-safe with jq's "all numbers are
            // doubles" model rather than rejecting the input.
            if (std.fmt.parseInt(i64, num_str, 10)) |val| {
                const max_exact: i64 = 1 << 53; // 9007199254740992
                if (val > max_exact or val < -max_exact) {
                    const fval: f64 = @floatFromInt(val);
                    try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = fval } });
                } else {
                    try p.tape_buf.append(p.allocator, .{ .tag = .int, .payload = .{ .int = val } });
                }
            } else |_| {
                const fval = std.fmt.parseFloat(f64, num_str) catch return error.InvalidNumber;
                try p.tape_buf.append(p.allocator, .{ .tag = .float, .payload = .{ .float = fval } });
            }
        }
        p.transitionAfterValue();
    }

    fn finalizeString(p: *Parser) (ZqError || error{OutOfMemory})!void {
        if (p.utf8_pending > 0 or p.unicode_surrogate != 0) return error.InvalidUtf8;
        const str_len: u32 = @intCast(p.string_buf.items.len - p.string_start);
        const ref = types.Tape.StringRef{ .offset = p.string_start, .len = str_len };
        const tag: types.Tape.Tag = if (p.string_is_key) .key else .string;
        try p.tape_buf.append(p.allocator, .{ .tag = tag, .payload = .{ .string = ref } });
        if (p.string_is_key) {
            p.state = .want_colon;
        } else {
            p.transitionAfterValue();
        }
    }

    fn encodeUtf8(p: *Parser, codepoint: u21) (ZqError || error{OutOfMemory})!void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidUtf8;
        try p.string_buf.appendSlice(p.allocator, buf[0..len]);
    }

    fn closeContainer(p: *Parser) error{OutOfMemory}!void {
        const entry = p.stack.pop().?;
        const end_idx: u32 = @intCast(p.tape_buf.items.len);
        // skip = index past the end entry (one after it).
        p.tape_buf.items[entry.tape_idx].payload.skip = end_idx + 1;
        const end_tag: types.Tape.Tag = switch (entry.kind) {
            .object => .object_end,
            .array => .array_end,
        };
        try p.tape_buf.append(p.allocator, .{ .tag = end_tag, .payload = PAYLOAD_NONE });
        p.transitionAfterValue();
    }

    /// Close all remaining open containers (Auto-Close on EOF).
    fn autoClose(p: *Parser) error{OutOfMemory}!void {
        while (p.stack.items.len > 0) {
            try p.closeContainer();
        }
    }

    fn transitionAfterValue(p: *Parser) void {
        p.state = if (p.stack.items.len == 0) .top_done else .after_value;
    }

    fn makeTape(p: *const Parser) Tape {
        return Tape{
            .entries = p.tape_buf.items,
            .string_buf = p.string_buf.items,
        };
    }

    fn keywordBytes(kind: KeywordKind) []const u8 {
        return switch (kind) {
            .kw_true => "true",
            .kw_false => "false",
            .kw_null => "null",
            // First byte already consumed by onWantValue or onInNumber .neg case;
            // kw_pos starts at 1, so match from index 1 of the full keyword.
            .kw_infinity, .kw_neg_infinity => "Infinity",
            .kw_nan, .kw_neg_nan => "NaN",
            // kw_nan_lower: 'n' consumed by onWantValue, 'a' consumed by
            // onInKeyword disambiguation; kw_pos=2 so match from index 2 of "nan".
            .kw_nan_lower => "nan",
            // kw_neg_nan_lower: '-' consumed by onWantValue→neg state, 'n' consumed
            // by onInNumber neg branch; kw_pos=1 so match from index 1 of "nan".
            .kw_neg_nan_lower => "nan",
        };
    }
};

// ── Plan-aware helpers ─────────────────────────────────────────────────────────

/// Walk the per-record tape window to find the terminal field
/// referenced by `plan.predicate.?.field_path_node`, then compare the
/// field's value against `pred.literal` using `pred.op`. Returns
/// `true` when the predicate passes (record stays) and `false` when
/// it fails (record dropped).
///
/// The walk uses the plan's static path: starting from `plan.root`,
/// follow the `object_key` chain to the terminal node. Each step
/// performs a sequential scan over the surrounding object's
/// key/value pairs and recurses into the matched child. Out-of-plan
/// fields are skipped via tape `payload.skip` indices (set by
/// `closeContainer` when each container ends).
///
/// On structural mismatch (wrong type at any path step, missing
/// field, etc.) the predicate evaluates to `false` for `eq`/`lt`/`le`/
/// `gt`/`ge` (jq's coercion rules: comparing a missing field returns
/// `null < everything-else`, but the harvester only emits comparisons
/// that map cleanly to the available tape entries — we mirror that by
/// dropping on mismatch). For `ne`, the same rule yields `true`.
///
/// `has_key` is evaluated as a tape lookup: at the terminal, the
/// current tape index must point to an `object_start`; the predicate
/// passes iff the literal key exists in that object. No latch is
/// required — the tape already records every key the parser emitted.
fn evalPredicate(
    tape_window: []const types.Tape.Entry,
    string_buf: []const u8,
    plan: *const projection_plan_mod.ProjectionPlan,
    pred: projection_plan_mod.Predicate,
) bool {
    if (tape_window.len == 0) return false;
    const root_entry = tape_window[0];

    // Non-object top-level value with an object-key predicate path:
    // the path can't resolve. For top-level `select(has("k"))` plans
    // (whose plan root is itself a `terminal`) the value can be any
    // type — the has_key check evaluates against the value directly.
    const root_node = plan.nodes[plan.root];
    if (root_node.kind != .terminal and root_entry.tag != .object_start) {
        return predicateFalseValue(pred);
    }

    // Walk from plan.root following object_key chains until terminal.
    var current_node_idx: u32 = plan.root;
    var current_tape_idx: u32 = 0; // index into tape_window
    while (true) {
        const node = plan.nodes[current_node_idx];
        switch (node.kind) {
            .object_key => {
                if (current_tape_idx >= tape_window.len) return predicateFalseValue(pred);
                const obj_entry = tape_window[current_tape_idx];
                if (obj_entry.tag != .object_start) return predicateFalseValue(pred);
                const want_key = plan.keyBytes(node);
                const found_value_idx = findObjectKey(tape_window, string_buf, current_tape_idx, want_key) orelse {
                    return predicateFalseValue(pred);
                };
                const children = plan.childIndices(node);
                if (children.len == 0) return predicateFalseValue(pred);
                current_node_idx = children[0];
                current_tape_idx = found_value_idx;
            },
            .terminal => {
                if (current_tape_idx >= tape_window.len) return predicateFalseValue(pred);
                if (pred.op == .has_key) {
                    // The terminal value must be an object; the literal
                    // (a string) is the key whose presence is tested.
                    const value_entry = tape_window[current_tape_idx];
                    if (value_entry.tag != .object_start) return predicateFalseValue(pred);
                    const key_bytes = switch (pred.literal) {
                        .string => |s| plan.string_buf[s.offset .. s.offset + s.len],
                        else => return predicateFalseValue(pred),
                    };
                    return findObjectKey(tape_window, string_buf, current_tape_idx, key_bytes) != null;
                }
                return compareTapeValue(tape_window[current_tape_idx], string_buf, plan, pred);
            },
            // Array index / iterate not supported by the predicate
            // harvester today — drop conservatively.
            else => return predicateFalseValue(pred),
        }
    }
}

/// Locate the value of a given key inside an object that starts at
/// `obj_start` (where `tape_window[obj_start].tag == .object_start`).
/// Returns the tape index of the matched value entry, or `null` when
/// the key is absent. Out-of-match entries are skipped via the
/// container's `payload.skip` indices stored on `*_start` entries.
fn findObjectKey(
    tape_window: []const types.Tape.Entry,
    string_buf: []const u8,
    obj_start: u32,
    want_key: []const u8,
) ?u32 {
    var i: u32 = obj_start + 1;
    const end = tape_window[obj_start].payload.skip;
    while (i < end and i < tape_window.len) {
        const e = tape_window[i];
        if (e.tag == .object_end) return null;
        if (e.tag != .key) return null; // malformed
        const key_ref = e.payload.string;
        const key_bytes = string_buf[key_ref.offset .. key_ref.offset + key_ref.len];
        const value_idx = i + 1;
        if (std.mem.eql(u8, key_bytes, want_key)) {
            return value_idx;
        }
        // Advance past the value: containers carry a `skip`; scalars
        // are exactly one entry.
        const v = tape_window[value_idx];
        switch (v.tag) {
            .object_start, .array_start => {
                // skip points one past the matching *_end (relative to
                // the full tape, but our window starts at obj_start of
                // the top-level object — still valid because skip is
                // tape-absolute: tape_window aliases parser.tape_buf
                // starting at the top-level object's first entry).
                i = v.payload.skip;
            },
            else => i = value_idx + 1,
        }
    }
    return null;
}

/// Compare a single tape entry against the predicate literal under
/// the harvested operator. jq numeric semantics (everything is f64)
/// apply for numeric ops; string equality is exact byte-equality on
/// the decoded UTF-8 form; bool / null / float compare directly.
fn compareTapeValue(
    entry: types.Tape.Entry,
    string_buf: []const u8,
    plan: *const projection_plan_mod.ProjectionPlan,
    pred: projection_plan_mod.Predicate,
) bool {
    // `has_key` is handled in `evalPredicate` (tape lookup at the
    // terminal object), not here. Reaching `compareTapeValue` with
    // `op == .has_key` would mean the harvester emitted a comparison
    // predicate against a `has_key` op — the harvester never does that.
    std.debug.assert(pred.op != .has_key);
    const op = pred.op;
    return switch (pred.literal) {
        .null_ => switch (op) {
            .eq => entry.tag == .null_val,
            .ne => entry.tag != .null_val,
            else => false,
        },
        .bool_ => |b| switch (entry.tag) {
            .true_val => switch (op) {
                .eq => b == true,
                .ne => b == false,
                else => false,
            },
            .false_val => switch (op) {
                .eq => b == false,
                .ne => b == true,
                else => false,
            },
            else => predicateFalseValue(pred),
        },
        .int => |n| compareNumeric(entry, @as(f64, @floatFromInt(n)), op),
        .float => |f| compareNumeric(entry, f, op),
        .string => |s| switch (entry.tag) {
            .string => switch (op) {
                .eq, .ne => blk: {
                    const want = plan.string_buf[s.offset .. s.offset + s.len];
                    const got_ref = entry.payload.string;
                    const got = string_buf[got_ref.offset .. got_ref.offset + got_ref.len];
                    const eql = std.mem.eql(u8, want, got);
                    break :blk if (op == .eq) eql else !eql;
                },
                else => false, // ordering on strings not harvested
            },
            else => predicateFalseValue(pred),
        },
    };
}

fn compareNumeric(entry: types.Tape.Entry, want: f64, op: projection_plan_mod.PredicateOp) bool {
    std.debug.assert(op != .has_key);
    const got: f64 = switch (entry.tag) {
        .int => @as(f64, @floatFromInt(entry.payload.int)),
        .float => entry.payload.float,
        else => return op == .ne, // type mismatch: false for ==, true for !=
    };
    return switch (op) {
        .eq => got == want,
        .ne => got != want,
        .lt => got < want,
        .le => got <= want,
        .gt => got > want,
        .ge => got >= want,
        .has_key => unreachable,
    };
}

/// Outcome when the predicate's path can't be resolved against the
/// current top-level value (missing field, type mismatch at a path
/// step, non-object root for an object-key plan, etc.).
///
/// jq treats missing-key access as `null`, which propagates through
/// comparison operators as: `null == lit` → false (for any non-null
/// `lit`), `null != lit` → true (likewise), `null < lit` / `null > lit`
/// follow jq's null-orders-first ordering, which depends on the
/// literal — those edge cases aren't currently emitted by the
/// harvester (it only accepts `<path> CMP <load_const>` with a
/// matching scalar type), so the conservative rule below is safe:
/// drop the record on any unresolvable path *unless* the operator is
/// `ne`, where missing ≠ literal is logically true.
///
/// This is the final word on the result — the pool worker sees
/// `.dropped` and emits no record, so the VM never runs against a
/// dropped value. Earlier comments referenced a "VM re-run" fallback
/// that does not exist.
fn predicateFalseValue(pred: projection_plan_mod.Predicate) bool {
    return pred.op == .ne;
}

// Note on projection skipping: a scalar JSON-value skipper (Component E
// per the original C1 plan) was removed pre-merge. The current commit
// implements predicate-only pushdown — records that fail a harvested
// pure-scalar `select(...)` predicate are dropped at the parser
// boundary via `finalizePlannedRecord`. Projection skipping (dropping
// out-of-plan subtrees byte-wise without tape emission) is deferred to
// a follow-up commit; introducing it requires intrusive changes to the
// per-byte dispatch state-machine and is being staged separately to
// keep this commit's blast radius bounded. The `ProjectionPlan` shape
// is already future-proofed for both (its node tree is the
// single-source representation either pass would consume).
