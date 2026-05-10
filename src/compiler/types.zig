//! Shared compile-time types — the seam between `src/compiler/` and the
//! production query module. Both `lower.zig` and `emit.zig` import this
//! module without depending on each other.
//!
//! `CompileResult` exposes the same field set the legacy compiler does so
//! `src/query/root.zig` can plug either backend behind `the legacy `compile=` flag (` without
//! touching its `CompiledQuery` field set.

const std = @import("std");
const types_mod = @import("types");
const err_mod = @import("error");
const regex_mod = @import("regex");
const prefilter_mod = @import("prefilter");
const projection_plan_mod = @import("projection_plan");

/// Caller-owned compiled bytecode + auxiliary tables. Produced by
/// `src/compiler/root.zig:compile`. The lifetime contract: every
/// slice and pool here is freed by `deinit(allocator)`, where `allocator`
/// is the same one passed to `compile`.
pub const Compiled = struct {
    instructions: []types_mod.Instruction,
    /// MUST be set to a static `&.{}` when empty (NOT `alloc(.., 0)`) —
    /// `Compiled.deinit` cannot distinguish an owned zero-length heap
    /// alloc from a static empty slice, and freeing a non-allocator
    /// pointer crashes under `.safety = true`.
    function_table: []const types_mod.FunctionDef,
    string_buf: []u8,
    external_var_ids: []u32,
    source_map: []u32,
    regex_pool: regex_mod.RegexPool,
    prefilter: ?prefilter_mod.PrefilterSet,
    /// Static projection plan + optional pure-scalar predicate harvested
    /// from the IR. `null` when the filter shape doesn't qualify (any
    /// non-pure op in the projection chain, or any unsupported predicate
    /// shape). Consumed by `parser.feedPlanned` in the pool worker.
    projection_plan: ?projection_plan_mod.ProjectionPlan,

    pub fn deinit(c: *Compiled, alloc: std.mem.Allocator) void {
        alloc.free(c.instructions);
        alloc.free(c.string_buf);
        alloc.free(c.source_map);
        alloc.free(c.external_var_ids);
        c.regex_pool.deinit();
        if (c.prefilter) |*p| p.deinit();
        if (c.projection_plan) |*pp| pp.deinit();
        // `function_table` is owned by emit (one entry per fn_id), with a
        // per-entry `write_set` slice. Frees a no-op for empty cat-9 case
        // since the literal `&.{}` slice is static.
        if (c.function_table.len > 0) {
            for (c.function_table) |def| {
                if (def.write_set.len > 0) alloc.free(def.write_set);
            }
            alloc.free(c.function_table);
        }
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
