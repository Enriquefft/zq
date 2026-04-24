# zq Bug Findings

A record of non-obvious bugs and root causes. Check here before debugging
similar symptoms.

Last verified: 2026-04-23.

---

## BUG-001: Silent write elimination in ReleaseFast/ReleaseSafe (extern union + non-extern struct)

**Symptom**: SIGSEGV or wrong opcode in release builds. Debug builds work fine.

**Root cause**: Mixing `extern union` inside a non-`extern struct` gives LLVM
two contradictory memory layout stories. LLVM uses the `extern union`'s ABI
authority to conclude a write to another field in the same struct is dead
code — and deletes it silently.

**Example**:
```zig
// WRONG — extern union inside non-extern struct
const RawInstr = struct {
    op: RawOp,       // RawOp is extern union — LLVM claims ABI ownership
    operand: ...,
};
// Zig reorders fields. LLVM sees contradiction. Write to `op` gets DCE'd.
// op stays 0 (.output) even after writing .fork.

// CORRECT — outer struct must also be extern
const RawInstr = extern struct {
    op: RawOp,
    operand: ...,
};
```

**Rule**: If a struct contains an `extern union`, the struct must also be
`extern struct`.

**Fixed in**: `RawInstr` + `RawOp` (commit after `d37a5e7`);
`Instruction.Operand` (`src/types.zig`). Re-verified 2026-04-23:
`RawInstr` (`src/query/src/compiler.zig:68`), `Tape.Entry`
(`src/types.zig:19`), and `Instruction` (`src/types.zig:691`) are all
`extern struct`. No non-extern outer structs remain around the codebase's
three `extern union`s.

**Why only release builds**: LLVM's TBAA dead-code elimination only runs at
`-O2`/`-O3`. Debug skips it.

**CI status (open)**: `.github/workflows/ci.yml:40` runs `zig build test` at
the default optimization level. Line 74 builds ReleaseSafe as a
cross-compile step but does not run tests. Adding a dedicated
`zig build test -Doptimize=ReleaseSafe` job would keep safety checks active
while enabling the optimizations that expose this class of bug. Not yet in
CI.

---

## BUG-002: Silent test inflation via SkipZigTest

**Symptom**: Test suite reports 500+ passing. After refactor, drops to ~327.
Looks like a regression.

**Root cause**: Unimplemented filters returned `error.QuerySyntaxError`,
which was caught and converted to `error.SkipZigTest`. Zig's test runner
counts skipped tests alongside passes in some output modes. ~228 tests were
never executing.

**Rule**:

1. Never use `error.SkipZigTest` to hide unimplemented features. A test for
   a missing feature must fail loudly — silently passing an unimplemented
   case hides regressions and inflates the passing denominator.
2. `error.SkipZigTest` IS acceptable for build-time feature gates.
   `-Dregex=false` disables the Rust shim at build time; regex-dependent
   tests legitimately skip in that configuration (see the
   `if (!regex.enabled) return error.SkipZigTest` pattern across
   `src/regex/`, `src/query/src/prefilter.zig`, `tests/pool_test.zig`,
   etc). Gate on the build option, not on "someone will implement it
   eventually".

**Fixed in**: Domain-split test refactor (post-`2e8eb29`). Re-verified
2026-04-23: all 116 `SkipZigTest` callsites are either build-option gates
(mostly `if (!regex.enabled)`) or legitimate stress/bench skips. Compat
denominator remains 533.

---

## BUG-003: Prefilter false negatives on escape-encoded JSON strings

**Symptom**: `select(.k | test("LIT"))` silently drops records whose `k`
serializes `LIT`'s bytes as JSON escapes (`\uXXXX`, short escapes like
`\n`/`\t`, or `\"` / `\\`). Spec-legal JSON records are eliminated before
the query ever runs.

