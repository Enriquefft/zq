# zq Bug Findings

A record of non-obvious active bugs. Fixed entries are pruned; check git
history / commit messages for resolved incidents.

Last verified: 2026-05-05, HEAD 14c3e71 (post wave-generator-decnum-conditional — 4 decnum-gated tests skipped via generator allowlist).

---

## Active compat failures

Current baseline: `zig build test` → 1173 pass, 0 fail, 28 skipped. Zero active failures.

## Skipped via generator (Deliberate Deviation: decnum)

The compat generator emits `error.SkipZigTest` for these four tests via the
hardcoded `%SKIP_DECNUM_GATED` allowlist in `tests/scripts/generate_compat_tests.pl`.
Each filter contains an `if have_decnum/have_literal_numbers then … else … end`
shape; the else-branch encodes lossy f64 behavior zq deliberately doesn't
emit (see ROADMAP.md → Deliberate Deviations → Number representation).
SSOT for the `have_decnum` / `have_literal_numbers` truth value:
`tests/compat/zq_features.zig`, mirrored from `src/vm/root.zig:4176`.

| Tag | Filter |
|-----|--------|
| L2195 | `(13911860366432393 == 13911860366432392) \| . == if have_decnum then false else true end` |
| L2223 | `[1E+1000,-1E+1000 \| tojson] == if have_decnum then [...] else [...] end` |
| L2262 | `[1E+1000,-1E+1000 \| abs \| tojson] \| unique == if have_decnum then [...] else [...] end` |
| L2266 | `[1E+1000,-1E+1000 \| length \| tojson] \| unique == if have_decnum then [...] else [...] end` |

If decnum support ever lands, flip the constants in `tests/compat/zq_features.zig`
and the skip guards become no-ops automatically; the allowlist can then be retired.

## Intentional jq divergences

Documented, internally-coherent deviations from jq's observable behavior. Not bugs.

- **Duplicate `--arg` / `--argjson` / `--slurpfile` / `--rawfile` NAME collision** (wave5-cli-flags-12): when the same `NAME` is bound by multiple CLI bindings, zq resolves **last-wins** (the final occurrence on the command line shadows earlier ones). jq resolves **first-wins**. zq's behavior is consistent across all four binding flags and matches the natural shell-override intuition (`--arg x 1 --arg x 2` ⇒ `$x == "2"`). Documented; not slated for change.

### Fixed in wave4-large-reduce-compaction (3)

Merged 2026-05-04:
- L2549 / L2554 / L2559 (commit f714eec, merge f665d79): `reduce range(9999+) as $_ ([];[.]) | tojson | fromjson` and siblings. Quadratic tape growth via `copyTapeSpanToRuntimeTape` in the reduce update-arm body saturated `RuntimeTape.max_entries=4*1024*1024` before serialize/parse could run. Fix lands per-iteration tape compaction in the reduce update-arm via a new `compact_runtime_tape` opcode; converts deep tape walks to iterative form to avoid recursion blowup; adds parse/serialize depth gates to fail-fast on pathological depth before tape OOM. Touches `src/vm/root.zig` (~830 lines), `src/compiler/emit.zig`, `src/types.zig`. Tests: 1152→1155 pass, 7→4 fail (remaining decnum-gated). Full diagnosis in commit f714eec body.

### Fixed in wave3-imports-modulemeta (12)

Merged 2026-05-04:
- L1891 / L1895 / L1899 / L1903 / L1908 / L1912 / L1916 / L1920 / L1984 (commit 82821b2, Phase 2a): jq module system parser + resolver. `import "x" as foo` and `include "x"` syntax now parses; new `src/module_resolver/root.zig` (renamed from `src/compiler/resolver.zig`) walks `JQ_LIBRARY_PATH` + relative paths to load and link module ASTs into the consuming program. Module fixtures under `tests/compat/fixtures/modules/` exercise import-then-call, include-then-call, and `as $alias::name` referencing.
- L1960 / L1964 / L1968 (commit 79979e7, Phase 2b): `modulemeta` builtin. Replaces the prior `lookupKeyInValue` abort on `modulemeta` with a real implementation in `src/vm/root.zig` (~302 LOC) that returns the module's `{name, deps, ...}` metadata object as jq does. `meta` keys flow through the resolver's per-module record; `deps` enumerates resolved imports/includes; `BuiltinClass`/dispatch wired through `lower.zig`+`emit.zig`+`types.zig`.

