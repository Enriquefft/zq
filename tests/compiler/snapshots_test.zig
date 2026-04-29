//! Snapshot tests for `lower.zig`. Each fixture pairs a filter source
//! with the expected IR text dump. The dumper is in `src/compiler/ir.zig`;
//! the format spec is `research/compiler-ir-format.md` §10.
//!
//! Layout: one fixture per `tests/compiler/snapshots/lower/<name>.txt`.
//! The `# source: <filter>` line tells the runner which filter to compile;
//! the rest of the file is the expected dump (including the `# SemOp`
//! banner and the indented IR tree).
//!
//! Plan §3 R3 step 9: regeneration uses `zig build snapshots-update`,
//! which rewrites every fixture from the dumper's current output.
//! Hand-edits to fixture text become drift on the next regen.

const std = @import("std");
const ast = @import("ast");
const compiler = @import("compiler");

/// Embed every snapshot file at comptime so the test binary doesn't
/// shell out to disk during the test run. The fixtures live in
/// `tests/compiler/snapshots/lower/`; when adding a new one, append it
/// to the array below — the build's bundle step copies each path
/// straight into the binary via `@embedFile`.
const Fixture = struct { name: []const u8, expected: []const u8 };

const FIXTURES = [_]Fixture{
    .{ .name = "literal_null", .expected = @embedFile("snapshots/lower/literal_null.txt") },
    .{ .name = "literal_true", .expected = @embedFile("snapshots/lower/literal_true.txt") },
    .{ .name = "literal_false", .expected = @embedFile("snapshots/lower/literal_false.txt") },
    .{ .name = "literal_int", .expected = @embedFile("snapshots/lower/literal_int.txt") },
    .{ .name = "literal_float", .expected = @embedFile("snapshots/lower/literal_float.txt") },
    .{ .name = "literal_string", .expected = @embedFile("snapshots/lower/literal_string.txt") },
    .{ .name = "identity", .expected = @embedFile("snapshots/lower/identity.txt") },
    .{ .name = "recurse", .expected = @embedFile("snapshots/lower/recurse.txt") },
    .{ .name = "unary_neg", .expected = @embedFile("snapshots/lower/unary_neg.txt") },
    .{ .name = "not_zero_arg", .expected = @embedFile("snapshots/lower/not_zero_arg.txt") },
    .{ .name = "type_zero_arg", .expected = @embedFile("snapshots/lower/type_zero_arg.txt") },
    .{ .name = "load_field", .expected = @embedFile("snapshots/lower/load_field.txt") },
    .{ .name = "load_index", .expected = @embedFile("snapshots/lower/load_index.txt") },
    .{ .name = "iterate", .expected = @embedFile("snapshots/lower/iterate.txt") },
    .{ .name = "slice", .expected = @embedFile("snapshots/lower/slice.txt") },
    .{ .name = "try_optional", .expected = @embedFile("snapshots/lower/try_optional.txt") },
    .{ .name = "pipe_simple", .expected = @embedFile("snapshots/lower/pipe_simple.txt") },
    .{ .name = "pipe_chain", .expected = @embedFile("snapshots/lower/pipe_chain.txt") },
    .{ .name = "comma_simple", .expected = @embedFile("snapshots/lower/comma_simple.txt") },
    .{ .name = "comma_pipe_mixed", .expected = @embedFile("snapshots/lower/comma_pipe_mixed.txt") },
    .{ .name = "arith_add", .expected = @embedFile("snapshots/lower/arith_add.txt") },
    .{ .name = "arith_sub", .expected = @embedFile("snapshots/lower/arith_sub.txt") },
    .{ .name = "arith_mul", .expected = @embedFile("snapshots/lower/arith_mul.txt") },
    .{ .name = "arith_div", .expected = @embedFile("snapshots/lower/arith_div.txt") },
    .{ .name = "arith_mod", .expected = @embedFile("snapshots/lower/arith_mod.txt") },
    .{ .name = "arith_chain", .expected = @embedFile("snapshots/lower/arith_chain.txt") },
    .{ .name = "cmp_eq", .expected = @embedFile("snapshots/lower/cmp_eq.txt") },
    .{ .name = "cmp_ne", .expected = @embedFile("snapshots/lower/cmp_ne.txt") },
    .{ .name = "cmp_lt", .expected = @embedFile("snapshots/lower/cmp_lt.txt") },
    .{ .name = "cmp_ge", .expected = @embedFile("snapshots/lower/cmp_ge.txt") },
    .{ .name = "logical_and", .expected = @embedFile("snapshots/lower/logical_and.txt") },
    .{ .name = "logical_or", .expected = @embedFile("snapshots/lower/logical_or.txt") },
    .{ .name = "alt_basic", .expected = @embedFile("snapshots/lower/alt_basic.txt") },
    .{ .name = "alt_chain", .expected = @embedFile("snapshots/lower/alt_chain.txt") },
    .{ .name = "obj_static_keys", .expected = @embedFile("snapshots/lower/obj_static_keys.txt") },
    .{ .name = "obj_computed_keys", .expected = @embedFile("snapshots/lower/obj_computed_keys.txt") },
    .{ .name = "obj_shorthand", .expected = @embedFile("snapshots/lower/obj_shorthand.txt") },
    .{ .name = "arr_simple", .expected = @embedFile("snapshots/lower/arr_simple.txt") },
    .{ .name = "arr_nested", .expected = @embedFile("snapshots/lower/arr_nested.txt") },
    .{ .name = "interp_basic", .expected = @embedFile("snapshots/lower/interp_basic.txt") },
    .{ .name = "interp_nested", .expected = @embedFile("snapshots/lower/interp_nested.txt") },
    .{ .name = "format_at_base64", .expected = @embedFile("snapshots/lower/format_at_base64.txt") },
    .{ .name = "format_at_csv_tail", .expected = @embedFile("snapshots/lower/format_at_csv_tail.txt") },
    .{ .name = "assign_set", .expected = @embedFile("snapshots/lower/assign_set.txt") },
    .{ .name = "assign_add", .expected = @embedFile("snapshots/lower/assign_add.txt") },
    .{ .name = "assign_sub", .expected = @embedFile("snapshots/lower/assign_sub.txt") },
    .{ .name = "assign_mul", .expected = @embedFile("snapshots/lower/assign_mul.txt") },
    .{ .name = "assign_div", .expected = @embedFile("snapshots/lower/assign_div.txt") },
    .{ .name = "assign_mod", .expected = @embedFile("snapshots/lower/assign_mod.txt") },
    .{ .name = "assign_alt", .expected = @embedFile("snapshots/lower/assign_alt.txt") },
    .{ .name = "assign_update", .expected = @embedFile("snapshots/lower/assign_update.txt") },
    .{ .name = "assign_general_iterate", .expected = @embedFile("snapshots/lower/assign_general_iterate.txt") },
    .{ .name = "try_simple", .expected = @embedFile("snapshots/lower/try_simple.txt") },
    .{ .name = "try_catch", .expected = @embedFile("snapshots/lower/try_catch.txt") },
    .{ .name = "if_basic", .expected = @embedFile("snapshots/lower/if_basic.txt") },
    .{ .name = "if_elif", .expected = @embedFile("snapshots/lower/if_elif.txt") },
    .{ .name = "path_simple", .expected = @embedFile("snapshots/lower/path_simple.txt") },
    .{ .name = "path_iterate", .expected = @embedFile("snapshots/lower/path_iterate.txt") },
    .{ .name = "var_load", .expected = @embedFile("snapshots/lower/var_load.txt") },
    .{ .name = "as_simple", .expected = @embedFile("snapshots/lower/as_simple.txt") },
    .{ .name = "destructure_array", .expected = @embedFile("snapshots/lower/destructure_array.txt") },
    .{ .name = "destructure_nested", .expected = @embedFile("snapshots/lower/destructure_nested.txt") },
    .{ .name = "destructure_object", .expected = @embedFile("snapshots/lower/destructure_object.txt") },
    .{ .name = "destructure_object_shorthand", .expected = @embedFile("snapshots/lower/destructure_object_shorthand.txt") },
    .{ .name = "alt_bind", .expected = @embedFile("snapshots/lower/alt_bind.txt") },
    // ── Cat-10 builtin call snapshots — one per IR shape ──────────
    .{ .name = "builtin_length", .expected = @embedFile("snapshots/lower/builtin_length.txt") },
    .{ .name = "builtin_keys", .expected = @embedFile("snapshots/lower/builtin_keys.txt") },
    .{ .name = "builtin_arrays", .expected = @embedFile("snapshots/lower/builtin_arrays.txt") },
    .{ .name = "builtin_now", .expected = @embedFile("snapshots/lower/builtin_now.txt") },
    .{ .name = "builtin_split", .expected = @embedFile("snapshots/lower/builtin_split.txt") },
    .{ .name = "builtin_join", .expected = @embedFile("snapshots/lower/builtin_join.txt") },
    .{ .name = "builtin_has", .expected = @embedFile("snapshots/lower/builtin_has.txt") },
    .{ .name = "builtin_flatten1", .expected = @embedFile("snapshots/lower/builtin_flatten1.txt") },
    .{ .name = "builtin_sort_by", .expected = @embedFile("snapshots/lower/builtin_sort_by.txt") },
    .{ .name = "builtin_map_values", .expected = @embedFile("snapshots/lower/builtin_map_values.txt") },
    .{ .name = "builtin_pow", .expected = @embedFile("snapshots/lower/builtin_pow.txt") },
    .{ .name = "builtin_setpath", .expected = @embedFile("snapshots/lower/builtin_setpath.txt") },
    .{ .name = "builtin_fma", .expected = @embedFile("snapshots/lower/builtin_fma.txt") },
    // ── Cat-11 regex / datetime / arg-builtin snapshots ───────────
    .{ .name = "regex_test_lit", .expected = @embedFile("snapshots/lower/regex_test_lit.txt") },
    .{ .name = "regex_match_g", .expected = @embedFile("snapshots/lower/regex_match_g.txt") },
    .{ .name = "regex_capture", .expected = @embedFile("snapshots/lower/regex_capture.txt") },
    .{ .name = "regex_sub_lit", .expected = @embedFile("snapshots/lower/regex_sub_lit.txt") },
    .{ .name = "regex_gsub_g_subst", .expected = @embedFile("snapshots/lower/regex_gsub_g_subst.txt") },
    .{ .name = "datetime_now", .expected = @embedFile("snapshots/lower/datetime_now.txt") },
    .{ .name = "datetime_strftime", .expected = @embedFile("snapshots/lower/datetime_strftime.txt") },
    .{ .name = "argbuiltin_split", .expected = @embedFile("snapshots/lower/argbuiltin_split.txt") },
    .{ .name = "argbuiltin_pow", .expected = @embedFile("snapshots/lower/argbuiltin_pow.txt") },
    // ── Cat-9 — user-defined functions + recursion + filter args ──
    .{ .name = "udf_simple_def_call", .expected = @embedFile("snapshots/lower/udf_simple_def_call.txt") },
    .{ .name = "udf_filter_arg", .expected = @embedFile("snapshots/lower/udf_filter_arg.txt") },
    .{ .name = "udf_value_arg", .expected = @embedFile("snapshots/lower/udf_value_arg.txt") },
    .{ .name = "udf_recursion", .expected = @embedFile("snapshots/lower/udf_recursion.txt") },
    .{ .name = "udf_mutual_recursion", .expected = @embedFile("snapshots/lower/udf_mutual_recursion.txt") },
    // ── Cat-13 — generator-arg builtins (range/limit/skip/nth/first/last) ──
    .{ .name = "cat-13-range-1", .expected = @embedFile("snapshots/lower/cat-13-range-1.txt") },
    .{ .name = "cat-13-range-2", .expected = @embedFile("snapshots/lower/cat-13-range-2.txt") },
    .{ .name = "cat-13-range-3", .expected = @embedFile("snapshots/lower/cat-13-range-3.txt") },
    .{ .name = "cat-13-limit", .expected = @embedFile("snapshots/lower/cat-13-limit.txt") },
    .{ .name = "cat-13-first-0", .expected = @embedFile("snapshots/lower/cat-13-first-0.txt") },
    .{ .name = "cat-13-first-1", .expected = @embedFile("snapshots/lower/cat-13-first-1.txt") },
    .{ .name = "cat-13-last-0", .expected = @embedFile("snapshots/lower/cat-13-last-0.txt") },
    .{ .name = "cat-13-last-1", .expected = @embedFile("snapshots/lower/cat-13-last-1.txt") },
    .{ .name = "cat-13-nth", .expected = @embedFile("snapshots/lower/cat-13-nth.txt") },
    .{ .name = "cat-13-skip", .expected = @embedFile("snapshots/lower/cat-13-skip.txt") },
    // ── Cat-17 — format builtins (@text/@json/@csv/@tsv/@html/@sh/@uri/@urid/@base64/@base64d) ──
    .{ .name = "cat-17-standalone-base64", .expected = @embedFile("snapshots/lower/cat-17-standalone-base64.txt") },
    .{ .name = "cat-17-standalone-json", .expected = @embedFile("snapshots/lower/cat-17-standalone-json.txt") },
    .{ .name = "cat-17-standalone-uri", .expected = @embedFile("snapshots/lower/cat-17-standalone-uri.txt") },
    .{ .name = "cat-17-pipe-json", .expected = @embedFile("snapshots/lower/cat-17-pipe-json.txt") },
    .{ .name = "cat-17-fmt-string-uri", .expected = @embedFile("snapshots/lower/cat-17-fmt-string-uri.txt") },
    .{ .name = "cat-17-fmt-string-html", .expected = @embedFile("snapshots/lower/cat-17-fmt-string-html.txt") },
    .{ .name = "cat-17-fmt-string-multi-interp", .expected = @embedFile("snapshots/lower/cat-17-fmt-string-multi-interp.txt") },
    // ── Cat-15 — control flow (label/break, until, while) ────────
    .{ .name = "cat-15-label", .expected = @embedFile("snapshots/lower/cat-15-label.txt") },
    .{ .name = "cat-15-label-break", .expected = @embedFile("snapshots/lower/cat-15-label-break.txt") },
    .{ .name = "cat-15-label-nested", .expected = @embedFile("snapshots/lower/cat-15-label-nested.txt") },
    .{ .name = "cat-15-until", .expected = @embedFile("snapshots/lower/cat-15-until.txt") },
    .{ .name = "cat-15-while", .expected = @embedFile("snapshots/lower/cat-15-while.txt") },
    // ── Cat-16 (P25) — error 0/1-arity, index/rindex/indices, del general forms ──
    .{ .name = "cat-16-error-0arg", .expected = @embedFile("snapshots/lower/cat-16-error-0arg.txt") },
    .{ .name = "cat-16-error-1arg", .expected = @embedFile("snapshots/lower/cat-16-error-1arg.txt") },
    .{ .name = "cat-16-index", .expected = @embedFile("snapshots/lower/cat-16-index.txt") },
    .{ .name = "cat-16-rindex", .expected = @embedFile("snapshots/lower/cat-16-rindex.txt") },
    .{ .name = "cat-16-indices", .expected = @embedFile("snapshots/lower/cat-16-indices.txt") },
    // Generator-arg form — `comma` SemOp child captures the
    // alternation; emit's `value_arg1_gen` arm dispatches per
    // fork branch via the natural `comma` fork/jump bytecode.
    .{ .name = "cat-16-indices-gen", .expected = @embedFile("snapshots/lower/cat-16-indices-gen.txt") },
    .{ .name = "cat-16-del-simple", .expected = @embedFile("snapshots/lower/cat-16-del-simple.txt") },
    // Multi-path `del(.a, .b)` — comma generates two paths, both
    // collected by emit-time path_begin/path_end pipeline.
    .{ .name = "cat-16-del-multi", .expected = @embedFile("snapshots/lower/cat-16-del-multi.txt") },
    // Array-slice path — exercises `slice` SemOp inside del's
    // path expression child.
    .{ .name = "cat-16-del-array-slice", .expected = @embedFile("snapshots/lower/cat-16-del-array-slice.txt") },
    // ── Cat-18 (P27) — dynamic regex + computed bracket access ──
    .{ .name = "cat-18-regex-test-dynamic", .expected = @embedFile("snapshots/lower/cat-18-regex-test-dynamic.txt") },
    .{ .name = "cat-18-regex-sub-dynamic", .expected = @embedFile("snapshots/lower/cat-18-regex-sub-dynamic.txt") },
    .{ .name = "cat-18-bracket-standalone", .expected = @embedFile("snapshots/lower/cat-18-bracket-standalone.txt") },
    // Standalone generator-form key — exercises the `dumpAst` arm
    // for `__computed_access(BuiltinCall)` (distinct code path from
    // the suffix-form renderer).
    .{ .name = "cat-18-bracket-standalone-gen", .expected = @embedFile("snapshots/lower/cat-18-bracket-standalone-gen.txt") },
    // Lock-in for the `unreachable` invariant in `dumpSuffixOp` —
    // exercises a suffix chain with `bracket_expr` in non-tail
    // position (`.arr[$i].name`); the renderer recursion handles it
    // via the tail-special-case at every depth.
    .{ .name = "cat-18-bracket-mid-chain", .expected = @embedFile("snapshots/lower/cat-18-bracket-mid-chain.txt") },
    .{ .name = "cat-18-bracket-array-base", .expected = @embedFile("snapshots/lower/cat-18-bracket-array-base.txt") },
    .{ .name = "cat-18-bracket-expr-key", .expected = @embedFile("snapshots/lower/cat-18-bracket-expr-key.txt") },
    // ── Cat-14 (P23) — reduce / foreach + as-pattern body fix ───
    .{ .name = "cat-14-reduce", .expected = @embedFile("snapshots/lower/cat-14-reduce.txt") },
    .{ .name = "cat-14-reduce-range", .expected = @embedFile("snapshots/lower/cat-14-reduce-range.txt") },
    .{ .name = "cat-14-foreach-4arg", .expected = @embedFile("snapshots/lower/cat-14-foreach-4arg.txt") },
    .{ .name = "cat-14-foreach-5arg", .expected = @embedFile("snapshots/lower/cat-14-foreach-5arg.txt") },
    .{ .name = "cat-14-as-pattern-fixed", .expected = @embedFile("snapshots/lower/cat-14-as-pattern-fixed.txt") },
};

