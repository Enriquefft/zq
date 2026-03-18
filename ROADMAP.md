# zq Roadmap

> The JSON tool agents reach for first — 25x faster than jq, with structured errors,
> machine-readable interfaces, and seamless integration into automated workflows.

---

## Vision

jq powers every JSON pipeline on the planet. It is also single-threaded, has cryptic
error messages, and was designed for humans reading man pages. The next generation of
software consumers are AI agents — they choose tools, orchestrate workflows, and process
data autonomously. They care about structured output, reliable APIs, low latency, and
clean integration. jq fails on all of these.

zq is **agents first**: same jq filter language, but built to be discovered, integrated,
and reliably used by AI agents operating inside automated workflows. Where jq returns
a cryptic text error, zq returns structured JSON with suggestions. Where jq requires
memorizing arcane syntax, zq validates queries, describes data shapes, and explains
what filters do. Where jq is single-threaded, zq saturates all cores.

Agents are the new customer. zq is built for **Agent Market Fit** — not just whether
humans love it, but whether agents can discover it, integrate it, and reliably use it.

**Non-goals:** zq is not a general-purpose data tool. It does not aim to replace
awk, miller, or SQL. The filter language is jq — not a superset, not a fork.
Deliberate deviations from jq semantics are documented and justified.

---

## Quick Status (Updated 2026-03-18)

**Last updated:** Memory audit — madvise(MADV_DONTNEED) on processed mmap chunks; RSS reduced from 1.29x to 0.31–0.64x input

```
Binary size:        2.7 MB (ReleaseFast, stripped)
Compat tests:       327/533 passing (61.4%)
  +-- 203 failing, 3 skipped
Startup:            ~2 ms (2x faster than jq)
Cold start:         sub-3ms

Parallel (file arg, .id, 15M-record JSONL, 1.3 GB):
  jq   37.8s   3.7 MB RSS
  jaq  25.0s   1312 MB RSS
  zq    1.44s   396 MB RSS  <- 26x faster than jq, 0.31x input RSS

Parallel (file arg, select(.id > 500000), 15M-record JSONL, 1.3 GB):
  jq   69.8s   3.6 MB RSS
  jaq  39.0s   1312 MB RSS
  zq    2.21s   820 MB RSS  <- 32x faster than jq, 0.64x input RSS

Parallel (file arg, complex transform, 15M-record JSONL, 1.3 GB):
  jq   91.2s   3.7 MB RSS
  jaq 178.3s   1312 MB RSS
  zq    3.64s   543 MB RSS  <- 25x faster than jq, 0.42x input RSS
```

**Architecture:** error | types | io | parser | query | output | pool | describe | c_abi | main.zig — all modules complete.
**Agent interface:** `--json-errors`, `--describe`, `--validate`, exit codes, C ABI errors, `llms.txt`, 134 builtins.

---

## v0.1.0 — Useful (Agent Quick Wins)

> Goal: Replace jq for the 20 most common CLI one-liners, with the agent-friendly
> fundamentals that make zq the obvious choice for automated workflows.
> `curl api | zq '.results[] | {name, id}'` works — and when it doesn't, the error
> tells you exactly why in machine-readable JSON.

### Milestone criteria

- [x] 60%+ of migrated jq compat tests pass (achieved: 61.4%, 327/533)
- [ ] All P0/P1 query features below are implemented
- [x] `zq` binary under 3 MB static (2.7 MB stripped)
- [ ] Zero known crashes on valid JSON input
- [x] Memory: RSS < 2x input size for per-record queries on file mode (achieved: 0.31x for `.id`, 0.64x for `select()`)
- [x] Startup time < 3ms (achieved: ~2ms)
- [x] `--json-errors` produces structured error output
- [x] `--describe` shows input data shape
- [x] `--validate` checks filter syntax without executing

### Agent interface — P0

These are the highest-leverage agent-first features. Small implementation cost,
massive improvement in agent usability. Every one of these addresses a concrete
failure mode agents hit with jq today.

| | Feature | What it does | Why agents need it |
|---|---------|-------------|-------------------|
| [x] | **`--json-errors`** | Errors as JSON to stderr: `{"error": "type_error", "line": 1, "col": 5, "offset": 4, "len": 0, "filter": "...", "message": "...", "description": "..."}` | Agents can parse errors, understand what went wrong, and self-correct. jq's text errors cause retry loops. |
| [x] | **`--describe`** | Print input data shape to stdout: `{"type": "object", "fields": {"id": "number", "name": "string", "tags": "array"}, "count": 15000000}` | Agents can inspect data before writing a query. Eliminates blind guessing. |
| [x] | **`--validate FILTER`** | Check filter syntax, exit 0 if valid, exit 3 with JSON error if not. No input required. | Agents can verify a filter before running it on real data. Fail fast, no wasted work. |
| [x] | **Documented exit codes** | 0=success, 1=false/null (-e), 2=usage, 3=compile error, 4=runtime error, 5=system error | Agents need unambiguous signal of what went wrong. Exit codes split by error category. |
| [x] | **`llms.txt`** | Machine-readable documentation file at repo root. Structured reference of all flags, builtins, and query syntax for LLM consumption. | How agents discover what zq can do. Optimized for context windows, not human scanning. |

