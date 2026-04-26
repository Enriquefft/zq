//! Phase 2R compiler — public entry point. Wired into the production
//! `query.CompiledQuery.compile` dispatcher; only invoked when the
//! build is configured with `-Dcompile=new`.
//!
//! Pipeline shape (plan §1.1):
//!
//!   src → ast.parse → AST → lower → IR → fuse → IR → emit → CompileResult
//!
//! Categories landed: cat-1 (literals/identity/recurse/unary), cat-2
//! (field/index/iterate/slice + postfix `?`), cat-3 (pipe/comma),
//! cat-4 (vars/destructure/alt-bind), cat-5 (arith/cmp/logical/alt),
//! cat-6 (try/catch/if/path), cat-7 (obj/arr/interp/format), cat-8
//! (update_assign), cat-10 (general builtins) and cat-11 (regex /
//! datetime / extended arg-builtins). Other AST shapes surface as
//! `error.NewCompilerNotImplemented`; the harness reports SKIP and
//! the production dispatcher falls back to legacy.
const std = @import("std");

const ast = @import("ast");
const ir_mod = @import("ir.zig");
const lower_mod = @import("lower.zig");
const fuse_mod = @import("fuse.zig");
const emit_mod = @import("emit.zig");
const ctypes = @import("types.zig");
const harvest_mod = @import("harvest.zig");

// Re-export for downstream callers / tests (snapshot harness reaches
// in for `Lowerer` + `lowerNode` + `dump` to drive the dumper without
// going through `compile()`).
pub const Op = ir_mod.Op;
pub const Node = ir_mod.Node;
pub const IR = ir_mod.IR;
pub const dump = ir_mod.dump;
/// IR-walking dumper (vs `dump` which walks the AST). Used by the
/// fuse snapshot harness to render the post-rewrite IR shape.
pub const dumpIR = ir_mod.dumpIR;
pub const Lowerer = lower_mod.Lowerer;
pub const lowerNode = lower_mod.lowerNode;
/// Fuse pass entry point — see `fuse.zig` for the rewrite rules.
/// Snapshot tests import this directly to drive the IR-level diff.
pub const fuse = fuse_mod.fuse;
pub const FuseResult = fuse_mod.Result;

// Re-export the legacy-shape result types so callers can speak in our
// vocabulary without dragging the compiler module's internals in.
pub const Compiled = ctypes.Compiled;
pub const CompileResult = ctypes.CompileResult;
pub const ExternalVarDecl = ctypes.ExternalVarDecl;

