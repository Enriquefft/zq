# TODO

Items known to be unfinished but not yet promoted to `ROADMAP.md`. Each entry
should move to `ROADMAP.md` (if becoming a milestone goal) or to `bugs.md` (if
it turns into a named defect) as it matures. Delete entries as they resolve.

Last verified: 2026-05-05.

## Active

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

### Perf bug: complex_query benchmark — zq ~7x slower than jq at 1M records

CI benchmark run https://github.com/Enriquefft/zq/actions/runs/25457229652
exposed a large slowdown in `benchmarks/scenarios/05_complex_query.sh`
on a 1M-record dataset. Old 15M-record baseline amortized the cost and
hid it; the new regression mode (1M records) makes it dominant.

Numbers (Ubuntu GH runner, ZQ_QUICK=1, 3 runs):

  jq 1.7.1: 4.99s ± 0.03
  zq:       34.80s ± 1.66   (User: 9.0s, System: 38.7s, elapsed 35s)

System ≫ user time → syscall-bound, not CPU-bound. Other scenarios on
the same 1M dataset behave normally (parallelism `.id` zq=0.31s,
streaming `.id` zq=0.37s), so the regression is specific to this query
shape.

Query:

  {id: .id,
   mod3: (.id % 3),
   big:  (.id > 7500000),
   kind: (.values // .meta // .data // "none" | type)}

Suspects (in rough order of likelihood):
  - per-record allocator thrash (mmap/munmap on every chunk)
  - parallel chunking misconfigured for short-record workloads → thread
    thrash, lock contention
  - alternative-operator chain backtracking (`.values // .meta // .data
    // "none"`) re-walks the value
  - `type` builtin slow path

Local repro on a freshly built `zig-out/bin/zq`:

  HUGE_LINES=1000000 bash benchmarks/data/huge.generator.sh
  time zig-out/bin/zq -c \
    '{id:.id, mod3:(.id%3), big:(.id>7500000),
      kind:(.values // .meta // .data // "none" | type)}' \
    benchmarks/data/huge.jsonl > /dev/null

Bisect candidates: try simplifying the query one element at a time
(drop `kind`, drop `big`, drop `mod3`) and watch where the cliff
appears. Also profile with `perf stat -e syscalls:sys_enter_*` to
identify the dominant syscall.
