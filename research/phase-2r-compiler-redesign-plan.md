# Phase 2R — Compiler Redesign (VM-semantics, IR-layered)

Supersedes `research/phase-2-ast-walk-plan.md`. That plan pursued a
byte-identical walker over Stages 0–12; this plan replaces both the
goal and the correctness contract for the same underlying objective
(collapse to one parser, one compiler).

Revision: 3 (post-review + decision-locked). All deferred decisions
resolved by user; one-sitting execution plan. Reviewer-flagged
corrections applied: LSP-shared `assign_general` retained;
variable-arity contract frozen; explicit pipeline shape; source-map
parity hardened; fixture-extraction strategy split per source; bench
noise floor stated; speculative "parse-plan IR" citation dropped.

Locked decisions (this revision):
- Branch: `redesign/compiler` off `main`.
- Archive tag: `archive/phase-2-byte-identical` at `1565f6b` before R1.
- Snapshot location: `tests/compiler/snapshots/`.
- IR text format: indented tree.
- Source-position parity: exact match on curated set.
- `parse_plan` field: NOT reserved. Add when research work needs it.
- `-Dcompile=experimental` slot: NOT reserved. Add when first
  experimental pass arrives.
- Commit cadence: one commit per operator category in R3 (12 commits).
- Snapshot regen: `zig build snapshots-update`.
- Compat fixture source: `../jq/tests/jq.test`, hash pinned in
  `research/compiler-baselines.md`.
- R5 soak: NONE. R5 merges into R4 — legacy deleted in same sitting
  once all five guardrails pass.

---

## 0. Why

Governed by `CLAUDE.md` principles (project + `~/.claude/CLAUDE.md`):

- **§1 Decision quality.** The byte-identical contract was picked
  because it was easy to diff. VM-semantics is the right contract;
  pick it even though it is more expensive to test.
- **§3 Single source of truth.** Two parsers today (legacy at
  `src/query/src/compiler.zig`, AST at `src/ast/parser.zig`). Grammar
  decisions duplicate and drift. Proven twice in the last 48 h
  (commits `83f0212`, `c1ef970`).
- **§4 Zero workarounds.** The byte-identical bar forces the new
  compiler to reproduce legacy defects verbatim (e.g. `compileRange`
  lookahead at `src/ast/compiler.zig:5259-5264`). That is a workaround
  codified as a spec, forever.
- **§5 Production-ready is the floor.** A clean boundary between
  lowering and emission is baseline engineering, not a feature.
- **§6 Build for 2026+.** Future research work (per
  `ROADMAP.md § Research-Backed Optimizations`: constant folding,
  extended fuse, projection pushdown, predicate pushdown) will need a
  stable IR to operate on. This plan does not implement those, but
  reserves the architectural seams so they land additively.

"Raw win → do it; drawbacks → think hard." The byte-identical plan had
real drawbacks (quirks frozen as spec, walker is a legacy clone). The
VM-semantics plan is the raw win that was missed. Dev cost is not a
tiebreaker; architectural cleanliness is.

---

## 1. Architecture

### 1.1 Pipeline shape

```
source text
  → lex          (existing lexer, unchanged)
  → parse        src/ast/parser.zig (shared with LSP)
  → AST
  → lower        src/compiler/lower.zig
  → IR
  → fuse         src/compiler/fuse.zig (single pass today)
  → emit         src/compiler/emit.zig
  → Bytecode + SourceMap + StringBuf + FunctionTable + Prefilter
                + ParsePlan? (reserved field, stub today)
```

**Pipeline discipline.** Each stage is a pure function with a fixed
signature, called from `src/compiler/root.zig`:

```zig
const ir   = try lower.run(arena, ast);
const ir2  = try fuse.run(arena, ir);
const out  = try emit.run(arena, ir2);
```

Adding a new IR→IR pass later is one line in `root.zig` and zero
edits in `lower`/`fuse`/`emit`. Not a framework — three function
signatures plus a discipline. No pass-pipeline abstraction, no plugin
surface, no registry.

### 1.2 Correctness contract — VM-semantics

Two compiler outputs are equivalent iff, for every query in the
fixture set and every input in the matching input set, running both
bytecodes on the VM produces:

1. The same output stream (same values, same order).
2. The same numeric formatting via `src/types.zig:formatJqFloat`. Any
   numeric divergence is a bug in `formatJqFloat`, not in the bar.
