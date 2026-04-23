//! Sparser-style raw-byte prefilter for low-selectivity `select(...|regex(lit))`
//! queries.
//!
//! At filter-compile time we detect the `select(X | regex_builtin("literal"))`
//! idiom and extract each regex's required literals via
//! `regex.Regex.requiredLiterals()`. Those literals are stored here; the
//! parallel chunk worker consults them BEFORE handing a raw record's bytes to
//! the JSON parser. Records whose bytes don't satisfy every group are skipped
//! — the full parse + regex run never happens for them.
//!
//! ## Correctness contract (critical)
//! The prefilter MUST NEVER produce false negatives — i.e., it must never
//! reject a record whose full-parse-then-regex result would have been a match.
//! False positives are fine: the record still goes through the normal path,
//! which runs the full regex and rejects it naturally.
//!
//! This property follows directly from `regex-syntax`'s literal extraction
//! guarantees:
//!   - `is_exhaustive == true`: every literal is required to appear anywhere in
//!     the input for the regex to possibly match. Scanning for ALL of them and
//!     rejecting on any-missing cannot miss a match.
//!   - `is_exhaustive == false`: the literals form a covering set — any match
//!     of the regex must cross at least one of them. Rejecting if NONE appear
//!     cannot miss a match.
//!   - `requiredLiterals() == null`: the shim returns null when no sound
//!     literal set exists; we simply don't prefilter that regex.
//!
//! The scan is against the RAW RECORD BYTES (JSON source), not the decoded
//! string values. This is a superset: if a literal appears in any decoded
//! string field, the same bytes appear in the raw JSON (JSON string encoding
//! only prepends `\` escape sequences — which we handle below). The prefilter
//! may match on bytes that don't correspond to a value (e.g., a key name), but
//! that's a harmless false positive — the full regex run filters it out.
//!
//! ## JSON escape handling
//! JSON may encode the byte sequence "foo" inside a string as `foo`, or as
//! `foo`, or as `foo`. Escapes are rare in practice (<1% of strings
//! in common JSON data), and only ambiguity when the literal is itself a
//! char that JSON might escape: `"`, `\`, or a control char. The prefilter
//! trades this edge case (mandatory fall-through on missed escape-encoded
//! literal = missed match = false negative = WRONG) for speed, by restricting
//! which literals are safe to scan. See `canPrefilterLiteral` below.

const std = @import("std");
const regex_mod = @import("regex");

pub const enabled: bool = regex_mod.enabled;

/// One literal group — the requirement produced by a single regex call.
pub const LiteralGroup = struct {
    /// Each entry is a heap-owned byte copy. Owner: the parent `PrefilterSet`.
    literals: [][]const u8,
    /// true  → all literals must appear (AND — from `is_exhaustive`).
    /// false → any one literal must appear (OR — alternation).
    all_required: bool,
};

