# Phase 2R Coverage Gap — P21-redux Cutover Blocker

**Status:** BLOCKED. Cutover deferred pending Wave-3-mini.
**Discovered:** 2026-04-27 during P21-redux Step 1 gate measurement.
**Gate measurement:** removing dispatcher fallback at `src/query/root.zig:102-109` fails to compile under `pre-cutover compile-flag new` because `compile-new` still raises `error.NotImpl-pre-cutover` from 12 production sites.

## Inventory

| bucket | site | ast_tag/op | surface | complexity | legacy_ref |
|--------|------|------------|---------|------------|------------|
| identifier-binding | src/compiler/lower.zig:530 | field_access (unknown ident) | `.foo` where foo is not a builtin, udf, or function binding | trivial | legacy@22cd23c compiler.zig:6445-6450 |
| variable-binding | src/compiler/lower.zig:1122 | variable_ref ($__loc__) | `$__loc__` magic variable | moderate | legacy@22cd23c compiler.zig:6460-6480 |
| catch-all-ast | src/compiler/lower.zig:1403 | catch-all (else arm) | any AST kind not explicitly lowered | hard (deferred §3.5 P24-P27) | varies |
| builtin-classifier | src/compiler/lower.zig:1978 | .not_implemented builtin class | builtin calls outside classifyBuiltin arms | hard (deferred §3.5 P24-P27) | varies |
| regex-validation | src/compiler/lower.zig:2025 | regex1 arity check | test/match/capture/scan/splits arg count != 1-2 | trivial | legacy@22cd23c compiler.zig:3059-3147 |
| regex-validation | src/compiler/lower.zig:2054 | regex2 arity check | sub/gsub arg count != 2-3 | trivial | legacy@22cd23c compiler.zig:3742-3864 |
| regex-dynamic | src/compiler/lower.zig:2067 | regex2 comma-replacement | sub/gsub with comma-generating replacement arg | moderate | legacy@22cd23c compiler.zig:3821-3825 |
| regex-dynamic | src/compiler/lower.zig:2192 | dynamic-regex-comma | dynamic pattern arg to regex1 that is itself a comma expr | hard (deferred §3.5 P27) | legacy@22cd23c compiler.zig:3104-3110 |
| format-builtin | src/compiler/emit.zig:567 | format_string (unknown format) | @unknown_fmt or unregistered @fmt variant | hard (deferred §3.5 P26) | legacy@22cd23c compiler.zig:5605-5620 |
| destructure-pattern | src/compiler/emit.zig:721 | alt_bind in destructure | pattern matching with `or` in strict context (nested) | hard | legacy@22cd23c compiler.zig:594-754 |
| pattern-strict | src/compiler/emit.zig:1027 | alt_bind in pattern_strict | alt_bind at object destructure strict recursion (legacy never produces) | hard | legacy@22cd23c compiler.zig:594-754 |
| builtin-dispatch | src/compiler/emit.zig:1819 | nameToBuiltinId fallback | builtin name/arity pair not in nameToBuiltinId table | hard (deferred §3.5 P24-P27) | legacy@22cd23c compiler.zig:6185-6195 |

## Summary

- **12 sites / 9 unique operators / 4+ buckets**
- **Complexity:** 2 trivial | 2 moderate | 6 hard (4 plan-deferred, 2 legacy-never-produces)
- **Verdict:** 5b structured close. ≥7 unique ops, any-hard, plan-deferred all trigger.

## Wave-3-mini scope (next session)

Bucket-level phases proposed:

1. **regex-completion** — lower.zig:{2025, 2054, 2067, 2192} + emit-side dynamic comma-replacement. ≥1 phase.
2. **format-builtin** — emit.zig:567 + @fmt registry. 1 phase.
3. **builtin-dispatch + classifier** — lower.zig:1978 + emit.zig:1819 + nameToBuiltinId table coverage. ≥1 phase.
4. **destructure alt_bind strict** — emit.zig:{721, 1027}. 1 phase. May be unreachable in current AST surface; if so, swap raises for `unreachable` with rationale comment.
5. **identifier + $__loc__** — lower.zig:{530, 1122}. 1 phase (trivial+moderate together).
6. **catch-all collapse** — lower.zig:1403 closed once buckets 1-5 land; verify no remaining AST tags hit it.

Estimate: **5-6 phases** under Wave-3-mini. Re-enter P21-redux Step 1 gate measurement after.

## Re-entry criteria

- `rg "NotImpl-pre-cutover" src/compiler/` returns zero (or only at the dispatcher edge for safety).
- vm-equiv stays 268/0/3 or improves.
- `pre-cutover compile-flag new` test count moves toward legacy baseline 1028/111 (current 1131/15 fallback-active is non-comparable).

## Worktree disposition

Step 1 measurement worktree at `.claude/worktrees/agent-a1a9cce4227ec671d` carries the uncommitted `src/query/root.zig` fallback-removal diff. Discard after this commit lands — no longer load-bearing.