3. The same compile-error kind on rejected queries. Compile-error
   source position must match on the curated error-fixture set
   defined in §1.4 row 5; elsewhere positions are free.
4. The same runtime-error kind on failing queries.

Not equivalent: bytecode shape, instruction order, operand layout,
intermediate allocations.

### 1.3 IR invariants

1. **Arena-scoped.** One bump allocator per compile; dropped after
   emit. Zero IR memory survives into query execution.
2. **Packed.** Tagged-union nodes with payload struct. `@sizeOf`
   asserted at comptime to be ≤ 32 bytes per node.
3. **Index-based edges.** Children are `u32` indices into the IR node
   array, not `*Node` pointers.
4. **No virtual dispatch.** Switch on tag.
5. **Variable-arity contract.** One mechanism, frozen here:
   - `Node.children: [2]u32` for fixed-arity ops (≤ 2 children).
   - `Node.span: { start: u32, len: u32 }` indexes into a per-IR
     `extra_children: []u32` for any op with ≥ 3 children or
     dynamic-arity children.
   - `Node.extra: u32` indexes into `extra_data: []u32` for non-child
     scalars (string-buf ids, regex-pool ids, flag bitsets).

   Per-op mapping table (final list grown only when an op needs ≥ 3
   children):

   | Op | children layout |
   |---|---|
   | `load_const` / `load_var` / `load_field` / `load_index` | `extra` → const/var/string-id |
   | `pipe` / `comma` / `arith` / `cmp` / `logical` / `alt` | binary, `children[0..1]` |
   | `iterate` / `recurse` / `try` / `not` / `neg` | unary, `children[0]` |
   | `if` | `span` → [cond, then, else] |
   | `reduce` | `span` → [src, init, update] |
   | `foreach` | `span` → [src, init, update, extract] |
   | `interp` | `span` → segments (alternating literal/expr) |
   | `format` | `span` → segments + `extra` → format-spec id |
   | `obj_ctor` | `span` → key/value pairs interleaved |
   | `arr_ctor` | `span` → elements |
   | `call_user` / `call_builtin` | `span` → args + `extra` → fn id |
   | `update_assign` | binary + `extra` → op kind |
   | `destructure` | `span` → pattern subnodes + `extra` → pattern kind |
   | `path_begin` / `path_end` | unary, `children[0]` (paired by IP) |

6. **Op-namespace split.** Single IR struct, but `Op` enum has two
   subranges in the same file:
   - `SemOp` (lowered from AST — semantic ops)
   - `EmitOp` (produced by fuse for emission shortcuts: `load_path`,
     `key_exists`, etc. — none today; reserved namespace for fuse's
     output and future passes)
   Switch tables enumerate one namespace at a time.
7. **Not retained at runtime.** VM never sees IR. `CompileResult`
   exposes only legacy-shape fields:
   - `instructions: []Bytecode`
   - `function_table`, `string_buf`, `external_var_ids`, `source_map`,
     `regex_pool`, `prefilter` (all matching legacy field names + types)
   No `parse_plan` field reserved. Future research work adds it as a
   one-line additive API change when needed.
8. **No debug-print in release builds.** IR text dump (used by snapshot
   tests) gated behind `-Ddebug-ir=true`. Zero bytes in ReleaseFast.
   Stable IR text format spec: short doc in
   `research/compiler-ir-format.md` written in R2 (one page).

### 1.4 Guardrails (measured before R4 cutover)

| # | Metric | Bar vs legacy | Measurement |
|---|---|---|---|
| 1 | VM-semantics test pass rate | 100% on extracted fixtures + every existing `tests/query_test.zig` test green under `-Dcompile=new` | `zig build test -Dcompile=new` + new `vm-equiv` step |
| 2 | Compile throughput median | within 5% AND within 2σ of legacy median | `zig build bench-compile`; ≥3 fresh-process runs; σ recorded |
| 3 | Release binary size | within 1% of legacy total [recast in §3.5 per P20 deferral resolution; effective bound: within 10% absolute OR within 1% per added pass file] | `size zig-out/bin/zq`; strip + debug-info flags held constant between legacy and new measurements; baseline numbers in `research/compiler-baselines.md` |
| 4 | Compile peak RSS | within 5% of legacy | `/usr/bin/time -v` over fixture corpus, median across 3 runs |
| 5 | Source-position parity on errors | exact match on curated runtime/compile error fixtures (~30 cases drawn from `tests/compat/*.zig` `expectCompileError`/`expectError` sites) | new step `vm-equiv-errpos`; no tolerance |

