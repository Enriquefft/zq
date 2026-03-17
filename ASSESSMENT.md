# ZQ Test Assessment — 2026-03-17

## Baseline: 305/533 passing (57.2%), 225 failing, 3 skipped

## Failure Breakdown by Root Cause (225 failing)

| Root Cause | Count | Categories |
|---|---|---|
| Compile/unimplemented (runFilter) | 120 | paths, assignment, object_merge, datetime, string_ops, user_functions, iteration |
| Wrong output (runs but incorrect) | 58 | numbers, builtins, try_catch, literals, datetime, iteration |
| VM crashes (panic/unreachable) | 44 | 18x lookupKeyInValue, 6x error_, 4x doIterate, 4x getVariable, 12x other |
| Other | 3 | 2x expectCompileError, 1x timeout |

## Failures by Test Category (225 total)

| Category | Failing | Breakdown |
|---|---|---|
| try_catch | 29 | 12 wrong output, 7 runFilter, 2 vm:7128, 8 other |
| datetime | 23 | 7 wrong output, 11 runFilter, 3 vm:7128, 2 other |
| regression | 22 | 4 wrong output, 14 runFilter, 4 other |
| paths | 17 | 1 wrong output, 16 runFilter |
| numbers | 17 | 13 runFilter, 3 vm:7128, 1 wrong output |
| iteration | 17 | 3 wrong output, 11 runFilter, 1 vm:7128, 2 other |
| builtins | 17 | 11 wrong output, 3 runFilter, 2 vm:7128, 1 other |
| object_merge | 16 | 1 wrong output, 8 runFilter, 7 other |
| assignment | 15 | 2 wrong output, 10 runFilter, 3 other |
| string_ops | 13 | 2 wrong output, 8 runFilter, 3 vm:7128 |
| user_functions | 11 | 5 wrong output, 2 runFilter, 4 other |
| unary_negation | 8 | 3 wrong output, 4 vm:7128, 1 runFilter |
| literals | 5 | 3 wrong output, 1 parser, 1 runFilter |
| array_indices | 5 | 1 wrong output, 4 runFilter |
| object_construction | 4 | 0 wrong output, 2 runFilter, 2 expectCompileError |
| conditionals | 3 | 2 wrong output, 1 runFilter |
| variables | 2 | 0 wrong output, 1 vm:456, 1 runFilter |
| field_access | 1 | 1 wrong output |

## VM Crash Sites

| Location | Count | Issue |
|---|---|---|
| vm.zig:7128 lookupKeyInValue | 18 | TypeError on non-object with allow_null=false |
| vm.zig:2391 error_ builtin | 6 | UserError not caught (try/catch propagation) |
| vm.zig:5258 doIterate | 4 | TypeError on non-iterable values |
| vm.zig:438/456 getVariable | 4 | Variable index out of bounds |
| vm.zig:856/838 | 4 | Unknown — needs investigation |
| vm.zig:2306 | 2 | Unknown — needs investigation |
| vm.zig:6473/5748/3074/2702/2140/1698/1671 | 7 | 1 each — scattered |
