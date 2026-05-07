# Phase 0 — Per-stage microbench harness (design)

Status: **landed** (2026-04-23).
Source: `src/microbench/main.zig`, hook surface `src/microbench/hooks.zig`.
Build step: `zig build microbench` (gated; not in `test_step`).

## Why this exists

Production performance work needs per-stage attribution. Wall-time end-to-end
measurements tell you "zq is 30% slower on workload X" but not *where* — parse,
value lookup, predicate evaluation, output serialization, or worker
coordination. Without that breakdown, every optimization attempt is guesswork.

Earlier work lived in a now-removed `src/microbench.zig` that produced the
historical per-record numbers (parse 1.30 µs / lookup 0.32 µs / output
0.38 µs). Those numbers are NOT reproducible from the current tree. This
redesign rebuilds that capability from zero, on two explicit invariants:

1. **Single source of truth.** The harness drives the same
   `parser.Parser` / `query.CompiledQuery` / `output.serialize` that
   production drives. No bench-only forks of the hot code.
2. **Zero-cost when disabled.** When built with the default `-Dprofile=false`,
   the comptime hook interface compiles to nothing. Production binary size,
   disassembly, and behavior are identical to pre-microbench commits.

## The five phases

Each phase is measured in isolation, one record at a time, after a warmup
pass. The boundaries correspond to the production pipeline stages already
visible in `src/pool/root.zig:process_line_serialized`.

| Phase       | What it measures                                                   | Production analog                                          |
|-------------|--------------------------------------------------------------------|------------------------------------------------------------|
| `parse`     | `parser.feed(line, true)` — bytes → Tape                           | `src/pool/root.zig:780-801` (Parse block)                  |
| `lookup`    | `query.execute(tape, …)` — bind tape, allocate eval stack          | `src/pool/root.zig:804-820` (Bind/rebind ResultIterator)   |
| `predicate` | `iterator.next()` — run VM to first/next result                    | `src/pool/root.zig:826` (inside serialize loop)            |
| `serialize` | `output.serialize(sink, value, …)` — Value → JSON bytes            | `src/pool/root.zig:840` (serialize call)                   |
| `coord`     | Full per-record loop: parse+lookup+predicate+serialize+reset       | `src/pool/root.zig:744` (whole body of `process_line_serialized`) |

`coord` minus the sum of the first four is the per-record
coordination/reset/teardown overhead.

## Measurement methodology

- **Clock**: `std.time.Timer` (monotonic, nanosecond resolution on Linux; wraps
  `clock_gettime(CLOCK_MONOTONIC)` under the hood — no RDTSC portability bug).
- **Warmup**: 1 000 iterations per phase before measurement begins. Drains
  branch-predictor cold state and allocates the iterator / parser / sink
  buffers so they're present for the measured passes.
- **Sample count**: configurable via `--iterations N` (default 10 000).
  Samples are stored in a pre-allocated `[]u64`; no allocations in the hot
  path.
- **Counter-overhead subtraction**: before each phase, a calibration loop
  runs `N` empty `timer.reset(); _ = timer.read();` pairs and records the
  median. That median is subtracted from every measured sample. Negative
  results clamp to 0.
- **Statistical summary**: mean, p50 (median), p90, p99, min, max — all
  computed after sorting samples ascending. Standard deviation is not
  emitted (useless for the heavy-tailed distributions a syscall path
  produces; percentiles are the right summary).
- **No I/O during measurement**: all records are pre-loaded into memory
  before the timing window opens. `parser.reset()` is called after every
  parse sample so the tape buffer state matches the production per-record
  cycle. The serialize sink uses a heap-allocated `std.ArrayList(u8)` that
  is `clearRetainingCapacity()`-reset per sample — the first warmup
  iteration pays the allocation cost; later samples see reuse.

## `-Dprofile` flag semantics

```
zig build microbench                      # profile=false (default). Builds the
                                          # harness but the in-module hook
                                          # functions expand to no-ops.
zig build microbench -Dprofile=true       # profile=true. Hook functions compile
                                          # to real counter increments that the
                                          # harness reads.
```