Any gate miss → fix root cause, not threshold.

### 1.5 File layout

```
src/compiler/
  root.zig       -- public API: compile() → CompileResult, deinit
  lower.zig      -- AST → IR
  ir.zig         -- IR types, arena, debug dump (gated)
  fuse.zig       -- the one pass today (IR → IR); load_path fold
  emit.zig       -- IR → Bytecode + auxiliary tables
  bench.zig      -- ReleaseFast-only compile-throughput bench

tests/compiler/
  snapshots/lower/  -- AST-string → IR-text-dump snapshot tests
  snapshots/fuse/   -- IR-before → IR-after snapshot tests
  vm_equiv.zig      -- VM-semantics harness (extracted fixtures + dual
                      compile + output-stream diff)
  vm_equiv_errpos.zig -- source-position parity on curated error set

src/ast/parser.zig    -- shared with LSP. Walker-only switch-arms in
                         existing nodes are removed; the AST node types
                         themselves are retained where the LSP uses them.
src/ast/nodes.zig     -- shared (no removals; walker-only consumers removed)

src/query/
  root.zig            -- public query API; dispatches compile backend
                         via `-Dcompile=` build flag
  src/vm.zig          -- unchanged
  src/prefilter.zig   -- unchanged
  src/compiler.zig    -- legacy; deleted in R5
```

### 1.6 Build flag — `-Dcompile`

| Value | Meaning | Phase |
|---|---|---|
| `legacy` | Legacy compiler (`src/query/src/compiler.zig`) | R1–R3 default; removed at R5 |
| `new` | New compiler (`src/compiler/`) under construction | R3 opt-in |

At R4 cutover: default flips from `legacy` to `new`. At R5 (same
sitting): the `-Dcompile` flag is removed entirely; the new compiler
is unconditional. No `canonical`/`experimental` aliases reserved
upfront — when an experimental pass first arrives, that's when
`-Dcompile=experimental` gets added.

---

## 2. What's reused vs discarded

### Reused (kept)

- `src/ast/parser.zig` — stays.
  - `assign_general` node retained: 2 active LSP consumers
    (`src/lsp/analysis.zig:296`, `src/lsp/features/formatting.zig:341`).
  - `parseAssignGeneral` (parser.zig:206-242) retained.
  - Only walker-specific switch-arms in `src/ast/compiler.zig` are
    removed.
- `src/ast/nodes.zig` — no removals; verify no walker-only variants
  remain (none currently identified beyond `assign_general`, which is
  shared).
- `src/query/src/vm.zig` — unchanged.
- `src/query/src/prefilter.zig` — unchanged (already module-scoped).
- BUG-005 d1 fix in legacy `parseObjectFieldValue`, BUG-006 in
  `vm.zig`, regex n-flag operand packing, microbench
  (`src/microbench/`), pool `user_error_msg` plumbing — all from
  commit `c1ef970`, all orthogonal to the walker, all kept.
  Verified via `git show c1ef970 --stat`.
- **Knowledge** captured in Stages 0–12 (operator semantics, builtin
  dispatch, destructure lowering, user-function scope/recursion,
  regex intern discipline, update-assign LHS forms, format strings,
  prefilter harvesting) — re-expressed through the IR in R3.
- All existing tests in `tests/compat/*.zig` and `tests/query_test.zig`
  — they keep running under both compilers via the build flag.

### Discarded

- `src/ast/compiler.zig` (Stage 0–12 walker, byte-identical baggage).
- `tests/ast_compile_equiv.zig`, `tests/ast_compile_equiv_fixtures.zig`.
- `tests/compile_leak_matrix.zig` — keep; it tests legacy parse-error
  cleanup, orthogonal to walker. (Re-examined post-review.)
- All byte-identical parity machinery in the walker (`insertRawInstr`,
  `rebaseExprBuf`, `last_tok_offset` simulation, `scan_cursor` source
  scanner, `scanning_body` body-scan pass).
- `research/phase-2-ast-walk-plan.md` — superseded; banner prepended,
  not deleted.

---

## 3. Phases

### R1 — Revert walker scaffold (one session)

**Goal.** Tree returns to legacy-as-sole-compiler state without losing
the orthogonal fixes that shipped alongside Stages 0–12, without
breaking the LSP.

**Steps.**

