# Phase 0 Design — Evaluation Harness

> Status: design, not yet implemented.
> Owner: research track, Phase 0.
> Spec source: [`RESEARCH_ROADMAP.md`](../RESEARCH_ROADMAP.md) "Phase 0", "Paper 1
> — JSONQBench", "Cross-Cutting Infrastructure".
> Quality bar: [`CLAUDE.md`](../CLAUDE.md) — production-only, single source of
> truth, no workarounds.

This document is the contract Phase 0 will be built against. It defines the
evaluation harness that simultaneously serves as (a) the engineering regression
gate for every subsequent optimization and (b) the experimental infrastructure
for Paper 1 (JSONQBench) and the ablation tables of every subsequent paper.

The design is a single tool, a single result format, a single runner — the
single-source-of-truth requirement is non-negotiable.

---

## 0. Scope and Non-Goals

### In scope
- Cross-system multi-runner extending `benchmarks/run_all.sh` to ≥8 systems.
- Microbench attribution model rebuilt as a first-class build target.
- Five-domain workload corpus replacing the lone `huge.jsonl` generator.
- Deterministic synthetic generator that sweeps individual axes.
- Machine-readable result schema with a query interface for the paper writer.
- CI gating policy that uses one harness for both PR gating and paper data.
- Statistical methodology with documented outlier policy.
- Reproducibility checklist tied to the existing Nix flake.

### Out of scope (explicit deferral)
- The parse-plan IR (Phase 1).
- Any optimization PR (Phases 2+).
- Hosting / publication of the result database (Phase 0 produces it locally
  and in CI artifacts; long-term hosting is a Paper 1 publication concern).
- Cloud-only / serverless JSON systems (Athena, BigQuery). See §3 for the
  reasoned exclusion.

---

## 1. Inventory — what exists today

| Artifact | Path | Covers | Does not cover |
|---|---|---|---|
| Benchmark runner | `benchmarks/run_all.sh` | Orchestrates 5 scenarios; emits per-scenario `.md`/`.json` and a v1.0 `summary.json`. | Hardcoded to 4 systems (zq/jq/jaq/gojq), 1 dataset, 1 query per scenario. No microbench, no matrix. |
| Common utilities | `benchmarks/common.sh` | Hyperfine presets (warmup 2 / runs 10; quick mode 1 / 3), tool detection, correctness helper. | No statistical post-processing (no p99, IQR, CI). Quick mode is a single boolean. |
| Progress UI | `benchmarks/progress.sh` | ANSI progress / timers / spinner on stderr. | Fit for purpose. |
| Scenario 1 parallelism | `benchmarks/scenarios/01_parallelism.sh` | `.id` over `huge.jsonl` for jq/jaq/zq. | Excludes gojq (inconsistent with 04/05); 1 query, 1 dataset. |
| Scenario 2 memory | `benchmarks/scenarios/02_memory.sh` | `/usr/bin/time -v` for `select(.id > 500000)`; emits `mean`/`max_rss_kb`. | gojq excluded; one query; RSS only. |
| Scenario 3 startup | `benchmarks/scenarios/03_startup_latency.sh` | `--warmup 0 --shell=none` 100 runs of `.a` on `tiny.json`. | Only place yq appears. No syscall breakdown. |
| Scenario 4 streaming | `benchmarks/scenarios/04_streaming.sh` | `cat file \| tool '.id'` for jq/jaq/gojq/zq + correctness check. | One query, one file. No selectivity / file-size / core sweeps. |
| Scenario 5 complex | `benchmarks/scenarios/05_complex_query.sh` | Object construction + arith + cmp + alternative + type. | One query, one file. |
| Regression checker | `benchmarks/check_regression.sh` | Ratio `zq_mean/jq_mean` vs baseline ratio, 15% threshold. | jq-anchored — not extensible to a non-jq universe. No significance test. |
| Generator (real) | `benchmarks/data/huge.generator.sh` | 15 M JSONL records, 7 hand-coded shapes. ~650 MB. | One synthetic; no real corpora; no axis sweep. |
| Generator (malformed) | `benchmarks/data/malformed.generator.sh` | 100 lines: 90 valid + 5 truncated + 5 syntax errors. | Tiny, not wired into a streaming-error scenario. |
| Tiny fixture | `benchmarks/data/tiny.json` | `{"a":1}` for startup latency. | — |
| Reference baseline | `benchmarks/baseline.json` | Developer-machine snapshot 2026-03-18, v1.0 schema. | Not used by CI (CI keeps its own cache). Manual. |
| CI bench workflow | `.github/workflows/benchmark.yml` | PRs / main / tags / weekly cron. Pinned hyperfine 1.18.0, jaq 2.1.0, gojq 0.12.17. Cache-tracked baseline. Quick mode only. | Linux x86_64 only. No ARM, no microbench, no matrix, no statistical hardening. |
| CI test workflow | `.github/workflows/ci.yml` | `zig fmt`, `zig build test`, cross-compile to 6 targets. | Does not run benchmarks. |
| Nix flake | `flake.nix` | Rolling `nixos-unstable` (no rev pin). `zig`, `zls`, `hyperfine`, `jq`, `jaq`, `yq`, `just`, `vhs`, `nodejs`. | Not actually reproducible. Missing `gojq`, `simdjson`, `duckdb`, `clickhouse`, `polars`. Not used by CI. |
| Justfile microbench target | `justfile:19-21` | `just bench` → `zig build && ./zig-out/bin/microbench`. | Binary does not exist; `build.zig` has no microbench target; `src/microbench.zig` is gone. Dead. |
| Project memory note | `MEMORY.md` "Microbench Tool" | Claims `/src/microbench.zig` exists with phase split. | Stale. The file is gone. |

**Honest finding.** The microbench is the single most important Phase 0
deliverable that has no scaffolding to extend. The justfile target is dead
code. We are rebuilding it from zero (§4).

**Honest finding.** The Nix flake uses `nixos-unstable` without a flake.lock
review and pulls a *rolling* nixpkgs. Reproducibility today is "best effort,"
not "byte-identical." Phase 0 must fix this.

**Honest finding.** The current regression checker is jq-anchored. It cannot
gate a multi-system harness without redesign — not because the math is wrong
but because it presumes one comparator. We replace it with a per-system
self-baseline gate (§7).

---

## 2. Gaps vs Phase 0 requirements

| Phase 0 requirement | Present today | Missing | How it gets closed |
|---|---|---|---|
| Multi-system runner (≥8 systems) | 4 systems (zq/jq/jaq/gojq) | simdjson+query layer, DuckDB `read_json`, ClickHouse JSON funcs, Polars JSON | §3 — one runner with system adapters; each adapter is a tiny Bash file under `benchmarks/systems/<name>.sh`, all consumed by `benchmarks/runner.sh` (replaces `run_all.sh`). |
| Microbench attribution (parse/lookup/predicate/serialize/coord) | Nothing — broken `just bench` target | Entire tool, build target, output schema, integration | §4 — new `src/microbench/main.zig`, dedicated `microbench` exe in `build.zig`, ReleaseFast-only, opt-in `Dprofile=true` build flag for compile-time hooks. |
| Workload corpus (5 domains) | 1 synthetic (`huge.jsonl`) + 1 malformed | API / logs / configs / geospatial / scientific | §5 — `benchmarks/corpus/<domain>/`, plus a deterministic synthetic axis-sweep generator at `benchmarks/corpus/synthetic/`. |
| Scalability sweep matrix (cores, file size, record size, selectivity, depth) | None | Entire matrix runner, result aggregation, plotting input | §3 + §6 — sweep is a runner mode (`runner.sh sweep`), result rows include matrix coordinates. |
| Machine-readable results | Per-scenario `.json` + flat `summary.json` v1.0 | Schema with system_version, sha, hardware_id, run_index, percentiles, microbench phases, dataset_version | §6 — results stored as line-delimited JSON (`results.ndjson`) with documented schema v2.0; DuckDB views for the paper writer. |
| CI gating that posts ablation row | Ratio gate vs jq, no PR comment | Per-system self-baseline gate, statistical significance, PR comment with diff table | §7 — replace `check_regression.sh` with `check_regression_v2.sh` that compares per-system absolute throughput against the cached self-baseline using a two-sided test. |
| Statistical methodology (warmup, runs, outliers, CI) | Hyperfine warmup 2, runs 10; no IQR; no CI | Documented outlier policy, p99 reporting, confidence intervals, hardware control | §8 — documented and enforced in `benchmarks/common.sh`; per-system pre-pinning (`taskset` / `nice`); minimum-of-N reporting in addition to mean. |
| Reproducibility (Nix pin, dataset version, hardware) | Flake exists but rolling; no lock review; no dataset version | flake.lock pinning, dataset content hash, hardware_id derivation | §9 — explicit `flake.lock` commit, `corpus/MANIFEST.json` with sha256 per file, `hardware_id = sha256(/proc/cpuinfo + /proc/meminfo + uname)`. |