- Production binary (`zig-out/bin/zq`) is unaffected by `-Dprofile`. The flag
  is only consulted by the `microbench_hooks` module, which no production
  module re-exports. Stable equivalence is verified by a binary-size
  assertion in the landing commit.
- `-Dprofile=true` is opt-in; it's *not* enabled by `just test`,
  `zig build test`, or `zig build`. This avoids accidentally perturbing
  production benchmarks.

### Hook interface

`src/microbench/hooks.zig` exposes one function:

```zig
pub fn markPhase(comptime tag: PhaseTag) void { … }
```

With `profile=false` the body is `comptime return;` — the compiler erases
every call site. With `profile=true` the body increments a thread-local
counter (for future use — the harness itself doesn't need them because it
times phase boundaries at the call site, but the hooks exist so in-flight
work that *does* need a marker during production execution has a stable
API).

Production call sites are intentionally minimal: zero today. The harness
drives the production modules from outside; the hook surface exists as the
public API for future in-flight probes (e.g. when we need to attribute
time spent in a nested VM opcode). Adding a hook call is a one-line change
that compiles to nothing when disabled.

## Dataset fixtures

The harness does not ship its own fixtures. It reuses what the repo
already has:

- `benchmarks/data/huge.jsonl` (1.3 GB, 15 M records) — the primary
  long-form workload.
- `benchmarks/data/tiny.json` — smoke-test fixture.
- `tests/compat/` records (small hand-written JSONL) — when a specific
  filter-shape matters.

Call sites pass fixtures via `--dataset <path>`. The harness reads the
file into memory once at startup, splits on `\n`, and iterates that
in-memory array during the measurement window.

For smoke testing, the harness accepts a `--inline '<record>'` option that
skips the dataset read entirely and uses the provided JSON object as the
single record. This is what the landing commit uses to verify the
end-to-end NDJSON output.

## CLI

```
zig build microbench -Dprofile=true -- \
    [--dataset <path>]                  # JSONL file; overrides --inline
    [--inline '<json>']                 # single-record smoke fixture
    [--filter '<expr>']                 # default: ".id"
    [--iterations N]                    # default: 10 000
    [--warmup N]                        # default: 1 000
    [--phases parse,lookup,…]           # default: all five
    [--style <axes>]                    # +-separated: compact, raw, join, pretty (default: compact)
```

Exactly one of `--dataset` or `--inline` must be supplied. The harness
asserts the filter compiles cleanly; a compile error aborts before any
measurement.

## Output format: NDJSON v2.0

Each phase emits exactly one NDJSON object to stdout. Stderr carries only
status/warnings. The schema is stable; agents consuming this output can
rely on every field being present for every row.

```jsonl
{"schema":"zq.microbench.v2","phase":"parse","zq_rev":"eae7af7","zig_version":"0.15.2","os":"linux","arch":"x86_64","cpu_model":"…","dataset":"benchmarks/data/huge.jsonl","record_count":15000000,"filter":".id","style":{"compact":true,"raw_strings":false,"join":false},"iterations":10000,"warmup":1000,"overhead_ns":12,"ns_mean":1328.4,"ns_p50":1310,"ns_p90":1420,"ns_p99":1815,"ns_min":1280,"ns_max":9422,"total_ns":13284000,"timestamp_utc":"2026-04-23T12:00:00Z"}
```

### Field reference

