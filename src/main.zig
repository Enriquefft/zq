const std = @import("std");
const build_options = @import("build_options");
const io_mod = @import("io");
const parser_mod = @import("parser");
const query_mod = @import("query");
const output_mod = @import("output");
const pool_mod = @import("pool");
const describe_mod = @import("describe");
const types = @import("types");
const err_mod = @import("error");

const EXIT_OK = 0;
const EXIT_FALSE = 1; // -e: last output was false/null
const EXIT_USAGE = 2;
const EXIT_COMPILE = 3; // filter syntax/compilation error
const EXIT_RUNTIME = 4; // TypeError, IndexOutOfBounds, UserError during query execution
const EXIT_SYSTEM = 5; // OOM, I/O error, write failure

/// Source classification for an external variable binding.
/// Drives binding construction in main.zig: `string`/`json` carry the literal
/// VALUE from argv; `slurpfile`/`rawfile` carry a filesystem path that must
/// be loaded before binding. Replaces the old `is_json: bool` discriminant
/// so adding new flag-driven sources is a one-arm extension.
const ExternalVarKind = enum { string, json, slurpfile, rawfile };

const ExternalVar = struct {
    name: []const u8,
    /// For `.string`/`.json`: the raw VALUE token from argv.
    /// For `.slurpfile`/`.rawfile`: the FILE path.
    value: []const u8,
    kind: ExternalVarKind,
};

const Config = struct {
    filter: ?[]const u8 = null,
    files: []const []const u8 = &.{},
    style: types.OutputStyle = .{},
    exit_status: bool = false,
    null_input: bool = false,
    raw_input: bool = false,
    slurp: bool = false,
    sort_keys: bool = false,
    tab_indent: bool = false,
    indent_width: u8 = 2,
    color: enum { auto, on, off } = .auto,
    filter_file: ?[]const u8 = null,
    external_vars: []const ExternalVar = &.{},
    positional_args: []const []const u8 = &.{},
    positional_is_json: bool = false,
    json_errors: bool = false,
    describe: bool = false,
    describe_depth: u32 = 12,
    validate: bool = false,
    lsp_mode: bool = false,
    /// --unbuffered: flush stdout after every emitted value. Matches jq's
    /// flag of the same name. Pool-based execution still batches across
    /// chunks, but each `BytesResult` (stdin/file pool) and each per-value
    /// emit (null-input / slurp) is followed by an explicit flush.
    unbuffered: bool = false,

    // Owned allocations to free on cleanup.
    _owned_positional_strs: [][]u8 = &.{},
    _owned_positional_list: ?[]const []const u8 = null,
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
        for (self._owned_positional_strs) |s| alloc.free(s);
        if (self._owned_positional_strs.len > 0) alloc.free(self._owned_positional_strs);
        if (self._owned_positional_list) |l| alloc.free(l);
    }
};

/// Consolidated diagnostic context for query errors.
/// Replaces scattered out-parameters (last_error_ip, etc.).
const QueryDiag = struct {
    last_ip: u32 = 0,
    user_error_msg: ?[]const u8 = null,
    /// When true, `user_error_msg` was allocated by the caller's allocator and
    /// the consumer must free it. Set by code paths (e.g. pool file-arg mode)
    /// where the original message pointer outlives its arena only after a copy.
    user_error_msg_owned: bool = false,
    error_kind: ?err_mod.ErrorKind = null,

    fn deinit(d: *QueryDiag, allocator: std.mem.Allocator) void {
        if (d.user_error_msg_owned) {
            if (d.user_error_msg) |s| allocator.free(s);
            d.user_error_msg_owned = false;
            d.user_error_msg = null;
        }
    }
};

