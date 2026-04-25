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
