# dsJSON: A Distributed SQL-on-JSON Processor

**Paper:** "dsJSON: A Distributed SQL-on-JSON Processor"
**Authors:** Lin Jiang, Junqiao Qiu, Zhijia Zhao
**Venue:** SIGMOD 2023
**Affiliations:** Michigan Technological University, UC Riverside

---

## Core Technique: Projection Trees

A compact tree-structured representation of which fields (at which nesting levels) a query needs. Derived from SQL query's SELECT, WHERE, and JOIN clauses. Captures the minimal JSON schema skeleton to materialize.

### How Projection Trees Work

1. **Query Analysis:** Determine which JSON paths are referenced for output and filtering. E.g., `SELECT t.name, t.address.city FROM records t WHERE t.age > 30` needs paths `/name`, `/address/city`, `/age`.

2. **Tree Construction:** Paths organized into tree mirroring JSON nesting. Internal nodes = objects/arrays to partially traverse. Leaf nodes = needed fields. Branches not in tree can be skipped entirely.

3. **Guided Parsing:** Projection tree acts as roadmap during parsing. Consults tree per object entry to decide: materialize (descend) or skip (advance past without allocating).

4. **Structural Pruning:** JSON documents often contain far more fields than any query needs. Pruning at parse time avoids "parse everything, then project."

## Predicate Pushdown into Parsing

Predicates are pushed into the parsing phase itself:

- **Early evaluation:** Predicate fields prioritized during extraction. Once parsed, predicate evaluated immediately.
- **Short-circuit skipping:** Record fails predicate -> stop extracting remaining fields, skip to next record.
- **Predicate ordering:** Simple predicates on top-level scalar fields evaluated first (cheapest, highest selectivity benefit).
- **Combined effect:** Projection tree restricts *which fields*; predicates restrict *which records*. Two-level pruning.

## Distributed Aspect

- **Partitioned processing:** JSON partitioned across nodes/threads, each with own projection-tree-guided parser
- **Broadcast projection tree:** Derived once from query, broadcast to all workers
- **Chunk boundary handling:** Boundary resolution identifies valid record start points within each chunk (similar to Mison/Pison)
- **Near-linear scalability:** Parsing is embarrassingly parallel, projection eliminates redundant work per node, predicate pushdown reduces pre-shuffle volume

## Results

- **3x-20x+ over full-parsing baselines** (speedup larger for wide/deep documents, highly selective predicates)
- **Significant advantage over Mison/simdjson in naive mode:** Those optimize *how fast* you parse; dsJSON optimizes *how much* you parse
- **Near-linear parallel scalability**
- **Significant memory reduction** from not materializing unneeded fields

## Key Insight

**"The fastest way to parse JSON is to not parse it at all"** — at least not the parts you don't need. Parse avoidance beats parse acceleration.

## Comparison to Prior Work

| System | Optimizes | dsJSON Advantage |
|--------|----------|------------------|
| Mison | Structural index for field lookup | dsJSON has holistic query-aware skip strategy + distributed |
| Sparser | Raw byte pre-filtering | dsJSON handles nested structures; full predicate semantics, not just substrings |
| simdjson | SIMD-accelerated full parsing | dsJSON avoids parsing altogether for unneeded fields |

**These are complementary:** dsJSON's projection trees + simdjson's SIMD acceleration for what remains.

## Limitations

1. Schema semi-regularity: heterogeneous documents reduce effectiveness
2. Static query analysis: `SELECT *` can't benefit from projection
3. JSON-specific technique
4. Simple scalar predicates only for pushdown; UDFs/correlated subqueries can't be pushed
5. Distributed overhead for small datasets
6. No schema evolution handling

## Relevance to zq

Directly relevant. zq's architecture maps naturally:
- Compiled bytecode already knows which fields are needed (fuse pass)
- Projection tree = feeding fuse-pass field info back to parser
- Predicate pushdown = evaluating `select()` predicates during parsing
- Parallel pool + worker architecture is the distributed equivalent
- Could reduce the 73% parse-time bottleneck by skipping unneeded fields

**The projection tree is essentially what zq needs: a bridge between query compilation and the parser.**
