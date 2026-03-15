const std = @import("std");
const build_options = @import("build_options");
const io_mod = @import("io");
const parser_mod = @import("parser");
const query_mod = @import("query");
const output_mod = @import("output");
const pool_mod = @import("pool");
const types = @import("types");

const EXIT_OK = 0;
const EXIT_FALSE = 1; // -e: last output was false/null
const EXIT_USAGE = 2;
const EXIT_SYSTEM = 5;

const ExternalVar = struct {
    name: []const u8,
    value: []const u8,
    is_json: bool,
};

const Config = struct {
    filter: ?[]const u8 = null,
    files: []const []const u8 = &.{},
    format: types.Format = .pretty,
    exit_status: bool = false,
    null_input: bool = false,
    raw_input: bool = false,
    slurp: bool = false,
    sort_keys: bool = false,
    join_output: bool = false,
    tab_indent: bool = false,
    indent_width: u8 = 2,
    color: enum { auto, on, off } = .auto,
    filter_file: ?[]const u8 = null,
    external_vars: []const ExternalVar = &.{},

    // Owned allocations to free on cleanup.
    _owned_filter: ?[]u8 = null,
    _owned_filter_file_path: ?[]u8 = null,
    _owned_file_strs: [][]u8 = &.{},
    _owned_file_list: ?[]const []const u8 = null,
    _owned_ext_vars: ?[]ExternalVar = null,
    _owned_ext_var_strs: [][]u8 = &.{},
    _allocator: ?std.mem.Allocator = null,

    fn deinit(self: *Config) void {
        const alloc = self._allocator orelse return;
        if (self._owned_filter_file_path) |f| alloc.free(f);
        if (self._owned_filter) |f| alloc.free(f);
        for (self._owned_file_strs) |f| alloc.free(f);
        if (self._owned_file_strs.len > 0) alloc.free(self._owned_file_strs);
        if (self._owned_file_list) |f| alloc.free(f);
        for (self._owned_ext_var_strs) |s| alloc.free(s);
        if (self._owned_ext_var_strs.len > 0) alloc.free(self._owned_ext_var_strs);
        if (self._owned_ext_vars) |v| alloc.free(v);
    }
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = parseArgs(allocator) catch |e| {
        switch (e) {
            error.UsageError => return EXIT_USAGE,
            else => return EXIT_SYSTEM,
        }
    };
    defer config.deinit();

    // Determine filter source.
    const filter_src: []const u8 = blk: {
        if (config.filter_file) |path| {
            const file = std.fs.cwd().openFile(path, .{}) catch {
                printErr("zq: could not open filter file: ");
                printErr(path);
                printErr("\n");
                return EXIT_SYSTEM;
            };
            defer file.close();

            const contents = file.readToEndAlloc(allocator, 1 * 1024 * 1024) catch {
                printErr("zq: could not read filter file: ");
                printErr(path);
                printErr("\n");
                return EXIT_SYSTEM;
            };
            if (config._owned_filter) |old| allocator.free(old);
            config._owned_filter = contents;

            break :blk std.mem.trimRight(u8, contents, "\r\n");
        }
        break :blk config.filter orelse {
            printErr("zq: no filter provided\n");
            printUsage();
            return EXIT_USAGE;
        };
    };

    // Build external variable declarations for compile.
    var ext_decls_buf = allocator.alloc(query_mod.ExternalVarDecl, config.external_vars.len) catch {
        printErr("zq: out of memory\n");
        return EXIT_SYSTEM;
    };
    defer allocator.free(ext_decls_buf);
    for (config.external_vars, 0..) |ev, i| {
        ext_decls_buf[i] = .{ .name = ev.name };
    }

    // Compile query.
    var cq = query_mod.CompiledQuery.compile(filter_src, .{
        .external_vars = ext_decls_buf,
    }, allocator) catch |e| {
        printErr("zq: compile error: ");
        printZqErr(e);
        return EXIT_USAGE;
    };
    defer cq.deinit();

    // Build external variable bindings after compile (var_ids are now known).
    var ext_bindings_buf = allocator.alloc(query_mod.ExternalVarBinding, config.external_vars.len) catch {
        printErr("zq: out of memory\n");
        return EXIT_SYSTEM;
    };
    defer allocator.free(ext_bindings_buf);

    // RuntimeTape for --argjson compound values (objects/arrays/strings).
    // Must outlive all execution since StackValues reference its tape entries.
    var argjson_rt = types.RuntimeTape.init(allocator) catch {
        printErr("zq: out of memory\n");
        return EXIT_SYSTEM;
    };
    defer argjson_rt.deinit(allocator);

    // Track which binding indices need compound-type resolution after RT is built.
    const CompoundRef = struct { idx: usize, rt_start: u32 };
    var compound_refs = std.ArrayList(CompoundRef){};
    defer compound_refs.deinit(allocator);

    {
        // Temporary parser for --argjson values.
        var argjson_parser = parser_mod.Parser.init(allocator) catch {
            printErr("zq: out of memory\n");
            return EXIT_SYSTEM;
        };
        defer argjson_parser.deinit();

        for (config.external_vars, 0..) |ev, i| {
            if (ev.is_json) {
                // --argjson: parse the JSON value
                const parse_result = argjson_parser.feed(ev.value, true) catch {
                    printErr("zq: --argjson: invalid JSON for $");
                    printErr(ev.name);
                    printErr("\n");
                    return EXIT_USAGE;
                };
                const tape = switch (parse_result) {
                    .done => |d| d.tape,
                    .need_more => {
                        printErr("zq: --argjson: incomplete JSON for $");
                        printErr(ev.name);
                        printErr("\n");
                        return EXIT_USAGE;
                    },
                };
                const entry = tape.entries[0];
                switch (entry.tag) {
                    .null_val => {
                        ext_bindings_buf[i] = .{ .var_id = cq.external_var_ids[i], .value = .null_val };
                    },
                    .true_val => {
                        ext_bindings_buf[i] = .{ .var_id = cq.external_var_ids[i], .value = .{ .bool_val = true } };
                    },
                    .false_val => {
                        ext_bindings_buf[i] = .{ .var_id = cq.external_var_ids[i], .value = .{ .bool_val = false } };
                    },
                    .int => {
                        ext_bindings_buf[i] = .{ .var_id = cq.external_var_ids[i], .value = .{ .int = entry.payload.int } };
                    },
                    .float => {
                        ext_bindings_buf[i] = .{ .var_id = cq.external_var_ids[i], .value = .{ .float = entry.payload.float } };
                    },
                    else => {
                        // String, array, or object: copy into RuntimeTape.
                        const rt_start: u32 = @intCast(argjson_rt.entries.items.len);
                        copyTapeToRuntimeTape(&argjson_rt, tape, allocator) catch {
                            printErr("zq: out of memory\n");
                            return EXIT_SYSTEM;
                        };
                        // Placeholder value; will be resolved below.
                        ext_bindings_buf[i] = .{ .var_id = cq.external_var_ids[i], .value = .null_val };
                        compound_refs.append(allocator, .{ .idx = i, .rt_start = rt_start }) catch {
                            printErr("zq: out of memory\n");
                            return EXIT_SYSTEM;
                        };
                    },
                }
                argjson_parser.reset();
            } else {
                // --arg: string value
                ext_bindings_buf[i] = .{
                    .var_id = cq.external_var_ids[i],
                    .value = .{ .tape_value = .{ .string = ev.value } },
                };
            }
        }
    }

    // Build the stable tape view from the RuntimeTape and resolve compound bindings.
    var argjson_tape_view = argjson_rt.asTape();
    for (compound_refs.items) |ref| {
        const rt_entry = argjson_tape_view.entries[ref.rt_start];
        ext_bindings_buf[ref.idx].value = switch (rt_entry.tag) {
            .string => .{ .tape_value = .{ .string = argjson_tape_view.getString(rt_entry.payload.string) } },
            .array_start => .{ .tape_value = .{ .array = .{ .tape = &argjson_tape_view, .start = ref.rt_start, .end = rt_entry.payload.skip } } },
            .object_start => .{ .tape_value = .{ .object = .{ .tape = &argjson_tape_view, .start = ref.rt_start, .end = rt_entry.payload.skip } } },
            else => .null_val,
        };
    }
    const ext_bindings: []const query_mod.ExternalVarBinding = ext_bindings_buf;

    // Set up output writer on stdout.
    var writer = output_mod.Writer.init(std.fs.File.stdout(), allocator) catch {
        printErr("zq: out of memory\n");
        return EXIT_SYSTEM;
    };
    defer writer.deinit();

    // Pick format: if stdout is TTY and no explicit format flag, use pretty.
    const format: types.Format = if (config.join_output) .join else config.format;

    const serialize_opts = output_mod.SerializeOpts{
        .sort_keys = config.sort_keys,
        .indent = if (config.tab_indent) .tab else .{ .spaces = config.indent_width },
    };

    const color: ?*const output_mod.Color = switch (config.color) {
        .on => &output_mod.default_colors,
        .off => null,
        .auto => if (writer.is_tty() and !hasNoColor()) &output_mod.default_colors else null,
    };

    var last_was_false_or_null = false;
    var had_parse_errors = false;

    if (config.null_input) {
        last_was_false_or_null = processNullInput(&cq, &writer, format, color, serialize_opts, ext_bindings, allocator) catch |e| {
            printErr("zq: ");
            printZqErr(e);
            return EXIT_SYSTEM;
        };
    } else if (config.slurp) {
        last_was_false_or_null = processSlurp(&config, &cq, &writer, format, color, serialize_opts, ext_bindings, allocator) catch |e| {
            printErr("zq: ");
            printZqErr(e);
            return EXIT_SYSTEM;
        };
    } else if (config.files.len == 0) {
        // Read from stdin using parallel pool.
        var src = io_mod.Source.init(std.fs.File.stdin(), allocator) catch |e| {
            printErr("zq: ");
            printZqErr(e);
            return EXIT_SYSTEM;
        };
        defer src.deinit();

        const n_threads = std.Thread.getCpuCount() catch 4;
        var pool = pool_mod.Pool.init(n_threads, allocator) catch |e| {
            printErr("zq: ");
            printZqErr(e);
            return EXIT_SYSTEM;
        };
        defer pool.deinit();

        pool.submit_stream(&src, &cq, format, color, serialize_opts, config.raw_input, ext_bindings);

        while (true) {
            const maybe = pool.collect_bytes() catch |e| {
                printErr("zq: ");
                printZqErr(e);
                had_parse_errors = true;
                continue;
            };
            const result = maybe orelse break;
            writer.writeSlice(result.data) catch {
                printErr("zq: write error\n");
                return EXIT_SYSTEM;
            };
            last_was_false_or_null = result.last_was_false_or_null;
        }
    } else {
        for (config.files) |path| {
            const file = openFile(path) catch {
                printErr("zq: could not open ");
                printErr(path);
                printErr("\n");
                return EXIT_SYSTEM;
            };
            defer file.close();

            last_was_false_or_null = processFile(file, &cq, &writer, format, color, serialize_opts, ext_bindings, allocator, config.raw_input) catch |e| {
                printErr("zq: ");
                printZqErr(e);
                return EXIT_SYSTEM;
            };
        }
    }

    writer.flush() catch {
        printErr("zq: write error\n");
        return EXIT_SYSTEM;
    };

    if (had_parse_errors) return EXIT_SYSTEM;
    if (config.exit_status and last_was_false_or_null) {
        return EXIT_FALSE;
    }
    return EXIT_OK;
}