### Fixed in wave-2 fold-3 closure (17)

Merged 2026-05-03:
- repeat:nested-limit (commit b4be0ee, Phase 1a): `yield_output` propagates limit decrements outward — `[limit(2; limit(3; repeat(.+1)))]` and similar nested-limit forms now respect outermost truncation correctly.
- L2438 / L2442 (commits 49719e7 + 0046231): parser slice-bound literals clamp i64-overflow values to i32 range. `.[99999999999999999999:]` no longer panics; literal bounds saturate at i32 ±limits matching jq.
- L2489 (commit c050207 via merge): `fromjson` error message reshape — invalid JSON input now raises catchable error with jq-canonical shape.
- L2426 / L2430 / L2434 (commit 260b745 via merge): float slice-bound rounding. `sliceBoundFromStackValue` adds `SliceBoundKind` enum so from/to bounds round per jq semantics (toward 0); `.[1.5:3.5]` on `[1..5]` yields `[2,3,4]` matching jq.
- L2458 / L2466 / L2470 / L2474 / L2478 (commit a90150b via merge of wave2-nan-slice-errors): NaN slice bounds treated as absent; `.[1:nan]` on array yields `.[1:]`. setpath through `null` path-component on array raises canonical UserError "Cannot set array element at NaN index". load_computed `.string` arm under non-integer index emits "Cannot index string with number (<f>)" via new `index_number_float: f64` TypeErrorKind variant. setpath slice-arm on string base raises UserError "Cannot update string slices".
- L2524 (commit b1691e8 via merge of wave2-setpath-array): setpath base × path-component matrix dispatch. New helpers `setpathRaiseIndexError` / `setpathRaiseSliceIndexError` produce jq-canonical "Cannot index <T> with <pc>" and "Array/string slice indices must be integers" messages across all base/pc combos. Special-case "Cannot update field at array index of array" UserError preserved. Hand-merged with NaN+errors at `.null_val` arm: array-base → NaN error wins, else → setpathRaiseIndexError(base, "null").
- L2539 (commit c0b9df8 via merge of wave2-strftime-save): `strftime` / `strflocaltime` save-input across format-string filter argument. Adds `BuiltinClass` enum (lower.zig L1669-1681), `isMath1Builtin` classifier, math1 emit arm (emit.zig L2201-2233) so the filter-arg generator no longer pollutes outer input.
- L2416 / L2421 (commit 9d616b6 via merge of wave2-update-assign-gen): walk/1 generator-aware update-assign. New `walk1` SemOp in IR enum, `lowerWalkDesugar1` reduced 170→20 lines via direct emit handler (`emitWalk1`), `walkApplyBody` return type ZqError!Value → ZqError!?Value with `walkChildren` skip-null path. `[walk(.,1)]` on `{x:0}` → `[{x:0},1]`; `walk(select(IN({},[]) | not))` on `{a:1,b:[]}` → `{a:1}`.
- saved_collect_len (commit 0638062 via merge of wave2-repeat-collect-cleanup): tests-only wave (+37 lines, 3 oracle-probe coverage tests) — `RepeatState` already snapshots/restores collect-stack depth correctly; coverage tests pin the contract. Merger note: original commit subject overstates scope (claims VM fix); body discloses honestly. Acceptable as-is.
- regex:n-flag (commit bf778c0 via merge of wave2-regex-n-flag): `match(""; "n")` and similar empty-only-pattern matches with `n` flag now drop to no-match (empty stdout, exit 0) per jq. Adds `runFilterStrict` test helper for empty-stream coverage; reverts incorrect prior fixture; 3 sibling tests added. 6 sites in `builtinMatch`/`builtinCapture` exhaustion arms updated with `@max(n_slots, 1)` saturation.

### Fixed in finish-the-domain wave (15)