---

## 3. Multi-system runner extension

### Architecture

Replace `benchmarks/run_all.sh` with a layered runner:

```
benchmarks/runner.sh                # entry point — orchestration only
  └─ benchmarks/systems/<system>.sh # one adapter per system
  └─ benchmarks/queries/<class>/    # one file per query class
  └─ benchmarks/corpus/<domain>/    # datasets + manifest
  └─ benchmarks/results/            # ndjson result rows + DuckDB view
```

Every system adapter exposes the same shell interface — three functions:

```sh
system_name()              # printable name (e.g. "duckdb")
system_version()           # `duckdb --version | head -1`
system_sha()               # binary sha256 (`sha256sum $(which duckdb) | cut -d' ' -f1`)
system_invoke FILE QUERY   # prints to stdout the exact shell command line
                           # the runner will hand to hyperfine
```

The runner discovers adapters with `find benchmarks/systems -name '*.sh'`.
Adding a system is one new file. Removing one is `git rm`. No central
registry. This is the single-source-of-truth principle applied to system
membership.

### Per-system specification

| System | Invocation | Equivalence vs jq | Streaming? | File mode? | Inclusion |
|---|---|---|---|---|---|
| **jq** | `jq -c <Q> <F>` | Reference | Yes (stdin) | Yes | Always — anchor system. |
| **jaq** | `jaq -c <Q> <F>` | Same jq language; `-c` for compact output to match | Yes | Yes | Always. |
| **gojq** | `gojq -c <Q> <F>` | Same | Yes | Yes | Always. |
| **zq** | `zq -c <Q> <F>` | Same | Yes | Yes | System under test. |
| **simdjson + thin query layer** | `simdjson_zq_bridge <Q> <F>` (see below) | Equivalent to projection-only and predicate-only queries. **Cannot** evaluate full jq. | File only — simdjson_padded_string_view requires aligned bytes. | Yes | Conditional inclusion: only on the projection / predicate / scalar-extraction query classes. Marked `n/a` on full-jq classes. |
| **DuckDB `read_json`** | `duckdb -c "SELECT json_extract(x, '$Q') FROM read_json('<F>', auto_detect=true);"` (where `Q` is the equivalent JSONPath) | Approximates field extraction and predicate; cannot do jq-specific constructs (`alternative //`, `to_entries`). | No (file only) | Yes | Always on the queries that translate. Marked `n/a` otherwise. |
| **ClickHouse `JSONExtract*`** | `clickhouse local -q "SELECT JSONExtractString(line, '$F') FROM file('<F>', JSONEachRow, 'line String')"` | Field extraction + scalar predicates. Limited path syntax. | No | Yes | Always on translatable queries. |
| **Polars JSON** | `python -m benchmarks.runners.polars_runner --query <Q> --file <F>` | Full DataFrame ops; covers field extraction, filter, project. No jq alternative `//`. | No | Yes | Always on translatable queries. |

#### simdjson query layer — recommendation

Build a **thin native bridge**, not a full query engine. The bridge is:

- A single C++17 source file at `benchmarks/systems/simdjson_bridge/main.cpp`.
- Compiles against `simdjson` from Nix (pinned).
- Accepts a tiny query DSL covering exactly four classes: `field`,
  `field.subfield`, `field > N`, `select(field op N) | .other`.
- Built once via `nix develop -c make -C benchmarks/systems/simdjson_bridge`.
- Adapter `benchmarks/systems/simdjson.sh` invokes the resulting binary.

**Why a bridge instead of "use simdjson directly":** simdjson is a parsing
library, not a query tool. Pretending it competes with jq on full jq queries
is dishonest; pretending it doesn't compete on extraction queries is also
dishonest. The bridge resolves both — we measure simdjson on exactly the
class of queries where the comparison is valid, and we explicitly mark it
`n/a` everywhere else. Reviewer attack "you cherry-picked simdjson's
strengths" is mitigated by the explicit query-class restriction.

**Alternative considered:** ship no simdjson at all. Rejected — simdjson is
the obvious reviewer-asked-for baseline; omitting it is worse than including
it with documented restrictions.

**Alternative considered:** use simdjson's `ondemand` API embedded as a
worker in zq. Rejected — that would be a comparison against ourselves, not
against simdjson as a system.

### Inclusion criteria (paper-facing)

A system is in the suite iff *all* of:

1. Open source, redistributable license.
2. Either (a) jq-language compatible, (b) ships a documented JSON query API
   that maps to at least the field-extraction class, or (c) a parsing library
   we wrap with a documented thin query layer (only simdjson, today).
3. Runs unattended from the command line on a Nix-pinned version.
4. Produces output that is mechanically comparable to jq's output for at
   least one query class.

### Out of scope — and why

| Excluded system | Why |
|---|---|
| Athena, BigQuery, Snowflake | Cloud-only. Different cost model (network round trips, cold starts, billing units). Not reproducible by external readers. Reviewers expect a fair single-machine comparison; cloud systems are a separate paper. |
| Spark `spark.read.json` | Heavyweight runtime. Startup dominates fair-comparison cells; the paper is not about JVM warmup. Polars covers the analytical-engine slot already. |
| MongoDB / Couchbase aggregation | Database servers, not query processors. Different operational class. |
| Pandas `read_json` | Subsumed by Polars (faster, same surface, same Python invocation pattern). Including both is redundant. |
| `yq` | Already excluded from JSONL scenarios in the current suite (can't handle multi-record). Excluded from the new harness for the same reason; included only on Scenario "single-document YAML/JSON" if we add one (we don't, yet). |
| Custom in-house tools | Not reproducible by readers. |

The "why" column above is what we put in the paper's exclusion paragraph. It
is the reviewer-attack mitigation in §1.

### Version pinning

All benchmarked systems pinned via the Nix flake. The flake adds:

```nix
buildInputs = with pkgs; [
  jq jaq gojq simdjson duckdb clickhouse polars-cli
  hyperfine bc python3Packages.polars
];
```

The runner records `system_version` and `system_sha` for *every* row at
runtime — so even if the flake.lock drifts, the result data is
self-describing.

---

## 4. Microbench attribution model

### Goal

Per-record cost split into five phases, measured with overhead < 5% of
baseline cost on the queries we care about:

1. **parse** — `parser.feed(...)` from byte input to a complete tape entry.
2. **lookup** — `ResultIterator` advancement that walks the tape to materialize
   the values referenced by the query (the `load_path` phase, after fuse).
3. **predicate** — VM bytecode execution from value-on-stack to first
   selection / arithmetic / comparison verdict.
4. **serialize** — `output.Writer.write_value` / `BufferSink` writing.
5. **coord** — pool orchestration: chunk splitting, in-flight limiter
   blocking, sequencer post/next, atomic arena release.

