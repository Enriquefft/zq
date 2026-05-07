# zq Bug Findings

Active bugs and latent issues. Fixed entries are pruned; check git history / commit messages for resolved incidents.

Last verified: 2026-05-06, HEAD ed1d0c1 (post B1-B6 wave — load_path/load_computed push semantics, big_number negate/length, streaming-frame yields, per-frame slot snapshots, recursive 1+arity self-calls, path-assign `.set` RHS-mutates-current + IR child-arity predicate guard).

---

## Active compat failures

Current baseline: `zig build test` → 1210 pass, 0 fail, 28 skipped. Zero active
failures in the test corpus. The compat generator still emits inputs as compact
single-line JSON only, but the ingestion layer is now JSON-structure-aware
(see NIX-001 below — fixed) so that limitation is no longer a correctness gap.

---

## NIX-001: Pool input chunker splits on `\n` without tracking JSON structural context (FIXED)

Discovered 2026-05-06 during /etc/nixos jq → zq overlay re-enable attempt.
Default-mode invocation (no `--slurp`, no `--null-input`) routed both stdin
and file-arg paths through `pool.submit_stream` / `pool.submit_file`
(`src/main.zig:642`, `src/main.zig:732`). The chunker split the byte stream
at newline boundaries and dispatched each line as an independent JSON record
to a worker — without tracking `{}`/`[]` depth or string state. Any
pretty-printed (multi-line) top-level value was shredded into per-line
fragments, each of which failed to parse as a standalone value.

### Fix (landed)

Single-source-of-truth structural boundary scanner (`src/parser/src/boundary.zig`)
shared by all three pool ingestion sites:

- `file_feeder_fn` (`src/pool/root.zig`) — persistent `ScannerState` walks the
  mmapped file once sequentially; each chunk_end is a depth-0/outside-string
  `\n`, so multi-line pretty values are never split across workers.
- `io_thread_fn` → `io_thread_json_boundaries` — persistent scanner across
  RingBuffer views; pipe-stall flushes only at clean record boundaries
  (carry empty + depth 0 + not in_string). Raw-input retains the line-split
  via `io_thread_raw_lines` (jq `--raw-input` parity).
- `worker_fn` — replaces the `\n`-split loop with a `parser.feed`-loop that
  cursor-advances on each `.done`, mirroring `collectJsonValues`
  (`src/main.zig:821`). Raw-input keeps the per-line split.

`process_line_serialized` and `process_line` were renamed to
`process_value_serialized` / `process_value` — they now take a pre-parsed
tape from the worker's feed-loop instead of re-parsing per line. The
`countNewlines` record-count estimator on the JSON path was replaced with
`boundary.countTopLevelValues`.

Two parser API quirks documented and handled:
1. `parser.feed` with `is_eof=true` returns `.done { consumed = 0 }` from
   `processEof` for values finalized via EOF (e.g. integer at end-of-buffer
   with no terminator). Worker advances cursor to slice-end in that case.
2. `findNextRecordEnd` may consume past the next ideal chunk midpoint;
   `file_feeder_fn` clamps `ideal_end` to `chunk_start` and breaks early
   once the prior chunk has consumed past EOF.

### Test coverage

- `src/parser/src/boundary.zig` — 10 module-level unit tests (empty input,
  JSONL three boundaries, pretty-3-lines, string-with-newline, structural-
  in-string, escape-pending across `feedBytes` split, escaped backslash,
  unterminated string, `countTopLevelValues`, `findNextRecordEnd`).
- `tests/cli_test.zig` — 6 NIX-001 CLI tests (the original 4 RED reproducers
  plus concatenated pretty values and `--raw-input` multi-line).
- `tests/pool_test.zig` — 2 module tests (`submit_file: pretty record
  crossing chunk boundary (4 workers)`, `submit_stream: pretty value
  spanning IO refill`).

Pinned regressions:

```sh
$ printf '{"a":1}'         | ./zig-out/bin/zq '.a'      # 1
$ printf '{\n  "a": 1\n}'  | ./zig-out/bin/zq '.a'      # 1
$ printf '[\n  1,\n  2\n]' | ./zig-out/bin/zq 'length'  # 2
```

## NIX-002: ReleaseSafe SIGABRT on cascade-error path (EXPECTED RESOLVED, downstream of NIX-001)

The same `closure-info` filter that produced an exit-5 cascade locally pre-fix
(NIX-001) hit SIGABRT (exit 134) inside the nix sandbox. The hypothesis was
cascade error: parser repeatedly fed mis-aligned chunks, `parser.reset()`
invoked on a non-record-aligned boundary, leaving stale tape / string-buf
state that a later `feed()` indexed into.

Now that NIX-001 is fixed (chunks are always record-aligned, parser only
sees complete values), the precondition for this crash should no longer
exist. To verify against the live nix sandbox, re-enable the system-wide
`pkgs.jq → zq` overlay and retry the closure-info build. If the SIGABRT
still reproduces, the parser's reset-on-error path needs an audit for
tape/string-buf invariants — but the most likely outcome is that this
crash is gone.

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

- **Duplicate `--arg` / `--argjson` / `--slurpfile` / `--rawfile` NAME collision**: zq resolves **last-wins** (final occurrence shadows earlier ones); jq resolves **first-wins**. zq behavior is consistent across all four binding flags and matches shell-override intuition. Documented; not slated for change.

