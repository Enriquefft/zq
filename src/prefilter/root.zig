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
//! JSON (RFC 8259 §7) permits a given character to be serialized as raw bytes
//! OR as an escape sequence. Any escape form (short: `\n` `\t` `\\` `\"` `\/`
//! `\b` `\f` `\r`, or `\uXXXX` incl. surrogate pairs) REQUIRES a `\` (0x5C)
//! byte in the raw record. UTF-8 multi-byte sequences never contain `\`.
//!
//! The prefilter exploits this invariant:
//!   - If the literal's raw bytes appear → keep (may be a real match).
//!   - If the literal's raw bytes DO NOT appear AND the record contains ANY
//!     `\` byte → keep (we cannot rule out an escape-encoded occurrence).
//!   - Only when BOTH conditions fail can we soundly reject.
//!
//! This makes every literal prefilter-safe — including literals that contain
//! `"`, `\`, control chars, or non-ASCII UTF-8 — because a false negative is
//! impossible by construction. False positives on records that happen to
//! contain `\` (e.g. key names with escape sequences that don't correspond to
//! the literal) are harmless: the full regex run filters them out.
//!
//! Performance: both checks are a single-byte indexOf over the record; one
//! SIMD pass each. The second check runs ONLY when the first misses, so
//! records that match (the common case in hit-heavy workloads) pay a single
//! multi-byte indexOf. Records that miss and contain no `\` (also common in
//! numeric-heavy payloads) get rejected in two linear passes — fastest case.

const std = @import("std");
const regex_mod = @import("regex");
const ast = @import("ast");

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
    ///
    /// Escape-aware scan: a literal is deemed "possibly present" if its raw
    /// bytes appear in the record, OR if the record contains any `\` (0x5C)
    /// byte (because any JSON escape form for any character in the literal
    /// requires a backslash). This closes the `\uXXXX`/short-escape hole
    /// (RFC 8259 §7) without length caps or a variant explosion. See the
    /// module doc comment for the correctness argument.
    pub fn accept(self: PrefilterSet, bytes: []const u8) bool {
        // Compute once per record — shared across all groups. A single SIMD
        // pass over the record identifies whether any escaped-form occurrence
        // is even plausible.
        const has_backslash = std.mem.indexOfScalar(u8, bytes, '\\') != null;

        for (self.groups) |g| {
            if (g.all_required) {
                for (g.literals) |lit| {
                    if (std.mem.indexOf(u8, bytes, lit) != null) continue;
                    if (has_backslash) continue; // cannot rule out escape
                    return false;
                }
            } else {
                var any_hit = false;
                for (g.literals) |lit| {
                    if (std.mem.indexOf(u8, bytes, lit) != null) {
                        any_hit = true;
                        break;
                    }
                }
                if (any_hit) continue;
                // No raw hit. If record has `\`, one of the literals might be
                // escape-encoded — we cannot rule out an OR match.
                if (has_backslash) continue;
                return false;
            }
        }
        return true;
    }
};

/// Every literal is safe to prefilter under the escape-aware scan in
/// `PrefilterSet.accept`: the fallback `\`-presence check guarantees no false
/// negative regardless of which bytes the literal contains. The only literals
/// we reject are those too short to matter — single-byte literals have such
/// low selectivity that the SIMD pass beats the savings even on cache-resident
/// records, and empty literals are a degenerate no-op.
const MIN_LITERAL_LEN: usize = 2;

pub fn canPrefilterLiteral(lit: []const u8) bool {
    return lit.len >= MIN_LITERAL_LEN;
}

/// Process a `regex.Regex.requiredLiterals()` result into a `LiteralGroup` of
/// byte-owned copies. Filters out any literal that fails `canPrefilterLiteral`
/// (currently: too-short literals — see `MIN_LITERAL_LEN`).
///
/// Soundness under dropping (AND/OR):
///   - Exhaustive AND set: if any literal is dropped we can no longer assert
///     ALL appear; downgrade to OR over the survivors. OR is a strict weaker
///     condition, so no false negatives.
///   - Non-exhaustive OR set (alternation cover): if any literal is dropped
///     we lose coverage — a match could go through the dropped literal and we
///     would reject. Disable prefilter for this group (null).
///
/// Returns `null` if the group would be empty after filtering.
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

