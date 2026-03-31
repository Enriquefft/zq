# Compiled vs Vectorized Query Execution

**Paper:** "Everything You Always Wanted to Know About Compiled and Vectorized Queries But Were Afraid to Ask"
**Authors:** Timo Kersten, Viktor Leis, Alfons Kemper, Thomas Neumann, Andrew Pavlo, Peter Boncz
**Venue:** PVLDB, Vol. 11, No. 13, 2018
**Affiliations:** TU Munich (HyPer), CMU, CWI Amsterdam (MonetDB/Vectorwise)

---

## The Two Paradigms

### Vectorized Execution (MonetDB/X100 / Vectorwise)
- Process data in **batches (vectors)** of ~1024 tuples
- Operators are pre-compiled primitives — tight loops over typed arrays
- Interpretation overhead amortized: one virtual call per 1024 tuples
- SIMD-friendly: tight loops over contiguous typed arrays easy to auto-vectorize

### Data-Centric Compilation (HyPer)
- Query compiled to **native machine code** (via LLVM) specific to the query
- Data-centric: tuples kept in CPU registers across multiple operators
- Zero interpretation overhead — no virtual calls, no type dispatch
- Pipeline breakers define code segment boundaries

## Key Finding

**Neither approach is fundamentally superior. Differences are small (within 2x) and workload-dependent.**

| Workload | Winner | Why |
|----------|--------|-----|
| Computation-heavy (complex expressions) | Compiled (~20-50%) | Avoids intermediate materialization |
| Data-movement-heavy (large scans, simple filters) | Tie | Memory bandwidth bottleneck dominates |
| SIMD-amenable (selections, hash) | Vectorized (2-4x) | Columnar tight loops easier to SIMD-vectorize |
| Many operators / complex plans | Vectorized | Compiled code has instruction cache pressure |
| Short/interactive queries | Vectorized | No compilation latency (LLVM: 50-500ms) |

## SIMD Impact

- **Vectorized:** Natural SIMD fit. Simple loops auto-vectorize; hand-written SIMD intrinsics add more.
- **Compiled:** Fused loops are complex (branches, mixed types, register pressure) — harder to auto-vectorize.
- For selection-heavy queries (TPC-H Q6): SIMD gives vectorized **2-4x** advantage.
- **As SIMD width increases (AVX-512, ARM SVE), vectorized advantage grows.**

## TPC-H Results

- Overall throughput: within 10-30% across most queries
- Q6 (SIMD showcase): vectorized ~2x faster
- Q9, Q18 (complex multi-join): compiled ~10-20% faster
- Hash join probe: nearly identical
- Memory bandwidth saturation: both saturate at similar points

## Practical Recommendations

1. **Choice less important than commonly believed** — engineering quality, algorithms, storage format matter more
2. **Hybrid approaches promising** — vectorized for SIMD-friendly ops, compiled for complex expressions
3. **SIMD is critical regardless of model**
4. **Compilation latency matters** for interactive workloads
5. **Simplicity and maintainability favor vectorization** — pre-compiled primitives easier to write/test/debug
6. **Modern hardware trends favor vectorization** (wider SIMD)

## Industry Impact

Post-2018 trend toward vectorized execution:
- **DuckDB:** Vectorized (CWI team). Validates the approach.
- **Velox (Meta):** Vectorized. Engineering simplicity argument.
- **Photon (Databricks):** Vectorized native engine replacing Spark's code-gen.
- **ClickHouse:** Vectorized (predates paper, retroactively validated).
- **Umbra (TUM):** Moved from pure LLVM to bytecode VM + optional compilation.
- **DataFusion/Arrow:** Vectorized on Arrow columnar batches.

## Relevance to zq

**A bytecode VM is the correct architecture for zq.** Reasons:

1. **Parsing dominates (73% of time).** Filter execution model is secondary. Whether interpreted or compiled, parse cost dwarfs filter cost.

2. **SIMD matters in parser, not filter VM.** zq already uses SIMD for parsing. Paper confirms SIMD is critical where time is spent.

3. **Compilation latency unacceptable for CLI.** jq/zq filters run ms-to-seconds. LLVM JIT adds 50-500ms startup. Paper's interactive workload concern applies directly.

4. **Filter complexity is low.** jq filters are simple: field access, selection, object construction. Map well to small bytecode primitive set. Not the "complex expressions" where compilation shines.

5. **Engineering complexity.** JIT compiler for jq filters = enormous complexity for marginal gain. Bytecode VM is the practical choice.

6. **Hybrid insight applies.** Bytecode VM for filter dispatch + SIMD within specific opcodes (e.g., field lookup with SIMD string matching). Best of both worlds.

**Bottom line:** Invest SIMD effort in the parser (projection pushdown, structural indexing), not in compiling filter bytecode to native code.
