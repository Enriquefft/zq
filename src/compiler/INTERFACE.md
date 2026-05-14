# Module: compiler

## Purpose
Phase 2R compile backend. Sole compile path post Phase 2R cutover —
`query.CompiledQuery.compile` dispatches here unconditionally.

The pipeline is fixed and linear:

```
src → ast.parse → AST → lower → IR → fuse → IR → emit → CompileResult
```

Stages 2-4 run inside an arena local to `compile`; the IR is dropped after
emit. Stage 5 is a read-only IR walk that harvests prefilter literals and
attaches a `PrefilterSet` to the resulting `Compiled`.

Categories landed: cat-1 (literals/identity/recurse/unary), cat-2
(field/index/iterate/slice + postfix `?`), cat-3 (pipe/comma), cat-4
(vars/destructure/alt-bind), cat-5 (arith/cmp/logical/alt), cat-6
(try/catch/if/path), cat-7 (obj/arr/interp/format), cat-8 (update_assign),
cat-10 (general builtins), cat-11 (regex / datetime / extended arg-builtins).
Every supported category lowers; lower/emit gaps panic, not soft-error.

Consumed by:
- `src/query/root.zig` — `CompiledQuery.compile` dispatches here.
- `src/compiler/bench.zig` — pipeline microbench.
- Snapshot test harness — drives `Lowerer` + `lowerNode` + `dump` / `dumpIR`
  directly to render AST and post-fuse IR shapes without going through
  `compile()`.

---

## Public Interface

### Types

```zig
const std = @import("std");

/// IR opcode set. Every supported AST shape lowers to a sequence of these.
/// Defined in `ir.zig`; re-exported here so callers and snapshot tests can
/// speak in the public vocabulary.
pub const Op = ir_mod.Op;

/// IR node — one operation plus its operand payload. The IR is a flat
/// vector of `Node`s indexed by `u32`; child relationships are encoded as
/// indices, not pointers, so the `fuse` pass can rewrite the graph by
/// producing a fresh vector and an `index_map`.
pub const Node = ir_mod.Node;

/// Owned IR container — node vector plus auxiliary tables. Built by the
/// `Lowerer`, mutated by `fuse`, consumed by `emit`. Allocations live in
/// the lowerer's arena and are dropped when `compile` returns.
pub const IR = ir_mod.IR;

/// AST-walking IR dumper. Pretty-prints the operations the lowerer would
/// emit for a given AST without going through the IR. Used by the snapshot
/// harness as the pre-fuse baseline.
pub const dump = ir_mod.dump;

/// IR-walking dumper — renders the IR vector directly. Used by the fuse
/// snapshot harness to surface the post-rewrite shape.
pub const dumpIR = ir_mod.dumpIR;

/// Subtree variant of `dumpIR`. Renders an arbitrary IR root, used by the
/// fuse snapshot harness to surface cat-9 function bodies that live off
/// the main IR root via `function_table.body_ir_root`.
pub const dumpIRSubtree = ir_mod.dumpIRSubtree;

/// Per-compile lowering state. Owns the arena-backed IR vector under
/// construction, the symbol/var-id environment, the function table, and
/// the regex pool that is later transferred into `Compiled`. Held by
/// `compile` for one filter; not reusable.
pub const Lowerer = lower_mod.Lowerer;

/// Entry point of the lower pass — walks an AST node and appends its
/// lowered IR to `lowerer.out`. Recursive: each `Kind` variant has a
/// dedicated lowering rule. Errors (`OutOfMemory`, `LowerDiagnostic`)
/// surface as `.err` from `compile`.
pub const lowerNode = lower_mod.lowerNode;

/// Fuse pass entry point — applies IR-level rewrite rules
/// (e.g. chained `.a | .b | .c` → single `load_path`). See `fuse.zig`.
/// Snapshot tests import this directly to drive the IR-level diff.
pub const fuse = fuse_mod.fuse;

/// Result of the fuse pass: a fresh IR plus an `index_map` from old node
/// indices to new ones. Auxiliary tables that index the IR by node
/// (cat-9 `function_table.body_ir_root`) MUST be re-pointed through
/// `index_map` after fuse.
pub const FuseResult = fuse_mod.Result;

/// Sentinel value used by `function_table.body_ir_root` to mean
/// "not yet lowered". Surfaced so snapshot tests can skip recursive UDFs
/// whose body lowering is deferred to the first emit-site.
pub const BODY_IR_NOT_LOWERED = lower_mod.BODY_IR_NOT_LOWERED;

/// Final compiled artifact: bytecode + auxiliary tables (string buffer,
/// function table, external var ids, regex pool, prefilter). Owned by
/// the caller's allocator after a successful `compile`. See `types.zig`.
pub const Compiled = ctypes.Compiled;

/// Discriminated result of a single `compile` call: `.ok = Compiled` on
/// success, `.err = Diagnostic { kind, offset, len }` on parse or lower
/// failure.
pub const CompileResult = ctypes.CompileResult;

/// Caller-supplied external variable declaration. `compile` pre-declares
/// these in the root scope at var ids `0..N-1` so cat-4 `$external_var`
/// references resolve to the same operand index every run.
pub const ExternalVarDecl = ctypes.ExternalVarDecl;

/// Module-system options threaded into `compile()`. Together,
/// `module_search_path` (the fixture-root chain) and the optional
/// `current_file_dir` feed the resolver's lookup. Callers that don't use
/// the module system pass `.{}`.
pub const ModuleOpts = struct {
    module_search_path: []const []const u8 = &.{},
    current_file_dir: ?[]const u8 = null,
};
```

