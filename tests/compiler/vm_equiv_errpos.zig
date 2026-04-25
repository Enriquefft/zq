//! Source-position parity for compile errors.
//!
//! Plan §1.4 row 5 — exact match on `(kind, offset, len)` between the
//! legacy and new compilers for a curated corpus of malformed filters.
//! Each fixture's expected triple is discovered by running
//! `zig build vm-equiv-probe` and transcribing the legacy compiler's
//! emission. Do NOT invent values.

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

/// Populated from `zig build vm-equiv-probe` output. The legacy compiler
/// reports every syntax-shape error as `query_syntax_error` with a
/// zero-length span pointing at the offending position; the new backend
/// must reproduce that triple.
const FIXTURES = [_]ErrFixture{
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
    var passed: u32 = 0;
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

        // New-backend side. Errors matching the legacy triple count as
        // PASS; mismatches surface loudly. NotImplemented is SKIP.
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
            .ok => {
                try w.print("NEW_OK_UNEXPECTED name={s} filter={s}\n", .{ fx.name, fx.filter });
                legacy_unexpected_ok += 1;
                continue;
            },
            .err => |ne| {
                const new_kind_name = @tagName(ne.kind);
                if (!std.mem.eql(u8, new_kind_name, fx.expected_kind) or
                    ne.offset != fx.expected_offset or
                    ne.len != fx.expected_len)
                {
                    try w.print(
                        "NEW_DRIFT name={s} filter={s} expected={s}@{d}+{d} got={s}@{d}+{d}\n",
                        .{
                            fx.name,
                            fx.filter,
                            fx.expected_kind,
                            fx.expected_offset,
                            fx.expected_len,
                            new_kind_name,
                            ne.offset,
                            ne.len,
                        },
                    );
                    legacy_kind_drift += 1;
                    continue;
                }
            },
        }

        passed += 1;
        try w.print("PASS name={s} kind={s} offset={d} len={d}\n", .{
            fx.name,
            fx.expected_kind,
            fx.expected_offset,
            fx.expected_len,
        });
    }

    try w.print("\nvm_equiv_errpos: total={d} passed={d} skipped={d} legacy_unexpected_ok={d} legacy_drift={d}\n", .{
        FIXTURES.len,
        passed,
        skipped,
        legacy_unexpected_ok,
        legacy_kind_drift,
    });

    try std.fs.File.stdout().writeAll(stdout_buf.items);

    if (legacy_unexpected_ok > 0 or legacy_kind_drift > 0) std.process.exit(1);
}
