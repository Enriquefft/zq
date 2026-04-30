# zq Bug Findings

A record of non-obvious active bugs. Fixed entries are pruned; check git
history / commit messages for resolved incidents.

Last verified: 2026-04-30 (post builtin-fixes wave — with_entries, rindex, sort_by stability, min_by/max_by tie-breaking).

---

## Active compat failures (1 pre-existing from try_catch.zig + 6 newly-exposed post-fixes)

Current baseline: `zig build test` → 1127/1177 pass, 30 fail, 20 skipped.

### Pre-existing failures (L1481)

Masked by L1712's signal-6 in prior baseline; remain unfixed.

| Tag | Symptom | Repro | Category | Hypothesis |
|-----|---------|-------|----------|-----------|
| L1481 | `try -.? catch .` mismatched output | `try -.? catch .` | error message | unary-minus on non-numeric error string format mismatch vs jq |

### Newly exposed post-L1712 fix (6)

Once L1712 signal-6 was fixed, test runner continues and exposes pre-existing failures in datetime, numbers suites.

| Tag | Symptom | Repro | Category | Hypothesis |
|-----|---------|-------|----------|-----------|
| L2037–L2053 | div-by-zero error message mismatch | `try (1/0) catch .` | error message | try/catch error message format differs from jq |
| L2062 | range parse error | `[range(-99/2;99/2;1)]` | parser | range with negative float bounds fails to parse |
| L2080 | INDEX signal-6 abort | `INDEX(range(5)\|[., _foo_(.)_]; .[0])` | builtin | INDEX builtin triggers signal 6 (segfault equivalent) |

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

### Fixed post-G6

- L1692 (`.foo[.baz]` computed-index now reseeds outer input for key eval — restructured `computed_index` IR node to binary `[base, key]` shape; emit captures outer input pre-base, restores it pre-key; new `mark_computed_key` opcode suppresses path-component pollution during inner key eval inside `path(f)` / path-assign frames)

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
