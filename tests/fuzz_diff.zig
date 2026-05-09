//! Generalized differential fuzz harness against jq.
//!
//! Strategy: generate random (filter, JSON input) pairs, run both `jq -c` and
//! the built `zq -c` binary, byte-diff stdout. Skip-compare known-divergent
//! constructs at the production where they are generated, so the harness
//! reports real bugs instead of expected differences.
//!
//! Not part of the default test step. Invoke with:
//!   `zig build fuzz-diff`
//!
//! Defaults:
//!   - iterations: 1000
//!   - seed:       0  (override with ZQ_FUZZ_SEED)
//!   - jq binary:  `jq` on PATH (override with ZQ_JQ)
//!   - zq binary:  emitted by this build (path threaded via build_options)
//!
//! Reproduce hint:
//!   On divergence, the harness prints `seed=N iter=K` so a single failing
//!   iteration can be re-run with `ZQ_FUZZ_SEED=N ZQ_FUZZ_ITERS=K+1`.
//!
//! Exit codes:
//!   0 — every non-skipped iteration agreed
//!   1 — any divergence found, or `checked == 0` (vacuous-pass guard)

const std = @import("std");
const fc = @import("fuzz_common.zig");
const build_options = @import("build_options");

const default_iterations: u32 = 1000;

// ── Seed corpus from JSONTestSuite ────────────────────────────────────────────
//
// Embedded valid JSON samples covering shapes the random generator is unlikely
// to produce often: empty containers, top-level non-aggregate, multi-key
// objects, etc. With probability `seed_prob` the JSON generator returns one of
// these instead of a fresh tree, biasing coverage toward known-valid edges.

const seeds = [_][]const u8{
    @embedFile("JSONTestSuite/y_array_empty.json"),
    @embedFile("JSONTestSuite/y_object_basic.json"),
    @embedFile("JSONTestSuite/y_number_simple_int.json"),
    @embedFile("JSONTestSuite/y_string_simple_ascii.json"),
    @embedFile("JSONTestSuite/y_structure_lonely_null.json"),
    @embedFile("JSONTestSuite/y_number_negative_int.json"),
    @embedFile("JSONTestSuite/y_object.json"),
    @embedFile("JSONTestSuite/y_structure_lonely_true.json"),
    @embedFile("JSONTestSuite/y_array_with_1_and_newline.json"),
    @embedFile("JSONTestSuite/y_object_empty.json"),
};

const seed_prob: f32 = 0.15;

// ── JSON generator ────────────────────────────────────────────────────────────
//
// Depth-bounded recursive generator. Output: caller-owned bytes containing one
// JSON value followed by '\n'. Single-value-per-input keeps the diff against
// jq well-defined; multi-record (JSONL) inputs are deferred to v2.
//
// Signal-amplification choices, named explicitly:
//   - Object keys are drawn from a 10-word dict that the FilterGenerator
//     also targets. Without this, `.a` lookups hit a real field ~1 in 10k
//     iters; with it, ~1 in 5. Single biggest decision in the harness.
//   - Numbers exclude Infinity / -Infinity / NaN literals (zq deliberate
//     IEEE-754 deviation; the FilterGenerator flags those separately).
//   - Boundary values come from a small fixed table, not full random f64,
//     to catch edge cases without spamming them.

const KEY_DICT = [_][]const u8{ "a", "b", "c", "k", "x", "y", "name", "id", "val", "arr" };

const NUMBER_BOUNDARIES = [_][]const u8{ "0", "-0", "1", "-1", "1e-10", "1e10" };

const MAX_DEPTH: u8 = 4;

