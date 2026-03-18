const std = @import("std");
const ZqError = @import("error").ZqError;
const types = @import("types");
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

const ForkType = enum(u8) { normal, each, range, try_handler, alt_handler, label, limit };

const EachState = struct {
    pos: u32,
    end: u32,
    tape: *const Tape,
    is_object: bool,
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

const ForkAux = union(ForkType) {
    normal: void,
    each: EachState,
    range: RangeState,
    try_handler: TryHandlerState,
    alt_handler: TryHandlerState,
    label: LabelState,
    limit: LimitState,
};

const Forkpoint = struct {
    saved_value_stack_len: u32,
    saved_current: Value,
    backtrack_ip: u32,
    aux: ForkAux,
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
    /// Stack of saved field counts for nested object construction.
    object_construct_depth: std.ArrayList(u32),
    /// Stack of saved `current` values for if/elif branch restoration.
    /// save_input pushes; restore_input pops.
    if_stack: std.ArrayList(Value),
    /// Active array collection frames. Pushed by array_collect_start.
    collect_stack: std.ArrayList(CollectFrame),
    /// Active call frames for user-defined recursive function calls.
    call_stack: std.ArrayList(CallFrame),
    /// Fork stack for unified backtracking (comma, iteration, range, try, alt, label, limit).
    fork_stack: std.ArrayList(Forkpoint),
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

    pub fn init(
        instructions: []const Instruction,
        function_table: []const types.FunctionDef,
        string_buf: []const u8,
        opts_allow_null: bool,
        tape: Tape,
        external_bindings: []const ExternalVarBinding,
        source_map: []const u32,
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

        // Initialize if-branch input stack
        var if_stack = std.ArrayList(Value){};
        errdefer if_stack.deinit(allocator);
        try if_stack.ensureTotalCapacity(allocator, max_stack_depth);

        // Initialize array collect stack (nesting depth rarely exceeds 8)
        var collect_stack = std.ArrayList(CollectFrame){};
        errdefer collect_stack.deinit(allocator);
        try collect_stack.ensureTotalCapacity(allocator, 16);

        // Initialize call frame stack for recursive user-defined functions
        var call_stack = std.ArrayList(CallFrame){};
        errdefer call_stack.deinit(allocator);
        try call_stack.ensureTotalCapacity(allocator, 64);

        // Initialize fork stack for unified backtracking
        var fork_stack = std.ArrayList(Forkpoint){};
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
            .value_stack = value_stack,
            .variable_store = variable_store,
            .runtime_tape = runtime_tape,
            .runtime_tape_view = runtime_tape_view,
            .object_construct = object_construct,
            .object_construct_depth = object_construct_depth,
            .if_stack = if_stack,
            .collect_stack = collect_stack,
            .call_stack = call_stack,
            .fork_stack = fork_stack,
            .next_break_token = 0,
            .user_error_msg = null,
            .type_error_detail = null,
            .alloc = allocator,
            .done = false,
            .initialized = false,
            .source_map = source_map,
            .last_error_ip = 0,
        };
    }

    /// Free the internal eval stack. Idempotent.
    pub fn deinit(it: *ResultIterator) void {
        it.value_stack.deinit(it.alloc);
        it.variable_store.deinit(it.alloc);
        it.object_construct.deinit(it.alloc);
        it.object_construct_depth.deinit(it.alloc);
        it.if_stack.deinit(it.alloc);
        for (it.collect_stack.items) |*frame| frame.buffer.deinit(it.alloc);
        it.collect_stack.deinit(it.alloc);
        it.call_stack.deinit(it.alloc);
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
        for (it.collect_stack.items) |*frame| frame.buffer.deinit(it.alloc);
        it.collect_stack.clearRetainingCapacity();
        it.call_stack.clearRetainingCapacity();
        it.fork_stack.clearRetainingCapacity();
        it.next_break_token = 0;
        it.user_error_msg = null;
        it.type_error_detail = null;
        it.runtime_tape.entries.clearRetainingCapacity();
        it.runtime_tape.string_buf.clearRetainingCapacity();
        it.runtime_tape_view = types.Tape{
            .entries = it.runtime_tape.entries.items,
            .string_buf = it.runtime_tape.string_buf.items,
        };
    }

    /// True when null propagation is active (globally via Opts).
    inline fn nullAllowed(it: *const ResultIterator) bool {
        return it.opts_allow_null;
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
                // Try fork-stack backtracking (handles comma, each, range, try, alt, label, limit).
                if (it.doBacktrack()) continue;

                // No forkpoints — check for collect frame finalization.
                if (it.collect_stack.items.len > 0) {
                    var completed = it.collect_stack.pop().?;
                    defer completed.buffer.deinit(it.alloc);
                    const arr_val = try it.buildCollectedArray(&completed);
                    it.pushValue(arr_val);
                    it.if_stack.items.len = completed.outer_if_depth;
                    it.ip = completed.end_ip + 1;
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
                if (it.handleError(err)) {
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
    fn handleError(it: *ResultIterator, err: ZqError) bool {
        var idx = it.fork_stack.items.len;
        while (idx > 0) {
            idx -= 1;
            const fp = it.fork_stack.items[idx];
            const state = switch (fp.aux) {
                .try_handler, .alt_handler => |s| s,
                else => continue,
            };

            // Unwind fork stack (pops generators between error and handler).
            it.fork_stack.items.len = idx;
            // Unwind other stacks.
            it.value_stack.items.len = fp.saved_value_stack_len;
            it.if_stack.items.len = state.saved_if_len;
            // Unwind collect frames (free buffers).
            while (it.collect_stack.items.len > state.saved_collect_len) {
                var cf = it.collect_stack.pop().?;
                cf.buffer.deinit(it.alloc);
            }
            it.call_stack.items.len = state.saved_call_len;

            if (state.catch_ip > 0) {
                // Route to catch handler with error as current.
                if (err == error.UserError) {
                    it.current = it.user_error_msg orelse Value{ .string = "null" };
                    it.user_error_msg = null;
                } else if (err == error.TypeError and it.type_error_detail != null) {
                    it.current = it.type_error_detail.?;
                    it.type_error_detail = null;
                } else {
                    it.current = Value{ .string = errorToString(err) };
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

                if (!it.doBacktrack()) {
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

            .output, .iterate => unreachable,

            .load_key => {
                const key = it.string_buf[instr.operand.str_ref.offset..][0..instr.operand.str_ref.len];
                const result = lookupKeyInValue(
                    &it.tape,
                    it.nullAllowed(),
                    it.current,
                    key,
                ) catch |err| {
                    if (err == error.TypeError) {
                        it.type_error_detail = it.buildTypeErrorMsg(it.current, key);
                    }
                    return err;
                };
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
                    // jq: float index on array truncates to int; nan/inf → null
                    .float => |f| switch (base) {
                        .array => |span| blk: {
                            if (std.math.isNan(f) or std.math.isInf(f)) break :blk @as(Value, .null_val);
                            const i: i64 = @intFromFloat(@trunc(f));
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
                    // jq: null index on anything returns null
                    .null_val => @as(Value, .null_val),
                    else => return error.TypeError,
                };
                it.ip += 1;
                return null;
            },

            .load_path => {
                const path = it.string_buf[instr.operand.str_ref.offset..][0..instr.operand.str_ref.len];
                it.current = try it.doLoadPath(path);
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
                const key = it.string_buf[instr.operand.str_ref.offset..][0..instr.operand.str_ref.len];
                it.current = lookupKeyInValue(&it.tape, it.nullAllowed(), it.current, key) catch |err| {
                    if (err == error.TypeError) {
                        it.type_error_detail = it.buildTypeErrorMsg(it.current, key);
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

            // Deprecated opcodes — kept in enum for ABI stability.
            .alt_start, .alt_check, .try_begin, .try_end => unreachable,

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
                    .backtrack_ip = @intCast(instr.operand.index),
                    .aux = .{ .try_handler = handler_state },
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
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .backtrack_ip = @intCast(instr.operand.index),
                    .aux = .{ .alt_handler = handler_state },
                });
                it.ip += 1;
                return null;
            },

            .pop_try => {
                // Scan fork_stack backwards for nearest try_handler or alt_handler and remove it.
                var idx = it.fork_stack.items.len;
                while (idx > 0) {
                    idx -= 1;
                    switch (it.fork_stack.items[idx].aux) {
                        .try_handler, .alt_handler => {
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
                // Pop the depth marker to find where this level's fields start.
                const saved_depth = if (it.object_construct_depth.items.len > 0)
                    it.object_construct_depth.pop().?
                else
                    0;
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
                // Recursive function call: push a call frame and jump to the body.
                const max_recursion_depth = 10000;
                if (it.call_stack.items.len >= max_recursion_depth) {
                    return error.TypeError;
                }
                const body_ip = @as(u32, @intCast(instr.operand.index));
                try it.call_stack.append(it.alloc, CallFrame{
                    .return_ip = it.ip + 1,
                    .saved_value_len = @intCast(it.value_stack.items.len),
                    .saved_if_len = @intCast(it.if_stack.items.len),
                    .saved_collect_len = @intCast(it.collect_stack.items.len),
                    .saved_fork_len = @intCast(it.fork_stack.items.len),
                });
                it.ip = body_ip;
                return null;
            },

            .return_function => {
                // Return from a recursive function call.
                if (it.call_stack.items.len > 0) {
                    const frame = it.call_stack.pop().?;
                    it.ip = frame.return_ip;
                } else {
                    // Should not happen — return without matching call.
                    it.ip += 1;
                }
                return null;
            },

            .call_filter_arg => {
                // Should never appear at runtime — filter args are expanded at compile time.
                return error.TypeError;
            },

            .call_builtin => {
                const bid: BuiltinId = @enumFromInt(@as(u16, @intCast(instr.operand.index)));
                const result = try it.doBuiltin(bid);
                if (result) |val| {
                    it.pushValue(val);
                }
                // doBuiltin advances ip when it sets up generators (range, paths, leaf_paths);
                // otherwise advance here.
                // For empty, ip is set past end of instructions — do not advance again.
                // We only advance if doBuiltin didn't already change ip.
                if (bid != .empty and bid != .range and bid != .range2 and bid != .range3 and
                    bid != .paths and bid != .leaf_paths and bid != .recurse)
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
                    .backtrack_ip = @intCast(instr.operand.index), // exit_ip
                    .aux = .{ .label = .{
                        .break_token = token,
                        .exit_ip = @intCast(instr.operand.index),
                        .saved_if_len = @intCast(it.if_stack.items.len),
                        .saved_collect_len = @intCast(it.collect_stack.items.len),
                        .saved_call_len = @intCast(it.call_stack.items.len),
                    } },
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
                            it.fork_stack.items.len = idx;
                            // Unwind other stacks.
                            it.value_stack.items.len = fp.saved_value_stack_len;
                            it.if_stack.items.len = state.saved_if_len;
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
                            it.call_stack.items.len = state.saved_call_len;
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
                    it.user_error_msg = .{ .string = "limit doesn't support negative count" };
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
                    .backtrack_ip = @intCast(instr.operand.index), // exit_ip
                    .aux = .{ .limit = .{
                        .remaining = @intCast(n_i),
                        .body_start_ip = it.ip,
                        .exit_ip = @intCast(instr.operand.index),
                        .saved_collect_len = @intCast(it.collect_stack.items.len),
                    } },
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

            // ── Fork stack opcodes ──────────────────────────────────────────

            .fork => {
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .backtrack_ip = @intCast(instr.operand.index),
                    .aux = .{ .normal = {} },
                });
                it.ip += 1;
                return null;
            },

            .backtrack => {
                if (!it.doBacktrack()) {
                    // No forkpoints — let step() handle collect finalization or done.
                    it.ip = @intCast(it.instructions.len);
                }
                return null;
            },

            .each => {
                switch (it.current) {
                    .array => |span| {
                        const first = span.start + 1;
                        const end = span.end - 1;
                        if (first >= end) {
                            // Empty array — backtrack to next generator.
                            if (!it.doBacktrack()) {
                                it.ip = @intCast(it.instructions.len);
                            }
                            return null;
                        }
                        it.fork_stack.appendAssumeCapacity(.{
                            .saved_value_stack_len = @intCast(it.value_stack.items.len),
                            .saved_current = it.current,
                            .backtrack_ip = it.ip,
                            .aux = .{ .each = .{
                                .pos = first,
                                .end = end,
                                .is_object = false,
                                .tape = span.tape,
                            } },
                        });
                        it.current = tapeEntryToValue(span.tape, first);
                        it.ip += 1;
                    },
                    .object => |span| {
                        const first_key = span.start + 1;
                        const end = span.end - 1;
                        if (first_key >= end) {
                            if (!it.doBacktrack()) {
                                it.ip = @intCast(it.instructions.len);
                            }
                            return null;
                        }
                        it.fork_stack.appendAssumeCapacity(.{
                            .saved_value_stack_len = @intCast(it.value_stack.items.len),
                            .saved_current = it.current,
                            .backtrack_ip = it.ip,
                            .aux = .{ .each = .{
                                .pos = first_key,
                                .end = end,
                                .is_object = true,
                                .tape = span.tape,
                            } },
                        });
                        it.current = tapeEntryToValue(span.tape, first_key + 1);
                        it.ip += 1;
                    },
                    .null_val => {
                        // null | .[] produces nothing.
                        if (!it.doBacktrack()) {
                            it.ip = @intCast(it.instructions.len);
                        }
                        return null;
                    },
                    else => return error.TypeError,
                }
                return null;
            },

            .yield_output => {
                const val = if (it.value_stack.items.len > 0)
                    try stackValueToValue(try it.popValue())
                else
                    it.current;

                // Check limit counter via fork_stack.
                {
                    const output_ip = it.ip;
                    var li: usize = it.fork_stack.items.len;
                    while (li > 0) {
                        li -= 1;
                        if (it.fork_stack.items[li].aux == .limit) {
                            var lstate = &it.fork_stack.items[li].aux.limit;
                            if (output_ip > lstate.body_start_ip and output_ip < lstate.exit_ip) {
                                if (it.collect_stack.items.len > lstate.saved_collect_len) {
                                    break;
                                }
                                lstate.remaining -= 1;
                                if (lstate.remaining == 0) {
                                    // Exhausted: unwind fork stack to this limit.
                                    it.fork_stack.items.len = li;
                                    if (it.collect_stack.items.len > 0) {
                                        const cf = &it.collect_stack.items[it.collect_stack.items.len - 1];
                                        try cf.buffer.append(it.alloc, try valueToStackValue(val));
                                        it.value_stack.items.len = cf.outer_value_depth;
                                        it.ip = @intCast(it.instructions.len);
                                        return null;
                                    } else {
                                        it.ip = @intCast(it.instructions.len);
                                        return val;
                                    }
                                }
                                break;
                            }
                        }
                    }
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
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;

        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape_view,
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
                .int => |ri| .{ .int = li + ri },
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
                .int => |ri| .{ .int = li - ri },
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
    /// Copy a tape span into the runtime tape. Two-pass linear approach:
    /// no recursion, no auxiliary allocations. O(n) in span size.
    fn copyTapeSpanToRuntimeTape(it: *ResultIterator, span: types.Value.TapeSpan) ZqError!void {
        const n_entries = span.end - span.start;
        var n_string_bytes: usize = 0;
        for (span.tape.entries[span.start..span.end]) |e| {
            switch (e.tag) {
                .key, .string => n_string_bytes += e.payload.string.len,
                else => {},
            }
        }

        // Reserve capacity up front so the view stays valid.
        try it.runtime_tape.entries.ensureUnusedCapacity(it.alloc, n_entries);
        try it.runtime_tape.string_buf.ensureUnusedCapacity(it.alloc, n_string_bytes);
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;

        const base: u32 = @intCast(it.runtime_tape.entries.items.len);

        // Pass 1: copy all entries linearly, re-interning strings.
        var pos = span.start;
        while (pos < span.end) {
            const entry = span.tape.entries[pos];
            switch (entry.tag) {
                .key, .string => {
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

        // Refresh the view after modifications.
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
    }

    fn doMul(it: *ResultIterator) ZqError!StackValue {
        const right = try it.popValue();
        const left = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);

        return switch (left) {
            .int => |li| switch (right) {
                .int => |ri| .{ .int = li * ri },
                .float => |rf| .{ .float = @as(f64, @floatFromInt(li)) * rf },
                .tape_value => |rtv| switch (rtv) {
                    .string => |s| try it.doStringRepeat(s, li),
                    else => error.TypeError,
                },
                else => error.TypeError,
            },
            .float => |lf| switch (right) {
                .int => |ri| .{ .float = lf * @as(f64, @floatFromInt(ri)) },
                .float => |rf| .{ .float = lf * rf },
                .tape_value => |rtv| switch (rtv) {
                    .string => |s| try it.doStringRepeat(s, @intFromFloat(@floor(lf))),
                    else => error.TypeError,
                },
                else => error.TypeError,
            },
            .tape_value => |ltv| switch (ltv) {
                .object => |lspan| switch (right) {
                    .tape_value => |rtv| switch (rtv) {
                        .object => |rspan| try it.doRecursiveMerge(lspan, rspan),
                        else => error.TypeError,
                    },
                    else => error.TypeError,
                },
                .string => |s| switch (right) {
                    .int => |ri| try it.doStringRepeat(s, ri),
                    .float => |rf| try it.doStringRepeat(s, @intFromFloat(@floor(rf))),
                    else => error.TypeError,
                },
                else => error.TypeError,
            },
            else => error.TypeError,
        };
    }

    /// String repetition for `*` operator.
    /// `"abc" * 3` produces `"abcabcabc"`. `"abc" * 0` produces `null`.
    fn doStringRepeat(it: *ResultIterator, s: []const u8, n: i64) !StackValue {
        if (n < 0) return .null_val;
        if (n == 0) return .{ .tape_value = .{ .string = "" } };
        const count: usize = @intCast(n);
        if (count == 1) return .{ .tape_value = .{ .string = s } };
        // Guard against excessive allocations
        const total_len = s.len * count;
        if (total_len > 128 * 1024 * 1024) {
            const str_ref = try it.runtime_tape.internString(it.alloc, "Repeat string result too long");
            it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
            it.user_error_msg = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] };
            return error.UserError;
        }
        const start_off: u32 = @intCast(it.runtime_tape.string_buf.items.len);
        try it.runtime_tape.string_buf.ensureUnusedCapacity(it.alloc, total_len);
        for (0..count) |_| {
            it.runtime_tape.string_buf.appendSliceAssumeCapacity(s);
        }
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[start_off..][0..total_len] } };
    }

    /// jq: string / string = split. Splits the left string by the right separator.
    fn doStringSplit(it: *ResultIterator, input: []const u8, sep: []const u8) ZqError!StackValue {
        const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });

        if (sep.len == 0) {
            // Split into individual characters (UTF-8 aware)
            var i: usize = 0;
            while (i < input.len) {
                const seq_len = std.unicode.utf8ByteSequenceLength(input[i]) catch 1;
                const char_end = @min(i + seq_len, input.len);
                const str_ref = try it.runtime_tape.internString(it.alloc, input[i..char_end]);
                _ = try it.runtime_tape.appendEntry(it.alloc, .{
                    .tag = .string,
                    .payload = .{ .string = str_ref },
                });
                i = char_end;
            }
        } else {
            var rest = input;
            while (true) {
                if (std.mem.indexOf(u8, rest, sep)) |idx| {
                    const str_ref = try it.runtime_tape.internString(it.alloc, rest[0..idx]);
                    _ = try it.runtime_tape.appendEntry(it.alloc, .{
                        .tag = .string,
                        .payload = .{ .string = str_ref },
                    });
                    rest = rest[idx + sep.len ..];
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
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape_view,
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
            // jq: string / string = split(separator)
            .tape_value => |ltv| switch (ltv) {
                .string => |ls| switch (right) {
                    .tape_value => |rtv| switch (rtv) {
                        .string => |rs| try it.doStringSplit(ls, rs),
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
        // If either operand is a float (including inf/nan), use float modulo
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
                else => return error.TypeError,
            };
            const rf: f64 = switch (right) {
                .int => |i| @as(f64, @floatFromInt(i)),
                .float => |f| f,
                else => return error.TypeError,
            };
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
                // `empty` produces no output — backtrack to next generator path.
                if (!it.doBacktrack()) {
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
            .test_ => return try it.builtinTest(),
            .match_ => return try it.builtinMatch(),
            .sub_ => return try it.builtinSub(),
            .gsub_ => return try it.builtinGsub(),

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
            .input_, .inputs_ => {
                // Produce empty — not applicable in query context
                it.ip = @intCast(it.instructions.len);
                return null;
            },
            .env_ => return try it.builtinEnv(),
            .halt_ => {
                it.ip = @intCast(it.instructions.len);
                return null;
            },
            .halt_error_ => {
                return error.UserError;
            },
            .map_values_ => return try it.builtinMapValues(),
            .isempty_ => return try it.builtinIsempty(),
            .first_ => return try it.builtinFirst(),
            .last_ => return try it.builtinLast(),
        }
    }

    fn builtinLength(it: *ResultIterator) ZqError!?StackValue {
        const val = it.current;
        return switch (val) {
            .null_val => .{ .int = 0 },
            .bool_val => return error.TypeError,
            .int => |i| .{ .int = if (i < 0) -i else i },
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
                    // jq: has(nan) / has(float) on array returns false — not a valid index.
                    .float => return .{ .bool_val = false },
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
                const formatted = types.formatJqFloat(f);
                const str_ref = try it.runtime_tape.internString(it.alloc, formatted.slice());
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
                            // Look for key/name/Key/Name field (jq accepts all four variants)
                            const key_val = lookupKey(espan.tape, espan, "key") orelse
                                lookupKey(espan.tape, espan, "name") orelse
                                lookupKey(espan.tape, espan, "Key") orelse
                                lookupKey(espan.tape, espan, "Name") orelse
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
                // String search: find all codepoint indices of needle string
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
            .string => |haystack| {
                const needle_str = switch (needle) {
                    .string => |s| s,
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

    // ── Format string builtins ─────────────────────────────────────────────

    /// @json: serialize current value as compact JSON string (like tojson)
    fn builtinFormatJson(it: *ResultIterator) ZqError!?StackValue {
        var json_buf = std.ArrayList(u8){};
        defer json_buf.deinit(it.alloc);
        try serializeValueCompact(&json_buf, it.alloc, it.current);
        const str_ref = try it.runtime_tape.internString(it.alloc, json_buf.items);
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
    }

    /// @html: HTML-escape: & → &amp;, < → &lt;, > → &gt;, ' → &apos;, " → &quot;
    fn builtinFormatHtml(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |str| str,
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
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
    }

    /// @uri: Percent-encode all bytes except A-Za-z0-9-._~, uppercase hex (%XX)
    fn builtinFormatUri(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |str| str,
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
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
    }

    /// @urid: Decode %XX sequences in a string
    fn builtinFormatUrid(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |str| str,
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
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
    }

    /// @sh: Wrap in single quotes, escape ' as '\''
    fn builtinFormatSh(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |str| str,
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
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
    }

    /// @base64: Base64 encode the string
    fn builtinFormatBase64(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |str| str,
            else => return error.TypeError,
        };
        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(s.len);
        const buf = try it.alloc.alloc(u8, encoded_len);
        defer it.alloc.free(buf);
        const encoded = encoder.encode(buf, s);
        const str_ref = try it.runtime_tape.internString(it.alloc, encoded);
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
    }

    /// @base64d: Base64 decode the string
    fn builtinFormatBase64d(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |str| str,
            else => return error.TypeError,
        };
        const decoder = std.base64.standard.Decoder;
        const decoded_len = decoder.calcSizeForSlice(s) catch return error.TypeError;
        var buf = try it.alloc.alloc(u8, decoded_len);
        defer it.alloc.free(buf);
        decoder.decode(buf, s) catch return error.TypeError;
        const str_ref = try it.runtime_tape.internString(it.alloc, buf[0..decoded_len]);
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
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
                .string => |s| {
                    try buf.append(it.alloc, '"');
                    for (s) |c| {
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
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
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
                .string => |s| {
                    for (s) |c| {
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
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
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

    /// `range(n)`: generate 0..n-1 via fork stack
    fn builtinRange1(it: *ResultIterator) ZqError!?StackValue {
        const end_sv = try it.popValue();
        const resume_ip = it.ip + 1;

        switch (end_sv) {
            .int => |end_n| {
                if (end_n <= 0) {
                    if (!it.doBacktrack()) it.ip = @intCast(it.instructions.len);
                    return null;
                }
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
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
                });
                it.current = .{ .int = 0 };
                it.ip = resume_ip;
            },
            .float => |end_f| {
                if (end_f <= 0) {
                    if (!it.doBacktrack()) it.ip = @intCast(it.instructions.len);
                    return null;
                }
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
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
                if (!it.doBacktrack()) it.ip = @intCast(it.instructions.len);
                return null;
            }
            it.fork_stack.appendAssumeCapacity(.{
                .saved_value_stack_len = @intCast(it.value_stack.items.len),
                .saved_current = it.current,
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
                if (!it.doBacktrack()) it.ip = @intCast(it.instructions.len);
                return null;
            }
            it.fork_stack.appendAssumeCapacity(.{
                .saved_value_stack_len = @intCast(it.value_stack.items.len),
                .saved_current = it.current,
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
                if (!it.doBacktrack()) it.ip = @intCast(it.instructions.len);
                return null;
            }
            it.fork_stack.appendAssumeCapacity(.{
                .saved_value_stack_len = @intCast(it.value_stack.items.len),
                .saved_current = it.current,
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
                if (!it.doBacktrack()) it.ip = @intCast(it.instructions.len);
                return null;
            }
            it.fork_stack.appendAssumeCapacity(.{
                .saved_value_stack_len = @intCast(it.value_stack.items.len),
                .saved_current = it.current,
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
        var elems = try it.alloc.alloc(Value, len);
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
        defer it.alloc.free(n_elems);

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
        defer it.alloc.free(from_elems);
        const to_elems = try it.extractArrayElements(to_arr);
        defer it.alloc.free(to_elems);

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
        defer it.alloc.free(from_elems);
        const to_elems = try it.extractArrayElements(to_val);
        defer it.alloc.free(to_elems);
        const by_elems = try it.extractArrayElements(by_arr);
        defer it.alloc.free(by_elems);

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
        defer it.alloc.free(n_elems);
        const f_elems = try it.extractArrayElements(f_arr);
        defer it.alloc.free(f_elems);

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
    fn builtinGetpath(it: *ResultIterator) ZqError!?StackValue {
        const path_sv = try it.popValue();
        const path_val = try stackValueToValue(path_sv);

        // Walk the path array directly from the tape without extracting elements.
        // This avoids holding Value references that might become stale.
        const span = switch (path_val) {
            .array => |s| s,
            else => return error.TypeError,
        };

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
        defer it.alloc.free(path_elems);

        const result = try it.setpathRecursive(it.current, path_elems, 0, new_val);
        return try valueToStackValue(result);
    }

    /// Recursively rebuild the structure with the value at path[depth..] replaced.
    fn setpathRecursive(it: *ResultIterator, base: Value, path: []const Value, depth: usize, new_val: Value) ZqError!Value {
        if (depth >= path.len) return new_val;

        const component = path[depth];
        switch (component) {
            .string => |key| {
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
                    else => {},
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
                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .object = .{
                    .tape = &it.runtime_tape_view,
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
                        else => 0,
                    };
                    const resolved = len + idx;
                    if (resolved < 0) break :blk 0;
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
                    else => return error.TypeError,
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
                it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .array = .{
                    .tape = &it.runtime_tape_view,
                    .start = result_start,
                    .end = result_end,
                } };
            },
            else => return error.TypeError,
        }
    }

    /// `delpaths(PATHS)`: delete multiple paths. Paths is an array of path arrays.
    /// Sort paths in reverse order (deeper/higher-index first), apply each deletion.
    fn builtinDelpaths(it: *ResultIterator) ZqError!?StackValue {
        const paths_sv = try it.popValue();
        const paths_val = try stackValueToValue(paths_sv);
        const paths_elems = try it.extractArrayElements(paths_val);
        defer it.alloc.free(paths_elems);

        // Extract each path as an array of elements.
        var path_list = std.ArrayList([]Value){};
        defer {
            for (path_list.items) |p| it.alloc.free(p);
            path_list.deinit(it.alloc);
        }
        for (paths_elems) |p| {
            const elems = try it.extractArrayElements(p);
            try path_list.append(it.alloc, elems);
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

    /// Delete a single path from a value.
    fn delpathSingle(it: *ResultIterator, base: Value, path: []const Value, depth: usize) ZqError!Value {
        if (depth >= path.len) return error.TypeError; // can't delete empty path

        const component = path[depth];
        const is_leaf = (depth + 1 == path.len);

        switch (component) {
            .string => |key| {
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
                        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                        return .{ .object = .{
                            .tape = &it.runtime_tape_view,
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
                        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
                        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                        return .{ .array = .{
                            .tape = &it.runtime_tape_view,
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
            if (!it.doBacktrack()) {
                it.ip = @intCast(it.instructions.len);
            }
            return null;
        }

        // Build a container array of all path arrays on runtime tape.
        const arr = try it.buildRuntimeArray(all_paths.items);
        it.current = try stackValueToValue(arr);

        // Set up fork-based iteration over the container.
        if (!it.setupEachFromCurrent()) {
            if (!it.doBacktrack()) {
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
                    const k = span.tape.getString(span.tape.entries[pos].payload.string);
                    const child_val = tapeEntryToValue(span.tape, pos + 1);
                    try path_buf.append(it.alloc, .{ .string = k });
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
    fn builtinRecurse(it: *ResultIterator) ZqError!?StackValue {
        var all_values = std.ArrayList(Value){};
        defer all_values.deinit(it.alloc);

        try it.collectRecurse(it.current, &all_values);

        if (all_values.items.len == 0) {
            if (!it.doBacktrack()) {
                it.ip = @intCast(it.instructions.len);
            }
            return null;
        }

        // Build a container array of all collected values on runtime tape.
        const arr = try it.buildRuntimeArray(all_values.items);
        it.current = try stackValueToValue(arr);

        // Set up fork-based iteration over the container.
        if (!it.setupEachFromCurrent()) {
            if (!it.doBacktrack()) {
                it.ip = @intCast(it.instructions.len);
            }
        }
        return null;
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

    /// Build a path array (e.g. ["a", 0, "b"]) on the runtime tape.
    fn buildPathArray(it: *ResultIterator, components: []const Value) ZqError!Value {
        const arr_start = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });
        for (components) |comp| {
            switch (comp) {
                .string => |s| {
                    const str_ref = try it.runtime_tape.internString(it.alloc, s);
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
                else => return error.TypeError,
            }
        }
        const arr_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .array = .{
            .tape = &it.runtime_tape_view,
            .start = arr_start,
            .end = arr_end_idx + 1,
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

    // ── Fork stack backtracking ─────────────────────────────────────────────

    /// Set up fork-based iteration over it.current (must be array/object).
    /// Used by builtins (paths, recurse) that build a container and iterate.
    /// Returns false if container is empty (caller should backtrack or set ip past end).
    fn setupEachFromCurrent(it: *ResultIterator) bool {
        switch (it.current) {
            .array => |span| {
                const first = span.start + 1;
                const end = span.end - 1;
                if (first >= end) return false;
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .backtrack_ip = it.ip,
                    .aux = .{ .each = .{
                        .pos = first,
                        .end = end,
                        .is_object = false,
                        .tape = span.tape,
                    } },
                });
                it.current = tapeEntryToValue(span.tape, first);
                it.ip += 1;
                return true;
            },
            .object => |span| {
                const first_key = span.start + 1;
                const end = span.end - 1;
                if (first_key >= end) return false;
                it.fork_stack.appendAssumeCapacity(.{
                    .saved_value_stack_len = @intCast(it.value_stack.items.len),
                    .saved_current = it.current,
                    .backtrack_ip = it.ip,
                    .aux = .{ .each = .{
                        .pos = first_key,
                        .end = end,
                        .is_object = true,
                        .tape = span.tape,
                    } },
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
        it.current = if (st.is_object)
            tapeEntryToValue(st.tape, next_pos + 1) // value after key
        else
            tapeEntryToValue(st.tape, next_pos);
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

    /// Walk the fork stack from the top, trying to advance each forkpoint.
    /// Normal forkpoints restore saved state and jump to backtrack_ip.
    /// Each/range forkpoints try to advance; if exhausted, pop and continue.
    /// Stops when it finds a forkpoint that can produce the next path.
    /// Returns true if a path was found, false if all forkpoints exhausted.
    fn backtrackToDepth(it: *ResultIterator, min_depth: u32) bool {
        while (it.fork_stack.items.len > min_depth) {
            const fp = &it.fork_stack.items[it.fork_stack.items.len - 1];
            switch (fp.aux) {
                .normal => {
                    it.value_stack.items.len = fp.saved_value_stack_len;
                    it.current = fp.saved_current;
                    it.ip = fp.backtrack_ip;
                    _ = it.fork_stack.pop();
                    return true;
                },
                .each => {
                    if (it.advanceEachForkpoint(fp)) {
                        it.value_stack.items.len = fp.saved_value_stack_len;
                        it.ip = fp.backtrack_ip + 1; // resume AFTER the each instruction
                        return true;
                    }
                    it.value_stack.items.len = fp.saved_value_stack_len;
                    it.current = fp.saved_current;
                    _ = it.fork_stack.pop();
                },
                .range => {
                    if (it.advanceRangeForkpoint(fp)) {
                        it.value_stack.items.len = fp.saved_value_stack_len;
                        it.ip = fp.backtrack_ip;
                        return true;
                    }
                    it.value_stack.items.len = fp.saved_value_stack_len;
                    it.current = fp.saved_current;
                    _ = it.fork_stack.pop();
                },
                .try_handler => {
                    // Normal exhaustion — just pop, continue backtracking.
                    _ = it.fork_stack.pop();
                },
                .alt_handler => |state| {
                    // Left side exhausted (all falsy or no outputs) — fire right side.
                    it.value_stack.items.len = fp.saved_value_stack_len;
                    it.current = fp.saved_current;
                    it.if_stack.items.len = state.saved_if_len;
                    while (it.collect_stack.items.len > state.saved_collect_len) {
                        var cf = it.collect_stack.pop().?;
                        cf.buffer.deinit(it.alloc);
                    }
                    it.call_stack.items.len = state.saved_call_len;
                    it.ip = fp.backtrack_ip; // right side IP
                    _ = it.fork_stack.pop();
                    return true;
                },
                .label, .limit => {
                    // Label/limit scope completed — just pop.
                    _ = it.fork_stack.pop();
                },
            }
        }
        return false;
    }

    /// Backtrack within the innermost scope (collect frame boundary or depth 0).
    fn doBacktrack(it: *ResultIterator) bool {
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
            .string => |str| str,
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
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
    }

    fn builtinAscii(it: *ResultIterator) ZqError!?StackValue {
        switch (it.current) {
            .string => |s| {
                if (s.len == 0) return error.TypeError;
                return .{ .int = @intCast(s[0]) };
            },
            .int => |i| {
                if (i < 0 or i > 127) return error.TypeError;
                var buf: [1]u8 = .{@intCast(@as(u8, @intCast(i)))};
                const str_ref = try it.runtime_tape.internString(it.alloc, &buf);
                it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
                return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
            },
            else => return error.TypeError,
        }
    }

    fn builtinExplode(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |str| str,
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
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape_view,
            .start = arr_start,
            .end = arr_end_idx + 1,
        } } };
    }

    fn builtinImplode(it: *ResultIterator) ZqError!?StackValue {
        const span = switch (it.current) {
            .array => |s| s,
            else => return error.TypeError,
        };
        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        var pos = span.start + 1;
        const end = span.end - 1;
        while (pos < end) {
            const val = tapeEntryToValue(span.tape, pos);
            const cp_i: i64 = switch (val) {
                .int => |i| i,
                .float => |f| @intFromFloat(f),
                else => return error.TypeError,
            };
            if (cp_i < 0 or cp_i > 0x10FFFF) return error.TypeError;
            const cp: u21 = @intCast(@as(u32, @intCast(cp_i)));
            var encode_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &encode_buf) catch return error.TypeError;
            try buf.appendSlice(it.alloc, encode_buf[0..len]);
            pos = skipEntry(span.tape.*, pos);
        }
        const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
    }

    // ── JSON builtins ──────────────────────────────────────────────────────

    fn builtinTojson(it: *ResultIterator) ZqError!?StackValue {
        return it.builtinFormatJson();
    }

    fn builtinFromjson(it: *ResultIterator) ZqError!?StackValue {
        const s = switch (it.current) {
            .string => |str| str,
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
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape_view,
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
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .object = .{
            .tape = &it.runtime_tape_view,
            .start = obj_start,
            .end = obj_end_idx + 1,
        } } };
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

    fn builtinIsempty(it: *ResultIterator) ZqError!?StackValue {
        // isempty(f) compiled as: save_input, [f], call_builtin
        // The collected array is on value_stack
        const arr_sv = try it.popValue();
        if (it.if_stack.items.len > 0) _ = it.if_stack.pop(); // pop saved input
        const is_empty = switch (arr_sv) {
            .tape_value => |tv| switch (tv) {
                .array => |span| arrayLength(span.tape, span) == 0,
                else => false,
            },
            else => false,
        };
        return .{ .bool_val = is_empty };
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
    fn builtinSplit(it: *ResultIterator) ZqError!?StackValue {
        const sep_sv = try it.popValue();
        const sep_val = try stackValueToValue(sep_sv);
        const sep = switch (sep_val) {
            .string => |s| s,
            else => return error.TypeError,
        };
        const input = switch (it.current) {
            .string => |s| s,
            else => return error.TypeError,
        };

        var parts = std.ArrayList(Value){};
        defer parts.deinit(it.alloc);

        if (sep.len == 0) {
            // Split into individual characters (Unicode codepoints)
            var i: usize = 0;
            while (i < input.len) {
                const seq_len = std.unicode.utf8ByteSequenceLength(input[i]) catch 1;
                const char_end = @min(i + seq_len, input.len);
                try parts.append(it.alloc, .{ .string = input[i..char_end] });
                i = char_end;
            }
        } else {
            var start: usize = 0;
            while (start <= input.len) {
                if (start + sep.len <= input.len and std.mem.eql(u8, input[start..][0..sep.len], sep)) {
                    try parts.append(it.alloc, .{ .string = input[start..start] });
                    start += sep.len;
                } else {
                    // Find next occurrence of separator
                    var end = start;
                    var found = false;
                    while (end < input.len) {
                        if (end + sep.len <= input.len and std.mem.eql(u8, input[end..][0..sep.len], sep)) {
                            try parts.append(it.alloc, .{ .string = input[start..end] });
                            start = end + sep.len;
                            found = true;
                            break;
                        }
                        end += 1;
                    }
                    if (!found) {
                        try parts.append(it.alloc, .{ .string = input[start..input.len] });
                        break;
                    }
                }
            }
        }

        return try it.buildRuntimeArray(parts.items);
    }

    /// `join(sep)`: join array elements with separator.
    /// In jq, join converts scalars to strings but raises an error for arrays/objects.
    fn builtinJoin(it: *ResultIterator) ZqError!?StackValue {
        const sep_sv = try it.popValue();
        const sep_val = try stackValueToValue(sep_sv);
        const sep = switch (sep_val) {
            .string => |s| s,
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
                try buf.appendSlice(it.alloc, sep);
            }
            first = false;

            const elem = tapeEntryToValue(span.tape, pos);
            switch (elem) {
                .string => |s| try buf.appendSlice(it.alloc, s),
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
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
    }

    /// Build a jq-compatible TypeError detail message for field access on wrong type.
    /// Uses runtime tape for the message string so it remains valid during iteration.
    /// The key parameter is included via runtime tape string interning.
    fn buildTypeErrorMsg(it: *ResultIterator, val: Value, key: []const u8) ?Value {
        const type_name = switch (val) {
            .null_val => "null",
            .bool_val => |b| if (b) "boolean (true)" else "boolean (false)",
            .int => "number",
            .float => "number",
            .string => "string",
            .array => "array",
            .object => "object",
        };
        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        buf.appendSlice(it.alloc, "Cannot index ") catch return null;
        buf.appendSlice(it.alloc, type_name) catch return null;
        buf.appendSlice(it.alloc, " with string (\"") catch return null;
        buf.appendSlice(it.alloc, key) catch return null;
        buf.appendSlice(it.alloc, "\")") catch return null;
        // Store in the runtime tape so the string lives as long as the iterator.
        // Note: callers must access this value before the iterator is deinitialized.
        const str_ref = it.runtime_tape.internString(it.alloc, buf.items) catch return null;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] };
    }

    /// Helper: raise a UserError with a message string.
    fn raiseUserError(it: *ResultIterator, msg: []const u8) ZqError!?StackValue {
        const str_ref = try it.runtime_tape.internString(it.alloc, msg);
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        it.user_error_msg = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] };
        return error.UserError;
    }

    /// `startswith(str)`: test if string starts with prefix.
    fn builtinStartswith(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const arg = try stackValueToValue(arg_sv);
        const prefix = switch (arg) {
            .string => |s| s,
            else => return try it.raiseUserError("startswith() requires string inputs"),
        };
        const input = switch (it.current) {
            .string => |s| s,
            else => return try it.raiseUserError("startswith() requires string inputs"),
        };
        return .{ .bool_val = std.mem.startsWith(u8, input, prefix) };
    }

    /// `endswith(str)`: test if string ends with suffix.
    fn builtinEndswith(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const arg = try stackValueToValue(arg_sv);
        const suffix = switch (arg) {
            .string => |s| s,
            else => return try it.raiseUserError("endswith() requires string inputs"),
        };
        const input = switch (it.current) {
            .string => |s| s,
            else => return try it.raiseUserError("endswith() requires string inputs"),
        };
        return .{ .bool_val = std.mem.endsWith(u8, input, suffix) };
    }

    /// `ltrimstr(str)`: remove prefix if present.
    fn builtinLtrimstr(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const arg = try stackValueToValue(arg_sv);
        const prefix = switch (arg) {
            .string => |s| s,
            else => return try it.raiseUserError("startswith() requires string inputs"),
        };
        const input = switch (it.current) {
            .string => |s| s,
            else => return try it.raiseUserError("startswith() requires string inputs"),
        };
        if (std.mem.startsWith(u8, input, prefix)) {
            return .{ .tape_value = .{ .string = input[prefix.len..] } };
        }
        return .{ .tape_value = .{ .string = input } };
    }

    /// `rtrimstr(str)`: remove suffix if present.
    fn builtinRtrimstr(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const arg = try stackValueToValue(arg_sv);
        const suffix = switch (arg) {
            .string => |s| s,
            else => return try it.raiseUserError("endswith() requires string inputs"),
        };
        const input = switch (it.current) {
            .string => |s| s,
            else => return try it.raiseUserError("endswith() requires string inputs"),
        };
        if (suffix.len > 0 and std.mem.endsWith(u8, input, suffix)) {
            return .{ .tape_value = .{ .string = input[0 .. input.len - suffix.len] } };
        }
        return .{ .tape_value = .{ .string = input } };
    }

    /// `test(regex)`: simplified — test if string contains substring.
    fn builtinTest(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const arg = try stackValueToValue(arg_sv);
        const pattern = switch (arg) {
            .string => |s| s,
            else => return error.TypeError,
        };
        const input = switch (it.current) {
            .string => |s| s,
            else => return error.TypeError,
        };
        return .{ .bool_val = std.mem.indexOf(u8, input, pattern) != null };
    }

    /// `match(regex)`: simplified — return match object for first substring occurrence.
    fn builtinMatch(it: *ResultIterator) ZqError!?StackValue {
        const arg_sv = try it.popValue();
        const arg = try stackValueToValue(arg_sv);
        const pattern = switch (arg) {
            .string => |s| s,
            else => return error.TypeError,
        };
        const input = switch (it.current) {
            .string => |s| s,
            else => return error.TypeError,
        };

        if (std.mem.indexOf(u8, input, pattern)) |pos| {
            // Build match object: {"offset": N, "length": N, "string": "...", "captures": []}
            const obj_start = try it.runtime_tape.appendEntry(it.alloc, .{
                .tag = .object_start,
                .payload = .{ .skip = 0 },
            });

            // offset
            const k_offset = try it.runtime_tape.internString(it.alloc, "offset");
            _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .key, .payload = .{ .string = k_offset } });
            _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .int, .payload = .{ .int = @intCast(pos) } });

            // length
            const k_length = try it.runtime_tape.internString(it.alloc, "length");
            _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .key, .payload = .{ .string = k_length } });
            _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .int, .payload = .{ .int = @intCast(pattern.len) } });

            // string
            const k_string = try it.runtime_tape.internString(it.alloc, "string");
            _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .key, .payload = .{ .string = k_string } });
            const match_str = try it.runtime_tape.internString(it.alloc, pattern);
            _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .string, .payload = .{ .string = match_str } });

            // captures (empty array)
            const k_captures = try it.runtime_tape.internString(it.alloc, "captures");
            _ = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .key, .payload = .{ .string = k_captures } });
            const cap_start = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .array_start, .payload = .{ .skip = 0 } });
            const cap_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .array_end, .payload = .{ .none = {} } });
            it.runtime_tape.entries.items[cap_start].payload.skip = cap_end_idx + 1;

            const obj_end_idx = try it.runtime_tape.appendEntry(it.alloc, .{ .tag = .object_end, .payload = .{ .none = {} } });
            it.runtime_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;
            it.runtime_tape_view.entries = it.runtime_tape.entries.items;
            it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
            return .{ .tape_value = .{ .object = .{
                .tape = &it.runtime_tape_view,
                .start = obj_start,
                .end = obj_end_idx + 1,
            } } };
        }

        // No match — raise error (jq behavior for test/match without match)
        return error.TypeError;
    }

    /// `sub(pattern; replacement)`: replace first occurrence.
    fn builtinSub(it: *ResultIterator) ZqError!?StackValue {
        const replacement_sv = try it.popValue();
        const pattern_sv = try it.popValue();
        const replacement = switch (try stackValueToValue(replacement_sv)) {
            .string => |s| s,
            else => return error.TypeError,
        };
        const pattern = switch (try stackValueToValue(pattern_sv)) {
            .string => |s| s,
            else => return error.TypeError,
        };
        const input = switch (it.current) {
            .string => |s| s,
            else => return error.TypeError,
        };

        if (std.mem.indexOf(u8, input, pattern)) |pos| {
            var buf = std.ArrayList(u8){};
            defer buf.deinit(it.alloc);
            try buf.appendSlice(it.alloc, input[0..pos]);
            try buf.appendSlice(it.alloc, replacement);
            try buf.appendSlice(it.alloc, input[pos + pattern.len ..]);
            const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
            it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
            return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
        }
        return .{ .tape_value = .{ .string = input } };
    }

    /// `gsub(pattern; replacement)`: replace all occurrences.
    fn builtinGsub(it: *ResultIterator) ZqError!?StackValue {
        const replacement_sv = try it.popValue();
        const pattern_sv = try it.popValue();
        const replacement = switch (try stackValueToValue(replacement_sv)) {
            .string => |s| s,
            else => return error.TypeError,
        };
        const pattern = switch (try stackValueToValue(pattern_sv)) {
            .string => |s| s,
            else => return error.TypeError,
        };
        const input = switch (it.current) {
            .string => |s| s,
            else => return error.TypeError,
        };

        if (pattern.len == 0) {
            // Empty pattern: return input unchanged (avoid infinite loop)
            return .{ .tape_value = .{ .string = input } };
        }

        var buf = std.ArrayList(u8){};
        defer buf.deinit(it.alloc);
        var i: usize = 0;
        while (i < input.len) {
            if (i + pattern.len <= input.len and std.mem.eql(u8, input[i..][0..pattern.len], pattern)) {
                try buf.appendSlice(it.alloc, replacement);
                i += pattern.len;
            } else {
                try buf.append(it.alloc, input[i]);
                i += 1;
            }
        }

        const str_ref = try it.runtime_tape.internString(it.alloc, buf.items);
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .string = it.runtime_tape_view.string_buf[str_ref.offset..][0..str_ref.len] } };
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
        it.runtime_tape_view.entries = it.runtime_tape.entries.items;
        it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
        return .{ .tape_value = .{ .array = .{
            .tape = &it.runtime_tape_view,
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
                    .string => |s| {
                        try msg_buf.appendSlice(it.alloc, "string (");
                        try appendJsonString(&msg_buf, it.alloc, s);
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
};

/// Simple JSON parser for fromjson builtin.
/// Parses a JSON string and builds entries in the ResultIterator's runtime tape.
/// Uses a tape-first approach: all parsed values are written directly to the runtime
/// tape. The top-level result is then read back as a StackValue.
fn parseJsonToStackValue(it: *ResultIterator, json_str: []const u8) ZqError!StackValue {
    var parser = JsonParser{ .src = json_str, .pos = 0, .it = it };
    const start_idx: u32 = @intCast(it.runtime_tape.entries.items.len);
    parser.writeValue() catch return error.TypeError;
    it.runtime_tape_view.entries = it.runtime_tape.entries.items;
    it.runtime_tape_view.string_buf = it.runtime_tape.string_buf.items;
    return valueToStackValue(tapeEntryToValue(&it.runtime_tape_view, start_idx));
}

const JsonParser = struct {
    src: []const u8,
    pos: usize,
    it: *ResultIterator,

    fn skipWhitespace(self: *JsonParser) void {
        while (self.pos < self.src.len and
            (self.src[self.pos] == ' ' or self.src[self.pos] == '\t' or
                self.src[self.pos] == '\n' or self.src[self.pos] == '\r'))
        {
            self.pos += 1;
        }
    }

    /// Write a JSON value directly to the runtime tape.
    fn writeValue(self: *JsonParser) ZqError!void {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return error.TypeError;

        switch (self.src[self.pos]) {
            '"' => try self.writeString(),
            '{' => try self.writeObject(),
            '[' => try self.writeArray(),
            't' => try self.writeLiteral("true", .true_val),
            'f' => try self.writeLiteral("false", .false_val),
            'n' => try self.writeLiteral("null", .null_val),
            '-', '0'...'9' => try self.writeNumber(),
            else => return error.TypeError,
        }
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
        if (self.pos < self.src.len and self.src[self.pos] == '-') self.pos += 1;
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

    fn writeArray(self: *JsonParser) ZqError!void {
        self.pos += 1; // skip '['
        self.skipWhitespace();

        const arr_start = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
            .tag = .array_start,
            .payload = .{ .skip = 0 },
        });

        if (self.pos < self.src.len and self.src[self.pos] == ']') {
            self.pos += 1;
        } else {
            while (true) {
                try self.writeValue();
                self.skipWhitespace();
                if (self.pos >= self.src.len) return error.TypeError;
                if (self.src[self.pos] == ']') {
                    self.pos += 1;
                    break;
                }
                if (self.src[self.pos] != ',') return error.TypeError;
                self.pos += 1;
            }
        }

        const arr_end_idx = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
            .tag = .array_end,
            .payload = .{ .none = {} },
        });
        self.it.runtime_tape.entries.items[arr_start].payload.skip = arr_end_idx + 1;
    }

    fn writeObject(self: *JsonParser) ZqError!void {
        self.pos += 1; // skip '{'
        self.skipWhitespace();

        const obj_start = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
            .tag = .object_start,
            .payload = .{ .skip = 0 },
        });

        if (self.pos < self.src.len and self.src[self.pos] == '}') {
            self.pos += 1;
        } else {
            while (true) {
                self.skipWhitespace();
                // Parse key (must be a string)
                if (self.pos >= self.src.len or self.src[self.pos] != '"') return error.TypeError;
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

                // Parse value directly into tape
                try self.writeValue();

                self.skipWhitespace();
                if (self.pos >= self.src.len) return error.TypeError;
                if (self.src[self.pos] == '}') {
                    self.pos += 1;
                    break;
                }
                if (self.src[self.pos] != ',') return error.TypeError;
                self.pos += 1;
            }
        }

        const obj_end_idx = try self.it.runtime_tape.appendEntry(self.it.alloc, .{
            .tag = .object_end,
            .payload = .{ .none = {} },
        });
        self.it.runtime_tape.entries.items[obj_start].payload.skip = obj_end_idx + 1;
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
/// Convert a hex digit character to its numeric value (0-15), or null if invalid.
fn hexDigitVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

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
            const formatted = types.formatJqFloat(f);
            try buf.appendSlice(alloc, formatted.slice());
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
        .string => |s| {
            const str_ref = try tape.internString(alloc, s);
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
    }
}