These boundaries are chosen because they correspond exactly to module
boundaries already in the tree. They are *not* invented for the harness; they
are visible in `ARCHITECTURE.md` "Data Flow":

| Phase | Module(s) | Functions |
|---|---|---|
| parse | `src/parser/src/parser.zig`, `simd.zig` | `Parser.feed`, `Parser.classify_chunk` |
| lookup | `src/query/src/vm.zig` | `ResultIterator.next`, `load_path` opcode dispatch |
| predicate | `src/query/src/vm.zig` | All non-`load_path` opcode dispatches inside `next` |
| serialize | `src/output/root.zig` | `Writer.write_value`, `BufferSink.write_value` |
| coord | `src/pool/root.zig` | `submit_file`, `submit_stream`, `Sequencer`, `InFlightLimiter` |

### Where the microbench lives

**File:** `src/microbench/main.zig` (new file, new directory).

Why a directory: the microbench will grow scenario files (`scenarios/`),
phase counters (`phases.zig`), and a result writer (`writer.zig`). One file
becomes unmaintainable.

**Build target:** `build.zig` adds an `exe_microbench` artifact in addition
to `exe`. It is gated behind a step (`zig build microbench`) so it does not
ship in default `zig build` (no risk to user-visible binaries) but is built
unconditionally in CI's microbench job. The `justfile` `bench` target updates
to `zig build microbench -Doptimize=ReleaseFast && ./zig-out/bin/microbench`.

**Imports:** the microbench module imports the same modules as `exe`:
`error`, `types`, `io`, `parser`, `query`, `output`, `pool`. It is not
a separate parallel implementation — that would violate single-source-of-truth.
It is an *instrumented driver* of the same modules.

### Instrumentation strategy — *compile-time hooks*, not sampling

Instrumented build is a separate compile flag, **not** runtime branching:

```zig
const profile = b.option(bool, "profile", "Enable phase profiling") orelse false;
options.addOption(bool, "profile", profile);
```

In each module hot path, a `comptime` branch:

```zig
if (build_options.profile) phase_counters.enter(.parse);
defer if (build_options.profile) phase_counters.exit(.parse);
```

When `profile=false` (the default and the shipped binary), the branch
compiles to nothing — zero overhead, zero ABI change, zero risk to the
production path. When `profile=true`, the microbench binary picks up the
counters via a global `phase_counters` thread-local.

**Why compile-time, not runtime feature flag:**
- Runtime flags add a per-call branch on the hot path — visible at
  microsecond cost on `.id` queries (current cost ~2 µs/record).
- Comptime branch elision is the only way to honestly measure overhead at
  this scale.
- Ships zero risk to the user binary — the production build never sees the
  counter code.

**Why not sampling (perf, eBPF):**
- Sampling at sub-microsecond granularity is unreliable; the kernel sample
  rate is 1 ms, the events we care about are 100–2000 ns.
- Sampling cannot distinguish "lookup" from "predicate" inside the same VM
  function — both are inside `ResultIterator.next` and both touch the same
  cache lines.
- A targeted instrumentation strategy gives clean attribution; sampling
  gives a flame graph that mixes phases.

### Avoiding measurement distortion

Three mechanisms:

1. **Counters are thread-local `u64` deltas, not allocations.**
   `enter(.parse)` reads `rdtsc` (or `clock_monotonic_raw` fallback), stores
   it in a per-thread frame stack. `exit` reads again and accumulates the
   delta into the per-thread phase totals. No mutex, no atomic, no syscall.
2. **No I/O during measurement.** Counters are flushed once at the end of
   the run, not per record.
3. **Warmup-then-measure with iteration count adjustment.** The microbench
   runs each scenario for N records of warmup (default 10 000), then for
   M records of measurement (default 100 000). The output reports
   per-record means and the per-phase share. M is auto-tuned so the run
   takes 1–5 seconds — too short loses statistical resolution, too long is
   wasted CI time.
4. **Counter-overhead cell.** A "no-op profile" cell measures
   `enter(.parse) + exit(.parse)` paired with an empty body. This cost is
   subtracted from every reported phase — so the reported numbers are *net*
   of the instrumentation overhead. The cell also serves as a regression
   tripwire: if counter overhead drifts above 50 ns/call, the harness
   refuses to run and the microbench is rebuilt.

### Output schema (microbench result row)

One row per (scenario × system × dataset × query) cell, written to
`benchmarks/results/microbench.ndjson`. Schema is the same as §6's main
result schema with `kind="microbench"`, the `ns_per_record_*` columns
populated, and the percentile columns null (microbench is a single
high-resolution run, not a hyperfine sweep).

`ns_per_record_coord` is zero on the single-threaded microbench cells; it
is non-zero only on the parallel microbench cell (a separate scenario that
submits the same data through `pool.submit_file`).

### Integration with the regression checker

The microbench attribution row is consumed by the same regression checker
as the hyperfine rows (§7). A regression in any *phase* triggers a CI
warning, even if the total time is within tolerance — because a phase
regression is a leading indicator of a future total regression that the
hyperfine resolution can't see yet.

Microbench rows are always per-system; we never compare microbench cost
across systems (the instrumentation is zq-internal). The checker only
compares `zq` microbench rows against the cached `zq` microbench baseline.
This is the correct call: there is no honest way to instrument jq's
internals, so cross-system phase attribution would be guessing.

### Rebuilding the microbench

The dead `justfile` `bench` target and the missing `src/microbench.zig` are
fixed in this order:

1. Create `src/microbench/main.zig` skeleton, `phases.zig`, `writer.zig`.
2. Add `microbench` build target to `build.zig` (gated behind
   `zig build microbench`, behind `-Dprofile=true`).
3. Add comptime hooks to `parser`, `query`, `output`, `pool`. Each is a
   one-line `if (build_options.profile) phase_counters.{enter,exit}(.X)`.
4. Add `phase_counters` import to each instrumented module via the same
   `build_options` mechanism that already exists for the version string.
5. Update `justfile` `bench` target to the new build invocation.
6. Add a `microbench` job in `.github/workflows/benchmark.yml` (separate
   job — runs less frequently, not on every PR).

This is the only Phase 0 deliverable that touches `src/`. Everything else
is in `benchmarks/`. The touch is additive (new files + comptime-zero
branches) and gated by an opt-in build flag, so the production binary is
unchanged.

---

## 5. Workload corpus

### Layout

```
benchmarks/corpus/
  MANIFEST.json                 # one entry per file: {path, sha256, bytes, source, license}
  api/
    github_events.jsonl         # real
    twitter_sample.jsonl        # real or substitute
    rest_collection.jsonl       # real
    queries/                    # *.jq files — domain-canonical queries
  logs/
    cloudwatch.jsonl            # real or sanitized
    elk_app.jsonl               # real or sanitized
    queries/
  configs/
    terraform_plan.json         # real
    k8s_manifests.jsonl         # real
    package_json.jsonl          # real
    queries/
  geospatial/
    countries.geojson           # real, public domain
    osm_pois.geojson            # real
    queries/
  scientific/
    exoplanets.jsonl            # real
    ml_metadata.jsonl           # real
    queries/
  synthetic/
    generator.py                # deterministic axis sweep
    queries/
```

### Per-domain dataset proposals

#### API responses