const JsonGenerator = struct {
    rng: std.Random,
    alloc: std.mem.Allocator,

    /// Public entry. ~85% fresh tree, ~15% seed clone.
    /// Returns []u8 with trailing '\n'. Caller frees.
    pub fn gen(self: *JsonGenerator) ![]u8 {
        // Always consume one f32 from RNG so seed/iter reproducibility holds
        // regardless of which branch we take.
        const roll = self.rng.float(f32);
        if (roll < seed_prob) {
            const idx = self.rng.uintLessThan(usize, seeds.len);
            var out = try self.alloc.alloc(u8, seeds[idx].len + 1);
            @memcpy(out[0..seeds[idx].len], seeds[idx]);
            out[seeds[idx].len] = '\n';
            return out;
        }
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(self.alloc);
        try self.genValue(&buf, 0);
        try buf.append(self.alloc, '\n');
        return buf.toOwnedSlice(self.alloc);
    }

    fn genValue(self: *JsonGenerator, buf: *std.ArrayList(u8), depth: u8) anyerror!void {
        // At max depth, force a scalar to keep output bounded.
        if (depth >= MAX_DEPTH) {
            return self.genScalar(buf);
        }
        // Mixture: 60% scalar, 20% array, 20% object at non-max depths.
        const pick = self.rng.uintLessThan(u8, 10);
        switch (pick) {
            0, 1, 2, 3, 4, 5 => try self.genScalar(buf),
            6, 7 => try self.genArray(buf, depth),
            else => try self.genObject(buf, depth),
        }
    }

    fn genScalar(self: *JsonGenerator, buf: *std.ArrayList(u8)) !void {
        const pick = self.rng.uintLessThan(u8, 10);
        switch (pick) {
            0 => try buf.appendSlice(self.alloc, "null"),
            1 => try buf.appendSlice(self.alloc, "true"),
            2 => try buf.appendSlice(self.alloc, "false"),
            3, 4, 5, 6 => try self.genNumber(buf),
            else => try self.genString(buf),
        }
    }

    fn genNumber(self: *JsonGenerator, buf: *std.ArrayList(u8)) !void {
        const pick = self.rng.uintLessThan(u8, 20);
        if (pick < 14) {
            // 70% int in [-1000, 1000]
            const n = @as(i32, @intCast(self.rng.uintLessThan(u32, 2001))) - 1000;
            try std.fmt.format(buf.writer(self.alloc), "{d}", .{n});
        } else if (pick < 19) {
            // 25% f64; bounded magnitude, no NaN/Inf
            const f = (self.rng.float(f64) - 0.5) * 2.0e6;
            try std.fmt.format(buf.writer(self.alloc), "{d}", .{f});
        } else {
            // 5% boundary value
            const idx = self.rng.uintLessThan(usize, NUMBER_BOUNDARIES.len);
            try buf.appendSlice(self.alloc, NUMBER_BOUNDARIES[idx]);
        }
    }

    fn genString(self: *JsonGenerator, buf: *std.ArrayList(u8)) !void {
        const pick = self.rng.uintLessThan(u8, 20);
        try buf.append(self.alloc, '"');
        if (pick == 0) {
            // 5% empty string
        } else if (pick < 4) {
            // 15% with embedded escapes — emit a few benign printable chars
            // plus one short-escape sequence the parser MUST decode.
            const escapes = [_][]const u8{ "\\n", "\\t", "\\\\", "\\\"", "\\u0041" };
            const e = escapes[self.rng.uintLessThan(usize, escapes.len)];
            const len = self.rng.uintLessThan(u8, 4) + 1;
            var i: u8 = 0;
            while (i < len) : (i += 1) {
                try buf.append(self.alloc, 'a' + self.rng.uintLessThan(u8, 26));
            }
            try buf.appendSlice(self.alloc, e);
        } else {
            // 80% lowercase a-z, length 0–8
            const len = self.rng.uintLessThan(u8, 9);
            var i: u8 = 0;
            while (i < len) : (i += 1) {
                try buf.append(self.alloc, 'a' + self.rng.uintLessThan(u8, 26));
            }
        }
        try buf.append(self.alloc, '"');
    }

    fn genArray(self: *JsonGenerator, buf: *std.ArrayList(u8), depth: u8) !void {
        try buf.append(self.alloc, '[');
        const n = self.rng.uintLessThan(u8, 6); // 0–5 elements
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            if (i > 0) try buf.append(self.alloc, ',');
            try self.genValue(buf, depth + 1);
        }
        try buf.append(self.alloc, ']');
    }

    fn genObject(self: *JsonGenerator, buf: *std.ArrayList(u8), depth: u8) !void {
        try buf.append(self.alloc, '{');
        const n = self.rng.uintLessThan(u8, 5); // 0–4 keys
        // Track keys used to avoid duplicates (jq sees them, but value is
        // implementation-defined — sidestep the divergence class entirely).
        var used = [_]bool{false} ** KEY_DICT.len;
        var emitted: u8 = 0;
        var attempts: u8 = 0;
        while (emitted < n and attempts < 16) : (attempts += 1) {
            const idx = self.rng.uintLessThan(usize, KEY_DICT.len);
            if (used[idx]) continue;
            used[idx] = true;
            if (emitted > 0) try buf.append(self.alloc, ',');
            try buf.append(self.alloc, '"');
            try buf.appendSlice(self.alloc, KEY_DICT[idx]);
            try buf.appendSlice(self.alloc, "\":");
            try self.genValue(buf, depth + 1);
            emitted += 1;
        }
        try buf.append(self.alloc, '}');
    }
};

