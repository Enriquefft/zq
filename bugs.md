# zq Bug Findings

Active bugs and latent issues. Fixed entries are pruned; check git history for resolved incidents.

Last verified: 2026-05-07. Suite: 1220/1252 pass, 28 skipped, 4 NIX-004 failures (gsub/sub replacement-as-filter — out of current scope).

---

## NIX-006 — `StackValue.tape_value.string` aliasing across runtime_tape grows (UAF / SIGSEGV)

**Status**: open, reproduces on `main` (39d8f2c) and on the working tree's
in-progress NIX-005 follow-up (which extends `stabilizeAgainstStringBuf` to
`builtinMatch` / `builtinSub` / `builtinScan` / `builtinMatchG` /
`builtinSplits`). The follow-up patch is necessary but not sufficient — it
covers regex *input* aliasing but not the broader `StackValue.tape_value.string`
aliasing exercised by this repro.

**Symptom**: `zq -f filter.jq input.json` exits 134 (SIGABRT after SIGSEGV)
with stack trace pointing at `compiler_rt/memcpy.zig` from
`appendSliceAssumeCapacity` inside `internStringConcat`:

```
Segmentation fault at address 0x...
compiler_rt/memcpy.zig:170:17        memcpyFast
std/array_list.zig:987:42            appendSliceAssumeCapacity
src/types.zig:233:54                 internStringConcat
src/types.zig:196:39                 internString
src/vm/root.zig:3844                 stackValueToRuntimeTapeEntry  (tape_value.string arm)
src/vm/root.zig:3786                 constructObjectFromFieldsRange
src/vm/root.zig:1959                 execOneInner                  (object construction)
```

**Trigger shape** (all three required to reach a crash):
1. `gsub` (or sub/scan/match) whose replacement filter dereferences captures
   (`.anchor`, `.text`, …) — produces a `StackValue.tape_value.string` whose
   slice is taken from `runtime_tape.view.string_buf` (`vm/root.zig:3253`,
   `:3552`).
2. The result is plumbed through string `+` concatenation in the replacement
   filter, repeatedly re-publishing slices into `string_buf`.
3. The resulting string is bound as a field of a recursively-constructed
   object whose construction is interleaved with further `internString*`
   calls (`constructObjectFromFieldsRange` at `vm/root.zig:3776`).

Trigger is exercised in the wild by NixOS's `nix-manual` mdbook build via
the `[preprocessor.anchors] command = "jq --from-file ./anchors.jq"` step
(`pkgs/tools/package-management/nix/manual.nix` →
`doc/manual/anchors.jq`), reaching SIGSEGV when zq is overlaid for jq.

**Self-contained repro** (no external files, runs against the current repo):

```sh
# 1. Build (any optimization mode crashes; Debug gives the trace above)
zig build -Doptimize=Debug -Dshim-archive=$(realpath \
    third_party/zq-regex-shim/target/release/libzq_regex_shim.a)

# 2. Generate ~4KB synthetic chapter tree (depth=2, branching=8).
python3 -c "
import json
def chap(s, kids): return {'Chapter':{'content':s, 'sub_items':kids}}
def gen(d, p):
    return [] if d == 0 else [chap(f'[t]{{#{p}{i}}}', gen(d-1, p+str(i)))
                              for i in range(8)]
print(json.dumps([{'renderer':'html'}, {'items': gen(2, '')}]))
" > /tmp/nix006.json

# 3. Reduced anchors.jq — recursive Chapter walk + capture-using gsub.
cat > /tmp/nix006.jq <<'EOF'
def rec(t):
  . + { Chapter: (.Chapter + {
    content: (.Chapter.content | t),
    sub_items: (.Chapter.sub_items | map(rec(t)))
  })};
.[0] as $ctx | .[1]
| . + { items: (.items | map(rec(
    gsub("\\[(?<text>[^\\]]+?)\\]\\{#(?<anchor>[^\\}]+?)\\}";
         "<a id=\"" + .anchor + "\">" + .text + "</a>")
  ))) }
EOF

# 4. Run — exits 134 reliably (5/5 in dev).
./zig-out/bin/zq -f /tmp/nix006.jq /tmp/nix006.json
echo "exit=$?"   # → exit=134
```

The repro is sensitive to record size because `string_buf`'s growth schedule
determines whether the realloc lands between the slice's capture and its
read. The depth=2 / branching=8 tree (~4KB) crashes 5/5; depth=1 trees do not.

**Root cause**: `StackValue.tape_value.string` carries a raw `[]const u8`
pointing into `runtime_tape.view.string_buf`. Any subsequent operation that
grows `string_buf` (string concat, `internString` for capture names,
chained gsub) can relocate the backing — the cached slice is now a
dangling pointer into freed memory. When that StackValue is later
materialized via `stackValueToRuntimeTapeEntry → internString`,
`SliceSnap.capture` (`src/types.zig:167`) checks the slice against the
*current* `string_buf` backing. The check fails (pointer lies outside the
new backing), so it is classified `.external` and the raw dangling
pointer is handed to `appendSliceAssumeCapacity` → memcpy → SIGSEGV.

`SliceSnap` only protects against in-call self-aliasing during a single
`internString*` invocation; it cannot detect a slice that was captured
against a *previous* incarnation of `string_buf` and stored on the value
stack across other VM operations.

**Why NIX-003 / NIX-005 fixes don't catch this**: NIX-003 sealed
`internStringConcat` against in-call self-aliasing. NIX-005 (39d8f2c)
duped gsub's *result string* into the per-record scratch arena before
returning, eliminating that specific aliasing path. The working-tree
follow-up extends `stabilizeAgainstStringBuf` to all regex input/result
sites. None of these touch the broader invariant: any
`StackValue.tape_value.string` produced from `runtime_tape.view.string_buf`
(slice ops at `:3253`, concat at `:3552`, replacement-filter
materialization, etc.) lives on the value stack with a raw slice that
goes stale on the next `string_buf` realloc.

**Real fix path**: change `StackValue.tape_value.string` from
`[]const u8` to a tape-relative reference (`StringRef`, resolved against
`runtime_tape.view.string_buf` at every read), mirroring how
`object`/`array` already use `TapeSpan`. Spot fixes (duping at every
producer site) are the workaround shape; they leak through whenever a
new producer is added and bury the cost (per-record dupes) in arena
churn.

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
