const std = @import("std");

/// Core data types shared across all zq modules.
///
/// These are the "contracts" that connect Parser → Query → Output:
///   - Parser produces a Tape
///   - Query compiles to Instructions, executes against a Tape, yields Values
///   - Output consumes Values

// ─── Tape ────────────────────────────────────────────────────────────────────
// Linear encoding of JSON structure. No hash maps, no pointers — just a flat
// array of opcodes + payloads. Enables O(1) skipping and minimal cache misses.

pub const Tape = struct {
    entries: []const Entry,
    /// Interned string/key bytes backing all `string_offset` references.
    string_buf: []const u8,

    pub const Entry = extern struct {
        tag: Tag,
        payload: Payload,
    };

    pub const Tag = enum(u8) {
        object_start, // '{' — payload.skip = index past matching object_end
        object_end, // '}'
        array_start, // '[' — payload.skip = index past matching array_end
        array_end, // ']'
        key, // object key — payload indexes into string_buf
        string, // string value — payload indexes into string_buf
        int, // integer value — payload.int
        float, // float value — payload.float
        true_val, // true
        false_val, // false
        null_val, // null
        /// Out-of-range numeric literal (overflow/underflow for f64).
        /// payload.string = canonical normalized text in string_buf, e.g. "9E+999999999".
        big_number,
    };

    pub const Payload = extern union {
        /// Byte offset + length into Tape.string_buf.
        string: StringRef,
        /// Tape index to jump to for skipping containers.
        skip: u32,
        int: i64,
        float: f64,
        /// Tags that carry no data (true/false/null/end markers).
        none: void,
    };

    pub const StringRef = extern struct {
        offset: u32,
        len: u32,
    };

    /// Resolve a StringRef to the actual bytes.
    pub fn getString(self: Tape, ref: StringRef) []const u8 {
        return self.string_buf[ref.offset..][0..ref.len];
    }
};

// ─── Value ───────────────────────────────────────────────────────────────────
// The result type that Query yields and Output consumes.
// A Value is a *view* into a Tape — it doesn't own memory.

pub const Value = union(enum) {
    null_val,
    bool_val: bool,
    int: i64,
    float: f64,
    /// Slice into the Tape's string_buf.
    string: []const u8,
    /// Out-of-range numeric literal (overflow or underflow for f64).
    /// Stores the normalized canonical form, e.g. "9E+999999999".
    /// Backed by the VM's compiled string_buf; never owned by Value.
    big_number: []const u8,
    /// A sub-range of Tape entries representing an object or array.
    /// Consumer can iterate or re-encode from these bounds.
    object: TapeSpan,
    array: TapeSpan,

    pub const TapeSpan = struct {
        /// Pointer back to the originating tape.
        tape: *const Tape,
        /// Start index (the *_start entry).
        start: u32,
        /// One-past-end index (entry after *_end).
        end: u32,
    };
};

// ─── Runtime Tape ─────────────────────────────────────────────────────────────
/// Mutable tape for constructing objects/arrays at query time.
/// Used by VM to build objects from {k: v} syntax.
pub const RuntimeTape = struct {
    entries: std.ArrayList(Tape.Entry),
    string_buf: std.ArrayList(u8),
    /// Persistent view that TapeSpan pointers reference. Auto-updated by
    /// appendEntry/internString so it always reflects the current backing
    /// buffer — eliminates stale-pointer bugs after ArrayList reallocations.
    view: Tape,

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!RuntimeTape {
        var rt_tape: RuntimeTape = .{
            .entries = std.ArrayList(Tape.Entry){},
            .string_buf = std.ArrayList(u8){},
            .view = .{ .entries = &.{}, .string_buf = &.{} },
        };
        // Pre-allocate capacity for typical object construction
        try rt_tape.entries.ensureTotalCapacity(allocator, 256);
        try rt_tape.string_buf.ensureTotalCapacity(allocator, 4096);
        rt_tape.view = .{
            .entries = rt_tape.entries.items,
            .string_buf = rt_tape.string_buf.items,
        };
        return rt_tape;
    }

    pub fn deinit(self: *RuntimeTape, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.string_buf.deinit(allocator);
    }

    /// Intern a string and return its reference.
    pub fn internString(self: *RuntimeTape, allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}!Tape.StringRef {
        const offset = @as(u32, @intCast(self.string_buf.items.len));
        try self.string_buf.appendSlice(allocator, s);
        self.view.string_buf = self.string_buf.items;
        return Tape.StringRef{
            .offset = offset,
            .len = @as(u32, @intCast(s.len)),
        };
    }

    /// Max entries in a runtime tape. Prevents quadratic blowup from deeply
    /// nested constructions like `reduce range(N) as $_ ([];[.])`.
    pub const max_entries = 4 * 1024 * 1024; // ~4M entries ≈ ~64 MB

    /// Append an entry and return its index.
    pub fn appendEntry(self: *RuntimeTape, allocator: std.mem.Allocator, entry: Tape.Entry) error{OutOfMemory}!u32 {
        if (self.entries.items.len >= max_entries) return error.OutOfMemory;
        const idx = @as(u32, @intCast(self.entries.items.len));
        try self.entries.append(allocator, entry);
        self.view.entries = self.entries.items;
        return idx;
    }

    /// Get immutable view of this runtime tape as a regular Tape.
    pub fn asTape(self: *const RuntimeTape) Tape {
        return .{
            .entries = self.entries.items,
            .string_buf = self.string_buf.items,
        };
    }

    /// Refresh the view after direct ArrayList manipulation (e.g.
    /// ensureUnusedCapacity). Mutation methods like appendEntry and
    /// internString call this automatically.
    pub fn refreshView(self: *RuntimeTape) void {
        self.view.entries = self.entries.items;
        self.view.string_buf = self.string_buf.items;
    }

    /// Copy all entries from a parsed tape into this runtime tape,
    /// re-interning strings and rebasing skip pointers.
    pub fn copyFrom(self: *RuntimeTape, tape: Tape, allocator: std.mem.Allocator) !void {
        try self.copySpan(tape, 0, @intCast(tape.entries.len), allocator);
    }

    /// Copy a range of entries [start, end) from a tape into this runtime tape,
    /// re-interning strings and rebasing skip pointers.
    ///
    /// Two-pass approach: first pass copies all entries linearly (O(n), no
    /// recursion, no auxiliary allocations). Second pass fixes up container
    /// skip pointers by scanning backwards from each end marker.
    pub fn copySpan(self: *RuntimeTape, tape: Tape, start: u32, end: u32, allocator: std.mem.Allocator) !void {
        const base: u32 = @intCast(self.entries.items.len);
        const count = end - start;

        // Pass 1: copy every entry, re-interning strings. Container skips are
        // left as their original source-relative values (fixed up in pass 2).
        var pos = start;
        while (pos < end) {
            const entry = tape.entries[pos];
            switch (entry.tag) {
                .key, .string, .big_number => {
                    const str = tape.getString(entry.payload.string);
                    const new_ref = try self.internString(allocator, str);
                    _ = try self.appendEntry(allocator, .{
                        .tag = entry.tag,
                        .payload = .{ .string = new_ref },
                    });
                },
                else => {
                    _ = try self.appendEntry(allocator, entry);
                },
            }
            pos += 1;
        }

        // Pass 2: fix up container skip pointers. For each entry in the copied
        // range, translate the source-tape skip to a runtime-tape skip.
        const items = self.entries.items;
        var i: u32 = base;
        while (i < base + count) : (i += 1) {
            switch (items[i].tag) {
                .object_start, .array_start => {
                    // Original skip pointed into source tape; translate to
                    // runtime tape: new_skip = base + (orig_skip - start).
                    const orig_skip = items[i].payload.skip;
                    items[i].payload.skip = base + (orig_skip - start);
                },
                else => {},
            }
        }
    }
};

