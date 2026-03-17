const std = @import("std");
const err_mod = @import("error");
const types = @import("types");

pub const ZqError = err_mod.ZqError;
pub const Value = types.Value;
pub const Format = types.Format;

pub const Color = struct {
    null_color: []const u8,
    bool_color: []const u8,
    number_color: []const u8,
    string_color: []const u8,
    key_color: []const u8,
    reset: []const u8,
};

pub const default_colors = Color{
    .null_color = "\x1b[1;30m",
    .bool_color = "\x1b[35m",
    .number_color = "\x1b[36m",
    .string_color = "\x1b[32m",
    .key_color = "\x1b[1;34m",
    .reset = "\x1b[0m",
};

pub const SerializeOpts = struct {
    sort_keys: bool = false,
    indent: Indent = .{ .spaces = 2 },
    allocator: ?std.mem.Allocator = null,

    pub const Indent = union(enum) {
        spaces: u8,
        tab,
    };
};

/// Internal buffer capacity: 64 KB.
const BUF_CAP: usize = 64 * 1024;

// ── BufferSink — growable-buffer target for generic serialization ─────────────

/// Adapts an `std.ArrayList(u8)` to the same `writeByte`/`writeSlice` interface
/// used by the generic serialization functions.  Used by pool workers to
/// serialize values directly into arena-backed byte buffers.
pub const BufferSink = struct {
    list: *std.ArrayList(u8),
    aa: std.mem.Allocator,

    pub fn writeByte(self: *BufferSink, byte: u8) error{OutOfMemory}!void {
        try self.list.append(self.aa, byte);
    }

    pub fn writeSlice(self: *BufferSink, data: []const u8) error{OutOfMemory}!void {
        try self.list.appendSlice(self.aa, data);
    }
};

// ── Public serialize entry point ──────────────────────────────────────────────

/// Serialize `val` into any sink supporting `writeByte`/`writeSlice`.
/// Format semantics match `Writer.write_value`.
pub fn serialize(ctx: anytype, val: Value, format: Format, color: ?*const Color, opts: SerializeOpts) !void {
    switch (format) {
        .pretty => try serializeValuePretty(ctx, val, 0, color, opts),
        .compact => try serializeValueCompact(ctx, val, color, opts),
        .raw => try serializeValueRaw(ctx, val, opts),
        .jsonl => {
            try serializeValueCompact(ctx, val, color, opts);
            try ctx.writeByte('\n');
        },
        .join => try serializeValueRaw(ctx, val, opts),
    }
}

// ── Generic serialization functions ───────────────────────────────────────────
//
// Each function takes `ctx: anytype` which must provide:
//   fn writeByte(*@TypeOf(ctx), u8) !void
//   fn writeSlice(*@TypeOf(ctx), []const u8) !void

fn serializeValueCompact(ctx: anytype, val: Value, color: ?*const Color, opts: SerializeOpts) anyerror!void {
    switch (val) {
        .null_val => {
            if (color) |c| try ctx.writeSlice(c.null_color);
            try ctx.writeSlice("null");
            if (color) |c| try ctx.writeSlice(c.reset);
        },
        .bool_val => |b| {
            if (color) |c| try ctx.writeSlice(c.bool_color);
            try ctx.writeSlice(if (b) "true" else "false");
            if (color) |c| try ctx.writeSlice(c.reset);
        },
        .int => |n| {
            if (color) |c| try ctx.writeSlice(c.number_color);
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
            try ctx.writeSlice(s);
            if (color) |c| try ctx.writeSlice(c.reset);
        },
        .float => |f| {
            if (color) |c| try ctx.writeSlice(c.number_color);
            const formatted = types.formatJqFloat(f);
            try ctx.writeSlice(formatted.slice());
            if (color) |c| try ctx.writeSlice(c.reset);
        },
        .string => |s| {
            if (color) |c| try ctx.writeSlice(c.string_color);
            try ctx.writeByte('"');
            try serializeEscaped(ctx, s);
            try ctx.writeByte('"');
            if (color) |c| try ctx.writeSlice(c.reset);
        },
        .array => |span| try serializeArrayCompact(ctx, span, color, opts),
        .object => |span| try serializeObjectCompact(ctx, span, color, opts),
    }
}