1. Pre-revert archaeology: `git tag archive/phase-2-byte-identical 1565f6b`.
   Permanent named pointer to walker tip; never garbage-collected.
2. Create branch `redesign/compiler` off `main`. All R1–R5 work lands
   here; cutover merges back to `main` at end of session.
3. Delete walker files:
   - `src/ast/compiler.zig`
   - `tests/ast_compile_equiv.zig`
   - `tests/ast_compile_equiv_fixtures.zig`
4. Walker-only AST cleanup. Verified scope (post-review):
   - **Keep** `assign_general` node in `src/ast/nodes.zig` and
     `parseAssignGeneral` in `src/ast/parser.zig` — used by
     `src/lsp/analysis.zig:296` and
     `src/lsp/features/formatting.zig:341`.
   - **Remove** any node variant that, after walker deletion, has zero
     consumers. Verify per-variant via
     `rg "\\.<variant_name>\\b" src/`. If a variant has zero hits
     outside `src/ast/parser.zig` and `src/ast/nodes.zig`, it is
     walker-only and deleted; otherwise kept.
   - Document each variant's status in the R1 commit message.
5. Remove walker build wiring:
   - `build.zig`: delete `ast-compile-equiv` step + `ast_compile_equiv`
     test module + walker module imports. Confirm with
     `rg "ast.compiler|ast_compile_equiv" build.zig` returning zero.
6. Supersession bookkeeping:
   - `TODO.md`: replace AST-walk entry with one-line pointer to this
     document.
   - `research/phase-2-ast-walk-plan.md`: prepend `[SUPERSEDED]`
     banner referencing this plan; do not delete.
7. Build + test acceptance:
   - `zig build` passes.
   - `zig build test` matches the post-revert legacy baseline measured
     on the `redesign/compiler` branch (capture the actual numbers in
     R2 step 2; pre-walker counts may have changed since Stage 0).
   - LSP smoke test: `zig build run -- --lsp <<<` document open +
     formatting request executes without error.
8. AST-shape diff verification (parser cleanup soundness check):
   - Run a small driver that parses every filter in
     `tests/compat/*.zig` and dumps AST node tags.
   - Diff against the same corpus parsed at the pre-walker tip
     (commit before `c1ef970`).
   - Any diff: either documented as a legitimate post-walker grammar
     fix kept (e.g. BUG-005 d1) or treated as walker leakage and
     removed.
9. Single atomic commit:
   `refactor(compiler): drop Phase 2 byte-identical walker scaffold;
   supersede with Phase 2R (see research/phase-2r-compiler-redesign-plan.md)`.

**Acceptance.**
- Tree clean.
- Legacy is sole compiler.
- LSP intact.
- Test counts recorded as the new baseline.

### R2 — Baseline measurement + architecture lock-in (one session)

**Goal.** Capture legacy numbers and reserve the architectural seams
for R3+.

**Steps.**

1. Add `zig build bench-compile` target. Filter corpus:
   - 10 filters from `tests/compat/` (small/medium/large AST).
   - 3 filters with user-defined functions.
   - 1 filter with regex literal, 1 with dynamic regex.
   - 1 filter with `reduce`/`foreach`.
   - 1 filter with deep pipe/comma chain.
   N=1000 iterations per filter, ≥3 fresh-process runs, median + p99 + σ.
2. Measure legacy baseline. Record in `research/compiler-baselines.md`:
   - per-filter median µs, p99 µs, σ.
   - peak RSS during bench run.
   - `size zig-out/bin/zq` (text/data/bss/total) — strip + debug-info
     settings recorded.
   - ReleaseFast build; commit hash recorded.
   - `zig build test` baseline pass/fail/skip counts.
3. Write `research/compiler-ir-format.md` — one-page stable spec for
   the IR text dump (op tag, children, span, extra, source offset).
   Format must be diffable line-by-line for snapshot tests.
4. Lock this plan as-is. Future edits require a new revision banner +
   user approval.
5. Commit: `bench(compiler): capture legacy baselines for Phase 2R gate`.

**Acceptance.** Baselines recorded; bench reproducible; IR-format spec
written.

### R3 — Scaffold new compiler, parity behind a flag (one sitting; commit-per-category)

**Goal.** New `src/compiler/` produces bytecode that passes the
VM-semantics harness on every fixture. Legacy remains default at
`src/query/root.zig`. Both build into the same binary when the flag
selects new; only legacy when flag is `legacy`.

**Steps.**

