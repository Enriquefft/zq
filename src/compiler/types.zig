//! Shared compile-time types — the seam between `src/compiler/` and the
//! production query module.
//!
//! Plan §2R, handoff issue #10: `lower.zig` and `emit.zig` cannot share a
//! `CompileResult` shape via `query` (which already depends on the new
//! compiler), and emitting via `*const anyopaque` was banned. This module
//! is the third leg: both sides import `types.zig` and never each other.
//!
//! Plan §1.3 row 7 (verbatim): `CompileResult` exposes only legacy-shape
//! fields — `instructions`, `function_table`, `string_buf`,
//! `external_var_ids`, `source_map`, `regex_pool`, `prefilter`. The new
//! compiler matches that shape exactly so `src/query/root.zig` can plug
//! either backend behind the `-Dcompile=` switch without touching its
//! `CompiledQuery` field set.
//!
//! No state lives here — this is the contract layer. New types (e.g. an
//! eventual `parse_plan`) are added when the first consumer needs them,
//! per plan §1.3 row 7.

const std = @import("std");
const types_mod = @import("types");
const err_mod = @import("error");
const regex_mod = @import("regex");
const prefilter_mod = @import("prefilter");

/// Caller-owned compiled bytecode + auxiliary tables. Field-for-field
/// identical to the legacy compiler's `Compiled` struct in
/// `src/query/src/compiler.zig:21`. The lifetime contract matches: every
/// slice and pool here is freed by `deinit(allocator)`, where `allocator`
/// is the same one passed to `compile`.
pub const Compiled = struct {
    instructions: []types_mod.Instruction,
    function_table: []const types_mod.FunctionDef,
    string_buf: []u8,
    external_var_ids: []u32,
    source_map: []u32,
    regex_pool: regex_mod.RegexPool,
    prefilter: ?prefilter_mod.PrefilterSet,

    pub fn deinit(c: *Compiled, alloc: std.mem.Allocator) void {
        alloc.free(c.instructions);
        alloc.free(c.string_buf);
        alloc.free(c.source_map);
        alloc.free(c.external_var_ids);
        c.regex_pool.deinit();
        if (c.prefilter) |*p| p.deinit();
        // `function_table` is sliced from `string_buf` per plan §1.3 row 7
        // — no separate free needed; mirrors legacy.
    }
};

/// Compile result: `.ok` carries owned bytecode; `.err` carries a
/// structured compile error with source position. Identical shape to
/// `query.CompileResult`; the dispatcher in `src/query/root.zig` adapts
/// straight across without re-wrapping.
pub const CompileResult = union(enum) {
    ok: Compiled,
    err: err_mod.CompileError,
};

/// External variable declaration — pre-declared in the root scope before
/// compile starts. Matches `query.CompiledQuery.Opts.external_vars`.
pub const ExternalVarDecl = struct {
    name: []const u8,
};