| Dataset | Provenance | License | Approx size | Characterization |
|---|---|---|---|---|
| GitHub Archive sample | `https://gharchive.org/` (1 hour of public events, snapshotted) | CC-BY 4.0 — redistributable | 200 MB / ~600 K records | Wide records (15–40 fields), depth 4–6, high schema homogeneity within event type, 7 distinct event types. |
| Mastodon sample | Mastodon `streaming/public` capture (always-runs default per OQ-B decision). | CC0 — fully redistributable. | 100 MB / ~400 K records | Wide, deeply nested, mixed string/array fields. The reproducible social-API workload. |
| Twitter sample (optional) | Twitter API v1 sample stream — *not publicly redistributable*. Manifest entry has `source: user_provided`; runner errors with "place file at <path>, sha256 must equal <expected>" if absent. | User-provided; not redistributed by us. | 100 MB / ~400 K records | Same shape as Mastodon. Supplementary cell for users who have credentials; paper figures use Mastodon as the primary. |
| REST API collection | OpenLibrary `/works` endpoint, ~50 K paginated responses, captured with `wget`. | OpenLibrary public domain (CC0). | 80 MB / ~50 K records | Heterogeneous record shapes within one file (the failure case for schema speculation). |

**License resolution (per OQ-B decision 2026-04-07):** Mastodon is the
always-runs default and the source of paper figures. Twitter is a
supplementary opt-in cell for users who have credentials; we never
redistribute it. The synthetic API generator (§5, synthetic) backs both up
if neither is available.

#### Application logs

| Dataset | Provenance | License | Approx size | Characterization |
|---|---|---|---|---|
| AWS CloudWatch sample | AWS public sample logs (`aws-public-blockchain` bucket access logs). | Apache 2.0. | 500 MB / 2 M records | Narrow records (5–10 fields), shallow nesting, ISO timestamps, high homogeneity. |
| ELK-style app logs | Elastic public sample dataset (`elastic/examples/Common Data Formats/nginx_logs`). | Apache 2.0. | 50 MB / 200 K records | Mid-width records, message field is a string, request path strings are heavy. |
| Loki public dump | Grafana Loki public test dataset. | Apache 2.0. | 100 MB / 300 K records | Tagged log lines, label sets, narrow records. |

#### Infrastructure configs

| Dataset | Provenance | License | Approx size | Characterization |
|---|---|---|---|---|
| Terraform plan corpus | OpenTofu open registry sample plans. | MPL 2.0. | 30 MB / 1 K plans (one big-ish JSON per file) | Deeply nested (10–15), single document, very heterogeneous within one document, "module" indirection. |
| `package.json` corpus | npm registry top-1000 packages, snapshotted. | individual package licenses; manifest data redistributable as fact. | 10 MB / 1 K records | Mid-depth, dependency-tree-shaped, lots of small string fields. |
| Kubernetes manifests | `kubernetes/examples` GitHub repo dump. | Apache 2.0. | 5 MB / ~500 small files | Many small files, exercise the file-mode-vs-streaming switching. |

#### Geospatial

| Dataset | Provenance | License | Approx size | Characterization |
|---|---|---|---|---|
| Natural Earth `countries.geojson` | naturalearthdata.com | Public domain. | 25 MB / 256 features | Deeply nested coordinate arrays (the worst case for nested-array parsing). |
| OpenStreetMap POI sample | Geofabrik regional GeoJSON export, single city | ODbL — share-alike, redistributable with attribution. | 200 MB / 500 K features | Wide property bags + nested geometry; common real-world stress test. |

#### Scientific

| Dataset | Provenance | License | Approx size | Characterization |
|---|---|---|---|---|
| NASA exoplanet archive | `exoplanetarchive.ipac.caltech.edu` JSON export | Public domain. | 10 MB / 5 K records | Mid-width, lots of nullable numerics, the `tonumber` / `null` failure modes. |
| ML model metadata | HuggingFace `/api/models` paginated dump | individual model licenses; metadata is fact-data and redistributable. | 50 MB / 200 K records | Heterogeneous, deeply nested config blobs, very long string fields. |
| Observatory event log | Vera Rubin Observatory (LSST) public alert sample | CC-BY 4.0. | 100 MB / 100 K records | Nested arrays of arrays — the multi-dimensional case. |

### Synthetic axis-sweep generator

A real corpus is necessary for paper credibility but insufficient for
controlled ablation. We complement it with a deterministic generator that
sweeps individual axes, holding all others constant:

**File:** `benchmarks/corpus/synthetic/generator.py` (Python — chosen for
readability of the parameter sweep code; the *generated* data is
deterministic and language-agnostic).

**Axes:**

| Axis | Values |
|---|---|
| `record_width` | 5, 10, 25, 50, 100, 250, 500 fields |
| `nesting_depth` | 1, 3, 5, 10, 20 |
| `selectivity` | 0.001, 0.01, 0.1, 0.5, 1.0 (fraction of records that pass the canonical predicate) |
| `string_ratio` | 0.0, 0.25, 0.5, 0.75, 1.0 (fraction of fields that are strings vs. numbers) |
| `schema_homogeneity` | 1, 2, 4, 8, 16 (number of distinct shapes the file cycles through) |
| `record_count` | 10 K, 100 K, 1 M, 10 M, 100 M |
| `seed` | 0..N (default 0) |

The generator emits files named `synthetic_w{width}_d{depth}_s{sel}_…
_seed{seed}.jsonl` and writes a manifest entry with the sha256. Files are
generated *on demand* by the runner — Phase 0 does not check 100 GB of
synthetic data into the repo.

**Why Python and not Zig:** the generator is run rarely (once per
hardware), never on the hot path. Python's `json` is fast enough, and the
parameter sweep loop is more readable than the equivalent Zig. This is the
one place in Phase 0 where readability beats performance.

**Why deterministic:** seed → identical bytes → identical sha256, so the
same generator on two machines produces byte-identical inputs and the
manifest matches across runs. This is the reproducibility floor.

### Per-domain canonical queries

Each domain's `queries/` directory has files named by query class:

- `extract.scalar.jq` — `.id`
- `extract.path.jq` — `.actor.login` (or domain equivalent)
- `extract.array.jq` — `.values[]`
- `predicate.scalar.jq` — `select(.count > 100)`
- `predicate.compound.jq` — `select(.created_at > "2024-01-01" and .type == "PushEvent")`
- `transform.simple.jq` — `{id, name}`
- `transform.complex.jq` — `{id, summary: (.title // .name // "untitled"), count: (.children | length)}`
- `aggregate.jq` — `[.[] | .count] | add` (slurp mode)
- `recursive.jq` — `[.. | numbers]`

These nine query classes form the JSONQBench query taxonomy. Each cell in
the result matrix is the cross-product of (system × dataset × query class
× scenario).

---

## 6. Result schema

### Format: line-delimited JSON (NDJSON)

**Recommendation:** NDJSON, with a DuckDB view layered on top for analysis.

**Alternative considered — Parquet:** Parquet is more compact and supports
column pruning, but:
- Writing it requires a Parquet library; NDJSON is `printf`.
- The result volume is small (≤10 MB per full sweep) — compression wins
  nothing.
- DuckDB reads NDJSON natively (`SELECT * FROM 'results.ndjson'`).
- NDJSON is grep-able and human-readable in CI logs.

**Alternative considered — single SQLite database:** SQLite needs a
schema migration tooling story. NDJSON is append-only and the schema
version field is in every row. Rejected.

**Alternative considered — multiple JSON files (current state):** the
current `summary.json` shape is per-scenario nested. Cross-system queries
require parsing dozens of files. Rejected for the new harness — one
appendable log is the right shape.

### Schema v2.0

Every row is a flat JSON object with these fields. Field types: `s` string,
`n` number, `b` bool, `null`-able fields explicitly marked.

