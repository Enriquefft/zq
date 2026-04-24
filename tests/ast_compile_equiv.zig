//! AST-walk compile equivalence harness (Phase 2 Stage 0–10).
//!
//! Invocation: `zig build ast-compile-equiv`.
//!
//! For every fixture in `stage1_supported`, compile via:
//!   1. Legacy compiler (`src/query/src/compiler.zig`).
//!   2. AST walker (`src/ast/compiler.zig`).
//! Then diff `Instruction[]` and `source_map[]` byte-for-byte. Any mismatch
//! prints the first diverging index with both ops and operands and causes a
//! nonzero exit.
//!
//! For every fixture in `stage1_unsupported`, the legacy path must succeed
//! (it covers full jq grammar) and the walker must reject with
//! `error.AstCompilerStageIncomplete`. Any other combination is a failure.
//!
//! Nothing here is in the default test step; the harness is a standalone
//! build target only. See `research/phase-2-ast-walk-plan.md` §3 for the
//! design.

const std = @import("std");
const legacy = @import("compiler_legacy");
const walker = @import("compiler_ast");
const types = @import("types");
const prefilter_mod = @import("prefilter");
const regex_mod = @import("regex");
const fixtures = @import("ast_compile_equiv_fixtures.zig");

const Instruction = types.Instruction;

const verbose = @import("build_options").ast_equiv_verbose;

fn resolveString(buf: []const u8, ref: types.Tape.StringRef) []const u8 {
    if (@as(u64, ref.offset) + @as(u64, ref.len) > buf.len) return "<OOB>";
    return buf[ref.offset..][0..ref.len];
}

fn opName(op: Instruction.Op) []const u8 {
    return @tagName(op);
}

fn dumpOperand(
    out: anytype,
    op: Instruction.Op,
    operand: Instruction.Operand,
    string_buf: []const u8,
) !void {
    switch (op) {
        .push_bool => try out.print("bool={}", .{operand.bool}),
        .push_int => try out.print("int={}", .{operand.int}),
        .push_float => try out.print("float={d}", .{operand.float}),
        .push_string, .load_key, .load_path, .navigate_key, .update_key => {
            const s = resolveString(string_buf, operand.str_ref);
            try out.print("str=\"{s}\" @{d}+{d}", .{ s, operand.str_ref.offset, operand.str_ref.len });
        },
        .push_null, .push_current, .identity, .pipe, .negate, .yield_output => try out.print("(none)", .{}),
        .save_input, .restore_input, .backtrack, .pop_try => try out.print("(none)", .{}),
        .call_builtin => try out.print("builtin_idx={d}", .{operand.index}),
        .capture_variable, .load_variable, .pop_variable => try out.print("var_id={d}", .{operand.index}),
        .fork, .jump, .fork_try, .fork_alt => try out.print("ip={d}", .{operand.index}),
        .load_index => try out.print("idx={d}", .{operand.index}),
        else => try out.print("<unprinted>", .{}),
    }
}

fn dumpInstruction(
    out: anytype,
    prefix: []const u8,
    idx: usize,
    ins: Instruction,
    src_offset: u32,
    string_buf: []const u8,
) !void {
    try out.print("    {s}[{d}] op={s} operand=", .{ prefix, idx, opName(ins.op) });
    try dumpOperand(out, ins.op, ins.operand, string_buf);
    try out.print(" src_offset={d}\n", .{src_offset});
}

/// Compare two compiled results. Returns true on match. On mismatch, prints a
/// diff report to the supplied writer.
fn diffCompiled(
    out: anytype,
    filter: []const u8,
    a_ins: []const Instruction,
    a_src: []const u32,
    a_buf: []const u8,
    b_ins: []const Instruction,
    b_src: []const u32,
    b_buf: []const u8,
) !bool {
    if (a_ins.len != b_ins.len) {
        try out.print(
            "  MISMATCH filter=\"{s}\" field=instructions: count differs legacy={d} walker={d}\n",
            .{ filter, a_ins.len, b_ins.len },
        );
        return false;
    }
    if (a_src.len != b_src.len) {
        try out.print(
            "  MISMATCH filter=\"{s}\" field=source_map: count differs legacy={d} walker={d}\n",
            .{ filter, a_src.len, b_src.len },
        );
        return false;
    }

    for (a_ins, b_ins, a_src, b_src, 0..) |ai, bi, as, bs, i| {
        var differs = false;
        if (ai.op != bi.op) differs = true;
        if (!operandsEqual(ai.op, ai.operand, a_buf, bi.operand, b_buf)) differs = true;
        if (as != bs) differs = true;

        if (differs) {
            try out.print("  MISMATCH filter=\"{s}\" field=instructions at index {d}:\n", .{ filter, i });
            try out.writeAll("    legacy:\n");
            try dumpInstruction(out, "    ", i, ai, as, a_buf);
            try out.writeAll("    walker:\n");
            try dumpInstruction(out, "    ", i, bi, bs, b_buf);
            return false;
        }
    }

    return true;
}