fn serializeArrayCompact(ctx: anytype, span: Value.TapeSpan, color: ?*const Color, opts: SerializeOpts) anyerror!void {
    try ctx.writeByte('[');
    const tape = span.tape;
    var idx = span.start + 1;
    var first = true;
    while (idx < span.end - 1) {
        if (!first) try ctx.writeByte(',');
        first = false;
        const entry = tape.entries[idx];
        const child_val = entryToValue(tape, idx, entry);
        try serializeValueCompact(ctx, child_val, color, opts);
        idx = skipEntry(tape, idx);
    }
    try ctx.writeByte(']');
}

fn serializeObjectCompact(ctx: anytype, span: Value.TapeSpan, color: ?*const Color, opts: SerializeOpts) anyerror!void {
    try ctx.writeByte('{');
    const tape = span.tape;

    if (opts.sort_keys) {
        const KV = struct { key: []const u8, val_idx: u32 };

        // Count keys to decide buffer strategy
        var key_count: usize = 0;
        {
            var ci = span.start + 1;
            while (ci < span.end - 1) {
                ci += 1;
                ci = skipEntry(tape, ci);
                key_count += 1;
            }
        }

        var stack_buf: [256]KV = undefined;
        var heap_buf: ?[]KV = null;
        const kvs: ?[]KV = if (key_count <= 256)
            stack_buf[0..key_count]
        else if (opts.allocator) |a| blk: {
            heap_buf = a.alloc(KV, key_count) catch break :blk null;
            break :blk heap_buf.?;
        } else null;
        defer if (heap_buf) |h| (opts.allocator.?).free(h);

        if (kvs) |buf| {
            var count: usize = 0;
            var idx = span.start + 1;
            while (idx < span.end - 1) {
                const key_ref = tape.entries[idx].payload.string;
                const key_str = tape.getString(key_ref);
                idx += 1;
                buf[count] = .{ .key = key_str, .val_idx = idx };
                count += 1;
                idx = skipEntry(tape, idx);
            }
            std.mem.sortUnstable(KV, buf[0..count], {}, struct {
                fn lessThan(_: void, a: KV, b: KV) bool {
                    return std.mem.order(u8, a.key, b.key) == .lt;
                }
            }.lessThan);
            for (buf[0..count], 0..) |kv, i| {
                if (i > 0) try ctx.writeByte(',');
                if (color) |c| try ctx.writeSlice(c.key_color);
                try ctx.writeByte('"');
                try serializeEscaped(ctx, kv.key);
                try ctx.writeByte('"');
                if (color) |c| try ctx.writeSlice(c.reset);
                try ctx.writeByte(':');
                const val_entry = tape.entries[kv.val_idx];
                const child_val = entryToValue(tape, kv.val_idx, val_entry);
                try serializeValueCompact(ctx, child_val, color, opts);
            }
        } else {
            try serializeObjectUnsorted(ctx, tape, span, color, opts, false, 0);
        }
    } else {
        try serializeObjectUnsorted(ctx, tape, span, color, opts, false, 0);
    }
    try ctx.writeByte('}');
}

fn serializeValuePretty(ctx: anytype, val: Value, depth: u32, color: ?*const Color, opts: SerializeOpts) anyerror!void {
    switch (val) {
        .null_val, .bool_val, .int, .float, .string => {
            try serializeValueCompact(ctx, val, color, opts);
        },
        .array => |span| try serializeArrayPretty(ctx, span, depth, color, opts),
        .object => |span| try serializeObjectPretty(ctx, span, depth, color, opts),
    }
}

fn serializeArrayPretty(ctx: anytype, span: Value.TapeSpan, depth: u32, color: ?*const Color, opts: SerializeOpts) anyerror!void {
    const tape = span.tape;
    if (span.end - span.start == 2) {
        try ctx.writeSlice("[]");
        return;
    }
    try ctx.writeSlice("[\n");
    var idx = span.start + 1;
    var first = true;
    while (idx < span.end - 1) {
        if (!first) try ctx.writeSlice(",\n");
        first = false;
        try serializeIndent(ctx, depth + 1, opts.indent);
        const entry = tape.entries[idx];
        const child_val = entryToValue(tape, idx, entry);
        try serializeValuePretty(ctx, child_val, depth + 1, color, opts);
        idx = skipEntry(tape, idx);
    }
    try ctx.writeByte('\n');
    try serializeIndent(ctx, depth, opts.indent);
    try ctx.writeByte(']');
}