/// Process a streaming source (stdin, pipe) single-threaded with a persistent
/// iterator that is reset() per JSONL record — zero allocations after the first.
fn processSource(
    file: std.fs.File,
    cq: *const query_mod.CompiledQuery,
    writer: *output_mod.Writer,
    format: types.Format,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    ext_bindings: []const query_mod.ExternalVarBinding,
    allocator: std.mem.Allocator,
    had_errors: *bool,
    raw_input: bool,
) !bool {
    _ = raw_input;
    var src = try io_mod.Source.init(file, allocator);
    defer src.deinit();

    var parser = try parser_mod.Parser.init(allocator);
    defer parser.deinit();

    // Persistent iterator: allocated once, reset() per JSONL record.
    var opt_it: ?query_mod.ResultIterator = null;
    defer if (opt_it) |*it| it.deinit();

    var last_was_false_or_null = false;

    // Initial refill for stream sources (ring buffer starts empty).
    _ = try src.refill();

    var fed_any = false;
    while (true) {
        const view = try src.peek();

        if (view.bytes.len == 0 and view.is_eof) {
            // If parser has pending state, finalize with empty eof feed.
            if (fed_any) {
                const result = parser.feed("", true) catch |e| {
                    printErr("zq: ");
                    printZqErr(e);
                    had_errors.* = true;
                    break;
                };
                switch (result) {
                    .done => |d| {
                        last_was_false_or_null = try writeRecord(cq, d.tape, &opt_it, writer, format, color, opts, ext_bindings, allocator);
                    },
                    .need_more => {},
                }
            }
            break;
        }

        if (view.bytes.len == 0) {
            _ = try src.refill();
            continue;
        }

        fed_any = true;
        const result = parser.feed(view.bytes, view.is_eof) catch |e| {
            // Parse error: report, skip to next record boundary (\n), and continue.
            printErr("zq: ");
            printZqErr(e);
            had_errors.* = true;
            // Skip past the next newline to re-sync on the next JSONL record.
            const skip = std.mem.indexOfScalar(u8, view.bytes, '\n') orelse view.bytes.len - 1;
            src.consume(skip + 1);
            parser.reset();
            fed_any = false;
            if (view.is_eof and skip + 1 >= view.bytes.len) break;
            continue;
        };

        switch (result) {
            .done => |d| {
                src.consume(d.consumed);
                last_was_false_or_null = try writeRecord(cq, d.tape, &opt_it, writer, format, color, opts, ext_bindings, allocator);
                parser.reset();
                fed_any = false;
            },
            .need_more => {
                src.consume(view.bytes.len);
                if (view.is_eof) break;
                _ = try src.refill();
            },
        }
    }

    return last_was_false_or_null;
}

