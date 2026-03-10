const std = @import("std");
const err_mod = @import("error");
const types = @import("types");

pub const ZqError = err_mod.ZqError;
pub const Value = types.Value;
pub const Format = types.Format;

/// Internal buffer capacity: 64 KB.
const BUF_CAP: usize = 64 * 1024;

/// Buffered serializer targeting a single file descriptor.
///
/// Accumulates output in a 64 KB heap buffer and issues `write()` only when
/// the buffer is full or `flush()` is called explicitly. This reduces syscalls
/// from one-per-value to a handful for typical workloads.
pub const Writer = struct {
    fd: std.posix.fd_t,
    buf: []u8,
    len: usize,
    allocator: std.mem.Allocator,
    tty: bool,

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    /// Allocate a 64 KB buffer and detect whether `fd` is a terminal.
    pub fn init(fd: std.posix.fd_t, allocator: std.mem.Allocator) error{OutOfMemory}!Writer {
        const buf = try allocator.alloc(u8, BUF_CAP);
        const tty = std.posix.isatty(fd);
        return Writer{
            .fd = fd,
            .buf = buf,
            .len = 0,
            .allocator = allocator,
            .tty = tty,
        };
    }

    /// Flush buffered output and free the internal buffer.
    /// Write errors during the final flush are silently dropped (destructor contract).
    pub fn deinit(w: *Writer) void {
        // Best-effort flush; ignore write errors in deinit.
        w.flush() catch {};
        w.allocator.free(w.buf);
        w.buf = &.{};
        w.len = 0;
    }

    // ── Public API ────────────────────────────────────────────────────────────

    /// True if `fd` refers to a terminal device (result cached from `init`).
    pub fn is_tty(w: *const Writer) bool {
        return w.tty;
    }

    /// Serialize `val` to the internal buffer using `format`.
    /// Auto-flushes before serializing if the buffer cannot hold a single
    /// worst-case value (64 KB flush boundary). Returns `error.IoError` if
    /// any underlying `write()` syscall fails.
    pub fn write_value(w: *Writer, val: Value, format: Format) ZqError!void {
        // Flush proactively when the buffer is more than half full to avoid
        // splitting large values. Entire values are written atomically to the
        // buffer (the buffer is 64 KB; a single JSON value is unlikely to
        // exceed that, but we flush first to maximize available space).
        if (w.len > BUF_CAP / 2) {
            try w.flush();
        }

        switch (format) {
            .pretty => try w.writeValuePretty(val, 0),
            .compact => try w.writeValueCompact(val),
            .raw => try w.writeValueRaw(val),
            .jsonl => {
                try w.writeValueCompact(val);
                try w.writeByte('\n');
            },
        }
    }

    /// Write all buffered bytes to the OS and reset the buffer cursor.
    pub fn flush(w: *Writer) ZqError!void {
        if (w.len == 0) return;
        try writeAll(w.fd, w.buf[0..w.len]);
        w.len = 0;
    }

    // ── Low-level buffer helpers ───────────────────────────────────────────────

    /// Append a single byte to the buffer, flushing first if full.
    fn writeByte(w: *Writer, byte: u8) ZqError!void {
        if (w.len == BUF_CAP) try w.flush();
        w.buf[w.len] = byte;
        w.len += 1;
    }

    /// Append a slice to the buffer, flushing in chunks as needed.
    fn writeSlice(w: *Writer, data: []const u8) ZqError!void {
        var remaining = data;
        while (remaining.len > 0) {
            const space = BUF_CAP - w.len;
            if (space == 0) try w.flush();
            const chunk = @min(remaining.len, BUF_CAP - w.len);
            @memcpy(w.buf[w.len..][0..chunk], remaining[0..chunk]);
            w.len += chunk;
            remaining = remaining[chunk..];
        }
    }

    /// Write `n` space characters (for indentation).
    fn writeIndent(w: *Writer, depth: u32) ZqError!void {
        var i: u32 = 0;
        while (i < depth * 2) : (i += 1) {
            try w.writeByte(' ');
        }
    }

    // ── Format: compact ───────────────────────────────────────────────────────

    fn writeValueCompact(w: *Writer, val: Value) ZqError!void {
        switch (val) {
            .null_val => try w.writeSlice("null"),
            .bool_val => |b| try w.writeSlice(if (b) "true" else "false"),
            .int => |n| {
                var tmp: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
                try w.writeSlice(s);
            },
            .float => |f| {
                var tmp: [64]u8 = undefined;
                const s = formatFloat(&tmp, f);
                try w.writeSlice(s);
            },
            .string => |s| {
                try w.writeByte('"');
                try w.writeEscaped(s);
                try w.writeByte('"');
            },
            .array => |span| try w.writeArrayCompact(span),
            .object => |span| try w.writeObjectCompact(span),
        }
    }

    fn writeArrayCompact(w: *Writer, span: Value.TapeSpan) ZqError!void {
        try w.writeByte('[');
        const tape = span.tape;
        var idx = span.start + 1; // skip array_start
        var first = true;
        while (idx < span.end - 1) { // stop before array_end
            if (!first) try w.writeByte(',');
            first = false;
            const entry = tape.entries[idx];
            const child_val = entryToValue(tape, idx, entry);
            try w.writeValueCompact(child_val);
            idx = skipEntry(tape, idx);
        }
        try w.writeByte(']');
    }

    fn writeObjectCompact(w: *Writer, span: Value.TapeSpan) ZqError!void {
        try w.writeByte('{');
        const tape = span.tape;
        var idx = span.start + 1; // skip object_start
        var first = true;
        while (idx < span.end - 1) { // stop before object_end
            // entry at idx is always a key
            const key_ref = tape.entries[idx].payload.string;
            const key_str = tape.getString(key_ref);
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeByte('"');
            try w.writeEscaped(key_str);
            try w.writeSlice("\":");
            idx += 1; // advance to value entry
            const val_entry = tape.entries[idx];
            const child_val = entryToValue(tape, idx, val_entry);
            try w.writeValueCompact(child_val);
            idx = skipEntry(tape, idx);
        }
        try w.writeByte('}');
    }

    // ── Format: pretty ────────────────────────────────────────────────────────

    fn writeValuePretty(w: *Writer, val: Value, depth: u32) ZqError!void {
        switch (val) {
            .null_val, .bool_val, .int, .float, .string => {
                // Scalars render identically in pretty and compact.
                try w.writeValueCompact(val);
            },
            .array => |span| try w.writeArrayPretty(span, depth),
            .object => |span| try w.writeObjectPretty(span, depth),
        }
    }

    fn writeArrayPretty(w: *Writer, span: Value.TapeSpan, depth: u32) ZqError!void {
        const tape = span.tape;
        // Check if array is empty.
        if (span.end - span.start == 2) {
            try w.writeSlice("[]");
            return;
        }
        try w.writeSlice("[\n");
        var idx = span.start + 1;
        var first = true;
        while (idx < span.end - 1) {
            if (!first) try w.writeSlice(",\n");
            first = false;
            try w.writeIndent(depth + 1);
            const entry = tape.entries[idx];
            const child_val = entryToValue(tape, idx, entry);
            try w.writeValuePretty(child_val, depth + 1);
            idx = skipEntry(tape, idx);
        }
        try w.writeByte('\n');
        try w.writeIndent(depth);
        try w.writeByte(']');
    }

    fn writeObjectPretty(w: *Writer, span: Value.TapeSpan, depth: u32) ZqError!void {
        const tape = span.tape;
        // Check if object is empty.
        if (span.end - span.start == 2) {
            try w.writeSlice("{}");
            return;
        }
        try w.writeSlice("{\n");
        var idx = span.start + 1;
        var first = true;
        while (idx < span.end - 1) {
            const key_ref = tape.entries[idx].payload.string;
            const key_str = tape.getString(key_ref);
            if (!first) try w.writeSlice(",\n");
            first = false;
            try w.writeIndent(depth + 1);
            try w.writeByte('"');
            try w.writeEscaped(key_str);
            try w.writeSlice("\": ");
            idx += 1;
            const val_entry = tape.entries[idx];
            const child_val = entryToValue(tape, idx, val_entry);
            try w.writeValuePretty(child_val, depth + 1);
            idx = skipEntry(tape, idx);
        }
        try w.writeByte('\n');
        try w.writeIndent(depth);
        try w.writeByte('}');
    }

    // ── Format: raw ───────────────────────────────────────────────────────────

    fn writeValueRaw(w: *Writer, val: Value) ZqError!void {
        switch (val) {
            .string => |s| try w.writeSlice(s), // no quotes, no escaping
            else => try w.writeValueCompact(val),
        }
    }

    // ── JSON string escaping ──────────────────────────────────────────────────

    fn writeEscaped(w: *Writer, s: []const u8) ZqError!void {
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            switch (c) {
                '"' => try w.writeSlice("\\\""),
                '\\' => try w.writeSlice("\\\\"),
                '\n' => try w.writeSlice("\\n"),
                '\r' => try w.writeSlice("\\r"),
                '\t' => try w.writeSlice("\\t"),
                0x08 => try w.writeSlice("\\b"),
                0x0C => try w.writeSlice("\\f"),
                0x00...0x07, 0x0B, 0x0E...0x1F => {
                    var tmp: [6]u8 = undefined;
                    const seq = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                    try w.writeSlice(seq);
                },
                else => try w.writeByte(c),
            }
        }
    }
};