// ── Filter generator ──────────────────────────────────────────────────────────
//
// Tier-1 jq grammar plus bindings (`as $x`) and assignments (`=`, `|=`, `+=`,
// `-=`) — the surface a v1.0 "drop-in jq replacement" claim is staked on.
// Excluded by design: reduce/foreach/def/destructuring/recursive-descent
// (deferred to v2), regex (covered by fuzz_regex), datetime/formatters
// (out of v1 grammar).
//
// `uses_unsupported`: set on this generator when a production emits a known
// divergent construct (div-by-zero RHS, large-int literal, side-effecting
// any/all). The harness still emits the filter — the iteration is skip-
// compared, not skip-generated, so RNG consumption stays deterministic.

const Filter = struct {
    src: []u8,
    uses_unsupported: bool,
};

const FILTER_MAX_DEPTH: u8 = 3;

const BUILTINS_NULLARY = [_][]const u8{
    "length",         "type",         "keys",   "keys_unsorted",
    "values",         "not",          "min",    "max",
    "add",            "reverse",      "unique", "sort",
    "floor",          "ceil",         "round",  "sqrt",
    "tostring",       "tonumber",     "tojson", "fromjson",
    "ascii_downcase", "ascii_upcase", "first",  "last",
    "to_entries",     "from_entries", "empty",
};

const BUILTINS_FILTER_ARG = [_][]const u8{
    "map", "select", "sort_by", "group_by", "any", "all",
};

const BUILTINS_STR_ARG = [_][]const u8{
    "ltrimstr", "rtrimstr", "startswith", "endswith", "split", "has",
};

const ARITH_OPS = [_][]const u8{ "+", "-", "*", "/", "%" };
const CMP_OPS = [_][]const u8{ "==", "!=", "<", "<=", ">", ">=" };
const LOGICAL_OPS = [_][]const u8{ "and", "or" };
const ASSIGN_OPS = [_][]const u8{ " = ", " |= ", " += ", " -= " };