Merged 2026-04-30:
- L2332 (commit d657abb): `debug/0` builtin — added to `isZeroArgBuiltin` in lower.zig + `nameToBuiltinId` mapping in emit.zig. Was the next abort-slot panic.
- L2299 (commit e028d48): `$y` shorthand inside object literals — added `.dollar_ident` ObjectKey AST variant; runtime dereference of variable to bound value's source key.
- L2328 (commit 54b7535): `try input catch .` — `input/0` raises catchable `UserError` on EOF instead of returning zero rows.
- L2394 + L2398 + L2402 (commit cd28a2e): `implode` U+FFFD substitution for invalid surrogates + `load_computed` type-error detail; `map(try implode catch .)` now passes.
- L2306 + L2310 + L2315 (commit 5148a3e): `NaN`/`Infinity` literals in `fromjson` (writeValue NaN arm) + JSON parser's `in_keyword` state; round-trip `tojson \| fromjson` of NaN now works.
- L2381 (commit 4aad5c9): `fork_try` zero-sentinel preservation across `rebaseInstrs` in emit (update-each path).
- L2121 (commit 063ca3c): suspend path-recording for `as`-binding LHS in path-context — added `path_suspend`/`path_resume` opcodes. `(.a as $x \| .b) = _b_` now produces correct path frames.
- L2126 (commit 56ba371): `and`/`or` short-circuit via if-then-else AST desugar; fixes path pollution in if conditions.
- L2345 + L2350 (commit 47f7af7): generator-aware `try_handler` deferral in `pop_try` + partial-output collection in test helper (`it.next() catch null`).
- L2407 (commit a626191): `walk/1` desugar to jq canonical prelude form via synthesized `func_def` AST. Object arm uses `to_entries \| map(.value \|= walk(f)) \| from_entries` instead of jq's `reduce keys[]` to avoid pre-existing reduce pattern-var-clobbering bug. Adds `bodyReferencesSelf` detection of `builtin_call` self-references for recursive desugar bodies.

### Fixed in error-format/VM/parser wave (10)

Merged 2026-04-30:
- L1802 (commit 6e9898e): `try flatten(-1) catch .` — `flatten/1` now raises UserError matching jq prelude `"flatten depth must not be negative"` shape.
- L2084 + JOIN/3 + JOIN/4 (commit f1f7a5c): `JOIN/2/3/4` now desugar at AST level via shared `buildJoinPair` helper to jq prelude form `def JOIN($idx; idx_expr): [.[] | [., $idx[idx_expr]]];`.
- L2088 + L2096 + L2107 + L2112 + L2116 (commit ff25f25): `IN/1` and `IN/2` desugar to `any(. == s; .)` / `any($source; . == s)` respectively at AST level. Operand swap on /1 avoids pre-existing VM generator-on-LHS reseed asymmetry; commutativity-correct.
- L2130 + L2134 + L2138 (commit 9d699db): `isempty/1` desugar to `first((f|false), true)` AST; deleted dead `builtinIsempty` VM stub (14 lines).
- Dead-code removal (commit 3294f28): deleted `toFloat(val: StackValue) ZqError!f64` from `vm/root.zig` after R-impl correctly identified that `bool→1.0/0.0` branch differed from `else=>TypeError` semantics at every of 47 call sites. `@floatFromInt` is the actual SSOT; `toFloat` was a wrong wrapper.

### Fixed in G7/G8/G9/G10/G12 orchestration wave (14)

Merged 2026-04-30: L2037 L2041 L2045 L2049 L2053 (G7 div/mod-by-zero error format), L1988 L1992 L1996 (G8 binary-arith error format + UTF-8 truncation), L1736 (G9 suffix-form computed-slice base reseed), L1886 (G9 multiplication overflow + binop outer-input reseed), L2005 (G9 oversized integer literal coerce + add variant), L1838 (G12 strftime fixture generator regex fix), L2062 (G10 leading-dot float lexer + computed_index in subtreeHasIterate), L2080 (G10 INDEX/1 INDEX/2 AST desugar).

Baseline: 1131 → 1144 pass (+13). Subsequent error-format/VM/parser wave unmasks → 1134 honest pass.

### Fixed in pre-existing-fixes wave (3)

Merged 2026-04-30: L1481 unary-minus error format, L1692 computed-index outer-input reseed, L1696 string fixture correction.

- L1481: `try -.? catch .` — VM unary-minus error path now formats the operand with jq's `"<type> (<value>) cannot be negated"` shape instead of bare `"TypeError"`.
- L1692: `.foo[.baz]` computed-index now reseeds outer input for key eval — restructured `computed_index` IR node to binary `[base, key]` shape; emit captures outer input pre-base, restores it pre-key; new `mark_computed_key` opcode suppresses path-component pollution during inner key eval inside `path(f)` / path-assign frames.
- L1696: Test fixture corrected to match jq's actual output for `.[] | .error = "no, it's OK"` — no parser bug; the prior fixture string was wrong.

