const std = @import("std");
const err_mod = @import("error");
const query_mod = @import("query");
const parser_mod = @import("parser");
const types = @import("types");

const ZqError = err_mod.ZqError;
const CompiledQuery = query_mod.CompiledQuery;
const Parser = parser_mod.Parser;
const FeedResult = parser_mod.FeedResult;
const Value = types.Value;

// ── Error codes returned by zq_execute ───────────────────────────────────────

/// Parse error: malformed input JSON.
const ERR_PARSE: c_int = -1;
/// Query execution error: TypeError or IndexOutOfBounds.
const ERR_EXECUTE: c_int = -2;
/// Out of memory during execute.
const ERR_OOM: c_int = -3;

// ── QueryHandle ───────────────────────────────────────────────────────────────

/// Opaque handle owning all zq state for a single compiled query.
/// Callers receive and pass a `?*QueryHandle`; they must never dereference it.
pub const QueryHandle = struct {
    allocator: std.mem.Allocator,
    query: CompiledQuery,
    parser: Parser,
    /// Null-terminated buffer holding the result of the last successful execute.
    result_buf: []u8,
    /// Number of content bytes in result_buf (excludes the null terminator).
    result_len: usize,

    /// Minimum initial capacity for the result buffer (avoids tiny reallocations
    /// for the common case of small query outputs).
    const INITIAL_RESULT_CAP: usize = 4096;
};

// ── Compact JSON serialiser ───────────────────────────────────────────────────
//
// Mirrors output/root.zig's compact path but writes into an ArrayList(u8)
// instead of an fd-backed buffer, so we can capture all results in memory
// before committing them to the handle's result buffer.

fn writeValueCompact(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    val: Value,
) error{OutOfMemory}!void {
    switch (val) {
        .null_val => try buf.appendSlice(allocator, "null"),
        .bool_val => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .int => |n| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            var tmp: [64]u8 = undefined;
            const s = formatFloat(&tmp, f);
            try buf.appendSlice(allocator, s);
        },
        .string => |s| {
            try buf.append(allocator, '"');
            try writeEscaped(buf, allocator, s);
            try buf.append(allocator, '"');
        },
        .array => |span| {
            try buf.append(allocator, '[');
            const tape = span.tape;
            var idx = span.start + 1;
            var first = true;
            while (idx < span.end - 1) {
                if (!first) try buf.append(allocator, ',');
                first = false;
                const entry = tape.entries[idx];
                const child = entryToValue(tape, idx, entry);
                try writeValueCompact(buf, allocator, child);
                idx = skipEntry(tape, idx);
            }
            try buf.append(allocator, ']');
        },
        .object => |span| {
            try buf.append(allocator, '{');
            const tape = span.tape;
            var idx = span.start + 1;
            var first = true;
            while (idx < span.end - 1) {
                const key_ref = tape.entries[idx].payload.string;
                const key_str = tape.getString(key_ref);
                if (!first) try buf.append(allocator, ',');
                first = false;
                try buf.append(allocator, '"');
                try writeEscaped(buf, allocator, key_str);
                try buf.appendSlice(allocator, "\":");
                idx += 1;
                const val_entry = tape.entries[idx];
                const child = entryToValue(tape, idx, val_entry);
                try writeValueCompact(buf, allocator, child);
                idx = skipEntry(tape, idx);
            }
            try buf.append(allocator, '}');
        },
    }
}

// ── Tape traversal helpers (mirrors output/root.zig) ─────────────────────────

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
        .key, .object_end, .array_end => unreachable,
    };
}

fn skipEntry(tape: *const types.Tape, idx: u32) u32 {
    const entry = tape.entries[idx];
    return switch (entry.tag) {
        .array_start, .object_start => entry.payload.skip,
        else => idx + 1,
    };
}

// ── Float formatting ──────────────────────────────────────────────────────────

fn formatFloat(buf: *[64]u8, f: f64) []const u8 {
    if (std.math.isNan(f) or std.math.isInf(f)) return "null";
    return std.fmt.bufPrint(buf, "{d}", .{f}) catch unreachable;
}

// ── JSON string escaping ──────────────────────────────────────────────────────

fn writeEscaped(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    s: []const u8,
) error{OutOfMemory}!void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0C => try buf.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                var tmp: [6]u8 = undefined;
                const seq = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                try buf.appendSlice(allocator, seq);
            },
            else => try buf.append(allocator, c),
        }
    }
}

// ── Allocator ─────────────────────────────────────────────────────────────────
//
// The C ABI module must allocate heap memory that outlives any single Zig
// function call. We use the page allocator — always available with no libc
// dependency — as the backing allocator for all handle memory.

fn handleAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}

// ── C ABI exports ─────────────────────────────────────────────────────────────