/// Process a regular file in parallel using the worker Pool.
/// Uses all available CPU cores. Results are delivered in submission order.
fn processFile(
    file: std.fs.File,
    cq: *const query_mod.CompiledQuery,
    writer: *output_mod.Writer,
    format: types.Format,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    ext_bindings: []const query_mod.ExternalVarBinding,
    allocator: std.mem.Allocator,
    raw_input: bool,
) !bool {
    const n_threads = std.Thread.getCpuCount() catch 4;
    var pool = try pool_mod.Pool.init(n_threads, allocator);
    defer pool.deinit();

    try pool.submit_file(file, cq, format, color, opts, raw_input, ext_bindings);

    var last_was_false_or_null = false;
    while (try pool.collect_bytes()) |result| {
        try writer.writeSlice(result.data);
        last_was_false_or_null = result.last_was_false_or_null;
    }

    return last_was_false_or_null;
}

// ── Slurp Processing ─────────────────────────────────────────────────────────

fn processSlurp(
    config: *const Config,
    cq: *const query_mod.CompiledQuery,
    writer: *output_mod.Writer,
    format: types.Format,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    ext_bindings: []const query_mod.ExternalVarBinding,
    allocator: std.mem.Allocator,
) !bool {
    if (config.raw_input) {
        return processSlurpRaw(config, cq, writer, format, color, opts, ext_bindings, allocator);
    }
    return processSlurpJson(config, cq, writer, format, color, opts, ext_bindings, allocator);
}

