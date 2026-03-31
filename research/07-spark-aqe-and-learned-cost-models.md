# Spark Adaptive Query Execution and Learned Cost Models

## Part 1: Spark AQE

**Introduced:** Apache Spark 3.0 (June 2020), default in Spark 3.2 (October 2021)
**Key contributors:** Databricks engineers (Maryann Xue, Herman van Hovell et al.)
**Type:** Engineering contribution (no single academic paper)

---

### Core Architecture

AQE operates at **stage boundaries** (shuffles) in Spark's DAG execution:

1. Execute plan up to first shuffle boundary
2. Materialize shuffle outputs (map-side writes)
3. Collect **exact runtime statistics** from materialized data
4. Re-optimize remaining plan using actual statistics
5. Repeat per stage boundary

Statistics collected: partition sizes (bytes), record counts, data distribution, total shuffle size. All **exact** (not sampled).

### Three Core Techniques

**A. Dynamic Partition Coalescing:**
Adjacent small shuffle partitions merged to target advisory size (default 64MB). Eliminates manual `spark.sql.shuffle.partitions` tuning.

**B. Sort-Merge Join -> Broadcast Hash Join:**
After shuffle, check actual materialized sizes. If one side is below broadcast threshold, convert SMJ to BHJ (avoids probe-side shuffle entirely). Often the single most impactful optimization.

**C. Skew Join Optimization:**
Detect skewed partitions (size >> median). Split large partitions, replicate corresponding other-side partition. Eliminates manual salting/custom skew handling.

### Results

- 2-10x speedup on queries with inaccurate cardinality estimates
- 10-30% median query time reduction on production workloads with no code changes
- Elimination of manual partition tuning (top Spark support issue)

### Limitations

1. Only adapts at stage boundaries (not within stages)
2. Cannot change fundamental query structure (logical plan unchanged)
3. Greedy, not globally optimal (local per-stage decisions)
4. No benefit without shuffles (simple filter-project queries)
5. Rule-based heuristics only (no learning)
6. Overhead for very short queries

---

## Part 2: Learned Cost Models (SIGMOD 2019-2025)

### Key Papers

**Foundational:**
- **"Learned Cardinalities"** (Kipf et al., CIDR 2019): Deep learning for join cardinality estimation
- **"End-to-End Learned Cost Estimator"** (Sun & Li, VLDB 2019): Tree-structured neural network predicting query cost

**Practical Optimizers:**
- **Bao** (Marcus et al., SIGMOD 2021): Learns to select among optimizer-generated plan hints using Thompson sampling. 50%+ tail latency improvement in PostgreSQL. Practically deployable alongside existing optimizers.
- **Balsa** (Yang et al., SIGMOD 2022): Bootstraps learned optimizer from scratch using simulation
- **LEON** (VLDB 2023): Integrates learned models into existing optimizers as additional signal
- **Lero** (Chen et al., VLDB 2023): Learning-to-rank candidate plans (more robust than absolute cost prediction)

**Cross-Engine Routing:**
- Predict execution time on each engine, route to best one
- 25-30% overall latency reduction in mixed workload environments
- Biggest gains from correcting worst plans, not improving good ones

### Key Finding Across Papers

Learned models reduce cardinality estimation errors from 100-1000x (traditional) to 2-10x. But the biggest wins come from **correcting catastrophic plans** — distribution of speedups is heavily skewed (few queries 10-100x faster, many unchanged).

### AQE + Learned Models: Complementary

| Aspect | AQE | Learned Cost Models |
|--------|-----|---------------------|
| When | Runtime (during execution) | Compile time (before) |
| Uses | Exact runtime statistics | Historical execution data + ML |
| Changes | Physical plan | Plan selection, engine routing |
| Cold start | No problem | Needs training data |

**Emerging direction:** Compile-time ML for initial plan + AQE runtime correction + feedback loop.

## Relevance to zq

- AQE's partition coalescing ~ dynamic work-stealing / adaptive batch sizing
- zq's mode selection (streaming vs file) could use a simple cost heuristic (few `if` statements on file size + query type gets 95% of the way — validates "Paper only" tag)
- Key AQE insight for zq: **exact statistics at materialization points (chunks) are vastly more useful than compile-time estimates**
- First-chunk statistics can inform strategy for remaining chunks
- Full learned cost models are over-engineering for zq's scope