### Query language — P0

These are table-stakes. Without them, zq cannot process real-world filters.

| | Feature | Scope | What it unlocks |
|---|---------|-------|-----------------|
| [x] | **Arithmetic** (`+`, `-`, `*`, `/`, `%`) | Compiler + VM | Object merge (`+`), string concat, array concat, numeric math |
| [x] | **Unary negation** (`-expr`) | Compiler + VM | `-1`, `-.foo` |
| [x] | **Comparisons** (`==`, `!=`, `<`, `>`, `<=`, `>=`) | Compiler + VM | Required for `select`, `if/then`, sorting |
| [x] | **Boolean operators** (`and`, `or`, `not`) | Compiler + VM | Required for any conditional logic |
| [x] | **Conditionals** (`if/then/elif/else/end`) | Compiler + VM | Control flow |
| [x] | **Variables** (`expr as $x \| ...`) | Compiler + VM (scope stack) | Required for object construction, reduce, def, and most non-trivial filters |
| [x] | **Comma operator** (`a, b`) | Compiler + VM (generator stack) | Multiple outputs. Required for array/object construction. |
| [x] | **Object construction** (`{a: .b, c: .d}`) | Compiler + VM | Shorthand `{a}` = `{a: .a}`. Computed keys `{(.k): .v}`. |
| [x] | **Array construction** (`[expr]`) | Compiler + VM | Collect generator outputs into array. `[.[] \| .name]`. |
| [x] | **String interpolation** (`"hello \(.name)"`) | Lexer + Compiler + VM | Very common in practice. Required for readable output. |
| [x] | **Recursive descent** (`..`) | Compiler + VM | Deep search. `.. \| .name?` |
| [x] | **Pipe expressions in brackets** (`.[.foo]`, `.["key"]`) | Lexer + Compiler | String key access, computed index |

### Query language — P1

| | Feature | Scope | What it unlocks |
|---|---------|-------|-----------------|
| [x] | **Alternative operator** (`//`) | Compiler + VM | Null coalescing. `(.foo // "default")` |
| [x] | **Try/catch** (`try expr catch expr`) | Compiler + VM | Error recovery. The LLM streaming use case. |
| [x] | **Optional operator** (`expr?`) | Compiler + VM | Suppress errors on missing keys. `.foo?` |
| [x] | **Slicing** (`.[2:4]`, `.[2:]`, `.[:4]`) | Compiler + VM | Array and string slicing |
| [x] | **Update assignment** (`\|=`, `+=`, `-=`, `*=`, `/=`, `%=`, `//=`) | Compiler + VM | In-place modification. `.foo \|= . + 1` |
| [x] | **Negative indexing** (`.[-1]`, `.[-2:]`) | VM | Last element, tail slicing |
| [x] | **Core builtins (tier 1)** | VM builtins table | `length`, `keys`, `values`, `has`, `in`, `type`, `empty`, `select`, `map`, `add`, `not`, `error`, `null`, `true`, `false`, `tostring`, `tonumber`, `range`, `keys_unsorted` |
| [x] | **Core builtins (tier 2)** | VM builtins table | `sort`, `sort_by`, `group_by`, `unique`, `unique_by`, `reverse`, `flatten`, `min`, `max`, `min_by`, `max_by`, `to_entries`, `from_entries`, `with_entries`, `del`, `contains`, `inside`, `any`, `all`, `limit`, `first`, `last`, `indices`, `index`, `rindex` |

### Query language — P2

