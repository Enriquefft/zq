# zq Bug Findings

Active bugs and latent issues. Fixed entries are pruned; check git history for resolved incidents.

Last verified: 2026-05-07. Suite: 1220/1252 pass, 28 skipped, 4 NIX-004 failures (gsub/sub replacement-as-filter — out of current scope).

---

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

`subtreeHasIterate` / `subtreeRebindsCurrent` / `subtreeMayFork` previously skipped IR child indices equal to 0 (a `!= 0` guard treating index 0 as a sentinel). IR index 0 is a real node, so any `.arith` / `.cmp` / `.logical` / path-assign `.set` whose LHS lowered to index 0 (e.g. `.a = (.a | .)`, `.a = (.a + 1)`) had its predicate result silently flipped from true to false, routing through "raw" instead of save/restore reseed and producing type errors instead of jq-correct output. Fix at ed1d0c1. Future bisects landing on an arith/cmp/logical/path-assign behavior change near this commit should consider the predicate as authoritative.

### D1 whitelist gain absorbed by per-record scratch arena (2026-05-06)

D1 (1366f27) added `load_field`/`load_index`/`load_path` to `subtreeRebindsCurrent`, measured -10.8% / -4.8% / -5.3% on `.a=.b{,.c,.c.d}` against parent `c369339`. After the per-record scratch arena merge `9ee4f20` landed concurrently, those wins collapsed to flat (1.00x / 1.10x / 1.01x at 50k records, σ ~6-9%). The arena change apparently subsumed the savings the whitelist removed. D1 remains a correctness improvement (avoids unnecessary `save_input/restore_input` wrap) but is no longer benchmark-visible on merged main.

### `subtreeRebindsCurrent` SSOT debt — predicate ↔ VM handler coupling (LATENT)

`subtreeRebindsCurrent` at `src/compiler/emit.zig` whitelists IR ops by their VM-handler push-only semantics (`load_field`/`load_index`/`load_path`/`load_variable` plus pure-value ops). The mirror is hand-maintained: a future VM-handler change that re-introduces `it.current` rebinding for any whitelisted op would silently break path-assign fast-path codegen with no failing test elsewhere. `tests/cli_test.zig` D1-pin tests anchor the load_path/load_index/load_variable arms; remaining whitelist entries (`identity`, `arith`, `cmp`, `logical`, `alt`, `neg`, `not`, `arr_ctor`, `obj_ctor`, `interp`, `format`, `load_const`) still rely on the convention that VM handlers for those ops push without touching `it.current`. Real fix would derive the predicate from a single declaration co-located with each opcode (or a comptime table the VM and predicate both consume).

### `reduce` pattern-var-clobbering across recursive calls (LATENT)

A `reduce` expression with `as $key` pattern variables clobbers `$key`/`$in` slots across recursive `call_function` invocations — the inner recursive call overwrites the outer call's pattern-var slot. Walk/1's desugar (commit a626191) avoided this by using `to_entries | map(.value |= walk(f)) | from_entries` instead of jq's canonical `reduce keys[] as $key ({}; ...)` form. Reduce works correctly for non-recursive bodies; the bug surfaces only when a recursive self-call lives inside `reduce`'s update body. Fix would address pattern-var slot allocation in `emitReduce` to scope per-frame rather than per-fn_id.

### Filter-arg recursive value passing (LATENT)

`def w(n): … w(n+1) end; w(1)` (filter-arg `n`, not value-arg `$n`) — the body is lowered once with `n` substituted as the FIRST call site's arg AST. Inner recursive call_function jumps to that shared body, where `n` is baked in to the outer value. Recursion does not see updated `n`. Pre-emit (`0566623`) keeps `cache.body_ip` valid across `captureAndTruncate` regions, but does not address per-call filter-arg re-substitution. Proper fix would either re-lower the body per recursive call or coerce filter-arg → value-arg semantics for recursive shapes. Not exercised by current corpus; surfaces only as `def w(n)` recursion with `n` referenced inside the body's recursive call args.
