# TODO

Items known to be unfinished but not yet promoted to `ROADMAP.md`. Each entry
should move to `ROADMAP.md` (if becoming a milestone goal) or to `bugs.md` (if
it turns into a named defect) as it matures. Delete entries as they resolve.

Last verified: 2026-05-08.

## Active

### Dead param: `initial_depth: i64` on `computeBoundariesParallelRange`

`src/pool/root.zig:computeBoundariesParallelRange` takes `initial_depth:
i64`. Every callsite passes `0` (`feedParallel` and the test path). The
function clamps with `if (initial_depth < 0) 0 else @intCast(...)` —
unreachable branch since the carry invariant guarantees depth-0 entry.
Drop the parameter, drop the conditional. SSOT win: the cross-wave
`(.oos, depth=0)` invariant is encoded in one place (the boundary-aligned
slicing in `feedParallel`) instead of also being shadowed by an unused
clamp.

### Surface tightening: demote `Cat` / `Stripe` / `summarizeStripe` to non-`pub`

`src/parser/src/boundary.zig` exports `Cat`, `Stripe`, and
`summarizeStripe` as `pub`. The only consumer outside the file is
`src/pool/root.zig`'s `computeBoundariesParallelRange`. Move that
function into `boundary.zig` (or its own module under `parser/src/`) so
the parallel-prefix-sum support API stays internal to the boundary
package, and demote the three names. Reduces the parser/pool coupling
surface to just `feedBytes` + `ScannerState`.

### Persistent worker pool: amortize per-wave thread spawn

`feedParallel` spawns N threads per wave for both pass 1 and pass 2
(`runStripesParallel` in `src/pool/root.zig`). Under tight `MemoryBudget`
regimes wave count grows (~25 waves on 1.3 GB / `in_flight_factor=1`),
so spawn overhead is ~0.5–3 ms total. Replace with a reused
`std.Thread.Pool` (or a `WaitGroup` + persistent worker set) so the
threads outlive a single wave. Watch out: workers must not retain
references to per-wave `StripeWork` slices across waves.

### Stream-mode RSS audit on adversarial inputs

File mode is now bounded to ~`in_flight_bytes + wave_bytes` peak RSS
(0.23× input on the 1.3 GB benchmark). Stream mode (`submit_stream`)
reports 7 MB on the standard JSONL workload but has not been stress-
tested on adversarial inputs: huge single-line records, huge batches
that exceed `InFlightLimiter` slot budgets, or producer/consumer rate
imbalance that piles up in `JobQueue`. Run `/usr/bin/time -f "rss=%MKB"`
across:
- 100 MB single-line JSON
- 1 GB JSONL piped via `cat` at line rate
- adversarial pretty-printed multi-line batches
Confirm stream RSS stays bounded by `chunk_size × in_flight_factor + 1
batch`, or wire wave-dispatch's bounding strategy into the stream path.

### SSOT: LSP server bypasses typed protocol structs

`src/lsp/protocol.zig` defines `TextDocumentItem`,
`VersionedTextDocumentIdentifier`, `TextDocumentContentChangeEvent` per
the LSP spec. `src/lsp/server.zig` parses `didOpen`/`didChange`/
`didClose` payloads ad-hoc via `getString` / `getObject` helpers (see
L230-260 for didChange). Wire payload parsing through the typed structs
so the LSP wire format has a single source of truth.

### Feature gap: completion floods all builtins

`src/lsp/features/completion.zig:addBuiltinCompletions` emits all 134
builtins flat regardless of context. `src/lsp/builtins.zig:byCategory`
is the correct primitive for category-aware filtering but is never
called. Wire `byCategory` (or richer scoring) into completion so
results match the cursor context.