| | Feature | Scope | Complexity |
|---|---------|-------|------------|
| [x] | **`def`** (user-defined functions, including recursion) | Composability | High |
| [x] | **`while`/`until`/`repeat`** | Loop constructs | Low |
| [x] | **`label`/`break`** | Non-local exit from generators | High |
| [x] | **`reduce`** (`reduce expr as $x (init; update)`) | Aggregation | Medium |
| [x] | **`foreach`** (`foreach expr as $x (init; update; extract)`) | Stateful iteration | Medium |
| [x] | **`getpath`/`setpath`/`delpaths`/`paths`/`leaf_paths`** | Path algebra | Medium |
| [x] | **Variable destructuring** (`as [$a,$b]`, `as {a: $x}`) | Pattern matching in bindings | Medium |
| [x] | **`?//`** (destructuring alternative operator) | Pattern match with fallback | Medium |
| [x] | **Builtin overloads** (`any/all(gen;cond)`, `flatten(depth)`, `range(a;b;c)`) | Complete multi-arg signatures | Low |
| [x] | **`contains` on strings** | `"foobar" \| contains("foo")` | Low |
| [x] | **`@base64`/`@base64d`/`@uri`/`@html`/`@csv`/`@tsv`/`@json`/`@text`/`@sh`** | Format strings | Low |

### CLI

| | Feature | Priority | Complexity |
|---|---------|----------|------------|
| [x] | `-s` / `--slurp` | P0 | Medium |
| [x] | `-S` / `--sort-keys` | P1 | Low |
| [x] | `-R` / `--raw-input` | P1 | Low |
| [x] | `-j` / `--join-output` | P1 | Low |
| [x] | `-f` / `--from-file` | P1 | Low |
| [x] | `--arg NAME VALUE` | P1 | Medium |
| [x] | `--argjson NAME VALUE` | P1 | Medium |
| [x] | `--tab` / `--indent N` | P2 | Low |
| [x] | `--args` / `--jsonargs` | P2 | Medium |

### Memory optimization — P0

Current state: **396 MB RSS** for 1277 MB JSONL `.id` query **(0.31x input)**. Target < 2x: **achieved**. Target ~1x: **achieved**.
Progress: 2998 MB -> 1702 MB -> 701 MB -> 396 MB (-87% total).

| | Item | Detail |
|---|------|--------|
| [x] | **Bounded chunk count** | InFlightLimiter caps in-flight chunks at `IN_FLIGHT_FACTOR x n_threads`. Memory bounded to ~`chunk_size x n_threads`, not file size. **Result: 2998 MB -> 1764 MB (-41%), 38s -> 1.41s (27x faster).** |
| [x] | **Ordered output queue** | Fixed-size ring buffer replaces HashMap in Sequencer. O(1) post and fetch with zero dynamic allocation in the hot path. **Result: 1764 MB -> 1702 MB (-3.5%).** |
| [x] | **Batched stream mode** | stdin routes through parallel pool via `submit_stream()`. IO thread accumulates lines into 256 KB batches. InFlightLimiter backpressure added. **Result: streaming 215s -> 1.6s (120x faster); RSS ~8 MB.** |
| [x] | **2 MiB thread stacks** | Reduced from 16 MiB default. Workers use heap-allocated parse/query stacks. **Result: ~224 MB saved (22 threads x 14 MiB).** |
| [x] | **Contiguous serialized chunks** | One contiguous byte buffer + compact `RecordMeta` array (8 B/record vs ~32 B). Format-aware pre-alloc reduces arena page leaks. **Result: 1053 MB -> 715 MB (-32%) for `.id`; 2203 MB -> 1980 MB (-10%) for `select()`.** |
| [x] | **`madvise(MADV_DONTNEED)` on processed chunks** | After workers serialize a chunk's output into the arena buffer, call `madvise(MADV_DONTNEED)` on the mmap pages. Releases physical pages immediately, bounding mmap RSS to `in_flight × chunk_size` instead of `file_size`. Linux-only; no-op elsewhere. **Result: 1648 MB -> 396 MB for `.id` (-76%); 0.31x input RSS.** |

**Target:** RSS < 2x input size for per-record queries (`.id`, `select()`, `{a,b}`). **Achieved and exceeded:**
- `.id`: **0.31x input** (396 MB for 1277 MB file)
- `select(.id > 500000)`: **0.64x input** (820 MB) — higher because output ≈ input for high-selectivity filters
- Complex transform: **0.42x input** (543 MB)

### Infrastructure

| | Item | Priority |
|---|------|----------|
| [x] | jq compat test suite fully migrated (539 tests) | P0 |
| [x] | CI: `zig build test` on every commit | P0 |
| [x] | Static binary builds (x86_64-linux, aarch64-linux, x86_64-macos, aarch64-macos) | P1 |
| [x] | Expanded `--help` with filter syntax, format strings, examples, exit codes, and builtins discovery | P1 |
| [x] | Error messages include filter position and input context | P2 |

---

## v0.5.0 — Agent Ready

> Goal: Full jq language coverage with deep agent integration. zq is the tool agents
> choose over jq — discoverable via MCP, self-documenting, and impossible to misuse.
> `alias jq=zq` works for 95% of users. Agents never need to retry a zq command.

