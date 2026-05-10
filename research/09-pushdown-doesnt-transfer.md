# Predicate Pushdown Doesn't Transfer to zq

**Status:** evaluated, rejected (2026-05-09)
**Revert:** `main` commit `af78b17` (reverts `04c6fbf` + `440ebf2`)

---

## What pushdown is in the literature

Sparser (VLDB 2018), Mison (SIGMOD 2017), and dsJSON (SIGMOD 2023) all
push selective predicates and projection down into the parsing stage.
The pattern works because their per-record cost split is asymmetric:
post-parse evaluation in a query engine (`V`) is much more expensive
than parser-side predicate evaluation (`E`), because the parser is the
bottleneck on raw JSON and the query engine is interpreted. Sparser
pre-filters with SIMD substring search before the parser ever runs.
Mison uses a structural index to skip fields the query doesn't read.
dsJSON broadcasts a projection tree to every parser worker and
short-circuits on predicate failure during materialization. Across all
three the speedup compounds with `(V − E)·N`: the larger the gap, the
bigger the win.

## What we tried in zq

Two commits on `main` (both reverted):

1. **`440ebf2` — query-aware projection plan + pure-predicate pushdown.**
   Compile-time `ProjectionPlan` harvester walked the post-fuse IR DAG,
   recognized `select(<pure-path> CMP <literal>)` and `select(has(K))`
   shapes, lifted them into a flat plan structure, and threaded the
   plan through `CompiledQuery → Pool → Parser`. The parser routed
   plan-aware records through a new `feedPlanned` entry point that
   evaluated the predicate against the just-finalized tape window at
   top-of-record and returned `FeedResult.dropped` for failing records,
   so the VM never saw them.

2. **`04c6fbf` — strip select root + wide-record attribution.** Mutated
   the IR in place to replace `select(...)` with `Op.identity` whenever
   `harvestPredicate` accepted the body, so kept records flowed through
   `push_current` instead of re-evaluating the predicate they had
   already passed at the parser boundary. Added a wide-record
   attribution scenario (`08_selective_wide.sh`) on a generator
   producing ~1KB-per-line, ~50-field records.

Attribution was done by building a sibling `-Dno-plan=true` binary
where `harvestProjectionPlan` and `harvestPredicate` returned `null`
unconditionally. Hyperfine ran the default and no-plan binaries
interleaved on the same workload, isolating the pushdown delta from
parse/VM noise.

## The data

Post-fix CI run, 1M-line CI dataset (regression mode), ~25%
selectivity:

| Scenario | Workload | zq-default | zq-noplan | jq | Pushdown vs no-plan |
|----------|----------|-----------:|----------:|---:|---------------------|
| 7 narrow | `select(.id > N) \| .id`, ~83B/record, 250k pass | 366.1 ± 2.4 ms | 358.3 ± 2.2 ms | 2140 ms | 0.98× (Δ +7.8 ms / +2.18% slower, 2.4σ) |
| 8 wide   | `select(.id > N)`, ~1KB/record, ~50 fields, ~80k pass | 279.1 ± 1.4 ms | 287.1 ± 1.3 ms | 2277 ms | 1.03× (Δ −8.0 ms / −2.79% faster, 4σ) |

Pre-strip (`440ebf2` only) the narrow penalty was +12 ms / +3.4% / 5σ —
the strip transform cut it 35% by removing the double-eval on kept
records, but did not eliminate it.

Cost-model derivation. Per-record delta from pushdown is `(E − V_p)`
where `E` is the parser-side predicate eval cost and `V_p` is the VM
trip the pushdown skips. Across `N` records the total delta is
`(E − V_p)·N`:

- Narrow: `+7.8 ms / 250k records ≈ +31 ns/record`. So `E` exceeds `V_p`
  by ~31 ns/record. The parser-side eval (tape walk + cmp) is more
  expensive than the VM trip it replaces.
- Wide: `−8.0 ms / ~80k records ≈ −100 ns/record`. So `V_p` exceeds `E`
  by ~100 ns/record. The VM trip on a 50-field record is enough longer
  than the parser-side eval to flip the sign.

## The structural finding

In zq, parse and VM are **both SIMD-accelerated**. The parser is a
streaming state machine with AVX2/NEON structural-character
classification (64 bytes at a time). The VM is bytecode-dispatched on a
fused IR that collapses `.a.b.c` chains into single `load_path` ops
walking a flat tape. There is no slow interpreter waiting downstream of
a fast parser. `V ≈ E`.

Sparser, Mison, and dsJSON all assume `V ≫ E`. In their target
architectures the parser is dramatically faster than the query engine;
moving work upstream is a free lunch because every byte the parser
short-circuits saves a VM trip that costs orders of magnitude more.
**The precondition for pushdown to be a uniform win is the parse-VM
asymmetry, and zq doesn't have it.**

What we observe instead is workload-regime: pushdown wins where the VM
trip dominates (wide records, scenario 8) and loses where parse cost
dominates (narrow records, scenario 7). The crossover is at the per-
record cost where `E = V_p`. CLAUDE.md disqualifies workload-regime
trades — "wins on workload X, loses on Y" is exactly the shape we
reject. Wide records would justify pushdown; narrow records would not.
zq cannot ship one path.

## What would change the verdict

- **Path C (latch-during-parse).** Drop `E` further by piggybacking
  predicate evaluation onto the byte-level parse — every structural
  character classification already touches the bytes; record the value
  for the predicate's terminal field as a side effect, evaluate when
  the record closes. This is bounded by the same SIMD ceiling parse
  already hits: if `E` is dominated by tape-walk traversal, latching
  during parse cuts the traversal but not the comparison, and the
  comparison is what costs ~31 ns/record on narrow workloads. Unlikely
  to flip narrow records into the win column.

- **VM architecture change that raises `V`.** If zq abandoned bytecode
  for a tree-walking interpreter or a tagged-union dispatch loop, `V`
  would balloon back up and the asymmetry the literature exploits
  would reappear. Not on the roadmap; the bytecode path is
  load-bearing for every other workload.

The verdict is structural, not implementation. Documented as research,
not as a roadmap item.

## What survives

- **Scenarios 6/7/8 as workload-coverage benchmarks.** Simplified to
  single-binary zq vs jq, standard 15% threshold. They cover three
  selective-filter regimes (narrow no-plan, narrow selective, wide
  selective) and catch regressions on each independently.

- **The cost-model framing.** Future selective-filter optimizations
  should be evaluated through the lens of `(E − V_p)·N`. Any
  optimization that promises a win across all selectivity regimes
  needs to either drop `E` to zero (the parse already touches every
  byte — bounded by SIMD throughput) or raise `V_p` (architectural,
  not local).

## Relationship to prior research entries

- `research/01-mison.md` and `research/02-sparser.md` — the literature
  this work tried to import. Both presuppose `V ≫ E` (slow query
  engines downstream of fast parsers).
- `research/04-dsjson.md` — projection trees + predicate pushdown,
  same precondition.
- `research/03-simdjson-on-demand.md` — interesting counterpart:
  simdjson optimizes the parse stage with SIMD, which is exactly the
  move that closes the `V/E` gap and makes downstream pushdown
  marginal. zq has the simdjson side; it doesn't have the slow query
  engine that would make pushdown pay.
