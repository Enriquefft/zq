const std = @import("std");
const ZqError = @import("error").ZqError;
const types = @import("types");
const Tape = types.Tape;
const Value = types.Value;
const Instruction = types.Instruction;

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
};

/// State for one active `[expr]` array collection.
/// Pushed by array_collect_start, popped by array_collect_end or ip-exhaustion.
const CollectFrame = struct {
    /// Accumulated outputs from the inner expression.
    buffer: std.ArrayList(StackValue),
    /// IterFrame stack depth when collection started.
    /// Used to distinguish inner vs outer iteration frames.
    outer_stack_depth: u32,
    /// IP of the matching array_collect_end instruction.
    end_ip: u32,
};

/// A value on the evaluation stack.
const StackValue = union(enum) {
    null_val,
    bool_val: bool,
    int: i64,
    float: f64,
    /// A view into the Tape for objects/arrays/strings.
    tape_value: Value,
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
    alloc: std.mem.Allocator,
    done: bool,
    /// Defers initial tapeEntryToValue(&self.tape, 0) until after any struct move.
    initialized: bool,

    pub fn init(
        instructions: []const Instruction,
        function_table: []const types.FunctionDef,
        string_buf: []const u8,
        opts_allow_null: bool,
        tape: Tape,
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
            .alloc = allocator,
            .done = false,
            .initialized = false,
        };
    }

    /// Free the internal eval stack. Idempotent.
    pub fn deinit(it: *ResultIterator) void {
        it.stack.deinit(it.alloc);
        it.value_stack.deinit(it.alloc);
        it.variable_store.deinit(it.alloc);
        it.object_construct.deinit(it.alloc);
        it.if_stack.deinit(it.alloc);
        for (it.collect_stack.items) |*frame| frame.buffer.deinit(it.alloc);
        it.collect_stack.deinit(it.alloc);
        it.runtime_tape.deinit(it.alloc);
    }

    /// Rebind this iterator to a new tape from the same query.
    /// All internal buffers retain their capacity — zero allocations.
    /// The iterator returns to the initial state, ready for a new next() loop.
    ///
    /// Must be called only when the previous run is complete: either next()
    /// returned null or an error, or the caller has decided to abandon it.
    /// Must NOT be called after deinit().
    pub fn reset(it: *ResultIterator, tape: Tape) void {
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
        it.object_construct.clearRetainingCapacity();
        it.if_stack.clearRetainingCapacity();
        for (it.collect_stack.items) |*frame| frame.buffer.deinit(it.alloc);
        it.collect_stack.clearRetainingCapacity();
        it.runtime_tape.entries.clearRetainingCapacity();
        it.runtime_tape.string_buf.clearRetainingCapacity();
        it.runtime_tape_view = types.Tape{
            .entries = it.runtime_tape.entries.items,
            .string_buf = it.runtime_tape.string_buf.items,
        };
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

    fn step(it: *ResultIterator) ZqError!?Value {
        while (true) {
            if (it.ip >= it.instructions.len) {
                if (it.stack.items.len == 0) {
                    // If an array collect frame is waiting to finalize, do it now.
                    // This path is taken when all inner iteration frames are exhausted
                    // after the last collect_output fired.
                    if (it.collect_stack.items.len > 0) {
                        var completed = it.collect_stack.pop().?;
                        defer completed.buffer.deinit(it.alloc);
                        const arr_val = try it.buildCollectedArray(&completed);
                        it.pushValue(arr_val);
                        it.ip = completed.end_ip + 1; // skip past array_collect_end
                        continue;
                    }
                    it.done = true;
                    return null;
                }
                // Current instruction sequence is exhausted; advance the topmost
                // iterate frame to its next element. If the frame is also exhausted,
                // loop again — the outer frame (if any) will be handled on the next
                // iteration without recursion.
                if (!it.advanceFrame()) continue;
                continue;
            }

            const instr = it.instructions[it.ip];
            switch (instr.op) {
                .identity, .pipe => it.ip += 1,

                .output => {
                    const val = if (it.value_stack.items.len > 0)
                        try stackValueToValue(try it.popValue())
                    else
                        it.current;

                    if (it.collect_stack.items.len > 0) {
                        // Collect mode: buffer value instead of yielding.
                        const cf = &it.collect_stack.items[it.collect_stack.items.len - 1];
                        try cf.buffer.append(it.alloc, try valueToStackValue(val));
                        if (it.stack.items.len > cf.outer_stack_depth) {
                            // More inner iterations pending: trigger advanceFrame.
                            it.ip = @intCast(it.instructions.len);
                        } else {
                            // No more inner iterations: jump to array_collect_end.
                            it.ip = cf.end_ip;
                        }
                    } else {
                        it.ip += 1;
                        return val;
                    }
                },

                .load_key => {
                    const result = try lookupKeyInValue(
                        &it.tape,
                        it.opts_allow_null,
                        it.current,
                        instr.operand.string,
                    );
                    it.current = result;
                    // Push result to value stack so arithmetic operations can use it
                    const result_sv = try valueToStackValue(result);
                    it.pushValue(result_sv);
                    it.ip += 1;
                },

                .load_index => {
                    it.current = try it.doLoadIndex(instr.operand.index);
                    it.ip += 1;
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
                                    if (it.opts_allow_null) @as(Value, .null_val) else return error.TypeError,
                                .null_val => if (it.opts_allow_null) @as(Value, .null_val) else return error.TypeError,
                                else => return error.TypeError,
                            },
                            else => return error.TypeError,
                        },
                        .int => |i| blk: {
                            if (i < 0 or i > std.math.maxInt(u32)) return error.IndexOutOfBounds;
                            const idx: u32 = @intCast(i);
                            break :blk switch (base) {
                                .array => |span| lookupIndex(span.tape, span, idx) orelse
                                    return error.IndexOutOfBounds,
                                .null_val => if (it.opts_allow_null) @as(Value, .null_val) else return error.TypeError,
                                else => return error.TypeError,
                            };
                        },
                        else => return error.TypeError,
                    };
                    it.ip += 1;
                },

                .load_path => {
                    it.current = try it.doLoadPath(instr.operand.string);
                    it.ip += 1;
                },

                .iterate => try it.doIterate(it.ip + 1),

                .push_bool => {
                    it.pushValue(.{ .bool_val = instr.operand.bool });
                    it.ip += 1;
                },

                .push_int => {
                    it.pushValue(.{ .int = instr.operand.int });
                    it.ip += 1;
                },

                .push_float => {
                    it.pushValue(.{ .float = instr.operand.float });
                    it.ip += 1;
                },

                .push_null => {
                    it.pushValue(.null_val);
                    it.ip += 1;
                },

                .push_string => {
                    const str_ref = instr.operand.str_ref;
                    // Get string from compiled string buffer
                    const str = it.string_buf[str_ref.offset..][0..str_ref.len];
                    it.pushValue(.{ .tape_value = .{ .string = str } });
                    it.ip += 1;
                },

                .push_current => {
                    it.pushValue(try valueToStackValue(it.current));
                    it.ip += 1;
                },

                // Conditional branching
                .save_input => {
                    it.if_stack.appendAssumeCapacity(it.current);
                    it.ip += 1;
                },

                .restore_input => {
                    if (it.if_stack.items.len == 0) return error.TypeError;
                    it.current = it.if_stack.pop().?;
                    it.ip += 1;
                },

                // Array construction
                .array_collect_start => {
                    var buf = std.ArrayList(StackValue){};
                    errdefer buf.deinit(it.alloc);
                    try buf.ensureTotalCapacity(it.alloc, 32);
                    try it.collect_stack.append(it.alloc, CollectFrame{
                        .buffer = buf,
                        .outer_stack_depth = @intCast(it.stack.items.len),
                        .end_ip = instr.operand.index,
                    });
                    it.ip += 1;
                },

                .array_collect_end => {
                    // Reached when: (a) inner expr is empty [], or (b) output handler
                    // jumped here after the last (non-iterating) element.
                    var completed = it.collect_stack.pop().?;
                    defer completed.buffer.deinit(it.alloc);
                    const arr_val = try it.buildCollectedArray(&completed);
                    it.pushValue(arr_val);
                    it.ip += 1;
                },

                .jump => {
                    it.ip = instr.operand.index;
                },

                .jump_if_false => {
                    const cond = if (it.value_stack.items.len > 0)
                        try it.popValue()
                    else
                        try valueToStackValue(it.current);
                    if (!isCondTruthy(cond)) {
                        it.ip = instr.operand.index;
                    } else {
                        it.ip += 1;
                    }
                },

                // Object construction operations
                .object_construct_start => {
                    it.object_construct.clearRetainingCapacity();
                    // Snapshot input so each field's value expression starts from it.
                    it.current = it.input_value;
                    it.ip += 1;
                },

                .object_key => {
                    // Get value from stack if available, otherwise use current
                    // We check for 2 items on stack (key + value) vs 1 item (just key)
                    const value = if (it.value_stack.items.len > 1)
                        try it.popValue()
                    else
                        try valueToStackValue(it.current);

                    const key_val = try it.popValue();

                    // Extract key string - only support string keys for now
                    const key = switch (key_val) {
                        .tape_value => |tv| switch (tv) {
                            .string => |s| s,
                            else => return error.TypeError,
                        },
                        else => return error.TypeError, // Only strings can be object keys
                    };

                    // Use appendAssumeCapacity since we pre-allocated
                    it.object_construct.appendAssumeCapacity(ObjectField{
                        .key = key,
                        .value = value,
                    });

                    // Restore current to the filter input so the next field's
                    // value expression is evaluated against the same context.
                    it.current = it.input_value;
                    it.ip += 1;
                },

                .object_construct_end => {
                    // Construct object and push to stack
                    const obj = try it.constructObjectFromFields();
                    it.pushValue(obj);
                    it.ip += 1;
                },

                .add => {
                    const result = try it.doAdd();
                    it.pushValue(result);
                    it.ip += 1;
                },

                .sub => {
                    const result = try it.doSub();
                    it.pushValue(result);
                    it.ip += 1;
                },

                .mul => {
                    const result = try it.doMul();
                    it.pushValue(result);
                    it.ip += 1;
                },

                .div => {
                    const result = try it.doDiv();
                    it.pushValue(result);
                    it.ip += 1;
                },

                .mod => {
                    const result = try it.doMod();
                    it.pushValue(result);
                    it.ip += 1;
                },

                .eq => {
                    const result = try it.doEq();
                    it.pushValue(.{ .bool_val = result });
                    it.ip += 1;
                },

                .ne => {
                    const result = try it.doNe();
                    it.pushValue(.{ .bool_val = result });
                    it.ip += 1;
                },

                .lt => {
                    const result = try it.doLt();
                    it.pushValue(.{ .bool_val = result });
                    it.ip += 1;
                },

                .le => {
                    const result = try it.doLe();
                    it.pushValue(.{ .bool_val = result });
                    it.ip += 1;
                },

                .gt => {
                    const result = try it.doGt();
                    it.pushValue(.{ .bool_val = result });
                    it.ip += 1;
                },

                .ge => {
                    const result = try it.doGe();
                    it.pushValue(.{ .bool_val = result });
                    it.ip += 1;
                },

                .and_op => {
                    try it.doAndOp();
                    it.ip += 1;
                },

                .or_op => {
                    try it.doOrOp();
                    it.ip += 1;
                },

                .not => {
                    const val = try it.popValue();
                    const is_true = try isTruthy(val);
                    it.pushValue(.{ .bool_val = !is_true });
                    it.ip += 1;
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
                },

                .capture_variable => {
                    const var_id = instr.operand.index;
                    // If value stack is empty, capture current value
                    const val = if (it.value_stack.items.len > 0)
                        try it.popValue()
                    else
                        try valueToStackValue(it.current);
                    it.setVariable(var_id, val);
                    it.ip += 1;
                },

                .load_variable => {
                    const var_id = instr.operand.index;
                    const val = try it.getVariable(var_id);
                    it.pushValue(val);
                    it.ip += 1;
                },

                .pop_variable => {
                    const var_id = instr.operand.index;
                    it.clearVariable(var_id);
                    it.ip += 1;
                },

                .def_function => {
                    // Function definitions are resolved at compile time
                    // No runtime action needed
                    it.ip += 1;
                },

                .call_function => {
                    _ = instr.operand.index;
                    // For now, functions are expanded at compile time
                    // TODO: Add function call support
                    it.ip += 1;
                },
            }
        }
    }

    /// Convert a completed CollectFrame buffer into an array Value backed by runtime_tape.
    fn buildCollectedArray(it: *ResultIterator, frame: *const CollectFrame) ZqError!StackValue {
        it.runtime_tape.entries.clearRetainingCapacity();
        it.runtime_tape.string_buf.clearRetainingCapacity();

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

    fn doLoadIndex(it: *ResultIterator, idx: u32) ZqError!Value {
        return switch (it.current) {
            .array => |span| lookupIndex(&it.tape, span, idx) orelse error.IndexOutOfBounds,
            .null_val => if (it.opts_allow_null) .null_val else error.TypeError,
            else => error.TypeError,
        };
    }

    fn doLoadPath(it: *ResultIterator, path: []const u8) ZqError!Value {
        var current = it.current;
        var segs = std.mem.splitScalar(u8, path, '.');
        while (segs.next()) |seg| {
            current = try lookupKeyInValue(&it.tape, it.opts_allow_null, current, seg);
        }
        return current;
    }

    // ── Arithmetic operations ─────────────────────────────────────────────────────

    fn doAdd(it: *ResultIterator) ZqError!StackValue {
        const right = try it.popValue();
        const left = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);

        // Arithmetic always produces a result that could be float
        // Convert both operands to float for calculation
        const left_f = try toFloat(left);
        const right_f = try toFloat(right);
        return .{ .float = left_f + right_f };
    }

    fn doSub(it: *ResultIterator) ZqError!StackValue {
        const right = try it.popValue();
        const left = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);

        // Arithmetic always produces a result that could be float
        const left_f = try toFloat(left);
        const right_f = try toFloat(right);
        return .{ .float = left_f - right_f };
    }

    // ── Object construction operations ─────────────────────────────────────────────────

    const ObjectField = struct {
        key: []const u8,
        value: StackValue,
    };

    fn constructObjectFromFields(it: *ResultIterator) ZqError!StackValue {
        // Clear runtime tape for new object construction
        it.runtime_tape.entries.clearRetainingCapacity();
        it.runtime_tape.string_buf.clearRetainingCapacity();

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
    fn copyTapeSpanToRuntimeTape(it: *ResultIterator, span: types.Value.TapeSpan) ZqError!void {
        var pos = span.start;

        // Copy all entries in the span
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

                    // Skip to after the container in the source tape
                    pos = container_end_idx + 1;
                },
                .key => {
                    // Skip key entries when copying values (not constructing objects)
                    pos = skipEntry(span.tape.*, pos);
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

        // Arithmetic always produces a result that could be float
        const left_f = try toFloat(left);
        const right_f = try toFloat(right);
        return .{ .float = left_f * right_f };
    }

    fn doDiv(it: *ResultIterator) ZqError!StackValue {
        const right = try it.popValue();
        const left = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);

        // Arithmetic always produces a result that could be float
        const left_f = try toFloat(left);
        const right_f = try toFloat(right);
        return .{ .float = left_f / right_f };
    }

    fn doMod(it: *ResultIterator) ZqError!StackValue {
        const right = try it.popValue();
        const left = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);
        const left_int = try toInt(left);
        const right_int = try toInt(right);
        return .{ .int = @rem(left_int, right_int) };
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
        const right = try it.popValue();
        const left = if (it.value_stack.items.len > 0)
            try it.popValue()
        else
            try valueToStackValue(it.current);

        return switch (left) {
            .bool_val => |lb| switch (right) {
                .bool_val => |rb| op(@as(f64, if (lb) 1 else 0), @as(f64, if (rb) 1 else 0)),
                .int => |ri| op(@as(f64, if (lb) 1 else 0), @floatFromInt(ri)),
                .float => |rf| op(@as(f64, if (lb) 1 else 0), rf),
                else => error.TypeError,
            },
            .int => |li| switch (right) {
                .bool_val => |rb| op(@floatFromInt(li), @as(f64, if (rb) 1 else 0)),
                .int => |ri| op(@floatFromInt(li), @floatFromInt(ri)),
                .float => |rf| op(@floatFromInt(li), rf),
                else => error.TypeError,
            },
            .float => |lf| switch (right) {
                .bool_val => |rb| op(lf, @as(f64, if (rb) 1 else 0)),
                .int => |ri| op(lf, @floatFromInt(ri)),
                .float => |rf| op(lf, rf),
                else => error.TypeError,
            },
            else => error.TypeError,
        };
    }

    // ── Boolean operations ───────────────────────────────────────────────────────

    /// Short-circuit AND: if left is falsy, push it and skip to after right expression.
    fn doAndOp(it: *ResultIterator) ZqError!void {
        const right = try it.popValue();
        const left = try it.peekValue();

        const left_truthy = try isTruthy(left);
        if (!left_truthy) {
            // Left is falsy: AND result is falsy, skip right
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

        const left_truthy = try isTruthy(left);
        if (left_truthy) {
            // Left is truthy: OR result is truthy, skip right
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
                });
                it.current = tapeEntryToValue(&it.tape, first);
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
                });
                // Value is one entry past its key.
                it.current = tapeEntryToValue(&it.tape, first_key + 1);
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
            skipEntry(it.tape, frame.pos + 1) // step past value → next key
        else
            skipEntry(it.tape, frame.pos); // step past current value

        if (next_pos >= frame.end) {
            _ = it.stack.pop();
            return false;
        }

        frame.pos = next_pos;
        it.current = if (frame.is_object)
            tapeEntryToValue(&it.tape, next_pos + 1) // value after key
        else
            tapeEntryToValue(&it.tape, next_pos);
        it.ip = frame.resume_ip;
        return true;
    }
};

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
    tape: *const Tape,
    allow_null: bool,
    val: Value,
    key: []const u8,
) ZqError!Value {
    return switch (val) {
        .object => |span| lookupKey(tape, span, key) orelse
            (if (allow_null) .null_val else error.TypeError),
        .null_val => if (allow_null) .null_val else error.TypeError,
        else => error.TypeError,
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
