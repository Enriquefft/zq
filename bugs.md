# zq Bug Findings

A record of non-obvious active bugs. Fixed entries are pruned; check git
history / commit messages for resolved incidents.

Last verified: 2026-04-30 (post finish-the-domain orchestration wave — closed L2121 L2126 L2299 L2306 L2310 L2315 L2328 L2332 L2345 L2350 L2381 L2394 L2398 L2402 L2407; fold-2 unmask exposed walk/1 then walk/2 + float-slice cluster).

---

## Active compat failures

Current baseline: `zig build test` → 1118/1177 pass, 35 fail, 24 skipped. Wave closed 15 tags; fold-3 unmask (left for next wave) revealed 12 latent regression-suite failures (walk/2, float-index slices, fromjson try, large-reduce tojson, strflocaltime, regex n-flag empty pattern, repeat nested-limit) that were masked by the prior `walk_desugar1` abort slot. Per wave protocol (max 2 fold-iterations) these are deferred.

### Imports / modulemeta (G11 — out of scope this wave)

| Tag | Symptom | Category |
|-----|---------|----------|
| L1891 / L1895 / L1899 / L1903 / L1908 / L1912 / L1916 / L1920 / L1984 | `import "x" as foo` / `include "x"` syntax errors | parser/imports — module import & include not implemented |
| L1960 / L1964 / L1968 | `modulemeta` lookupKeyInValue abort | builtin — `modulemeta` not implemented (segfault on lookup) |

### In-domain unmasked (next wave candidates — fold-3 from finish-the-domain wave)

| Tag | Symptom | Repro | Category | Hypothesis |
|-----|---------|-------|----------|-----------|
| L2195 | `(13911860366432393 == 13911860366432392) \| . == if have_decnum then ... else ... end` | i64 equality near precision boundary | numeric | gated on decnum support (jq decimal numbers feature flag). Skip until decnum domain opened. |
| L2416 | `[walk(.,1)]` | walk/2 arity | builtin | walk/2 is a 2-arity variant in later jq prelude; only walk/1 lowering exists. Add walk/2 desugar (or accept jq's optional-arg form). |
| L2426 / L2430 / L2434 | `[range(10)] \| .[1.2:3.5]` etc | float slice indices | slice/index | jq accepts non-integer slice bounds (rounds toward 0); zq's slice arm rejects float bounds via TypeError. Coerce bounds via `@floatFromInt`-aware path. |
| L2438 / L2442 | `.[1.7:4294967295]` / `.[1.7:-4294967296]` | large/negative slice bounds | slice | overflow on i64 conversion; jq clamps to len. |
| L2458 | `[range(3)] \| .[1:nan]` | NaN slice bound | slice | jq treats NaN as 0 / no-op; zq raises TypeError. |
| L2466 | `try ([range(3)] \| .[nan] = 9) catch .` | NaN index assign | assign/index | should produce catchable error; currently shape mismatch. |
| L2470 / L2474 / L2478 | `try (_foobar_ \| .[1.5:3.5] = _xyz_) catch .` etc | float slice/index in assign path | assign | assign-LHS path validation for non-integer indices/slices. |
| L2489 | `try fromjson catch .` | fromjson on null input | error-class | error message shape mismatch on `fromjson` over null/non-string input. |
| L2524 | `try [_OK_, setpath([[1]]; 1)] catch [_KO_, .]` | setpath nested-array path | builtin/setpath | setpath path-element type validation; jq raises specific error shape. |
| L2539 | `strflocaltime(__ \| ., @uri)` | strflocaltime + format-string filter arg | builtin/datetime | strflocaltime/1 over a generator argument — likely missing fork-on-arg. |
| L2549 / L2554 / L2559 | `reduce range(9999) as $_ ([];[.]) \| tojson \| fromjson` etc | large-reduce + tojson roundtrip | builtin | tojson on deeply-nested array — output buffer growth or recursion limit. |
| regex.test.jq:n-flag empty-only pattern | `match(_x*_; _n_)` when pattern matches only empty | regex | builtin/regex | n-flag should drop empty-only matches. |
| repeat_builtin nested limits | `[limit(2; limit(3; repeat(.+1)))]` | nested limit ordering | repeat | outer limit truncates first; reorder fork-frame interaction. |

### Decnum domain (gated on `have_decnum` flag)

| Tag | Symptom |
|-----|---------|
| L2223 | `[1E+1000,-1E+1000 \| tojson] == if have_decnum then ...` |
| L2262 | `[1E+1000,-1E+1000 \| abs \| tojson] \| unique == if have_decnum then ...` |
| L2266 | `[1E+1000,-1E+1000 \| length \| tojson] \| unique == if have_decnum then ...` |

All three guard on `have_decnum` for the precise-decimal branch. Park until decnum support is decided.

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

| Severity | Location | Issue | Fix |
|----------|----------|-------|-----|
| MEDIUM | `src/vm/root.zig:6956-6967` | `.repeat` backtrack arm has `if (fp.saved_stack)` and `if (fp.saved_object)` branches, but `.repeat_start` (1792-1802) never populates either field. Dead code. | Drop both branches — fall through to `value_stack.items.len = fp.saved_value_stack_len`. Iteration semantics don't need stack/object snapshots. |
| LOW | `src/vm/root.zig:137-141` | `RepeatState` lacks `saved_call_len`. try_handler/alt_handler/label all carry it. Repeat re-enters body each iteration; a body with `label $L \| ...break $L` inside a partially-popped recursive def could leave call_stack unbalanced across iterations. No reproducer found. | Add `saved_call_len: u32` to `RepeatState`; capture at `.repeat_start` push, restore in backtrack arm. |
| LOW | `tests/compat/repeat_builtin.zig` | Coverage gaps: `try/catch` mid-body assertion, `label/break` interaction, `reduce limit(N; repeat(.+1)) as $x (init; ...)`, `[limit(0; repeat(.))]`, `path(repeat(...))`, 1M-iteration stress. | Add cases. The label/break case would surface the LOW-severity row above. |
| NIT | `src/vm/root.zig:1786-1789` | Comment "backtrack_ip is unused" is technically true but `backtrack_ip = exit_ip` is set "for diagnostic symmetry". Confusing for readers modeling fork-frame transitions. | Either set `backtrack_ip = body_start_ip` (encodes actual re-entry target) or add explicit `// unused; symmetry only` marker. |
| NIT | `src/compiler/emit.zig:2264-2278` | `emitRepeat` and `emitLimitSkipNth` share scaffolding (`<op_start exit_ip> <body> yield_output backtrack <op_end>`). | Factor into `emitStreamingFrame(start_op, end_op, body_idx)` for the next streaming-generator builtin. |

Discovered: 2026-04-29.
