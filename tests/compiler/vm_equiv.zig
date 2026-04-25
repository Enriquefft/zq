//! VM-equivalence harness for Phase 2R compiler.
//!
//! For each fixture: compile via legacy AND via new, then compare outputs
//! when both compile successfully. At Phase 6 the new path returns
//! `error.NewCompilerNotImplemented` for every fixture → all SKIP. Cluster B
//! retrofits VM-execution + output-stream diff once operator categories land.
//!
//! Plan: research/phase-2r-compiler-redesign-plan.md §3 R3 step 4.
//! Spec:  research/compiler-ir-format.md (Phase 4).
//!
//! Exit codes: 0 on all-match-or-skip, 1 if any mismatch or unexpected
//! compile error. Phase 6 default: 0 (everything skipped).
//!
//! Module note: the harness reaches the legacy backend through
//! `query.CompiledQuery.compileLegacy` (re-exported on the `query` module)
//! rather than importing `compiler` directly. The "new" path is stubbed at
//! Phase 6 — every fixture is reported SKIP — so the harness does not yet
//! need a runtime call into `src/compiler/`. Cluster B+ wires that in once
//! the new backend can produce a real `CompileResult`.

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

    // Phase 6 placeholder counters. `match` / `mismatch` stay at 0
    // until Cluster B+ wires the real new-backend invocation; they
    // are kept as `const` so the binary compiles cleanly and the
    // print statement below stays in the post-Phase-6 layout.
    const match: u32 = 0;
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
                // Expected compile error → SKIP for now (Cluster B will
                // compare error kinds across backends).
                skipped += 1;
                try w.print("SKIP name={s} reason=expected-compile-err\n", .{fx.name});
                continue;
            },
            .ok => {},
        }

        // New compile — Phase 6 stub. The new backend (`src/compiler/`)
        // currently always returns `error.NewCompilerNotImplemented`, so
        // wiring an actual call here at scaffold time would be a noop.
        // We hard-code the SKIP to keep the test binary's dep graph free
        // of a duplicate `compiler` import (which under Zig 0.15.2's build
        // runner produces a malformed link output via `--listen=-`).
        //
        // TODO(Cluster B): switch this to a real call into the new
        // backend once it returns `CompileResult` for at least one
        // fixture. At that point: diff legacy/new instruction streams,
        // then run the VM on `fx.input` against both and compare output
        // JSON value-by-value.
        skipped += 1;
        try w.print("SKIP name={s} reason=new-compiler-not-implemented\n", .{fx.name});
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