### Fixed in builtin-fixes wave (4)

Merged 2026-04-30: L1592 rindex, L1668 sort_by stability, L1684 min_by/max_by tie-breaking, L1712 with_entries.

- L1592: Computed slice bounds support (`parser` + `AST` + `IR` + `emit` + `VM` — `.[:rindex("x")]` now works; also fixed UTF-8 codepoint indexing in doSlice)
- L1668: Sort multi-output key grouping in emit (array_collect wrapping for by-key family ensures 1:1 element-to-key pairing)
- L1684: max_by tie-break from `== .gt` to `!= .lt` (jq asymmetry: min_by first-wins, max_by last-wins; min_by already correct)
- L1712: with_entries desugar in lower (AST synthesis to `to_entries | map(f) | from_entries`; no new VM opcode)

### Fixed in G6 round (commits 5d8888b, 2b1fb80, 53f2a67, 0e020c6)

- L1421 (`contains/inside` arity-1 builtins added to lower + emit dispatch)
- L1322 (`if-cond` reseed via variable instead of save/restore_input across fork-points)
- L878 (factored `emitInputScopeBracket`/`emitInputScopeReseed` helpers in emit.zig; applied at filter-arg call sites)
- L1127 / L1131 / L1135 (PathFrame extended with `break_kind` + `break_source` enum, populated at upstream-value descent ops, dispatched per-kind by `raisePathExprError`)
- L1139 (path_end nested-path heuristic refined: terminal-output taints outer with `break_kind=.generic`, computed-key consumer pops + skips component append; outer-frame pop in terminal-else added in 0e020c6)
- L1290 / L1294 (clearsPathBroken refined to consult `break_origin` enum — only clears when same-step-scratch, preserves when upstream-value)
- L1258 (`getpath` marked path-emitting; `builtinGetpath` populates frame components for autovivify in `getpath(P) |= V`)
- L1302 (parser dispatches lparen body to parseFilter so leading `def` is accepted before assignment)
- L1306 (parser accepts `Infinity`, `-Infinity`, `NaN`, `-NaN` JSON literals)

### Fixed in G5 round

L200 (each iter detail), L353 (.arith lhs-temp), L401 (emitFirst empty-stream), L478 (setpath slice arm), L725 (emitAsBind save/restore), L775 (.obj_ctor computed-key save_input), L915 (.arith reduce), L1173 (delpaths msg), L1201 (pick desugar).

### Fixed in G4 round

L48, L122, L661, L674, L1045.

### Bug residuals from prior orchestration

| Tag | Status |
|-----|--------|
| L873 | Parser: def-after-binding — fixed in a370bcd / merge 99580b9. Confirmed PASS. |
| L884 | Parser: multi-index before def — fixed in a370bcd. Confirmed PASS. |
| L933 | Parser: nested destructure — fixed in a370bcd. Confirmed PASS. |

---

## Architectural follow-ups (not in current scope)

### `first(...) // fallback` VM bug

`limit_start` exits via `ip = instructions.len`, leaving `fork_alt` frames on the fork stack. G4's `lowerAnyAllDesugar` and G5's `lowerPickDesugar` both work around this by using array-wrap (`[first(...)]`) instead of jq's literal `first(...) // fallback` desugar form. Worth fixing the underlying VM behavior to allow direct `first(...) // fallback` use.

### `reduce` with streamed `limit/repeat` source emits vs folds (LATENT)

Discovered 2026-05-05 during repeat(f) coverage review (wave-cleanup-hygiene, phase 3). zq's `reduce` treats a streamed `limit(N; repeat(...))` source as a scalar list emit-vs-fold rather than folding over the stream. Symptom: `reduce limit(1; repeat(.+1)) as $x (0; . + $x)` with input `5` emits `5` and `6` (each value alongside init) instead of folding to `11` as jq does. Root cause: reduce's generator arm loads the source stream but does not integrate with the fold-loop; each source emission triggers a separate update-arm evaluation instead of accumulating into the fold state. Fix would refactor reduce's streaming-source handling in `emitReduce` to thread through the accumulator across all source emissions (similar to `limit/skip` integration with `first`).

### `reduce` pattern-var-clobbering across recursive calls (LATENT)

