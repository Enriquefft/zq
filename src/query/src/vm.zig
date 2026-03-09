const std = @import("std");
const ZqError = @import("error").ZqError;
const types = @import("types");
const Tape = types.Tape;
const Value = types.Value;
const Instruction = types.Instruction;

const max_stack_depth: u32 = 512;

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

/// Lazy execution state. Not thread-safe. Must not be moved after creation:
/// Value.TapeSpan.tape pointers reference &self.tape.
pub const ResultIterator = struct {
    tape: Tape,
    instructions: []const Instruction,
    opts_allow_null: bool,
    ip: u32,
    current: Value,
    stack: std.ArrayList(IterFrame),
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

        return ResultIterator{
            .tape = tape,
            .instructions = instructions,
            .opts_allow_null = opts_allow_null,
            .ip = 0,
            .current = undefined,
            .stack = stack,
            .alloc = allocator,
            .done = false,
            .initialized = false,
        };
    }

    /// Free the internal eval stack. Idempotent.
    pub fn deinit(it: *ResultIterator) void {
        it.stack.deinit(it.alloc);
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
                    const val = it.current;
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