fn serializeObjectPretty(ctx: anytype, span: Value.TapeSpan, depth: u32, color: ?*const Color, opts: SerializeOpts) anyerror!void {
    const tape = span.tape;
    if (span.end - span.start == 2) {
        try ctx.writeSlice("{}");
        return;
    }
    try ctx.writeSlice("{\n");

    if (opts.sort_keys) {
        const KV = struct { key: []const u8, val_idx: u32 };

        var key_count: usize = 0;
        {
            var ci = span.start + 1;
            while (ci < span.end - 1) {
                ci += 1;
                ci = skipEntry(tape, ci);
                key_count += 1;
            }
        }

        var stack_buf: [256]KV = undefined;
        var heap_buf: ?[]KV = null;
        const kvs: ?[]KV = if (key_count <= 256)
            stack_buf[0..key_count]
        else if (opts.allocator) |a| blk: {
            heap_buf = a.alloc(KV, key_count) catch break :blk null;
            break :blk heap_buf.?;
        } else null;
        defer if (heap_buf) |h| (opts.allocator.?).free(h);

        if (kvs) |buf| {
            var count: usize = 0;
            var idx = span.start + 1;
            while (idx < span.end - 1) {
                const key_ref = tape.entries[idx].payload.string;
                const key_str = tape.getString(key_ref);
                idx += 1;
                buf[count] = .{ .key = key_str, .val_idx = idx };
                count += 1;
                idx = skipEntry(tape, idx);
            }
            std.mem.sortUnstable(KV, buf[0..count], {}, struct {
                fn lessThan(_: void, a: KV, b: KV) bool {
                    return std.mem.order(u8, a.key, b.key) == .lt;
                }
            }.lessThan);
            for (buf[0..count], 0..) |kv, i| {
                if (i > 0) try ctx.writeSlice(",\n");
                try serializeIndent(ctx, depth + 1, opts.indent);
                if (color) |c| try ctx.writeSlice(c.key_color);
                try ctx.writeByte('"');
                try serializeEscaped(ctx, kv.key);
                try ctx.writeByte('"');
                if (color) |c| try ctx.writeSlice(c.reset);
                try ctx.writeSlice(": ");
                const val_entry = tape.entries[kv.val_idx];
                const child_val = entryToValue(tape, kv.val_idx, val_entry);
                try serializeValuePretty(ctx, child_val, depth + 1, color, opts);
            }
        } else {
            try serializeObjectUnsorted(ctx, tape, span, color, opts, true, depth);
        }
    } else {
        try serializeObjectUnsorted(ctx, tape, span, color, opts, true, depth);
    }
    try ctx.writeByte('\n');
    try serializeIndent(ctx, depth, opts.indent);
    try ctx.writeByte('}');
}

/// Emit object key-value pairs in tape order (unsorted).
/// When `pretty` is true, emits indented output with newlines between entries.
fn serializeObjectUnsorted(ctx: anytype, tape: *const types.Tape, span: Value.TapeSpan, color: ?*const Color, opts: SerializeOpts, comptime pretty: bool, depth: u32) anyerror!void {
    var idx = span.start + 1;
    var first = true;
    while (idx < span.end - 1) {
        const key_ref = tape.entries[idx].payload.string;
        const key_str = tape.getString(key_ref);
        if (!first) {
            if (pretty) try ctx.writeSlice(",\n") else try ctx.writeByte(',');
        }
        first = false;
        if (pretty) try serializeIndent(ctx, depth + 1, opts.indent);
        if (color) |c| try ctx.writeSlice(c.key_color);
        try ctx.writeByte('"');
        try serializeEscaped(ctx, key_str);
        try ctx.writeByte('"');
        if (color) |c| try ctx.writeSlice(c.reset);
        if (pretty) try ctx.writeSlice(": ") else try ctx.writeByte(':');
        idx += 1;
        const val_entry = tape.entries[idx];
        const child_val = entryToValue(tape, idx, val_entry);
        if (pretty)
            try serializeValuePretty(ctx, child_val, depth + 1, color, opts)
        else
            try serializeValueCompact(ctx, child_val, color, opts);
        idx = skipEntry(tape, idx);
    }
}

