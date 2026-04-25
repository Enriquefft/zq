# Phase 2R Progress Log

Append-only log written by `progress-logger` subagents. Read by
`progress-reader` at orchestrator boot.

---

## Phase 0 complete
Branch: `redesign/compiler` created off `main`.
Archive tag: `archive/phase-2-byte-identical` → `1565f6b` (walker tip
preserved for reference).
Verifier-confirmed: branch + tag exist; no premature changes.

## Phase 1 complete
Last commit: `15f20df` — refactor(compiler): drop Phase 2 walker
scaffold; supersede with Phase 2R.
Removed:
  - `src/ast/compiler.zig` (7559 lines)
  - `tests/ast_compile_equiv.zig`
  - `tests/ast_compile_equiv_fixtures.zig`
  - walker build wiring in `build.zig` (`ast-compile-equiv` step,
    `compiler_legacy_module`, `compiler_ast_module`,
    `ast_equiv` test module)
Preserved per plan §2 reused-and-kept:
  - All AST node variants in `src/ast/nodes.zig`
  - `assign_general` grammar in `src/ast/parser.zig` (LSP consumers)
  - `src/query/src/{vm,prefilter,compiler}.zig` (legacy compile path
    remains sole compiler until R3 lands `-Dcompile=new`)
Comment cleanup in `src/ast/parser.zig` and
`src/query/src/prefilter.zig` for the deleted walker.
Verifier checks expected (run by Orchestrator A on resume if not yet
recorded):
  - `rg "ast.compiler|ast_compile_equiv" build.zig` → 0
  - `zig build` passes
  - `zig build test` baseline recorded
  - LSP smoke test passes

Open work for Phase 2 (next):
  - `TODO.md`: replace AST-walk entry with one-line pointer to plan.
  - `research/phase-2-ast-walk-plan.md`: prepend `[SUPERSEDED]` banner.
  - AST-shape diff verification per plan §3 R1 step 8.

Next orchestrator: `phase-2r-orchestrator-A.md`, start Phase 2.

## Phase 2 — R1 Supersession Bookkeeping (Cluster A)

Date: 2026-04-25
Commit: c9d4a696221854a66dae6c9dd0e85bc0561fd315
Branch: redesign/compiler
Status: PROCEED (3/3 reviewers)

### Changes
- TODO.md: collapsed AST-walk entry (-141/+1) to one-line pointer
  → research/phase-2r-compiler-redesign-plan.md
- research/phase-2-ast-walk-plan.md: prepended [SUPERSEDED] banner
  (file body retained for historical reference; src/ast/nodes.zig:82
  doc-comment still resolves)

### Verification
- zig build: PASS (exit 0)
- zig build test: 1023/1161 passed, 27 skipped, 111 failed
  → recorded as legacy baseline; failures are pre-existing jq-compat
    semantic divergence, not R1 regression.
- LSP wiring: PASS (--lsp flag intact at src/main.zig:136,1386,1562)
- AST-shape diff vs c1ef970^: 5 grammar-affecting diffs, all KEEP
  (Stage 8 assign_general, BUG-005 d1, BUG-006, update-path
   .rbracket, isBuiltinName alignment)
- build.zig walker refs: 0 (rg "ast\.compiler|ast_compile_equiv")
- walker source files: confirmed deleted

### Reviewer summary
- code-reviewer: PROCEED — no bugs/leaks/edges/scope creep.
- architect-reviewer: PROCEED — §1 invariants intact, R1 acceptance met,
  AST-diff classification sound. Informational note: plan R1 step 9
  ("single atomic commit") split across 15f20df + c9d4a69; end state
  equivalent, no invariant violated.
- future-readiness-reviewer: PROCEED — no lost followups, no dangling
  refs, agents-first preserved.

### Phase 2 acceptance: MET
Tree clean; legacy is sole compiler; LSP intact; baseline counts recorded.

Next: Phase 3 — bench harness + legacy baselines (R2).

## Phase 3 — R2 Bench Harness + Legacy Baselines (Cluster A)

Date: 2026-04-25
Commit: 018e6b8fc938514e47e0b4e2522ee3450021d062
Branch: redesign/compiler
Status: PROCEED (after 1 fix attempt)

### Changes
- src/compiler/bench.zig (new, ~164 lines): 17-filter compile-only bench
  driver, ReleaseFast, N=1000 + 50 warmup, per-iteration ArenaAllocator,
  TSV ns-precision stdout.
- build.zig: `zig build bench-compile` step (addExecutable, ReleaseFast,
  outside test_step).
- research/compiler-baselines.md (new): legacy compile-only baselines.

