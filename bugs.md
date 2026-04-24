# zq Bug Findings

A record of non-obvious active bugs. Fixed entries are pruned; check git
history / commit messages for resolved incidents.

Last verified: 2026-04-24.

---

## BUG-005 (defect 2): Leak on `QuerySyntaxError` exit path — REFUTED

Surfaced during the hermetic-Nix-build rollout (commit `1f57ce1`) while
rebuilding `nix-manual-2.34.6.drv`: mdbook's `anchors` preprocessor shelled
out to the overlayed `zq` and reported `memory address 0x7ffff7e60000
leaked` on `QuerySyntaxError` exit. Defect 1 (the parser rejection of `|`
inside object-field values) is resolved; this entry tracked only the
leak claim.

**Verification 2026-04-24 — compile-error matrix regression test:**

`tests/compile_leak_matrix.zig` runs a representative filter per distinct
class of compile-time failure through a
`std.heap.GeneralPurposeAllocator(.{ .safety = true })` and asserts
`gpa.deinit() != .leak` after each cycle. The detector is loud: a
deliberate 8-byte leak injected into the harness during development was
surfaced with the exact allocation stack trace and page-aligned address
shape (`0x7f…`) that matches the original report — so the harness would
catch a real regression through any covered path.

Classes covered (all leak-clean under Debug):

- unexpected top-level token / trailing comma (object + array literals)
- missing closers (`{`, `[`, `(`), unterminated string literal
- malformed numeric literal (two dots, dangling exponent, `0x` prefix)
- destructure pattern shape errors (`. as {,}`, `. as 1`)
- function-def syntax (colon in wrong slot)
- `break $x` without enclosing `label $x`
- trailing dot after path head, empty source, bad format directive
- regex-enabled only: invalid literal pattern, rejected flag letter,
  unsupported backreference, regex inside object-field value (the
  BUG-005-d1 successor shape), mid-pipeline regex failure with a prior
  interned entry, regex error inside a function body

Every filter above returns `CompileResult.err` and leaves the GPA
leak-free. The regression test is wired into `zig build test` and runs
on every CI invocation — any future regression through a covered class
fails before merge.

The original `0x7ffff7e60000` leak was likely path-specific to the
pre-BUG-005-d1 parser state and is no longer reachable: the trigger
filter now compiles successfully, and no covered error-path shape
leaks on a modern build.