/// Collect all parsed JSON values into a single array, then run the query once.
fn processSlurpJson(
    config: *const Config,
    cq: *const query_mod.CompiledQuery,
    writer: *output_mod.Writer,
    format: types.Format,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    ext_bindings: []const query_mod.ExternalVarBinding,
    allocator: std.mem.Allocator,
) !bool {
    var rt = try types.RuntimeTape.init(allocator);
    defer rt.deinit(allocator);

    // array_start with placeholder skip
    const arr_start = try rt.appendEntry(allocator, .{
        .tag = .array_start,
        .payload = .{ .skip = 0 },
    });

    var parser = try parser_mod.Parser.init(allocator);
    defer parser.deinit();

    if (config.files.len == 0) {
        try collectJsonValues(std.fs.File.stdin(), &rt, &parser, allocator);
    } else {
        for (config.files) |path| {
            const file = openFile(path) catch {
                printErr("zq: could not open ");
                printErr(path);
                printErr("\n");
                return error.IoError;
            };
            defer file.close();
            try collectJsonValues(file, &rt, &parser, allocator);
        }
    }

    // array_end
    const arr_end = try rt.appendEntry(allocator, .{
        .tag = .array_end,
        .payload = .{ .none = {} },
    });

    // Backfill skip pointer
    rt.entries.items[arr_start].payload.skip = arr_end + 1;

    const tape = rt.asTape();
    var opt_it: ?query_mod.ResultIterator = null;
    defer if (opt_it) |*it| it.deinit();
    return try writeRecord(cq, tape, &opt_it, writer, format, color, opts, ext_bindings, allocator);
}

