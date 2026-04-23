//! Zig-side wrapper over the `zq-regex-shim` static Rust library.
//!
//! Phase B: full surface — compile/deinit, metadata (captureCount, groupName,
//! groupIndexByName), per-worker clone (RegexClone), and search primitives
//! (isMatch, find, findCaptures, iterNext). Panic-safety contract: any FFI
//! call that the shim aborts with `-1`/`NULL` surfaces as `Error.RegexInternalError`
//! and the last message is retrievable via `lastError(&buf)`.
//!
//! When `build_options.regex_enabled == false`, every public type/constructor
//! collapses into a compile-time stub that returns `Error.RegexNotCompiled` —
//! callers stay the same; the shim just isn't linked.
//!
//! Thread model (mirrors the shim):
//!   - `Regex` is created once per compiled filter / cache entry. Sync, shareable.
//!   - `RegexClone` is per-worker, owns a Cache, not Sync. Cheap to construct
//!     (Arc bump + fresh Cache) but still worth amortizing over a chunk.

const std = @import("std");
const build_options = @import("build_options");

pub const enabled: bool = build_options.regex_enabled;

/// Re-export the cache submodule so downstream code (compiler, VM) can use
/// `regex.cache.RegexPool` / `regex.cache.LruCache` without a second import.
pub const cache = @import("cache.zig");
pub const RegexPool = cache.RegexPool;

/// Byte→char offset helper used by `match` / `capture` / `scan` to build
/// jq-compatible `offset` values (character count, not bytes).
pub const offset = @import("offset.zig");

pub const Error = error{
    RegexNotCompiled,
    RegexCompileFailed,
    RegexInternalError,
    OutOfMemory,
};

/// Scratch buffer size used when surfacing the shim's last-error message.
/// Stack-allocated at call sites — keep it modest.
pub const error_buffer_size: usize = 512;

/// Layout-compatible with the Rust `ZqMatchSlot`. `start == SLOT_UNMATCHED`
/// indicates an optional group that did not participate in the match.
pub const MatchSlot = extern struct {
    start: usize,
    end: usize,
};

pub const SLOT_UNMATCHED: usize = std.math.maxInt(usize);

/// Read the last error message from the shim into a caller-provided buffer.
/// Returns the slice of `buf` that was written (no null terminator). When
/// regex is disabled the returned slice is always empty.
pub fn lastError(buf: []u8) []const u8 {
    if (!enabled) return buf[0..0];
    if (buf.len == 0) return buf[0..0];
    const n = c.zq_regex_last_error(buf.ptr, buf.len);
    return buf[0..n];
}

pub const Regex = if (enabled) EnabledRegex else DisabledRegex;
pub const RegexClone = if (enabled) EnabledRegexClone else DisabledRegexClone;

/// Prefilter literal set for the Sparser-style raw-byte prescreen in the
/// parallel chunk worker. Owned by the parent `Regex` (and therefore by the
/// filter-compile-time `RegexPool`); never freed independently.
///
/// Semantics of `isExhaustive()`:
///   - `true`  — every literal in the set MUST appear in the haystack for the
///                regex to have any chance of matching (AND semantics).
///   - `false` — at least one literal MUST appear (OR semantics).
///
/// In both cases, `false` on the check guarantees the regex cannot match —
/// which is exactly the correctness contract Sparser needs: zero false
/// negatives, bounded false positives.
pub const Literals = if (enabled) EnabledLiterals else DisabledLiterals;

const DisabledLiterals = struct {
    _placeholder: u8 = 0,
    pub fn count(self: Literals) usize {
        _ = self;
        return 0;
    }
    pub fn at(self: Literals, idx: usize) []const u8 {
        _ = self;
        _ = idx;
        return &[_]u8{};
    }
    pub fn isExhaustive(self: Literals) bool {
        _ = self;
        return false;
    }
};

const EnabledLiterals = struct {
    handle: *const c.ZqLiterals,

    pub fn count(self: Literals) usize {
        return c.zq_literals_count(self.handle);
    }

    pub fn at(self: Literals, idx: usize) []const u8 {
        var len: usize = 0;
        const p = c.zq_literals_at(self.handle, idx, &len) orelse return &[_]u8{};
        return p[0..len];
    }

    pub fn isExhaustive(self: Literals) bool {
        const rc = c.zq_literals_is_exhaustive(self.handle);
        return rc == 1;
    }
};

// ─── Disabled stubs (regex feature off at build time) ─────────────────────────

