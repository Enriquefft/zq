# Adaptive Query Processing Survey

**Paper:** "Adaptive Query Processing"
**Authors:** Amol Deshpande, Zachary Ives, Vijayshankar Raman
**Venue:** Foundations and Trends in Databases, Vol. 1, No. 1, pp. 1-140, 2007
**Affiliations:** University of Maryland, University of Pennsylvania, IBM Almaden

---

## Scope

Comprehensive 140-page survey covering two decades of techniques for making query processing adaptive — changing behavior mid-execution rather than committing to a static plan. 800-1000+ citations.

## Key Taxonomy

### By What's Adapted

1. **Plan-Based Adaptation:** Modify/replace query plan
   - **Inter-query:** Learn from completed queries to improve future plans (histogram updates, LEO optimizer)
   - **Intra-query:** Change plan during execution (more powerful, more complex)

2. **Routing-Based Adaptation:** Dynamically route tuples through operators
   - **Eddies:** Central router makes per-tuple decisions
   - **SteMs:** Decomposed join state management for flexible routing

3. **Operator-Level Adaptation:** Individual operators internally adaptive
   - Adaptive join algorithms (XJoin, hash ripple joins)
   - Adaptive memory management, scheduling

### Major Systems Covered

- **Eddies** (Avnur & Hellerstein, 2000): Per-tuple routing paradigm
- **Mid-Query Re-Optimization** (Kabra & DeWitt, 1998): Monitor at materialization points, re-invoke optimizer
- **Progressive Optimization / POP** (Markl et al., IBM, 2004): Cardinality validation checkpoints, preserve completed work
- **Rio** (Babu et al., 2005): Choose robust plans across parameter ranges
- **Tukwila** (Ives et al., 2004): Adaptive query processing for data integration
- **TelegraphCQ** (Chandrasekaran et al., 2003): Eddies for streaming

## When Adaptation Helps vs Hurts

### Helps When:
- Statistics unreliable/unavailable (data integration, data lakes, schema changes)
- Runtime conditions unpredictable (network, skew, memory pressure)
- Queries long-running (amortizes adaptation cost)
- Data is streaming/continuous (no compile time)
- Large estimation errors (compound exponentially through joins)

### Hurts When:
- Monitoring overhead exceeds benefit (short queries, well-understood data)
- Thrashing: too-reactive adaptation oscillates between plans
- State migration is expensive (hash table mid-build)
- Plan space is flat (many plans have similar cost)

### Key Insight: "Plan Diagram" Perspective

Adaptation is most valuable near **boundaries** between plan regions in parameter space — where small estimation errors cause jumps to very different optimal plans with very different costs.

## How This Frames Subsequent Work

The taxonomy predicts why Spark AQE works the way it does:
- **Why not eddies?** Per-tuple routing too fine-grained for batch billions of rows
- **Why stage boundaries?** Natural materialization points (shuffles)
- **Why not intra-stage?** Switching cost too high in distributed systems

Similarly explains Presto/Trino, Flink, CockroachDB adaptive approaches.

## Relevance to zq

- zq's mode selection (streaming vs parallel-file) is a plan-level decision
- Per-chunk adaptation is mid-query re-optimization at materialization points (chunks)
- The survey's insight about overhead vs benefit is critical: zq's per-record processing is so fast that adaptation granularity must be coarse enough (chunk or batch level) to amortize overhead
- Validates "Profile first" tag on adaptive items in the optimization plan