/// Read all JSON values from a file/stdin using Source + Parser, copying each
/// parsed value into the RuntimeTape.
fn collectJsonValues(
    file: std.fs.File,
    rt: *types.RuntimeTape,
    parser: *parser_mod.Parser,
    allocator: std.mem.Allocator,
) !void {
    var src = try io_mod.Source.init(file, allocator);
    defer src.deinit();

    _ = try src.refill();

    var fed_any = false;
    while (true) {
        const view = try src.peek();

        if (view.bytes.len == 0 and view.is_eof) {
            if (fed_any) {
                const result = parser.feed("", true) catch return;
                switch (result) {
                    .done => |d| {
                        try copyTapeToRuntimeTape(rt, d.tape, allocator);
                    },
                    .need_more => {},
                }
            }
            break;
        }

        if (view.bytes.len == 0) {
            _ = try src.refill();
            continue;
        }

        fed_any = true;
        const result = parser.feed(view.bytes, view.is_eof) catch {
            const skip = std.mem.indexOfScalar(u8, view.bytes, '\n') orelse view.bytes.len - 1;
            src.consume(skip + 1);
            parser.reset();
            fed_any = false;
            if (view.is_eof and skip + 1 >= view.bytes.len) break;
            continue;
        };

        switch (result) {
            .done => |d| {
                src.consume(d.consumed);
                try copyTapeToRuntimeTape(rt, d.tape, allocator);
                parser.reset();
                fed_any = false;
            },
            .need_more => {
                src.consume(view.bytes.len);
                if (view.is_eof) break;
                _ = try src.refill();
            },
        }
    }
}

/// Copy a complete parsed tape into the RuntimeTape, re-interning strings and
/// rebasing skip pointers. Follows the pattern from vm.zig copyTapeSpanToRuntimeTape.
fn copyTapeToRuntimeTape(
    rt: *types.RuntimeTape,
    parsed: types.Tape,
    allocator: std.mem.Allocator,
) !void {
    try copyTapeSpan(rt, parsed, 0, @intCast(parsed.entries.len), allocator);
}

fn copyTapeSpan(
    rt: *types.RuntimeTape,
    tape: types.Tape,
    start: u32,
    end: u32,
    allocator: std.mem.Allocator,
) !void {
    var pos = start;
    while (pos < end) {
        const entry = tape.entries[pos];
        switch (entry.tag) {
            .object_start, .array_start => {
                const container_start = try rt.appendEntry(allocator, entry);
                const orig_skip = entry.payload.skip;
                // Copy content (excluding end marker)
                if (orig_skip > pos + 2) {
                    try copyTapeSpan(rt, tape, pos + 1, orig_skip - 1, allocator);
                }
                // Append end marker
                const new_end = try rt.appendEntry(allocator, .{
                    .tag = if (entry.tag == .object_start) .object_end else .array_end,
                    .payload = .{ .none = {} },
                });
                // Update skip pointer
                rt.entries.items[container_start].payload.skip = new_end + 1;
                pos = orig_skip;
            },
            .key, .string => {
                const str = tape.getString(entry.payload.string);
                const new_ref = try rt.internString(allocator, str);
                _ = try rt.appendEntry(allocator, .{
                    .tag = entry.tag,
                    .payload = .{ .string = new_ref },
                });
                pos += 1;
            },
            .object_end, .array_end => {
                // Skip end markers — handled by container start
                pos += 1;
            },
            else => {
                // Scalars: int, float, true_val, false_val, null_val
                _ = try rt.appendEntry(allocator, entry);
                pos += 1;
            },
        }
    }
}

/// Collect all raw bytes into one string, trim trailing newline, then run query
/// on a single string value (the -Rs path).
fn processSlurpRaw(
    config: *const Config,
    cq: *const query_mod.CompiledQuery,
    writer: *output_mod.Writer,
    format: types.Format,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    ext_bindings: []const query_mod.ExternalVarBinding,
    allocator: std.mem.Allocator,
) !bool {
    var text_buf = std.ArrayList(u8){};
    defer text_buf.deinit(allocator);

    if (config.files.len == 0) {
        try readAllBytes(std.fs.File.stdin(), &text_buf, allocator);
    } else {
        for (config.files) |path| {
            const file = openFile(path) catch {
                printErr("zq: could not open ");
                printErr(path);
                printErr("\n");
                return error.IoError;
            };
            defer file.close();
            try readAllBytes(file, &text_buf, allocator);
        }
    }

    // Trim trailing newline (jq compat: -Rs strips final \n)
    var len = text_buf.items.len;
    if (len > 0 and text_buf.items[len - 1] == '\n') {
        len -= 1;
    }

    // Build single-string tape
    var entry_buf: [1]types.Tape.Entry = .{.{
        .tag = .string,
        .payload = .{ .string = .{ .offset = 0, .len = @intCast(len) } },
    }};
    const tape = types.Tape{
        .entries = &entry_buf,
        .string_buf = text_buf.items[0..len],
    };

    var opt_it: ?query_mod.ResultIterator = null;
    defer if (opt_it) |*it| it.deinit();
    return try writeRecord(cq, tape, &opt_it, writer, format, color, opts, ext_bindings, allocator);
}