1. Create `src/compiler/{root,lower,ir,fuse,emit,bench}.zig` (empty
   skeletons except `ir.zig`).
2. Define `ir.zig`: `Op` enum (SemOp + EmitOp namespaces), `Node`
   struct (fixed-arity children + span + extra), `IR` container
   (nodes, extra_children, extra_data, arena, source map, string buf
   ref, regex pool ref). Comptime assert `@sizeOf(Node) <= 32`.
3. Wire `src/query/root.zig` to dispatch based on `-Dcompile=`:
   - `legacy` → existing path.
   - `new` → new path. Today returns `error.NewCompilerNotImplemented`
     until R3 lands the first category.
4. Build VM-semantics harness `tests/vm_equiv.zig`:
   - **Compat fixtures**: regenerate from upstream `../jq/tests/jq.test`
     via the existing `tests/scripts/generate_compat_tests.pl`. Each
     test = `{ filter, input, expected_output_or_error }`. ~533 cases.
   - **Hand-rolled tests**: `tests/query_test.zig` (210 cases) does
     **not** extract — it builds tapes directly. Instead, add a
     `-Dcompile=` dispatch at the test-binary level so every existing
     hand-rolled test runs once under each compiler. Compare full
     output stream + error kind + (R3 close) source position.
   - Output: NDJSON `MISMATCH filter=... input=... legacy=... new=...`
     for failed cases.
5. Wire `zig build vm-equiv` step.
6. Port operator categories in this order; each step closes one
   category of the harness:
   1. Literals + identity + recurse + unary
   2. Field/index/iterate/slice + optional `?`
   3. Pipe + comma
   4. Variables + as-pattern + destructure + `?//`
   5. Arithmetic + comparison + logical + alternative `//`
   6. try/catch + if/elif/else + path() + parens
   7. Object/array constructors + string interpolation + format
   8. Update assignments (fast path + general LHS via `assign_general`)
   9. User-defined functions + recursion + filter args
   10. 26 builtins (generator/reducing, `del`/`pick`, `INDEX`/`IN`/`JOIN`)
   11. Regex + datetime + extended arg-builtin surface
   12. Prefilter harvest off the IR (no second `ast.parse`) — ✓ COMPLETE (7454b6f)
7. After each category, harness must be 100% green on that category's
   fixtures + zero new regressions in `zig build test -Dcompile=new`.
8. Fuse pass: port legacy's `.a | .b | .c` → `load_path` fold into
   `fuse.zig` as one IR→IR pass. Other fuse opportunities deferred.
9. Snapshot tests:
   - For each new IR shape: `tests/compiler/snapshots/lower/<name>.txt`
     (AST source string → IR dump in indented-tree format).
   - For each fuse rewrite: `tests/compiler/snapshots/fuse/<name>.txt`
     (IR before → IR after).
   - IR text format: indented tree, one node per line, child indent
     +2 spaces, payload after node tag. Spec: `research/compiler-ir-format.md`.
   - Regeneration: `zig build snapshots-update` rewrites every
     snapshot from current new-compiler output. Intended for
     deliberate IR changes only; CI fails on any uncommitted snapshot
     diff.
10. Commit cadence: one atomic commit per operator category (12
    commits across R3). Each commit must leave the harness 100% green
    on its category, no new regressions in `zig build test
    -Dcompile=new`. Bisectable.
11. Acknowledge `ROADMAP.md § Deliberate Deviations` (large-int,
    division-by-zero, input-EOF, duplicate-keys, etc.) in R3
    acceptance: VM-semantics harness must pass on the deviation
    fixtures since they live in `tests/compat/`. No special handling
    needed if the harness is comprehensive — this is a correctness
    check, not a code path.

**Acceptance.**
- `zig build vm-equiv -Dcompile=new` green on all extracted fixtures.
- `zig build test -Dcompile=new` matches the R2 R1-baseline pass/fail/skip.
- Bench numbers recorded for `-Dcompile=new` against R2 baseline.
- Snapshot tests cover every IR op + every fuse rewrite.

### R4+R5 — Guardrail close, flag flip, legacy delete (one sitting, no soak)

**Goal.** All five guardrails met; new compiler unconditional; legacy
deleted; flag removed. Single sitting per user directive — no soak
window.

**Steps.**

1. Measure all five gates (§1.4) on the R3-final new compiler. Record
   in `research/compiler-baselines.md` as the final pre-cutover row.
2. Any gate miss → root-cause investigation in `bugs.md`, fix in
   `src/compiler/`, re-measure. Do not relax thresholds.