---

## Architectural follow-ups (parked, not in current scope)

### B4b predicate-arity correction — bisect bookmark (2026-05-06, ed1d0c1)

`subtreeHasIterate` / `subtreeRebindsCurrent` / `subtreeMayFork` previously skipped IR child indices equal to 0 (a `!= 0` guard treating index 0 as a sentinel). IR index 0 is a real node, so any `.arith` / `.cmp` / `.logical` / path-assign `.set` whose LHS lowered to index 0 (e.g. `.a = (.a | .)`, `.a = (.a + 1)`) had its predicate result silently flipped from true to false, routing through "raw" instead of save/restore reseed and producing type errors instead of jq-correct output. Fix at ed1d0c1 (D6 audit 2026-05-06: 23+ filter sweep, zero jq-compat regression vs parent 72eb07d on filters that worked PRE; baseline arith/cmp/logical (`.a + .b`, `.a == .b`, `(.a>0) and (.b>0)`) within ±1% noise on 200k inputs). Future bisects landing on an arith/cmp/logical/path-assign behavior change near this commit should consider the predicate as authoritative.

### D1 whitelist gain absorbed by per-record scratch arena (2026-05-06)

D1 (1366f27) added `load_field`/`load_index`/`load_path` to `subtreeRebindsCurrent`, measured -10.8% / -4.8% / -5.3% on `.a=.b{,.c,.c.d}` against parent `c369339`. After the per-record scratch arena merge `9ee4f20` landed concurrently, those wins collapsed to flat (1.00x / 1.10x / 1.01x at 50k records, hyperfine 30-50 runs, σ ~6-9%). The arena change apparently subsumed the savings the whitelist removed. D1 remains a correctness improvement (avoids unnecessary `save_input/restore_input` wrap) but is no longer benchmark-visible on merged main. Worth noting before claiming the speedup elsewhere.

### `subtreeRebindsCurrent` SSOT debt — predicate ↔ VM handler coupling (LATENT)

`subtreeRebindsCurrent` at `src/compiler/emit.zig:4239-4263` whitelists IR ops by their VM-handler push-only semantics (`load_field`/`load_index`/`load_path`/`load_variable` plus pure-value ops). The mirror is hand-maintained: a future VM-handler change that re-introduces `it.current` rebinding for any whitelisted op would silently break path-assign fast-path codegen with no failing test elsewhere. `tests/cli_test.zig` D1-pin tests (added 2026-05-06) anchor the load_path/load_index/load_variable arms; remaining whitelist entries (`identity`, `arith`, `cmp`, `logical`, `alt`, `neg`, `not`, `arr_ctor`, `obj_ctor`, `interp`, `format`, `load_const`) still rely on the convention that VM handlers for those ops push without touching it.current. Real fix would derive the predicate from a single declaration co-located with each opcode (or a comptime table the VM and predicate both consume).

### `try ((.a, .b) + 1)` comma-fork inside try-wrapped binop (FIXED)

Discovered 2026-05-06 during D-wave audit verification. On `{"a":2,"b":3}`, jq yields `3\n4` (each fork value `+ 1`); zq yielded `4\n4` (second fork's value applied twice). Reproduced on `c369339` (pre-D-wave) and `ed1d0c1` (B4b) — pre-existing.

Root cause: `emit.zig` `.try_` no-handler arm emitted the body first then `instructions.insert(start, fork_try)`. The insert shifted every body instruction down by one, but body-internal backpatched IPs (comma's `fork right_start`, `jump end`; alt jumps) still referenced pre-shift indices, so a comma's fork target landed off-by-one. Both arms ended up routing through the second value. Even the pure-literal `try (1, 2)` printed `2\n2` pre-fix.

Fix: emit `fork_try` *before* the body via `pushInstr` (mirrors handler-present form). With the prefix in place from the start, body-side backpatches reference final IPs. `catch_ip` stays 0 (suppress sentinel preserved). Regression tests at `tests/query_test.zig` B5 wave: `try (1, 2)`, `try (.a, .b)`, `try ((.a, .b) + 1)`. All four manual repros now match jq; full suite 1213/1241 pass, 0 failed.

### `reduce` pattern-var-clobbering across recursive calls (LATENT)

Discovered 2026-04-30 during walk/1 implementer work. A `reduce` expression with `as $key` pattern variables clobbers `$key`/`$in` slots across recursive `call_function` invocations — the inner recursive call overwrites the outer call's pattern-var slot. Walk/1's desugar (commit a626191) avoided this by using `to_entries | map(.value |= walk(f)) | from_entries` instead of jq's canonical `reduce keys[] as $key ({}; ...)` form. Reduce works correctly for non-recursive bodies; the bug surfaces only when a recursive self-call lives inside `reduce`'s update body. Fix would address pattern-var slot allocation in `emitReduce` to scope per-frame rather than per-fn_id.

### Bug residuals from prior orchestration (not in current scope)

| Tag | Status |
|-----|--------|
| L873 | Parser: def-after-binding — fixed in a370bcd / merge 99580b9. Confirmed PASS. |
| L884 | Parser: multi-index before def — fixed in a370bcd. Confirmed PASS. |
| L933 | Parser: nested destructure — fixed in a370bcd. Confirmed PASS. |

