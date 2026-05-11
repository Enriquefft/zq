const std = @import("std");
const ZqError = @import("error").ZqError;
const types = @import("types");
const regex_mod = @import("regex");
const ast = @import("ast");
const resolver_mod = @import("module_resolver");
const Tape = types.Tape;
const Value = types.Value;
const Instruction = types.Instruction;
const BuiltinId = types.BuiltinId;

const max_stack_depth: u32 = 512;
const max_value_stack: u32 = 256;

/// State for one active `[expr]` array collection.
/// Pushed by array_collect_start, popped by array_collect_end or ip-exhaustion.
const CollectFrame = struct {
    /// Accumulated outputs from the inner expression.
    buffer: std.ArrayList(StackValue),
    /// Value stack depth when collection started.
    /// Used to trim leftover operands after each output.
    outer_value_depth: u32,
    /// if_stack depth when collection started.
    /// Used to clean up save_input entries when the iteration finalization
    /// shortcut bypasses restore_input instructions.
    outer_if_depth: u32,
    /// Fork stack depth when collection started.
    /// Used by yield_output to scope backtracking within the collect body.
    outer_fork_depth: u32,
    /// IP of the matching array_collect_end instruction.
    end_ip: u32,
};

// ── Fork stack types ─────────────────────────────────────────────────────────

const ForkType = enum(u8) { normal, each, range, try_handler, alt_handler, label, limit, skip, repeat, reduce_source, path_scope, scan, match_g, splits, recurse_path, sub_gen };

const EachState = struct {
    pos: u32,
    end: u32,
    tape: *const Tape,
    is_object: bool,
    /// Logical index/iteration count, used to record path components for
    /// path() over `.[]`. For arrays this is the array index; for objects
    /// the key is recorded directly so this remains a counter.
    index: u32 = 0,
};

const RangeState = struct {
    current_int: i64,
    end_int: i64,
    step_int: i64,
    current_float: f64,
    end_float: f64,
    step_float: f64,
    is_float: bool,
};

const TryHandlerState = struct {
    catch_ip: u32, // 0 = suppress mode (no catch handler)
    saved_if_len: u32,
    saved_collect_len: u32,
    saved_call_len: u32,
};

const LabelState = struct {
    break_token: u32,
    exit_ip: u32,
    saved_if_len: u32,
    saved_collect_len: u32,
    saved_call_len: u32,
};

const LimitState = struct {
    remaining: u64,
    body_start_ip: u32,
    exit_ip: u32,
    saved_collect_len: u32,
};

/// Classifies what kind of path-breaking access was attempted, so
/// `raisePathExprError` can emit jq's per-access diagnostic messages.
const PathBreakKind = enum {
    /// Generic: "Invalid path expression with result <v>"
    generic,
    /// "Invalid path expression near attempt to access element <N> of <src>"
    index_n,
    /// "Invalid path expression near attempt to access element \"<k>\" of <src>"
    key_s,
    /// "Invalid path expression near attempt to iterate through <src>"
    iterate,
};

/// Tracks whether the path_broken flag was set by an upstream call_builtin
/// (whose output is being descended into) or by a same-step literal/arith
/// (a scratch value used only as a key/predicate). Only the former prevents
/// clearsPathBroken from resetting the flag — a scratch literal break is
/// legitimately absorbed by the descent op that follows it.
const PathBreakOrigin = enum {
    /// Arithmetic, literals, or comparisons used to compute a key/index.
    /// The descent op that follows MAY clear path_broken.
    same_step_scratch,
    /// An upstream call_builtin produced the value being navigated.
    /// The descent op must NOT clear path_broken.
    upstream_value,
};

/// State for path(f) tracking. Pushed by path_begin, popped by path_end.
const PathFrame = struct {
    components: std.ArrayList(Value),
    /// value_stack depth at path_begin — restored at path_end to discard
    /// only the value(s) pushed by the body, not prior state.
    saved_value_stack_len: u32,
    /// Set when a path-breaking opcode (`types.Instruction.Op.breaksPath`)
    /// fires while this frame is innermost. `path_end` consults the flag to
    /// raise jq's "Invalid path expression" error.
    /// Reset across generator iterations via `PathSnapshot` save/restore.
    path_broken: bool = false,
    /// Classifies why path_broken was set; consulted by clearsPathBroken
    /// logic and raisePathExprError for per-kind diagnostic messages.
    break_origin: PathBreakOrigin = .same_step_scratch,
    /// What kind of access was attempted when path broke.
    break_kind: PathBreakKind = .generic,
    /// The value being navigated when path broke (used in error messages).
    break_source: Value = .null_val,
    /// Populated when break_kind == .index_n.
    break_index_n: i64 = 0,
    /// Populated when break_kind == .key_s; points into string_buf.
    break_key_s: []const u8 = &.{},
    /// True when the body is a path-emitting builtin (`paths`, `leaf_paths`,
    /// `..`/`recurse`) whose per-iteration current value already IS the path
    /// array for this `path(f)` call. `path_end` yields that value directly
    /// instead of building the array from `components` (which stays empty
    /// because these builtins don't use navigation ops). The companion
    /// each-iteration forkpoint must avoid appending an index/key component
    /// when this flag is set — see `advanceEachForkpoint` and `.each`.
    body_emits_paths_directly: bool = false,
    /// Set when an inner path(f) result is being consumed as a computed key
    /// (e.g. path(.a[path(.b)[0]])). While set, descent ops skip recording
    /// path components — the intervening load_index/load_computed ops that
    /// index the inner path result array are meta-level, not path descents.
    /// Cleared by the `load_computed` that consumes the key.
    skip_components_for_computed_key: bool = false,
    /// Set by `path_suspend`, cleared by `path_resume`. While set, descent
    /// ops skip component recording AND `breaksPath` ops do NOT mark
    /// `path_broken`. Used to evaluate the LHS of an `EXPR1 as $v | EXPR2`
    /// binding inside a path frame: jq treats EXPR1 as value-context (path
    /// of the whole binding is `path(EXPR2)` only). Snapshotted alongside
    /// the rest of the frame state so suspension persists across generator
    /// backtracks within the LHS subexpression.
    suspended: bool = false,

    fn deinit(self: *PathFrame, alloc: std.mem.Allocator) void {
        self.components.deinit(alloc);
    }

    /// True when descent ops should NOT append a path component to this
    /// frame. Combined predicate for the two suppression mechanisms:
    ///   - `skip_components_for_computed_key`: meta-level descents on an
    ///     inner `path(f)` result consumed as a computed key/index.
    ///   - `suspended`: the LHS of an `as` binding is being evaluated in
    ///     value context (jq path semantics).
    fn skipComponents(self: *const PathFrame) bool {
        return self.skip_components_for_computed_key or self.suspended;
    }
};

/// True for builtins that, when called inside a `path(f)` frame, emit path
/// arrays as their per-iteration value — so the outer `path()` yields those
/// directly instead of tracking descent. Whitelisted:
///   - `paths` / `leaf_paths`: define themselves in jq as `path(..) | ...`
///   - `recurse` (and the `..` operator, compiled to the same builtin): jq's
///     `def recurse: ., (.[]? | recurse);` — path tracking would produce the
///     same paths as `paths`, including the root `[]`.
/// These builtins populate the `PathFrame.body_emits_paths_directly` flag,
/// and `path_end` yields the current value as the result.
fn callBuiltinIsPathEmittingInFrame(bid: types.BuiltinId) bool {
    return switch (bid) {
        .paths, .leaf_paths, .recurse => true,
        // getpath(P) in a path(f) context: the path IS the argument P.
        // builtinGetpath populates frame.components directly from P so that
        // path_end can build the path array via buildPathArray(components).
        // Marking it here prevents path_broken from being set before dispatch.
        .getpath => true,
        else => false,
    };
}

const SkipState = struct {
    remaining: u64,
    body_start_ip: u32,
    exit_ip: u32,
    saved_collect_len: u32,
};

/// State for `repeat(f)` — jq's infinite generator
/// `def repeat(exp): def _r: exp, _r; _r;`. Each backtrack into the
/// frame restores the captured input as `current` and re-enters the
/// body at `body_start_ip`, producing the body's outputs ad infinitum.
/// Termination is delegated to an enclosing `limit_start` whose
/// counter, decremented at each `yield_output` inside the body's IP
/// range, will truncate the fork stack past us once it hits zero.
/// `saved_collect_len` lets the backtrack handler tear down any
/// collect frames the body opened mid-iteration so the next iteration
/// starts clean.
const RepeatState = struct {
    body_start_ip: u32,
    exit_ip: u32,
    saved_collect_len: u32,
    saved_call_len: u32,
};

/// State for a `reduce_source_start` wrap — see opcode doc-comment.
/// `body_start_ip` is the first instruction of the wrapped source
/// expression; `exit_ip` is the IP of the matching `reduce_source_end`.
/// `yield_output` consults innermost-out: if its emission IP lies in
/// `(body_start_ip, exit_ip)`, the value is routed into `current` and
/// `ip` advances to `exit_ip + 1` (past `reduce_source_end`), so the
/// destructure/update arm of the enclosing reduce runs as if the
/// source had produced the value via the natural per-iteration flow.
const ReduceSourceState = struct {
    body_start_ip: u32,
    exit_ip: u32,
    saved_collect_len: u32,
};

/// State for one active `scan(pattern)` generator iteration. The fork frame
/// owns the `slots` slice (allocated at push, freed at pop).
///
/// Two ownership modes for the regex handles:
///   - Static-pool path: `clone` points into the iterator's `regex_clones`
///     array (which owns the RegexClone for the compiled-filter lifetime).
///     `owned_regex`/`owned_clone` are null. Pool entries never evict, so the
///     borrowed pointer is stable for the life of the fork frame.
///   - Dynamic path (`scan($var)`): the frame owns a private compiled `Regex`
///     AND its `RegexClone`, both populated at fork-push time. This isolates
///     the frame from the runtime LRU — subsequent dynamic-pattern compiles
///     that evict the LRU entry backing the pattern cannot dangle this frame's
///     handles. `clone` aliases `&owned_clone.?` for uniform iterNext access.
///
/// `hay` is a slice into tape / runtime_tape memory — arena-owned, lifetime
/// covers the full next() call, so borrowing it across backtracks is safe.
const ScanState = struct {
    clone: *regex_mod.RegexClone,
    owned_regex: ?regex_mod.Regex = null,
    owned_clone: ?regex_mod.RegexClone = null,
    hay: []const u8,
    cursor: usize,
    /// capture_count slots. slots[0] is the full-match span; slots[1..] are
    /// capture groups. Allocated with iterator's allocator; freed on frame pop.
    slots: []regex_mod.MatchSlot,
    /// Whether the pattern has any capture groups beyond the implicit full-
    /// match. When true, `scan` yields arrays of capture strings; when false
    /// (pattern has no user-written groups), `scan` yields the matched string.
    has_user_captures: bool,
    /// jq `n` flag — skip zero-width overall matches on both the initial
    /// draw and every backtrack advance. See `advanceScanForkpoint`.
    n_flag: bool = false,
};

/// Fork state for `match(re; "g")` — yields one jq-match-object per
/// non-overlapping occurrence. Distinct opcode from scan because the yield
/// value shape differs (full match object vs scan's string/array).
///
/// Same two-mode ownership as ScanState. `regex` is used for metadata
/// (capture count + group names) when building match objects.
const MatchGState = struct {
    clone: *regex_mod.RegexClone,
    regex: *const regex_mod.Regex,
    owned_regex: ?regex_mod.Regex = null,
    owned_clone: ?regex_mod.RegexClone = null,
    hay: []const u8,
    cursor: usize,
    slots: []regex_mod.MatchSlot,
    /// jq `n` flag — skip zero-width overall matches during iteration.
    n_flag: bool = false,
};

/// Fork state for `splits(re; flags)` — yields the segment between the
/// previous match end and the current match start, then a final tail segment
/// when matches are exhausted.
///
/// Same two-mode ownership as ScanState.
const SplitsState = struct {
    clone: *regex_mod.RegexClone,
    owned_regex: ?regex_mod.Regex = null,
    owned_clone: ?regex_mod.RegexClone = null,
    hay: []const u8,
    cursor: usize,
    /// Byte offset where the previous match ended (= start of next segment).
    prev_end: usize,
    slots: []regex_mod.MatchSlot,
    /// True after matches are exhausted and the trailing tail segment has
    /// been yielded. Used to terminate the generator on the following
    /// backtrack without producing an extra empty segment.
    tail_yielded: bool,
    /// jq `n` flag — zero-width overall matches do not split (they are
    /// treated as non-matches; cursor advances past them without emitting
    /// a segment boundary).
    n_flag: bool = false,
};

/// State for `sub`/`gsub` generator-in-replacement (NIX-004). When the
/// replacement filter produces K > 1 outputs per match, `builtinSubImpl`
/// computes all K final strings up-front, returns the first as the call's
/// pushed value, and parks the remaining as `Tape.StringRef` offsets on
/// this frame. `advanceSubGenForkpoint` pushes the next ref's resolved
/// string onto value_stack at each backtrack and pops the frame when the
/// queue empties.
///
/// Storing `Tape.StringRef` (offset+len) rather than raw `[]const u8`
/// keeps the frame robust against `runtime_tape.string_buf` reallocations
/// that may happen between yields (bytecode emitted by downstream filters
/// may intern more strings before we backtrack to advance this frame).
///
/// `refs` is allocated from the iterator's per-record scratch arena —
/// released wholesale at `reset()`. No explicit per-frame deinit needed.
const SubGenState = struct {
    refs: []const Tape.StringRef,
    /// Index of the NEXT string to yield (refs[index..] is the queue).
    index: u32,
};

/// One (value, path-components) pair collected by `..` (recurse) when it runs
/// inside a `path(f)` frame. The path components are a heap-allocated slice of
/// `Value` (int / string elements only); the value is a `Value` borrowed from
/// the tape (lifetime = this `next()` call). Both stay valid across the full
/// fork iteration since no tape compaction occurs within a single `next()`.
const RecursePathEntry = struct {
    /// The actual data value at this point in the DFS walk. Downstream filters
    /// (e.g. `select(type == "object")`) operate on this value, not the path.
    value: Value,
    /// Path components from root to this node. Slice owned by the RecursePathState.
    path_comps: []Value,
};

/// Fork state for `..` (recurse) inside a `path(f)` frame. Unlike the normal
/// `body_emits_paths_directly` mode (which sets `it.current` to the path array
/// itself and breaks any downstream filter), this mode keeps `it.current` as the
/// actual value and repopulates `frame.components` from `path_comps` before each
/// iteration — allowing `select`, type tests, and field access to work correctly.
///
/// `items` and per-entry `path_comps` live in the iterator's per-record scratch
/// arena — released wholesale at `reset()`. Per-record lifetime: no entry can
/// escape the record boundary because the recurse_path fork frame is owned by
/// `fork_stack`, which is unwound before the next record starts.
const RecursePathState = struct {
    items: []RecursePathEntry,
    index: usize,

    fn deinit(_: *RecursePathState) void {}
};

const ForkAux = union(ForkType) {
    normal: void,
    each: EachState,
    range: RangeState,
    try_handler: TryHandlerState,
    alt_handler: TryHandlerState,
    label: LabelState,
    limit: LimitState,
    skip: SkipState,
    /// State for `repeat(f)` — see `RepeatState` doc-comment. Backtrack
    /// into this frame restores the saved input and re-enters the body
    /// at `body_start_ip`; the frame is popped only when an enclosing
    /// `limit` truncates the fork stack past us, or when `repeat_end`
    /// runs (only reachable via that truncation).
    repeat: RepeatState,
    /// State for `reduce_source_start` — see `ReduceSourceState` doc.
    /// On backtrack into the frame the wrap is simply popped (the
    /// enclosing `reduce`'s outer `fork L_done` is the real iteration
    /// driver; the wrap only routes streaming-source values into the
    /// destructure arm).
    reduce_source: ReduceSourceState,
    /// Sentinel forkpoint pushed by `path_begin`. Holds no extra state — its
    /// sole purpose is to pop the matching path frame when execution
    /// backtracks past the path() expression scope.
    path_scope: void,
    /// State for `scan(pattern)` generator iterations. On backtrack,
    /// `doBacktrack` / `backtrackToDepth` calls `iterNext` via the frame's
    /// `clone`; when no more matches are available the frame is popped.
    scan: ScanState,
    /// State for `match(pattern; "g")` generator iterations. Yields one
    /// full jq-match-object per occurrence.
    match_g: MatchGState,
    /// State for `splits(pattern; flags)` generator iterations. Yields each
    /// segment between matches plus the trailing tail.
    splits: SplitsState,
    /// State for `..` (recurse) inside a `path(f)` frame. Stores all DFS
    /// (value, path) pairs so downstream filters see actual values (not
    /// pre-built path arrays) while `frame.components` is set correctly per
    /// iteration for `path_end` to reconstruct the path.
    recurse_path: RecursePathState,
    /// State for `sub`/`gsub` generator-in-replacement (NIX-004). Yields
    /// the queued result strings one per backtrack until exhausted.
    sub_gen: SubGenState,
};

/// Snapshot of the path-tracking state at the time a fork was created.
/// On backtrack, the snapshot is restored so each generator iteration
/// starts with a fresh path frame state (matching jq's per-output paths).
///
/// Outside of `path(...)` expressions, both fields are 0 — restoration is a
/// no-op and adds no overhead.
const PathSnapshot = struct {
    /// Path-stack depth at fork time. Inner frames pushed after the fork are
    /// torn down on backtrack.
    stack_len: u32 = 0,
    /// Components.items.len of the innermost path frame at fork time, or 0
    /// if there was no active frame.
    components_len: u32 = 0,
    /// `path_broken` state of the innermost frame at fork time. Restored on
    /// backtrack so generators like `path(.[])` start each iteration with a
    /// clean flag (the prior iteration's broken side-path can't leak).
    path_broken: bool = false,
    break_origin: PathBreakOrigin = .same_step_scratch,
    break_kind: PathBreakKind = .generic,
    break_source: Value = .null_val,
    break_index_n: i64 = 0,
    break_key_s: []const u8 = &.{},
    skip_components_for_computed_key: bool = false,
    suspended: bool = false,
};

const Forkpoint = struct {
    saved_value_stack_len: u32,
    saved_current: Value,
    backtrack_ip: u32,
    aux: ForkAux,
    /// Path tracking state at fork time. Restored on backtrack so generator
    /// iterations inside `path(...)` produce one path per iteration rather
    /// than accumulating components across all iterations.
    saved_path: PathSnapshot = .{},
    /// Snapshot of value-stack entries above the enclosing collect frame's
    /// outer_value_depth at fork time. When a generator iteration emits a
    /// value via yield_output, the stack is truncated to outer_value_depth;
    /// setting items.len back up to saved_value_stack_len on backtrack would
    /// otherwise expose stale slots. Restoring from this snapshot preserves
    /// left-operand slots (e.g. `. * (a,b)` keeps `.` for the second branch).
    /// Null when no collect frame is active (the stack isn't truncated then).
    saved_stack: ?[]StackValue = null,
    /// Snapshot of the three object-construction stacks taken at fork time.
    /// See `ObjectConstructSnapshot`. Null when no object literal is being
    /// constructed at fork time (the common case).
    saved_object: ?ObjectConstructSnapshot = null,
    /// `it.current_args` at fork-creation time. Restored on every fork
    /// FIRE site in `backtrackToDepth` so a fork created inside a
    /// recursive UDF body can re-enter that body after the frame has
    /// already returned (e.g. `range(2) as $i | f($p-1)` — the range
    /// fork outlives the call to f's body in the same frame, and the
    /// caller's outer fork resumes into a now-popped frame). Default
    /// `&.{}` is correct for forks created outside any UDF body.
    /// NIX-011: replaces the dead `frame.args` lookup that broke when
    /// `call_stack` was popped on return.
    saved_current_args: []StackValue = &.{},
    /// `it.call_stack.items.len` at fork-creation time. Used at fire
    /// time to detect "this fork was created inside a now-yielded
    /// frame's body" (deferred-pop scheme): a yielded frame stays on
    /// `call_stack` until its body forks are exhausted, so a fork with
    /// `saved_call_len == call_stack.items.len` whose top frame has
    /// `returned == true` is a body fork — `backtrackToDepth` swaps
    /// the frame's `body_vars` back into `variable_store` before
    /// resuming, so body re-execution sees its own pattern-var
    /// bindings (not the caller's) (NIX-011).
    saved_call_len: u32 = 0,
};

/// State for one active function call (used for recursive user-defined functions).
/// Pushed by call_function, popped by return_function.
const CallFrame = struct {
    /// IP to resume at when the function body returns.
    return_ip: u32,
    /// Saved stack depths for correct unwinding.
    saved_value_len: u32,
    saved_if_len: u32,
    saved_collect_len: u32,
    /// Saved fork stack depth for unwinding on return.
    saved_fork_len: u32,
    /// Saved `var_save_stack.items.len` BEFORE this call's write-set
    /// snapshots were pushed. On return (or fork backtrack truncation
    /// of call_stack), entries above this length are popped, restoring
    /// each (id, prev) pair so the caller sees its pre-call slot values.
    /// Without this, recursive bodies sharing the same compiled slot ids
    /// (pattern vars in reduce/foreach, value-arg slots) clobber the
    /// outer call's bindings.
    saved_var_len: u32,
    /// Caller's `value_stack` contents at call_function time. Owned slice.
    /// On call entry the body sees an empty value_stack; on return (or
    /// fork-unwind via truncateCallStackTo) the caller's stack is
    /// restored verbatim. Without this, a body's `capture_variable` ops
    /// pop pending operands the caller had stashed for an outer binary
    /// op (e.g. the LHS of `(. + $i) + ($n-1 | rec)`), wrongly binding
    /// pattern vars to caller residue. Bodies return their result via
    /// `current` per the emitter convention, so any leftover on body's
    /// own value_stack at return is discarded.
    saved_stack: []StackValue,
    /// Caller's `current_args` register at call_function time. Restored
    /// by return_function so the caller body's subsequent `load_arg`s
    /// resolve against the caller's own value-args (NIX-011). Owned by
    /// the previous frame's scratch allocation (or `&.{}` for the
    /// outermost call) — no explicit free.
    saved_args: []StackValue,
    /// Set true the first time `return_function` fires for this frame.
    /// Frame stays on `call_stack` after return so body forks created
    /// inside the body (e.g. `range(2) as $i | f($p-1)`) can re-enter
    /// the body when they fire — `backtrackToDepth` only finalizes
    /// the pop once `fork_stack.items.len <= frame.saved_fork_len`.
    /// While `returned == true`, the caller is the active execution
    /// context; `variable_store` holds caller-state pattern vars and
    /// body's bindings live in `body_vars`. (NIX-011)
    returned: bool = false,
    /// Snapshot of body's pattern-var values at last yield, for every
    /// id in the called fn's `write_set`. Populated lazily on first
    /// `return_function` call (frame.returned=false→true) and refreshed
    /// on each subsequent yield. `backtrackToDepth` writes these back
    /// into `variable_store` before resuming a body fork so the body
    /// sees its own `as $x` / reduce-key bindings, not the caller's.
    /// Owned by the same scratch arena as `saved_stack` / `args` —
    /// freed implicitly on per-record reset; no explicit free.
    body_vars: []SavedVar = &.{},
    /// Index into `function_table` for the fn this frame is executing.
    /// `return_function` uses the fn's `[body_ip, body_end)` to identify
    /// which frame's body contains the current IP — when nested
    /// yielded frames are present (cascading returns), the topmost
    /// frame on `call_stack` is not necessarily the one whose body the
    /// return_function instruction lives in. (NIX-011)
    fn_id: u32,
};

/// A snapshot of one variable slot's value, taken at call_function time
/// for each var_id in the called fn's write set. Stored on `var_save_stack`;
/// indexed implicitly by `CallFrame.saved_var_len` boundaries.
const SavedVar = struct {
    id: u32,
    prev: ?StackValue,
};

/// Resolve a slice bound (possibly negative) against collection length.
/// Negative x wraps from end: x + len. Result is clamped to [0, len].
fn resolveSliceBound(x: i32, len: i32) i32 {
    const resolved = if (x < 0) len + x else x;
    if (resolved < 0) return 0;
    if (resolved > len) return len;
    return resolved;
}

/// Map a ZqError to its display name for the catch handler's input value.
/// Returns a string literal (static memory); no allocation required.
fn errorToString(err: ZqError) []const u8 {
    return switch (err) {
        error.TypeError => "TypeError",
        error.IndexOutOfBounds => "IndexOutOfBounds",
        error.DepthLimitExceeded => "DepthLimitExceeded",
        error.IoError => "IoError",
        error.QuerySyntaxError => "QuerySyntaxError",
        error.OutOfMemory => "OutOfMemory",
        error.UserError => "UserError",
        else => "error",
    };
}

/// A value on the evaluation stack.
pub const StackValue = union(enum) {
    null_val,
    bool_val: bool,
    int: i64,
    float: f64,
    /// Out-of-range numeric literal in canonical normalized form, e.g. "9E+999999999".
    /// Backed by the compiled string_buf; never owned by StackValue.
    big_number: []const u8,
    /// A view into the Tape for objects/arrays/strings.
    tape_value: Value,
};

/// One accumulated field during object literal construction.
/// Declared at module level (rather than nested in ResultIterator) so
/// Forkpoint can snapshot slices of the in-progress construct stack.
/// `key` resolves at every read — when it points into a runtime tape's
/// `string_buf`, that buffer may grow between push and finalize, but
/// growth is append-only so `(offset, len)` stays valid (NIX-006).
const ObjectField = struct {
    key: Value.StringView,
    value: StackValue,
};

/// Snapshot of the three object-construction stacks captured at fork time.
/// Restored on any backtrack path that re-enters code lexically inside an
/// `{...}` literal's field-value expression (comma generators, `.each`,
/// range, alt, and regex generators). Without this, `object_construct_end`
/// inside the first iteration pops the input/depth frames and leaves the
/// second iteration with no context to consume via `object_key`, surfacing
/// as a spurious `type error` at the generator's second yield.
///
/// `null` when none of the three stacks had entries at fork time — keeps
/// the common case (forks outside any `{...}` literal) allocation-free.
const ObjectConstructSnapshot = struct {
    fields: []ObjectField,
    depth: []u32,
    input: []Value,
};

/// Binding of an external variable (by compiler-assigned ID) to a concrete value.
pub const ExternalVarBinding = struct {
    var_id: u32,
    value: StackValue,
};

/// Lazy execution state. Not thread-safe. Must not be moved after creation:
/// Value.TapeSpan.tape pointers reference &self.tape.
pub const ResultIterator = struct {
    tape: Tape,
    instructions: []const Instruction,
    /// Function definitions table.
    function_table: []const types.FunctionDef,
    /// Compiled string buffer for string literals.
    string_buf: []const u8,
    /// Original input value, preserved for object construction.
    input_value: Value,
    opts_allow_null: bool,
    ip: u32,
    current: Value,
    /// Value stack for expression evaluation.
    value_stack: std.ArrayList(StackValue),
    /// Variable storage for variable capture and reference.
    variable_store: std.ArrayList(?StackValue),
    /// Mutable runtime tape for constructing objects/arrays at query time.
    /// TapeSpan pointers reference `runtime_tape.view`, which is auto-updated
    /// by appendEntry/internString — no manual view sync needed.
    runtime_tape: types.RuntimeTape,
    /// Object construction state.
    object_construct: std.ArrayList(ObjectField),
    /// Stack of saved field counts for nested object construction.
    object_construct_depth: std.ArrayList(u32),
    /// Stack of saved input values for nested object construction. Each entry
    /// is the `current` value at object_construct_start time, restored before
    /// every field's value expression so all fields evaluate against the same
    /// `.` even when prior fields leave intermediate values in `current`.
    object_construct_input: std.ArrayList(Value),
    /// Stack of saved `current` values for if/elif branch restoration.
    /// save_input pushes; restore_input pops.
    if_stack: std.ArrayList(Value),
    /// Parallel to if_stack: stores the innermost path frame's components.items.len
    /// at the time of save_input (or maxInt(u32) when no path frame is active).
    /// restore_input truncates frame.components back to this length, preventing
    /// navigations inside if/elif conditions from polluting the path component list.
    if_path_comps_stack: std.ArrayList(u32),
    /// Active array collection frames. Pushed by array_collect_start.
    collect_stack: std.ArrayList(CollectFrame),
    /// Active call frames for user-defined recursive function calls.
    call_stack: std.ArrayList(CallFrame),
    /// Snapshot stack for variable slots saved across recursive call_function /
    /// return_function pairs. Each CallFrame records the length-mark BEFORE
    /// the call's write-set snapshots, so return (or fork-backtrack
    /// truncation of call_stack) restores each saved slot in LIFO order.
    /// See `CallFrame.saved_var_len` and `truncateCallStackTo`.
    var_save_stack: std.ArrayList(SavedVar),
    /// Live value-args of the innermost recursive UDF body currently
    /// executing. `Op.load_arg(i)` reads `current_args[i]`. Updated by
    /// `call_function` (set to the new frame's args after saving the
    /// caller's value into `frame.saved_args`) and `return_function`
    /// (restored from the popped frame's `saved_args`). Forkpoints
    /// snapshot this at creation (`Forkpoint.saved_current_args`) and
    /// restore on fire so a fork that re-enters a returned-and-popped
    /// body still resolves load_arg correctly. Empty `&.{}` outside
    /// any body. Owned by `scratch` (per-record arena) at the call
    /// that allocated it. NIX-011 SSOT for value-arg storage.
    current_args: []StackValue,
    /// Fork stack for unified backtracking (comma, iteration, range, try, alt, label, limit).
    fork_stack: std.ArrayList(Forkpoint),
    /// Path tracking stack for path(f). Pushed by path_begin, popped by path_end.
    path_stack: std.ArrayList(PathFrame),
    /// Monotonically increasing counter for generating unique break tokens.
    next_break_token: u32,
    /// Value stored by the `error` builtin so the catch handler can retrieve it.
    user_error_msg: ?Value,
    /// Descriptive message for TypeError, set before returning error.TypeError in
    /// key VM operations. Used by handleCaughtError for jq-compatible error messages.
    type_error_detail: ?Value,
    alloc: std.mem.Allocator,
    done: bool,
    /// Defers initial tapeEntryToValue(&self.tape, 0) until after any struct move.
    initialized: bool,
    source_map: []const u32,
    last_error_ip: u32,
    /// Borrowed reference to the compiled filter's regex pool. Non-null for
    /// every iterator constructed via `CompiledQuery.execute`; may be null in
    /// unit tests that short-circuit the pool. When null, every regex builtin
    /// that reaches a pool-index path errors cleanly.
    regex_pool: ?*const regex_mod.RegexPool,
    /// Per-worker clones of every pool entry. Lazily populated on first use:
    /// `regex_clones[i] == null` until the i-th pool regex is accessed.
    /// Aligned 1:1 with `regex_pool.entries`. Owned by this iterator; every
    /// non-null clone is deinit'd in `deinit`.
    regex_clones: []?regex_mod.RegexClone,
    /// Bounded LRU for dynamic (`test($var)` etc.) patterns. Each entry bundles
    /// the compiled `Regex` AND its per-iterator `RegexClone` — the cache is
    /// the single source of truth for keyed-by-pattern regex state. Owned by
    /// this iterator; evicted entries free both halves in lockstep.
    dynamic_regex_cache: regex_mod.cache.LruCache(64),
    /// Entry of the last resolved dynamic pattern in THIS builtin call. Used
    /// by metadata helpers so capture/match builders don't need the pattern
    /// string a second time. Only valid for the duration of a single builtin
    /// invocation. A single borrowed-pointer pair — no ownership.
    last_dynamic_entry: ?regex_mod.cache.DynamicEntry,
    /// Module search path threaded from compile-time `Opts`. Used by the
    /// `modulemeta` builtin to resolve its input-string argument against
    /// the same search machinery the compiler uses for `import`/`include`.
    /// Borrowed; lifetime tied to the parent `CompiledQuery.opts`.
    module_search_path: []const []const u8,
    /// Importer file directory (jq's analog of `-L .`). Borrowed; same
    /// lifetime contract as `module_search_path`.
    current_file_dir: ?[]const u8,
    /// Per-record scratch arena. Reset (retain_capacity) on every `reset()` —
    /// lifetime is "one record's evaluation". Bump-pointer; mutex-free under
    /// load. Holds every transient allocation that does not survive across
    /// records: fork-stack snapshots (value_stack, object_construct), call
    /// frame value-stack saves, base64 scratch, extracted-array elem buffers,
    /// path-component arrays, regex MatchSlot buffers. Persistent stacks
    /// (`value_stack`, `fork_stack`, `variable_store`, etc.) keep `alloc`.
    ///
    /// Worker invariant (`process_line_serialized` in pool/root.zig):
    /// `next()` is drained for record N before `reset(tape_{N+1})` is called.
    /// No yielded Value points into scratch beyond the record boundary.
    scratch: std.heap.ArenaAllocator,

    pub fn init(
        instructions: []const Instruction,
        function_table: []const types.FunctionDef,
        string_buf: []const u8,
        opts_allow_null: bool,
        tape: Tape,
        external_bindings: []const ExternalVarBinding,
        source_map: []const u32,
        regex_pool: ?*const regex_mod.RegexPool,
        module_search_path: []const []const u8,
        current_file_dir: ?[]const u8,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!ResultIterator {
        var value_stack = std.ArrayList(StackValue){};
        errdefer value_stack.deinit(allocator);
        try value_stack.ensureTotalCapacity(allocator, max_value_stack);

        var variable_store = std.ArrayList(?StackValue){};
        errdefer variable_store.deinit(allocator);
        try variable_store.ensureTotalCapacity(allocator, max_value_stack);
        // Initialize variable slots to null
        variable_store.items.len = 0;
        try variable_store.appendNTimes(allocator, null, max_value_stack);

        // Inject external variable bindings
        for (external_bindings) |b| {
            if (b.var_id < variable_store.items.len) {
                variable_store.items[b.var_id] = b.value;
            }
        }

        // Initialize object construction state
        var object_construct = std.ArrayList(ObjectField){};
        errdefer object_construct.deinit(allocator);
        try object_construct.ensureTotalCapacity(allocator, 128);

        // Initialize object construction depth stack for nested objects
        var object_construct_depth = std.ArrayList(u32){};
        errdefer object_construct_depth.deinit(allocator);
        try object_construct_depth.ensureTotalCapacity(allocator, 16);

        var object_construct_input = std.ArrayList(Value){};
        errdefer object_construct_input.deinit(allocator);
        try object_construct_input.ensureTotalCapacity(allocator, 16);

        // Initialize if-branch input stack
        var if_stack = std.ArrayList(Value){};
        errdefer if_stack.deinit(allocator);
        try if_stack.ensureTotalCapacity(allocator, max_stack_depth);

        // Initialize parallel path-components save stack for if-branch restoration
        var if_path_comps_stack = std.ArrayList(u32){};
        errdefer if_path_comps_stack.deinit(allocator);
        try if_path_comps_stack.ensureTotalCapacity(allocator, max_stack_depth);

        // Initialize array collect stack (nesting depth rarely exceeds 8)
        var collect_stack = std.ArrayList(CollectFrame){};
        errdefer collect_stack.deinit(allocator);
        try collect_stack.ensureTotalCapacity(allocator, 16);

        // Initialize call frame stack for recursive user-defined functions
        var call_stack = std.ArrayList(CallFrame){};
        errdefer call_stack.deinit(allocator);
        try call_stack.ensureTotalCapacity(allocator, 64);

        // Per-frame variable snapshot side stack (B4: pattern-var clobbering
        // across recursive reduce/foreach calls).
        var var_save_stack = std.ArrayList(SavedVar){};
        errdefer var_save_stack.deinit(allocator);
        try var_save_stack.ensureTotalCapacity(allocator, 64);

        // Initialize fork stack for unified backtracking
        var fork_stack = std.ArrayList(Forkpoint){};
        errdefer fork_stack.deinit(allocator);
        try fork_stack.ensureTotalCapacity(allocator, max_stack_depth);

        var path_stack = std.ArrayList(PathFrame){};
        errdefer path_stack.deinit(allocator);
        try path_stack.ensureTotalCapacity(allocator, 4);

        // Initialize runtime tape
        var runtime_tape = try types.RuntimeTape.init(allocator);
        errdefer runtime_tape.deinit(allocator);

        // Allocate the clone slots array sized to the pool. On regex-disabled
        // builds `len()` is 0 (no patterns can be interned), so this is a
        // zero-length allocation. Slots start at null; lazy population
        // amortizes per-pattern clone cost across scans.
        const clone_count: usize = if (regex_pool) |p| p.len() else 0;
        const regex_clones = try allocator.alloc(?regex_mod.RegexClone, clone_count);
        errdefer allocator.free(regex_clones);
        for (regex_clones) |*slot| slot.* = null;

        return ResultIterator{
            .tape = tape,
            .instructions = instructions,
            .function_table = function_table,
            .string_buf = string_buf,
            .input_value = undefined, // Will be set on first next() call
            .opts_allow_null = opts_allow_null,
            .ip = 0,
            .current = undefined,
            .value_stack = value_stack,
            .variable_store = variable_store,
            .runtime_tape = runtime_tape,
            .object_construct = object_construct,
            .object_construct_depth = object_construct_depth,
            .object_construct_input = object_construct_input,
            .if_stack = if_stack,
            .if_path_comps_stack = if_path_comps_stack,
            .collect_stack = collect_stack,
            .call_stack = call_stack,
            .var_save_stack = var_save_stack,
            .current_args = &.{},
            .fork_stack = fork_stack,
            .path_stack = path_stack,
            .next_break_token = 0,
            .user_error_msg = null,
            .type_error_detail = null,
            .alloc = allocator,
            .done = false,
            .initialized = false,
            .source_map = source_map,
            .last_error_ip = 0,
            .regex_pool = regex_pool,
            .regex_clones = regex_clones,
            .dynamic_regex_cache = regex_mod.cache.LruCache(64).init(allocator),
            .last_dynamic_entry = null,
            .module_search_path = module_search_path,
            .current_file_dir = current_file_dir,
            .scratch = std.heap.ArenaAllocator.init(allocator),
        };
    }

    /// Free arena-allocated state attached to a regex-generator forkpoint
    /// (`scan`, `match_g`, `splits`): the `slots` slice plus any
    /// dynamic-path-owned `Regex`/`RegexClone`. No-op for any other aux kind.
    ///
    /// The owned-regex / owned-clone pair exists only for dynamic-pattern
    /// forks (see state-struct docs) — freeing them here is what makes the
    /// fork robust against LRU eviction of the pattern backing the frame.
    fn freeRegexForkSlots(_: *ResultIterator, fp: *Forkpoint) void {
        switch (fp.aux) {
            .scan => |*s| {
                if (s.owned_clone) |*c| c.deinit();
                if (s.owned_regex) |*r| r.deinit();
                s.owned_clone = null;
                s.owned_regex = null;
            },
            .match_g => |*s| {
                if (s.owned_clone) |*c| c.deinit();
                if (s.owned_regex) |*r| r.deinit();
                s.owned_clone = null;
                s.owned_regex = null;
            },
            .splits => |*s| {
                if (s.owned_clone) |*c| c.deinit();
                if (s.owned_regex) |*r| r.deinit();
                s.owned_clone = null;
                s.owned_regex = null;
            },
            else => {},
        }
    }

    /// Free the internal eval stack. Idempotent.
    pub fn deinit(it: *ResultIterator) void {
        it.value_stack.deinit(it.alloc);
        it.variable_store.deinit(it.alloc);
        it.object_construct.deinit(it.alloc);
        it.object_construct_depth.deinit(it.alloc);
        it.object_construct_input.deinit(it.alloc);
        it.if_stack.deinit(it.alloc);
        it.if_path_comps_stack.deinit(it.alloc);
        for (it.collect_stack.items) |*frame| frame.buffer.deinit(it.alloc);
        it.collect_stack.deinit(it.alloc);
        it.call_stack.deinit(it.alloc);
        it.var_save_stack.deinit(it.alloc);
        for (it.fork_stack.items) |*fp| {
            it.freeRegexForkSlots(fp);
            switch (fp.aux) {
                .recurse_path => |*state| state.deinit(),
                else => {},
            }
        }
        it.fork_stack.deinit(it.alloc);
        for (it.path_stack.items) |*frame| frame.deinit(it.alloc);
        it.path_stack.deinit(it.alloc);
        it.runtime_tape.deinit(it.alloc);

        // Free per-pool clones and the runtime dynamic cache (which owns both
        // Regex + RegexClone for every resident entry).
        for (it.regex_clones) |*maybe_clone| {
            if (maybe_clone.*) |*c| c.deinit();
        }
        it.alloc.free(it.regex_clones);
        it.dynamic_regex_cache.deinit();
        it.scratch.deinit();
    }

    /// Rebind this iterator to a new tape from the same query.
    /// All internal buffers retain their capacity — zero allocations.
    /// The iterator returns to the initial state, ready for a new next() loop.
    ///
    /// Must be called only when the previous run is complete: either next()
    /// returned null or an error, or the caller has decided to abandon it.
    /// Must NOT be called after deinit().
    pub fn reset(it: *ResultIterator, tape: Tape, external_bindings: []const ExternalVarBinding) void {
        it.tape = tape;
        it.ip = 0;
        it.done = false;
        it.initialized = false;
        it.value_stack.clearRetainingCapacity();
        // Restore variable slots to their initial null state without reallocating.
        // capacity >= max_value_stack is guaranteed by init()'s ensureTotalCapacity.
        it.variable_store.items.len = max_value_stack;
        @memset(it.variable_store.items, null);
        // Re-inject external variable bindings
        for (external_bindings) |b| {
            if (b.var_id < it.variable_store.items.len) {
                it.variable_store.items[b.var_id] = b.value;
            }
        }
        it.object_construct.clearRetainingCapacity();
        it.object_construct_depth.clearRetainingCapacity();
        it.object_construct_input.clearRetainingCapacity();
        it.if_stack.clearRetainingCapacity();
        it.if_path_comps_stack.clearRetainingCapacity();
        for (it.collect_stack.items) |*frame| frame.buffer.deinit(it.alloc);
        it.collect_stack.clearRetainingCapacity();
        it.call_stack.clearRetainingCapacity();
        it.var_save_stack.clearRetainingCapacity();
        it.current_args = &.{};
        for (it.fork_stack.items) |*fp| {
            it.freeRegexForkSlots(fp);
            switch (fp.aux) {
                .recurse_path => |*state| state.deinit(),
                else => {},
            }
        }
        it.fork_stack.clearRetainingCapacity();
        for (it.path_stack.items) |*frame| frame.deinit(it.alloc);
        it.path_stack.clearRetainingCapacity();
        it.next_break_token = 0;
        it.user_error_msg = null;
        it.type_error_detail = null;
        it.runtime_tape.entries.clearRetainingCapacity();
        it.runtime_tape.string_buf.clearRetainingCapacity();
        it.runtime_tape.refreshView();
        // Retain per-pool clones and the dynamic LRU across resets — the
        // compiled filter (and therefore its regex pool) is unchanged between
        // iterator runs, so recompiling would be pure waste.
        it.last_dynamic_entry = null;
        // Per-record scratch arena: drop every transient allocation from the
        // previous record in a single bump-pointer reset. Worker invariant:
        // no yielded Value points into scratch beyond the record boundary.
        _ = it.scratch.reset(.retain_capacity);
    }

    /// True when null propagation is active (globally via Opts).
    inline fn nullAllowed(it: *const ResultIterator) bool {
        return it.opts_allow_null;
    }

    // ── Value stack operations ──────────────────────────────────────────────────

    fn pushValue(it: *ResultIterator, val: StackValue) void {
        it.value_stack.appendAssumeCapacity(val);
    }

    /// Construct a `Value.StringView` referencing a string interned in this
    /// iterator's `runtime_tape`. Resolved lazily at every read against
    /// `runtime_tape.view.string_buf`, which is append-only — refs are
    /// permanently valid even when the buffer's backing relocates after a
    /// grow. Use this for any string produced by `internString*` whose
    /// `StackValue` (or `Value`) will outlive the producing op. NIX-006.
    fn rtString(it: *ResultIterator, ref: Tape.StringRef) Value.StringView {
        return .{ .tape_ref = .{ .tape = &it.runtime_tape.view, .ref = ref } };
    }

    /// Construct a tape-resident `StackValue.tape_value.string` for a string
    /// interned in `runtime_tape`. See `rtString`.
    fn rtStringSV(it: *ResultIterator, ref: Tape.StringRef) StackValue {
        return .{ .tape_value = .{ .string = it.rtString(ref) } };
    }

    fn popValue(it: *ResultIterator) ZqError!StackValue {
        if (it.value_stack.items.len == 0) return error.TypeError;
        return it.value_stack.pop() orelse return error.TypeError;
    }

    /// Snapshot the current path-tracking state (for fork capture).
    /// Returns zero-initialized snapshot if no path frame is active — that
    /// means restoration is a no-op for forks outside `path(...)` scopes.
    fn snapshotPathState(it: *const ResultIterator) PathSnapshot {
        if (it.path_stack.items.len == 0) return .{};
        const frame = &it.path_stack.items[it.path_stack.items.len - 1];
        return .{
            .stack_len = @intCast(it.path_stack.items.len),
            .components_len = @intCast(frame.components.items.len),
            .path_broken = frame.path_broken,
            .break_origin = frame.break_origin,
            .break_kind = frame.break_kind,
            .break_source = frame.break_source,
            .break_index_n = frame.break_index_n,
            .break_key_s = frame.break_key_s,
            .skip_components_for_computed_key = frame.skip_components_for_computed_key,
            .suspended = frame.suspended,
        };
    }

    /// Restore the path-tracking state to a previously captured snapshot.
    /// Pops frames pushed after the snapshot, then truncates the innermost
    /// frame's components to the saved length and restores its broken flag.
    ///
    /// `stack_len == 0` means "no path frame was active at fork time" — in
    /// that case, we still tear down any inner frames added in the meantime
    /// to keep the path stack consistent.
    fn restorePathState(it: *ResultIterator, snap: PathSnapshot) void {
        while (it.path_stack.items.len > snap.stack_len) {
            var frame = it.path_stack.pop().?;
            frame.deinit(it.alloc);
        }
        if (it.path_stack.items.len > 0) {
            const frame = &it.path_stack.items[it.path_stack.items.len - 1];
            if (frame.components.items.len > snap.components_len) {
                frame.components.shrinkRetainingCapacity(snap.components_len);
            }
            frame.path_broken = snap.path_broken;
            frame.break_origin = snap.break_origin;
            frame.break_kind = snap.break_kind;
            frame.break_source = snap.break_source;
            frame.break_index_n = snap.break_index_n;
            frame.break_key_s = snap.break_key_s;
            frame.skip_components_for_computed_key = snap.skip_components_for_computed_key;
            frame.suspended = snap.suspended;
        }
    }

    /// Snapshot the value_stack contents above the current collect-frame
    /// outer depth (or from 0 if no collect frame is active). Returns null
    /// when no snapshot is needed — i.e., no collect frame AND no object
    /// literal is under construction at fork time.
    ///
    /// Required whenever the fork may resume after intermediate execution
    /// overwrites stack slots below `saved_value_stack_len`. Two cases need
    /// it: (a) collect frames — `yield_output` truncates to outer_value_depth
    /// so slots between outer and saved_len may be stale; (b) object
    /// literals — `object_construct_end` pushes the obj through those same
    /// slots and `yield_output` pops it, leaving stale bits for the next
    /// branch/iteration to trip over.
    fn snapshotValueStackForFork(it: *ResultIterator) error{OutOfMemory}!?[]StackValue {
        // Always snapshot any live stack slots so that on backtrack the
        // second generator branch sees the same left-operand values as the
        // first.  Previously the snapshot was skipped when not inside a
        // collect frame or object literal, but that left stale values at
        // slots [0..saved_value_stack_len) after the first branch consumed
        // and overwrote them (e.g. `a > (b, c)` at top level: first `gt`
        // consumed slot[0]=a and pushed the result there; backtrack restored
        // len to 1, exposing the stale result as the left operand for the
        // second branch).
        const inside_collect = it.collect_stack.items.len > 0;
        const outer: usize = if (inside_collect)
            it.collect_stack.items[it.collect_stack.items.len - 1].outer_value_depth
        else
            0;
        const cur_len = it.value_stack.items.len;
        if (cur_len <= outer) return null;
        const slice = try it.scratch.allocator().alloc(StackValue, cur_len - outer);
        @memcpy(slice, it.value_stack.items[outer..cur_len]);
        return slice;
    }

    /// Restore value_stack from a `saved_stack` snapshot, truncating first
    /// to the outer collect-frame depth (or 0). Snapshot lives in scratch.
    fn restoreValueStackFromSnapshot(it: *ResultIterator, snap: []StackValue) void {
        const outer: usize = if (it.collect_stack.items.len > 0)
            it.collect_stack.items[it.collect_stack.items.len - 1].outer_value_depth
        else
            0;
        it.value_stack.items.len = outer;
        it.value_stack.appendSliceAssumeCapacity(snap);
    }

    /// Snapshot the three object-construction stacks at fork time. Returns
    /// null when all three are empty — the common case for forks outside any
    /// `{...}` literal. Slices are owned by the returned snapshot.
    fn snapshotObjectConstructState(it: *ResultIterator) error{OutOfMemory}!?ObjectConstructSnapshot {
        const d = it.object_construct_depth.items.len;
        const i = it.object_construct_input.items.len;
        const f = it.object_construct.items.len;
        if (d == 0 and i == 0 and f == 0) return null;
        const aa = it.scratch.allocator();
        const fields = try aa.alloc(ObjectField, f);
        @memcpy(fields, it.object_construct.items);
        const depth = try aa.alloc(u32, d);
        @memcpy(depth, it.object_construct_depth.items);
        const input = try aa.alloc(Value, i);
        @memcpy(input, it.object_construct_input.items);
        return .{ .fields = fields, .depth = depth, .input = input };
    }

    /// Restore object-construction stacks from a fork-time snapshot. Replaces
    /// current stack contents with the snapshot. Snapshot lives in scratch.
    fn restoreObjectConstructState(it: *ResultIterator, snap: ObjectConstructSnapshot) void {
        it.object_construct.items.len = 0;
        it.object_construct.appendSliceAssumeCapacity(snap.fields);
        it.object_construct_depth.items.len = 0;
        it.object_construct_depth.appendSliceAssumeCapacity(snap.depth);
        it.object_construct_input.items.len = 0;
        it.object_construct_input.appendSliceAssumeCapacity(snap.input);
    }

    /// Truncate the fork stack to `new_len`. saved_stack/saved_object/scan-slot
    /// buffers live in the per-record scratch arena — no free needed; the
    /// recurse_path state still owns its own GPA heap and must be torn down.
    fn truncateForkStack(it: *ResultIterator, new_len: usize) void {
        var i = it.fork_stack.items.len;
        while (i > new_len) {
            i -= 1;
            const fp = &it.fork_stack.items[i];
            it.freeRegexForkSlots(fp);
            switch (fp.aux) {
                .scan, .match_g, .splits => fp.aux = .{ .normal = {} },
                .recurse_path => |*state| {
                    state.deinit();
                    fp.aux = .{ .normal = {} };
                },
                else => {},
            }
        }
        it.fork_stack.items.len = new_len;
    }

    // ── Variable operations ─────────────────────────────────────────
    fn setVariable(it: *ResultIterator, var_id: u32, val: StackValue) void {
        if (var_id >= it.variable_store.items.len) return;
        it.variable_store.items[var_id] = val;
    }

    fn getVariable(it: *ResultIterator, var_id: u32) ZqError!StackValue {
        if (var_id >= it.variable_store.items.len) return error.TypeError;
        const opt_val = it.variable_store.items[var_id];
        return opt_val orelse error.TypeError;
    }

    fn clearVariable(it: *ResultIterator, var_id: u32) void {
        if (var_id < it.variable_store.items.len) {
            it.variable_store.items[var_id] = null;
        }
    }

    /// Truncate `call_stack` to `target_len`, restoring each popped frame's
    /// variable-slot snapshots and value_stack contents in LIFO order.
    /// Replaces direct `call_stack.items.len = X` writes wherever a
    /// forkpoint backtrack or label/break unwind crosses a recursive call
    /// boundary; without this, a recursive frame's saved slots would leak
    /// on var_save_stack and the caller's value_stack would be lost.
    ///
    /// Capacity for value_stack is preserved across the call (clear-then-
    /// restore reuses the same buffer), so `appendSliceAssumeCapacity`
    /// cannot allocate. If a body grew the buffer, the saved slice still
    /// fits; if it shrunk (no caller does), the caller's resize-up would
    /// have failed earlier.
    fn truncateCallStackTo(it: *ResultIterator, target_len: usize) void {
        while (it.call_stack.items.len > target_len) {
            const frame = it.call_stack.pop().?;
            if (frame.returned) {
                // NIX-011 deferred-pop: yielded frame — caller-state
                // value_stack / variable_store / current_args were
                // already established at yield. Just discard the
                // var_save_stack entries this frame owned.
                it.var_save_stack.items.len = frame.saved_var_len;
                continue;
            }
            while (it.var_save_stack.items.len > frame.saved_var_len) {
                const sv = it.var_save_stack.pop().?;
                if (sv.id < it.variable_store.items.len) {
                    it.variable_store.items[sv.id] = sv.prev;
                }
            }
            it.value_stack.clearRetainingCapacity();
            it.value_stack.ensureTotalCapacity(it.alloc, frame.saved_stack.len) catch {
                // OOM here would only fire if the caller's previously-
                // sized buffer was shrunk by something else mid-call,
                // which no opcode does. Fall back to a best-effort
                // restore: append what fits, drop the rest.
                const fit = @min(it.value_stack.capacity, frame.saved_stack.len);
                it.value_stack.appendSliceAssumeCapacity(frame.saved_stack[0..fit]);
                it.current_args = frame.saved_args;
                continue;
            };
            it.value_stack.appendSliceAssumeCapacity(frame.saved_stack);
            // Mirror return_function's restore: peel off this frame's
            // arg context as the call_stack drops below it. The fork
            // that drove this truncate (alt/break/etc.) will then
            // override `current_args` from its own snapshot in
            // `backtrackToDepth`. NIX-011.
            it.current_args = frame.saved_args;
        }
    }

    /// Advance and return the next output value, or null when complete.
    pub fn next(it: *ResultIterator) ZqError!?Value {
        if (it.done) return null;

        // Resolve the root value here so &self.tape is the iterator's final address,
        // not the temporary address inside execute() before the struct was returned.
        if (!it.initialized) {
            it.initialized = true;
            if (it.tape.entries.len == 0) {
                it.done = true;
                return null;
            }
            it.current = tapeEntryToValue(&it.tape, 0);
            // Store input value for object construction to reference
            it.input_value = it.current;
        }

        return it.step();
    }

    // ── VM loop ───────────────────────────────────────────────────────────────

    /// Outer dispatch loop. Handles exhaustion/frame advancement and routes errors
    /// to the active try frame (if any), propagating uncaught errors to the caller.
    fn step(it: *ResultIterator) ZqError!?Value {
        while (true) {
            if (it.ip >= it.instructions.len) {
                // Try fork-stack backtracking (handles comma, each, range, try, alt, label, limit).
                if (try it.doBacktrack()) continue;

                // No forkpoints — check for collect frame finalization.
                if (it.collect_stack.items.len > 0) {
                    const end_ip = it.collect_stack.items[it.collect_stack.items.len - 1].end_ip;
                    const outer_if_depth = it.collect_stack.items[it.collect_stack.items.len - 1].outer_if_depth;
                    it.if_stack.items.len = outer_if_depth;
                    it.if_path_comps_stack.items.len = outer_if_depth;
                    // Jump to the matching array_collect_end instruction so it
                    // executes through execOne. This ensures path-tracking hooks
                    // (breaksPath / clearsPathBroken) fire just as they would in
                    // the non-generator code path, avoiding the need to duplicate
                    // the path_broken=upstream_value logic here.
                    it.ip = end_ip;
                    continue;
                }

                it.done = true;
                return null;
            }

            const saved_ip = it.ip;
            const instr = it.instructions[it.ip];
            if (it.execOne(instr)) |maybe_val| {
                if (maybe_val) |v| return v;
                // null → no output produced; continue main loop
            } else |err| {
                if (try it.handleError(err)) {
                    if (it.done) return null;
                    // Continue executing at catch handler (or done path handled above).
                } else {
                    it.last_error_ip = saved_ip;
                    return err;
                }
            }
        }
    }

    /// Scan fork_stack for the nearest try_handler or alt_handler, unwind to it,
    /// and route execution to the catch handler (or suppress).
    /// Returns true if an error handler was found, false if error should propagate.
    /// Returns ZqError only if the suppressed-error backtrack itself fails
    /// (e.g. a scan generator hits OOM while advancing).
    fn handleError(it: *ResultIterator, err: ZqError) ZqError!bool {
        var idx = it.fork_stack.items.len;
        while (idx > 0) {
            idx -= 1;
            const fp = it.fork_stack.items[idx];
            const state = switch (fp.aux) {
                .try_handler, .alt_handler => |s| s,
                else => continue,
            };

            // Unwind fork stack (pops generators between error and handler).
            it.truncateForkStack(idx);
            // Unwind other stacks.
            it.value_stack.items.len = fp.saved_value_stack_len;
            it.if_stack.items.len = state.saved_if_len;
            it.if_path_comps_stack.items.len = state.saved_if_len;
            // Unwind collect frames (free buffers).
            while (it.collect_stack.items.len > state.saved_collect_len) {
                var cf = it.collect_stack.pop().?;
                cf.buffer.deinit(it.alloc);
            }
            it.truncateCallStackTo(state.saved_call_len);
            // Catch handler runs in the lexical context where the
            // try/alt was opened — same args that were live when fp
            // was pushed. truncateCallStackTo already restored
            // current_args to that depth's frame; mirror the explicit
            // restore that fire-paths in backtrackToDepth perform so
            // the contract "current_args reflects fp.saved_current_args
            // after a fire" holds uniformly. NIX-011.
            it.current_args = fp.saved_current_args;

            if (state.catch_ip > 0) {
                // Route to catch handler with error as current.
                if (err == error.UserError) {
                    it.current = it.user_error_msg orelse Value{ .string = .{ .external = "null" } };
                    it.user_error_msg = null;
                } else if (err == error.TypeError and it.type_error_detail != null) {
                    it.current = it.type_error_detail.?;
                    it.type_error_detail = null;
                } else {
                    it.current = Value{ .string = .{ .external = errorToString(err) } };
                }
                it.ip = state.catch_ip;
            } else {
                // Suppress: backtrack to next generator path.
                if (it.collect_stack.items.len > 0) {
                    const cf = &it.collect_stack.items[it.collect_stack.items.len - 1];
                    it.value_stack.items.len = cf.outer_value_depth;
                } else {
                    it.value_stack.items.len = fp.saved_value_stack_len;
                }

                if (!(try it.doBacktrack())) {
                    it.ip = @intCast(it.instructions.len);
                }
            }
            return true;
        }
        return false;
    }

    /// Execute a single instruction. Returns:
    ///   .{val} — the instruction produced an output value; caller should yield it.
    ///   null   — no output; caller should continue the main loop.
    ///   error  — a runtime error occurred; caller checks for an active try frame.
    fn execOne(it: *ResultIterator, instr: Instruction) ZqError!?Value {
        // path(f) validation: if a path frame is active and the about-to-fire
        // opcode breaks the path invariant, mark the innermost frame. The
        // error is deferred to `path_end` so jq's message can serialize the
        // body's result value (on top of value_stack at that point).
        //
        // A path-descent / restore-input op that follows clears the flag
        // (see `clearsPathBroken`) — that's applied after the op's body runs,
        // below, so the component/restore is actually performed.
        //
        // Exception: `call_builtin` with a path-emitting builtin (`paths`,
        // `leaf_paths`, `recurse`/`..`) is treated as preserving inside a
        // `path(f)` frame — these builtins yield path arrays directly and
        // `path_end` uses the body's current value as the result. See
        // `callBuiltinIsPathEmittingInFrame`.
        if (it.path_stack.items.len > 0 and instr.op.breaksPath()) {
            const is_path_emit = instr.op == .call_builtin and
                callBuiltinIsPathEmittingInFrame(types.builtinIdOf(instr.operand.index));
            const suspended = it.path_stack.items[it.path_stack.items.len - 1].suspended;
            if (!is_path_emit and !suspended) {
                const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                frame.path_broken = true;
                // Ops that produce a derived container value (array/object
                // constructor end, most builtins) cannot legitimately be
                // navigated as path steps. Mark as upstream so that
                // clearsPathBroken is suppressed when a descent op follows.
                // The break_source (value being navigated) is recorded by
                // the descent op itself (it.current at that point).
                // Literals and arithmetic are same-step scratch: a following
                // descent op is using them as a computed key and CAN clear.
                // Array/object constructors produce derived containers that
                // cannot be navigated as path steps — mark as upstream so
                // clearsPathBroken is suppressed when a descent op follows.
                // call_builtin, literals, and arithmetic are same-step
                // scratch: the descent op is computing a key and CAN clear.
                if (instr.op == .array_collect_end or
                    instr.op == .object_construct_end)
                {
                    frame.break_origin = .upstream_value;
                } else {
                    frame.break_origin = .same_step_scratch;
                }
            }
        }

        const result = try it.execOneInner(instr);
        if (it.path_stack.items.len > 0 and instr.op.clearsPathBroken()) {
            const frame = &it.path_stack.items[it.path_stack.items.len - 1];
            // Only clear path_broken for same-step scratch (literals/arith
            // used to compute a key). When break_origin is upstream_value
            // (a value that was piped to become the navigation source), the
            // descent op is navigating a non-path value — don't clear.
            // Skip while the frame is suspended: LHS of an `as` binding does
            // not interact with the surrounding path's broken-state at all.
            if (!frame.suspended and frame.break_origin == .same_step_scratch) {
                frame.path_broken = false;
            }
        }
        return result;
    }

    /// Inner dispatch of a single opcode. Wrapper `execOne` adds the path(f)
    /// validation pre- and post-hooks around the dispatch.
    fn execOneInner(it: *ResultIterator, instr: Instruction) ZqError!?Value {
        switch (instr.op) {
            .identity => {
                it.ip += 1;
                return null;
            },

            .pipe => {
                // Transfer the top of the value stack to it.current so that the
                // right-hand side of a pipe (e.g. builtins, field access) receives
                // the correct input value.  When the stack is empty the current
                // value is already correct because the preceding op set it.current
                // directly without pushing — namely: `each` (per-element on entry
                // and on each backtrack via advanceEachForkpoint); fork-based
                // generator builtins that drive iteration through `it.current`
                // (range, recurse, paths, leaf_paths, scan, match (//g), splits,
                // repeat); update-mode descents `navigate_key`/`navigate_index`;
                // and `restore_input`. NOTE: as of B1/B6, `load_key`,
                // `load_index`, `load_path`, and `load_computed` push their
                // result and so always go through the popValue branch above.
                if (it.value_stack.items.len > 0) {
                    it.current = try stackValueToValue(try it.popValue());
                }
                it.ip += 1;
                return null;
            },

            .load_key => {
                const key = it.string_buf[instr.operand.str_ref.offset..][0..instr.operand.str_ref.len];
                // When an upstream call_builtin has broken the path, a key
                // descent on its result cannot represent a valid path step.
                // Record the per-kind break details and defer the error to
                // path_end. Skip the actual lookup and push null as a
                // placeholder so the instruction stream remains consistent.
                if (it.path_stack.items.len > 0) {
                    const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                    if (frame.path_broken and frame.break_origin == .upstream_value) {
                        // Only record key_s details if no more-specific
                        // break_kind was already recorded (e.g. by 'each').
                        if (frame.break_kind == .generic) {
                            frame.break_kind = .key_s;
                            frame.break_key_s = key;
                            frame.break_source = it.current;
                        }
                        it.pushValue(.{ .tape_value = .null_val });
                        it.ip += 1;
                        return null;
                    }
                }
                const result = lookupKeyInValue(
                    &it.tape,
                    it.nullAllowed(),
                    it.current,
                    key,
                ) catch |err| {
                    if (err == error.TypeError) {
                        it.type_error_detail = it.buildTypeErrorMsg(it.current, .{ .index_string = key });
                    }
                    return err;
                };
                // Record path component if path tracking is active and not
                // suppressed for computed-key meta-ops or suspended (LHS of
                // an `as` binding).
                if (it.path_stack.items.len > 0) {
                    const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                    if (!frame.skipComponents()) {
                        try frame.components.append(it.alloc, .{ .string = .{ .external = key } });
                    }
                }
                // Push result to value stack. Do NOT update it.current here — the
                // pipe opcode (or explicit | between stages) is responsible for
                // advancing it.current. This ensures both operands of .a + .b see
                // the same original input rather than the left operand's result.
                const result_sv = try valueToStackValue(result);
                it.pushValue(result_sv);
                it.ip += 1;
                return null;
            },

            .load_index => {
                const idx = instr.operand.index;
                // When an upstream call_builtin has broken the path, record
                // per-kind break details. The actual load still executes so
                // the value stack stays consistent; path_end raises the error.
                if (it.path_stack.items.len > 0) {
                    const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                    if (frame.path_broken and frame.break_origin == .upstream_value) {
                        // Only record index_n details if no more-specific
                        // break_kind was already recorded (e.g. by 'each').
                        if (frame.break_kind == .generic) {
                            frame.break_kind = .index_n;
                            frame.break_index_n = idx;
                            frame.break_source = it.current;
                        }
                    }
                }
                const idx_result = try it.doLoadIndex(idx);
                if (it.path_stack.items.len > 0) {
                    const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                    const skip = frame.skipComponents() or
                        (frame.path_broken and frame.break_origin == .upstream_value);
                    if (!skip) {
                        try frame.components.append(it.alloc, .{ .int = idx });
                    }
                }
                it.pushValue(try valueToStackValue(idx_result));
                it.ip += 1;
                return null;
            },

            .load_computed => {
                // When an inner path(f) result was consumed as the computed
                // key, the skip_components flag on the outer frame was set to
                // suppress meta-level descent ops (load_index on path array).
                // Clear it here so this load_computed records its component.
                if (it.path_stack.items.len > 0) {
                    it.path_stack.items[it.path_stack.items.len - 1]
                        .skip_components_for_computed_key = false;
                }
                // Key/index: pop from value_stack if non-empty, else use current.
                const key_sv = if (it.value_stack.items.len > 0)
                    try it.popValue()
                else
                    try valueToStackValue(it.current);
                // Base: pop from if_stack (pushed by save_input before inner expr).
                if (it.if_stack.items.len == 0) return error.TypeError;
                const base = it.if_stack.pop().?;
                // B6 fix: push the result onto value_stack (do NOT set
                // it.current) so that `load_computed` behaves consistently
                // with `load_key` / `load_path`. Without this, a `pipe`
                // following `load_computed` inside an object-field value
                // expression would pop the field KEY off the stack instead
                // of the lookup result, because `load_computed` set
                // it.current directly and left the key as top-of-stack.
                // Mirrors the B1 fix for `load_path` at vm/root.zig:1546.
                const result: Value = switch (key_sv) {
                    .tape_value => |tv| switch (tv) {
                        .string => |s| blk: {
                            // Record path component if path tracking is active
                            // and not suspended.
                            if (it.path_stack.items.len > 0) {
                                const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                                if (!frame.skipComponents()) {
                                    try frame.components.append(it.alloc, .{ .string = s });
                                }
                            }
                            break :blk switch (base) {
                                .object => |span| lookupKey(span.tape, span, s.slice()) orelse @as(Value, .null_val),
                                .null_val => @as(Value, .null_val),
                                else => {
                                    it.type_error_detail = it.buildTypeErrorMsg(base, .{ .index_string = s.slice() });
                                    return error.TypeError;
                                },
                            };
                        },
                        else => return error.TypeError,
                    },
                    .int => |i| blk: {
                        // Record path component if path tracking is active
                        // and not suspended.
                        if (it.path_stack.items.len > 0) {
                            const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                            if (!frame.skipComponents()) {
                                try frame.components.append(it.alloc, .{ .int = i });
                            }
                        }
                        break :blk switch (base) {
                            .array => |span| blk2: {
                                const resolved_idx = if (i < 0) blk3: {
                                    const len = arrayLength(span.tape, span);
                                    const neg_idx = @as(i64, @intCast(len)) + i;
                                    if (neg_idx < 0 or neg_idx > std.math.maxInt(u32)) break :blk2 @as(Value, .null_val);
                                    break :blk3 @as(u32, @intCast(neg_idx));
                                } else blk4: {
                                    if (i > std.math.maxInt(u32)) break :blk2 @as(Value, .null_val);
                                    break :blk4 @as(u32, @intCast(i));
                                };
                                break :blk2 lookupIndex(span.tape, span, resolved_idx) orelse .null_val;
                            },
                            // jq: indexing null with an integer yields null.
                            .null_val => @as(Value, .null_val),
                            else => return error.TypeError,
                        };
                    },
                    // jq: float index on array truncates to int; nan/inf → null.
                    // Path tracking: nan/inf are recorded as `null` components
                    // (matching jq's `path(.[nan])` → `[null]`).
                    .float => |f| switch (base) {
                        .array => |span| blk: {
                            if (std.math.isNan(f) or std.math.isInf(f)) {
                                if (it.path_stack.items.len > 0) {
                                    const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                                    if (!frame.skipComponents()) {
                                        try frame.components.append(it.alloc, .null_val);
                                    }
                                }
                                break :blk @as(Value, .null_val);
                            }
                            const i: i64 = @intFromFloat(@trunc(f));
                            // Record path component if path tracking is active
                            // and not suspended.
                            if (it.path_stack.items.len > 0) {
                                const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                                if (!frame.skipComponents()) {
                                    try frame.components.append(it.alloc, .{ .int = i });
                                }
                            }
                            const resolved_idx = if (i < 0) blk2: {
                                const len = arrayLength(span.tape, span);
                                const neg_idx = @as(i64, @intCast(len)) + i;
                                if (neg_idx < 0 or neg_idx > std.math.maxInt(u32)) break :blk @as(Value, .null_val);
                                break :blk2 @as(u32, @intCast(neg_idx));
                            } else blk3: {
                                if (i > std.math.maxInt(u32)) break :blk @as(Value, .null_val);
                                break :blk3 @as(u32, @intCast(i));
                            };
                            break :blk lookupIndex(span.tape, span, resolved_idx) orelse .null_val;
                        },
                        .null_val => if (it.nullAllowed()) @as(Value, .null_val) else return error.TypeError,
                        .string => {
                            // jq: indexing a string with a float raises a catchable
                            // UserError "Cannot index string with number (<f>)".
                            it.type_error_detail = it.buildTypeErrorMsg(base, .{ .index_number_float = f });
                            return error.TypeError;
                        },
                        else => return error.TypeError,
                    },
                    // jq: null index on anything returns null. Path tracking
                    // records `null` as the component to match jq's
                    // `path(.[null])` → `[null]`.
                    .null_val => blk: {
                        if (it.path_stack.items.len > 0) {
                            const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                            if (!frame.skipComponents()) {
                                try frame.components.append(it.alloc, .null_val);
                            }
                        }
                        break :blk @as(Value, .null_val);
                    },
                    else => return error.TypeError,
                };
                it.pushValue(try valueToStackValue(result));
                it.ip += 1;
                return null;
            },

            .load_path => {
                // B1 fix: push the result onto value_stack (do NOT set
                // it.current) so that `load_path` behaves consistently
                // with `load_key`.  The pipe opcode that always follows
                // `load_path` in the instruction stream (either from an
                // explicit user `|` or from the binary-op save_input path)
                // will pop the result into it.current for downstream
                // consumers.  Without this change, `pipe` after `load_path`
                // inside an object-field value expression would pop the
                // field KEY off the stack instead of the path result,
                // because `load_path` set it.current directly and left the
                // key as the top-of-stack item.  Aligning with `load_key`
                // semantics keeps the stack protocol uniform across all
                // field-access opcodes.
                const path = it.string_buf[instr.operand.str_ref.offset..][0..instr.operand.str_ref.len];
                if (it.path_stack.items.len > 0) {
                    const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                    if (!frame.skipComponents()) {
                        var segs = std.mem.splitScalar(u8, path, '.');
                        while (segs.next()) |seg| {
                            try frame.components.append(it.alloc, .{ .string = .{ .external = seg } });
                        }
                    }
                }
                const result = try it.doLoadPath(path);
                it.pushValue(try valueToStackValue(result));
                it.ip += 1;
                return null;
            },

            .slice => {
                const args = instr.operand.slice_args;
                // Record slice path component if path tracking is active
                // and not suspended.
                // jq stores literal bounds (negative allowed, missing bound = null).
                if (it.path_stack.items.len > 0) {
                    const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                    if (!frame.skipComponents()) {
                        const slice_obj = try it.buildSlicePathComponent(args);
                        try frame.components.append(it.alloc, slice_obj);
                    }
                }
                const result = try it.doSlice(args);
                it.pushValue(result);
                it.ip += 1;
                return null;
            },

            .slice_computed => {
                // `.[<from_expr>:<to_expr>]` — at least one bound is an
                // expression. Bounds were pushed onto `value_stack` in
                // from-then-to order by `emitSliceComputed`; pop them in
                // reverse (`to` first, then `from`). The slice base was
                // pushed onto `if_stack` via the `save_input` that
                // bracketed this opcode.
                const op_args = instr.operand.slice_args;
                var resolved = types.SliceArgs{
                    .from = op_args.from,
                    .to = op_args.to,
                    .has_from = op_args.has_from,
                    .has_to = op_args.has_to,
                };
                if (op_args.has_to_expr) {
                    if (it.value_stack.items.len == 0) return error.TypeError;
                    const to_sv = try it.popValue();
                    resolved.to = try it.sliceBoundFromStackValue(to_sv, .to_bound);
                    // NaN to-bound is treated as absent (use len), matching jq's
                    // behaviour: `.[1:nan]` on an array yields `.[1:]`.
                    resolved.has_to = to_sv != .null_val and
                        !(to_sv == .float and std.math.isNan(to_sv.float));
                }
                if (op_args.has_from_expr) {
                    if (it.value_stack.items.len == 0) return error.TypeError;
                    const from_sv = try it.popValue();
                    resolved.from = try it.sliceBoundFromStackValue(from_sv, .from_bound);
                    resolved.has_from = from_sv != .null_val;
                }
                if (it.if_stack.items.len == 0) return error.TypeError;
                it.current = it.if_stack.pop().?;
                if (it.path_stack.items.len > 0) {
                    const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                    if (!frame.skipComponents()) {
                        const slice_obj = try it.buildSlicePathComponent(resolved);
                        try frame.components.append(it.alloc, slice_obj);
                    }
                }
                const result = try it.doSlice(resolved);
                it.pushValue(result);
                it.ip += 1;
                return null;
            },

            .navigate_key => {
                const key = it.string_buf[instr.operand.str_ref.offset..][0..instr.operand.str_ref.len];
                it.current = lookupKeyInValue(&it.tape, it.nullAllowed(), it.current, key) catch |err| {
                    if (err == error.TypeError) {
                        it.type_error_detail = it.buildTypeErrorMsg(it.current, .{ .index_string = key });
                    }
                    return err;
                };
                it.ip += 1;
                return null;
            },

            .navigate_index => {
                it.current = try it.doLoadIndex(instr.operand.index);
                it.ip += 1;
                return null;
            },

            .update_key => {
                const key = it.string_buf[instr.operand.str_ref.offset..][0..instr.operand.str_ref.len];
                const result = try it.doUpdateKey(key);
                it.current = try stackValueToValue(result);
                it.pushValue(result);
                it.ip += 1;
                return null;
            },

            .update_index => {
                const result = try it.doUpdateIndex(instr.operand.index);
                it.current = try stackValueToValue(result);
                it.pushValue(result);
                it.ip += 1;
                return null;
            },

            .push_bool => {
                it.pushValue(.{ .bool_val = instr.operand.bool });
                it.ip += 1;
                return null;
            },

            .push_int => {
                it.pushValue(.{ .int = instr.operand.int });
                it.ip += 1;
                return null;
            },

            .push_float => {
                it.pushValue(.{ .float = instr.operand.float });
                it.ip += 1;
                return null;
            },

            .push_null => {
                it.pushValue(.null_val);
                it.ip += 1;
                return null;
            },

            .push_string => {
                const str_ref = instr.operand.str_ref;
                const str = it.string_buf[str_ref.offset..][0..str_ref.len];
                it.pushValue(.{ .tape_value = .{ .string = .{ .external = str } } });
                it.ip += 1;
                return null;
            },

            .push_big_number => {
                const str_ref = instr.operand.str_ref;
                const text = it.string_buf[str_ref.offset..][0..str_ref.len];
                it.pushValue(.{ .big_number = text });
                it.ip += 1;
                return null;
            },

            .push_current => {
                it.pushValue(try valueToStackValue(it.current));
                it.ip += 1;
                return null;
            },

            // Conditional branching
            .save_input => {
                it.if_stack.appendAssumeCapacity(it.current);
                // Also save the current path frame's components length (or sentinel
                // when no path frame is active) so restore_input can truncate any
                // path components appended by navigations inside the if/elif condition.
                const comps_len: u32 = if (it.path_stack.items.len > 0)
                    @intCast(it.path_stack.items[it.path_stack.items.len - 1].components.items.len)
                else
                    std.math.maxInt(u32);
                it.if_path_comps_stack.appendAssumeCapacity(comps_len);
                it.ip += 1;
                return null;
            },

            .restore_input => {
                if (it.if_stack.items.len == 0) return error.TypeError;
                it.current = it.if_stack.pop().?;
                // Restore path components to the saved length to undo any navigations
                // that occurred inside the if/elif condition body.
                if (it.if_path_comps_stack.pop()) |saved_len| {
                    if (saved_len != std.math.maxInt(u32) and it.path_stack.items.len > 0) {
                        const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                        if (frame.components.items.len > saved_len) {
                            frame.components.shrinkRetainingCapacity(saved_len);
                        }
                    }
                }
                it.ip += 1;
                return null;
            },

            // Array construction
            .array_collect_start => {
                var buf = std.ArrayList(StackValue){};
                errdefer buf.deinit(it.alloc);
                try buf.ensureTotalCapacity(it.alloc, 32);
                try it.collect_stack.append(it.alloc, CollectFrame{
                    .buffer = buf,
                    .outer_value_depth = @intCast(it.value_stack.items.len),
                    .outer_if_depth = @intCast(it.if_stack.items.len),
                    .outer_fork_depth = @intCast(it.fork_stack.items.len),
                    .end_ip = @intCast(instr.operand.index),
                });
                it.ip += 1;
                return null;
            },

            .array_collect_end => {
                // Reached when: (a) inner expr is empty [], or (b) output handler
                // jumped here after the last (non-iterating) element.
                var completed = it.collect_stack.pop().?;
                defer completed.buffer.deinit(it.alloc);
                const arr_val = try it.buildCollectedArray(&completed);
                it.pushValue(arr_val);
                it.ip += 1;
                return null;
            },

            // ── Fork-based try/alt/pop_try ────────────────────────────────
            .fork_try => {
                const handler_state = TryHandlerState{
                    .catch_ip = @intCast(instr.operand.index),
                    .saved_if_len = @intCast(it.if_stack.items.len),
                    .saved_collect_len = @intCast(it.collect_stack.items.len),
                    .saved_call_len = @intCast(it.call_stack.items.len),
                };
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .saved_current_args = it.current_args,
                    .saved_call_len = @intCast(it.call_stack.items.len),
                    .backtrack_ip = @intCast(instr.operand.index),
                    .aux = .{ .try_handler = handler_state },
                    .saved_path = it.snapshotPathState(),
                });
                it.ip += 1;
                return null;
            },
            .fork_alt => {
                const handler_state = TryHandlerState{
                    .catch_ip = @intCast(instr.operand.index),
                    .saved_if_len = @intCast(it.if_stack.items.len),
                    .saved_collect_len = @intCast(it.collect_stack.items.len),
                    .saved_call_len = @intCast(it.call_stack.items.len),
                };
                const saved_stack = try it.snapshotValueStackForFork();
                const saved_object = try it.snapshotObjectConstructState();
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .saved_current_args = it.current_args,
                    .saved_call_len = @intCast(it.call_stack.items.len),
                    .backtrack_ip = @intCast(instr.operand.index),
                    .aux = .{ .alt_handler = handler_state },
                    .saved_path = it.snapshotPathState(),
                    .saved_stack = saved_stack,
                    .saved_object = saved_object,
                });
                it.ip += 1;
                return null;
            },

            .pop_try => {
                // Scan fork_stack backwards for nearest try_handler or alt_handler and remove it.
                //
                // Generator-aware deferral: when a try_handler is found, check whether
                // any active generator frame (each, range, fork/comma, repeat, scan, etc.)
                // sits between the handler and the top of the stack. Such frames were
                // pushed *inside* the try body and represent iterations that have not
                // completed yet. Removing the handler now would leave those future
                // iterations without an error catcher — the handler must persist until
                // the generators exhaust or an error fires. In that case we skip the
                // removal; backtrackToDepth will pop the handler naturally once the
                // last generator frame below it is gone.
                //
                // alt_handler (the `//` operator) does not require this treatment: its
                // semantics are falsy-suppression on a per-value basis rather than
                // spanning multiple generator iterations.
                var idx = it.fork_stack.items.len;
                while (idx > 0) {
                    idx -= 1;
                    switch (it.fork_stack.items[idx].aux) {
                        .try_handler => {
                            // If any generator frame sits above this handler (i.e. was
                            // pushed after it, inside the try body), leave the handler in
                            // place so it can catch errors from subsequent iterations.
                            var has_gen_above = false;
                            for (it.fork_stack.items[idx + 1 ..]) |frame| {
                                switch (frame.aux) {
                                    .each, .range, .normal, .repeat, .scan, .match_g, .splits, .limit, .skip, .path_scope, .label => {
                                        has_gen_above = true;
                                        break;
                                    },
                                    else => {},
                                }
                            }
                            if (has_gen_above) break; // defer to backtrackToDepth
                            _ = it.fork_stack.orderedRemove(idx);
                            break;
                        },
                        .alt_handler => {
                            _ = it.fork_stack.orderedRemove(idx);
                            break;
                        },
                        else => {},
                    }
                }
                it.ip += 1;
                return null;
            },

            .jump => {
                it.ip = @intCast(instr.operand.index);
                return null;
            },

            .jump_if_false => {
                const cond = if (it.value_stack.items.len > 0)
                    try it.popValue()
                else
                    try valueToStackValue(it.current);
                if (!isCondTruthy(cond)) {
                    it.ip = @intCast(instr.operand.index);
                } else {
                    it.ip += 1;
                }
                return null;
            },

            // Object construction operations
            .object_construct_start => {
                // Save the current field count so nested object constructions
                // don't clobber the outer object's fields.
                it.object_construct_depth.appendAssumeCapacity(@intCast(it.object_construct.items.len));
                // Snapshot the input `.` for this object literal so every field's
                // value expression evaluates against the same context.
                it.object_construct_input.appendAssumeCapacity(it.current);
                it.ip += 1;
                return null;
            },

            .object_key => {
                // Get value from stack if available, otherwise use current.
                // 2 items on stack = key + value; 1 item = just key.
                const value = if (it.value_stack.items.len > 1)
                    try it.popValue()
                else
                    try valueToStackValue(it.current);

                const key_val = try it.popValue();

                const key = switch (key_val) {
                    .tape_value => |tv| switch (tv) {
                        .string => |s| s,
                        else => return error.TypeError,
                    },
                    else => return error.TypeError,
                };

                it.object_construct.appendAssumeCapacity(ObjectField{
                    .key = key,
                    .value = value,
                });

                // Restore current to the snapshot taken at object_construct_start
                // so the next field's value expression sees the same `.` as the
                // first one (rather than whatever this field's expression left).
                const depth = it.object_construct_input.items.len;
                it.current = it.object_construct_input.items[depth - 1];
                it.ip += 1;
                return null;
            },

            .object_construct_end => {
                // Pop the depth marker to find where this level's fields start.
                const saved_depth = if (it.object_construct_depth.items.len > 0)
                    it.object_construct_depth.pop().?
                else
                    0;
                if (it.object_construct_input.items.len > 0) {
                    _ = it.object_construct_input.pop();
                }
                const obj = try it.constructObjectFromFieldsRange(saved_depth);
                // Truncate back to the saved depth, removing this level's fields.
                it.object_construct.items.len = saved_depth;
                it.pushValue(obj);
                it.ip += 1;
                return null;
            },

            .add => {
                const result = try it.doAdd();
                it.pushValue(result);
                it.ip += 1;
                return null;
            },

            .sub => {
                const result = try it.doSub();
                it.pushValue(result);
                it.ip += 1;
                return null;
            },

            .mul => {
                const result = try it.doMul();
                it.pushValue(result);
                it.ip += 1;
                return null;
            },

            .div => {
                const result = try it.doDiv();
                it.pushValue(result);
                it.ip += 1;
                return null;
            },

            .mod => {
                const result = try it.doMod();
                it.pushValue(result);
                it.ip += 1;
                return null;
            },

            .eq => {
                const result = try it.doEq();
                it.pushValue(.{ .bool_val = result });
                it.ip += 1;
                return null;
            },

            .ne => {
                const result = try it.doNe();
                it.pushValue(.{ .bool_val = result });
                it.ip += 1;
                return null;
            },

            .lt => {
                const result = try it.doLt();
                it.pushValue(.{ .bool_val = result });
                it.ip += 1;
                return null;
            },

            .le => {
                const result = try it.doLe();
                it.pushValue(.{ .bool_val = result });
                it.ip += 1;
                return null;
            },

            .gt => {
                const result = try it.doGt();
                it.pushValue(.{ .bool_val = result });
                it.ip += 1;
                return null;
            },

            .ge => {
                const result = try it.doGe();
                it.pushValue(.{ .bool_val = result });
                it.ip += 1;
                return null;
            },

            .and_op => {
                try it.doAndOp();
                it.ip += 1;
                return null;
            },

            .or_op => {
                try it.doOrOp();
                it.ip += 1;
                return null;
            },

            .not => {
                const val = if (it.value_stack.items.len > 0)
                    try it.popValue()
                else
                    try valueToStackValue(it.current);
                it.pushValue(.{ .bool_val = !isCondTruthy(val) });
                it.ip += 1;
                return null;
            },

            .negate => {
                const val = if (it.value_stack.items.len > 0)
                    try it.popValue()
                else
                    try valueToStackValue(it.current);
                const result: StackValue = switch (val) {
                    .int => |i| .{ .int = -i },
                    .float => |f| .{ .float = -f },
                    .big_number => |bn| blk: {
                        if (bn.len > 0 and bn[0] == '-') break :blk .{ .big_number = bn[1..] };
                        var buf = std.ArrayList(u8){};
                        defer buf.deinit(it.alloc);
                        try buf.append(it.alloc, '-');
                        try buf.appendSlice(it.alloc, bn);
                        const sref = try it.runtime_tape.internString(it.alloc, buf.items);
                        break :blk .{ .big_number = it.runtime_tape.view.string_buf[sref.offset..][0..sref.len] };
                    },
                    else => {
                        it.type_error_detail = it.buildTypeErrorMsg(
                            try stackValueToValue(val),
                            .negate,
                        );
                        return error.TypeError;
                    },
                };
                it.pushValue(result);
                it.ip += 1;
                return null;
            },

            .capture_variable => {
                const var_id = @as(u32, @intCast(instr.operand.index));
                const val = if (it.value_stack.items.len > 0)
                    try it.popValue()
                else
                    try valueToStackValue(it.current);
                it.setVariable(var_id, val);
                it.ip += 1;
                return null;
            },

            .load_variable => {
                const var_id = @as(u32, @intCast(instr.operand.index));
                const val = try it.getVariable(var_id);
                it.pushValue(val);
                it.ip += 1;
                return null;
            },

            .pop_variable => {
                const var_id = @as(u32, @intCast(instr.operand.index));
                it.clearVariable(var_id);
                it.ip += 1;
                return null;
            },

            .load_arg => {
                const arg_index = @as(u32, @intCast(instr.operand.index));
                std.debug.assert(arg_index < it.current_args.len);
                it.pushValue(it.current_args[arg_index]);
                it.ip += 1;
                return null;
            },

            .compact_runtime_tape => {
                it.compactRuntimeTape();
                it.ip += 1;
                return null;
            },

            .def_function => {
                // Function definitions are resolved at compile time
                it.ip += 1;
                return null;
            },

            .call_function => {
                // Recursive function call. Three snapshots establish the
                // body's isolation boundary:
                //   1. frame.args: value-args popped off `value_stack`
                //      LIFO, leftmost arg landing at args[0]. The body
                //      reads them only via `Op.load_arg(i)` —
                //      frame-local, no shared slot, no save/restore
                //      ordering bug across recursive calls (NIX-011).
                //   2. var_save_stack: every slot the body may overwrite
                //      (FunctionDef.write_set: pattern vars + closure
                //      slots only — value-args excluded post-NIX-011)
                //      records its caller value, restored on return.
                //   3. value_stack: caller's pending operands (e.g. the
                //      LHS of an outer binary op) are duped onto the
                //      frame and the live stack cleared. The args pop
                //      MUST happen before this snapshot, otherwise
                //      return_function would re-push consumed args onto
                //      the caller's stack.
                // saved_var_len / saved_stack / args ownership is freed
                // by the per-record `scratch` arena reset; explicit
                // free paths in return_function / truncateCallStackTo
                // are unnecessary.
                const max_recursion_depth = 10000;
                if (it.call_stack.items.len >= max_recursion_depth) {
                    return error.TypeError;
                }
                const fn_id = @as(u32, @intCast(instr.operand.index));
                const fn_def = it.function_table[fn_id];
                std.debug.assert(it.value_stack.items.len >= fn_def.value_param_count);
                const argc: usize = fn_def.value_param_count;
                var frame_args: []StackValue = &.{};
                if (argc > 0) {
                    frame_args = try it.scratch.allocator().alloc(StackValue, argc);
                    // value_stack holds args in push order (leftmost
                    // pushed first → bottom-of-args). Copy the top
                    // `argc` entries verbatim so frame_args[0] is the
                    // leftmost (= deepest of the arg block).
                    const top = it.value_stack.items.len;
                    @memcpy(frame_args, it.value_stack.items[top - argc .. top]);
                    it.value_stack.shrinkRetainingCapacity(top - argc);
                }
                const saved_var_len: u32 = @intCast(it.var_save_stack.items.len);
                for (fn_def.write_set) |id| {
                    const cur: ?StackValue = if (id < it.variable_store.items.len)
                        it.variable_store.items[id]
                    else
                        null;
                    try it.var_save_stack.append(it.alloc, .{ .id = id, .prev = cur });
                }
                const saved_stack = try it.scratch.allocator().dupe(StackValue, it.value_stack.items);
                it.value_stack.clearRetainingCapacity();
                const prev_current_args = it.current_args;
                try it.call_stack.append(it.alloc, CallFrame{
                    .return_ip = it.ip + 1,
                    .saved_value_len = 0,
                    .saved_if_len = @intCast(it.if_stack.items.len),
                    .saved_collect_len = @intCast(it.collect_stack.items.len),
                    .saved_fork_len = @intCast(it.fork_stack.items.len),
                    .saved_var_len = saved_var_len,
                    .saved_stack = saved_stack,
                    .saved_args = prev_current_args,
                    .returned = false,
                    .body_vars = &.{},
                    .fn_id = fn_id,
                });
                it.current_args = frame_args;
                it.ip = fn_def.body_ip;
                return null;
            },

            .return_function => {
                // Yield from a recursive function call. Body produced one
                // value via `current`; caller resumes from `return_ip`
                // with that value pushed onto its restored value_stack.
                //
                // NIX-011 deferred pop: do NOT pop the frame yet. Body
                // forks (e.g. `range(2) as $i | f($p-1)`) created during
                // body execution stay live on `fork_stack`; when one
                // fires after this yield we must re-enter the body with
                // its own bindings intact. The frame stays on
                // `call_stack` (with `returned = true`) until
                // `backtrackToDepth` observes
                // `fork_stack.items.len <= frame.saved_fork_len` and
                // performs the final pop. While yielded, `body_vars`
                // stashes the body's pattern-var values; the caller's
                // pre-call values (already in `var_save_stack` entries
                // above `frame.saved_var_len`) are written back into
                // `variable_store` so the caller's continuation sees
                // its own bindings. On a body fork fire, `backtrack`
                // swaps `body_vars` back in and resumes.
                // Drop any exhausted yielded frames at the top of
                // call_stack first — a nested call whose return left
                // its frame behind (because the OUTER frame still had
                // body forks alive at that moment) must be cleared
                // before we identify the frame this return belongs to.
                // The outer frame's body forks may have been consumed
                // by intervening backtracks; this is the next chance
                // to finalize the inner pop. Without this, we'd
                // re-yield the inner frame's value indefinitely while
                // the IP cycles through its return_ip.
                it.dropExhaustedYieldedFrames();
                if (it.call_stack.items.len == 0) {
                    // Stray return without matching call — defensive.
                    it.ip += 1;
                    return null;
                }
                const ret_val: ?StackValue = if (it.value_stack.items.len > 0)
                    it.value_stack.items[it.value_stack.items.len - 1]
                else
                    null;

                // Fast path: top frame not yet yielded AND no body forks
                // alive — legacy pop. Common case (no generators left
                // in body at return time).
                {
                    const top = &it.call_stack.items[it.call_stack.items.len - 1];
                    if (!top.returned and
                        it.fork_stack.items.len <= top.saved_fork_len)
                    {
                        const popped = it.call_stack.pop().?;
                        while (it.var_save_stack.items.len > popped.saved_var_len) {
                            const sv = it.var_save_stack.pop().?;
                            if (sv.id < it.variable_store.items.len) {
                                it.variable_store.items[sv.id] = sv.prev;
                            }
                        }
                        it.value_stack.clearRetainingCapacity();
                        try it.value_stack.ensureTotalCapacity(it.alloc, popped.saved_stack.len + 1);
                        it.value_stack.appendSliceAssumeCapacity(popped.saved_stack);
                        if (ret_val) |v| it.value_stack.appendAssumeCapacity(v);
                        it.ip = popped.return_ip;
                        it.current_args = popped.saved_args;
                        return null;
                    }
                }

                // Deferred / cascading path. The IP we just executed
                // (return_function) lives in some frame's body. With
                // self-recursion, multiple frames share the same
                // compiled body bytecode, so IP alone cannot identify
                // the target frame. Instead: walk call_stack top-down
                // and pick the first NON-returned frame as the yield
                // target. Already-returned frames represent yields
                // that have been cascaded through — control flow has
                // returned past them, and their next yield will fire
                // when the caller's body re-enters them via this same
                // return_function instruction.
                var target_idx: usize = it.call_stack.items.len;
                var found_target = false;
                while (target_idx > 0) {
                    target_idx -= 1;
                    if (!it.call_stack.items[target_idx].returned) {
                        found_target = true;
                        break;
                    }
                }
                if (!found_target) {
                    // All frames already returned — every cascade level
                    // has yielded and we hit return_function again with
                    // no live body. Should not happen in well-formed
                    // emission (the outermost yield exits the call_stack
                    // before a fresh return_function fires). Defensive
                    // skip: advance ip past return_function to avoid hang.
                    std.debug.assert(false);
                    it.ip += 1;
                    return null;
                }
                const frame = &it.call_stack.items[target_idx];

                // Scope this frame's body captures: var_save_stack
                // entries between `frame.saved_var_len` and the next
                // inner frame's `saved_var_len` (or stack top if none)
                // belong to THIS frame's body. Without scoping, we'd
                // mistake inner-frame captures for ours and corrupt
                // their slot bindings on yield.
                const upper_bound: usize = if (target_idx + 1 < it.call_stack.items.len)
                    it.call_stack.items[target_idx + 1].saved_var_len
                else
                    it.var_save_stack.items.len;
                const saved_count = upper_bound - frame.saved_var_len;
                if (!frame.returned) {
                    frame.body_vars = try it.scratch.allocator().alloc(SavedVar, saved_count);
                }
                std.debug.assert(frame.body_vars.len == saved_count);
                var i: usize = 0;
                while (i < saved_count) : (i += 1) {
                    const entry = it.var_save_stack.items[frame.saved_var_len + i];
                    const cur: ?StackValue = if (entry.id < it.variable_store.items.len)
                        it.variable_store.items[entry.id]
                    else
                        null;
                    frame.body_vars[i] = .{ .id = entry.id, .prev = cur };
                    if (entry.id < it.variable_store.items.len) {
                        it.variable_store.items[entry.id] = entry.prev;
                    }
                }
                frame.returned = true;

                it.value_stack.clearRetainingCapacity();
                try it.value_stack.ensureTotalCapacity(it.alloc, frame.saved_stack.len + 1);
                it.value_stack.appendSliceAssumeCapacity(frame.saved_stack);
                if (ret_val) |v| it.value_stack.appendAssumeCapacity(v);
                it.ip = frame.return_ip;
                it.current_args = frame.saved_args;
                return null;
            },

            .call_filter_arg => {
                // Should never appear at runtime — filter args are expanded at compile time.
                return error.TypeError;
            },

            .call_builtin => {
                // Low 16 bits of operand.index carry the BuiltinId; upper bits
                // may carry a RegexPool index for regex builtins (see
                // types.packRegexBuiltinOperand). Truncate here so non-regex
                // builtins ignore the upper slot cleanly.
                const bid: BuiltinId = types.builtinIdOf(instr.operand.index);
                const result = try it.doBuiltin(bid, instr.operand.index);
                if (result) |val| {
                    it.pushValue(val);
                }
                // doBuiltin advances ip when it sets up generators (range, paths, leaf_paths, scan);
                // otherwise advance here.
                // For empty, ip is set past end of instructions — do not advance again.
                // We only advance if doBuiltin didn't already change ip.
                if (bid != .empty and bid != .range and bid != .range2 and bid != .range3 and
                    bid != .paths and bid != .leaf_paths and bid != .recurse and
                    bid != .scan_ and bid != .match_g_ and bid != .splits_)
                {
                    it.ip += 1;
                }
                return null;
            },

            .label_begin => {
                // Save stack depths BEFORE pushing the token.
                const saved_value_len: u32 = @intCast(it.value_stack.items.len);

                // Generate a unique break token and push it to the value stack as an int.
                const token = it.next_break_token;
                it.next_break_token += 1;
                it.pushValue(.{ .int = @as(i64, @intCast(token)) });

                // Push a label forkpoint.
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = saved_value_len,
                    .saved_current = it.current,
                    .saved_current_args = it.current_args,
                    .saved_call_len = @intCast(it.call_stack.items.len),
                    .backtrack_ip = @intCast(instr.operand.index), // exit_ip
                    .aux = .{ .label = .{
                        .break_token = token,
                        .exit_ip = @intCast(instr.operand.index),
                        .saved_if_len = @intCast(it.if_stack.items.len),
                        .saved_collect_len = @intCast(it.collect_stack.items.len),
                        .saved_call_len = @intCast(it.call_stack.items.len),
                    } },
                    .saved_path = it.snapshotPathState(),
                });
                it.ip += 1;
                return null;
            },

            .label_end => {
                // Pop the label forkpoint if present (normal exit, no break fired).
                var idx = it.fork_stack.items.len;
                while (idx > 0) {
                    idx -= 1;
                    if (it.fork_stack.items[idx].aux == .label) {
                        _ = it.fork_stack.orderedRemove(idx);
                        break;
                    }
                }
                it.ip += 1;
                return null;
            },

            .break_op => {
                // Load break token from value stack (pushed by load_variable before this).
                const token_sv = try it.popValue();
                const token = switch (token_sv) {
                    .int => |i| @as(u32, @intCast(i)),
                    else => return error.TypeError,
                };
                // Scan fork_stack backwards for matching label, unwind and jump.
                var idx = it.fork_stack.items.len;
                while (idx > 0) {
                    idx -= 1;
                    if (it.fork_stack.items[idx].aux == .label) {
                        const state = it.fork_stack.items[idx].aux.label;
                        if (state.break_token == token) {
                            const fp = it.fork_stack.items[idx];
                            // Unwind fork stack.
                            it.truncateForkStack(idx);
                            // Unwind other stacks.
                            it.value_stack.items.len = fp.saved_value_stack_len;
                            it.if_stack.items.len = state.saved_if_len;
                            it.if_path_comps_stack.items.len = state.saved_if_len;
                            // Unwind collect frames, freeing buffers and propagating to parent.
                            while (it.collect_stack.items.len > state.saved_collect_len) {
                                var cf = it.collect_stack.pop().?;
                                defer cf.buffer.deinit(it.alloc);
                                if (cf.buffer.items.len > 0 and it.collect_stack.items.len > 0) {
                                    const parent = &it.collect_stack.items[it.collect_stack.items.len - 1];
                                    for (cf.buffer.items) |item| {
                                        parent.buffer.append(it.alloc, item) catch {};
                                    }
                                }
                            }
                            it.truncateCallStackTo(state.saved_call_len);
                            // Mirror catch-handler / fork-fire restore so
                            // the post-break IP runs with the args the
                            // label scope was opened in. NIX-011.
                            it.current_args = fp.saved_current_args;
                            // Break produces empty — set ip past end for backtracking.
                            it.ip = @intCast(it.instructions.len);
                            return null;
                        }
                    }
                }
                // No matching label found — treat as done.
                it.done = true;
                return null;
            },

            .limit_start => {
                const n_sv = try it.popValue();
                const n_i: i64 = switch (n_sv) {
                    .int => |i| i,
                    .float => |f| @intFromFloat(@round(f)),
                    else => return error.TypeError,
                };
                if (n_i < 0) {
                    it.user_error_msg = .{ .string = .{ .external = "limit doesn't support negative count" } };
                    return error.UserError;
                }
                if (n_i == 0) {
                    // Produce empty (no output) — trigger step loop to advance.
                    it.ip = @intCast(it.instructions.len);
                    return null;
                }
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .saved_current_args = it.current_args,
                    .saved_call_len = @intCast(it.call_stack.items.len),
                    .backtrack_ip = @intCast(instr.operand.index), // exit_ip
                    .aux = .{ .limit = .{
                        .remaining = @intCast(n_i),
                        .body_start_ip = it.ip,
                        .exit_ip = @intCast(instr.operand.index),
                        .saved_collect_len = @intCast(it.collect_stack.items.len),
                    } },
                    .saved_path = it.snapshotPathState(),
                });
                it.ip += 1;
                return null;
            },
            .limit_end => {
                // Pop the limit forkpoint if present.
                var idx = it.fork_stack.items.len;
                while (idx > 0) {
                    idx -= 1;
                    if (it.fork_stack.items[idx].aux == .limit) {
                        _ = it.fork_stack.orderedRemove(idx);
                        break;
                    }
                }
                it.ip += 1;
                return null;
            },

            .repeat_start => {
                // Push a RepeatFrame fork capturing the current input. On
                // backtrack into the frame (when the body's generator chain
                // exhausts), the saved input is restored as `current` and
                // execution resumes at body_start_ip — yielding the body's
                // outputs ad infinitum. Termination is delegated to an
                // enclosing `limit_start` whose counter, decremented at each
                // `yield_output` inside the body's IP range, will truncate
                // the fork stack past us once it hits zero. `backtrack_ip`
                // is unused for `.repeat` (the backtrack arm always re-enters
                // at `body_start_ip`); we set it to `exit_ip` for diagnostic
                // symmetry with `limit_start`.
                const exit_ip: u32 = @intCast(instr.operand.index);
                const body_start_ip: u32 = it.ip + 1;
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .saved_current_args = it.current_args,
                    .saved_call_len = @intCast(it.call_stack.items.len),
                    .backtrack_ip = exit_ip,
                    .aux = .{ .repeat = .{
                        .body_start_ip = body_start_ip,
                        .exit_ip = exit_ip,
                        .saved_collect_len = @intCast(it.collect_stack.items.len),
                        .saved_call_len = @intCast(it.call_stack.items.len),
                    } },
                    .saved_path = it.snapshotPathState(),
                });
                it.ip = body_start_ip;
                return null;
            },
            .repeat_end => {
                // Symmetric counterpart to `limit_end`. Reachable only if an
                // enclosing scope shifts ip past us without truncating the
                // RepeatFrame; the body's trailing `backtrack` normally
                // re-enters via the .repeat backtrack arm instead. Pop the
                // matching frame for safety so it can't outlive its scope.
                var idx = it.fork_stack.items.len;
                while (idx > 0) {
                    idx -= 1;
                    if (it.fork_stack.items[idx].aux == .repeat) {
                        _ = it.fork_stack.orderedRemove(idx);
                        break;
                    }
                }
                it.ip += 1;
                return null;
            },

            .reduce_source_start => {
                // Push a wrap forkpoint covering the reduce source IP range.
                // `yield_output` inside that range routes the emitted value
                // back into the destructure arm via `current` (see the
                // yield_output dispatch). The frame's backtrack_ip is the
                // exit_ip; on natural fork-stack unwind it pops cleanly.
                const exit_ip: u32 = @intCast(instr.operand.index);
                const body_start_ip: u32 = it.ip;
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .saved_current_args = it.current_args,
                    .saved_call_len = @intCast(it.call_stack.items.len),
                    .backtrack_ip = exit_ip,
                    .aux = .{ .reduce_source = .{
                        .body_start_ip = body_start_ip,
                        .exit_ip = exit_ip,
                        .saved_collect_len = @intCast(it.collect_stack.items.len),
                    } },
                    .saved_path = it.snapshotPathState(),
                });
                it.ip += 1;
                return null;
            },
            .reduce_source_end => {
                // Source completed without firing `yield_output` (natural
                // each/comma/range flow): pop the wrap frame; the
                // destructure arm consumes the value already in `current`.
                var idx = it.fork_stack.items.len;
                while (idx > 0) {
                    idx -= 1;
                    if (it.fork_stack.items[idx].aux == .reduce_source) {
                        _ = it.fork_stack.orderedRemove(idx);
                        break;
                    }
                }
                it.ip += 1;
                return null;
            },

            .skip_start, .nth_start => {
                const is_nth = instr.op == .nth_start;
                const n_sv = try it.popValue();
                const n_i: i64 = switch (n_sv) {
                    .int => |i| i,
                    .float => |f| @intFromFloat(@round(f)),
                    else => return error.TypeError,
                };
                if (n_i < 0) {
                    it.user_error_msg = .{ .string = .{ .external = if (is_nth)
                        "nth doesn't support negative indices"
                    else
                        "skip doesn't support negative count" } };
                    return error.UserError;
                }
                // n==0 means pass through all outputs (no skip frame needed).
                // Just continue to the body.
                if (n_i == 0) {
                    it.ip += 1;
                    return null;
                }
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .saved_current_args = it.current_args,
                    .saved_call_len = @intCast(it.call_stack.items.len),
                    .backtrack_ip = @intCast(instr.operand.index), // exit_ip
                    .aux = .{ .skip = .{
                        .remaining = @intCast(n_i),
                        .body_start_ip = it.ip,
                        .exit_ip = @intCast(instr.operand.index),
                        .saved_collect_len = @intCast(it.collect_stack.items.len),
                    } },
                    .saved_path = it.snapshotPathState(),
                });
                it.ip += 1;
                return null;
            },
            .skip_end => {
                // Pop the skip forkpoint if present.
                var idx = it.fork_stack.items.len;
                while (idx > 0) {
                    idx -= 1;
                    if (it.fork_stack.items[idx].aux == .skip) {
                        _ = it.fork_stack.orderedRemove(idx);
                        break;
                    }
                }
                it.ip += 1;
                return null;
            },

            // ── Path tracking opcodes ──────────────────────────────────────

            .path_begin => {
                // Push a fresh path frame for component recording.
                try it.path_stack.append(it.alloc, PathFrame{
                    .components = std.ArrayList(Value){},
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                });
                // Push a sentinel forkpoint that pops the frame when the
                // outer scope backtracks past this point. Without this,
                // generators inside path(...) would leak the frame after
                // exhaustion. The sentinel's saved_path captures the OUTER
                // path state so backtrack-through cleans up correctly.
                try it.fork_stack.append(it.alloc, .{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .saved_current_args = it.current_args,
                    .saved_call_len = @intCast(it.call_stack.items.len),
                    .backtrack_ip = 0, // unused for path_scope
                    .aux = .{ .path_scope = {} },
                    .saved_path = .{
                        .stack_len = @intCast(it.path_stack.items.len - 1),
                        .components_len = 0,
                    },
                });
                it.ip += 1;
                return null;
            },

            .path_end => {
                if (it.path_stack.items.len == 0) return error.TypeError;
                // Build the path array from accumulated components, but DO
                // NOT pop the frame — generators inside path(...) need it
                // alive across backtracks. The frame is popped by the
                // matching path_scope sentinel forkpoint when execution
                // backtracks out of the scope.
                const frame = &it.path_stack.items[it.path_stack.items.len - 1];

                // Validation: if any path-breaking opcode fired inside this
                // frame, jq raises "Invalid path expression with result <x>"
                // where <x> is the tojson of the body's produced value.
                if (frame.path_broken) {
                    const result_val: Value = if (it.value_stack.items.len > frame.saved_value_stack_len)
                        try stackValueToValue(it.value_stack.items[it.value_stack.items.len - 1])
                    else
                        it.current;
                    try it.raisePathExprError(result_val);
                    return error.UserError;
                }

                // Discard only values pushed by the body — restore to saved depth.
                it.value_stack.items.len = frame.saved_value_stack_len;
                // path(f) returns the path array. For most bodies this is
                // built from the components recorded by navigation ops
                // (load_key, navigate_index, each...). For path-emitting
                // builtins (`paths` / `leaf_paths` / `..`) the current value
                // IS the path array for this iteration — yield it directly.
                const path_arr: Value = if (frame.body_emits_paths_directly)
                    it.current
                else
                    try it.buildPathArray(frame.components.items);
                it.pushValue(try valueToStackValue(path_arr));
                // Nested path(path(f)):
                // Determine whether the inner path result is being consumed
                // as a computed key/index for the outer path (e.g.
                // path(.a[path(.b)[0]])) or is the outer body's terminal
                // output (e.g. path(path(.a))). We scan past pipe/identity
                // to find the next meaningful op.
                if (it.path_stack.items.len >= 2) {
                    var scan_ip = it.ip + 1;
                    while (scan_ip < it.instructions.len) {
                        const sop = it.instructions[scan_ip].op;
                        if (sop == .pipe or sop == .identity) {
                            scan_ip += 1;
                        } else break;
                    }
                    const meaningful_clears = scan_ip < it.instructions.len and
                        it.instructions[scan_ip].op.clearsPathBroken();
                    if (meaningful_clears) {
                        // Inner path result is consumed as computed key.
                        // Pop inner frame so subsequent descent ops append
                        // to the outer frame. Set skip_components flag on
                        // outer frame to suppress recording the meta-level
                        // ops (load_index on path array, etc.) until
                        // load_computed consumes the key.
                        var inner_frame = it.path_stack.pop().?;
                        inner_frame.deinit(it.alloc);
                        const outer = &it.path_stack.items[it.path_stack.items.len - 1];
                        outer.skip_components_for_computed_key = true;
                    } else {
                        // Terminal: inner path result is the outer body's
                        // output. Pop the inner frame so the outer path_end
                        // reads its own (outer) frame as the innermost frame,
                        // then mark the outer frame broken. The path array
                        // already pushed at L2099 stays on the value stack so
                        // the outer path_end's result_val check
                        // (value_stack.len > outer.saved_value_stack_len) finds
                        // it and passes it to raisePathExprError as the result.
                        var inner_frame = it.path_stack.pop().?;
                        inner_frame.deinit(it.alloc);
                        const outer = &it.path_stack.items[it.path_stack.items.len - 1];
                        outer.path_broken = true;
                        outer.break_origin = .upstream_value;
                        outer.break_kind = .generic;
                    }
                }
                it.ip += 1;
                return null;
            },

            .mark_computed_key => {
                // Set the skip flag on the topmost path frame so the upcoming
                // key-evaluation block (e.g. inner `.baz` of `.foo[.baz]`)
                // does NOT pollute the outer path with its own descent ops.
                // The flag is cleared by `load_computed` once the key has
                // been consumed, which then records the actual key as the
                // single legitimate path component. No-op outside a
                // `path(f)` / path-assign frame.
                if (it.path_stack.items.len > 0) {
                    const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                    frame.skip_components_for_computed_key = true;
                }
                it.ip += 1;
                return null;
            },

            .path_suspend => {
                // Suspend path-component recording on the innermost path frame.
                // While suspended, descent ops do not append components and
                // path-breaking ops do not mark `path_broken`. Used by
                // `emitAsBind` to evaluate the LHS of `EXPR1 as $v | EXPR2`
                // in value context — jq's path semantics treat
                // `path(EXPR1 as $v | EXPR2)` as `path(EXPR2)`. No-op when
                // no path frame is active.
                if (it.path_stack.items.len > 0) {
                    const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                    frame.suspended = true;
                }
                it.ip += 1;
                return null;
            },

            .path_resume => {
                // Clear the `suspended` flag set by `path_suspend`. Emitter
                // must guarantee 1:1 pairing — `path_resume` always follows
                // a corresponding `path_suspend` within the same execution
                // path. No-op when no path frame is active.
                if (it.path_stack.items.len > 0) {
                    const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                    frame.suspended = false;
                }
                it.ip += 1;
                return null;
            },

            // ── Walk opcodes ───────────────────────────────────────────────

            .walk_start => {
                // Recursively walk children bottom-up, then let the body (f)
                // execute on the walked result via normal instruction flow.
                const exit_ip: u32 = @intCast(instr.operand.index);
                const body_start = it.ip + 1;
                const body_end = exit_ip - 1; // walk_end is at exit_ip - 1

                const walked = try it.walkChildren(it.current, body_start, body_end, 0);
                it.current = walked;
                // Fall through to the body instructions (f)
                it.ip = body_start;
                return null;
            },

            .walk_end => {
                it.ip += 1;
                return null;
            },

            // ── Fork stack opcodes ──────────────────────────────────────────

            .fork => {
                // Capture stack snapshot when inside a collect frame or an
                // object literal so the second comma branch sees the same
                // value-stack contents as the first (collect: left-operand
                // of `[. * (a,b)]`; object: the key pushed before `object_key`
                // — see `snapshotValueStackForFork` for details).
                const saved_stack = try it.snapshotValueStackForFork();
                const saved_object = try it.snapshotObjectConstructState();
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .saved_current_args = it.current_args,
                    .saved_call_len = @intCast(it.call_stack.items.len),
                    .backtrack_ip = @intCast(instr.operand.index),
                    .aux = .{ .normal = {} },
                    .saved_path = it.snapshotPathState(),
                    .saved_stack = saved_stack,
                    .saved_object = saved_object,
                });
                it.ip += 1;
                return null;
            },

            .backtrack => {
                if (!(try it.doBacktrack())) {
                    // No forkpoints — let step() handle collect finalization or done.
                    it.ip = @intCast(it.instructions.len);
                }
                return null;
            },

            .each => {
                // When an upstream call_builtin has broken the path, iterating
                // through its result cannot represent a valid path step.
                // Record break_kind=.iterate and defer the error to path_end.
                if (it.path_stack.items.len > 0) {
                    const ef = &it.path_stack.items[it.path_stack.items.len - 1];
                    if (ef.path_broken and ef.break_origin == .upstream_value) {
                        ef.break_kind = .iterate;
                        ef.break_source = it.current;
                        // Skip the iteration entirely and let path_end raise the
                        // error. We backtrack past any generator context so the
                        // path frame's path_broken is preserved for path_end.
                        // Continue execution without forking — path_end sees the flag.
                        it.ip += 1;
                        return null;
                    }
                }
                switch (it.current) {
                    .array => |span| {
                        const first = span.start + 1;
                        const end = span.end - 1;
                        if (first >= end) {
                            // Empty array — backtrack to next generator.
                            if (!(try it.doBacktrack())) {
                                it.ip = @intCast(it.instructions.len);
                            }
                            return null;
                        }
                        it.fork_stack.appendAssumeCapacity(.{
                            .saved_value_stack_len = @intCast(it.value_stack.items.len),
                            .saved_current = it.current,
                            .saved_current_args = it.current_args,
                            .saved_call_len = @intCast(it.call_stack.items.len),
                            .backtrack_ip = it.ip,
                            .aux = .{ .each = .{
                                .pos = first,
                                .end = end,
                                .is_object = false,
                                .tape = span.tape,
                                .index = 0,
                            } },
                            .saved_path = it.snapshotPathState(),
                            .saved_stack = try it.snapshotValueStackForFork(),
                            .saved_object = try it.snapshotObjectConstructState(),
                        });
                        // Record path component (the array index 0).
                        if (it.path_stack.items.len > 0) {
                            const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                            if (!frame.skipComponents()) {
                                try frame.components.append(it.alloc, .{ .int = 0 });
                            }
                        }
                        it.current = tapeEntryToValue(span.tape, first);
                        it.ip += 1;
                    },
                    .object => |span| {
                        const first_key = span.start + 1;
                        const end = span.end - 1;
                        if (first_key >= end) {
                            if (!(try it.doBacktrack())) {
                                it.ip = @intCast(it.instructions.len);
                            }
                            return null;
                        }
                        it.fork_stack.appendAssumeCapacity(.{
                            .saved_value_stack_len = @intCast(it.value_stack.items.len),
                            .saved_current = it.current,
                            .saved_current_args = it.current_args,
                            .saved_call_len = @intCast(it.call_stack.items.len),
                            .backtrack_ip = it.ip,
                            .aux = .{ .each = .{
                                .pos = first_key,
                                .end = end,
                                .is_object = true,
                                .tape = span.tape,
                                .index = 0,
                            } },
                            .saved_path = it.snapshotPathState(),
                            .saved_stack = try it.snapshotValueStackForFork(),
                            .saved_object = try it.snapshotObjectConstructState(),
                        });
                        // Record path component (the object key).
                        if (it.path_stack.items.len > 0) {
                            const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                            if (!frame.skipComponents()) {
                                const key_entry = span.tape.entries[first_key];
                                try frame.components.append(it.alloc, .{
                                    .string = .{ .tape_ref = .{ .tape = span.tape, .ref = key_entry.payload.string } },
                                });
                            }
                        }
                        it.current = tapeEntryToValue(span.tape, first_key + 1);
                        it.ip += 1;
                    },
                    .null_val => {
                        // null | .[] produces nothing.
                        if (!(try it.doBacktrack())) {
                            it.ip = @intCast(it.instructions.len);
                        }
                        return null;
                    },
                    else => {
                        it.type_error_detail = it.buildTypeErrorMsg(it.current, .iterate);
                        return error.TypeError;
                    },
                }
                return null;
            },

            .yield_output => {
                const val = if (it.value_stack.items.len > 0)
                    try stackValueToValue(try it.popValue())
                else
                    it.current;

                // Check reduce_source wrap via fork_stack (innermost-out).
                // If a wrap frame's IP range contains this yield, route the
                // emitted value into the enclosing reduce's destructure arm
                // by setting `current` and advancing `ip` past
                // `reduce_source_end`. Skip/limit frames inside the source
                // (e.g. `limit(N; repeat(f))`) take precedence — they fire
                // first below and may suppress / truncate this output. The
                // wrap routing only applies to outputs that survive those
                // checks. We detect the wrap here, but defer the actual
                // routing until after skip/limit decrements below.
                //
                // Routing only fires when no collect frame opened inside
                // the wrap is buffering the yield: an internal yield emitted
                // by a sub-expression's `[arg]` collection (e.g. `[n_arg]`
                // in `limit(n; f)`) is captured by its `array_collect_end`
                // and must NOT be treated as a source value.
                var reduce_wrap_idx: ?usize = null;
                {
                    const output_ip = it.ip;
                    var ri: usize = it.fork_stack.items.len;
                    while (ri > 0) {
                        ri -= 1;
                        if (it.fork_stack.items[ri].aux == .reduce_source) {
                            const rs = &it.fork_stack.items[ri].aux.reduce_source;
                            if (output_ip > rs.body_start_ip and
                                output_ip < rs.exit_ip and
                                it.collect_stack.items.len <= rs.saved_collect_len)
                            {
                                reduce_wrap_idx = ri;
                            }
                            break;
                        }
                    }
                }

                // Check skip counter via fork_stack.
                // If a skip frame is active and counter > 0, suppress this output.
                {
                    const output_ip = it.ip;
                    var si: usize = it.fork_stack.items.len;
                    while (si > 0) {
                        si -= 1;
                        if (it.fork_stack.items[si].aux == .skip) {
                            var sstate = &it.fork_stack.items[si].aux.skip;
                            if (output_ip > sstate.body_start_ip and output_ip < sstate.exit_ip) {
                                if (it.collect_stack.items.len > sstate.saved_collect_len) {
                                    break;
                                }
                                if (sstate.remaining > 0) {
                                    sstate.remaining -= 1;
                                    // Suppress this output — backtrack to get next value from generator.
                                    it.ip = @intCast(it.instructions.len);
                                    return null;
                                }
                                break;
                            }
                        }
                    }
                }

                // Check limit counters via fork_stack.
                // Walk innermost→outermost: decrement every limit frame whose
                // IP range contains this yield and whose saved_collect_len
                // matches the current collect depth (output is escaping to
                // that limit's level). Stop propagating when a collect frame
                // was opened inside the limit body (output is captured there,
                // not escaping further; outer limits must not count it yet).
                //
                // Decrement ALL applicable limits before deciding where to
                // exit. If multiple exhaust on the same yield (nested
                // `first(... first(...) ...)`), exit at the OUTERMOST exhausted
                // one — that level commits to the value and unwinds everything
                // beneath. Stopping at the innermost (and bypassing the outer
                // decrement) would leak the outer first into the next backtrack
                // iteration and produce duplicate outputs.
                {
                    const output_ip = it.ip;
                    var exhausted_at: ?usize = null;
                    var li: usize = it.fork_stack.items.len;
                    while (li > 0) {
                        li -= 1;
                        if (it.fork_stack.items[li].aux != .limit) continue;
                        const lstate = &it.fork_stack.items[li].aux.limit;
                        if (output_ip <= lstate.body_start_ip or output_ip >= lstate.exit_ip) continue;
                        // Output is inside this limit's body IP range.
                        if (it.collect_stack.items.len > lstate.saved_collect_len) {
                            // A collect frame opened inside this limit body is
                            // buffering the output; it has not escaped to this
                            // limit's level. Stop propagating — outer limits
                            // (which have an even lower saved_collect_len) also
                            // cannot see this output yet.
                            break;
                        }
                        lstate.remaining -= 1;
                        if (lstate.remaining == 0) {
                            // Track outermost exhausted: keep overwriting as we
                            // walk outward (li decreases each iteration).
                            exhausted_at = li;
                        }
                    }
                    if (exhausted_at) |li_ex| {
                        // Capture the limit's exit_ip BEFORE truncate so we
                        // can route the final value through the post-frame
                        // code (pipe RHS, // truthiness check, outer
                        // yield_output) instead of short-circuiting it back
                        // to the user / collect buffer.
                        const exhausted_exit_ip = it.fork_stack.items[li_ex].aux.limit.exit_ip;
                        // Innermost exhausted limit: unwind fork stack to it.
                        it.truncateForkStack(li_ex);
                        // If a reduce_source wrap survived the truncate, the
                        // value belongs to the enclosing reduce's destructure
                        // arm — route it there.
                        if (reduce_wrap_idx) |rw_idx| {
                            if (rw_idx < li_ex) {
                                const rs = &it.fork_stack.items[rw_idx].aux.reduce_source;
                                it.current = val;
                                it.value_stack.items.len = it.fork_stack.items[rw_idx].saved_value_stack_len;
                                it.ip = rs.exit_ip + 1;
                                return null;
                            }
                        }
                        // Push val and jump to the OUTERMOST streaming-frame
                        // exit_ip among the exhausted frame and any surviving
                        // enclosing frames whose body wraps this yield. The
                        // outermost has the largest exit_ip, so jumping there
                        // bypasses every intermediate yield_output the value
                        // would otherwise re-trigger (which would re-decrement
                        // the same value through enclosing limits — see
                        // `limit(N; first(g))`, `limit(N; repeat(f))`).
                        // Preserves alt_handler frames for `first(g) // f`:
                        // the truthy/falsy branch decides whether to pop or
                        // fire it via the natural // desugar.
                        var route_exit_ip: u32 = exhausted_exit_ip;
                        const output_ip_e = it.ip;
                        var fi_e: usize = 0;
                        while (fi_e < it.fork_stack.items.len) : (fi_e += 1) {
                            const fpe = &it.fork_stack.items[fi_e];
                            switch (fpe.aux) {
                                .limit => |s| {
                                    if (output_ip_e > s.body_start_ip and output_ip_e < s.exit_ip and
                                        it.collect_stack.items.len <= s.saved_collect_len)
                                    {
                                        route_exit_ip = s.exit_ip;
                                        break;
                                    }
                                },
                                .skip => |s| {
                                    if (output_ip_e > s.body_start_ip and output_ip_e < s.exit_ip and
                                        it.collect_stack.items.len <= s.saved_collect_len)
                                    {
                                        route_exit_ip = s.exit_ip;
                                        break;
                                    }
                                },
                                .repeat => |s| {
                                    if (output_ip_e >= s.body_start_ip and output_ip_e < s.exit_ip and
                                        it.collect_stack.items.len <= s.saved_collect_len)
                                    {
                                        // exit_ip points at `repeat_end` (the
                                        // optional end_op); landing on it would
                                        // pop the frame and break re-entry on
                                        // the next backtrack. Skip past it so
                                        // the frame stays alive for subsequent
                                        // iterations to drive via the .repeat
                                        // backtrack arm.
                                        route_exit_ip = s.exit_ip + 1;
                                        break;
                                    }
                                },
                                else => {},
                            }
                        }
                        it.pushValue(try valueToStackValue(val));
                        it.ip = route_exit_ip;
                        return null;
                    }
                }

                // Streaming-frame routing for non-exhausting yields:
                // when the yield originates inside a limit/skip/repeat body
                // and no reduce_source wrap claims it, push val and jump to
                // the OUTERMOST enclosing frame's exit_ip so the post-frame
                // code executes on it. Outermost-first ensures we don't
                // re-trigger the same value through nested yield_outputs (each
                // of which would re-decrement enclosing limits — see
                // `limit(N; repeat(f))`). Without this routing, the raw inner
                // value short-circuits to the user / collect buffer, bypassing
                // pipe RHS, // truthiness checks, and outer yield transforms.
                // Skipped when collect_stack opened inside the streaming body
                // (the inner collect captures the value, not us).
                if (reduce_wrap_idx == null) {
                    const output_ip = it.ip;
                    var found_exit_ip: ?u32 = null;
                    var fi: usize = 0;
                    while (fi < it.fork_stack.items.len) : (fi += 1) {
                        const fp = &it.fork_stack.items[fi];
                        switch (fp.aux) {
                            .limit => |s| {
                                if (output_ip > s.body_start_ip and output_ip < s.exit_ip and
                                    it.collect_stack.items.len <= s.saved_collect_len)
                                {
                                    found_exit_ip = s.exit_ip;
                                    break;
                                }
                            },
                            .skip => |s| {
                                if (output_ip > s.body_start_ip and output_ip < s.exit_ip and
                                    it.collect_stack.items.len <= s.saved_collect_len)
                                {
                                    found_exit_ip = s.exit_ip;
                                    break;
                                }
                            },
                            .repeat => |s| {
                                if (output_ip >= s.body_start_ip and output_ip < s.exit_ip and
                                    it.collect_stack.items.len <= s.saved_collect_len)
                                {
                                    // Skip past `repeat_end` so the frame
                                    // stays alive (see exhaust path comment).
                                    found_exit_ip = s.exit_ip + 1;
                                    break;
                                }
                            },
                            else => {},
                        }
                    }
                    if (found_exit_ip) |exit_ip| {
                        it.pushValue(try valueToStackValue(val));
                        it.ip = exit_ip;
                        return null;
                    }
                }

                // Reduce-source wrap: route the emitted value into the
                // enclosing reduce's destructure/update arm. The wrap is
                // still on the fork stack (limit-exhaustion above did not
                // truncate it), so re-entering the source for the next
                // iteration happens via the body's trailing `backtrack`.
                if (reduce_wrap_idx) |rw_idx| {
                    const rs = &it.fork_stack.items[rw_idx].aux.reduce_source;
                    it.current = val;
                    it.value_stack.items.len = it.fork_stack.items[rw_idx].saved_value_stack_len;
                    it.ip = rs.exit_ip + 1;
                    return null;
                }

                if (it.collect_stack.items.len > 0) {
                    // Collect mode: buffer value, then trigger backtracking via step() loop.
                    const cf = &it.collect_stack.items[it.collect_stack.items.len - 1];
                    try cf.buffer.append(it.alloc, try valueToStackValue(val));
                    it.value_stack.items.len = cf.outer_value_depth;
                    if (it.fork_stack.items.len > cf.outer_fork_depth) {
                        // Active generators within collect scope — set ip past end
                        // so step() loop handles backtracking/advancement.
                        it.ip = @intCast(it.instructions.len);
                    } else {
                        // No generators — continue sequentially (imperative loops).
                        it.ip += 1;
                    }
                    return null;
                } else {
                    // Normal mode: yield value to caller.
                    it.ip += 1;
                    return val;
                }
            },
        }
    }

    /// Convert a completed CollectFrame buffer into an array Value backed by runtime_tape.
    fn buildCollectedArray(it: *ResultIterator, frame: *const CollectFrame) ZqError!StackValue {
        const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });

        for (frame.buffer.items) |sv| {
            try it.stackValueToRuntimeTapeEntry(sv);
        }

        const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });

        it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;

        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape.view,
            .start = arr_start,
            .end = arr_end_idx + 1,
        } } };
    }

    fn doLoadIndex(it: *ResultIterator, idx: i64) ZqError!Value {
        return switch (it.current) {
            .array => |span| {
                const resolved_idx = if (idx < 0) blk: {
                    const len = arrayLength(span.tape, span);
                    const neg_idx = @as(i64, @intCast(len)) + idx;
                    if (neg_idx < 0 or neg_idx > std.math.maxInt(u32)) return .null_val;
                    break :blk @as(u32, @intCast(neg_idx));
                } else blk: {
                    if (idx > std.math.maxInt(u32)) return .null_val;
                    break :blk @as(u32, @intCast(idx));
                };
                return lookupIndex(span.tape, span, resolved_idx) orelse .null_val;
            },
            // jq: indexing null yields null.
            .null_val => .null_val,
            else => error.TypeError,
        };
    }

    /// Resolve a bound value popped off `value_stack` for
    /// `slice_computed`. Mirrors jq's slice-bound coercion rules:
    /// - int → used directly (clamped to i32 range; OOB → end-extreme)
    /// - float → truncate toward zero, then int rule
    /// - null → caller treats as "missing" (returns 0 placeholder; the
    ///   caller flips `has_from` / `has_to` off to fall back to the
    ///   length default in `doSlice`)
    /// - anything else → TypeError
    const SliceBoundKind = enum { from_bound, to_bound };

    fn sliceBoundFromStackValue(it: *ResultIterator, sv: StackValue, kind: SliceBoundKind) ZqError!i32 {
        _ = it;
        return switch (sv) {
            .int => |n| blk: {
                if (n > std.math.maxInt(i32)) break :blk std.math.maxInt(i32);
                if (n < std.math.minInt(i32)) break :blk std.math.minInt(i32);
                break :blk @intCast(n);
            },
            .float => |f| blk: {
                if (std.math.isNan(f)) break :blk 0;
                if (f >= @as(f64, @floatFromInt(std.math.maxInt(i32)))) break :blk std.math.maxInt(i32);
                if (f <= @as(f64, @floatFromInt(std.math.minInt(i32)))) break :blk std.math.minInt(i32);
                // jq rounds from-bound toward -inf (floor) and to-bound toward +inf (ceil)
                const rounded = switch (kind) {
                    .from_bound => @floor(f),
                    .to_bound => @ceil(f),
                };
                break :blk @as(i32, @intFromFloat(rounded));
            },
            .null_val => 0,
            else => error.TypeError,
        };
    }

    fn doSlice(it: *ResultIterator, args: types.SliceArgs) ZqError!StackValue {
        switch (it.current) {
            .array => |span| {
                // Count array length.
                var len: i32 = 0;
                {
                    var pos = span.start + 1;
                    const end = span.end - 1;
                    while (pos < end) : (len += 1) pos = skipEntry(span.tape.*, pos);
                }
                const from = resolveSliceBound(if (args.has_from) args.from else 0, len);
                const to_resolved = resolveSliceBound(if (args.has_to) args.to else len, len);
                const actual_to: i32 = if (to_resolved < from) from else to_resolved;

                const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_start,
                    .payload = .{ .skip = 0 },
                });

                // Walk to the `from`-th element.
                var pos = span.start + 1;
                const end = span.end - 1;
                var i: i32 = 0;
                while (i < from and pos < end) : (i += 1) pos = skipEntry(span.tape.*, pos);

                // Copy elements [from..actual_to).
                while (i < actual_to and pos < end) : (i += 1) {
                    const sv = try valueToStackValue(tapeEntryToValue(span.tape, pos));
                    try it.stackValueToRuntimeTapeEntry(sv);
                    pos = skipEntry(span.tape.*, pos);
                }

                const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
                return .{ .tape_value = .{ .array = .{
                    .tape = &it.runtime_tape.view,
                    .start = arr_start,
                    .end = arr_end_idx + 1,
                } } };
            },
            .string => |sv| {
                const s = sv.slice();
                // jq slice on strings is codepoint-indexed, not
                // byte-indexed. Walk the UTF-8 sequence to map the
                // requested codepoint bounds to byte offsets. ASCII
                // strings remain a hot path because every codepoint
                // is one byte; multibyte strings (e.g. `"正xyz"`)
                // require the walk so `.[:1]` slices the first
                // codepoint rather than splitting a multi-byte
                // sequence into invalid UTF-8.
                var cp_len: i32 = 0;
                {
                    var i: usize = 0;
                    while (i < s.len) : (cp_len += 1) {
                        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                        i += seq_len;
                    }
                }
                const from = resolveSliceBound(if (args.has_from) args.from else 0, cp_len);
                const to_resolved = resolveSliceBound(if (args.has_to) args.to else cp_len, cp_len);
                const actual_to_cp: i32 = if (to_resolved < from) from else to_resolved;

                // Walk to the byte offsets corresponding to the
                // resolved codepoint bounds.
                var byte_from: usize = 0;
                var byte_to: usize = 0;
                {
                    var i: usize = 0;
                    var cp_i: i32 = 0;
                    while (i < s.len and cp_i < from) : (cp_i += 1) {
                        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                        i += seq_len;
                    }
                    byte_from = i;
                    while (i < s.len and cp_i < actual_to_cp) : (cp_i += 1) {
                        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                        i += seq_len;
                    }
                    byte_to = i;
                }
                const str_ref = try it.runtime_tape.internString(it.alloc, s[byte_from..byte_to]);
                return it.rtStringSV(str_ref);
            },
            // jq: slicing null yields null (not an error).
            .null_val => return .null_val,
            else => return error.TypeError,
        }
    }

    fn doUpdateKey(it: *ResultIterator, key: []const u8) ZqError!StackValue {
        const new_val = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);

        if (it.if_stack.items.len == 0) return error.TypeError;
        const base = it.if_stack.pop().?;

        switch (base) {
            .object => |span| {
                const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .object_start,
                    .payload = .{ .skip = 0 },
                });
                var pos = span.start + 1;
                const end = span.end - 1;
                var found = false;
                while (pos < end) {
                    const key_entry = span.tape.entries[pos];
                    const this_key = span.tape.getString(key_entry.payload.string);
                    const val_pos = pos + 1;
                    const new_key_ref = try it.runtime_tape.internString(it.alloc, this_key);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .key,
                        .payload = .{ .string = new_key_ref },
                    });
                    if (std.mem.eql(u8, this_key, key)) {
                        try it.stackValueToRuntimeTapeEntry(new_val);
                        found = true;
                    } else {
                        const orig_val = tapeEntryToValue(span.tape, val_pos);
                        try it.stackValueToRuntimeTapeEntry(try valueToStackValue(orig_val));
                    }
                    pos = skipEntry(span.tape.*, val_pos);
                }
                if (!found) {
                    const new_key_ref = try it.runtime_tape.internString(it.alloc, key);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .key,
                        .payload = .{ .string = new_key_ref },
                    });
                    try it.stackValueToRuntimeTapeEntry(new_val);
                }
                const obj_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .object_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;
                return .{ .tape_value = .{ .object = .{
                    .tape = &it.runtime_tape.view,
                    .start = obj_start,
                    .end = obj_end_idx + 1,
                } } };
            },
            .null_val => {
                const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .object_start,
                    .payload = .{ .skip = 0 },
                });
                const new_key_ref = try it.runtime_tape.internString(it.alloc, key);
                _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .key,
                    .payload = .{ .string = new_key_ref },
                });
                try it.stackValueToRuntimeTapeEntry(new_val);
                const obj_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .object_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;
                return .{ .tape_value = .{ .object = .{
                    .tape = &it.runtime_tape.view,
                    .start = obj_start,
                    .end = obj_end_idx + 1,
                } } };
            },
            else => return error.TypeError,
        }
    }

    fn doUpdateIndex(it: *ResultIterator, idx: i64) ZqError!StackValue {
        const new_val = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);

        if (it.if_stack.items.len == 0) return error.TypeError;
        const base = it.if_stack.pop().?;

        // jq's MAX_ARRAY_INDEX threshold (INT_MAX/4 in jq's jv_array.c).
        // Indices above this are rejected with "Array index too large".
        const max_array_index: i64 = std.math.maxInt(i32) >> 2;

        switch (base) {
            .array => |span| {
                const len = arrayLength(span.tape, span);
                const resolved_idx = if (idx < 0) blk: {
                    const neg_idx = @as(i64, @intCast(len)) + idx;
                    if (neg_idx < 0) {
                        it.type_error_detail = .{ .string = .{ .external = "Out of bounds negative array index" } };
                        return error.TypeError;
                    }
                    if (neg_idx > max_array_index) {
                        it.type_error_detail = .{ .string = .{ .external = "Array index too large" } };
                        return error.TypeError;
                    }
                    break :blk @as(u32, @intCast(neg_idx));
                } else blk: {
                    if (idx > max_array_index) {
                        it.type_error_detail = .{ .string = .{ .external = "Array index too large" } };
                        return error.TypeError;
                    }
                    break :blk @as(u32, @intCast(idx));
                };
                return try it.buildUpdatedArray(span, len, resolved_idx, new_val);
            },
            .null_val => {
                // Updating an index on null creates a fresh array. Negative
                // indices are an error because there is no length to wrap around.
                if (idx < 0) {
                    it.type_error_detail = .{ .string = .{ .external = "Out of bounds negative array index" } };
                    return error.TypeError;
                }
                if (idx > max_array_index) {
                    it.type_error_detail = .{ .string = .{ .external = "Array index too large" } };
                    return error.TypeError;
                }
                return try it.buildNewArrayAtIndex(@intCast(idx), new_val);
            },
            else => {
                it.type_error_detail = it.buildTypeErrorMsg(base, .index_number);
                return error.TypeError;
            },
        }
    }

    /// Build a new array equal to `span` with `target_idx` replaced by `new_val`,
    /// extending with nulls if `target_idx >= len`.
    fn buildUpdatedArray(
        it: *ResultIterator,
        span: types.Value.TapeSpan,
        len: u32,
        target_idx: u32,
        new_val: StackValue,
    ) ZqError!StackValue {
        const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });
        var pos = span.start + 1;
        const end = span.end - 1;
        var i: u32 = 0;
        // Copy existing elements, replacing the target index.
        while (pos < end) : (i += 1) {
            if (i == target_idx) {
                try it.stackValueToRuntimeTapeEntry(new_val);
            } else {
                const orig_val = tapeEntryToValue(span.tape, pos);
                try it.stackValueToRuntimeTapeEntry(try valueToStackValue(orig_val));
            }
            pos = skipEntry(span.tape.*, pos);
        }
        // Pad with nulls if target_idx is beyond the original length.
        if (target_idx >= len) {
            while (i < target_idx) : (i += 1) {
                try it.stackValueToRuntimeTapeEntry(.{ .null_val = {} });
            }
            try it.stackValueToRuntimeTapeEntry(new_val);
        }
        const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape.view,
            .start = arr_start,
            .end = arr_end_idx + 1,
        } } };
    }

    /// Build a fresh array of length `target_idx + 1`, with all entries null
    /// except position `target_idx` set to `new_val`.
    fn buildNewArrayAtIndex(
        it: *ResultIterator,
        target_idx: u32,
        new_val: StackValue,
    ) ZqError!StackValue {
        const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });
        var i: u32 = 0;
        while (i < target_idx) : (i += 1) {
            try it.stackValueToRuntimeTapeEntry(.{ .null_val = {} });
        }
        try it.stackValueToRuntimeTapeEntry(new_val);
        const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape.view,
            .start = arr_start,
            .end = arr_end_idx + 1,
        } } };
    }

    fn doLoadPath(it: *ResultIterator, path: []const u8) ZqError!Value {
        var current_val = it.current;
        var segs = std.mem.splitScalar(u8, path, '.');
        while (segs.next()) |seg| {
            current_val = try lookupKeyInValue(&it.tape, it.nullAllowed(), current_val, seg);
        }
        return current_val;
    }

    // ── Arithmetic operations ─────────────────────────────────────────────────────

    /// Integer addition with overflow promotion to f64.  jq treats all
    /// numbers as IEEE-754 doubles, so once an `i64 + i64` would wrap we
    /// fall back to the float result silently — matches `jq_arith.c::jv_add`
    /// which never wraps because it always operates on `double`.
    fn addIntInt(li: i64, ri: i64) StackValue {
        const r = @addWithOverflow(li, ri);
        if (r[1] == 0) return .{ .int = r[0] };
        return .{ .float = @as(f64, @floatFromInt(li)) + @as(f64, @floatFromInt(ri)) };
    }

    /// Integer subtraction with overflow promotion to f64.  Same rationale
    /// as `addIntInt` — jq's reference VM never wraps i64s.
    fn subIntInt(li: i64, ri: i64) StackValue {
        const r = @subWithOverflow(li, ri);
        if (r[1] == 0) return .{ .int = r[0] };
        return .{ .float = @as(f64, @floatFromInt(li)) - @as(f64, @floatFromInt(ri)) };
    }

    /// Integer multiplication with overflow promotion to f64.  jq's `jv_mul`
    /// always uses doubles, so `i64*i64` wrapping is a zq-specific bug
    /// (L1886): `last(range(365 * 67) | strptime(...))` produced a wrap
    /// during strptime's year multiplier computation.  Promote on overflow.
    fn mulIntInt(li: i64, ri: i64) StackValue {
        const r = @mulWithOverflow(li, ri);
        if (r[1] == 0) return .{ .int = r[0] };
        return .{ .float = @as(f64, @floatFromInt(li)) * @as(f64, @floatFromInt(ri)) };
    }

    fn doAdd(it: *ResultIterator) ZqError!StackValue {
        const right = try it.popValue();
        const left = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);

        return doAddValues(it, left, right);
    }

    /// Core add implementation shared by `+` operator and `add` builtin.
    fn doAddValues(it: *ResultIterator, left: StackValue, right: StackValue) ZqError!StackValue {
        return switch (left) {
            .int => |li| switch (right) {
                .int => |ri| addIntInt(li, ri),
                .float => |rf| .{ .float = @as(f64, @floatFromInt(li)) + rf },
                .null_val => left,
                else => return it.raiseBinaryArithTypeError(left, right, .add),
            },
            .float => |lf| switch (right) {
                .int => |ri| .{ .float = lf + @as(f64, @floatFromInt(ri)) },
                .float => |rf| .{ .float = lf + rf },
                .null_val => left,
                else => return it.raiseBinaryArithTypeError(left, right, .add),
            },
            .big_number => return it.raiseBinaryArithTypeError(left, right, .add),
            .null_val => switch (right) {
                .null_val => .null_val,
                else => right,
            },
            .tape_value => |ltv| switch (ltv) {
                .string => |ls| switch (right) {
                    .tape_value => |rtv| switch (rtv) {
                        .string => |rs| blk: {
                            // Concat into runtime_tape via the alias-safe helper.
                            // Either operand may live in `string_buf` (typical
                            // for `add` over a string array, where each
                            // intermediate accumulator points back into the
                            // buffer). NIX-003: naive `appendSlice` here UAF'd
                            // the source slice when ensureUnusedCapacity grew
                            // the backing — see types.zig:internStringConcat.
                            const ref = try it.runtime_tape.internStringConcat(it.alloc, &.{ ls.slice(), rs.slice() });
                            break :blk it.rtStringSV(ref);
                        },
                        .null_val => left,
                        else => return it.raiseBinaryArithTypeError(left, right, .add),
                    },
                    .null_val => left,
                    else => return it.raiseBinaryArithTypeError(left, right, .add),
                },
                .array => |lspan| switch (right) {
                    .tape_value => |rtv| switch (rtv) {
                        .array => |rspan| blk: {
                            // Concatenate arrays into runtime_tape
                            const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
                                .tag = .array_start,
                                .payload = .{ .skip = 0 },
                            });
                            // Copy left array elements
                            var pos = lspan.start + 1;
                            const lend = lspan.end - 1;
                            while (pos < lend) {
                                const sv = try valueToStackValue(tapeEntryToValue(lspan.tape, pos));
                                try it.stackValueToRuntimeTapeEntry(sv);
                                pos = skipEntry(lspan.tape.*, pos);
                            }
                            // Copy right array elements
                            pos = rspan.start + 1;
                            const rend = rspan.end - 1;
                            while (pos < rend) {
                                const sv = try valueToStackValue(tapeEntryToValue(rspan.tape, pos));
                                try it.stackValueToRuntimeTapeEntry(sv);
                                pos = skipEntry(rspan.tape.*, pos);
                            }
                            const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                                .tag = .array_end,
                                .payload = .{ .none = {} },
                            });
                            it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
                            break :blk .{ .tape_value = .{ .array = .{
                                .tape = &it.runtime_tape.view,
                                .start = arr_start,
                                .end = arr_end_idx + 1,
                            } } };
                        },
                        .null_val => left,
                        else => return it.raiseBinaryArithTypeError(left, right, .add),
                    },
                    .null_val => left,
                    else => return it.raiseBinaryArithTypeError(left, right, .add),
                },
                .object => |lspan| switch (right) {
                    .tape_value => |rtv| switch (rtv) {
                        .object => |rspan| blk: {
                            // Merge objects: jq semantics — iterate left keys in order,
                            // using right's value where the key exists in right; then
                            // append right keys that have no matching key in left.
                            const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
                                .tag = .object_start,
                                .payload = .{ .skip = 0 },
                            });
                            // Write all left keys, overwriting with right's value when present.
                            var lpos = lspan.start + 1;
                            const lend = lspan.end - 1;
                            while (lpos < lend) {
                                const lkey = lspan.tape.getString(lspan.tape.entries[lpos].payload.string);
                                // Look for this key in right
                                var rpos2 = rspan.start + 1;
                                const rend2 = rspan.end - 1;
                                var right_val_pos: ?u32 = null;
                                while (rpos2 < rend2) {
                                    const rkey = rspan.tape.getString(rspan.tape.entries[rpos2].payload.string);
                                    if (std.mem.eql(u8, lkey, rkey)) {
                                        right_val_pos = rpos2 + 1;
                                        break;
                                    }
                                    rpos2 = skipEntry(rspan.tape.*, rpos2 + 1);
                                }
                                const new_key_ref = try it.runtime_tape.internString(it.alloc, lkey);
                                _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .key, .payload = .{ .string = new_key_ref } });
                                if (right_val_pos) |rvp| {
                                    // Key exists in right: use right's value
                                    const rval_sv = try valueToStackValue(tapeEntryToValue(rspan.tape, rvp));
                                    try it.stackValueToRuntimeTapeEntry(rval_sv);
                                } else {
                                    // Key only in left: use left's value
                                    const lval_sv = try valueToStackValue(tapeEntryToValue(lspan.tape, lpos + 1));
                                    try it.stackValueToRuntimeTapeEntry(lval_sv);
                                }
                                lpos = skipEntry(lspan.tape.*, lpos + 1);
                            }
                            // Append right keys that are not in left
                            var rpos = rspan.start + 1;
                            const rend = rspan.end - 1;
                            while (rpos < rend) {
                                const rkey = rspan.tape.getString(rspan.tape.entries[rpos].payload.string);
                                // Check if left has this key
                                var lpos2 = lspan.start + 1;
                                var in_left = false;
                                while (lpos2 < lend) {
                                    const lkey2 = lspan.tape.getString(lspan.tape.entries[lpos2].payload.string);
                                    if (std.mem.eql(u8, rkey, lkey2)) {
                                        in_left = true;
                                        break;
                                    }
                                    lpos2 = skipEntry(lspan.tape.*, lpos2 + 1);
                                }
                                if (!in_left) {
                                    const new_key_ref = try it.runtime_tape.internString(it.alloc, rkey);
                                    _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .key, .payload = .{ .string = new_key_ref } });
                                    const rval_sv = try valueToStackValue(tapeEntryToValue(rspan.tape, rpos + 1));
                                    try it.stackValueToRuntimeTapeEntry(rval_sv);
                                }
                                rpos = skipEntry(rspan.tape.*, rpos + 1);
                            }
                            const obj_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                                .tag = .object_end,
                                .payload = .{ .none = {} },
                            });
                            it.runtime_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;
                            break :blk .{ .tape_value = .{ .object = .{
                                .tape = &it.runtime_tape.view,
                                .start = obj_start,
                                .end = obj_end_idx + 1,
                            } } };
                        },
                        .null_val => left,
                        else => return it.raiseBinaryArithTypeError(left, right, .add),
                    },
                    .null_val => left,
                    else => return it.raiseBinaryArithTypeError(left, right, .add),
                },
                .null_val => switch (right) {
                    .null_val => .null_val,
                    else => right,
                },
                else => return it.raiseBinaryArithTypeError(left, right, .add),
            },
            .bool_val => return it.raiseBinaryArithTypeError(left, right, .add),
        };
    }

    fn doSub(it: *ResultIterator) ZqError!StackValue {
        const right = try it.popValue();
        const left = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);

        return switch (left) {
            .int => |li| switch (right) {
                .int => |ri| subIntInt(li, ri),
                .float => |rf| .{ .float = @as(f64, @floatFromInt(li)) - rf },
                else => it.raiseBinaryArithTypeError(left, right, .subtract),
            },
            .float => |lf| switch (right) {
                .int => |ri| .{ .float = lf - @as(f64, @floatFromInt(ri)) },
                .float => |rf| .{ .float = lf - rf },
                else => it.raiseBinaryArithTypeError(left, right, .subtract),
            },
            .tape_value => |ltv| switch (ltv) {
                .array => |lspan| switch (right) {
                    .tape_value => |rtv| switch (rtv) {
                        .array => |rspan| blk: {
                            // Array subtraction: remove elements from left that appear in right
                            const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
                                .tag = .array_start,
                                .payload = .{ .skip = 0 },
                            });
                            var lpos = lspan.start + 1;
                            const lend = lspan.end - 1;
                            while (lpos < lend) {
                                const lval = tapeEntryToValue(lspan.tape, lpos);
                                const lsv = try valueToStackValue(lval);
                                // Check if this value appears in right
                                var rpos = rspan.start + 1;
                                const rend = rspan.end - 1;
                                var found = false;
                                while (rpos < rend) {
                                    const rval = tapeEntryToValue(rspan.tape, rpos);
                                    const rsv = try valueToStackValue(rval);
                                    if (stackValuesEqual(lsv, rsv)) {
                                        found = true;
                                        break;
                                    }
                                    rpos = skipEntry(rspan.tape.*, rpos);
                                }
                                if (!found) {
                                    try it.stackValueToRuntimeTapeEntry(lsv);
                                }
                                lpos = skipEntry(lspan.tape.*, lpos);
                            }
                            const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                                .tag = .array_end,
                                .payload = .{ .none = {} },
                            });
                            it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
                            break :blk .{ .tape_value = .{ .array = .{
                                .tape = &it.runtime_tape.view,
                                .start = arr_start,
                                .end = arr_end_idx + 1,
                            } } };
                        },
                        else => it.raiseBinaryArithTypeError(left, right, .subtract),
                    },
                    else => it.raiseBinaryArithTypeError(left, right, .subtract),
                },
                else => it.raiseBinaryArithTypeError(left, right, .subtract),
            },
            else => it.raiseBinaryArithTypeError(left, right, .subtract),
        };
    }

    // ── Object construction operations ─────────────────────────────────────────────────

    fn constructObjectFromFields(it: *ResultIterator) ZqError!StackValue {
        return it.constructObjectFromFieldsRange(0);
    }

    fn constructObjectFromFieldsRange(it: *ResultIterator, start_idx: u32) ZqError!StackValue {
        // Append object_start entry
        const obj_start_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_start,
            .payload = .{ .skip = 0 }, // Will update after object_end
        });

        // Append key-value pairs from start_idx to end
        for (it.object_construct.items[start_idx..]) |field| {
            // Intern key string. Re-resolve via StringView at this read so
            // any prior `runtime_tape.string_buf` grow (from peer fields)
            // sees the up-to-date backing rather than a captured slice.
            const key_ref = try it.runtime_tape.internString(it.alloc, field.key.slice());
            // Append key entry
            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .key,
                .payload = .{ .string = key_ref },
            });
            // Append value entry
            try it.stackValueToRuntimeTapeEntry(field.value);
        }

        // Append object_end entry
        const obj_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_end,
            .payload = .{ .none = {} },
        });

        // Update object_start skip pointer to point past object_end
        it.runtime_tape.entries.items[obj_start_idx].payload.skip = obj_end_idx + 1;

        // Create tape view and construct object value
        return .{ .tape_value = .{ .object = .{
            .tape = &it.runtime_tape.view,
            .start = obj_start_idx,
            .end = obj_end_idx + 1,
        } } };
    }

    /// Convert a StackValue to a runtime tape entry.
    /// Appends the entry(s) to the runtime tape.
    fn stackValueToRuntimeTapeEntry(it: *ResultIterator, val: StackValue) ZqError!void {
        switch (val) {
            .null_val => {
                _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .null_val,
                    .payload = .{ .none = {} },
                });
            },
            .bool_val => |b| {
                _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = if (b) .true_val else .false_val,
                    .payload = .{ .none = {} },
                });
            },
            .int => |i| {
                _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .int,
                    .payload = .{ .int = i },
                });
            },
            .float => |f| {
                _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .float,
                    .payload = .{ .float = f },
                });
            },
            .big_number => |bn| {
                const str_ref = try it.runtime_tape.internString(it.alloc, bn);
                _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .big_number,
                    .payload = .{ .string = str_ref },
                });
            },
            .tape_value => |tv| switch (tv) {
                .string => |sv| {
                    // Resolve the StringView at the moment of intern. If the
                    // view points into runtime_tape.string_buf, the resolved
                    // slice reflects the *current* backing — the upcoming
                    // ensureUnusedCapacity inside internString may relocate
                    // the buffer, but `internStringConcat`'s SliceSnap
                    // catches the in-call self-aliasing case (NIX-003).
                    const str_ref = try it.runtime_tape.internString(it.alloc, sv.slice());
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .string,
                        .payload = .{ .string = str_ref },
                    });
                },
                .object => |span| {
                    // Copy entire object from original tape to runtime tape
                    try it.copyTapeSpanToRuntimeTape(span);
                },
                .array => |span| {
                    // Copy entire array from original tape to runtime tape
                    try it.copyTapeSpanToRuntimeTape(span);
                },
                .null_val => {
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .null_val,
                        .payload = .{ .none = {} },
                    });
                },
                .bool_val => |b| {
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = if (b) .true_val else .false_val,
                        .payload = .{ .none = {} },
                    });
                },
                .int => |i| {
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .int,
                        .payload = .{ .int = i },
                    });
                },
                .float => |f| {
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .float,
                        .payload = .{ .float = f },
                    });
                },
                .big_number => |bn| {
                    const str_ref = try it.runtime_tape.internString(it.alloc, bn);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .big_number,
                        .payload = .{ .string = str_ref },
                    });
                },
            },
        }
    }

    /// Copy a tape span (object or array) from the original tape to the runtime tape.
    /// Preserves the structure and string references.
    ///
    /// When span references runtime_tape's own storage (self-copy during nested object
    /// construction), we must pre-reserve exact capacity before the loop.  Any ArrayList
    /// reallocation during the loop would move the backing memory and invalidate the
    /// slice pointers we are reading from.  Pre-reserving guarantees zero reallocations
    /// inside the loop, making the self-copy safe.
    /// Copy a tape span into the runtime tape. Two-pass linear approach:
    /// no recursion, no auxiliary allocations. O(n) in span size.
    fn copyTapeSpanToRuntimeTape(it: *ResultIterator, span: types.Value.TapeSpan) ZqError!void {
        const n_entries = span.end - span.start;
        var n_string_bytes: usize = 0;
        for (span.tape.entries[span.start..span.end]) |e| {
            switch (e.tag) {
                .key, .string, .big_number => n_string_bytes += e.payload.string.len,
                else => {},
            }
        }

        // Reserve capacity up front so no reallocation occurs during the copy loop.
        try it.runtime_tape.entries.ensureUnusedCapacity(it.alloc, n_entries);
        try it.runtime_tape.string_buf.ensureUnusedCapacity(it.alloc, n_string_bytes);
        // ensureUnusedCapacity may have reallocated — refresh the view so
        // span.tape reads (which go through runtime_tape.view) see valid memory.
        it.runtime_tape.refreshView();

        const base: u32 = @intCast(it.runtime_tape.entries.items.len);

        // Pass 1: copy all entries linearly, re-interning strings.
        var pos = span.start;
        while (pos < span.end) {
            const entry = span.tape.entries[pos];
            switch (entry.tag) {
                .key, .string, .big_number => {
                    const str = span.tape.getString(entry.payload.string);
                    const new_ref = try it.runtime_tape.internString(it.alloc, str);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = entry.tag,
                        .payload = .{ .string = new_ref },
                    });
                },
                else => {
                    _ = try it.runtime_tape.appendEntry(it.alloc, entry);
                },
            }
            pos += 1;
        }

        // Pass 2: fix up container skip pointers (translate from source to runtime indices).
        const items = it.runtime_tape.entries.items;
        var i: u32 = base;
        while (i < base + n_entries) : (i += 1) {
            switch (items[i].tag) {
                .object_start, .array_start => {
                    const orig_skip = items[i].payload.skip;
                    items[i].payload.skip = base + (orig_skip - span.start);
                },
                else => {},
            }
        }
    }

    /// In-place compaction of `runtime_tape.entries` for the
    /// `compact_runtime_tape` opcode. Identifies every live tape interval
    /// reachable from VM roots (current, value_stack, variable_store,
    /// if_stack, collect_stack, object_construct, fork_stack — the latter
    /// including `saved_current`, `saved_stack`, `saved_object`, plus each
    /// `EachState`'s `pos..end`), sorts/merges them into disjoint segments,
    /// packs the surviving entries down to the front of the tape, rebases
    /// every reference and `skip` pointer through a position-translation
    /// table, then truncates. Drops dead entries between live intervals
    /// (the gap between a half-consumed `range(N)` array and the
    /// accumulator), which a single-shift compaction cannot reclaim.
    ///
    /// Conservative bail-out: skipped (no-op) whenever a fork frame holds
    /// state we don't fully model — regex generator frames (`scan`/
    /// `match_g`/`splits` borrow `hay` slices from runtime_tape's
    /// `string_buf`) and recurse_path frames (cached `Value`/path
    /// components) — or any active path frame (`PathFrame.components`/
    /// `break_source`). Reduce bodies of the wave4 cluster never push
    /// these frames during iteration, so this fast path applies and the
    /// quadratic tape growth is shed.
    ///
    /// Strings are not relocated — `string_buf` keeps growing
    /// monotonically. Reduce bodies that don't intern strings (the
    /// worst-case targets, `[];[.]`-shape) therefore see flat memory.
    /// Bodies that do intern strings still benefit from entry compaction;
    /// their string-buf growth is independently bounded by
    /// `RuntimeTape.max_entries`-driven OOM.
    fn compactRuntimeTape(it: *ResultIterator) void {
        if (it.path_stack.items.len != 0) return;
        for (it.fork_stack.items) |fp| {
            switch (fp.aux) {
                .scan, .match_g, .splits, .recurse_path, .sub_gen => return,
                .each,
                .normal,
                .range,
                .try_handler,
                .alt_handler,
                .label,
                .limit,
                .skip,
                .repeat,
                .reduce_source,
                .path_scope,
                => {},
            }
        }

        const tape_ptr = &it.runtime_tape.view;
        const len_now: u32 = @intCast(it.runtime_tape.entries.items.len);
        if (len_now == 0) return;

        // Amortization gate. Compaction is O(len_now); without a gate
        // every reduce iteration would compact after a single fresh
        // append and turn an O(N) fold into O(N²). Compact only once
        // the entry count has grown by at least the absolute threshold
        // *and* doubled the post-last-compaction baseline, so total
        // compaction work over N iterations stays O(N).
        const baseline = it.runtime_tape.compact_live_baseline;
        const trigger = @max(
            baseline + @as(u32, types.RuntimeTape.compact_min_threshold),
            2 * baseline,
        );
        if (len_now < trigger) return;

        // Phase 1: collect live half-open intervals on the runtime tape.
        var intervals: std.ArrayList(LiveInterval) = .{};
        defer intervals.deinit(it.alloc);
        it.collectLiveIntervals(tape_ptr, &intervals) catch return;
        if (intervals.items.len == 0) {
            it.runtime_tape.entries.items.len = 0;
            it.runtime_tape.refreshView();
            it.runtime_tape.compact_live_baseline = 0;
            return;
        }

        // Phase 2: sort + merge overlapping/adjacent intervals so we walk
        // each surviving entry exactly once.
        std.mem.sort(LiveInterval, intervals.items, {}, LiveInterval.lessThan);
        var merged: std.ArrayList(LiveInterval) = .{};
        defer merged.deinit(it.alloc);
        var cur = intervals.items[0];
        for (intervals.items[1..]) |iv| {
            if (iv.start <= cur.end) {
                if (iv.end > cur.end) cur.end = iv.end;
            } else {
                merged.append(it.alloc, cur) catch return;
                cur = iv;
            }
        }
        merged.append(it.alloc, cur) catch return;

        // Phase 3: build position-translation table mapping every live
        // (and one-past-each-interval) old index to its new packed index.
        // `0` for unreferenced positions — the caller never queries those.
        const translation = it.alloc.alloc(u32, @as(usize, len_now) + 1) catch return;
        defer it.alloc.free(translation);
        @memset(translation, 0);
        var packed_len: u32 = 0;
        for (merged.items) |iv| {
            var old = iv.start;
            while (old <= iv.end and old <= len_now) : (old += 1) {
                translation[old] = packed_len + (old - iv.start);
            }
            packed_len += iv.end - iv.start;
        }

        // Phase 4: pack entries down. Walks merged intervals in order so
        // copyForwards is always non-overlapping for any single source
        // segment, and every prior write happens before reading the next.
        const items = it.runtime_tape.entries.items;
        var write: u32 = 0;
        for (merged.items) |iv| {
            const len = iv.end - iv.start;
            if (write != iv.start) {
                std.mem.copyForwards(Tape.Entry, items[write .. write + len], items[iv.start..iv.end]);
            }
            write += len;
        }
        it.runtime_tape.entries.items.len = packed_len;

        // Phase 5: rebase container skip pointers (always point to a live
        // position one-past their matching end marker, hence translation
        // covers them via the `<= iv.end` upper bound above).
        for (it.runtime_tape.entries.items) |*e| {
            switch (e.tag) {
                .object_start, .array_start => e.payload.skip = translation[e.payload.skip],
                else => {},
            }
        }
        it.runtime_tape.refreshView();

        // Phase 6: rebase every live root through the translation.
        it.rebaseLiveRoots(tape_ptr, translation);

        // Update the amortization baseline so the next gate compares
        // against the live-entry count we just produced.
        it.runtime_tape.compact_live_baseline = packed_len;
    }

    /// Append every runtime-tape interval reachable from any live root to
    /// `out` (raw, unsorted, possibly overlapping). Helper for
    /// `compactRuntimeTape`.
    fn collectLiveIntervals(
        it: *ResultIterator,
        target: *const Tape,
        out: *std.ArrayList(LiveInterval),
    ) error{OutOfMemory}!void {
        try collectFromValue(it.alloc, out, it.current, target);
        try collectFromValue(it.alloc, out, it.input_value, target);
        for (it.value_stack.items) |v| try collectFromStackValue(it.alloc, out, v, target);
        for (it.variable_store.items) |maybe_v| {
            if (maybe_v) |v| try collectFromStackValue(it.alloc, out, v, target);
        }
        for (it.if_stack.items) |v| try collectFromValue(it.alloc, out, v, target);
        for (it.collect_stack.items) |frame| {
            for (frame.buffer.items) |v| try collectFromStackValue(it.alloc, out, v, target);
        }
        for (it.object_construct.items) |field| try collectFromStackValue(it.alloc, out, field.value, target);
        for (it.fork_stack.items) |fp| {
            try collectFromValue(it.alloc, out, fp.saved_current, target);
            if (fp.saved_stack) |snap| {
                for (snap) |v| try collectFromStackValue(it.alloc, out, v, target);
            }
            if (fp.saved_object) |snap| {
                for (snap.fields) |field| try collectFromStackValue(it.alloc, out, field.value, target);
                for (snap.input) |v| try collectFromValue(it.alloc, out, v, target);
            }
            switch (fp.aux) {
                .each => |st| {
                    if (st.tape == target and st.end > st.pos) {
                        try out.append(it.alloc, .{ .start = st.pos, .end = st.end });
                    }
                },
                else => {},
            }
        }
    }

    /// Rebase every live tape reference through `translation`. Mirrors
    /// `collectLiveIntervals` so any new root added there must be added
    /// here too. Helper for `compactRuntimeTape`.
    fn rebaseLiveRoots(it: *ResultIterator, target: *const Tape, translation: []const u32) void {
        translateValueSpan(&it.current, target, translation);
        translateValueSpan(&it.input_value, target, translation);
        for (it.value_stack.items) |*v| translateStackValueSpan(v, target, translation);
        for (it.variable_store.items) |*maybe_v| {
            if (maybe_v.*) |*v| translateStackValueSpan(v, target, translation);
        }
        for (it.if_stack.items) |*v| translateValueSpan(v, target, translation);
        for (it.collect_stack.items) |*frame| {
            for (frame.buffer.items) |*v| translateStackValueSpan(v, target, translation);
        }
        for (it.object_construct.items) |*field| translateStackValueSpan(&field.value, target, translation);
        for (it.fork_stack.items) |*fp| {
            translateValueSpan(&fp.saved_current, target, translation);
            if (fp.saved_stack) |snap| {
                for (snap) |*v| translateStackValueSpan(v, target, translation);
            }
            if (fp.saved_object) |snap| {
                for (snap.fields) |*field| translateStackValueSpan(&field.value, target, translation);
                for (snap.input) |*v| translateValueSpan(v, target, translation);
            }
            switch (fp.aux) {
                .each => |*st| {
                    if (st.tape == target) {
                        st.pos = translation[st.pos];
                        st.end = translation[st.end];
                    }
                },
                else => {},
            }
        }
    }

    fn doMul(it: *ResultIterator) ZqError!StackValue {
        const right = try it.popValue();
        const left = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);

        return switch (left) {
            .int => |li| switch (right) {
                .int => |ri| mulIntInt(li, ri),
                .float => |rf| .{ .float = @as(f64, @floatFromInt(li)) * rf },
                .tape_value => |rtv| switch (rtv) {
                    .string => |s| try it.doStringRepeat(s, li),
                    else => return it.raiseBinaryArithTypeError(left, right, .multiply),
                },
                else => return it.raiseBinaryArithTypeError(left, right, .multiply),
            },
            .float => |lf| switch (right) {
                .int => |ri| .{ .float = lf * @as(f64, @floatFromInt(ri)) },
                .float => |rf| .{ .float = lf * rf },
                .tape_value => |rtv| switch (rtv) {
                    // jq: float * string with non-finite count yields null.
                    .string => |s| if (std.math.isNan(lf) or std.math.isInf(lf))
                        .null_val
                    else
                        try it.doStringRepeat(s, @intFromFloat(@floor(lf))),
                    else => return it.raiseBinaryArithTypeError(left, right, .multiply),
                },
                else => return it.raiseBinaryArithTypeError(left, right, .multiply),
            },
            .tape_value => |ltv| switch (ltv) {
                .object => |lspan| switch (right) {
                    .tape_value => |rtv| switch (rtv) {
                        .object => |rspan| try it.doRecursiveMerge(lspan, rspan),
                        else => return it.raiseBinaryArithTypeError(left, right, .multiply),
                    },
                    else => return it.raiseBinaryArithTypeError(left, right, .multiply),
                },
                .string => |s| switch (right) {
                    .int => |ri| try it.doStringRepeat(s, ri),
                    // jq: string * nan or string * ±inf yields null (matches
                    // jq's dtoi-based repeat-count: dtoi(nan) = 0 → null; and
                    // "string and string cannot be multiplied" semantics fall
                    // through to the typeerror→null path for non-finite).
                    .float => |rf| if (std.math.isNan(rf) or std.math.isInf(rf))
                        .null_val
                    else
                        try it.doStringRepeat(s, @intFromFloat(@floor(rf))),
                    else => return it.raiseBinaryArithTypeError(left, right, .multiply),
                },
                else => return it.raiseBinaryArithTypeError(left, right, .multiply),
            },
            else => return it.raiseBinaryArithTypeError(left, right, .multiply),
        };
    }

    /// String repetition for `*` operator.
    /// `"abc" * 3` produces `"abcabcabc"`. `"abc" * 0` produces `null`.
    fn doStringRepeat(it: *ResultIterator, sv: Value.StringView, n: i64) !StackValue {
        if (n < 0) return .null_val;
        if (n == 0) return .{ .tape_value = .{ .string = .{ .external = "" } } };
        const count: usize = @intCast(n);
        if (count == 1) return .{ .tape_value = .{ .string = sv } };
        const s = sv.slice();
        // Guard against excessive allocations
        const total_len = s.len * count;
        if (total_len > 128 * 1024 * 1024) {
            const str_ref = try it.runtime_tape.internString(it.alloc, "Repeat string result too long");
            it.user_error_msg = .{ .string = it.rtString(str_ref) };
            return error.UserError;
        }
        // Alias-safe repeat: `s` itself may live in string_buf (chained
        // repeats like `("x" * 4000) * 2` route the prior repeat result
        // back through here). NIX-003.
        const ref = try it.runtime_tape.internStringRepeat(it.alloc, s, count);
        return it.rtStringSV(ref);
    }

    /// jq: string / string = split. Splits the left string by the right separator.
    fn doStringSplit(it: *ResultIterator, input_sv: Value.StringView, sep_sv: Value.StringView) ZqError!StackValue {
        const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });

        // Re-resolve the StringViews at every iteration so growth of
        // `runtime_tape.string_buf` (from the per-segment internString
        // below) does not leave us reading from a relocated, freed
        // backing. NIX-006: the prior code passed raw `[]const u8`
        // slices that dangled after the first internString.
        if (sep_sv.slice().len == 0) {
            // Split into individual characters (UTF-8 aware)
            var i: usize = 0;
            while (i < input_sv.slice().len) {
                const input_now = input_sv.slice();
                const seq_len = std.unicode.utf8ByteSequenceLength(input_now[i]) catch 1;
                const char_end = @min(i + seq_len, input_now.len);
                const str_ref = try it.runtime_tape.internString(it.alloc, input_now[i..char_end]);
                _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .string,
                    .payload = .{ .string = str_ref },
                });
                i = char_end;
            }
        } else {
            var rest_off: usize = 0;
            while (true) {
                const input_now = input_sv.slice();
                const sep_now = sep_sv.slice();
                const rest = input_now[rest_off..];
                if (std.mem.indexOf(u8, rest, sep_now)) |idx| {
                    const str_ref = try it.runtime_tape.internString(it.alloc, rest[0..idx]);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .string,
                        .payload = .{ .string = str_ref },
                    });
                    rest_off += idx + sep_now.len;
                } else {
                    const str_ref = try it.runtime_tape.internString(it.alloc, rest);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .string,
                        .payload = .{ .string = str_ref },
                    });
                    break;
                }
            }
        }

        const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape.view,
            .start = arr_start,
            .end = arr_end_idx + 1,
        } } };
    }

    /// Recursive object merge for `*` operator.
    /// For each key: if both values are objects, recurse; otherwise right wins.
    fn doRecursiveMerge(it: *ResultIterator, lspan: types.Value.TapeSpan, rspan: types.Value.TapeSpan) ZqError!StackValue {
        const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_start,
            .payload = .{ .skip = 0 },
        });

        // Write all left keys, recursively merging or overwriting with right's value when present.
        var lpos = lspan.start + 1;
        const lend = lspan.end - 1;
        while (lpos < lend) {
            const lkey = lspan.tape.getString(lspan.tape.entries[lpos].payload.string);
            // Look for this key in right
            var rpos2 = rspan.start + 1;
            const rend2 = rspan.end - 1;
            var right_val_pos: ?u32 = null;
            while (rpos2 < rend2) {
                const rkey = rspan.tape.getString(rspan.tape.entries[rpos2].payload.string);
                if (std.mem.eql(u8, lkey, rkey)) {
                    right_val_pos = rpos2 + 1;
                    break;
                }
                rpos2 = skipEntry(rspan.tape.*, rpos2 + 1);
            }
            const new_key_ref = try it.runtime_tape.internString(it.alloc, lkey);
            _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .key, .payload = .{ .string = new_key_ref } });
            if (right_val_pos) |rvp| {
                // Key exists in both: check if both values are objects for recursive merge
                const lval = tapeEntryToValue(lspan.tape, lpos + 1);
                const rval = tapeEntryToValue(rspan.tape, rvp);
                switch (lval) {
                    .object => |lobj_span| switch (rval) {
                        .object => |robj_span| {
                            // Both are objects: recursive merge.
                            // The recursive call appends entries directly to runtime_tape,
                            // so we just call it — no need to copy the result.
                            _ = try it.doRecursiveMerge(lobj_span, robj_span);
                        },
                        else => {
                            // Right is not an object: right wins
                            const rval_sv = try valueToStackValue(rval);
                            try it.stackValueToRuntimeTapeEntry(rval_sv);
                        },
                    },
                    else => {
                        // Left is not an object: right wins
                        const rval_sv = try valueToStackValue(rval);
                        try it.stackValueToRuntimeTapeEntry(rval_sv);
                    },
                }
            } else {
                // Key only in left: use left's value
                const lval_sv = try valueToStackValue(tapeEntryToValue(lspan.tape, lpos + 1));
                try it.stackValueToRuntimeTapeEntry(lval_sv);
            }
            lpos = skipEntry(lspan.tape.*, lpos + 1);
        }

        // Append right keys that are not in left
        var rpos = rspan.start + 1;
        const rend = rspan.end - 1;
        while (rpos < rend) {
            const rkey = rspan.tape.getString(rspan.tape.entries[rpos].payload.string);
            // Check if left has this key
            var lpos2 = lspan.start + 1;
            var in_left = false;
            while (lpos2 < lend) {
                const lkey2 = lspan.tape.getString(lspan.tape.entries[lpos2].payload.string);
                if (std.mem.eql(u8, rkey, lkey2)) {
                    in_left = true;
                    break;
                }
                lpos2 = skipEntry(lspan.tape.*, lpos2 + 1);
            }
            if (!in_left) {
                const new_key_ref = try it.runtime_tape.internString(it.alloc, rkey);
                _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .key, .payload = .{ .string = new_key_ref } });
                const rval_sv = try valueToStackValue(tapeEntryToValue(rspan.tape, rpos + 1));
                try it.stackValueToRuntimeTapeEntry(rval_sv);
            }
            rpos = skipEntry(rspan.tape.*, rpos + 1);
        }

        const obj_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;

        return .{ .tape_value = .{ .object = .{
            .tape = &it.runtime_tape.view,
            .start = obj_start,
            .end = obj_end_idx + 1,
        } } };
    }

    fn doDiv(it: *ResultIterator) ZqError!StackValue {
        const right = try it.popValue();
        const left = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);

        switch (left) {
            .int => |li| switch (right) {
                .int => |ri| {
                    if (ri == 0) return it.raiseBinaryArithTypeError(left, right, .divide);
                    // Integer division: if evenly divisible keep int, otherwise float
                    if (@rem(li, ri) == 0) return .{ .int = @divTrunc(li, ri) };
                    return .{ .float = @as(f64, @floatFromInt(li)) / @as(f64, @floatFromInt(ri)) };
                },
                .float => |rf| {
                    if (rf == 0.0) return it.raiseBinaryArithTypeError(left, right, .divide);
                    return .{ .float = @as(f64, @floatFromInt(li)) / rf };
                },
                else => return it.raiseBinaryArithTypeError(left, right, .divide),
            },
            .float => |lf| switch (right) {
                .int => |ri| {
                    if (ri == 0) return it.raiseBinaryArithTypeError(left, right, .divide);
                    return .{ .float = lf / @as(f64, @floatFromInt(ri)) };
                },
                .float => |rf| {
                    if (rf == 0.0) return it.raiseBinaryArithTypeError(left, right, .divide);
                    return .{ .float = lf / rf };
                },
                else => return it.raiseBinaryArithTypeError(left, right, .divide),
            },
            // jq: string / string = split(separator)
            .tape_value => |ltv| switch (ltv) {
                .string => |ls| switch (right) {
                    .tape_value => |rtv| switch (rtv) {
                        .string => |rs| return try it.doStringSplit(ls, rs),
                        else => return it.raiseBinaryArithTypeError(left, right, .divide),
                    },
                    else => return it.raiseBinaryArithTypeError(left, right, .divide),
                },
                else => return it.raiseBinaryArithTypeError(left, right, .divide),
            },
            else => return it.raiseBinaryArithTypeError(left, right, .divide),
        }
    }

    fn doMod(it: *ResultIterator) ZqError!StackValue {
        const right = try it.popValue();
        const left = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);
        // If either operand is a float, use jq's binop_mod semantics
        // (builtin.c: nan → nan; else coerce both via dtoi and integer-%):
        //   dtoi(x) = x < INT64_MIN ? INT64_MIN
        //           : -x <= INT64_MIN ? INT64_MAX
        //           : (i64)x
        // If bi == -1, result is 0 (avoids UB on INT64_MIN % -1).
        const left_is_float = switch (left) {
            .float => true,
            else => false,
        };
        const right_is_float = switch (right) {
            .float => true,
            else => false,
        };
        if (left_is_float or right_is_float) {
            const lf: f64 = switch (left) {
                .int => |i| @as(f64, @floatFromInt(i)),
                .float => |f| f,
                else => return it.raiseBinaryArithTypeError(left, right, .modulo),
            };
            const rf: f64 = switch (right) {
                .int => |i| @as(f64, @floatFromInt(i)),
                .float => |f| f,
                else => return it.raiseBinaryArithTypeError(left, right, .modulo),
            };
            if (std.math.isNan(lf) or std.math.isNan(rf)) {
                return .{ .float = std.math.nan(f64) };
            }
            const bi = dtoiClamp(rf);
            if (bi == 0) return it.raiseBinaryArithTypeError(left, right, .modulo);
            if (bi == -1) return .{ .int = 0 };
            const ai = dtoiClamp(lf);
            return .{ .int = @rem(ai, bi) };
        }
        const left_int = toInt(left) catch return it.raiseBinaryArithTypeError(left, right, .modulo);
        const right_int = toInt(right) catch return it.raiseBinaryArithTypeError(left, right, .modulo);
        if (right_int == 0) return it.raiseBinaryArithTypeError(left, right, .modulo);
        if (right_int == -1) return .{ .int = 0 };
        return .{ .int = @rem(left_int, right_int) };
    }

    // ── Builtin implementations ───────────────────────────────────────────────────

    /// Dispatch to individual builtin implementations.
    /// Returns a StackValue to push (or null for empty/generators that set ip).
    noinline fn doBuiltin(it: *ResultIterator, bid: BuiltinId, operand: i64) ZqError!?StackValue {
        switch (bid) {
            .length => return try it.builtinLength(),
            .keys => return try it.builtinKeys(true),
            .keys_unsorted => return try it.builtinKeys(false),
            .values => return try it.builtinValues(),
            .has => return try it.builtinHas(),
            .in_ => return try it.builtinIn(),
            .type_ => return it.builtinType(),
            .empty => {
                // `empty` produces no output — backtrack to next generator path.
                if (!(try it.doBacktrack())) {
                    it.ip = @intCast(it.instructions.len);
                }
                return null;
            },
            .tostring => return try it.builtinTostring(),
            .tonumber => return try it.builtinTonumber(),
            .error_ => {
                it.user_error_msg = it.current;
                return error.UserError;
            },
            .add => return try it.builtinAdd(),
            .range => return try it.builtinRange1(),
            .range2 => return try it.builtinRange2(),
            .range3 => return try it.builtinRange3(),
            .sort => return try it.builtinSort(),
            .reverse => return try it.builtinReverse(),
            .flatten => return try it.builtinFlatten(),
            .min => return try it.builtinMin(),
            .max => return try it.builtinMax(),
            .to_entries => return try it.builtinToEntries(),
            .from_entries => return try it.builtinFromEntries(),
            .any => return try it.builtinAny(),
            .all => return try it.builtinAll(),
            .unique => return try it.builtinUnique(),
            .flatten_n => return try it.builtinFlattenN(),
            .contains => return try it.builtinContains(),
            .inside => return try it.builtinInside(),
            .indices => return try it.builtinIndices(),
            .index_ => return try it.builtinIndex(),
            .rindex => return try it.builtinRindex(),
            .sort_by => return try it.builtinSortBy(),
            .group_by => return try it.builtinGroupBy(),
            .min_by => return try it.builtinMinBy(),
            .max_by => return try it.builtinMaxBy(),
            .unique_by => return try it.builtinUniqueBy(),
            .del => return try it.builtinDel(),
            .format_text => return try it.builtinTostring(),
            .format_json => return try it.builtinFormatJson(),
            .format_csv => return try it.builtinFormatCsv(),
            .format_tsv => return try it.builtinFormatTsv(),
            .format_html => return try it.builtinFormatHtml(),
            .format_uri => return try it.builtinFormatUri(),
            .format_urid => return try it.builtinFormatUrid(),
            .format_sh => return try it.builtinFormatSh(),
            .format_base64 => return try it.builtinFormatBase64(),
            .format_base64d => return try it.builtinFormatBase64d(),
            .range1_gen => return try it.builtinRange1Gen(),
            .range2_gen => return try it.builtinRange2Gen(),
            .range3_gen => return try it.builtinRange3Gen(),
            .limit_gen => return try it.builtinLimitGen(),
            .getpath => return try it.builtinGetpath(),
            .setpath => return try it.builtinSetpath(),
            .delpaths => return try it.builtinDelpaths(),
            .paths => return try it.builtinPaths(),
            .leaf_paths => return try it.builtinLeafPaths(),
            .recurse => return try it.builtinRecurse(),

            // Math builtins (zero-arg)
            .abs => return try it.builtinAbs(),
            .floor_ => return it.builtinFloor(),
            .ceil_ => return it.builtinCeil(),
            .round_ => return it.builtinRound(),
            .sqrt_ => return it.builtinSqrt(),
            .fabs_ => return it.builtinFabs(),
            .nan_ => return .{ .float = std.math.nan(f64) },
            .infinite_ => return .{ .float = std.math.inf(f64) },
            .isinfinite_ => return it.builtinIsinfinite(),
            .isnan_ => return it.builtinIsnan(),
            .isnormal_ => return it.builtinIsnormal(),
            // zq uses f64 exclusively; no jq-style decimal (decnum) support.
            .have_decnum_ => return .{ .bool_val = false },
            .exp_ => return it.builtinExp(),
            .exp2_ => return it.builtinExp2(),
            .exp10_ => return it.builtinExp10(),
            .log_ => return it.builtinLog(),
            .log2_ => return it.builtinLog2(),
            .log10_ => return it.builtinLog10(),
            .cbrt_ => return it.builtinCbrt(),
            .sin_ => return it.builtinSin(),
            .cos_ => return it.builtinCos(),
            .tan_ => return it.builtinTan(),
            .asin_ => return it.builtinAsin(),
            .acos_ => return it.builtinAcos(),
            .atan_ => return it.builtinAtan(),
            .rint_ => return it.builtinRint(),
            .nearbyint_ => return it.builtinRint(),
            .trunc_ => return it.builtinTrunc(),
            .significand_ => return it.builtinSignificand(),
            .logb_ => return it.builtinLogb(),
            .j0_ => return .{ .float = 0.0 },
            .j1_ => return .{ .float = 0.0 },
            .lgamma_ => return it.builtinLgamma(),
            .tgamma_ => return it.builtinTgamma(),

            // Two-arg math builtins
            .pow_ => return it.builtinPow(),
            .atan2_ => return it.builtinAtan2(),
            .remainder_ => return it.builtinRemainder(),
            .hypot_ => return it.builtinHypot(),
            .scalb_ => return it.builtinLdexp(),
            .scalbln_ => return it.builtinLdexp(),
            .ldexp_ => return it.builtinLdexp(),
            .fma_ => return it.builtinFma(),
            .drem_ => return it.builtinRemainder(),

            // Type-check filter builtins
            .arrays_ => return it.builtinTypeFilter(.array),
            .objects_ => return it.builtinTypeFilter(.object),
            .strings_ => return it.builtinTypeFilter(.string),
            .numbers_ => return it.builtinTypeFilter(.number),
            .booleans_ => return it.builtinTypeFilter(.boolean),
            .nulls_ => return it.builtinTypeFilter(.null_type),
            .values_ => return it.builtinTypeFilter(.values_type),
            .scalars_ => return it.builtinTypeFilter(.scalar),
            .normals_ => return it.builtinTypeFilter(.normal),
            .iterables_ => return it.builtinTypeFilter(.iterable),

            // String builtins
            .ascii_downcase => return try it.builtinAsciiCase(false),
            .ascii_upcase => return try it.builtinAsciiCase(true),
            .ascii_ => return try it.builtinAscii(),
            .explode_ => return try it.builtinExplode(),
            .implode_ => return try it.builtinImplode(),

            // String builtins (arg-taking)
            .split_ => return try it.builtinSplit(),
            .join_ => return try it.builtinJoin(),
            .startswith_ => return try it.builtinStartswith(),
            .endswith_ => return try it.builtinEndswith(),
            .ltrimstr_ => return try it.builtinLtrimstr(),
            .rtrimstr_ => return try it.builtinRtrimstr(),
            .trimstr_ => return try it.builtinTrimstr(),
            .test_ => return try it.builtinTest(operand),
            .match_ => return try it.builtinMatch(operand),
            .match_g_ => return try it.builtinMatchG(operand),
            .sub_ => return try it.builtinSub(operand),
            .gsub_ => return try it.builtinGsub(operand),
            .capture_ => return try it.builtinCapture(operand),
            .scan_ => return try it.builtinScan(operand),
            .splits_ => return try it.builtinSplits(operand),

            // Array utility builtins
            .transpose_ => return try it.builtinTranspose(),
            .bsearch_ => return try it.builtinBsearch(),

            // JSON builtins
            .tojson => return try it.builtinTojson(),
            .fromjson => return try it.builtinFromjson(),

            // Misc builtins
            .not_ => return it.builtinNot(),
            .builtins_ => return try it.builtinBuiltins(),
            .debug_, .stderr_ => {
                // Pass through current value (debug is a no-op for now)
                return try valueToStackValue(it.current);
            },
            .input_ => {
                // jq raises a catchable "break" error when there are no more inputs.
                // This matches jq 1.8 behaviour: `try input catch .` → "break".
                return try it.raiseUserError("break");
            },
            .inputs_ => {
                // `inputs` (plural) silently produces nothing when exhausted.
                it.ip = @intCast(it.instructions.len);
                return null;
            },
            .env_ => return try it.builtinEnv(),
            .modulemeta_ => return try it.builtinModulemeta(),
            .halt_ => {
                it.ip = @intCast(it.instructions.len);
                return null;
            },
            .halt_error_ => {
                return error.UserError;
            },
            .map_values_ => return try it.builtinMapValues(),
            // `isempty_` is never emitted by the new compiler: isempty/1 is
            // desugared at lower time to `first((f | false), true)` via
            // lowerIsemptyDesugar1. BuiltinId.isempty_ is retained in types.zig
            // for enum exhaustiveness only — no bytecode path reaches here.
            .isempty_ => unreachable,
            .first_ => return try it.builtinFirst(),
            .last_ => return try it.builtinLast(),

            // Date/time builtins
            .now_ => return try it.builtinNow(),
            .gmtime_ => return try it.builtinGmtime(),
            .mktime_ => return try it.builtinMktime(),
            .strftime_ => return try it.builtinStrftimeImpl("strftime"),
            .strptime_ => return try it.builtinStrptime(),
            .strflocaltime_ => return try it.builtinStrftimeImpl("strflocaltime"),
            .todate_ => return try it.builtinTodate(),
            .fromdate_ => return try it.builtinFromdate(),
            .todateiso8601_ => return try it.builtinTodate(),
            .fromdateiso8601_ => return try it.builtinFromdate(),

            // Conversion / inspection builtins
            .toboolean => return try it.builtinToboolean(),
            .utf8bytelength => return try it.builtinUtf8bytelength(),

            // Trim builtins
            .trim_ => return try it.builtinTrim(.both),
            .ltrim_ => return try it.builtinTrim(.left),
            .rtrim_ => return try it.builtinTrim(.right),
        }
    }

    fn builtinLength(it: *ResultIterator) ZqError!?StackValue {
        const val = it.current;
        return switch (val) {
            .null_val => .{ .int = 0 },
            .bool_val => return error.TypeError,
            .int => |i| .{ .int = if (i < 0) -i else i },
            .float => |f| .{ .float = @abs(f) },
            .big_number => |bn| .{ .int = @intCast(bn.len) },
            .string => |sv| blk: {
                // Count Unicode codepoints, not bytes.
                const s = sv.slice();
                var count: i64 = 0;
                var i: usize = 0;
                while (i < s.len) {
                    const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
                        i += 1;
                        count += 1;
                        continue;
                    };
                    i += seq_len;
                    count += 1;
                }
                break :blk .{ .int = count };
            },
            .array => |span| .{ .int = @intCast(arrayLength(span.tape, span)) },
            .object => |span| blk: {
                var count: i64 = 0;
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    pos = skipEntry(span.tape.*, pos + 1); // skip value
                    count += 1;
                }
                break :blk .{ .int = count };
            },
        };
    }

    /// Build a sorted (or unsorted) array of keys from an object, or [0..n-1] for array.
    fn builtinKeys(it: *ResultIterator, sorted: bool) ZqError!?StackValue {
        switch (it.current) {
            .object => |span| {
                // Collect all keys
                var keys_list = std.ArrayList([]const u8){};
                defer keys_list.deinit(it.alloc);

                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const key_str = span.tape.getString(span.tape.entries[pos].payload.string);
                    try keys_list.append(it.alloc, key_str);
                    pos = skipEntry(span.tape.*, pos + 1); // skip value
                }

                if (sorted) {
                    std.mem.sort([]const u8, keys_list.items, {}, struct {
                        fn lt(_: void, a: []const u8, b: []const u8) bool {
                            return std.mem.lessThan(u8, a, b);
                        }
                    }.lt);
                }

                // Build array in runtime_tape
                const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_start,
                    .payload = .{ .skip = 0 },
                });
                for (keys_list.items) |k| {
                    const str_ref = try it.runtime_tape.internString(it.alloc, k);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .string,
                        .payload = .{ .string = str_ref },
                    });
                }
                const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
                return .{ .tape_value = .{ .array = .{
                    .tape = &it.runtime_tape.view,
                    .start = arr_start,
                    .end = arr_end_idx + 1,
                } } };
            },
            .array => |span| {
                const len = arrayLength(span.tape, span);
                const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_start,
                    .payload = .{ .skip = 0 },
                });
                var i: i64 = 0;
                while (i < @as(i64, @intCast(len))) : (i += 1) {
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .int,
                        .payload = .{ .int = i },
                    });
                }
                const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
                return .{ .tape_value = .{ .array = .{
                    .tape = &it.runtime_tape.view,
                    .start = arr_start,
                    .end = arr_end_idx + 1,
                } } };
            },
            else => return error.TypeError,
        }
    }

    fn builtinValues(it: *ResultIterator) ZqError!?StackValue {
        // jq `values` is a type selector: select(. != null)
        // Passes through all non-null values, produces empty for null.
        return switch (it.current) {
            .null_val => {
                it.ip = @intCast(it.instructions.len);
                return null;
            },
            else => try valueToStackValue(it.current),
        };
    }

    fn builtinHas(it: *ResultIterator) ZqError!?StackValue {
        const key_sv = try it.popValue();
        switch (it.current) {
            .object => |span| {
                const key_str = switch (key_sv) {
                    .tape_value => |tv| switch (tv) {
                        .string => |s| s.slice(),
                        else => return error.TypeError,
                    },
                    else => return error.TypeError,
                };
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const k = span.tape.getString(span.tape.entries[pos].payload.string);
                    if (std.mem.eql(u8, k, key_str)) return .{ .bool_val = true };
                    pos = skipEntry(span.tape.*, pos + 1);
                }
                return .{ .bool_val = false };
            },
            .array => |span| {
                switch (key_sv) {
                    .int => |i| {
                        if (i < 0) return .{ .bool_val = false };
                        const len = arrayLength(span.tape, span);
                        if (i > std.math.maxInt(u32)) return .{ .bool_val = false };
                        return .{ .bool_val = @as(u32, @intCast(i)) < len };
                    },
                    .float => |f| return .{ .bool_val = floatIndexInBounds(f, arrayLength(span.tape, span)) },
                    else => return error.TypeError,
                }
            },
            else => return error.TypeError,
        }
    }

    fn builtinIn(it: *ResultIterator) ZqError!?StackValue {
        // Dual of builtinHas: input is the key, popped arg is the container.
        const obj_sv = try it.popValue();
        const key_sv = try valueToStackValue(it.current);
        switch (obj_sv) {
            .tape_value => |tv| switch (tv) {
                .object => |span| {
                    const key_str = switch (key_sv) {
                        .tape_value => |ktv| switch (ktv) {
                            .string => |s| s.slice(),
                            else => return error.TypeError,
                        },
                        else => return error.TypeError,
                    };
                    var pos = span.start + 1;
                    const end = span.end - 1;
                    while (pos < end) {
                        const k = span.tape.getString(span.tape.entries[pos].payload.string);
                        if (std.mem.eql(u8, k, key_str)) return .{ .bool_val = true };
                        pos = skipEntry(span.tape.*, pos + 1);
                    }
                    return .{ .bool_val = false };
                },
                .array => |span| {
                    switch (key_sv) {
                        .int => |i| {
                            if (i < 0) return .{ .bool_val = false };
                            const len = arrayLength(span.tape, span);
                            if (i > std.math.maxInt(u32)) return .{ .bool_val = false };
                            return .{ .bool_val = @as(u32, @intCast(i)) < len };
                        },
                        .float => |f| return .{ .bool_val = floatIndexInBounds(f, arrayLength(span.tape, span)) },
                        else => return error.TypeError,
                    }
                },
                else => return error.TypeError,
            },
            else => return error.TypeError,
        }
    }

    fn builtinType(it: *ResultIterator) ?StackValue {
        const type_str: []const u8 = switch (it.current) {
            .null_val => "null",
            .bool_val => "boolean",
            .int, .float, .big_number => "number",
            .string => "string",
            .array => "array",
            .object => "object",
        };
        return .{ .tape_value = .{ .string = .{ .external = type_str } } };
    }

    fn builtinTostring(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .string => |s| return .{ .tape_value = .{ .string = s } },
            .null_val => return .{ .tape_value = .{ .string = .{ .external = "null" } } },
            .bool_val => |b| return .{ .tape_value = .{ .string = .{ .external = if (b) "true" else "false" } } },
            .int => |n| {
                var tmp: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return error.TypeError;
                const str_ref = try it.runtime_tape.internString(it.alloc, s);
                return it.rtStringSV(str_ref);
            },
            .float => |f| {
                const formatted = types.formatJqFloat(f);
                const str_ref = try it.runtime_tape.internString(it.alloc, formatted.slice());
                return it.rtStringSV(str_ref);
            },
            .big_number => |bn| {
                const str_ref = try it.runtime_tape.internString(it.alloc, bn);
                return it.rtStringSV(str_ref);
            },
            .array, .object => {
                // Compact JSON serialization into runtime_tape string_buf
                var json_buf = std.ArrayList(u8){};
                defer json_buf.deinit(it.alloc);
                try serializeValueCompact(&json_buf, it.alloc, it.current);
                const str_ref = try it.runtime_tape.internString(it.alloc, json_buf.items);
                return it.rtStringSV(str_ref);
            },
        }
    }

    fn builtinTonumber(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .int => |n| return .{ .int = n },
            .float => |f| return .{ .float = f },
            .big_number => |bn| return .{ .big_number = bn },
            .string => |sv| {
                const s = sv.slice();
                // Try integer parse first; fall back to float.
                // jq raises an error for null-byte strings or invalid number strings.
                const null_byte = std.mem.indexOfScalar(u8, s, 0) != null;
                if (!null_byte) {
                    if (std.fmt.parseInt(i64, s, 10)) |n| {
                        return .{ .int = n };
                    } else |_| {}
                    if (std.fmt.parseFloat(f64, s)) |f| {
                        return .{ .float = f };
                    } else |_| {}
                }
                // Build jq-compatible error message: string ("VALUE") cannot be parsed as a number
                var msg_buf = std.ArrayList(u8){};
                defer msg_buf.deinit(it.alloc);
                try msg_buf.appendSlice(it.alloc, "string (");
                try appendJsonString(&msg_buf, it.alloc, s);
                try msg_buf.appendSlice(it.alloc, ") cannot be parsed as a number");
                const str_ref = try it.runtime_tape.internString(it.alloc, msg_buf.items);
                it.user_error_msg = .{ .string = it.rtString(str_ref) };
                return error.UserError;
            },
            else => return error.TypeError,
        }
    }

    /// `toboolean`: convert string "true"/"false" to bool, pass through bools.
    fn builtinToboolean(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .bool_val => |b| return .{ .bool_val = b },
            .string => |sv| {
                const s = sv.slice();
                if (std.mem.eql(u8, s, "true")) return .{ .bool_val = true };
                if (std.mem.eql(u8, s, "false")) return .{ .bool_val = false };
                // Invalid string — produce typed error
                return try it.raiseTobooleanError();
            },
            else => return try it.raiseTobooleanError(),
        }
    }

    /// Build error message: "TYPE (VALUE) cannot be parsed as a boolean"
    fn raiseTobooleanError(it: *ResultIterator) ZqError!?StackValue {
        var msg_buf = std.ArrayList(u8){};
        defer msg_buf.deinit(it.alloc);
        try appendTypeName(&msg_buf, it.alloc, it.current);
        try msg_buf.appendSlice(it.alloc, " (");
        try serializeValueCompact(&msg_buf, it.alloc, it.current);
        try msg_buf.appendSlice(it.alloc, ") cannot be parsed as a boolean");
        const str_ref = try it.runtime_tape.internString(it.alloc, msg_buf.items);
        it.user_error_msg = .{ .string = it.rtString(str_ref) };
        return error.UserError;
    }

    /// `utf8bytelength`: return byte length of a string.
    fn builtinUtf8bytelength(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .string => |sv| return .{ .int = @intCast(sv.slice().len) },
            else => {
                var msg_buf = std.ArrayList(u8){};
                defer msg_buf.deinit(it.alloc);
                try appendTypeName(&msg_buf, it.alloc, it.current);
                try msg_buf.appendSlice(it.alloc, " (");
                try serializeValueCompact(&msg_buf, it.alloc, it.current);
                try msg_buf.appendSlice(it.alloc, ") only strings have UTF-8 byte length");
                const str_ref = try it.runtime_tape.internString(it.alloc, msg_buf.items);
                it.user_error_msg = .{ .string = it.rtString(str_ref) };
                return error.UserError;
            },
        }
    }

    const TrimSide = enum { left, right, both };

    /// `trim`, `ltrim`, `rtrim`: trim Unicode whitespace.
    fn builtinTrim(it: *ResultIterator, side: TrimSide) ZqError!?StackValue {
        const sv = switch (it.current) {
            .string => |sv| sv,
            else => return try it.raiseUserError("trim input must be a string"),
        };
        const s = sv.slice();

        var start: usize = 0;
        var end: usize = s.len;

        // Trim from left
        if (side == .left or side == .both) {
            while (start < end) {
                const seq_len = std.unicode.utf8ByteSequenceLength(s[start]) catch break;
                if (start + seq_len > end) break;
                const cp = std.unicode.utf8Decode(s[start..][0..seq_len]) catch break;
                if (!isUnicodeWhitespace(cp)) break;
                start += seq_len;
            }
        }

        // Trim from right
        if (side == .right or side == .both) {
            while (end > start) {
                // Walk backwards to find the start of the last codepoint
                var back: usize = 1;
                while (back < end - start and back < 4) : (back += 1) {
                    // Continuation bytes have the form 10xxxxxx
                    if (s[end - back] & 0xC0 != 0x80) break;
                }
                const cp_start = end - back;
                const seq_len = std.unicode.utf8ByteSequenceLength(s[cp_start]) catch break;
                if (cp_start + seq_len != end) break;
                const cp = std.unicode.utf8Decode(s[cp_start..][0..seq_len]) catch break;
                if (!isUnicodeWhitespace(cp)) break;
                end = cp_start;
            }
        }

        const trimmed = s[start..end];
        const str_ref = try it.runtime_tape.internString(it.alloc, trimmed);
        return it.rtStringSV(str_ref);
    }

    /// `add` builtin: fold array elements with +. Empty array → null.
    fn builtinAdd(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .array => |span| {
                var pos = span.start + 1;
                const end = span.end - 1;
                if (pos >= end) return .null_val; // empty array

                // Get first element
                var acc = try valueToStackValue(tapeEntryToValue(span.tape, pos));
                pos = skipEntry(span.tape.*, pos);

                // Fold remaining elements
                while (pos < end) {
                    const elem = try valueToStackValue(tapeEntryToValue(span.tape, pos));
                    acc = try it.doAddValues(acc, elem);
                    pos = skipEntry(span.tape.*, pos);
                }
                return acc;
            },
            .null_val => return .null_val,
            else => return error.TypeError,
        }
    }

    /// `sort`: sort array elements using jq total ordering.
    fn builtinSort(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .array => |span| {
                // Collect all elements as Values
                var elems = std.ArrayList(Value){};
                defer elems.deinit(it.alloc);
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    try elems.append(it.alloc, tapeEntryToValue(span.tape, pos));
                    pos = skipEntry(span.tape.*, pos);
                }
                // Sort using jqCompareValues
                std.mem.sort(Value, elems.items, {}, struct {
                    fn lt(_: void, a: Value, b: Value) bool {
                        return jqCompareValues(a, b) == .lt;
                    }
                }.lt);
                // Build runtime tape array
                return try it.buildRuntimeArray(elems.items);
            },
            else => return error.TypeError,
        }
    }

    /// `reverse`: reverse an array.
    fn builtinReverse(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .array => |span| {
                // Collect all elements as Values
                var elems = std.ArrayList(Value){};
                defer elems.deinit(it.alloc);
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    try elems.append(it.alloc, tapeEntryToValue(span.tape, pos));
                    pos = skipEntry(span.tape.*, pos);
                }
                // Reverse in place
                std.mem.reverse(Value, elems.items);
                // Build runtime tape array
                return try it.buildRuntimeArray(elems.items);
            },
            .string => |sv| {
                const s = sv.slice();
                // Reverse a string (by Unicode codepoints)
                var reversed = std.ArrayList(u8){};
                defer reversed.deinit(it.alloc);
                // Collect codepoint byte ranges
                var ranges = std.ArrayList(struct { start: usize, end: usize }){};
                defer ranges.deinit(it.alloc);
                var i: usize = 0;
                while (i < s.len) {
                    const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                    const cp_end = @min(i + seq_len, s.len);
                    try ranges.append(it.alloc, .{ .start = i, .end = cp_end });
                    i = cp_end;
                }
                // Build reversed string
                var ri = ranges.items.len;
                while (ri > 0) {
                    ri -= 1;
                    const r = ranges.items[ri];
                    try reversed.appendSlice(it.alloc, s[r.start..r.end]);
                }
                const str_ref = try it.runtime_tape.internString(it.alloc, reversed.items);
                return it.rtStringSV(str_ref);
            },
            else => return error.TypeError,
        }
    }

    /// `flatten` (zero-arg): recursively flatten all nested arrays.
    fn builtinFlatten(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .array => |span| {
                var elems = std.ArrayList(Value){};
                defer elems.deinit(it.alloc);
                try flattenRecursive(span, &elems, it.alloc);
                return try it.buildRuntimeArray(elems.items);
            },
            else => return error.TypeError,
        }
    }

    /// `min`: find the minimum element in an array. Empty array -> null.
    fn builtinMin(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .array => |span| {
                var pos = span.start + 1;
                const end = span.end - 1;
                if (pos >= end) return .null_val; // empty array
                var best = tapeEntryToValue(span.tape, pos);
                pos = skipEntry(span.tape.*, pos);
                while (pos < end) {
                    const elem = tapeEntryToValue(span.tape, pos);
                    if (jqCompareValues(elem, best) == .lt) {
                        best = elem;
                    }
                    pos = skipEntry(span.tape.*, pos);
                }
                return try valueToStackValue(best);
            },
            else => return error.TypeError,
        }
    }

    /// `max`: find the maximum element in an array. Empty array -> null.
    fn builtinMax(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .array => |span| {
                var pos = span.start + 1;
                const end = span.end - 1;
                if (pos >= end) return .null_val; // empty array
                var best = tapeEntryToValue(span.tape, pos);
                pos = skipEntry(span.tape.*, pos);
                while (pos < end) {
                    const elem = tapeEntryToValue(span.tape, pos);
                    if (jqCompareValues(elem, best) == .gt) {
                        best = elem;
                    }
                    pos = skipEntry(span.tape.*, pos);
                }
                return try valueToStackValue(best);
            },
            else => return error.TypeError,
        }
    }

    /// `to_entries`: convert object to array of {"key":k,"value":v} entries.
    fn builtinToEntries(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .object => |span| {
                // Build array of {key:k, value:v} objects
                const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_start,
                    .payload = .{ .skip = 0 },
                });
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const key_str = span.tape.getString(span.tape.entries[pos].payload.string);
                    const val = tapeEntryToValue(span.tape, pos + 1);

                    // Build {"key": key_str, "value": val}
                    const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .object_start,
                        .payload = .{ .skip = 0 },
                    });
                    // "key" field
                    const key_key_ref = try it.runtime_tape.internString(it.alloc, "key");
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .key,
                        .payload = .{ .string = key_key_ref },
                    });
                    const key_val_ref = try it.runtime_tape.internString(it.alloc, key_str);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .string,
                        .payload = .{ .string = key_val_ref },
                    });
                    // "value" field
                    const val_key_ref = try it.runtime_tape.internString(it.alloc, "value");
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .key,
                        .payload = .{ .string = val_key_ref },
                    });
                    const val_sv = try valueToStackValue(val);
                    try it.stackValueToRuntimeTapeEntry(val_sv);
                    // object_end
                    const obj_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .object_end,
                        .payload = .{ .none = {} },
                    });
                    it.runtime_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;

                    pos = skipEntry(span.tape.*, pos + 1);
                }
                const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
                return .{ .tape_value = .{ .array = .{
                    .tape = &it.runtime_tape.view,
                    .start = arr_start,
                    .end = arr_end_idx + 1,
                } } };
            },
            else => return error.TypeError,
        }
    }

    /// `from_entries`: convert array of entry objects to an object.
    /// Accepts "key", "name", or "Key" for key field; "value" or "Value" for value field.
    fn builtinFromEntries(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .array => |span| {
                const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .object_start,
                    .payload = .{ .skip = 0 },
                });
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const entry_val = tapeEntryToValue(span.tape, pos);
                    switch (entry_val) {
                        .object => |espan| {
                            // Look for key/name/Key/Name field (jq accepts all four variants)
                            const key_val = lookupKey(espan.tape, espan, "key") orelse
                                lookupKey(espan.tape, espan, "name") orelse
                                lookupKey(espan.tape, espan, "Key") orelse
                                lookupKey(espan.tape, espan, "Name") orelse
                                return error.TypeError;
                            // Extract key string
                            const key_str = switch (key_val) {
                                .string => |sv| sv.slice(),
                                // jq coerces non-string keys to string via tostring
                                .int => |n| blk: {
                                    var tmp: [32]u8 = undefined;
                                    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return error.TypeError;
                                    break :blk s;
                                },
                                .null_val => "null",
                                .bool_val => |b| if (b) "true" else "false",
                                else => return error.TypeError,
                            };
                            // Look for value/Value field (default to null)
                            const val = lookupKey(espan.tape, espan, "value") orelse
                                lookupKey(espan.tape, espan, "Value") orelse
                                Value.null_val;
                            // Emit key
                            const new_key_ref = try it.runtime_tape.internString(it.alloc, key_str);
                            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                                .tag = .key,
                                .payload = .{ .string = new_key_ref },
                            });
                            // Emit value
                            const val_sv = try valueToStackValue(val);
                            try it.stackValueToRuntimeTapeEntry(val_sv);
                        },
                        // jq also accepts strings as shorthand: "foo" -> {"key":"foo","value":null}
                        .string => |sv| {
                            const new_key_ref = try it.runtime_tape.internString(it.alloc, sv.slice());
                            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                                .tag = .key,
                                .payload = .{ .string = new_key_ref },
                            });
                            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                                .tag = .null_val,
                                .payload = .{ .none = {} },
                            });
                        },
                        else => return error.TypeError,
                    }
                    pos = skipEntry(span.tape.*, pos);
                }
                const obj_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .object_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;
                return .{ .tape_value = .{ .object = .{
                    .tape = &it.runtime_tape.view,
                    .start = obj_start,
                    .end = obj_end_idx + 1,
                } } };
            },
            else => return error.TypeError,
        }
    }

    /// `any` (zero-arg): true if any array element is truthy. Empty array -> false.
    fn builtinAny(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .array => |span| {
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const elem = tapeEntryToValue(span.tape, pos);
                    const sv = try valueToStackValue(elem);
                    if (isCondTruthy(sv)) return .{ .bool_val = true };
                    pos = skipEntry(span.tape.*, pos);
                }
                return .{ .bool_val = false };
            },
            else => return error.TypeError,
        }
    }

    /// `all` (zero-arg): true if all array elements are truthy. Empty array -> true.
    fn builtinAll(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .array => |span| {
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const elem = tapeEntryToValue(span.tape, pos);
                    const sv = try valueToStackValue(elem);
                    if (!isCondTruthy(sv)) return .{ .bool_val = false };
                    pos = skipEntry(span.tape.*, pos);
                }
                return .{ .bool_val = true };
            },
            else => return error.TypeError,
        }
    }

    /// `unique` (zero-arg): sort elements, remove consecutive duplicates.
    fn builtinUnique(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .array => |span| {
                // Collect all elements
                var elems = std.ArrayList(Value){};
                defer elems.deinit(it.alloc);
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    try elems.append(it.alloc, tapeEntryToValue(span.tape, pos));
                    pos = skipEntry(span.tape.*, pos);
                }
                // Sort
                std.mem.sort(Value, elems.items, {}, struct {
                    fn lt(_: void, a: Value, b: Value) bool {
                        return jqCompareValues(a, b) == .lt;
                    }
                }.lt);
                // Remove consecutive duplicates
                var unique_elems = std.ArrayList(Value){};
                defer unique_elems.deinit(it.alloc);
                for (elems.items) |elem| {
                    if (unique_elems.items.len == 0 or !jqValuesEqual(unique_elems.items[unique_elems.items.len - 1], elem)) {
                        try unique_elems.append(it.alloc, elem);
                    }
                }
                return try it.buildRuntimeArray(unique_elems.items);
            },
            else => return error.TypeError,
        }
    }

    /// `flatten(n)`: flatten array up to n levels deep.
    fn builtinFlattenN(it: *ResultIterator) ZqError!?StackValue {
        const depth_sv = try it.popValue();
        const depth: i64 = switch (depth_sv) {
            .int => |i| i,
            .float => |f| @as(i64, @intFromFloat(@round(f))),
            else => return error.TypeError,
        };
        // jq prelude: `if $d < 0 then error("flatten depth must not be negative")`
        // fires before the input-type check. UserError class so `try ... catch .`
        // surfaces the message string.
        if (depth < 0) return try it.raiseUserError("flatten depth must not be negative");
        switch (it.current) {
            .array => |span| {
                var elems = std.ArrayList(Value){};
                defer elems.deinit(it.alloc);
                try flattenNLevels(span, &elems, it.alloc, @intCast(depth));
                return try it.buildRuntimeArray(elems.items);
            },
            else => return error.TypeError,
        }
    }

    /// `contains(b)`: true if current recursively contains b.
    fn builtinContains(it: *ResultIterator) ZqError!?StackValue {
        const b_sv = try it.popValue();
        const b = try stackValueToValue(b_sv);
        return .{ .bool_val = jqContains(it.current, b) };
    }

    /// `inside(b)`: reverse of contains. `a | inside(b)` = `b | contains(a)`.
    fn builtinInside(it: *ResultIterator) ZqError!?StackValue {
        const b_sv = try it.popValue();
        const b = try stackValueToValue(b_sv);
        return .{ .bool_val = jqContains(b, it.current) };
    }

    /// `indices(s)`: find all positions of s in current.
    fn builtinIndices(it: *ResultIterator) ZqError!?StackValue {
        const needle_sv = try it.popValue();
        const needle = try stackValueToValue(needle_sv);
        var positions = std.ArrayList(Value){};
        defer positions.deinit(it.alloc);

        switch (it.current) {
            .string => |hsv| {
                const haystack = hsv.slice();
                // String search: find all codepoint indices of needle string
                const needle_str = switch (needle) {
                    .string => |sv| sv.slice(),
                    else => return error.TypeError,
                };
                if (needle_str.len == 0) {
                    // jq returns empty array for empty needle
                    return try it.buildRuntimeArray(positions.items);
                }
                var i: usize = 0;
                while (i + needle_str.len <= haystack.len) {
                    if (std.mem.eql(u8, haystack[i..][0..needle_str.len], needle_str)) {
                        try positions.append(it.alloc, .{ .int = byteOffsetToCodepointIndex(haystack, i) });
                    }
                    // Advance by one codepoint (not one byte) to match jq behavior
                    const seq_len = std.unicode.utf8ByteSequenceLength(haystack[i]) catch 1;
                    i += seq_len;
                }
                return try it.buildRuntimeArray(positions.items);
            },
            .array => |span| {
                switch (needle) {
                    .array => |needle_span| {
                        // Find all positions where sub-array occurs
                        const needle_len = arrayLength(needle_span.tape, needle_span);
                        if (needle_len == 0) return try it.buildRuntimeArray(positions.items);
                        const arr_len = arrayLength(span.tape, span);
                        if (needle_len > arr_len) return try it.buildRuntimeArray(positions.items);

                        var pos = span.start + 1;
                        const end = span.end - 1;
                        var idx: i64 = 0;
                        while (pos < end) {
                            // Check if sub-array starting at idx matches
                            var match = true;
                            var check_pos = pos;
                            var npos = needle_span.start + 1;
                            const nend = needle_span.end - 1;
                            while (npos < nend and check_pos < end) {
                                if (!jqValuesEqual(tapeEntryToValue(span.tape, check_pos), tapeEntryToValue(needle_span.tape, npos))) {
                                    match = false;
                                    break;
                                }
                                check_pos = skipEntry(span.tape.*, check_pos);
                                npos = skipEntry(needle_span.tape.*, npos);
                            }
                            if (match and npos >= nend) {
                                try positions.append(it.alloc, .{ .int = idx });
                            }
                            pos = skipEntry(span.tape.*, pos);
                            idx += 1;
                        }
                        return try it.buildRuntimeArray(positions.items);
                    },
                    else => {
                        // Find all positions of element in array
                        var pos = span.start + 1;
                        const end = span.end - 1;
                        var idx: i64 = 0;
                        while (pos < end) {
                            if (jqValuesEqual(tapeEntryToValue(span.tape, pos), needle)) {
                                try positions.append(it.alloc, .{ .int = idx });
                            }
                            pos = skipEntry(span.tape.*, pos);
                            idx += 1;
                        }
                        return try it.buildRuntimeArray(positions.items);
                    },
                }
            },
            .null_val => return .null_val,
            else => return error.TypeError,
        }
    }

    /// `index(s)`: first occurrence (null if not found).
    fn builtinIndex(it: *ResultIterator) ZqError!?StackValue {
        const needle_sv = try it.popValue();
        const needle = try stackValueToValue(needle_sv);

        switch (it.current) {
            .string => |hsv| {
                const haystack = hsv.slice();
                const needle_str = switch (needle) {
                    .string => |sv| sv.slice(),
                    else => return error.TypeError,
                };
                if (needle_str.len == 0 or haystack.len == 0) return .null_val;
                if (std.mem.indexOf(u8, haystack, needle_str)) |byte_pos| {
                    return .{ .int = byteOffsetToCodepointIndex(haystack, byte_pos) };
                }
                return .null_val;
            },
            .array => |span| {
                switch (needle) {
                    .array => |needle_span| {
                        const needle_len = arrayLength(needle_span.tape, needle_span);
                        if (needle_len == 0) return .null_val;
                        var pos = span.start + 1;
                        const end = span.end - 1;
                        var idx: i64 = 0;
                        while (pos < end) {
                            var match = true;
                            var check_pos = pos;
                            var npos = needle_span.start + 1;
                            const nend = needle_span.end - 1;
                            while (npos < nend and check_pos < end) {
                                if (!jqValuesEqual(tapeEntryToValue(span.tape, check_pos), tapeEntryToValue(needle_span.tape, npos))) {
                                    match = false;
                                    break;
                                }
                                check_pos = skipEntry(span.tape.*, check_pos);
                                npos = skipEntry(needle_span.tape.*, npos);
                            }
                            if (match and npos >= nend) return .{ .int = idx };
                            pos = skipEntry(span.tape.*, pos);
                            idx += 1;
                        }
                        return .null_val;
                    },
                    else => {
                        var pos = span.start + 1;
                        const end = span.end - 1;
                        var idx: i64 = 0;
                        while (pos < end) {
                            if (jqValuesEqual(tapeEntryToValue(span.tape, pos), needle)) return .{ .int = idx };
                            pos = skipEntry(span.tape.*, pos);
                            idx += 1;
                        }
                        return .null_val;
                    },
                }
            },
            .null_val => return .null_val,
            else => return error.TypeError,
        }
    }

    /// `rindex(s)`: last occurrence (null if not found).
    fn builtinRindex(it: *ResultIterator) ZqError!?StackValue {
        const needle_sv = try it.popValue();
        const needle = try stackValueToValue(needle_sv);

        switch (it.current) {
            .string => |hsv| {
                const haystack = hsv.slice();
                const needle_str = switch (needle) {
                    .string => |sv| sv.slice(),
                    else => return error.TypeError,
                };
                if (needle_str.len == 0 or haystack.len == 0) return .null_val;
                if (needle_str.len > haystack.len) return .null_val;
                // Search backwards: start from the last possible position
                var i: usize = haystack.len - needle_str.len + 1;
                while (i > 0) {
                    i -= 1;
                    if (std.mem.eql(u8, haystack[i..][0..needle_str.len], needle_str)) {
                        return .{ .int = byteOffsetToCodepointIndex(haystack, i) };
                    }
                }
                return .null_val;
            },
            .array => |span| {
                switch (needle) {
                    .array => |needle_span| {
                        const needle_len = arrayLength(needle_span.tape, needle_span);
                        if (needle_len == 0) return .null_val;
                        // Collect all element positions for reverse scan
                        var elem_positions = std.ArrayList(u32){};
                        defer elem_positions.deinit(it.alloc);
                        var pos = span.start + 1;
                        const end = span.end - 1;
                        while (pos < end) {
                            try elem_positions.append(it.alloc, pos);
                            pos = skipEntry(span.tape.*, pos);
                        }
                        // Scan backwards
                        var idx: i64 = @intCast(elem_positions.items.len);
                        while (idx > 0) {
                            idx -= 1;
                            const check_start = elem_positions.items[@intCast(idx)];
                            var match = true;
                            var check_pos = check_start;
                            var npos = needle_span.start + 1;
                            const nend = needle_span.end - 1;
                            while (npos < nend and check_pos < end) {
                                if (!jqValuesEqual(tapeEntryToValue(span.tape, check_pos), tapeEntryToValue(needle_span.tape, npos))) {
                                    match = false;
                                    break;
                                }
                                check_pos = skipEntry(span.tape.*, check_pos);
                                npos = skipEntry(needle_span.tape.*, npos);
                            }
                            if (match and npos >= nend) return .{ .int = idx };
                        }
                        return .null_val;
                    },
                    else => {
                        var pos = span.start + 1;
                        const end = span.end - 1;
                        var last_idx: ?i64 = null;
                        var idx: i64 = 0;
                        while (pos < end) {
                            if (jqValuesEqual(tapeEntryToValue(span.tape, pos), needle)) last_idx = idx;
                            pos = skipEntry(span.tape.*, pos);
                            idx += 1;
                        }
                        return if (last_idx) |li| .{ .int = li } else .null_val;
                    },
                }
            },
            .null_val => return .null_val,
            else => return error.TypeError,
        }
    }

    /// `sort_by(f)`: Sort array by keys computed by f.
    /// Pops keys array from value_stack, original array from if_stack.
    fn builtinSortBy(it: *ResultIterator) ZqError!?StackValue {
        const keys_sv = try it.popValue();
        const keys_val = try stackValueToValue(keys_sv);
        if (it.if_stack.items.len == 0) return error.TypeError;
        const original = it.if_stack.pop().?;

        const keys_span = switch (keys_val) {
            .array => |s| s,
            else => return error.TypeError,
        };
        const orig_span = switch (original) {
            .array => |s| s,
            else => return error.TypeError,
        };

        // Collect elements and keys
        var pairs = std.ArrayList(ValueKeyPair){};
        defer pairs.deinit(it.alloc);

        var epos = orig_span.start + 1;
        const eend = orig_span.end - 1;
        var kpos = keys_span.start + 1;
        const kend = keys_span.end - 1;
        while (epos < eend and kpos < kend) {
            try pairs.append(it.alloc, .{
                .value = tapeEntryToValue(orig_span.tape, epos),
                .key = tapeEntryToValue(keys_span.tape, kpos),
            });
            epos = skipEntry(orig_span.tape.*, epos);
            kpos = skipEntry(keys_span.tape.*, kpos);
        }

        // Sort by key using jqCompareValues
        std.mem.sort(ValueKeyPair, pairs.items, {}, struct {
            fn lt(_: void, a: ValueKeyPair, b: ValueKeyPair) bool {
                return jqCompareValues(a.key, b.key) == .lt;
            }
        }.lt);

        // Build result array from sorted elements
        var result = std.ArrayList(Value){};
        defer result.deinit(it.alloc);
        for (pairs.items) |p| try result.append(it.alloc, p.value);
        return try it.buildRuntimeArray(result.items);
    }

    /// `group_by(f)`: Group array elements by key.
    fn builtinGroupBy(it: *ResultIterator) ZqError!?StackValue {
        const keys_sv = try it.popValue();
        const keys_val = try stackValueToValue(keys_sv);
        if (it.if_stack.items.len == 0) return error.TypeError;
        const original = it.if_stack.pop().?;

        const keys_span = switch (keys_val) {
            .array => |s| s,
            else => return error.TypeError,
        };
        const orig_span = switch (original) {
            .array => |s| s,
            else => return error.TypeError,
        };

        // Collect pairs
        var pairs = std.ArrayList(ValueKeyPair){};
        defer pairs.deinit(it.alloc);

        var epos = orig_span.start + 1;
        const eend = orig_span.end - 1;
        var kpos = keys_span.start + 1;
        const kend = keys_span.end - 1;
        while (epos < eend and kpos < kend) {
            try pairs.append(it.alloc, .{
                .value = tapeEntryToValue(orig_span.tape, epos),
                .key = tapeEntryToValue(keys_span.tape, kpos),
            });
            epos = skipEntry(orig_span.tape.*, epos);
            kpos = skipEntry(keys_span.tape.*, kpos);
        }

        // Sort by key
        std.mem.sort(ValueKeyPair, pairs.items, {}, struct {
            fn lt(_: void, a: ValueKeyPair, b: ValueKeyPair) bool {
                return jqCompareValues(a.key, b.key) == .lt;
            }
        }.lt);

        // Group consecutive elements with equal keys
        // Build array of arrays
        const outer_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });

        var i: usize = 0;
        while (i < pairs.items.len) {
            const group_key = pairs.items[i].key;
            // Find end of this group
            var j = i + 1;
            while (j < pairs.items.len and jqValuesEqual(pairs.items[j].key, group_key)) {
                j += 1;
            }
            // Build inner array for this group
            const inner_start = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .array_start,
                .payload = .{ .skip = 0 },
            });
            var k = i;
            while (k < j) : (k += 1) {
                const sv = try valueToStackValue(pairs.items[k].value);
                try it.stackValueToRuntimeTapeEntry(sv);
            }
            const inner_end = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .array_end,
                .payload = .{ .none = {} },
            });
            it.runtime_tape.entries.items[inner_start].payload.skip = inner_end + 1;

            i = j;
        }

        const outer_end = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[outer_start].payload.skip = outer_end + 1;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape.view,
            .start = outer_start,
            .end = outer_end + 1,
        } } };
    }

    /// `min_by(f)`: find element with minimum key.
    fn builtinMinBy(it: *ResultIterator) ZqError!?StackValue {
        const keys_sv = try it.popValue();
        const keys_val = try stackValueToValue(keys_sv);
        if (it.if_stack.items.len == 0) return error.TypeError;
        const original = it.if_stack.pop().?;

        const keys_span = switch (keys_val) {
            .array => |s| s,
            else => return error.TypeError,
        };
        const orig_span = switch (original) {
            .array => |s| s,
            else => return error.TypeError,
        };

        var epos = orig_span.start + 1;
        const eend = orig_span.end - 1;
        var kpos = keys_span.start + 1;
        const kend = keys_span.end - 1;
        if (epos >= eend) return .null_val;

        var best_val = tapeEntryToValue(orig_span.tape, epos);
        var best_key = tapeEntryToValue(keys_span.tape, kpos);
        epos = skipEntry(orig_span.tape.*, epos);
        kpos = skipEntry(keys_span.tape.*, kpos);

        while (epos < eend and kpos < kend) {
            const elem = tapeEntryToValue(orig_span.tape, epos);
            const key = tapeEntryToValue(keys_span.tape, kpos);
            if (jqCompareValues(key, best_key) == .lt) {
                best_val = elem;
                best_key = key;
            }
            epos = skipEntry(orig_span.tape.*, epos);
            kpos = skipEntry(keys_span.tape.*, kpos);
        }
        return try valueToStackValue(best_val);
    }

    /// `max_by(f)`: find element with maximum key.
    fn builtinMaxBy(it: *ResultIterator) ZqError!?StackValue {
        const keys_sv = try it.popValue();
        const keys_val = try stackValueToValue(keys_sv);
        if (it.if_stack.items.len == 0) return error.TypeError;
        const original = it.if_stack.pop().?;

        const keys_span = switch (keys_val) {
            .array => |s| s,
            else => return error.TypeError,
        };
        const orig_span = switch (original) {
            .array => |s| s,
            else => return error.TypeError,
        };

        var epos = orig_span.start + 1;
        const eend = orig_span.end - 1;
        var kpos = keys_span.start + 1;
        const kend = keys_span.end - 1;
        if (epos >= eend) return .null_val;

        var best_val = tapeEntryToValue(orig_span.tape, epos);
        var best_key = tapeEntryToValue(keys_span.tape, kpos);
        epos = skipEntry(orig_span.tape.*, epos);
        kpos = skipEntry(keys_span.tape.*, kpos);

        while (epos < eend and kpos < kend) {
            const elem = tapeEntryToValue(orig_span.tape, epos);
            const key = tapeEntryToValue(keys_span.tape, kpos);
            if (jqCompareValues(key, best_key) != .lt) {
                best_val = elem;
                best_key = key;
            }
            epos = skipEntry(orig_span.tape.*, epos);
            kpos = skipEntry(keys_span.tape.*, kpos);
        }
        return try valueToStackValue(best_val);
    }

    /// `unique_by(f)`: remove duplicates by key (sort by key, then dedup).
    fn builtinUniqueBy(it: *ResultIterator) ZqError!?StackValue {
        const keys_sv = try it.popValue();
        const keys_val = try stackValueToValue(keys_sv);
        if (it.if_stack.items.len == 0) return error.TypeError;
        const original = it.if_stack.pop().?;

        const keys_span = switch (keys_val) {
            .array => |s| s,
            else => return error.TypeError,
        };
        const orig_span = switch (original) {
            .array => |s| s,
            else => return error.TypeError,
        };

        // Collect pairs
        var pairs = std.ArrayList(ValueKeyPair){};
        defer pairs.deinit(it.alloc);

        var epos = orig_span.start + 1;
        const eend = orig_span.end - 1;
        var kpos = keys_span.start + 1;
        const kend = keys_span.end - 1;
        while (epos < eend and kpos < kend) {
            try pairs.append(it.alloc, .{
                .value = tapeEntryToValue(orig_span.tape, epos),
                .key = tapeEntryToValue(keys_span.tape, kpos),
            });
            epos = skipEntry(orig_span.tape.*, epos);
            kpos = skipEntry(keys_span.tape.*, kpos);
        }

        // Sort by key
        std.mem.sort(ValueKeyPair, pairs.items, {}, struct {
            fn lt(_: void, a: ValueKeyPair, b: ValueKeyPair) bool {
                return jqCompareValues(a.key, b.key) == .lt;
            }
        }.lt);

        // Deduplicate consecutive equal keys
        var result = std.ArrayList(Value){};
        defer result.deinit(it.alloc);
        var last_key: ?Value = null;
        for (pairs.items) |p| {
            if (last_key == null or !jqValuesEqual(last_key.?, p.key)) {
                try result.append(it.alloc, p.value);
                last_key = p.key;
            }
        }
        return try it.buildRuntimeArray(result.items);
    }

    /// `del(key_or_index)`: delete a key from object or element from array.
    fn builtinDel(it: *ResultIterator) ZqError!?StackValue {
        const key_sv = try it.popValue();

        switch (it.current) {
            .object => |span| {
                // Delete by key (string)
                const key_str = switch (key_sv) {
                    .tape_value => |tv| switch (tv) {
                        .string => |sv| sv.slice(),
                        else => return error.TypeError,
                    },
                    else => return error.TypeError,
                };
                const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .object_start,
                    .payload = .{ .skip = 0 },
                });
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const k = span.tape.getString(span.tape.entries[pos].payload.string);
                    const val_pos = pos + 1;
                    if (!std.mem.eql(u8, k, key_str)) {
                        const new_key_ref = try it.runtime_tape.internString(it.alloc, k);
                        _ = try it.runtime_tape.appendEntry(it.alloc, .{
                            .tag = .key,
                            .payload = .{ .string = new_key_ref },
                        });
                        const orig_val = tapeEntryToValue(span.tape, val_pos);
                        try it.stackValueToRuntimeTapeEntry(try valueToStackValue(orig_val));
                    }
                    pos = skipEntry(span.tape.*, val_pos);
                }
                const obj_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .object_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;
                return .{ .tape_value = .{ .object = .{
                    .tape = &it.runtime_tape.view,
                    .start = obj_start,
                    .end = obj_end_idx + 1,
                } } };
            },
            .array => |span| {
                // Delete by index (integer)
                const idx = switch (key_sv) {
                    .int => |i| i,
                    else => return error.TypeError,
                };
                const arr_len = arrayLength(span.tape, span);
                const resolved_idx: ?u32 = if (idx < 0) blk: {
                    const neg_idx = @as(i64, @intCast(arr_len)) + idx;
                    if (neg_idx < 0 or neg_idx > std.math.maxInt(u32)) break :blk null;
                    break :blk @intCast(neg_idx);
                } else blk: {
                    if (idx > std.math.maxInt(u32)) break :blk null;
                    break :blk @intCast(idx);
                };

                const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_start,
                    .payload = .{ .skip = 0 },
                });
                var pos = span.start + 1;
                const end = span.end - 1;
                var i: u32 = 0;
                while (pos < end) {
                    if (resolved_idx == null or i != resolved_idx.?) {
                        const sv = try valueToStackValue(tapeEntryToValue(span.tape, pos));
                        try it.stackValueToRuntimeTapeEntry(sv);
                    }
                    pos = skipEntry(span.tape.*, pos);
                    i += 1;
                }
                const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
                return .{ .tape_value = .{ .array = .{
                    .tape = &it.runtime_tape.view,
                    .start = arr_start,
                    .end = arr_end_idx + 1,
                } } };
            },
            else => return error.TypeError,
        }
    }

    // ── Format string builtins ─────────────────────────────────────────────

    /// @json: serialize current value as compact JSON string (like tojson)
    fn builtinFormatJson(it: *ResultIterator) ZqError!?StackValue {
        var json_buf = std.ArrayList(u8){};
        defer json_buf.deinit(it.alloc);
        try serializeValueCompact(&json_buf, it.alloc, it.current);
        const str_ref = try it.runtime_tape.internString(it.alloc, json_buf.items);
        return it.rtStringSV(str_ref);
    }

    /// @html: HTML-escape: & → &amp;, < → &lt;, > → &gt;, ' → &apos;, " → &quot;
    fn builtinFormatHtml(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return error.TypeError,
        };
        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        for (s) |c| {
            switch (c) {
                '&' => try buf.appendSlice(it.alloc, "&amp;"),
                '<' => try buf.appendSlice(it.alloc, "&lt;"),
                '>' => try buf.appendSlice(it.alloc, "&gt;"),
                '\'' => try buf.appendSlice(it.alloc, "&apos;"),
                '"' => try buf.appendSlice(it.alloc, "&quot;"),
                else => try buf.append(it.alloc, c),
            }
        }
        const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
        return it.rtStringSV(str_ref);
    }

    /// @uri: Percent-encode all bytes except A-Za-z0-9-._~, uppercase hex (%XX)
    fn builtinFormatUri(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return error.TypeError,
        };
        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        for (s) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
                try buf.append(it.alloc, c);
            } else {
                var tmp: [3]u8 = undefined;
                const hex = std.fmt.bufPrint(&tmp, "%{X:0>2}", .{c}) catch unreachable;
                try buf.appendSlice(it.alloc, hex);
            }
        }
        const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
        return it.rtStringSV(str_ref);
    }

    /// @urid: Decode %XX sequences in a string
    fn builtinFormatUrid(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return error.TypeError,
        };
        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '%' and i + 2 < s.len) {
                const high = hexDigitVal(s[i + 1]);
                const low = hexDigitVal(s[i + 2]);
                if (high != null and low != null) {
                    try buf.append(it.alloc, (high.? << 4) | low.?);
                    i += 3;
                    continue;
                }
            }
            try buf.append(it.alloc, s[i]);
            i += 1;
        }
        const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
        return it.rtStringSV(str_ref);
    }

    /// @sh: Wrap in single quotes, escape ' as '\''
    fn builtinFormatSh(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return error.TypeError,
        };
        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        try buf.append(it.alloc, '\'');
        for (s) |c| {
            if (c == '\'') {
                try buf.appendSlice(it.alloc, "'\\''");
            } else {
                try buf.append(it.alloc, c);
            }
        }
        try buf.append(it.alloc, '\'');
        const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
        return it.rtStringSV(str_ref);
    }

    /// @base64: Base64 encode the string
    fn builtinFormatBase64(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return error.TypeError,
        };
        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(s.len);
        const buf = try it.scratch.allocator().alloc(u8, encoded_len);
        const encoded = encoder.encode(buf, s);
        const str_ref = try it.runtime_tape.internString(it.alloc, encoded);
        return it.rtStringSV(str_ref);
    }

    /// @base64d: Base64 decode the string
    fn builtinFormatBase64d(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return error.TypeError,
        };
        const decoder = std.base64.standard.Decoder;
        const decoded_len = decoder.calcSizeForSlice(s) catch return error.TypeError;
        const buf = try it.scratch.allocator().alloc(u8, decoded_len);
        decoder.decode(buf, s) catch return error.TypeError;
        const str_ref = try it.runtime_tape.internString(it.alloc, buf[0..decoded_len]);
        return it.rtStringSV(str_ref);
    }

    /// @csv: Array → CSV row. Strings double-quoted (internal " doubled to ""),
    /// numbers/bools/null unquoted
    fn builtinFormatCsv(it: *ResultIterator) ZqError!?StackValue {
        const span = switch (it.current) {
            .array => |s| s,
            else => return error.TypeError,
        };
        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        var pos = span.start + 1;
        const end = span.end - 1;
        var first = true;
        while (pos < end) {
            if (!first) try buf.append(it.alloc, ',');
            first = false;
            const elem = tapeEntryToValue(span.tape, pos);
            switch (elem) {
                .string => |sv| {
                    try buf.append(it.alloc, '"');
                    for (sv.slice()) |c| {
                        if (c == '"') {
                            try buf.appendSlice(it.alloc, "\"\"");
                        } else {
                            try buf.append(it.alloc, c);
                        }
                    }
                    try buf.append(it.alloc, '"');
                },
                .int => |n| {
                    var tmp: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
                    try buf.appendSlice(it.alloc, s);
                },
                .float => |f| {
                    const formatted = types.formatJqFloat(f);
                    try buf.appendSlice(it.alloc, formatted.slice());
                },
                .bool_val => |b| try buf.appendSlice(it.alloc, if (b) "true" else "false"),
                .null_val => try buf.appendSlice(it.alloc, "null"),
                else => return error.TypeError,
            }
            pos = skipEntry(span.tape.*, pos);
        }
        const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
        return it.rtStringSV(str_ref);
    }

    /// @tsv: Array → TSV row. Tab-separated, strings escape \t→\\t, \n→\\n, \r→\\r, \\→\\\\
    fn builtinFormatTsv(it: *ResultIterator) ZqError!?StackValue {
        const span = switch (it.current) {
            .array => |s| s,
            else => return error.TypeError,
        };
        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        var pos = span.start + 1;
        const end = span.end - 1;
        var first = true;
        while (pos < end) {
            if (!first) try buf.append(it.alloc, '\t');
            first = false;
            const elem = tapeEntryToValue(span.tape, pos);
            switch (elem) {
                .string => |sv| {
                    for (sv.slice()) |c| {
                        switch (c) {
                            '\t' => try buf.appendSlice(it.alloc, "\\t"),
                            '\n' => try buf.appendSlice(it.alloc, "\\n"),
                            '\r' => try buf.appendSlice(it.alloc, "\\r"),
                            '\\' => try buf.appendSlice(it.alloc, "\\\\"),
                            else => try buf.append(it.alloc, c),
                        }
                    }
                },
                .int => |n| {
                    var tmp: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
                    try buf.appendSlice(it.alloc, s);
                },
                .float => |f| {
                    const formatted = types.formatJqFloat(f);
                    try buf.appendSlice(it.alloc, formatted.slice());
                },
                .bool_val => |b| try buf.appendSlice(it.alloc, if (b) "true" else "false"),
                .null_val => try buf.appendSlice(it.alloc, "null"),
                else => return error.TypeError,
            }
            pos = skipEntry(span.tape.*, pos);
        }
        const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
        return it.rtStringSV(str_ref);
    }

    /// Helper: build a runtime tape array from a slice of Values.
    fn buildRuntimeArray(it: *ResultIterator, elems: []const Value) ZqError!StackValue {
        const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });
        for (elems) |elem| {
            const sv = try valueToStackValue(elem);
            try it.stackValueToRuntimeTapeEntry(sv);
        }
        const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape.view,
            .start = arr_start,
            .end = arr_end_idx + 1,
        } } };
    }

    /// `range(n)`: generate 0..n-1 via fork stack
    fn builtinRange1(it: *ResultIterator) ZqError!?StackValue {
        const end_sv = try it.popValue();
        const resume_ip = it.ip + 1;

        switch (end_sv) {
            .int => |end_n| {
                if (end_n <= 0) {
                    if (!(try it.doBacktrack())) it.ip = @intCast(it.instructions.len);
                    return null;
                }
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .saved_current_args = it.current_args,
                    .saved_call_len = @intCast(it.call_stack.items.len),
                    .backtrack_ip = resume_ip,
                    .aux = .{ .range = .{
                        .current_int = 0,
                        .end_int = end_n,
                        .step_int = 1,
                        .current_float = 0,
                        .end_float = 0,
                        .step_float = 0,
                        .is_float = false,
                    } },
                    .saved_path = it.snapshotPathState(),
                    .saved_stack = try it.snapshotValueStackForFork(),
                    .saved_object = try it.snapshotObjectConstructState(),
                });
                it.current = .{ .int = 0 };
                it.ip = resume_ip;
            },
            .float => |end_f| {
                if (end_f <= 0) {
                    if (!(try it.doBacktrack())) it.ip = @intCast(it.instructions.len);
                    return null;
                }
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .saved_current_args = it.current_args,
                    .saved_call_len = @intCast(it.call_stack.items.len),
                    .backtrack_ip = resume_ip,
                    .aux = .{ .range = .{
                        .current_int = 0,
                        .end_int = 0,
                        .step_int = 0,
                        .current_float = 0,
                        .end_float = end_f,
                        .step_float = 1,
                        .is_float = true,
                    } },
                    .saved_path = it.snapshotPathState(),
                    .saved_stack = try it.snapshotValueStackForFork(),
                    .saved_object = try it.snapshotObjectConstructState(),
                });
                it.current = .{ .float = 0 };
                it.ip = resume_ip;
            },
            else => return error.TypeError,
        }
        return null;
    }

    /// `range(from;to)`: generate from..to-1 via fork stack
    fn builtinRange2(it: *ResultIterator) ZqError!?StackValue {
        const to_sv = try it.popValue();
        const from_sv = try it.popValue();
        const resume_ip = it.ip + 1;

        const is_float = (from_sv == .float or to_sv == .float);
        if (is_float) {
            const from_f: f64 = switch (from_sv) {
                .float => |f| f,
                .int => |i| @floatFromInt(i),
                else => return error.TypeError,
            };
            const to_f: f64 = switch (to_sv) {
                .float => |f| f,
                .int => |i| @floatFromInt(i),
                else => return error.TypeError,
            };
            if (from_f >= to_f) {
                if (!(try it.doBacktrack())) it.ip = @intCast(it.instructions.len);
                return null;
            }
            it.fork_stack.appendAssumeCapacity(.{
                .saved_value_stack_len = @intCast(it.value_stack.items.len),
                .saved_current = it.current,
                .saved_current_args = it.current_args,
                .saved_call_len = @intCast(it.call_stack.items.len),
                .backtrack_ip = resume_ip,
                .aux = .{ .range = .{
                    .current_int = 0,
                    .end_int = 0,
                    .step_int = 0,
                    .current_float = from_f,
                    .end_float = to_f,
                    .step_float = 1,
                    .is_float = true,
                } },
                .saved_path = it.snapshotPathState(),
                .saved_stack = try it.snapshotValueStackForFork(),
                .saved_object = try it.snapshotObjectConstructState(),
            });
            it.current = .{ .float = from_f };
        } else {
            const from_i: i64 = switch (from_sv) {
                .int => |i| i,
                else => return error.TypeError,
            };
            const to_i: i64 = switch (to_sv) {
                .int => |i| i,
                else => return error.TypeError,
            };
            if (from_i >= to_i) {
                if (!(try it.doBacktrack())) it.ip = @intCast(it.instructions.len);
                return null;
            }
            it.fork_stack.appendAssumeCapacity(.{
                .saved_value_stack_len = @intCast(it.value_stack.items.len),
                .saved_current = it.current,
                .saved_current_args = it.current_args,
                .saved_call_len = @intCast(it.call_stack.items.len),
                .backtrack_ip = resume_ip,
                .aux = .{ .range = .{
                    .current_int = from_i,
                    .end_int = to_i,
                    .step_int = 1,
                    .current_float = 0,
                    .end_float = 0,
                    .step_float = 0,
                    .is_float = false,
                } },
                .saved_path = it.snapshotPathState(),
                .saved_stack = try it.snapshotValueStackForFork(),
                .saved_object = try it.snapshotObjectConstructState(),
            });
            it.current = .{ .int = from_i };
        }
        it.ip = resume_ip;
        return null;
    }

    /// `range(from;to;by)`: generate from..to-1 stepping by `by` via fork stack
    fn builtinRange3(it: *ResultIterator) ZqError!?StackValue {
        const by_sv = try it.popValue();
        const to_sv = try it.popValue();
        const from_sv = try it.popValue();
        const resume_ip = it.ip + 1;

        const is_float = (from_sv == .float or to_sv == .float or by_sv == .float);
        if (is_float) {
            const from_f: f64 = switch (from_sv) {
                .float => |f| f,
                .int => |i| @floatFromInt(i),
                else => return error.TypeError,
            };
            const to_f: f64 = switch (to_sv) {
                .float => |f| f,
                .int => |i| @floatFromInt(i),
                else => return error.TypeError,
            };
            const by_f: f64 = switch (by_sv) {
                .float => |f| f,
                .int => |i| @floatFromInt(i),
                else => return error.TypeError,
            };
            if (by_f == 0 or (by_f > 0 and from_f >= to_f) or (by_f < 0 and from_f <= to_f)) {
                if (!(try it.doBacktrack())) it.ip = @intCast(it.instructions.len);
                return null;
            }
            it.fork_stack.appendAssumeCapacity(.{
                .saved_value_stack_len = @intCast(it.value_stack.items.len),
                .saved_current = it.current,
                .saved_current_args = it.current_args,
                .saved_call_len = @intCast(it.call_stack.items.len),
                .backtrack_ip = resume_ip,
                .aux = .{ .range = .{
                    .current_int = 0,
                    .end_int = 0,
                    .step_int = 0,
                    .current_float = from_f,
                    .end_float = to_f,
                    .step_float = by_f,
                    .is_float = true,
                } },
                .saved_path = it.snapshotPathState(),
                .saved_stack = try it.snapshotValueStackForFork(),
                .saved_object = try it.snapshotObjectConstructState(),
            });
            it.current = .{ .float = from_f };
        } else {
            const from_i: i64 = switch (from_sv) {
                .int => |i| i,
                else => return error.TypeError,
            };
            const to_i: i64 = switch (to_sv) {
                .int => |i| i,
                else => return error.TypeError,
            };
            const by_i: i64 = switch (by_sv) {
                .int => |i| i,
                else => return error.TypeError,
            };
            if (by_i == 0 or (by_i > 0 and from_i >= to_i) or (by_i < 0 and from_i <= to_i)) {
                if (!(try it.doBacktrack())) it.ip = @intCast(it.instructions.len);
                return null;
            }
            it.fork_stack.appendAssumeCapacity(.{
                .saved_value_stack_len = @intCast(it.value_stack.items.len),
                .saved_current = it.current,
                .saved_current_args = it.current_args,
                .saved_call_len = @intCast(it.call_stack.items.len),
                .backtrack_ip = resume_ip,
                .aux = .{ .range = .{
                    .current_int = from_i,
                    .end_int = to_i,
                    .step_int = by_i,
                    .current_float = 0,
                    .end_float = 0,
                    .step_float = 0,
                    .is_float = false,
                } },
                .saved_path = it.snapshotPathState(),
                .saved_stack = try it.snapshotValueStackForFork(),
                .saved_object = try it.snapshotObjectConstructState(),
            });
            it.current = .{ .int = from_i };
        }
        it.ip = resume_ip;
        return null;
    }

    /// Helper: extract all elements from an array Value into a slice of Values.
    fn extractArrayElements(it: *ResultIterator, arr: Value) ZqError![]Value {
        const span = switch (arr) {
            .array => |s| s,
            else => return error.TypeError,
        };
        const len = arrayLength(span.tape, span);
        const elems = try it.scratch.allocator().alloc(Value, len);
        var pos = span.start + 1;
        const end = span.end - 1;
        var i: u32 = 0;
        while (pos < end) : (i += 1) {
            elems[i] = tapeEntryToValue(span.tape, pos);
            pos = skipEntry(span.tape.*, pos);
        }
        return elems;
    }

    /// Helper: generate range values from start to end (exclusive) by step, appending to results.
    fn generateRangeValues(it: *ResultIterator, results: *std.ArrayList(Value), from_i: i64, to_i: i64, step_i: i64) !void {
        if (step_i > 0) {
            var cur = from_i;
            while (cur < to_i) : (cur += step_i) {
                try results.append(it.alloc, .{ .int = cur });
            }
        } else if (step_i < 0) {
            var cur = from_i;
            while (cur > to_i) : (cur += step_i) {
                try results.append(it.alloc, .{ .int = cur });
            }
        }
        // step_i == 0: produce nothing
    }

    /// Helper: generate float range values, appending to results.
    fn generateRangeValuesFloat(it: *ResultIterator, results: *std.ArrayList(Value), from_f: f64, to_f: f64, step_f: f64) !void {
        if (step_f > 0) {
            var cur = from_f;
            while (cur < to_f) : (cur += step_f) {
                try results.append(it.alloc, .{ .float = cur });
            }
        } else if (step_f < 0) {
            var cur = from_f;
            while (cur > to_f) : (cur += step_f) {
                try results.append(it.alloc, .{ .float = cur });
            }
        }
    }

    /// `range1_gen`: apply range(n) for each n in the input array, concatenate all results.
    /// Current is [n_values]. Returns a flat array of all range outputs.
    fn builtinRange1Gen(it: *ResultIterator) ZqError!?StackValue {
        const n_arr = it.current;
        const n_elems = try it.extractArrayElements(n_arr);

        var results = std.ArrayList(Value){};
        defer results.deinit(it.alloc);

        for (n_elems) |n_v| {
            switch (n_v) {
                .int => |end_n| {
                    if (end_n > 0) {
                        try it.generateRangeValues(&results, 0, end_n, 1);
                    }
                },
                .float => |end_f| {
                    if (end_f > 0) {
                        try it.generateRangeValuesFloat(&results, 0, end_f, 1);
                    }
                },
                else => return error.TypeError,
            }
        }

        return try it.buildRuntimeArray(results.items);
    }

    /// `range2_gen`: Cartesian product of from_array x to_array applied to range(from;to).
    /// if_stack has [from_values], current is [to_values].
    /// Returns a flat array of all range outputs.
    fn builtinRange2Gen(it: *ResultIterator) ZqError!?StackValue {
        const to_arr = it.current;
        const from_val = if (it.if_stack.items.len > 0) it.if_stack.pop().? else return error.TypeError;

        const from_elems = try it.extractArrayElements(from_val);
        const to_elems = try it.extractArrayElements(to_arr);

        var results = std.ArrayList(Value){};
        defer results.deinit(it.alloc);

        for (from_elems) |from_v| {
            for (to_elems) |to_v| {
                const is_float = (from_v == .float or to_v == .float);
                if (is_float) {
                    const from_f: f64 = switch (from_v) {
                        .float => |f| f,
                        .int => |i| @floatFromInt(i),
                        else => return error.TypeError,
                    };
                    const to_f: f64 = switch (to_v) {
                        .float => |f| f,
                        .int => |i| @floatFromInt(i),
                        else => return error.TypeError,
                    };
                    try it.generateRangeValuesFloat(&results, from_f, to_f, 1.0);
                } else {
                    const from_i: i64 = switch (from_v) {
                        .int => |i| i,
                        else => return error.TypeError,
                    };
                    const to_i: i64 = switch (to_v) {
                        .int => |i| i,
                        else => return error.TypeError,
                    };
                    try it.generateRangeValues(&results, from_i, to_i, 1);
                }
            }
        }

        return try it.buildRuntimeArray(results.items);
    }

    /// `range3_gen`: Cartesian product of from_array x to_array x by_array applied to range(from;to;by).
    /// if_stack has [from_values] then [to_values] (from pushed first, then to),
    /// current is [by_values].
    /// Returns a flat array of all range outputs.
    fn builtinRange3Gen(it: *ResultIterator) ZqError!?StackValue {
        const by_arr = it.current;
        // Pop in reverse order: to was pushed second, from was pushed first
        const to_val = if (it.if_stack.items.len > 0) it.if_stack.pop().? else return error.TypeError;
        const from_val = if (it.if_stack.items.len > 0) it.if_stack.pop().? else return error.TypeError;

        const from_elems = try it.extractArrayElements(from_val);
        const to_elems = try it.extractArrayElements(to_val);
        const by_elems = try it.extractArrayElements(by_arr);

        var results = std.ArrayList(Value){};
        defer results.deinit(it.alloc);

        for (from_elems) |from_v| {
            for (to_elems) |to_v| {
                for (by_elems) |by_v| {
                    const is_float = (from_v == .float or to_v == .float or by_v == .float);
                    if (is_float) {
                        const from_f: f64 = switch (from_v) {
                            .float => |f| f,
                            .int => |i| @floatFromInt(i),
                            else => return error.TypeError,
                        };
                        const to_f: f64 = switch (to_v) {
                            .float => |f| f,
                            .int => |i| @floatFromInt(i),
                            else => return error.TypeError,
                        };
                        const by_f: f64 = switch (by_v) {
                            .float => |f| f,
                            .int => |i| @floatFromInt(i),
                            else => return error.TypeError,
                        };
                        if (by_f != 0 and !((by_f > 0 and from_f >= to_f) or (by_f < 0 and from_f <= to_f))) {
                            try it.generateRangeValuesFloat(&results, from_f, to_f, by_f);
                        }
                    } else {
                        const from_i: i64 = switch (from_v) {
                            .int => |i| i,
                            else => return error.TypeError,
                        };
                        const to_i: i64 = switch (to_v) {
                            .int => |i| i,
                            else => return error.TypeError,
                        };
                        const by_i: i64 = switch (by_v) {
                            .int => |i| i,
                            else => return error.TypeError,
                        };
                        if (by_i != 0 and !((by_i > 0 and from_i >= to_i) or (by_i < 0 and from_i <= to_i))) {
                            try it.generateRangeValues(&results, from_i, to_i, by_i);
                        }
                    }
                }
            }
        }

        return try it.buildRuntimeArray(results.items);
    }

    /// `limit_gen`: for each n in [n_values], take first n elements from [f_outputs].
    /// if_stack has [n_values], current is [f_outputs].
    /// Returns a flat array of all results concatenated.
    fn builtinLimitGen(it: *ResultIterator) ZqError!?StackValue {
        const f_arr = it.current;
        const n_val = if (it.if_stack.items.len > 0) it.if_stack.pop().? else return error.TypeError;

        const n_elems = try it.extractArrayElements(n_val);
        const f_elems = try it.extractArrayElements(f_arr);

        var results = std.ArrayList(Value){};
        defer results.deinit(it.alloc);

        for (n_elems) |n_v| {
            const n: usize = switch (n_v) {
                .int => |i| if (i < 0) 0 else @intCast(i),
                .float => |f| if (f < 0) 0 else @intFromFloat(@round(f)),
                else => return error.TypeError,
            };
            const take = @min(n, f_elems.len);
            for (f_elems[0..take]) |elem| {
                try results.append(it.alloc, elem);
            }
        }

        return try it.buildRuntimeArray(results.items);
    }

    // ── Path algebra builtins ──────────────────────────────────────────────────

    /// `getpath(PATH)`: walk the current value by path components, return result.
    /// Path is an array of strings (object keys) and ints (array indices).
    ///
    /// When called inside a `path(f)` frame (e.g. `path(getpath(P))` or
    /// `getpath(P) |= V`), the frame's components are populated from `P` so
    /// that `path_end` can reconstruct the path array correctly. This allows
    /// autovivification via setpath on null/missing intermediate nodes.
    fn builtinGetpath(it: *ResultIterator) ZqError!?StackValue {
        const path_sv = try it.popValue();
        const path_val = try stackValueToValue(path_sv);

        // Walk the path array directly from the tape without extracting elements.
        // This avoids holding Value references that might become stale.
        const span = switch (path_val) {
            .array => |s| s,
            else => return error.TypeError,
        };

        // If inside a path(f) frame and not suspended (e.g. evaluating the
        // LHS of an `as` binding in value context), record the path elements
        // as components so path_end builds the correct path array (enabling
        // |= autovivify). When suspended, getpath behaves as a pure value
        // builtin and must not affect the surrounding path's components.
        if (it.path_stack.items.len > 0 and !it.path_stack.items[it.path_stack.items.len - 1].suspended) {
            const frame = &it.path_stack.items[it.path_stack.items.len - 1];
            frame.components.clearRetainingCapacity();
            var scan_pos = span.start + 1;
            const scan_end = span.end - 1;
            while (scan_pos < scan_end) {
                const entry = span.tape.entries[scan_pos];
                switch (entry.tag) {
                    .string => {
                        // The parsed-tape string_buf is stable for the query lifetime,
                        // so refer to it via tape_ref to keep StringView the SSOT.
                        try frame.components.append(it.alloc, .{ .string = .{ .tape_ref = .{
                            .tape = span.tape,
                            .ref = entry.payload.string,
                        } } });
                    },
                    .int => {
                        try frame.components.append(it.alloc, .{ .int = entry.payload.int });
                    },
                    else => {},
                }
                scan_pos = skipEntry(span.tape.*, scan_pos);
            }
            // Clear path_broken: the argument expression (e.g. array literal)
            // may have set it while being evaluated. Since getpath(P)'s path IS
            // P (not a navigation trace), once we have the components the prior
            // broken state is superseded. path_end will use frame.components.
            frame.path_broken = false;
        }

        var current = it.current;
        var pos = span.start + 1;
        const end = span.end - 1;
        while (pos < end) {
            const entry = span.tape.entries[pos];
            switch (entry.tag) {
                .string => {
                    const key = span.tape.getString(entry.payload.string);
                    current = switch (current) {
                        .object => |obj| lookupKey(obj.tape, obj, key) orelse .null_val,
                        .null_val => .null_val,
                        else => .null_val,
                    };
                },
                .int => {
                    const i = entry.payload.int;
                    current = switch (current) {
                        .array => |arr| blk: {
                            if (i < 0) {
                                const len = arrayLength(arr.tape, arr);
                                const neg_idx = @as(i64, @intCast(len)) + i;
                                if (neg_idx < 0) break :blk @as(Value, .null_val);
                                break :blk lookupIndex(arr.tape, arr, @intCast(neg_idx)) orelse .null_val;
                            } else {
                                if (i > std.math.maxInt(u32)) break :blk @as(Value, .null_val);
                                break :blk lookupIndex(arr.tape, arr, @intCast(i)) orelse .null_val;
                            }
                        },
                        .null_val => .null_val,
                        else => .null_val,
                    };
                },
                else => {
                    current = .null_val;
                },
            }
            pos = skipEntry(span.tape.*, pos);
        }
        return try valueToStackValue(current);
    }

    /// `setpath(PATH; VALUE)`: set a value at the given path in the current input.
    /// Path and value are on the value stack; current is the base object.
    fn builtinSetpath(it: *ResultIterator) ZqError!?StackValue {
        const new_val_sv = try it.popValue();
        const path_sv = try it.popValue();
        const new_val = try stackValueToValue(new_val_sv);
        const path_val = try stackValueToValue(path_sv);
        const path_elems = try it.extractArrayElements(path_val);

        const result = try it.setpathRecursive(it.current, path_elems, 0, new_val);
        return try valueToStackValue(result);
    }

    /// Recursively rebuild the structure with the value at path[depth..] replaced.
    fn setpathRecursive(it: *ResultIterator, base: Value, path: []const Value, depth: usize, new_val: Value) ZqError!Value {
        if (depth >= path.len) return new_val;

        const component = path[depth];
        switch (component) {
            .string => |key_sv| {
                const key = key_sv.slice();
                // Build a new object with the key replaced/added.
                var tmp_tape = try types.RuntimeTape.init(it.alloc);
                defer tmp_tape.deinit(it.alloc);

                const obj_start = try tmp_tape.appendEntry(it.alloc, .{
                    .tag = .object_start,
                    .payload = .{ .skip = 0 },
                });

                var found = false;
                // Copy existing object fields, replacing the target key.
                switch (base) {
                    .object => |span| {
                        var pos = span.start + 1;
                        const end = span.end - 1;
                        while (pos < end) {
                            const k = span.tape.getString(span.tape.entries[pos].payload.string);
                            const val_pos = pos + 1;
                            const existing_val = tapeEntryToValue(span.tape, val_pos);
                            if (std.mem.eql(u8, k, key)) {
                                found = true;
                                const replaced = try it.setpathRecursive(existing_val, path, depth + 1, new_val);
                                const key_ref = try tmp_tape.internString(it.alloc, k);
                                _ = try tmp_tape.appendEntry(it.alloc, .{
                                    .tag = .key,
                                    .payload = .{ .string = key_ref },
                                });
                                try writeValueToTape(&tmp_tape, it.alloc, replaced);
                            } else {
                                const key_ref = try tmp_tape.internString(it.alloc, k);
                                _ = try tmp_tape.appendEntry(it.alloc, .{
                                    .tag = .key,
                                    .payload = .{ .string = key_ref },
                                });
                                try writeValueToTape(&tmp_tape, it.alloc, existing_val);
                            }
                            pos = skipEntry(span.tape.*, val_pos);
                        }
                    },
                    .null_val => {},
                    else => {
                        it.type_error_detail = it.buildTypeErrorMsg(base, .{ .index_string = key });
                        return error.TypeError;
                    },
                }

                if (!found) {
                    const replaced = try it.setpathRecursive(.null_val, path, depth + 1, new_val);
                    const key_ref = try tmp_tape.internString(it.alloc, key);
                    _ = try tmp_tape.appendEntry(it.alloc, .{
                        .tag = .key,
                        .payload = .{ .string = key_ref },
                    });
                    try writeValueToTape(&tmp_tape, it.alloc, replaced);
                }

                const obj_end_idx = try tmp_tape.appendEntry(it.alloc, .{
                    .tag = .object_end,
                    .payload = .{ .none = {} },
                });
                tmp_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;

                // Copy tmp_tape result to main runtime_tape.
                const result_start: u32 = @intCast(it.runtime_tape.entries.items.len);
                try it.runtime_tape.copySpan(tmp_tape.asTape(), obj_start, obj_end_idx + 1, it.alloc);
                const result_end: u32 = @intCast(it.runtime_tape.entries.items.len);
                return .{ .object = .{
                    .tape = &it.runtime_tape.view,
                    .start = result_start,
                    .end = result_end,
                } };
            },
            .int => |idx| {
                // Build a new array with the element at idx replaced/added.
                var tmp_tape = try types.RuntimeTape.init(it.alloc);
                defer tmp_tape.deinit(it.alloc);

                const arr_start = try tmp_tape.appendEntry(it.alloc, .{
                    .tag = .array_start,
                    .payload = .{ .skip = 0 },
                });

                const target_idx: usize = if (idx < 0) blk: {
                    const len: i64 = switch (base) {
                        .array => |span| @intCast(arrayLength(span.tape, span)),
                        .null_val => {
                            it.type_error_detail = .{ .string = .{ .external = "Out of bounds negative array index" } };
                            return error.TypeError;
                        },
                        else => 0,
                    };
                    const resolved = len + idx;
                    if (resolved < 0) {
                        it.type_error_detail = .{ .string = .{ .external = "Out of bounds negative array index" } };
                        return error.TypeError;
                    }
                    break :blk @intCast(resolved);
                } else @intCast(idx);

                switch (base) {
                    .array => |span| {
                        var pos = span.start + 1;
                        const end = span.end - 1;
                        var i: usize = 0;
                        while (pos < end) : (i += 1) {
                            const existing_val = tapeEntryToValue(span.tape, pos);
                            if (i == target_idx) {
                                const replaced = try it.setpathRecursive(existing_val, path, depth + 1, new_val);
                                try writeValueToTape(&tmp_tape, it.alloc, replaced);
                            } else {
                                try writeValueToTape(&tmp_tape, it.alloc, existing_val);
                            }
                            pos = skipEntry(span.tape.*, pos);
                        }
                        // If index is beyond array length, pad with nulls.
                        while (i < target_idx) : (i += 1) {
                            _ = try tmp_tape.appendEntry(it.alloc, .{
                                .tag = .null_val,
                                .payload = .{ .none = {} },
                            });
                        }
                        if (i == target_idx) {
                            const replaced = try it.setpathRecursive(.null_val, path, depth + 1, new_val);
                            try writeValueToTape(&tmp_tape, it.alloc, replaced);
                        }
                    },
                    .null_val => {
                        // null base: create array with nulls up to idx, then set.
                        var i: usize = 0;
                        while (i < target_idx) : (i += 1) {
                            _ = try tmp_tape.appendEntry(it.alloc, .{
                                .tag = .null_val,
                                .payload = .{ .none = {} },
                            });
                        }
                        const replaced = try it.setpathRecursive(.null_val, path, depth + 1, new_val);
                        try writeValueToTape(&tmp_tape, it.alloc, replaced);
                    },
                    else => {
                        it.type_error_detail = it.buildTypeErrorMsg(base, .{ .index_number_val = idx });
                        return error.TypeError;
                    },
                }

                const arr_end_idx = try tmp_tape.appendEntry(it.alloc, .{
                    .tag = .array_end,
                    .payload = .{ .none = {} },
                });
                tmp_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;

                // Copy to main runtime_tape.
                const result_start: u32 = @intCast(it.runtime_tape.entries.items.len);
                try it.runtime_tape.copySpan(tmp_tape.asTape(), arr_start, arr_end_idx + 1, it.alloc);
                const result_end: u32 = @intCast(it.runtime_tape.entries.items.len);
                return .{ .array = .{
                    .tape = &it.runtime_tape.view,
                    .start = result_start,
                    .end = result_end,
                } };
            },
            .object => |slice_span| {
                // Slice path component: {"start": int|null, "end": int|null}.
                // Splice new_val (must be array) into base[from..to].
                // jq dispatches the error message by base type: array/null/
                // string treat the component as a slice (bad slice indices ->
                // "Array/string slice indices must be integers"), other base
                // types report "Cannot index <T> with object".
                // Check base type first: object/number/boolean bases yield
                // "Cannot index <T> with object" before any slice validation
                // (per jq oracle).  Slice-shaped bases (array/null/string)
                // proceed to the slice-key checks below.
                const base_span: Value.TapeSpan = switch (base) {
                    .array => |s| s,
                    .string => {
                        // jq: slice-assign on strings is not supported; raise a
                        // catchable UserError with the canonical message.
                        const str_ref = try it.runtime_tape.internString(
                            it.alloc,
                            "Cannot update string slices",
                        );
                        it.user_error_msg = .{ .string = it.rtString(str_ref) };
                        return error.UserError;
                    },
                    .null_val => {
                        it.type_error_detail = it.buildTypeErrorMsg(.null_val, .{ .setpath_slice = {} });
                        return error.TypeError;
                    },
                    else => {
                        it.type_error_detail = it.buildTypeErrorMsg(.null_val, .{ .setpath_index = .{ .base = base, .pc_type = "object" } });
                        return error.TypeError;
                    },
                };
                // jq requires both "start" and "end" keys to be present on
                // the slice object — missing either yields the slice-indices
                // error.  See oracle: `setpath([{"a":1}]; [9])` on `[1,2,3]`.
                const from_val = lookupKey(slice_span.tape, slice_span, "start") orelse {
                    it.type_error_detail = it.buildTypeErrorMsg(.null_val, .{ .setpath_slice = {} });
                    return error.TypeError;
                };
                const to_val = lookupKey(slice_span.tape, slice_span, "end") orelse {
                    it.type_error_detail = it.buildTypeErrorMsg(.null_val, .{ .setpath_slice = {} });
                    return error.TypeError;
                };
                const arr_len: i64 = @intCast(arrayLength(base_span.tape, base_span));
                const from_raw: i64 = switch (from_val) {
                    .int => |v| v,
                    .null_val => 0,
                    else => {
                        it.type_error_detail = it.buildTypeErrorMsg(.null_val, .{ .setpath_slice = {} });
                        return error.TypeError;
                    },
                };
                const to_raw: i64 = switch (to_val) {
                    .int => |v| v,
                    .null_val => arr_len,
                    else => {
                        it.type_error_detail = it.buildTypeErrorMsg(.null_val, .{ .setpath_slice = {} });
                        return error.TypeError;
                    },
                };
                // Clamp bounds to [0, arr_len] and ensure from <= to.
                const from_resolved: i64 = if (from_raw < 0) @max(0, arr_len + from_raw) else @min(from_raw, arr_len);
                const to_clamped: i64 = if (to_raw < 0) @max(0, arr_len + to_raw) else @min(to_raw, arr_len);
                const to_resolved: i64 = @max(from_resolved, to_clamped);

                // new_val must be an array to splice in.
                const rhs: Value.TapeSpan = switch (new_val) {
                    .array => |s| s,
                    else => return error.TypeError,
                };

                var tmp_tape = try types.RuntimeTape.init(it.alloc);
                defer tmp_tape.deinit(it.alloc);

                const out_start = try tmp_tape.appendEntry(it.alloc, .{
                    .tag = .array_start,
                    .payload = .{ .skip = 0 },
                });

                // Copy base[0..from_resolved].
                var pos = base_span.start + 1;
                const base_end = base_span.end - 1;
                var idx: i64 = 0;
                while (idx < from_resolved and pos < base_end) : (idx += 1) {
                    try writeValueToTape(&tmp_tape, it.alloc, tapeEntryToValue(base_span.tape, pos));
                    pos = skipEntry(base_span.tape.*, pos);
                }

                // Splice in new_val elements.
                var rhs_pos = rhs.start + 1;
                const rhs_end = rhs.end - 1;
                while (rhs_pos < rhs_end) {
                    try writeValueToTape(&tmp_tape, it.alloc, tapeEntryToValue(rhs.tape, rhs_pos));
                    rhs_pos = skipEntry(rhs.tape.*, rhs_pos);
                }

                // Skip base[from_resolved..to_resolved].
                while (idx < to_resolved and pos < base_end) : (idx += 1) {
                    pos = skipEntry(base_span.tape.*, pos);
                }

                // Copy base[to_resolved..].
                while (pos < base_end) {
                    try writeValueToTape(&tmp_tape, it.alloc, tapeEntryToValue(base_span.tape, pos));
                    pos = skipEntry(base_span.tape.*, pos);
                }

                const out_end_idx = try tmp_tape.appendEntry(it.alloc, .{
                    .tag = .array_end,
                    .payload = .{ .none = {} },
                });
                tmp_tape.entries.items[out_start].payload.skip = out_end_idx + 1;

                const result_start: u32 = @intCast(it.runtime_tape.entries.items.len);
                try it.runtime_tape.copySpan(tmp_tape.asTape(), out_start, out_end_idx + 1, it.alloc);
                const result_end: u32 = @intCast(it.runtime_tape.entries.items.len);
                return .{ .array = .{
                    .tape = &it.runtime_tape.view,
                    .start = result_start,
                    .end = result_end,
                } };
            },
            .array => {
                // jq emits a special UserError for array-base + array-pc and
                // the generic "Cannot index <T> with array" for everything
                // else.  Keeping these as TypeError-class with detail (or
                // UserError for the special case) matches jq's catchable
                // surface.
                if (base == .array) {
                    it.user_error_msg = .{ .string = .{ .external = "Cannot update field at array index of array" } };
                    return error.UserError;
                }
                it.type_error_detail = it.buildTypeErrorMsg(.null_val, .{ .setpath_index = .{ .base = base, .pc_type = "array" } });
                return error.TypeError;
            },
            .bool_val => {
                it.type_error_detail = it.buildTypeErrorMsg(.null_val, .{ .setpath_index = .{ .base = base, .pc_type = "boolean" } });
                return error.TypeError;
            },
            .null_val => switch (base) {
                .array => {
                    // A null path component arises from `path(.[nan])` → `[null]`.
                    // jq raises a catchable error when assigning through such a
                    // path on an array; mirror that with the canonical message.
                    const str_ref = try it.runtime_tape.internString(
                        it.alloc,
                        "Cannot set array element at NaN index",
                    );
                    it.user_error_msg = .{ .string = it.rtString(str_ref) };
                    return error.UserError;
                },
                else => {
                    it.type_error_detail = it.buildTypeErrorMsg(.null_val, .{ .setpath_index = .{ .base = base, .pc_type = "null" } });
                    return error.TypeError;
                },
            },
            else => return error.TypeError,
        }
    }

    /// `delpaths(PATHS)`: delete multiple paths. Paths is an array of path arrays.
    /// Sort paths in reverse order (deeper/higher-index first), apply each deletion.
    fn builtinDelpaths(it: *ResultIterator) ZqError!?StackValue {
        const paths_sv = try it.popValue();
        const paths_val = try stackValueToValue(paths_sv);
        // jq error for non-array argument: "Paths must be specified as an array".
        // Set detail before delegating to extractArrayElements so the TypeError
        // surfaces with the right message rather than a bare type failure.
        if (paths_val != .array) {
            it.type_error_detail = .{ .string = .{ .external = "Paths must be specified as an array" } };
            return error.TypeError;
        }
        const paths_elems = try it.extractArrayElements(paths_val);

        // Extract each path as an array of elements, normalizing the first
        // component against the base value so that negative indices and slices
        // are resolved against the original array length (matching jq's
        // delpaths which resolves all paths before applying deletions).
        // path_list backing storage: GPA (capacity grows independently of the
        // scratch arena which holds the path slices themselves).
        var path_list = std.ArrayList([]Value){};
        defer path_list.deinit(it.alloc);
        for (paths_elems) |p| {
            const elems = try it.extractArrayElements(p);
            try it.normalizeAndAppendPath(&path_list, elems);
        }

        // Sort paths: longer paths first, then by last component descending.
        // This ensures we delete deeper paths before shallower ones and
        // higher indices before lower ones to avoid index shifting.
        std.mem.sort([]Value, path_list.items, {}, struct {
            fn lt(_: void, a: []Value, b: []Value) bool {
                // Longer paths first.
                if (a.len != b.len) return a.len > b.len;
                // Same length: compare last component (higher index first).
                if (a.len == 0) return false;
                const a_last = a[a.len - 1];
                const b_last = b[b.len - 1];
                const a_int: i64 = switch (a_last) {
                    .int => |i| i,
                    else => 0,
                };
                const b_int: i64 = switch (b_last) {
                    .int => |i| i,
                    else => 0,
                };
                return a_int > b_int;
            }
        }.lt);

        // Apply each deletion sequentially.
        var current = it.current;
        for (path_list.items) |path| {
            current = try it.delpathSingle(current, path, 0);
        }

        return try valueToStackValue(current);
    }

    /// Normalize a path against the base value (it.current) and append the
    /// result to `out`. Negative integer components at array depth are
    /// resolved to positive indices, and slice objects are expanded into one
    /// path per index in the slice range. Ownership of `elems` transfers in
    /// (we free or reuse it). Null components are kept verbatim (they become
    /// a no-op at deletion time).
    fn normalizeAndAppendPath(
        it: *ResultIterator,
        out: *std.ArrayList([]Value),
        elems: []Value,
    ) ZqError!void {
        // If the first component is a slice on an array base, expand into
        // one path per index in the slice range.
        if (elems.len > 0) {
            switch (elems[0]) {
                .object => |slice_span| switch (it.current) {
                    .array => |span| {
                        const arr_len: i64 = @intCast(arrayLength(span.tape, span));
                        const from_val = lookupKey(slice_span.tape, slice_span, "start") orelse Value.null_val;
                        const to_val = lookupKey(slice_span.tape, slice_span, "end") orelse Value.null_val;
                        const from_raw: i64 = switch (from_val) {
                            .int => |v| v,
                            .null_val => 0,
                            else => return error.TypeError,
                        };
                        const to_raw: i64 = switch (to_val) {
                            .int => |v| v,
                            .null_val => arr_len,
                            else => return error.TypeError,
                        };
                        const from_resolved: i64 = if (from_raw < 0) @max(0, arr_len + from_raw) else @min(from_raw, arr_len);
                        const to_resolved: i64 = if (to_raw < 0) @max(0, arr_len + to_raw) else @min(to_raw, arr_len);
                        const slice_end: i64 = if (to_resolved < from_resolved) from_resolved else to_resolved;

                        // The incoming elems live in scratch — arena reset
                        // reclaims them at end of record. Allocate replacement
                        // paths from the same scratch arena.
                        var i: i64 = from_resolved;
                        while (i < slice_end) : (i += 1) {
                            const new_path = try it.scratch.allocator().alloc(Value, 1);
                            new_path[0] = .{ .int = i };
                            try out.append(it.alloc, new_path);
                        }
                        return;
                    },
                    else => {},
                },
                .int => |idx| switch (it.current) {
                    .array => |span| {
                        if (idx < 0) {
                            const arr_len: i64 = @intCast(arrayLength(span.tape, span));
                            const resolved = arr_len + idx;
                            if (resolved >= 0) {
                                elems[0] = .{ .int = resolved };
                            }
                            // else: leave as-is; delpathSingle will skip out-of-range.
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }
        try out.append(it.alloc, elems);
    }

    /// Delete a single path from a value.
    fn delpathSingle(it: *ResultIterator, base: Value, path: []const Value, depth: usize) ZqError!Value {
        // Empty path deletes the value itself — jq returns null.
        if (depth >= path.len) return .null_val;

        const component = path[depth];
        const is_leaf = (depth + 1 == path.len);

        switch (component) {
            .null_val => return base,
            .string => |key_sv| {
                const key = key_sv.slice();
                switch (base) {
                    .object => |span| {
                        var tmp_tape = try types.RuntimeTape.init(it.alloc);
                        defer tmp_tape.deinit(it.alloc);

                        const obj_start = try tmp_tape.appendEntry(it.alloc, .{
                            .tag = .object_start,
                            .payload = .{ .skip = 0 },
                        });

                        var pos = span.start + 1;
                        const end = span.end - 1;
                        while (pos < end) {
                            const k = span.tape.getString(span.tape.entries[pos].payload.string);
                            const val_pos = pos + 1;
                            const existing_val = tapeEntryToValue(span.tape, val_pos);
                            if (std.mem.eql(u8, k, key)) {
                                if (!is_leaf) {
                                    // Recurse deeper.
                                    const replaced = try it.delpathSingle(existing_val, path, depth + 1);
                                    const key_ref = try tmp_tape.internString(it.alloc, k);
                                    _ = try tmp_tape.appendEntry(it.alloc, .{
                                        .tag = .key,
                                        .payload = .{ .string = key_ref },
                                    });
                                    try writeValueToTape(&tmp_tape, it.alloc, replaced);
                                }
                                // else: skip this key-value pair (delete it).
                            } else {
                                const key_ref = try tmp_tape.internString(it.alloc, k);
                                _ = try tmp_tape.appendEntry(it.alloc, .{
                                    .tag = .key,
                                    .payload = .{ .string = key_ref },
                                });
                                try writeValueToTape(&tmp_tape, it.alloc, existing_val);
                            }
                            pos = skipEntry(span.tape.*, val_pos);
                        }

                        const obj_end_idx = try tmp_tape.appendEntry(it.alloc, .{
                            .tag = .object_end,
                            .payload = .{ .none = {} },
                        });
                        tmp_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;

                        const result_start: u32 = @intCast(it.runtime_tape.entries.items.len);
                        try it.runtime_tape.copySpan(tmp_tape.asTape(), obj_start, obj_end_idx + 1, it.alloc);
                        const result_end: u32 = @intCast(it.runtime_tape.entries.items.len);
                        return .{ .object = .{
                            .tape = &it.runtime_tape.view,
                            .start = result_start,
                            .end = result_end,
                        } };
                    },
                    else => return base,
                }
            },
            .int => |idx| {
                switch (base) {
                    .array => |span| {
                        var tmp_tape = try types.RuntimeTape.init(it.alloc);
                        defer tmp_tape.deinit(it.alloc);

                        const arr_start = try tmp_tape.appendEntry(it.alloc, .{
                            .tag = .array_start,
                            .payload = .{ .skip = 0 },
                        });

                        const arr_len = arrayLength(span.tape, span);
                        const target_idx: usize = if (idx < 0) blk: {
                            const resolved = @as(i64, @intCast(arr_len)) + idx;
                            if (resolved < 0) break :blk std.math.maxInt(usize);
                            break :blk @intCast(resolved);
                        } else if (idx > std.math.maxInt(u32)) std.math.maxInt(usize) else @intCast(idx);

                        var pos = span.start + 1;
                        const end = span.end - 1;
                        var i: usize = 0;
                        while (pos < end) : (i += 1) {
                            const existing_val = tapeEntryToValue(span.tape, pos);
                            if (i == target_idx) {
                                if (!is_leaf) {
                                    const replaced = try it.delpathSingle(existing_val, path, depth + 1);
                                    try writeValueToTape(&tmp_tape, it.alloc, replaced);
                                }
                                // else: skip this element (delete it).
                            } else {
                                try writeValueToTape(&tmp_tape, it.alloc, existing_val);
                            }
                            pos = skipEntry(span.tape.*, pos);
                        }

                        const arr_end_idx = try tmp_tape.appendEntry(it.alloc, .{
                            .tag = .array_end,
                            .payload = .{ .none = {} },
                        });
                        tmp_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;

                        const result_start: u32 = @intCast(it.runtime_tape.entries.items.len);
                        try it.runtime_tape.copySpan(tmp_tape.asTape(), arr_start, arr_end_idx + 1, it.alloc);
                        const result_end: u32 = @intCast(it.runtime_tape.entries.items.len);
                        return .{ .array = .{
                            .tape = &it.runtime_tape.view,
                            .start = result_start,
                            .end = result_end,
                        } };
                    },
                    else => return base,
                }
            },
            .object => |slice_span| {
                // Slice path component `{"start": int|null, "end": int|null}`.
                // Delete the [start, end) range from an array.
                switch (base) {
                    .array => |span| {
                        const arr_len: i64 = @intCast(arrayLength(span.tape, span));
                        const from_val = lookupKey(slice_span.tape, slice_span, "start") orelse Value.null_val;
                        const to_val = lookupKey(slice_span.tape, slice_span, "end") orelse Value.null_val;
                        const from_raw: i64 = switch (from_val) {
                            .int => |v| v,
                            .null_val => 0,
                            else => return error.TypeError,
                        };
                        const to_raw: i64 = switch (to_val) {
                            .int => |v| v,
                            .null_val => arr_len,
                            else => return error.TypeError,
                        };
                        const from_resolved: i64 = if (from_raw < 0) @max(0, arr_len + from_raw) else @min(from_raw, arr_len);
                        const to_resolved: i64 = if (to_raw < 0) @max(0, arr_len + to_raw) else @min(to_raw, arr_len);
                        const slice_end: i64 = if (to_resolved < from_resolved) from_resolved else to_resolved;

                        if (!is_leaf) return error.TypeError;

                        var tmp_tape = try types.RuntimeTape.init(it.alloc);
                        defer tmp_tape.deinit(it.alloc);

                        const arr_start = try tmp_tape.appendEntry(it.alloc, .{
                            .tag = .array_start,
                            .payload = .{ .skip = 0 },
                        });

                        var pos = span.start + 1;
                        const end_pos = span.end - 1;
                        var i: i64 = 0;
                        while (pos < end_pos) : (i += 1) {
                            const existing_val = tapeEntryToValue(span.tape, pos);
                            if (i < from_resolved or i >= slice_end) {
                                try writeValueToTape(&tmp_tape, it.alloc, existing_val);
                            }
                            pos = skipEntry(span.tape.*, pos);
                        }

                        const arr_end_idx = try tmp_tape.appendEntry(it.alloc, .{
                            .tag = .array_end,
                            .payload = .{ .none = {} },
                        });
                        tmp_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;

                        const result_start: u32 = @intCast(it.runtime_tape.entries.items.len);
                        try it.runtime_tape.copySpan(tmp_tape.asTape(), arr_start, arr_end_idx + 1, it.alloc);
                        const result_end: u32 = @intCast(it.runtime_tape.entries.items.len);
                        return .{ .array = .{
                            .tape = &it.runtime_tape.view,
                            .start = result_start,
                            .end = result_end,
                        } };
                    },
                    else => return base,
                }
            },
            else => return error.TypeError,
        }
    }

    /// `paths`: enumerate all paths in the current value as a generator.
    /// Each path is an array of strings and ints.
    fn builtinPaths(it: *ResultIterator) ZqError!?StackValue {
        return it.builtinPathsImpl(false);
    }

    /// `leaf_paths`: enumerate only leaf (scalar) paths.
    fn builtinLeafPaths(it: *ResultIterator) ZqError!?StackValue {
        return it.builtinPathsImpl(true);
    }

    /// Common implementation for paths and leaf_paths.
    /// Collects all paths via DFS, builds them as an array of arrays on the
    /// runtime tape, sets it as current, and calls doIterate to yield each path.
    fn builtinPathsImpl(it: *ResultIterator, leaf_only: bool) ZqError!?StackValue {
        var path_buf = std.ArrayList(Value){};
        defer path_buf.deinit(it.alloc);
        var all_paths = std.ArrayList(Value){};
        defer all_paths.deinit(it.alloc);

        try it.collectPaths(it.current, &path_buf, &all_paths, leaf_only);

        if (all_paths.items.len == 0) {
            if (!(try it.doBacktrack())) {
                it.ip = @intCast(it.instructions.len);
            }
            return null;
        }

        // When called inside `path(paths)` / `path(leaf_paths)`, the each
        // iteration would otherwise append a spurious `[0]`, `[1]`... to the
        // frame's components because the iterated container is a list of
        // pre-built path arrays (not a user value). Flag the frame so
        // advanceEachForkpoint skips path recording and path_end yields the
        // current value (the path array) as the result. Skipped while the
        // frame is suspended — `paths` runs as a value-context generator.
        if (it.path_stack.items.len > 0 and !it.path_stack.items[it.path_stack.items.len - 1].suspended) {
            it.path_stack.items[it.path_stack.items.len - 1].body_emits_paths_directly = true;
        }

        // Build a container array of all path arrays on runtime tape.
        const arr = try it.buildRuntimeArray(all_paths.items);
        it.current = try stackValueToValue(arr);

        // Set up fork-based iteration over the container.
        if (!(try it.setupEachFromCurrent())) {
            if (!(try it.doBacktrack())) {
                it.ip = @intCast(it.instructions.len);
            }
        }
        return null;
    }

    /// Recursively collect all paths via DFS.
    fn collectPaths(
        it: *ResultIterator,
        val: Value,
        path_buf: *std.ArrayList(Value),
        all_paths: *std.ArrayList(Value),
        leaf_only: bool,
    ) ZqError!void {
        switch (val) {
            .object => |span| {
                if (!leaf_only and path_buf.items.len > 0) {
                    // Emit the current path for intermediate nodes (skip root).
                    const path_arr = try it.buildPathArray(path_buf.items);
                    try all_paths.append(it.alloc, path_arr);
                }
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const child_val = tapeEntryToValue(span.tape, pos + 1);
                    try path_buf.append(it.alloc, .{ .string = .{ .tape_ref = .{
                        .tape = span.tape,
                        .ref = span.tape.entries[pos].payload.string,
                    } } });
                    try it.collectPaths(child_val, path_buf, all_paths, leaf_only);
                    _ = path_buf.pop();
                    pos = skipEntry(span.tape.*, pos + 1);
                }
            },
            .array => |span| {
                if (!leaf_only and path_buf.items.len > 0) {
                    const path_arr = try it.buildPathArray(path_buf.items);
                    try all_paths.append(it.alloc, path_arr);
                }
                var pos = span.start + 1;
                const end = span.end - 1;
                var i: i64 = 0;
                while (pos < end) : (i += 1) {
                    const child_val = tapeEntryToValue(span.tape, pos);
                    try path_buf.append(it.alloc, .{ .int = i });
                    try it.collectPaths(child_val, path_buf, all_paths, leaf_only);
                    _ = path_buf.pop();
                    pos = skipEntry(span.tape.*, pos);
                }
            },
            else => {
                // Leaf node — emit only if not root (root scalars have no paths in jq).
                if (path_buf.items.len > 0) {
                    const path_arr = try it.buildPathArray(path_buf.items);
                    try all_paths.append(it.alloc, path_arr);
                }
            },
        }
    }

    /// `..` (recursive descent): output current value, then recursively descend
    /// into all sub-values. Errors from non-iterable values are suppressed.
    /// Equivalent to jq's `def recurse: ., (.[]? | recurse);`
    ///
    /// Inside a `path(f)` frame: two cases:
    ///
    ///   1. `path(..)` / `path(recurse)` — the body IS `..` with no
    ///      downstream filter. Use the fast `body_emits_paths_directly` mode:
    ///      collect path arrays upfront, iterate them as `it.current`, and
    ///      have `path_end` yield each one directly. This matches jq's output
    ///      for `path(..)` = `[], ["a"], ["a","b"], ...`.
    ///
    ///   2. `path(.. | filter)` — `..` is followed by something (select, type
    ///      test, field access, ...). The filter must operate on the ACTUAL
    ///      VALUE, not the path array. Use `recurse_path` forkpoints: collect
    ///      (value, path_components) pairs, set `it.current` to the value and
    ///      `frame.components` to the path per iteration so both the filter
    ///      (sees real values) and `path_end` (reads components) work correctly.
    ///
    /// The distinction is made by peeking ahead in the instruction stream: if
    /// the very next instruction (after any `pipe` that follows `call_builtin`)
    /// is `path_end`, we are case 1. Otherwise case 2.
    fn builtinRecurse(it: *ResultIterator) ZqError!?StackValue {
        // When suspended (LHS of an `as` binding), the surrounding path
        // frame must not see this builtin as path-emitting — recurse runs in
        // value context and produces values, not paths.
        const in_path_frame = it.path_stack.items.len > 0 and
            !it.path_stack.items[it.path_stack.items.len - 1].suspended;

        if (in_path_frame) {
            // Peek ahead to detect case 1 vs case 2. Skip `pipe`/`identity`
            // instructions (the compiler inserts a `pipe` between `call_builtin`
            // and whatever follows it in the value-piping sequence). If we reach
            // `path_end` before any other meaningful op, we are the direct body.
            var scan_ip = it.ip + 1;
            while (scan_ip < it.instructions.len) {
                const sop = it.instructions[scan_ip].op;
                if (sop == .pipe or sop == .identity) {
                    scan_ip += 1;
                } else break;
            }
            const next_is_path_end = scan_ip < it.instructions.len and
                it.instructions[scan_ip].op == .path_end;

            if (next_is_path_end) {
                // Case 1: fast path — collect path arrays and emit directly.
                var all_paths = std.ArrayList(Value){};
                defer all_paths.deinit(it.alloc);
                var path_buf = std.ArrayList(Value){};
                defer path_buf.deinit(it.alloc);
                try it.collectRecursePaths(it.current, &path_buf, &all_paths);

                if (all_paths.items.len == 0) {
                    if (!(try it.doBacktrack())) {
                        it.ip = @intCast(it.instructions.len);
                    }
                    return null;
                }

                it.path_stack.items[it.path_stack.items.len - 1].body_emits_paths_directly = true;
                const arr = try it.buildRuntimeArray(all_paths.items);
                it.current = try stackValueToValue(arr);
                if (!(try it.setupEachFromCurrent())) {
                    if (!(try it.doBacktrack())) {
                        it.ip = @intCast(it.instructions.len);
                    }
                }
                return null;
            }

            // Case 2: collect (value, path_components) pairs. Downstream
            // filters operate on values; path_end reads frame.components.
            // pairs + path_buf live in the per-record scratch arena —
            // released at reset(). RecursePathState carries the
            // toOwnedSlice'd buffer through the fork frame's lifetime.
            const aa = it.scratch.allocator();
            var pairs = std.ArrayList(RecursePathEntry){};
            var path_buf = std.ArrayList(Value){};
            try it.collectRecursePathValues(it.current, &path_buf, &pairs);

            if (pairs.items.len == 0) {
                if (!(try it.doBacktrack())) {
                    it.ip = @intCast(it.instructions.len);
                }
                return null;
            }

            // Snapshot path state BEFORE modifying components so that the
            // forkpoint's restorePathState truncates back to the pre-recurse
            // component depth (typically 0) before each advance repopulates.
            const saved_path_for_fork = it.snapshotPathState();

            // Set up first iteration: value and path components of index 0.
            const first = pairs.items[0];
            it.current = first.value;
            {
                const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                frame.components.clearRetainingCapacity();
                try frame.components.appendSlice(it.alloc, first.path_comps);
            }

            if (pairs.items.len == 1) {
                // Only one entry — no fork needed, just continue.
                it.ip += 1;
                return null;
            }

            // Push a recurse_path forkpoint for entries 1..n-1. items_owned
            // backed by scratch arena — freed at reset().
            const items_owned = try pairs.toOwnedSlice(aa);
            const saved_stack = try it.snapshotValueStackForFork();
            const saved_object = try it.snapshotObjectConstructState();
            try it.fork_stack.append(it.alloc, .{
                .saved_value_stack_len = @intCast(it.value_stack.items.len),
                .saved_current = it.current,
                .saved_current_args = it.current_args,
                .saved_call_len = @intCast(it.call_stack.items.len),
                .backtrack_ip = it.ip, // advance handler uses ip + 1
                .aux = .{ .recurse_path = .{
                    .items = items_owned,
                    .index = 0,
                } },
                .saved_path = saved_path_for_fork,
                .saved_stack = saved_stack,
                .saved_object = saved_object,
            });
            it.ip += 1;
            return null;
        }

        // Non-path frame: collect all values and iterate via setupEachFromCurrent.
        var all_items = std.ArrayList(Value){};
        defer all_items.deinit(it.alloc);
        try it.collectRecurse(it.current, &all_items);

        if (all_items.items.len == 0) {
            if (!(try it.doBacktrack())) {
                it.ip = @intCast(it.instructions.len);
            }
            return null;
        }

        // Build a container array of all collected values on runtime tape.
        const arr = try it.buildRuntimeArray(all_items.items);
        it.current = try stackValueToValue(arr);

        // Set up fork-based iteration over the container.
        if (!(try it.setupEachFromCurrent())) {
            if (!(try it.doBacktrack())) {
                it.ip = @intCast(it.instructions.len);
            }
        }
        return null;
    }

    /// DFS walk that collects (value, path_components) pairs for `..` inside
    /// a `path(f)` frame where a downstream filter follows `..`. Unlike
    /// `collectRecursePaths` (which emits path arrays as values), this function
    /// keeps the actual data value so downstream filters can operate on it.
    ///
    /// Each `path_comps` slice is independently allocated (owned by the caller /
    /// the `RecursePathState`). `path_buf` is a scratch buffer for DFS state.
    fn collectRecursePathValues(
        it: *ResultIterator,
        val: Value,
        path_buf: *std.ArrayList(Value),
        out: *std.ArrayList(RecursePathEntry),
    ) ZqError!void {
        // path_comps slices, path_buf growth, and `out` growth all live in
        // the per-record scratch arena — released wholesale at reset().
        const aa = it.scratch.allocator();
        const path_comps = try aa.dupe(Value, path_buf.items);
        try out.append(aa, .{ .value = val, .path_comps = path_comps });

        switch (val) {
            .array => |span| {
                var pos = span.start + 1;
                const end = span.end - 1;
                var i: i64 = 0;
                while (pos < end) : (i += 1) {
                    const child_val = tapeEntryToValue(span.tape, pos);
                    try path_buf.append(aa, .{ .int = i });
                    try it.collectRecursePathValues(child_val, path_buf, out);
                    _ = path_buf.pop();
                    pos = skipEntry(span.tape.*, pos);
                }
            },
            .object => |span| {
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const child_val = tapeEntryToValue(span.tape, pos + 1);
                    try path_buf.append(aa, .{ .string = .{ .tape_ref = .{
                        .tape = span.tape,
                        .ref = span.tape.entries[pos].payload.string,
                    } } });
                    try it.collectRecursePathValues(child_val, path_buf, out);
                    _ = path_buf.pop();
                    pos = skipEntry(span.tape.*, pos + 1);
                }
            },
            else => {}, // leaf — no descent
        }
    }

    /// DFS mirror of `collectRecurse` that emits the PATH to each visited
    /// node (root first, then children, depth-first, in source order).
    /// `path_buf` is the running path being built; each append/pop matches
    /// a descent/ascent in the walk. Matches jq's `path(recurse)` stream.
    fn collectRecursePaths(
        it: *ResultIterator,
        val: Value,
        path_buf: *std.ArrayList(Value),
        all_paths: *std.ArrayList(Value),
    ) ZqError!void {
        // Emit the current path (root is empty — matches jq's `path(..)`).
        const path_arr = try it.buildPathArray(path_buf.items);
        try all_paths.append(it.alloc, path_arr);

        switch (val) {
            .array => |span| {
                var pos = span.start + 1;
                const end = span.end - 1;
                var i: i64 = 0;
                while (pos < end) : (i += 1) {
                    const child_val = tapeEntryToValue(span.tape, pos);
                    try path_buf.append(it.alloc, .{ .int = i });
                    try it.collectRecursePaths(child_val, path_buf, all_paths);
                    _ = path_buf.pop();
                    pos = skipEntry(span.tape.*, pos);
                }
            },
            .object => |span| {
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const child_val = tapeEntryToValue(span.tape, pos + 1);
                    try path_buf.append(it.alloc, .{ .string = .{ .tape_ref = .{
                        .tape = span.tape,
                        .ref = span.tape.entries[pos].payload.string,
                    } } });
                    try it.collectRecursePaths(child_val, path_buf, all_paths);
                    _ = path_buf.pop();
                    pos = skipEntry(span.tape.*, pos + 1);
                }
            },
            else => {}, // leaf — no descent
        }
    }

    /// Recursively collect the value itself and all sub-values via DFS.
    fn collectRecurse(
        it: *ResultIterator,
        val: Value,
        all_values: *std.ArrayList(Value),
    ) ZqError!void {
        // Output the current value.
        try all_values.append(it.alloc, val);

        // Recurse into sub-values (array elements, object values).
        switch (val) {
            .array => |span| {
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const child_val = tapeEntryToValue(span.tape, pos);
                    try it.collectRecurse(child_val, all_values);
                    pos = skipEntry(span.tape.*, pos);
                }
            },
            .object => |span| {
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const child_val = tapeEntryToValue(span.tape, pos + 1);
                    try it.collectRecurse(child_val, all_values);
                    pos = skipEntry(span.tape.*, pos + 1);
                }
            },
            else => {
                // Scalars: no sub-values to descend into (like .[]? suppressing errors).
            },
        }
    }

    /// Recursively walk children of a value bottom-up for walk(f).
    /// For arrays: walk each element, collect first outputs into new array.
    /// For objects: walk each value, collect first outputs into new object.
    /// For scalars: return as-is (f is applied by the caller via normal instruction flow).
    ///
    /// The body range [body_start..body_end) contains the instructions for f.
    /// At each recursive level, the full walk range (walk_start..walk_end inclusive)
    /// is re-executed on the child, and only the first output is kept.
    const max_walk_depth: u32 = 1000;

    fn walkChildren(it: *ResultIterator, val: Value, body_start: u32, body_end: u32, depth: u32) ZqError!Value {
        if (depth > max_walk_depth) {
            it.user_error_msg = .{ .string = .{ .external = "walk recursion depth limit exceeded" } };
            return error.UserError;
        }
        switch (val) {
            .array => |span| {
                var walked_elems = std.ArrayList(Value){};
                defer walked_elems.deinit(it.alloc);

                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const elem = tapeEntryToValue(span.tape, pos);
                    // walkApplyBody returns null when f produced no output for
                    // this child (e.g. `select(false)` / empty). Skip null
                    // results so filter-f like `select` drops elements.
                    if (try it.walkApplyBody(elem, body_start, body_end, depth + 1)) |walked_elem| {
                        try walked_elems.append(it.alloc, walked_elem);
                    }
                    pos = skipEntry(span.tape.*, pos);
                }

                const arr_sv = try it.buildRuntimeArray(walked_elems.items);
                return try stackValueToValue(arr_sv);
            },
            .object => |span| {
                // Collect (key_pos, walked_value) pairs before touching
                // runtime_tape. A child walk that produces a composite appends
                // entries to runtime_tape and then re-copies them into place
                // via stackValueToRuntimeTapeEntry — the originals become
                // orphans. If obj_start were appended first, those orphans
                // would sit inside [obj_start..obj_end] and corrupt the tape.
                // Appending obj_start after all child walks keeps orphans
                // before the outer span, matching the array branch above.
                const Pair = struct { key_pos: u32, val: Value };
                var pairs = std.ArrayList(Pair){};
                defer pairs.deinit(it.alloc);

                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const child_val = tapeEntryToValue(span.tape, pos + 1);
                    // walkApplyBody returns null when f produced no output for
                    // this child value. Skip null results so filter-f like
                    // `select` drops keys from the walked object.
                    if (try it.walkApplyBody(child_val, body_start, body_end, depth + 1)) |walked_val| {
                        try pairs.append(it.alloc, .{ .key_pos = pos, .val = walked_val });
                    }
                    pos = skipEntry(span.tape.*, pos + 1);
                }

                const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .object_start,
                    .payload = .{ .skip = 0 },
                });
                for (pairs.items) |p| {
                    const key_str = span.tape.getString(span.tape.entries[p.key_pos].payload.string);
                    const key_ref = try it.runtime_tape.internString(it.alloc, key_str);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .key,
                        .payload = .{ .string = key_ref },
                    });
                    try it.stackValueToRuntimeTapeEntry(try valueToStackValue(p.val));
                }
                const obj_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .object_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;

                return Value{ .object = .{
                    .tape = &it.runtime_tape.view,
                    .start = obj_start,
                    .end = obj_end_idx + 1,
                } };
            },
            else => return val,
        }
    }

    /// Execute walk(f) on a child value and return the first output of f, or
    /// null if f produced no output (e.g. `select(false)` / empty).
    /// Recursively walks children first, then executes body f in a sub-loop
    /// (no call_function frame), taking only the first output. Null enables
    /// `walkChildren` to drop filtered children from the walked structure.
    fn walkApplyBody(it: *ResultIterator, val: Value, body_start: u32, body_end: u32, depth: u32) ZqError!?Value {
        // First, recursively walk children of this value.
        const walked = try it.walkChildren(val, body_start, body_end, depth);

        // Execute the body f on the walked value, capturing the first output.
        const saved_ip = it.ip;
        const saved_current = it.current;
        const saved_input = it.input_value;
        const saved_value_len: u32 = @intCast(it.value_stack.items.len);
        const saved_if_len: u32 = @intCast(it.if_stack.items.len);
        const saved_fork_len: u32 = @intCast(it.fork_stack.items.len);
        const saved_collect_len: u32 = @intCast(it.collect_stack.items.len);
        const saved_path_len: u32 = @intCast(it.path_stack.items.len);

        it.current = walked;
        it.input_value = walked;
        it.ip = body_start;

        var result: ?Value = null;
        while (it.ip < it.instructions.len and it.ip != body_end) {
            const body_instr = it.instructions[it.ip];

            if (it.execOne(body_instr)) |maybe_val| {
                if (maybe_val) |v| {
                    result = v;
                    break;
                }
            } else |err| {
                if (!(try it.handleError(err))) {
                    it.ip = saved_ip;
                    it.current = saved_current;
                    it.input_value = saved_input;
                    it.value_stack.items.len = saved_value_len;
                    it.if_stack.items.len = saved_if_len;
                    it.if_path_comps_stack.items.len = saved_if_len;
                    while (it.collect_stack.items.len > saved_collect_len) {
                        var cf = it.collect_stack.pop().?;
                        cf.buffer.deinit(it.alloc);
                    }
                    it.truncateForkStack(saved_fork_len);
                    while (it.path_stack.items.len > saved_path_len) {
                        var pf = it.path_stack.pop().?;
                        pf.deinit(it.alloc);
                    }
                    return err;
                }
                if (it.done) break;
            }

            if (it.ip >= it.instructions.len) {
                if (it.fork_stack.items.len > saved_fork_len) {
                    if (try it.backtrackToDepth(saved_fork_len)) {
                        continue;
                    }
                }
                if (it.collect_stack.items.len > saved_collect_len) {
                    var completed = it.collect_stack.pop().?;
                    defer completed.buffer.deinit(it.alloc);
                    const arr_val = try it.buildCollectedArray(&completed);
                    it.pushValue(arr_val);
                    it.if_stack.items.len = completed.outer_if_depth;
                    it.if_path_comps_stack.items.len = completed.outer_if_depth;
                    it.ip = completed.end_ip + 1;
                    continue;
                }
                break;
            }
        }

        // Determine if f produced an output. Three exit paths:
        //
        // 1. yield_output fired in normal mode: execOne returned Some(v),
        //    loop broke early, result is set, ip is inside body range.
        //
        // 2. f completed normally: ip advanced to body_end (the walk_end
        //    instruction). result is null but `it.current` holds the output.
        //    Also check value_stack in case the last instruction pushed there.
        //
        // 3. f backtracked (empty): ip jumped to instructions.len without
        //    reaching body_end. result is null; return null to signal "no
        //    output" so walkChildren can drop this element/key.
        //
        // Path 2 occurs for filters like `select(true_cond)`, `not`, `type`,
        // etc. that leave their output in `it.current` without yield_output.
        const body_reached_end = (it.ip == body_end);

        if (result == null) {
            if (it.value_stack.items.len > saved_value_len) {
                // Value was pushed onto stack (e.g. by push_current or an
                // expression that pushes before the final output).
                result = try stackValueToValue(try it.popValue());
            } else if (body_reached_end) {
                // f completed normally — capture current as the output.
                result = it.current;
            }
            // else: f backtracked (empty) — result stays null.
        }

        while (it.collect_stack.items.len > saved_collect_len) {
            var cf = it.collect_stack.pop().?;
            cf.buffer.deinit(it.alloc);
        }
        it.truncateForkStack(saved_fork_len);
        it.if_stack.items.len = saved_if_len;
        it.if_path_comps_stack.items.len = saved_if_len;
        it.value_stack.items.len = saved_value_len;
        while (it.path_stack.items.len > saved_path_len) {
            var pf = it.path_stack.pop().?;
            pf.deinit(it.alloc);
        }

        it.ip = saved_ip;
        it.current = saved_current;
        it.input_value = saved_input;
        it.done = false;

        // Return null when f produced no output (e.g. `select(false)`, empty).
        // `walkChildren` skips null entries so filter-f like `select` correctly
        // drops elements/keys from the walked structure.
        return result;
    }

    /// Build a path array (e.g. ["a", 0, "b", {"start":2,"end":4}]) on the
    /// runtime tape. Components may be strings, ints, slice objects, or null
    /// (for `path(.[nan])` and similar — jq records these as null components).
    fn buildPathArray(it: *ResultIterator, components: []const Value) ZqError!Value {
        const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });
        for (components) |comp| {
            switch (comp) {
                .string => |sv| {
                    const str_ref = try it.runtime_tape.internString(it.alloc, sv.slice());
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .string,
                        .payload = .{ .string = str_ref },
                    });
                },
                .int => |i| {
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .int,
                        .payload = .{ .int = i },
                    });
                },
                .object => |span| {
                    // Slice path component: copy the {"start":..,"end":..}
                    // object span into the path array.
                    try it.runtime_tape.copySpan(span.tape.*, span.start, span.end, it.alloc);
                },
                .null_val => {
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .null_val,
                        .payload = .{ .none = {} },
                    });
                },
                else => return error.TypeError,
            }
        }
        const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
        return .{ .array = .{
            .tape = &it.runtime_tape.view,
            .start = arr_start,
            .end = arr_end_idx + 1,
        } };
    }

    /// Build a slice path component `{"start": from?, "end": to?}` on the
    /// runtime tape and return it as a Value. Stores literal bounds as in jq:
    /// missing bounds become null, negative bounds are preserved verbatim.
    fn buildSlicePathComponent(it: *ResultIterator, args: types.SliceArgs) ZqError!Value {
        const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_start,
            .payload = .{ .skip = 0 },
        });

        const start_key_ref = try it.runtime_tape.internString(it.alloc, "start");
        _ = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .key,
            .payload = .{ .string = start_key_ref },
        });
        if (args.has_from) {
            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .int,
                .payload = .{ .int = args.from },
            });
        } else {
            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .null_val,
                .payload = .{ .none = {} },
            });
        }

        const end_key_ref = try it.runtime_tape.internString(it.alloc, "end");
        _ = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .key,
            .payload = .{ .string = end_key_ref },
        });
        if (args.has_to) {
            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .int,
                .payload = .{ .int = args.to },
            });
        } else {
            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .null_val,
                .payload = .{ .none = {} },
            });
        }

        const obj_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;
        return .{ .object = .{
            .tape = &it.runtime_tape.view,
            .start = obj_start,
            .end = obj_end_idx + 1,
        } };
    }

    fn toInt(val: StackValue) ZqError!i64 {
        return switch (val) {
            .int => |i| i,
            .bool_val => |b| if (b) 1 else 0,
            .float => |f| @intFromFloat(@round(f)),
            else => error.TypeError,
        };
    }

    /// jq's `dtoi` macro (builtin.c): saturating f64→i64 cast.
    ///   x < INT64_MIN (as f64) → INT64_MIN
    ///   -x <= INT64_MIN        → INT64_MAX   (covers +inf and large positives)
    ///   else                   → (i64)x      (truncation toward zero)
    /// Caller must ensure x is not NaN.
    fn dtoiClamp(x: f64) i64 {
        const i64_min_f: f64 = @floatFromInt(std.math.minInt(i64));
        if (x < i64_min_f) return std.math.minInt(i64);
        if (-x <= i64_min_f) return std.math.maxInt(i64);
        return @intFromFloat(x);
    }

    // ── Comparison operations ─────────────────────────────────────────────────────

    fn doEq(it: *ResultIterator) ZqError!bool {
        return it.doCompareOp(struct {
            fn op(a: f64, b: f64) bool {
                return a == b;
            }
        }.op);
    }

    fn doNe(it: *ResultIterator) ZqError!bool {
        return it.doCompareOp(struct {
            fn op(a: f64, b: f64) bool {
                return a != b;
            }
        }.op);
    }

    fn doLt(it: *ResultIterator) ZqError!bool {
        return it.doCompareOp(struct {
            fn op(a: f64, b: f64) bool {
                return a < b;
            }
        }.op);
    }

    fn doLe(it: *ResultIterator) ZqError!bool {
        return it.doCompareOp(struct {
            fn op(a: f64, b: f64) bool {
                return a <= b;
            }
        }.op);
    }

    fn doGt(it: *ResultIterator) ZqError!bool {
        return it.doCompareOp(struct {
            fn op(a: f64, b: f64) bool {
                return a > b;
            }
        }.op);
    }

    fn doGe(it: *ResultIterator) ZqError!bool {
        return it.doCompareOp(struct {
            fn op(a: f64, b: f64) bool {
                return a >= b;
            }
        }.op);
    }

    fn doCompareOp(
        it: *ResultIterator,
        comptime op: fn (f64, f64) bool,
    ) ZqError!bool {
        const right_sv = try it.popValue();
        const left_sv = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);

        const left = try stackValueToValue(left_sv);
        const right = try stackValueToValue(right_sv);
        const order = jqCompareValues(left, right);

        return switch (order) {
            .lt => op(-1.0, 0.0),
            .eq => op(0.0, 0.0),
            .gt => op(1.0, 0.0),
        };
    }

    // ── Boolean operations ───────────────────────────────────────────────────────

    /// Boolean AND: both operands evaluated, result is always a boolean.
    /// Uses jq conditional semantics: only false and null are falsy.
    fn doAndOp(it: *ResultIterator) ZqError!void {
        const right = try it.popValue();
        const left = try it.popValue();
        const result = isCondTruthy(left) and isCondTruthy(right);
        it.pushValue(.{ .bool_val = result });
    }

    /// Boolean OR: both operands evaluated, result is always a boolean.
    /// Uses jq conditional semantics: only false and null are falsy.
    fn doOrOp(it: *ResultIterator) ZqError!void {
        const right = try it.popValue();
        const left = try it.popValue();
        const result = isCondTruthy(left) or isCondTruthy(right);
        it.pushValue(.{ .bool_val = result });
    }

    /// jq conditional semantics: only `false` and `null` are falsy; everything
    /// else (0, "", [], {}, ...) is truthy.
    fn isCondTruthy(val: StackValue) bool {
        return switch (val) {
            .null_val => false,
            .bool_val => |b| b,
            else => true,
        };
    }

    // ── Fork stack backtracking ─────────────────────────────────────────────

    /// Set up fork-based iteration over it.current (must be array/object).
    /// Used by builtins (paths, recurse) that build a container and iterate.
    /// Returns false if container is empty (caller should backtrack or set ip past end).
    fn setupEachFromCurrent(it: *ResultIterator) error{OutOfMemory}!bool {
        switch (it.current) {
            .array => |span| {
                const first = span.start + 1;
                const end = span.end - 1;
                if (first >= end) return false;
                const saved_stack = try it.snapshotValueStackForFork();
                const saved_object = try it.snapshotObjectConstructState();
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .saved_current_args = it.current_args,
                    .saved_call_len = @intCast(it.call_stack.items.len),
                    .backtrack_ip = it.ip,
                    .aux = .{ .each = .{
                        .pos = first,
                        .end = end,
                        .is_object = false,
                        .tape = span.tape,
                    } },
                    .saved_path = it.snapshotPathState(),
                    .saved_stack = saved_stack,
                    .saved_object = saved_object,
                });
                it.current = tapeEntryToValue(span.tape, first);
                it.ip += 1;
                return true;
            },
            .object => |span| {
                const first_key = span.start + 1;
                const end = span.end - 1;
                if (first_key >= end) return false;
                const saved_stack = try it.snapshotValueStackForFork();
                const saved_object = try it.snapshotObjectConstructState();
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .saved_current_args = it.current_args,
                    .saved_call_len = @intCast(it.call_stack.items.len),
                    .backtrack_ip = it.ip,
                    .aux = .{ .each = .{
                        .pos = first_key,
                        .end = end,
                        .is_object = true,
                        .tape = span.tape,
                    } },
                    .saved_path = it.snapshotPathState(),
                    .saved_stack = saved_stack,
                    .saved_object = saved_object,
                });
                it.current = tapeEntryToValue(span.tape, first_key + 1);
                it.ip += 1;
                return true;
            },
            else => return false,
        }
    }

    /// Advance an each-type forkpoint to the next element.
    /// Returns true if advanced (sets it.current), false if exhausted.
    fn advanceEachForkpoint(it: *ResultIterator, fp: *Forkpoint) bool {
        var st = &fp.aux.each;
        const next_pos: u32 = if (st.is_object)
            skipEntry(st.tape.*, st.pos + 1) // step past value → next key
        else
            skipEntry(st.tape.*, st.pos); // step past current value

        if (next_pos >= st.end) return false;

        st.pos = next_pos;
        st.index += 1;
        it.current = if (st.is_object)
            tapeEntryToValue(st.tape, next_pos + 1) // value after key
        else
            tapeEntryToValue(st.tape, next_pos);
        // Record path component for the new iteration. The fork's saved_path
        // restoration in backtrackToDepth will have already truncated the
        // previous iteration's component, so we append fresh here. Skipped
        // when the enclosing path frame is a path-emitting builtin — the
        // container being iterated is a list of pre-built path arrays, not
        // a user value being descended into.
        if (it.path_stack.items.len > 0) {
            const frame = &it.path_stack.items[it.path_stack.items.len - 1];
            if (!frame.body_emits_paths_directly and !frame.skipComponents()) {
                if (st.is_object) {
                    const key_entry = st.tape.entries[next_pos];
                    frame.components.append(it.alloc, .{
                        .string = .{ .tape_ref = .{ .tape = st.tape, .ref = key_entry.payload.string } },
                    }) catch return false;
                } else {
                    frame.components.append(it.alloc, .{ .int = @intCast(st.index) }) catch return false;
                }
            }
        }
        return true;
    }

    /// Advance a range-type forkpoint to the next value.
    /// Returns true if advanced (sets it.current), false if exhausted.
    fn advanceRangeForkpoint(it: *ResultIterator, fp: *Forkpoint) bool {
        var st = &fp.aux.range;
        if (st.is_float) {
            st.current_float += st.step_float;
            if ((st.step_float > 0 and st.current_float >= st.end_float) or
                (st.step_float < 0 and st.current_float <= st.end_float) or
                st.step_float == 0)
            {
                return false;
            }
            it.current = .{ .float = st.current_float };
        } else {
            st.current_int += st.step_int;
            if ((st.step_int > 0 and st.current_int >= st.end_int) or
                (st.step_int < 0 and st.current_int <= st.end_int) or
                st.step_int == 0)
            {
                return false;
            }
            it.current = .{ .int = st.current_int };
        }
        return true;
    }

    /// Drop any yielded frames at the top of `call_stack` whose body
    /// forks are exhausted (`fork_stack.items.len <= saved_fork_len`).
    /// Caller-state value_stack / variable_store / current_args were
    /// already established by the yield; the final pop just removes
    /// the bookkeeping.
    fn dropExhaustedYieldedFrames(it: *ResultIterator) void {
        while (it.call_stack.items.len > 0) {
            const top = &it.call_stack.items[it.call_stack.items.len - 1];
            if (!top.returned) break;
            if (it.fork_stack.items.len > top.saved_fork_len) break;
            // Drop var_save_stack entries this frame owned. variable_store
            // is already at caller-state from the yield.
            it.var_save_stack.items.len = top.saved_var_len;
            _ = it.call_stack.pop();
        }
    }

    /// Re-activate frames whose bodies are about to re-execute because
    /// a fork created at `fork_saved_call_len` is firing. The fork's
    /// resume IP lives in the body of `call_stack[fork_saved_call_len-1]`,
    /// which (in jq's cascading-yield semantics) implicitly re-enters
    /// EVERY ancestor frame's body too — when this frame next yields,
    /// the cascade walks back up `call_stack` through each ancestor's
    /// post-call instruction. So for every frame at idx 0..depth-1 that
    /// was previously yielded, swap its `body_vars` back into
    /// `variable_store` (re-establish the body bindings) and clear
    /// `returned` so the next `return_function` cascade can target it.
    /// No-op for caller-side forks (depth ≤ pre-call call_stack length,
    /// which means no yielded frames lie within the fork's IP scope —
    /// the loop body's `if (f.returned)` guard handles this naturally).
    /// (NIX-011)
    fn reactivateFramesUpToDepth(it: *ResultIterator, depth: u32) void {
        const limit = @min(@as(usize, depth), it.call_stack.items.len);
        var idx: usize = 0;
        while (idx < limit) : (idx += 1) {
            const f = &it.call_stack.items[idx];
            if (!f.returned) continue;
            for (f.body_vars) |bv| {
                if (bv.id < it.variable_store.items.len) {
                    it.variable_store.items[bv.id] = bv.prev;
                }
            }
            f.returned = false;
        }
    }

    /// Walk the fork stack from the top, trying to advance each forkpoint.
    /// Normal forkpoints restore saved state and jump to backtrack_ip.
    /// Each/range forkpoints try to advance; if exhausted, pop and continue.
    /// Stops when it finds a forkpoint that can produce the next path.
    /// Returns true if a path was found, false if all forkpoints exhausted.
    fn backtrackToDepth(it: *ResultIterator, min_depth: u32) ZqError!bool {
        while (it.fork_stack.items.len > min_depth) {
            // NIX-011: any yielded frame whose body forks are exhausted
            // must finalize its pop before we inspect the next fork —
            // a caller-side fork with `saved_call_len < call_stack.len`
            // would otherwise be mis-detected as a body fork.
            it.dropExhaustedYieldedFrames();
            if (it.fork_stack.items.len <= min_depth) break;
            const fp = &it.fork_stack.items[it.fork_stack.items.len - 1];
            // NIX-011: rebind current_args to the lexical context where
            // this fork was created. Whether this fork fires (return
            // true) or pops to its outer context (continues the while
            // loop), the IP we resume at lived inside the fork-time
            // call frame's body. The next iteration re-sets from the
            // outer fork; if the loop exits with no fire, the latest
            // popped fork's snapshot is the surviving lexical context,
            // which matches the call_stack state truncateCallStackTo
            // already restored.
            it.current_args = fp.saved_current_args;
            // NIX-011 deferred-pop: capture saved_call_len BEFORE the
            // switch — every fire-site below pops `fp` from
            // `fork_stack`, invalidating the pointer. The captured
            // value is consumed by `reactivateFramesUpToDepth` to
            // detect body-fork-fires and swap `frame.body_vars` back
            // into `variable_store` so body re-execution sees its own
            // pattern-var bindings (not the caller's, which the prior
            // yield wrote to `variable_store`).
            const fp_saved_call_len = fp.saved_call_len;
            switch (fp.aux) {
                .normal => {
                    // If we captured a stack snapshot (fork nested in a
                    // collect or object literal), restore the value slots
                    // that intervening ops may have overwritten. Otherwise
                    // just restore the length.
                    if (fp.saved_stack) |snap| {
                        it.restoreValueStackFromSnapshot(snap);
                    } else {
                        it.value_stack.items.len = fp.saved_value_stack_len;
                    }
                    it.current = fp.saved_current;
                    it.ip = fp.backtrack_ip;
                    const saved_path = fp.saved_path;
                    // Restore object-construct stacks from fork-time snapshot
                    // so the next comma branch's field-value expression sees
                    // the same `{...}` context as the first branch (BUG-006).
                    if (fp.saved_object) |snap| it.restoreObjectConstructState(snap);
                    _ = it.fork_stack.pop();
                    it.restorePathState(saved_path);
                    it.reactivateFramesUpToDepth(fp_saved_call_len);
                    return true;
                },
                .each => {
                    // Restore path state BEFORE advancing — advanceEachForkpoint
                    // appends the new iteration's path component, which would
                    // be wiped out if we restored after.
                    it.restorePathState(fp.saved_path);
                    if (it.advanceEachForkpoint(fp)) {
                        // Restore object-construct stacks FIRST so the
                        // value-stack re-snapshot below sees the correct
                        // "inside-object" flag (snapshotValueStackForFork
                        // skips when neither a collect frame nor an object
                        // literal is active at call time — the re-snapshot
                        // would lose the fork-time values otherwise).
                        if (fp.saved_object) |snap| {
                            it.restoreObjectConstructState(snap);
                            fp.saved_object = try it.snapshotObjectConstructState();
                        }
                        // Restore value stack (from snapshot if captured;
                        // otherwise just truncate to saved length). Then
                        // re-snapshot so the next advance still has a valid
                        // snapshot — the value-stack slots may be clobbered
                        // again by this iteration's execution.
                        if (fp.saved_stack) |snap| {
                            it.restoreValueStackFromSnapshot(snap);
                            fp.saved_stack = try it.snapshotValueStackForFork();
                        } else {
                            it.value_stack.items.len = fp.saved_value_stack_len;
                        }
                        it.ip = fp.backtrack_ip + 1; // resume AFTER the each instruction
                        it.reactivateFramesUpToDepth(fp_saved_call_len);
                        return true;
                    }
                    it.value_stack.items.len = fp.saved_value_stack_len;
                    it.current = fp.saved_current;
                    _ = it.fork_stack.pop();
                },
                .range => {
                    it.restorePathState(fp.saved_path);
                    if (it.advanceRangeForkpoint(fp)) {
                        if (fp.saved_object) |snap| {
                            it.restoreObjectConstructState(snap);
                            fp.saved_object = try it.snapshotObjectConstructState();
                        }
                        if (fp.saved_stack) |snap| {
                            it.restoreValueStackFromSnapshot(snap);
                            fp.saved_stack = try it.snapshotValueStackForFork();
                        } else {
                            it.value_stack.items.len = fp.saved_value_stack_len;
                        }
                        it.ip = fp.backtrack_ip;
                        it.reactivateFramesUpToDepth(fp_saved_call_len);
                        return true;
                    }
                    it.value_stack.items.len = fp.saved_value_stack_len;
                    it.current = fp.saved_current;
                    _ = it.fork_stack.pop();
                },
                .try_handler => {
                    // Normal exhaustion — just pop, continue backtracking.
                    const saved_path = fp.saved_path;
                    _ = it.fork_stack.pop();
                    it.restorePathState(saved_path);
                },
                .alt_handler => |state| {
                    // Left side exhausted (all falsy or no outputs) — fire right side.
                    // Restore value-stack from snapshot (if captured) so the
                    // right-side expression starts with the same stack the
                    // left side began with.
                    if (fp.saved_stack) |snap| {
                        it.restoreValueStackFromSnapshot(snap);
                    } else {
                        it.value_stack.items.len = fp.saved_value_stack_len;
                    }
                    it.current = fp.saved_current;
                    it.if_stack.items.len = state.saved_if_len;
                    it.if_path_comps_stack.items.len = state.saved_if_len;
                    while (it.collect_stack.items.len > state.saved_collect_len) {
                        var cf = it.collect_stack.pop().?;
                        cf.buffer.deinit(it.alloc);
                    }
                    it.truncateCallStackTo(state.saved_call_len);
                    it.ip = fp.backtrack_ip; // right side IP
                    const saved_path = fp.saved_path;
                    if (fp.saved_object) |snap| it.restoreObjectConstructState(snap);
                    _ = it.fork_stack.pop();
                    it.restorePathState(saved_path);
                    it.reactivateFramesUpToDepth(fp_saved_call_len);
                    return true;
                },
                .label, .limit, .skip => {
                    // Label/limit/skip scope completed — just pop.
                    const saved_path = fp.saved_path;
                    _ = it.fork_stack.pop();
                    it.restorePathState(saved_path);
                },
                .reduce_source => |state| {
                    // The wrap is passive scaffolding for routing — when
                    // we backtrack into it, the source is exhausted (no
                    // inner generator advanced). Pop and continue
                    // unwinding so the enclosing reduce's `fork L_done`
                    // can fire its alternative arm.
                    while (it.collect_stack.items.len > state.saved_collect_len) {
                        var cf = it.collect_stack.pop().?;
                        cf.buffer.deinit(it.alloc);
                    }
                    const saved_path = fp.saved_path;
                    _ = it.fork_stack.pop();
                    it.restorePathState(saved_path);
                },
                .repeat => |state| {
                    while (it.collect_stack.items.len > state.saved_collect_len) {
                        var cf = it.collect_stack.pop().?;
                        cf.buffer.deinit(it.alloc);
                    }
                    it.truncateCallStackTo(state.saved_call_len);
                    it.value_stack.items.len = fp.saved_value_stack_len;
                    it.current = fp.saved_current;
                    it.restorePathState(fp.saved_path);
                    it.ip = state.body_start_ip;
                    it.reactivateFramesUpToDepth(fp_saved_call_len);
                    return true;
                },
                .path_scope => {
                    // Path() scope is exiting due to backtrack from outside —
                    // pop the matching path frame to clean up.
                    if (it.path_stack.items.len > 0) {
                        var frame = it.path_stack.pop().?;
                        frame.deinit(it.alloc);
                    }
                    _ = it.fork_stack.pop();
                },
                .scan => {
                    // Mirror range: advance via iterNext; if exhausted, pop.
                    it.restorePathState(fp.saved_path);
                    if (try it.advanceScanForkpoint(fp)) {
                        if (fp.saved_object) |snap| {
                            it.restoreObjectConstructState(snap);
                            fp.saved_object = try it.snapshotObjectConstructState();
                        }
                        if (fp.saved_stack) |snap| {
                            it.restoreValueStackFromSnapshot(snap);
                            fp.saved_stack = try it.snapshotValueStackForFork();
                        } else {
                            it.value_stack.items.len = fp.saved_value_stack_len;
                        }
                        it.ip = fp.backtrack_ip;
                        it.reactivateFramesUpToDepth(fp_saved_call_len);
                        return true;
                    }
                    it.value_stack.items.len = fp.saved_value_stack_len;
                    it.current = fp.saved_current;
                    it.freeRegexForkSlots(fp);
                    fp.aux = .{ .normal = {} };
                    _ = it.fork_stack.pop();
                },
                .match_g => {
                    it.restorePathState(fp.saved_path);
                    if (try it.advanceMatchGForkpoint(fp)) {
                        if (fp.saved_object) |snap| {
                            it.restoreObjectConstructState(snap);
                            fp.saved_object = try it.snapshotObjectConstructState();
                        }
                        if (fp.saved_stack) |snap| {
                            it.restoreValueStackFromSnapshot(snap);
                            fp.saved_stack = try it.snapshotValueStackForFork();
                        } else {
                            it.value_stack.items.len = fp.saved_value_stack_len;
                        }
                        it.ip = fp.backtrack_ip;
                        it.reactivateFramesUpToDepth(fp_saved_call_len);
                        return true;
                    }
                    it.value_stack.items.len = fp.saved_value_stack_len;
                    it.current = fp.saved_current;
                    it.freeRegexForkSlots(fp);
                    fp.aux = .{ .normal = {} };
                    _ = it.fork_stack.pop();
                },
                .sub_gen => {
                    // sub_/gsub_ K>1 generator: park each remaining branch
                    // string in fp.aux.sub_gen.refs (Tape.StringRef offsets).
                    // Each backtrack pushes the next branch onto value_stack
                    // (mirroring the dispatcher's `pushValue` after the
                    // initial call_builtin) and resumes at the trailing
                    // `jump exit_ip` (== backtrack_ip). No regex-fork slots
                    // owned — the regex was a one-shot in builtinSubImpl.
                    //
                    // Order matters: restore stack/object state FIRST (which
                    // truncates value_stack to its pre-call snapshot), THEN
                    // push the new branch value. Reversing the order would
                    // see our push wiped by the restore.
                    it.restorePathState(fp.saved_path);
                    var st = &fp.aux.sub_gen;
                    if (st.index < st.refs.len) {
                        if (fp.saved_object) |snap| {
                            it.restoreObjectConstructState(snap);
                            fp.saved_object = try it.snapshotObjectConstructState();
                        }
                        if (fp.saved_stack) |snap| {
                            it.restoreValueStackFromSnapshot(snap);
                            fp.saved_stack = try it.snapshotValueStackForFork();
                        } else {
                            it.value_stack.items.len = fp.saved_value_stack_len;
                        }
                        const r = st.refs[st.index];
                        st.index += 1;
                        it.pushValue(.{ .tape_value = .{ .string = .{
                            .tape_ref = .{ .tape = &it.runtime_tape.view, .ref = r },
                        } } });
                        it.ip = fp.backtrack_ip;
                        it.reactivateFramesUpToDepth(fp_saved_call_len);
                        return true;
                    }
                    it.value_stack.items.len = fp.saved_value_stack_len;
                    it.current = fp.saved_current;
                    fp.aux = .{ .normal = {} };
                    _ = it.fork_stack.pop();
                },
                .splits => {
                    it.restorePathState(fp.saved_path);
                    if (try it.advanceSplitsForkpoint(fp)) {
                        if (fp.saved_object) |snap| {
                            it.restoreObjectConstructState(snap);
                            fp.saved_object = try it.snapshotObjectConstructState();
                        }
                        if (fp.saved_stack) |snap| {
                            it.restoreValueStackFromSnapshot(snap);
                            fp.saved_stack = try it.snapshotValueStackForFork();
                        } else {
                            it.value_stack.items.len = fp.saved_value_stack_len;
                        }
                        it.ip = fp.backtrack_ip;
                        it.reactivateFramesUpToDepth(fp_saved_call_len);
                        return true;
                    }
                    it.value_stack.items.len = fp.saved_value_stack_len;
                    it.current = fp.saved_current;
                    it.freeRegexForkSlots(fp);
                    fp.aux = .{ .normal = {} };
                    _ = it.fork_stack.pop();
                },
                .recurse_path => {
                    // Advance to the next (value, path) pair. We restore path
                    // state first so the previous iteration's components are
                    // cleared, then immediately repopulate from the next entry.
                    it.restorePathState(fp.saved_path);
                    var state = &fp.aux.recurse_path;
                    const next_idx = state.index + 1;
                    if (next_idx < state.items.len) {
                        state.index = next_idx;
                        const entry = state.items[next_idx];
                        it.current = entry.value;
                        // Repopulate frame.components from the stored path.
                        if (it.path_stack.items.len > 0) {
                            const frame = &it.path_stack.items[it.path_stack.items.len - 1];
                            frame.components.clearRetainingCapacity();
                            try frame.components.appendSlice(it.alloc, entry.path_comps);
                        }
                        if (fp.saved_object) |snap| {
                            it.restoreObjectConstructState(snap);
                            fp.saved_object = try it.snapshotObjectConstructState();
                        }
                        if (fp.saved_stack) |snap| {
                            it.restoreValueStackFromSnapshot(snap);
                            fp.saved_stack = try it.snapshotValueStackForFork();
                        } else {
                            it.value_stack.items.len = fp.saved_value_stack_len;
                        }
                        it.ip = fp.backtrack_ip + 1; // resume after the call_builtin
                        it.reactivateFramesUpToDepth(fp_saved_call_len);
                        return true;
                    }
                    // All entries exhausted — pop and continue backtracking.
                    it.value_stack.items.len = fp.saved_value_stack_len;
                    it.current = fp.saved_current;
                    state.deinit();
                    _ = it.fork_stack.pop();
                },
            }
        }
        return false;
    }

    /// Backtrack within the innermost scope (collect frame boundary or depth 0).
    fn doBacktrack(it: *ResultIterator) ZqError!bool {
        const min_depth: u32 = if (it.collect_stack.items.len > 0)
            it.collect_stack.items[it.collect_stack.items.len - 1].outer_fork_depth
        else
            0;
        return it.backtrackToDepth(min_depth);
    }

    // ── Math builtins ──────────────────────────────────────────────────────

    fn getFloat(it: *ResultIterator) ZqError!f64 {
        return switch (it.current) {
            .int => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => error.TypeError,
        };
    }

    fn builtinAbs(it: *ResultIterator) ZqError!?StackValue {
        return switch (it.current) {
            .int => |i| .{ .int = if (i < 0) -i else i },
            .float => |f| .{ .float = @abs(f) },
            .null_val => .{ .int = 0 },
            else => try valueToStackValue(it.current),
        };
    }

    fn builtinFloor(it: *ResultIterator) StackValue {
        return switch (it.current) {
            .int => |i| .{ .int = i },
            .float => |f| .{ .int = @intFromFloat(@floor(f)) },
            else => .{ .int = 0 },
        };
    }

    fn builtinCeil(it: *ResultIterator) StackValue {
        return switch (it.current) {
            .int => |i| .{ .int = i },
            .float => |f| .{ .int = @intFromFloat(@ceil(f)) },
            else => .{ .int = 0 },
        };
    }

    fn builtinRound(it: *ResultIterator) StackValue {
        return switch (it.current) {
            .int => |i| .{ .int = i },
            .float => |f| .{ .int = @intFromFloat(@round(f)) },
            else => .{ .int = 0 },
        };
    }

    fn builtinSqrt(it: *ResultIterator) StackValue {
        return switch (it.current) {
            .int => |i| .{ .float = @sqrt(@as(f64, @floatFromInt(i))) },
            .float => |f| .{ .float = @sqrt(f) },
            else => .{ .float = std.math.nan(f64) },
        };
    }

    fn builtinFabs(it: *ResultIterator) StackValue {
        return switch (it.current) {
            .int => |i| .{ .float = @abs(@as(f64, @floatFromInt(i))) },
            .float => |f| .{ .float = @abs(f) },
            else => .{ .float = 0.0 },
        };
    }

    fn builtinIsinfinite(it: *ResultIterator) StackValue {
        return switch (it.current) {
            .float => |f| .{ .bool_val = std.math.isInf(f) },
            .int => .{ .bool_val = false },
            else => .{ .bool_val = false },
        };
    }

    fn builtinIsnan(it: *ResultIterator) StackValue {
        return switch (it.current) {
            .float => |f| .{ .bool_val = std.math.isNan(f) },
            .int => .{ .bool_val = false },
            else => .{ .bool_val = false },
        };
    }

    fn builtinIsnormal(it: *ResultIterator) StackValue {
        return switch (it.current) {
            .float => |f| .{ .bool_val = std.math.isNormal(f) },
            .int => .{ .bool_val = true },
            else => .{ .bool_val = false },
        };
    }

    fn builtinExp(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = @exp(x) };
    }

    fn builtinExp2(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = @exp2(x) };
    }

    fn builtinExp10(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = @exp(x * @log(@as(f64, 10.0))) };
    }

    fn builtinLog(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = @log(x) };
    }

    fn builtinLog2(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = @log2(x) };
    }

    fn builtinLog10(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = @log10(x) };
    }

    fn builtinCbrt(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = std.math.cbrt(x) };
    }

    fn builtinSin(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = @sin(x) };
    }

    fn builtinCos(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = @cos(x) };
    }

    fn builtinTan(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = @tan(x) };
    }

    fn builtinAsin(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = std.math.asin(x) };
    }

    fn builtinAcos(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = std.math.acos(x) };
    }

    fn builtinAtan(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = std.math.atan(x) };
    }

    fn builtinRint(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = @round(x) };
    }

    fn builtinTrunc(it: *ResultIterator) StackValue {
        const x = it.getFloat() catch return .{ .float = std.math.nan(f64) };
        return .{ .float = @trunc(x) };
    }

    fn builtinSignificand(it: *ResultIterator) StackValue {
        const x = switch (it.current) {
            .int => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => return .{ .float = std.math.nan(f64) },
        };
        const fr = std.math.frexp(x);
        return .{ .float = fr.significand * 2.0 };
    }

    fn builtinLogb(it: *ResultIterator) StackValue {
        const x = switch (it.current) {
            .int => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => return .{ .float = std.math.nan(f64) },
        };
        const fr = std.math.frexp(x);
        return .{ .float = @as(f64, @floatFromInt(fr.exponent - 1)) };
    }

    fn builtinLgamma(it: *ResultIterator) StackValue {
        const x = switch (it.current) {
            .int => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => return .{ .float = std.math.nan(f64) },
        };
        return .{ .float = std.math.lgamma(f64, x) };
    }

    fn builtinTgamma(it: *ResultIterator) StackValue {
        const x = switch (it.current) {
            .int => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => return .{ .float = std.math.nan(f64) },
        };
        // tgamma = exp(lgamma(x)) with sign correction
        // For positive integers, it's (n-1)!
        if (x > 0 and x <= 171) {
            const lg = std.math.lgamma(f64, x);
            return .{ .float = @exp(lg) };
        }
        return .{ .float = std.math.nan(f64) };
    }

    // ── Two-arg math builtins ──────────────────────────────────────────────

    fn popFloat(it: *ResultIterator) ZqError!f64 {
        const sv = try it.popValue();
        return switch (sv) {
            .int => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => error.TypeError,
        };
    }

    fn builtinPow(it: *ResultIterator) ZqError!?StackValue {
        const b = try it.popFloat();
        const a = try it.popFloat();
        return .{ .float = std.math.pow(f64, a, b) };
    }

    fn builtinAtan2(it: *ResultIterator) ZqError!?StackValue {
        const x = try it.popFloat();
        const y = try it.popFloat();
        return .{ .float = std.math.atan2(y, x) };
    }

    fn builtinRemainder(it: *ResultIterator) ZqError!?StackValue {
        const b = try it.popFloat();
        const a = try it.popFloat();
        return .{ .float = @rem(a, b) };
    }

    fn builtinHypot(it: *ResultIterator) ZqError!?StackValue {
        const b = try it.popFloat();
        const a = try it.popFloat();
        return .{ .float = std.math.hypot(a, b) };
    }

    fn builtinLdexp(it: *ResultIterator) ZqError!?StackValue {
        const n_f = try it.popFloat();
        const x = try it.popFloat();
        const n: i32 = @intFromFloat(n_f);
        return .{ .float = std.math.ldexp(x, n) };
    }

    fn builtinFma(it: *ResultIterator) ZqError!?StackValue {
        const z = try it.popFloat();
        const y = try it.popFloat();
        const x = try it.popFloat();
        return .{ .float = @mulAdd(f64, x, y, z) };
    }

    // ── Type-check filter builtins ─────────────────────────────────────────

    const TypeFilterKind = enum {
        array,
        object,
        string,
        number,
        boolean,
        null_type,
        values_type,
        scalar,
        normal,
        iterable,
    };

    fn builtinTypeFilter(it: *ResultIterator, comptime kind: TypeFilterKind) ?StackValue {
        const matches = switch (kind) {
            .array => switch (it.current) {
                .array => true,
                else => false,
            },
            .object => switch (it.current) {
                .object => true,
                else => false,
            },
            .string => switch (it.current) {
                .string => true,
                else => false,
            },
            .number => switch (it.current) {
                .int, .float => true,
                else => false,
            },
            .boolean => switch (it.current) {
                .bool_val => true,
                else => false,
            },
            .null_type => switch (it.current) {
                .null_val => true,
                else => false,
            },
            .values_type => switch (it.current) {
                .null_val => false,
                else => true,
            },
            .scalar => switch (it.current) {
                .array, .object => false,
                else => true,
            },
            .normal => switch (it.current) {
                .null_val => false,
                .bool_val => |b| b, // false is not normal
                .float => |f| !std.math.isNan(f) and !std.math.isInf(f),
                else => true,
            },
            .iterable => switch (it.current) {
                .array, .object => true,
                else => false,
            },
        };
        if (matches) {
            // Pass through current value
            return valueToStackValue(it.current) catch null;
        } else {
            // Produce empty
            it.ip = @intCast(it.instructions.len);
            return null;
        }
    }

    // ── String builtins ────────────────────────────────────────────────────

    fn builtinAsciiCase(it: *ResultIterator, comptime upper: bool) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return error.TypeError,
        };
        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        try buf.ensureTotalCapacity(it.alloc, s.len);
        for (s) |c| {
            if (upper) {
                try buf.append(it.alloc, if (c >= 'a' and c <= 'z') c - 32 else c);
            } else {
                try buf.append(it.alloc, if (c >= 'A' and c <= 'Z') c + 32 else c);
            }
        }
        const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
        return it.rtStringSV(str_ref);
    }

    fn builtinAscii(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .string => |sv| {
                const s = sv.slice();
                if (s.len == 0) return error.TypeError;
                return .{ .int = @intCast(s[0]) };
            },
            .int => |i| {
                if (i < 0 or i > 127) return error.TypeError;
                var buf: [1]u8 = .{@intCast(@as(u8, @intCast(i)))};
                const str_ref = try it.runtime_tape.internString(it.alloc, &buf);
                return it.rtStringSV(str_ref);
            },
            else => return error.TypeError,
        }
    }

    fn builtinExplode(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return error.TypeError,
        };
        const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });
        var i: usize = 0;
        while (i < s.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
                // Invalid UTF-8 byte: emit as-is
                _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .int,
                    .payload = .{ .int = @intCast(s[i]) },
                });
                i += 1;
                continue;
            };
            if (i + seq_len > s.len) {
                _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .int,
                    .payload = .{ .int = @intCast(s[i]) },
                });
                i += 1;
                continue;
            }
            const cp = std.unicode.utf8Decode(s[i..][0..seq_len]) catch {
                _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .int,
                    .payload = .{ .int = @intCast(s[i]) },
                });
                i += 1;
                continue;
            };
            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .int,
                .payload = .{ .int = @intCast(cp) },
            });
            i += seq_len;
        }
        const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape.view,
            .start = arr_start,
            .end = arr_end_idx + 1,
        } } };
    }

    fn builtinImplode(it: *ResultIterator) ZqError!?StackValue {
        const span = switch (it.current) {
            .array => |s| s,
            else => {
                // Non-array input: raise a catchable error matching jq's message.
                return it.raiseUserError("implode input must be an array");
            },
        };
        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        var pos = span.start + 1;
        const end = span.end - 1;
        // U+FFFD (REPLACEMENT CHARACTER) UTF-8 encoding.
        const fffd_utf8 = "\xEF\xBF\xBD";
        while (pos < end) {
            const val = tapeEntryToValue(span.tape, pos);
            // Resolve the element to a signed codepoint integer.
            // Strings, bools, arrays, objects, and nan/inf floats are not valid
            // unicode codepoints — raise a catchable jq-compatible UserError.
            const cp_i: i64 = switch (val) {
                .int => |i| i,
                .float => |f| blk: {
                    // nan and inf are not valid codepoints.
                    if (std.math.isNan(f) or std.math.isInf(f)) {
                        // Build error message: "<type> (<json>) can't be imploded,unicode codepoint needs to be numeric"
                        var msg_buf = std.ArrayList(u8){};
                        defer msg_buf.deinit(it.alloc);
                        try msg_buf.appendSlice(it.alloc, baseTypeName(val));
                        try msg_buf.append(it.alloc, ' ');
                        try msg_buf.append(it.alloc, '(');
                        try appendCompactJsonTrunc(&msg_buf, it.alloc, val);
                        try msg_buf.appendSlice(it.alloc, ") can't be imploded,unicode codepoint needs to be numeric");
                        const str_ref = try it.runtime_tape.internString(it.alloc, msg_buf.items);
                        it.user_error_msg = .{ .string = it.rtString(str_ref) };
                        return error.UserError;
                    }
                    // Valid finite float: truncate toward zero (jq behaviour).
                    break :blk @as(i64, @intFromFloat(@trunc(f)));
                },
                else => {
                    // Non-numeric element: raise catchable error.
                    var msg_buf = std.ArrayList(u8){};
                    defer msg_buf.deinit(it.alloc);
                    try msg_buf.appendSlice(it.alloc, baseTypeName(val));
                    try msg_buf.append(it.alloc, ' ');
                    try msg_buf.append(it.alloc, '(');
                    try appendCompactJsonTrunc(&msg_buf, it.alloc, val);
                    try msg_buf.appendSlice(it.alloc, ") can't be imploded,unicode codepoint needs to be numeric");
                    const str_ref = try it.runtime_tape.internString(it.alloc, msg_buf.items);
                    it.user_error_msg = .{ .string = it.rtString(str_ref) };
                    return error.UserError;
                },
            };
            // Validate codepoint: negative, > U+10FFFF, or surrogate (U+D800–U+DFFF)
            // are replaced with U+FFFD (REPLACEMENT CHARACTER), matching jq behaviour.
            if (cp_i < 0 or cp_i > 0x10FFFF or (cp_i >= 0xD800 and cp_i <= 0xDFFF)) {
                try buf.appendSlice(it.alloc, fffd_utf8);
            } else {
                const cp: u21 = @intCast(@as(u32, @intCast(cp_i)));
                var encode_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &encode_buf) catch {
                    // Should be unreachable after the range checks above,
                    // but substitute FFFD defensively.
                    try buf.appendSlice(it.alloc, fffd_utf8);
                    pos = skipEntry(span.tape.*, pos);
                    continue;
                };
                try buf.appendSlice(it.alloc, encode_buf[0..len]);
            }
            pos = skipEntry(span.tape.*, pos);
        }
        const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
        return it.rtStringSV(str_ref);
    }

    // ── JSON builtins ──────────────────────────────────────────────────────

    fn builtinTojson(it: *ResultIterator) ZqError!?StackValue {
        return it.builtinFormatJson();
    }

    fn builtinFromjson(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return error.TypeError,
        };
        // Parse JSON string into a value using a simple recursive descent parser
        return try parseJsonToStackValue(it, s);
    }

    // ── Misc builtins ──────────────────────────────────────────────────────

    fn builtinNot(it: *ResultIterator) StackValue {
        // jq truthiness: false and null are falsy, everything else is truthy
        const truthy = switch (it.current) {
            .null_val => false,
            .bool_val => |b| b,
            else => true,
        };
        return .{ .bool_val = !truthy };
    }

    fn builtinBuiltins(it: *ResultIterator) ZqError!?StackValue {
        // Derive "name/arity" entries from BuiltinId enum — single source of truth.
        // Matches jq's format: ["length/0", "keys/0", "range/1", "range/2", ...]
        const builtin_strs = comptime blk: {
            const count = types.BuiltinId.jqBuiltinCount();
            var result: [count][]const u8 = undefined;
            var i: usize = 0;
            for (std.enums.values(types.BuiltinId)) |id| {
                if (id.jqEntry()) |entry| {
                    result[i] = entry.name ++ "/" ++ &[1]u8{'0' + entry.arity};
                    i += 1;
                }
            }
            break :blk result;
        };
        const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });
        for (builtin_strs) |name| {
            const str_ref = try it.runtime_tape.internString(it.alloc, name);
            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .string,
                .payload = .{ .string = str_ref },
            });
        }
        const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape.view,
            .start = arr_start,
            .end = arr_end_idx + 1,
        } } };
    }

    fn builtinEnv(it: *ResultIterator) ZqError!?StackValue {
        // Return empty object for now (environment not accessible in query context)
        const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_start,
            .payload = .{ .skip = 0 },
        });
        const obj_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;
        return .{ .tape_value = .{ .object = .{
            .tape = &it.runtime_tape.view,
            .start = obj_start,
            .end = obj_end_idx + 1,
        } } };
    }

    /// `modulemeta` builtin — Phase 2b. Input value is a string giving a
    /// module relpath (jq's convention); resolves it via the same search
    /// machinery the compiler uses, parses the target module, and returns
    /// `{<module_meta_fields...>, deps:[...], defs:[...]}`.
    ///
    /// `deps` mirrors the source-order import/include directives; entries
    /// carry `as` (alias, omitted for `include`), `is_data`, `relpath`,
    /// and `search` (only when the directive declared `{search:"..."}`).
    /// `defs` lists the module's own top-level `def name(...): ...` chain
    /// as `"name/arity"` strings — transitive imports are not included.
    fn builtinModulemeta(it: *ResultIterator) ZqError!?StackValue {
        const relpath = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return error.TypeError,
        };

        // Per-call arena owns Resolver bookkeeping; module ParseResults
        // attach to it.alloc and are dropped via resolver.deinit() before
        // the arena tears down. All strings reaching runtime_tape are
        // re-interned so parse-result lifetime ends here.
        var arena = std.heap.ArenaAllocator.init(it.alloc);
        defer arena.deinit();
        var r = resolver_mod.Resolver.init(
            &arena,
            it.alloc,
            it.module_search_path,
            it.current_file_dir,
        );
        defer r.deinit();

        const resolved = r.loadJq(relpath) catch return error.TypeError;
        const root = resolved.parse_result.root;

        // Extract module_meta + directives + def chain from the parsed
        // root. A `program` node carries module_meta and directives;
        // a bare-body root has neither (whatever-merge yields nothing).
        var module_meta: ?*const ast.Node = null;
        var directives: []const ast.Node.Directive = &.{};
        var body: *const ast.Node = root;
        if (root.kind == .program) {
            const prog = root.kind.program;
            module_meta = prog.module_meta;
            directives = prog.directives;
            body = prog.body;
        }

        const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_start,
            .payload = .{ .skip = 0 },
        });

        // ── Spread module_meta fields verbatim ──────────────────────
        if (module_meta) |meta_node| {
            if (meta_node.kind == .object_construct) {
                for (meta_node.kind.object_construct.fields) |f| {
                    const key_str: []const u8 = switch (f.key) {
                        .ident => |s| s,
                        .string => |s| s,
                        // Dollar / expr keys aren't const-object literals;
                        // parser rejects them upstream so we'd never reach
                        // here. Treat as a malformed module — error out.
                        else => return error.TypeError,
                    };
                    try it.appendObjectKey(key_str);
                    try it.appendConstLiteralNode(f.value);
                }
            }
        }

        // ── deps array ──────────────────────────────────────────────
        try it.appendObjectKey("deps");
        const deps_arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });
        for (directives) |dir| {
            try it.appendDirectiveEntry(dir);
        }
        const deps_arr_end = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[deps_arr_start].payload.skip = deps_arr_end + 1;

        // ── defs array (top-level `def name(...): ...` chain only) ──
        try it.appendObjectKey("defs");
        const defs_arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });
        var cur: *const ast.Node = body;
        while (cur.kind == .func_def) {
            const fd = cur.kind.func_def;
            // Format "<name>/<arity>" — arity is the param count.
            var buf: [256]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "{s}/{d}", .{ fd.name, fd.params.len }) catch return error.OutOfMemory;
            const sref = try it.runtime_tape.internString(it.alloc, formatted);
            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .string,
                .payload = .{ .string = sref },
            });
            cur = fd.rest;
        }
        const defs_arr_end = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[defs_arr_start].payload.skip = defs_arr_end + 1;

        const obj_end = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[obj_start].payload.skip = obj_end + 1;
        return .{ .tape_value = .{ .object = .{
            .tape = &it.runtime_tape.view,
            .start = obj_start,
            .end = obj_end + 1,
        } } };
    }

    /// Append a `key` tape entry interning the key string. Used by
    /// `builtinModulemeta` to build the result object field-by-field.
    fn appendObjectKey(it: *ResultIterator, key: []const u8) ZqError!void {
        const sref = try it.runtime_tape.internString(it.alloc, key);
        _ = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .key,
            .payload = .{ .string = sref },
        });
    }

    /// Append one directive's `{as?, is_data, relpath, search?}` object.
    /// The key order matches jq's `modulemeta` output: when `search` is
    /// present it precedes `as`; `as` is omitted entirely for `include`.
    fn appendDirectiveEntry(it: *ResultIterator, dir: ast.Node.Directive) ZqError!void {
        const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_start,
            .payload = .{ .skip = 0 },
        });

        // Extract optional `search` from the directive's const-object meta.
        var search_str: ?[]const u8 = null;
        if (dir.meta) |m| {
            if (m.kind == .object_construct) {
                for (m.kind.object_construct.fields) |f| {
                    const key_str: []const u8 = switch (f.key) {
                        .ident => |s| s,
                        .string => |s| s,
                        else => continue,
                    };
                    if (std.mem.eql(u8, key_str, "search")) {
                        if (f.value.kind == .literal) {
                            switch (f.value.kind.literal) {
                                .string => |s| search_str = s,
                                else => {},
                            }
                        }
                    }
                }
            }
        }

        if (search_str) |s| {
            try it.appendObjectKey("search");
            const sref = try it.runtime_tape.internString(it.alloc, s);
            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .string,
                .payload = .{ .string = sref },
            });
        }

        if (dir.alias) |alias| {
            try it.appendObjectKey("as");
            const sref = try it.runtime_tape.internString(it.alloc, alias);
            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .string,
                .payload = .{ .string = sref },
            });
        }

        try it.appendObjectKey("is_data");
        _ = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = if (dir.is_data) .true_val else .false_val,
            .payload = .{ .none = {} },
        });

        try it.appendObjectKey("relpath");
        const rref = try it.runtime_tape.internString(it.alloc, dir.relpath);
        _ = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .string,
            .payload = .{ .string = rref },
        });

        const obj_end = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[obj_start].payload.skip = obj_end + 1;
    }

    /// Recursively materialize a const-literal AST subtree onto the
    /// runtime tape. Const literals are: scalar literal, array of const
    /// literals, or object with const-literal values (mirrors the parser's
    /// `isConstLiteralExpr` shape — `modulemeta` is the only consumer).
    fn appendConstLiteralNode(it: *ResultIterator, node: *const ast.Node) ZqError!void {
        switch (node.kind) {
            .literal => |lit| switch (lit) {
                .null_val => _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .null_val,
                    .payload = .{ .none = {} },
                }),
                .bool_val => |b| _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = if (b) .true_val else .false_val,
                    .payload = .{ .none = {} },
                }),
                .int => |n| _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .int,
                    .payload = .{ .int = n },
                }),
                .float => |f| _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .float,
                    .payload = .{ .float = f },
                }),
                .big_number => |s| {
                    const sref = try it.runtime_tape.internString(it.alloc, s);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .big_number,
                        .payload = .{ .string = sref },
                    });
                },
                .string => |s| {
                    const sref = try it.runtime_tape.internString(it.alloc, s);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .string,
                        .payload = .{ .string = sref },
                    });
                },
            },
            .array_construct => |ac| {
                const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_start,
                    .payload = .{ .skip = 0 },
                });
                if (ac.expr) |elem| try it.appendConstLiteralCommaSeq(elem);
                const arr_end = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[arr_start].payload.skip = arr_end + 1;
            },
            .object_construct => |oc| {
                const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .object_start,
                    .payload = .{ .skip = 0 },
                });
                for (oc.fields) |f| {
                    const key_str: []const u8 = switch (f.key) {
                        .ident => |s| s,
                        .string => |s| s,
                        else => return error.TypeError,
                    };
                    try it.appendObjectKey(key_str);
                    try it.appendConstLiteralNode(f.value);
                }
                const obj_end = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .object_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[obj_start].payload.skip = obj_end + 1;
            },
            else => return error.TypeError,
        }
    }

    /// Walk a comma-separated const-literal sequence (the body of an
    /// array literal) and emit each element. Mirrors the parser's
    /// `isConstLiteralCommaSeq` shape.
    fn appendConstLiteralCommaSeq(it: *ResultIterator, node: *const ast.Node) ZqError!void {
        switch (node.kind) {
            .comma => |c| {
                try it.appendConstLiteralCommaSeq(c.left);
                try it.appendConstLiteralCommaSeq(c.right);
            },
            else => try it.appendConstLiteralNode(node),
        }
    }

    fn builtinMapValues(it: *ResultIterator) ZqError!?StackValue {
        // map_values(f) is compiled like sort_by: the filter-arg builtin pattern
        // collects [.[] | f] into an array on value_stack, original is on if_stack.
        // We need to reconstruct the original structure with new values.
        const mapped_sv = try it.popValue();
        if (it.if_stack.items.len == 0) return error.TypeError;
        const original = it.if_stack.pop().?;

        switch (original) {
            .array => {
                // For arrays, the mapped values ARE the result
                return mapped_sv;
            },
            .object => |span| {
                // For objects, reconstruct with original keys and mapped values
                const mapped_span = switch (mapped_sv) {
                    .tape_value => |tv| switch (tv) {
                        .array => |s| s,
                        else => return error.TypeError,
                    },
                    else => return error.TypeError,
                };

                const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .object_start,
                    .payload = .{ .skip = 0 },
                });

                // Walk original keys and mapped values in parallel
                var key_pos = span.start + 1;
                const key_end = span.end - 1;
                var val_pos = mapped_span.start + 1;
                const val_end = mapped_span.end - 1;

                while (key_pos < key_end and val_pos < val_end) {
                    // Copy key from original
                    const key_str = span.tape.getString(span.tape.entries[key_pos].payload.string);
                    const key_ref = try it.runtime_tape.internString(it.alloc, key_str);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .key,
                        .payload = .{ .string = key_ref },
                    });

                    // Copy mapped value
                    const val = tapeEntryToValue(mapped_span.tape, val_pos);
                    const val_sv = try valueToStackValue(val);
                    try it.stackValueToRuntimeTapeEntry(val_sv);

                    key_pos = skipEntry(span.tape.*, key_pos + 1); // skip original value
                    val_pos = skipEntry(mapped_span.tape.*, val_pos);
                }

                const obj_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .object_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;
                return .{ .tape_value = .{ .object = .{
                    .tape = &it.runtime_tape.view,
                    .start = obj_start,
                    .end = obj_end_idx + 1,
                } } };
            },
            else => return error.TypeError,
        }
    }

    fn builtinFirst(it: *ResultIterator) ZqError!?StackValue {
        // first as zero-arg: .[0]
        return try valueToStackValue(try it.doLoadIndex(0));
    }

    fn builtinLast(it: *ResultIterator) ZqError!?StackValue {
        // last as zero-arg: .[-1]
        return try valueToStackValue(try it.doLoadIndex(-1));
    }

    // ── String builtins (arg-taking) ─────────────────────────────────────────

    /// `split(sep)`: split string by separator.
    /// Intern each substring on the runtime tape eagerly and re-resolve
    /// `input`/`sep` slices via StringView after every intern, since the
    /// runtime_tape.string_buf may reallocate (NIX-006 alias-safety).
    fn builtinSplit(it: *ResultIterator) ZqError!?StackValue {
        const sep_sv = try it.popValue();
        const sep_val = try stackValueToValue(sep_sv);
        const sep_view: Value.StringView = switch (sep_val) {
            .string => |sv| sv,
            else => return error.TypeError,
        };
        const input_view: Value.StringView = switch (it.current) {
            .string => |sv| sv,
            else => return error.TypeError,
        };

        // Open the result array on the runtime tape directly so we can
        // intern part strings into it as we go without holding stale Values.
        const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });

        const sep_len_initial = sep_view.slice().len;
        if (sep_len_initial == 0) {
            // Split into individual codepoints.
            var i: usize = 0;
            while (true) {
                const input = input_view.slice();
                if (i >= input.len) break;
                const seq_len = std.unicode.utf8ByteSequenceLength(input[i]) catch 1;
                const char_end = @min(i + seq_len, input.len);
                const part_ref = try it.runtime_tape.internString(it.alloc, input[i..char_end]);
                _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .string,
                    .payload = .{ .string = part_ref },
                });
                i = char_end;
            }
        } else {
            var start: usize = 0;
            while (true) {
                const input = input_view.slice();
                const sep = sep_view.slice();
                if (start > input.len) break;
                if (start + sep.len <= input.len and std.mem.eql(u8, input[start..][0..sep.len], sep)) {
                    const part_ref = try it.runtime_tape.internString(it.alloc, "");
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .string,
                        .payload = .{ .string = part_ref },
                    });
                    start += sep.len;
                } else {
                    var end = start;
                    var found = false;
                    while (end < input.len) {
                        const input2 = input_view.slice();
                        const sep2 = sep_view.slice();
                        if (end + sep2.len <= input2.len and std.mem.eql(u8, input2[end..][0..sep2.len], sep2)) {
                            const part_ref = try it.runtime_tape.internString(it.alloc, input2[start..end]);
                            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                                .tag = .string,
                                .payload = .{ .string = part_ref },
                            });
                            start = end + sep2.len;
                            found = true;
                            break;
                        }
                        end += 1;
                    }
                    if (!found) {
                        const input3 = input_view.slice();
                        const part_ref = try it.runtime_tape.internString(it.alloc, input3[start..input3.len]);
                        _ = try it.runtime_tape.appendEntry(it.alloc, .{
                            .tag = .string,
                            .payload = .{ .string = part_ref },
                        });
                        break;
                    }
                }
            }
        }

        const arr_end = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[arr_start].payload.skip = arr_end + 1;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape.view,
            .start = arr_start,
            .end = arr_end + 1,
        } } };
    }

    /// `join(sep)`: join array elements with separator.
    /// In jq, join converts scalars to strings but raises an error for arrays/objects.
    fn builtinJoin(it: *ResultIterator) ZqError!?StackValue {
        const sep_sv = try it.popValue();
        const sep_val = try stackValueToValue(sep_sv);
        const sep_view: Value.StringView = switch (sep_val) {
            .string => |sv| sv,
            else => return error.TypeError,
        };

        const span = switch (it.current) {
            .array => |s| s,
            else => return error.TypeError,
        };

        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);

        var pos = span.start + 1;
        const end = span.end - 1;
        var first = true;
        while (pos < end) {
            if (!first) {
                try buf.appendSlice(it.alloc, sep_view.slice());
            }
            first = false;

            const elem = tapeEntryToValue(span.tape, pos);
            switch (elem) {
                .string => |sv| try buf.appendSlice(it.alloc, sv.slice()),
                .null_val => {}, // null treated as empty string
                .int => |n| {
                    var tmp: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return error.TypeError;
                    try buf.appendSlice(it.alloc, s);
                },
                .float => |f| {
                    const formatted = types.formatJqFloat(f);
                    try buf.appendSlice(it.alloc, formatted.slice());
                },
                .bool_val => |b| try buf.appendSlice(it.alloc, if (b) "true" else "false"),
                .big_number => |bn| try buf.appendSlice(it.alloc, bn),
                .array, .object => {
                    // jq raises "string (...) and TYPE (...) cannot be added"
                    var msg_buf = std.ArrayList(u8){};
                    defer msg_buf.deinit(it.alloc);
                    try msg_buf.appendSlice(it.alloc, "string (");
                    try appendJsonString(&msg_buf, it.alloc, buf.items);
                    try msg_buf.appendSlice(it.alloc, ") and ");
                    switch (elem) {
                        .array => try msg_buf.appendSlice(it.alloc, "array ("),
                        .object => try msg_buf.appendSlice(it.alloc, "object ("),
                        else => unreachable,
                    }
                    try serializeValueCompact(&msg_buf, it.alloc, elem);
                    try msg_buf.appendSlice(it.alloc, ") cannot be added");
                    return try it.raiseUserError(msg_buf.items);
                },
            }
            pos = skipEntry(span.tape.*, pos);
        }

        const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
        return it.rtStringSV(str_ref);
    }

    /// Build a jq-compatible TypeError detail message for field access on wrong type.
    /// Uses runtime tape for the message string so it remains valid during iteration.
    /// The key parameter is included via runtime tape string interning.
    /// Describes what kind of type mismatch occurred.  Used by `buildTypeErrorMsg`
    /// to produce jq-compatible error strings from a single formatting path.
    /// Identifies the arithmetic operation in a binary-arith TypeError.
    /// Each op contributes its own jq verb suffix; div/mod additionally
    /// gain a "(remainder)" tag (mod only) and a "because the divisor is
    /// zero" tail when both operands are numeric and rhs is exactly zero.
    /// Mirrors jq 1.8.1's `make_arith_op_type_error` callsites (builtin.c
    /// `binop_minus`, `binop_div`, `binop_mod`).
    const BinaryArithOp = enum { add, subtract, multiply, divide, modulo };

    const TypeErrorKind = union(enum) {
        /// `.foo` / `.["key"]` field access on a non-object/null.
        /// Produces: "Cannot index <type> with string ("<key>")"
        index_string: []const u8,
        /// `.[n]` / `.[n] = v` numeric index on a non-array/null.
        /// Produces: "Cannot index <type> with number"
        index_number,
        /// Numeric index with the actual index value included.
        /// Produces: "Cannot index <type> with number (<n>)"
        index_number_val: i64,
        /// Float (non-integer) index with the actual value included.
        /// Produces: "Cannot index <type> with number (<f>)"
        index_number_float: f64,
        /// `.[]` iteration on a non-array/object/null.
        /// Produces: "Cannot iterate over <type> (<compact-json>)"
        iterate,
        /// Unary `-` applied to a non-numeric value.
        /// Produces: "<type> (<compact-json>) cannot be negated"
        negate,
        /// Binary arithmetic (`-`, `/`, `%`) with an unsupported operand
        /// pair, or a divide/modulo by numeric zero.
        /// Produces: "<lhs_type> (<lhs_json>) and <rhs_type> (<rhs_json>) cannot be <verb>[ (remainder)][ because the divisor is zero]"
        /// The "(remainder)" suffix is appended for `.modulo`; the
        /// "because the divisor is zero" tail is appended when both
        /// operands are numeric and rhs is exactly zero.
        /// `val` is unused for this kind; operand values live in the payload.
        binary_arith: struct { lhs: Value, rhs: Value, op: BinaryArithOp },
        /// `setpath` path-component type-mismatch on a non-slice base.
        /// Produces: "Cannot index <baseTypeName(base)> with <pc_type>"
        /// `pc_type` is the static label (`"object"`, `"array"`, `"boolean"`,
        /// `"null"`) of the offending path-component shape.
        /// `val` is unused; the base lives in the payload so the message
        /// uses `baseTypeName` rather than the parenthesized boolean form.
        setpath_index: struct { base: Value, pc_type: []const u8 },
        /// `setpath` slice path component with non-integer "start"/"end".
        /// Produces: "Array/string slice indices must be integers"
        setpath_slice,
    };

    /// Base jq type name for `<type> (<compact-json>)`-style messages.
    /// Unlike the indexer-style `type_name` (which folds the boolean value
    /// into the type name), this returns just the base label so callers can
    /// append `(<compact-json>)` themselves and avoid double-rendering.
    fn baseTypeName(val: Value) []const u8 {
        return switch (val) {
            .null_val => "null",
            .bool_val => "boolean",
            .int, .float, .big_number => "number",
            .string => "string",
            .array => "array",
            .object => "object",
        };
    }

    /// True if `val` is a JSON number (int, float, or big_number).
    fn isNumber(val: Value) bool {
        return switch (val) {
            .int, .float, .big_number => true,
            else => false,
        };
    }

    /// True if `val` is a number whose value is exactly zero.  Used to decide
    /// whether to append jq's "because the divisor is zero" tail to a
    /// divmod-type-error message.
    fn isNumericZero(val: Value) bool {
        return switch (val) {
            .int => |i| i == 0,
            .float => |f| f == 0.0,
            else => false,
        };
    }

    /// Set `type_error_detail` for a binary-arithmetic operand-type or
    /// divisor-zero failure and return `error.TypeError`.  Single canonical
    /// formatter for the entire binary-arith error class — see
    /// `TypeErrorKind.binary_arith`.  Used by `doSub`/`doDiv`/`doMod`.
    fn raiseBinaryArithTypeError(
        it: *ResultIterator,
        left: StackValue,
        right: StackValue,
        op: BinaryArithOp,
    ) ZqError {
        const lhs = stackValueToValue(left) catch return error.TypeError;
        const rhs = stackValueToValue(right) catch return error.TypeError;
        it.type_error_detail = it.buildTypeErrorMsg(
            .null_val,
            .{ .binary_arith = .{ .lhs = lhs, .rhs = rhs, .op = op } },
        );
        return error.TypeError;
    }

    /// Build a jq-compatible TypeError detail message.
    /// The string is interned in the runtime tape so it lives as long as the
    /// iterator.  Returns `null` on allocation failure (caller silently omits
    /// detail — the error is still raised).
    fn buildTypeErrorMsg(it: *ResultIterator, val: Value, kind: TypeErrorKind) ?Value {
        const type_name = switch (val) {
            .null_val => "null",
            .bool_val => |b| if (b) "boolean (true)" else "boolean (false)",
            .int => "number",
            .float => "number",
            .big_number => "number",
            .string => "string",
            .array => "array",
            .object => "object",
        };
        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        switch (kind) {
            .index_string => |key| {
                buf.appendSlice(it.alloc, "Cannot index ") catch return null;
                buf.appendSlice(it.alloc, type_name) catch return null;
                buf.appendSlice(it.alloc, " with string (\"") catch return null;
                buf.appendSlice(it.alloc, key) catch return null;
                buf.appendSlice(it.alloc, "\")") catch return null;
            },
            .index_number => {
                buf.appendSlice(it.alloc, "Cannot index ") catch return null;
                buf.appendSlice(it.alloc, type_name) catch return null;
                buf.appendSlice(it.alloc, " with number") catch return null;
            },
            .index_number_val => |n| {
                buf.appendSlice(it.alloc, "Cannot index ") catch return null;
                buf.appendSlice(it.alloc, type_name) catch return null;
                buf.appendSlice(it.alloc, " with number (") catch return null;
                var num_buf: [32]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch return null;
                buf.appendSlice(it.alloc, num_str) catch return null;
                buf.appendSlice(it.alloc, ")") catch return null;
            },
            .index_number_float => |f| {
                buf.appendSlice(it.alloc, "Cannot index ") catch return null;
                buf.appendSlice(it.alloc, type_name) catch return null;
                buf.appendSlice(it.alloc, " with number (") catch return null;
                appendCompactJsonTrunc(&buf, it.alloc, .{ .float = f }) catch return null;
                buf.appendSlice(it.alloc, ")") catch return null;
            },
            .iterate => {
                buf.appendSlice(it.alloc, "Cannot iterate over ") catch return null;
                buf.appendSlice(it.alloc, type_name) catch return null;
                buf.appendSlice(it.alloc, " (") catch return null;
                appendCompactJsonTrunc(&buf, it.alloc, val) catch return null;
                buf.appendSlice(it.alloc, ")") catch return null;
            },
            .negate => {
                buf.appendSlice(it.alloc, baseTypeName(val)) catch return null;
                buf.appendSlice(it.alloc, " (") catch return null;
                appendCompactJsonTrunc(&buf, it.alloc, val) catch return null;
                buf.appendSlice(it.alloc, ") cannot be negated") catch return null;
            },
            .binary_arith => |ba| {
                buf.appendSlice(it.alloc, baseTypeName(ba.lhs)) catch return null;
                buf.appendSlice(it.alloc, " (") catch return null;
                appendCompactJsonTrunc(&buf, it.alloc, ba.lhs) catch return null;
                buf.appendSlice(it.alloc, ") and ") catch return null;
                buf.appendSlice(it.alloc, baseTypeName(ba.rhs)) catch return null;
                buf.appendSlice(it.alloc, " (") catch return null;
                appendCompactJsonTrunc(&buf, it.alloc, ba.rhs) catch return null;
                buf.appendSlice(it.alloc, ") cannot be ") catch return null;
                buf.appendSlice(it.alloc, switch (ba.op) {
                    .add => "added",
                    .subtract => "subtracted",
                    .multiply => "multiplied",
                    .divide, .modulo => "divided",
                }) catch return null;
                if (ba.op == .modulo) buf.appendSlice(it.alloc, " (remainder)") catch return null;
                // jq only appends "because the divisor is zero" when both
                // operands are numeric and the divisor is zero — otherwise
                // the type-mismatch is the primary cause of the error.
                if ((ba.op == .divide or ba.op == .modulo) and isNumber(ba.lhs) and isNumericZero(ba.rhs)) {
                    buf.appendSlice(it.alloc, " because the divisor is zero") catch return null;
                }
            },
            .setpath_index => |sp| {
                buf.appendSlice(it.alloc, "Cannot index ") catch return null;
                buf.appendSlice(it.alloc, baseTypeName(sp.base)) catch return null;
                buf.appendSlice(it.alloc, " with ") catch return null;
                buf.appendSlice(it.alloc, sp.pc_type) catch return null;
            },
            .setpath_slice => {
                buf.appendSlice(it.alloc, "Array/string slice indices must be integers") catch return null;
            },
        }
        // Store in the runtime tape so the string lives as long as the iterator.
        // Note: callers must access this value before the iterator is deinitialized.
        const str_ref = it.runtime_tape.internString(it.alloc, buf.items) catch return null;
        return .{ .string = it.rtString(str_ref) };
    }

    /// Helper: raise a UserError with a message string.
    fn raiseUserError(it: *ResultIterator, msg: []const u8) ZqError!?StackValue {
        const str_ref = try it.runtime_tape.internString(it.alloc, msg);
        it.user_error_msg = .{ .string = it.rtString(str_ref) };
        return error.UserError;
    }

    /// Set `user_error_msg` to jq's path-expression error, dispatching on
    /// the innermost PathFrame's break_kind for the correct diagnostic:
    ///   generic  → "Invalid path expression with result <result>"
    ///   index_n  → "Invalid path expression near attempt to access element <N> of <src>"
    ///   key_s    → "Invalid path expression near attempt to access element \"<k>\" of <src>"
    ///   iterate  → "Invalid path expression near attempt to iterate through <src>"
    /// `result` is the body's final value (used only for the generic case).
    /// Caller returns `error.UserError`.
    fn raisePathExprError(it: *ResultIterator, result: Value) ZqError!void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        const frame = if (it.path_stack.items.len > 0)
            &it.path_stack.items[it.path_stack.items.len - 1]
        else
            null;
        const kind: PathBreakKind = if (frame) |f| f.break_kind else .generic;
        switch (kind) {
            .generic => {
                try buf.appendSlice(it.alloc, "Invalid path expression with result ");
                try serializeValueCompact(&buf, it.alloc, result);
            },
            .index_n => {
                const src = if (frame) |f| f.break_source else result;
                const idx = if (frame) |f| f.break_index_n else 0;
                try buf.appendSlice(it.alloc, "Invalid path expression near attempt to access element ");
                var idx_buf: [32]u8 = undefined;
                const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{idx}) catch unreachable;
                try buf.appendSlice(it.alloc, idx_str);
                try buf.appendSlice(it.alloc, " of ");
                try serializeValueCompact(&buf, it.alloc, src);
            },
            .key_s => {
                const src = if (frame) |f| f.break_source else result;
                const key = if (frame) |f| f.break_key_s else "";
                try buf.appendSlice(it.alloc, "Invalid path expression near attempt to access element \"");
                try buf.appendSlice(it.alloc, key);
                try buf.appendSlice(it.alloc, "\" of ");
                try serializeValueCompact(&buf, it.alloc, src);
            },
            .iterate => {
                const src = if (frame) |f| f.break_source else result;
                try buf.appendSlice(it.alloc, "Invalid path expression near attempt to iterate through ");
                try serializeValueCompact(&buf, it.alloc, src);
            },
        }
        const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
        it.user_error_msg = .{ .string = it.rtString(str_ref) };
    }

    /// `startswith(str)`: test if string starts with prefix.
    fn builtinStartswith(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const arg = try stackValueToValue(arg_sv);
        const prefix = switch (arg) {
            .string => |sv| sv.slice(),
            else => return try it.raiseUserError("startswith() requires string inputs"),
        };
        const input = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return try it.raiseUserError("startswith() requires string inputs"),
        };
        return .{ .bool_val = std.mem.startsWith(u8, input, prefix) };
    }

    /// `endswith(str)`: test if string ends with suffix.
    fn builtinEndswith(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const arg = try stackValueToValue(arg_sv);
        const suffix = switch (arg) {
            .string => |sv| sv.slice(),
            else => return try it.raiseUserError("endswith() requires string inputs"),
        };
        const input = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return try it.raiseUserError("endswith() requires string inputs"),
        };
        return .{ .bool_val = std.mem.endsWith(u8, input, suffix) };
    }

    /// `ltrimstr(str)`: remove prefix if present.
    /// Re-intern the trimmed slice on the runtime tape so the returned
    /// StackValue does not alias the (possibly volatile) input view.
    fn builtinLtrimstr(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const arg = try stackValueToValue(arg_sv);
        const input_view: Value.StringView = switch (it.current) {
            .string => |sv| sv,
            else => return try it.raiseUserError("startswith() requires string inputs"),
        };
        const prefix = switch (arg) {
            .string => |sv| sv.slice(),
            else => return try it.raiseUserError("startswith() requires string inputs"),
        };
        const input = input_view.slice();
        if (std.mem.startsWith(u8, input, prefix)) {
            const ref = try it.runtime_tape.internString(it.alloc, input[prefix.len..]);
            return it.rtStringSV(ref);
        }
        return .{ .tape_value = .{ .string = input_view } };
    }

    /// `rtrimstr(str)`: remove suffix if present.
    fn builtinRtrimstr(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const arg = try stackValueToValue(arg_sv);
        const input_view: Value.StringView = switch (it.current) {
            .string => |sv| sv,
            else => return try it.raiseUserError("endswith() requires string inputs"),
        };
        const suffix = switch (arg) {
            .string => |sv| sv.slice(),
            else => return try it.raiseUserError("endswith() requires string inputs"),
        };
        const input = input_view.slice();
        if (suffix.len > 0 and std.mem.endsWith(u8, input, suffix)) {
            const ref = try it.runtime_tape.internString(it.alloc, input[0 .. input.len - suffix.len]);
            return it.rtStringSV(ref);
        }
        return .{ .tape_value = .{ .string = input_view } };
    }

    /// `trimstr(str)`: remove prefix and suffix if present.
    fn builtinTrimstr(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const arg = try stackValueToValue(arg_sv);
        const input_view: Value.StringView = switch (it.current) {
            .string => |sv| sv,
            else => return try it.raiseUserError("trimstr() requires string inputs"),
        };
        const affix = switch (arg) {
            .string => |sv| sv.slice(),
            else => return try it.raiseUserError("trimstr() requires string inputs"),
        };
        const input = input_view.slice();
        // Apply ltrimstr then rtrimstr
        const after_prefix = if (std.mem.startsWith(u8, input, affix))
            input[affix.len..]
        else
            input;
        if (affix.len > 0 and std.mem.endsWith(u8, after_prefix, affix)) {
            const ref = try it.runtime_tape.internString(it.alloc, after_prefix[0 .. after_prefix.len - affix.len]);
            return it.rtStringSV(ref);
        }
        if (after_prefix.ptr == input.ptr and after_prefix.len == input.len) {
            return .{ .tape_value = .{ .string = input_view } };
        }
        const ref = try it.runtime_tape.internString(it.alloc, after_prefix);
        return it.rtStringSV(ref);
    }

    // ── Regex fork-frame handle ownership ──────────────────────────────────
    //
    // Generator regex builtins (`scan`, `match(re;"g")`, `splits`) live as
    // fork frames that can remain suspended while the VM does arbitrary
    // work, including further dynamic-pattern compiles that evict the LRU
    // entry backing this frame. Borrowing the LRU's clone pointer is a UAF
    // waiting to happen.
    //
    // `ForkRegexHandles` is the staging struct: for dynamic patterns we
    // eagerly compile + clone a private pair; for pool-backed patterns we
    // keep the stable borrowed pointers. Callers move the `owned_*` fields
    // into the fork aux on frame push and null their local copy so the
    // `defer deinit` does not double-free.

    const ForkRegexHandles = struct {
        /// Borrowed pointer when pool-backed; aliases `&owned_clone.?` when
        /// dynamic. Always safe to call `clone.iterNext(...)` on.
        clone_ref: *regex_mod.RegexClone,
        /// Borrowed pointer when pool-backed; aliases `&owned_regex.?` when
        /// dynamic. Used for metadata (captureCount / groupName).
        regex_ref: *const regex_mod.Regex,
        owned_regex: ?regex_mod.Regex = null,
        owned_clone: ?regex_mod.RegexClone = null,

        fn clonePtr(self: *ForkRegexHandles) *regex_mod.RegexClone {
            if (self.owned_clone) |*oc| return oc;
            return self.clone_ref;
        }
        fn regexPtr(self: *const ForkRegexHandles) *const regex_mod.Regex {
            if (self.owned_regex) |*or_| return or_;
            return self.regex_ref;
        }
        fn deinit(self: *ForkRegexHandles) void {
            if (self.owned_clone) |*c| c.deinit();
            if (self.owned_regex) |*r| r.deinit();
            self.owned_clone = null;
            self.owned_regex = null;
        }
    };

    /// Resolve a fork-safe (regex, clone) pair for a generator regex builtin.
    /// Static-pool operands: borrow the iterator-owned clone + pool regex.
    /// Dynamic operands: consume the pattern from the stack, compile a fresh
    /// private `Regex`, clone it, and return both as owned handles on the
    /// returned struct — independent of the LRU entry.
    ///
    /// The caller MUST either move `owned_regex`/`owned_clone` into a fork
    /// aux (and set them to null on the returned struct) or call
    /// `handles.deinit()` to release them. The helper never leaks on its
    /// own error paths.
    fn buildRegexForkHandles(it: *ResultIterator, operand: i64) ZqError!ForkRegexHandles {
        if (!regex_mod.enabled) return it.regexError();
        it.last_dynamic_entry = null;
        const pool_index = types.regexPoolIndexOf(operand);
        if (pool_index != types.REGEX_POOL_DYNAMIC) {
            const clone = try it.resolveRegexClone(pool_index);
            const regex = try it.resolveRegexMetaForOperand(pool_index);
            return .{ .clone_ref = clone, .regex_ref = regex };
        }
        // Dynamic path: consume pattern from stack, compile a frame-private
        // Regex + RegexClone. The LRU's cached clone is intentionally NOT
        // used here — the frame must not alias cache-owned state.
        const pat_sv = try it.popValue();
        const pat_val = try stackValueToValue(pat_sv);
        const pat = switch (pat_val) {
            .string => |sv| sv.slice(),
            else => return error.TypeError,
        };

        var compiled = regex_mod.Regex.compile(pat) catch |e| return it.mapRegexError(e);
        errdefer compiled.deinit();
        var cloned = compiled.clone() catch |e| return it.mapRegexError(e);
        errdefer cloned.deinit();

        // Warm the LRU with the same pattern so subsequent non-fork
        // dynamic-path callers still amortize compile cost.
        _ = it.dynamic_regex_cache.getOrCompile(pat) catch |e| {
            // If the LRU warm-up fails (OOM), we still return the owned
            // handles — the fork itself is unaffected. Surface the error
            // so the caller can decide; but practically only OOM fires.
            return it.mapRegexError(e);
        };

        // Transfer into the returned handles struct. `owned_*` pointers
        // remain stable as long as the struct itself is not moved after
        // the caller embeds the owned fields into the fork aux.
        return .{
            .clone_ref = undefined, // unused when owned_* is set
            .regex_ref = undefined,
            .owned_regex = compiled,
            .owned_clone = cloned,
        };
    }

    // ── Regex builtins (real engine, Phase D) ──────────────────────────────
    //
    // Dispatch:
    //   - Fast path (literal pattern): operand's upper slot holds a pool index.
    //     `resolveRegexClone` lazy-initializes the per-worker clone on first
    //     use and returns a pointer into `regex_clones`.
    //   - Dynamic path (`test($var)` etc.): operand's upper slot is
    //     `REGEX_POOL_DYNAMIC`. The pattern was pushed by the slow compile
    //     path; pop it, look up in the LRU, compile on miss.
    //
    // When regex is disabled at build time the shim's types collapse to stubs
    // that return `error.RegexNotCompiled`; we pass that through as a clean
    // VM-level error with the shim's last message attached.

    /// Fetch a per-worker RegexClone for a filter-compile-time pool entry.
    /// Lazily clones on first use. Returned pointer is stable for this
    /// iterator's lifetime (owned by `regex_clones`).
    fn resolveRegexClone(it: *ResultIterator, pool_index: u32) ZqError!*regex_mod.RegexClone {
        if (!regex_mod.enabled) return it.regexError();
        const pool = it.regex_pool orelse return it.regexError();
        if (pool_index >= it.regex_clones.len) return it.regexError();
        if (it.regex_clones[pool_index]) |*existing| return existing;
        const base = pool.get(pool_index);
        const cloned = base.clone() catch |e| return it.mapRegexError(e);
        it.regex_clones[pool_index] = cloned;
        return &it.regex_clones[pool_index].?;
    }

    /// Resolve a regex clone from a packed operand. For dynamic operands the
    /// pattern is popped from the value stack and fed through the LRU cache.
    /// For pool operands the stack is NOT touched — Phase D compiler emits
    /// no push_string on the literal fast path.
    fn resolveRegexForOperand(it: *ResultIterator, operand: i64) ZqError!*regex_mod.RegexClone {
        it.last_dynamic_entry = null;
        const idx = types.regexPoolIndexOf(operand);
        if (idx != types.REGEX_POOL_DYNAMIC) return it.resolveRegexClone(idx);
        // Dynamic path: pattern is on the value stack.
        const pat_sv = try it.popValue();
        const pat_val = try stackValueToValue(pat_sv);
        const pat = switch (pat_val) {
            .string => |sv| sv.slice(),
            else => return error.TypeError,
        };
        const entry = try it.resolveDynamicRegex(pat);
        return entry.clone;
    }

    fn resolveDynamicRegex(it: *ResultIterator, pattern: []const u8) ZqError!regex_mod.cache.DynamicEntry {
        if (!regex_mod.enabled) return it.regexError();
        const entry = it.dynamic_regex_cache.getOrCompile(pattern) catch |e| return it.mapRegexError(e);
        it.last_dynamic_entry = entry;
        return entry;
    }

    /// Produce the appropriate ZqError for a regex failure in a given build:
    /// disabled builds raise `RegexNotCompiled` (feature not linked), enabled
    /// builds raise `RegexInternalError`. Detail for `RegexInternalError`
    /// lives on the shim's last-error TLS channel — the VM never synthesises
    /// a message of its own, so there is no parameter to surface.
    ///
    /// This function takes no arguments on purpose: a descriptive Zig-side
    /// message string would be dead weight (no surfacing path exists for it
    /// without crossing the shim boundary) and having one invites drift.
    /// If the call site has structural context that genuinely belongs in
    /// the user-facing error, route it via `type_error_detail` / a new
    /// detail channel instead of through this shim-error helper.
    fn regexError(it: *ResultIterator) ZqError {
        _ = it;
        if (comptime !regex_mod.enabled) return error.RegexNotCompiled;
        return error.RegexInternalError;
    }

    fn mapRegexError(it: *ResultIterator, e: regex_mod.Error) ZqError {
        _ = it;
        return switch (e) {
            regex_mod.Error.OutOfMemory => error.OutOfMemory,
            regex_mod.Error.RegexNotCompiled => error.RegexNotCompiled,
            regex_mod.Error.RegexCompileFailed => error.RegexCompileError,
            regex_mod.Error.RegexInternalError => error.RegexInternalError,
        };
    }

    /// `test(regex)`: bool — does the input match?
    ///
    /// With jq's `n` flag, zero-width matches do not count: we fall through
    /// to the captures path and report `true` only when some non-empty match
    /// exists in the input.
    fn builtinTest(it: *ResultIterator, operand: i64) ZqError!?StackValue {
        const clone = try it.resolveRegexForOperand(operand);
        const input = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return error.TypeError,
        };
        const n_flag = types.regexBuiltinNFlagOf(operand);
        if (!n_flag) {
            const matched = clone.isMatch(input) catch |e| return it.mapRegexError(e);
            return .{ .bool_val = matched };
        }
        // n-flag path: iterate until we find a non-empty match or exhaust.
        // One slot pair is enough — we only care about slots[0].
        var slot_buf: [1]regex_mod.MatchSlot = undefined;
        var cursor: usize = 0;
        while (true) {
            const got = clone.iterNext(input, &cursor, slot_buf[0..1]) catch |e| return it.mapRegexError(e);
            if (!got) return .{ .bool_val = false };
            if (slot_buf[0].end > slot_buf[0].start) return .{ .bool_val = true };
        }
    }

    /// `match(regex)`: full match-object (or raise TypeError if no match).
    ///
    /// With jq's `n` flag, zero-width matches are skipped. If the pattern has
    /// only zero-width matches (e.g. empty pattern, or every alternative is
    /// empty) jq emits **no output** — exit 0, empty stream — instead of
    /// raising. We mirror that by terminating the value stream via the same
    /// backtrack/ip-jump idiom used by empty-`range` and exhausted scanners.
    fn builtinMatch(it: *ResultIterator, operand: i64) ZqError!?StackValue {
        const clone = try it.resolveRegexForOperand(operand);
        const input_view: Value.StringView = switch (it.current) {
            .string => |sv| sv,
            else => return error.TypeError,
        };
        // For raw byte-level regex calls (isMatch / iterNext / findCaptures)
        // the haystack must be a stable []const u8 for the duration of the
        // call. Re-resolve through StringView and pass the slice. The slice
        // is only used INSIDE one regex call before the next intern, so it
        // remains valid. NIX-006 alias safety: callers passing the slice
        // into helpers that intern on runtime_tape thread `input_view`
        // through and re-resolve via `.slice()` after each intern.
        const input = input_view.slice();
        const pool_index = types.regexPoolIndexOf(operand);
        const regex = try it.resolveRegexMetaForOperand(pool_index);
        const n_slots = regex.captureCount();
        // Allocate at least 1 slot so that slot 0 (overall match span) is
        // always readable even for zero-capture patterns (captureCount() == 0
        // in a disabled-regex build; guarded() returning 0 on a NULL handle).
        const slots_buf = try it.scratch.allocator().alloc(regex_mod.MatchSlot, @max(n_slots, 1));
        const n_flag = types.regexBuiltinNFlagOf(operand);
        if (!n_flag) {
            const matched = clone.findCaptures(input, 0, slots_buf) catch |e| return it.mapRegexError(e);
            if (!matched) return error.TypeError;
            return try it.buildMatchObject(regex, input_view, slots_buf);
        }
        // n-flag path: iterate until a non-empty overall match lands. If the
        // iterator exhausts without one (only zero-width hits, or none at
        // all) jq outputs nothing and exits cleanly — surface the same by
        // terminating the value stream rather than raising TypeError.
        var cursor: usize = 0;
        while (true) {
            const input_iter = input_view.slice();
            const got = clone.iterNext(input_iter, &cursor, slots_buf) catch |e| return it.mapRegexError(e);
            if (!got) {
                if (!(try it.doBacktrack())) it.ip = @intCast(it.instructions.len);
                return null;
            }
            if (slots_buf[0].end > slots_buf[0].start) {
                return try it.buildMatchObject(regex, input_view, slots_buf);
            }
        }
    }

    /// Resolve the shared compiled `Regex` (for metadata like captureCount and
    /// groupName) corresponding to an operand's pool index. The dynamic-path
    /// case piggy-backs on the LRU entry stashed by `resolveRegexForOperand`.
    fn resolveRegexMetaForOperand(it: *ResultIterator, pool_index: u32) ZqError!*const regex_mod.Regex {
        if (pool_index != types.REGEX_POOL_DYNAMIC) {
            const pool = it.regex_pool orelse return it.regexError();
            if (pool_index >= pool.len()) return it.regexError();
            return pool.get(pool_index);
        }
        const entry = it.last_dynamic_entry orelse return it.regexError();
        return entry.regex;
    }

    /// `capture(regex)`: jq — object of NAMED groups only. Raises on no match.
    ///
    /// With jq's `n` flag, zero-width overall matches are skipped — see
    /// `builtinMatch`'s doc comment for the precise semantics. Same
    /// empty-stream termination rule applies when only zero-width matches
    /// exist.
    fn builtinCapture(it: *ResultIterator, operand: i64) ZqError!?StackValue {
        const clone = try it.resolveRegexForOperand(operand);
        const input_view: Value.StringView = switch (it.current) {
            .string => |sv| sv,
            else => return error.TypeError,
        };
        const input = input_view.slice();
        const pool_index = types.regexPoolIndexOf(operand);
        const regex = try it.resolveRegexMetaForOperand(pool_index);
        const n_slots = regex.captureCount();
        const slots_buf = try it.scratch.allocator().alloc(regex_mod.MatchSlot, @max(n_slots, 1));
        const n_flag = types.regexBuiltinNFlagOf(operand);
        if (!n_flag) {
            const matched = clone.findCaptures(input, 0, slots_buf) catch |e| return it.mapRegexError(e);
            if (!matched) return error.TypeError;
            return try it.buildCaptureObject(regex, input_view, slots_buf);
        }
        var cursor: usize = 0;
        while (true) {
            const input_iter = input_view.slice();
            const got = clone.iterNext(input_iter, &cursor, slots_buf) catch |e| return it.mapRegexError(e);
            if (!got) {
                if (!(try it.doBacktrack())) it.ip = @intCast(it.instructions.len);
                return null;
            }
            if (slots_buf[0].end > slots_buf[0].start) {
                return try it.buildCaptureObject(regex, input_view, slots_buf);
            }
        }
    }

    /// `sub(pattern; replacement)`: first-match replacement. Replacement
    /// supports `\1..\9` numeric backrefs and `\g<name>` named backrefs.
    fn builtinSub(it: *ResultIterator, operand: i64) ZqError!?StackValue {
        return try it.builtinSubImpl(operand, false);
    }

    /// `gsub(pattern; replacement)`: all-match replacement. Same backref
    /// syntax as `sub`.
    fn builtinGsub(it: *ResultIterator, operand: i64) ZqError!?StackValue {
        return try it.builtinSubImpl(operand, true);
    }

    /// `sub(pattern; replacement)` / `gsub(pattern; replacement)` — NIX-004.
    ///
    /// jq strict semantics: the replacement is a *filter expression*,
    /// re-evaluated for each match with `.` rebound to the captures object
    /// (named groups only; unmatched optional names → null; unnamed groups
    /// omitted). Cartesian generator-in-repl: if the replacement filter
    /// produces K outputs per match, this builtin emits K final strings,
    /// where output i = concat of (gap, branch_i_repl) across all matches
    /// followed by the trailing tail.
    ///
    /// Bytecode shape (set by `emit.zig` `.regex2` arm for `.sub_`/`.gsub_`):
    ///
    ///   [pat-eval]                ; dynamic only — pat on value_stack
    ///   call_builtin(sub_|gsub_)  ; this function. ip auto-advances to →
    ///   jump <exit_ip>            ; skip body at top level
    ///   <repl bytecode>           ; body — invoked per match, `.` = captures
    ///   exit_ip: <next instr>
    ///
    /// We read the trailing `jump`'s operand to discover the body IP range
    /// and re-enter that range per match via `runReplacementBody`. The K==1
    /// hot path returns one StackValue (legacy shape preserved). The K>1
    /// generator path push-yields the first string and parks remaining
    /// `Tape.StringRef`s on a fork frame (`ForkAux.sub_gen`), each released
    /// on backtrack via `advanceSubGenForkpoint`.
    fn builtinSubImpl(it: *ResultIterator, operand: i64, global: bool) ZqError!?StackValue {
        // SSOT for body IP range: the trailing `jump exit_ip` opcode
        // immediately after `call_builtin`. Emit guarantees this shape.
        std.debug.assert(it.ip + 1 < it.instructions.len);
        std.debug.assert(it.instructions[it.ip + 1].op == .jump);
        const exit_ip: u32 = @intCast(it.instructions[it.ip + 1].operand.index);
        const body_start: u32 = it.ip + 2;
        const body_end: u32 = exit_ip;

        // Dynamic pattern: pop pat from value_stack and compile/cache.
        // Literal pattern: pool supplies regex.
        const clone = try it.resolveRegexForOperand(operand);
        const input_view: Value.StringView = switch (it.current) {
            .string => |sv| sv,
            else => return error.TypeError,
        };
        // NIX-006: input_view is a tape-relative reference; we re-resolve
        // via `.slice()` after every operation that may grow
        // runtime_tape.string_buf (interns inside buildCaptureObject and
        // body intermediates). Each call to `clone.iterNext(input, ...)`
        // sees a fresh resolution so the regex engine never sees a stale
        // pointer.
        const pool_index = types.regexPoolIndexOf(operand);
        const regex = try it.resolveRegexMetaForOperand(pool_index);
        const n_slots = regex.captureCount();
        const slots_buf = try it.scratch.allocator().alloc(regex_mod.MatchSlot, @max(n_slots, 1));
        const n_flag = types.regexBuiltinNFlagOf(operand);

        // Per-branch output accumulators. `branches` grows monotonically as
        // matches with K outputs are seen — each accumulator is one final
        // gsub/sub output. Allocator is the iterator's GPA; deinit on exit.
        var branches = std.ArrayList(std.ArrayList(u8)){};
        defer {
            for (branches.items) |*b| b.deinit(it.alloc);
            branches.deinit(it.alloc);
        }

        // Per-match scratch: capture-object outputs are accumulated into
        // a small list. Lives in iterator GPA, deinit per iteration.
        var match_outputs = std.ArrayList(Tape.StringRef){};
        defer match_outputs.deinit(it.alloc);

        var cursor: usize = 0;
        var prev_end: usize = 0;
        while (true) {
            // Re-resolve input freshly: the previous iteration may have grown
            // runtime_tape.string_buf (NIX-006 alias safety).
            const input_iter = input_view.slice();
            const got = clone.iterNext(input_iter, &cursor, slots_buf) catch |e| return it.mapRegexError(e);
            if (!got) break;
            const m_start = slots_buf[0].start;
            const m_end = slots_buf[0].end;
            // jq `n` flag: zero-width matches are no-ops (no replacement at
            // that position). iterNext has advanced the cursor; loop makes
            // forward progress.
            if (n_flag and m_end == m_start) continue;

            // Snapshot runtime_tape so per-match captures/body-intermediate
            // entries are released after we've extracted the body's outputs.
            // Output strings extracted as StringRefs (offset+len), NOT raw
            // []const u8, so they survive subsequent string_buf growth.
            const entries_pre: u32 = @intCast(it.runtime_tape.entries.items.len);
            const string_buf_pre: u32 = @intCast(it.runtime_tape.string_buf.items.len);
            // On any error path between snapshot and the success-path
            // truncation below (body raises TypeError, branch alloc OOM,
            // etc.) restore the tape so per-match captures + intermediates
            // don't leak into subsequent records' tape.
            errdefer {
                it.runtime_tape.entries.items.len = entries_pre;
                it.runtime_tape.string_buf.items.len = string_buf_pre;
                it.runtime_tape.refreshView();
            }

            // Snapshot the gap NOW (before captures-object interns relocate
            // string_buf) into a per-iteration scratch buffer, so subsequent
            // intern/grow operations cannot dangle it.
            const gap_src = input_view.slice()[prev_end..m_start];
            const gap_copy = try it.scratch.allocator().dupe(u8, gap_src);

            // Build {<named groups...>} captures-object on runtime_tape.
            const captures_sv = try it.buildCaptureObject(regex, input_view, slots_buf);
            const captures = try stackValueToValue(captures_sv);

            // Run replacement body with `.` = captures-object. Collect ALL
            // outputs as StringRefs (live in runtime_tape.string_buf). Null
            // outputs coerce to "" (jq parity); non-string raises TypeError
            // (jq parity via concat). Generator-in-repl yields K StringRefs.
            match_outputs.clearRetainingCapacity();
            try it.runReplacementBody(captures, body_start, body_end, &match_outputs);

            // Extend per-branch accumulators with this match's gap + insert.
            // Match k contributes to branches [0..match_outputs.len). Slots
            // already populated in earlier matches but missing this match
            // are not extended — mirrors jq's `def gsub` reduce shape (a
            // newly-arriving branch slot starts from null and concatenates
            // forward; an absent slot for this match keeps its content).
            //
            // Common case (1 match output): exactly 1 branch ever; this is
            // a single concat per match, the optimal path.
            for (match_outputs.items, 0..) |sref, i| {
                if (i >= branches.items.len) {
                    try branches.append(it.alloc, .{});
                }
                // Resolve StringRef NOW, before any further runtime_tape
                // growth invalidates string_buf backing.
                const slice = it.runtime_tape.view.string_buf[sref.offset..][0..sref.len];
                try branches.items[i].appendSlice(it.alloc, gap_copy);
                try branches.items[i].appendSlice(it.alloc, slice);
            }

            // Release per-match captures + body intermediates. Final
            // accumulators in `branches` already hold copies; safe to drop.
            it.runtime_tape.entries.items.len = entries_pre;
            it.runtime_tape.string_buf.items.len = string_buf_pre;
            it.runtime_tape.refreshView();

            prev_end = m_end;
            if (!global) break;
        }

        // Trailing tail appended to every branch. Snapshot to scratch so
        // subsequent runtime_tape.string_buf grows (the per-branch concat
        // intern below) cannot dangle it.
        const tail_src = input_view.slice()[prev_end..];
        const tail = try it.scratch.allocator().dupe(u8, tail_src);

        // Edge case: zero matches. Mirror legacy: yield input unchanged.
        if (branches.items.len == 0) {
            const ref = try it.runtime_tape.internString(it.alloc, input_view.slice());
            return it.rtStringSV(ref);
        }

        // Intern each branch into runtime_tape via alias-safe concat.
        // We pre-allocate a scratch slice of StringRefs for the K>1
        // fork-frame yield queue.
        var refs = try it.scratch.allocator().alloc(Tape.StringRef, branches.items.len);
        for (branches.items, 0..) |b, i| {
            // internStringConcat is alias-safe even though our parts come
            // from a separate ArrayList — required by NIX-003 SSOT (one
            // contiguous alloc, snapshot-resolve aliasing).
            refs[i] = try it.runtime_tape.internStringConcat(it.alloc, &.{ b.items, tail });
        }

        // Hot path (K == 1): return single string, no fork frame needed.
        if (refs.len == 1) {
            const r = refs[0];
            return it.rtStringSV(r);
        }

        // Generator path (K > 1): push fork frame holding refs[1..]; return
        // refs[0]. Backtracks consume one ref per call via
        // `advanceSubGenForkpoint`. Storing StringRefs (not slices) keeps
        // the frame robust to string_buf growth across backtrack boundaries.
        const resume_ip = it.ip + 1; // re-enters the trailing `jump`, which jumps to exit_ip
        it.fork_stack.appendAssumeCapacity(.{
            .saved_value_stack_len = @intCast(it.value_stack.items.len),
            .saved_current = it.current,
            .saved_current_args = it.current_args,
            .saved_call_len = @intCast(it.call_stack.items.len),
            .backtrack_ip = resume_ip,
            .aux = .{ .sub_gen = .{
                .refs = refs,
                .index = 1,
            } },
            .saved_path = it.snapshotPathState(),
            .saved_stack = try it.snapshotValueStackForFork(),
            .saved_object = try it.snapshotObjectConstructState(),
        });
        const r0 = refs[0];
        return it.rtStringSV(r0);
    }

    /// Run the replacement body bytecode (`<repl>`) once with `.` rebound to
    /// `captures`, gathering ALL outputs as `Tape.StringRef`s in `out`.
    /// Mirrors `walkApplyBody`'s state save/restore but collects every yield
    /// (not just the first) so the cartesian generator-in-repl test
    /// (`gsub("a"; "x", "y")`) works.
    ///
    /// Per-output policy:
    ///   - `null`     → coerced to empty string (jq parity).
    ///   - `string`   → interned via `internString` (alias-safe).
    ///   - other      → `error.TypeError` (jq surfaces this via concat).
    fn runReplacementBody(
        it: *ResultIterator,
        captures: Value,
        body_start: u32,
        body_end: u32,
        out: *std.ArrayList(Tape.StringRef),
    ) ZqError!void {
        const saved_ip = it.ip;
        const saved_current = it.current;
        const saved_input = it.input_value;
        const saved_value_len: u32 = @intCast(it.value_stack.items.len);
        const saved_if_len: u32 = @intCast(it.if_stack.items.len);
        const saved_fork_len: u32 = @intCast(it.fork_stack.items.len);
        const saved_collect_len: u32 = @intCast(it.collect_stack.items.len);
        const saved_path_len: u32 = @intCast(it.path_stack.items.len);

        it.current = captures;
        it.input_value = captures;
        it.ip = body_start;

        // Sub-execution loop — collect ALL outputs the body produces. The
        // body emits one "output" per *fall-through to body_end*: the value
        // sitting on value_stack (or `it.current` if stack is empty). After
        // capturing, we backtrack to any fork the body opened (e.g. comma's
        // generator fork) and re-run from there to obtain the next output.
        // Loop terminates when no fork above saved_fork_len remains.
        //
        // Errors during body execution route through `handleError`; an
        // unrecoverable error is rolled back and propagated, mirroring
        // walkApplyBody.
        while (true) {
            // Inner loop: drive instructions until the body's exit point or
            // an instruction-emit yields (path-emitting builtins).
            while (it.ip < it.instructions.len and it.ip != body_end) {
                const body_instr = it.instructions[it.ip];
                if (it.execOne(body_instr)) |maybe_val| {
                    if (maybe_val) |v| {
                        // Path-emitting builtin yielded. Capture and continue.
                        try collectReplacementOutput(it, v, out);
                        if (it.fork_stack.items.len > saved_fork_len) {
                            if (try it.backtrackToDepth(saved_fork_len)) {
                                break; // re-enter inner loop after backtrack
                            }
                        }
                        // No fork to drive — drop out cleanly.
                        it.ip = body_end;
                        break;
                    }
                } else |err| {
                    if (!(try it.handleError(err))) {
                        it.ip = saved_ip;
                        it.current = saved_current;
                        it.input_value = saved_input;
                        it.value_stack.items.len = saved_value_len;
                        it.if_stack.items.len = saved_if_len;
                        it.if_path_comps_stack.items.len = saved_if_len;
                        while (it.collect_stack.items.len > saved_collect_len) {
                            var cf = it.collect_stack.pop().?;
                            cf.buffer.deinit(it.alloc);
                        }
                        it.truncateForkStack(saved_fork_len);
                        while (it.path_stack.items.len > saved_path_len) {
                            var pf = it.path_stack.pop().?;
                            pf.deinit(it.alloc);
                        }
                        return err;
                    }
                    if (it.done) {
                        it.ip = body_end;
                        break;
                    }
                }
            }

            // Body reached its exit (or fell off the instruction stream).
            // Capture the trailing output: top-of-value_stack if the body
            // pushed one, else `it.current` (jq's "the value IS the output"
            // shape). Pop the stack so the next iteration starts clean.
            if (it.ip == body_end or it.ip >= it.instructions.len) {
                if (it.value_stack.items.len > saved_value_len) {
                    const v = try stackValueToValue(try it.popValue());
                    try collectReplacementOutput(it, v, out);
                } else {
                    try collectReplacementOutput(it, it.current, out);
                }
            }
            // else: inner loop exited via path-emit branch — output already
            // captured there; just continue the outer loop.

            // Drive the next output via the body's own fork stack.
            if (it.fork_stack.items.len > saved_fork_len) {
                if (try it.backtrackToDepth(saved_fork_len)) continue;
            }
            break;
        }

        // Cleanup any residual state opened by the body.
        while (it.collect_stack.items.len > saved_collect_len) {
            var cf = it.collect_stack.pop().?;
            cf.buffer.deinit(it.alloc);
        }
        it.truncateForkStack(saved_fork_len);
        it.if_stack.items.len = saved_if_len;
        it.if_path_comps_stack.items.len = saved_if_len;
        it.value_stack.items.len = saved_value_len;
        while (it.path_stack.items.len > saved_path_len) {
            var pf = it.path_stack.pop().?;
            pf.deinit(it.alloc);
        }

        it.ip = saved_ip;
        it.current = saved_current;
        it.input_value = saved_input;
        it.done = false;
    }

    /// Coerce a replacement-body output value to a `Tape.StringRef` and
    /// append to `out`. Null → empty string; non-string → TypeError.
    fn collectReplacementOutput(
        it: *ResultIterator,
        v: Value,
        out: *std.ArrayList(Tape.StringRef),
    ) ZqError!void {
        const ref: Tape.StringRef = switch (v) {
            .string => |sv| try it.runtime_tape.internString(it.alloc, sv.slice()),
            .null_val => try it.runtime_tape.internString(it.alloc, ""),
            else => return error.TypeError,
        };
        try out.append(it.alloc, ref);
    }

    /// `scan(pattern)`: generator. See header comment above for integration.
    ///
    /// Dynamic-pattern forks: build a fresh private `Regex` + `RegexClone`
    /// for the frame. Without this the frame would borrow the clone pointer
    /// from an LRU entry that can evict while the fork is suspended; the
    /// LRU is strictly an amortization layer for pattern compile and does
    /// not participate in fork-frame lifetime.
    fn builtinScan(it: *ResultIterator, operand: i64) ZqError!?StackValue {
        const input_view: Value.StringView = switch (it.current) {
            .string => |sv| sv,
            else => return error.TypeError,
        };
        // NIX-006: the fork frame stashes `hay` and reuses it across yields.
        // Snapshot the input bytes onto scratch (which lives for the whole
        // record) so subsequent runtime_tape.string_buf grows cannot dangle
        // the fork-frame's cached pointer.
        const input = try it.scratch.allocator().dupe(u8, input_view.slice());
        var handles = try it.buildRegexForkHandles(operand);
        var handles_transferred = false;
        defer if (!handles_transferred) handles.deinit();

        const n_slots = handles.regexPtr().captureCount();
        const has_user_captures = n_slots > 1;
        const slots_buf = try it.scratch.allocator().alloc(regex_mod.MatchSlot, @max(n_slots, 1));
        const n_flag = types.regexBuiltinNFlagOf(operand);
        var cursor: usize = 0;
        // Draw matches until we find one the caller wants to see. With the
        // jq `n` flag that skips zero-width matches; without it we take the
        // first match as-is. iterNext advances past empty matches by +1 so
        // the loop always terminates.
        const got = blk: {
            while (true) {
                const ok = handles.clonePtr().iterNext(input, &cursor, slots_buf) catch |e| {
                    return it.mapRegexError(e);
                };
                if (!ok) break :blk false;
                if (!n_flag or slots_buf[0].end > slots_buf[0].start) break :blk true;
            }
        };
        if (!got) {
            if (!(try it.doBacktrack())) it.ip = @intCast(it.instructions.len);
            return null;
        }
        // First match succeeded. Push fork frame; build the yield value; set current.
        const resume_ip = it.ip + 1;
        it.fork_stack.appendAssumeCapacity(.{
            .saved_value_stack_len = @intCast(it.value_stack.items.len),
            .saved_current = it.current,
            .saved_current_args = it.current_args,
            .saved_call_len = @intCast(it.call_stack.items.len),
            .backtrack_ip = resume_ip,
            .aux = .{ .scan = .{
                .clone = handles.clonePtr(),
                .owned_regex = handles.owned_regex,
                .owned_clone = handles.owned_clone,
                .hay = input,
                .cursor = cursor,
                .slots = slots_buf,
                .has_user_captures = has_user_captures,
                .n_flag = n_flag,
            } },
            .saved_path = it.snapshotPathState(),
            .saved_stack = try it.snapshotValueStackForFork(),
            .saved_object = try it.snapshotObjectConstructState(),
        });
        handles_transferred = true;

        // Re-point `clone` into the aux-owned copy so later backtracks (and
        // the very first advance) use the stable storage on the frame, not
        // the address of the now-expired local.
        const st = &it.fork_stack.items[it.fork_stack.items.len - 1].aux.scan;
        if (st.owned_clone) |*oc| st.clone = oc;

        const yield_sv = try it.buildScanYield(st.slots, input, has_user_captures);
        it.current = try stackValueToValue(yield_sv);
        it.ip = resume_ip;
        return null;
    }

    /// Called from backtrackToDepth on a `.scan` frame. Advances the cursor
    /// to the next match; returns true if found (it.current set), false if
    /// exhausted (caller will pop the frame).
    fn advanceScanForkpoint(it: *ResultIterator, fp: *Forkpoint) ZqError!bool {
        var st = &fp.aux.scan;
        while (true) {
            const got = st.clone.iterNext(st.hay, &st.cursor, st.slots) catch |e| return it.mapRegexError(e);
            if (!got) return false;
            // jq `n`: skip zero-width overall matches on every advance.
            if (st.n_flag and st.slots[0].end == st.slots[0].start) continue;
            const yield_sv = try it.buildScanYield(st.slots, st.hay, st.has_user_captures);
            it.current = try stackValueToValue(yield_sv);
            return true;
        }
    }

    /// `match(pattern; "g")`: generator — one match object per non-overlapping
    /// occurrence. Shape mirrors `match(pattern)`: `{offset, length, string,
    /// captures: [...]}` with character-count offsets.
    ///
    /// Dynamic-pattern ownership mirrors `builtinScan`: frame owns its own
    /// (Regex, Clone) pair so the LRU cannot dangle it via eviction.
    fn builtinMatchG(it: *ResultIterator, operand: i64) ZqError!?StackValue {
        const input_view: Value.StringView = switch (it.current) {
            .string => |sv| sv,
            else => return error.TypeError,
        };
        // Fork-frame `hay` must remain valid across backtracks, possibly
        // through arbitrary runtime_tape interns. Snapshot to scratch (which
        // outlives the iterator). NIX-006: replaces stabilizeAgainstStringBuf.
        const input = try it.scratch.allocator().dupe(u8, input_view.slice());
        var handles = try it.buildRegexForkHandles(operand);
        var handles_transferred = false;
        defer if (!handles_transferred) handles.deinit();

        const n_slots = handles.regexPtr().captureCount();
        const slots_buf = try it.scratch.allocator().alloc(regex_mod.MatchSlot, @max(n_slots, 1));
        const n_flag = types.regexBuiltinNFlagOf(operand);
        var cursor: usize = 0;
        const got = blk: {
            while (true) {
                const ok = handles.clonePtr().iterNext(input, &cursor, slots_buf) catch |e| {
                    return it.mapRegexError(e);
                };
                if (!ok) break :blk false;
                if (!n_flag or slots_buf[0].end > slots_buf[0].start) break :blk true;
            }
        };
        if (!got) {
            if (!(try it.doBacktrack())) it.ip = @intCast(it.instructions.len);
            return null;
        }
        const resume_ip = it.ip + 1;
        it.fork_stack.appendAssumeCapacity(.{
            .saved_value_stack_len = @intCast(it.value_stack.items.len),
            .saved_current = it.current,
            .saved_current_args = it.current_args,
            .saved_call_len = @intCast(it.call_stack.items.len),
            .backtrack_ip = resume_ip,
            .aux = .{ .match_g = .{
                .clone = handles.clonePtr(),
                .regex = handles.regexPtr(),
                .owned_regex = handles.owned_regex,
                .owned_clone = handles.owned_clone,
                .hay = input,
                .cursor = cursor,
                .slots = slots_buf,
                .n_flag = n_flag,
            } },
            .saved_path = it.snapshotPathState(),
            .saved_stack = try it.snapshotValueStackForFork(),
            .saved_object = try it.snapshotObjectConstructState(),
        });
        handles_transferred = true;

        const st = &it.fork_stack.items[it.fork_stack.items.len - 1].aux.match_g;
        if (st.owned_clone) |*oc| st.clone = oc;
        if (st.owned_regex) |*or_| st.regex = or_;

        const yield_sv = try it.buildMatchObject(st.regex, Value.StringView.fromExternal(input), st.slots);
        it.current = try stackValueToValue(yield_sv);
        it.ip = resume_ip;
        return null;
    }

    fn advanceMatchGForkpoint(it: *ResultIterator, fp: *Forkpoint) ZqError!bool {
        var st = &fp.aux.match_g;
        while (true) {
            const got = st.clone.iterNext(st.hay, &st.cursor, st.slots) catch |e| return it.mapRegexError(e);
            if (!got) return false;
            if (st.n_flag and st.slots[0].end == st.slots[0].start) continue;
            const yield_sv = try it.buildMatchObject(st.regex, Value.StringView.fromExternal(st.hay), st.slots);
            it.current = try stackValueToValue(yield_sv);
            return true;
        }
    }

    /// `splits(pattern; flags)`: generator — yields the input split into
    /// segments by the regex, mirroring jq's builtin. Like `scan` but yields
    /// the "between" pieces: the prefix before the first match, each
    /// inter-match gap, and the tail after the last match (including empty
    /// tails). Equivalent to `split` when the pattern is a literal.
    fn builtinSplits(it: *ResultIterator, operand: i64) ZqError!?StackValue {
        const input_view: Value.StringView = switch (it.current) {
            .string => |sv| sv,
            else => return error.TypeError,
        };
        // NIX-006: snapshot input to scratch — fork frames hold `hay` across
        // backtracks and arbitrary runtime_tape interns.
        const input = try it.scratch.allocator().dupe(u8, input_view.slice());
        var handles = try it.buildRegexForkHandles(operand);
        var handles_transferred = false;
        defer if (!handles_transferred) handles.deinit();

        const n_slots = handles.regexPtr().captureCount();
        const slots_buf = try it.scratch.allocator().alloc(regex_mod.MatchSlot, @max(n_slots, 1));
        const n_flag = types.regexBuiltinNFlagOf(operand);
        var cursor: usize = 0;
        const got = blk: {
            while (true) {
                const ok = handles.clonePtr().iterNext(input, &cursor, slots_buf) catch |e| {
                    return it.mapRegexError(e);
                };
                if (!ok) break :blk false;
                if (!n_flag or slots_buf[0].end > slots_buf[0].start) break :blk true;
            }
        };

        const resume_ip = it.ip + 1;

        if (!got) {
            // No matches: yield the input whole, then terminate on next backtrack.
            // handles defer frees owned pair automatically.
            const ref = try it.runtime_tape.internString(it.alloc, input);
            const whole_sv: StackValue = it.rtStringSV(ref);
            // Push a `normal` forkpoint so the single emitted value ends the
            // generator cleanly on backtrack — this matches scan's empty-case
            // shape without bypassing the fork stack.
            it.fork_stack.appendAssumeCapacity(.{
                .saved_value_stack_len = @intCast(it.value_stack.items.len),
                .saved_current = it.current,
                .saved_current_args = it.current_args,
                .saved_call_len = @intCast(it.call_stack.items.len),
                // Point past the instructions so backtracking pops the frame
                // and the loop sees no more work.
                .backtrack_ip = @intCast(it.instructions.len),
                .aux = .{ .normal = {} },
                .saved_path = it.snapshotPathState(),
                .saved_stack = try it.snapshotValueStackForFork(),
                .saved_object = try it.snapshotObjectConstructState(),
            });
            it.current = try stackValueToValue(whole_sv);
            it.ip = resume_ip;
            return null;
        }

        // First match found. Yield the prefix segment [0, slots[0].start).
        const seg_start: usize = 0;
        const seg_end: usize = slots_buf[0].start;
        const prev_end: usize = slots_buf[0].end;
        const seg_bytes = input[seg_start..seg_end];
        const ref = try it.runtime_tape.internString(it.alloc, seg_bytes);
        const seg_sv: StackValue = it.rtStringSV(ref);

        it.fork_stack.appendAssumeCapacity(.{
            .saved_value_stack_len = @intCast(it.value_stack.items.len),
            .saved_current = it.current,
            .saved_current_args = it.current_args,
            .saved_call_len = @intCast(it.call_stack.items.len),
            .backtrack_ip = resume_ip,
            .aux = .{ .splits = .{
                .clone = handles.clonePtr(),
                .owned_regex = handles.owned_regex,
                .owned_clone = handles.owned_clone,
                .hay = input,
                .cursor = cursor,
                .prev_end = prev_end,
                .slots = slots_buf,
                .tail_yielded = false,
                .n_flag = n_flag,
            } },
            .saved_path = it.snapshotPathState(),
            .saved_stack = try it.snapshotValueStackForFork(),
            .saved_object = try it.snapshotObjectConstructState(),
        });
        handles_transferred = true;

        const st = &it.fork_stack.items[it.fork_stack.items.len - 1].aux.splits;
        if (st.owned_clone) |*oc| st.clone = oc;

        it.current = try stackValueToValue(seg_sv);
        it.ip = resume_ip;
        return null;
    }

    fn advanceSplitsForkpoint(it: *ResultIterator, fp: *Forkpoint) ZqError!bool {
        var st = &fp.aux.splits;
        if (st.tail_yielded) return false;
        // Draw the next *emittable* match. With the jq `n` flag active,
        // zero-width matches don't split — skip them (cursor advances past
        // each via iterNext's internal +1 bump, guaranteeing progress).
        const got = blk: {
            while (true) {
                const ok = st.clone.iterNext(st.hay, &st.cursor, st.slots) catch |e| return it.mapRegexError(e);
                if (!ok) break :blk false;
                if (!st.n_flag or st.slots[0].end > st.slots[0].start) break :blk true;
            }
        };
        if (!got) {
            // Yield final tail segment [prev_end, input.len), then terminate.
            const bytes = st.hay[st.prev_end..st.hay.len];
            const ref = try it.runtime_tape.internString(it.alloc, bytes);
            const sv: StackValue = it.rtStringSV(ref);
            it.current = try stackValueToValue(sv);
            st.tail_yielded = true;
            return true;
        }
        // Inter-match segment [prev_end, slots[0].start).
        const seg_bytes = st.hay[st.prev_end..st.slots[0].start];
        const ref = try it.runtime_tape.internString(it.alloc, seg_bytes);
        const sv: StackValue = it.rtStringSV(ref);
        st.prev_end = st.slots[0].end;
        it.current = try stackValueToValue(sv);
        return true;
    }

    /// Build the value yielded by one scan iteration: a matched string when
    /// the pattern has no user-written capture groups, or an array of capture
    /// strings when it does. Mirrors jq's behavior exactly.
    fn buildScanYield(
        it: *ResultIterator,
        slots: []const regex_mod.MatchSlot,
        hay: []const u8,
        has_user_captures: bool,
    ) ZqError!StackValue {
        if (!has_user_captures) {
            const s = slots[0];
            const bytes = hay[s.start..s.end];
            const ref = try it.runtime_tape.internString(it.alloc, bytes);
            return it.rtStringSV(ref);
        }
        // Array of capture strings (indices 1..captureCount).
        const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });
        var i: usize = 1;
        while (i < slots.len) : (i += 1) {
            const s = slots[i];
            if (s.start == regex_mod.SLOT_UNMATCHED) {
                _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .null_val, .payload = .{ .none = {} } });
            } else {
                const bytes = hay[s.start..s.end];
                const ref = try it.runtime_tape.internString(it.alloc, bytes);
                _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .string, .payload = .{ .string = ref } });
            }
        }
        const arr_end = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[arr_start].payload.skip = arr_end + 1;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape.view,
            .start = arr_start,
            .end = arr_end + 1,
        } } };
    }

    /// Build the jq `match` object: {offset, length, string, captures}.
    /// offset/length are **character counts**, not bytes.
    fn buildMatchObject(
        it: *ResultIterator,
        regex: *const regex_mod.Regex,
        hay_view: Value.StringView,
        slots: []const regex_mod.MatchSlot,
    ) ZqError!StackValue {
        var oc = regex_mod.offset.OffsetCursor.init(hay_view.slice());
        const m_start_char = oc.charAt(slots[0].start);
        const m_end_char = oc.charAt(slots[0].end);

        const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_start,
            .payload = .{ .skip = 0 },
        });

        try it.appendRuntimeKV(
            "offset",
            .{ .tag = .int, .payload = .{ .int = @intCast(m_start_char) } },
        );
        try it.appendRuntimeKV(
            "length",
            .{ .tag = .int, .payload = .{ .int = @intCast(m_end_char - m_start_char) } },
        );
        // Re-resolve hay AFTER any intern that grew runtime_tape.string_buf
        // — `appendRuntimeKV` interns the key. NIX-006 alias safety.
        const match_bytes = hay_view.slice()[slots[0].start..slots[0].end];
        const match_ref = try it.runtime_tape.internString(it.alloc, match_bytes);
        try it.appendRuntimeKV(
            "string",
            .{ .tag = .string, .payload = .{ .string = match_ref } },
        );

        // captures
        const k_captures = try it.runtime_tape.internString(it.alloc, "captures");
        _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .key, .payload = .{ .string = k_captures } });
        const caps_start = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .array_start, .payload = .{ .skip = 0 } });

        var i: usize = 1;
        while (i < slots.len) : (i += 1) {
            try it.appendCaptureEntry(regex, hay_view, slots[i], i, &oc);
        }

        const caps_end = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .array_end, .payload = .{ .none = {} } });
        it.runtime_tape.entries.items[caps_start].payload.skip = caps_end + 1;

        const obj_end = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .object_end, .payload = .{ .none = {} } });
        it.runtime_tape.entries.items[obj_start].payload.skip = obj_end + 1;

        return .{ .tape_value = .{ .object = .{
            .tape = &it.runtime_tape.view,
            .start = obj_start,
            .end = obj_end + 1,
        } } };
    }

    /// Build a capture() object: {<named groups...>}. Unnamed groups skipped.
    /// Unmatched optional named groups emit null.
    fn buildCaptureObject(
        it: *ResultIterator,
        regex: *const regex_mod.Regex,
        hay_view: Value.StringView,
        slots: []const regex_mod.MatchSlot,
    ) ZqError!StackValue {
        const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_start,
            .payload = .{ .skip = 0 },
        });

        var i: usize = 1;
        while (i < slots.len) : (i += 1) {
            const name = regex.groupName(i) orelse continue;
            const k_ref = try it.runtime_tape.internString(it.alloc, name);
            _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .key, .payload = .{ .string = k_ref } });
            if (slots[i].start == regex_mod.SLOT_UNMATCHED) {
                _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .null_val, .payload = .{ .none = {} } });
            } else {
                // Re-resolve hay each iteration — interns above may have
                // grown runtime_tape.string_buf (NIX-006 alias safety).
                const hay = hay_view.slice();
                const bytes = hay[slots[i].start..slots[i].end];
                const s_ref = try it.runtime_tape.internString(it.alloc, bytes);
                _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .string, .payload = .{ .string = s_ref } });
            }
        }

        const obj_end = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .object_end, .payload = .{ .none = {} } });
        it.runtime_tape.entries.items[obj_start].payload.skip = obj_end + 1;
        return .{ .tape_value = .{ .object = .{
            .tape = &it.runtime_tape.view,
            .start = obj_start,
            .end = obj_end + 1,
        } } };
    }

    /// Append one capture entry (a nested object) to the runtime tape.
    /// Shape: `{offset, length, string, name}` with `name = null` when the
    /// group is unnamed. Unmatched optional groups get `offset: -1, length: 0,
    /// string: null`.
    fn appendCaptureEntry(
        it: *ResultIterator,
        regex: *const regex_mod.Regex,
        hay_view: Value.StringView,
        slot: regex_mod.MatchSlot,
        idx: usize,
        oc: *regex_mod.offset.OffsetCursor,
    ) ZqError!void {
        const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_start,
            .payload = .{ .skip = 0 },
        });

        if (slot.start == regex_mod.SLOT_UNMATCHED) {
            try it.appendRuntimeKV("offset", .{ .tag = .int, .payload = .{ .int = -1 } });
            try it.appendRuntimeKV("length", .{ .tag = .int, .payload = .{ .int = 0 } });
            try it.appendRuntimeKV("string", .{ .tag = .null_val, .payload = .{ .none = {} } });
        } else {
            const s_char = oc.charAt(slot.start);
            const e_char = oc.charAt(slot.end);
            try it.appendRuntimeKV("offset", .{ .tag = .int, .payload = .{ .int = @intCast(s_char) } });
            try it.appendRuntimeKV("length", .{ .tag = .int, .payload = .{ .int = @intCast(e_char - s_char) } });
            // Re-resolve hay AFTER appendRuntimeKV interns above (NIX-006).
            const hay = hay_view.slice();
            const bytes = hay[slot.start..slot.end];
            const ref = try it.runtime_tape.internString(it.alloc, bytes);
            try it.appendRuntimeKV("string", .{ .tag = .string, .payload = .{ .string = ref } });
        }

        if (regex.groupName(idx)) |name| {
            const name_ref = try it.runtime_tape.internString(it.alloc, name);
            try it.appendRuntimeKV("name", .{ .tag = .string, .payload = .{ .string = name_ref } });
        } else {
            try it.appendRuntimeKV("name", .{ .tag = .null_val, .payload = .{ .none = {} } });
        }

        const obj_end = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .object_end, .payload = .{ .none = {} } });
        it.runtime_tape.entries.items[obj_start].payload.skip = obj_end + 1;
    }

    /// Helper: append a key entry + value entry. `entry` must be a value
    /// entry (not a container). For containers the caller must manage starts
    /// and ends manually.
    fn appendRuntimeKV(it: *ResultIterator, key: []const u8, entry: Tape.Entry) ZqError!void {
        const k_ref = try it.runtime_tape.internString(it.alloc, key);
        _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .key, .payload = .{ .string = k_ref } });
        // Strings embedded by callers must have had their bytes interned
        // before we're called — we just append the entry as-is.
        _ = try it.runtime_tape.appendEntry(it.alloc, entry);
    }

    // ── Array utility builtins ───────────────────────────────────────────────

    /// `transpose`: transpose array of arrays.
    fn builtinTranspose(it: *ResultIterator) ZqError!?StackValue {
        const span = switch (it.current) {
            .array => |s| s,
            else => return error.TypeError,
        };

        // Collect inner arrays and find max length
        var inner_arrays = std.ArrayList(Value.TapeSpan){};
        defer inner_arrays.deinit(it.alloc);
        var max_len: u32 = 0;

        var pos = span.start + 1;
        const end = span.end - 1;
        while (pos < end) {
            const elem = tapeEntryToValue(span.tape, pos);
            switch (elem) {
                .array => |inner| {
                    const len = arrayLength(inner.tape, inner);
                    if (len > max_len) max_len = len;
                    try inner_arrays.append(it.alloc, inner);
                },
                else => return error.TypeError,
            }
            pos = skipEntry(span.tape.*, pos);
        }

        // Build transposed array of arrays
        const outer_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });

        var col: u32 = 0;
        while (col < max_len) : (col += 1) {
            const row_start = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .array_start,
                .payload = .{ .skip = 0 },
            });

            for (inner_arrays.items) |inner| {
                const elem = lookupIndex(inner.tape, inner, col);
                if (elem) |v| {
                    const sv = try valueToStackValue(v);
                    try it.stackValueToRuntimeTapeEntry(sv);
                } else {
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .null_val,
                        .payload = .{ .none = {} },
                    });
                }
            }

            const row_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .array_end,
                .payload = .{ .none = {} },
            });
            it.runtime_tape.entries.items[row_start].payload.skip = row_end_idx + 1;
        }

        const outer_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[outer_start].payload.skip = outer_end_idx + 1;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape.view,
            .start = outer_start,
            .end = outer_end_idx + 1,
        } } };
    }

    /// `bsearch(x)`: binary search in sorted array.
    /// Returns index if found, or (-1 - insertion_point) if not found.
    fn builtinBsearch(it: *ResultIterator) ZqError!?StackValue {
        const target_sv = try it.popValue();
        const target = try stackValueToValue(target_sv);

        const span = switch (it.current) {
            .array => |s| s,
            else => {
                // Build jq-compatible error: 'TYPE (VALUE) cannot be searched from'
                var msg_buf = std.ArrayList(u8){};
                defer msg_buf.deinit(it.alloc);
                switch (it.current) {
                    .string => |sv| {
                        try msg_buf.appendSlice(it.alloc, "string (");
                        try appendJsonString(&msg_buf, it.alloc, sv.slice());
                        try msg_buf.appendSlice(it.alloc, ") cannot be searched from");
                    },
                    .null_val => try msg_buf.appendSlice(it.alloc, "null cannot be searched from"),
                    .bool_val => |b| {
                        try msg_buf.appendSlice(it.alloc, if (b) "true cannot be searched from" else "false cannot be searched from");
                    },
                    .int => |n| {
                        var tmp: [32]u8 = undefined;
                        const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return error.TypeError;
                        try msg_buf.appendSlice(it.alloc, "number (");
                        try msg_buf.appendSlice(it.alloc, s);
                        try msg_buf.appendSlice(it.alloc, ") cannot be searched from");
                    },
                    .float => |f| {
                        const formatted = types.formatJqFloat(f);
                        try msg_buf.appendSlice(it.alloc, "number (");
                        try msg_buf.appendSlice(it.alloc, formatted.slice());
                        try msg_buf.appendSlice(it.alloc, ") cannot be searched from");
                    },
                    .big_number => |bn| {
                        try msg_buf.appendSlice(it.alloc, "number (");
                        try msg_buf.appendSlice(it.alloc, bn);
                        try msg_buf.appendSlice(it.alloc, ") cannot be searched from");
                    },
                    .object => try msg_buf.appendSlice(it.alloc, "object cannot be searched from"),
                    .array => unreachable,
                }
                return try it.raiseUserError(msg_buf.items);
            },
        };

        // Collect array elements for binary search
        var elems = std.ArrayList(Value){};
        defer elems.deinit(it.alloc);
        var apos = span.start + 1;
        const aend = span.end - 1;
        while (apos < aend) {
            try elems.append(it.alloc, tapeEntryToValue(span.tape, apos));
            apos = skipEntry(span.tape.*, apos);
        }

        // Binary search
        var lo: i64 = 0;
        var hi: i64 = @intCast(elems.items.len);
        while (lo < hi) {
            const mid = @divTrunc(lo + hi, 2);
            const cmp = jqCompareValues(elems.items[@intCast(mid)], target);
            switch (cmp) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return .{ .int = mid },
            }
        }
        // Not found: return -1 - lo (insertion point)
        return .{ .int = -1 - lo };
    }

    // ── Date/time builtin implementations ───────────────────────────────

    fn builtinNow(_: *ResultIterator) ZqError!?StackValue {
        const ns = std.time.nanoTimestamp();
        return .{ .float = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0 };
    }

    fn builtinGmtime(it: *ResultIterator) ZqError!?StackValue {
        var ts_int: i64 = undefined;
        var sec_frac: f64 = 0.0;
        switch (it.current) {
            .int => |n| ts_int = n,
            .float => |f| {
                if (std.math.isNan(f) or std.math.isInf(f)) return error.TypeError;
                ts_int = @intFromFloat(@floor(f));
                sec_frac = f - @floor(f);
                if (sec_frac < 0) sec_frac = 0;
            },
            else => return error.TypeError,
        }
        const bd = unixToDatetime(ts_int, sec_frac);
        // Build 8-element array. Seconds field preserves fractional part.
        var elems: [8]Value = undefined;
        elems[0] = .{ .int = bd.year };
        elems[1] = .{ .int = bd.month };
        elems[2] = .{ .int = bd.mday };
        elems[3] = .{ .int = bd.hour };
        elems[4] = .{ .int = bd.min };
        if (bd.sec_frac > 0.0) {
            elems[5] = .{ .float = @as(f64, @floatFromInt(bd.sec)) + bd.sec_frac };
        } else {
            elems[5] = .{ .int = bd.sec };
        }
        elems[6] = .{ .int = bd.wday };
        elems[7] = .{ .int = bd.yday };
        return try it.buildRuntimeArray(&elems);
    }

    fn builtinMktime(it: *ResultIterator) ZqError!?StackValue {
        const span = switch (it.current) {
            .array => |s| s,
            else => return try it.raiseUserError("mktime requires parsed datetime inputs"),
        };
        // Extract up to 8 numeric elements; missing defaults to 0.
        var fields = [_]i64{0} ** 8;
        var pos = span.start + 1;
        const end = span.end - 1;
        var idx: usize = 0;
        while (pos < end and idx < 8) : (idx += 1) {
            const v = tapeEntryToValue(span.tape, pos);
            switch (v) {
                .int => |n| fields[idx] = n,
                .float => |f| fields[idx] = @intFromFloat(@trunc(f)),
                else => return try it.raiseUserError("mktime requires parsed datetime inputs"),
            }
            pos = skipEntry(span.tape.*, pos);
        }
        const ts = datetimeToUnix(fields[0], fields[1], fields[2], fields[3], fields[4], fields[5]);
        return .{ .int = ts };
    }

    /// Shared implementation for strftime and strflocaltime.
    fn builtinStrftimeImpl(it: *ResultIterator, comptime name: []const u8) ZqError!?StackValue {
        // Pop format argument
        const fmt_sv = try it.popValue();
        const fmt_val = try stackValueToValue(fmt_sv);
        const fmt = switch (fmt_val) {
            .string => |sv| sv.slice(),
            else => return try it.raiseUserError(name ++ "/1 requires a string format"),
        };
        // Convert current value to BrokenDownTime
        const bd = currentToBdt(it) catch {
            return try it.raiseUserError(name ++ "/1 requires parsed datetime inputs");
        };
        // Format
        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        formatDatetime(&buf, it.alloc, fmt, bd) catch return error.OutOfMemory;
        const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
        return it.rtStringSV(str_ref);
    }

    fn builtinStrptime(it: *ResultIterator) ZqError!?StackValue {
        // Pop format argument
        const fmt_sv = try it.popValue();
        const fmt_val = try stackValueToValue(fmt_sv);
        const fmt = switch (fmt_val) {
            .string => |sv| sv.slice(),
            else => return try it.raiseUserError("strptime/1 requires string inputs and arguments"),
        };
        const input = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return try it.raiseUserError("strptime/1 requires string inputs and arguments"),
        };
        const bd = parseDatetime(input, fmt) catch {
            return try it.raiseUserError("strptime/1 requires string inputs and arguments");
        };
        // Build 8-element array
        var elems: [8]Value = undefined;
        elems[0] = .{ .int = bd.year };
        elems[1] = .{ .int = bd.month };
        elems[2] = .{ .int = bd.mday };
        elems[3] = .{ .int = bd.hour };
        elems[4] = .{ .int = bd.min };
        elems[5] = .{ .int = bd.sec };
        elems[6] = .{ .int = bd.wday };
        elems[7] = .{ .int = bd.yday };
        return try it.buildRuntimeArray(&elems);
    }

    fn builtinTodate(it: *ResultIterator) ZqError!?StackValue {
        const bd = currentToBdt(it) catch {
            return try it.raiseUserError("strftime/1 requires parsed datetime inputs");
        };
        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        formatDatetime(&buf, it.alloc, "%Y-%m-%dT%H:%M:%SZ", bd) catch return error.OutOfMemory;
        const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
        return it.rtStringSV(str_ref);
    }

    fn builtinFromdate(it: *ResultIterator) ZqError!?StackValue {
        const input = switch (it.current) {
            .string => |sv| sv.slice(),
            else => return try it.raiseUserError("strptime/1 requires string inputs and arguments"),
        };
        const bd = parseDatetime(input, "%Y-%m-%dT%H:%M:%SZ") catch {
            return try it.raiseUserError("strptime/1 requires string inputs and arguments");
        };
        const ts = datetimeToUnix(bd.year, bd.month, bd.mday, bd.hour, bd.min, bd.sec);
        return .{ .int = ts };
    }

    /// Convert current value to BrokenDownTime: accepts int, float, or array.
    fn currentToBdt(it: *ResultIterator) error{ TypeError, OutOfMemory }!BrokenDownTime {
        switch (it.current) {
            .int => |n| return unixToDatetime(n, 0.0),
            .float => |f| {
                if (std.math.isNan(f) or std.math.isInf(f)) return error.TypeError;
                const ts_int: i64 = @intFromFloat(@floor(f));
                var sec_frac = f - @floor(f);
                if (sec_frac < 0) sec_frac = 0;
                return unixToDatetime(ts_int, sec_frac);
            },
            .array => |span| {
                var fields = [_]i64{0} ** 8;
                var sec_frac: f64 = 0.0;
                var pos = span.start + 1;
                const end = span.end - 1;
                var idx: usize = 0;
                while (pos < end and idx < 8) : (idx += 1) {
                    const v = tapeEntryToValue(span.tape, pos);
                    switch (v) {
                        .int => |n| fields[idx] = n,
                        .float => |fv| {
                            fields[idx] = @intFromFloat(@trunc(fv));
                            if (idx == 5) sec_frac = fv - @trunc(fv);
                        },
                        else => return error.TypeError,
                    }
                    pos = skipEntry(span.tape.*, pos);
                }
                // Recompute wday/yday from parsed fields
                const days = daysFromCivil(fields[0], fields[1] + 1, fields[2]);
                return .{
                    .year = fields[0],
                    .month = fields[1],
                    .mday = fields[2],
                    .hour = fields[3],
                    .min = fields[4],
                    .sec = fields[5],
                    .sec_frac = sec_frac,
                    .wday = dayOfWeek(days),
                    .yday = dayOfYear(fields[0], fields[1], fields[2]),
                };
            },
            else => return error.TypeError,
        }
    }
};

/// jq-canonical container-nesting limit for JSON parsing (`fromjson`).
/// Matches jq 1.8.1 (`MAX_PARSING_DEPTH = 10000` in `src/jv_parse.c`):
/// once an open bracket would push nesting strictly beyond this, jq aborts
/// with the message preserved below. Both the limit and the message must
/// remain byte-identical for `try (fromjson) catch .` parity.
const PARSE_DEPTH_LIMIT: u32 = 10000;
const PARSE_DEPTH_LIMIT_MSG: []const u8 = "Exceeds depth limit for parsing";

/// jq-canonical container-nesting limit for JSON serialisation (`tojson`).
/// Once recursion reaches this depth (i.e. the call stack already represents
/// `SERIALIZE_DEPTH_LIMIT` nested containers), the serializer emits the
/// literal sentinel `<skipped: too deep>` in place of the subtree (matching
/// jq's `jv_dump_recurse` output) and stops descending — preventing
/// native-stack overflow on pathological inputs. With `[];[.]`-style
/// nesting (depth = N+1 after `range(N)`), sentinel-emission therefore
/// triggers at `range(10001)` (D = 10002, max call depth 10001) and not
/// at `range(10000)` (D = 10001, max call depth 10000).
const SERIALIZE_DEPTH_LIMIT: u32 = 10001;
const SERIALIZE_DEPTH_SENTINEL: []const u8 = "<skipped: too deep>";

/// Simple JSON parser for fromjson builtin.
/// Parses a JSON string and builds entries in the ResultIterator's runtime tape.
/// Uses a tape-first approach: all parsed values are written directly to the runtime
/// tape. The top-level result is then read back as a StackValue.
fn parseJsonToStackValue(it: *ResultIterator, json_str: []const u8) ZqError!StackValue {
    var parser = JsonParser{ .src = json_str, .pos = 0, .it = it, .depth = 0 };
    const start_idx: u32 = @intCast(it.runtime_tape.entries.items.len);
    // Propagate ZqError directly: UserError carries the depth-limit
    // message (raised by `JsonParser.writeValue` once `depth >=
    // PARSE_DEPTH_LIMIT`); TypeError carries any malformed-JSON detail
    // set by the parser; OutOfMemory bubbles up untouched.
    try parser.writeValue();
    return valueToStackValue(tapeEntryToValue(&it.runtime_tape.view, start_idx));
}

const JsonParser = struct {
    src: []const u8,
    pos: usize,
    it: *ResultIterator,
    /// Container-nesting depth — incremented on entry to every array/object,
    /// decremented on exit. Compared against `PARSE_DEPTH_LIMIT` before
    /// recursing further.
    depth: u32,

    /// Raise the jq-canonical depth-limit UserError. Sets `user_error_msg`
    /// so that `try (fromjson) catch .` yields the literal
    /// "Exceeds depth limit for parsing" string.
    fn raiseDepthLimit(self: *JsonParser) ZqError {
        const str_ref = self.it.runtime_tape.internString(self.it.alloc, PARSE_DEPTH_LIMIT_MSG) catch return error.OutOfMemory;
        self.it.user_error_msg = .{ .string = self.it.rtString(str_ref) };
        return error.UserError;
    }

    fn skipWhitespace(self: *JsonParser) void {
        while (self.pos < self.src.len and
            (self.src[self.pos] == ' ' or self.src[self.pos] == '\t' or
                self.src[self.pos] == '\n' or self.src[self.pos] == '\r'))
        {
            self.pos += 1;
        }
    }

    /// Iteratively parse a JSON value into the runtime tape. Uses an
    /// explicit container-frame stack so deeply nested input cannot blow
    /// the native thread stack (workers run with `THREAD_STACK_SIZE = 2 MiB`,
    /// while jq accepts up to `PARSE_DEPTH_LIMIT = 10000` levels of
    /// nesting). Once `depth >= PARSE_DEPTH_LIMIT` the parser raises the
    /// jq-canonical "Exceeds depth limit for parsing" UserError before
    /// descending further, exactly as the original recursive form did.
    fn writeValue(self: *JsonParser) ZqError!void {
        const Frame = struct {
            /// Tape index of the matching `array_start` / `object_start`
            /// entry so we can patch its skip pointer when we close.
            start_idx: u32,
            is_object: bool,
            /// True until the first child has been emitted; flips to false
            /// after the first element is parsed.
            first: bool,
        };

        var stack = std.ArrayList(Frame){};
        defer stack.deinit(self.it.alloc);

        // Outer loop: each iteration parses exactly one element of the
        // currently-open container, or the single root value when the
        // stack is empty.
        outer: while (true) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) return error.TypeError;

            // Inside a container, first decide whether we're closing or
            // expecting a separator + next element. The very first call
            // path (stack empty) always parses a value.
            if (stack.items.len > 0) {
                const top = &stack.items[stack.items.len - 1];
                if (top.is_object) {
                    if (top.first) {
                        // Either '}' (empty object) or a string key.
                        if (self.src[self.pos] == '}') {
                            self.pos += 1;
                            const end_idx = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
                                .tag = .object_end,
                                .payload = .{ .none = {} },
                            });
                            self.it.runtime_tape.entries.items[top.start_idx].payload.skip = end_idx + 1;
                            _ = stack.pop();
                            self.depth -= 1;
                            if (stack.items.len == 0) return;
                            continue :outer;
                        }
                    } else {
                        // After at least one key:value pair: expect ',' or '}'.
                        if (self.src[self.pos] == '}') {
                            self.pos += 1;
                            const end_idx = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
                                .tag = .object_end,
                                .payload = .{ .none = {} },
                            });
                            self.it.runtime_tape.entries.items[top.start_idx].payload.skip = end_idx + 1;
                            _ = stack.pop();
                            self.depth -= 1;
                            if (stack.items.len == 0) return;
                            continue :outer;
                        }
                        if (self.src[self.pos] != ',') return error.TypeError;
                        self.pos += 1;
                        self.skipWhitespace();
                        if (self.pos >= self.src.len) return error.TypeError;
                    }
                    // Parse key (must be a string literal).
                    if (self.src[self.pos] != '"') return self.stringLiteralError(self.pos);
                    const key_bytes = try self.parseStringBytes();
                    const key_ref = try self.it.runtime_tape.internString(self.it.alloc, key_bytes);
                    self.it.alloc.free(key_bytes);
                    _ = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
                        .tag = .key,
                        .payload = .{ .string = key_ref },
                    });
                    self.skipWhitespace();
                    if (self.pos >= self.src.len or self.src[self.pos] != ':') return error.TypeError;
                    self.pos += 1;
                    self.skipWhitespace();
                    if (self.pos >= self.src.len) return error.TypeError;
                    top.first = false;
                    // Fall through to value-parse below.
                } else {
                    // Array container.
                    if (top.first) {
                        if (self.src[self.pos] == ']') {
                            self.pos += 1;
                            const end_idx = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
                                .tag = .array_end,
                                .payload = .{ .none = {} },
                            });
                            self.it.runtime_tape.entries.items[top.start_idx].payload.skip = end_idx + 1;
                            _ = stack.pop();
                            self.depth -= 1;
                            if (stack.items.len == 0) return;
                            continue :outer;
                        }
                    } else {
                        if (self.src[self.pos] == ']') {
                            self.pos += 1;
                            const end_idx = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
                                .tag = .array_end,
                                .payload = .{ .none = {} },
                            });
                            self.it.runtime_tape.entries.items[top.start_idx].payload.skip = end_idx + 1;
                            _ = stack.pop();
                            self.depth -= 1;
                            if (stack.items.len == 0) return;
                            continue :outer;
                        }
                        if (self.src[self.pos] != ',') return error.TypeError;
                        self.pos += 1;
                        self.skipWhitespace();
                        if (self.pos >= self.src.len) return error.TypeError;
                    }
                    top.first = false;
                    // Fall through to value-parse below.
                }
            }

            // Parse one value. Containers push a new frame and continue;
            // scalars finish here. The very first iteration arrives here
            // with an empty stack and parses the root value.
            switch (self.src[self.pos]) {
                '"' => try self.writeString(),
                '{' => {
                    if (self.depth >= PARSE_DEPTH_LIMIT) return self.raiseDepthLimit();
                    self.depth += 1;
                    self.pos += 1;
                    const obj_start = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
                        .tag = .object_start,
                        .payload = .{ .skip = 0 },
                    });
                    try stack.append(self.it.alloc, .{
                        .start_idx = obj_start,
                        .is_object = true,
                        .first = true,
                    });
                    continue :outer;
                },
                '[' => {
                    if (self.depth >= PARSE_DEPTH_LIMIT) return self.raiseDepthLimit();
                    self.depth += 1;
                    self.pos += 1;
                    const arr_start = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
                        .tag = .array_start,
                        .payload = .{ .skip = 0 },
                    });
                    try stack.append(self.it.alloc, .{
                        .start_idx = arr_start,
                        .is_object = false,
                        .first = true,
                    });
                    continue :outer;
                },
                't' => try self.writeLiteral("true", .true_val),
                'f' => try self.writeLiteral("false", .false_val),
                // 'n' may begin "null" or case-insensitive "nan" / "NaN" etc.
                'n' => try self.writeNullOrNan(),
                // 'N' begins case-insensitive "NaN".
                'N' => try self.writeNanLiteral(false),
                '-', '0'...'9' => try self.writeNumber(),
                else => return error.TypeError,
            }

            // Scalar consumed. If we're at the root, we're done.
            if (stack.items.len == 0) return;
            // Otherwise loop to parse the next sibling / close the container.
        }
    }

    /// Disambiguate 'n': accepts "null" or case-insensitive "nan".
    /// jq accepts "nan" (all lowercase) as a NaN literal.
    fn writeNullOrNan(self: *JsonParser) ZqError!void {
        // Peek at the second character to decide.
        if (self.pos + 1 < self.src.len and
            (self.src[self.pos + 1] == 'a' or self.src[self.pos + 1] == 'A'))
        {
            // Starts with 'n' followed by 'a'/'A' → NaN branch.
            return self.writeNanLiteral(false);
        }
        // Otherwise fall through to "null".
        return self.writeLiteral("null", .null_val);
    }

    /// Parse a NaN literal (case-insensitive "nan" / "NaN" / "Nan" etc.)
    /// or "-NaN" / "-nan" (negated; `negated` is true when '-' was already consumed).
    /// After consuming exactly 3 chars (n-a-n or N-a-N etc.), any trailing
    /// non-whitespace / non-structural character makes the literal invalid and
    /// generates a jq-compatible error message, e.g.:
    ///   "Invalid numeric literal at EOF at line 1,column 4 (while parsing 'NaN1')"
    fn writeNanLiteral(self: *JsonParser, negated: bool) ZqError!void {
        const literal_start = if (negated) self.pos - 1 else self.pos;
        // Expect exactly 3 characters: first letter already seen as 'n'/'N',
        // second must be 'a'/'A', third must be 'n'/'N'.
        if (self.pos + 3 > self.src.len) return self.nanError();
        const b0 = self.src[self.pos]; // 'n' or 'N'
        const b1 = self.src[self.pos + 1];
        const b2 = self.src[self.pos + 2];
        if ((b0 != 'n' and b0 != 'N') or
            (b1 != 'a' and b1 != 'A') or
            (b2 != 'n' and b2 != 'N'))
        {
            return self.nanError();
        }
        self.pos += 3;
        // Check that nothing invalid follows (whitespace / structural chars are ok).
        if (self.pos < self.src.len) {
            const next = self.src[self.pos];
            // Valid terminators: whitespace, ']', '}', ',', end-of-container.
            const is_term = (next == ' ' or next == '\t' or next == '\n' or
                next == '\r' or next == ']' or next == '}' or next == ',');
            if (!is_term) {
                return self.nanErrorAt(literal_start);
            }
        }
        const nan_val = if (negated) -std.math.nan(f64) else std.math.nan(f64);
        _ = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
            .tag = .float,
            .payload = .{ .float = nan_val },
        });
    }

    /// Build and set a NaN-parse error detail matching jq's format, then return TypeError.
    /// `literal_start` is the index of the first char of the whole literal (including '-').
    /// jq reports the column as the length of the full input string (EOF position),
    /// and the "while parsing" fragment is the entire remaining input from literal_start.
    fn nanErrorAt(self: *JsonParser, literal_start: usize) ZqError {
        const col = self.src.len; // jq: EOF column = length of the input token
        const literal = self.src[literal_start..]; // full literal from start (e.g. "NaN1")
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.it.alloc);
        buf.writer(self.it.alloc).print(
            "Invalid numeric literal at EOF at line 1,column {d} (while parsing '{s}')",
            .{ col, literal },
        ) catch return error.TypeError;
        const str_ref = self.it.runtime_tape.internString(self.it.alloc, buf.items) catch return error.TypeError;
        self.it.type_error_detail = .{ .string = self.it.rtString(str_ref) };
        return error.TypeError;
    }

    /// NaN error with no trailing char info (e.g. premature EOF during nan parsing).
    fn nanError(self: *JsonParser) ZqError {
        _ = self;
        return error.TypeError;
    }

    /// Build and set a string-literal parse error matching jq's format, then return TypeError.
    /// Called when we expect `"` but find a different character at `bad_pos`.
    /// Format: `Invalid string literal; expected ",but got X at line 1,column N (while parsing 'FRAGMENT')`
    /// Column N: jq scans past the bad "token" (treating `'` as a matching close-quote) and
    /// reports the 1-based column of the first character after it.
    fn stringLiteralError(self: *JsonParser, bad_pos: usize) ZqError {
        if (bad_pos >= self.src.len) return error.TypeError;
        const bad_char = self.src[bad_pos];
        // Scan forward to compute column: find the exclusive end of the bad token.
        var scan = bad_pos + 1; // skip the bad_char itself
        if (bad_char == '\'') {
            // jq treats the single-quote as an opening delimiter and scans for the closing one.
            while (scan < self.src.len) {
                const c = self.src[scan];
                scan += 1;
                if (c == '\'') break; // closing quote found; scan now points past it
                // Structural characters terminate the scan (do not consume).
                if (c == ',' or c == ':' or c == '[' or c == ']' or
                    c == '{' or c == '}' or
                    c == ' ' or c == '\t' or c == '\n' or c == '\r')
                {
                    scan -= 1; // put it back; column points at this structural char
                    break;
                }
            }
        } else {
            // For other bad chars, scan until structural char or whitespace.
            while (scan < self.src.len) {
                const c = self.src[scan];
                if (c == ',' or c == ':' or c == '[' or c == ']' or
                    c == '{' or c == '}' or c == '"' or c == '\'' or
                    c == ' ' or c == '\t' or c == '\n' or c == '\r')
                {
                    break;
                }
                scan += 1;
            }
        }
        const col = scan + 1; // 1-based column of first char after the scanned token
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.it.alloc);
        buf.writer(self.it.alloc).print(
            "Invalid string literal; expected \", but got {c} at line 1, column {d} (while parsing '{s}')",
            .{ bad_char, col, self.src },
        ) catch return error.TypeError;
        const str_ref = self.it.runtime_tape.internString(self.it.alloc, buf.items) catch return error.TypeError;
        self.it.type_error_detail = .{ .string = self.it.rtString(str_ref) };
        return error.TypeError;
    }

    fn writeLiteral(self: *JsonParser, expected: []const u8, tag: Tape.Tag) ZqError!void {
        if (self.pos + expected.len > self.src.len) return error.TypeError;
        if (!std.mem.eql(u8, self.src[self.pos..][0..expected.len], expected)) return error.TypeError;
        self.pos += expected.len;
        _ = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
            .tag = tag,
            .payload = .{ .none = {} },
        });
    }

    fn writeNumber(self: *JsonParser) ZqError!void {
        const start = self.pos;
        if (self.pos < self.src.len and self.src[self.pos] == '-') {
            self.pos += 1;
            // jq accepts -NaN and -nan as negated NaN literals.
            if (self.pos < self.src.len and
                (self.src[self.pos] == 'N' or self.src[self.pos] == 'n'))
            {
                return self.writeNanLiteral(true);
            }
        }
        while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
            self.pos += 1;
        }
        var is_float = false;
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            is_float = true;
            self.pos += 1;
            while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
                self.pos += 1;
            }
        }
        if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) {
                self.pos += 1;
            }
            while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
                self.pos += 1;
            }
        }
        const num_str = self.src[start..self.pos];
        if (!is_float) {
            if (std.fmt.parseInt(i64, num_str, 10)) |n| {
                _ = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
                    .tag = .int,
                    .payload = .{ .int = n },
                });
                return;
            } else |_| {}
        }
        const f = std.fmt.parseFloat(f64, num_str) catch return error.TypeError;
        _ = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
            .tag = .float,
            .payload = .{ .float = f },
        });
    }

    fn writeString(self: *JsonParser) ZqError!void {
        const s = try self.parseStringBytes();
        const str_ref = try self.it.runtime_tape.internString(self.it.alloc, s);
        self.it.alloc.free(s);
        _ = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
            .tag = .string,
            .payload = .{ .string = str_ref },
        });
    }

    /// Parse a JSON string and return the decoded bytes (caller must free).
    fn parseStringBytes(self: *JsonParser) ZqError![]const u8 {
        if (self.src[self.pos] != '"') return error.TypeError;
        self.pos += 1;
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(self.it.alloc);
        while (self.pos < self.src.len and self.src[self.pos] != '"') {
            if (self.src[self.pos] == '\\') {
                self.pos += 1;
                if (self.pos >= self.src.len) return error.TypeError;
                switch (self.src[self.pos]) {
                    '"' => try buf.append(self.it.alloc, '"'),
                    '\\' => try buf.append(self.it.alloc, '\\'),
                    '/' => try buf.append(self.it.alloc, '/'),
                    'b' => try buf.append(self.it.alloc, 0x08),
                    'f' => try buf.append(self.it.alloc, 0x0C),
                    'n' => try buf.append(self.it.alloc, '\n'),
                    'r' => try buf.append(self.it.alloc, '\r'),
                    't' => try buf.append(self.it.alloc, '\t'),
                    'u' => {
                        self.pos += 1;
                        if (self.pos + 4 > self.src.len) return error.TypeError;
                        const hex = std.fmt.parseInt(u16, self.src[self.pos..][0..4], 16) catch return error.TypeError;
                        self.pos += 3; // will be incremented by 1 at end
                        var encode_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(@intCast(hex), &encode_buf) catch return error.TypeError;
                        try buf.appendSlice(self.it.alloc, encode_buf[0..len]);
                    },
                    else => try buf.append(self.it.alloc, self.src[self.pos]),
                }
            } else {
                try buf.append(self.it.alloc, self.src[self.pos]);
            }
            self.pos += 1;
        }
        if (self.pos >= self.src.len) return error.TypeError;
        self.pos += 1; // skip closing quote
        return try buf.toOwnedSlice(self.it.alloc);
    }
};

/// Deep equality for StackValues (used by array subtraction).
fn stackValuesEqual(a: StackValue, b: StackValue) bool {
    return switch (a) {
        .null_val => switch (b) {
            .null_val => true,
            else => false,
        },
        .bool_val => |ab| switch (b) {
            .bool_val => |bb| ab == bb,
            else => false,
        },
        .int => |ai| switch (b) {
            .int => |bi| ai == bi,
            .float => |bf| @as(f64, @floatFromInt(ai)) == bf,
            else => false,
        },
        .float => |af| switch (b) {
            .float => |bf| af == bf,
            .int => |bi| af == @as(f64, @floatFromInt(bi)),
            else => false,
        },
        .big_number => |abn| switch (b) {
            .big_number => |bbn| std.mem.eql(u8, abn, bbn),
            else => false,
        },
        .tape_value => |atv| switch (b) {
            .tape_value => |btv| tapeValuesEqual(atv, btv),
            else => false,
        },
    };
}

fn tapeValuesEqual(a: Value, b: Value) bool {
    return switch (a) {
        .null_val => switch (b) {
            .null_val => true,
            else => false,
        },
        .bool_val => |ab| switch (b) {
            .bool_val => |bb| ab == bb,
            else => false,
        },
        .int => |ai| switch (b) {
            .int => |bi| ai == bi,
            .float => |bf| @as(f64, @floatFromInt(ai)) == bf,
            else => false,
        },
        .float => |af| switch (b) {
            .float => |bf| af == bf,
            .int => |bi| af == @as(f64, @floatFromInt(bi)),
            else => false,
        },
        .string => |as| switch (b) {
            .string => |bs| std.mem.eql(u8, as.slice(), bs.slice()),
            else => false,
        },
        .array => |aspan| switch (b) {
            .array => |bspan| blk: {
                var apos = aspan.start + 1;
                var bpos = bspan.start + 1;
                const aend = aspan.end - 1;
                const bend = bspan.end - 1;
                while (apos < aend and bpos < bend) {
                    if (!tapeValuesEqual(tapeEntryToValue(aspan.tape, apos), tapeEntryToValue(bspan.tape, bpos))) break :blk false;
                    apos = skipEntry(aspan.tape.*, apos);
                    bpos = skipEntry(bspan.tape.*, bpos);
                }
                break :blk (apos >= aend and bpos >= bend);
            },
            else => false,
        },
        .big_number => |abn| switch (b) {
            .big_number => |bbn| std.mem.eql(u8, abn, bbn),
            else => false,
        },
        .object => false, // Simplified; object equality not needed for array subtraction
    };
}

// ── jq-compatible value comparison ────────────────────────────────────────────
// jq defines a total ordering: null < false < true < numbers < strings < arrays < objects

fn jqTypeOrder(v: Value) u8 {
    return switch (v) {
        .null_val => 0,
        .bool_val => |b| if (b) @as(u8, 2) else 1,
        .int, .float, .big_number => 3,
        .string => 4,
        .array => 5,
        .object => 6,
    };
}

/// Recursive total-order comparison of two Values using jq semantics.
fn jqCompareValues(a: Value, b: Value) std.math.Order {
    const ta = jqTypeOrder(a);
    const tb = jqTypeOrder(b);
    if (ta != tb) return std.math.order(ta, tb);

    // Same type group
    return switch (a) {
        .null_val => .eq,
        .bool_val => .eq, // false=1, true=2 already distinguished by type order
        .int => |ai| switch (b) {
            .int => |bi| std.math.order(ai, bi),
            .float => |bf| floatOrder(@as(f64, @floatFromInt(ai)), bf),
            // big_number is always out-of-range; positive > any i64, negative < any i64
            .big_number => |bn| if (bn.len > 0 and bn[0] == '-') .gt else .lt,
            else => unreachable,
        },
        .float => |af| switch (b) {
            .int => |bi| floatOrder(af, @as(f64, @floatFromInt(bi))),
            .float => |bf| floatOrder(af, bf),
            // big_number is always out-of-range; positive > any finite f64, negative < any finite f64
            .big_number => |bn| if (bn.len > 0 and bn[0] == '-') .gt else .lt,
            else => unreachable,
        },
        .big_number => |abn| switch (b) {
            .big_number => |bbn| types.compareBigNumbers(abn, bbn),
            .int => if (abn.len > 0 and abn[0] == '-') .lt else .gt,
            .float => if (abn.len > 0 and abn[0] == '-') .lt else .gt,
            else => unreachable,
        },
        .string => |as_str| switch (b) {
            .string => |bs_str| std.mem.order(u8, as_str.slice(), bs_str.slice()),
            else => unreachable,
        },
        .array => |aspan| switch (b) {
            .array => |bspan| jqCompareArrays(aspan, bspan),
            else => unreachable,
        },
        .object => |aspan| switch (b) {
            .object => |bspan| jqCompareObjects(aspan, bspan),
            else => unreachable,
        },
    };
}

fn floatOrder(a: f64, b: f64) std.math.Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    // Handle NaN: NaN is considered equal to NaN for sorting stability
    if (std.math.isNan(a) and std.math.isNan(b)) return .eq;
    if (std.math.isNan(a)) return .lt;
    if (std.math.isNan(b)) return .gt;
    return .eq;
}

fn jqCompareArrays(aspan: Value.TapeSpan, bspan: Value.TapeSpan) std.math.Order {
    var apos = aspan.start + 1;
    var bpos = bspan.start + 1;
    const aend = aspan.end - 1;
    const bend = bspan.end - 1;
    while (apos < aend and bpos < bend) {
        const av = tapeEntryToValue(aspan.tape, apos);
        const bv = tapeEntryToValue(bspan.tape, bpos);
        const cmp = jqCompareValues(av, bv);
        if (cmp != .eq) return cmp;
        apos = skipEntry(aspan.tape.*, apos);
        bpos = skipEntry(bspan.tape.*, bpos);
    }
    // Shorter array is less
    const a_done = apos >= aend;
    const b_done = bpos >= bend;
    if (a_done and b_done) return .eq;
    if (a_done) return .lt;
    return .gt;
}

fn jqCompareObjects(aspan: Value.TapeSpan, bspan: Value.TapeSpan) std.math.Order {
    // jq compares objects by: collect keys from both, sort, compare by sorted keys then values.
    // This is expensive but correct. We do a simple approach: compare key count, then
    // compare sorted key-value pairs.
    const alen = objectLength(aspan);
    const blen = objectLength(bspan);
    if (alen != blen) return std.math.order(alen, blen);

    // For equal-length objects, we compare by sorted keys then values.
    // Simple approach: since this is mainly used for sort stability, we compare
    // key-value pairs in insertion order. Full jq compat would sort keys first,
    // but this handles the common cases correctly.
    var apos = aspan.start + 1;
    var bpos = bspan.start + 1;
    const aend = aspan.end - 1;
    const bend = bspan.end - 1;
    while (apos < aend and bpos < bend) {
        // Compare keys
        const akey = aspan.tape.getString(aspan.tape.entries[apos].payload.string);
        const bkey = bspan.tape.getString(bspan.tape.entries[bpos].payload.string);
        const key_cmp = std.mem.order(u8, akey, bkey);
        if (key_cmp != .eq) return key_cmp;
        // Compare values
        const av = tapeEntryToValue(aspan.tape, apos + 1);
        const bv = tapeEntryToValue(bspan.tape, bpos + 1);
        const val_cmp = jqCompareValues(av, bv);
        if (val_cmp != .eq) return val_cmp;
        apos = skipEntry(aspan.tape.*, apos + 1);
        bpos = skipEntry(bspan.tape.*, bpos + 1);
    }
    return .eq;
}

fn objectLength(span: Value.TapeSpan) u32 {
    var count: u32 = 0;
    var pos = span.start + 1;
    const end = span.end - 1;
    while (pos < end) {
        pos = skipEntry(span.tape.*, pos + 1);
        count += 1;
    }
    return count;
}

fn jqValuesEqual(a: Value, b: Value) bool {
    return jqCompareValues(a, b) == .eq;
}

/// Element-key pair used by sort_by, group_by, min_by, max_by, unique_by.
const ValueKeyPair = struct {
    value: Value,
    key: Value,
};

/// Flatten nested arrays up to `depth` levels, appending non-array elements to `out`.
/// Flatten an array up to `depth` levels into `out`. Iterative explicit-
/// stack walk; each frame remembers how many further levels of arrays
/// should still be unwrapped (`remaining`). Same stack-safety rationale
/// as `flattenRecursive`.
fn flattenNLevels(span: Value.TapeSpan, out: *std.ArrayList(Value), alloc: std.mem.Allocator, depth: u32) error{OutOfMemory}!void {
    const Frame = struct {
        tape: *const Tape,
        pos: u32,
        end: u32,
        remaining: u32,
    };
    var stack = std.ArrayList(Frame){};
    defer stack.deinit(alloc);
    try stack.append(alloc, .{
        .tape = span.tape,
        .pos = span.start + 1,
        .end = span.end - 1,
        .remaining = depth,
    });

    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.pos >= top.end) {
            _ = stack.pop();
            continue;
        }
        const elem = tapeEntryToValue(top.tape, top.pos);
        const remaining = top.remaining;
        top.pos = skipEntry(top.tape.*, top.pos);
        switch (elem) {
            .array => |inner_span| {
                if (remaining > 0) {
                    try stack.append(alloc, .{
                        .tape = inner_span.tape,
                        .pos = inner_span.start + 1,
                        .end = inner_span.end - 1,
                        .remaining = remaining - 1,
                    });
                } else {
                    try out.append(alloc, elem);
                }
            },
            else => try out.append(alloc, elem),
        }
    }
}

/// Recursive containment check (jq semantics).
/// - Strings: b is substring of a
/// - Arrays: every element of b is contained by some element of a
/// Convert a byte offset within a UTF-8 string to a codepoint index.
/// jq uses codepoint indices for string operations, not byte offsets.
fn byteOffsetToCodepointIndex(s: []const u8, byte_offset: usize) i64 {
    var cp_index: i64 = 0;
    var i: usize = 0;
    while (i < byte_offset and i < s.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += seq_len;
        cp_index += 1;
    }
    return cp_index;
}

/// - Objects: for every key in b, a has that key and a[key] contains b[key]
/// - Scalars: exact equality
fn jqContains(a: Value, b: Value) bool {
    switch (b) {
        .null_val => return switch (a) {
            .null_val => true,
            else => false,
        },
        .bool_val => |bb| return switch (a) {
            .bool_val => |ab| ab == bb,
            else => false,
        },
        .int => |bi| return switch (a) {
            .int => |ai| ai == bi,
            .float => |af| af == @as(f64, @floatFromInt(bi)),
            else => false,
        },
        .float => |bf| return switch (a) {
            .float => |af| af == bf,
            .int => |ai| @as(f64, @floatFromInt(ai)) == bf,
            else => false,
        },
        .string => |bs_sv| return switch (a) {
            .string => |as_sv| {
                const bs = bs_sv.slice();
                const as_str = as_sv.slice();
                // b is substring of a
                if (bs.len == 0) return true;
                if (bs.len > as_str.len) return false;
                return std.mem.indexOf(u8, as_str, bs) != null;
            },
            else => false,
        },
        .array => |bspan| return switch (a) {
            .array => |aspan| {
                // Every element of b must be contained by some element of a
                var bpos = bspan.start + 1;
                const bend = bspan.end - 1;
                while (bpos < bend) {
                    const belem = tapeEntryToValue(bspan.tape, bpos);
                    // Find some element in a that contains belem
                    var apos = aspan.start + 1;
                    const aend = aspan.end - 1;
                    var found = false;
                    while (apos < aend) {
                        if (jqContains(tapeEntryToValue(aspan.tape, apos), belem)) {
                            found = true;
                            break;
                        }
                        apos = skipEntry(aspan.tape.*, apos);
                    }
                    if (!found) return false;
                    bpos = skipEntry(bspan.tape.*, bpos);
                }
                return true;
            },
            else => false,
        },
        .big_number => |bbn| return switch (a) {
            .big_number => |abn| std.mem.eql(u8, abn, bbn),
            else => false,
        },
        .object => |bspan| return switch (a) {
            .object => |aspan| {
                // For every key in b, a must have that key and a[key] contains b[key]
                var bpos = bspan.start + 1;
                const bend = bspan.end - 1;
                while (bpos < bend) {
                    const bkey = bspan.tape.getString(bspan.tape.entries[bpos].payload.string);
                    const bval = tapeEntryToValue(bspan.tape, bpos + 1);
                    // Look up key in a
                    const aval = lookupKey(aspan.tape, aspan, bkey) orelse return false;
                    if (!jqContains(aval, bval)) return false;
                    bpos = skipEntry(bspan.tape.*, bpos + 1);
                }
                return true;
            },
            else => false,
        },
    }
}

/// Recursively flatten nested arrays, appending non-array elements to `out`.
/// Convert a hex digit character to its numeric value (0-15), or null if invalid.
fn hexDigitVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// Flatten an array fully (no depth bound) into `out`. Uses an explicit
/// stack of cursor frames so deeply nested input cannot overflow the
/// native thread stack — required because workers run with
/// `THREAD_STACK_SIZE = 2 MiB` while jq accepts arrays nested up to
/// `PARSE_DEPTH_LIMIT = 10000` levels.
fn flattenRecursive(span: Value.TapeSpan, out: *std.ArrayList(Value), alloc: std.mem.Allocator) error{OutOfMemory}!void {
    const Frame = struct {
        tape: *const Tape,
        pos: u32,
        end: u32,
    };
    var stack = std.ArrayList(Frame){};
    defer stack.deinit(alloc);
    try stack.append(alloc, .{
        .tape = span.tape,
        .pos = span.start + 1,
        .end = span.end - 1,
    });

    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.pos >= top.end) {
            _ = stack.pop();
            continue;
        }
        const elem = tapeEntryToValue(top.tape, top.pos);
        top.pos = skipEntry(top.tape.*, top.pos);
        switch (elem) {
            .array => |inner_span| {
                try stack.append(alloc, .{
                    .tape = inner_span.tape,
                    .pos = inner_span.start + 1,
                    .end = inner_span.end - 1,
                });
            },
            else => try out.append(alloc, elem),
        }
    }
}

/// Compact JSON serialization of a Value into a buffer (for tostring builtin).
/// Append a JSON-encoded string (with surrounding quotes) to buf.
/// Uses standard JSON escape sequences (\n, \t, \r, \b, \f) for common
/// control characters, matching jq's output format.
fn appendJsonString(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}!void {
    try buf.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            0x08 => try buf.appendSlice(alloc, "\\b"),
            0x0C => try buf.appendSlice(alloc, "\\f"),
            else => {
                if (c < 0x20) {
                    var tmp: [6]u8 = undefined;
                    const seq = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                    try buf.appendSlice(alloc, seq);
                } else {
                    try buf.append(alloc, c);
                }
            },
        }
    }
    try buf.append(alloc, '"');
}

/// Iterative compact serializer. Uses an explicit container-frame stack so
/// deeply nested structures cannot overflow the native thread stack
/// (worker threads run with `THREAD_STACK_SIZE = 2 MiB`, while jq accepts
/// up to `SERIALIZE_DEPTH_LIMIT = 10001` levels of nesting). Once the
/// effective container depth equals or exceeds `SERIALIZE_DEPTH_LIMIT`,
/// emits the sentinel `<skipped: too deep>` in place of the offending
/// container — matching jq's `jv_dump_recurse` truncation semantics —
/// and continues without descending into it.
fn serializeValueCompact(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, val: Value) error{OutOfMemory}!void {
    // Fast path for scalars: avoid any heap allocation.
    switch (val) {
        .array, .object => {},
        else => return writeScalar(buf, alloc, val),
    }

    const Frame = struct {
        tape: *const Tape,
        pos: u32,
        end: u32,
        is_object: bool,
        first: bool,
    };

    var stack = std.ArrayList(Frame){};
    defer stack.deinit(alloc);

    // Push the root container.
    switch (val) {
        .array => |span| {
            try buf.append(alloc, '[');
            try stack.append(alloc, .{
                .tape = span.tape,
                .pos = span.start + 1,
                .end = span.end - 1,
                .is_object = false,
                .first = true,
            });
        },
        .object => |span| {
            try buf.append(alloc, '{');
            try stack.append(alloc, .{
                .tape = span.tape,
                .pos = span.start + 1,
                .end = span.end - 1,
                .is_object = true,
                .first = true,
            });
        },
        else => unreachable,
    }

    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.pos >= top.end) {
            try buf.append(alloc, if (top.is_object) '}' else ']');
            _ = stack.pop();
            continue;
        }
        if (!top.first) try buf.append(alloc, ',');
        top.first = false;

        var child_pos = top.pos;
        if (top.is_object) {
            const key_str = top.tape.getString(top.tape.entries[child_pos].payload.string);
            try buf.append(alloc, '"');
            try buf.appendSlice(alloc, key_str);
            try buf.appendSlice(alloc, "\":");
            child_pos += 1; // step over key
        }
        const child_val = tapeEntryToValue(top.tape, child_pos);
        // Advance the parent's pos past this child before any potential push,
        // so when we return after the nested container closes we resume at
        // the correct sibling.
        top.pos = skipEntry(top.tape.*, child_pos);

        switch (child_val) {
            .array => |span| {
                if (stack.items.len >= SERIALIZE_DEPTH_LIMIT) {
                    try buf.appendSlice(alloc, SERIALIZE_DEPTH_SENTINEL);
                } else {
                    try buf.append(alloc, '[');
                    try stack.append(alloc, .{
                        .tape = span.tape,
                        .pos = span.start + 1,
                        .end = span.end - 1,
                        .is_object = false,
                        .first = true,
                    });
                }
            },
            .object => |span| {
                if (stack.items.len >= SERIALIZE_DEPTH_LIMIT) {
                    try buf.appendSlice(alloc, SERIALIZE_DEPTH_SENTINEL);
                } else {
                    try buf.append(alloc, '{');
                    try stack.append(alloc, .{
                        .tape = span.tape,
                        .pos = span.start + 1,
                        .end = span.end - 1,
                        .is_object = true,
                        .first = true,
                    });
                }
            },
            else => try writeScalar(buf, alloc, child_val),
        }
    }
}

/// Append a non-container value's compact JSON form. Containers are
/// rejected by callers before reaching this helper.
fn writeScalar(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, val: Value) error{OutOfMemory}!void {
    switch (val) {
        .null_val => try buf.appendSlice(alloc, "null"),
        .bool_val => |b| try buf.appendSlice(alloc, if (b) "true" else "false"),
        .int => |n| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
            try buf.appendSlice(alloc, s);
        },
        .float => |f| {
            const formatted = types.formatJqFloat(f);
            try buf.appendSlice(alloc, formatted.slice());
        },
        .big_number => |bn| try buf.appendSlice(alloc, bn),
        .string => |sv| try appendJsonString(buf, alloc, sv.slice()),
        .array, .object => unreachable,
    }
}

/// Append a value's compact JSON form to `buf`, applying jq 1.8.1's
/// `jv_dump_string_trunc` rule for embedded value renderings inside
/// TypeError messages: if the JSON form is longer than 14 bytes,
/// truncate to the longest UTF-8-aligned prefix that fits in 11 bytes
/// and append `...` (no closing quote/bracket).  Mirrors jq's `errbuf[15]`
/// + `strncpy` + `jvp_utf8_backtrack` logic in `src/builtin.c::type_error`.
///
/// The full serialization is built into a temporary buffer first so the
/// truncation decision is made on the final byte length, not on partial
/// output (matching jq's behavior of always producing full JSON before
/// truncation).
fn appendCompactJsonTrunc(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, val: Value) error{OutOfMemory}!void {
    var tmp = std.ArrayList(u8){};
    defer tmp.deinit(alloc);
    try serializeValueCompact(&tmp, alloc, val);
    const full = tmp.items;
    // jq uses `errbuf[15]` and treats `len > bufsize - 1 = 14` as the
    // truncation trigger.  Below the threshold, emit verbatim.
    if (full.len <= 14) {
        try buf.appendSlice(alloc, full);
        return;
    }
    // Find the longest UTF-8-aligned prefix length <= 11.  jq's logic
    // walks back from byte index 11 to the start of any UTF-8 codepoint
    // it might be in the middle of; the result `s` is the codepoint
    // start, and all bytes [0, s - outbuf) are kept.
    const cut: usize = utf8AlignedTruncate(full, 11);
    try buf.appendSlice(alloc, full[0..cut]);
    try buf.appendSlice(alloc, "...");
}

/// Return the largest index `<= max_bytes` that is a UTF-8 codepoint
/// boundary in `s`, walking back from `max_bytes` over any continuation
/// bytes.  Mirrors `jvp_utf8_backtrack` semantics: if byte at `max_bytes`
/// is a continuation byte, walk back until a lead byte is found and
/// return that lead byte's index (so the partial codepoint is dropped).
/// If the byte at `max_bytes` is itself a lead/ASCII, it is also dropped
/// because jq's caller treats `s` as the codepoint START — bytes [0, s)
/// are preserved; bytes [s, max_bytes] are replaced with `...`.
fn utf8AlignedTruncate(s: []const u8, max_bytes: usize) usize {
    if (max_bytes >= s.len) return s.len;
    var i: usize = max_bytes;
    // Walk back over any continuation bytes (0b10xxxxxx).
    while (i > 0 and (s[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

/// Append the jq type name for a Value to a buffer.
fn appendTypeName(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, val: Value) error{OutOfMemory}!void {
    const name: []const u8 = switch (val) {
        .null_val => "null",
        .bool_val => "boolean",
        .int, .float, .big_number => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
    try buf.appendSlice(alloc, name);
}

/// Check if a Unicode codepoint is whitespace per jq's trim definition.
/// Matches: \t \n \v \f \r \x20 \u0085 \u00A0 \u1680 \u2000-\u200A
///          \u2028 \u2029 \u202F \u205F \u3000
fn isUnicodeWhitespace(cp: u21) bool {
    return switch (cp) {
        '\t', '\n', 0x0B, 0x0C, '\r', ' ' => true,
        0x0085, 0x00A0, 0x1680 => true,
        0x2000...0x200A => true,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// Convert a StackValue to a Value for output.
fn stackValueToValue(sv: StackValue) ZqError!Value {
    return switch (sv) {
        .null_val => .null_val,
        .bool_val => |b| .{ .bool_val = b },
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .big_number => |bn| .{ .big_number = bn },
        .tape_value => |tv| tv,
    };
}

/// Convert a Value to a StackValue for expression evaluation.
fn valueToStackValue(v: Value) ZqError!StackValue {
    return switch (v) {
        .null_val => .null_val,
        .bool_val => |b| .{ .bool_val = b },
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .big_number => |bn| .{ .big_number = bn },
        .string => |s| .{ .tape_value = .{ .string = s } },
        .object => |o| .{ .tape_value = .{ .object = o } },
        .array => |a| .{ .tape_value = .{ .array = a } },
    };
}

// ── Tape helpers ──────────────────────────────────────────────────────────────

/// Half-open live runtime-tape interval used by `compactRuntimeTape` to
/// describe reachable regions before merging and packing.
const LiveInterval = struct {
    start: u32,
    end: u32,
    fn lessThan(_: void, a: LiveInterval, b: LiveInterval) bool {
        if (a.start != b.start) return a.start < b.start;
        return a.end < b.end;
    }
};

/// Append `[span.start, span.end)` to `out` if `sv` is a container span on
/// `target`. Strings and scalars contribute no interval.
fn collectFromValue(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(LiveInterval),
    sv: Value,
    target: *const Tape,
) error{OutOfMemory}!void {
    switch (sv) {
        .object, .array => |s| {
            if (s.tape == target and s.end > s.start) {
                try out.append(alloc, .{ .start = s.start, .end = s.end });
            }
        },
        else => {},
    }
}

fn collectFromStackValue(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(LiveInterval),
    v: StackValue,
    target: *const Tape,
) error{OutOfMemory}!void {
    switch (v) {
        .tape_value => |tv| try collectFromValue(alloc, out, tv, target),
        else => {},
    }
}

/// Translate a runtime-tape container span's `start`/`end` through the
/// `compactRuntimeTape` mapping. Non-spans, strings, and spans on other
/// tapes are left untouched.
fn translateValueSpan(v: *Value, target: *const Tape, translation: []const u32) void {
    switch (v.*) {
        .object => |old| {
            if (old.tape == target) {
                v.* = .{ .object = .{
                    .tape = target,
                    .start = translation[old.start],
                    .end = translation[old.end],
                } };
            }
        },
        .array => |old| {
            if (old.tape == target) {
                v.* = .{ .array = .{
                    .tape = target,
                    .start = translation[old.start],
                    .end = translation[old.end],
                } };
            }
        },
        else => {},
    }
}

fn translateStackValueSpan(v: *StackValue, target: *const Tape, translation: []const u32) void {
    switch (v.*) {
        .tape_value => |*tv| translateValueSpan(tv, target, translation),
        else => {},
    }
}

fn tapeEntryToValue(tape: *const Tape, pos: u32) Value {
    const e = tape.entries[pos];
    return switch (e.tag) {
        .null_val => .null_val,
        .true_val => .{ .bool_val = true },
        .false_val => .{ .bool_val = false },
        .int => .{ .int = e.payload.int },
        .float => .{ .float = e.payload.float },
        .string => .{ .string = .{ .tape_ref = .{ .tape = tape, .ref = e.payload.string } } },
        .big_number => .{ .big_number = tape.getString(e.payload.string) },
        .object_start => .{ .object = .{ .tape = tape, .start = pos, .end = e.payload.skip } },
        .array_start => .{ .array = .{ .tape = tape, .start = pos, .end = e.payload.skip } },
        // These tags are never returned as values.
        .key, .object_end, .array_end => unreachable,
    };
}

/// Return the tape index of the first entry after the entry at `pos`.
/// Containers jump using their skip pointer; scalars advance by 1.
fn skipEntry(tape: Tape, pos: u32) u32 {
    return switch (tape.entries[pos].tag) {
        .object_start => tape.entries[pos].payload.skip,
        .array_start => tape.entries[pos].payload.skip,
        else => pos + 1,
    };
}

fn lookupKeyInValue(
    _: *const Tape,
    allow_null: bool,
    val: Value,
    key: []const u8,
) ZqError!Value {
    return switch (val) {
        // Missing key on an object always yields null — this is not an error.
        // Use span.tape (not the passed tape) so runtime-tape objects work correctly.
        .object => |span| lookupKey(span.tape, span, key) orelse .null_val,
        // Accessing a key on null yields null (jq semantics).
        .null_val => .null_val,
        else => if (allow_null) .null_val else error.TypeError,
    };
}

fn lookupKey(tape: *const Tape, span: Value.TapeSpan, key: []const u8) ?Value {
    var pos = span.start + 1;
    const end = span.end - 1; // position of object_end
    while (pos < end) {
        const k = tape.getString(tape.entries[pos].payload.string);
        const val_pos = pos + 1;
        if (std.mem.eql(u8, k, key)) return tapeEntryToValue(tape, val_pos);
        pos = skipEntry(tape.*, val_pos);
    }
    return null;
}

/// Get the length of an array span.
fn arrayLength(tape: *const Tape, span: Value.TapeSpan) u32 {
    var pos = span.start + 1;
    const end = span.end - 1; // position of array_end
    var len: u32 = 0;
    while (pos < end) {
        pos = skipEntry(tape.*, pos);
        len += 1;
    }
    return len;
}

/// jq float-as-array-index semantics for `has/1` and `in/1`:
///   NaN / ±Inf       → false
///   −1 < f < 0       → index 0 (trunc toward zero); valid iff len > 0
///   f ≤ −1           → false
///   f ≥ 0            → valid iff f < len (float-domain compare avoids
///                      i64 overflow for huge floats; for non-negative f,
///                      trunc(f) < len ⇔ f < len since len is integral).
fn floatIndexInBounds(f: f64, len: u32) bool {
    if (std.math.isNan(f) or std.math.isInf(f)) return false;
    if (f < 0) {
        if (f <= -1.0) return false;
        return len > 0;
    }
    return f < @as(f64, @floatFromInt(len));
}

fn lookupIndex(tape: *const Tape, span: Value.TapeSpan, idx: u32) ?Value {
    var pos = span.start + 1;
    const end = span.end - 1; // position of array_end
    var i: u32 = 0;
    while (pos < end) {
        if (i == idx) return tapeEntryToValue(tape, pos);
        pos = skipEntry(tape.*, pos);
        i += 1;
    }
    return null;
}

/// Write a Value to a RuntimeTape. Used by setpath/delpaths to build results
/// on a temporary tape without self-reference issues.
fn writeValueToTape(tape: *types.RuntimeTape, alloc: std.mem.Allocator, val: Value) !void {
    switch (val) {
        .null_val => {
            _ = try tape.appendEntry(alloc, .{
                .tag = .null_val,
                .payload = .{ .none = {} },
            });
        },
        .bool_val => |b| {
            _ = try tape.appendEntry(alloc, .{
                .tag = if (b) .true_val else .false_val,
                .payload = .{ .none = {} },
            });
        },
        .int => |i| {
            _ = try tape.appendEntry(alloc, .{
                .tag = .int,
                .payload = .{ .int = i },
            });
        },
        .float => |f| {
            _ = try tape.appendEntry(alloc, .{
                .tag = .float,
                .payload = .{ .float = f },
            });
        },
        .string => |sv| {
            const str_ref = try tape.internString(alloc, sv.slice());
            _ = try tape.appendEntry(alloc, .{
                .tag = .string,
                .payload = .{ .string = str_ref },
            });
        },
        .object => |span| {
            try tape.copySpan(span.tape.*, span.start, span.end, alloc);
        },
        .array => |span| {
            try tape.copySpan(span.tape.*, span.start, span.end, alloc);
        },
        .big_number => |bn| {
            const str_ref = try tape.internString(alloc, bn);
            _ = try tape.appendEntry(alloc, .{
                .tag = .big_number,
                .payload = .{ .string = str_ref },
            });
        },
    }
}

// ── Date/time builtins ──────────────────────────────────────────────────────

const BrokenDownTime = struct {
    year: i64,
    month: i64, // 0-based (0=Jan, 11=Dec)
    mday: i64, // 1-based (1-31)
    hour: i64, // 0-23
    min: i64, // 0-59
    sec: i64, // 0-59 (integer part)
    sec_frac: f64, // fractional seconds (0.0–0.999…)
    wday: i64, // 0=Sunday, 6=Saturday
    yday: i64, // 0-based day of year
};

/// Hinnant civil_from_days: convert days since Unix epoch → (year, month 1-based, day).
/// Handles negative days (pre-1970) correctly.
/// Reference: https://howardhinnant.github.io/date_algorithms.html
fn civilFromDays(days_in: i64) struct { year: i64, month: i64, day: i64 } {
    // Shift to a March-based epoch (March 1, 0000).
    const z: i64 = days_in + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097; // [0, 146096]
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp: i64 = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m: i64 = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    const yr: i64 = if (m <= 2) y + 1 else y;
    return .{ .year = yr, .month = m, .day = d };
}

/// Hinnant days_from_civil: convert (year, month 1-based, day) → days since Unix epoch.
fn daysFromCivil(year_in: i64, month_in: i64, day: i64) i64 {
    const y: i64 = if (month_in <= 2) year_in - 1 else year_in;
    const m: i64 = if (month_in <= 2) month_in + 9 else month_in - 3; // March-based [0, 11]
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const doy: i64 = @divFloor(153 * m + 2, 5) + day - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

const days_in_months = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

fn dayOfYear(year: i64, month_0: i64, mday: i64) i64 {
    var yday: i64 = 0;
    var m: i64 = 0;
    while (m < month_0 and m < 12) : (m += 1) {
        yday += days_in_months[@intCast(@mod(m, 12))];
        if (m == 1 and isLeapYear(year)) yday += 1;
    }
    return yday + mday - 1;
}

/// Day of week: 0=Sunday, 1=Monday, … 6=Saturday.
fn dayOfWeek(days_since_epoch: i64) i64 {
    // 1970-01-01 was Thursday (4). Add 4 and mod 7.
    return @mod(days_since_epoch + 4, 7);
}

fn unixToDatetime(ts: i64, frac: f64) BrokenDownTime {
    const days = @divFloor(ts, 86400);
    const rem = @mod(ts, 86400);
    const civil = civilFromDays(days);
    const month_0 = civil.month - 1; // Convert to 0-based
    return .{
        .year = civil.year,
        .month = month_0,
        .mday = civil.day,
        .hour = @divFloor(rem, 3600),
        .min = @mod(@divFloor(rem, 60), 60),
        .sec = @mod(rem, 60),
        .sec_frac = frac,
        .wday = dayOfWeek(days),
        .yday = dayOfYear(civil.year, month_0, civil.day),
    };
}

fn datetimeToUnix(year: i64, month_0: i64, mday: i64, hour: i64, min: i64, sec: i64) i64 {
    const month_1 = month_0 + 1; // Convert to 1-based
    const days = daysFromCivil(year, month_1, mday);
    return days * 86400 + hour * 3600 + min * 60 + sec;
}

// POSIX "C" locale day/month names — single source of truth for strftime
// %A/%a/%B/%b. Abbreviations are derived from the full names at comptime
// (POSIX C locale uses the first 3 chars of every full name verbatim), so
// any future locale change propagates from one place.
const weekday_names = [7][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const month_names = [12][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const weekday_abbrs = blk: {
    var out: [7][]const u8 = undefined;
    for (weekday_names, 0..) |name, i| out[i] = name[0..3];
    break :blk out;
};
const month_abbrs = blk: {
    var out: [12][]const u8 = undefined;
    for (month_names, 0..) |name, i| out[i] = name[0..3];
    break :blk out;
};

fn formatDatetime(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, fmt: []const u8, bd: BrokenDownTime) !void {
    var tmp: [64]u8 = undefined;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            try buf.append(alloc, fmt[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= fmt.len) break;
        const spec = fmt[i];
        i += 1;
        switch (spec) {
            'Y' => {
                if (bd.year >= 0) {
                    const s = std.fmt.bufPrint(&tmp, "{:0>4}", .{@as(u64, @intCast(bd.year))}) catch unreachable;
                    try buf.appendSlice(alloc, s);
                } else {
                    // Negative year (BCE)
                    try buf.append(alloc, '-');
                    const s = std.fmt.bufPrint(&tmp, "{:0>4}", .{@as(u64, @intCast(-bd.year))}) catch unreachable;
                    try buf.appendSlice(alloc, s);
                }
            },
            'y' => {
                const s = std.fmt.bufPrint(&tmp, "{:0>2}", .{@as(u64, @intCast(@mod(bd.year, 100)))}) catch unreachable;
                try buf.appendSlice(alloc, s);
            },
            'C' => {
                const c = @divFloor(bd.year, 100);
                if (c >= 0) {
                    const s = std.fmt.bufPrint(&tmp, "{:0>2}", .{@as(u64, @intCast(c))}) catch unreachable;
                    try buf.appendSlice(alloc, s);
                } else {
                    try buf.append(alloc, '-');
                    const s = std.fmt.bufPrint(&tmp, "{:0>2}", .{@as(u64, @intCast(-c))}) catch unreachable;
                    try buf.appendSlice(alloc, s);
                }
            },
            'm' => {
                const s = std.fmt.bufPrint(&tmp, "{:0>2}", .{@as(u64, @intCast(bd.month + 1))}) catch unreachable;
                try buf.appendSlice(alloc, s);
            },
            'd' => {
                const s = std.fmt.bufPrint(&tmp, "{:0>2}", .{@as(u64, @intCast(bd.mday))}) catch unreachable;
                try buf.appendSlice(alloc, s);
            },
            'e' => {
                const s = std.fmt.bufPrint(&tmp, "{:>2}", .{@as(u64, @intCast(bd.mday))}) catch unreachable;
                try buf.appendSlice(alloc, s);
            },
            'H' => {
                const s = std.fmt.bufPrint(&tmp, "{:0>2}", .{@as(u64, @intCast(bd.hour))}) catch unreachable;
                try buf.appendSlice(alloc, s);
            },
            'I' => {
                const h = @mod(bd.hour + 11, 12) + 1;
                const s = std.fmt.bufPrint(&tmp, "{:0>2}", .{@as(u64, @intCast(h))}) catch unreachable;
                try buf.appendSlice(alloc, s);
            },
            'M' => {
                const s = std.fmt.bufPrint(&tmp, "{:0>2}", .{@as(u64, @intCast(bd.min))}) catch unreachable;
                try buf.appendSlice(alloc, s);
            },
            'S' => {
                const s = std.fmt.bufPrint(&tmp, "{:0>2}", .{@as(u64, @intCast(bd.sec))}) catch unreachable;
                try buf.appendSlice(alloc, s);
            },
            'j' => {
                const s = std.fmt.bufPrint(&tmp, "{:0>3}", .{@as(u64, @intCast(bd.yday + 1))}) catch unreachable;
                try buf.appendSlice(alloc, s);
            },
            'A' => try buf.appendSlice(alloc, weekday_names[@intCast(@mod(bd.wday, 7))]),
            'a' => try buf.appendSlice(alloc, weekday_abbrs[@intCast(@mod(bd.wday, 7))]),
            'B' => try buf.appendSlice(alloc, month_names[@intCast(@mod(bd.month, 12))]),
            'b', 'h' => try buf.appendSlice(alloc, month_abbrs[@intCast(@mod(bd.month, 12))]),
            'w' => {
                const s = std.fmt.bufPrint(&tmp, "{}", .{@as(u64, @intCast(@mod(bd.wday, 7)))}) catch unreachable;
                try buf.appendSlice(alloc, s);
            },
            'u' => {
                const u = if (bd.wday == 0) @as(i64, 7) else bd.wday;
                const s = std.fmt.bufPrint(&tmp, "{}", .{@as(u64, @intCast(u))}) catch unreachable;
                try buf.appendSlice(alloc, s);
            },
            'p' => try buf.appendSlice(alloc, if (bd.hour < 12) "AM" else "PM"),
            'P' => try buf.appendSlice(alloc, if (bd.hour < 12) "am" else "pm"),
            'Z' => try buf.appendSlice(alloc, "UTC"),
            'z' => try buf.appendSlice(alloc, "+0000"),
            'n' => try buf.append(alloc, '\n'),
            't' => try buf.append(alloc, '\t'),
            '%' => try buf.append(alloc, '%'),
            // Composite specifiers
            'D' => try formatDatetime(buf, alloc, "%m/%d/%y", bd),
            'F' => try formatDatetime(buf, alloc, "%Y-%m-%d", bd),
            'T' => try formatDatetime(buf, alloc, "%H:%M:%S", bd),
            'R' => try formatDatetime(buf, alloc, "%H:%M", bd),
            'c' => try formatDatetime(buf, alloc, "%a %b %e %T %Y", bd),
            'x' => try formatDatetime(buf, alloc, "%m/%d/%y", bd),
            'X' => try formatDatetime(buf, alloc, "%H:%M:%S", bd),
            'U' => {
                // Week of year (Sunday start)
                const w = @divFloor(bd.yday + 7 - @mod(bd.wday, 7), 7);
                const s = std.fmt.bufPrint(&tmp, "{:0>2}", .{@as(u64, @intCast(w))}) catch unreachable;
                try buf.appendSlice(alloc, s);
            },
            'W' => {
                // Week of year (Monday start)
                const w = @divFloor(bd.yday + 7 - @mod(bd.wday + 6, 7), 7);
                const s = std.fmt.bufPrint(&tmp, "{:0>2}", .{@as(u64, @intCast(w))}) catch unreachable;
                try buf.appendSlice(alloc, s);
            },
            else => {
                // Unknown specifier: output literally
                try buf.append(alloc, '%');
                try buf.append(alloc, spec);
            },
        }
    }
}

fn parseDigits(input: []const u8, start: usize, max_digits: usize) struct { val: i64, end: usize } {
    var end = start;
    const limit = @min(start + max_digits, input.len);
    while (end < limit and input[end] >= '0' and input[end] <= '9') : (end += 1) {}
    if (end == start) return .{ .val = 0, .end = start };
    var val: i64 = 0;
    for (input[start..end]) |ch| {
        val = val * 10 + @as(i64, ch - '0');
    }
    return .{ .val = val, .end = end };
}

fn parseDatetime(input: []const u8, fmt: []const u8) error{ParseError}!BrokenDownTime {
    var bd = BrokenDownTime{
        .year = 0,
        .month = 0,
        .mday = 0,
        .hour = 0,
        .min = 0,
        .sec = 0,
        .sec_frac = 0.0,
        .wday = 0,
        .yday = 0,
    };
    var fi: usize = 0;
    var ii: usize = 0;
    while (fi < fmt.len) {
        if (fmt[fi] != '%') {
            // Literal match
            if (ii >= input.len or input[ii] != fmt[fi]) return error.ParseError;
            fi += 1;
            ii += 1;
            continue;
        }
        fi += 1;
        if (fi >= fmt.len) break;
        const spec = fmt[fi];
        fi += 1;
        switch (spec) {
            'Y' => {
                const r = parseDigits(input, ii, 4);
                if (r.end == ii) return error.ParseError;
                bd.year = r.val;
                ii = r.end;
            },
            'y' => {
                const r = parseDigits(input, ii, 2);
                if (r.end == ii) return error.ParseError;
                bd.year = if (r.val >= 69) 1900 + r.val else 2000 + r.val;
                ii = r.end;
            },
            'm' => {
                const r = parseDigits(input, ii, 2);
                if (r.end == ii) return error.ParseError;
                bd.month = r.val - 1;
                ii = r.end;
            },
            'd', 'e' => {
                // Skip leading spaces for %e
                while (ii < input.len and input[ii] == ' ') ii += 1;
                const r = parseDigits(input, ii, 2);
                if (r.end == ii) return error.ParseError;
                bd.mday = r.val;
                ii = r.end;
            },
            'H' => {
                const r = parseDigits(input, ii, 2);
                if (r.end == ii) return error.ParseError;
                bd.hour = r.val;
                ii = r.end;
            },
            'I' => {
                const r = parseDigits(input, ii, 2);
                if (r.end == ii) return error.ParseError;
                bd.hour = r.val;
                ii = r.end;
            },
            'M' => {
                const r = parseDigits(input, ii, 2);
                if (r.end == ii) return error.ParseError;
                bd.min = r.val;
                ii = r.end;
            },
            'S' => {
                const r = parseDigits(input, ii, 2);
                if (r.end == ii) return error.ParseError;
                bd.sec = r.val;
                ii = r.end;
            },
            'j' => {
                const r = parseDigits(input, ii, 3);
                if (r.end == ii) return error.ParseError;
                bd.yday = r.val - 1;
                ii = r.end;
            },
            'Z' => {
                // Skip timezone name
                while (ii < input.len and input[ii] != ' ' and input[ii] != '+' and input[ii] != '-' and !(input[ii] >= '0' and input[ii] <= '9')) ii += 1;
            },
            'z' => {
                // Skip timezone offset (+0000 or +00:00)
                if (ii < input.len and (input[ii] == '+' or input[ii] == '-')) {
                    ii += 1;
                    const r = parseDigits(input, ii, 4);
                    ii = r.end;
                    if (ii < input.len and input[ii] == ':') {
                        ii += 1;
                        const r2 = parseDigits(input, ii, 2);
                        ii = r2.end;
                    }
                }
            },
            'n' => {
                if (ii < input.len and input[ii] == '\n') ii += 1;
            },
            't' => {
                if (ii < input.len and (input[ii] == '\t' or input[ii] == ' ')) ii += 1;
            },
            '%' => {
                if (ii >= input.len or input[ii] != '%') return error.ParseError;
                ii += 1;
            },
            'A', 'a' => {
                // Match weekday name — find match
                var found = false;
                for (weekday_names, 0..) |name, idx| {
                    if (ii + name.len <= input.len and std.mem.eql(u8, input[ii..][0..name.len], name)) {
                        bd.wday = @intCast(idx);
                        ii += name.len;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    for (weekday_abbrs, 0..) |name, idx| {
                        if (ii + name.len <= input.len and std.mem.eql(u8, input[ii..][0..name.len], name)) {
                            bd.wday = @intCast(idx);
                            ii += name.len;
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) return error.ParseError;
            },
            'B', 'b', 'h' => {
                var found = false;
                for (month_names, 0..) |name, idx| {
                    if (ii + name.len <= input.len and std.mem.eql(u8, input[ii..][0..name.len], name)) {
                        bd.month = @intCast(idx);
                        ii += name.len;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    for (month_abbrs, 0..) |name, idx| {
                        if (ii + name.len <= input.len and std.mem.eql(u8, input[ii..][0..name.len], name)) {
                            bd.month = @intCast(idx);
                            ii += name.len;
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) return error.ParseError;
            },
            'p', 'P' => {
                if (ii + 2 <= input.len) {
                    const tok = input[ii..][0..2];
                    if (std.mem.eql(u8, tok, "PM") or std.mem.eql(u8, tok, "pm")) {
                        if (bd.hour < 12) bd.hour += 12;
                        ii += 2;
                    } else if (std.mem.eql(u8, tok, "AM") or std.mem.eql(u8, tok, "am")) {
                        if (bd.hour == 12) bd.hour = 0;
                        ii += 2;
                    }
                }
            },
            'w' => {
                const r = parseDigits(input, ii, 1);
                bd.wday = r.val;
                ii = r.end;
            },
            'u' => {
                const r = parseDigits(input, ii, 1);
                bd.wday = if (r.val == 7) 0 else r.val;
                ii = r.end;
            },
            else => {
                // Unknown specifier — skip one char
                if (ii < input.len) ii += 1;
            },
        }
    }
    // Recompute wday and yday from parsed year/month/mday
    if (bd.year != 0 and bd.mday != 0) {
        const days = daysFromCivil(bd.year, bd.month + 1, bd.mday);
        bd.wday = dayOfWeek(days);
        bd.yday = dayOfYear(bd.year, bd.month, bd.mday);
    }
    return bd;
}
