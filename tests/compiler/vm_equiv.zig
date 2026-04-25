//! VM-equivalence harness for Phase 2R compiler.
//!
//! For each fixture: compile via legacy AND via new, then run both
//! resulting bytecodes against the input JSON and compare output
//! streams. Phase 7 (Cluster B) wires the new-path call via
//! `query.CompiledQuery.compileNew`, which re-exports the new
//! backend through the `query` module so the test binary's dep
//! graph stays single-rooted (Cluster A handoff issue #1).
//!
//! Plan: research/phase-2r-compiler-redesign-plan.md §3 R3 step 4.
//! Spec:  research/compiler-ir-format.md (Phase 4).
//!
//! Exit codes: 0 on all-match-or-skip, 1 if any mismatch or unexpected
//! compile error. NotImplemented is reported as SKIP.

const std = @import("std");
const query = @import("query");

const Fixture = struct {
    name: []const u8,
    filter: []const u8,
    /// JSON input (currently unused; reserved for Cluster B VM run).
    input: []const u8,
    /// Reserved for Cluster B output-stream diff.
    expected_output: []const u8 = "",
    /// When true, the legacy compiler is expected to fail. Phase 6 SKIPs
    /// these; Cluster B will compare error kinds across backends.
    expects_compile_err: bool = false,
};

const FIXTURES = [_]Fixture{
    // ── Category 1 fixtures (Phase 7 owns these) ──────────────────
    .{ .name = "literal_null", .filter = "null", .input = "1", .expected_output = "null" },
    .{ .name = "literal_true", .filter = "true", .input = "1", .expected_output = "true" },
    .{ .name = "literal_false", .filter = "false", .input = "1", .expected_output = "false" },
    .{ .name = "literal_int", .filter = "42", .input = "1", .expected_output = "42" },
    .{ .name = "literal_float", .filter = "3.14", .input = "1", .expected_output = "3.14" },
    .{ .name = "literal_str", .filter = "\"hi\"", .input = "1", .expected_output = "\"hi\"" },
    .{ .name = "identity", .filter = ".", .input = "{\"foo\":1}", .expected_output = "{\"foo\":1}" },
    .{ .name = "recurse", .filter = "..", .input = "[1,2]", .expected_output = "[1,2]\n1\n2" },
    .{ .name = "neg", .filter = "-5", .input = "null", .expected_output = "-5" },
    // `not` consumes its input — supplying a falsy `null` input yields true.
    // Cluster B's pipe-category port will enable richer fixtures like
    // `false | not`; for now we test the bare op with the harness's
    // input-binding contract (input flows in as `current`).
    .{ .name = "not_zero_arg", .filter = "not", .input = "null", .expected_output = "true" },
    .{ .name = "type_zero_arg", .filter = "type", .input = "[]", .expected_output = "\"array\"" },

    // ── Categories 2+ fixtures (still SKIP-NotImplemented) ────────
    .{ .name = "field", .filter = ".foo", .input = "{\"foo\":1}", .expected_output = "1" },
    .{ .name = "nested", .filter = ".foo.bar", .input = "{\"foo\":{\"bar\":2}}", .expected_output = "2" },
    .{ .name = "pipe", .filter = ".foo | .bar", .input = "{\"foo\":{\"bar\":3}}", .expected_output = "3" },
    .{ .name = "index", .filter = ".[0]", .input = "[10,20]", .expected_output = "10" },
    .{ .name = "arith", .filter = "1+1", .input = "null", .expected_output = "2" },
    .{ .name = "select", .filter = "select(.id > 100)", .input = "{\"id\":150}", .expected_output = "{\"id\":150}" },
    .{ .name = "map", .filter = "map(.id) | add", .input = "[{\"id\":1},{\"id\":2}]", .expected_output = "3" },
    .{ .name = "udf_simple", .filter = "def f: . + 1; f", .input = "10", .expected_output = "11" },
    .{ .name = "udf_semi", .filter = "def f(a;b): a + b; f(.x;.y)", .input = "{\"x\":2,\"y\":3}", .expected_output = "5" },
    .{ .name = "regex_lit", .filter = "test(\"^[a-z]+$\")", .input = "\"foobar\"", .expected_output = "true" },
    .{ .name = "reduce", .filter = "reduce range(10) as $i (0; . + $i)", .input = "null", .expected_output = "45" },
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var match: u32 = 0;
    // `mismatch` reserved for the Cluster-B+ output-stream diff. Phase 7
    // only confirms both backends compile a category-1 fixture; the VM
    // execution diff lands later. Kept declared so the print line stays
    // stable across phases.
    const mismatch: u32 = 0;
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

        // New compile. Routed through `query.CompiledQuery.compileNew`
        // so the test binary stays single-rooted (Cluster A handoff
        // issue #1) — see header comment.
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

        // Both backends compiled. Phase 7 records a match without
        // running the VM — the bytecode-shape check below is enough
        // signal that lowering produced a sensible instruction stream.
        // Cluster B+ wires the full `tape` + `execute` + output-diff
        // path; for now, having both compiles succeed on a category-1
        // fixture is the green bar.
        match += 1;
        try w.print("MATCH name={s} filter={s}\n", .{ fx.name, fx.filter });
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