const DisabledRegex = struct {
    /// One-byte placeholder: `ArrayList(Regex)` and similar containers in the
    /// cache layer require `@sizeOf(Regex) > 0`. Without this the stdlib's
    /// `growCapacity` hits a division-by-zero in its comptime initial-capacity
    /// calculation. Harmless otherwise — the field is never inspected, every
    /// method on DisabledRegex is a stub.
    _placeholder: u8 = 0,

    pub fn compile(pattern: []const u8) Error!Regex {
        _ = pattern;
        return Error.RegexNotCompiled;
    }

    pub fn deinit(self: *Regex) void {
        _ = self;
    }

    pub fn captureCount(self: Regex) usize {
        _ = self;
        return 0;
    }

    pub fn groupName(self: Regex, idx: usize) ?[]const u8 {
        _ = self;
        _ = idx;
        return null;
    }

    pub fn groupIndexByName(self: Regex, name: []const u8) ?usize {
        _ = self;
        _ = name;
        return null;
    }

    pub fn clone(self: Regex) Error!RegexClone {
        _ = self;
        return Error.RegexNotCompiled;
    }

    pub fn requiredLiterals(self: Regex) ?Literals {
        _ = self;
        return null;
    }
};

const DisabledRegexClone = struct {
    /// Same reason as DisabledRegex._placeholder: Zig 0.15's stdlib
    /// containers (HashMap, ArrayList) require non-zero sizeOf for element
    /// arithmetic. The LRU cache's Node embeds a RegexClone value; it must
    /// have runtime bits even in disabled builds.
    _placeholder: u8 = 0,

    pub fn deinit(self: *RegexClone) void {
        _ = self;
    }

    pub fn isMatch(self: RegexClone, hay: []const u8) Error!bool {
        _ = self;
        _ = hay;
        return Error.RegexNotCompiled;
    }

    pub fn find(self: RegexClone, hay: []const u8, start: usize) Error!?struct { start: usize, end: usize } {
        _ = self;
        _ = hay;
        _ = start;
        return Error.RegexNotCompiled;
    }

    pub fn findCaptures(self: RegexClone, hay: []const u8, start: usize, slots: []MatchSlot) Error!bool {
        _ = self;
        _ = hay;
        _ = start;
        _ = slots;
        return Error.RegexNotCompiled;
    }

    pub fn iterNext(self: RegexClone, hay: []const u8, cursor: *usize, slots: []MatchSlot) Error!bool {
        _ = self;
        _ = hay;
        _ = cursor;
        _ = slots;
        return Error.RegexNotCompiled;
    }
};

// ─── Enabled bindings ─────────────────────────────────────────────────────────

const EnabledRegex = struct {
    handle: *c.ZqRegex,

    pub fn compile(pattern: []const u8) Error!Regex {
        const ptr_in: ?[*]const u8 = if (pattern.len == 0) null else pattern.ptr;
        const maybe = c.zq_regex_compile(ptr_in, pattern.len);
        if (maybe) |handle| {
            return Regex{ .handle = handle };
        }
        return Error.RegexCompileFailed;
    }

    pub fn deinit(self: *Regex) void {
        c.zq_regex_free(self.handle);
        self.handle = undefined;
    }

    pub fn captureCount(self: Regex) usize {
        return c.zq_regex_capture_count(self.handle);
    }

    /// Returns the capture group name if the group is named, or `null`
    /// otherwise (unnamed group or out-of-bounds index).
    pub fn groupName(self: Regex, idx: usize) ?[]const u8 {
        var name_ptr: ?[*]const u8 = null;
        var name_len: usize = 0;
        const rc = c.zq_regex_group_name(self.handle, idx, &name_ptr, &name_len);
        if (rc != 1) return null;
        const p = name_ptr orelse return null;
        return p[0..name_len];
    }

    /// Returns the group index if the name resolves, or `null` otherwise.
    pub fn groupIndexByName(self: Regex, name: []const u8) ?usize {
        const ptr_in: ?[*]const u8 = if (name.len == 0) null else name.ptr;
        const rc = c.zq_regex_group_index_by_name(self.handle, ptr_in, name.len);
        if (rc < 0) return null;
        return @intCast(rc);
    }

    pub fn clone(self: Regex) Error!RegexClone {
        const maybe = c.zq_regex_clone(self.handle);
        if (maybe) |h| return RegexClone{ .handle = h };
        return Error.RegexInternalError;
    }

    /// Borrow the shim's cached literal set for this pattern (Sparser
    /// prefilter). Returns `null` when the pattern has no extractable
    /// literals — callers must skip prefilter and run the full regex.
    ///
    /// The returned `Literals` aliases memory inside the shim's `ZqRegex`
    /// struct: lifetime tracks `self`. Do NOT outlive the parent `Regex`.
    pub fn requiredLiterals(self: Regex) ?Literals {
        const p = c.zq_regex_required_literals(self.handle) orelse return null;
        return Literals{ .handle = p };
    }
};

