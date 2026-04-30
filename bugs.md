# zq Bug Findings

A record of non-obvious active bugs. Fixed entries are pruned; check git
history / commit messages for resolved incidents.

Last verified: 2026-04-30 (post error-format/VM/parser orchestration wave — closed L1802 L2084 L2088 L2096 L2107 L2112 L2116 L2130 L2134 L2138; deleted dead `toFloat` + `builtinIsempty`).

---

## Active compat failures

Current baseline: `zig build test` → 1134/1177 pass, 23 fail, 20 skipped. Net pass count dropped from 1144 because the L2080→L2084→L2088→L2130 abort-slot chain unmasks downstream latent failures with each fix. Next abort slot (signal 6) is L2332 `debug` builtin; its abort masks any further downstream tests.

### Imports / modulemeta (G11 — out of scope this wave)

| Tag | Symptom | Category |
|-----|---------|----------|
| L1891 / L1895 / L1899 / L1903 / L1908 / L1912 / L1916 / L1920 / L1984 | `import "x" as foo` / `include "x"` syntax errors | parser/imports — module import & include not implemented |
| L1960 / L1964 / L1968 | `modulemeta` lookupKeyInValue abort | builtin — `modulemeta` not implemented (segfault on lookup) |

### In-domain unmasked (next wave candidates)

| Tag | Symptom | Repro | Category | Hypothesis |
|-----|---------|-------|----------|-----------|
| L2121 | `(.a as $x \| .b) = _b_` output mismatch | path-LHS update with as-binding | path/assign | `as`-binding inside path expression — assign rewrites need to honor binding scope; LHS path-walk likely loses binding frame across `=` rewrite. |
| L2126 | `(.. \| select(type == _object_ and has(_b_) and (.b \| type ...)))` | recursive descent + `has` | builtin/recursion | `has/1` over a stream from `..` — likely missing recursive-descent binding or `has` arity-1 dispatch over array/object distinction. |
| L2195 | `(13911860366432393 == 13911860366432392) \| . == if have_decnum then ... else ... end` | i64 equality near precision boundary | numeric | gated on decnum support (jq decimal numbers feature flag). Skip until decnum domain opened. |
| L2299 | `1 as $x \| _2_ as $y \| _3_ as $z \| { $x, as, $y: 4, ($z): ... }` | object literal with `as`-keyed shorthand | parser/object_ctor | `$y` shorthand inside object literal rewriting key from `2` to `as` — object-shorthand key lookup uses raw string of bind name instead of bound value's source key. |
| L2306 | `fromjson \| isnan` | parsing literal `NaN` | builtin/parser | `fromjson` `parseJsonToStackValue` rejects `NaN` literal (`writeLiteral` only accepts `null`/`true`/`false`); jq accepts `NaN`/`Infinity`. Add NaN/Infinity branches to writeLiteral or pre-parser. |
| L2310 | `tojson \| fromjson` round-trip | feed parser rejects `NaN` | parser/keyword | parser's `in_keyword` state aborts on `NaN`/`Infinity` tokens — symmetric defect to L2306 in the input-side parser. |
| L2315 | `.[] \| try (fromjson \| isnan) catch .` | try/catch wraps NaN-parse error | error-class | `fromjson` raises bare `TypeError` instead of catchable jq-shaped error string when feeding `NaN`; once L2306 fixed, this likely passes. |
| L2328 | `try input catch .` | empty input stream | builtin | `input/0` returns 0 rows where jq returns 1 (`error("No more inputs")`); needs `input` builtin to raise catchable end-of-stream. |
| L2332 | `debug` builtin signal-6 abort | `debug` | builtin (next abort slot) | `debug/0` not implemented — VM dispatch likely panics with `.not_implemented => unreachable`. Masks any further downstream tests in the suite. |

### Decnum domain (gated on `have_decnum` flag)

| Tag | Symptom |
|-----|---------|
| L2223 | `[1E+1000,-1E+1000 \| tojson] == if have_decnum then ...` |
| L2262 | `[1E+1000,-1E+1000 \| abs \| tojson] \| unique == if have_decnum then ...` |
| L2266 | `[1E+1000,-1E+1000 \| length \| tojson] \| unique == if have_decnum then ...` |

All three guard on `have_decnum` for the precise-decimal branch. Park until decnum support is decided.

### Fixed in error-format/VM/parser wave (10)