Discovered 2026-04-30 during walk/1 implementer work. A `reduce` expression with `as $key` pattern variables clobbers `$key`/`$in` slots across recursive `call_function` invocations — the inner recursive call overwrites the outer call's pattern-var slot. Walk/1's desugar (commit a626191) avoided this by using `to_entries | map(.value |= walk(f)) | from_entries` instead of jq's canonical `reduce keys[] as $key ({}; ...)` form. Reduce works correctly for non-recursive bodies; the bug surfaces only when a recursive self-call lives inside `reduce`'s update body. Fix would address pattern-var slot allocation in `emitReduce` to scope per-frame rather than per-fn_id.

### Bug residuals from prior orchestration (not in current scope)

| Tag | Status |
|-----|--------|
| L873 | Parser: def-after-binding — fixed in a370bcd / merge 99580b9. Confirmed PASS. |
| L884 | Parser: multi-index before def — fixed in a370bcd. Confirmed PASS. |
| L933 | Parser: nested destructure — fixed in a370bcd. Confirmed PASS. |

---

## Infinite generators: zero-output via pool streaming (HIGH)

| Field | Value |
|-------|-------|
| Symptom | Bare infinite generator filters (e.g. `repeat(.+1)`, `range(1; 1_000_000_000)`) emit zero bytes to stdout/file/pipe. |
| Repro | `echo 0 \| zq 'repeat(.+1)'` — hangs with no output (kill before OOM). Same with `zq 'range(1; 1_000_000_000)'`. |
| Root cause | `src/pool/root.zig:822-836` (`process_line_serialized`) buffers an entire chunk's serialized output into `chunk_buf` **before** publishing to the sequencer. An infinite-generator iterator never returns null → chunk never publishes → no bytes ever flush. |
| Affects | Any filter that produces an unbounded result stream without an enclosing `limit/skip/first/last` short-circuit. |
| Not affected | Bounded generators (`limit(N; repeat(.+1))`, `range(1; 100)`, finite filters) — all flush correctly. |
| Severity | HIGH (correctness, but only on infinite filters which are themselves rare in agent workloads). |
| Fix sketch | Stream output from `process_line_serialized` incrementally — flush partial `chunk_buf` to sequencer at a configurable byte/record threshold, rather than waiting for iterator exhaustion. |
| Discovered | 2026-04-29, during `repeat(f)` builtin review. |

---

## repeat(f) follow-ups (LOW/MEDIUM)

Cleanup items from the post-merge review of `feat/repeat-builtin` (3a4a350). Implementation is semantically correct vs jq 1.8.1 and passes 10 compat tests with zero leaks under 1M-iteration stress. These are latent quality issues, not active failures.

| Severity | Location | Issue | Status |
|----------|----------|-------|--------|
| ~~MEDIUM~~ | `src/vm/root.zig` `.repeat` backtrack arm | `fp.saved_stack` / `fp.saved_object` branches were unreachable (`.repeat_start` never populated either). | Resolved in wave-cleanup-hygiene Commit 1 — dead branches dropped. |
| ~~LOW~~ | `src/vm/root.zig` `RepeatState` | Missing `saved_call_len` (try_handler/alt_handler/label all carry it). | Resolved in wave-cleanup-hygiene Commit 1 — captured at `.repeat_start` push, restored in backtrack arm. |
| ~~LOW~~ | `tests/compat/repeat_builtin.zig` | Coverage gaps: try/catch, label/break, reduce-as-init, `[limit(0; repeat(.))]`, path. | Mostly resolved in wave-cleanup-hygiene Commit 2 — 4 of 5 added (try/catch, label/break, empty-limit array, path). The `reduce limit(N; repeat(.+1)) as $x` case parked — zq's reduce currently emits the streamed values instead of folding them when the source is `limit/repeat`; bug is wider than this wave's cleanup scope. |
| ~~NIT~~ | `src/vm/root.zig` `.repeat_start` comment | "backtrack_ip is unused" was technically true but the field was set to `exit_ip` for symmetry; comment was confusing. | Resolved in wave-cleanup-hygiene Commit 1 — comment reworded to make the unused-but-symmetric assignment explicit. |
| NIT | `src/compiler/emit.zig:2264-2278` | `emitRepeat` and `emitLimitSkipNth` share scaffolding (`<op_start exit_ip> <body> yield_output backtrack <op_end>`). | Parked — factor into `emitStreamingFrame(start_op, end_op, body_idx)` for the next streaming-generator builtin. |

Discovered: 2026-04-29. Resolved (most): 2026-05-05.