/// Compare the function_table between the two compilers. Both currently inline
/// all user definitions at compile time (length-0 tables), but the field is
/// part of the public Compiled shape so the harness diffs it regardless.
fn diffFunctionTable(
    out: anytype,
    filter: []const u8,
    a: []const types.FunctionDef,
    b: []const types.FunctionDef,
) !bool {
    if (a.len != b.len) {
        try out.print(
            "  MISMATCH filter=\"{s}\" field=function_table: length differs legacy={d} walker={d}\n",
            .{ filter, a.len, b.len },
        );
        return false;
    }
    for (a, b, 0..) |ae, be, i| {
        if (ae.body_ip != be.body_ip or ae.body_end != be.body_end or ae.param_count != be.param_count) {
            try out.print(
                "  MISMATCH filter=\"{s}\" field=function_table at index {d}: legacy(body_ip={d},body_end={d},param_count={d}) walker(body_ip={d},body_end={d},param_count={d})\n",
                .{ filter, i, ae.body_ip, ae.body_end, ae.param_count, be.body_ip, be.body_end, be.param_count },
            );
            return false;
        }
    }
    return true;
}

/// Compare the `external_var_ids` slices. The harness passes no externals so
/// both should be empty, but we compare contents for correctness if that
/// changes.
fn diffExternalVarIds(
    out: anytype,
    filter: []const u8,
    a: []const u32,
    b: []const u32,
) !bool {
    if (a.len != b.len) {
        try out.print(
            "  MISMATCH filter=\"{s}\" field=external_var_ids: length differs legacy={d} walker={d}\n",
            .{ filter, a.len, b.len },
        );
        return false;
    }
    for (a, b, 0..) |av, bv, i| {
        if (av != bv) {
            try out.print(
                "  MISMATCH filter=\"{s}\" field=external_var_ids at index {d}: legacy={d} walker={d}\n",
                .{ filter, i, av, bv },
            );
            return false;
        }
    }
    return true;
}

/// Compare regex-pool size + interned-pattern contents. Offset ordering may
/// differ if the two compilers insert patterns in a different order — we
/// compare the unordered set of pattern keys, not their positions.
fn diffRegexPool(
    out: anytype,
    filter: []const u8,
    a: *const regex_mod.RegexPool,
    b: *const regex_mod.RegexPool,
) !bool {
    if (a.len() != b.len()) {
        try out.print(
            "  MISMATCH filter=\"{s}\" field=regex_pool: size differs legacy={d} walker={d}\n",
            .{ filter, a.len(), b.len() },
        );
        return false;
    }
    // Compare unordered key sets: every legacy key must appear in the walker
    // pool's index map.
    var it = a.index.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (b.index.get(key) == null) {
            try out.print(
                "  MISMATCH filter=\"{s}\" field=regex_pool: pattern \"{s}\" present in legacy but missing in walker\n",
                .{ filter, key },
            );
            return false;
        }
    }
    // Symmetric check in case lengths matched but keys differ.
    it = b.index.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (a.index.get(key) == null) {
            try out.print(
                "  MISMATCH filter=\"{s}\" field=regex_pool: pattern \"{s}\" present in walker but missing in legacy\n",
                .{ filter, key },
            );
            return false;
        }
    }
    return true;
}

