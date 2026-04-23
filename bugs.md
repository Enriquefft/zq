# zq Bug Findings

A record of non-obvious bugs and root causes. Check here before debugging similar symptoms.

---

## BUG-001: Silent write elimination in ReleaseFast/ReleaseSafe (extern union + non-extern struct)

**Symptom**: SIGSEGV or wrong opcode in release builds. Debug builds work fine.

**Root cause**: Mixing `extern union` inside a non-`extern struct` gives LLVM two contradictory memory layout stories. LLVM uses the `extern union`'s ABI authority to conclude a write to another field in the same struct is dead code — and deletes it silently.

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

**Rule**: If a struct contains an `extern union`, the struct must also be `extern struct`.

**Fixed in**: `RawInstr` + `RawOp` (compiler.zig), `Instruction.Operand` (types.zig) — commit after d37a5e7. `Tape.Entry` (types.zig:19) and `Instruction` (types.zig:691) are now `extern struct` as well. No remaining occurrences.

**Why only release builds**: LLVM's TBAA dead-code elimination only runs at `-O2`/`-O3`. Debug skips it.

**CI fix**: Always run `zig build test -Doptimize=ReleaseSafe` in CI — it keeps safety checks active while enabling the optimizations that expose this class of bug.

---

## BUG-002: Silent test inflation via SkipZigTest

**Symptom**: Test suite reports 500+ passing. After refactor, drops to ~327. Looks like a regression.

**Root cause**: Unimplemented filters returned `error.QuerySyntaxError`, which was caught and converted to `error.SkipZigTest`. Zig's test runner counts skipped tests alongside passes in some output modes. ~228 tests were never executing.

**Rule**:

1. Never use `error.SkipZigTest` to hide unimplemented features. A test for a missing
   feature must fail loudly — silently passing an unimplemented case hides regressions
   and inflates the passing denominator.
2. `error.SkipZigTest` IS acceptable for build-time feature gates. `-Dregex=false`
   disables the Rust shim at build time; regex-dependent tests legitimately skip in
   that configuration (see the `if (!regex.enabled) return error.SkipZigTest` pattern
   across `src/regex/`, `src/query/src/prefilter.zig`, `tests/pool_test.zig`, etc).
   Gate on the build option, not on "someone will implement it eventually".

**Fixed in**: Domain-split test refactor (post-2e8eb29). True denominator: 533 tests, 0 silently skipped.

---

## BUG-003: Prefilter false negatives on escape-encoded JSON strings

**Symptom**: `select(.k | test("LIT"))` silently drops records whose `k` serializes
`LIT`'s bytes as JSON escapes (`\uXXXX`, short escapes like `\n`/`\t`, or `\"` / `\\`).
Spec-legal JSON records are eliminated before the query ever runs.

**Root cause**: The prefilter performed a raw-byte SIMD scan for required literals
over record bytes. RFC 8259 §7 permits a string like `"foo"` to be serialized as
`"foo"`; the raw scan misses the escape-encoded form. The earlier workaround
(`canPrefilterLiteral` rejecting anything containing `\`, quotes, controls, or
non-ASCII) discarded whole classes of literals instead of handling the escape forms,
so the hole was merely narrowed, not closed.

**Rule**: Any soundness property that depends on source encoding must either (a)
handle every spec-legal encoding or (b) degrade to the general path on evidence that
the encoding might differ. Never ship a raw-byte optimization that silently assumes
one canonical form.

**Fixed in**: commit `8a73a20` — escape-aware fallback. A record is accepted by a
required literal if EITHER its raw bytes appear OR the record contains any `\` byte
(0x5C). Every JSON escape form requires a backslash; if none is present, no
escape-encoded occurrence is possible and the record can soundly be rejected. Every
literal with `len >= 2` is now prefilter-safe (including `"`, `\`, control chars,
non-ASCII UTF-8). Regression tests in `tests/pool_test.zig` cover the `\uXXXX`, `\t`,
and raw paths end-to-end; `zig build fuzz-regex` runs a differential harness that
diffs zq-with-prefilter vs zq-without vs jq (0 divergences over 1000 iterations).