// ── Tape traversal helpers ────────────────────────────────────────────────────

/// Convert a tape entry at `idx` into a `Value`. For container tags, the span
/// is derived from the entry's skip field to find the one-past-end index.
fn entryToValue(tape: *const types.Tape, idx: u32, entry: types.Tape.Entry) Value {
    return switch (entry.tag) {
        .null_val => .null_val,
        .true_val => .{ .bool_val = true },
        .false_val => .{ .bool_val = false },
        .int => .{ .int = entry.payload.int },
        .float => .{ .float = entry.payload.float },
        .string => .{ .string = tape.getString(entry.payload.string) },
        .array_start => .{ .array = .{
            .tape = tape,
            .start = idx,
            .end = entry.payload.skip,
        } },
        .object_start => .{ .object = .{
            .tape = tape,
            .start = idx,
            .end = entry.payload.skip,
        } },
        // Keys and end markers are never top-level values.
        .key, .object_end, .array_end => unreachable,
    };
}

/// Return the tape index of the entry immediately following the value at `idx`.
/// For scalars this is `idx + 1`. For containers it uses the skip field.
fn skipEntry(tape: *const types.Tape, idx: u32) u32 {
    const entry = tape.entries[idx];
    return switch (entry.tag) {
        .array_start, .object_start => entry.payload.skip,
        else => idx + 1,
    };
}

