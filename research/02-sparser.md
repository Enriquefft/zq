# Sparser: Raw Filtering for Fast Analytics over Raw Data

**Paper:** "Sparser: Raw Filtering for Fast Analytics over Raw Data"
**Authors:** Shoumik Palkar, Firas Abuzaid, Peter Bailis, Matei Zaharia
**Venue:** VLDB 2018 (Proceedings of the VLDB Endowment, Vol. 11, No. 12)
**Affiliation:** Stanford University (DAWN project)

---

## Core Technique: Raw Filter Cascades

Before any parsing, scan raw bytes of each record using SIMD-accelerated substring searches. Records that can't possibly match a predicate are skipped entirely. No false negatives; false positives are handled by the full parser.

### Raw Filter (RF) Primitives

- **Byte search:** Does the record contain a specific byte?
- **Substring search:** Does the record contain a multi-byte string? (e.g., `"San Francisco"`)
- **Key-value search:** Does the record contain a specific key-string adjacency?

Implemented with SIMD (SSE4.2 `PCMPESTRI`/`PCMPESTRM`, AVX2). Single RF operates at near-memory-bandwidth speeds.

### Cascade Composition

Multiple RFs composed in sequence — record must pass all filters to reach full parser:

1. Cheapest filters first (single-byte before multi-byte)
2. Most selective filters first (eliminate most records early)

Ordering determined by **cost-based optimizer using sampling** (1-2% of input):
- Estimates false positive rate of each RF
- Estimates cost per record of each RF
- Greedy/DP selection to minimize: `Sum(cost_RF_i * P(reach_stage_i)) + cost_parse * cascade_FP_rate`

### Example Cascade

For `WHERE city = "San Francisco" AND year = 2017`:
1. RF1: Search for byte `S` (very cheap, moderate selectivity)
2. RF2: Search for `"San F"` (more expensive, higher selectivity)
3. RF3: Search for `2017` (good selectivity if rare)
4. Full parse: only records passing all three

## Results

- **Up to 22x over Mison** on highly selective queries
- **~9x over hand-optimized parsers** (RapidJSON etc.)
- Processing rate: ~2-4 GB/s single core on selective queries (approaching memory bandwidth)

### Selectivity vs Speedup

| Selectivity (% filtered) | Speedup |
|--------------------------|---------|
| >99% | 10-22x |
| ~95% | 3-8x |
| ~80% | 1.5-3x |
| ~50% | ~1x (break-even) |
| <50% | Slower (optimizer should disable) |

## False Positive Analysis

Sources: substring in wrong field, wrong type, partial matches, cross-record spans.

Mitigations:
- Longer substrings reduce FP but cost more (optimizer balances)
- Cascaded filters exponentially reduce FP (approximately multiplicative)
- Full parser is final arbiter (correctness never compromised)
- Optimizer disables cascade when FP rate exceeds ~30-50%

## Limitations

1. **Text-only input:** No binary/compressed formats
2. **Record boundaries must be cheaply identifiable** (JSONL newlines)
3. **Predicate must translate to substring RFs:** Equality/containment good; range predicates (`> 30`) impractical
4. **Sampling overhead:** Few ms on multi-GB files, but non-negligible for small files
5. **Single-pass assumption:** Repeated queries should use indexes/columnar instead
6. **Memory bandwidth bound** on highly selective queries

## Relationship to Mison

**Complementary, not competing:**
- Mison = projection optimization (parse fewer fields per record)
- Sparser = selection optimization (parse fewer records)
- Compose well: Sparser skips non-matching records, Mison extracts needed fields from matching ones
- Sparser uses Mison (or any parser) as its backend for records that pass filters
- The 22x over Mison demonstrates that even fast parsing can't compete with not parsing at all

## Follow-up Work

- Part of Stanford **Weld** project (common runtime for data analytics)
- "Filter Before You Parse" became a design principle in raw data analytics
- Influenced simdjson's On-Demand philosophy (avoid unnecessary work)
- Cascade approach influenced speculative predicate evaluation in database systems

## Relevance to zq

- jq/zq queries are often selective: `.[] | select(.status == "error")` on logs may match <1%
- JSONL format gives free record boundaries (ideal for Sparser)
- zq's existing SIMD infrastructure makes adding raw-byte pre-filter architecturally clean
- Composable with zq's thread pool (per-record, embarrassingly parallel)
- **Key concern:** Filter compilation latency for interactive CLI use. Small files: overhead may dominate. Multi-GB JSONL: transformative.
- The cascade optimizer (adaptive RF selection + ordering) is the hard part, not the basic substring check