### Verification
- zig build: PASS
- zig build bench-compile: PASS, 17 rows, 0 compile errors
- zig build test: 1023 passed / 27 skipped / 111 failed (delta vs R1: 0)
- 3 fresh-process bench runs aggregated; median/p99/σ per filter recorded.
- Peak RSS: 51.2 MB. Binary size: 9,450,465 B (≈9.0 MB).

### Filter corpus (17)
10 compat + 3 UDF (incl. udf.semicolon = `def f(a;b): a + b; f(.x;.y)`)
+ 1 regex literal + 1 dynamic regex + 1 reduce + 1 deep pipe/comma.

### Reviewer pass
- code-reviewer: BLOCK initially (doc test-count contradiction line 89);
  resolved in fix attempt #1.
- architect-reviewer: PROCEED w/ flags. Filter substitution rationale was
  wrong (legacy DOES accept `def f(a;b)`; original failure was `add`
  builtin shadow). Fixed: udf.composed → udf.semicolon. Plan-conflict
  flagged (hash-pin timing) → second-opinion verdict NO CONFLICT
  (§1 specifies location, not timing; §3.2 R2 acceptance does not
  require pin).
- future-readiness-reviewer: PROCEED. Suggested R3 enhancements: TSV
  companion + arg parsing.

### Open issues for R3 (Phase 5/6)
- Implement compat-fixture hash pin in baselines.md.
- Optional: TSV companion + bench arg parsing for filter subsetting.
- Cosmetic: bench.zig p99 comment off-by-one (989 vs 990 — index correct).

### Phase 3 acceptance: MET
Legacy baselines locked. R3 must hold or improve median µs / p99 µs / σ
per filter, peak RSS, binary size, and the 1023/1161 test count floor.

Next: Phase 4 — IR-format spec (`research/compiler-ir-format.md`).

## Phase 4 — R2 IR-Format Spec (Cluster A)

Date: 2026-04-25
Commit: 90dce829bd0f5f472f1dc70a95d129ad2ca87ea8
Branch: redesign/compiler
Status: PROCEED (after 1 fix attempt)

### Changes
- research/compiler-ir-format.md (new, 388 lines): stable diffable
  indented-tree IR text format spec. Pins node syntax, span semantics
  (start..end byte-exclusive), flat op-tag namespace with SemOp/EmitOp
  banners, inline extra-data rendering, snapshot directives in EBNF,
  regex pool ref escape rules, cross-namespace tag uniqueness, and
  append-only stability.

### Verification
- zig build: PASS (no source changes)
- zig build test: not re-run (no source changes; baselines unchanged)
- All 11 required sections present.
- Worked examples (.foo | .bar, keys | length, if/then/else,
  fuse-rewrite to key_count) all use byte-exact spans, consistent
  across §2/§4/§7/§10.

### Reviewer pass
- code-reviewer: BLOCK initially (span values inconsistent across
  §2/§10; EBNF missing fuse directives `# before`/`# after`;
  regex pool ref serialization underspecified). All 3 cleared in
  fix attempt #1.
- architect-reviewer: PROCEED. Plan §1.3 row 6 (SemOp/EmitOp), row 5
  (extra_children), row 8 (diffable), §3 R3 step 9 (indent format),
  §1.2 (span semantics), §1 invariants — all PASS.
- future-readiness-reviewer: PROCEED. Minor flags: partial-regen
  not specified (additive future), no JSON dump surface (additive
  future). No foreclosures.

### Open issues for R3 (Phase 5/6)
- Op enum implementation in src/compiler/ir.zig.
- Lowering rules in src/compiler/lower.zig.
- Snapshot directories tests/compiler/snapshots/{lower,fuse}/.
- Optional: partial-regen support (`zig build snapshots-update -- <name>`).
- Optional: typed JSON dump surface.

### Phase 4 acceptance: MET
IR text format is implementable from the spec without further questions;
R3 implementers conform to it.

Next: Phase 5 — compiler scaffold + dispatch flag.

## Phase 5 — R3 Scaffold + Dispatch Flag (Cluster A)

Date: 2026-04-25
Commit: 9d70ce2759ab56a5ae6f3dcd8dd1cf6dd925a408
Branch: redesign/compiler
Status: PROCEED (single attempt, no fixes needed)

### Changes
- src/compiler/ir.zig (143 lines): Op enum (29 SemOp variants, EmitOp
  reserved), Node (sizeof=32, comptime ≤32 assert), IR container with
  arena + 4 unmanaged ArrayLists (nodes, extra_children, extra_data,
  string_buf).
- src/compiler/lower.zig (31 lines): skeleton, returns
  error.NewCompilerNotImplemented; AST root typed as *const anyopaque
  with TODO(R3) for typed import.