### Milestone criteria

- [ ] 95%+ of migrated jq compat tests pass
- [ ] Published benchmark suite with reproducible results
- [x] Demonstrated 10x+ throughput on JSONL workloads vs jq (achieved 21x on `.id`, 23x on `select() + transform`)
- [ ] `--strict` + `--suggest` + `--explain` all working
- [ ] WASM build for sandboxed agent environments
- [ ] Python bindings for programmatic agent use

### Agent interface — core

| | Feature | What it does | Why agents need it |
|---|---------|-------------|-------------------|
| [ ] | **`--strict`** | Error on null field access instead of propagating null. `.foo` on `{"bar": 1}` is an error, not `null`. | Agents need unambiguous pass/fail. Silent null propagation causes subtle bugs that agents can't detect without inspecting every output value. |
| [ ] | **`--suggest`** | On field-not-found errors, include available fields: `"available": ["foos", "foo_count"]`. On function errors, suggest closest builtin. | Agents can self-correct in a single retry instead of blind guessing. Closes the feedback loop. |
| [ ] | **`--explain FILTER`** | Output a plain-english description of what a filter does: `"Select all elements from the .results array, extract the .name field from each"` | Agents can verify their own query intent before executing. Self-documentation. |
| [ ] | **Structured `--help`** | `--help --json` outputs help as structured JSON: flags, builtins, examples, all machine-parseable. | Agents can programmatically understand zq's full capabilities without parsing human-readable text. |

### Agent interface — integration

| | Feature | What it does | Why agents need it |
|---|---------|-------------|-------------------|
| [x] | **C ABI error details** | `zq_execute` returns granular error codes (-1 to -5). `zq_get_error` returns JSON error string. `zq_compile_ext` reports compile errors. | Language bindings (Python, Node) can surface actionable errors, not opaque codes. |
| [ ] | **Python bindings** | `pip install zq` — cffi bindings wrapping the C ABI. `zq.query('.id', data)` returns Python objects. | Agents run in Python. Direct library calls are faster and more reliable than shelling out. |
| [ ] | **WASM build** | `zig build -Dtarget=wasm32-wasi`. zq in browsers, edge functions, sandboxed agent environments. | Many agent runtimes are sandboxed (Cloudflare Workers, browser-based agents, Deno Deploy). WASM is the universal portable target. |
| [ ] | **`--json-output` default detection** | When stdout is not a TTY (agent/pipe context), default to compact JSON + `--json-errors`. | Agents get machine-readable output by default without needing to remember flags. Human-friendly when interactive, agent-friendly when piped. |

### Query language — remaining builtins

| | Category | Functions |
|---|----------|-----------|
| [x] | **String** | `split`, `join`, `test`, `match`, `sub`, `gsub`, `startswith`, `endswith`, `ltrimstr`, `rtrimstr`, `ascii_downcase`, `ascii_upcase`, `explode`, `implode`, `tojson`, `fromjson` |
| [ ] | **String (remaining)** | `capture`, `scan`, `trim`, `ltrim`, `rtrim`, `trimstr` |
| [x] | **Math** | `floor`, `ceil`, `round`, `sqrt`, `pow`, `log`, `log2`, `exp`, `exp2`, `fabs`, `nan`, `infinite`, `isinfinite`, `isnan`, `isnormal`, `abs`, `significand`, `logb`, `cbrt`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `hypot`, `remainder`, `tgamma`, `lgamma`, `j0`, `j1`, `nearbyint`, `rint`, `trunc`, `scalb`, `scalbln`, `ldexp`, `fma`, `drem`, `exp10`, `log10` |
| [x] | **Array** | `transpose`, `bsearch`, `recurse` |
| [ ] | **Array (remaining)** | `nth`, `combinations`, `walk` |
| [x] | **Object** | `paths`, `leaf_paths`, `map_values`, `getpath`, `setpath`, `delpaths` |
| [ ] | **Object (remaining)** | `pick` |
| [x] | **I/O** | `input`, `inputs`, `debug`, `stderr`, `halt`, `halt_error` |
| [x] | **Env** | `env`, `builtins` |
| [ ] | **Env (remaining)** | `$ENV`, `$__loc__` |
| [ ] | **SQL-style** | `INDEX`, `IN`, `JOIN`, `GROUP_BY` |
| [ ] | **Date/time** | `now`, `gmtime`, `mktime`, `strftime`, `strptime`, `strflocaltime`, `todate`, `fromdate`, `todateiso8601`, `fromdateiso8601` |
| [x] | **Type selectors** | `arrays`, `objects`, `iterables`, `booleans`, `numbers`, `strings`, `nulls`, `normals`, `scalars`, `values` |
| [ ] | **Type selectors (remaining)** | `finites` |
| [x] | **Misc** | `isempty`, `ascii`, `first`, `last` |
| [ ] | **Misc (remaining)** | `utf8bytelength`, `splits`, `repeat`, `skip`, `until`, `while`, `limit/2` |