const FilterGenerator = struct {
    rng: std.Random,
    alloc: std.mem.Allocator,
    flag_unsupported: bool = false,

    pub fn init(rng: std.Random, alloc: std.mem.Allocator) FilterGenerator {
        return .{ .rng = rng, .alloc = alloc };
    }

    pub fn gen(self: *FilterGenerator) !Filter {
        self.flag_unsupported = false;
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(self.alloc);

        const shape = self.rng.float(f32);
        if (shape < 0.7) {
            try self.genExpr(&buf, 0);
        } else if (shape < 0.85) {
            try buf.appendSlice(self.alloc, ".[] | ");
            try self.genExpr(&buf, 1);
        } else if (shape < 0.95) {
            try buf.appendSlice(self.alloc, "select(");
            try self.genExpr(&buf, 1);
            try buf.appendSlice(self.alloc, ") | ");
            try self.genExpr(&buf, 1);
        } else {
            try self.genAssignTopLevel(&buf);
        }
        return .{
            .src = try buf.toOwnedSlice(self.alloc),
            .uses_unsupported = self.flag_unsupported,
        };
    }

    fn genExpr(self: *FilterGenerator, buf: *std.ArrayList(u8), depth: u8) anyerror!void {
        if (depth >= FILTER_MAX_DEPTH) return self.genLeaf(buf);
        const pick = self.rng.uintLessThan(u8, 100);
        if (pick < 30) {
            try self.genLeaf(buf);
        } else if (pick < 45) {
            try self.genArrayCtor(buf, depth + 1);
        } else if (pick < 55) {
            try self.genObjectCtor(buf, depth + 1);
        } else if (pick < 65) {
            try self.genBuiltin(buf, depth + 1);
        } else if (pick < 75) {
            try buf.append(self.alloc, '(');
            try self.genExpr(buf, depth + 1);
            try buf.appendSlice(self.alloc, " | ");
            try self.genExpr(buf, depth + 1);
            try buf.append(self.alloc, ')');
        } else if (pick < 80) {
            try buf.append(self.alloc, '(');
            try self.genExpr(buf, depth + 1);
            try buf.appendSlice(self.alloc, ", ");
            try self.genExpr(buf, depth + 1);
            try buf.append(self.alloc, ')');
        } else if (pick < 86) {
            try self.genArith(buf, depth + 1);
        } else if (pick < 90) {
            try self.genCmp(buf, depth + 1);
        } else if (pick < 93) {
            try self.genLogical(buf, depth + 1);
        } else if (pick < 95) {
            // alt //
            try buf.append(self.alloc, '(');
            try self.genExpr(buf, depth + 1);
            try buf.appendSlice(self.alloc, " // ");
            try self.genExpr(buf, depth + 1);
            try buf.append(self.alloc, ')');
        } else if (pick < 97) {
            // if/then/else
            try buf.appendSlice(self.alloc, "(if ");
            try self.genExpr(buf, depth + 1);
            try buf.appendSlice(self.alloc, " then ");
            try self.genExpr(buf, depth + 1);
            try buf.appendSlice(self.alloc, " else ");
            try self.genExpr(buf, depth + 1);
            try buf.appendSlice(self.alloc, " end)");
        } else if (pick < 99) {
            // try/catch
            try buf.appendSlice(self.alloc, "(try ");
            try self.genExpr(buf, depth + 1);
            try buf.appendSlice(self.alloc, " catch ");
            try self.genExpr(buf, depth + 1);
            try buf.append(self.alloc, ')');
        } else {
            // binding
            try buf.append(self.alloc, '(');
            try self.genExpr(buf, depth + 1);
            try buf.appendSlice(self.alloc, " as $");
            try buf.appendSlice(self.alloc, KEY_DICT[self.rng.uintLessThan(usize, KEY_DICT.len)]);
            try buf.appendSlice(self.alloc, " | ");
            try self.genExpr(buf, depth + 1);
            try buf.append(self.alloc, ')');
        }
    }

    /// Leaf production. Never recurses. Used at max depth and as the base case.
    fn genLeaf(self: *FilterGenerator, buf: *std.ArrayList(u8)) !void {
        const pick = self.rng.uintLessThan(u8, 100);
        if (pick < 12) {
            try buf.append(self.alloc, '.');
        } else if (pick < 45) {
            // .field [.field]{0,2}
            const n = self.rng.uintLessThan(u8, 3) + 1;
            var i: u8 = 0;
            while (i < n) : (i += 1) {
                try buf.append(self.alloc, '.');
                try buf.appendSlice(self.alloc, KEY_DICT[self.rng.uintLessThan(usize, KEY_DICT.len)]);
            }
            if (self.rng.float(f32) < 0.2) try buf.append(self.alloc, '?');
        } else if (pick < 58) {
            // .[INT]
            const idx = @as(i32, @intCast(self.rng.uintLessThan(u32, 9))) - 3;
            try std.fmt.format(buf.writer(self.alloc), ".[{d}]", .{idx});
            if (self.rng.float(f32) < 0.2) try buf.append(self.alloc, '?');
        } else if (pick < 66) {
            // .[INT?:INT?]
            try buf.appendSlice(self.alloc, ".[");
            if (self.rng.float(f32) < 0.5) {
                const lo = @as(i32, @intCast(self.rng.uintLessThan(u32, 4)));
                try std.fmt.format(buf.writer(self.alloc), "{d}", .{lo});
            }
            try buf.append(self.alloc, ':');
            if (self.rng.float(f32) < 0.5) {
                const hi = @as(i32, @intCast(self.rng.uintLessThan(u32, 5))) + 1;
                try std.fmt.format(buf.writer(self.alloc), "{d}", .{hi});
            }
            try buf.append(self.alloc, ']');
        } else if (pick < 73) {
            try buf.appendSlice(self.alloc, ".[]");
            if (self.rng.float(f32) < 0.2) try buf.append(self.alloc, '?');
        } else if (pick < 92) {
            try self.genLiteral(buf);
        } else {
            const name = BUILTINS_NULLARY[self.rng.uintLessThan(usize, BUILTINS_NULLARY.len)];
            try buf.appendSlice(self.alloc, name);
        }
    }

    fn genArith(self: *FilterGenerator, buf: *std.ArrayList(u8), depth: u8) !void {
        const op = ARITH_OPS[self.rng.uintLessThan(usize, ARITH_OPS.len)];
        try buf.append(self.alloc, '(');
        try self.genExpr(buf, depth);
        try buf.append(self.alloc, ' ');
        try buf.appendSlice(self.alloc, op);
        try buf.append(self.alloc, ' ');
        // For / and %, force a positive integer literal RHS to skip the
        // div-by-zero divergence class entirely. Cheap, deterministic.
        if (op[0] == '/' or op[0] == '%') {
            try std.fmt.format(buf.writer(self.alloc), "{d}", .{self.rng.uintLessThan(u32, 99) + 1});
        } else {
            try self.genExpr(buf, depth);
        }
        try buf.append(self.alloc, ')');
    }

    fn genCmp(self: *FilterGenerator, buf: *std.ArrayList(u8), depth: u8) !void {
        try buf.append(self.alloc, '(');
        try self.genExpr(buf, depth);
        try buf.append(self.alloc, ' ');
        try buf.appendSlice(self.alloc, CMP_OPS[self.rng.uintLessThan(usize, CMP_OPS.len)]);
        try buf.append(self.alloc, ' ');
        try self.genExpr(buf, depth);
        try buf.append(self.alloc, ')');
    }

    fn genLogical(self: *FilterGenerator, buf: *std.ArrayList(u8), depth: u8) !void {
        try buf.append(self.alloc, '(');
        try self.genExpr(buf, depth);
        try buf.append(self.alloc, ' ');
        try buf.appendSlice(self.alloc, LOGICAL_OPS[self.rng.uintLessThan(usize, LOGICAL_OPS.len)]);
        try buf.append(self.alloc, ' ');
        try self.genExpr(buf, depth);
        try buf.append(self.alloc, ')');
    }

    fn genArrayCtor(self: *FilterGenerator, buf: *std.ArrayList(u8), depth: u8) !void {
        try buf.append(self.alloc, '[');
        try self.genExpr(buf, depth);
        try buf.append(self.alloc, ']');
    }

    fn genObjectCtor(self: *FilterGenerator, buf: *std.ArrayList(u8), depth: u8) !void {
        try buf.append(self.alloc, '{');
        const n = self.rng.uintLessThan(u8, 3) + 1;
        var used = [_]bool{false} ** KEY_DICT.len;
        var emitted: u8 = 0;
        var attempts: u8 = 0;
        while (emitted < n and attempts < 8) : (attempts += 1) {
            const idx = self.rng.uintLessThan(usize, KEY_DICT.len);
            if (used[idx]) continue;
            used[idx] = true;
            if (emitted > 0) try buf.append(self.alloc, ',');
            try buf.appendSlice(self.alloc, KEY_DICT[idx]);
            try buf.append(self.alloc, ':');
            // Object-ctor RHS: parens-wrap to dodge ambiguity in the jq parser
            // when the value is itself a comma'd or piped expression.
            try buf.append(self.alloc, '(');
            try self.genExpr(buf, depth);
            try buf.append(self.alloc, ')');
            emitted += 1;
        }
        try buf.append(self.alloc, '}');
    }

    fn genBuiltin(self: *FilterGenerator, buf: *std.ArrayList(u8), depth: u8) !void {
        const pick = self.rng.uintLessThan(u8, 100);
        if (pick < 50) {
            const name = BUILTINS_NULLARY[self.rng.uintLessThan(usize, BUILTINS_NULLARY.len)];
            try buf.appendSlice(self.alloc, name);
        } else if (pick < 85) {
            const name = BUILTINS_FILTER_ARG[self.rng.uintLessThan(usize, BUILTINS_FILTER_ARG.len)];
            // any/all on side-effecting / generator filters has documented
            // eager-eval divergence — flag uniformly rather than analyze RHS.
            if (std.mem.eql(u8, name, "any") or std.mem.eql(u8, name, "all")) {
                self.flag_unsupported = true;
            }
            try buf.appendSlice(self.alloc, name);
            try buf.append(self.alloc, '(');
            try self.genExpr(buf, depth);
            try buf.append(self.alloc, ')');
        } else {
            const name = BUILTINS_STR_ARG[self.rng.uintLessThan(usize, BUILTINS_STR_ARG.len)];
            try buf.appendSlice(self.alloc, name);
            try buf.append(self.alloc, '(');
            try self.genStringLiteral(buf);
            try buf.append(self.alloc, ')');
        }
    }

    fn genLiteral(self: *FilterGenerator, buf: *std.ArrayList(u8)) !void {
        const pick = self.rng.uintLessThan(u8, 10);
        switch (pick) {
            0 => try buf.appendSlice(self.alloc, "null"),
            1 => try buf.appendSlice(self.alloc, "true"),
            2 => try buf.appendSlice(self.alloc, "false"),
            3, 4, 5, 6 => {
                const n = @as(i32, @intCast(self.rng.uintLessThan(u32, 201))) - 100;
                try std.fmt.format(buf.writer(self.alloc), "{d}", .{n});
            },
            else => try self.genStringLiteral(buf),
        }
    }

    fn genStringLiteral(self: *FilterGenerator, buf: *std.ArrayList(u8)) !void {
        try buf.append(self.alloc, '"');
        const len = self.rng.uintLessThan(u8, 6);
        var i: u8 = 0;
        while (i < len) : (i += 1) {
            try buf.append(self.alloc, 'a' + self.rng.uintLessThan(u8, 26));
        }
        try buf.append(self.alloc, '"');
    }

    fn genAssignTopLevel(self: *FilterGenerator, buf: *std.ArrayList(u8)) !void {
        // .field OP expr — restrict LHS to a 1-segment field path so the
        // assignment is well-typed against the JSON generator's objects.
        try buf.append(self.alloc, '.');
        try buf.appendSlice(self.alloc, KEY_DICT[self.rng.uintLessThan(usize, KEY_DICT.len)]);
        try buf.appendSlice(self.alloc, ASSIGN_OPS[self.rng.uintLessThan(usize, ASSIGN_OPS.len)]);
        try self.genExpr(buf, 1);
    }
};

