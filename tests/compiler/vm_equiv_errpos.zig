//! Source-position parity for compile errors. Phase 6 scaffold.
//!
//! Plan §1.4 row 5 — exact match on `(kind, offset, len)` between the
//! legacy and new compilers for a curated corpus of malformed filters.
//! At Phase 6 the new backend always returns `NewCompilerNotImplemented`,
//! so every fixture is reported as SKIP and the binary exits 0.
//!
//! Cluster B+ retrofits the actual comparison once the new compiler can
//! emit `CompileResult.err` for these cases.
//!
//! Authoring note: each fixture's expected triple was discovered by
//! running `zig build vm-equiv-probe` (see `tests/vm_equiv_probe.zig`)
//! and transcribing the legacy compiler's actual emission. Do NOT invent
//! values.
//!
//! Module note: see `tests/vm_equiv.zig` — same dep-graph constraint.

const std = @import("std");
const query = @import("query");

const ErrFixture = struct {
    name: []const u8,
    filter: []const u8,
    /// `@tagName` of the expected `err_mod.ErrorKind`.
    expected_kind: []const u8,
    expected_offset: u32,
    expected_len: u32,
};

/// Populated from `zig build vm-equiv-probe` output. Phase 6 ships these
/// as legacy-side sanity checks; the cross-backend comparison only fires
/// once Cluster B+ wires the new backend's compile-error path.
const FIXTURES = [_]ErrFixture{
    // Triples below transcribed from `zig build vm-equiv-probe` on
    // commit 9d70ce2 (Phase 5). The legacy compiler reports every
    // syntax-shape error as `query_syntax_error` with a zero-length
    // span pointing at the offending position; that's the contract
    // the new backend must reproduce.
    .{ .name = "unclosed_str", .filter = "\"foo", .expected_kind = "query_syntax_error", .expected_offset = 0, .expected_len = 0 },
    .{ .name = "trailing_pipe", .filter = ". |", .expected_kind = "query_syntax_error", .expected_offset = 3, .expected_len = 0 },
    .{ .name = "trailing_arith", .filter = "1 +", .expected_kind = "query_syntax_error", .expected_offset = 3, .expected_len = 0 },
    .{ .name = "open_bracket", .filter = ".[", .expected_kind = "query_syntax_error", .expected_offset = 2, .expected_len = 0 },
    .{ .name = "incomplete_def", .filter = "def f", .expected_kind = "query_syntax_error", .expected_offset = 5, .expected_len = 0 },
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var skipped: u32 = 0;
    var legacy_unexpected_ok: u32 = 0;
    var legacy_kind_drift: u32 = 0;

    var stdout_buf: std.ArrayList(u8) = .{};
    defer stdout_buf.deinit(alloc);
    const w = stdout_buf.writer(alloc);

    for (FIXTURES) |fx| {
        var legacy_result = try query.CompiledQuery.compileLegacy(fx.filter, .{}, alloc);
        defer switch (legacy_result) {
            .ok => |*cq| cq.deinit(),
            .err => {},
        };

        const legacy_err = switch (legacy_result) {
            .err => |ce| ce,
            .ok => {
                // Legacy unexpectedly accepted a filter we believed was
                // malformed — fixture is wrong. Surface loudly so the
                // corpus can be re-probed.
                try w.print("LEGACY_OK_UNEXPECTED name={s} filter={s}\n", .{ fx.name, fx.filter });
                legacy_unexpected_ok += 1;
                continue;
            },
        };

        // Legacy-side sanity: kind/offset/len must match what the probe
        // recorded at authoring time. If this drifts, regenerate the
        // corpus via `zig build vm-equiv-probe`.
        const legacy_kind_name = @tagName(legacy_err.kind);
        if (!std.mem.eql(u8, legacy_kind_name, fx.expected_kind) or
            legacy_err.offset != fx.expected_offset or
            legacy_err.len != fx.expected_len)
        {
            try w.print(
                "LEGACY_DRIFT name={s} filter={s} expected={s}@{d}+{d} got={s}@{d}+{d}\n",
                .{
                    fx.name,
                    fx.filter,
                    fx.expected_kind,
                    fx.expected_offset,
                    fx.expected_len,
                    legacy_kind_name,
                    legacy_err.offset,
                    legacy_err.len,
                },
            );
            legacy_kind_drift += 1;
            continue;
        }

        // New-backend side — Phase 6: hard-coded SKIP. Same rationale as
        // `tests/vm_equiv.zig` (avoid duplicate `compiler` module in the
        // test binary's dep graph). Cluster B+ wires the real call.
        skipped += 1;
        try w.print("SKIP name={s} reason=new-compiler-not-implemented\n", .{fx.name});
    }

    try w.print("\nvm_equiv_errpos: total={d} skipped={d} legacy_unexpected_ok={d} legacy_drift={d}\n", .{
        FIXTURES.len,
        skipped,
        legacy_unexpected_ok,
        legacy_kind_drift,
    });

    try std.fs.File.stdout().writeAll(stdout_buf.items);

    if (legacy_unexpected_ok > 0 or legacy_kind_drift > 0) std.process.exit(1);
}
