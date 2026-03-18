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

**Fixed in**: `RawInstr` + `RawOp` (compiler.zig), `Instruction.Operand` (types.zig) — commit after d37a5e7.

**Still present in**: `Tape.Entry` (types.zig:19), `Instruction` (types.zig:583) — low-risk until write paths are stressed.

**Why only release builds**: LLVM's TBAA dead-code elimination only runs at `-O2`/`-O3`. Debug skips it.

**CI fix**: Always run `zig build test -Doptimize=ReleaseSafe` in CI — it keeps safety checks active while enabling the optimizations that expose this class of bug.

---

## BUG-002: Silent test inflation via SkipZigTest

**Symptom**: Test suite reports 500+ passing. After refactor, drops to ~327. Looks like a regression.

**Root cause**: Unimplemented filters returned `error.QuerySyntaxError`, which was caught and converted to `error.SkipZigTest`. Zig's test runner counts skipped tests alongside passes in some output modes. ~228 tests were never executing.

**Rule**: Never use `error.SkipZigTest` for unimplemented features. A test must fail loudly until the feature is implemented. Silently passing unimplemented tests hides regressions.

**Fixed in**: Domain-split test refactor (post-2e8eb29). True denominator: 533 tests, 0 silently skipped.
