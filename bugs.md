# zq Bug Findings

A record of non-obvious active bugs. Fixed entries are pruned; check git
history / commit messages for resolved incidents.

Last verified: 2026-04-29 (post G5 land — emit lhs-temp / save_input bracketing, vm slice + iter detail + delpaths msg, pick desugar).

---

## Active compat failures (1 emit residual + 4 path-flavor + 6 newly revealed + L1421 signal-6)

Post-G5 baseline: `zig build test` → 1146/1177 pass, 11 fail + 1 signal-6, 20 skipped.

### Still failing after G5 (5)

| Tag | Symptom | Repro | Category | Notes |
|-----|---------|-------|----------|-------|
| L878 | filter-param binding still leaks `it.current` into body — emitAsBind fix in G5 covers value-arg as-binds (L725) but the filter-arg call site uses a different emission path | `def x(a;b): a as $a \| b as $b \| $a + $b; def y($a;$b): $a + $b; ...` | Compiler emit | Sibling of fixed L725. Filter-arg `def` lowers to a different emit shape that needs the same save_input/restore_input bracket; not yet wrapped. |
| L1127 | `path(.a \| map(select(.b == 0)) \| .[0])` — generic "Invalid path expression with result" message; jq says "near attempt to access element 0 of <v>" | `try path(...) catch .` | VM (error message) | Phase 1 inv-path identified `raisePathExprError` at `src/vm/root.zig:7888` needs op-flavor tag captured in PathFrame at the path-break site (`vm/root.zig:1004`). G5 G2 implementer punted on this (claimed they "already pass" — wrong). |
| L1131 | same flavor as L1127, tail `.c` | `try path(.a \| map(select(.b == 0)) \| .c) catch .` | VM | Same site as L1127. |
| L1135 | same flavor, tail `.[]` | `try path(.a \| map(select(.b == 0)) \| .[]) catch .` | VM | Same site as L1127. |
| L1139 | `path(.a[path(.b)[0]])` returns wrong shape — nested-path heuristic at `vm/root.zig:1960-1962` poisons outer frame even when inner result is consumed as int subscript | `path(.a[path(.b)[0]])` on `{a:{b:42}}` | VM (heuristic) | Refine the heuristic — only mark broken if produced value is consumed as path-array, not scalar. |

### Newly revealed by G4+G5 — were masked by signal-6 aborts in baseline (6 + 1 signal-6)

Once G4 fixed L1045 (signal-6 in user_functions) and G5 fixed L1201 (signal-6 in pick), the test runner reached compat sections that previously never ran. These are all pre-existing failures.

| Tag | Symptom | Repro |
|-----|---------|-------|
| L1258 | `getpath([_a_,0,_b_]) \|= 5` mismatched error string | `.[] \| try (getpath([_a_,0,_b_]) \|= 5) catch .` |
| L1290 | `((map(select(.a == 1))[].b) = 10)` mismatched output | `try ((map(select(.a == 1))[].b) = 10) catch .` |
| L1294 | `((map(select(.a == 1))[].a) \|= .+1)` mismatched output | `try ((map(select(.a == 1))[].a) \|= .+1) catch .` |
| L1302 | `def x: reverse; x=10` runtime error path | `try (def x: reverse; x=10) catch .` |
| L1306 | `.[] = 1` parser bug — onWantValue rejects | `.[] = 1` |
| L1322 | `[if 1,null,2 then 3 else 4 end]` VM crash at execOneInner:1292 | `[if 1,null,2 then 3 else 4 end]` |
| L1421 (signal 6) | `[(_foo_ \| contains(_foo_)), ...]` aborts test runner — comparisons.zig:103 | `[("foo" \| contains("foo")), ...]` |

L1421 is the new test-runner abort point. Once fixed, more pre-existing failures may surface (mirroring what L1045 → L1201 → L1421 chain has revealed).

### Fixed in G5 round (commit pending)

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