3. Once all five gates pass: cutover commit:
   - Delete `src/query/src/compiler.zig`.
   - Remove `-Dcompile` build flag from `build.zig` entirely.
   - Update `src/query/root.zig` to dispatch the new compiler
     unconditionally.
   - Remove legacy-specific imports, helpers, test hooks.
   - Update `TODO.md`: compiler track closed.
   - Update `ROADMAP.md`: research-roadmap entries that referenced
     "the compiler" now point unambiguously at `src/compiler/`.
4. Run full CI matrix (ReleaseFast, ReleaseSafe, Debug). All green.
5. Re-measure binary size + compile throughput against R2 baseline
   one final time post-flag-removal (flag removal itself can shift
   numbers slightly).
6. Single commit:
   `refactor(compiler): cutover to VM-semantics compiler; delete
   legacy + -Dcompile flag`.
7. Merge `redesign/compiler` to `main` (fast-forward or merge commit
   per repo convention).

**Acceptance.**
- `rg "src/query/src/compiler" src/ tests/ build.zig` returns zero.
- `rg "Dcompile" build.zig` returns zero.
- `zig build test` fully green.
- All five guardrails final numbers in `research/compiler-baselines.md`.

---

### §3.5 R3-extended — Cluster B+ category completion

#### Rationale

The R5 cutover attempt at the original P21 (HEAD `2b9706a`) failed silently
on runtime: 12+ AST shapes and builtin names dispatch through the
`NewCompilerNotImplemented` arm at `src/query/root.zig:104` and route to
legacy via `compileLegacy`. P20 gate 1 measured 178 vm-equiv MATCH but did
not measure the dispatcher-fallback rate. The fallback masked
incompleteness: true new-compiler test coverage was ~1064 pass / ~82 fail
(measured empirically by P21 cutover implementer with fallback removed),
not the reported 1133/13.

User-elected Path 1: implement the missing categories (cat-13 through
cat-18) before retrying cutover. Replans the unit of work from "one
sitting" to "one phase per cat-N" with explicit serialization and a hard
dispatcher-fallback policy.

#### Phase grouping

| Phase | Cat | Operators / AST shapes | lower.zig sites | Affinity rationale | Size vs P18 |
|-------|-----|------------------------|-----------------|--------------------|------------|
| P22 | cat-13 | `range` (1/2/3-arity), `limit`, `first`, `last`, `nth`, `skip` | `lowerBuiltinCall` (1591) — new generator-arg classifier branches; legacy ref `compileRange/Limit/First/Last/Nth` | All numeric iteration generators sharing a save/restore + bounded-yield bracketing pattern; one shared classifier extension `isGeneratorArg{1,2,3}Builtin` | 1.0× |
| P23 | cat-14 | `foreach` AST kind, `reduce range(...)` multi-arity completion, `as`-pattern body holes uncovered by P22 | `lowerNode` else (1251) for `.foreach`; revisit `.as_pattern` body lowering at 1113 | All control-flow built around an iterating source + accumulator; foreach reuses the reduce IR shape per §1.3 row 5 | 1.2× |
| P24 | cat-15 | `label_expr`, `break_expr`, `until`, `while`, `recurse` builtin-call form | `lowerNode` else (1251) for `.label_expr`/`.break_expr`; `lowerBuiltinCall` for `until`/`while`/`recurse` | Backward-jump control flow + label/break unwinding share VM patch-table semantics | 1.3× |
| P25 | cat-16 | `error` (0/1-arity), `index`, `rindex`, `indices`, `del` general forms | `lowerBuiltinCall` (1591); legacy `compileErrorArg`, `compileIndices/Index/Rindex`, `compileDel` | Error raising + path-substring + path-deletion all manipulate the path-stack/path-builder machinery | 1.2× |
| P26 | cat-17 | `format_string` interpolation completion: `@text`, `@json`, `@csv`, `@tsv`, `@html`, `@sh`, `@uri`, `@urid`, `@base64`, `@base64d`; `expr | @json` pipe shape | `lowerNode` `.format_string` (973) — verify all parts paths; `formatBuiltinId` table at emit.zig:1088 already complete | All format builtins resolve via existing `formatBuiltinId` table; remaining work is interpolation-segment edge cases | 0.7× |
| P27 | cat-18 | Dynamic regex patterns (non-literal pattern arg to `test`/`match`/`sub`), `bracket_expr` LHS expression-indexed (`[1,2,3][$x]`, `.[$x]`, `expr[$x]`) | `lowerRegexBuiltinCommon` 1763 (drop the `if (pat_literal == null) return error...`); suffix branch at 625 | Two remaining lowerNode/lower-builtin holes; both require dynamic-arg evaluation paths interacting with `as`-bindings | 1.1× |

