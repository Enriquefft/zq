# Compat Test Coverage

> 111/539 passing (20.6%) — Updated 2026-03-14

See [ROADMAP.md](ROADMAP.md) for feature priorities and implementation status.

---

## Per-file breakdown

| File | Total | Pass | Fail | Primary blockers |
|------|------:|-----:|-----:|------------------|
| literals | 20 | 10 | 10 | `@format` strings (6), `tojson`/`fromjson` (1), string interpolation bug (1), `abs` (1), BOM (1) |
| object_construction | 6 | 2 | 4 | Shorthand+computed key bugs (2), string interp in key (1), error test (1) |
| field_access | 14 | 9 | 5 | `[..]` bug (1), `."foo"."bar"` syntax (1), `.e0`/`.E1` lexer (1), `map(try .a[] catch .)` (1), `try [...]` (1) |
| array_indices | 11 | 6 | 5 | Assignment with negative index (4), huge index error (1) |
| iteration | 55 | 10 | 45 | `foreach` (7), `while`/`until` (2), `label`/`break` (2), `limit`/`skip`/`nth` (10), `reduce` (1), comma/generator bugs (6), slice assignment (5), `range` multi-arg (4), `first`/`last` (3), `flatten` depth (1), `del` (1), `join` (2) |
| variables | 15 | 7 | 8 | Destructuring patterns (5), keyword identifiers (2), scoping edge case (1) |
| builtins | 44 | 22 | 22 | `empty` (1), `add()` args (3), `map_values` (1), `utf8bytelength` (2), `toboolean` (3), `tonumber` (1), extreme floats (3), `nan`/`infinite` modulo (2), string `contains` (1), `array+array` (2), keyword obj (1), `sort`/`group_by` (1) |
| user_functions | 63 | 1 | 62 | `def` bugs (18), `reduce` (8), `?//` destructuring (17), `any`/`all` 2-arg (12), math builtins (5), variance (1) |
| paths | 24 | 0 | 24 | `path`/`getpath`/`setpath`/`delpaths` (14), `pick` (4), `del` edge cases (3), `[paths]` (1), `del(.[nan])` (2) |
| assignment | 19 | 2 | 17 | Plain `=` (5), `\|=`/`+=` (5), `def x: ...; x=10` (2), `.[] \|= select(...)` (2), `try` (2), `getpath \|=` (1) |
| conditionals | 18 | 10 | 8 | Generators in `if` (3), `[.[] \| not]` (1), `.[] \| [and, or]` (1), `//=` (1), `[.[] \| [.foo[] // .bar]]` (1) |
| comparisons | 13 | 0 | 13 | Basic comparison bugs (7), `contains` on strings (6) |
| try_catch | 69 | 13 | 56 | String builtins (24), string `*`/`/` (9), `contains` deep (5), `sort_by`/`min`/`max` (3), `to_entries`/`from_entries`/`with_entries` (3), `try`/`catch` edge cases (8) |
| string_ops | 34 | 0 | 34 | Type selectors (7), `bsearch` (3), `transpose` (2), `flatten` (5), `ascii_upcase` (1), date/time (10), object deep merge (5) |
| datetime | 36 | 8 | 28 | Module system (12), `join` (5), div/mod errors (5), keyword obj (1), unary/string edge cases (3), date/time (1) |
| numbers | 29 | 7 | 22 | `INDEX`/`IN`/`JOIN` (7), `isempty` (3), `builtins` (4), `have_decnum` (2), `tojson` (1), math (2), assignment+`..` (2) |
| unary_negation | 17 | 2 | 15 | `abs`/`fabs` (5), `reduce` (1), `foreach` (1), `label`/`break` (1), `tojson`/`have_decnum` (3), keyword vars (1) |
| object_merge | 24 | 2 | 22 | `try`/`catch` chains (6), `tojson`/`fromjson` (3), `explode`/`implode` (3), `walk` (2), `input`/`debug` (2), `$__loc__` (1), `?//` (1) |
| regression | 28 | 0 | 28 | Float index (10), `reduce`+`tojson` (3), `walk` (2), `ltrimstr`/`rtrimstr` (4), `foreach` (1), `nan` in slicing (4) |

---

## Feature impact on compat tests

How many compat tests each roadmap feature unblocks.

### P0+P1 bugs (implemented — ~98 tests blocked by bugs)

Fixing these alone would bring pass rate from 20.6% to ~39%.

| Feature | Failing | Key bugs |
|---------|--------:|----------|
| Core builtins (tier 2) | ~57 | `any`/`all` 2-arg (17), `limit`/`first`/`last` (10), string `contains` (6), `flatten` depth (6), `del` (3) |
| Assignment | 17 | plain `=`, `\|=`/`+=`, `.[] \|= select(...)` |
| Arithmetic | ~15 | string `*`/`/` ops, div/mod error format, extreme float handling |
| Comparisons | 13 | 7 basic comparison bugs, 6 `contains` on strings |
| Boolean/Conditionals | ~8 | generators in `if` branches, `[.[] \| not]` |
| Core builtins (tier 1) | ~8 | `empty` in arrays, `add()` args, `range` multi-arg |
| Variables | 8 | destructuring (`as [$a,$b]`, `as {$a, b:[$c]}`), keyword identifiers |
| Try/catch | ~8 | nested chains, `try -.?`, `try error(0) // 1` |
| Slicing | 7 | slice assignment, negative edge cases, float index |
| Comma operator | ~6 | `1,.`, `1,1`, `{x:(1,2)}` |
| Negative indexing | 5 | assignment with negative index |
| Object construction | 4 | shorthand+computed key, string interp in key |
| Optional operator | 3 | `(.a,.a)?`, `[try [...]?]` edge cases |
| String interpolation | 1 | `"inter\("pol" + "ation")"` |
| Recursive descent | 1 | `[..]` inside array construction |
| Alternative operator | 1 | `.[] //= .[0]` |

### P2 features (not implemented)

| Feature | Tests unlocked |
|---------|---------------:|
| `path`/`getpath`/`setpath`/`delpaths` | ~25 |
| `def` (bugs in existing impl) | ~18 |
| `reduce` | ~16 |
| `label`/`break` (+ proper `limit`/`first`/`last`) | ~14 |
| `foreach` | ~10 |
| `@format` strings | ~7 |
| `while`/`until` | ~4 |

### v0.5 builtins (not implemented)

| Category | Tests unlocked |
|----------|---------------:|
| String builtins | ~48 |
| Math builtins | ~14 |
| Date/time | ~14 |
| Array builtins | ~12 |
| Misc (`isempty`, `utf8bytelength`, etc.) | ~12 |
| SQL-style (`INDEX`/`IN`/`JOIN`) | ~7 |
| Type selectors | ~7 |
| Object builtins | ~5 |
| Env/introspection | ~5 |
| I/O | ~2 |

### Module system (not implemented)

| Feature | Tests unlocked |
|---------|---------------:|
| `import` | 7 |
| `include` | 3 |
| `modulemeta` | 2 |