| Field            | Type     | Meaning                                                       |
|------------------|----------|---------------------------------------------------------------|
| `schema`         | string   | Always `"zq.microbench.v2"`. Agents key on this.              |
| `phase`          | string   | One of `parse` / `lookup` / `predicate` / `serialize` / `coord`. |
| `zq_rev`         | string   | Short git SHA of the source tree (`git rev-parse --short HEAD`). |
| `zig_version`    | string   | Compiler version.                                             |
| `os`             | string   | `@tagName(builtin.os.tag)` (linux / macos / …).               |
| `arch`           | string   | `@tagName(builtin.cpu.arch)`.                                 |
| `cpu_model`      | string   | `builtin.cpu.model.name`.                                     |
| `dataset`        | string   | Dataset path or `<inline>`.                                   |
| `record_count`   | number   | Records loaded from the dataset (1 for `--inline`).           |
| `filter`         | string   | Filter source.                                                |
| `style`          | object   | `{compact:bool, raw_strings:bool, join:bool}` — output style for the serialize phase. Additive: future axes append new fields without breaking existing consumers. |
| `iterations`     | number   | Sample count.                                                 |
| `warmup`         | number   | Warmup iterations (not included in samples).                  |
| `overhead_ns`    | number   | Subtracted per-sample counter-read overhead.                  |
| `ns_mean`        | number   | Arithmetic mean of samples (after overhead subtraction).      |
| `ns_p50`         | number   | 50th percentile (median).                                     |
| `ns_p90`         | number   | 90th percentile.                                              |
| `ns_p99`         | number   | 99th percentile.                                              |
| `ns_min`         | number   | Minimum.                                                      |
| `ns_max`         | number   | Maximum.                                                      |
| `total_ns`       | number   | Sum of samples (after overhead subtraction).                  |
| `timestamp_utc`  | string   | ISO-8601 UTC second of the run.                               |

Agents can pipe output straight through `jq` or `zq`:

```
zig build microbench -Dprofile=true -- --iterations 10000 \
  | zq '. | select(.phase=="parse") | .ns_p50'
```

## Sink: stdout

Results land on stdout as NDJSON, one object per phase. Stdout is chosen
over an on-disk `research/results/<ts>.ndjson` sink because:

- Composes with `jq` / `zq` / `sqlite3 :memory:` / etc. without extra
  ceremony.
- The caller decides whether/where to persist by redirecting.
- CI harnesses can capture stdout directly.

Persistent archives live under `research/results/` *by convention*, not
by harness behavior. The landing commit documents the convention but
doesn't enforce it.

## Initial measurements (smoke test — 2026-04-23, meteorlake x86_64-linux)

Filter `.id`, dataset = first 100 lines of `benchmarks/data/huge.jsonl`,
10 000 iterations, warmup 1 000, ReleaseFast. Counter-overhead ≈ 22 ns.

| Phase       | ns_p50  | ns_p90  | ns_p99  |
|-------------|---------|---------|---------|
| parse       | 352     | 446     | 463     |
| lookup      | 12 191  | 15 188  | 17 394  |
| predicate   | 44      | 47      | 62      |
| serialize   | 0       | 0       | 0       |
| coord       | 417     | 480     | 526     |

Interpretation:

- `parse` dominates the coord budget (352 ns of 417 ns coord p50, ≈84%).
  Matches the historical 1.3 µs figure scaled down by the smaller records.
- `lookup` at 12 µs is the per-`execute()` cost including eval stack
  allocation + iterator init. Production amortizes this across every
  record in a chunk via `it.reset()` — which is why the `coord` phase
  (iterator reused) runs three orders of magnitude faster.
- `predicate` at 44 ns is one `it.next()` to produce `.id`.
- `serialize` below counter-overhead (22 ns). Integer serialization of
  one digit is a single `writeSlice`; unsurprising. Larger values exercise
  the code more.
- `coord` measures the full production hot path minus worker-pool /
  Sequencer overhead.

Regressions will be gated against these numbers by a future CI step (not
in scope for this landing).

## Non-goals

- **Not** a user-facing benchmark. `just bench` remains wired to
  `bench-regex`. A future `just microbench` recipe may shell into this
  harness, but `just bench`'s semantics stay stable.
- **Not** a replacement for `hyperfine` end-to-end comparisons. This
  harness attributes time *within* a single-threaded pipeline; it
  deliberately disables the worker pool, the mmap/chunk feeder, and the
  Sequencer. Those components get their own measurement story.
- **Not** multi-threaded. Coordination/backpressure costs surface in the
  `coord` phase as reset overhead; the full concurrent pipeline is a
  separate Phase 2 topic.
