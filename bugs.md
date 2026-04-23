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

---

## BUG-004: `capture()` with named groups aborts with StringRef OOB

**Symptom**: `capture("(?<a>\\d+)-(?<b>\\d+)") | .a + "|" + .b` on input `"12-34"`
terminates with signal 6 and `index out of bounds: index 6, len 2` at
`src/types.zig:56 getString`. Reproduces on both Linux and macOS.

**Root cause**: Not yet root-caused. The capture object written by the `capture`
builtin contains `StringRef { offset, len }` entries into a string buffer whose
addressable length is 2, but one of the capture slots records an offset of 6 —
a stale pointer into a reallocated or already-freed buffer. Likely the match slot
survives across a `RuntimeTape.internString` call that reallocates the underlying
`string_buf`, invalidating the earlier offset. Confirm by instrumenting the capture
emission path and the tape-grow paths around `+` concatenation.

**Lives in**: `tests/query_test.zig:2659-2664`. Currently counted inside the
"107 pre-existing failures" number but is NOT a compat-gap test — it's a regex
test shipped by this codebase. Separating it out surfaces the real defect count.

**Fixed in**: _pending_. See also `TODO.md` for triage priority once AST-walk
pipeline (Phase 2) lands, since the capture-emission path may move.

---

## BUG-005: Query syntax error on nix-manual mdbook filter (+ leak on error path)

**Symptom**: `sudo nixos-rebuild switch` against a NixOS flake that overlays `jq`
with `zq` fails while rebuilding `nix-manual-2.34.6.drv`. mdbook invokes the
`anchors` preprocessor, which shells out to `jq` (now `zq`). zq rejects the
filter:

```
zq: query syntax error at line 18, col 31
              content: .Chapter.content | transformer,
                              ^
error(gpa): memory address 0x7ffff7e60000 leaked:
Unable to print stack trace: Unable to open debug info: MissingDebugInfo
 WARN Error writing the RenderContext to the backend, Broken pipe (os error 32)
ERROR The "anchors" preprocessor exited unsuccessfully with exit status: 3 status
ninja: build stopped: subcommand failed.
```

**Two defects**:
1. **Compat gap** — the filter (a jq program mdbook's anchors preprocessor
   feeds over stdin) uses a construct zq rejects. The shown context
   `content: .Chapter.content | transformer,` suggests an object-constructor
   value calling a user-defined function `transformer` (likely declared via
   `def transformer: ...;` earlier in the filter). Unconfirmed whether zq's
   parser rejects `def`-call inside an object value, or chokes on something
   else at col 31.
2. **Leak on error path** — zq's syntax-error exit leaks an allocation
   (`0x7ffff7e60000`). Error paths must free before exit; the GPA leak check
   fires because the allocator is not short-circuited on `QuerySyntaxError`.

**Repro strategy**: capture the exact filter by running nix-manual's build
under a strace/ptrace that records argv+stdin to jq, or grep the nixpkgs
source tree for the mdbook `anchors` preprocessor invocation. Minimize to a
single `.jq` file; then `zq -f min.jq < sample.json`.

**Blast radius**: any NixOS configuration that substitutes `jq` → `zq` via
overlay cannot rebuild `nix` itself (because nix ships the mdbook-built
manual). Breaks `nixos-rebuild switch`.

**Fixed in**: _pending_. Triage: (1) first isolate the minimal filter;
(2) classify — parser limitation vs. interpreter limitation; (3) fix the
leak on `QuerySyntaxError` regardless of (1)/(2) progress, since any
syntax error path will leak today.

**Context**: Surfaced during the hermetic-Nix-build rollout
(commit `1f57ce1`). The hermetic flake itself works — `nix build .#default`
is green, the overlay is live, and zq is actually being invoked by nix's
build graph. This is a separate zq compat gap, not a Nix packaging issue.

---

## BUG-006: Generator in object-value position errors with "type error"

**Symptom**: Any generator yielding more than one value in object-construction
value position raises a runtime `type error` at the position where the
generator emits its second value. jq produces N separate objects, one per
generator yield.

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

Same failure mode for `.[]` in value position (`[1,2,3] | {a:.[]}`),
multi-yield user functions, and bare commas (`{a:1,2}` — note jq parses
this as `{a:1, 2:???}` and errors differently, but `{"a":(1,2)}` is the
clean form).

**Single-yield works** (`{a:(1)}` ✓, `{a:(empty)}` ✓ — produces nothing).
**Generator outside the object literal works** (`(1,2,3) | {a:.}` ✓).

**Root cause hypothesis**: `object_key` opcode consumes one value off the
stack, emits one ObjectField, advances `ip`. When the value expression is a
generator, the generator's first yield is consumed cleanly but the
forkpoint backtracks to the generator's "next value" rather than to
`object_construct_start` — so on backtrack, the second yield arrives at
`object_key` with the field-stack already populated from the first
iteration, the `it.current` pointing at a non-input intermediate, or
similar invariant violation that surfaces as `type error`.

The compiler does NOT wrap the entire `object_construct_start … object_construct_end`
range in a save/restore frame keyed for the generator forkpoint. This is
why the parallel pattern `[(1,2,3) | {a:.}]` — where the comma operator
sits OUTSIDE the object literal — works correctly.

**Surfaced during**: contains() fix work (commit `dbd53e2`). Reviewer ran
`5 | {a:(1,2,3)}` as an edge-case probe; pre-existing pre-fix failure, NOT
a regression of the contains fix. Filed as separate bug rather than rolled
into that scope.

**Fix sketch**: emit the object construction sequence inside a forkpoint
frame so generator backtrack restores `object_construct.items.len`,
`object_construct_depth`, `object_construct_input`, and `it.current` to
their `object_construct_start`-time snapshots. Likely lives in
`src/query/src/compiler.zig` around object-literal compilation; the VM
opcodes themselves should not need to know about generators.

**Blast radius**: blocks any jq pattern that builds multiple objects per
input record via in-value generators. Common in transformations that
expand one record into many (logs → events, batch → items). Likely a
contributor to compat-test failures involving `with_entries` /
`from_entries` / object reshaping pipelines.

**Fixed in**: _pending_.