fn readAllBytes(
    file: std.fs.File,
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    var src = try io_mod.Source.init(file, allocator);
    defer src.deinit();

    _ = try src.refill();

    while (true) {
        const view = try src.peek();
        if (view.bytes.len == 0 and view.is_eof) break;
        if (view.bytes.len == 0) {
            _ = try src.refill();
            continue;
        }
        try buf.appendSlice(allocator, view.bytes);
        src.consume(view.bytes.len);
        if (view.is_eof) break;
        _ = try src.refill();
    }
}

fn processNullInput(
    cq: *const query_mod.CompiledQuery,
    writer: *output_mod.Writer,
    format: types.Format,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    ext_bindings: []const query_mod.ExternalVarBinding,
    allocator: std.mem.Allocator,
) !bool {
    var parser = try parser_mod.Parser.init(allocator);
    defer parser.deinit();

    const result = try parser.feed("null", true);
    const tape = switch (result) {
        .done => |d| d.tape,
        .need_more => return false,
    };

    var opt_it: ?query_mod.ResultIterator = null;
    defer if (opt_it) |*it| it.deinit();
    return try writeRecord(cq, tape, &opt_it, writer, format, color, opts, ext_bindings, allocator);
}

/// Execute the query against `tape` and write all output values.
/// On the first call, `opt_it.*` is null and the iterator is allocated.
/// On subsequent calls, the existing iterator is reset() to the new tape —
/// zero allocations after the first record.
fn writeRecord(
    cq: *const query_mod.CompiledQuery,
    tape: parser_mod.Tape,
    opt_it: *?query_mod.ResultIterator,
    writer: *output_mod.Writer,
    format: types.Format,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    ext_bindings: []const query_mod.ExternalVarBinding,
    allocator: std.mem.Allocator,
) !bool {
    if (opt_it.*) |*it| {
        it.reset(tape, ext_bindings);
    } else {
        opt_it.* = try cq.execute(tape, ext_bindings, allocator);
    }
    const it = &opt_it.*.?;

    var last_was_false_or_null = false;
    while (try it.next()) |val| {
        try writer.write_value(val, format, color, opts);
        if (format == .pretty or format == .compact) {
            try writer.write_value(.{ .string = "\n" }, .raw, null, .{});
        }
        last_was_false_or_null = switch (val) {
            .null_val => true,
            .bool_val => |b| !b,
            else => false,
        };
    }

    return last_was_false_or_null;
}

fn hasNoColor() bool {
    if (comptime @import("builtin").os.tag == .windows) {
        const key = std.unicode.utf8ToUtf16LeStringLiteral("NO_COLOR");
        const val = std.process.getenvW(key) orelse return false;
        return val.len > 0;
    } else {
        const val = std.posix.getenv("NO_COLOR") orelse return false;
        return val.len > 0;
    }
}

fn openFile(path: []const u8) !std.fs.File {
    return std.fs.cwd().openFile(path, .{}) catch return error.IoError;
}

// ── Arg Parsing ──────────────────────────────────────────────────────────────