// ─── Builtin IDs ─────────────────────────────────────────────────────────────
/// Identifies a built-in function called via the `call_builtin` opcode.
/// The numeric values are stable — do not reorder.
pub const BuiltinId = enum(u16) {
    length,
    keys,
    keys_unsorted,
    values,
    has,
    in_,
    type_,
    empty,
    tostring,
    tonumber,
    error_,
    add,
    range,
    range2,
    range3,
    sort,
    sort_by,
    group_by,
    reverse,
    flatten,
    flatten_n,
    min,
    max,
    min_by,
    max_by,
    to_entries,
    from_entries,
    any,
    all,
    contains,
    inside,
    del,
    indices,
    index_,
    rindex,
    unique,
    unique_by,
    format_text,
    format_json,
    format_csv,
    format_tsv,
    format_html,
    format_uri,
    format_urid,
    format_sh,
    format_base64,
    format_base64d,
    // Generator variants: take arrays of values and produce flat result arrays
    range1_gen, // range([n1,n2,...]) — apply range to each, concatenate results
    range2_gen, // range([from1,from2,...];[to1,to2,...]) — Cartesian product
    range3_gen, // range([from1,...];[to1,...];[by1,...]) — Cartesian product
    limit_gen, // limit([n1,n2,...]; f_collected_array)

    // Path algebra builtins
    getpath, // getpath(PATH) — retrieve value at path
    setpath, // setpath(PATH; VALUE) — set value at path
    delpaths, // delpaths(PATHS) — delete multiple paths
    paths, // paths — enumerate all paths (generator)
    leaf_paths, // leaf_paths — enumerate leaf paths (generator)
    recurse, // .. — recursive descent (generator)

    // Math builtins (zero-arg, operate on current value)
    abs, // absolute value: int→int, float→float
    floor_, // floor: float→int, int→int
    ceil_, // ceil: float→int, int→int
    round_, // round: float→int (half away from zero), int→int
    sqrt_, // square root: returns float
    fabs_, // abs but always returns float
    nan_, // returns NaN (ignores input)
    infinite_, // returns positive infinity (ignores input)
    isinfinite_, // true if input is infinite
    isnan_, // true if input is NaN
    isnormal_, // true if input is a normal number
    have_decnum_, // always false — zq uses f64, not jq's decimal numbers
    exp_, // e^x
    exp2_, // 2^x
    exp10_, // 10^x
    log_, // natural log
    log2_, // log base 2
    log10_, // log base 10
    cbrt_, // cube root
    sin_, // sine
    cos_, // cosine
    tan_, // tangent
    asin_, // arc sine
    acos_, // arc cosine
    atan_, // arc tangent
    rint_, // round to nearest int (return float)
    nearbyint_, // round to nearest int (return float)
    trunc_, // truncate toward zero (return float)
    significand_, // floating point significand
    logb_, // floating point exponent
    j0_, // Bessel function of first kind, order 0
    j1_, // Bessel function of first kind, order 1
    lgamma_, // log-gamma function
    tgamma_, // gamma function

    // Two-arg math builtins
    pow_, // pow(a;b) — a^b
    atan2_, // atan2(y;x)
    remainder_, // IEEE remainder
    hypot_, // hypotenuse
    scalb_, // x * 2^n
    scalbln_, // same as scalb
    ldexp_, // x * 2^n
    fma_, // fused multiply-add (three args)
    drem_, // same as remainder

    // Type-check filter builtins (zero-arg)
    arrays_, // select arrays only
    objects_, // select objects only
    strings_, // select strings only
    numbers_, // select numbers only
    booleans_, // select booleans only
    nulls_, // select nulls only
    values_, // select non-null values
    scalars_, // select non-array, non-object values
    normals_, // select normal values
    iterables_, // select arrays and objects

    // String builtins
    ascii_downcase, // lowercase ASCII
    ascii_upcase, // uppercase ASCII
    ascii_, // ASCII value of char / char from int
    explode_, // string to array of codepoints
    implode_, // array of codepoints to string

    // JSON builtins
    tojson, // serialize to JSON string
    fromjson, // parse JSON string to value

    // String builtins (arg-taking)
    split_, // split(sep) — split string by separator
    join_, // join(sep) — join array with separator
    startswith_, // startswith(str) — test prefix
    endswith_, // endswith(str) — test suffix
    ltrimstr_, // ltrimstr(str) — remove prefix
    rtrimstr_, // rtrimstr(str) — remove suffix
    trimstr_, // trimstr(str) — remove prefix and suffix
    test_, // test(regex) — boolean match
    match_, // match(regex) — full match details object
    match_g_, // match(regex; "g") — generator: yields a match object per occurrence
    sub_, // sub(regex; replacement) — replace first
    gsub_, // gsub(regex; replacement) — replace all
    capture_, // capture(regex) — object of named captures
    scan_, // scan(regex) — generator of matches (string or array of captures)
    splits_, // splits(regex) — generator yielding segments between matches

    // Array utility builtins
    transpose_, // transpose — transpose array of arrays (zero-arg)
    bsearch_, // bsearch(x) — binary search in sorted array (one-arg)

    // Misc builtins
    not_, // logical negation
    builtins_, // list all builtin names
    debug_, // pass through (debug to stderr)
    stderr_, // same as debug
    input_, // read from stdin (produce empty)
    inputs_, // read all from stdin (produce empty)
    env_, // environment variables object
    halt_, // exit
    halt_error_, // exit with error
    map_values_, // map_values(f)
    isempty_, // isempty(f) — true if f produces no output
    first_, // first(expr)
    last_, // last(expr)

    // Date/time builtins
    now_, // now — current Unix timestamp as float (sub-second precision)
    gmtime_, // gmtime — Unix timestamp -> broken-down time array [year, month(0-based), mday, hour, min, sec, wday, yday]
    mktime_, // mktime — broken-down time array -> Unix timestamp
    strftime_, // strftime(fmt) — format broken-down time (or timestamp) to string
    strptime_, // strptime(fmt) — parse string to broken-down time array
    strflocaltime_, // strflocaltime(fmt) — like strftime but local time (UTC in zq, no TZ support)
    todate_, // todate — shorthand for strftime("%Y-%m-%dT%H:%M:%SZ")
    fromdate_, // fromdate — shorthand for strptime("%Y-%m-%dT%H:%M:%SZ") | mktime
    todateiso8601_, // todateiso8601 — alias for todate
    fromdateiso8601_, // fromdateiso8601 — alias for fromdate

    // Conversion / inspection builtins (zero-arg)
    toboolean, // toboolean — parse string to bool or pass through bool
    utf8bytelength, // utf8bytelength — byte length of a string

    // Trim builtins (zero-arg)
    trim_, // trim — trim Unicode whitespace from both ends
    ltrim_, // ltrim — trim Unicode whitespace from left
    rtrim_, // rtrim — trim Unicode whitespace from right

    // Module-system builtins (Phase 2b)
    modulemeta_, // modulemeta — input string is a module relpath; returns metadata object

    const JqEntry = struct { name: []const u8, arity: u8 };

    /// Return the jq-visible "name/arity" entry for this builtin, or null for
    /// internal variants that should not appear in `builtins` output.
    pub fn jqEntry(comptime self: BuiltinId) ?JqEntry {
        // Internal generator variants — not user-facing. `match_g_` dispatches
        // through the ordinary `match(re; flags)` surface when flags contain
        // `g`; it does not get its own builtins-list entry.
        switch (self) {
            .range1_gen, .range2_gen, .range3_gen, .limit_gen, .match_g_ => return null,
            else => {},
        }
        return .{ .name = self.jqBaseName(), .arity = self.jqArity() };
    }

    /// Derive the jq-visible base name from the enum tag at comptime.
    fn jqBaseName(comptime self: BuiltinId) []const u8 {
        @setEvalBranchQuota(10_000);
        const tag = @tagName(self);

        // Arity-suffixed overloads → return base name
        if (std.mem.eql(u8, tag, "range2") or std.mem.eql(u8, tag, "range3")) return "range";
        if (std.mem.eql(u8, tag, "flatten_n")) return "flatten";

        // format_ prefix → @name
        if (tag.len > 7 and std.mem.eql(u8, tag[0..7], "format_")) {
            return "@" ++ tag[7..];
        }

        // Trailing underscore (Zig keyword avoidance) → strip it
        if (tag.len > 1 and tag[tag.len - 1] == '_' and tag[tag.len - 2] != '_') {
            return tag[0 .. tag.len - 1];
        }

        return tag;
    }

    /// Return the jq arity (number of explicit arguments, excluding input).
    /// Exhaustive switch — the compiler enforces completeness when new variants are added.
    fn jqArity(comptime self: BuiltinId) u8 {
        return switch (self) {
            // 0-arity: operate on input only
            .length,
            .keys,
            .keys_unsorted,
            .values,
            .empty,
            .type_,
            .tostring,
            .tonumber,
            .add,
            .sort,
            .reverse,
            .min,
            .max,
            .to_entries,
            .from_entries,
            .any,
            .all,
            .indices,
            .unique,
            .tojson,
            .fromjson,
            .not_,
            .builtins_,
            .debug_,
            .stderr_,
            .input_,
            .inputs_,
            .env_,
            .halt_,
            .paths,
            .leaf_paths,
            .recurse,
            .abs,
            .floor_,
            .ceil_,
            .round_,
            .sqrt_,
            .fabs_,
            .nan_,
            .infinite_,
            .isinfinite_,
            .isnan_,
            .isnormal_,
            .have_decnum_,
            .exp_,
            .exp2_,
            .exp10_,
            .log_,
            .log2_,
            .log10_,
            .cbrt_,
            .sin_,
            .cos_,
            .tan_,
            .asin_,
            .acos_,
            .atan_,
            .rint_,
            .nearbyint_,
            .trunc_,
            .significand_,
            .logb_,
            .j0_,
            .j1_,
            .lgamma_,
            .tgamma_,
            .arrays_,
            .objects_,
            .strings_,
            .numbers_,
            .booleans_,
            .nulls_,
            .values_,
            .scalars_,
            .normals_,
            .iterables_,
            .ascii_downcase,
            .ascii_upcase,
            .ascii_,
            .explode_,
            .implode_,
            .transpose_,
            .flatten,
            .format_text,
            .format_json,
            .format_csv,
            .format_tsv,
            .format_html,
            .format_uri,
            .format_urid,
            .format_sh,
            .format_base64,
            .format_base64d,
            .error_,
            .now_,
            .gmtime_,
            .mktime_,
            .todate_,
            .fromdate_,
            .todateiso8601_,
            .fromdateiso8601_,
            .toboolean,
            .utf8bytelength,
            .trim_,
            .ltrim_,
            .rtrim_,
            .modulemeta_,
            => 0,

            // 1-arity: one explicit argument
            .has,
            .in_,
            .sort_by,
            .group_by,
            .min_by,
            .max_by,
            .unique_by,
            .del,
            .contains,
            .inside,
            .index_,
            .rindex,
            .getpath,
            .delpaths,
            .flatten_n,
            .split_,
            .join_,
            .startswith_,
            .endswith_,
            .ltrimstr_,
            .rtrimstr_,
            .trimstr_,
            .test_,
            .match_,
            .capture_,
            .scan_,
            .splits_,
            .bsearch_,
            .map_values_,
            .isempty_,
            .first_,
            .last_,
            .halt_error_,
            .range,
            .strftime_,
            .strptime_,
            .strflocaltime_,
            => 1,

            // 2-arity: two explicit arguments
            .setpath,
            .sub_,
            .gsub_,
            .pow_,
            .atan2_,
            .remainder_,
            .hypot_,
            .scalb_,
            .scalbln_,
            .ldexp_,
            .drem_,
            .range2,
            => 2,

            // 3-arity
            .fma_, .range3 => 3,

            // Internal generator variants — handled by jqEntry returning null
            .range1_gen, .range2_gen, .range3_gen, .limit_gen, .match_g_ => unreachable,
        };
    }

    /// Return the number of jq-visible builtin entries (including arity overloads).
    pub fn jqBuiltinCount() comptime_int {
        var count: comptime_int = 0;
        for (std.enums.values(BuiltinId)) |id| {
            if (comptime id.jqEntry() != null) count += 1;
        }
        return count;
    }
};