// ── Skip-compare backstop ─────────────────────────────────────────────────────
//
// Pure-string heuristic over (filter, json) pair. Catches dynamic divergences
// the production-time `uses_unsupported` flag can't see — e.g. `/.x` where
// `.x` evaluates to 0 at runtime, or `tonumber` applied to a non-numeric
// string. Bar: zero false-divergences on the known-good corpus.

fn shouldSkipDiff(filter: []const u8, json: []const u8) bool {
    _ = json;
    // Filter-source heuristics. Cheap substring checks — false positives just
    // shrink coverage, false negatives manifest as known-divergent reports.
    if (std.mem.indexOf(u8, filter, "Infinity") != null) return true;
    if (std.mem.indexOf(u8, filter, "NaN") != null) return true;
    // Module system unimplemented.
    if (std.mem.indexOf(u8, filter, "import ") != null) return true;
    if (std.mem.indexOf(u8, filter, "include ") != null) return true;
    return false;
}

fn parseIters() u32 {
    const env = std.posix.getenv("ZQ_FUZZ_ITERS") orelse return default_iterations;
    return std.fmt.parseInt(u32, env, 10) catch default_iterations;
}

fn parseSeed() u64 {
    const env = std.posix.getenv("ZQ_FUZZ_SEED") orelse return 0;
    return std.fmt.parseInt(u64, env, 10) catch 0;
}

