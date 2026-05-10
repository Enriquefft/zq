//! Phase 2R compiler — public entry point. Sole compile path post
//! Phase 2R cutover; `query.CompiledQuery.compile` dispatches here
//! unconditionally.
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
//! datetime / extended arg-builtins). Every category lowers; gaps
//! panic.
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
/// Subtree variant of `dumpIR` — renders an arbitrary IR root, used
/// by the fuse snapshot harness to surface cat-9 function bodies that
/// live off the main IR root via `function_table.body_ir_root`.
pub const dumpIRSubtree = ir_mod.dumpIRSubtree;
pub const Lowerer = lower_mod.Lowerer;
pub const lowerNode = lower_mod.lowerNode;
/// Fuse pass entry point — see `fuse.zig` for the rewrite rules.
/// Snapshot tests import this directly to drive the IR-level diff.
pub const fuse = fuse_mod.fuse;
pub const FuseResult = fuse_mod.Result;
/// Sentinel value used by `function_table.body_ir_root` to mean
/// "not yet lowered". Surfaced so snapshot tests can skip recursive
/// UDFs whose body lowering is deferred to the first emit-site.
pub const BODY_IR_NOT_LOWERED = lower_mod.BODY_IR_NOT_LOWERED;

// Re-export the legacy-shape result types so callers can speak in our
// vocabulary without dragging the compiler module's internals in.
pub const Compiled = ctypes.Compiled;
pub const CompileResult = ctypes.CompileResult;
pub const ExternalVarDecl = ctypes.ExternalVarDecl;

/// Module-system options threaded into `compile()`. The fixture-root
/// `module_search_path` plus optional `current_file_dir` together feed
/// the resolver's lookup chain. Callers that don't use the module
/// system pass `.{}`.
pub const ModuleOpts = struct {
    module_search_path: []const []const u8 = &.{},
    current_file_dir: ?[]const u8 = null,
};