| Field | Type | Meaning |
|---|---|---|
| `schema_version` | s | "2.0" — mandatory on every row |
| `kind` | s | `hyperfine` \| `microbench` \| `memory` |
| `timestamp` | s | ISO-8601 UTC of run start |
| `system` | s | adapter name (jq, jaq, gojq, zq, simdjson, duckdb, clickhouse, polars) |
| `system_version` | s | tool `--version` output |
| `system_sha` | s | sha256 of the system binary at run time |
| `hardware_id` | s | sha256(`/proc/cpuinfo` + `/proc/meminfo` + `uname`) — short label form retained beside it |
| `git_sha` | s | zq commit being measured |
| `harness_version` | s | `benchmarks/runner.sh` semver |
| `dataset` | s | corpus key (e.g. `api.github_events`) |
| `dataset_version` | s | `sha256:…` of the file |
| `dataset_bytes` | n | file size |
| `dataset_records` | n | record count |
| `query` | s | the literal jq filter or DSL string |
| `query_class` | s | one of the 9 classes in §5 |
| `scenario` | s | `file_mode_parallel` \| `file_mode_serial` \| `stream` \| `startup_latency` \| `microbench` |
| `run_index` | n | 1..R |
| `warmup_runs` | n | hyperfine warmup count |
| `total_runs` | n | hyperfine run count |
| `cpu_cores_used` | n | from `--jobs` / cgroup |
| `cpu_pinned` | b | taskset applied |
| `cpu_governor` | s | captured at run time |
| `mean_ms`, `median_ms`, `p99_ms`, `min_ms`, `max_ms`, `stddev_ms` | n \| null | hyperfine cell stats |
| `ci95_low_ms`, `ci95_high_ms` | n \| null | bootstrap 95% CI on the median |
| `peak_rss_bytes` | n \| null | from `/usr/bin/time -v` |
| `user_cpu_ms`, `sys_cpu_ms` | n \| null | from `/usr/bin/time -v` |
| `ns_per_record_total`, `_parse`, `_lookup`, `_predicate`, `_serialize`, `_coord` | n \| null | populated only on `kind=microbench` |
| `counter_overhead_ns` | n \| null | per-call instrumentation cost subtracted from phase rows |
| `output_lines` | n | line count of stdout |
| `output_sha256` | s | sha256 of stdout (see OQ-C) |
| `output_equivalent_to_jq` | b | computed by checker |
| `status` | s | `ok` \| `skip` \| `fail` \| `timeout` |
| `skip_reason`, `fail_reason` | s \| null | populated when applicable |
| `elapsed_wall_ms` | n | end-to-end wall time |

### Versioning and migration

- `schema_version` is a top-level field on every row, mandatory.
- **Forward compatibility rule:** new fields are added at the end and are
  always optional. Removed fields are kept as `null` for two version bumps.
- **Migration:** a `benchmarks/migrations/v1_to_v2.py` script translates the
  current `summary.json` (v1.0) into v2.0 NDJSON rows. This is one-shot and
  preserves the historical baseline.

### Storage layout

- One file per harness invocation: `benchmarks/results/run-<timestamp>.ndjson`.
- A symlink `benchmarks/results/latest.ndjson` always points to the newest.
- A long-lived `benchmarks/results/history.ndjson` is the concatenated log.
  CI appends to this file in the cached baseline path (the cache key
  scheme already exists; we extend the cache to include `history.ndjson`).
- Per-run files are uploaded as artifacts on every CI run for 90 days.

### Query interface for the paper writer

The paper writer's workflow:

```sh
duckdb benchmarks/results/queries.duckdb <<'SQL'
CREATE OR REPLACE VIEW results AS
  SELECT * FROM read_json_auto('benchmarks/results/history.ndjson',
                                format='newline_delimited');

-- Example: Paper 1 throughput leaderboard
SELECT system,
       system_version,
       median(median_ms) AS p50_ms,
       median(p99_ms)    AS p99_ms
FROM results
WHERE query_class = 'extract.path'
  AND dataset = 'github_events'
  AND scenario = 'file_mode_parallel'
  AND status = 'ok'
GROUP BY system, system_version
ORDER BY p50_ms;
SQL
```

DuckDB is the right tool because it reads NDJSON natively, supports window
functions for percentile / regression analysis, and is already in the Nix
flake (as a benchmarked system). One install, two uses — single source of
truth applies to dev tools too.

---

## 7. CI gating policy

### When the harness runs

| Trigger | Scope | Why |
|---|---|---|
| Pull request (touches `src/`, `build.zig*`, `benchmarks/`) | Quick mode: 3 systems (zq + jq + jaq), 2 scenarios (parallelism + streaming), 2 datasets (synthetic small + synthetic medium), all 9 query classes. ~5 min budget. **No microbench.** | Catches obvious regressions before merge without 30-minute PR latency. Hyperfine end-to-end is the engineering gate; phase-level data is paper-quality and lives on tag runs. |
| Push to main (after PR merge) | Full mode: all systems, all scenarios, all datasets except the 100 GB cells, all queries. ~25 min budget. Updates the cached baseline. **No microbench.** | Authoritative end-to-end measurement on a clean main; what the engineering regression checker reads. |
| **Weekly** (cron Sunday 06:00 UTC) — **PARKED until AWS credits arrive** | Full mode plus 100 GB cells plus the scaling sweep (cores 1, 2, 4, 8, 16, 32, 64, 96). ~3 h budget on the AWS bare-metal instance. **No microbench.** | Per OQ-A: scaling sweep runs on an ephemeral AWS bare-metal instance (`m7i.metal-48xl` or `hpc7a.96xlarge`). ~$20–40 per run. **Currently parked** — credits expected in 1–6 weeks. While parked: scaling sweep code is built and tested locally on the developer laptop (under its own `hardware_id`, never compared to future AWS results); the workflow file is staged but the cron trigger is commented out. Unblock action: enable cron + push secrets + first manual `workflow_dispatch` to validate the launcher. |
| **Tag push (`v*`) — PARKED until AWS credits arrive** | Full mode + microbench (all five phase splits, both shape-uniform and shape-mixed cells). Result rows attached to the GitHub release as artifacts. ~45 min budget. | Per OQ-D + OQ-A: microbench is paper-quality and runs on the same AWS bare-metal pattern as the weekly sweep. **Currently parked** for the same reason as the weekly job — paper-bound microbench numbers must come from a clean dedicated runner, and the laptop is unsuitable. While parked: microbench code is built and runnable locally on the developer laptop for development validation only; no laptop microbench numbers ship to the result history. Unblock action: same as the weekly job. |
| **Tag push (`v*`) — the only microbench trigger** | Full mode + **microbench** (all five phase splits, both shape-uniform and shape-mixed cells). Result rows attached to the GitHub release as artifacts. ~45 min budget. | Per OQ-D: microbench is paper-quality measurement, runs only at release boundaries on the dedicated runner where the noise floor is low enough for sub-microsecond phase attribution to be honest. Tag releases are the natural review points; intermediate phase data is unavailable by design. |
| Manual `workflow_dispatch` | Selected by inputs, including a `microbench=true` toggle for ad-hoc phase capture between tags. | Re-run a flaky cell, run a specific dataset, or capture an unscheduled microbench (e.g., before a major refactor lands). |

### Regression failure trigger

The current ratio-vs-jq policy is wrong for the multi-system harness.
Replacement policy:

- Each `(system, query_class, dataset, scenario)` cell has its own cached
  baseline.
- A cell *regresses* if its current `median_ms` is more than:
  - **15%** worse than its own baseline median, **and**
  - The 95% confidence intervals do not overlap (so the regression is
    statistically distinguishable from noise).
- A cell *warns* (does not block) if either (a) the median is 7–15% worse, or
  (b) the median is >15% worse but the CIs overlap.
- A *system* fails the gate if **two or more cells regress simultaneously**
  in the same run — single-cell regressions on PRs are too noisy to gate
  on (CI hardware contention).
- Microbench *phase* regressions warn but never block — they are advisory,
  surfacing future risk early.

**Why two-cells-or-more for blocking:** single-cell regressions on shared CI
runners (`ubuntu-latest`) are dominated by neighbor noise. Requiring two
correlated regressions filters that out without raising the threshold to a
dishonest level. The dedicated nightly runner is the source of truth for
single-cell regressions.