/// Map an ErrorKind to the appropriate exit code.
///
/// Bucket rationale (single source of truth for the zq exit-code contract):
///   - `EXIT_COMPILE`  — the user's filter or build environment cannot run
///     the query as written. `regex_compile_error` (bad pattern) is obvious.
///     `regex_not_compiled` also lands here even when it fires at runtime
///     (dynamic pattern in a `-Dregex=false` build): the failure root-cause
///     is build-configuration, not runtime data. The user cannot recover by
///     changing input — they recover by rebuilding with regex enabled. That
///     makes it a compile-surface class of failure, not a data-runtime one.
///   - `EXIT_RUNTIME` — the filter compiled and the build supports the
///     operation, but the runtime data tripped a jq-level semantic error
///     (type mismatch, index OOB, user-raised `error`, regex-engine
///     internal failure). These can be caught with `try`/`?`.
///   - `EXIT_SYSTEM`  — the process itself failed at a lower layer
///     (tokenization, number parsing, I/O, OOM, depth-limit). Not
///     recoverable from the filter; operational issue.
fn exitCodeForKind(kind: err_mod.ErrorKind) u8 {
    return switch (kind) {
        .query_syntax_error, .regex_compile_error, .regex_not_compiled => EXIT_COMPILE,
        .type_error, .index_out_of_bounds, .user_error, .regex_internal_error => EXIT_RUNTIME,
        .unexpected_token, .unexpected_eof, .invalid_utf8, .invalid_number, .unterminated_string, .depth_limit_exceeded, .io_error, .out_of_memory => EXIT_SYSTEM,
    };
}

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

    if (config.lsp_mode) {
        const lsp_mod = @import("lsp");
        if (comptime !lsp_mod.enabled) {
            printErr("zq: --lsp is not available in this build (compiled with -Dlsp=false).\n");
            return EXIT_USAGE;
        }
        lsp_mod.run(allocator) catch return EXIT_SYSTEM;
        return EXIT_OK;
    }

    if (config.validate) {
        return processValidate(&config, allocator);
    }

    if (config.describe) {
        return processDescribe(&config, allocator);
    }

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
        break :blk config.filter orelse ".";
    };

    // Build external variable declarations for compile.
    var ext_decls_buf = allocator.alloc(query_mod.ExternalVarDecl, config.external_vars.len + 1) catch {
        printErr("zq: out of memory\n");
        return EXIT_SYSTEM;
    };
    defer allocator.free(ext_decls_buf);
    for (config.external_vars, 0..) |ev, i| {
        ext_decls_buf[i] = .{ .name = ev.name };
    }
    ext_decls_buf[config.external_vars.len] = .{ .name = "ARGS" };

    // Compile query.
    const stderr_writer = StderrWriter{};
    const compile_result = query_mod.CompiledQuery.compile(filter_src, .{
        .external_vars = ext_decls_buf,
    }, allocator) catch {
        printErr("zq: out of memory\n");
        return EXIT_SYSTEM;
    };
    var cq = switch (compile_result) {
        .ok => |compiled| compiled,
        .err => |ce| {
            err_mod.formatDiagnostic(stderr_writer, filter_src, ce.kind, ce.offset, ce.len, null, null, allocator, if (config.json_errors) .json else .text);
            return EXIT_COMPILE;
        },
    };
    defer cq.deinit();

    // Build external variable bindings after compile (var_ids are now known).
    var ext_bindings_buf = allocator.alloc(query_mod.ExternalVarBinding, config.external_vars.len + 1) catch {
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

    var args_obj_start: u32 = 0;

    {
        // Temporary parser for --argjson and --slurpfile values.
        var argjson_parser = parser_mod.Parser.init(allocator) catch {
            printErr("zq: out of memory\n");
            return EXIT_SYSTEM;
        };
        defer argjson_parser.deinit();

        for (config.external_vars, 0..) |ev, i| {
            switch (ev.kind) {
                .json => {
                    // --argjson: parse the JSON value
                    const parse_result = argjson_parser.feed(ev.value, true) catch {
                        printErr("zq: --argjson: invalid JSON for $");
                        printErr(ev.name);
                        printErr("\n");
                        return EXIT_USAGE;
                    };
                    const tape = switch (parse_result) {
                        .done => |d| blk: {
                            if (std.mem.trim(u8, ev.value[d.consumed..], " \t\r\n").len != 0) {
                                printErr("zq: --argjson: trailing garbage for $");
                                printErr(ev.name);
                                printErr("\n");
                                return EXIT_USAGE;
                            }
                            break :blk d.tape;
                        },
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
                            argjson_rt.copyFrom(tape, allocator) catch {
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
                },
                .slurpfile => {
                    // --slurpfile: read FILE; wrap top-level values into one array.
                    const rt_start = loadSlurpfile(ev.value, &argjson_rt, &argjson_parser, ev.name, allocator) catch |e| switch (e) {
                        error.OutOfMemory => {
                            printErr("zq: out of memory\n");
                            return EXIT_SYSTEM;
                        },
                        error.UsageError => return EXIT_USAGE,
                    };
                    ext_bindings_buf[i] = .{ .var_id = cq.external_var_ids[i], .value = .null_val };
                    compound_refs.append(allocator, .{ .idx = i, .rt_start = rt_start }) catch {
                        printErr("zq: out of memory\n");
                        return EXIT_SYSTEM;
                    };
                },
                .rawfile => {
                    // --rawfile: read FILE bytes verbatim into a JSON string.
                    const rt_start = loadRawfile(ev.value, &argjson_rt, ev.name, allocator) catch |e| switch (e) {
                        error.OutOfMemory => {
                            printErr("zq: out of memory\n");
                            return EXIT_SYSTEM;
                        },
                        error.UsageError => return EXIT_USAGE,
                    };
                    ext_bindings_buf[i] = .{ .var_id = cq.external_var_ids[i], .value = .null_val };
                    compound_refs.append(allocator, .{ .idx = i, .rt_start = rt_start }) catch {
                        printErr("zq: out of memory\n");
                        return EXIT_SYSTEM;
                    };
                },
                .string => {
                    // --arg: string value
                    ext_bindings_buf[i] = .{
                        .var_id = cq.external_var_ids[i],
                        .value = .{ .tape_value = .{ .string = .{ .external = ev.value } } },
                    };
                },
            }
        }

        // Build $ARGS = {"positional": [...], "named": {...}} into argjson_rt.
        args_obj_start = @intCast(argjson_rt.entries.items.len);
        {
            // outer object_start
            _ = argjson_rt.appendEntry(allocator, .{ .tag = .object_start, .payload = .{ .skip = 0 } }) catch {
                printErr("zq: out of memory\n");
                return EXIT_SYSTEM;
            };

            // key "positional"
            const pos_key_ref = argjson_rt.internString(allocator, "positional") catch {
                printErr("zq: out of memory\n");
                return EXIT_SYSTEM;
            };
            _ = argjson_rt.appendEntry(allocator, .{ .tag = .key, .payload = .{ .string = pos_key_ref } }) catch {
                printErr("zq: out of memory\n");
                return EXIT_SYSTEM;
            };

            // array_start for positional
            const pos_arr_start: u32 = @intCast(argjson_rt.entries.items.len);
            _ = argjson_rt.appendEntry(allocator, .{ .tag = .array_start, .payload = .{ .skip = 0 } }) catch {
                printErr("zq: out of memory\n");
                return EXIT_SYSTEM;
            };

            // Populate positional args
            for (config.positional_args) |pa| {
                if (config.positional_is_json) {
                    // --jsonargs: parse each positional arg as JSON
                    const parse_result = argjson_parser.feed(pa, true) catch {
                        printErr("zq: --jsonargs: invalid JSON: ");
                        printErr(pa);
                        printErr("\n");
                        return EXIT_USAGE;
                    };
                    const tape = switch (parse_result) {
                        .done => |d| blk: {
                            if (std.mem.trim(u8, pa[d.consumed..], " \t\r\n").len != 0) {
                                printErr("zq: --jsonargs: trailing garbage: ");
                                printErr(pa);
                                printErr("\n");
                                return EXIT_USAGE;
                            }
                            break :blk d.tape;
                        },
                        .need_more => {
                            printErr("zq: --jsonargs: incomplete JSON: ");
                            printErr(pa);
                            printErr("\n");
                            return EXIT_USAGE;
                        },
                    };
                    // Copy parsed value into argjson_rt
                    argjson_rt.copyFrom(tape, allocator) catch {
                        printErr("zq: out of memory\n");
                        return EXIT_SYSTEM;
                    };
                    argjson_parser.reset();
                } else {
                    // --args: store as string
                    const str_ref = argjson_rt.internString(allocator, pa) catch {
                        printErr("zq: out of memory\n");
                        return EXIT_SYSTEM;
                    };
                    _ = argjson_rt.appendEntry(allocator, .{ .tag = .string, .payload = .{ .string = str_ref } }) catch {
                        printErr("zq: out of memory\n");
                        return EXIT_SYSTEM;
                    };
                }
            }

            // array_end for positional
            const pos_arr_end: u32 = @intCast(argjson_rt.entries.items.len);
            _ = argjson_rt.appendEntry(allocator, .{ .tag = .array_end, .payload = .{ .none = {} } }) catch {
                printErr("zq: out of memory\n");
                return EXIT_SYSTEM;
            };
            argjson_rt.entries.items[pos_arr_start].payload.skip = pos_arr_end + 1;

            // key "named"
            const named_key_ref = argjson_rt.internString(allocator, "named") catch {
                printErr("zq: out of memory\n");
                return EXIT_SYSTEM;
            };
            _ = argjson_rt.appendEntry(allocator, .{ .tag = .key, .payload = .{ .string = named_key_ref } }) catch {
                printErr("zq: out of memory\n");
                return EXIT_SYSTEM;
            };

            // object_start for named
            const named_obj_start: u32 = @intCast(argjson_rt.entries.items.len);
            _ = argjson_rt.appendEntry(allocator, .{ .tag = .object_start, .payload = .{ .skip = 0 } }) catch {
                printErr("zq: out of memory\n");
                return EXIT_SYSTEM;
            };

            // Populate named args from --arg / --argjson / --slurpfile / --rawfile.
            // Mirrors per-binding semantics from the loop above; later-wins for
            // duplicate names falls out of map-style key emission (jq drops the
            // earlier key when serialised, but we mirror the source order — the
            // VM resolves $NAME via var_id, which already implements last-wins).
            for (config.external_vars) |ev| {
                // key
                const k_ref = argjson_rt.internString(allocator, ev.name) catch {
                    printErr("zq: out of memory\n");
                    return EXIT_SYSTEM;
                };
                _ = argjson_rt.appendEntry(allocator, .{ .tag = .key, .payload = .{ .string = k_ref } }) catch {
                    printErr("zq: out of memory\n");
                    return EXIT_SYSTEM;
                };
                switch (ev.kind) {
                    .json => {
                        // Parse and copy into RT
                        const parse_result = argjson_parser.feed(ev.value, true) catch {
                            // Already validated during binding construction, but handle gracefully
                            _ = argjson_rt.appendEntry(allocator, .{ .tag = .null_val, .payload = .{ .none = {} } }) catch {};
                            continue;
                        };
                        const tape = switch (parse_result) {
                            .done => |d| blk: {
                                if (std.mem.trim(u8, ev.value[d.consumed..], " \t\r\n").len != 0) {
                                    _ = argjson_rt.appendEntry(allocator, .{ .tag = .null_val, .payload = .{ .none = {} } }) catch {};
                                    argjson_parser.reset();
                                    continue;
                                }
                                break :blk d.tape;
                            },
                            .need_more => {
                                _ = argjson_rt.appendEntry(allocator, .{ .tag = .null_val, .payload = .{ .none = {} } }) catch {};
                                continue;
                            },
                        };
                        argjson_rt.copyFrom(tape, allocator) catch {
                            printErr("zq: out of memory\n");
                            return EXIT_SYSTEM;
                        };
                        argjson_parser.reset();
                    },
                    .slurpfile => {
                        // Re-load — first load already succeeded, so file open
                        // failure here is a TOCTOU race; degrade to null rather
                        // than abort the query that's already partially set up.
                        _ = loadSlurpfile(ev.value, &argjson_rt, &argjson_parser, ev.name, allocator) catch |e| switch (e) {
                            error.OutOfMemory => {
                                printErr("zq: out of memory\n");
                                return EXIT_SYSTEM;
                            },
                            error.UsageError => {
                                _ = argjson_rt.appendEntry(allocator, .{ .tag = .null_val, .payload = .{ .none = {} } }) catch {};
                                continue;
                            },
                        };
                    },
                    .rawfile => {
                        _ = loadRawfile(ev.value, &argjson_rt, ev.name, allocator) catch |e| switch (e) {
                            error.OutOfMemory => {
                                printErr("zq: out of memory\n");
                                return EXIT_SYSTEM;
                            },
                            error.UsageError => {
                                _ = argjson_rt.appendEntry(allocator, .{ .tag = .null_val, .payload = .{ .none = {} } }) catch {};
                                continue;
                            },
                        };
                    },
                    .string => {
                        // String value
                        const v_ref = argjson_rt.internString(allocator, ev.value) catch {
                            printErr("zq: out of memory\n");
                            return EXIT_SYSTEM;
                        };
                        _ = argjson_rt.appendEntry(allocator, .{ .tag = .string, .payload = .{ .string = v_ref } }) catch {
                            printErr("zq: out of memory\n");
                            return EXIT_SYSTEM;
                        };
                    },
                }
            }

            // object_end for named
            const named_obj_end: u32 = @intCast(argjson_rt.entries.items.len);
            _ = argjson_rt.appendEntry(allocator, .{ .tag = .object_end, .payload = .{ .none = {} } }) catch {
                printErr("zq: out of memory\n");
                return EXIT_SYSTEM;
            };
            argjson_rt.entries.items[named_obj_start].payload.skip = named_obj_end + 1;

            // outer object_end
            const args_obj_end: u32 = @intCast(argjson_rt.entries.items.len);
            _ = argjson_rt.appendEntry(allocator, .{ .tag = .object_end, .payload = .{ .none = {} } }) catch {
                printErr("zq: out of memory\n");
                return EXIT_SYSTEM;
            };
            argjson_rt.entries.items[args_obj_start].payload.skip = args_obj_end + 1;
        }
    }

    // Build the stable tape view from the RuntimeTape and resolve compound bindings.
    var argjson_tape_view = argjson_rt.asTape();
    for (compound_refs.items) |ref| {
        const rt_entry = argjson_tape_view.entries[ref.rt_start];
        ext_bindings_buf[ref.idx].value = switch (rt_entry.tag) {
            .string => .{ .tape_value = .{ .string = .{ .tape_ref = .{ .tape = &argjson_tape_view, .ref = rt_entry.payload.string } } } },
            .big_number => .{ .big_number = argjson_tape_view.getString(rt_entry.payload.string) },
            .array_start => .{ .tape_value = .{ .array = .{ .tape = &argjson_tape_view, .start = ref.rt_start, .end = rt_entry.payload.skip } } },
            .object_start => .{ .tape_value = .{ .object = .{ .tape = &argjson_tape_view, .start = ref.rt_start, .end = rt_entry.payload.skip } } },
            else => .null_val,
        };
    }

    // Bind $ARGS to the object we just built.
    {
        const args_var_id = cq.external_var_ids[config.external_vars.len];
        const args_entry = argjson_tape_view.entries[args_obj_start];
        ext_bindings_buf[config.external_vars.len] = .{
            .var_id = args_var_id,
            .value = .{ .tape_value = .{ .object = .{
                .tape = &argjson_tape_view,
                .start = args_obj_start,
                .end = args_entry.payload.skip,
            } } },
        };
    }
    const ext_bindings: []const query_mod.ExternalVarBinding = ext_bindings_buf;

    // Set up output writer on stdout.
    var writer = output_mod.Writer.init(std.fs.File.stdout(), allocator) catch {
        printErr("zq: out of memory\n");
        return EXIT_SYSTEM;
    };
    defer writer.deinit();

    const style: types.OutputStyle = config.style;

    const serialize_opts = output_mod.SerializeOpts{
        .sort_keys = config.sort_keys,
        .indent = if (config.tab_indent) .tab else .{ .spaces = config.indent_width },
        .allocator = allocator,
    };

    const color: ?*const output_mod.Color = switch (config.color) {
        .on => &output_mod.default_colors,
        .off => null,
        .auto => if (writer.is_tty() and !hasNoColor()) &output_mod.default_colors else null,
    };

    var last_was_false_or_null = false;
    var had_parse_errors = false;
    var pool_error_exit: ?u8 = null;

    const diag_format: err_mod.DiagnosticFormat = if (config.json_errors) .json else .text;

    if (config.null_input) {
        var diag = QueryDiag{};
        last_was_false_or_null = processNullInput(&cq, &writer, style, color, serialize_opts, ext_bindings, allocator, config.unbuffered, &diag) catch |e| {
            const kind = err_mod.kindFromZqError(@errorCast(e));
            const src_offset = if (diag.last_ip < cq.source_map.len) cq.source_map[diag.last_ip] else 0;
            err_mod.formatDiagnostic(stderr_writer, filter_src, kind, src_offset, 0, null, diag.user_error_msg, allocator, diag_format);
            return exitCodeForKind(kind);
        };
    } else if (config.slurp) {
        var diag = QueryDiag{};
        last_was_false_or_null = processSlurp(&config, &cq, &writer, style, color, serialize_opts, ext_bindings, allocator, &had_parse_errors, &diag) catch |e| {
            const kind = err_mod.kindFromZqError(@errorCast(e));
            const src_offset = if (diag.last_ip < cq.source_map.len) cq.source_map[diag.last_ip] else 0;
            err_mod.formatDiagnostic(stderr_writer, filter_src, kind, src_offset, 0, null, diag.user_error_msg, allocator, diag_format);
            return exitCodeForKind(kind);
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
        const budget = pool_mod.MemoryBudget.detect();
        var pool = pool_mod.Pool.init(n_threads, budget, allocator) catch |e| {
            printErr("zq: ");
            printZqErr(e);
            return EXIT_SYSTEM;
        };
        defer pool.deinit();

        pool.submit_stream(&src, &cq, style, color, serialize_opts, config.raw_input, ext_bindings);

        while (true) {
            const maybe = pool.collect_bytes() catch |e| {
                const kind = err_mod.kindFromZqError(@errorCast(e));
                const src_offset = if (pool.last_error_ip < cq.source_map.len) cq.source_map[pool.last_error_ip] else 0;
                err_mod.formatDiagnostic(stderr_writer, filter_src, kind, src_offset, 0, null, pool.last_user_error_msg, allocator, diag_format);
                const code = exitCodeForKind(kind);
                if (pool_error_exit == null or code > pool_error_exit.?) pool_error_exit = code;
                continue;
            };
            const result = maybe orelse break;
            writer.writeSlice(result.data) catch {
                printErr("zq: write error\n");
                return EXIT_SYSTEM;
            };
            if (config.unbuffered) writer.flush() catch {
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

            var diag = QueryDiag{};
            defer diag.deinit(allocator);
            last_was_false_or_null = processFile(file, &cq, &writer, style, color, serialize_opts, ext_bindings, allocator, config.raw_input, config.unbuffered, &diag) catch |e| {
                const kind = err_mod.kindFromZqError(@errorCast(e));
                const src_offset = if (diag.last_ip < cq.source_map.len) cq.source_map[diag.last_ip] else 0;
                err_mod.formatDiagnostic(stderr_writer, filter_src, kind, src_offset, 0, null, diag.user_error_msg, allocator, diag_format);
                return exitCodeForKind(kind);
            };
        }
    }

    writer.flush() catch {
        printErr("zq: write error\n");
        return EXIT_SYSTEM;
    };

    if (pool_error_exit) |code| return code;
    if (had_parse_errors) return EXIT_SYSTEM;
    if (config.exit_status and last_was_false_or_null) {
        return EXIT_FALSE;
    }
    return EXIT_OK;
}

/// Process a regular file in parallel using the worker Pool.
/// Uses all available CPU cores. Results are delivered in submission order.
fn processFile(
    file: std.fs.File,
    cq: *const query_mod.CompiledQuery,
    writer: *output_mod.Writer,
    style: types.OutputStyle,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    ext_bindings: []const query_mod.ExternalVarBinding,
    allocator: std.mem.Allocator,
    raw_input: bool,
    unbuffered: bool,
    diag: *QueryDiag,
) !bool {
    const n_threads = std.Thread.getCpuCount() catch 4;
    const budget = pool_mod.MemoryBudget.detect();
    var pool = try pool_mod.Pool.init(n_threads, budget, allocator);
    defer pool.deinit();
    errdefer {
        diag.last_ip = pool.last_error_ip;
        // Dupe into the caller's allocator: the source string is arena-backed
        // by the chunk that raised the error, and `pool.deinit()` (the
        // preceding `defer`) will free that arena before main's catch runs.
        // We intentionally do not free — the process is exiting with an error
        // and `allocator` is the gpa whose memory is reclaimed at teardown.
        if (pool.last_user_error_msg) |msg| {
            if (allocator.dupe(u8, msg)) |copy| {
                diag.user_error_msg = copy;
                diag.user_error_msg_owned = true;
            } else |_| {}
        }
    }

    try pool.submit_file(file, cq, style, color, opts, raw_input, ext_bindings);

    var last_was_false_or_null = false;
    while (try pool.collect_bytes()) |result| {
        try writer.writeSlice(result.data);
        if (unbuffered) try writer.flush();
        last_was_false_or_null = result.last_was_false_or_null;
    }

    return last_was_false_or_null;
}

// ── Slurp Processing ─────────────────────────────────────────────────────────

fn processSlurp(
    config: *const Config,
    cq: *const query_mod.CompiledQuery,
    writer: *output_mod.Writer,
    style: types.OutputStyle,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    ext_bindings: []const query_mod.ExternalVarBinding,
    allocator: std.mem.Allocator,
    had_errors: *bool,
    diag: *QueryDiag,
) !bool {
    if (config.raw_input) {
        return processSlurpRaw(config, cq, writer, style, color, opts, ext_bindings, allocator, diag);
    }
    return processSlurpJson(config, cq, writer, style, color, opts, ext_bindings, allocator, had_errors, diag);
}

/// Collect all parsed JSON values into a single array, then run the query once.
fn processSlurpJson(
    config: *const Config,
    cq: *const query_mod.CompiledQuery,
    writer: *output_mod.Writer,
    style: types.OutputStyle,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    ext_bindings: []const query_mod.ExternalVarBinding,
    allocator: std.mem.Allocator,
    had_errors: *bool,
    diag: *QueryDiag,
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
        try collectJsonValues(std.fs.File.stdin(), &rt, &parser, allocator, had_errors);
    } else {
        for (config.files) |path| {
            const file = openFile(path) catch {
                printErr("zq: could not open ");
                printErr(path);
                printErr("\n");
                return error.IoError;
            };
            defer file.close();
            try collectJsonValues(file, &rt, &parser, allocator, had_errors);
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
    return try writeRecord(cq, tape, &opt_it, writer, style, color, opts, ext_bindings, allocator, config.unbuffered, diag);
}

/// Read all JSON values from a file/stdin using Source + Parser, copying each
/// parsed value into the RuntimeTape.
fn collectJsonValues(
    file: std.fs.File,
    rt: *types.RuntimeTape,
    parser: *parser_mod.Parser,
    allocator: std.mem.Allocator,
    had_errors: *bool,
) !void {
    var src = try io_mod.Source.init(file, allocator);
    defer src.deinit();

    _ = try src.refill();

    var fed_any = false;
    while (true) {
        const view = try src.peek();

        if (view.bytes.len == 0 and view.is_eof) {
            if (fed_any) {
                const result = parser.feed("", true) catch {
                    printErr("zq: parse error (skipping malformed input)\n");
                    had_errors.* = true;
                    return;
                };
                switch (result) {
                    .done => |d| {
                        try rt.copyFrom(d.tape, allocator);
                        parser.reset();
                    },
                    .need_more => {
                        printErr("zq: parse error (skipping malformed input)\n");
                        had_errors.* = true;
                        parser.reset();
                    },
                }
            }
            break;
        }

        if (view.bytes.len == 0) {
            _ = try src.refill();
            continue;
        }

        // Between values (parser reset), skip whitespace-only chunks to avoid
        // false "parse error" on trailing newlines in JSONL input.
        if (!fed_any) {
            const has_content = for (view.bytes) |c| {
                if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break true;
            } else false;
            if (!has_content) {
                src.consume(view.bytes.len);
                if (view.is_eof) break;
                _ = try src.refill();
                continue;
            }
        }

        fed_any = true;
        const result = parser.feed(view.bytes, view.is_eof) catch {
            printErr("zq: parse error (skipping malformed input)\n");
            had_errors.* = true;
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
                try rt.copyFrom(d.tape, allocator);
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

/// Collect all raw bytes into one string, trim trailing newline, then run query
/// on a single string value (the -Rs path).
fn processSlurpRaw(
    config: *const Config,
    cq: *const query_mod.CompiledQuery,
    writer: *output_mod.Writer,
    style: types.OutputStyle,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    ext_bindings: []const query_mod.ExternalVarBinding,
    allocator: std.mem.Allocator,
    diag: *QueryDiag,
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
    return try writeRecord(cq, tape, &opt_it, writer, style, color, opts, ext_bindings, allocator, config.unbuffered, diag);
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
    style: types.OutputStyle,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    ext_bindings: []const query_mod.ExternalVarBinding,
    allocator: std.mem.Allocator,
    unbuffered: bool,
    diag: *QueryDiag,
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
    return try writeRecord(cq, tape, &opt_it, writer, style, color, opts, ext_bindings, allocator, unbuffered, diag);
}

/// Process --validate mode: compile filter only, report success or error.
fn processValidate(config: *const Config, allocator: std.mem.Allocator) u8 {
    if (config.files.len > 0) {
        printErr("zq: --validate does not accept input files\n");
        return EXIT_USAGE;
    }
    if (config.describe) {
        printErr("zq: --validate is incompatible with --describe\n");
        return EXIT_USAGE;
    }

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
            // Note: leaks on this path, but process exits immediately after.
            break :blk std.mem.trimRight(u8, contents, "\r\n");
        }
        break :blk config.filter orelse {
            printErr("zq: --validate requires a filter\n");
            return EXIT_USAGE;
        };
    };

    // Build external variable declarations for compile.
    var ext_decls_buf = allocator.alloc(query_mod.ExternalVarDecl, config.external_vars.len + 1) catch {
        printErr("zq: out of memory\n");
        return EXIT_SYSTEM;
    };
    defer allocator.free(ext_decls_buf);
    for (config.external_vars, 0..) |ev, i| {
        ext_decls_buf[i] = .{ .name = ev.name };
    }
    ext_decls_buf[config.external_vars.len] = .{ .name = "ARGS" };

    const compile_result = query_mod.CompiledQuery.compile(filter_src, .{
        .external_vars = ext_decls_buf,
    }, allocator) catch {
        printErr("zq: out of memory\n");
        return EXIT_SYSTEM;
    };

    switch (compile_result) {
        .ok => |compiled| {
            var cq = compiled;
            cq.deinit();
            if (config.json_errors) {
                std.fs.File.stdout().writeAll("{\"valid\":true}\n") catch {
                    printErr("zq: write error\n");
                    return EXIT_SYSTEM;
                };
            }
            return EXIT_OK;
        },
        .err => |ce| {
            const stderr_writer = StderrWriter{};
            err_mod.formatDiagnostic(stderr_writer, filter_src, ce.kind, ce.offset, ce.len, null, null, allocator, if (config.json_errors) .json else .text);
            return EXIT_COMPILE;
        },
    }
}

/// Process --describe mode: infer schema from all inputs, write result to stdout.
fn processDescribe(config: *const Config, allocator: std.mem.Allocator) u8 {
    // Validate incompatible options.
    if (config.filter != null) {
        printErr("zq: --describe does not accept a filter\n");
        return EXIT_USAGE;
    }
    if (config.null_input) {
        printErr("zq: --describe is incompatible with --null-input\n");
        return EXIT_USAGE;
    }
    if (config.slurp) {
        printErr("zq: --describe is incompatible with --slurp\n");
        return EXIT_USAGE;
    }
    if (config.raw_input) {
        printErr("zq: --describe is incompatible with --raw-input\n");
        return EXIT_USAGE;
    }

    var inferrer = describe_mod.SchemaInferrer.init(allocator, config.describe_depth);
    defer inferrer.deinit();

    var parser = parser_mod.Parser.init(allocator) catch {
        printErr("zq: out of memory\n");
        return EXIT_SYSTEM;
    };
    defer parser.deinit();

    if (config.files.len == 0) {
        // Read from stdin.
        describeStream(std.fs.File.stdin(), &inferrer, &parser, allocator) catch {
            printErr("zq: I/O error reading stdin\n");
            return EXIT_SYSTEM;
        };
    } else {
        for (config.files) |path| {
            const file = openFile(path) catch {
                printErr("zq: could not open ");
                printErr(path);
                printErr("\n");
                return EXIT_SYSTEM;
            };
            defer file.close();
            describeStream(file, &inferrer, &parser, allocator) catch {
                printErr("zq: I/O error reading ");
                printErr(path);
                printErr("\n");
                return EXIT_SYSTEM;
            };
        }
    }

    // Determine output format.
    const use_pretty = !config.style.compact;

    // Serialize into buffer then write to stdout.
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    const buf_writer = buf.writer(allocator);

    if (use_pretty) {
        const indent: describe_mod.Indent = if (config.tab_indent) .tab else .{ .spaces = config.indent_width };
        inferrer.serializePretty(buf_writer, config.sort_keys, indent) catch {
            printErr("zq: out of memory\n");
            return EXIT_SYSTEM;
        };
    } else {
        inferrer.serialize(buf_writer, config.sort_keys) catch {
            printErr("zq: out of memory\n");
            return EXIT_SYSTEM;
        };
    }
    buf_writer.writeByte('\n') catch {
        printErr("zq: out of memory\n");
        return EXIT_SYSTEM;
    };
    std.fs.File.stdout().writeAll(buf.items) catch {
        printErr("zq: write error\n");
        return EXIT_SYSTEM;
    };

    return EXIT_OK;
}

/// Read all JSON values from a file/stdin using Source + Parser, feeding each to the SchemaInferrer.
fn describeStream(
    file: std.fs.File,
    inferrer: *describe_mod.SchemaInferrer,
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
                const result = parser.feed("", true) catch {
                    parser.reset();
                    return;
                };
                switch (result) {
                    .done => |d| {
                        try inferrer.feedTape(d.tape);
                        parser.reset();
                    },
                    .need_more => {
                        parser.reset();
                    },
                }
            }
            break;
        }

        if (view.bytes.len == 0) {
            _ = try src.refill();
            continue;
        }

        // Between values (parser reset), skip whitespace-only chunks to avoid
        // false "parse error" on trailing newlines in JSONL input.
        if (!fed_any) {
            const has_content = for (view.bytes) |c| {
                if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break true;
            } else false;
            if (!has_content) {
                src.consume(view.bytes.len);
                if (view.is_eof) break;
                _ = try src.refill();
                continue;
            }
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
                try inferrer.feedTape(d.tape);
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

/// Execute the query against `tape` and write all output values.
/// On the first call, `opt_it.*` is null and the iterator is allocated.
/// On subsequent calls, the existing iterator is reset() to the new tape —
/// zero allocations after the first record.
fn writeRecord(
    cq: *const query_mod.CompiledQuery,
    tape: parser_mod.Tape,
    opt_it: *?query_mod.ResultIterator,
    writer: *output_mod.Writer,
    style: types.OutputStyle,
    color: ?*const output_mod.Color,
    opts: output_mod.SerializeOpts,
    ext_bindings: []const query_mod.ExternalVarBinding,
    allocator: std.mem.Allocator,
    unbuffered: bool,
    diag: *QueryDiag,
) !bool {
    if (opt_it.*) |*it| {
        it.reset(tape, ext_bindings);
    } else {
        opt_it.* = try cq.execute(tape, ext_bindings, allocator);
    }
    const it = &opt_it.*.?;
    errdefer {
        diag.last_ip = it.last_error_ip;
        // Capture user error message from the iterator before it's cleaned up.
        if (it.user_error_msg) |msg| {
            switch (msg) {
                .string => |sv| diag.user_error_msg = sv.slice(),
                else => {},
            }
        }
    }

    var last_was_false_or_null = false;
    while (try it.next()) |val| {
        try writer.write_value(val, style, color, opts);
        if (!style.join) {
            try writer.writeByte('\n');
        }
        if (unbuffered) try writer.flush();
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

// ── --slurpfile / --rawfile loaders ──────────────────────────────────────────

const ExtFileLoadError = error{ OutOfMemory, UsageError };

/// Cap on bytes we will read from a single --slurpfile / --rawfile argument.
/// Mirrors the filter-file cap (1 MiB scaled for data files) — generous for
/// real-world configs, tight enough to fail fast on a `/dev/zero` mishap.
const ext_file_max_bytes: usize = 256 * 1024 * 1024;

fn printExtFileOpenError(flag: []const u8, name: []const u8, path: []const u8) void {
    printErr("zq: ");
    printErr(flag);
    printErr(": could not open ");
    printErr(path);
    printErr(" for $");
    printErr(name);
    printErr("\n");
}

/// --slurpfile NAME FILE: parse FILE as one or more top-level JSON values
/// (NDJSON-style stream allowed), wrap them in a single array, and append
/// the array span to `rt`. Always wraps — a single value becomes a 1-elem
/// array (jq spec verified against jq-1.8.1).
///
/// Returns the rt index of the array_start entry (the span’s rt_start).
fn loadSlurpfile(
    path: []const u8,
    rt: *types.RuntimeTape,
    parser: *parser_mod.Parser,
    name: []const u8,
    allocator: std.mem.Allocator,
) ExtFileLoadError!u32 {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        printExtFileOpenError("--slurpfile", name, path);
        return error.UsageError;
    };
    defer file.close();
    const bytes = file.readToEndAlloc(allocator, ext_file_max_bytes) catch {
        printErr("zq: --slurpfile: could not read ");
        printErr(path);
        printErr(" for $");
        printErr(name);
        printErr("\n");
        return error.UsageError;
    };
    defer allocator.free(bytes);

    const arr_start: u32 = @intCast(rt.entries.items.len);
    _ = try rt.appendEntry(allocator, .{ .tag = .array_start, .payload = .{ .skip = 0 } });

    // Stream-parse top-level values. Trim leading whitespace between values
    // so NDJSON / pretty-printed concatenations both work.
    parser.reset();
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        // Skip whitespace between values.
        while (cursor < bytes.len) : (cursor += 1) {
            const c = bytes[cursor];
            if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
        }
        if (cursor >= bytes.len) break;

        const result = parser.feed(bytes[cursor..], true) catch {
            printErr("zq: --slurpfile: invalid JSON in ");
            printErr(path);
            printErr(" for $");
            printErr(name);
            printErr("\n");
            return error.UsageError;
        };
        switch (result) {
            .done => |d| {
                const value_tape = d.tape;
                // Copy each entry's span. The parsed tape always describes a
                // single value, so copyFrom (entire tape) is safe.
                try rt.copyFrom(value_tape, allocator);
                cursor += d.consumed;
                parser.reset();
            },
            .need_more => {
                // EOF was already passed (is_eof=true). need_more here means
                // the input ended mid-value.
                printErr("zq: --slurpfile: incomplete JSON in ");
                printErr(path);
                printErr(" for $");
                printErr(name);
                printErr("\n");
                return error.UsageError;
            },
        }
    }

    const arr_end_idx: u32 = @intCast(rt.entries.items.len);
    _ = try rt.appendEntry(allocator, .{ .tag = .array_end, .payload = .{ .none = {} } });
    rt.entries.items[arr_start].payload.skip = arr_end_idx + 1;
    rt.refreshView();
    return arr_start;
}

/// --rawfile NAME FILE: read FILE bytes verbatim (including trailing
/// newline, if present) into a JSON string entry on `rt`. Returns the rt
/// index of the string entry.
fn loadRawfile(
    path: []const u8,
    rt: *types.RuntimeTape,
    name: []const u8,
    allocator: std.mem.Allocator,
) ExtFileLoadError!u32 {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        printExtFileOpenError("--rawfile", name, path);
        return error.UsageError;
    };
    defer file.close();
    const bytes = file.readToEndAlloc(allocator, ext_file_max_bytes) catch {
        printErr("zq: --rawfile: could not read ");
        printErr(path);
        printErr(" for $");
        printErr(name);
        printErr("\n");
        return error.UsageError;
    };
    defer allocator.free(bytes);

    const str_ref = try rt.internString(allocator, bytes);
    const str_idx: u32 = @intCast(rt.entries.items.len);
    _ = try rt.appendEntry(allocator, .{ .tag = .string, .payload = .{ .string = str_ref } });
    return str_idx;
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
    var positional_args = std.ArrayList([]u8){};
    errdefer {
        for (owned_files.items) |f| allocator.free(f);
        owned_files.deinit(allocator);
        if (owned_filter) |f| allocator.free(f);
        if (owned_ff_path) |f| allocator.free(f);
        for (ext_var_strs.items) |s| allocator.free(s);
        ext_var_strs.deinit(allocator);
        ext_vars.deinit(allocator);
        for (positional_args.items) |s| allocator.free(s);
        positional_args.deinit(allocator);
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
                    'r' => config.style.raw_strings = true,
                    'c' => config.style.compact = true,
                    'e' => config.exit_status = true,
                    'n' => config.null_input = true,
                    's' => config.slurp = true,
                    'S' => config.sort_keys = true,
                    'j' => {
                        config.style.join = true;
                        config.style.raw_strings = true;
                    },
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
            config.style.raw_strings = true;
        } else if (std.mem.eql(u8, arg, "--compact-output")) {
            config.style.compact = true;
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
            config.style.join = true;
            config.style.raw_strings = true;
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
            config.tab_indent = false;
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
            try ext_vars.append(allocator, .{ .name = name_duped, .value = val_duped, .kind = .string });
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
            try ext_vars.append(allocator, .{ .name = name_duped, .value = val_duped, .kind = .json });
        } else if (std.mem.eql(u8, arg, "--slurpfile")) {
            if (i + 2 >= args.len) {
                printErr("zq: --slurpfile requires name and file path\n");
                return error.UsageError;
            }
            i += 1;
            const name_duped = try allocator.dupe(u8, args[i]);
            try ext_var_strs.append(allocator, name_duped);
            i += 1;
            const path_duped = try allocator.dupe(u8, args[i]);
            try ext_var_strs.append(allocator, path_duped);
            try ext_vars.append(allocator, .{ .name = name_duped, .value = path_duped, .kind = .slurpfile });
        } else if (std.mem.eql(u8, arg, "--rawfile")) {
            if (i + 2 >= args.len) {
                printErr("zq: --rawfile requires name and file path\n");
                return error.UsageError;
            }
            i += 1;
            const name_duped = try allocator.dupe(u8, args[i]);
            try ext_var_strs.append(allocator, name_duped);
            i += 1;
            const path_duped = try allocator.dupe(u8, args[i]);
            try ext_var_strs.append(allocator, path_duped);
            try ext_vars.append(allocator, .{ .name = name_duped, .value = path_duped, .kind = .rawfile });
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
        } else if (std.mem.eql(u8, arg, "--args") or std.mem.eql(u8, arg, "--jsonargs")) {
            config.positional_is_json = std.mem.eql(u8, arg, "--jsonargs");
            i += 1;
            while (i < args.len) : (i += 1) {
                const duped = try allocator.dupe(u8, args[i]);
                try positional_args.append(allocator, duped);
            }
            break;
        } else if (std.mem.eql(u8, arg, "--json-errors")) {
            config.json_errors = true;
        } else if (std.mem.eql(u8, arg, "--unbuffered")) {
            config.unbuffered = true;
        } else if (std.mem.eql(u8, arg, "--lsp")) {
            config.lsp_mode = true;
        } else if (std.mem.eql(u8, arg, "--validate")) {
            config.validate = true;
        } else if (std.mem.eql(u8, arg, "--describe")) {
            config.describe = true;
        } else if (std.mem.eql(u8, arg, "--depth")) {
            i += 1;
            if (i >= args.len) {
                printErr("zq: --depth requires a number\n");
                return error.UsageError;
            }
            config.describe_depth = std.fmt.parseInt(u32, args[i], 10) catch {
                printErr("zq: --depth: invalid number\n");
                return error.UsageError;
            };
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
            // Positional: in --describe mode all positionals are files;
            // otherwise first is filter, rest are files.
            if (config.describe or filter_set) {
                const duped = try allocator.dupe(u8, arg);
                try owned_files.append(allocator, duped);
                try files.append(allocator, duped);
            } else {
                const duped = try allocator.dupe(u8, arg);
                if (owned_filter) |old| allocator.free(old);
                owned_filter = duped;
                config.filter = duped;
                filter_set = true;
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
    if (positional_args.items.len > 0) {
        config._owned_positional_strs = try positional_args.toOwnedSlice(allocator);
        const pa_list = try allocator.alloc([]const u8, config._owned_positional_strs.len);
        for (config._owned_positional_strs, 0..) |s, idx| pa_list[idx] = s;
        config.positional_args = pa_list;
        config._owned_positional_list = pa_list;
    } else {
        positional_args.deinit(allocator);
    }

    return config;
}

// ── Error Output Helpers ─────────────────────────────────────────────────────

fn printVersion() void {
    printErr("zq " ++ build_options.version ++ "\n");
}

/// Minimal writer adapter for formatDiagnostic over stderr.
const StderrWriter = struct {
    pub fn print(_: StderrWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
            printErr("zq: format error\n");
            return;
        };
        printErr(msg);
    }

    pub fn writeByteNTimes(_: StderrWriter, byte: u8, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            printErrByte(byte);
        }
    }

    pub fn writeByte(_: StderrWriter, byte: u8) !void {
        printErrByte(byte);
    }
};

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
        \\A high-performance JSON processor, compatible with jq filter syntax.
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
        \\  --slurpfile NAME FILE Set $NAME to FILE's JSON values, wrapped in an array
        \\  --rawfile NAME FILE   Set $NAME to FILE's raw bytes as a string
        \\  --args                Remaining args are string values
        \\  --jsonargs            Remaining args are JSON values
        \\  --json-errors         Output errors as JSON on stderr
        \\  --unbuffered          Flush output after every emitted value
    ++ (if (@import("lsp").enabled)
        "\n  --lsp                 Start Language Server Protocol server on stdin/stdout"
    else
        "") ++
        \\
        \\  --validate            Check filter syntax without executing (exit 0=valid, 3=error)
        \\  --describe            Print input data shape (type, fields, count)
        \\  --depth N             Schema recursion depth (default: 12, 0=unlimited)
        \\  -h, --help            Print this help
        \\  -V, --version         Print version
        \\
        \\Filter syntax:
        \\  .               Identity
        \\  .foo, .foo.bar  Field access
        \\  .foo?           Optional field access (no error if missing)
        \\  .[0], .[-1]     Array index
        \\  .[2:5]          Array/string slice
        \\  .[]             Iterate all elements
        \\  |               Pipe (compose filters)
        \\  ,               Output multiple values
        \\  select(f)       Keep values where f is truthy
        \\  if-then-else    Conditionals: if .x then .y else .z end
        \\  try-catch       Error handling: try .x catch .y
        \\  //              Alternative operator: .x // "default"
        \\  |=, +=, -=      Update operators
        \\  {a,b}, {x:.y}  Object construction
        \\  [.[] | f]      Array construction
        \\  \(.x)           String interpolation: "val=\(.x)"
        \\  def f: body;   Function definition
        \\  reduce          reduce .[] as $x (init; update)
        \\  foreach         foreach .[] as $x (init; update; extract)
        \\  ..              Recursive descent
        \\
        \\Format strings: @base64 @base64d @csv @tsv @html @uri @sh @json @text
        \\
        \\Examples:
        \\  echo '{"a":1}' | zq '.a'
        \\  zq '.[] | .name' data.json
        \\  zq -c '.' input.json
        \\  zq 'select(.age > 30)' users.json
        \\  zq '{name: .title, id: .num}' items.json
        \\  zq '[.[] | .price] | add' orders.json
        \\
        \\Exit codes: 0=success, 1=false(-e), 2=usage, 3=compile, 4=runtime, 5=system
        \\
        \\Run 'zq -n builtins' for all built-in functions.
        \\
    );
}