/// Extract the filter source text from a snapshot's `# source:` directive
/// (always the first line).
fn extractSource(snapshot: []const u8) []const u8 {
    const prefix = "# source: ";
    std.debug.assert(std.mem.startsWith(u8, snapshot, prefix));
    const after = snapshot[prefix.len..];
    const newline = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
    return after[0..newline];
}

test "snapshot fixtures: lower" {
    const alloc = std.testing.allocator;
    inline for (FIXTURES) |fx| {
        const filter = extractSource(fx.expected);

        // Parse → lower → dump.
        var parse_result = ast.parse(filter, alloc);
        defer parse_result.deinit();
        try std.testing.expect(!parse_result.hasErrors());

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        var lowerer = compiler.Lowerer{
            .arena = &arena,
            .src = filter,
            .out = compiler.IR.init(&arena),
            .opts = .{},
            .pool_alloc = alloc,
        };
        defer lowerer.deinitRegexPool();
        _ = try compiler.lowerNode(&lowerer, parse_result.root);

        var actual_buf: std.ArrayList(u8) = .{};
        defer actual_buf.deinit(alloc);
        try compiler.dump(&lowerer.out, parse_result.root, filter, actual_buf.writer(alloc));

        std.testing.expectEqualStrings(fx.expected, actual_buf.items) catch |e| {
            std.debug.print(
                "snapshot mismatch: {s}\n--- expected ---\n{s}\n--- actual ---\n{s}\n",
                .{ fx.name, fx.expected, actual_buf.items },
            );
            return e;
        };
    }
}