Merged 2026-04-30:
- L1802 (commit 6e9898e): `try flatten(-1) catch .` — `flatten/1` now raises UserError matching jq prelude `"flatten depth must not be negative"` shape.
- L2084 + JOIN/3 + JOIN/4 (commit f1f7a5c): `JOIN/2/3/4` now desugar at AST level via shared `buildJoinPair` helper to jq prelude form `def JOIN($idx; idx_expr): [.[] | [., $idx[idx_expr]]];`.
- L2088 + L2096 + L2107 + L2112 + L2116 (commit ff25f25): `IN/1` and `IN/2` desugar to `any(. == s; .)` / `any($source; . == s)` respectively at AST level. Operand swap on /1 avoids pre-existing VM generator-on-LHS reseed asymmetry; commutativity-correct.
- L2130 + L2134 + L2138 (commit 9d699db): `isempty/1` desugar to `first((f|false), true)` AST; deleted dead `builtinIsempty` VM stub (14 lines).
- Dead-code removal (commit 3294f28): deleted `toFloat(val: StackValue) ZqError!f64` from `vm/root.zig` after R-impl correctly identified that `bool→1.0/0.0` branch differed from `else=>TypeError` semantics at every of 47 call sites. `@floatFromInt` is the actual SSOT; `toFloat` was a wrong wrapper.

### Fixed in G7/G8/G9/G10/G12 orchestration wave (14)

Merged 2026-04-30: L2037 L2041 L2045 L2049 L2053 (G7 div/mod-by-zero error format), L1988 L1992 L1996 (G8 binary-arith error format + UTF-8 truncation), L1736 (G9 suffix-form computed-slice base reseed), L1886 (G9 multiplication overflow + binop outer-input reseed), L2005 (G9 oversized integer literal coerce + add variant), L1838 (G12 strftime fixture generator regex fix), L2062 (G10 leading-dot float lexer + computed_index in subtreeHasIterate), L2080 (G10 INDEX/1 INDEX/2 AST desugar).

Baseline: 1131 → 1144 pass (+13). Subsequent error-format/VM/parser wave unmasks → 1134 honest pass.

### Fixed in pre-existing-fixes wave (3)

Merged 2026-04-30: L1481 unary-minus error format, L1692 computed-index outer-input reseed, L1696 string fixture correction.

- L1481: `try -.? catch .` — VM unary-minus error path now formats the operand with jq's `"<type> (<value>) cannot be negated"` shape instead of bare `"TypeError"`.
- L1692: `.foo[.baz]` computed-index now reseeds outer input for key eval — restructured `computed_index` IR node to binary `[base, key]` shape; emit captures outer input pre-base, restores it pre-key; new `mark_computed_key` opcode suppresses path-component pollution during inner key eval inside `path(f)` / path-assign frames.
- L1696: Test fixture corrected to match jq's actual output for `.[] | .error = "no, it's OK"` — no parser bug; the prior fixture string was wrong.

### Fixed in builtin-fixes wave (4)

Merged 2026-04-30: L1592 rindex, L1668 sort_by stability, L1684 min_by/max_by tie-breaking, L1712 with_entries.

- L1592: Computed slice bounds support (`parser` + `AST` + `IR` + `emit` + `VM` — `.[:rindex("x")]` now works; also fixed UTF-8 codepoint indexing in doSlice)
- L1668: Sort multi-output key grouping in emit (array_collect wrapping for by-key family ensures 1:1 element-to-key pairing)
- L1684: max_by tie-break from `== .gt` to `!= .lt` (jq asymmetry: min_by first-wins, max_by last-wins; min_by already correct)
- L1712: with_entries desugar in lower (AST synthesis to `to_entries | map(f) | from_entries`; no new VM opcode)

### Fixed in G6 round (commits 5d8888b, 2b1fb80, 53f2a67, 0e020c6)

- L1421 (`contains/inside` arity-1 builtins added to lower + emit dispatch)
- L1322 (`if-cond` reseed via variable instead of save/restore_input across fork-points)
- L878 (factored `emitInputScopeBracket`/`emitInputScopeReseed` helpers in emit.zig; applied at filter-arg call sites)
- L1127 / L1131 / L1135 (PathFrame extended with `break_kind` + `break_source` enum, populated at upstream-value descent ops, dispatched per-kind by `raisePathExprError`)
- L1139 (path_end nested-path heuristic refined: terminal-output taints outer with `break_kind=.generic`, computed-key consumer pops + skips component append; outer-frame pop in terminal-else added in 0e020c6)
- L1290 / L1294 (clearsPathBroken refined to consult `break_origin` enum — only clears when same-step-scratch, preserves when upstream-value)
- L1258 (`getpath` marked path-emitting; `builtinGetpath` populates frame components for autovivify in `getpath(P) |= V`)
- L1302 (parser dispatches lparen body to parseFilter so leading `def` is accepted before assignment)
- L1306 (parser accepts `Infinity`, `-Infinity`, `NaN`, `-NaN` JSON literals)

### Fixed in G5 round

L200 (each iter detail), L353 (.arith lhs-temp), L401 (emitFirst empty-stream), L478 (setpath slice arm), L725 (emitAsBind save/restore), L775 (.obj_ctor computed-key save_input), L915 (.arith reduce), L1173 (delpaths msg), L1201 (pick desugar).

### Fixed in G4 round