/// Compile `query_str` into a reusable `QueryHandle`.
///
/// Returns null on any error (syntax, OOM). On success the caller owns the
/// handle and must release it with `zq_free` exactly once.
pub export fn zq_compile(query_str: [*:0]const u8) ?*QueryHandle {
    const allocator = handleAllocator();
    const src = std.mem.sliceTo(query_str, 0);

    // Compile first; avoids allocating the handle on syntax errors.
    const compiled = CompiledQuery.compile(src, .{}, allocator) catch return null;
    var compiled_mut = compiled;

    const parser = Parser.init(allocator) catch {
        compiled_mut.deinit();
        return null;
    };
    var parser_mut = parser;

    const result_buf = allocator.alloc(u8, QueryHandle.INITIAL_RESULT_CAP) catch {
        parser_mut.deinit();
        compiled_mut.deinit();
        return null;
    };
    // Null-terminate immediately so zq_get_result is always safe.
    result_buf[0] = 0;

    const handle = allocator.create(QueryHandle) catch {
        allocator.free(result_buf);
        parser_mut.deinit();
        compiled_mut.deinit();
        return null;
    };

    handle.* = QueryHandle{
        .allocator = allocator,
        .query = compiled_mut,
        .parser = parser_mut,
        .result_buf = result_buf,
        .result_len = 0,
    };

    return handle;
}

/// Execute the compiled query against `input_ptr[0..input_len]`.
///
/// Parses the input, runs the query, and serialises all output values into the
/// handle's result buffer in compact JSON format (one value per line for
/// multiple results). Returns 0 on success or a negative error code on failure.
///
/// The result buffer is updated only on success. On failure the buffer retains
/// the output from the previous successful execute (or is empty if there was
/// no prior successful execute).
pub export fn zq_execute(
    handle: *QueryHandle,
    input_ptr: [*]const u8,
    input_len: usize,
) c_int {
    const allocator = handle.allocator;
    const input = input_ptr[0..input_len];

    // Reset the parser state machine so it is ready for a fresh record.
    handle.parser.reset();

    // Feed the entire input in one call with is_eof = true.
    const feed_result = handle.parser.feed(input, true) catch |e| {
        return switch (e) {
            error.OutOfMemory => ERR_OOM,
            else => ERR_PARSE,
        };
    };

    const tape = switch (feed_result) {
        .done => |d| d.tape,
        // is_eof = true means feed() must return .done or an error, never
        // .need_more.  Treat it as a parse error defensively.
        .need_more => return ERR_PARSE,
    };

    // Execute the compiled query against the tape.
    var iterator = handle.query.execute(tape, allocator) catch return ERR_OOM;
    defer iterator.deinit();

    // Accumulate all results into a temporary ArrayList, then move into the
    // handle's result buffer only on full success.  This preserves the
    // previous result on partial failure.
    var tmp = std.ArrayList(u8){};
    defer tmp.deinit(allocator);

    // Pre-size to avoid reallocations for common small outputs.
    tmp.ensureTotalCapacity(allocator, handle.result_buf.len) catch {};

    var value_count: usize = 0;
    while (iterator.next() catch |e| {
        return switch (e) {
            error.TypeError, error.IndexOutOfBounds => ERR_EXECUTE,
            else => ERR_PARSE,
        };
    }) |val| {
        // Separate multiple values with a newline (JSONL style).
        if (value_count > 0) {
            tmp.append(allocator, '\n') catch return ERR_OOM;
        }
        writeValueCompact(&tmp, allocator, val) catch return ERR_OOM;
        value_count += 1;
    }

    // Ensure there is room for the content plus a null terminator.
    const needed = tmp.items.len + 1;
    if (needed > handle.result_buf.len) {
        const new_buf = allocator.realloc(handle.result_buf, needed) catch
            return ERR_OOM;
        handle.result_buf = new_buf;
    }

    // Copy content and null-terminate.
    @memcpy(handle.result_buf[0..tmp.items.len], tmp.items);
    handle.result_buf[tmp.items.len] = 0;
    handle.result_len = tmp.items.len;

    return 0;
}

/// Return a pointer to the null-terminated result string from the most recent
/// successful `zq_execute` call. Valid until the next `zq_execute` or
/// `zq_free` call.
pub export fn zq_get_result(handle: *QueryHandle) [*:0]const u8 {
    // The buffer is always null-terminated at result_len.
    return handle.result_buf[0..handle.result_len :0];
}

/// Release all resources owned by the handle and free the handle itself.
/// The pointer must not be used after this call.
pub export fn zq_free(handle: *QueryHandle) void {
    const allocator = handle.allocator;
    handle.query.deinit();
    handle.parser.deinit();
    allocator.free(handle.result_buf);
    allocator.destroy(handle);
}