// ─── Regex opcode payload packing ────────────────────────────────────────────
//
// Regex-taking builtins (`test_`, `match_`, `sub_`, `gsub_`, `capture_`,
// `scan_`, `splits_`, `match_g_`) piggy-back on `call_builtin`'s i64 operand.
// Bit layout (LSB→MSB):
//   bits [ 0..16)  BuiltinId
//   bits [16..48)  RegexPool index (or REGEX_POOL_DYNAMIC sentinel)
//   bit  48        jq `n` flag — "ignore empty (zero-width) matches".
//                  Parsed at compile time; threaded through to the handler.
// Remaining high bits are reserved for future per-pattern flag bits.
//
// Single source of truth: compiler packs via `packRegexBuiltinOperand`, the
// VM unpacks via `regexPoolIndexOf` / `builtinIdOf` / `regexBuiltinNFlagOf`.
// No other code inspects the bit layout.

/// Sentinel in the pool-index slot meaning "compile at runtime" — the pattern
/// argument was not a string literal so no entry was interned at compile time.
/// Phase D's VM wires this to the per-worker `LruCache`.
pub const REGEX_POOL_DYNAMIC: u32 = std.math.maxInt(u32);

/// Bit position of the jq `n` flag in the `call_builtin` operand.
const REGEX_N_FLAG_BIT_POS: u6 = 48;
const REGEX_N_FLAG_BIT: u64 = @as(u64, 1) << REGEX_N_FLAG_BIT_POS;

