const std = @import("std");
const ZqError = @import("error").ZqError;
const types = @import("types");
const Parser = @import("parser").Parser;
const Tape = types.Tape;
const Value = types.Value;
const Instruction = types.Instruction;
const BuiltinId = types.BuiltinId;

const max_stack_depth: u32 = 512;
const max_value_stack: u32 = 256;

const IterFrame = struct {
    /// For arrays: position of the current value entry.
    /// For objects: position of the current key entry (value is at pos + 1).
    pos: u32,
    /// Index of the *_end entry — iteration stops when next_pos >= end.
    end: u32,
    /// True when iterating an object (yields values, steps over keys).
    is_object: bool,
    /// Instruction pointer to restore when this frame produces the next element.
    resume_ip: u32,
    /// Pointer to the tape whose entries pos/end index into.
    /// Points to either the input tape or the runtime_tape_view.
    tape: *const Tape,
};

/// State for one active `[expr]` array collection.
/// Pushed by array_collect_start/map_values_start, popped by the matching end op.
const MapValuesEntry = struct {
    iter_pos: u32,
    value: StackValue,
};

const CollectFrame = struct {
    /// Accumulated outputs from the inner expression.
    buffer: std.ArrayList(StackValue),
    /// IterFrame stack depth when collection started.
    /// Used to distinguish inner vs outer iteration frames.
    outer_stack_depth: u32,
    /// RangeFrame stack depth when collection started.
    outer_range_depth: u32,
    /// Value stack depth when collection started.
    /// Used to trim leftover operands after each output.
    outer_value_depth: u32,
    /// if_stack depth when collection started.
    /// Used to clean up save_input entries when the iteration finalization
    /// shortcut bypasses restore_input instructions.
    outer_if_depth: u32,
    /// For map_values: stores (iter_pos, value) pairs for per-key tracking.
    /// Uses |= semantics: only first output per key is kept.
    map_values_entries: std.ArrayList(MapValuesEntry) = std.ArrayList(MapValuesEntry){},
    /// For map_values: the iterate frame pos when the last output was captured.
    map_values_last_iter_pos: u32 = std.math.maxInt(u32),
    /// IP of the matching array_collect_end/map_values_end instruction.
    end_ip: u32,
    /// Non-null for map_values: saves the original input so map_values_end can
    /// reconstruct an object with original keys paired with collected values.
    map_values_input: ?Value = null,
};

/// State for an active `range` generator.
/// Pushed by range/range2/range3 call_builtin; advanced after each output.
const RangeFrame = struct {
    current_int: i64,
    end_int: i64,
    step_int: i64,
    current_float: f64,
    end_float: f64,
    step_float: f64,
    is_float: bool,
    resume_ip: u32,
};

/// State for a comma (fork) operator.
/// When the left side is exhausted, the VM pops this frame,
/// restores the saved input, and jumps to the right side.
const ForkFrame = struct {
    /// IP of the right-side expression.
    right_ip: u32,
    /// Saved input value to restore for the right side.
    saved_input: Value,
    /// Saved stack depths for proper unwinding.
    saved_iter_len: u32,
    saved_range_len: u32,
    saved_value_len: u32,
};