const EnabledRegexClone = struct {
    handle: *c.ZqRegexClone,

    pub fn deinit(self: *RegexClone) void {
        c.zq_regex_clone_free(self.handle);
        self.handle = undefined;
    }

    pub fn isMatch(self: RegexClone, hay: []const u8) Error!bool {
        const ptr_in: ?[*]const u8 = if (hay.len == 0) null else hay.ptr;
        const rc = c.zq_regex_is_match_clone(self.handle, ptr_in, hay.len);
        return switch (rc) {
            1 => true,
            0 => false,
            else => Error.RegexInternalError,
        };
    }

    pub const Match = struct { start: usize, end: usize };

    pub fn find(self: RegexClone, hay: []const u8, start: usize) Error!?Match {
        const ptr_in: ?[*]const u8 = if (hay.len == 0) null else hay.ptr;
        var out_start: usize = 0;
        var out_end: usize = 0;
        const rc = c.zq_regex_find(self.handle, ptr_in, hay.len, start, &out_start, &out_end);
        return switch (rc) {
            1 => Match{ .start = out_start, .end = out_end },
            0 => null,
            else => Error.RegexInternalError,
        };
    }

    pub fn findCaptures(self: RegexClone, hay: []const u8, start: usize, slots: []MatchSlot) Error!bool {
        const ptr_in: ?[*]const u8 = if (hay.len == 0) null else hay.ptr;
        const slot_ptr: ?[*]MatchSlot = if (slots.len == 0) null else slots.ptr;
        const rc = c.zq_regex_find_captures(self.handle, ptr_in, hay.len, start, slot_ptr, slots.len);
        return switch (rc) {
            1 => true,
            0 => false,
            else => Error.RegexInternalError,
        };
    }

    pub fn iterNext(self: RegexClone, hay: []const u8, cursor: *usize, slots: []MatchSlot) Error!bool {
        const ptr_in: ?[*]const u8 = if (hay.len == 0) null else hay.ptr;
        const slot_ptr: ?[*]MatchSlot = if (slots.len == 0) null else slots.ptr;
        const rc = c.zq_regex_iter_next(self.handle, ptr_in, hay.len, cursor, slot_ptr, slots.len);
        return switch (rc) {
            1 => true,
            0 => false,
            else => Error.RegexInternalError,
        };
    }
};

// ─── extern "C" declarations (the shim's C ABI) ───────────────────────────────

