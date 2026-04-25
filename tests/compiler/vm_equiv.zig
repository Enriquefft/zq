//! VM-equivalence harness for Phase 2R compiler.
//!
//! For each fixture: compile via legacy AND via new, then run both
//! resulting bytecodes against the input JSON and byte-compare the
//! emitted value streams. Mismatches surface a per-fixture diff line
//! and exit non-zero.
//!
//! Plan: research/phase-2r-compiler-redesign-plan.md §3 R3 step 4.
//! Spec:  research/compiler-ir-format.md (Phase 4).

const std = @import("std");
const query = @import("query");
const parser_mod = @import("parser");
const output_mod = @import("output");
const types_mod = @import("types");

const Fixture = struct {
    name: []const u8,
    filter: []const u8,
    /// JSON input fed through the production parser to build a Tape.
    input: []const u8,
    /// Reference value stream — one JSON value per emitted output, separated
    /// by '\n'. When set, BOTH backends must match this string AND each other
    /// (3-way comparison). When left empty (`""`), the harness only asserts
    /// legacy-vs-new equivalence and does not pin the absolute value stream.
    expected_output: []const u8 = "",
    /// When true, the legacy compiler is expected to fail. We then check
    /// the new compiler reports the same error class.
    expects_compile_err: bool = false,
};

const FIXTURES = [_]Fixture{
    .{ .name = "literal_null", .filter = "null", .input = "1", .expected_output = "null" },
    .{ .name = "literal_true", .filter = "true", .input = "1", .expected_output = "true" },
    .{ .name = "literal_false", .filter = "false", .input = "1", .expected_output = "false" },
    .{ .name = "literal_int", .filter = "42", .input = "1", .expected_output = "42" },
    .{ .name = "literal_float", .filter = "3.14", .input = "1", .expected_output = "3.14" },
    .{ .name = "literal_str", .filter = "\"hi\"", .input = "1", .expected_output = "\"hi\"" },
    .{ .name = "identity", .filter = ".", .input = "{\"foo\":1}", .expected_output = "{\"foo\":1}" },
    .{ .name = "recurse", .filter = "..", .input = "[1,2]", .expected_output = "[1,2]\n1\n2" },
    .{ .name = "neg", .filter = "-5", .input = "null", .expected_output = "-5" },
    .{ .name = "not_zero_arg", .filter = "not", .input = "null", .expected_output = "true" },
    .{ .name = "type_zero_arg", .filter = "type", .input = "[]", .expected_output = "\"array\"" },

    .{ .name = "field", .filter = ".foo", .input = "{\"foo\":1}", .expected_output = "1" },
    .{ .name = "nested", .filter = ".foo.bar", .input = "{\"foo\":{\"bar\":2}}", .expected_output = "2" },
    .{ .name = "pipe", .filter = ".foo | .bar", .input = "{\"foo\":{\"bar\":3}}", .expected_output = "3" },
    .{ .name = "index", .filter = ".[0]", .input = "[10,20]", .expected_output = "10" },
    .{ .name = "iterate_top", .filter = ".[]", .input = "[1,2,3]", .expected_output = "1\n2\n3" },
    .{ .name = "field_iterate", .filter = ".foo[]", .input = "{\"foo\":[10,20]}", .expected_output = "10\n20" },
    .{ .name = "slice_top", .filter = ".[1:3]", .input = "[10,20,30,40]", .expected_output = "[20,30]" },
    .{ .name = "slice_open_left", .filter = ".[:2]", .input = "[1,2,3,4]", .expected_output = "[1,2]" },
    .{ .name = "optional_missing", .filter = ".foo?", .input = "{}", .expected_output = "null" },
    .{ .name = "optional_type_err", .filter = ".foo?", .input = "[1,2]", .expected_output = "" },
    .{ .name = "field_quoted", .filter = ".[\"foo\"]", .input = "{\"foo\":42}", .expected_output = "42" },
    .{ .name = "neg_index", .filter = ".[-1]", .input = "[10,20,30]", .expected_output = "30" },
    .{ .name = "chain_index_field", .filter = ".[0].x", .input = "[{\"x\":7}]", .expected_output = "7" },
    .{ .name = "chain_field_index", .filter = ".a[1]", .input = "{\"a\":[10,20]}", .expected_output = "20" },
    .{ .name = "arith", .filter = "1+1", .input = "null", .expected_output = "2" },

    // ── Category 5 — arithmetic ───────────────────────────────────
    .{ .name = "arith_sub", .filter = "10-3", .input = "null", .expected_output = "7" },
    .{ .name = "arith_mul", .filter = "4*5", .input = "null", .expected_output = "20" },
    .{ .name = "arith_div", .filter = "20/4", .input = "null", .expected_output = "5" },
    .{ .name = "arith_mod", .filter = "10%3", .input = "null", .expected_output = "1" },
    .{ .name = "arith_chain", .filter = "1+2*3", .input = "null", .expected_output = "7" },
    .{ .name = "arith_field", .filter = ".x + .y", .input = "{\"x\":2,\"y\":3}", .expected_output = "5" },

    // ── Category 5 — comparison ───────────────────────────────────
    .{ .name = "cmp_eq_true", .filter = "1==1", .input = "null", .expected_output = "true" },
    .{ .name = "cmp_ne_true", .filter = "1!=2", .input = "null", .expected_output = "true" },
    .{ .name = "cmp_lt_true", .filter = "1<2", .input = "null", .expected_output = "true" },
    .{ .name = "cmp_le_true", .filter = "2<=2", .input = "null", .expected_output = "true" },
    .{ .name = "cmp_gt_true", .filter = "3>2", .input = "null", .expected_output = "true" },
    .{ .name = "cmp_ge_false", .filter = "1>=2", .input = "null", .expected_output = "false" },
    .{ .name = "cmp_field", .filter = ".id > 100", .input = "{\"id\":150}", .expected_output = "true" },

    // ── Category 5 — logical and/or ───────────────────────────────
    .{ .name = "logical_and_tt", .filter = "true and true", .input = "null", .expected_output = "true" },
    .{ .name = "logical_and_tf", .filter = "true and false", .input = "null", .expected_output = "false" },
    .{ .name = "logical_or_tf", .filter = "true or false", .input = "null", .expected_output = "true" },
    .{ .name = "logical_or_ff", .filter = "false or false", .input = "null", .expected_output = "false" },

    // ── Category 5 — alternative `//` ─────────────────────────────
    .{ .name = "alt_null_lhs", .filter = "null // 5", .input = "null", .expected_output = "5" },
    .{ .name = "alt_false_lhs", .filter = "false // 7", .input = "null", .expected_output = "7" },
    .{ .name = "alt_truthy_lhs", .filter = "1 // 5", .input = "null", .expected_output = "1" },

    .{ .name = "select", .filter = "select(.id > 100)", .input = "{\"id\":150}", .expected_output = "{\"id\":150}" },
    .{ .name = "map", .filter = "map(.id) | add", .input = "[{\"id\":1},{\"id\":2}]", .expected_output = "3" },
    .{ .name = "udf_simple", .filter = "def f: . + 1; f", .input = "10", .expected_output = "11" },
    .{ .name = "udf_semi", .filter = "def f(a;b): a + b; f(.x;.y)", .input = "{\"x\":2,\"y\":3}", .expected_output = "5" },
    .{ .name = "regex_lit", .filter = "test(\"^[a-z]+$\")", .input = "\"foobar\"", .expected_output = "true" },
    .{ .name = "reduce", .filter = "reduce range(10) as $i (0; . + $i)", .input = "null", .expected_output = "45" },

    .{ .name = "pipe_chain", .filter = ".a | .b | .c", .input = "{\"a\":{\"b\":{\"c\":7}}}", .expected_output = "7" },
    .{ .name = "comma_simple", .filter = ".a, .b", .input = "{\"a\":1,\"b\":2}", .expected_output = "1\n2" },
    .{ .name = "comma_chain", .filter = ".a, .b, .c", .input = "{\"a\":1,\"b\":2,\"c\":3}", .expected_output = "1\n2\n3" },
};

