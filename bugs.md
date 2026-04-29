# zq Bug Findings

A record of non-obvious active bugs. Fixed entries are pruned; check git
history / commit messages for resolved incidents.

Last verified: 2026-04-28.

---

## L798-unmasked bugs (post phase-2R cutover)

These pre-existing failures became visible once `lower.zig` L798's
`expanding_stack` push got gated on `is_recursive` (ec21f78). They are
NOT regressions from phase-2R — they were masked by the prior over-push.

| Tag | Symptom | Repro | Category |
|-----|---------|-------|----------|
| L873 | parser rejects def-after-binding | `def id(x):x; 2000 as $x \| def f(x):...` | Parser |
| L878 | VM TypeError on filter-param binding | `def x(a;b): a as $a \| ...` | VM |
| L884 | parser rejects multi-index before def | `[20,10][1,0] as $x \| def f: ...` | Parser |
| L915 | VM TypeError on reduce with division | `[reduce .[] / .[] as $i ...]` | VM |
| L933 | parser rejects nested destructure pattern | `. as {$a, $b:[$c, $d]}\|...` | Parser |
| L1045 | `unreachable` in `lowerBuiltinCall` — `any/2` builtin missing from `classifyBuiltin` (src/compiler/lower.zig:2169) | `. as $dot \| any($dot[];not)` | Compiler |

Total: 6 distinct test-tag failures (the commit message phrases this as "5 + L1045").