#### Per-phase template

Mirrors P15-P18 with one explicit addition for the dispatcher-fallback lesson.

**Implementer (single agent, opus):**
1. Extend `src/compiler/lower.zig` to handle the cat-N AST kinds / builtin names. Add classifier rows where applicable.
2. Extend `src/compiler/ir.zig` with new SemOps **only** when an existing op shape from §1.3 row 5 cannot accommodate the operator. New ops MUST live in `SemOp` namespace; document in `research/compiler-ir-format.md`.
3. Extend `src/compiler/emit.zig` to emit bytecode for new SemOps using the legacy compiler line numbers as the byte-shape reference.
4. Extend `src/compiler/harvest.zig` only if new operators introduce literal-yielding shapes the prefilter should harvest.
5. Add lower snapshots in `tests/compiler/snapshots/lower/cat-N-*.txt` — one per distinct IR shape introduced.
6. Add fuse snapshots only if new shapes interact with `load_path` folding (most cat-13–18 don't).
7. Add vm-equiv fixtures explicitly exercising new operators. Mandatory: ≥ 8 fixtures per phase covering positive + error + edge-case inputs.
8. **Fallback-disabled spot-check (informational)**: in a throwaway worktree, comment out the dispatcher fallback at `src/query/root.zig:102-109`; run `zig build vm-equiv` + `zig build test -Dcompile=new`; record failure delta in implementer brief notes. **The dispatcher fallback stays in the actual commit** — informational only, surfaces incompleteness early.
9. Run `zig build snapshots-update`; commit only if diff is bounded to cat-N additions.

**Verifier trio (parallel, all opus):**
- `mechanical-verifier`: legacy untouched; opcode integrity; no scope creep; vm-equiv MATCH delta ≥ +8.
- `equiv-runner`: full vm-equiv + `-Dcompile=new` + `-Dcompile=legacy`; no regressions.
- `snapshot-validator`: every new SemOp/IR shape has ≥ 1 lower snapshot; deterministic regen; ≤ 200-line snapshots (CONCERN bound from P20).

**Reviewer (single, opus):** BLOCK loop max 2 attempts; on round-3 BLOCK, escalate.

**Git-operator:** ff-merge to `redesign/compiler`; append progress entry under `### Phase NN — cat-N <name>` mirroring P15-P19; update `phase_2r_state.md` inline.

#### Dispatcher fallback policy

**Hard rule until P21-redux:**

> No commit between P22 and P27 inclusive may remove, weaken, or condition the dispatcher fallback at `src/query/root.zig:102-109`. The fallback stays in place across the entire cat-13–18 work cycle. P21-redux's cutover commit is the **only** place where the fallback is removed.

**Rationale:** Removing the fallback during cat-N work causes 69+ test failures and obliterates gate 1/2/4 measurement signal. The fallback is a measurement scaffold (sunset commit: P21-redux), not a workaround per CLAUDE.md.

**Verification of the rule:** each phase's git-operator step diffs `src/query/root.zig:102-109` against `redesign/compiler` tip pre-phase; non-zero diff in those lines → BLOCKING.

#### R3-redux acceptance criteria

Stricter than original §3 R3 acceptance. Replaces it for the cutover (P21-redux):

1. **Cat-13 through cat-18 implemented**: all six phases (P22–P27) merged; each phase's vm-equiv MATCH delta ≥ +8 from its baseline.
2. **Fallback-disabled gate** (the headline): in a verification worktree, comment out `src/query/root.zig:102-109`. Run `zig build test`. Acceptance threshold: ≤ N failures, where N = the count of plan-sanctioned ZQ-DEFER cases (currently 5 from P21 fix-task 1; may grow if cat-13–18 work surfaces additional defers — each new defer requires explicit plan-file ZQ-DEFER row + user sign-off). Failures categorized as: ZQ-DEFER-tagged (allowed), legacy-only-bug (allowed if pre-existing), uncategorized (BLOCKING).
3. **vm-equiv full suite**: target ≥ 178 + Σ(per-phase fixture count) ≈ 254 MATCH minimum, 0 FAIL, ≤ 3 SKIP.
4. **Snapshot suite**: ≥ 1 lower snapshot per new cat-N operator (mandatory); net snapshot count target: ~132 minimum.
5. **§1.4 R4 guardrails re-measured at the new HEAD post-P27** with fallback-disabled measurements where applicable.

#### Phase count + dependency order

```
P22 (cat-13) ──► P23 (cat-14)    (foreach reuses reduce-via-range scaffolding)
P24 (cat-15) ──► P25 (cat-16)    (del paths reuse label/break patch-list)
P26 (cat-17)                     (independent — anywhere)
P27 (cat-18)                     (independent — anywhere)
```

- **Max parallel-team width**: 3 ({P22→P23}, {P24→P25}, {P26 then P27}).
- **Single-team serial order** (recommended): P22 → P23 → P24 → P25 → P26 → P27 → P21-redux.

#### P21-redux

After P27 closes, P21-redux re-runs original §3 R4+R5 procedure:
1. Re-measure all five §1.4 gates at the cat-18 HEAD.
2. Run the fallback-disabled gate (§3.5 acceptance step 2).
3. Once green: cutover commit removes the dispatcher fallback, `src/query/src/compiler.zig`, the `-Dcompile` build flag, and vm-equiv harnesses (Option B per P21 cutover implementer's selection) in one atomic step.

#### Estimated session count to P21-redux

- Single-team serial: 6 cat-N sittings + 1 P21-redux = **7 sittings**.
- Two-team parallel: 3–4 sittings + 1 P21-redux = **4–5 sittings**.
- Three-team parallel (max): 3 sittings + 1 P21-redux = **4 sittings**.

Original plan's "one-sitting R3" assumption (in §3 R3 step 7) is invalidated by the P21 escalation; this section supersedes it.

---

## 4. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Walker-only AST node deletion breaks an LSP feature not yet checked | Low (now) | High | R1 step 7 AST-shape diff catches grammar leakage; per-variant rg verified before deletion |
| Compat-fixture regeneration drifts from `../jq/tests/jq.test` | Medium | Medium | Pin upstream commit hash in `research/compiler-baselines.md`; re-pull only at explicit checkpoints |
| `tests/query_test.zig` dual-dispatch reveals VM-side bugs unrelated to compiler | Medium | Medium | File against existing VM track; do not let them hold up R3 if the same failure occurs under both compilers |
| IR design needs revision mid-R3 | Medium | Medium | IR is arena-scoped + private to `src/compiler/`; refactoring is local. Accept one design-revision budget |
| Compile throughput regresses past 5%/2σ | Medium | High | R3 step 7 measures per category; regression surfaces immediately |
| Binary size grows past 1% | Low | High | IR cap 32 B; no vtables; debug dump gated. Monitor per commit |
| Source-position parity gate fails on a broad set | Medium | Medium | If error fixtures show systematic drift, adjust emit to stamp matching offsets — emission is free elsewhere; positions are not |
| Future research work needs an IR shape this plan didn't anticipate | Low | Medium | Op-namespace split (SemOp/EmitOp) leaves room to add ops without touching existing tag values |

---

## 5. Non-goals

- No optimization passes beyond the existing `load_path` fold.
  Constant folding, extended fuse, projection pushdown, predicate
  pushdown, CSE, TCO, monomorphic specialization, etc. are research
  roadmap items. Architecture must accept them additively; this plan
  does not implement them.
- No VM changes. Bytecode format and opcodes stay. The new compiler
  emits instructions the existing VM already executes.
- No parser rewrite.
- No LSP changes.
- No `tests/query_test.zig` rewrite — it runs as-is under the dual-flag
  test binary.

---

## 6. Audit-during-R3 (not blocking)

1. **Test-file audit.** During R3 step 4, audit every file under
   `tests/` and confirm whether it touches the compiler path (needs
   dual-dispatch wiring) or not. Known primaries: `tests/compat/*.zig`
   (regenerated), `tests/query_test.zig` (dual-dispatch in test
   binary). Anything else discovered during the audit gets the same
   treatment.
2. **Compat fixture upstream pin.** Initial pin recorded in
   `research/compiler-baselines.md` at R2. Subsequent bumps require
   an explicit "bumped to jq@<sha>" commit with regenerated fixtures
   in the same commit.

All previously-deferred decisions are resolved in the revision-3
banner at the top of this document. No remaining open questions.