L48, L122, L661, L674, L1045.

### Bug residuals from prior orchestration

| Tag | Status |
|-----|--------|
| L873 | Parser: def-after-binding — fixed in a370bcd / merge 99580b9. Confirmed PASS. |
| L884 | Parser: multi-index before def — fixed in a370bcd. Confirmed PASS. |
| L933 | Parser: nested destructure — fixed in a370bcd. Confirmed PASS. |

---

## Architectural follow-ups (not in current scope)

### `first(...) // fallback` VM bug

`limit_start` exits via `ip = instructions.len`, leaving `fork_alt` frames on the fork stack. G4's `lowerAnyAllDesugar` and G5's `lowerPickDesugar` both work around this by using array-wrap (`[first(...)]`) instead of jq's literal `first(...) // fallback` desugar form. Worth fixing the underlying VM behavior to allow direct `first(...) // fallback` use.

### Bug residuals from prior orchestration (not in current scope)

| Tag | Status |
|-----|--------|
| L873 | Parser: def-after-binding — fixed in a370bcd / merge 99580b9. Confirmed PASS. |
| L884 | Parser: multi-index before def — fixed in a370bcd. Confirmed PASS. |
| L933 | Parser: nested destructure — fixed in a370bcd. Confirmed PASS. |

---

## Infinite generators: zero-output via pool streaming (HIGH)

| Field | Value |
|-------|-------|
| Symptom | Bare infinite generator filters (e.g. `repeat(.+1)`, `range(1; 1_000_000_000)`) emit zero bytes to stdout/file/pipe. |
| Repro | `echo 0 \| zq 'repeat(.+1)'` — hangs with no output (kill before OOM). Same with `zq 'range(1; 1_000_000_000)'`. |
| Root cause | `src/pool/root.zig:822-836` (`process_line_serialized`) buffers an entire chunk's serialized output into `chunk_buf` **before** publishing to the sequencer. An infinite-generator iterator never returns null → chunk never publishes → no bytes ever flush. |
| Affects | Any filter that produces an unbounded result stream without an enclosing `limit/skip/first/last` short-circuit. |
| Not affected | Bounded generators (`limit(N; repeat(.+1))`, `range(1; 100)`, finite filters) — all flush correctly. |
| Severity | HIGH (correctness, but only on infinite filters which are themselves rare in agent workloads). |
| Fix sketch | Stream output from `process_line_serialized` incrementally — flush partial `chunk_buf` to sequencer at a configurable byte/record threshold, rather than waiting for iterator exhaustion. |
| Discovered | 2026-04-29, during `repeat(f)` builtin review. |

---

## repeat(f) follow-ups (LOW/MEDIUM)

Cleanup items from the post-merge review of `feat/repeat-builtin` (3a4a350). Implementation is semantically correct vs jq 1.8.1 and passes 10 compat tests with zero leaks under 1M-iteration stress. These are latent quality issues, not active failures.

| Severity | Location | Issue | Fix |
|----------|----------|-------|-----|
| MEDIUM | `src/vm/root.zig:6956-6967` | `.repeat` backtrack arm has `if (fp.saved_stack)` and `if (fp.saved_object)` branches, but `.repeat_start` (1792-1802) never populates either field. Dead code. | Drop both branches — fall through to `value_stack.items.len = fp.saved_value_stack_len`. Iteration semantics don't need stack/object snapshots. |
| LOW | `src/vm/root.zig:137-141` | `RepeatState` lacks `saved_call_len`. try_handler/alt_handler/label all carry it. Repeat re-enters body each iteration; a body with `label $L \| ...break $L` inside a partially-popped recursive def could leave call_stack unbalanced across iterations. No reproducer found. | Add `saved_call_len: u32` to `RepeatState`; capture at `.repeat_start` push, restore in backtrack arm. |
| LOW | `tests/compat/repeat_builtin.zig` | Coverage gaps: `try/catch` mid-body assertion, `label/break` interaction, `reduce limit(N; repeat(.+1)) as $x (init; ...)`, `[limit(0; repeat(.))]`, `path(repeat(...))`, 1M-iteration stress. | Add cases. The label/break case would surface the LOW-severity row above. |
| NIT | `src/vm/root.zig:1786-1789` | Comment "backtrack_ip is unused" is technically true but `backtrack_ip = exit_ip` is set "for diagnostic symmetry". Confusing for readers modeling fork-frame transitions. | Either set `backtrack_ip = body_start_ip` (encodes actual re-entry target) or add explicit `// unused; symmetry only` marker. |
| NIT | `src/compiler/emit.zig:2264-2278` | `emitRepeat` and `emitLimitSkipNth` share scaffolding (`<op_start exit_ip> <body> yield_output backtrack <op_end>`). | Factor into `emitStreamingFrame(start_op, end_op, body_idx)` for the next streaming-generator builtin. |

Discovered: 2026-04-29.