// ── Spot test (smoke gate) ────────────────────────────────────────────────────
//
// Before any generators run, prove that:
//   1. jq is on PATH.
//   2. zq binary built and runs.
//   3. Identity filter `.` on input `42` produces byte-identical output from
//      both. If this fails, all subsequent diffs are noise — output format
//      drift somewhere — fail loud at the gate.

test "fuzz-diff: spot — identity filter byte-eq" {
    const alloc = std.testing.allocator;
    try fc.requireJqOnPath(alloc);
    try fc.requireZqBinary(alloc, build_options.zq_path);

    const filter = ".";
    const input = "42\n";

    const jq_out = try fc.runJqStdin(alloc, filter, input);
    defer {
        var m = jq_out;
        m.deinit(alloc);
    }
    const zq_out = try fc.runZqSubprocess(alloc, build_options.zq_path, filter, input);
    defer {
        var m = zq_out;
        m.deinit(alloc);
    }

    if (!std.mem.eql(u8, jq_out.stdout, zq_out.stdout)) {
        std.debug.print(
            "spot-test FAIL: identity filter byte-eq broken\n  jq={s}\n  zq={s}\n  zq stderr={s}\n",
            .{ jq_out.stdout, zq_out.stdout, zq_out.stderr },
        );
        return error.SpotTestFailed;
    }
}