/// Compare string_buf by content reachable through the instruction stream.
/// We cannot diff the raw bytes — allocation order across the two compilers
/// is not byte-identical (e.g. legacy interns function-body source bytes
/// during body re-parse, walker doesn't). The `instructions` diff above
/// already compares every str_ref by resolved string content via
/// `operandsEqual`. As an additional check, ensure both string_buf byte
/// slices are reachable (not null, not poisoned) by re-resolving every
/// emitted str_ref and confirming it's in-bounds.
fn diffStringBuf(
    out: anytype,
    filter: []const u8,
    a_ins: []const Instruction,
    a_buf: []const u8,
    b_ins: []const Instruction,
    b_buf: []const u8,
) !bool {
    for (a_ins, b_ins, 0..) |ai, bi, i| {
        switch (ai.op) {
            .push_string, .load_key, .load_path, .navigate_key, .update_key => {
                const a_end = @as(u64, ai.operand.str_ref.offset) + @as(u64, ai.operand.str_ref.len);
                const b_end = @as(u64, bi.operand.str_ref.offset) + @as(u64, bi.operand.str_ref.len);
                if (a_end > a_buf.len) {
                    try out.print(
                        "  MISMATCH filter=\"{s}\" field=string_buf: legacy str_ref at instruction {d} out of bounds (end={d} buf_len={d})\n",
                        .{ filter, i, a_end, a_buf.len },
                    );
                    return false;
                }
                if (b_end > b_buf.len) {
                    try out.print(
                        "  MISMATCH filter=\"{s}\" field=string_buf: walker str_ref at instruction {d} out of bounds (end={d} buf_len={d})\n",
                        .{ filter, i, b_end, b_buf.len },
                    );
                    return false;
                }
            },
            else => {},
        }
    }
    return true;
}

/// Compare prefilter groups: length, per-group literal list, per-group flag.
/// Order matters — both compilers harvest from the same idiom via the same
/// matcher, so groups are produced in identical order.
fn diffPrefilter(
    out: anytype,
    filter: []const u8,
    a: ?prefilter_mod.PrefilterSet,
    b: ?prefilter_mod.PrefilterSet,
) !bool {
    if ((a == null) != (b == null)) {
        try out.print(
            "  MISMATCH filter=\"{s}\" field=prefilter: presence differs legacy={} walker={}\n",
            .{ filter, a != null, b != null },
        );
        return false;
    }
    if (a == null) return true;

    const ag = a.?.groups;
    const bg = b.?.groups;
    if (ag.len != bg.len) {
        try out.print(
            "  MISMATCH filter=\"{s}\" field=prefilter_groups: length differs legacy={d} walker={d}\n",
            .{ filter, ag.len, bg.len },
        );
        return false;
    }
    for (ag, bg, 0..) |ga, gb, gi| {
        if (ga.all_required != gb.all_required) {
            try out.print(
                "  MISMATCH filter=\"{s}\" field=prefilter_groups at group {d}: all_required differs legacy={} walker={}\n",
                .{ filter, gi, ga.all_required, gb.all_required },
            );
            return false;
        }
        if (ga.literals.len != gb.literals.len) {
            try out.print(
                "  MISMATCH filter=\"{s}\" field=prefilter_groups at group {d}: literal count differs legacy={d} walker={d}\n",
                .{ filter, gi, ga.literals.len, gb.literals.len },
            );
            return false;
        }
        for (ga.literals, gb.literals, 0..) |la, lb, li| {
            if (!std.mem.eql(u8, la, lb)) {
                try out.print(
                    "  MISMATCH filter=\"{s}\" field=prefilter_groups at group {d} literal {d}: legacy=\"{s}\" walker=\"{s}\"\n",
                    .{ filter, gi, li, la, lb },
                );
                return false;
            }
        }
    }
    return true;
}

/// Full-shape diff: runs every field comparison and returns true only when
/// all pass. On failure the first field-level mismatch message is already
/// printed by the sub-diff that returned false.
fn diffCompiledFull(
    out: anytype,
    filter: []const u8,
    a: legacy.Compiled,
    b: walker.Compiled,
) !bool {
    if (!try diffCompiled(out, filter, a.instructions, a.source_map, a.string_buf, b.instructions, b.source_map, b.string_buf)) return false;
    if (!try diffFunctionTable(out, filter, a.function_table, b.function_table)) return false;
    if (!try diffExternalVarIds(out, filter, a.external_var_ids, b.external_var_ids)) return false;
    if (!try diffRegexPool(out, filter, &a.regex_pool, &b.regex_pool)) return false;
    if (!try diffStringBuf(out, filter, a.instructions, a.string_buf, b.instructions, b.string_buf)) return false;
    if (!try diffPrefilter(out, filter, a.prefilter, b.prefilter)) return false;
    return true;
}

