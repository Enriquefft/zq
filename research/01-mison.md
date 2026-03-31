# Mison: A Fast JSON Parser for Data Analytics

**Paper:** "Mison: A Fast JSON Parser for Data Analytics"
**Authors:** Yinan Li, Nikos R. Koudas, Craig Chasseur, Jignesh M. Patel, Jeff Naughton
**Venue:** VLDB 2017 (Proceedings of the VLDB Endowment, Vol. 10, No. 10)
**Affiliations:** University of Wisconsin-Madison, University of Toronto

---

## Core Technique: SIMD Structural Indexing

Mison's insight: you don't need to parse an entire JSON record to extract a subset of fields. Build a lightweight SIMD-accelerated bitmap structure to locate fields directly.

### Four Phases

1. **Character Classification (SIMD):** Load 32-64 bytes at a time, produce character bitmaps for structural characters (`:`, `,`, `{`, `}`, `[`, `]`, `"`) using `_mm256_cmpeq_epi8` + `_mm256_movemask_epi8`.

2. **Quote Masking:** Build a string mask from the quote bitmap to zero out structural characters inside string values. Handles escaped quotes correctly.

3. **Leveled Bitmaps (Key Innovation):** Build per-nesting-level colon and comma bitmaps. A colon at depth 0 is different from depth 2. Only build bitmaps for levels the query actually accesses. Uses brace bitmaps to track nesting depth.

4. **Field Lookup:** Find the N-th field at level L by finding the N-th set bit in `colon_bitmap[L]` using `TZCNT`/`BLSR`. Get value byte range without parsing surrounding record.

## Results

| Mode | Speedup vs RapidJSON |
|------|---------------------|
| Without speculation | ~3.6x |
| With speculation | ~10.2x |

- Scales linearly with number of projected fields
- Bitmap construction: ~1-2 cycles/byte using SIMD
- Integrated into Apache Spark's JSON reader

## Speculation: Cross-Record Optimization

JSONL records typically share schema. Cache field byte-offsets from record N, jump directly to that offset in record N+1.

1. **First record (training):** Full structural indexing, record byte offsets per projected field
2. **Subsequent records:** Jump to cached offset, validate key matches expected name
3. **Hit:** Extract value directly (no bitmap construction). **Miss:** Fall back to full indexing, update cache

- Hit rate typically 99%+ on real datasets
- Sensitive to field ordering changes and value length changes
- Drives the improvement from 3.6x to 10.2x

## Limitations

- Assumes JSONL / newline-delimited records
- Speculation requires homogeneous schemas
- Best for flat/shallow field access; deep nesting reduces benefit
- Projection-only: no predicate evaluation, aggregation, or transforms
- Arrays less amenable to speculation (no keys to validate)
- Memory overhead for bitmaps: `input_length / 8` bytes per character class per level
- x86-centric (SSE/AVX2); portable algorithmically but requires per-ISA implementation

## Follow-up Work

- **Pison (VLDB 2021):** Parallel structural indexing across multiple cores
- **JPStream:** Streaming JSON processing using structural indexing
- **Sparser (VLDB 2018):** Complementary predicate pushdown (filter before parse)
- **simdjson On-Demand (2020+):** Lazy tape traversal inspired by Mison's insight

## Relevance to zq

- Level-selective bitmaps map to zq's parser when query is a simple projection (`.id`, `.name`)
- Speculation could dramatically accelerate homogeneous JSONL (dominant use case)
- Directly targets zq's 73% parse-time bottleneck
- Composes naturally with zq's parallel chunk processing: per-chunk query-aware parsing

**Key comparison with simdjson:** Mison asks "parse less"; simdjson asks "parse all of it faster." A hybrid (simdjson's SIMD character classification + Mison's query-aware level-selective indexing) is the theoretical optimum.