**Root cause**: The prefilter performed a raw-byte SIMD scan for required
literals over record bytes. RFC 8259 §7 permits a string like `"foo"` to be
serialized as `"foo"`; the raw scan misses the escape-encoded form.
The earlier workaround (`canPrefilterLiteral` rejecting anything containing
`\`, quotes, controls, or non-ASCII) discarded whole classes of literals
instead of handling the escape forms, so the hole was merely narrowed, not
closed.

**Rule**: Any soundness property that depends on source encoding must
either (a) handle every spec-legal encoding or (b) degrade to the general
path on evidence that the encoding might differ. Never ship a raw-byte
optimization that silently assumes one canonical form.

**Fixed in**: commit `8a73a20` — escape-aware fallback. A record is
accepted by a required literal if EITHER its raw bytes appear OR the record
contains any `\` byte (0x5C). Every JSON escape form requires a backslash;
if none is present, no escape-encoded occurrence is possible and the record
can soundly be rejected. Every literal with `len >= 2` is now
prefilter-safe (including `"`, `\`, control chars, non-ASCII UTF-8).
Re-verified 2026-04-23 at `src/query/src/prefilter.zig:128-149` (logic
intact) with regression tests in `tests/pool_test.zig` (`\uXXXX`, `\t`,
and raw paths, gated on `regex.enabled`). `zig build fuzz-regex` runs a
differential harness that diffs zq-with-prefilter vs zq-without vs jq
(0 divergences over 1000 iterations).

---

## BUG-004: `capture()` named-group test aborts with StringRef OOB (test-harness UAF, NOT a runtime defect)

**Symptom in test**: `zig build test` — `tests/query_test.zig:2659-2664`
panics with `index out of bounds: index 6, len 2` at `src/types.zig:56
getString`.

**Symptom in CLI**: **None.** Re-verified 2026-04-23:
```
$ echo '"12-34"' | ./zig-out/bin/zq 'capture("(?<a>\\d+)-(?<b>\\d+)") | .a + "|" + .b'
"12|34"
```
Exit 0, correct output, no diagnostics.

**Revised root cause** (sharper than the earlier hypothesis): the panic is a
test-harness use-after-free, not a defect in the capture builtin.

- `runFilterStr` (`tests/query_test.zig:2556-2562`) calls `collectAll`, which
  owns and defers `it.deinit()` before returning — that tears down the
  `RuntimeTape` along with its `string_buf`.
- The returned `vals[]` slice contains `StringRef { offset, len }` entries
  that pointed into the now-freed `string_buf`.
- The test then asserts on `vals[0].string`, which dereferences freed
  memory. Whatever garbage sits at offset 6 produces the OOB.

The CLI works because `src/main.zig` keeps the `RuntimeTape` alive through
serialization. The capture emission path (`buildCaptureObject` at
`src/query/src/vm.zig:8102-8134`) correctly uses `&it.runtime_tape.view`
and calls `internString` before the captures are consumed.

**Fix direction**: change the test harness, not the runtime. Either (a)
have `runFilterStr` materialize string `Value`s into caller-owned memory
before `it.deinit()`, or (b) return a guard struct that keeps the tape
alive until the test frees its result. The capture code does not need to
change.

**Lives in**: `tests/query_test.zig:2659-2664`. Was being miscounted in the
compat-failure bucket; reclassifying it as a test-infrastructure issue
makes the runtime behavior claim accurate.

**Fixed in**: _pending_. Test-only; no user-visible CLI impact.

---

## BUG-005: Pipe in object-field value — parser rejects; leak claim unreproduced

Surfaced during the hermetic-Nix-build rollout (commit `1f57ce1`) while
rebuilding `nix-manual-2.34.6.drv`: mdbook's `anchors` preprocessor shelled
out to the overlayed `zq` with a filter that zq rejected, breaking
`nixos-rebuild switch`.

### Defect 1 — parser gap (confirmed, minimal repro)

Both parsers route object-field values through `parseAlternative()`, which
handles only the `//` operator — not `|`. Any pipe in a field value fails:

```
$ echo '{}' | ./zig-out/bin/zq '{a: 1 | length}'
zq: query syntax error at line 1, col 5
```

Same shape as the observed nix-manual rejection (`content:
.Chapter.content | transformer,`). Verified call sites:

- AST parser — `src/ast/parser.zig:720` (`parseObjectField`) dispatches to
  `parseAlternative`.
- Compile-path parser — `src/query/src/compiler.zig:6841`
  (`parseObjectLiteral`) also dispatches to `parseAlternative` inside
  object value position.

**Fix direction**: call a pipe-aware parser inside object-value position
that still respects `,` as the field separator. Must land in both parsers
so compiled behavior and LSP diagnostics agree.

**Blast radius**: any NixOS configuration that substitutes `jq` → `zq` via
overlay cannot rebuild `nix` itself (nix ships the mdbook-built manual);
also blocks any jq script that pipes inside an object literal without
explicit parenthesization.

### Defect 2 — leak on error path (not reproduced)

The original report included a GPA leak on `QuerySyntaxError` exit
(`memory address 0x7ffff7e60000 leaked` during `nixos-rebuild switch`).

Re-verification 2026-04-23 against a Debug build with a simple bad-token
input (`./zig-out/bin/zq 'invalid @@@ syntax' <<< '{}'`) produced **no
leak**. Code audit of `compile()` (`src/query/src/compiler.zig:1304-1489`)
shows defers covering `ctx.raw`, the function table, pattern allocations,
the intern table, the regex pool, prefilter groups, and the scope chain,
all executing on `parseFilter`'s error return at `:1408`.

The earlier leak may have been path-specific (not triggered by a simple
bad-token case) or fixed incidentally. Do not treat as real until a
specific filter-input pair reproduces it. Suggested repro strategy:
overlay-wrap zq with a shell script that tees stdin + argv into a log
file, run the failing `nixos-rebuild switch`, replay the captured
filter under a Debug build.

**Fixed in**: _pending_. Defect 1 is the ship-blocker; defect 2 stays
parked until reproduced.

---

## BUG-006: Generator in object-value position errors with "type error"

**Symptom**: Any generator yielding more than one value in object-
construction value position raises a runtime `type error` at the position
where the generator emits its second value. jq produces N separate
objects, one per generator yield.

```
$ echo 5 | zq '{a:(1,2,3)}'
zq: type error at line 1, col 10
  {a:(1,2,3)}
           ^
  type error

$ echo 5 | jq '{a:(1,2,3)}'
{"a":1}
{"a":2}
{"a":3}
```

Re-verified 2026-04-23. Same failure for `[1,2,3] | {a:.[]}` and for
generators in any key's value position (`{a:1, b:(1,2)}` fails,
`{a:{b:(1,2,3)}}` fails).