fn serializeValueRaw(ctx: anytype, val: Value, opts: SerializeOpts) anyerror!void {
    switch (val) {
        .string => |s| try ctx.writeSlice(s),
        else => try serializeValueCompact(ctx, val, null, opts),
    }
}

fn serializeEscaped(ctx: anytype, s: []const u8) anyerror!void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '"' => try ctx.writeSlice("\\\""),
            '\\' => try ctx.writeSlice("\\\\"),
            '\n' => try ctx.writeSlice("\\n"),
            '\r' => try ctx.writeSlice("\\r"),
            '\t' => try ctx.writeSlice("\\t"),
            0x08 => try ctx.writeSlice("\\b"),
            0x0C => try ctx.writeSlice("\\f"),
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                var tmp: [6]u8 = undefined;
                const seq = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                try ctx.writeSlice(seq);
            },
            else => try ctx.writeByte(c),
        }
    }
}

fn serializeIndent(ctx: anytype, depth: u32, indent: SerializeOpts.Indent) anyerror!void {
    switch (indent) {
        .tab => {
            var i: u32 = 0;
            while (i < depth) : (i += 1) {
                try ctx.writeByte('\t');
            }
        },
        .spaces => |n| {
            var i: u32 = 0;
            while (i < depth * n) : (i += 1) {
                try ctx.writeByte(' ');
            }
        },
    }
}

// ── Buffered Writer targeting a single file ───────────────────────────────────

/// Buffered serializer targeting a single file.
///
/// Accumulates output in a 64 KB heap buffer and issues `writeAll()` only when
/// the buffer is full or `flush()` is called explicitly. This reduces syscalls
/// from one-per-value to a handful for typical workloads.
pub const Writer = struct {
    file: std.fs.File,
    buf: []u8,
    len: usize,
    allocator: std.mem.Allocator,
    tty: bool,

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    /// Allocate a 64 KB buffer and detect whether `file` is a terminal.
    pub fn init(file: std.fs.File, allocator: std.mem.Allocator) error{OutOfMemory}!Writer {
        const buf = try allocator.alloc(u8, BUF_CAP);
        const tty = file.isTty();
        return Writer{
            .file = file,
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

    /// True if `file` refers to a terminal device (result cached from `init`).
    pub fn is_tty(w: *const Writer) bool {
        return w.tty;
    }

    /// Serialize `val` to the internal buffer using `format`.
    /// Auto-flushes before serializing if the buffer cannot hold a single
    /// worst-case value (64 KB flush boundary). Returns `error.IoError` if
    /// any underlying `writeAll()` call fails.
    pub fn write_value(w: *Writer, val: Value, format: Format, color: ?*const Color, opts: SerializeOpts) ZqError!void {
        if (w.len > BUF_CAP / 2) {
            try w.flush();
        }
        // Generic serialize functions return anyerror (needed for recursive generics);
        // Writer's writeByte/writeSlice only produce ZqError, so @errorCast is safe.
        serialize(w, val, format, color, opts) catch |e| return @as(ZqError, @errorCast(e));
    }

    /// Write all buffered bytes to the OS and reset the buffer cursor.
    pub fn flush(w: *Writer) ZqError!void {
        if (w.len == 0) return;
        w.file.writeAll(w.buf[0..w.len]) catch return error.IoError;
        w.len = 0;
    }

    /// Append pre-serialized bytes directly to the internal buffer.
    /// Used by main.zig to write output from the serialized pool path.
    pub fn writeSlice(w: *Writer, data: []const u8) ZqError!void {
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

    // ── Low-level buffer helpers (satisfy generic serialize interface) ─────────

    /// Append a single byte to the buffer, flushing first if full.
    fn writeByte(w: *Writer, byte: u8) ZqError!void {
        if (w.len == BUF_CAP) try w.flush();
        w.buf[w.len] = byte;
        w.len += 1;
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
// Removed: formatFloat — use types.formatJqFloat() (single source of truth).