const c = if (enabled) struct {
    pub const ZqRegex = opaque {};
    pub const ZqRegexClone = opaque {};
    pub const ZqLiterals = opaque {};

    pub extern fn zq_regex_compile(pat: ?[*]const u8, pat_len: usize) ?*ZqRegex;
    pub extern fn zq_regex_free(handle: *ZqRegex) void;
    pub extern fn zq_regex_capture_count(handle: *const ZqRegex) usize;
    pub extern fn zq_regex_group_name(
        handle: *const ZqRegex,
        idx: usize,
        out_name: *?[*]const u8,
        out_len: *usize,
    ) c_int;
    pub extern fn zq_regex_group_index_by_name(
        handle: *const ZqRegex,
        name: ?[*]const u8,
        name_len: usize,
    ) isize;
    pub extern fn zq_regex_clone(handle: *const ZqRegex) ?*ZqRegexClone;
    pub extern fn zq_regex_clone_free(clone: *ZqRegexClone) void;
    pub extern fn zq_regex_is_match_clone(
        clone: *ZqRegexClone,
        hay: ?[*]const u8,
        hay_len: usize,
    ) c_int;
    pub extern fn zq_regex_find(
        clone: *ZqRegexClone,
        hay: ?[*]const u8,
        hay_len: usize,
        start: usize,
        out_start: *usize,
        out_end: *usize,
    ) c_int;
    pub extern fn zq_regex_find_captures(
        clone: *ZqRegexClone,
        hay: ?[*]const u8,
        hay_len: usize,
        start: usize,
        slots: ?[*]MatchSlot,
        slot_count: usize,
    ) c_int;
    pub extern fn zq_regex_iter_next(
        clone: *ZqRegexClone,
        hay: ?[*]const u8,
        hay_len: usize,
        cursor: *usize,
        slots: ?[*]MatchSlot,
        slot_count: usize,
    ) c_int;
    pub extern fn zq_regex_last_error(buf: [*]u8, buf_len: usize) usize;
    pub extern fn zq_regex__test_panic() c_int;

    // Sparser prefilter literal extraction. See regex-plan §"Sparser-style
    // raw-byte prefilter". The returned `ZqLiterals*` is borrowed from the
    // parent `ZqRegex` and has no separate free routine — its lifetime equals
    // the regex's lifetime.
    pub extern fn zq_regex_required_literals(handle: *const ZqRegex) ?*const ZqLiterals;
    pub extern fn zq_literals_count(lits: *const ZqLiterals) usize;
    pub extern fn zq_literals_at(lits: *const ZqLiterals, idx: usize, out_len: *usize) ?[*]const u8;
    pub extern fn zq_literals_is_exhaustive(lits: *const ZqLiterals) c_int;
} else struct {
    pub const ZqRegex = opaque {};
    pub const ZqRegexClone = opaque {};
    pub const ZqLiterals = opaque {};
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "regex disabled: compile returns RegexNotCompiled" {
    if (enabled) return error.SkipZigTest;
    try std.testing.expectError(Error.RegexNotCompiled, Regex.compile("hello"));
}

test "regex enabled: literal match round-trip" {
    if (!enabled) return error.SkipZigTest;

    var r = try Regex.compile("hello");
    defer r.deinit();
    var clone = try r.clone();
    defer clone.deinit();

    try std.testing.expect(try clone.isMatch("hello world"));
    try std.testing.expect(!try clone.isMatch("goodbye world"));
}

test "regex enabled: compile error populates last_error" {
    if (!enabled) return error.SkipZigTest;

    const res = Regex.compile("(unclosed");
    try std.testing.expectError(Error.RegexCompileFailed, res);

    var buf: [error_buffer_size]u8 = undefined;
    const msg = lastError(&buf);
    try std.testing.expect(msg.len > 0);
}

test "regex enabled: unicode class matches" {
    if (!enabled) return error.SkipZigTest;

    var r = try Regex.compile("\\p{L}+");
    defer r.deinit();
    var clone = try r.clone();
    defer clone.deinit();

    try std.testing.expect(try clone.isMatch("café"));
}

test "regex enabled: capture count includes implicit group" {
    if (!enabled) return error.SkipZigTest;

    var r = try Regex.compile("foo(?<year>\\d{4})-(\\d{2})");
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 3), r.captureCount());
    try std.testing.expectEqual(@as(?usize, 1), r.groupIndexByName("year"));
    try std.testing.expectEqual(@as(?usize, null), r.groupIndexByName("missing"));

    try std.testing.expectEqualStrings("year", r.groupName(1).?);
    try std.testing.expect(r.groupName(0) == null);
    try std.testing.expect(r.groupName(2) == null);
    try std.testing.expect(r.groupName(99) == null);
}

test "regex enabled: find returns byte offsets" {
    if (!enabled) return error.SkipZigTest;

    var r = try Regex.compile("\\d+");
    defer r.deinit();
    var clone = try r.clone();
    defer clone.deinit();

    const m = (try clone.find("abc 123 def", 0)).?;
    try std.testing.expectEqual(@as(usize, 4), m.start);
    try std.testing.expectEqual(@as(usize, 7), m.end);

    // No match at the tail.
    try std.testing.expect(try clone.find("abc", 0) == null);

    // Start past end-of-haystack: no match, not an error.
    try std.testing.expect(try clone.find("abc", 10) == null);
}

test "regex enabled: findCaptures populates slots" {
    if (!enabled) return error.SkipZigTest;

    var r = try Regex.compile("(\\w+)@(\\w+)");
    defer r.deinit();
    var clone = try r.clone();
    defer clone.deinit();

    var slots: [3]MatchSlot = undefined;
    const matched = try clone.findCaptures("send mail to alice@example then", 0, &slots);
    try std.testing.expect(matched);
    // group 0: full match "alice@example"
    try std.testing.expectEqual(@as(usize, 13), slots[0].start);
    try std.testing.expectEqual(@as(usize, 26), slots[0].end);
    // group 1: "alice"
    try std.testing.expectEqual(@as(usize, 13), slots[1].start);
    try std.testing.expectEqual(@as(usize, 18), slots[1].end);
    // group 2: "example"
    try std.testing.expectEqual(@as(usize, 19), slots[2].start);
    try std.testing.expectEqual(@as(usize, 26), slots[2].end);
}