/// State for one active `try` block.
/// Pushed by try_begin, popped by try_end (normal path) or handleCaughtError (error path).
const TryFrame = struct {
    /// IP of the catch handler. 0 = no catch (suppress error silently).
    catch_ip: u32,
    /// Saved stack depths for unwinding on error.
    saved_iter_len: u32,
    saved_value_len: u32,
    saved_if_len: u32,
    saved_collect_len: u32,
    saved_range_len: u32,
    saved_fork_len: u32,
    /// Saved alt_null_depth so the counter is restored correctly on error.
    saved_alt_null_depth: u32,
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
    /// A view into the Tape for objects/arrays/strings.
    tape_value: Value,
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
    /// Frame stack for iteration (.iterate opcode).
    stack: std.ArrayList(IterFrame),
    /// Value stack for expression evaluation.
    value_stack: std.ArrayList(StackValue),
    /// Variable storage for variable capture and reference.
    variable_store: std.ArrayList(?StackValue),
    /// Mutable runtime tape for constructing objects/arrays at query time.
    runtime_tape: types.RuntimeTape,
    /// Persistent Tape view of runtime_tape for value references.
    runtime_tape_view: types.Tape,
    /// Object construction state.
    object_construct: std.ArrayList(ObjectField),
    /// Stack of saved `current` values for if/elif branch restoration.
    /// save_input pushes; restore_input pops.
    if_stack: std.ArrayList(Value),
    /// Active array collection frames. Pushed by array_collect_start.
    collect_stack: std.ArrayList(CollectFrame),
    /// Active try frames. Pushed by try_begin, popped by try_end or handleCaughtError.
    try_stack: std.ArrayList(TryFrame),
    /// Active range generator frames. Pushed by range/range2/range3 builtins.
    range_stack: std.ArrayList(RangeFrame),
    /// Fork frames for comma operator. Pushed by fork opcode.
    fork_stack: std.ArrayList(ForkFrame),
    /// Value stored by the `error` builtin so the catch handler can retrieve it.
    user_error_msg: ?Value,
    alloc: std.mem.Allocator,
    done: bool,
    /// Defers initial tapeEntryToValue(&self.tape, 0) until after any struct move.
    initialized: bool,
    /// Depth counter for alternative-operator null propagation (incremented by alt_start,
    /// decremented by alt_check). When > 0, missing key lookups return null instead of TypeError,
    /// matching jq's left-side semantics for the // operator.
    alt_null_depth: u32,

    pub fn init(
        instructions: []const Instruction,
        function_table: []const types.FunctionDef,
        string_buf: []const u8,
        opts_allow_null: bool,
        tape: Tape,
        external_bindings: []const ExternalVarBinding,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!ResultIterator {
        var stack = std.ArrayList(IterFrame){};
        errdefer stack.deinit(allocator);
        // Pre-allocate the full depth budget so doIterate can use
        // appendAssumeCapacity — keeping next()'s error set free of OutOfMemory.
        try stack.ensureTotalCapacity(allocator, max_stack_depth);

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

        // Initialize if-branch input stack
        var if_stack = std.ArrayList(Value){};
        errdefer if_stack.deinit(allocator);
        try if_stack.ensureTotalCapacity(allocator, max_stack_depth);

        // Initialize array collect stack (nesting depth rarely exceeds 8)
        var collect_stack = std.ArrayList(CollectFrame){};
        errdefer collect_stack.deinit(allocator);
        try collect_stack.ensureTotalCapacity(allocator, 16);

        // Initialize try frame stack (nesting depth rarely exceeds 8)
        var try_stack = std.ArrayList(TryFrame){};
        errdefer try_stack.deinit(allocator);
        try try_stack.ensureTotalCapacity(allocator, 16);

        // Initialize range frame stack (supports up to max_stack_depth nesting)
        var range_stack = std.ArrayList(RangeFrame){};
        errdefer range_stack.deinit(allocator);
        try range_stack.ensureTotalCapacity(allocator, max_stack_depth);

        // Initialize fork frame stack for comma operator
        var fork_stack = std.ArrayList(ForkFrame){};
        errdefer fork_stack.deinit(allocator);
        try fork_stack.ensureTotalCapacity(allocator, max_stack_depth);

        // Initialize runtime tape
        var runtime_tape = try types.RuntimeTape.init(allocator);
        errdefer runtime_tape.deinit(allocator);

        // Initialize runtime tape view
        const runtime_tape_view = types.Tape{
            .entries = runtime_tape.entries.items,
            .string_buf = runtime_tape.string_buf.items,
        };

        return ResultIterator{
            .tape = tape,
            .instructions = instructions,
            .function_table = function_table,
            .string_buf = string_buf,
            .input_value = undefined, // Will be set on first next() call
            .opts_allow_null = opts_allow_null,
            .ip = 0,
            .current = undefined,
            .stack = stack,
            .value_stack = value_stack,
            .variable_store = variable_store,
            .runtime_tape = runtime_tape,
            .runtime_tape_view = runtime_tape_view,
            .object_construct = object_construct,
            .if_stack = if_stack,
            .collect_stack = collect_stack,
            .try_stack = try_stack,
            .range_stack = range_stack,
            .fork_stack = fork_stack,
            .user_error_msg = null,
            .alloc = allocator,
            .done = false,
            .initialized = false,
            .alt_null_depth = 0,
        };
    }

    /// Free the internal eval stack. Idempotent.
    pub fn deinit(it: *ResultIterator) void {
        it.stack.deinit(it.alloc);
        it.value_stack.deinit(it.alloc);
        it.variable_store.deinit(it.alloc);
        it.object_construct.deinit(it.alloc);
        it.if_stack.deinit(it.alloc);
        for (it.collect_stack.items) |*frame| {
            frame.buffer.deinit(it.alloc);
            frame.map_values_entries.deinit(it.alloc);
        }
        it.collect_stack.deinit(it.alloc);
        it.try_stack.deinit(it.alloc);
        it.range_stack.deinit(it.alloc);
        it.fork_stack.deinit(it.alloc);
        it.runtime_tape.deinit(it.alloc);
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
        it.stack.clearRetainingCapacity();
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
        it.if_stack.clearRetainingCapacity();
        it.alt_null_depth = 0;
        for (it.collect_stack.items) |*frame| {
            frame.buffer.deinit(it.alloc);
            frame.map_values_entries.deinit(it.alloc);
        }
        it.collect_stack.clearRetainingCapacity();
        it.try_stack.clearRetainingCapacity();
        it.range_stack.clearRetainingCapacity();
        it.fork_stack.clearRetainingCapacity();
        it.user_error_msg = null;
        it.runtime_tape.entries.clearRetainingCapacity();
        it.runtime_tape.string_buf.clearRetainingCapacity();
        it.runtime_tape_view = types.Tape{
            .entries = it.runtime_tape.entries.items,
            .string_buf = it.runtime_tape.string_buf.items,
        };
    }

    /// True when null propagation is active: either globally via Opts, or locally
    /// because we are evaluating the left side of a `//` alternative operator.
    inline fn nullAllowed(it: *const ResultIterator) bool {
        return it.opts_allow_null or it.alt_null_depth > 0;
    }

    // ── Value stack operations ──────────────────────────────────────────────────

    fn pushValue(it: *ResultIterator, val: StackValue) void {
        it.value_stack.appendAssumeCapacity(val);
    }

    fn popValue(it: *ResultIterator) ZqError!StackValue {
        if (it.value_stack.items.len == 0) return error.TypeError;
        return it.value_stack.pop() orelse unreachable;
    }

    fn peekValue(it: *ResultIterator) ZqError!StackValue {
        if (it.value_stack.items.len == 0) return error.TypeError;
        return it.value_stack.items[it.value_stack.items.len - 1];
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
                if (it.stack.items.len == 0) {
                    // Check if there's an active inner range frame.
                    if (it.collect_stack.items.len > 0) {
                        const cf = &it.collect_stack.items[it.collect_stack.items.len - 1];
                        if (it.range_stack.items.len > cf.outer_range_depth) {
                            // Range frame belonging to this collect scope: advance it.
                            if (it.advanceRangeFrame()) continue;
                            // Range exhausted; check for more or finalize.
                        }
                    } else if (it.range_stack.items.len > 0) {
                        // Top-level range (no collect scope).
                        if (it.advanceRangeFrame()) continue;
                        // Range exhausted.
                    }
                    // If an array collect frame is waiting to finalize, do it now.
                    // This path is taken when all inner iteration frames are exhausted
                    // after the last collect_output fired.
                    if (it.collect_stack.items.len > 0) {
                        const top_cf = &it.collect_stack.items[it.collect_stack.items.len - 1];
                        if (it.stack.items.len <= top_cf.outer_stack_depth and
                            it.range_stack.items.len <= top_cf.outer_range_depth)
                        {
                            var completed = it.collect_stack.pop().?;
                            defer completed.buffer.deinit(it.alloc);
                            defer completed.map_values_entries.deinit(it.alloc);
                            const result = if (completed.map_values_input) |input|
                                switch (input) {
                                    .object => try it.buildCollectedObject(&completed, input),
                                    else => try it.buildCollectedArrayFromEntries(&completed),
                                }
                            else
                                try it.buildCollectedArray(&completed);
                            it.pushValue(result);
                            // Clean up any save_input entries that were bypassed
                            // when the iteration finalization shortcut skipped
                            // restore_input instructions.
                            it.if_stack.items.len = completed.outer_if_depth;
                            it.ip = completed.end_ip + 1; // skip past collect_end
                            continue;
                        }
                    }
                    // Check for fork frames (comma operator).
                    // When the left side is exhausted, restore input and jump to the
                    // right side. The fork_cleanup instruction at right_ip will pop
                    // the fork frame.
                    if (it.fork_stack.items.len > 0) {
                        const ff = &it.fork_stack.items[it.fork_stack.items.len - 1];
                        if (it.stack.items.len <= ff.saved_iter_len and
                            it.range_stack.items.len <= ff.saved_range_len)
                        {
                            const saved = it.fork_stack.pop().?;
                            it.current = saved.saved_input;
                            it.stack.items.len = saved.saved_iter_len;
                            it.range_stack.items.len = saved.saved_range_len;
                            it.value_stack.items.len = saved.saved_value_len;
                            // Jump to fork_cleanup which pops the fork frame
                            // (already popped above, fork_cleanup will be a no-op)
                            it.ip = saved.right_ip + 1; // skip fork_cleanup
                            continue;
                        }
                    }
                    if (it.collect_stack.items.len == 0 and it.range_stack.items.len == 0) {
                        it.done = true;
                        return null;
                    }
                    // Nothing advanced, we're in a stuck state — mark done.
                    it.done = true;
                    return null;
                }
                // Current instruction sequence is exhausted; advance the topmost
                // iterate frame to its next element. If the frame is also exhausted,
                // check if a fork frame should fire at this depth before looping.
                if (!it.advanceFrame()) {
                    // Frame exhausted and popped. Check if a fork frame at this
                    // depth should fire before trying the next outer iter frame.
                    if (it.fork_stack.items.len > 0) {
                        const ff = &it.fork_stack.items[it.fork_stack.items.len - 1];
                        if (it.stack.items.len <= ff.saved_iter_len and
                            it.range_stack.items.len <= ff.saved_range_len)
                        {
                            const saved = it.fork_stack.pop().?;
                            it.current = saved.saved_input;
                            it.stack.items.len = saved.saved_iter_len;
                            it.range_stack.items.len = saved.saved_range_len;
                            it.value_stack.items.len = saved.saved_value_len;
                            it.ip = saved.right_ip + 1; // skip fork_cleanup
                            continue;
                        }
                    }
                    continue;
                }
                continue;
            }

            const instr = it.instructions[it.ip];
            if (it.execOne(instr)) |maybe_val| {
                if (maybe_val) |v| return v;
                // null → no output produced; continue main loop
            } else |err| {
                if (it.try_stack.items.len > 0) {
                    it.handleCaughtError(err);
                    if (it.done) return null;
                    // Continue executing at catch handler (or done path handled above).
                } else {
                    return err;
                }
            }
        }
    }

    /// Unwind VM state to the saved depths in the active TryFrame and redirect
    /// execution to the catch handler (or terminate if no handler).
    fn handleCaughtError(it: *ResultIterator, err: ZqError) void {
        const frame = it.try_stack.pop().?;

        // Unwind iteration frames to the depth at try_begin.
        it.stack.items.len = frame.saved_iter_len;

        // Unwind value stack.
        it.value_stack.items.len = frame.saved_value_len;

        // Unwind if/input stack.
        it.if_stack.items.len = frame.saved_if_len;

        // Unwind collect frames, freeing their buffers.
        while (it.collect_stack.items.len > frame.saved_collect_len) {
            var cf = it.collect_stack.pop().?;
            cf.buffer.deinit(it.alloc);
            cf.map_values_entries.deinit(it.alloc);
        }

        // Unwind range frames.
        it.range_stack.items.len = frame.saved_range_len;

        // Unwind fork frames.
        it.fork_stack.items.len = frame.saved_fork_len;

        // Restore null-propagation depth.
        it.alt_null_depth = frame.saved_alt_null_depth;

        if (frame.catch_ip > 0) {
            // For UserError, the error message is the value stored by the `error` builtin.
            // For other errors, it's the error type name string.
            if (err == error.UserError) {
                it.current = it.user_error_msg orelse Value{ .string = "null" };
                it.user_error_msg = null;
            } else {
                it.current = Value{ .string = errorToString(err) };
            }
            it.ip = frame.catch_ip;
        } else {
            // No catch (try expr / expr?): suppress the error and signal that this
            // output path is exhausted by setting ip past the instruction sequence.
            // The outer step() loop then advances any remaining iterate frame (e.g.
            // .[] | .foo? continues to the next element) or sets done=true if none.
            // Also trim the value_stack to the active collect frame's outer depth so
            // that leftover operands don't corrupt the next iteration's pipeline input.
            if (it.collect_stack.items.len > 0) {
                const cf = &it.collect_stack.items[it.collect_stack.items.len - 1];
                it.value_stack.items.len = cf.outer_value_depth;
            } else {
                it.value_stack.items.len = 0;
            }
            it.ip = @intCast(it.instructions.len);
        }
    }

    /// Execute a single instruction. Returns:
    ///   .{val} — the instruction produced an output value; caller should yield it.
    ///   null   — no output; caller should continue the main loop.
    ///   error  — a runtime error occurred; caller checks for an active try frame.
    fn execOne(it: *ResultIterator, instr: Instruction) ZqError!?Value {
        switch (instr.op) {
            .identity => {
                it.ip += 1;
                return null;
            },

            .pipe => {
                // Transfer the top of the value stack to it.current so that the
                // right-hand side of a pipe (e.g. builtins, field access) receives
                // the correct input value.  When the stack is empty the current
                // value is already correct (e.g. after iterate or load_key which
                // update it.current directly).
                if (it.value_stack.items.len > 0) {
                    it.current = try stackValueToValue(try it.popValue());
                }
                it.ip += 1;
                return null;
            },

            .output => {
                const val = if (it.value_stack.items.len > 0)
                    try stackValueToValue(try it.popValue())
                else
                    it.current;

                if (it.collect_stack.items.len > 0) {
                    // Collect mode: buffer value instead of yielding.
                    const cf = &it.collect_stack.items[it.collect_stack.items.len - 1];

                    if (cf.map_values_input != null) {
                        // map_values uses |= semantics: only first output per iteration element.
                        // Detect current iterate position from the innermost iter frame.
                        const cur_iter_pos = if (it.stack.items.len > cf.outer_stack_depth)
                            it.stack.items[cf.outer_stack_depth].pos
                        else
                            std.math.maxInt(u32);

                        if (cur_iter_pos != cf.map_values_last_iter_pos) {
                            // New key/element: accept this output and record its iter position
                            cf.map_values_last_iter_pos = cur_iter_pos;
                            try cf.map_values_entries.append(it.alloc, .{
                                .iter_pos = cur_iter_pos,
                                .value = try valueToStackValue(val),
                            });
                        }
                        // else: duplicate output for same key, drop it (|= semantics)
                    } else {
                        try cf.buffer.append(it.alloc, try valueToStackValue(val));
                    }

                    // Trim value_stack back to the depth at collect_start.
                    // This prevents operand leftovers from one iteration contaminating
                    // the next iteration's pipeline input via the pipe opcode.
                    it.value_stack.items.len = cf.outer_value_depth;
                    if (it.stack.items.len > cf.outer_stack_depth or
                        it.range_stack.items.len > cf.outer_range_depth)
                    {
                        // More inner iterations pending (iter frame or range frame): trigger advance.
                        it.ip = @intCast(it.instructions.len);
                    } else {
                        // No more inner iterations: continue to next instruction
                        // (handles sequential comma-separated expressions).
                        it.ip += 1;
                    }
                    return null;
                } else {
                    it.ip += 1;
                    return val;
                }
            },

            .load_key => {
                const result = try lookupKeyInValue(
                    &it.tape,
                    it.nullAllowed(),
                    it.current,
                    instr.operand.string,
                );
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
                const idx_result = try it.doLoadIndex(instr.operand.index);
                it.pushValue(try valueToStackValue(idx_result));
                it.ip += 1;
                return null;
            },

            .load_computed => {
                // Key/index: pop from value_stack if non-empty, else use current.
                const key_sv = if (it.value_stack.items.len > 0)
                    try it.popValue()
                else
                    try valueToStackValue(it.current);
                // Base: pop from if_stack (pushed by save_input before inner expr).
                if (it.if_stack.items.len == 0) return error.TypeError;
                const base = it.if_stack.pop().?;
                it.current = switch (key_sv) {
                    .tape_value => |tv| switch (tv) {
                        .string => |s| switch (base) {
                            .object => |span| lookupKey(span.tape, span, s) orelse
                                if (it.nullAllowed()) @as(Value, .null_val) else return error.TypeError,
                            .null_val => if (it.nullAllowed()) @as(Value, .null_val) else return error.TypeError,
                            else => return error.TypeError,
                        },
                        else => return error.TypeError,
                    },
                    .int => |i| switch (base) {
                        .array => |span| blk: {
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
                        else => return error.TypeError,
                    },
                    else => return error.TypeError,
                };
                it.ip += 1;
                return null;
            },

            .load_path => {
                it.current = try it.doLoadPath(instr.operand.string);
                it.ip += 1;
                return null;
            },

            .slice => {
                const result = try it.doSlice(instr.operand.slice_args);
                it.pushValue(result);
                it.ip += 1;
                return null;
            },

            .navigate_key => {
                it.current = try lookupKeyInValue(&it.tape, it.nullAllowed(), it.current, instr.operand.string);
                it.ip += 1;
                return null;
            },

            .navigate_index => {
                it.current = try it.doLoadIndex(instr.operand.index);
                it.ip += 1;
                return null;
            },

            .update_key => {
                const result = try it.doUpdateKey(instr.operand.string);
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

            .iterate => {
                try it.doIterate(it.ip + 1);
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
                it.pushValue(.{ .tape_value = .{ .string = str } });
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
                it.ip += 1;
                return null;
            },

            .restore_input => {
                if (it.if_stack.items.len == 0) return error.TypeError;
                it.current = it.if_stack.pop().?;
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
                    .outer_stack_depth = @intCast(it.stack.items.len),
                    .outer_range_depth = @intCast(it.range_stack.items.len),
                    .outer_value_depth = @intCast(it.value_stack.items.len),
                    .outer_if_depth = @intCast(it.if_stack.items.len),
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
                defer completed.map_values_entries.deinit(it.alloc);
                const arr_val = try it.buildCollectedArray(&completed);
                it.pushValue(arr_val);
                it.ip += 1;
                return null;
            },

            // map_values construction
            .map_values_start => {
                var buf = std.ArrayList(StackValue){};
                errdefer buf.deinit(it.alloc);
                try buf.ensureTotalCapacity(it.alloc, 32);
                try it.collect_stack.append(it.alloc, CollectFrame{
                    .buffer = buf,
                    .outer_stack_depth = @intCast(it.stack.items.len),
                    .outer_range_depth = @intCast(it.range_stack.items.len),
                    .outer_value_depth = @intCast(it.value_stack.items.len),
                    .outer_if_depth = @intCast(it.if_stack.items.len),
                    .end_ip = @intCast(instr.operand.index),
                    .map_values_input = it.current,
                });
                it.ip += 1;
                return null;
            },

            .map_values_end => {
                var completed = it.collect_stack.pop().?;
                defer completed.buffer.deinit(it.alloc);
                defer completed.map_values_entries.deinit(it.alloc);
                const result = if (completed.map_values_input) |input|
                    switch (input) {
                        .object => try it.buildCollectedObject(&completed, input),
                        else => try it.buildCollectedArrayFromEntries(&completed),
                    }
                else
                    try it.buildCollectedArray(&completed);
                it.pushValue(result);
                it.ip += 1;
                return null;
            },

            // Alternative operator (//)
            .alt_start => {
                it.if_stack.appendAssumeCapacity(it.current);
                it.alt_null_depth += 1;
                it.ip += 1;
                return null;
            },

            .alt_check => {
                // Saturating decrement: guards against re-entry when a generator
                // on the left side drives the VM back to this instruction on
                // subsequent iterations (depth is already 0 after the first pass).
                if (it.alt_null_depth > 0) it.alt_null_depth -= 1;
                const val = if (it.value_stack.items.len > 0)
                    try it.popValue()
                else
                    try valueToStackValue(it.current);
                if (isCondTruthy(val)) {
                    // Left side produced a usable value: clean up the saved input
                    // and jump past the right expression.
                    if (it.if_stack.items.len > 0) _ = it.if_stack.pop();
                    it.pushValue(val);
                    it.ip = @intCast(instr.operand.index);
                } else {
                    // Left side was false/null: fall through to restore_input which
                    // will pop if_stack and reset current for the right expression.
                    it.ip += 1;
                }
                return null;
            },

            // Comma (fork) operator
            .fork_cleanup => {
                // Pop the fork frame when the right side is reached normally
                // (not via IP-exhaustion). Restore the saved input for the right side.
                if (it.fork_stack.items.len > 0) {
                    const ff = &it.fork_stack.items[it.fork_stack.items.len - 1];
                    // If there are still iterate/range frames from the left side,
                    // don't clean up yet — trigger exhaustion handler to advance them.
                    if (it.stack.items.len > ff.saved_iter_len or
                        it.range_stack.items.len > ff.saved_range_len)
                    {
                        it.ip = @intCast(it.instructions.len);
                        return null;
                    }
                    const saved = it.fork_stack.pop().?;
                    it.current = saved.saved_input;
                }
                it.ip += 1;
                return null;
            },
            .fork => {
                if (it.fork_stack.items.len >= max_stack_depth) return error.DepthLimitExceeded;
                it.fork_stack.appendAssumeCapacity(ForkFrame{
                    .right_ip = @intCast(instr.operand.index),
                    .saved_input = it.current,
                    .saved_iter_len = @intCast(it.stack.items.len),
                    .saved_range_len = @intCast(it.range_stack.items.len),
                    .saved_value_len = @intCast(it.value_stack.items.len),
                });
                it.ip += 1;
                return null;
            },

            // Try-catch error handling
            .try_begin => {
                it.try_stack.appendAssumeCapacity(TryFrame{
                    .catch_ip = @intCast(instr.operand.index),
                    .saved_iter_len = @intCast(it.stack.items.len),
                    .saved_value_len = @intCast(it.value_stack.items.len),
                    .saved_if_len = @intCast(it.if_stack.items.len),
                    .saved_collect_len = @intCast(it.collect_stack.items.len),
                    .saved_range_len = @intCast(it.range_stack.items.len),
                    .saved_fork_len = @intCast(it.fork_stack.items.len),
                    .saved_alt_null_depth = it.alt_null_depth,
                });
                it.ip += 1;
                return null;
            },

            .try_end => {
                // Normal (non-error) path: pop the try frame and skip the catch handler.
                _ = it.try_stack.pop();
                const after_ip = instr.operand.index;
                it.ip = if (after_ip > 0) @intCast(after_ip) else it.ip + 1;
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
                it.object_construct.clearRetainingCapacity();
                // Snapshot input so each field's value expression starts from it.
                it.current = it.input_value;
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

                // Restore current to the filter input so the next field's
                // value expression is evaluated against the same context.
                it.current = it.input_value;
                it.ip += 1;
                return null;
            },

            .object_construct_end => {
                const obj = try it.constructObjectFromFields();
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
                    .int => |i| if (i == std.math.minInt(i64))
                        .{ .float = -@as(f64, @floatFromInt(i)) }
                    else
                        .{ .int = -i },
                    .float => |f| .{ .float = -f },
                    else => return error.TypeError,
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

            .def_function => {
                // Function definitions are resolved at compile time
                it.ip += 1;
                return null;
            },

            .call_function => {
                _ = @as(u32, @intCast(instr.operand.index));
                it.ip += 1;
                return null;
            },

            .call_builtin => {
                const bid: BuiltinId = @enumFromInt(@as(u16, @intCast(instr.operand.index)));
                const result = try it.doBuiltin(bid);
                if (result) |val| {
                    it.pushValue(val);
                }
                // doBuiltin advances ip when it sets up generators (range); otherwise advance here.
                // For empty, ip is set past end of instructions — do not advance again.
                // We only advance if doBuiltin didn't already change ip.
                if (bid != .empty and bid != .range and bid != .range2 and bid != .range3) {
                    it.ip += 1;
                }
                return null;
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
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;

        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape_view,
            .start = arr_start,
            .end = arr_end_idx + 1,
        } } };
    }

    /// Build an array from map_values entries (for arrays with |= semantics).
    fn buildCollectedArrayFromEntries(it: *ResultIterator, frame: *const CollectFrame) ZqError!StackValue {
        const entries = frame.map_values_entries.items;
        const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });
        // Refresh view after appendEntry may have reallocated
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        for (entries) |entry| {
            try it.stackValueToRuntimeTapeEntry(entry.value);
            // Refresh after each append since entry.value may reference runtime_tape_view
            it.runtime_tape_view.entries = it.runtime_tape.entries.items;
            it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        }
        const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape_view,
            .start = arr_start,
            .end = arr_end_idx + 1,
        } } };
    }

    /// Build an object from map_values entries paired with original object keys.
    /// Uses iter_pos to match entries with keys, implementing |= semantics:
    /// keys with no output are deleted, only first output per key is kept.
    /// Estimate tape entries and string bytes needed for a StackValue.
    fn estimateStackValueFootprint(sv: StackValue, n_entries: *usize, n_str_bytes: *usize) void {
        switch (sv) {
            .null_val, .bool_val, .int, .float => n_entries.* += 1,
            .tape_value => |tv| switch (tv) {
                .string => |s| {
                    n_entries.* += 1;
                    n_str_bytes.* += s.len;
                },
                .array => |span| {
                    n_entries.* += span.end - span.start;
                    for (span.tape.entries[span.start..span.end]) |e| {
                        if (e.tag == .string or e.tag == .key) n_str_bytes.* += e.payload.string.len;
                    }
                },
                .object => |span| {
                    n_entries.* += span.end - span.start;
                    for (span.tape.entries[span.start..span.end]) |e| {
                        if (e.tag == .string or e.tag == .key) n_str_bytes.* += e.payload.string.len;
                    }
                },
                else => n_entries.* += 1,
            },
        }
    }

    fn buildCollectedObject(it: *ResultIterator, frame: *const CollectFrame, input: Value) ZqError!StackValue {
        const span = input.object;
        const entries = frame.map_values_entries.items;

        // Pre-reserve capacity to prevent reallocation during the loop,
        // which would invalidate span.tape pointers if it references runtime_tape_view.
        // Include value footprint estimates for nested objects/arrays.
        var estimated_tape_entries: usize = 2; // obj_start + obj_end
        var n_string_bytes: usize = 0;
        {
            var p = span.start + 1;
            const e = span.end - 1;
            while (p < e) {
                n_string_bytes += span.tape.entries[p].payload.string.len;
                p = skipEntry(span.tape.*, p + 1);
            }
        }
        for (entries) |entry| {
            estimated_tape_entries += 2; // key + value shell
            estimateStackValueFootprint(entry.value, &estimated_tape_entries, &n_string_bytes);
        }
        try it.runtime_tape.entries.ensureUnusedCapacity(it.alloc, estimated_tape_entries);
        try it.runtime_tape.string_buf.ensureUnusedCapacity(it.alloc, n_string_bytes);
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;

        const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_start,
            .payload = .{ .skip = 0 },
        });

        // Iterate original object keys and match with map_values_entries by iter_pos.
        // For objects, iterate yields values at pos+1 where pos is the key position.
        // The iter_pos stored in entries is the key position in the original tape.
        var pos = span.start + 1;
        const end = span.end - 1;
        var entry_idx: usize = 0;
        while (pos < end) {
            // Check if this key position has a matching entry
            if (entry_idx < entries.len and entries[entry_idx].iter_pos == pos) {
                const key_str = span.tape.getString(span.tape.entries[pos].payload.string);
                const key_ref = try it.runtime_tape.internString(it.alloc, key_str);
                _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .key, .payload = .{ .string = key_ref } });
                try it.stackValueToRuntimeTapeEntry(entries[entry_idx].value);
                entry_idx += 1;
            }
            // Skip to next key (skip past value)
            pos = skipEntry(span.tape.*, pos + 1);
        }

        const obj_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_end,
            .payload = .{ .none = {} },
        });

        it.runtime_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;

        return .{ .tape_value = .{ .object = .{
            .tape = &it.runtime_tape_view,
            .start = obj_start,
            .end = obj_end_idx + 1,
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
                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .array = .{
                    .tape = &it.runtime_tape_view,
                    .start = arr_start,
                    .end = arr_end_idx + 1,
                } } };
            },
            .string => |s| {
                const len: i32 = @intCast(s.len);
                const from = resolveSliceBound(if (args.has_from) args.from else 0, len);
                const to_resolved = resolveSliceBound(if (args.has_to) args.to else len, len);
                const actual_from: usize = @intCast(from);
                const actual_to: usize = @intCast(if (to_resolved < from) from else to_resolved);
                const str_ref = try it.runtime_tape.internString(it.alloc, s[actual_from..actual_to]);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
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
                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .object = .{
                    .tape = &it.runtime_tape_view,
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
                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .object = .{
                    .tape = &it.runtime_tape_view,
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

        switch (base) {
            .array => |span| {
                const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_start,
                    .payload = .{ .skip = 0 },
                });
                var pos = span.start + 1;
                const end = span.end - 1;
                var i: u32 = 0;
                const resolved_idx = if (idx < 0) blk: {
                    const len = arrayLength(span.tape, span);
                    const neg_idx = @as(i64, @intCast(len)) + idx;
                    if (neg_idx < 0 or neg_idx > std.math.maxInt(u32)) return error.IndexOutOfBounds;
                    break :blk @as(u32, @intCast(neg_idx));
                } else blk: {
                    if (idx > std.math.maxInt(u32)) return error.IndexOutOfBounds;
                    break :blk @as(u32, @intCast(idx));
                };
                while (pos < end) {
                    if (i == resolved_idx) {
                        try it.stackValueToRuntimeTapeEntry(new_val);
                    } else {
                        const orig_val = tapeEntryToValue(span.tape, pos);
                        try it.stackValueToRuntimeTapeEntry(try valueToStackValue(orig_val));
                    }
                    pos = skipEntry(span.tape.*, pos);
                    i += 1;
                }
                const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .array = .{
                    .tape = &it.runtime_tape_view,
                    .start = arr_start,
                    .end = arr_end_idx + 1,
                } } };
            },
            else => return error.TypeError,
        }
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
                .int => |ri| blk: {
                    const ov = @addWithOverflow(li, ri);
                    break :blk if (ov[1] == 0) .{ .int = ov[0] } else .{ .float = @as(f64, @floatFromInt(li)) + @as(f64, @floatFromInt(ri)) };
                },
                .float => |rf| .{ .float = @as(f64, @floatFromInt(li)) + rf },
                .null_val => left,
                else => error.TypeError,
            },
            .float => |lf| switch (right) {
                .int => |ri| .{ .float = lf + @as(f64, @floatFromInt(ri)) },
                .float => |rf| .{ .float = lf + rf },
                .null_val => left,
                else => error.TypeError,
            },
            .null_val => switch (right) {
                .null_val => .null_val,
                else => right,
            },
            .tape_value => |ltv| switch (ltv) {
                .string => |ls| switch (right) {
                    .tape_value => |rtv| switch (rtv) {
                        .string => |rs| blk: {
                            // Concatenate strings by appending both into runtime_tape string_buf.
                            const total_len = ls.len + rs.len;
                            const concat_off: u32 = @intCast(it.runtime_tape.string_buf.items.len);
                            try it.runtime_tape.string_buf.appendSlice(it.alloc, ls);
                            try it.runtime_tape.string_buf.appendSlice(it.alloc, rs);
                            it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                            break :blk .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[concat_off..][0..total_len] } };
                        },
                        .null_val => left,
                        else => error.TypeError,
                    },
                    .null_val => left,
                    else => error.TypeError,
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
                            it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                            it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                            break :blk .{ .tape_value = .{ .array = .{
                                .tape = &it.runtime_tape_view,
                                .start = arr_start,
                                .end = arr_end_idx + 1,
                            } } };
                        },
                        .null_val => left,
                        else => error.TypeError,
                    },
                    .null_val => left,
                    else => error.TypeError,
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
                            it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                            it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                            break :blk .{ .tape_value = .{ .object = .{
                                .tape = &it.runtime_tape_view,
                                .start = obj_start,
                                .end = obj_end_idx + 1,
                            } } };
                        },
                        .null_val => left,
                        else => error.TypeError,
                    },
                    .null_val => left,
                    else => error.TypeError,
                },
                .null_val => switch (right) {
                    .null_val => .null_val,
                    else => right,
                },
                else => error.TypeError,
            },
            .bool_val => return error.TypeError,
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
                .int => |ri| blk: {
                    const ov = @subWithOverflow(li, ri);
                    break :blk if (ov[1] == 0) .{ .int = ov[0] } else .{ .float = @as(f64, @floatFromInt(li)) - @as(f64, @floatFromInt(ri)) };
                },
                .float => |rf| .{ .float = @as(f64, @floatFromInt(li)) - rf },
                else => error.TypeError,
            },
            .float => |lf| switch (right) {
                .int => |ri| .{ .float = lf - @as(f64, @floatFromInt(ri)) },
                .float => |rf| .{ .float = lf - rf },
                else => error.TypeError,
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
                            it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                            it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                            break :blk .{ .tape_value = .{ .array = .{
                                .tape = &it.runtime_tape_view,
                                .start = arr_start,
                                .end = arr_end_idx + 1,
                            } } };
                        },
                        else => error.TypeError,
                    },
                    else => error.TypeError,
                },
                else => error.TypeError,
            },
            else => error.TypeError,
        };
    }

    // ── Object construction operations ─────────────────────────────────────────────────

    const ObjectField = struct {
        key: []const u8,
        value: StackValue,
    };

    fn constructObjectFromFields(it: *ResultIterator) ZqError!StackValue {
        // Append object_start entry
        const obj_start_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_start,
            .payload = .{ .skip = 0 }, // Will update after object_end
        });

        // Append key-value pairs
        for (it.object_construct.items) |field| {
            // Intern key string
            const key_ref = try it.runtime_tape.internString(it.alloc, field.key);
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

        // Update runtime_tape_view to point to current runtime_tape state
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;

        // Create tape view and construct object value
        return .{ .tape_value = .{ .object = .{
            .tape = &it.runtime_tape_view,
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
            .tape_value => |tv| switch (tv) {
                .string => |s| {
                    // Intern the string
                    const str_ref = try it.runtime_tape.internString(it.alloc, s);
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
    fn copyTapeSpanToRuntimeTape(it: *ResultIterator, span: types.Value.TapeSpan) ZqError!void {
        // Count exact resources needed by this span.
        const n_entries = span.end - span.start;
        var n_string_bytes: usize = 0;
        for (span.tape.entries[span.start..span.end]) |e| {
            switch (e.tag) {
                .key, .string => n_string_bytes += e.payload.string.len,
                else => {},
            }
        }

        // Reserve without reallocating during the copy.  ensureUnusedCapacity may
        // itself reallocate the backing arrays, so refresh the view afterwards so
        // that span.tape (which may point to &runtime_tape_view) sees the new pointers.
        try it.runtime_tape.entries.ensureUnusedCapacity(it.alloc, n_entries);
        try it.runtime_tape.string_buf.ensureUnusedCapacity(it.alloc, n_string_bytes);
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;

        var pos = span.start;

        // Copy all entries in the span.  No allocation happens below this point.
        while (pos < span.end) {
            const entry = span.tape.entries[pos];

            switch (entry.tag) {
                .object_start, .array_start => {
                    // For container start, we need to copy the container recursively
                    // and track the skip pointer
                    const container_start_idx = try it.runtime_tape.appendEntry(it.alloc, entry);
                    const container_end_idx = entry.payload.skip;
                    // Recursively copy container content (excluding end marker)
                    // Check if there's content to copy (empty container case)
                    if (container_end_idx > pos + 1) {
                        const nested_span = types.Value.TapeSpan{
                            .tape = span.tape,
                            .start = pos + 1,
                            .end = container_end_idx - 1, // Exclude end marker from recursive copy
                        };
                        try it.copyTapeSpanToRuntimeTape(nested_span);
                    }

                    // Append end marker
                    const new_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = if (entry.tag == .object_start) .object_end else .array_end,
                        .payload = .{ .none = {} },
                    });

                    // Update skip pointer to point past the new end
                    it.runtime_tape.entries.items[container_start_idx].payload.skip = new_end_idx + 1;

                    // Skip to after the container in the source tape.
                    // container_end_idx (the skip value) already points past the end marker.
                    pos = container_end_idx;
                },
                .key => {
                    // Intern the key string into runtime_tape.string_buf so that the
                    // copied entry's StringRef is valid within the runtime tape.
                    const key_str = span.tape.getString(entry.payload.string);
                    const new_ref = try it.runtime_tape.internString(it.alloc, key_str);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .key,
                        .payload = .{ .string = new_ref },
                    });
                    pos += 1;
                },
                .string => {
                    // Intern the string value into runtime_tape.string_buf.
                    const str = span.tape.getString(entry.payload.string);
                    const new_ref = try it.runtime_tape.internString(it.alloc, str);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .string,
                        .payload = .{ .string = new_ref },
                    });
                    pos += 1;
                },
                else => {
                    _ = try it.runtime_tape.appendEntry(it.alloc, entry);
                    pos += 1;
                },
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
                .int => |ri| blk: {
                    const ov = @mulWithOverflow(li, ri);
                    break :blk if (ov[1] == 0) .{ .int = ov[0] } else .{ .float = @as(f64, @floatFromInt(li)) * @as(f64, @floatFromInt(ri)) };
                },
                .float => |rf| .{ .float = @as(f64, @floatFromInt(li)) * rf },
                else => error.TypeError,
            },
            .float => |lf| switch (right) {
                .int => |ri| .{ .float = lf * @as(f64, @floatFromInt(ri)) },
                .float => |rf| .{ .float = lf * rf },
                else => error.TypeError,
            },
            .tape_value => |ltv| switch (ltv) {
                .object => |lspan| switch (right) {
                    .tape_value => |rtv| switch (rtv) {
                        .object => |rspan| try it.recursiveMerge(lspan, rspan),
                        else => error.TypeError,
                    },
                    else => error.TypeError,
                },
                else => error.TypeError,
            },
            else => error.TypeError,
        };
    }

    /// Recursive merge for object * object (jq semantics).
    /// When both left and right have the same key and both values are objects,
    /// recursively merge them. Otherwise, right's value wins.
    fn recursiveMerge(it: *ResultIterator, lspan: Value.TapeSpan, rspan: Value.TapeSpan) ZqError!StackValue {
        // Pre-reserve capacity to avoid reallocation invalidating span pointers
        // when spans reference runtime_tape_view (e.g. chained merges).
        const estimated_entries = (lspan.end - lspan.start) + (rspan.end - rspan.start) + 2;
        try it.runtime_tape.entries.ensureUnusedCapacity(it.alloc, estimated_entries);
        var lstring_bytes: usize = 0;
        for (lspan.tape.entries[lspan.start..lspan.end]) |e| {
            if (e.tag == .key or e.tag == .string) lstring_bytes += e.payload.string.len;
        }
        var rstring_bytes: usize = 0;
        for (rspan.tape.entries[rspan.start..rspan.end]) |e| {
            if (e.tag == .key or e.tag == .string) rstring_bytes += e.payload.string.len;
        }
        try it.runtime_tape.string_buf.ensureUnusedCapacity(it.alloc, lstring_bytes + rstring_bytes);
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;

        const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .object_start,
            .payload = .{ .skip = 0 },
        });

        // Write all left keys, merging with right's value when both are objects
        var lpos = lspan.start + 1;
        const lend = lspan.end - 1;
        while (lpos < lend) {
            const lkey = lspan.tape.getString(lspan.tape.entries[lpos].payload.string);
            const lval = tapeEntryToValue(lspan.tape, lpos + 1);

            // Look for this key in right
            var rpos2 = rspan.start + 1;
            const rend2 = rspan.end - 1;
            var right_val: ?Value = null;
            while (rpos2 < rend2) {
                const rkey = rspan.tape.getString(rspan.tape.entries[rpos2].payload.string);
                if (std.mem.eql(u8, lkey, rkey)) {
                    right_val = tapeEntryToValue(rspan.tape, rpos2 + 1);
                    break;
                }
                rpos2 = skipEntry(rspan.tape.*, rpos2 + 1);
            }

            const new_key_ref = try it.runtime_tape.internString(it.alloc, lkey);
            _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .key, .payload = .{ .string = new_key_ref } });

            if (right_val) |rv| {
                // Both have the key: if both values are objects, recurse
                switch (lval) {
                    .object => |linner| switch (rv) {
                        .object => |rinner| {
                            // recursiveMerge already materializes the merged object
                            // into runtime_tape — don't copy it again.
                            _ = try it.recursiveMerge(linner, rinner);
                            // Update views after recursion may have grown the tape
                            it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                            it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                        },
                        else => try it.stackValueToRuntimeTapeEntry(try valueToStackValue(rv)),
                    },
                    else => try it.stackValueToRuntimeTapeEntry(try valueToStackValue(rv)),
                }
            } else {
                try it.stackValueToRuntimeTapeEntry(try valueToStackValue(lval));
            }
            lpos = skipEntry(lspan.tape.*, lpos + 1);
        }

        // Append right keys not in left
        var rpos = rspan.start + 1;
        const rend = rspan.end - 1;
        while (rpos < rend) {
            const rkey = rspan.tape.getString(rspan.tape.entries[rpos].payload.string);
            var in_left = false;
            var lpos2 = lspan.start + 1;
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
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .object = .{
            .tape = &it.runtime_tape_view,
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

        return switch (left) {
            .int => |li| switch (right) {
                .int => |ri| blk: {
                    if (ri == 0) return error.TypeError;
                    // Integer division: if evenly divisible keep int, otherwise float
                    if (@rem(li, ri) == 0) break :blk .{ .int = @divTrunc(li, ri) };
                    break :blk .{ .float = @as(f64, @floatFromInt(li)) / @as(f64, @floatFromInt(ri)) };
                },
                .float => |rf| blk: {
                    if (rf == 0.0) return error.TypeError;
                    break :blk .{ .float = @as(f64, @floatFromInt(li)) / rf };
                },
                else => error.TypeError,
            },
            .float => |lf| switch (right) {
                .int => |ri| blk: {
                    if (ri == 0) return error.TypeError;
                    break :blk .{ .float = lf / @as(f64, @floatFromInt(ri)) };
                },
                .float => |rf| blk: {
                    if (rf == 0.0) return error.TypeError;
                    break :blk .{ .float = lf / rf };
                },
                else => error.TypeError,
            },
            .tape_value => |ltv| switch (ltv) {
                .string => |ls| switch (right) {
                    .tape_value => |rtv| switch (rtv) {
                        // string / string = split
                        .string => |rs| blk: {
                            // string / string = split (jq semantics)
                            // Store StringRefs to avoid invalidation during interning
                            var refs = std.ArrayList(Tape.StringRef){};
                            defer refs.deinit(it.alloc);
                            // Pre-reserve string_buf so ls/rs slices stay valid
                            try it.runtime_tape.string_buf.ensureUnusedCapacity(it.alloc, ls.len);
                            it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                            if (rs.len == 0) {
                                var ci: usize = 0;
                                while (ci < ls.len) {
                                    const seq_len = std.unicode.utf8ByteSequenceLength(ls[ci]) catch 1;
                                    const cp_end = @min(ci + seq_len, ls.len);
                                    const sr = try it.runtime_tape.internString(it.alloc, ls[ci..cp_end]);
                                    try refs.append(it.alloc, sr);
                                    ci = cp_end;
                                }
                            } else {
                                var rest: []const u8 = ls;
                                while (true) {
                                    if (std.mem.indexOf(u8, rest, rs)) |idx| {
                                        const sr = try it.runtime_tape.internString(it.alloc, rest[0..idx]);
                                        try refs.append(it.alloc, sr);
                                        rest = rest[idx + rs.len ..];
                                    } else {
                                        const sr = try it.runtime_tape.internString(it.alloc, rest);
                                        try refs.append(it.alloc, sr);
                                        break;
                                    }
                                }
                            }
                            break :blk try it.buildRuntimeArrayFromRefs(refs.items);
                        },
                        else => error.TypeError,
                    },
                    else => error.TypeError,
                },
                else => error.TypeError,
            },
            else => error.TypeError,
        };
    }

    fn doMod(it: *ResultIterator) ZqError!StackValue {
        const right = try it.popValue();
        const left = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);

        // Check if either operand is float — use fmod for float modulo
        const left_is_float = switch (left) {
            .float => true,
            else => false,
        };
        const right_is_float = switch (right) {
            .float => true,
            else => false,
        };

        if (left_is_float or right_is_float) {
            const lf = try toFloat(left);
            const rf = try toFloat(right);
            // NaN or Inf operands: use @mod which maps to C fmod
            if (std.math.isNan(lf) or std.math.isNan(rf)) {
                return .{ .float = std.math.nan(f64) };
            }
            if (std.math.isInf(lf)) {
                if (std.math.isInf(rf)) {
                    return .{ .float = std.math.nan(f64) };
                }
                return .{ .float = std.math.nan(f64) };
            }
            if (rf == 0.0) return error.TypeError;
            return .{ .float = @rem(lf, rf) };
        }

        const left_int = try toInt(left);
        const right_int = try toInt(right);
        if (right_int == 0) return error.TypeError; // modulo by zero
        return .{ .int = @rem(left_int, right_int) };
    }

    // ── Builtin implementations ───────────────────────────────────────────────────

    /// Dispatch to individual builtin implementations.
    /// Returns a StackValue to push (or null for empty/generators that set ip).
    fn doBuiltin(it: *ResultIterator, bid: BuiltinId) ZqError!?StackValue {
        switch (bid) {
            .length => return try it.builtinLength(),
            .keys => return try it.builtinKeys(true),
            .keys_unsorted => return try it.builtinKeys(false),
            .values => return try it.builtinValues(),
            .has => return try it.builtinHas(),
            .in_ => return try it.builtinIn(),
            .type_ => return try it.builtinType(),
            .empty => {
                // Set ip past end so this path produces no output.
                it.ip = @intCast(it.instructions.len);
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

            // ── Type selectors (Group A) ──
            .arrays => return try it.builtinTypeSelector(.arrays),
            .objects_sel => return try it.builtinTypeSelector(.objects_sel),
            .strings_sel => return try it.builtinTypeSelector(.strings_sel),
            .numbers_sel => return try it.builtinTypeSelector(.numbers_sel),
            .booleans_sel => return try it.builtinTypeSelector(.booleans_sel),
            .nulls_sel => return try it.builtinTypeSelector(.nulls_sel),
            .values_sel => return try it.builtinTypeSelector(.values_sel),
            .scalars_sel => return try it.builtinTypeSelector(.scalars_sel),
            .iterables_sel => return try it.builtinTypeSelector(.iterables_sel),

            // ── Math builtins (Group B) ──
            .floor => return try it.builtinFloor(),
            .ceil => return try it.builtinCeil(),
            .round => return try it.builtinRound(),
            .sqrt => return try it.builtinMathUnary(.sqrt),
            .fabs => return try it.builtinFabs(),
            .nan_val => return .{ .float = std.math.nan(f64) },
            .infinite_val => return .{ .float = std.math.inf(f64) },
            .isnan_val => return try it.builtinIsnan(),
            .isinfinite_val => return try it.builtinIsinfinite(),
            .isnormal_val => return try it.builtinIsnormal(),
            .pow_ => return try it.builtinPow(),
            .log2_ => return try it.builtinMathUnary(.log2),
            .log_ => return try it.builtinMathUnary(.log),
            .exp_ => return try it.builtinMathUnary(.exp),
            .exp2_ => return try it.builtinMathUnary(.exp2),
            .sin_ => return try it.builtinMathUnary(.sin),
            .cos_ => return try it.builtinMathUnary(.cos),
            .atan_ => return try it.builtinMathUnary(.atan),
            .tan_ => return try it.builtinMathUnary(.tan),
            .asin_ => return try it.builtinMathUnary(.asin),
            .acos_ => return try it.builtinMathUnary(.acos),
            .sinh_ => return try it.builtinMathUnary(.sinh),
            .cosh_ => return try it.builtinMathUnary(.cosh),
            .tanh_ => return try it.builtinMathUnary(.tanh),
            .significand => return try it.builtinSignificand(),
            .exponent_ => return try it.builtinExponent(),
            .logb_ => return try it.builtinLogb(),
            .abs => return try it.builtinAbs(),

            // ── String builtins (Group C) ──
            .ascii_downcase => return try it.builtinAsciiDowncase(),
            .ascii_upcase => return try it.builtinAsciiUpcase(),
            .ltrimstr => return try it.builtinLtrimstr(),
            .rtrimstr => return try it.builtinRtrimstr(),
            .startswith => return try it.builtinStartswith(),
            .endswith => return try it.builtinEndswith(),
            .split_ => return try it.builtinSplit(),
            .join_ => return try it.builtinJoin(),
            .explode => return try it.builtinExplode(),
            .implode => return try it.builtinImplode(),
            .tojson => return try it.builtinTojson(),
            .fromjson => return try it.builtinFromjson(),
            .toboolean => return try it.builtinToboolean(),
            .ascii_val => return try it.builtinAsciiVal(),

            // ── Misc builtins (Group D) ──
            .utf8bytelength => return try it.builtinUtf8bytelength(),
            .transpose => return try it.builtinTranspose(),
            .builtins_list => return try it.builtinBuiltinsList(),
            .have_decnum => return .{ .bool_val = false },
            .bsearch => return try it.builtinBsearch(),
        }
    }

    fn builtinLength(it: *ResultIterator) ZqError!?StackValue {
        const val = it.current;
        return switch (val) {
            .null_val => .{ .int = 0 },
            .bool_val => return error.TypeError,
            .int => |i| absIntStackValue(i),
            .float => |f| .{ .float = @abs(f) },
            .string => |s| blk: {
                // Count Unicode codepoints, not bytes.
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
                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .array = .{
                    .tape = &it.runtime_tape_view,
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
                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .array = .{
                    .tape = &it.runtime_tape_view,
                    .start = arr_start,
                    .end = arr_end_idx + 1,
                } } };
            },
            else => return error.TypeError,
        }
    }

    fn builtinValues(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .object => |span| {
                // Build array of values in insertion order
                const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_start,
                    .payload = .{ .skip = 0 },
                });
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const val_sv = try valueToStackValue(tapeEntryToValue(span.tape, pos + 1));
                    try it.stackValueToRuntimeTapeEntry(val_sv);
                    pos = skipEntry(span.tape.*, pos + 1); // skip past value
                }
                const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .array_end,
                    .payload = .{ .none = {} },
                });
                it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .array = .{
                    .tape = &it.runtime_tape_view,
                    .start = arr_start,
                    .end = arr_end_idx + 1,
                } } };
            },
            .array => {
                // Array identity: values of an array is itself
                return try valueToStackValue(it.current);
            },
            else => return error.TypeError,
        }
    }

    fn builtinHas(it: *ResultIterator) ZqError!?StackValue {
        const key_sv = try it.popValue();
        switch (it.current) {
            .object => |span| {
                const key_str = switch (key_sv) {
                    .tape_value => |tv| switch (tv) {
                        .string => |s| s,
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
                const idx = switch (key_sv) {
                    .int => |i| i,
                    else => return error.TypeError,
                };
                if (idx < 0) return .{ .bool_val = false };
                const len = arrayLength(span.tape, span);
                return .{ .bool_val = @as(u32, @intCast(idx)) < len };
            },
            else => return error.TypeError,
        }
    }

    fn builtinIn(it: *ResultIterator) ZqError!?StackValue {
        // Current value is the key; top of if_stack (put there by save_input before compile_in) is the object.
        const obj_sv = try it.popValue();
        const key_sv = try valueToStackValue(it.current);
        switch (obj_sv) {
            .tape_value => |tv| switch (tv) {
                .object => |span| {
                    const key_str = switch (key_sv) {
                        .tape_value => |ktv| switch (ktv) {
                            .string => |s| s,
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
                    const idx = switch (key_sv) {
                        .int => |i| i,
                        else => return error.TypeError,
                    };
                    if (idx < 0) return .{ .bool_val = false };
                    const len = arrayLength(span.tape, span);
                    return .{ .bool_val = @as(u32, @intCast(idx)) < len };
                },
                else => return error.TypeError,
            },
            else => return error.TypeError,
        }
    }

    fn builtinType(it: *ResultIterator) ZqError!?StackValue {
        const type_str: []const u8 = switch (it.current) {
            .null_val => "null",
            .bool_val => "boolean",
            .int, .float => "number",
            .string => "string",
            .array => "array",
            .object => "object",
        };
        const str_ref = try it.runtime_tape.internString(it.alloc, type_str);
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
    }

    fn builtinTostring(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .string => |s| return .{ .tape_value = .{ .string = s } },
            .null_val => {
                const str_ref = try it.runtime_tape.internString(it.alloc, "null");
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
            },
            .bool_val => |b| {
                const s: []const u8 = if (b) "true" else "false";
                const str_ref = try it.runtime_tape.internString(it.alloc, s);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
            },
            .int => |n| {
                var tmp: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return error.TypeError;
                const str_ref = try it.runtime_tape.internString(it.alloc, s);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
            },
            .float => |f| {
                var tmp: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch return error.TypeError;
                const str_ref = try it.runtime_tape.internString(it.alloc, s);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
            },
            .array, .object => {
                // Compact JSON serialization into runtime_tape string_buf
                var json_buf = std.ArrayList(u8){};
                defer json_buf.deinit(it.alloc);
                try serializeValueCompact(&json_buf, it.alloc, it.current);
                const str_ref = try it.runtime_tape.internString(it.alloc, json_buf.items);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
            },
        }
    }

    fn builtinTonumber(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .int => |n| return .{ .int = n },
            .float => |f| return .{ .float = f },
            .string => |s| {
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
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                it.user_error_msg = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] };
                return error.UserError;
            },
            else => return error.TypeError,
        }
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
            .string => |s| {
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
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
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
                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .array = .{
                    .tape = &it.runtime_tape_view,
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
                            // Look for key/name/Key field
                            const key_val = lookupKey(espan.tape, espan, "key") orelse
                                lookupKey(espan.tape, espan, "name") orelse
                                lookupKey(espan.tape, espan, "Key") orelse
                                return error.TypeError;
                            // Extract key string
                            const key_str = switch (key_val) {
                                .string => |s| s,
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
                        .string => |s| {
                            const new_key_ref = try it.runtime_tape.internString(it.alloc, s);
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
                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .object = .{
                    .tape = &it.runtime_tape_view,
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
        if (depth < 0) return error.TypeError;
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
            .string => |haystack| {
                // String search: find all byte offsets of needle string
                const needle_str = switch (needle) {
                    .string => |s| s,
                    else => return error.TypeError,
                };
                if (needle_str.len == 0) {
                    // jq returns empty array for empty needle
                    return try it.buildRuntimeArray(positions.items);
                }
                var i: usize = 0;
                while (i + needle_str.len <= haystack.len) {
                    if (std.mem.eql(u8, haystack[i..][0..needle_str.len], needle_str)) {
                        try positions.append(it.alloc, .{ .int = @intCast(i) });
                        i += 1;
                    } else {
                        i += 1;
                    }
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
            .string => |haystack| {
                const needle_str = switch (needle) {
                    .string => |s| s,
                    else => return error.TypeError,
                };
                if (needle_str.len == 0 or haystack.len == 0) return .null_val;
                if (std.mem.indexOf(u8, haystack, needle_str)) |pos| {
                    return .{ .int = @intCast(pos) };
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
            .string => |haystack| {
                const needle_str = switch (needle) {
                    .string => |s| s,
                    else => return error.TypeError,
                };
                if (needle_str.len == 0 or haystack.len == 0) return .null_val;
                if (needle_str.len > haystack.len) return .null_val;
                // Search backwards: start from the last possible position
                var i: usize = haystack.len - needle_str.len + 1;
                while (i > 0) {
                    i -= 1;
                    if (std.mem.eql(u8, haystack[i..][0..needle_str.len], needle_str)) {
                        return .{ .int = @intCast(i) };
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
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape_view,
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
            if (jqCompareValues(key, best_key) == .gt) {
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
                        .string => |s| s,
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
                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .object = .{
                    .tape = &it.runtime_tape_view,
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
                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .array = .{
                    .tape = &it.runtime_tape_view,
                    .start = arr_start,
                    .end = arr_end_idx + 1,
                } } };
            },
            else => return error.TypeError,
        }
    }

    // ── Type selectors (Group A) ──────────────────────────────────────────────

    fn builtinTypeSelector(it: *ResultIterator, sel: BuiltinId) ZqError!?StackValue {
        const matches = switch (sel) {
            .arrays => switch (it.current) {
                .array => true,
                else => false,
            },
            .objects_sel => switch (it.current) {
                .object => true,
                else => false,
            },
            .strings_sel => switch (it.current) {
                .string => true,
                else => false,
            },
            .numbers_sel => switch (it.current) {
                .int, .float => true,
                else => false,
            },
            .booleans_sel => switch (it.current) {
                .bool_val => true,
                else => false,
            },
            .nulls_sel => switch (it.current) {
                .null_val => true,
                else => false,
            },
            .values_sel => switch (it.current) {
                .null_val => false,
                else => true,
            },
            .scalars_sel => switch (it.current) {
                .array, .object => false,
                else => true,
            },
            .iterables_sel => switch (it.current) {
                .array, .object => true,
                else => false,
            },
            else => false,
        };

        if (matches) {
            return try valueToStackValue(it.current);
        } else {
            // Act like `empty` — produce no output
            it.ip = @intCast(it.instructions.len);
            return null;
        }
    }

    // ── Math builtins (Group B) ─────────────────────────────────────────────

    fn builtinFloor(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .int => |n| return .{ .int = n },
            .float => |f| {
                if (std.math.isNan(f) or std.math.isInf(f)) return .{ .float = f };
                const floored = @floor(f);
                if (floored < @as(f64, @floatFromInt(std.math.minInt(i64))) or
                    floored >= 0x1p63)
                    return .{ .float = floored };
                return .{ .int = @intFromFloat(floored) };
            },
            else => return error.TypeError,
        }
    }

    fn builtinCeil(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .int => |n| return .{ .int = n },
            .float => |f| {
                if (std.math.isNan(f) or std.math.isInf(f)) return .{ .float = f };
                const ceiled = @ceil(f);
                if (ceiled < @as(f64, @floatFromInt(std.math.minInt(i64))) or
                    ceiled >= 0x1p63)
                    return .{ .float = ceiled };
                return .{ .int = @intFromFloat(ceiled) };
            },
            else => return error.TypeError,
        }
    }

    fn builtinRound(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .int => |n| return .{ .int = n },
            .float => |f| {
                if (std.math.isNan(f) or std.math.isInf(f)) return .{ .float = f };
                const rounded = @round(f);
                if (rounded < @as(f64, @floatFromInt(std.math.minInt(i64))) or
                    rounded >= 0x1p63)
                    return .{ .float = rounded };
                return .{ .int = @intFromFloat(rounded) };
            },
            else => return error.TypeError,
        }
    }

    const MathOp = enum { sqrt, log2, log, exp, exp2, sin, cos, atan, tan, asin, acos, sinh, cosh, tanh };

    fn builtinMathUnary(it: *ResultIterator, comptime op: MathOp) ZqError!?StackValue {
        const f: f64 = switch (it.current) {
            .float => |v| v,
            .int => |n| @as(f64, @floatFromInt(n)),
            else => return error.TypeError,
        };
        const result: f64 = switch (op) {
            .sqrt => @sqrt(f),
            .log2 => std.math.log2(f),
            .log => @log(f),
            .exp => @exp(f),
            .exp2 => std.math.exp2(f),
            .sin => @sin(f),
            .cos => @cos(f),
            .atan => std.math.atan(f),
            .tan => std.math.tan(f),
            .asin => std.math.asin(f),
            .acos => std.math.acos(f),
            .sinh => std.math.sinh(f),
            .cosh => std.math.cosh(f),
            .tanh => std.math.tanh(f),
        };
        return .{ .float = result };
    }

    /// Absolute value for integers. Promotes to float when the result
    /// would overflow (minInt(i64)), matching jq behavior.
    fn absIntStackValue(n: i64) StackValue {
        if (n == std.math.minInt(i64))
            return .{ .float = @abs(@as(f64, @floatFromInt(n))) };
        return .{ .int = if (n < 0) -n else n };
    }

    fn builtinFabs(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .int => |n| return absIntStackValue(n),
            .float => |f| return .{ .float = @abs(f) },
            else => return error.TypeError,
        }
    }

    fn builtinAbs(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .int => |n| return absIntStackValue(n),
            .float => |f| return .{ .float = @abs(f) },
            else => return error.TypeError,
        }
    }

    fn builtinIsnan(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .float => |f| return .{ .bool_val = std.math.isNan(f) },
            .int => return .{ .bool_val = false },
            else => return .{ .bool_val = false },
        }
    }

    fn builtinIsinfinite(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .float => |f| return .{ .bool_val = std.math.isInf(f) },
            .int => return .{ .bool_val = false },
            else => return .{ .bool_val = false },
        }
    }

    fn builtinIsnormal(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .float => |f| {
                if (f == 0.0 or std.math.isNan(f) or std.math.isInf(f))
                    return .{ .bool_val = false };
                // Exclude subnormals: biased exponent == 0 means subnormal
                const bits = @as(u64, @bitCast(f));
                const biased_exp = (bits >> 52) & 0x7FF;
                return .{ .bool_val = biased_exp != 0 };
            },
            .int => |n| return .{ .bool_val = n != 0 },
            else => return .{ .bool_val = false },
        }
    }

    fn builtinPow(it: *ResultIterator) ZqError!?StackValue {
        const exp_sv = try it.popValue();
        const base_sv = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);
        const base_f = try toFloat(base_sv);
        const exp_f = try toFloat(exp_sv);
        return .{ .float = std.math.pow(f64, base_f, exp_f) };
    }

    /// Compute the base-2 exponent of f (like C's ilogb).
    /// Handles subnormals, zero, and Inf/NaN per IEEE 754.
    fn ilogb64(f: f64) i32 {
        if (f == 0.0) return std.math.minInt(i32); // FP_ILOGB0
        const bits = @as(u64, @bitCast(f));
        const biased_exp = @as(u32, @intCast((bits >> 52) & 0x7FF));
        if (biased_exp == 0x7FF) return std.math.maxInt(i32); // Inf/NaN
        if (biased_exp == 0) {
            // Subnormal: find position of leading 1 in mantissa
            const mantissa = bits & 0x000FFFFFFFFFFFFF;
            if (mantissa == 0) return std.math.minInt(i32);
            const leading_zeros = @clz(mantissa) - 12; // 64 - 52 = 12 implicit bits
            return -1023 - @as(i32, @intCast(leading_zeros));
        }
        return @as(i32, @intCast(biased_exp)) - 1023;
    }

    fn builtinSignificand(it: *ResultIterator) ZqError!?StackValue {
        const f: f64 = switch (it.current) {
            .float => |v| v,
            .int => |n| @as(f64, @floatFromInt(n)),
            else => return error.TypeError,
        };
        if (f == 0.0) return .{ .float = 0.0 };
        if (std.math.isNan(f) or std.math.isInf(f)) return .{ .float = f };
        // jq significand: value in [1, 2) such that f = significand * 2^exponent
        const exp_val = ilogb64(f);
        // Divide by 2^exponent to get significand
        const divisor = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(exp_val)));
        return .{ .float = f / divisor };
    }

    fn builtinExponent(it: *ResultIterator) ZqError!?StackValue {
        const f: f64 = switch (it.current) {
            .float => |v| v,
            .int => |n| @as(f64, @floatFromInt(n)),
            else => return error.TypeError,
        };
        if (f == 0.0) return .{ .int = 0 };
        if (std.math.isNan(f) or std.math.isInf(f)) return .{ .float = std.math.inf(f64) };
        return .{ .int = @as(i64, ilogb64(f)) };
    }

    fn builtinLogb(it: *ResultIterator) ZqError!?StackValue {
        const f: f64 = switch (it.current) {
            .float => |v| v,
            .int => |n| @as(f64, @floatFromInt(n)),
            else => return error.TypeError,
        };
        if (f == 0.0) return .{ .float = -std.math.inf(f64) };
        if (std.math.isInf(f)) return .{ .float = std.math.inf(f64) };
        if (std.math.isNan(f)) return .{ .float = std.math.nan(f64) };
        return .{ .float = @as(f64, @floatFromInt(ilogb64(f))) };
    }

    // ── String builtins (Group C) ───────────────────────────────────────────

    fn builtinAsciiDowncase(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .string => |s| {
                var buf = std.ArrayList(u8){};
                defer buf.deinit(it.alloc);
                try buf.ensureTotalCapacity(it.alloc, s.len);
                for (s) |c| {
                    buf.appendAssumeCapacity(if (c >= 'A' and c <= 'Z') c + 32 else c);
                }
                const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
            },
            else => return error.TypeError,
        }
    }

    fn builtinAsciiUpcase(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .string => |s| {
                var buf = std.ArrayList(u8){};
                defer buf.deinit(it.alloc);
                try buf.ensureTotalCapacity(it.alloc, s.len);
                for (s) |c| {
                    buf.appendAssumeCapacity(if (c >= 'a' and c <= 'z') c - 32 else c);
                }
                const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
            },
            else => return error.TypeError,
        }
    }

    fn builtinLtrimstr(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const prefix = switch (arg_sv) {
            .tape_value => |tv| switch (tv) {
                .string => |s| s,
                else => return error.TypeError,
            },
            else => return error.TypeError,
        };
        switch (it.current) {
            .string => |s| {
                if (std.mem.startsWith(u8, s, prefix)) {
                    const trimmed = s[prefix.len..];
                    const str_ref = try it.runtime_tape.internString(it.alloc, trimmed);
                    it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                    return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
                }
                return try valueToStackValue(it.current);
            },
            else => return error.TypeError,
        }
    }

    fn builtinRtrimstr(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const suffix = switch (arg_sv) {
            .tape_value => |tv| switch (tv) {
                .string => |s| s,
                else => return error.TypeError,
            },
            else => return error.TypeError,
        };
        switch (it.current) {
            .string => |s| {
                if (std.mem.endsWith(u8, s, suffix)) {
                    const trimmed = s[0 .. s.len - suffix.len];
                    const str_ref = try it.runtime_tape.internString(it.alloc, trimmed);
                    it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                    return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
                }
                return try valueToStackValue(it.current);
            },
            else => return error.TypeError,
        }
    }

    fn builtinStartswith(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const prefix = switch (arg_sv) {
            .tape_value => |tv| switch (tv) {
                .string => |s| s,
                else => return error.TypeError,
            },
            else => return error.TypeError,
        };
        switch (it.current) {
            .string => |s| return .{ .bool_val = std.mem.startsWith(u8, s, prefix) },
            else => return error.TypeError,
        }
    }

    fn builtinEndswith(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const suffix = switch (arg_sv) {
            .tape_value => |tv| switch (tv) {
                .string => |s| s,
                else => return error.TypeError,
            },
            else => return error.TypeError,
        };
        switch (it.current) {
            .string => |s| return .{ .bool_val = std.mem.endsWith(u8, s, suffix) },
            else => return error.TypeError,
        }
    }

    fn builtinSplit(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const sep = switch (arg_sv) {
            .tape_value => |tv| switch (tv) {
                .string => |s| s,
                else => return error.TypeError,
            },
            else => return error.TypeError,
        };
        switch (it.current) {
            .string => |s| {
                // Store StringRefs to avoid invalidation during interning
                var refs = std.ArrayList(Tape.StringRef){};
                defer refs.deinit(it.alloc);
                // Pre-reserve string_buf so s/sep slices stay valid
                try it.runtime_tape.string_buf.ensureUnusedCapacity(it.alloc, s.len);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                if (sep.len == 0) {
                    var i: usize = 0;
                    while (i < s.len) {
                        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                        const cp_end = @min(i + seq_len, s.len);
                        const str_ref = try it.runtime_tape.internString(it.alloc, s[i..cp_end]);
                        try refs.append(it.alloc, str_ref);
                        i = cp_end;
                    }
                } else {
                    var rest: []const u8 = s;
                    while (true) {
                        if (std.mem.indexOf(u8, rest, sep)) |idx| {
                            const str_ref = try it.runtime_tape.internString(it.alloc, rest[0..idx]);
                            try refs.append(it.alloc, str_ref);
                            rest = rest[idx + sep.len ..];
                        } else {
                            const str_ref = try it.runtime_tape.internString(it.alloc, rest);
                            try refs.append(it.alloc, str_ref);
                            break;
                        }
                    }
                }
                return try it.buildRuntimeArrayFromRefs(refs.items);
            },
            else => return error.TypeError,
        }
    }

    fn builtinJoin(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const sep = switch (arg_sv) {
            .tape_value => |tv| switch (tv) {
                .string => |s| s,
                else => return error.TypeError,
            },
            else => return error.TypeError,
        };
        switch (it.current) {
            .array => |span| {
                var buf = std.ArrayList(u8){};
                defer buf.deinit(it.alloc);
                var pos = span.start + 1;
                const end = span.end - 1;
                var first = true;
                while (pos < end) {
                    if (!first) try buf.appendSlice(it.alloc, sep);
                    first = false;
                    const elem = tapeEntryToValue(span.tape, pos);
                    switch (elem) {
                        .string => |s| try buf.appendSlice(it.alloc, s),
                        .null_val => {},
                        else => {
                            // jq coerces non-string elements to string via tostring
                            var tmp_buf = std.ArrayList(u8){};
                            defer tmp_buf.deinit(it.alloc);
                            try serializeValueCompact(&tmp_buf, it.alloc, elem);
                            try buf.appendSlice(it.alloc, tmp_buf.items);
                        },
                    }
                    pos = skipEntry(span.tape.*, pos);
                }
                const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
            },
            else => return error.TypeError,
        }
    }

    fn builtinExplode(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .string => |s| {
                var codepoints = std.ArrayList(Value){};
                defer codepoints.deinit(it.alloc);
                var i: usize = 0;
                while (i < s.len) {
                    const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
                        try codepoints.append(it.alloc, .{ .int = @as(i64, s[i]) });
                        i += 1;
                        continue;
                    };
                    if (i + seq_len > s.len) {
                        try codepoints.append(it.alloc, .{ .int = @as(i64, s[i]) });
                        i += 1;
                        continue;
                    }
                    const cp = std.unicode.utf8Decode(s[i..][0..seq_len]) catch {
                        try codepoints.append(it.alloc, .{ .int = @as(i64, s[i]) });
                        i += 1;
                        continue;
                    };
                    try codepoints.append(it.alloc, .{ .int = @as(i64, cp) });
                    i += seq_len;
                }
                return try it.buildRuntimeArray(codepoints.items);
            },
            else => return error.TypeError,
        }
    }

    fn builtinImplode(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .array => |span| {
                var buf = std.ArrayList(u8){};
                defer buf.deinit(it.alloc);
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const elem = tapeEntryToValue(span.tape, pos);
                    const cp: u21 = switch (elem) {
                        .int => |n| blk: {
                            if (n < 0 or n > 0x10FFFF) return error.TypeError;
                            break :blk @intCast(n);
                        },
                        else => return error.TypeError,
                    };
                    var utf8_buf: [4]u8 = undefined;
                    const utf8_len = std.unicode.utf8Encode(cp, &utf8_buf) catch return error.TypeError;
                    try buf.appendSlice(it.alloc, utf8_buf[0..utf8_len]);
                    pos = skipEntry(span.tape.*, pos);
                }
                const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
            },
            else => return error.TypeError,
        }
    }

    fn builtinTojson(it: *ResultIterator) ZqError!?StackValue {
        var json_buf = std.ArrayList(u8){};
        defer json_buf.deinit(it.alloc);
        try serializeValueCompact(&json_buf, it.alloc, it.current);
        const str_ref = try it.runtime_tape.internString(it.alloc, json_buf.items);
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
    }

    fn builtinFromjson(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .string => |s| {
                // Use the real JSON parser to handle all valid JSON
                var json_parser = Parser.init(it.alloc) catch return error.OutOfMemory;
                defer json_parser.deinit();
                const feed_result = json_parser.feed(s, true) catch return error.TypeError;
                switch (feed_result) {
                    .done => |result| {
                        const parsed_tape = result.tape;
                        const val = tapeEntryToValue(&parsed_tape, 0);
                        switch (val) {
                            .null_val => return .null_val,
                            .bool_val => |b| return .{ .bool_val = b },
                            .int => |n| return .{ .int = n },
                            .float => |f| return .{ .float = f },
                            .string => |str| {
                                const str_ref = try it.runtime_tape.internString(it.alloc, str);
                                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                                return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
                            },
                            .array => {
                                const span = Value.TapeSpan{
                                    .tape = &parsed_tape,
                                    .start = 0,
                                    .end = @intCast(parsed_tape.entries.len),
                                };
                                const start: u32 = @intCast(it.runtime_tape.entries.items.len);
                                try it.copyTapeSpanToRuntimeTape(span);
                                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                                const end_idx: u32 = @intCast(it.runtime_tape.entries.items.len);
                                return .{ .tape_value = .{ .array = .{
                                    .tape = &it.runtime_tape_view,
                                    .start = start,
                                    .end = end_idx,
                                } } };
                            },
                            .object => {
                                const span = Value.TapeSpan{
                                    .tape = &parsed_tape,
                                    .start = 0,
                                    .end = @intCast(parsed_tape.entries.len),
                                };
                                const start: u32 = @intCast(it.runtime_tape.entries.items.len);
                                try it.copyTapeSpanToRuntimeTape(span);
                                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                                const end_idx: u32 = @intCast(it.runtime_tape.entries.items.len);
                                return .{ .tape_value = .{ .object = .{
                                    .tape = &it.runtime_tape_view,
                                    .start = start,
                                    .end = end_idx,
                                } } };
                            },
                        }
                    },
                    .need_more => return error.TypeError,
                }
            },
            // jq rejects non-string input: "only strings can be parsed"
            else => return error.TypeError,
        }
    }

    fn builtinToboolean(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .bool_val => |b| return .{ .bool_val = b },
            .string => |s| {
                if (std.mem.eql(u8, s, "true")) return .{ .bool_val = true };
                if (std.mem.eql(u8, s, "false")) return .{ .bool_val = false };
                // Build jq-compatible error message
                var msg_buf = std.ArrayList(u8){};
                defer msg_buf.deinit(it.alloc);
                try msg_buf.appendSlice(it.alloc, "string (");
                try appendJsonString(&msg_buf, it.alloc, s);
                try msg_buf.appendSlice(it.alloc, ") cannot be parsed as a boolean");
                const str_ref = try it.runtime_tape.internString(it.alloc, msg_buf.items);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                it.user_error_msg = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] };
                return error.UserError;
            },
            else => {
                // Build jq-compatible error: "TYPE (VALUE) cannot be parsed as a boolean"
                var msg_buf = std.ArrayList(u8){};
                defer msg_buf.deinit(it.alloc);
                const type_str: []const u8 = switch (it.current) {
                    .null_val => "null",
                    .int, .float => "number",
                    .array => "array",
                    .object => "object",
                    else => "unknown",
                };
                try msg_buf.appendSlice(it.alloc, type_str);
                try msg_buf.appendSlice(it.alloc, " (");
                try serializeValueCompact(&msg_buf, it.alloc, it.current);
                try msg_buf.appendSlice(it.alloc, ") cannot be parsed as a boolean");
                const str_ref = try it.runtime_tape.internString(it.alloc, msg_buf.items);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                it.user_error_msg = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] };
                return error.UserError;
            },
        }
    }

    fn builtinAsciiVal(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .string => |s| {
                if (s.len == 0) return error.TypeError;
                return .{ .int = @as(i64, s[0]) };
            },
            else => return error.TypeError,
        }
    }

    // ── Misc builtins (Group D) ──────────────────────────────────────────────

    fn builtinUtf8bytelength(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .string => |s| return .{ .int = @as(i64, @intCast(s.len)) },
            else => {
                // jq error: "TYPE (VALUE) only strings have UTF-8 byte length"
                var msg_buf = std.ArrayList(u8){};
                defer msg_buf.deinit(it.alloc);
                const type_str: []const u8 = switch (it.current) {
                    .null_val => "null",
                    .bool_val => "boolean",
                    .int, .float => "number",
                    .array => "array",
                    .object => "object",
                    else => "unknown",
                };
                try msg_buf.appendSlice(it.alloc, type_str);
                try msg_buf.appendSlice(it.alloc, " (");
                try serializeValueCompact(&msg_buf, it.alloc, it.current);
                try msg_buf.appendSlice(it.alloc, ") only strings have UTF-8 byte length");
                const str_ref = try it.runtime_tape.internString(it.alloc, msg_buf.items);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                it.user_error_msg = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] };
                return error.UserError;
            },
        }
    }

    fn builtinTranspose(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .array => |span| {
                // Collect all sub-arrays
                var rows = std.ArrayList(Value.TapeSpan){};
                defer rows.deinit(it.alloc);
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    const elem = tapeEntryToValue(span.tape, pos);
                    switch (elem) {
                        .array => |inner| try rows.append(it.alloc, inner),
                        else => return error.TypeError,
                    }
                    pos = skipEntry(span.tape.*, pos);
                }
                if (rows.items.len == 0) {
                    return try it.buildRuntimeArray(&[_]Value{});
                }
                // Find max column count
                var max_cols: u32 = 0;
                for (rows.items) |row| {
                    const row_len = arrayLength(row.tape, row);
                    if (row_len > max_cols) max_cols = row_len;
                }
                // Build transposed result
                var result_rows = std.ArrayList(Value){};
                defer result_rows.deinit(it.alloc);
                var col: u32 = 0;
                while (col < max_cols) : (col += 1) {
                    // Build one column array
                    const inner_start = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .array_start,
                        .payload = .{ .skip = 0 },
                    });
                    for (rows.items) |row| {
                        const val = lookupIndex(row.tape, row, col) orelse Value.null_val;
                        try it.stackValueToRuntimeTapeEntry(try valueToStackValue(val));
                    }
                    const inner_end = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .array_end,
                        .payload = .{ .none = {} },
                    });
                    it.runtime_tape.entries.items[inner_start].payload.skip = inner_end + 1;
                    it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                    it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                    try result_rows.append(it.alloc, .{ .array = .{
                        .tape = &it.runtime_tape_view,
                        .start = inner_start,
                        .end = inner_end + 1,
                    } });
                }
                return try it.buildRuntimeArray(result_rows.items);
            },
            else => return error.TypeError,
        }
    }

    fn builtinBuiltinsList(it: *ResultIterator) ZqError!?StackValue {
        const builtin_names = [_][]const u8{
            "length/0",       "keys/0",           "keys_unsorted/0",
            "values/0",       "has/1",            "in/1",
            "type/0",         "empty/0",          "tostring/0",
            "tonumber/0",     "error/0",          "add/0",
            "range/1",        "range/2",          "range/3",
            "sort/0",         "sort_by/1",        "group_by/1",
            "reverse/0",      "flatten/0",        "flatten/1",
            "min/0",          "max/0",            "min_by/1",
            "max_by/1",       "to_entries/0",     "from_entries/0",
            "any/0",          "any/1",            "all/0",
            "all/1",          "contains/1",       "inside/1",
            "del/1",          "indices/1",        "index/1",
            "rindex/1",       "unique/0",         "unique_by/1",
            "map/1",          "select/1",         "with_entries/1",
            "first/0",        "first/1",          "last/0",
            "last/1",         "limit/2",
            // Type selectors
                     "arrays/0",
            "objects/0",      "strings/0",        "numbers/0",
            "booleans/0",     "nulls/0",          "scalars/0",
            "iterables/0",
            // Math
               "floor/0",          "ceil/0",
            "round/0",        "sqrt/0",           "fabs/0",
            "nan/0",          "infinite/0",       "isnan/0",
            "isinfinite/0",   "isnormal/0",       "pow/2",
            "log2/0",         "log/0",            "exp/0",
            "exp2/0",         "sin/0",            "cos/0",
            "atan/0",         "tan/0",            "asin/0",
            "acos/0",         "sinh/0",           "cosh/0",
            "tanh/0",         "significand/0",    "exponent/0",
            "logb/0",         "abs/0",
            // String
                       "ascii_downcase/0",
            "ascii_upcase/0", "ltrimstr/1",       "rtrimstr/1",
            "startswith/1",   "endswith/1",       "split/1",
            "join/1",         "explode/0",        "implode/0",
            "tojson/0",       "fromjson/0",       "toboolean/0",
            "ascii/0",
            // Misc
                   "utf8bytelength/0", "transpose/0",
            "builtins/0",     "have_decnum/0",    "bsearch/1",
            "isempty/1",      "map_values/1",
        };
        // Store StringRefs to avoid invalidation during interning
        var refs = std.ArrayList(Tape.StringRef){};
        defer refs.deinit(it.alloc);
        // Pre-reserve for all builtin name strings
        var total_bytes: usize = 0;
        for (builtin_names) |name| total_bytes += name.len;
        try it.runtime_tape.string_buf.ensureUnusedCapacity(it.alloc, total_bytes);
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        for (builtin_names) |name| {
            const str_ref = try it.runtime_tape.internString(it.alloc, name);
            try refs.append(it.alloc, str_ref);
        }
        return try it.buildRuntimeArrayFromRefs(refs.items);
    }

    /// `bsearch(x)`: binary search for x in a sorted array.
    /// Returns the index if found, or (-1 - insertion_point) if not found.
    fn builtinBsearch(it: *ResultIterator) ZqError!?StackValue {
        const target_sv = try it.popValue();
        const target = try stackValueToValue(target_sv);
        switch (it.current) {
            .array => |span| {
                // Collect elements for binary search
                var elems = std.ArrayList(Value){};
                defer elems.deinit(it.alloc);
                var pos = span.start + 1;
                const end = span.end - 1;
                while (pos < end) {
                    try elems.append(it.alloc, tapeEntryToValue(span.tape, pos));
                    pos = skipEntry(span.tape.*, pos);
                }
                // Binary search
                var lo: i64 = 0;
                var hi: i64 = @as(i64, @intCast(elems.items.len)) - 1;
                while (lo <= hi) {
                    const mid = lo + @divTrunc(hi - lo, 2);
                    const cmp = jqCompareValues(elems.items[@intCast(mid)], target);
                    switch (cmp) {
                        .eq => return .{ .int = mid },
                        .lt => lo = mid + 1,
                        .gt => hi = mid - 1,
                    }
                }
                // Not found: return -(insertion_point) - 1
                return .{ .int = -lo - 1 };
            },
            else => {
                // jq error: "TYPE cannot be searched from"
                var msg_buf = std.ArrayList(u8){};
                defer msg_buf.deinit(it.alloc);
                const type_str: []const u8 = switch (it.current) {
                    .null_val => "null",
                    .bool_val => "boolean",
                    .int, .float => "number",
                    .string => "string",
                    .array => "array",
                    .object => "object",
                };
                try msg_buf.appendSlice(it.alloc, type_str);
                try msg_buf.appendSlice(it.alloc, " (");
                try serializeValueCompact(&msg_buf, it.alloc, it.current);
                try msg_buf.appendSlice(it.alloc, ") cannot be searched from");
                const str_ref = try it.runtime_tape.internString(it.alloc, msg_buf.items);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                it.user_error_msg = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] };
                return error.UserError;
            },
        }
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
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape_view,
            .start = arr_start,
            .end = arr_end_idx + 1,
        } } };
    }

    /// Build a runtime array from an array of StringRefs.
    /// Safe against invalidation since refs are offsets, not pointers.
    fn buildRuntimeArrayFromRefs(it: *ResultIterator, refs: []const Tape.StringRef) ZqError!StackValue {
        const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });
        for (refs) |ref| {
            _ = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .string,
                .payload = .{ .string = ref },
            });
        }
        const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape_view,
            .start = arr_start,
            .end = arr_end_idx + 1,
        } } };
    }

    /// `range(n)`: generate 0..n-1
    fn builtinRange1(it: *ResultIterator) ZqError!?StackValue {
        const end_sv = try it.popValue();
        const resume_ip = it.ip + 1;

        switch (end_sv) {
            .int => |end_n| {
                if (end_n <= 0) {
                    it.ip = @intCast(it.instructions.len);
                    return null;
                }
                it.range_stack.appendAssumeCapacity(RangeFrame{
                    .current_int = 0,
                    .end_int = end_n,
                    .step_int = 1,
                    .current_float = 0,
                    .end_float = 0,
                    .step_float = 0,
                    .is_float = false,
                    .resume_ip = resume_ip,
                });
                it.current = .{ .int = 0 };
                it.ip = resume_ip;
            },
            .float => |end_f| {
                if (end_f <= 0) {
                    it.ip = @intCast(it.instructions.len);
                    return null;
                }
                it.range_stack.appendAssumeCapacity(RangeFrame{
                    .current_int = 0,
                    .end_int = 0,
                    .step_int = 0,
                    .current_float = 0,
                    .end_float = end_f,
                    .step_float = 1,
                    .is_float = true,
                    .resume_ip = resume_ip,
                });
                it.current = .{ .float = 0 };
                it.ip = resume_ip;
            },
            else => return error.TypeError,
        }
        return null;
    }

    /// `range(from;to)`: generate from..to-1
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
                it.ip = @intCast(it.instructions.len);
                return null;
            }
            it.range_stack.appendAssumeCapacity(RangeFrame{
                .current_int = 0,
                .end_int = 0,
                .step_int = 0,
                .current_float = from_f,
                .end_float = to_f,
                .step_float = 1,
                .is_float = true,
                .resume_ip = resume_ip,
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
                it.ip = @intCast(it.instructions.len);
                return null;
            }
            it.range_stack.appendAssumeCapacity(RangeFrame{
                .current_int = from_i,
                .end_int = to_i,
                .step_int = 1,
                .current_float = 0,
                .end_float = 0,
                .step_float = 0,
                .is_float = false,
                .resume_ip = resume_ip,
            });
            it.current = .{ .int = from_i };
        }
        it.ip = resume_ip;
        return null;
    }

    /// `range(from;to;by)`: generate from..to-1 stepping by `by`
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
                it.ip = @intCast(it.instructions.len);
                return null;
            }
            it.range_stack.appendAssumeCapacity(RangeFrame{
                .current_int = 0,
                .end_int = 0,
                .step_int = 0,
                .current_float = from_f,
                .end_float = to_f,
                .step_float = by_f,
                .is_float = true,
                .resume_ip = resume_ip,
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
                it.ip = @intCast(it.instructions.len);
                return null;
            }
            it.range_stack.appendAssumeCapacity(RangeFrame{
                .current_int = from_i,
                .end_int = to_i,
                .step_int = by_i,
                .current_float = 0,
                .end_float = 0,
                .step_float = 0,
                .is_float = false,
                .resume_ip = resume_ip,
            });
            it.current = .{ .int = from_i };
        }
        it.ip = resume_ip;
        return null;
    }

    fn toInt(val: StackValue) ZqError!i64 {
        return switch (val) {
            .int => |i| i,
            .bool_val => |b| if (b) 1 else 0,
            .float => |f| @intFromFloat(@round(f)),
            else => error.TypeError,
        };
    }

    fn toFloat(val: StackValue) ZqError!f64 {
        return switch (val) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            .bool_val => |b| if (b) 1.0 else 0.0,
            else => error.TypeError,
        };
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

    /// Short-circuit AND: if left is falsy, push it and skip to after right expression.
    fn doAndOp(it: *ResultIterator) ZqError!void {
        const right = try it.popValue();
        const left = try it.peekValue();

        // jq semantics: only null and false are falsy.
        if (!isCondTruthy(left)) {
            // Left is falsy: AND result is left (falsy)
            return;
        }

        // Left is truthy: AND result is right
        _ = try it.popValue();
        it.pushValue(right);
    }

    /// Short-circuit OR: if left is truthy, push it and skip to after right expression.
    fn doOrOp(it: *ResultIterator) ZqError!void {
        const right = try it.popValue();
        const left = try it.peekValue();

        // jq semantics: only null and false are falsy.
        if (isCondTruthy(left)) {
            // Left is truthy: OR result is left (truthy)
            return;
        }

        // Left is falsy: OR result is right
        _ = try it.popValue();
        it.pushValue(right);
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

    fn isTruthy(val: StackValue) ZqError!bool {
        return switch (val) {
            .bool_val => |b| b,
            .null_val => false,
            .int => |i| i != 0,
            .float => |f| f != 0.0,
            .tape_value => |tv| switch (tv) {
                .array, .object => true, // Non-empty containers are truthy
                .string => |s| s.len > 0, // Non-empty string is truthy
                .null_val => false,
                .bool_val => |b| b,
                else => true,
            },
        };
    }

    fn doIterate(it: *ResultIterator, resume_ip: u32) ZqError!void {
        if (it.stack.items.len >= max_stack_depth) return error.DepthLimitExceeded;

        switch (it.current) {
            .array => |span| {
                const first = span.start + 1;
                const end = span.end - 1; // position of array_end
                if (first >= end) {
                    // Empty array — skip past all instructions; produce no output.
                    it.ip = @intCast(it.instructions.len);
                    return;
                }
                it.stack.appendAssumeCapacity(IterFrame{
                    .pos = first,
                    .end = end,
                    .is_object = false,
                    .resume_ip = resume_ip,
                    .tape = span.tape,
                });
                it.current = tapeEntryToValue(span.tape, first);
                it.ip = resume_ip;
            },
            .object => |span| {
                const first_key = span.start + 1;
                const end = span.end - 1; // position of object_end
                if (first_key >= end) {
                    it.ip = @intCast(it.instructions.len);
                    return;
                }
                it.stack.appendAssumeCapacity(IterFrame{
                    .pos = first_key,
                    .end = end,
                    .is_object = true,
                    .resume_ip = resume_ip,
                    .tape = span.tape,
                });
                it.current = tapeEntryToValue(span.tape, first_key + 1);
                it.ip = resume_ip;
            },
            else => return error.TypeError,
        }
    }

    /// Advance the topmost IterFrame to its next element.
    /// Returns true and updates ip+current on success.
    /// Returns false and pops the exhausted frame on failure.
    fn advanceFrame(it: *ResultIterator) bool {
        const frame = &it.stack.items[it.stack.items.len - 1];

        const next_pos: u32 = if (frame.is_object)
            skipEntry(frame.tape.*, frame.pos + 1) // step past value → next key
        else
            skipEntry(frame.tape.*, frame.pos); // step past current value

        if (next_pos >= frame.end) {
            _ = it.stack.pop();
            return false;
        }

        frame.pos = next_pos;
        it.current = if (frame.is_object)
            tapeEntryToValue(frame.tape, next_pos + 1) // value after key
        else
            tapeEntryToValue(frame.tape, next_pos);
        it.ip = frame.resume_ip;
        return true;
    }

    /// Advance the topmost RangeFrame to its next value.
    /// Returns true if it produced a value; false if exhausted.
    fn advanceRangeFrame(it: *ResultIterator) bool {
        const frame = &it.range_stack.items[it.range_stack.items.len - 1];
        if (frame.is_float) {
            frame.current_float += frame.step_float;
            if ((frame.step_float > 0 and frame.current_float >= frame.end_float) or
                (frame.step_float < 0 and frame.current_float <= frame.end_float) or
                frame.step_float == 0)
            {
                _ = it.range_stack.pop();
                return false;
            }
            it.current = .{ .float = frame.current_float };
        } else {
            frame.current_int += frame.step_int;
            if ((frame.step_int > 0 and frame.current_int >= frame.end_int) or
                (frame.step_int < 0 and frame.current_int <= frame.end_int) or
                frame.step_int == 0)
            {
                _ = it.range_stack.pop();
                return false;
            }
            it.current = .{ .int = frame.current_int };
        }
        it.ip = frame.resume_ip;
        return true;
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
            .string => |bs| std.mem.eql(u8, as, bs),
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
        .object => false, // Simplified; object equality not needed for array subtraction
    };
}