- src/compiler/fuse.zig (21 lines): identity passthrough.
- src/compiler/emit.zig (26 lines): skeleton, returns
  error.NewCompilerNotImplemented.
- src/compiler/root.zig (45 lines): public compile(src, allocator)
  error{NewCompilerNotImplemented, OutOfMemory}!noreturn; re-exports
  Op/Node/IR.
- build.zig (+27): CompileBackend enum, -Dcompile=legacy|new option
  (default legacy), compiler_module declared with build_options
  import, query_module imports compiler.
- src/query/root.zig (+44/-15): comptime switch on
  build_options.compile_backend; compileLegacy helper extracted;
  TODO(R3) documents misleading main.zig OOM mismatch.
- src/compiler/bench.zig (untouched, from Phase 3).

### Verification
- zig build: PASS
- zig build -Dcompile=legacy: PASS
- zig build -Dcompile=new: PASS (compiles cleanly; runtime returns
  error.NewCompilerNotImplemented mapped to "out of memory" via
  generic catch in main.zig — TODO(R3) documented).
- zig build test: 1023 passed / 27 skipped / 111 failed
  (exact R1 baseline match, delta 0).
- Op tag names align with research/compiler-ir-format.md spec.

### Reviewer pass
- code-reviewer: PROCEED.
- architect-reviewer: PROCEED. Plan editorial inconsistencies
  flagged (informational): plan §1.3 row 5 names load_field/load_index
  vs spec §10 field/index — implementer correctly chose spec names;
  bench.zig "5 vs 6" file count mismatch in implementer brief vs
  plan §1.5 — preserved correctly.
- future-readiness-reviewer: PROCEED. Foreclosures noted:
  Node sizeof at exactly 32B (zero headroom);
  -Dcompile=new not surfaced in CLAUDE.md/ARCHITECTURE.md (suggested
  one-line pointer addition).

### Open issues for R3 (Phase 6+ and beyond)
- lower.zig: replace *const anyopaque ast_root with typed import.
- root.zig: widen `!noreturn` to `!CompileResult` atomically with
  dispatcher when first operator lands.
- emit.zig: resolve circular-import via shared CompileResult-shape
  module.
- Editorial: plan §1.3 row 5 names → align to spec.
- Watch: Node 32B headroom; future fields require extra_data routing.
- Agents-first: ARCHITECTURE.md surface for -Dcompile=new.

### Phase 5 acceptance: MET
Scaffold present at all 6 files. Op enum exhaustive (SemOp).
Node ≤32B asserted. Dispatch flag wired with comptime switch.
Test baseline holds under default legacy.

Next: Phase 6 — vm-equiv harness (tests/vm_equiv.zig + errpos +
zig build vm-equiv); harness green under -Dcompile=legacy (sanity).

## Phase 6 — R3 vm-equiv Harness (Cluster A)

Date: 2026-04-25
Commit: <will be filled in after the commit>
Branch: redesign/compiler
Status: PROCEED (after 1 fix attempt for path drift)

### Changes
- tests/compiler/vm_equiv.zig (119 lines, new): 11 hand-rolled
  fixtures, dual-dispatch shape with TODO(Cluster B) for the new-path
  call (currently hard-coded SKIP due to a Zig 0.15.2 build-runner
  duplicate-import issue when both `query` and `compiler` modules are
  imported into the same test binary). Legacy invocation via the
  newly-public `query.CompiledQuery.compileLegacy`.
- tests/compiler/vm_equiv_errpos.zig (120 lines, new): 5 compile-error
  fixtures (unclosed_str, trailing_pipe, trailing_arith, open_bracket,
  incomplete_def). Each asserts (kind, offset, len) on the legacy side
  via a `legacy_drift` counter; new path SKIP at Phase 6.
- tests/compiler/vm_equiv_probe.zig (43 lines, new): throwaway helper
  for discovering legacy compile-error positions when expanding the
  errpos corpus. Gated behind `zig build vm-equiv-probe`. Cluster B
  cleanup-debt.
- build.zig: vm-equiv, vm-equiv-errpos, vm-equiv-probe steps
  (addExecutable; not in test_step).
- src/query/root.zig: `compileLegacy` exposed as `pub fn` for harness
  use; doc comment explains the always-legacy invocation regardless
  of -Dcompile= flag.
- .gitignore: defensive `zq-vm-equiv` entry (zig builds to .zig-cache/
  but probe artifact may leak under interactive runs).

### Verification
- zig build: PASS
- zig build vm-equiv: exit 0; "vm_equiv: total=11 match=0 mismatch=0
  skipped=11 compile_err=0"
- zig build vm-equiv-errpos: exit 0; "vm_equiv_errpos: total=5
  skipped=5 legacy_unexpected_ok=0 legacy_drift=0"