/// Compare two operands. For `str_ref` ops, compare the resolved bytes (not
/// the offsets) because the two compilers may intern in different orders.
fn operandsEqual(
    op: Instruction.Op,
    a: Instruction.Operand,
    a_buf: []const u8,
    b: Instruction.Operand,
    b_buf: []const u8,
) bool {
    switch (op) {
        .push_bool => return a.bool == b.bool,
        .push_int => return a.int == b.int,
        .push_float => {
            // NaN != NaN normally; treat bit-equal as equal.
            return @as(u64, @bitCast(a.float)) == @as(u64, @bitCast(b.float));
        },
        .push_string, .load_key, .load_path, .navigate_key, .update_key => {
            const as = resolveString(a_buf, a.str_ref);
            const bs = resolveString(b_buf, b.str_ref);
            return std.mem.eql(u8, as, bs);
        },
        .push_null, .push_current, .identity, .pipe, .negate, .yield_output => return true,
        .save_input, .restore_input, .backtrack, .pop_try => return true,
        .capture_variable, .load_variable, .pop_variable => return a.index == b.index,
        .fork, .jump, .fork_try, .fork_alt, .load_index => return a.index == b.index,
        .call_builtin => return a.index == b.index,
        else => {
            // Opcodes outside Stage 1 scope — fall back to raw byte equality.
            // If either path actually emits one of these, the structural diff
            // will catch differences and the harness will report MISMATCH.
            return a.index == b.index;
        },
    }
}

const Outcome = enum { pass, fail };

fn runSupported(
    alloc: std.mem.Allocator,
    out: anytype,
    filter: []const u8,
) !Outcome {
    var legacy_result = try legacy.compile(filter, &.{}, alloc);
    defer switch (legacy_result) {
        .ok => |*c| c.deinit(alloc),
        .err => {},
    };
    switch (legacy_result) {
        .err => |ce| {
            try out.print(
                "  FAIL filter=\"{s}\": legacy compiler rejected (kind={s} offset={d} len={d}); expected supported success.\n",
                .{ filter, @tagName(ce.kind), ce.offset, ce.len },
            );
            return .fail;
        },
        .ok => {},
    }

    var walker_result_or_err = walker.compile(alloc, filter, null);
    if (walker_result_or_err) |*walker_result| {
        defer switch (walker_result.*) {
            .ok => |*c| c.deinit(alloc),
            .err => {},
        };
        switch (walker_result.*) {
            .err => |ce| {
                try out.print(
                    "  FAIL filter=\"{s}\": walker returned CompileResult.err (kind={s} offset={d}); expected byte-identical success.\n",
                    .{ filter, @tagName(ce.kind), ce.offset },
                );
                return .fail;
            },
            .ok => {
                const a = legacy_result.ok;
                const b = walker_result.ok;
                const ok = try diffCompiledFull(out, filter, a, b);
                if (verbose) try dumpBoth(out, filter, a, b);
                return if (ok) .pass else .fail;
            },
        }
    } else |e| switch (e) {
        error.AstCompilerStageIncomplete => {
            try out.print(
                "  FAIL filter=\"{s}\": walker returned AstCompilerStageIncomplete for a supported fixture.\n",
                .{filter},
            );
            return .fail;
        },
        error.OutOfMemory => return error.OutOfMemory,
    }
}

fn runUnsupported(
    alloc: std.mem.Allocator,
    out: anytype,
    filter: []const u8,
) !Outcome {
    // Legacy must accept the input. If legacy rejects, the fixture is wrong.
    var legacy_result = try legacy.compile(filter, &.{}, alloc);
    defer switch (legacy_result) {
        .ok => |*c| c.deinit(alloc),
        .err => {},
    };
    switch (legacy_result) {
        .err => |ce| {
            try out.print(
                "  FAIL filter=\"{s}\" (unsupported): legacy rejected (kind={s}); stage1_unsupported entries must legacy-compile cleanly.\n",
                .{ filter, @tagName(ce.kind) },
            );
            return .fail;
        },
        .ok => {},
    }

    // Walker must return AstCompilerStageIncomplete.
    const walker_result = walker.compile(alloc, filter, null);
    if (walker_result) |res| {
        var r = res;
        switch (r) {
            .ok => |*c| {
                @constCast(c).deinit(alloc);
                try out.print(
                    "  FAIL filter=\"{s}\" (unsupported): walker returned success; expected AstCompilerStageIncomplete.\n",
                    .{filter},
                );
                return .fail;
            },
            .err => |ce| {
                try out.print(
                    "  FAIL filter=\"{s}\" (unsupported): walker returned CompileResult.err (kind={s}); expected AstCompilerStageIncomplete.\n",
                    .{ filter, @tagName(ce.kind) },
                );
                return .fail;
            },
        }
    } else |e| switch (e) {
        error.AstCompilerStageIncomplete => return .pass,
        error.OutOfMemory => return error.OutOfMemory,
    }
}