**Per-system, not vs-jq:** the current ratio-vs-jq scheme cannot detect a
regression where both jq and zq slow down equally (CI noise day). The new
scheme catches this because each system is gated against its own baseline.

### How the ablation row is attached to a PR

A `gh pr comment` step posts a Markdown table to the PR with:

- The diff of every cell that *changed* (>3% in either direction).
- The full microbench phase split for the touched modules.
- A footer link to the artifact with the full NDJSON.

The committed file path: nothing. Results live only in the cache + PR
comment + artifact. We do **not** commit results to git — that would mix
machine-generated noise with human commits and wreck blame.

The cached `history.ndjson` is the long-lived record. The PR comment is the
human-readable view. The artifact is the auditable evidence. Three views,
one underlying truth.

### Preventing CI noise from blocking PRs

1. The two-cells-or-more rule (above).
2. **CI runners are recorded in `hardware_id`.** PR runs on
   `ubuntu-latest` and the nightly runner on the dedicated machine have
   different `hardware_id`s and different baselines. They never compare
   across hardware.
3. **Quick-mode runs use a small, deterministic synthetic dataset** so the
   baseline median is reproducible to within ±2% on cold CI hardware.
4. **The microbench job runs only on the dedicated runner**, never on
   `ubuntu-latest`, because phase-level measurement on a shared runner is
   meaningless.
5. **A retry budget:** if a single cell fails, the harness re-runs that
   cell once. If it passes the second time, the run is marked "flaky"
   (not failing). Two flaky runs in a week trigger a hardware investigation
   issue.

---

## 8. Statistical methodology

### Per-cell

| Parameter | Quick mode (PR) | Full mode (main) | Microbench |
|---|---|---|---|
| Hyperfine `--warmup` | 2 | 5 | n/a |
| Hyperfine `--runs` | 5 | 25 | n/a |
| Microbench warmup records | n/a | n/a | 10 000 |
| Microbench measure records | n/a | n/a | 100 000 (auto-tuned to 1–5 s) |
| Reported summary | median, p99, stddev, ci95 | same | mean, stddev (single high-resolution run) |

Why bumped from current `runs=10` to `runs=25` in full mode: the current
suite is throughput-only and the median is already stable. The new harness
includes microbench cells, very small datasets, and startup latency — all
of which need more samples to stabilize the p99.

### Outlier policy

- **IQR-based trim**, applied *after* hyperfine reports raw timings:
  drop samples outside `[Q1 - 1.5·IQR, Q3 + 1.5·IQR]`.
- The number of dropped samples is recorded in the result row
  (`outliers_dropped` — added to schema v2.1 if needed; for v2.0 we keep
  the raw count and document the rule).
- If more than 30% of samples are dropped, the cell is marked
  `status=fail` with reason `excessive_variance` — that means the runner
  is unhealthy.

**Alternative considered:** trim top/bottom by fixed percentile (e.g.
trimmed 5%/95%). Rejected — the IQR rule adapts to the actual distribution
shape.

**Alternative considered:** report MAD instead of stddev. Considered for
v2.1; for v2.0 we keep stddev because hyperfine reports it directly.

### Hardware control

| Knob | Setting | Why |
|---|---|---|
| CPU governor | `performance` | Eliminates frequency scaling jitter. Captured per-row. |
| CPU pinning | `taskset -c 0-N` matching `--jobs N` | Prevents the kernel from migrating workers across NUMA nodes mid-run. |
| Hyperthreading | Disabled on the dedicated runner; left as-is on `ubuntu-latest` (it's a VM, we don't control it). | HT changes effective core count; explicit is better. |
| Background load | `nice -n -5` for the runner; check `/proc/loadavg < 0.5` before starting; otherwise sleep 30 s and retry up to 3× | Eliminates the most common noise source on shared runners. |
| ASLR | Disabled (`echo 0 > /proc/sys/kernel/randomize_va_space`) on the dedicated runner only | ASLR adds 1–3% jitter; only worth disabling on the controlled machine. |

The dedicated runner setup is documented in §9. None of the above is
applied on `ubuntu-latest` PR runs — the noise floor is what it is, and
the two-cells-or-more rule absorbs it.

### Confidence intervals and significance

For each cell, report a 95% confidence interval on the median computed via
the bootstrap (10 000 resamples) of the per-run timings. Include
`ci95_low_ms` and `ci95_high_ms` in the result row.

Regression gate uses CI overlap as the significance test: a regression
is statistically meaningful iff the new `[ci95_low, ci95_high]` does not
intersect the baseline interval. This is a coarser test than a paired
t-test but is appropriate because the runs are not paired (different
process invocations) and the sample sizes are small.

**Why bootstrap, not paired t-test:** bootstrap makes no normality
assumption; hyperfine's distributions are heavy-tailed.

**Why CI overlap, not p-value:** the gate must be a clear yes/no, and
"non-overlap of bootstrapped 95% CIs" is interpretable to a reviewer
without statistics expertise.

---

## 9. Reproducibility checklist

### Nix flake pinning

- `flake.lock` must be committed and reviewed in PRs.
- `flake.nix` is updated to add `simdjson`, `duckdb`, `clickhouse`,
  `polars-cli`, `python3` (with `polars`), plus the existing tools.
- The nixpkgs input is *pinned to a specific commit hash*, not
  `nixos-unstable` rolling. The `flake.lock` records the exact rev.
- CI uses the flake (`nix develop --command bash benchmarks/runner.sh
  full`) — currently CI installs hyperfine/jaq/gojq imperatively from
  GitHub releases; that path is removed in favor of `nix develop`.

### Dataset versioning and storage

- Every file in `benchmarks/corpus/` has an entry in `MANIFEST.json`:
  ```json
  {
    "path": "api/github_events.jsonl",
    "sha256": "d3a4…",
    "bytes": 209715200,
    "source": "https://gharchive.org/2024-01-01-12.json.gz",
    "captured_at": "2026-04-07T00:00:00Z",
    "license": "CC-BY-4.0",
    "version": "v1"
  }
  ```
- The runner verifies sha256 before every run; mismatch = abort with
  diagnostic.
- Real datasets >100 MB are not in git. They are fetched by
  `benchmarks/corpus/<domain>/fetch.sh` against pinned source URLs and
  cached in `benchmarks/corpus/.cache/`. Synthetic datasets are
  regenerated from the seeded generator.
- For datasets we cannot redistribute (Twitter), the manifest entry has
  `source: "user_provided"` and the runner errors with
  "place file at <path>, sha256 must equal <expected>".
- Long-term: a tarball of the full corpus is mirrored on a permanent host
  (Zenodo or similar) once Paper 1 ships; the DOI goes in the paper.

### Hardware requirements

| Role | Spec | Used for |
|---|---|---|
| PR gate | `ubuntu-latest` (2 vCPU, 7 GB RAM) | Quick mode only. Two-cell regression rule absorbs the noise. |
| Main / dedicated runner | 16+ physical cores, 64+ GB RAM, NVMe SSD, fixed `performance` governor, no other workloads | Full mode (push to main). Authoritative end-to-end results. May overlap with the scaling-sweep machine if cost permits keeping it long-lived; otherwise also ephemeral on AWS. |
| **Scaling sweep + microbench (AWS bare-metal, ephemeral)** — **PARKED** | `m7i.metal-48xl` (96 vCPU Sapphire Rapids) **or** `hpc7a.96xlarge` (96 cores EPYC). Single-tenant bare metal, no neighbor noise, no hypervisor overhead. | Per OQ-A: weekly scaling sweep + tag-time microbench. ~$20–40 per invocation. **Parked 1–6 weeks pending AWS credits.** Phase 0 implementation does not depend on this row being live — code lands, workflows are staged, the trigger lights up the day credits arrive. |
| **Developer laptop (Intel Core Ultra 9 185H, while AWS is parked)** | 6 P-cores + 8 E-cores + 2 LPE-cores, mobile thermal envelope. Heterogeneous architecture, not paper-quality. | Local validation of harness code only. Runs the full runner end-to-end during development to catch bugs before they hit CI. Results live under their own `hardware_id` derived from `/proc/cpuinfo` and **never compare to future AWS results** because the schema's hardware_id-keyed baselines isolate them. No laptop result ever ships to a paper figure. |
| ARM coverage | AWS Graviton3 bare metal (`c7g.metal` or `m7g.metal`) **or** Hetzner ARM dedicated | NEON code path coverage; runs full mode weekly via the same ephemeral pattern. |