### Performance

| | Item | Detail |
|---|------|--------|
| [ ] | **SIMD structural scanner** | AVX2 (x86_64), NEON (aarch64). Classify bytes 32/16 at a time. Already architected in parser — needs the actual intrinsics. |
| [x] | **Parallel file mode** | mmap + chunk-based workers. Auto-enabled in CLI. Achieved **21x vs jq, 14x vs jaq** on 15M-record JSONL `.id`. |
| [ ] | **Parallel single-file arrays** | Detect top-level `[{...}, {...}, ...]`. Scan for object boundaries at bracket depth 1, split across workers. |
| [x] | **Benchmark suite** | `benchmarks/` directory. Hyperfine scripts comparing zq vs jq vs jaq. 5 scenarios: parallelism, memory, startup, streaming, complex query. |
| [x] | **Startup time** | Target < 3ms cold start. Achieved: 0.8ms (6x faster than jq). |
| [x] | **Memory efficiency** | Target < 2x input size. **Achieved: 0.31x for `.id`, 0.64x for `select()`.** Total reduction: -87%. |

### CLI — remaining flags

| | Feature | Detail |
|---|---------|--------|
| [ ] | `-P N` / `--parallel N` | **zq extension.** Process JSONL with N worker threads. Default: auto. |
| [ ] | `--stream` | Streaming path-value event output |
| [ ] | `--seq` | RFC 7464 JSON Sequence support |
| [x] | `-C` / `--color-output` | ANSI color for TTY |
| [x] | `-M` / `--monochrome-output` | Disable color |
| [ ] | `--slurpfile NAME FILE` | Read file into variable as array |
| [ ] | `--rawfile NAME FILE` | Read file into variable as string |
| [ ] | `--unbuffered` | Flush after each value |

### Module system

| | Item | Detail |
|---|------|--------|
| [ ] | `import "path" as name;` | Load module definitions |
| [ ] | `include "path";` | Inline module definitions |
| [ ] | `-L dir` | Module search path |
| [ ] | `modulemeta` | Module metadata access |

### Infrastructure

| | Item | Detail |
|---|------|--------|
| [ ] | Man page (`zq.1`) | Generated from structured source |
| [ ] | Shell completions | bash, zsh, fish |
| [ ] | CI benchmark regression | Fail CI if throughput drops > 10% vs previous release |
| [ ] | Fuzz testing | AFL/libfuzzer on parser + query compiler |
| [x] | Release automation | GitHub Actions: tag -> build 6 platforms -> create release -> publish npm + PyPI + Homebrew + AUR |

---

## v1.0.0 — Agent Native

> Goal: Drop-in jq replacement where agents are first-class citizens.
> `alias jq=zq` is safe for everyone. Every agent framework has zq integration.
> zq is the default JSON tool in agent toolkits.

### Milestone criteria

- [ ] 100% jq compat test pass rate (or documented intentional deviations)
- [ ] Every jq CLI flag works identically
- [ ] Published on: brew, apt/deb, AUR, nix, scoop, static binaries, Docker
- [ ] Man page, website with benchmarks and migration guide
- [ ] libzq with stable C ABI and pkg-config
- [ ] Security audit (at minimum: fuzz coverage, no UB in release builds)
- [ ] Language bindings: Python, Node, Go (community-maintained)

### Agent ecosystem

| | Feature | What it does | Why it matters |
|---|---------|-------------|---------------|
| [ ] | **Agent framework integrations** | Pre-built tool definitions for LangChain, CrewAI, AutoGen, Claude Agent SDK. | Agents in any framework can use zq with zero configuration. |
| [ ] | **`--schema FILE`** | Validate input against JSON Schema before processing. Exit with structured error on mismatch. | Agents can enforce data contracts in pipelines. |
| [x] | **LSP (Language Server)** | Language server for jq filter syntax. Autocomplete, hover docs, error diagnostics, references, rename, semantic tokens, formatting. `zq --lsp` | Coding agents (Cursor, Copilot, Claude Code) get IDE-level support when writing zq filters. |
| [ ] | **VS Code extension** | Syntax highlighting + LSP integration for `.jq` filter files. | Coding agents working in VS Code/Cursor get first-class zq support. |
| [ ] | **Plugin system** | Custom builtins via shared library. Load with `--plugin path.so`. Uses the C ABI. | Agents can extend zq for domain-specific workflows without forking. |
| [ ] | **`zq serve`** | Long-running HTTP/gRPC server mode. POST JSON + filter, get results. Connection pooling, compiled query caching. | Agents in networked environments (k8s, microservices) can call zq without process spawn overhead. |
| [ ] | **Telemetry hooks** | Optional structured logging of queries, errors, and performance to stderr or a file. | Agent orchestrators can monitor zq usage, detect failure patterns, and optimize workflows. |

