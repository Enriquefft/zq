# zq Bug Findings

A record of non-obvious active bugs. Fixed entries are pruned; check git
history / commit messages for resolved incidents.

Last verified: 2026-04-29 (post G4 land — any/all desugar + BOM + interp-key + big_number).

---

## Active compat failures (8 of original L798-unmasked + 6 newly revealed)

Post-G4 baseline: `zig build test` → 1144/1177 pass, 13 fail, 20 skipped.

### Originally-listed, still failing (8)

These are the survivors from the L798-unmasked set after the G4 landing
fixed L48, L122, L1045, L661, L674. Categorisation refined by Phase 1
investigators: several were misfiled as VM but are emit-side input-scope
bugs.

| Tag | Symptom | Repro | Real category | Fix shape (validated by Phase 1) |
|-----|---------|-------|---------------|----------------------------------|
| L200 | `each` else-branch raises bare `error.TypeError`; catch payload reads `"TypeError"` not `"Cannot iterate over number (123)"` | `map(try .a[] catch .)` on `[{a:[1,2]},{a:123}]` | VM (error message) | Set `type_error_detail` via existing `buildTypeErrorMsg` helper at `src/vm/root.zig:2077` (each else). |
| L353 | `.arith` arm emits `<lhs>;<rhs>;op` without protecting LHS across RHS fork-replays | `[foreach .[] / .[] as $i (0; . + $i)]` | Compiler emit | `src/compiler/emit.zig:396` — capture LHS into `allocVar()` temp; idiom already at :1270/1303/1677/1737. Apply to `.cmp` (:411) and `.logical` (:431) too. |
| L401 | `emitFirst`/`emitLast` desugar yields stale `null` when inner stream is empty | `[first(range(.)), last(range(.))]` on `0` → `[null]` (want `[]`) | Compiler emit | `src/compiler/emit.zig:2220-2300` — empty-stream → no contribution semantics. |
| L478 | `setpathRecursive` lacks slice path-component arm | `.[2:4] = ([], ["a","b"], ["a","b","c"])` on `[0..7]` | VM | `src/vm/root.zig:5556-5717` — add `.object` slice arm with start/end resolution + array splice. |
| L725 | `emitAsBind` does not save/restore `it.current` around `<expr>` | `.[] as $x \| [$x == .[]]` | Compiler emit | `src/compiler/emit.zig:3069` — wrap with `save_input`/`restore_input` (mirror `emitDestructAlt:891-896`). Same root as L878. |
| L775 | `.obj_ctor` computed key emitted with no save_input wrapper | `add({(.[]):1})` | Compiler emit | `src/compiler/emit.zig:504-516` — bracket computed key expr. |
| L878 | filter-param binding leaks generator's `it.current` into body | `def x(a;b): a as $a \| b as $b \| $a + $b; def y($a;$b): $a + $b; ...` | Compiler emit | Same site as L725. |
| L915 | reduce/division: `.arith` LHS popped by RHS each-fork backtrack | `[reduce .[] / .[] as $i (0; . + $i)]` | Compiler emit | Same site as L353. |

These cluster into TWO emit-side fixes (`save_input` bracketing + lhs-temp
capture) plus one VM detail-string fix (L200) plus two structural VM
arms (L478 slice, L401 empty-stream). Phase 2 G1 worktree
(`worktree-agent-a69ca2341b0fcaf22`) attempted the emit cluster — it
introduced regressions (L118, L689) and is **not safe to land**; the
diff is preserved on its branch for reference but should be re-driven
from a fresh investigator pass.

### Newly revealed — masked previously by L1045 signal-6 abort (6)

Once G4 fixed L1045 (`any/all` desugar in `classifyBuiltin`), the test
runner stopped aborting at `user_functions.test.jq:L1045` and reached
`paths.test.jq`, exposing six pre-existing failures.

| Tag | Symptom | Repro |
|-----|---------|-------|
| L1127 | `path(...)` over filter chain yields wrong shape | `try path(.a \| map(select(.b == 0)) \| .[0]) catch .` |
| L1131 | same family, with `.c` tail | `try path(.a \| map(select(.b == 0)) \| .c) catch .` |
| L1135 | same family, with `.[]` tail | `try path(.a \| map(select(.b == 0)) \| .[]) catch .` |
| L1139 | nested `path()` not composing | `path(.a[path(.b)[0]])` |
| L1173 | `delpaths(0)` wrong error message | `try delpaths(0) catch .` |
| L1201 | `pick(.a.b.c)` triggers `signal 6` (assertion / unreachable) | `pick(.a.b.c)` |

These were never listed in the prior "13 failure" baseline because the
test runner aborted before reaching them. They are pre-existing,
non-regressions.

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