**OQ-A is resolved.** The AWS bare-metal pay-per-sweep model removes the
"buy a 64-core machine" requirement entirely and replaces it with a
recurring spend bounded by weekly cadence (~$20–40/week, ~$80–160/month;
upgradable to nightly during Paper 1 writeup if needed).

**Implementation prerequisites** (project lead must set up before the
weekly job lands in CI):
1. AWS account with sufficient credit / spending budget.
2. **OIDC trust between GitHub Actions and AWS IAM** (avoids storing AWS
   access keys in GitHub Secrets — same trust pattern already used for the
   npm OIDC publish in `release.yml`).
3. **Budget alarm** at e.g. $200/month to catch runaway spend (a
   misconfigured workflow that fails to terminate the instance is the
   most common failure mode).
4. **Ephemeral self-hosted runner pattern** — either roll our own with
   `aws ec2 run-instances` + GitHub runner registration, or adopt
   `philips-labs/terraform-aws-github-runner` (well-maintained, has
   ephemeral support). Recommend rolling our own first (~100 lines of
   Bash); the Terraform module is overkill for one workflow.
5. **Corpus pre-staging on S3** so the bare-metal instance doesn't have
   to re-fetch real datasets on every launch (Mastodon capture, GitHub
   Archive sample, etc. live in an S3 bucket; instance pulls them at
   start, runs sweep, uploads result NDJSON, terminates).

### Result storage

- Live in CI cache + per-run artifacts (90-day retention).
- `history.ndjson` lives in the cache and is uploaded as a separate
  long-retention artifact monthly.
- For Paper 1 publication, the snapshot used is committed to a
  reproducibility repo separate from `zq` and given a DOI.

### Documentation requirements

A `benchmarks/REPRODUCING.md` file must let an external reader, on a
clean machine, reproduce a paper figure with these steps:

1. `git clone` the repo and `nix develop`.
2. `bash benchmarks/corpus/fetch.sh` to materialize datasets (or fail with
   the missing-Twitter message).
3. `bash benchmarks/runner.sh full` (or `sweep`).
4. `duckdb -c "$(cat benchmarks/queries/figure_3.sql)"` to regenerate
   the figure data.
5. `python benchmarks/plotting/figure_3.py` to render.

If any of those steps requires a shell hack or a TODO, the doc has failed
its job and Phase 0 is not done.

---

## 10. Open questions

Six of the seven open questions were resolved on 2026-04-07 (see decision
log). One remains open and is gating a specific deliverable.

| # | Question | Blocks | Status |
|---|---|---|---|
| ~~OQ-A~~ | ~~64-core machine for the scaling sweep~~ | ~~Scaling sweep job~~ | **Decided 2026-04-07: AWS bare-metal pay-per-sweep — DEFERRED 1–6 weeks pending credit availability.** Target: `m7i.metal-48xl` (96 vCPU Sapphire Rapids) or `hpc7a.96xlarge` (96 cores EPYC), ephemeral, weekly cadence. **Phase 0 implementation proceeds on everything that does not require AWS.** Items parked until credits arrive: weekly scaling-sweep CI workflow, tag-time microbench CI workflow, S3 corpus staging. Items NOT parked: all five system adapters, microbench rebuild, workload corpus assembly, result schema, non-scaling CI gating, statistical methodology, Nix flake hardening, dataset MANIFEST. See §7 trigger table for the parked-job markings and §9 hardware table for the deferral. |
| ~~OQ-B~~ | ~~Twitter vs Mastodon for API workload~~ | ~~API corpus~~ | **Decided 2026-04-07: BOTH.** Mastodon `streaming/public` capture is the always-runs default (CC0, fully redistributable). Twitter is an opt-in cell — manifest entry `source: user_provided`, runner errors out with "place file at <path>" if not present. Paper figures use Mastodon as the primary; Twitter is a supplementary cell for users who have credentials. |
| ~~OQ-C~~ | ~~`output_sha256` cadence~~ | ~~Schema v2.0 sealing~~ | **Decided 2026-04-07:** always-on for **full mode**; first-run-only for **quick mode**. Honest correctness on the authoritative path, halved cost on the per-PR path. Schema v2.0 is sealed. |
| ~~OQ-D~~ | ~~Microbench frequency~~ | ~~CI workflow~~ | **Decided 2026-04-07: tag releases only.** Sparser than the agent's nightly+tag recommendation. Hyperfine ablation rows still run on every PR (preserve the roadmap's "every PR has an ablation row" promise at the end-to-end level). Microbench phase rows are emitted only on tag pushes, where the dedicated runner produces clean numbers and they get attached to the GitHub release. **Trade accepted:** phase regressions that cancel at the end-to-end level go undetected until the next tag. Tag releases become the natural microbench review points. |
| ~~OQ-E~~ | ~~Microbench shape uniformity (clean vs mixed)~~ | ~~Paper 1 narrative~~ | **Decided 2026-04-07:** report **both**. The clean (shape 0 only) cell is the headline microbench number; the mixed (current `huge.jsonl`-style cycling) cell is reported as the realistic-workload number. Two cells, two stories, no cherry-picking. |
| ~~OQ-F~~ | ~~C++ bridge in the repo~~ | ~~simdjson adapter~~ | **Decided 2026-04-07: yes, in `benchmarks/systems/simdjson_bridge/`.** Single `.cpp` file, restricted to four query classes, built via Nix-pinned simdjson, never shipped in the user binary. Documented as a benchmark-only adapter so the implicit "Zig only" intent of `src/` stays intact. The "single source of truth" rule is preserved: the bridge is the *only* place simdjson is invoked, and it doesn't duplicate any logic that lives elsewhere. |
| ~~OQ-G~~ | ~~DuckDB/ClickHouse on streaming~~ | ~~Streaming scenarios~~ | **Decided 2026-04-07:** skip and explain. Wrapping stdin into a temp file would add I/O the systems don't really do, contaminating the streaming-mode comparison with measurement artifacts. The paper's streaming chart marks DuckDB and ClickHouse `n/a` with the explanation "file-only ingest; cannot fairly compare on stream mode." |

---

## Decision Log

A running log of the calls made in this design. New decisions append here.

### 2026-04-07 — Single runner, system adapter files
**Alternatives:** Keep the per-scenario shell scripts and add system flags;
build a Python harness; build the runner in Zig.
**Chosen:** A single Bash runner (`benchmarks/runner.sh`) that discovers
system adapters by filesystem.
**Why:** Bash is already the runner's language; rewriting in Python or Zig
adds a dependency for no measurement value. Adapter-by-filesystem
discovery is the smallest possible interface — adding a system is one
file, removing one is `git rm`. Single source of truth is enforced by the
file layout.

### 2026-04-07 — NDJSON results, DuckDB query layer
**Alternatives:** Parquet, SQLite, JSON-per-run, the existing per-scenario
JSON.
**Chosen:** NDJSON with a DuckDB read view.
**Why:** DuckDB reads NDJSON natively and is already in the system list,
so the tool that *measures* DuckDB is also the tool that *queries* the
results — single source of truth. NDJSON is grep-able, append-only, and
diff-friendly; Parquet wins on size only when results are in the GB
range, which they are not.

