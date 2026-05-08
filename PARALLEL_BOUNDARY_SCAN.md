# Parallel Boundary Scan (Option B)

Design doc for replacing `file_feeder_fn`'s serial structural pre-pass with a
parallel prefix-sum scan over `ScannerState`. Removes the serial bottleneck
introduced by NIX-001 (`dc0597c`) without weakening any of its correctness
invariants.

## Problem

`src/pool/root.zig:file_feeder_fn` walks every byte of the mmap through
`parser_mod.boundary.advanceState` on a single thread before dispatching
chunks to N workers. For an 87 MB / 1 M-line JSONL input, this serializes
~17 ms of structural scanning ahead of the worker pool, dropping
parallelism factor (user_time / wall_time) from 14.7× (pre-NIX-001) to 6.8×.

Local benchmark, ReleaseFast, `.id` over 1 M-record JSONL:

| variant                          | wall   | user/wall |
| -------------------------------- | ------ | --------- |
| pre-NIX-001 (`\n`-find feeder)   | 113.8 ms | 14.7×   |
| post-NIX-001 (current main)      | 286.0 ms | 6.8×    |
| feeder-reverted (worker unchanged) | 137.7 ms | 14.9×   |

Reverting just the feeder recovers ~87 % of the regression. Worker-side
overhead (~24 ms residual) is real but not the dominant cost.

## NIX-001's correctness invariant — must be preserved

The bug NIX-001 fixed: pretty-printed JSON has literal `\n` at depth > 0
between fields (e.g. `{\n  "a": 1\n}`). Splitting chunks on raw `\n` shreds
multi-line records. Real workloads: `nix derivation show`,
`kubectl -o json`, `$NIX_ATTRS_JSON_FILE`, GitHub API output.

Invariant from `src/pool/root.zig:1542`:

> Each `chunk_end` is a depth-0/outside-string `\n`, so multi-line
> pretty-printed values are never split across workers.

Scanner state semantics (`src/parser/src/boundary.zig`):

```zig
ScannerState { depth: u32, in_string: bool, escape_pending: bool }
advanceState(state, bytes) -> state'   // pure function
findNextRecordEnd(state, bytes, ideal_end, file_size) -> usize
```

Both `advanceState` and `feedBytes` are pure functions of
`(state, bytes) → state'`. That is the textbook shape for prefix-sum
parallelization.

## Options considered

### A — probe + JSONL fast path (rejected)

Probe first 64 KiB structurally; if every `\n` lands at depth 0 outside
string, use `\n`-find for the whole file; else NIX-001 scan.

**Rejected**: latent re-introduction of NIX-001. A mostly-JSONL file with
one embedded multi-line value at byte 50 MB would silently misroute. Failure
mode is parse error per affected record (loud, not silent), but the design
trades correctness on adversarial-but-valid input for performance. Producer
trust is not a property the chunker should require.

### C — worker-cooperative chunking, simdjson-style (rejected)

Feeder does cheap `\n`-find only. Workers skip leading partial records and
extend past `chunk_end` into the next chunk's data via `parser.feed`.

**Rejected** (independent design review confirmed):

1. **Correctness on arbitrary JSON impossible.** `in_string` cannot be
   determined from an arbitrary byte offset. A worker starting mid-string
   sees `…":"}\n{"x":1}` as a depth-0 boundary when the `"` opening the
   string is many KiB earlier. Silent garbage records. Same class of bug
   NIX-001 fixed, just at chunk granularity instead of line granularity.

2. **Worker-to-worker stalls replace feeder bottleneck.** "Extend past
   `chunk_end`" means worker N reads worker N+1's bytes. Either share a
   whole-file mmap view (nobody can `MADV_DONTNEED` safely → bounded-RSS
   invariant breaks) or pass via channel (slow N+1 stalls N, which is
   holding its arena + `InFlightLimiter` slot). Trades one serial
   bottleneck for a stall chain.

3. **Sequencer ring breaks.** `Sequencer` (`src/pool/root.zig:408`) uses a
   fixed-size ring indexed by densely-assigned `chunk_id` at dispatch. With
   overlapping records, the correct ordering key is post-hoc record-start
   byte offset → sparse IDs → ring fails. Requires redesign to a heap
   reorder buffer or two-phase claim handshake.