/// A prefilter for one compiled filter. All groups must individually be
/// satisfied by a record's raw bytes for the record to proceed to full parse.
/// (Groups come from distinct regex calls, all chained under the same select —
/// so each regex must match, and each regex's literal set is a necessary
/// condition for that regex to match.)
pub const PrefilterSet = struct {
    allocator: std.mem.Allocator,
    groups: []LiteralGroup,

    pub fn deinit(self: *PrefilterSet) void {
        for (self.groups) |g| {
            for (g.literals) |lit| self.allocator.free(lit);
            self.allocator.free(g.literals);
        }
        self.allocator.free(self.groups);
        self.groups = &[_]LiteralGroup{};
    }

    /// Copy `groups` into a fresh owned PrefilterSet. Returns `null` if the
    /// group list is empty.
    pub fn ownFrom(
        allocator: std.mem.Allocator,
        src_groups: []const LiteralGroup,
    ) error{OutOfMemory}!?PrefilterSet {
        if (src_groups.len == 0) return null;
        const out_groups = try allocator.alloc(LiteralGroup, src_groups.len);
        var filled: usize = 0;
        errdefer {
            for (out_groups[0..filled]) |g| {
                for (g.literals) |l| allocator.free(l);
                allocator.free(g.literals);
            }
            allocator.free(out_groups);
        }
        for (src_groups, 0..) |g, i| {
            const lits = try allocator.alloc([]const u8, g.literals.len);
            var lits_filled: usize = 0;
            errdefer {
                for (lits[0..lits_filled]) |l| allocator.free(l);
                allocator.free(lits);
            }
            for (g.literals, 0..) |l, j| {
                const copy = try allocator.dupe(u8, l);
                lits[j] = copy;
                lits_filled += 1;
            }
            out_groups[i] = .{
                .literals = lits,
                .all_required = g.all_required,
            };
            filled += 1;
        }
        return PrefilterSet{ .allocator = allocator, .groups = out_groups };
    }

    /// Test `bytes` against every group. Returns true iff the record passes —
    /// i.e., cannot be rejected on the basis of missing literals.
    pub fn accept(self: PrefilterSet, bytes: []const u8) bool {
        for (self.groups) |g| {
            if (g.all_required) {
                for (g.literals) |lit| {
                    if (std.mem.indexOf(u8, bytes, lit) == null) return false;
                }
            } else {
                var any_hit = false;
                for (g.literals) |lit| {
                    if (std.mem.indexOf(u8, bytes, lit) != null) {
                        any_hit = true;
                        break;
                    }
                }
                if (!any_hit) return false;
            }
        }
        return true;
    }
};

/// A literal is safe to prefilter iff it contains no byte that JSON may
/// silently re-encode as an escape when the value is serialized. The raw-byte
/// scan works on source bytes, not decoded values — so a literal like `"\n"`
/// would fail to find its target even when `{"k":"foo\nbar"}` contains the
/// newline semantically.
///
/// Safe: printable ASCII except `"` and `\`, and any multi-byte UTF-8
/// continuation. Unsafe: `"`, `\`, control bytes (< 0x20), and DEL (0x7F).
///
/// Bytes in `0x80..=0xFF` are UTF-8 continuation bytes — JSON either keeps
/// them verbatim (compliant JSON must) or escapes them as `\uXXXX`. We
/// conservatively reject these too, because jq's output encodes non-ASCII as
/// `\uXXXX` by default on some implementations; upstream raw JSON that we're
/// scanning may be either form. Keeping the prefilter ASCII-printable-only is
/// the production-safe rule.
pub fn canPrefilterLiteral(lit: []const u8) bool {
    if (lit.len == 0) return false;
    for (lit) |b| {
        if (b < 0x20) return false;
        if (b == '"') return false;
        if (b == '\\') return false;
        if (b >= 0x7F) return false;
    }
    return true;
}