test "regex enabled: unmatched optional group gets SLOT_UNMATCHED" {
    if (!enabled) return error.SkipZigTest;

    var r = try Regex.compile("foo(bar)?baz");
    defer r.deinit();
    var clone = try r.clone();
    defer clone.deinit();

    var slots: [2]MatchSlot = undefined;
    const matched = try clone.findCaptures("foobaz", 0, &slots);
    try std.testing.expect(matched);
    try std.testing.expectEqual(@as(usize, 0), slots[0].start);
    try std.testing.expectEqual(@as(usize, 6), slots[0].end);
    try std.testing.expectEqual(SLOT_UNMATCHED, slots[1].start);
}

test "regex enabled: iterNext scans all matches" {
    if (!enabled) return error.SkipZigTest;

    var r = try Regex.compile("\\d+");
    defer r.deinit();
    var clone = try r.clone();
    defer clone.deinit();

    const hay = "a1 b22 c333";
    var cursor: usize = 0;
    var slots: [1]MatchSlot = undefined;

    var count: usize = 0;
    const expected = [_]struct { s: usize, e: usize }{
        .{ .s = 1, .e = 2 },
        .{ .s = 4, .e = 6 },
        .{ .s = 8, .e = 11 },
    };
    while (try clone.iterNext(hay, &cursor, &slots)) : (count += 1) {
        try std.testing.expectEqual(expected[count].s, slots[0].start);
        try std.testing.expectEqual(expected[count].e, slots[0].end);
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "regex enabled: iterNext handles zero-width match" {
    if (!enabled) return error.SkipZigTest;

    // Empty-match pattern forces the cursor-advance escape path.
    var r = try Regex.compile("a*");
    defer r.deinit();
    var clone = try r.clone();
    defer clone.deinit();

    const hay = "bcd";
    var cursor: usize = 0;
    var slots: [1]MatchSlot = undefined;

    // Must terminate — if our cursor-advance is buggy this is an infinite loop.
    var count: usize = 0;
    while (try clone.iterNext(hay, &cursor, &slots)) : (count += 1) {
        if (count > 16) return error.InfiniteLoop;
    }
    // "a*" matches empty string at every position plus one past the end: 4 matches.
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "regex enabled: panic in shim returns RegexInternalError and process survives" {
    if (!enabled) return error.SkipZigTest;

    const rc = c.zq_regex__test_panic();
    try std.testing.expectEqual(@as(c_int, -1), rc);

    // Last-error channel must carry the panic message — read it BEFORE any
    // subsequent successful call, because those clear the thread-local.
    var buf: [error_buffer_size]u8 = undefined;
    const msg = lastError(&buf);
    try std.testing.expect(std.mem.indexOf(u8, msg, "panic") != null);

    // And: we must still be able to compile + use a regex afterward, proving
    // the panic did not corrupt the shim's thread-local state or the VM.
    var r = try Regex.compile("after-panic");
    defer r.deinit();
    var clone = try r.clone();
    defer clone.deinit();
    try std.testing.expect(try clone.isMatch("after-panic survives"));
}

test "regex enabled: requiredLiterals extracts exhaustive literal pattern" {
    if (!enabled) return error.SkipZigTest;

    var r = try Regex.compile("hello world");
    defer r.deinit();

    const lits = r.requiredLiterals().?;
    try std.testing.expectEqual(@as(usize, 1), lits.count());
    try std.testing.expectEqualStrings("hello world", lits.at(0));
    try std.testing.expect(lits.isExhaustive());
}

test "regex enabled: requiredLiterals extracts alternation (OR-semantics)" {
    if (!enabled) return error.SkipZigTest;

    var r = try Regex.compile("foo|bar|baz");
    defer r.deinit();

    const lits = r.requiredLiterals().?;
    try std.testing.expectEqual(@as(usize, 3), lits.count());
    // Alternation of literals is NOT exhaustive — any one suffices.
    try std.testing.expect(!lits.isExhaustive());
}

test "regex enabled: requiredLiterals returns null for unbounded pattern" {
    if (!enabled) return error.SkipZigTest;

    var r = try Regex.compile(".+");
    defer r.deinit();
    try std.testing.expect(r.requiredLiterals() == null);
}

test "regex enabled: requiredLiterals returns null for digit class" {
    if (!enabled) return error.SkipZigTest;

    // Digit class yields 10 single-byte literals, filtered out by MIN_LITERAL_LEN.
    var r = try Regex.compile("\\d+");
    defer r.deinit();
    try std.testing.expect(r.requiredLiterals() == null);
}

test "regex disabled: requiredLiterals returns null" {
    if (enabled) return error.SkipZigTest;
    var r = Regex.compile("hello") catch return;
    defer r.deinit();
    try std.testing.expect(r.requiredLiterals() == null);
}

test {
    std.testing.refAllDecls(@import("cache.zig"));
    std.testing.refAllDecls(@import("offset.zig"));
}