### Conformance

| | Item | Detail |
|---|------|--------|
| [ ] | **100% test pass rate** | All ~600 jq tests pass, or deviations documented in `DEVIATIONS.md` |
| [ ] | **Intentional deviations** | Documented improvements over jq (e.g., large integer handling). Each deviation has a rationale. |
| [ ] | **Edge case parity** | `nan`/`infinite` arithmetic, division by zero, negative zero, empty input, duplicate keys, deeply nested structures |
| [ ] | **Error message parity** | Error messages need not be identical but must convey the same information |

### Distribution

| | Channel | Detail |
|---|---------|--------|
| [x] | **Static binaries** | All 6 platforms via GitHub Releases |
| [x] | **Homebrew** | `brew install Enriquefft/zq/zq` |
| [ ] | **APT/DEB** | PPA or direct .deb |
| [x] | **AUR** | `yay -S zq-bin` |
| [x] | **Nix** | `nix run github:Enriquefft/zq` |
| [ ] | **Scoop** | Windows package manager |
| [x] | **Docker** | `docker run ghcr.io/enriquefft/zq` |
| [x] | **GitHub Releases** | Automated via CI on tag push |
| [x] | **npm** | `npx @zqjson/zq` — for Node/JS agent environments |
| [x] | **PyPI** | `pip install zq-json` — for Python agent environments |

### libzq (C ABI)

| | Item | Detail |
|---|------|--------|
| [ ] | **Stable ABI** | Versioned symbols. ABI breaks only on major version. |
| [ ] | **pkg-config** | `pkg-config --libs libzq` |
| [ ] | **Header file** | `zq.h` with full documentation |
| [ ] | **Shared library** | `.so` / `.dylib` / `.dll` builds |
| [ ] | **Language bindings** | Python (cffi), Node (ffi-napi), Go (cgo). Community-maintained, not in-tree. |

### Memory optimization

| | Item | Detail |
|---|------|--------|
| [x] | **Adaptive chunk sizing** | Fewer, larger chunks on memory-constrained systems. Detect available memory and adjust chunk count accordingly. |
| [x] | **Two-path execution** | Per-record queries use streaming output — emit and free immediately. Aggregation queries necessarily buffer. |
| [x] | **`madvise(MADV_DONTNEED)` page reclaim** | Workers call `madvise(MADV_DONTNEED)` on mmap chunk pages after serializing output. Bounds mmap RSS to `in_flight × chunk_size`. **Result: 0.31x RSS for `.id`, 0.64x for `select()`.** |

### Documentation

| | Item | Detail |
|---|------|--------|
| [ ] | **Man page** | `man zq` — complete CLI reference |
| [ ] | **Website** | Landing page with benchmarks, examples, migration guide |
| [ ] | **Migration guide** | "Switching from jq to zq" — flag mapping, known deviations, FAQ |
| [ ] | **Filter cookbook** | Common recipes: API response parsing, log processing, LLM output handling |
| [ ] | **Agent integration guide** | "Using zq in automated workflows" — MCP setup, Python bindings, error handling patterns for agents |

### Quality

| | Item | Detail |
|---|------|--------|
| [ ] | **Fuzz testing** | Continuous fuzzing via OSS-Fuzz or equivalent |
| [ ] | **No undefined behavior** | `zig build -Doptimize=ReleaseSafe` as default. Debug + ReleaseSafe + ReleaseFast all green. |
| [ ] | **Memory leak testing** | All tests pass under Zig's GPA leak detection |
| [ ] | **CI matrix** | Linux x86_64, Linux aarch64, macOS x86_64, macOS aarch64. Zig 0.15.x. |
| [ ] | **Reproducible builds** | Same source -> same binary (bit-for-bit) |

---

## v2.0.0 — Better

> Goal: Features that make zq strictly better than jq — not just faster and more
> agent-friendly, but capable of things jq fundamentally cannot do.

### Native parallel JSONL

The killer feature. Pool module fully implemented; needs CLI surface.