/// Pack a `(BuiltinId, regex_pool_index)` pair into a `call_builtin` operand.
/// Non-regex builtins should pass `REGEX_POOL_DYNAMIC` — it is harmless because
/// they never inspect the upper bits.
pub fn packRegexBuiltinOperand(bid: BuiltinId, regex_pool_index: u32) i64 {
    return packRegexBuiltinOperandFlags(bid, regex_pool_index, false);
}

/// Variant of `packRegexBuiltinOperand` that also records the jq `n` flag in
/// bit 48. Only meaningful for regex-taking builtins.
pub fn packRegexBuiltinOperandFlags(
    bid: BuiltinId,
    regex_pool_index: u32,
    n_flag: bool,
) i64 {
    const low: u64 = @intFromEnum(bid);
    const high: u64 = @as(u64, regex_pool_index) << 16;
    const n_bits: u64 = if (n_flag) REGEX_N_FLAG_BIT else 0;
    return @bitCast(low | high | n_bits);
}

/// Extract the `BuiltinId` from any `call_builtin` operand. Safe for every
/// builtin regardless of whether regex metadata is packed.
pub fn builtinIdOf(operand_index: i64) BuiltinId {
    const bits: u64 = @bitCast(operand_index);
    return @enumFromInt(@as(u16, @truncate(bits)));
}

/// Extract the regex-pool index from a `call_builtin` operand. Only meaningful
/// for regex-taking builtins; others return `REGEX_POOL_DYNAMIC` (harmless).
pub fn regexPoolIndexOf(operand_index: i64) u32 {
    const bits: u64 = @bitCast(operand_index);
    return @truncate(bits >> 16);
}

/// Extract the jq `n` flag from a regex-builtin operand. Returns `false` for
/// any non-regex builtin (they never set the bit).
pub fn regexBuiltinNFlagOf(operand_index: i64) bool {
    const bits: u64 = @bitCast(operand_index);
    return (bits & REGEX_N_FLAG_BIT) != 0;
}

// ─── Slice Args ──────────────────────────────────────────────────────────────
/// Operands for the `slice` instruction (.[from:to]).
/// Uses i32 to keep @sizeOf(SliceArgs) = 12, within the 16-byte Operand union slot.
/// Absent bound: has_from/has_to = false; the corresponding from/to field is 0 (ignored).
pub const SliceArgs = extern struct {
    from: i32 = 0,
    to: i32 = 0,
    has_from: bool = false,
    has_to: bool = false,
    /// Slice-computed-only: the corresponding bound is provided via
    /// `value_stack` rather than the `from` / `to` literal fields.
    /// Always `false` for the legacy `slice` opcode. The two extra
    /// bytes fit within the existing 12-byte aligned SliceArgs slot
    /// without growing the `Operand` union.
    has_from_expr: bool = false,
    has_to_expr: bool = false,
};

// ─── Function Definition ─────────────────────────────────────────────────────

/// Function definition stored in compiled query.
pub const FunctionDef = struct {
    body_ip: u32,
    body_end: u32,
    param_count: u8,
};

// ─── Instruction ─────────────────────────────────────────────────────────────
// Bytecode emitted by Query.compile(), executed against a Tape.

