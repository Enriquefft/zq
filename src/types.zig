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
        /// Fused multi-level path descent. operand.string = "a.b.c".
        load_path,
        /// Iterate: push each element of array/object.
        iterate,
        /// Pipe: pop current, feed to next stage.
        pipe,
        /// Identity: no-op pass-through (`.`).
        identity,
    };

    pub const Operand = union {
        string: []const u8,
        index: u32,
        none: void,
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
};