### Functions

| Function          | Signature                                                                                                  | Description                                                                              |
|-------------------|------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------|
| `compile`         | `[]const u8, []const ExternalVarDecl, ModuleOpts, std.mem.Allocator → error{OutOfMemory}!CompileResult`   | Compile a filter source string. Always returns a `CompileResult`; only OOM bubbles up.   |
| `lowerNode`       | `*Lowerer, *const ast.Node → error{OutOfMemory, LowerDiagnostic}!void`                                     | Lower one AST node; recursive entry. `.err` carried via `lowerer.compile_err`.           |
| `fuse`            | `IR → error{OutOfMemory}!FuseResult`                                                                       | IR → IR rewrite pass. Result carries `index_map` for re-pointing aux tables.             |
| `dump` / `dumpIR` / `dumpIRSubtree` | (see `ir.zig`)                                                                              | Snapshot-test helpers; not used at runtime.                                              |

### Errors

| Error          | When                                                                                                   |
|----------------|--------------------------------------------------------------------------------------------------------|
| `OutOfMemory`  | Arena, IR vector grow, regex pool intern, or final `Compiled` allocation.                              |

Parse errors and lower diagnostics do NOT escape as Zig errors. They are
returned as `CompileResult.err` with `(kind, offset, len)` matching the
legacy diagnostic shape — the harness's `errpos` guardrail compares triples.

---

## Constraints & Invariants

- **`compile` is total modulo OOM.** Parse errors, lower diagnostics, and
  regex-compile failures surface as `CompileResult.err`. Only allocator
  failure escapes as a Zig `error.OutOfMemory`.
- **Ownership transfer is precise.** The lowerer's regex pool is taken via
  `lowerer.takeRegexPool()` immediately before `emit`; on emit success the
  pool ownership transfers into `Compiled.regex_pool`. The defer chain in
  `compile` guarantees the pool is freed exactly once on every error path.
- **IR arena is local.** Every `*Node`, every IR slice, every lowered
  payload comes from an arena that is freed when `compile` returns. The
  emitter must copy any bytes the VM needs into the caller's allocator
  before that arena drops.
- **`fuse` produces a fresh IR.** Node indices change. Auxiliary tables
  that point into the IR by index (currently only
  `function_table.body_ir_root`) MUST be re-pointed through
  `FuseResult.index_map`. Entries equal to `BODY_IR_NOT_LOWERED` are
  skipped — the sentinel value is preserved across the rewrite.
- **External var ids are positional.** `compile` pre-declares
  `external_vars` in the root scope; the i-th declaration becomes var id
  `i`. The VM relies on this stability for `ExternalVarBinding.var_id`.
- **Prefilter harvest is best-effort.** Stage 5 walks the IR (read-only)
  and may fail with OOM; on failure the prefilter is simply omitted and
  the filter still runs correctly. No bytecode mutation depends on a
  successful harvest.
- **Lower/emit gaps are panics, not soft errors.** Post-Phase-2R cutover
  every supported AST shape lowers. Hitting an unhandled `Kind` variant
  is a programmer bug — the lowerer panics instead of emitting an `.err`.
- **`Lowerer` is not thread-safe and not reusable.** One instance per
  `compile` call. Snapshot tests that drive it directly must construct a
  fresh `Lowerer` each time.
- **`compile` is not thread-safe per allocator.** Multiple concurrent
  compiles on a shared allocator are fine if the allocator is; on a
  single-threaded allocator they are not.

---

## Dependencies

- `src/ast/root.zig`       — `parse`, `ParseResult`, `Node`
- `src/compiler/ir.zig`    — `Op`, `Node`, `IR`, dumpers
- `src/compiler/lower.zig` — `Lowerer`, `lowerNode`, `BODY_IR_NOT_LOWERED`
- `src/compiler/fuse.zig`  — `fuse`, `Result`
- `src/compiler/emit.zig`  — `emit` (internal; produces `Compiled`)
- `src/compiler/types.zig` — `Compiled`, `CompileResult`, `ExternalVarDecl`
- `src/compiler/harvest.zig` — IR-walk prefilter harvest (`harvestFromIr`)
- `src/prefilter/root.zig` — `PrefilterSet.ownFrom`, `LiteralGroup`