pub const Instruction = extern struct {
    op: Op,
    operand: Operand,

    pub const Op = enum(u8) {
        /// Descend into an object key. operand.string = key name.
        load_key,
        /// Descend into an array index. operand.index = position.
        load_index,
        /// Computed descent: pop if_stack for base; pop value_stack (or use current)
        /// for key/index. String key → object field; integer → array element.
        load_computed,
        /// Fused multi-level path descent. operand.string = "a.b.c".
        load_path,
        /// Pipe: pop current, feed to next stage.
        pipe,
        /// Identity: no-op pass-through (`.`).
        identity,
        /// Push literal boolean. operand.bool = value.
        push_bool,
        /// Push literal integer. operand.int = value.
        push_int,
        /// Push literal float. operand.float = value.
        push_float,
        /// Add: pop 2 values, push sum.
        add,
        /// Subtract: pop 2 values, push difference.
        sub,
        /// Multiply: pop 2 values, push product.
        mul,
        /// Divide: pop 2 values, push quotient.
        div,
        /// Modulo: pop 2 values, push remainder.
        mod,
        /// Equal: pop 2 values, push boolean.
        eq,
        /// Not equal: pop 2 values, push boolean.
        ne,
        /// Less than: pop 2 values, push boolean.
        lt,
        /// Less than or equal: pop 2 values, push boolean.
        le,
        /// Greater than: pop 2 values, push boolean.
        gt,
        /// Greater than or equal: pop 2 values, push boolean.
        ge,
        /// Logical and: pop 2 values, push boolean (short-circuit).
        and_op,
        /// Logical or: pop 2 values, push boolean (short-circuit).
        or_op,
        /// Logical not: pop 1 value, push boolean.
        not,
        /// Negate: pop 1 numeric value, push negated value (int→int, float→float).
        negate,

        // Variable operations
        /// Capture top of stack into variable. operand.index = variable id.
        capture_variable,
        /// Load variable value onto stack. operand.index = variable id.
        load_variable,
        /// Pop variable from scope. operand.index = variable id.
        pop_variable,

        // Function operations
        /// Define function at compile time. operand.index = function id.
        def_function,
        /// Call function by name. operand.index = function id.
        call_function,
        /// Return from a function call. Pops the call stack and returns to caller.
        return_function,
        /// Placeholder for a filter argument reference inside a function body.
        /// During inline expansion, replaced with the caller's argument instructions.
        /// operand.index = parameter index within the function.
        call_filter_arg,

        // Object construction operations
        /// Begin object construction frame.
        object_construct_start,
        /// Add key-value pair to current object.
        object_key,
        /// Complete object construction, push to stack.
        object_construct_end,

        // Literal values
        /// Push null value to stack.
        push_null,
        /// Push string value to stack. operand.string = string value.
        push_string,
        /// Push out-of-range numeric literal. operand.str_ref = canonical text.
        push_big_number,
        /// Push current value to stack.
        push_current,

        // Conditional branching
        /// Unconditional jump. operand.index = target instruction index.
        jump,
        /// Pop value stack (or use current); if falsy jump to operand.index.
        /// jq truthiness: only `false` and `null` are falsy.
        jump_if_false,
        /// Push current value onto the if-input stack (saves input for branch restoration).
        save_input,
        /// Pop from the if-input stack and set current (restores input for a branch).
        restore_input,

        // Array construction operations
        /// Begin collecting generator outputs into an array.
        /// operand.index = IP of the matching array_collect_end instruction.
        array_collect_start,
        /// Finalize collection: pop the collect frame and push the assembled array
        /// onto the value stack.
        array_collect_end,

        // Builtin dispatch
        /// Call a built-in function. operand.index = BuiltinId (as i64).
        call_builtin,

        // Slicing
        /// Extract a sub-array or sub-string. operand.slice_args = bounds.
        /// Handles .[from:to], .[from:], .[:to], .[:] patterns.
        /// Negative indices count from the end; bounds are clamped to [0, length].
        slice,
        /// Computed-bound slice (`.[expr1:expr2]` where either bound is
        /// an arbitrary expression rather than an integer literal).
        /// operand.slice_args carries only the has_from / has_to flags;
        /// the integer fields are unused. The base value is popped from
        /// `if_stack` (saved by the surrounding capture pipeline before
        /// the bound expressions are evaluated). The bound values are
        /// popped from `value_stack` in reverse push order: `to` if
        /// has_to, then `from` if has_from. Each bound must be an
        /// integer (jq: float-truncate; null is treated as the literal
        /// default — 0 for `from`, length for `to`).
        slice_computed,

        // Update assignment (|=, +=, -=, *=, /=, %=, //=)
        /// Navigate to object field for update: sets current to field value without
        /// pushing to value_stack. operand.string = key name.
        navigate_key,
        /// Navigate to array element for update: sets current to element value without
        /// pushing to value_stack. operand.index = element index.
        navigate_index,
        /// Update object field: pops new_val from value_stack (or uses current if empty),
        /// pops base object from if_stack, reconstructs object with field replaced.
        /// Pushes modified object to value_stack; sets current to it.
        update_key,
        /// Update array element: pops new_val from value_stack (or uses current if empty),
        /// pops base array from if_stack, reconstructs array with element replaced.
        /// Pushes modified array to value_stack; sets current to it.
        update_index,

        // Label/break (non-local exit)
        /// Begin a label scope. Generates a unique break token, pushes it to value_stack
        /// as an int, and pushes a LabelFrame onto the label_stack.
        /// operand.index = variable id for the label token.
        label_begin,
        /// End of label scope. No-op; label frame cleanup is handled by handleBreak or reset.
        label_end,
        /// Trigger a non-local exit. Loads the break token from variable, sets pending_break_token.
        break_op,

        /// Begin a limit(n;f) scope. Pops n from value_stack.
        /// If n <= 0: n==0 produces empty, n<0 raises error. Jumps to operand.index.
        /// Otherwise pushes LimitFrame with counter.
        limit_start,
        /// End of limit scope. Pops LimitFrame.
        limit_end,

        /// Begin a skip(n;f) scope. Pops n from value_stack.
        /// If n < 0: raises "skip doesn't support negative count".
        /// n==0 passes through all outputs.
        /// Otherwise pushes SkipFrame that counts and suppresses first n outputs.
        /// operand.index = exit_ip (backpatched).
        skip_start,
        /// Like skip_start but for nth(n;f) — error message says
        /// "nth doesn't support negative indices" on n < 0.
        nth_start,
        /// End of skip/nth scope. Pops SkipFrame.
        skip_end,

        /// Begin a walk(f) scope. operand.index = IP past walk_end (exit_ip).
        /// Recursively walks children (arrays/objects) bottom-up, applying the
        /// body f at each level. Only the first output of f is used when rebuilding
        /// children; at the top level, f can produce multiple outputs (generators).
        walk_start,
        /// End of walk(f) scope. The VM jumps here after executing the body.
        walk_end,

        /// Begin a repeat(f) scope — jq's `def repeat(exp): def _r: exp, _r; _r;`.
        /// operand.index = exit_ip (IP of the matching repeat_end + 1).
        /// Pushes a RepeatFrame fork that captures the current input. On
        /// backtrack into the frame (i.e. when the body's generator chain
        /// exhausts), the saved input is restored as `current` and execution
        /// resumes at body_start_ip — yielding the body's outputs again, ad
        /// infinitum. Termination is delegated to an enclosing `limit_start`
        /// counter (matching jq's `limit(N; repeat(f))` idiom); without one
        /// the loop runs forever, matching jq.
        repeat_start,
        /// End of repeat(f) scope. Reachable only when an enclosing scope
        /// (typically `limit_start`) has truncated the fork stack and shifts
        /// `ip` past the repeat frame; otherwise the body's trailing
        /// `backtrack` re-enters the body via the RepeatFrame instead.
        /// Pops any matching RepeatFrame still on the fork stack.
        repeat_end,

        // Fork stack opcodes (unified backtracking)
        /// Push a forkpoint for backtracking. operand.index = backtrack target IP.
        fork,
        /// Backtrack: pop the most recent forkpoint and resume its alternative.
        backtrack,
        /// Iterate: push each element of array/object via fork stack.
        each,
        /// Yield a value to the caller (or buffer in collect mode).
        yield_output,
        /// Push a try-handler forkpoint. operand.index = catch handler IP (0 = suppress).
        fork_try,
        /// Push an alternative-handler forkpoint. operand.index = right-side IP.
        /// Like fork_try but also fires on exhaustion (all outputs falsy).
        fork_alt,
        /// Remove the nearest try_handler or alt_handler from the fork stack.
        pop_try,

        // Path tracking (for path(f) builtin)
        /// Enter path-tracking mode. operand.index = end IP (path_end).
        /// Pushes a PathFrame onto path_stack. While active, load_key/load_index/
        /// load_path append path components instead of only doing value lookup.
        path_begin,
        /// Exit path-tracking mode. Pops PathFrame, builds path array from tracked
        /// components and pushes it to value_stack.
        path_end,
        /// Mark the next descent ops as meta-level (e.g. evaluating the inner
        /// key expression of a computed-index `EXPR[KEY]`). Sets the topmost
        /// `PathFrame.skip_components_for_computed_key` flag so intermediate
        /// `load_key`/`load_index` ops do NOT append components to the outer
        /// path. The flag is cleared by the matching `load_computed` that
        /// consumes the key (which then records the actual key as a single
        /// path component). No-op when the path stack is empty (i.e. no
        /// enclosing `path(f)` / path-assign frame).
        mark_computed_key,
        /// Suspend path recording on the innermost `PathFrame`. While
        /// suspended, descent ops do not append components and path-breaking
        /// ops do not set `path_broken`. Used to evaluate the LHS of an
        /// `EXPR1 as $v | EXPR2` binding in value context: jq treats the
        /// binding's LHS as outside the surrounding `path(f)` (the path is
        /// `path(EXPR2)` only). No-op when no path frame is active.
        path_suspend,
        /// Resume path recording on the innermost `PathFrame`, clearing the
        /// suspension set by `path_suspend`. No-op when no path frame is
        /// active. Paired 1:1 with `path_suspend` — emitter must guarantee
        /// matching boundaries (no nesting across forks).
        path_resume,

        /// Whether this opcode's `operand.index` is an instruction-pointer that
        /// must be unconditionally rebased when instructions are shifted.
        ///
        /// Opcodes that use 0 as an "unpatched / no-handler" sentinel
        /// (`fork_try`, `fork_alt`, `label_begin`) are NOT included —
        /// they require a conditional check and are handled via `hasSentinelIpOperand`.
        pub fn hasIpOperand(self: Op) bool {
            return switch (self) {
                .jump,
                .jump_if_false,
                .array_collect_start,
                .limit_start,
                .skip_start,
                .nth_start,
                .walk_start,
                .repeat_start,
                .path_begin,
                .fork,
                .call_function,
                => true,
                else => false,
            };
        }

        /// Whether this opcode's `operand.index` is an instruction-pointer that
        /// uses 0 as a sentinel value (meaning "unpatched" or "no handler").
        /// These IPs must only be rebased when their value is > 0.
        pub fn hasSentinelIpOperand(self: Op) bool {
            return switch (self) {
                .fork_try,
                .fork_alt,
                .label_begin,
                => true,
                else => false,
            };
        }

        /// Whether this opcode invalidates an enclosing `path(f)` expression
        /// when it fires with an active path frame.
        ///
        /// jq requires that `path(f)` bodies describe a path — every step
        /// traverses into the input. An opcode that produces a value without
        /// recording a corresponding path component (arithmetic, comparison,
        /// literals, constructors) breaks that invariant, and jq raises
        /// "Invalid path expression with result <tojson>". The VM uses this
        /// predicate to mark the innermost `PathFrame` broken at fire time;
        /// `path_end` consults the flag to raise the user-visible error.
        ///
        /// Note: the flag is cleared when `clearsPathBroken` fires, so
        /// intermediate literals/arithmetic used to compute indexes or
        /// predicates (e.g. `.[0,1]`, `select(.>3)`) do not taint the outer
        /// path, matching jq's path-value tracking.
        ///
        /// Exhaustive switch so a new opcode fails to compile until classified.
        pub fn breaksPath(self: Op) bool {
            return switch (self) {
                // ── Path-preserving: descend / read / control flow ─────────
                .load_key,
                .load_index,
                .load_computed,
                .load_path,
                .slice,
                .slice_computed,
                .navigate_key,
                .navigate_index,
                .pipe,
                .identity,
                .push_current,
                .capture_variable,
                .pop_variable,
                // Variable load restores the prior input (often the compiler's
                // own scaffolding for `.[K]` generators — internal uses must
                // not break the path). Accepted gap: user-written
                // `$x | path($x.a)` won't raise, matching a subset of jq.
                .load_variable,
                .def_function,
                .call_function,
                .return_function,
                .call_filter_arg,
                .jump,
                .jump_if_false,
                .save_input,
                .restore_input,
                .label_begin,
                .label_end,
                .break_op,
                .limit_start,
                .limit_end,
                .skip_start,
                .nth_start,
                .skip_end,
                .walk_start,
                .walk_end,
                .repeat_start,
                .repeat_end,
                .fork,
                .backtrack,
                .each,
                .yield_output,
                .fork_try,
                .fork_alt,
                .pop_try,
                .path_begin,
                .path_end,
                .mark_computed_key,
                .path_suspend,
                .path_resume,
                => false,

                // ── Path-breaking: produce a value unrelated to the input ──
                // Literals replace current with a synthesized value.
                .push_bool,
                .push_int,
                .push_float,
                .push_null,
                .push_string,
                .push_big_number,
                // Arithmetic / comparison / logic produce derived values.
                .add,
                .sub,
                .mul,
                .div,
                .mod,
                .negate,
                .eq,
                .ne,
                .lt,
                .le,
                .gt,
                .ge,
                .and_op,
                .or_op,
                .not,
                // Constructors produce new containers.
                .object_construct_start,
                .object_key,
                .object_construct_end,
                .array_collect_start,
                .array_collect_end,
                // Update ops rebuild the input — not a path descent.
                .update_key,
                .update_index,
                // Builtins default to breaking. Specific whitelist entries
                // (e.g. `paths`, `leaf_paths`) could relax later.
                .call_builtin,
                => true,
            };
        }

        /// Whether this opcode clears the innermost `PathFrame.path_broken`
        /// flag after firing. Fires AFTER the op has recorded its path
        /// component (for descent ops) or restored a saved input (for
        /// `restore_input`), so prior scratch values are discarded.
        ///
        /// This lets internal literal/arithmetic (index computation in
        /// `.[0,1]`, predicates in `select(.>3)`) taint the flag briefly
        /// without breaking the outer `path(f)` — jq's path-value semantics
        /// only fail when the *final* body output isn't a path descent.
        pub fn clearsPathBroken(self: Op) bool {
            return switch (self) {
                // Path-recording descent ops: after consuming the (possibly
                // broken) key/index and appending a component, the broken
                // trail is absorbed into a legitimate path step.
                .load_key,
                .load_index,
                .load_computed,
                .load_path,
                .navigate_key,
                .navigate_index,
                .slice,
                .slice_computed,
                // Restoring a saved input discards any derived value that
                // only existed inside a predicate / if-branch scope.
                .restore_input,
                => true,
                else => false,
            };
        }
    };

    pub const Operand = extern union {
        str_ref: Tape.StringRef,
        index: i64,
        bool: bool,
        int: i64,
        float: f64,
        none: void,
        slice_args: SliceArgs,
    };
};

