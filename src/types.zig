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

    pub const Entry = struct {
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

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!RuntimeTape {
        var rt_tape: RuntimeTape = .{
            .entries = std.ArrayList(Tape.Entry){},
            .string_buf = std.ArrayList(u8){},
        };
        // Pre-allocate capacity for typical object construction
        try rt_tape.entries.ensureTotalCapacity(allocator, 256);
        try rt_tape.string_buf.ensureTotalCapacity(allocator, 4096);
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
        return Tape.StringRef{
            .offset = offset,
            .len = @as(u32, @intCast(s.len)),
        };
    }

    /// Append an entry and return its index.
    pub fn appendEntry(self: *RuntimeTape, allocator: std.mem.Allocator, entry: Tape.Entry) error{OutOfMemory}!u32 {
        const idx = @as(u32, @intCast(self.entries.items.len));
        try self.entries.append(allocator, entry);
        return idx;
    }

    /// Get immutable view of this runtime tape as a regular Tape.
    pub fn asTape(self: *const RuntimeTape) Tape {
        return .{
            .entries = self.entries.items,
            .string_buf = self.string_buf.items,
        };
    }

    /// Copy all entries from a parsed tape into this runtime tape,
    /// re-interning strings and rebasing skip pointers.
    pub fn copyFrom(self: *RuntimeTape, tape: Tape, allocator: std.mem.Allocator) !void {
        try self.copySpan(tape, 0, @intCast(tape.entries.len), allocator);
    }

    /// Copy a range of entries [start, end) from a tape into this runtime tape,
    /// re-interning strings and rebasing skip pointers.
    pub fn copySpan(self: *RuntimeTape, tape: Tape, start: u32, end: u32, allocator: std.mem.Allocator) !void {
        var pos = start;
        while (pos < end) {
            const entry = tape.entries[pos];
            switch (entry.tag) {
                .object_start, .array_start => {
                    const container_start = try self.appendEntry(allocator, entry);
                    const orig_skip = entry.payload.skip;
                    if (orig_skip > pos + 2) {
                        try self.copySpan(tape, pos + 1, orig_skip - 1, allocator);
                    }
                    const new_end = try self.appendEntry(allocator, .{
                        .tag = if (entry.tag == .object_start) .object_end else .array_end,
                        .payload = .{ .none = {} },
                    });
                    self.entries.items[container_start].payload.skip = new_end + 1;
                    pos = orig_skip;
                },
                .key, .string => {
                    const str = tape.getString(entry.payload.string);
                    const new_ref = try self.internString(allocator, str);
                    _ = try self.appendEntry(allocator, .{
                        .tag = entry.tag,
                        .payload = .{ .string = new_ref },
                    });
                    pos += 1;
                },
                .object_end, .array_end => {
                    pos += 1;
                },
                else => {
                    _ = try self.appendEntry(allocator, entry);
                    pos += 1;
                },
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
};

// ─── Slice Args ──────────────────────────────────────────────────────────────
/// Operands for the `slice` instruction (.[from:to]).
/// Uses i32 to keep @sizeOf(SliceArgs) = 12, within the 16-byte Operand union slot.
/// Absent bound: has_from/has_to = false; the corresponding from/to field is 0 (ignored).
pub const SliceArgs = extern struct {
    from: i32 = 0,
    to: i32 = 0,
    has_from: bool = false,
    has_to: bool = false,
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

pub const Instruction = struct {
    op: Op,
    operand: Operand,

    pub const Op = enum(u8) {
        /// Push the current value onto the output.
        output,
        /// Descend into an object key. operand.string = key name.
        load_key,
        /// Descend into an array index. operand.index = position.
        load_index,
        /// Computed descent: pop if_stack for base; pop value_stack (or use current)
        /// for key/index. String key → object field; integer → array element.
        load_computed,
        /// Fused multi-level path descent. operand.string = "a.b.c".
        load_path,
        /// Iterate: push each element of array/object.
        iterate,
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

        // Alternative operator (//) — null coalescing
        /// Begin alternative evaluation: push current to if_stack; increment alt_null_depth
        /// so that field accesses on the left side propagate null instead of TypeError.
        alt_start,
        /// End of left side: decrement alt_null_depth. Pop TOS (or use current).
        /// If truthy: pop one entry from if_stack, push val back, jump to operand.index.
        /// If falsy: discard val, continue — restore_input fires next to pop if_stack.
        alt_check,

        // Try-catch error handling
        /// Begin a try block. operand.index = catch handler IP (0 = no catch;
        /// suppress error silently and terminate this output path).
        try_begin,
        /// End of try body (no error occurred). Pop TryFrame.
        /// operand.index = IP after catch handler (0 = no handler, just ip+1).
        try_end,

        // Builtin dispatch
        /// Call a built-in function. operand.index = BuiltinId (as i64).
        call_builtin,

        // Slicing
        /// Extract a sub-array or sub-string. operand.slice_args = bounds.
        /// Handles .[from:to], .[from:], .[:to], .[:] patterns.
        /// Negative indices count from the end; bounds are clamped to [0, length].
        slice,

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
    };

    pub const Operand = union {
        string: []const u8,
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
