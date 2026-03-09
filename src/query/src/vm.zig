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
    opts_allow_null: bool,
    ip: u32,
    current: Value,
    /// Frame stack for iteration (.iterate opcode).
    stack: std.ArrayList(IterFrame),
    /// Value stack for expression evaluation.
    value_stack: std.ArrayList(StackValue),
    /// Variable storage for variable capture and reference.
    variable_store: std.ArrayList(?StackValue),
    alloc: std.mem.Allocator,
    done: bool,
    /// Defers initial tapeEntryToValue(&self.tape, 0) until after any struct move.
    initialized: bool,

    pub fn init(
        instructions: []const Instruction,
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

        return ResultIterator{
            .tape = tape,
            .instructions = instructions,
            .opts_allow_null = opts_allow_null,
            .ip = 0,
            .current = undefined,
            .stack = stack,
            .value_stack = value_stack,
            .variable_store = variable_store,
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
        }

        return it.step();
    }

    // ── VM loop ───────────────────────────────────────────────────────────────

    fn step(it: *ResultIterator) ZqError!?Value {
        while (true) {
            if (it.ip >= it.instructions.len) {
                if (it.stack.items.len == 0) {
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
                    it.ip += 1;
                    return val;
                },

                .load_key => {
                    it.current = try lookupKeyInValue(
                        &it.tape, it.opts_allow_null, it.current, instr.operand.string,
                    );
                    it.ip += 1;
                },

                .load_index => {
                    it.current = try it.doLoadIndex(instr.operand.index);
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

    fn doLoadIndex(it: *ResultIterator, idx: u32) ZqError!Value {
        return switch (it.current) {
            .array  => |span| lookupIndex(&it.tape, span, idx) orelse error.IndexOutOfBounds,
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
        return it.doCompareOp(struct { fn op(a: f64, b: f64) bool { return a == b; } }.op);
    }

    fn doNe(it: *ResultIterator) ZqError!bool {
        return it.doCompareOp(struct { fn op(a: f64, b: f64) bool { return a != b; } }.op);
    }

    fn doLt(it: *ResultIterator) ZqError!bool {
        return it.doCompareOp(struct { fn op(a: f64, b: f64) bool { return a < b; } }.op);
    }

    fn doLe(it: *ResultIterator) ZqError!bool {
        return it.doCompareOp(struct { fn op(a: f64, b: f64) bool { return a <= b; } }.op);
    }

    fn doGt(it: *ResultIterator) ZqError!bool {
        return it.doCompareOp(struct { fn op(a: f64, b: f64) bool { return a > b; } }.op);
    }

    fn doGe(it: *ResultIterator) ZqError!bool {
        return it.doCompareOp(struct { fn op(a: f64, b: f64) bool { return a >= b; } }.op);
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
                const end   = span.end - 1; // position of array_end
                if (first >= end) {
                    // Empty array — skip past all instructions; produce no output.
                    it.ip = @intCast(it.instructions.len);
                    return;
                }
                it.stack.appendAssumeCapacity(IterFrame{
                    .pos       = first,
                    .end       = end,
                    .is_object = false,
                    .resume_ip = resume_ip,
                });
                it.current = tapeEntryToValue(&it.tape, first);
                it.ip = resume_ip;
            },
            .object => |span| {
                const first_key = span.start + 1;
                const end       = span.end - 1; // position of object_end
                if (first_key >= end) {
                    it.ip = @intCast(it.instructions.len);
                    return;
                }
                it.stack.appendAssumeCapacity(IterFrame{
                    .pos       = first_key,
                    .end       = end,
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
            skipEntry(it.tape, frame.pos);    // step past current value

        if (next_pos >= frame.end) {
            _ = it.stack.pop();
            return false;
        }

        frame.pos  = next_pos;
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
        .null_val     => .null_val,
        .true_val     => .{ .bool_val = true },
        .false_val    => .{ .bool_val = false },
        .int          => .{ .int    = e.payload.int },
        .float        => .{ .float  = e.payload.float },
        .string       => .{ .string = tape.getString(e.payload.string) },
        .object_start => .{ .object = .{ .tape = tape, .start = pos, .end = e.payload.skip } },
        .array_start  => .{ .array  = .{ .tape = tape, .start = pos, .end = e.payload.skip } },
        // These tags are never returned as values.
        .key, .object_end, .array_end => unreachable,
    };
}

/// Return the tape index of the first entry after the entry at `pos`.
/// Containers jump using their skip pointer; scalars advance by 1.
fn skipEntry(tape: Tape, pos: u32) u32 {
    return switch (tape.entries[pos].tag) {
        .object_start => tape.entries[pos].payload.skip,
        .array_start  => tape.entries[pos].payload.skip,
        else          => pos + 1,
    };
}

fn lookupKeyInValue(
    tape: *const Tape,
    allow_null: bool,
    val: Value,
    key: []const u8,
) ZqError!Value {
    return switch (val) {
        .object   => |span| lookupKey(tape, span, key) orelse
            (if (allow_null) .null_val else error.TypeError),
        .null_val => if (allow_null) .null_val else error.TypeError,
        else      => error.TypeError,
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