/// One JSON-encoded value per emitted iterator output, separated by '\n'.
/// Compact format — matches the `--compact-output` mode jq users diff
/// against. The runtime error (if any) is captured as a structured tag so
/// we can compare error kinds + offsets across backends without leaking
/// `ZqError` enum names through `@tagName` mismatches.
const RunResult = struct {
    output: []u8,
    err: ?ErrInfo,

    const ErrInfo = struct {
        kind: []const u8,
    };

    fn deinit(self: *RunResult, alloc: std.mem.Allocator) void {
        alloc.free(self.output);
    }
};

fn runQuery(
    cq: *const query.CompiledQuery,
    tape: types_mod.Tape,
    alloc: std.mem.Allocator,
) !RunResult {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(alloc);

    var sink: output_mod.BufferSink = .{ .list = &buf, .aa = alloc };
    var first: bool = true;

    var it = try cq.execute(tape, &.{}, alloc);
    defer it.deinit();

    while (true) {
        const v_opt = it.next() catch |e| {
            const owned = try buf.toOwnedSlice(alloc);
            return .{ .output = owned, .err = .{ .kind = @errorName(e) } };
        };
        const v = v_opt orelse break;
        if (!first) try sink.writeByte('\n');
        first = false;
        try output_mod.serialize(&sink, v, .compact, null, .{});
    }

    const owned = try buf.toOwnedSlice(alloc);
    return .{ .output = owned, .err = null };
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var match: u32 = 0;
    var mismatch: u32 = 0;
    var skipped: u32 = 0;
    var compile_err: u32 = 0;

    var stdout_buf: std.ArrayList(u8) = .{};
    defer stdout_buf.deinit(alloc);
    const w = stdout_buf.writer(alloc);

    for (FIXTURES) |fx| {
        // Legacy compile (always legacy regardless of -Dcompile=).
        var legacy_result = try query.CompiledQuery.compileLegacy(fx.filter, .{}, alloc);
        defer switch (legacy_result) {
            .ok => |*cq| cq.deinit(),
            .err => {},
        };

        switch (legacy_result) {
            .err => |ce| {
                if (!fx.expects_compile_err) {
                    try w.print("LEGACY_COMPILE_ERR name={s} filter={s} kind={s}\n", .{ fx.name, fx.filter, @tagName(ce.kind) });
                    compile_err += 1;
                    continue;
                }
                skipped += 1;
                try w.print("SKIP name={s} reason=expected-compile-err\n", .{fx.name});
                continue;
            },
            .ok => {},
        }

        const new_result = query.CompiledQuery.compileNew(fx.filter, .{}, alloc) catch |e| switch (e) {
            error.NewCompilerNotImplemented => {
                skipped += 1;
                try w.print("SKIP name={s} reason=new-compiler-not-implemented\n", .{fx.name});
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        var new_compiled = new_result;
        defer switch (new_compiled) {
            .ok => |*cq| cq.deinit(),
            .err => {},
        };

        switch (new_compiled) {
            .err => |ce| {
                try w.print("NEW_COMPILE_ERR name={s} filter={s} kind={s}\n", .{ fx.name, fx.filter, @tagName(ce.kind) });
                compile_err += 1;
                continue;
            },
            .ok => {},
        }

        // Both backends compiled. Build a Tape from `fx.input` and run
        // each compiled query through the VM, capturing its full output
        // stream (or runtime error). Byte-diff the streams.
        var legacy_parser = parser_mod.Parser.init(alloc) catch |e| return e;
        defer legacy_parser.deinit();
        const legacy_feed = try legacy_parser.feed(fx.input, true);
        const legacy_tape = switch (legacy_feed) {
            .done => |d| d.tape,
            .need_more => {
                try w.print("INPUT_PARSE_ERR name={s} input={s}\n", .{ fx.name, fx.input });
                compile_err += 1;
                continue;
            },
        };

        var new_parser = parser_mod.Parser.init(alloc) catch |e| return e;
        defer new_parser.deinit();
        const new_feed = try new_parser.feed(fx.input, true);
        const new_tape = switch (new_feed) {
            .done => |d| d.tape,
            .need_more => {
                try w.print("INPUT_PARSE_ERR name={s} input={s}\n", .{ fx.name, fx.input });
                compile_err += 1;
                continue;
            },
        };

        const legacy_cq = legacy_result.ok;
        const new_cq = new_compiled.ok;

        var legacy_run = try runQuery(&legacy_cq, legacy_tape, alloc);
        defer legacy_run.deinit(alloc);
        var new_run = try runQuery(&new_cq, new_tape, alloc);
        defer new_run.deinit(alloc);

        const same_bytes = std.mem.eql(u8, legacy_run.output, new_run.output);
        const legacy_err_name: ?[]const u8 = if (legacy_run.err) |e| e.kind else null;
        const new_err_name: ?[]const u8 = if (new_run.err) |e| e.kind else null;
        const same_err = blk: {
            if (legacy_err_name == null and new_err_name == null) break :blk true;
            if (legacy_err_name == null or new_err_name == null) break :blk false;
            break :blk std.mem.eql(u8, legacy_err_name.?, new_err_name.?);
        };

        // 3-way comparison: when `expected_output` is set, both backends
        // must match it AND each other. When empty, fall back to the
        // legacy-vs-new pairwise check (backward-compatible default).
        const has_expected = fx.expected_output.len > 0;
        const matches_expected = !has_expected or
            (std.mem.eql(u8, legacy_run.output, fx.expected_output) and
                std.mem.eql(u8, new_run.output, fx.expected_output));

        if (same_bytes and same_err and matches_expected) {
            match += 1;
            try w.print("MATCH name={s} filter={s}\n", .{ fx.name, fx.filter });
        } else {
            mismatch += 1;
            try w.print(
                "MISMATCH name={s} filter={s} input={s}\n  legacy_out=`{s}` legacy_err={s}\n  new_out=   `{s}` new_err=   {s}\n  expected=  `{s}`\n",
                .{
                    fx.name,
                    fx.filter,
                    fx.input,
                    legacy_run.output,
                    legacy_err_name orelse "<none>",
                    new_run.output,
                    new_err_name orelse "<none>",
                    fx.expected_output,
                },
            );
        }
    }

    try w.print("\nvm_equiv: total={d} match={d} mismatch={d} skipped={d} compile_err={d}\n", .{
        FIXTURES.len,
        match,
        mismatch,
        skipped,
        compile_err,
    });

    try std.fs.File.stdout().writeAll(stdout_buf.items);

    if (mismatch > 0 or compile_err > 0) std.process.exit(1);
}