// ── jq-compatible value comparison ────────────────────────────────────────────
// jq defines a total ordering: null < false < true < numbers < strings < arrays < objects

fn jqTypeOrder(v: Value) u8 {
    return switch (v) {
        .null_val => 0,
        .bool_val => |b| if (b) @as(u8, 2) else 1,
        .int, .float => 3,
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
            else => unreachable,
        },
        .float => |af| switch (b) {
            .int => |bi| floatOrder(af, @as(f64, @floatFromInt(bi))),
            .float => |bf| floatOrder(af, bf),
            else => unreachable,
        },
        .string => |as_str| switch (b) {
            .string => |bs_str| std.mem.order(u8, as_str, bs_str),
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
fn flattenNLevels(span: Value.TapeSpan, out: *std.ArrayList(Value), alloc: std.mem.Allocator, depth: u32) error{OutOfMemory}!void {
    var pos = span.start + 1;
    const end = span.end - 1;
    while (pos < end) {
        const elem = tapeEntryToValue(span.tape, pos);
        switch (elem) {
            .array => |inner_span| {
                if (depth > 0) {
                    try flattenNLevels(inner_span, out, alloc, depth - 1);
                } else {
                    try out.append(alloc, elem);
                }
            },
            else => {
                try out.append(alloc, elem);
            },
        }
        pos = skipEntry(span.tape.*, pos);
    }
}

/// Recursive containment check (jq semantics).
/// - Strings: b is substring of a
/// - Arrays: every element of b is contained by some element of a
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
        .string => |bs| return switch (a) {
            .string => |as_str| {
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
fn flattenRecursive(span: Value.TapeSpan, out: *std.ArrayList(Value), alloc: std.mem.Allocator) error{OutOfMemory}!void {
    var pos = span.start + 1;
    const end = span.end - 1;
    while (pos < end) {
        const elem = tapeEntryToValue(span.tape, pos);
        switch (elem) {
            .array => |inner_span| {
                try flattenRecursive(inner_span, out, alloc);
            },
            else => {
                try out.append(alloc, elem);
            },
        }
        pos = skipEntry(span.tape.*, pos);
    }
}

/// Compact JSON serialization of a Value into a buffer (for tostring builtin).
/// Append a JSON-encoded string (with surrounding quotes) to buf.
fn appendJsonString(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}!void {
    try buf.append(alloc, '"');
    for (s) |c| {
        if (c == '"') try buf.appendSlice(alloc, "\\\"") else if (c == '\\') try buf.appendSlice(alloc, "\\\\") else if (c < 0x20) {
            var tmp: [6]u8 = undefined;
            const seq = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(alloc, seq);
        } else try buf.append(alloc, c);
    }
    try buf.append(alloc, '"');
}

fn serializeValueCompact(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, val: Value) error{OutOfMemory}!void {
    switch (val) {
        .null_val => try buf.appendSlice(alloc, "null"),
        .bool_val => |b| try buf.appendSlice(alloc, if (b) "true" else "false"),
        .int => |n| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
            try buf.appendSlice(alloc, s);
        },
        .float => |f| {
            if (std.math.isNan(f) or std.math.isInf(f)) {
                try buf.appendSlice(alloc, "null");
            } else {
                var tmp: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
                try buf.appendSlice(alloc, s);
            }
        },
        .string => |s| {
            try appendJsonString(buf, alloc, s);
        },
        .array => |span| {
            try buf.append(alloc, '[');
            var pos = span.start + 1;
            const end = span.end - 1;
            var first = true;
            while (pos < end) {
                if (!first) try buf.append(alloc, ',');
                first = false;
                try serializeValueCompact(buf, alloc, tapeEntryToValue(span.tape, pos));
                pos = skipEntry(span.tape.*, pos);
            }
            try buf.append(alloc, ']');
        },
        .object => |span| {
            try buf.append(alloc, '{');
            var pos = span.start + 1;
            const end = span.end - 1;
            var first = true;
            while (pos < end) {
                if (!first) try buf.append(alloc, ',');
                first = false;
                const key_str = span.tape.getString(span.tape.entries[pos].payload.string);
                try buf.append(alloc, '"');
                try buf.appendSlice(alloc, key_str);
                try buf.appendSlice(alloc, "\":");
                try serializeValueCompact(buf, alloc, tapeEntryToValue(span.tape, pos + 1));
                pos = skipEntry(span.tape.*, pos + 1);
            }
            try buf.append(alloc, '}');
        },
    }
}

/// Convert a StackValue to a Value for output.
fn stackValueToValue(sv: StackValue) ZqError!Value {
    return switch (sv) {
        .null_val => .null_val,
        .bool_val => |b| .{ .bool_val = b },
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
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
        .string => |s| .{ .tape_value = .{ .string = s } },
        .object => |o| .{ .tape_value = .{ .object = o } },
        .array => |a| .{ .tape_value = .{ .array = a } },
    };
}

// ── Tape helpers ──────────────────────────────────────────────────────────────

fn tapeEntryToValue(tape: *const Tape, pos: u32) Value {
    const e = tape.entries[pos];
    return switch (e.tag) {
        .null_val => .null_val,
        .true_val => .{ .bool_val = true },
        .false_val => .{ .bool_val = false },
        .int => .{ .int = e.payload.int },
        .float => .{ .float = e.payload.float },
        .string => .{ .string = tape.getString(e.payload.string) },
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