/// Compile a filter source string with the new VM-semantics compiler.
///
/// On success, returns `.ok` carrying owned bytecode + auxiliary
/// tables (see `Compiled`). On compile error, returns `.err` with
/// `(kind, offset, len)` matching the legacy compiler's diagnostic
/// shape. AST shapes outside the supported categories surface as
/// `error.NewCompilerNotImplemented`.
pub fn compile(
    src: []const u8,
    external_vars: []const ExternalVarDecl,
    allocator: std.mem.Allocator,
) error{ OutOfMemory, NewCompilerNotImplemented }!CompileResult {
    // Stage 1: parse. Always succeeds; errors live in `parse_result.errors`.
    var parse_result = ast.parse(src, allocator);
    defer parse_result.deinit();

    if (parse_result.hasErrors()) {
        // Surface the first parse error as a compile-error diagnostic
        // matching the legacy shape (kind, offset, len). The harness's
        // errpos guardrail compares triples, so we map the AST error
        // span back to byte offsets directly.
        const first = parse_result.errors[0];
        return .{ .err = .{
            .kind = .query_syntax_error,
            .offset = first.span.start,
            .len = if (first.span.end >= first.span.start) first.span.end - first.span.start else 0,
        } };
    }

    // Stage 2: lower AST → IR. The arena is local to this compile call;
    // the IR is dropped after emit (plan §1.3 row 1).
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // `pool_alloc = allocator` wires the regex pool to the same
    // allocator that owns `Compiled`, so the pool transfers cleanly
    // through emit into the final result. The pool is taken via
    // `takeRegexPool()` once emit succeeds; the `defer
    // deinitRegexPool()` below frees it on every other path.
    var lowerer = lower_mod.Lowerer{
        .arena = &arena,
        .src = src,
        .out = ir_mod.IR.init(&arena),
        .opts = .{},
        .pool_alloc = allocator,
    };
    defer lowerer.deinitRegexPool();

    // Pre-declare external variables in the root scope (var ids 0..N-1).
    // Mirrors legacy `compile`'s seeding at
    // `src/query/src/compiler.zig:1390-1406`. Required so cat-4
    // `$external_var` references resolve to the same operand index.
    for (external_vars) |ev| {
        _ = lowerer.declareVar(ev.name) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    _ = lower_mod.lowerNode(&lowerer, parse_result.root) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NewCompilerNotImplemented => return error.NewCompilerNotImplemented,
        // Lowering diagnostic (e.g. invalid `\v` string escape, regex
        // compile failure). Surface as `.err` matching legacy's
        // diagnostic shape.
        error.LowerDiagnostic => return .{ .err = lowerer.compile_err },
    };
    const lowered = lowerer.out;

    // Stage 3: fuse — chained `.a | .b | .c` collapses to one
    // `load_path` EmitOp (Phase 19, plan §3 R3 step 8). The pass
    // returns a fresh IR whose node ordering differs from `lowered`,
    // so any auxiliary table that points into the IR by node index
    // (cat-9 `function_table.body_ir_root`) must be re-pointed via
    // `index_map`. Untouched table entries (`BODY_IR_NOT_LOWERED`
    // sentinel) pass through unchanged.
    const fuse_result = try fuse_mod.fuse(lowered);
    const fused = fuse_result.ir;
    for (lowerer.function_table.items) |*entry| {
        if (entry.body_ir_root == lower_mod.BODY_IR_NOT_LOWERED) continue;
        entry.body_ir_root = fuse_result.index_map[entry.body_ir_root];
    }

    // Stage 4: emit IR → bytecode. The emitter copies bytes the VM
    // needs into the caller's allocator; the IR arena is freed by
    // `defer` above. The regex pool transfers ownership from the
    // lowerer to the emitted `Compiled` — `takeRegexPool` clears the
    // lowerer's slot so the top-level `deinitRegexPool` defer
    // becomes a no-op. `external_vars.len` flows in so emit allocates
    // `external_var_ids` at the final size in one shot. The lowerer's
    // `function_table` snapshot threads through to emit so cat-9
    // `call_user` IR nodes can resolve to body_ir_root + canonical
    // var_ids without re-traversing the AST.
    const pool = lowerer.takeRegexPool();
    var pool_consumed = false;
    errdefer if (!pool_consumed) {
        var p = pool;
        p.deinit();
    };
    var compiled = emit_mod.emit(
        fused,
        external_vars.len,
        lowerer.function_table.items,
        lowerer.next_var_id,
        pool,
        allocator,
    ) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NewCompilerNotImplemented => return error.NewCompilerNotImplemented,
    };
    pool_consumed = true; // emit owns the pool now (transferred into `compiled`).
    var compiled_consumed = false;
    defer if (!compiled_consumed) compiled.deinit(allocator);

    // Stage 5: harvest prefilter literals from IR (Phase 18).
    // Read-only IR walk; no mutations. The IR is still valid because
    // `arena` hasn't been freed yet (the defer above runs on return).
    // On OOM or harvest failure, we simply skip the prefilter — the
    // filter still runs correctly without it.
    const prefilter = @import("prefilter");
    var literal_groups: std.ArrayList(harvest_mod.LiteralGroup) = .{};
    const harvest_result = harvest_mod.harvestFromIr(
        allocator,
        &fused,
        &compiled.regex_pool,
        &literal_groups,
    );
    if (harvest_result) |_| {
        // Transfer ownership into compiled.prefilter.
        if (literal_groups.items.len > 0) {
            // Convert to the legacy PrefilterSet format.
            var legacy_groups = std.ArrayList(prefilter.LiteralGroup){};
            try legacy_groups.ensureTotalCapacity(allocator, literal_groups.items.len);
            for (literal_groups.items) |g| {
                legacy_groups.appendAssumeCapacity(.{
                    .literals = g.literals,
                    .all_required = g.all_required,
                });
            }
            compiled.prefilter = try prefilter.PrefilterSet.ownFrom(
                allocator,
                legacy_groups.items,
            );
        }
    } else |err| switch (err) {
        error.OutOfMemory => {
            // OOM during harvest: fall back to no prefilter. Clean up
            // any partial groups in the list.
            for (literal_groups.items) |g| {
                for (g.literals) |lit| allocator.free(lit);
                allocator.free(g.literals);
            }
        },
    }

    compiled_consumed = true;
    return .{ .ok = compiled };
}