// ── Float formatting ──────────────────────────────────────────────────────────

/// Format a float as JSON. Produces a decimal representation that round-trips
/// through `parseFloat`. Special values (inf, nan) are rendered as `null` per
/// the JSON specification (JSON has no representation for non-finite numbers).
fn formatFloat(buf: *[64]u8, f: f64) []const u8 {
    if (std.math.isNan(f) or std.math.isInf(f)) {
        return "null";
    }
    // Check if the float is actually an integer
    if (f == @trunc(f)) {
        // Integer-valued float - format as integer (no decimal point)
        const s = std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(f))}) catch unreachable;
        return s;
    }
    // Non-integer float - format with decimal part
    const s = std.fmt.bufPrint(buf, "{d}", .{f}) catch unreachable;
    return s;
}

// ── OS write helper ───────────────────────────────────────────────────────────

/// Write all bytes in `data` to `fd`, retrying on EINTR. Returns `error.IoError`
/// on any non-EINTR failure or if a short write occurs with no progress.
fn writeAll(fd: std.posix.fd_t, data: []const u8) ZqError!void {
    var remaining = data;
    while (remaining.len > 0) {
        const n = std.posix.write(fd, remaining) catch return error.IoError;
        if (n == 0) return error.IoError;
        remaining = remaining[n..];
    }
}