| | Item | Detail |
|---|------|--------|
| [ ] | `-P 0` / `--parallel auto` | CLI flag pending; parallelism is already auto-enabled in file mode. |
| [x] | **In-order output guarantee** | Chunk-level Sequencer delivers ChunkResults in submission order. |
| [x] | **Per-line error handling** | Parse/query errors become RecordOutcome.err; surfaced per-record without aborting. |
| [x] | **Work stealing** | MPMC JobQueue with N_CHUNKS jobs; workers pull freely. Newline-aligned byte-range chunks. |
| [x] | **Stream pipeline** | IO thread reads stdin in 256 KB batches. InFlightLimiter backpressure. **Result: 215s -> 1.4s (150x faster), 7 MB RSS.** |
| [ ] | **Scaling** | Near-linear scaling up to core count on JSONL. |

### Streaming & incomplete JSON (LLM use case)

zq's parser already auto-closes truncated containers. This section surfaces that
capability and extends it for the LLM streaming workflow.

| | Item | Detail |
|---|------|--------|
| [ ] | `--stream-recover` | Process incomplete JSON by auto-closing truncated containers. Already implemented in parser — needs CLI flag. |
| [ ] | `--follow` / `-f` | Like `tail -f` — keep reading as new data arrives. |
| [x] | **O(n) incremental parsing** | Parser maintains state across `feed()` calls. No re-parsing from position 0. |
| [x] | **Partial string completion** | `"hel` -> `"hel"` (close the string). Auto-close implemented for all containers. |
| [ ] | **SSE parsing** | Parse `data: {...}` lines from Server-Sent Events. Strip `data: ` prefix automatically. |

### Number precision

| | Item | Detail |
|---|------|--------|
| [x] | **i64 integers** | Tape stores integers as i64. Exact to 2^63 - 1. No silent float promotion. |
| [ ] | **Literal passthrough** | Numbers never modified by arithmetic output verbatim from source bytes. |
| [ ] | **i128 / bigint for arithmetic** | When i64 overflows, promote to i128 or arbitrary precision rather than silently wrapping. |
| [ ] | **Precision loss warning** | When precision is lost, emit a warning to stderr (opt-in via `--warn-precision`). |

### Extended input formats

| | Format | Detail |
|---|--------|--------|
| [x] | **NDJSON / JSONL** | Newline-delimited JSON. Already the default multi-document mode. |
| [ ] | **JSONC** | JSON with `//` and `/* */` comments. Very common in config files. |
| [ ] | **YAML** | Read YAML input, apply jq filters, output JSON. |
| [ ] | **TOML** | Read TOML input, apply jq filters, output JSON. |
| [ ] | **CSV/TSV** | Read CSV/TSV with header row -> array of objects. `--csv-input`, `--tsv-input`. |
| [ ] | **MessagePack** | Binary JSON. Read MessagePack, apply jq filters, output JSON or MessagePack. |
| [ ] | **CBOR** | Binary JSON (IETF standard). Similar to MessagePack support. |

### Extended output formats

| | Format | Flag | Detail |
|---|--------|------|--------|
| [ ] | YAML | `--yaml-output` | Output as YAML instead of JSON |
| [ ] | CSV | `--csv-output` | Output as CSV (requires flat objects) |
| [ ] | TSV | `--tsv-output` | Output as TSV |
| [ ] | MessagePack | `--msgpack-output` | Binary JSON output |
| [ ] | Table | `--table` | ASCII table for terminal display |

### Better errors

| | Item | Detail |
|---|------|--------|
| [x] | **Filter position** | Points to the exact character in the filter that failed, with `^~~~` underline. |
| [x] | **Input context** | Shows the JSON value that caused the error (input_preview in diagnostics). |
| [x] | **User error surfacing** | `error("msg")` surfaces the message in stderr output and JSON errors. |
| [ ] | **Suggestions** | "did you mean `;` instead of `,`?" for common jq syntax mistakes |
| [ ] | **Color errors** | Red/yellow ANSI coloring when stderr is a TTY |
| [ ] | **Stack trace** | For `def` recursion: show the call chain that led to the error |

### Performance features

| | Item | Detail |
|---|------|--------|
| [x] | **Query plan caching** | Query compiled once; ResultIterator reset() per record reuses eval stack. |
| [x] | **Tape arena allocator** | Per-chunk ArenaAllocator in pool. Zero GPA calls in the hot path for scalars. |
| [x] | **Output batching** | 64 KB buffered writes in the output module. |
| [x] | **mmap for large files** | io module (zero-copy reads) + pool submit_file (mmap -> byte-range chunks -> workers). |
| [ ] | **Prefetch** | Issue `madvise(MADV_SEQUENTIAL)` for large file scans. |

### Agent integration (deferred from v0.1)