- zig build vm-equiv -Dcompile=new: exit 0 (still SKIPs all 11)
- zig build test: 1023 passed / 27 skipped / 111 failed (delta vs R1: 0)
- vm-equiv steps NOT in test_step (verified by grep on test_step.dependOn).

### Reviewer pass
- code-reviewer: PROCEED (probe KEEP, scope clean).
- architect-reviewer: PROCEED with PLAN CONFLICT flags:
  1. Path drift tests/ vs tests/compiler/ — RESOLVED in fix #1
     (orchestrator brief misquoted plan §1.5).
  2. Fixture-source: plan §3 R3 step 4 mandates regen from
     ../jq/tests/jq.test via Perl; Phase 6 ships hand-rolled per
     orchestrator scope split. DEFERRED to Cluster B.
  3. -Dcompile flag semantics undocumented in plan; current
     interpretation (legacy always via compileLegacy) is sound.
  4. vm_equiv_probe.zig is cleanup-debt post-Cluster-B.
- future-readiness-reviewer: PROCEED. Discoverability gap (vm-equiv
  not in CLAUDE.md / ARCHITECTURE.md) flagged for Cluster B.

### Phase 6 acceptance: MET
Harness scaffolds in plan-mandated paths; both vm-equiv steps green
under default -Dcompile=legacy; baseline preserved.

## Handoff: A → B

Last commit: <Phase 6 commit hash will be filled in>
Phase 6 vm-equiv (legacy): green (11 fixtures SKIP-NotImplemented;
  vm-equiv-errpos 5 fixtures SKIP-NotImplemented; legacy_drift=0;
  vm_equiv compile_err=0).
Legacy baselines:
  - bench median/p99/σ per filter: see research/compiler-baselines.md
    (17-filter corpus; details per filter in the doc).
  - peak RSS: 51.2 MB
  - binary size (zq main, ReleaseFast): 9,450,465 bytes (≈9.0 MB)
IR contract: research/compiler-ir-format.md @ 90dce82 (388 lines,
  diffable indented-tree spec; 11 sections; spans byte-exact in all
  worked examples).
Open blockers: none (Cluster A acceptance met).
Open issues for Cluster B (R3 operator porting + parity):
  1. Wire real `compiler.compile(...)` invocation in
     tests/compiler/vm_equiv.zig (currently SKIP-bypass). Resolves a
     Zig 0.15.2 build-runner constraint when `query` and `compiler`
     modules both appear in the test binary's dep graph. Two paths:
     re-export `compiler.compile` through `src/query/root.zig`, or
     restructure the test-binary imports to a single root module.
  2. Regenerate the compat fixture corpus from
     `../jq/tests/jq.test` via `tests/scripts/generate_compat_tests.pl`
     (~533 cases) per plan §3 R3 step 4. Pin the upstream commit hash
     in research/compiler-baselines.md per plan §1 locked decision.
  3. Implement VM-execution + value-stream diff in vm_equiv.zig (the
     TODO at lines ~99-103). Compare error kinds + (R3 close) source
     positions per plan §1.2.
  4. Fold tests/compiler/vm_equiv_probe.zig into the regen pipeline
     or delete once the errpos corpus is auto-generated.
  5. Replace `*const anyopaque` ast_root in src/compiler/lower.zig
     with the typed AST root import; widen src/compiler/root.zig
     `compile()` from `!noreturn` to a real success type atomically
     with the dispatcher in src/query/root.zig.
  6. Replace the generic OOM `catch` in src/main.zig (or extend it)
     to handle `error.NewCompilerNotImplemented` cleanly under
     -Dcompile=new before any operator is gated runtime-selectable.
  7. Add a one-line surface for `-Dcompile=new` in CLAUDE.md or
     ARCHITECTURE.md (agents-first discoverability).
  8. Watch: `Node` is exactly 32 bytes (zero headroom). Future fields
     must route via `extra_data` index, not widen Node — preserve the
     comptime assert and document the rule in src/compiler/ir.zig.
  9. Editorial: plan §1.3 row 5 mapping table names `load_field` /
     `load_index`; spec §10 + ir.zig use `field` / `index`. Suggest
     plan revision to align names; not blocking, but a future plan
     edit should fix the editorial inconsistency.
 10. Resolve circular-import path: src/compiler/emit.zig comment
     notes that the cleanest cut is to move `CompileResult` shape
     into a third module (e.g., `types`). Tackle at the start of R3
     operator porting, not mid-port.
 11. Test baseline floor: under -Dcompile=new, R3 must hold or
     improve `zig build test` aggregate of 1023/1161 (R1 baseline,
     captured 2026-04-25).

Next orchestrator: phase-2r-orchestrator-B.md, start Phase 7.
