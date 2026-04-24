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
            "  MISMATCH filter=\"{s}\": instruction count differs legacy={d} walker={d}\n",
            .{ filter, a_ins.len, b_ins.len },
        );
        return false;
    }
    if (a_src.len != b_src.len) {
        try out.print(
            "  MISMATCH filter=\"{s}\": source_map count differs legacy={d} walker={d}\n",
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
            try out.print("  MISMATCH filter=\"{s}\" at index {d}:\n", .{ filter, i });
            try out.writeAll("    legacy:\n");
            try dumpInstruction(out, "    ", i, ai, as, a_buf);
            try out.writeAll("    walker:\n");
            try dumpInstruction(out, "    ", i, bi, bs, b_buf);
            return false;
        }
    }

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
                const ok = try diffCompiled(
                    out,
                    filter,
                    a.instructions,
                    a.source_map,
                    a.string_buf,
                    b.instructions,
                    b.source_map,
                    b.string_buf,
                );
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

test "ast compile equivalence — Stage 1 + Stage 2 + Stage 3 + Stage 4 + Stage 5 + Stage 6 + Stage 7 + Stage 8 + Stage 9 + Stage 10a + Stage 10b + Stage 10c + Stage 11" {
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
        fixtures.stage11_supported.len;
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
        fixtures.stage11_unsupported.len;
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

    try out.print("ast-compile-equiv: {d} passed, {d} failed\n", .{ passed, failed });
    try out.flush();

    if (failed != 0) return error.EquivalenceMismatch;
}