### 2026-04-07 — Comptime profile flag for microbench, not runtime
**Alternatives:** Runtime feature flag (cheap branch every call); separate
parallel implementation in `src/microbench/`.
**Chosen:** Comptime `-Dprofile=true` flag, gated comptime `if`s in the
existing modules.
**Why:** Runtime branching costs more than the events we're measuring (a
phase enter/exit is ~10 ns; a runtime branch on a hot path is ~1 ns
amortized but visible at sub-microsecond scale). A parallel implementation
violates single-source-of-truth — the microbench must drive the same
modules as production. Comptime branch elision is the only honest answer.

### 2026-04-07 — Per-system self-baseline gate, not vs-jq ratio
**Alternatives:** Keep the vs-jq ratio gate; add a second
absolute-time gate; replace entirely.
**Chosen:** Replace entirely with per-system absolute-time gates +
two-cells-or-more rule + bootstrap CI overlap.
**Why:** The ratio gate is undefined for systems that don't have a jq
analog (DuckDB, ClickHouse on file mode where jq runs streaming). It also
fails to detect "everything got slower equally" days. Per-system gates +
correlated-regression rule + CI overlap statistic is statistically honest
and extensible.

### 2026-04-07 — Synthetic generator in Python, real data in scripts
**Alternatives:** Generator in Zig (matches the rest of the codebase);
generator in awk (matches `huge.generator.sh`).
**Chosen:** Python generator under `benchmarks/corpus/synthetic/`.
**Why:** The synthetic axis sweep is a parameter-product loop, not a hot
path. Python is more readable for the parameter sweep code, and the
output is byte-deterministic regardless of language. The existing awk
generator is preserved as-is for backward compatibility but is *not* the
new corpus's source of truth — it becomes one of the synthetic shapes.

### 2026-04-07 — simdjson lives behind a thin C++ bridge, restricted to extraction queries
**Alternatives:** Omit simdjson; use simdjson via a Zig FFI binding;
include it as a "full" jq-like comparator.
**Chosen:** Thin C++ bridge limited to four query classes, marked `n/a`
on classes outside its scope.
**Why:** simdjson is a parsing library, not a query engine. Pretending
otherwise is dishonest in either direction. The bridge is the smallest
honest answer; the explicit `n/a` markings inoculate against the
"cherry-picked" reviewer attack.

### 2026-04-07 — Microbench rebuilt in `src/microbench/`, gated build target, opt-in profile flag
**Alternatives:** Restore the prior `src/microbench.zig` from git history;
build microbench inside `tests/` as a benchmark test.
**Chosen:** New `src/microbench/main.zig` directory, `zig build microbench`
gated step, comptime hooks in production modules.
**Why:** The prior file is gone and the prior justfile target is broken;
restoring is more work than rebuilding cleanly. `tests/` is for
correctness, not measurement. A directory under `src/` makes microbench a
first-class build target with its own scenarios subdirectory and result
writer — extensible without growing one giant file.

### 2026-04-07 — OQ resolutions (six of seven)
**Resolved in a single user review:**
- **OQ-B (Twitter/Mastodon):** both. Mastodon as the always-runs default (CC0,
  redistributable, source of paper figures); Twitter as opt-in user-provided
  cell. See §5 API table.
- **OQ-C (`output_sha256` cadence):** always-on for full mode, first-run-only
  for quick mode. See §6 schema.
- **OQ-D (microbench frequency):** **tag releases only** (sparser than the
  agent's nightly+tag recommendation). Hyperfine ablation rows still run on
  every PR; phase-level microbench rows live only on tag pushes. Trade
  accepted: phase regressions that cancel at the end-to-end level go
  undetected until the next tag. Tag releases become the natural microbench
  review points. See §7 trigger table.
- **OQ-E (microbench shape uniformity):** report **both** clean (shape 0
  only) and mixed (shape-cycling) cells. No cherry-picking, two stories.
- **OQ-F (C++ bridge in repo):** yes, in `benchmarks/systems/simdjson_bridge/`.
  Single `.cpp` file, four query classes, Nix-pinned simdjson, never shipped
  in the user binary. Documented as benchmark-only so the implicit "Zig only"
  intent of `src/` stays intact.
- **OQ-G (DuckDB/ClickHouse on streaming):** skip and explain. Marking
  `n/a` is honest; wrapping stdin into a temp file would contaminate the
  measurement.

**Still open:** none. All seven Phase 0 OQs are resolved as of 2026-04-07.

### 2026-04-07 — OQ-A resolution: AWS bare-metal pay-per-sweep
**Alternatives reconsidered:** owned Ryzen 9 7950X/9950X desktop build,
rented Hetzner AX162-R (~€150/mo), rented Hetzner AX102 (~€100/mo), AWS
bare-metal pay-per-sweep, or shrink the scaling figure to fit a heterogeneous
laptop chip.
**Chosen:** AWS bare-metal pay-per-sweep (`m7i.metal-48xl` 96 vCPU Sapphire
Rapids or `hpc7a.96xlarge` 96 cores EPYC), launched ephemerally by the CI
workflow. Cadence: **weekly default + on-demand during Paper 1 writeup**
(refines the design's original "nightly" wording in §7).
**Why:**
- Zero ongoing operational cost — no machine to babysit, no Hetzner monthly
  bill, no desktop to build.
- Pay-per-use scales with project intensity: cheap weeks during slow
  development, on-demand bursts during paper writeup.
- 96 P-cores is the largest scaling-figure ceiling among the four options;
  Paper 1's headline scaling figure spans cores=1, 2, 4, 8, 16, 32, 64, 96.
- Single-tenant bare metal eliminates the noise floor problem that killed
  the laptop option (no neighbor processes, no hypervisor overhead, no
  thermal throttling within the burst window).
- The OIDC trust pattern is already proven in this repo (`release.yml`
  publishes to npm via OIDC). Reusing the same auth model is single-source-
  of-truth at the CI auth layer.
**Cadence refinement:** "nightly" in the original §7 became "weekly default
+ on-demand". Nightly was design boilerplate from a "free dedicated runner"
worldview; with pay-per-sweep, weekly is the cost-rational default and the
sparser cadence is acceptable because Paper 1 writeup will burst the
schedule manually when needed.
**Prerequisites the project lead must complete before the weekly job lands:**
AWS account, OIDC IAM trust, budget alarm, ephemeral self-hosted runner
launcher, S3 corpus staging. See §9 for the checklist.

### 2026-04-07 — Phase 0 does not commit results to git
**Alternatives:** Commit `history.ndjson` to git; commit per-run NDJSON.
**Chosen:** Results live in CI cache + artifacts + (eventually) Zenodo.
**Why:** Git history pollution is real and irreversible. The cache +
artifact + Zenodo split gives short-term and long-term durability without
mixing measurement noise with code commits.

---

## Implementation notes (heads-up for the Phase 0 implementer)

- The `flake.nix` uses rolling `nixos-unstable` without a committed
  `flake.lock` review. Adding the new systems forces a regeneration; commit
  the result and gate CI on it.
- `just bench` is broken today (target binary does not exist). Update the
  justfile alongside the `build.zig` microbench step.
- `01_parallelism.sh` excludes gojq while `04_streaming.sh` and
  `05_complex_query.sh` include it. The new adapter-per-system layout
  unifies this; old per-scenario scripts can stay during the rebuild and
  CI flips from old to new in a single cutover PR.
- The current `baseline.json` is v1.0 schema. Keep it as a historical
  reference and start the v2.0 history fresh; do not back-fill.
- File-size drift on `huge.jsonl` between `MEMORY.md` (1277 MB) and
  `benchmarks/README.md` (~650 MB) is exactly the drift the v2.0
  manifest-with-sha256 prevents going forward.

---

*End of Phase 0 design.*