**Single-yield works** (`{a:(1)}` ✓, `{a:(empty)}` ✓). **Generator outside
the object literal works** (`(1,2,3) | {a:.}` ✓, `[(1,2,3) | {a:.}]` ✓).

**Verified root cause**: `backtrackToDepth` (`src/query/src/vm.zig:6464-
6484`) restores `value_stack`, `current`, `ip`, and path state on a
`.normal` forkpoint restore — but does not touch the three
object-construction stacks the VM maintains:

- `it.object_construct` (accumulated `ObjectField` list)
- `it.object_construct_depth` (nested-object depth stack)
- `it.object_construct_input` (per-frame input snapshot)

These are managed by `object_construct_start` / `object_key` /
`object_construct_end` in `src/query/src/vm.zig:1200-1258`. The compiler's
comma-generator emission (`parseComma` at
`src/query/src/compiler.zig:2504`, which emits `.fork` at `:2522`) has no
knowledge that it sits inside an object-construction frame, so the fork
instruction does not teach the VM to snapshot those stacks.

**Fix direction**: either (a) push a dedicated `object_construct_mark` /
`object_construct_rewind` opcode pair around the field-value subexpression
so backtrack rewinds the stacks explicitly; or (b) extend `Forkpoint` with
saved lengths for all three object-construct stacks and have
`backtrackToDepth` restore them when the frame unwinds. Option (b) is
symmetric with the `saved_stack` snapshot approach already in place for
binop left-operand survival (see roadmap Quick Status update 2026-04-23).

**Surfaced during**: contains() fix work (commit `dbd53e2`). Pre-existing
pre-fix failure, NOT a regression of the contains fix.

**Fixed in**: _pending_.
