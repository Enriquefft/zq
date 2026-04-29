# zq Compiler Baselines — Legacy (Phase 2R / R2)

> **Phase 2R Cluster A — Phase 3 (R2)**. Captured against the legacy
> compile path before the new VM-semantics compiler exists. These numbers
> are the floor R3 must hold or improve.

## Build context
- Commit: `c9d4a696221854a66dae6c9dd0e85bc0561fd315` (Phase 2R Cluster A tip)
- Branch: `redesign/compiler`
- Build profile: `ReleaseFast`
- Zig version: `0.15.2`
- Date captured: 2026-04-25

## Method
- Driver: `src/compiler/bench.zig` (run via `zig build bench-compile`).
- Per filter: 50 warm-up iterations + 1000 measured iterations.
- Compile path measured: `query_mod.CompiledQuery.compile(...)`. AST parse
  and bytecode emit are both included; runtime VM execution is excluded.
- Fresh-process aggregation: 3 invocations of `zig build bench-compile`.
  Per-filter `median_ns_agg = median(run_medians)`, `p99_ns_agg =
  max(run_p99s)`, `sigma_ns_agg = max(run_sigmas)`.

## Filter corpus (17 entries)
| name | filter |
|------|--------|
| f.field | `.foo` |
| f.nested | `.foo.bar` |
| f.pipe | `.foo \| .bar` |
| f.index | `.[0]` |
| f.arith | `1+1` |
| f.array_ctor | `[.foo, .bar, .baz]` |
| f.obj_ctor | `{a: .foo, b: .bar}` |
| f.select | `select(.id > 100)` |
| f.map_add | `map(.id) \| add` |
| f.if_else | `if .x then .y else .z end` |
| udf.simple | `def f: . + 1; f` |
| udf.semicolon | `def f(a;b): a + b; f(.x;.y)` |
| udf.higher | `def is_even: . % 2 == 0; .[] \| select(is_even)` |
| regex.literal | `test("^[a-z]+$")` |
| regex.dynamic | `match(.pattern)` |
| f.reduce | `reduce range(10) as $i (0; . + $i)` |
| f.deep_pipe | `.a \| .b \| .c \| .d, .e, .f, .g` |

## Per-filter timings (legacy)
| name | median µs | p99 µs | σ µs |
|------|----------:|-------:|-----:|
| f.field | 6.20 | 18.09 | 22.67 |
| f.nested | 6.38 | 14.01 | 4.66 |
| f.pipe | 9.74 | 17.26 | 11.94 |
| f.index | 9.07 | 20.16 | 10.16 |
| f.arith | 8.93 | 18.31 | 13.91 |
| f.array_ctor | 11.42 | 23.95 | 29.46 |
| f.obj_ctor | 11.52 | 27.70 | 21.30 |
| f.select | 10.68 | 22.66 | 23.47 |
| f.map_add | 11.51 | 20.05 | 11.60 |
| f.if_else | 13.19 | 21.29 | 23.68 |
| udf.simple | 12.03 | 19.86 | 19.20 |
| udf.semicolon | 15.97 | 21.70 | 2.38 |
| udf.higher | 17.30 | 39.27 | 13.15 |
| regex.literal | 18.72 | 34.16 | 15.20 |
| regex.dynamic | 10.81 | 22.06 | 12.98 |
| f.reduce | 14.99 | 38.37 | 24.34 |
| f.deep_pipe | 12.66 | 22.26 | 13.98 |

## Memory and binary
- Peak RSS during bench run: 51.2 MB (max across 3 runs; runs 2–3 were 51.0 MB)
- Binary size (`zq` main, ReleaseFast): 9,039,049 (text) + 404,960 (data) + 6,456 (bss) = 9,450,465 bytes (~9.0 MB)
- Bench harness is executed inline; no separate bench binary artifact is persisted.

## Test baseline (post-R1)
- `zig build test` aggregate at HEAD: 1023 passed / 27 skipped / 111 failed (out of 1161 total)
- 111 failures are pre-existing jq-compat semantic divergence in the legacy
  compiler. R3 must not regress this number.

## Source pin
- Upstream jq compat fixtures: `../jq/tests/jq.test` (path on dev machine; not vendored). Hash pin deferred to R3 when vm-equiv harness lands.

## Reproduction
```bash
cd /home/hybridz/Projects/zq
zig build bench-compile
# repeat 3×, aggregating outputs
```

## Notes
- Run 1 did not capture RSS from `/usr/bin/time -v` (log truncated); runs 2–3 both succeeded.
- Variance is elevated on some filters (σ up to 29.46 µs for `f.array_ctor`, 24.34 for `f.reduce`), likely due to system scheduling jitter and allocator behavior across iterations. The harness uses per-iteration ArenaAllocator reset to bound memory, which may introduce modest variability.
- Smallest filters (`f.field`, `f.nested`) show <7 µs median; largest (`regex.literal`, `udf.higher`) exceed 17 µs. This aligns with expected AST size and complexity.
- Test count at post-R1 HEAD: 1023 passed / 27 skipped / 111 failed; detailed regression analysis deferred to R3 once vm-equiv harness is complete.
