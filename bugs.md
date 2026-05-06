# zq Bug Findings

Active bugs and latent issues. Fixed entries are pruned; check git history / commit messages for resolved incidents.

Last verified: 2026-05-06, HEAD ed1d0c1 (post B1-B6 wave — load_path/load_computed push semantics, big_number negate/length, streaming-frame yields, per-frame slot snapshots, recursive 1+arity self-calls, path-assign `.set` RHS-mutates-current + IR child-arity predicate guard).

---

## Active compat failures

Current baseline: `zig build test` → 1198 pass, 0 fail, 28 skipped. Zero active
failures in the test corpus. **Caveat:** the corpus emits inputs as compact
single-line JSON only — see NIX-001 below for a class of inputs the corpus
does not exercise.

---

## NIX-001: Pool input chunker splits on `\n` without tracking JSON structural context (CRITICAL)

Discovered 2026-05-06 during /etc/nixos jq → zq overlay re-enable attempt.
Default-mode invocation (no `--slurp`, no `--null-input`) routes both stdin and
file-arg paths through `pool.submit_stream` / `pool.submit_file`
(`src/main.zig:642`, `src/main.zig:732`). Per `src/pool/INTERFACE.md:23-29` the
pool splits the byte stream at newline boundaries and dispatches each line as
an independent JSON record to a worker.

The chunker is not JSON-structure-aware: it does not track `{}` / `[]` depth
or string state. Any pretty-printed (multi-line) JSON top-level value is
shredded into per-line fragments, each of which fails to parse as a standalone
value. Output is a cascade of "type error / unexpected token at line 1, col 1"
lines plus garbage `null` / `0` records, exit 5.

The compat suite never surfaces this because `tests/scripts/generate_compat_tests.pl`
emits inputs as compact single-line JSON. The bug lives entirely in the input
ingestion layer, upstream of the VM the B1–B6 wave addressed.

### Minimal reproducer

```sh
$ printf '{"a":1}'         | ./zig-out/bin/zq '.a'      # compact → 1
$ printf '{\n  "a": 1\n}'  | ./zig-out/bin/zq '.a'      # pretty  → unexpected token, exit 5
$ printf '[\n  1,\n  2\n]' | ./zig-out/bin/zq 'length'  # pretty array → exit 5
```

`-s` / `--slurp` and `-n` / `--null-input` are unaffected — they go through
`processSlurpJson` / `processNullInput` which use `collectJsonValues`
(`src/main.zig:821`), a single-stream parser that handles whitespace between
top-level tokens correctly.

### Real-world impact

`/etc/nixos` jq → zq overlay (`pkgs.jq` symlink-joined to zq) breaks the
`closure-info` derivation (and every other nixpkgs build that pipes
`$NIX_ATTRS_JSON_FILE` into jq). Nix emits structuredAttrs JSON pretty-printed.
Filter under test:

```
.closure | map([.path, .narHash, .narSize, "", (.references | length)] + .references) | add | map("\(.)\n") | add
```

Build log: `nix log /nix/store/6gb5ibmq20d7cld5l3wxrj1fnzkfz1c9-closure-info.drv`
→ SIGABRT (exit 134) — see NIX-002.

Class of affected inputs: anything Nix or a human writes pretty-printed —
package manifests, mdbook configs, language-server output, `kubectl … -o json`,
GitHub API responses, `nix derivation show`. This is the dominant JSON shape
outside JSONL log streams.

### Fix sketch

Two viable directions:

1. **Structural chunker.** Teach the pool's split routine to track depth and
   string state so `\n` only delimits records at depth 0 outside strings.
   Preserves parallelism for JSONL and concatenated multi-document inputs.
2. **Autodetect single-document mode.** First-pass scan: if the first complete
   top-level value spans the whole input, route to `collectJsonValues`. Only
   activate the JSONL chunker when ≥2 top-level values are observed at depth 0.
   Simpler, gives up parallelism on single-document inputs (acceptable — a
   single document doesn't benefit from per-line worker dispatch anyway).

Until either lands, system-wide `pkgs.jq → zq` overlay must stay disabled.

## NIX-002: ReleaseSafe SIGABRT on cascade-error path (LATENT, downstream of NIX-001)

The same `closure-info` filter that produces an exit-5 cascade locally
(NIX-001) hits SIGABRT (exit 134) inside the nix sandbox. ReleaseSafe panic
handler dumps `Segmentation fault at address 0x7ffff7efea50`; debug info is
stripped so no Zig stack frame survives. Local ReleaseSafe build does not
reproduce against synthesized closure JSON — the trigger requires a specific
combination of input shape and parser-reset cadence that the nix sandbox
produces and my synthesized closure does not.

Almost certainly secondary to NIX-001: parser repeatedly fed mis-aligned
chunks, `parser.reset()` invoked on a non-record-aligned boundary, leaving
stale tape / string-buf state that a later `feed()` indexes into. Likely
resolves automatically once NIX-001 is fixed; if it persists, the parser's
reset-on-error path needs an audit for tape/string-buf invariants.

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

