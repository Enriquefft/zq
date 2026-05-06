# zq Bug Findings

Active bugs and latent issues. Fixed entries are pruned; check git history / commit messages for resolved incidents.

Last verified: 2026-05-05, HEAD 4ce4b4d (post wave-streaming-generators — reduce fold-vs-emit, infinite-gen pool streaming, emitStreamingFrame closures).

---

## Active compat failures

Current baseline: `zig build test` → 1184 pass, 0 fail, 56 skipped. Zero active failures.

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

### `reduce` pattern-var-clobbering across recursive calls (LATENT)

Discovered 2026-04-30 during walk/1 implementer work. A `reduce` expression with `as $key` pattern variables clobbers `$key`/`$in` slots across recursive `call_function` invocations — the inner recursive call overwrites the outer call's pattern-var slot. Walk/1's desugar (commit a626191) avoided this by using `to_entries | map(.value |= walk(f)) | from_entries` instead of jq's canonical `reduce keys[] as $key ({}; ...)` form. Reduce works correctly for non-recursive bodies; the bug surfaces only when a recursive self-call lives inside `reduce`'s update body. Fix would address pattern-var slot allocation in `emitReduce` to scope per-frame rather than per-fn_id.

### Bug residuals from prior orchestration (not in current scope)

| Tag | Status |
|-----|--------|
| L873 | Parser: def-after-binding — fixed in a370bcd / merge 99580b9. Confirmed PASS. |
| L884 | Parser: multi-index before def — fixed in a370bcd. Confirmed PASS. |
| L933 | Parser: nested destructure — fixed in a370bcd. Confirmed PASS. |

