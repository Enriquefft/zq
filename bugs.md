# zq Bug Findings

Active bugs and latent issues. Fixed entries are pruned; check git history / commit messages for resolved incidents.

Last verified: 2026-05-05, HEAD 4ce4b4d (post wave-streaming-generators — reduce fold-vs-emit, infinite-gen pool streaming, emitStreamingFrame closures).

---

## Active compat failures

Current baseline: `zig build test` → 1179 pass, 0 fail, 56 skipped. Test suite is green; the runtime bug below is uncovered (compile-only test exists, no execute assertion).

### Multi-segment path on pipe-LHS inside object-field value

| Field | Value |
|-------|-------|
| Symptom | `{k: .a.b \| f}` mis-evaluates the field VALUE. With `f = tostring`/`.`, the result is the field-NAME string ("k"), not `f(.a.b)`. With `f = length` (and similar type-checked builtins) it raises `type error`. Parenthesising the inner pipe (`{k: (.a.b \| length)}`) does not help. |
| Repro | `echo '{"a":{"b":"hi"}}' \| zq '{out: .a.b \| tostring}'` → zq prints `{"out":"out"}`, jq prints `{"out":"hi"}`. `echo '{"a":{"b":"hi"}}' \| zq '{out: .a.b \| length}'` → zq errors `type error`, jq prints `{"out":2}`. |
| Scope | Triggers when the pipe-LHS is a path with **2+ segments** (`.a.b`, `.["a"]["b"]`, `.a.b.c`). 1-segment LHS (`.a \| length`) and the same `.a.b \| length` outside an object construct both work. |
| Severity | HIGH. Silent wrong answer for `tostring`/`.` shapes; runtime error for typed builtins. Hits any caller that builds an object whose field reaches into a nested input. |
| Suspected site | Object-construct codegen for the field-value frame: parser threads `\|` through (BUG-005 d1) but the desugar appears to bind the LHS to the field-name slot when the path has more than one step. The parser-only test at `tests/query_test.zig:644` ("BUG-005: Nix mdbook-anchors filter compiles") does not catch this — it asserts `compile()` succeeds, never executes. |
| Fix sketch | Inspect `emitObject`/object-field-value lowering for the path-prefix optimisation; ensure the LHS path is evaluated against the input value (not the field-name literal) before the `\|` boundary. Add execute-level regression: `{content: .Chapter.content \| length}` on `{"Chapter":{"content":"hi"}}` → `{"content":2}`. |
| Discovered | 2026-05-05 against HEAD 6d178ed, zq 0.2.3. |

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

### `first(...) // fallback` VM bug

`limit_start` exits via `ip = instructions.len`, leaving `fork_alt` frames on the fork stack. G4's `lowerAnyAllDesugar` and G5's `lowerPickDesugar` both work around this by using array-wrap (`[first(...)]`) instead of jq's literal `first(...) // fallback` desugar form. Worth fixing the underlying VM behavior to allow direct `first(...) // fallback` use.

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

