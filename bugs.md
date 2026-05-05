# zq Bug Findings

Active bugs and latent issues. Fixed entries are pruned; check git history / commit messages for resolved incidents.

Last verified: 2026-05-05.

---

## Active compat failures

Current baseline: `zig build test` → 1173/1201 pass, 4 fail, 24 skipped. Remaining failures: 4 decnum-gated (L2195 L2223 L2262 L2266).

| Tag | Symptom | Category | Note |
|-----|---------|----------|------|
| L2195 | `(13911860366432393 == 13911860366432392)` | numeric | i64 equality near precision boundary; gated on decnum support. |
| L2223 | `[1E+1000,-1E+1000 \| tojson]` | decnum | Park until decnum support is decided. |
| L2262 | `[1E+1000,-1E+1000 \| abs \| tojson] \| unique` | decnum | Park until decnum support is decided. |
| L2266 | `[1E+1000,-1E+1000 \| length \| tojson] \| unique` | decnum | Park until decnum support is decided. |

## Intentional jq divergences

Documented, internally-coherent deviations from jq's observable behavior. Not bugs.

- **Duplicate `--arg` / `--argjson` / `--slurpfile` / `--rawfile` NAME collision**: zq resolves **last-wins** (final occurrence shadows earlier ones); jq resolves **first-wins**. zq behavior is consistent across all four binding flags and matches shell-override intuition. Documented; not slated for change.

---

## Architectural follow-ups (parked, not in current scope)

### `first(...) // fallback` VM bug

`limit_start` exits via `ip = instructions.len`, leaving `fork_alt` frames on the fork stack. G4's `lowerAnyAllDesugar` and G5's `lowerPickDesugar` both work around this by using array-wrap (`[first(...)]`) instead of jq's literal `first(...) // fallback` desugar form. Worth fixing the underlying VM behavior to allow direct `first(...) // fallback` use.

### `reduce` with streamed `limit/repeat` source emits vs folds (LATENT)

Discovered 2026-05-05 during repeat(f) coverage review (wave-cleanup-hygiene, phase 3). zq's `reduce` treats a streamed `limit(N; repeat(...))` source as a scalar list emit-vs-fold rather than folding over the stream. Symptom: `reduce limit(1; repeat(.+1)) as $x (0; . + $x)` with input `5` emits `5` and `6` (each value alongside init) instead of folding to `11` as jq does. Root cause: reduce's generator arm loads the source stream but does not integrate with the fold-loop; each source emission triggers a separate update-arm evaluation instead of accumulating into the fold state. Fix would refactor reduce's streaming-source handling in `emitReduce` to thread through the accumulator across all source emissions (similar to `limit/skip` integration with `first`).

### `reduce` pattern-var-clobbering across recursive calls (LATENT)

Discovered 2026-04-30 during walk/1 implementer work. A `reduce` expression with `as $key` pattern variables clobbers `$key`/`$in` slots across recursive `call_function` invocations — the inner recursive call overwrites the outer call's pattern-var slot. Walk/1's desugar (commit a626191) avoided this by using `to_entries | map(.value |= walk(f)) | from_entries` instead of jq's canonical `reduce keys[] as $key ({}; ...)` form. Reduce works correctly for non-recursive bodies; the bug surfaces only when a recursive self-call lives inside `reduce`'s update body. Fix would address pattern-var slot allocation in `emitReduce` to scope per-frame rather than per-fn_id.

### big_number missing arms in negate + length (LATENT)

| Field | Value |
|-------|-------|
| Symptom | `-(1E+1000)` and `1E+1000 \| length` produce wrong or error output |
| Repro | `echo null \| zq '-1E+1000'` and `echo null \| zq '1E+1000 \| length'` |
| Root cause | `src/vm/root.zig:1935-1953` negate switch lacks `.big_number` arm; `length` builtin has same gap |
| Affects | Any filter that arithmetics or measures big_number values |
| Severity | LOW today (no test coverage after decnum skip-guard), MEDIUM if Tier 4.3 literal-passthrough lands |
| Fix sketch | Add `.big_number` arm to `negate` (negate source bytes' sign) + `length` (return UTF-8 byte count of source slice) |
| Discovered | 2026-05-05 by wave-decnum-triage |

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

## Streaming generator refactor (PARKED)

`emitRepeat` and `emitLimitSkipNth` share scaffolding (`<op_start exit_ip> <body> yield_output backtrack <op_end>`). Factor into `emitStreamingFrame(start_op, end_op, body_idx)` for the next streaming-generator builtin (e.g., unfold, walk-generators).