| | Item | Detail |
|---|------|--------|
| [ ] | **MCP server** | zq as a Model Context Protocol tool. Agents call `query_json`, `describe_json`, `validate_filter` as structured tool calls. Nice-to-have — agents already use zq effectively via CLI with `--json-errors` and `--describe`. |
| [ ] | **`--tool-spec`** | Output a JSON tool definition (OpenAPI-compatible) describing zq's capabilities, flags, and builtins. Universal discovery beyond MCP. |
| [ ] | **MCP registry listing** | List zq in Anthropic's MCP registry and other agent tool directories after MCP server stabilizes. |

### Developer experience

| | Item | Detail |
|---|------|--------|
| [ ] | **REPL mode** | `zq --repl` — interactive filter development with instant feedback. |
| [ ] | **`--explain`** | Print human-readable description of what a filter does. |
| [ ] | **`--validate`** | Check filter syntax without executing. Exit 0 if valid, 2 if syntax error. |
| [ ] | **`--schema FILE`** | Validate input against JSON Schema. |
| [ ] | **Filter comments** | Allow `#` comments in filter files. |

---

## Deliberate Deviations from jq

These are cases where zq intentionally behaves differently from jq, because jq's
behavior is considered a bug, a footgun, or a missed opportunity.

| Behavior | jq | zq | Rationale |
|----------|----|----|-----------|
| Large integers | Silently converted to f64, losing precision above 2^53 | Stored as i64 (exact to 2^63). Arithmetic overflow returns error. | Data integrity. |
| Division by zero | Returns error or `nan` inconsistently | `nan` for `0/0`, `infinite` for `n/0` (n>0), `-infinite` for `n/0` (n<0). IEEE 754. | Consistency. |
| `input` with no remaining input | Error | Empty output (no values) | Composability with generators. Matches jaq. |
| Duplicate object keys | Last value wins silently | Last value wins, but `--warn-duplicate-keys` emits stderr warning | Data integrity. |
| Streaming incomplete JSON | Error | Auto-close truncated containers (opt-in via `--stream-recover`) | LLM streaming use case. |
| Filter comments | Not supported | `#` comments in filter files | Developer experience. |
| Error output | Human-readable text only | `--json-errors` for structured JSON errors | Agent integration. |
| Null propagation | Silent null on missing fields | `--strict` errors on null field access | Agent reliability. |

---

## Success Metrics

| Metric | Current | v0.1 | v0.5 | v1.0 |
|--------|---------|------|------|------|
| jq compat test pass rate | **61.4%** (327/533) | 60% | 95% | 100% |
| Throughput vs jq (parallel, `.id`) | **21x** (1.67s vs 35.1s) | > 1x | 5x | 10x |
| Throughput vs jq (parallel, `select() + transform`) | **23x** (1.66s vs 38.0s) | -- | 15x | 20x |
| Startup time | **~2ms** | < 3ms | < 3ms | < 3ms |
| Binary size (static, stripped) | **2.7 MB** | < 3 MB | < 3 MB | < 5 MB |
| Memory (1277 MB JSONL, `.id`) | **396 MB** (0.31x) | < 2x | < 2x | < 2x |
| Memory (1277 MB JSONL, `select()`) | **820 MB** (0.64x) | < 2x | < 2x | < 2x |
| Memory (streaming pipe) | **7 MB** | -- | -- | -- |
| Throughput vs jq (streaming, `.id`) | **16x** (1.4s vs 22.2s) | -- | -- | 10x |
| Test count | **302 compat + module** | 400+ | 800+ | 1000+ |
| Agent integration | **--json-errors, --describe, --validate, exit codes, C ABI errors, llms.txt, 134 builtins, LSP, npm, PyPI** | -- | Python bindings, WASM | Framework integrations, MCP |

---

## Execution Principles

1. **Agents first.** Every feature is evaluated through the lens of "would an agent
   choose zq over jq because of this?" Structured errors before pretty errors.
   Machine-readable output before human-readable output. Discoverability before
   documentation.

2. **Compatibility second.** Every filter in the jq manual should work in zq. Users
   (and agents) will not switch if their existing scripts break. But compatibility
   serves agent adoption — agents already know jq syntax.

3. **Measure everything.** No performance claim without a reproducible benchmark.
   "Faster" means a published number, not a feeling.

4. **One module at a time.** The deep modules architecture means each module can
   evolve independently. The query VM is the critical path for v0.1 — everything
   else is already in place.

5. **Test against jq, not against ourselves.** The compat test suite is the source
   of truth. A feature is done when jq's own tests pass.

6. **Ship early.** v0.1 with 60% compat, `--json-errors`, and `--describe` is more
   valuable than a perfect v1.0 that never ships. Agents can start choosing zq
   for simple workflows immediately.