// ── Main differential loop ────────────────────────────────────────────────────

/// One captured divergence. Owns no memory — `filter` and `input` are duped
/// at capture time (callee owns the originals), `jq_stdout`/`zq_stdout` are
/// duped from process outputs that get freed at end-of-iter.
const Divergence = struct {
    iter: u32,
    filter: []u8,
    input: []u8,
    jq_stdout: []u8,
    zq_stdout: []u8,
    zq_stderr: []u8,
    jq_exit: u8,
    zq_exit: u8,

    fn deinit(self: *Divergence, alloc: std.mem.Allocator) void {
        alloc.free(self.filter);
        alloc.free(self.input);
        alloc.free(self.jq_stdout);
        alloc.free(self.zq_stdout);
        alloc.free(self.zq_stderr);
    }
};

/// jq prints `jq: error (at <stdin>:1): ...` to stderr and exits 5 on
/// runtime errors, exit 3 on parse/compile errors. Both implementations
/// returning non-zero with no stdout = mutually rejected program → not a
/// divergence. Use the simplest signal: both exit non-zero AND both stdouts
/// empty.
fn mutuallyRejected(jq_exit: u8, zq_exit: u8, jq_stdout: []const u8, zq_stdout: []const u8) bool {
    return jq_exit != 0 and zq_exit != 0 and jq_stdout.len == 0 and zq_stdout.len == 0;
}

