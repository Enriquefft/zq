# TODO

## Pool — Serialized Path Inefficiencies

### chunk_buf pre-allocation underestimates for pretty format

`select()` in pretty format produces ~5.5x more output than input (each object
expands with indentation). `chunk_buf` is pre-allocated to `job.data.len` which
is insufficient — the arena must grow it in-place through multiple resizes. A
smarter estimate (e.g. 2× for pretty, 1× for compact) would avoid the extra
resize copies and reduce peak RSS for output-expanding queries.

Current `select()` RSS is 2065 MB (3.2x input) vs the ideal ~1.5x if the output
size were known upfront.

**File:** `src/pool/root.zig` — `worker_fn`, serialized path

### SIMD newline counting

The newline-counting loop to get exact `record_count` iterates every byte of
`job.data` (~7 MB per chunk). This could be SIMD-accelerated (`popcount('\n')`
over 32-byte AVX2 lanes) to reduce the cost from ~100 µs to ~10 µs per chunk.
Currently negligible vs parse/query time but matters if parsing gets faster.

**File:** `src/pool/root.zig` — `worker_fn`, serialized path