fn parseArgs(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = Config{};
    config._allocator = allocator;
    var files = std.ArrayList([]const u8){};
    defer files.deinit(allocator);

    var owned_filter: ?[]u8 = null;
    var owned_ff_path: ?[]u8 = null;
    var owned_files = std.ArrayList([]u8){};
    var ext_vars = std.ArrayList(ExternalVar){};
    var ext_var_strs = std.ArrayList([]u8){};
    errdefer {
        for (owned_files.items) |f| allocator.free(f);
        owned_files.deinit(allocator);
        if (owned_filter) |f| allocator.free(f);
        if (owned_ff_path) |f| allocator.free(f);
        for (ext_var_strs.items) |s| allocator.free(s);
        ext_var_strs.deinit(allocator);
        ext_vars.deinit(allocator);
    }

    var i: usize = 1; // skip argv[0]
    var filter_set = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and arg[1] != '-') {
            // Short flags, possibly combined: -rc, -ecr, etc.
            // But some flags consume next arg (-f).
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'r' => config.format = .raw,
                    'c' => config.format = .compact,
                    'e' => config.exit_status = true,
                    'n' => config.null_input = true,
                    's' => config.slurp = true,
                    'S' => config.sort_keys = true,
                    'j' => config.join_output = true,
                    'C' => config.color = .on,
                    'M' => config.color = .off,
                    'R' => config.raw_input = true,
                    'f' => {
                        i += 1;
                        if (i >= args.len) {
                            printErr("zq: -f requires an argument\n");
                            return error.UsageError;
                        }
                        const duped = try allocator.dupe(u8, args[i]);
                        if (owned_ff_path) |old| allocator.free(old);
                        owned_ff_path = duped;
                        config.filter_file = duped;
                        filter_set = true;
                        break; // -f consumes rest of flag group
                    },
                    'h' => {
                        printUsage();
                        std.process.exit(EXIT_OK);
                    },
                    'V' => {
                        printVersion();
                        std.process.exit(EXIT_OK);
                    },
                    else => {
                        printErr("zq: unknown option: -");
                        printErrByte(arg[j]);
                        printErr("\n");
                        return error.UsageError;
                    },
                }
            }
        } else if (std.mem.eql(u8, arg, "--raw-output")) {
            config.format = .raw;
        } else if (std.mem.eql(u8, arg, "--compact-output")) {
            config.format = .compact;
        } else if (std.mem.eql(u8, arg, "--color-output")) {
            config.color = .on;
        } else if (std.mem.eql(u8, arg, "--monochrome-output")) {
            config.color = .off;
        } else if (std.mem.eql(u8, arg, "--exit-status")) {
            config.exit_status = true;
        } else if (std.mem.eql(u8, arg, "--null-input")) {
            config.null_input = true;
        } else if (std.mem.eql(u8, arg, "--raw-input")) {
            config.raw_input = true;
        } else if (std.mem.eql(u8, arg, "--slurp")) {
            config.slurp = true;
        } else if (std.mem.eql(u8, arg, "--sort-keys")) {
            config.sort_keys = true;
        } else if (std.mem.eql(u8, arg, "--join-output")) {
            config.join_output = true;
        } else if (std.mem.eql(u8, arg, "--tab")) {
            config.tab_indent = true;
        } else if (std.mem.eql(u8, arg, "--indent")) {
            i += 1;
            if (i >= args.len) {
                printErr("zq: --indent requires a number\n");
                return error.UsageError;
            }
            const n = std.fmt.parseInt(u8, args[i], 10) catch {
                printErr("zq: --indent: invalid number\n");
                return error.UsageError;
            };
            if (n > 8) {
                printErr("zq: --indent: value must be 0-8\n");
                return error.UsageError;
            }
            config.indent_width = n;
        } else if (std.mem.eql(u8, arg, "--arg")) {
            if (i + 2 >= args.len) {
                printErr("zq: --arg requires name and value\n");
                return error.UsageError;
            }
            i += 1;
            const name_duped = try allocator.dupe(u8, args[i]);
            try ext_var_strs.append(allocator, name_duped);
            i += 1;
            const val_duped = try allocator.dupe(u8, args[i]);
            try ext_var_strs.append(allocator, val_duped);
            try ext_vars.append(allocator, .{ .name = name_duped, .value = val_duped, .is_json = false });
        } else if (std.mem.eql(u8, arg, "--argjson")) {
            if (i + 2 >= args.len) {
                printErr("zq: --argjson requires name and value\n");
                return error.UsageError;
            }
            i += 1;
            const name_duped = try allocator.dupe(u8, args[i]);
            try ext_var_strs.append(allocator, name_duped);
            i += 1;
            const val_duped = try allocator.dupe(u8, args[i]);
            try ext_var_strs.append(allocator, val_duped);
            try ext_vars.append(allocator, .{ .name = name_duped, .value = val_duped, .is_json = true });
        } else if (std.mem.eql(u8, arg, "--from-file")) {
            i += 1;
            if (i >= args.len) {
                printErr("zq: --from-file requires a path\n");
                return error.UsageError;
            }
            const duped = try allocator.dupe(u8, args[i]);
            if (owned_ff_path) |old| allocator.free(old);
            owned_ff_path = duped;
            config.filter_file = duped;
            filter_set = true;
        } else if (std.mem.eql(u8, arg, "--jsonargs") or std.mem.eql(u8, arg, "--args")) {
            printErr("zq: ");
            printErr(arg);
            printErr(" not yet implemented\n");
            return error.UsageError;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(EXIT_OK);
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            std.process.exit(EXIT_OK);
        } else if (std.mem.eql(u8, arg, "--")) {
            // Everything after -- is positional.
            i += 1;
            while (i < args.len) : (i += 1) {
                if (!filter_set) {
                    const duped = try allocator.dupe(u8, args[i]);
                    if (owned_filter) |old| allocator.free(old);
                    owned_filter = duped;
                    config.filter = duped;
                    filter_set = true;
                } else {
                    const duped = try allocator.dupe(u8, args[i]);
                    try owned_files.append(allocator, duped);
                    try files.append(allocator, duped);
                }
            }
            break;
        } else if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            printErr("zq: unknown option: ");
            printErr(arg);
            printErr("\n");
            return error.UsageError;
        } else {
            // Positional: first is filter, rest are files.
            if (!filter_set) {
                const duped = try allocator.dupe(u8, arg);
                if (owned_filter) |old| allocator.free(old);
                owned_filter = duped;
                config.filter = duped;
                filter_set = true;
            } else {
                const duped = try allocator.dupe(u8, arg);
                try owned_files.append(allocator, duped);
                try files.append(allocator, duped);
            }
        }
    }

    // Transfer ownership to config.
    config._owned_filter = owned_filter;
    config._owned_filter_file_path = owned_ff_path;
    if (owned_files.items.len > 0) {
        config._owned_file_strs = try owned_files.toOwnedSlice(allocator);
    } else {
        owned_files.deinit(allocator);
    }
    if (files.items.len > 0) {
        const file_list = try allocator.dupe([]const u8, files.items);
        config.files = file_list;
        config._owned_file_list = file_list;
    }
    if (ext_vars.items.len > 0) {
        config._owned_ext_vars = try ext_vars.toOwnedSlice(allocator);
        config.external_vars = config._owned_ext_vars.?;
        config._owned_ext_var_strs = try ext_var_strs.toOwnedSlice(allocator);
    } else {
        ext_vars.deinit(allocator);
        ext_var_strs.deinit(allocator);
    }

    return config;
}

