const std = @import("std");
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
    filter_file: ?[]const u8 = null,
    // --arg/--argjson deferred until query VM supports variables

    // Owned allocations to free on cleanup.
    _owned_filter: ?[]u8 = null,
    _owned_file_strs: [][]u8 = &.{},
    _owned_file_list: ?[]const []const u8 = null,
    _allocator: ?std.mem.Allocator = null,

    fn deinit(self: *Config) void {
        const alloc = self._allocator orelse return;
        if (self._owned_filter) |f| alloc.free(f);
        for (self._owned_file_strs) |f| alloc.free(f);
        if (self._owned_file_strs.len > 0) alloc.free(self._owned_file_strs);
        if (self._owned_file_list) |f| alloc.free(f);
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
            _ = path;
            printErr("zq: --from-file not yet implemented\n");
            return EXIT_USAGE;
        }
        break :blk config.filter orelse {
            printErr("zq: no filter provided\n");
            printUsage();
            return EXIT_USAGE;
        };
    };

    if (config.raw_input) {
        printErr("zq: --raw-input not yet implemented\n");
        return EXIT_USAGE;
    }
    if (config.slurp) {
        printErr("zq: --slurp not yet implemented\n");
        return EXIT_USAGE;
    }
    if (config.sort_keys) {
        printErr("zq: --sort-keys not yet implemented\n");
        return EXIT_USAGE;
    }

    // Compile query.
    var cq = query_mod.CompiledQuery.compile(filter_src, .{}, allocator) catch |e| {
        printErr("zq: compile error: ");
        printZqErr(e);
        return EXIT_USAGE;
    };
    defer cq.deinit();

    // Set up output writer on stdout.
    const stdout_fd = std.posix.STDOUT_FILENO;
    var writer = output_mod.Writer.init(stdout_fd, allocator) catch {
        printErr("zq: out of memory\n");
        return EXIT_SYSTEM;
    };
    defer writer.deinit();

    // Pick format: if stdout is TTY and no explicit format flag, use pretty.
    const format = config.format;

    var last_was_false_or_null = false;
    var had_parse_errors = false;

    if (config.null_input) {
        last_was_false_or_null = processNullInput(&cq, &writer, format, allocator) catch |e| {
            printErr("zq: ");
            printZqErr(e);
            return EXIT_SYSTEM;
        };
    } else if (config.files.len == 0) {
        // Read from stdin.
        const stdin_fd = std.posix.STDIN_FILENO;
        last_was_false_or_null = processSource(stdin_fd, &cq, &writer, format, allocator, &had_parse_errors) catch |e| {
            printErr("zq: ");
            printZqErr(e);
            return EXIT_SYSTEM;
        };
    } else {
        for (config.files) |path| {
            const fd = openFile(path) catch {
                printErr("zq: could not open ");
                printErr(path);
                printErr("\n");
                return EXIT_SYSTEM;
            };
            defer std.posix.close(fd);

            last_was_false_or_null = processFile(fd, &cq, &writer, format, allocator) catch |e| {
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
    fd: std.posix.fd_t,
    cq: *const query_mod.CompiledQuery,
    writer: *output_mod.Writer,
    format: types.Format,
    allocator: std.mem.Allocator,
    had_errors: *bool,
) !bool {
    var src = try io_mod.Source.init(fd, allocator);
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
                        last_was_false_or_null = try writeRecord(cq, d.tape, &opt_it, writer, format, allocator);
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
                last_was_false_or_null = try writeRecord(cq, d.tape, &opt_it, writer, format, allocator);
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
    fd: std.posix.fd_t,
    cq: *const query_mod.CompiledQuery,
    writer: *output_mod.Writer,
    format: types.Format,
    allocator: std.mem.Allocator,
) !bool {
    const n_threads = std.Thread.getCpuCount() catch 4;
    var pool = try pool_mod.Pool.init(n_threads, allocator);
    defer pool.deinit();

    try pool.submit_file(fd, cq);

    var last_was_false_or_null = false;
    while (try pool.collect()) |result| {
        const val = result.value;
        try writer.write_value(val, format);
        if (format == .pretty or format == .compact) {
            try writer.write_value(.{ .string = "\n" }, .raw);
        }
        last_was_false_or_null = switch (val) {
            .null_val => true,
            .bool_val => |b| !b,
            else => false,
        };
    }

    return last_was_false_or_null;
}

fn processNullInput(
    cq: *const query_mod.CompiledQuery,
    writer: *output_mod.Writer,
    format: types.Format,
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
    return try writeRecord(cq, tape, &opt_it, writer, format, allocator);
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
    allocator: std.mem.Allocator,
) !bool {
    if (opt_it.*) |*it| {
        it.reset(tape);
    } else {
        opt_it.* = try cq.execute(tape, allocator);
    }
    const it = &opt_it.*.?;

    var last_was_false_or_null = false;
    while (try it.next()) |val| {
        try writer.write_value(val, format);
        if (format == .pretty or format == .compact) {
            try writer.write_value(.{ .string = "\n" }, .raw);
        }
        last_was_false_or_null = switch (val) {
            .null_val => true,
            .bool_val => |b| !b,
            else => false,
        };
    }

    return last_was_false_or_null;
}

fn openFile(path: []const u8) !std.posix.fd_t {
    const file = std.fs.cwd().openFile(path, .{}) catch return error.IoError;
    return file.handle;
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
    var owned_files = std.ArrayList([]u8){};
    errdefer {
        for (owned_files.items) |f| allocator.free(f);
        owned_files.deinit(allocator);
        if (owned_filter) |f| allocator.free(f);
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
                    'R' => config.raw_input = true,
                    'f' => {
                        i += 1;
                        if (i >= args.len) {
                            printErr("zq: -f requires an argument\n");
                            return error.UsageError;
                        }
                        const duped = try allocator.dupe(u8, args[i]);
                        if (owned_filter) |old| allocator.free(old);
                        owned_filter = duped;
                        config.filter_file = duped;
                        break; // -f consumes rest of flag group
                    },
                    'h' => {
                        printUsage();
                        std.process.exit(EXIT_OK);
                    },
                    'V' => {
                        printErr("zq 0.1.0\n");
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
            // Store as format hint; output module doesn't support tab yet.
            printErr("zq: --tab not yet implemented\n");
            return error.UsageError;
        } else if (std.mem.eql(u8, arg, "--indent")) {
            i += 1;
            if (i >= args.len) {
                printErr("zq: --indent requires a number\n");
                return error.UsageError;
            }
            printErr("zq: --indent not yet implemented\n");
            return error.UsageError;
        } else if (std.mem.eql(u8, arg, "--arg")) {
            i += 2; // skip name and value
            if (i >= args.len) {
                printErr("zq: --arg requires name and value\n");
                return error.UsageError;
            }
            printErr("zq: --arg not yet implemented\n");
            return error.UsageError;
        } else if (std.mem.eql(u8, arg, "--argjson")) {
            i += 2;
            if (i >= args.len) {
                printErr("zq: --argjson requires name and value\n");
                return error.UsageError;
            }
            printErr("zq: --argjson not yet implemented\n");
            return error.UsageError;
        } else if (std.mem.eql(u8, arg, "--from-file")) {
            i += 1;
            if (i >= args.len) {
                printErr("zq: --from-file requires a path\n");
                return error.UsageError;
            }
            const duped = try allocator.dupe(u8, args[i]);
            if (owned_filter) |old| allocator.free(old);
            owned_filter = duped;
            config.filter_file = duped;
        } else if (std.mem.eql(u8, arg, "--jsonargs") or std.mem.eql(u8, arg, "--args")) {
            printErr("zq: ");
            printErr(arg);
            printErr(" not yet implemented\n");
            return error.UsageError;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(EXIT_OK);
        } else if (std.mem.eql(u8, arg, "--version")) {
            printErr("zq 0.1.0\n");
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

    return config;
}

// ── Error Output Helpers ─────────────────────────────────────────────────────

fn printErr(msg: []const u8) void {
    _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
}

fn printErrByte(b: u8) void {
    _ = std.posix.write(std.posix.STDERR_FILENO, &.{b}) catch {};
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
