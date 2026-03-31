# Eddies: Continuously Adaptive Query Processing

**Paper:** "Eddies: Adaptively Ordering Operators in Query Processing"
**Authors:** Ron Avnur, Joseph M. Hellerstein
**Venue:** ACM SIGMOD 2000
**Affiliation:** UC Berkeley

---

## The Problem

Traditional query optimizers commit to a fixed operator ordering at compile time based on catalog statistics. This fails when:
- Statistics are stale/absent (federated queries, intermediate results)
- Data is skewed (uniform distribution assumptions fail)
- Runtime conditions fluctuate (network latency, data arrival rates)
- Wrong join order costs can be orders of magnitude

## Core Technique: Per-Tuple Adaptive Routing

An **Eddy** is a meta-operator at the center of a query's dataflow. All tuples flow into the Eddy; it routes each tuple to the next operator based on runtime observations.

### Architecture

```
Scan R -> |       | -> Operator 1 (Join with S)
Scan S -> | EDDY  | -> Operator 2 (Join with T)
Scan T -> |       | -> Operator 3 (Selection)
          |       | <- results flow back
             |
           Output
```

Each tuple carries bitvectors:
- **Ready bits:** Which operators this tuple is eligible to visit
- **Done bits:** Which operators already processed this tuple

### Lottery Scheduling (Routing Policy)

Each operator holds "lottery tickets." Eddy draws random ticket per tuple to decide routing.

**Ticket adjustment (adaptive part):**
- High-selectivity operators (filter many tuples) -> more tickets -> visited earlier
- Slow/blocking operators -> fewer tickets -> deferred
- Continuously adjusted as tuples flow

**Why lottery:** Exploration vs exploitation balance. Pure greedy would never discover changed conditions. Randomness ensures ongoing exploration.

## Results

- Converges to near-optimal operator orderings
- Adapts to changing conditions mid-query (network fluctuations in federated settings)
- Handles data skew (effectively applies different orderings to different data portions)
- Modest overhead in worst case (when static optimizer was right)

## Limitations

1. **Per-tuple routing overhead:** Pure cost when operators are cheap and local
2. **Blocking operators:** Hash join build phase prevents selectivity feedback
3. **Memory for join state:** Multiple orderings require state for each
4. **Convergence speed:** Learning phase may dominate short queries
5. **No backtracking:** Bad per-tuple routing decisions are permanent
6. **Limited to reorderable operators** (selections, certain joins)
7. **Coarse for correlated predicates** (addressed by later STAIRs work)

## Legacy and Influence

Foundational paper for **Adaptive Query Processing (AQP)**:

- **SteMs** (Raman & Hellerstein, VLDB 2003): Decomposed join state for Eddies
- **STAIRs** (Deshpande & Hellerstein, VLDB 2004): Content-sensitive routing
- **TelegraphCQ** (Chandrasekaran et al.): Eddies for continuous/streaming queries
- Influenced SQL Server Adaptive Joins, Oracle Adaptive Plans, Spark AQE

Established principle: **query execution should be continuous optimization, not one-shot compile-time decision.**

## Comparison to Spark AQE

| Aspect | Eddies | Spark AQE |
|--------|--------|-----------|
| Granularity | Per-tuple | Per-stage (shuffle boundaries) |
| Statistics | Continuous, per-tuple | Exact, at materialization points |
| Overhead | High (per-tuple decision) | Low (one re-optimization per stage) |
| Scope | Single-node, in-memory | Distributed, disk-based shuffles |

Modern systems favor stage-level adaptation: most benefit at fraction of cost.

## Relevance to zq

- zq's "chunk" is the natural adaptation unit (between Eddies' per-tuple and Spark's per-stage)
- Per-chunk adaptation: measure selectivity/parse cost on first N chunks, adjust strategy for remaining
- Validates the concept in the optimization text of "per-chunk adaptive strategy"
- Key lesson: adaptation overhead must not exceed benefit. For zq's fast per-record processing, the granularity matters enormously.