4. **MADV_DONTNEED becomes refcounted.** With overlapping ranges, page X
   can be both past-end of N's read-ahead and inside N+1's start-skip.
   Neither knows when the other is finished. New failure surface.

5. **Silent corruption surfaces.** Three of C's failure modes (false
   record start inside string, MADV use-after-free, sequencer slot
   collision under skew) produce wrong output, not crashes.

### B — parallel prefix-sum boundary scan (selected)

Two parallel passes over the file, with a microsecond-scale serial stitch
between them. No format-level speculation. No overlap coordination. No
sequencer redesign. Reuses `boundary.zig` verbatim.

## B — algorithm

Inputs: `data: []const u8`, `n_stripes: usize` (≈ worker count).

The naive `compose(stripe_in[i-1], stripe_carries[i-1])` formulation is
**incorrect**: each stripe's terminal state depends on its *input* state, so
a single carry computed from the empty start state is not composable. The
function `f_stripe: State → State` must be summarized over the full domain
of reachable input states, then composed during stitch.

Reachable states are partitioned into 3 categories that fully determine
how the next byte is interpreted:

| `Cat`         | meaning                                          |
| ------------- | ------------------------------------------------ |
| `oos`         | outside string                                   |
| `is_no_esc`   | inside string, no pending escape                 |
| `is_esc`      | inside string, previous byte was `\` (escape pending) |

Depth contributes additively across stripes if and only if it is tracked
as **signed** (a stripe like `}{` has delta 0 from depth ≥ 1 but cannot
saturate at 0 from a low input). The runtime `ScannerState.depth: u32`
uses saturating subtraction; preserving compositionality requires `i64`
during the summary pass and clamping at pass-2 entry.

```
// Pass 1 — parallel: each stripe is summarized as a 3-entry function
//   table over its input category. Per stripe i and per input cat c:
//     terminal[c]     = output Cat after processing stripe[i] from c
//     depth_delta[c]  = i64 net depth change along that path
stripe_summary[i] = summarizeStripe(data[stripe_start[i]..stripe_end[i]])
   // = { terminal: [3]Cat, depth_delta: [3]i64 }

// Stitch — serial: fold left-to-right by indexing each stripe's
//   function table with the prior stripe's terminal Cat. O(n_stripes).
cur_cat   = .oos
cur_depth = 0  // i64
for i in 0..n_stripes:
    idx       = @intFromEnum(cur_cat)
    start[i]  = ScannerState{
        depth          = max(0, cur_depth) as u32,
        in_string      = (cur_cat != .oos),
        escape_pending = (cur_cat == .is_esc),
    }
    cur_depth += stripe_summary[i].depth_delta[idx]
    cur_cat    = stripe_summary[i].terminal[idx]

// Pass 2 — parallel: each stripe re-runs the scan with its correct
//   starting state, recording depth-0 boundaries inside its slice.
boundaries[i] = scanForBoundaries(start[i], data[stripe_start[i]..stripe_end[i]])

// Dispatch: identical to the serial feeder — chunks end at the recorded
//   depth-0/outside-string \n offsets.
```

Why the 3-state table is sufficient: `advanceState` is deterministic on
`(in_string, escape_pending)` plus the byte; depth motion outside a string
is byte-determined and additive once tracked signed. No further state
discriminates the per-byte transition function.

### Why pass fusion is unsound here

Recording candidate boundaries during pass 1 (assuming empty input carry)
and filtering during pass 2 was considered. It would be unsound: a
candidate `\n` recorded at apparent depth 0 from carry-empty may be at
depth 0 from one input cat but at depth N inside a string from another.
The filter cannot recover the truth without re-scanning. Pass 2 is kept
as a full structural walk.

## Invariants preserved

All NIX-001 guarantees survive verbatim:

- Every `chunk_end` is `(depth == 0 and !in_string and !escape_pending)`
  with the byte at `chunk_end - 1` being `\n`.
- Pretty multi-line records never split across workers.
- Worker `parser.feed` loop unchanged. `boundary.countTopLevelValues` and
  `process_value_serialized` unchanged.
- `Sequencer` ring, `InFlightLimiter`, `MADV_DONTNEED` semantics unchanged.

The only change is *who* and *how many threads* compute the boundaries.
The boundary set is byte-identical to the current serial feeder.

## Threshold for fallback

Below some file size, parallel scan overhead (thread fan-out, stitch,
cache-line ping-pong) exceeds the serial scan cost. Use the existing
serial path under that threshold.

Initial threshold: **256 KiB**. Tune empirically.

## Implementation

`src/pool/root.zig`:

- `computeBoundariesParallelRange(allocator, data, range_start, range_end,
  n_stripes, initial_cat, initial_depth, *out)` — two-pass scan over a
  sub-range. Pass 1 runs `summarizeStripe` per stripe in parallel; serial
  stitch composes terminal `Cat` and signed depth-delta tables; pass 2
  re-runs each stripe with its correct entry state and appends depth-0
  `\n` offsets to `out` in stripe order.
- `feedParallel` (wave dispatcher) drives the scan in waves of
  `wave_bytes` (see "Wave dispatch" below). Each wave calls
  `computeBoundariesParallelRange` over its slice and emits chunks
  bounded by the recorded boundaries.
- `feedSerialRange(ctx, *chunk_id, start_offset, start_state, *i_chunk)`
  is the single-threaded path. Used both as the small-file fallback and
  as the zero-boundary wave fallback. The explicit `start_state`
  parameter encodes the precondition: caller guarantees `start_state`
  matches the scanner state at `start_offset`.
- `n_stripes` defaults to `n_threads` from the existing `MemoryBudget`.
- Below `PARALLEL_BOUNDARY_THRESHOLD = 256 KiB`, the parallel path is
  skipped and `feedSerialRange` runs directly.

Thread orchestration: per-wave `std.Thread.spawn`. Stripes are read-only
over the mmap; per-stripe output buffers are the only mutable state
during pass 1 / pass 2.

`src/parser/src/boundary.zig`:

- `Cat` enum (`oos`/`is_no_esc`/`is_esc`) with `fromState(ScannerState)`
  (file-private; only the same-file test consumer uses it).
- `Stripe { terminal: [3]Cat, depth_delta: [3]i64 }` and
  `summarizeStripe(data) -> Stripe`. Internally walks the slice three
  times — once per input category — using a signed-depth variant of
  `advanceState`. The three walks are independent and trivially
  vectorizable; they share the byte stream in cache.
- Existing `advanceState` and `feedBytes` are reused unchanged for the
  per-stripe pass-2 boundary recording.

## Edge cases

- **Stripe boundary inside a string with `escape_pending`**: the carry
  must encode "previous byte was `\\` inside a string." `ScannerState`
  already has `escape_pending: bool` for exactly this. Verify the stitch
  composes it correctly.
- **Stripe boundary mid-UTF-8 sequence**: `boundary.zig` operates on
  bytes, not codepoints; no special handling required.
- **Final stripe with no trailing `\n`**: identical to today — the
  dispatcher emits a final chunk ending at `file_size`.
- **Empty stripes** (file smaller than `n_stripes`): fall back to the
  serial path under the threshold.
- **Adversarial pathological input** (e.g. `[[[[[…` with millions of
  open brackets): `depth` is `u32`, sufficient. Existing parser
  `DEPTH_LIMIT` still rejects at parse time.

## Wave dispatch

The two-pass scan as originally landed processed the file in one shot:
both passes spanned the full mmap, returning a single `[]usize` of all
depth-0 boundaries. On large inputs this prefaults the entire file into
the resident set ahead of any worker doing `MADV_DONTNEED` — peak RSS
spiked to roughly `file_size + in_flight_bytes` (1.5 GB on the 1.3 GB /
15 M-record reference workload, against a 440 MB README target).

`feedParallel` solves this without touching the per-pass scan logic:
the file is processed in waves of `wave_bytes`, where each wave runs
the full two-pass scan over its slice, dispatches its chunks, then
yields to the next wave. Workers `MADV_DONTNEED` chunks as they finish,
so wave N+1 enters with wave N's pages already evictable.

```
file_size: F     wave_bytes: W     in_flight_bytes: I
peak RSS  ≈  in_flight_bytes + wave_bytes
            └────────────────┘ └────────┘
            chunks owned by    bytes the
            slot-holding       current wave
            workers            scan touches
```

### `wave_bytes` derivation (SSOT)

The wave size is derived from the same `MemoryBudget` chain that sets
`in_flight_bytes`, ensuring the bound holds across all budget regimes:

```zig
const WAVE_BYTES_DIVISOR: usize = 8;
const ideal_chunk      = file_size / n_chunks;
const in_flight_bytes  = limiter.max * ideal_chunk;
const wave_bytes       = max(in_flight_bytes / WAVE_BYTES_DIVISOR,
                             PARALLEL_BOUNDARY_THRESHOLD);
```

`WAVE_BYTES_DIVISOR = 8` is Pareto-tuned across {1/2, 3/8, 1/4, 3/16}
of `n_stripes × ideal_chunk`. On the default 22-thread / `in_flight_factor=2`
configuration this reproduces the previous empirical `n_stripes × ideal_chunk / 4`
window. Tighter budgets (`in_flight_factor → 1`) scale the window
proportionally.

### Cross-wave carry: structurally `(.oos, depth=0)`

Each wave dispatches up to `boundaries.items[last] + 1`. Boundaries
returned by `feedBytes` are by construction depth-0 / outside-string
`\n` offsets, so the byte one past such a boundary always starts at
`(.oos, depth=0)`. The next wave begins from `last_boundary + 1` with
the default `ScannerState{}` and zero `initial_depth` — no carry plumbing
needed, no scanner-state composition across waves.

### Zero-boundary fallback

A wave can find zero in-wave boundaries on pathological inputs (one
record straddling the wave window, or an extremely long string). The
dispatcher tries one extension to `2 × wave_bytes`; if that also yields
zero boundaries, it falls back to `feedSerialRange` from `wave_start`
to EOF. This bounds re-scan cost while remaining correct on any input.

### Measured results

ReleaseFast, `zq '.id' huge.jsonl > /dev/null`, 1.3 GB / 15 M-record
JSONL, 22-core Intel Ultra 9 185H.

| variant                                | wall    | peak RSS  | RSS / input |
| -------------------------------------- | ------- | --------- | ----------- |
| post-NIX-001 serial scan               | 4.0 s   | 175 MB    | 0.13×       |
| parallel two-pass, no waves            | 3.18 s  | 1.5 GB    | 1.15×       |
| **wave dispatch (`/8` formula)**       | **3.20 s** | **373 MB** | **0.29×**   |
| README target                          | —       | 440 MB    | 0.31×       |

Wave dispatch beats the README's RSS target while preserving the
parallel-scan wall-time win (within noise of the no-wave variant).

### Tests

`tests/pool_test.zig` covers wave correctness with four targeted tests
that force ≥2 waves under a small `MemoryBudget`:

| test                                              | exercises                                          |
| ------------------------------------------------- | -------------------------------------------------- |
| wave-boundary mid-string with escape pending       | `is_esc` carry across stripe and wave splits       |
| wave-boundary inside multi-line pretty record      | cross-wave `(.oos, 0)` carry on pretty JSON        |
| many waves — file >> wave_bytes                    | cumulative ordering across ~25 waves               |
| zero-boundary wave fallback                        | extension-then-serial-fallback path                |

The pre-wave `submit_file: parallel boundary scan over >256 KiB pretty
JSON` runs as a single wave under the default budget — stays green
without modification.

## Open questions

1. Pass-fusion is not viable as originally sketched (see above). A
   different fusion — recording per-byte category bitmaps in pass 1 and
   stitching boundaries from those without re-walking — could collapse
   the second pass but is a substantial rewrite for unmeasured benefit
   given current memory-bandwidth ceiling.
2. `n_stripes == n_threads` is in use and not currently a tuning lever.
   Lower stripe counts may help on small files but the 256 KiB threshold
   already short-circuits to the serial path there.
3. Stream path (`io_thread_json_boundaries`) is unaffected by this
   design — streaming is inherently serial at the IO layer. The
   carry-buffer double-memcpy noted in the original review is a
   separate optimization, tracked elsewhere.

## References

- NIX-001 commit: `dc0597c` ("fix(pool): NIX-001 — JSON-structure-aware
  chunker (boundary scanner SSOT)").
- Boundary scanner: `src/parser/src/boundary.zig`.
- Wave dispatcher / `feedParallel` / `feedSerialRange` /
  `computeWaveBytes`: `src/pool/root.zig` (`feedParallel`,
  `feedSerialRange`, `computeWaveBytes`, `computeBoundariesParallelRange`).
- Sequencer: `src/pool/root.zig` (`Sequencer`).
