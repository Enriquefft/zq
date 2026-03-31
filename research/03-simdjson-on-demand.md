# simdjson On-Demand: Lazy Materialization for JSON Parsing

**Paper:** "Parsing Gigabytes of JSON per Second" (expanded from VLDB 2019)
**Authors:** Daniel Lemire, Geoff Langdale; On-Demand API by John Keiser
**Venue:** Software: Practice and Experience (SPE), 2024
**Core project:** simdjson (2018-present)

---

## Core Technique: Two-Stage Parsing with Lazy Materialization

A third paradigm beyond DOM (eager, full tree) and SAX (streaming callbacks). Builds structural index eagerly with SIMD, defers all value parsing to moment of access.

### Stage 1: Structural Indexing (Eager, SIMD)

Processes entire input buffer using SIMD (SSE4.2, AVX2, AVX-512, ARM NEON):
- **String detection:** SIMD quote finding + carry-less multiplication for escape handling
- **Character classification:** SIMD lookup tables (`vpshufb`/`vtbl`) — 32-64 bytes per cycle
- **Whitespace elimination:** Branchless identification and skip
- **Output:** Array of byte offsets to every structural character (compact: one 32-bit int per structural char)
- **UTF-8 validation:** Branchless SIMD algorithm during Stage 1
- Runs at **4-8 GB/s** depending on SIMD width

### Stage 2: On-Demand Navigation (Lazy, Per-Access)

Unlike DOM mode (which eagerly walks entire structural index):
- Lightweight iterator positioned at start of structural index
- Field lookup: iterator advances through structural index, compares keys in original input buffer (no copies)
- Value materialization: only when user calls `.get_string()`, `.get_int64()`, etc.
- Skipping unused values: count structural characters (nesting depth via brace/bracket matching) — proportional to structural chars, not byte length

### What's Built Eagerly vs Lazily

| Eager (Stage 1) | Lazy (Stage 2 On-Demand) |
|-----------------|-------------------------|
| Structural index (offsets) | Number parsing (int/float conversion) |
| String boundary detection | String unescaping |
| UTF-8 validation | Tree structure (implicit, discovered by traversal) |
| Basic structural validity | Type determination (first byte inspection) |
| | Value validation (at materialization) |

## Results

- **On-Demand:** 2-4 GB/s for partial access patterns
- **DOM mode:** 1-3 GB/s (must materialize everything)
- **Partial access (5% of values):** 2-5x faster than DOM
- **Full access:** Within 10-20% of DOM (slight iterator overhead)

### Memory Comparison

| Mode | Overhead relative to input |
|------|---------------------------|
| DOM | 2-3x (tape + string buffer + tree) |
| On-Demand | 0.2-0.6x (structural index only) |

For 1 GB file: DOM needs 2-3 GB extra; On-Demand needs 200-600 MB.

## Limitations

1. **Forward-only iteration:** Cannot go back to a passed field/element
2. **Single-pass:** Cannot re-iterate an object's fields
3. **No random access:** Array element by index requires iterating through predecessors
4. **Object field lookup is O(n):** Linear scan of keys (cache-friendly but not O(1))
5. **Delayed error detection:** Malformed JSON may not be caught until accessed
6. **Not thread-safe per iterator:** Each thread needs own parser instance

## Relationship to Mison

- Mison (2017) is the intellectual predecessor of structural indexing
- Mison: query-aware, per-level bitmaps, speculation across records
- simdjson: general-purpose, complete structural index, lazy access
- simdjson On-Demand = "Mison's vision realized as a practical, general-purpose API"
- Key difference: Mison requires knowing query upfront; simdjson doesn't

## SIMD Techniques

- Character classification: `vpshufb` (SSSE3/AVX2) / `vtbl` (NEON) lookup tables
- Quote/escape handling: carry-less multiplication (`vpclmulqdq`) or prefix-sum
- Structural extraction: comparison + `movemask`/`pmovmskb` to bitmasks, `tzcnt`/`popcnt` iteration
- UTF-8 validation: branchless SIMD with lookup tables and byte-shuffling
- **Entire Stage 1 is branchless** — critical for superscalar CPUs

Platforms: x86 (SSE4.2, AVX2, AVX-512 with runtime dispatch), ARM NEON, POWER VSX, scalar fallback.

## Follow-up Work

- **Number parsing at GB/s** (Lemire, SPE 2021)
- **simd-json (Rust port):** Similar SIMD structural indexing
- **Pison:** Parallel structural indexing extending Mison/simdjson Stage 1
- **JSON Tiles:** Columnar representations extending structural indexing for analytics
- Influenced SIMD-accelerated parsing of CSV, XML, regex, compiler lexing

## Relevance to zq

- zq already uses a tape-based parser — On-Demand style lazy materialization could reduce the 73% parse bottleneck
- Key question: zq builds full tape regardless of query. On-Demand defers materialization to access time.
- However: projection pushdown (Mison-style) is simpler and solves the same problem for zq's use case
- The structural index memory savings (0.2-0.6x vs 2-3x) are relevant to zq's memory efficiency goals
- On-Demand's forward-only limitation is fine for jq-style streaming transforms