// ─── AST-backed harvester ────────────────────────────────────────────────────
//
// Single source of truth for the prefilter shape match: walks an already-parsed
// AST root and appends any harvestable `LiteralGroup`s onto the caller's list.
//
// Today the legacy token-walk compiler (`legacy@22cd23c compiler.zig`) calls
// `harvestFromAstRoot` after a dedicated `ast.parse(src)`. The Phase 2R
// compiler (`src/compiler/`, when it lands) will call the same function with
// the AST it already parsed for lowering. The harvest logic depends only on
// the AST shape, not on the caller's state, so both call sites observe
// identical prefilter output by construction.
//
// Matches the exact idiom:
//
//     select( <pure-accessor> | <regex-builtin>("<literal>" [; "<flags>"]) )
//
// Anything else — boolean combinators, `//`, trailing pipes, `map(...)`,
// arithmetic, function calls, variable refs — invalidates the
// "no regex match ⇒ no select output" invariant the raw-byte prescreen relies
// on and the harvester bails (safe default: no prefilter).

/// Harvest prefilter literal groups from the given AST root into `out`.
/// Appends zero or one `LiteralGroup` depending on whether the root matches the
/// supported `select(... | test|scan("lit"[; "flags"]))` idiom. Never rejects
/// on shape mismatch — absence of a group is the default.
///
/// Ownership: each appended group's literal bytes are freshly allocated from
/// `alloc`; the caller (or the `PrefilterSet` that eventually consumes them)
/// is responsible for freeing them via `LiteralGroup` convention on failure
/// paths. The `ArrayList` storage itself is caller-owned.
pub fn harvestFromAstRoot(
    alloc: std.mem.Allocator,
    root: *const ast.Node,
    out: *std.ArrayList(LiteralGroup),
) error{OutOfMemory}!void {
    if (!enabled) return;

    // Top-level must be exactly `select(BODY)`. Any other shape → bail.
    const sel = switch (root.kind) {
        .builtin_call => |bc| bc,
        else => return,
    };
    if (!std.mem.eql(u8, sel.name, "select")) return;
    if (sel.args.len != 1) return;

    // BODY must be a pipe whose left is a pure accessor and whose right is a
    // builtin call to `test` or `scan` with 1-2 string literal args.
    const body = sel.args[0];
    const pipe = switch (body.kind) {
        .pipe => |p| p,
        else => return,
    };
    if (!isPureAccessorNode(pipe.left)) return;
    const call = switch (pipe.right.kind) {
        .builtin_call => |bc| bc,
        else => return,
    };
    // Only `test` / `scan` are prefilter-safe:
    //   - match / capture raise a TypeError on no-match — skipping the
    //     record would silently swallow the error.
    //   - splits on no-match yields the original string (non-empty), so
    //     `select(.x | splits("foo"))` outputs even without "foo".
    //   - sub / gsub are mutators — `select(.x | sub(...))` doesn't filter
    //     records at all.
    if (!std.mem.eql(u8, call.name, "test") and !std.mem.eql(u8, call.name, "scan")) return;
    if (call.args.len < 1 or call.args.len > 2) return;

    // Pattern arg must be a direct string literal. Interpolation or pipe
    // expressions as the pattern don't yield a statically-known literal.
    const pattern_decoded = stringLiteralValue(call.args[0]) orelse return;

    // Optional flags arg (same shape: plain string literal).
    var flags_decoded: ?[]const u8 = null;
    if (call.args.len == 2) {
        flags_decoded = stringLiteralValue(call.args[1]) orelse return;
    }

    // Build the real pattern that the regex engine will see: optional
    // `(?<flags>)` prefix, then the decoded literal. Pattern is ALREADY
    // decoded because the AST stores decoded string literals.
    var pattern_buf = std.ArrayList(u8){};
    defer pattern_buf.deinit(alloc);
    if (flags_decoded) |fl| {
        var inline_buf: [8]u8 = undefined;
        var inline_len: usize = 0;
        for (fl) |ch| {
            switch (ch) {
                'i', 'x', 'm', 's' => {
                    inline_buf[inline_len] = ch;
                    inline_len += 1;
                },
                'g', 'n' => {}, // no pattern effect
                else => return, // unknown → let the full compile path error
            }
        }
        if (inline_len > 0) {
            try pattern_buf.appendSlice(alloc, "(?");
            try pattern_buf.appendSlice(alloc, inline_buf[0..inline_len]);
            try pattern_buf.append(alloc, ')');
        }
    }
    try pattern_buf.appendSlice(alloc, pattern_decoded);

    var probe = regex_mod.Regex.compile(pattern_buf.items) catch return;
    defer probe.deinit();
    const maybe_group = try groupFromRegex(alloc, &probe);
    const group = maybe_group orelse return;
    try out.append(alloc, group);
}