/// Compile a filter source string with the VM-semantics compiler.
///
/// On success, returns `.ok` carrying owned bytecode + auxiliary
/// tables (see `Compiled`). On compile error, returns `.err` with
/// `(kind, offset, len)`. Post Phase 2R cutover every supported
/// category lowers; lower/emit gaps are panics, not soft errors.
pub fn compile(
    src: []const u8,
    external_vars: []const ExternalVarDecl,
    module_opts: ModuleOpts,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!CompileResult {
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
        .module_search_path = module_opts.module_search_path,
        .current_file_dir = module_opts.current_file_dir,
    };
    defer lowerer.deinitRegexPool();
    defer lowerer.deinitResolver();

    // Pre-declare external variables in the root scope (var ids 0..N-1).
    // Required so cat-4 `$external_var` references resolve to the correct
    // operand index — var_id assignment order must match the order in which
    // `external_vars` is passed by the caller (`src/query/root.zig`).
    for (external_vars) |ev| {
        _ = lowerer.declareVar(ev.name) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    _ = lower_mod.lowerNode(&lowerer, parse_result.root) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // Lowering diagnostic (e.g. invalid `\v` string escape, regex
        // compile failure). Surface as `.err` with diagnostic shape.
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
    //
    // Recursive UDF bodies live as off-main-root subtrees (the call
    // site emits `call_user`, not the body inline), so fuse only
    // reaches them if we hand them in as extra walk roots. Otherwise
    // their `index_map` slots stay at sentinel and the remap loop
    // below clobbers `body_ir_root` to `BODY_IR_NOT_LOWERED`.
    var extra_roots: std.ArrayList(u32) = .{};
    defer extra_roots.deinit(allocator);
    for (lowerer.function_table.items) |entry| {
        if (entry.body_ir_root == lower_mod.BODY_IR_NOT_LOWERED) continue;
        try extra_roots.append(allocator, entry.body_ir_root);
    }
    const fuse_result = try fuse_mod.fuse(lowered, extra_roots.items);
    var fused = fuse_result.ir;
    for (lowerer.function_table.items) |*entry| {
        if (entry.body_ir_root == lower_mod.BODY_IR_NOT_LOWERED) continue;
        entry.body_ir_root = fuse_result.index_map[entry.body_ir_root];
    }

    // Stage 3.5: harvest projection plan + optional pure-scalar
    // predicate (C1 of the per-core ceiling roadmap). MUST run before
    // emit because `harvestPredicate` rewrites the IR root in-place
    // when the predicate-pushdown shape matches: the parser will drop
    // failing records via `feedPlanned`, so the VM's bytecode for kept
    // records collapses to the body's identity-projection. Running this
    // after emit would leave the original `select(...)` body lowered
    // into bytecode, producing a double-eval of the predicate on every
    // kept record. The strip is a single in-place node overwrite — no
    // allocation, no resize — so on harvest-OOM the IR is unmodified
    // and the parser stays no-plan.
    //
    // Predicate harvest is attempted first because a `select(...)`
    // root rejects the plain projection harvester. If the predicate
    // shape doesn't match, we fall through to projection harvest.
    var staged_plan: ?harvest_mod.ProjectionPlan = null;
    errdefer if (staged_plan) |*pp| pp.deinit();
    if (harvest_mod.harvestPredicate(allocator, &fused)) |maybe_plan| {
        if (maybe_plan) |pp| staged_plan = pp;
    } else |err| switch (err) {
        error.OutOfMemory => {},
    }
    if (staged_plan == null) {
        if (harvest_mod.harvestProjectionPlan(allocator, &fused)) |maybe_plan| {
            if (maybe_plan) |pp| staged_plan = pp;
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
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
    //
    // The IR walked here is the post-strip IR if the predicate
    // harvester accepted the shape — emit lowers identity / projection
    // body, and the now-orphaned `select`-body sub-tree is dropped
    // when the IR arena dies.
    const pool = lowerer.takeRegexPool();
    var pool_consumed = false;
    errdefer if (!pool_consumed) {
        var p = pool;
        p.deinit();
    };
    var compiled = try emit_mod.emit(
        fused,
        external_vars.len,
        lowerer.function_table.items,
        lowerer.next_var_id,
        pool,
        allocator,
    );
    pool_consumed = true; // emit owns the pool now (transferred into `compiled`).
    var compiled_consumed = false;
    defer if (!compiled_consumed) compiled.deinit(allocator);

    // Transfer the staged projection plan into `compiled`. Ownership
    // moves; clear the local so the errdefer above doesn't double-free
    // if a later step fails (the plan now lives in `compiled` and is
    // freed by `compiled.deinit`).
    if (staged_plan) |pp| {
        compiled.projection_plan = pp;
        staged_plan = null;
    }

    // Stage 5: harvest prefilter literals from IR (Phase 18).
    // Read-only IR walk; no mutations. The IR is still valid because
    // `arena` hasn't been freed yet (the defer above runs on return).
    // On OOM or harvest failure, we simply skip the prefilter — the
    // filter still runs correctly without it.
    //
    // Note: the regex prefilter harvester walks from the IR root,
    // which after a successful predicate-strip is `Op.identity` — that
    // arm of `harvestFromIr` returns immediately (no select root), so
    // no work duplication and no spurious prefilters land. The two
    // harvesters are mutually exclusive on a given query: predicate
    // pushdown applies to scalar comparisons / `has()`, regex
    // prefilter applies to `select(... | test|scan(...))`. Composing
    // them is deferred (#4 from the original commit's deferred list).
    const prefilter = @import("prefilter");
    var literal_groups: std.ArrayList(harvest_mod.LiteralGroup) = .{};
    // The harvest output owns per-literal []u8 dupes plus the outer slice.
    // `prefilter.PrefilterSet.ownFrom` deep-copies everything into its own
    // allocations, so once that returns (or after a harvest failure) we own
    // the staging arrays and must release them — otherwise both the per-
    // literal dupes and the ArrayList backing storage leak on every compile.
    defer {
        for (literal_groups.items) |g| {
            for (g.literals) |lit| allocator.free(lit);
            allocator.free(g.literals);
        }
        literal_groups.deinit(allocator);
    }
    const harvest_result = harvest_mod.harvestFromIr(
        allocator,
        &fused,
        &compiled.regex_pool,
        &literal_groups,
    );
    if (harvest_result) |_| {
        // Transfer ownership into compiled.prefilter.
        if (literal_groups.items.len > 0) {
            // Convert to the legacy PrefilterSet format. `ownFrom` deep-
            // copies, so this staging ArrayList is throwaway — defer its
            // deinit so we don't leak the backing storage on any path.
            var legacy_groups = std.ArrayList(prefilter.LiteralGroup){};
            defer legacy_groups.deinit(allocator);
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
        // OOM during harvest: fall back to no prefilter. The outer defer
        // releases any partial groups already pushed into `literal_groups`.
        error.OutOfMemory => {},
    }

    compiled_consumed = true;
    return .{ .ok = compiled };
}