// ── Error Output Helpers ─────────────────────────────────────────────────────

fn printVersion() void {
    printErr("zq " ++ build_options.version ++ "\n");
}

fn printErr(msg: []const u8) void {
    std.fs.File.stderr().writeAll(msg) catch {};
}

fn printErrByte(b: u8) void {
    std.fs.File.stderr().writeAll(&[1]u8{b}) catch {};
}

fn printZqErr(e: anyerror) void {
    const msg: []const u8 = switch (e) {
        error.UnexpectedToken => "unexpected token\n",
        error.UnexpectedEof => "unexpected end of input\n",
        error.InvalidUtf8 => "invalid UTF-8\n",
        error.InvalidNumber => "invalid number\n",
        error.UnterminatedString => "unterminated string\n",
        error.DepthLimitExceeded => "depth limit exceeded\n",
        error.IoError => "I/O error\n",
        error.QuerySyntaxError => "query syntax error\n",
        error.TypeError => "type error\n",
        error.IndexOutOfBounds => "index out of bounds\n",
        error.OutOfMemory => "out of memory\n",
        else => "unknown error\n",
    };
    printErr(msg);
}

fn printUsage() void {
    printErr(
        \\Usage: zq [OPTIONS] <FILTER> [FILE...]
        \\
        \\A high-performance JSON processor.
        \\
        \\Options:
        \\  -r, --raw-output      Output raw strings (no quotes)
        \\  -R, --raw-input       Read each line as raw string
        \\  -c, --compact-output  Compact JSON output
        \\  -e, --exit-status     Exit 1 if last output is false/null
        \\  -n, --null-input      Use null as input
        \\  -s, --slurp           Read all inputs into array
        \\  -S, --sort-keys       Sort object keys
        \\  -j, --join-output     No newline after each output
        \\  -C, --color-output    Force colorized output
        \\  -M, --monochrome-output  Disable colorized output
        \\  -f, --from-file FILE  Read filter from file
        \\  --tab                 Use tab for indentation
        \\  --indent N            Use N spaces for indentation
        \\  --arg NAME VALUE      Set $NAME to string VALUE
        \\  --argjson NAME VALUE  Set $NAME to parsed JSON VALUE
        \\  --args                Remaining args are string values
        \\  --jsonargs            Remaining args are JSON values
        \\  -h, --help            Print this help
        \\  -V, --version         Print version
        \\
        \\Examples:
        \\  echo '{"a":1}' | zq '.a'
        \\  zq '.[] | .name' data.json
        \\  zq -c '.' input.json
        \\
    );
}