/// True iff `n` is a pure path expression — a chain of field accesses,
/// index accesses, iteration, slices, and optionals starting from identity
/// or a field access, with no function calls, boolean combinators, variable
/// refs, arithmetic, or alternatives.
fn isPureAccessorNode(n: *const ast.Node) bool {
    return switch (n.kind) {
        .identity => true,
        .field_access => true,
        .iterate => true,
        .index_access => true,
        .slice => true,
        .recurse => true,
        .optional => |u| isPureAccessorNode(u.operand),
        .paren => |u| isPureAccessorNode(u.operand),
        .pipe => |p| isPureAccessorNode(p.left) and isPureAccessorNode(p.right),
        .suffix => |s| blk: {
            if (!isPureAccessorNode(s.base)) break :blk false;
            for (s.ops) |op| {
                switch (op) {
                    .field, .index, .iterate, .slice, .optional, .bracket_str => {},
                    .bracket_expr => |inner| {
                        switch (inner.kind) {
                            .literal => {},
                            else => if (!isPureAccessorNode(inner)) break :blk false,
                        }
                    },
                }
            }
            break :blk true;
        },
        else => false,
    };
}

/// If `n` is a plain string literal node, return its decoded bytes. All
/// other shapes (interpolation, pipe, etc.) return null — a statically-known
/// literal is required for a sound prefilter.
fn stringLiteralValue(n: *const ast.Node) ?[]const u8 {
    switch (n.kind) {
        .literal => |l| switch (l) {
            .string => |s| return s,
            else => return null,
        },
        .paren => |u| return stringLiteralValue(u.operand),
        else => return null,
    }
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

test "canPrefilterLiteral: accepts any literal >= MIN_LITERAL_LEN" {
    try std.testing.expect(canPrefilterLiteral("hello"));
    try std.testing.expect(canPrefilterLiteral("abc123"));
    try std.testing.expect(!canPrefilterLiteral(""));
    try std.testing.expect(!canPrefilterLiteral("x"));
    // Escape-aware scan handles all byte classes safely — these must all pass.
    try std.testing.expect(canPrefilterLiteral("a\"b"));
    try std.testing.expect(canPrefilterLiteral("a\\b"));
    try std.testing.expect(canPrefilterLiteral("a\nb"));
    try std.testing.expect(canPrefilterLiteral("caf\xc3\xa9"));
}

test "PrefilterSet.accept: raw-hit kept regardless of backslash state" {
    const alloc = std.testing.allocator;
    const l1 = try alloc.dupe(u8, "foo");
    const lits_arr = try alloc.alloc([]const u8, 1);
    lits_arr[0] = l1;
    const groups_arr = try alloc.alloc(LiteralGroup, 1);
    groups_arr[0] = .{ .literals = lits_arr, .all_required = true };
    var set = PrefilterSet{ .allocator = alloc, .groups = groups_arr };
    defer set.deinit();

    try std.testing.expect(set.accept("{\"k\":\"foo\"}"));
    try std.testing.expect(set.accept("{\"k\":\"foo\\nbar\"}")); // raw "foo" present
}

test "PrefilterSet.accept: no raw hit + no backslash -> reject" {
    const alloc = std.testing.allocator;
    const l1 = try alloc.dupe(u8, "foo");
    const lits_arr = try alloc.alloc([]const u8, 1);
    lits_arr[0] = l1;
    const groups_arr = try alloc.alloc(LiteralGroup, 1);
    groups_arr[0] = .{ .literals = lits_arr, .all_required = true };
    var set = PrefilterSet{ .allocator = alloc, .groups = groups_arr };
    defer set.deinit();

    try std.testing.expect(!set.accept("{\"k\":\"bar\"}"));
    try std.testing.expect(!set.accept("plain text with no hit"));
}

test "PrefilterSet.accept: no raw hit BUT backslash present -> keep (escape possible)" {
    // Closes the \uXXXX hole: literal `foo` serialized as `foo`
    // won't match raw bytes but record contains backslashes -> cannot rule out.
    const alloc = std.testing.allocator;
    const l1 = try alloc.dupe(u8, "foo");
    const lits_arr = try alloc.alloc([]const u8, 1);
    lits_arr[0] = l1;
    const groups_arr = try alloc.alloc(LiteralGroup, 1);
    groups_arr[0] = .{ .literals = lits_arr, .all_required = true };
    var set = PrefilterSet{ .allocator = alloc, .groups = groups_arr };
    defer set.deinit();

    // foo is `foo` under \uXXXX escape. Raw bytes do not contain
    // "foo", but backslashes do -> must keep.
    try std.testing.expect(set.accept("{\"k\":\"\\u0066\\u006f\\u006f\"}"));
    // Short escapes similarly introduce backslashes -> cannot reject.
    try std.testing.expect(set.accept("{\"k\":\"a\\tb\"}"));
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
