# Compat Test Bug Fix Plan

> 111/539 passing (20.6%) — Updated 2026-03-14

Bugs in features already marked [x] in [ROADMAP.md](ROADMAP.md).
Unimplemented features are tracked in the roadmap, not here.

---

## Per-file breakdown

| File | Total | Pass | Fail |
|------|------:|-----:|-----:|
| literals | 20 | 10 | 10 |
| object_construction | 6 | 2 | 4 |
| field_access | 14 | 9 | 5 |
| array_indices | 11 | 6 | 5 |
| iteration | 55 | 10 | 45 |
| variables | 15 | 7 | 8 |
| builtins | 44 | 22 | 22 |
| user_functions | 63 | 1 | 62 |
| paths | 24 | 0 | 24 |
| assignment | 19 | 2 | 17 |
| conditionals | 18 | 10 | 8 |
| comparisons | 13 | 0 | 13 |
| try_catch | 69 | 13 | 56 |
| string_ops | 34 | 0 | 34 |
| datetime | 36 | 8 | 28 |
| numbers | 29 | 7 | 22 |
| unary_negation | 17 | 2 | 15 |
| object_merge | 24 | 2 | 22 |
| regression | 28 | 0 | 28 |

---

## Bug fix steps

Ordered by: foundational first, then by test yield.

---

### Step 1 — Comparisons

**~7 tests** | comparisons.zig

The comparison operators are implemented but have bugs on value ordering
and cross-type comparisons.

Bugs to fix:
- Basic comparison edge cases: 7 tests in comparisons.zig fail

Where to look:
- `src/query/src/vm.zig` — comparison operator implementation

---

### Step 2 — Parser: top-level comma, quoted field access, try/catch expressions

**~20 tests** | across literals, field_access, builtins, conditionals, try_catch, assignment

The compiler fails at "trailing content after parse" (compiler.zig:272) for
expressions that should be valid. The parser finishes too early and leaves
tokens behind.

Bugs to fix:
- Top-level comma: `1,1`, `1,.`, `null,1,null` — parser doesn't handle comma at top level
- Quoted field access: `."foo"."bar"` — parser doesn't handle quoted keys after `.`
- Scientific notation fields: `.e0`, `.E1` — lexer confuses field names with numbers
- Extreme float literals: `9E999999999` — parser chokes on huge exponents
- `try expr` in more positions: `try error(0) // 1`, `1, try error(2), 3`, `try -.? catch .`
- Assignment with comma: `.[] += 2, .[] *= 2, ...` — comma after assignment
- `|=` in more contexts: `.[] |= select(...)`, `.[] |= try tonumber`, `.foo |= .?`
- `//=` operator: `.[] //= .[0]`
- Postfix after `if/end`: `if true then [.] else . end []`

Where to look:
- `src/query/src/compiler.zig` — `compile()`, `parsePipe()`, `parseLogical()`
- `src/query/src/lexer.zig` — field name vs number disambiguation

---

### Step 3 — Generators in control flow & boolean edge cases

**~12 tests** | conditionals (5), iteration (6), field_access (1)

Generators (expressions that produce multiple values) don't propagate correctly
through `if/then/else`, `not`, `and`/`or`, `[..]`, and `?`.

Bugs to fix:
- Generators in `if` condition: `[if 1,null,2 then "a" else "b" end]` (3 tests)
- `[.[] | not]` — `not` doesn't work as a filter in array construction (1 test)
- `.[] | [.[0] and .[1]]` — `and`/`or` as filters in array construction (1 test)
- `[..]` — recursive descent inside array construction (1 test)
- Optional with generators: `(.a,.a)?`, `[.[] | (.a,.a)?]` (3 tests)
- Comma in object value: `{x:(1,2)}` should produce `{"x":1},{"x":2}` (1 test)
- Generator edge cases in iteration: `[(.,1),(2,3)]`, `[([5,5][]),.,.[]]` (2 tests)

Where to look:
- `src/query/src/vm.zig` — generator stack, `if/then/else` execution
- `src/query/src/compiler.zig` — how generators compile in nested contexts

---

### Step 4 — Assignment operators

**~21 tests** | assignment (16), array_indices (5)

Assignment (`=`, `|=`, `+=`, etc.) is implemented but broken in many cases.

Bugs to fix:
- Plain `=`: `.message = "hello"`, `.foo = .bar`, `.a = 999` (5 tests)
- Update `|=`/`+=`: `.[] += 2`, `.foo |= . + 1` edge cases (5 tests)
- `.[] |= select(...)`: filtering with update assignment (2 tests)
- `def x: .[1,2]; x=10` — assignment through user-defined path (2 tests)
- `try` in assignment: `try (.foo = 0) catch .` (2 tests)
- Negative index assignment: `.[-1] = 5`, `.[-2] = 5` (4 tests)
- Huge index error: `try (.[999999999] = 0) catch .` (1 test)

Where to look:
- `src/query/src/vm.zig` — assignment opcodes
- `src/query/src/compiler.zig` — how assignment LHS compiles