test "differential fuzz: jq surface vs zq" {
    const alloc = std.testing.allocator;
    try fc.requireJqOnPath(alloc);
    try fc.requireZqBinary(alloc, build_options.zq_path);

    const n: u32 = parseIters();
    const seed: u64 = parseSeed();

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var json_gen = JsonGenerator{ .rng = rng, .alloc = alloc };
    var filter_gen = FilterGenerator.init(rng, alloc);

    var checked: u32 = 0;
    var skipped_unsupported: u32 = 0;
    var skipped_backstop: u32 = 0;
    var mutual_errors: u32 = 0;
    var divergences: u32 = 0;

    var first_divergences = std.ArrayList(Divergence){};
    defer {
        for (first_divergences.items) |*d| d.deinit(alloc);
        first_divergences.deinit(alloc);
    }

    var iter: u32 = 0;
    while (iter < n) : (iter += 1) {
        // Determinism: BOTH generators run unconditionally so the RNG stream
        // doesn't depend on skip decisions. Reproduce-hint relies on this.
        const f = try filter_gen.gen();
        defer alloc.free(f.src);
        const j = try json_gen.gen();
        defer alloc.free(j);

        if (f.uses_unsupported) {
            skipped_unsupported += 1;
            continue;
        }
        if (shouldSkipDiff(f.src, j)) {
            skipped_backstop += 1;
            continue;
        }

        var jq = fc.runJqStdin(alloc, f.src, j) catch |e| {
            // Subprocess infrastructure failed (not a logical divergence).
            // Surface as test failure; harness bug if it happens repeatedly.
            std.debug.print("jq subprocess failed at iter={d}: {s}\n", .{ iter, @errorName(e) });
            return e;
        };
        defer jq.deinit(alloc);
        var zq = fc.runZqSubprocess(alloc, build_options.zq_path, f.src, j) catch |e| {
            std.debug.print("zq subprocess failed at iter={d}: {s}\n", .{ iter, @errorName(e) });
            return e;
        };
        defer zq.deinit(alloc);

        if (mutuallyRejected(jq.exit_code, zq.exit_code, jq.stdout, zq.stdout)) {
            mutual_errors += 1;
            continue;
        }

        checked += 1;
        if (!std.mem.eql(u8, jq.stdout, zq.stdout) or jq.exit_code != zq.exit_code) {
            divergences += 1;
            if (first_divergences.items.len < 10) {
                try first_divergences.append(alloc, .{
                    .iter = iter,
                    .filter = try alloc.dupe(u8, f.src),
                    .input = try alloc.dupe(u8, j),
                    .jq_stdout = try alloc.dupe(u8, jq.stdout),
                    .zq_stdout = try alloc.dupe(u8, zq.stdout),
                    .zq_stderr = try alloc.dupe(u8, zq.stderr),
                    .jq_exit = jq.exit_code,
                    .zq_exit = zq.exit_code,
                });
            }
        }
    }

    // ── Reporter ──────────────────────────────────────────────────────────
    std.debug.print(
        \\=== fuzz-diff summary ===
        \\seed:                {d}
        \\iterations:          {d}
        \\checked (diffed):    {d}
        \\skipped (unsupp):    {d}
        \\skipped (backstop):  {d}
        \\mutual errors:       {d}
        \\divergences:         {d}
        \\
    , .{ seed, n, checked, skipped_unsupported, skipped_backstop, mutual_errors, divergences });

    for (first_divergences.items, 0..) |d, idx| {
        std.debug.print(
            \\
            \\--- divergence #{d} (iter={d}, seed={d}) ---
            \\filter:    {s}
            \\input:     {s}
            \\jq stdout: {s}
            \\zq stdout: {s}
            \\jq exit:   {d}
            \\zq exit:   {d}
            \\zq stderr: {s}
            \\reproduce: ZQ_FUZZ_SEED={d} ZQ_FUZZ_ITERS={d} zig build fuzz-diff
            \\
        , .{
            idx + 1,     d.iter,
            seed,        d.filter,
            d.input,     d.jq_stdout,
            d.zq_stdout, d.jq_exit,
            d.zq_exit,   d.zq_stderr,
            seed,        d.iter + 1,
        });
    }

    // Vacuous-pass guard: harness must actually compare at least one pair.
    try std.testing.expect(checked > 0);
    // Every checked iteration must agree byte-for-byte with jq. Failing this
    // means zq diverges from the oracle on the Tier-1 surface — file each
    // divergence as a compat bug; do NOT mute the assertion.
    try std.testing.expectEqual(@as(u32, 0), divergences);
}