// ─── Output Format ───────────────────────────────────────────────────────────

pub const Format = enum {
    /// Pretty-printed JSON (default for TTY).
    pretty,
    /// Compact single-line JSON.
    compact,
    /// Raw string output (no quotes).
    raw,
    /// One JSON value per line (JSONL).
    jsonl,
    /// Raw output with no trailing newline (--join-output / -j).
    join,
};

// ─── Float Formatting ────────────────────────────────────────────────────────
// Single source of truth for jq-compatible float formatting.
// Implements jq's jvp_dtoa_fmt algorithm: uses Ryu shortest representation,
// then selects between decimal and scientific notation based on jq's thresholds.

/// Result of formatJqFloat — holds the formatted string and its backing buffer.
pub const FormattedFloat = struct {
    buf: [64]u8,
    len: usize,

    pub fn slice(self: *const FormattedFloat) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Format a f64 for JSON output using jq's non-decnum formatting rules.
///
/// Matches jq's `jvp_dtoa_fmt` (jv_dtoa.c) exactly:
///   1. NaN → "null" (jq: jv_dump_term emits null for NaN).
///   2. ±Inf → clamp to ±DBL_MAX, then format normally (jq: jv_print.c clamps
///      inf to DBL_MAX before calling dtoa_fmt; so 1E+1000 → 1.7976931348623157e+308).
///   3. Otherwise, Ryu shortest representation gives digits + decpt, then:
///        - decpt <= -4 or decpt > nd + 15 → scientific notation
///        - decpt <= 0                     → decimal with leading zeros (0.000…digits)
///        - else                           → decimal, point inserted at decpt
///
/// Note: jq's dtoa_fmt has NO integer-valued fast path. Values like 1e17 must
/// hit the scientific-notation branch (decpt=18 > nd+15=16), otherwise
/// `1 / 1e-17` would print as `100000000000000000` instead of jq's `1e+17`.
pub fn formatJqFloat(f: f64) FormattedFloat {
    var result: FormattedFloat = .{ .buf = undefined, .len = 0 };

    // NaN → "null"
    if (std.math.isNan(f)) {
        @memcpy(result.buf[0..4], "null");
        result.len = 4;
        return result;
    }

    // ±0 → "0" (jq's IGNORE_ZERO_SIGN in jvp_dtoa_fmt suppresses -0).
    if (f == 0.0) {
        result.buf[0] = '0';
        result.len = 1;
        return result;
    }

    // Inf → clamp to ±DBL_MAX (matches jq jv_print.c behaviour).
    // DBL_MAX = 0x1.fffffffffffffp+1023 = 1.7976931348623157e+308.
    var fx: f64 = f;
    if (std.math.isInf(fx)) {
        fx = if (fx > 0) std.math.floatMax(f64) else -std.math.floatMax(f64);
    }

    // Use Zig's Ryu-based {e} format to get the shortest representation
    // in scientific notation: e.g. "1.05e-19", "5e-1", "1.23e5"
    var ryu_buf: [64]u8 = undefined;
    const ryu = std.fmt.bufPrint(&ryu_buf, "{e}", .{fx}) catch unreachable;

    // Parse the Ryu output to extract:
    //   - sign (if negative)
    //   - significant digits (without decimal point)
    //   - exponent value
    var pos: usize = 0;
    const is_neg = ryu[0] == '-';
    if (is_neg) pos = 1;

    // Extract significant digits and locate 'e'
    var digits: [20]u8 = undefined;
    var ndigits: usize = 0;
    while (pos < ryu.len and ryu[pos] != 'e') {
        if (ryu[pos] != '.') {
            digits[ndigits] = ryu[pos];
            ndigits += 1;
        }
        pos += 1;
    }

    // Parse exponent (after 'e')
    pos += 1; // skip 'e'
    var exp_neg = false;
    if (pos < ryu.len and ryu[pos] == '-') {
        exp_neg = true;
        pos += 1;
    }
    var exp_val: i32 = 0;
    while (pos < ryu.len) {
        exp_val = exp_val * 10 + @as(i32, ryu[pos] - '0');
        pos += 1;
    }
    if (exp_neg) exp_val = -exp_val;

    // decpt = exponent + 1 (jq's dtoa convention: digits[0].digits[1:] * 10^(decpt-1))
    const decpt: i32 = exp_val + 1;
    const nd: i32 = @intCast(ndigits);

    // Now format according to jq's jvp_dtoa_fmt rules
    var b: usize = 0;

    if (is_neg) {
        result.buf[b] = '-';
        b += 1;
    }

    if (decpt <= -4 or decpt > nd + 15) {
        // Scientific notation: d.dddde+XX or d.dddde-XX
        result.buf[b] = digits[0];
        b += 1;
        if (ndigits > 1) {
            result.buf[b] = '.';
            b += 1;
            @memcpy(result.buf[b .. b + ndigits - 1], digits[1..ndigits]);
            b += ndigits - 1;
        }
        result.buf[b] = 'e';
        b += 1;

        var edecpt: i32 = decpt - 1;
        if (edecpt < 0) {
            result.buf[b] = '-';
            b += 1;
            edecpt = -edecpt;
        } else {
            result.buf[b] = '+';
            b += 1;
        }

        // Format exponent with minimum 2 digits
        var j: i32 = 2;
        var k: i32 = 10;
        while (10 * k <= edecpt) {
            j += 1;
            k *= 10;
        }
        while (true) {
            const digit: u8 = @intCast(@divTrunc(edecpt, k));
            result.buf[b] = digit + '0';
            b += 1;
            j -= 1;
            if (j <= 0) break;
            edecpt -= @as(i32, @intCast(digit)) * k;
            edecpt *= 10;
        }
    } else if (decpt <= 0) {
        // Decimal with leading zeros: 0.000...digits
        result.buf[b] = '0';
        b += 1;
        result.buf[b] = '.';
        b += 1;
        var zeros: i32 = -decpt;
        while (zeros > 0) : (zeros -= 1) {
            result.buf[b] = '0';
            b += 1;
        }
        @memcpy(result.buf[b .. b + ndigits], digits[0..ndigits]);
        b += ndigits;
    } else {
        // Decimal: digits with point inserted at decpt position
        const dp: usize = @intCast(decpt);
        if (dp >= ndigits) {
            // All digits before decimal point, possibly trailing zeros
            @memcpy(result.buf[b .. b + ndigits], digits[0..ndigits]);
            b += ndigits;
            var trailing: usize = dp - ndigits;
            while (trailing > 0) : (trailing -= 1) {
                result.buf[b] = '0';
                b += 1;
            }
        } else {
            // Insert decimal point within digits
            @memcpy(result.buf[b .. b + dp], digits[0..dp]);
            b += dp;
            result.buf[b] = '.';
            b += 1;
            @memcpy(result.buf[b .. b + ndigits - dp], digits[dp..ndigits]);
            b += ndigits - dp;
        }
    }

    result.len = b;
    return result;
}

/// Buffer large enough to hold any normalized big-number literal.
/// Format: optional '-', up to 20 significant digits, 'E', optional '+'/'-',
/// up to 19 exponent digits → 2 + 20 + 1 + 1 + 19 = 43 chars max.
pub const BigNumberBuf = struct {
    buf: [64]u8,
    len: usize,
    pub fn slice(self: *const BigNumberBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Normalize a decimal numeric literal that is out of range for f64 (overflow
/// or underflow) into jq's canonical big-number format:
///   ['-'] significant_digit ['.' fractional_digits] 'E' ['+'/'-'] exponent
///
/// The input is a raw lexer token like "9E999999999", "0.000000001E-999999990",
/// or "9999999999E999999990".  Both 'E' and 'e' are accepted.
/// Trailing zeros in the fractional part are stripped.
/// Returns a BigNumberBuf with the normalized text.
///
/// This is the single source of truth for big-number formatting; all callers
/// (parser, output) must go through here.
pub fn normalizeBigNumber(input: []const u8) BigNumberBuf {
    var result: BigNumberBuf = .{ .buf = undefined, .len = 0 };
    var b: usize = 0;

    const src = input;
    var pos: usize = 0;

    // Optional sign
    const is_neg = pos < src.len and src[pos] == '-';
    if (is_neg) pos += 1;

    // Collect all significant digits (integer part then fractional part).
    // Track the position of the decimal point within the digit string.
    var all_digits: [64]u8 = undefined;
    var nd: usize = 0; // total digit count
    var dec_pos: i64 = 0; // position of decimal point from left (= count of integer digits)
    var seen_dot = false;

    while (pos < src.len and src[pos] != 'e' and src[pos] != 'E') {
        const c = src[pos];
        pos += 1;
        if (c == '.') {
            seen_dot = true;
            dec_pos = @intCast(nd);
        } else if (c >= '0' and c <= '9') {
            if (nd < all_digits.len) {
                all_digits[nd] = c;
                nd += 1;
            }
        }
    }
    if (!seen_dot) dec_pos = @intCast(nd);

    // Parse explicit exponent (after 'E'/'e')
    var exp_val: i64 = 0;
    var exp_neg = false;
    if (pos < src.len and (src[pos] == 'e' or src[pos] == 'E')) {
        pos += 1;
        if (pos < src.len and src[pos] == '-') {
            exp_neg = true;
            pos += 1;
        } else if (pos < src.len and src[pos] == '+') {
            pos += 1;
        }
        while (pos < src.len and src[pos] >= '0' and src[pos] <= '9') {
            exp_val = exp_val * 10 + @as(i64, src[pos] - '0');
            pos += 1;
        }
        if (exp_neg) exp_val = -exp_val;
    }

    // Find the first non-zero digit index.
    var first_sig: usize = 0;
    while (first_sig < nd and all_digits[first_sig] == '0') {
        first_sig += 1;
    }

    // Completely zero mantissa → result is 0 (but jq outputs "0E<exponent>" for
    // big-number underflow; however since we only call this for actual literals
    // that cannot be represented as f64, we return "0" for zero mantissa).
    if (first_sig == nd) {
        result.buf[0] = '0';
        result.len = 1;
        return result;
    }

    // Strip trailing zeros from the significant digit window [first_sig, nd).
    var last_sig: usize = nd;
    while (last_sig > first_sig + 1 and all_digits[last_sig - 1] == '0') {
        last_sig -= 1;
    }

    // Effective decimal exponent of the first significant digit:
    //   dec_pos is the number of integer digits, so the first integer digit has
    //   value × 10^(dec_pos - 1 + exp_val).
    //   first_sig shifts that further: first_sig digits from position 0 were
    //   zero, each shifting the exponent by -1.
    //   Result: first_sig_digit × 10^(dec_pos - 1 - first_sig + exp_val)
    const effective_exp: i64 = @as(i64, @intCast(dec_pos)) - 1 -
        @as(i64, @intCast(first_sig)) + exp_val;

    // Build output
    if (is_neg) {
        result.buf[b] = '-';
        b += 1;
    }

    const sig_count = last_sig - first_sig;
    result.buf[b] = all_digits[first_sig];
    b += 1;
    if (sig_count > 1) {
        result.buf[b] = '.';
        b += 1;
        @memcpy(result.buf[b .. b + sig_count - 1], all_digits[first_sig + 1 .. last_sig]);
        b += sig_count - 1;
    }

    result.buf[b] = 'E';
    b += 1;

    var e = effective_exp;
    if (e < 0) {
        result.buf[b] = '-';
        b += 1;
        e = -e;
    } else {
        result.buf[b] = '+';
        b += 1;
    }

    // Write exponent digits (at least one digit).
    const exp_start = b;
    var tmp_e = e;
    if (tmp_e == 0) {
        result.buf[b] = '0';
        b += 1;
    } else {
        while (tmp_e > 0) {
            result.buf[b] = @intCast(@mod(tmp_e, 10) + '0');
            b += 1;
            tmp_e = @divTrunc(tmp_e, 10);
        }
        // Digits were written in reverse; reverse them.
        var lo = exp_start;
        var hi = b - 1;
        while (lo < hi) {
            const tmp = result.buf[lo];
            result.buf[lo] = result.buf[hi];
            result.buf[hi] = tmp;
            lo += 1;
            hi -= 1;
        }
    }

    result.len = b;
    return result;
}

/// Compare two big-number canonical strings (sign + significand + E + exponent).
/// Returns .lt, .eq, or .gt.  Both inputs must be the output of normalizeBigNumber.
pub fn compareBigNumbers(a: []const u8, b_str: []const u8) std.math.Order {
    if (a.len == 0 or b_str.len == 0) return .eq;

    const a_neg = a[0] == '-';
    const b_neg = b_str[0] == '-';

    // Different signs
    if (a_neg and !b_neg) return .lt;
    if (!a_neg and b_neg) return .gt;

    // Same sign: compare magnitudes, then flip for negatives
    const order = compareBigMagnitudes(a, b_str);
    return if (a_neg) flipOrder(order) else order;
}

fn flipOrder(o: std.math.Order) std.math.Order {
    return switch (o) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    };
}

/// Compare magnitudes of two normalized big-number strings.
fn compareBigMagnitudes(a: []const u8, b_str: []const u8) std.math.Order {
    // Extract exponent from "NE+EXP" or "NE-EXP" form.
    // The exponent is everything after the 'E'.
    const a_exp = parseBigExp(a);
    const b_exp = parseBigExp(b_str);

    if (a_exp != b_exp) {
        return if (a_exp < b_exp) .lt else .gt;
    }

    // Same exponent: compare significands digit by digit.
    const a_sig = bigSigPart(a);
    const b_sig = bigSigPart(b_str);
    return std.mem.order(u8, a_sig, b_sig);
}

/// Parse the signed exponent from a normalized big-number string.
fn parseBigExp(s: []const u8) i64 {
    var i: usize = 0;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
    // Skip significand digits and optional '.'
    while (i < s.len and s[i] != 'E') i += 1;
    if (i >= s.len) return 0;
    i += 1; // skip 'E'
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    } else if (i < s.len and s[i] == '+') {
        i += 1;
    }
    var e: i64 = 0;
    while (i < s.len) {
        e = e * 10 + @as(i64, s[i] - '0');
        i += 1;
    }
    return if (neg) -e else e;
}

/// Return the slice of the significant part (sign stripped, up to 'E').
fn bigSigPart(s: []const u8) []const u8 {
    var start: usize = 0;
    if (start < s.len and (s[start] == '-' or s[start] == '+')) start += 1;
    var end = start;
    while (end < s.len and s[end] != 'E') end += 1;
    return s[start..end];
}