/// Process a `regex.Regex.requiredLiterals()` result into a `LiteralGroup` of
/// byte-owned copies. Filters out any literal that fails `canPrefilterLiteral`.
/// Returns `null` if the group would be empty after filtering (no safe
/// literal → no prefilter signal).
pub fn groupFromRegex(
    allocator: std.mem.Allocator,
    regex: *const regex_mod.Regex,
) error{OutOfMemory}!?LiteralGroup {
    if (!enabled) return null;
    const lits = regex.requiredLiterals() orelse return null;
    const count = lits.count();
    if (count == 0) return null;

    // First pass: count how many literals survive the safety filter.
    var safe_count: usize = 0;
    var any_unsafe_dropped = false;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const b = lits.at(i);
        if (canPrefilterLiteral(b)) safe_count += 1 else any_unsafe_dropped = true;
    }

    // If the set is exhaustive (AND) and any literal was dropped, we've lost
    // information — we can no longer assert "all literals appear". Fall back
    // to OR-semantics over the safe subset: "at least one appears" is still a
    // strict necessary condition (weaker, but sound) so no false negatives.
    //
    // If the set is OR (alternation) and ANY literal was dropped, we lose
    // coverage: a match could come through the dropped literal and we'd
    // miss it → false negative. Disable prefilter for this group entirely.
    const is_exhaustive_src = lits.isExhaustive();
    const effective_all_required = is_exhaustive_src and !any_unsafe_dropped;

    if (!is_exhaustive_src and any_unsafe_dropped) {
        // OR-semantics: dropping a literal loses coverage — no safe prefilter.
        return null;
    }
    if (safe_count == 0) return null;

    const out = try allocator.alloc([]const u8, safe_count);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |l| allocator.free(l);
        allocator.free(out);
    }
    i = 0;
    while (i < count) : (i += 1) {
        const b = lits.at(i);
        if (!canPrefilterLiteral(b)) continue;
        const copy = try allocator.dupe(u8, b);
        out[filled] = copy;
        filled += 1;
    }

    return LiteralGroup{
        .literals = out,
        .all_required = effective_all_required,
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "PrefilterSet.accept: AND semantics rejects when any literal missing" {
    const alloc = std.testing.allocator;
    const l1 = try alloc.dupe(u8, "hello");
    const l2 = try alloc.dupe(u8, "world");
    const lits_arr = try alloc.alloc([]const u8, 2);
    lits_arr[0] = l1;
    lits_arr[1] = l2;
    const groups_arr = try alloc.alloc(LiteralGroup, 1);
    groups_arr[0] = .{ .literals = lits_arr, .all_required = true };
    var set = PrefilterSet{ .allocator = alloc, .groups = groups_arr };
    defer set.deinit();

    try std.testing.expect(set.accept("hello world!"));
    try std.testing.expect(!set.accept("hello there"));
    try std.testing.expect(!set.accept("no match here"));
}

test "PrefilterSet.accept: OR semantics accepts if any literal present" {
    const alloc = std.testing.allocator;
    const l1 = try alloc.dupe(u8, "foo");
    const l2 = try alloc.dupe(u8, "bar");
    const lits_arr = try alloc.alloc([]const u8, 2);
    lits_arr[0] = l1;
    lits_arr[1] = l2;
    const groups_arr = try alloc.alloc(LiteralGroup, 1);
    groups_arr[0] = .{ .literals = lits_arr, .all_required = false };
    var set = PrefilterSet{ .allocator = alloc, .groups = groups_arr };
    defer set.deinit();

    try std.testing.expect(set.accept("prefix foo suffix"));
    try std.testing.expect(set.accept("prefix bar suffix"));
    try std.testing.expect(!set.accept("prefix baz suffix"));
}

test "canPrefilterLiteral: rejects unsafe bytes" {
    try std.testing.expect(canPrefilterLiteral("hello"));
    try std.testing.expect(canPrefilterLiteral("abc123"));
    try std.testing.expect(!canPrefilterLiteral(""));
    try std.testing.expect(!canPrefilterLiteral("a\"b"));
    try std.testing.expect(!canPrefilterLiteral("a\\b"));
    try std.testing.expect(!canPrefilterLiteral("a\nb"));
    try std.testing.expect(!canPrefilterLiteral("caf\xc3\xa9"));
}

test "groupFromRegex: extracts exhaustive literal" {
    if (!enabled) return error.SkipZigTest;
    var r = try regex_mod.Regex.compile("hello world");
    defer r.deinit();
    const g = (try groupFromRegex(std.testing.allocator, &r)).?;
    defer {
        for (g.literals) |l| std.testing.allocator.free(l);
        std.testing.allocator.free(g.literals);
    }
    try std.testing.expectEqual(@as(usize, 1), g.literals.len);
    try std.testing.expectEqualStrings("hello world", g.literals[0]);
    try std.testing.expect(g.all_required);
}

test "groupFromRegex: returns null for unbounded pattern" {
    if (!enabled) return error.SkipZigTest;
    var r = try regex_mod.Regex.compile(".+");
    defer r.deinit();
    try std.testing.expect((try groupFromRegex(std.testing.allocator, &r)) == null);
}

test "groupFromRegex: OR-semantics for alternation" {
    if (!enabled) return error.SkipZigTest;
    var r = try regex_mod.Regex.compile("foo|bar|baz");
    defer r.deinit();
    const g = (try groupFromRegex(std.testing.allocator, &r)).?;
    defer {
        for (g.literals) |l| std.testing.allocator.free(l);
        std.testing.allocator.free(g.literals);
    }
    try std.testing.expectEqual(@as(usize, 3), g.literals.len);
    try std.testing.expect(!g.all_required);
}