fn dumpBoth(
    out: anytype,
    filter: []const u8,
    a: legacy.Compiled,
    b: walker.Compiled,
) !void {
    try out.print("  VERBOSE dump for filter=\"{s}\"\n", .{filter});
    try out.writeAll("    legacy:\n");
    for (a.instructions, a.source_map, 0..) |ins, src, i| {
        try dumpInstruction(out, "    ", i, ins, src, a.string_buf);
    }
    try out.writeAll("    walker:\n");
    for (b.instructions, b.source_map, 0..) |ins, src, i| {
        try dumpInstruction(out, "    ", i, ins, src, b.string_buf);
    }
}

test "ast compile equivalence — Stage 1 + Stage 2 + Stage 3 + Stage 4 + Stage 5 + Stage 6 + Stage 7 + Stage 8 + Stage 9 + Stage 10a + Stage 10b + Stage 10c + Stage 11 + Stage 12" {
    const alloc = std.testing.allocator;

    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buf);
    const out = &stderr.interface;

    const total_supported = fixtures.stage1_supported.len +
        fixtures.stage2_supported.len +
        fixtures.stage3_supported.len +
        fixtures.stage4_supported.len +
        fixtures.stage5_supported.len +
        fixtures.stage6_supported.len +
        fixtures.stage7_supported.len +
        fixtures.stage8_supported.len +
        fixtures.stage9_supported.len +
        fixtures.stage10a_supported.len +
        fixtures.stage10b_supported.len +
        fixtures.stage10c_supported.len +
        fixtures.stage11_supported.len +
        fixtures.stage12_supported.len;
    const total_unsupported = fixtures.stage1_unsupported.len +
        fixtures.stage2_unsupported.len +
        fixtures.stage3_unsupported.len +
        fixtures.stage4_unsupported.len +
        fixtures.stage5_unsupported.len +
        fixtures.stage6_unsupported.len +
        fixtures.stage7_unsupported.len +
        fixtures.stage8_unsupported.len +
        fixtures.stage9_unsupported.len +
        fixtures.stage10c_unsupported.len +
        fixtures.stage11_unsupported.len +
        fixtures.stage12_unsupported.len;
    try out.print(
        "ast-compile-equiv: {d} supported + {d} unsupported fixtures\n",
        .{ total_supported, total_unsupported },
    );

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixtures.stage1_supported) |filter| {
        const outcome = try runSupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage2_supported) |filter| {
        const outcome = try runSupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage3_supported) |filter| {
        const outcome = try runSupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage4_supported) |filter| {
        const outcome = try runSupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage5_supported) |filter| {
        const outcome = try runSupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage6_supported) |filter| {
        const outcome = try runSupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage7_supported) |filter| {
        const outcome = try runSupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage8_supported) |filter| {
        const outcome = try runSupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage9_supported) |filter| {
        const outcome = try runSupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage10a_supported) |filter| {
        const outcome = try runSupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage10b_supported) |filter| {
        const outcome = try runSupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage10c_supported) |filter| {
        const outcome = try runSupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage11_supported) |filter| {
        const outcome = try runSupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage12_supported) |filter| {
        const outcome = try runSupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage1_unsupported) |filter| {
        const outcome = try runUnsupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage2_unsupported) |filter| {
        const outcome = try runUnsupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage3_unsupported) |filter| {
        const outcome = try runUnsupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage4_unsupported) |filter| {
        const outcome = try runUnsupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage5_unsupported) |filter| {
        const outcome = try runUnsupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage6_unsupported) |filter| {
        const outcome = try runUnsupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage7_unsupported) |filter| {
        const outcome = try runUnsupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage8_unsupported) |filter| {
        const outcome = try runUnsupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage9_unsupported) |filter| {
        const outcome = try runUnsupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage10c_unsupported) |filter| {
        const outcome = try runUnsupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage11_unsupported) |filter| {
        const outcome = try runUnsupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    for (fixtures.stage12_unsupported) |filter| {
        const outcome = try runUnsupported(alloc, out, filter);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
        }
    }

    try out.print("ast-compile-equiv: {d} passed, {d} failed\n", .{ passed, failed });
    try out.flush();

    if (failed != 0) return error.EquivalenceMismatch;
}
