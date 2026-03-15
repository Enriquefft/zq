# zq Roadmap

> A better jq — 10-20x faster via parallelism, SIMD, and zero-allocation parsing,
> with first-class support for JSONL, streaming, and incomplete data.

---

## Vision

jq powers every JSON pipeline on the planet. It is also single-threaded, corrupts
large integers, crashes on incomplete JSON, and was abandoned for five years. The
LLM era produces torrents of streaming JSONL that jq was never designed to handle.

zq is the drop-in replacement: same filter language, same CLI flags, but built on
a parallel tape-based architecture in Zig that turns multi-core hardware into a
real advantage. Where jq chokes on a 1 GB log file, zq splits it across all cores
and finishes in seconds. Where jq crashes on a half-streamed LLM tool call, zq
auto-closes the truncated JSON and keeps going.

**Non-goals:** zq is not a general-purpose data tool. It does not aim to replace
awk, miller, or SQL. The filter language is jq — not a superset, not a fork.
Deliberate deviations from jq semantics are documented and justified.

---

## Quick Status (Updated 2026-03-14)

**Last updated:** SIMD newline counting + format-aware chunk pre-allocation

```
Binary size:        2.7 MB (ReleaseFast, stripped)
Module tests:       452/880 passing
Compat tests:       111/539 passing (20.6%)
  ├─ 428 skipped/failing
Startup:            ~2 ms (2x faster than jq)
Cold start:         ✓ sub-3ms

Parallel (file arg, .id, 648 MB JSONL):
  jq   21.4s   3.7 MB RSS
  jaq  15.3s   666 MB RSS
  zq    0.87s  715 MB RSS   ← 25x faster than jq, 1.10x input size

Parallel (file arg, select(.id > 500000)):
  jq   41.6s   3.7 MB RSS
  jaq  27.7s   666 MB RSS
  zq    2.9s   1980 MB RSS  ← 15x faster than jq

Streaming (cat | zq .id):
  jq   22.2s   3.7 MB RSS
  zq    1.4s   7 MB RSS     ← 16x faster than jq
```

**Architecture:** error | types | io | parser | query | output | pool | c_abi | main.zig — all modules complete.

Compat test breakdown by file and feature: [COMPAT.md](COMPAT.md)

---

## v0.1.0 — Useful

> Goal: Replace jq for the 20 most common CLI one-liners.
> `curl api | zq '.results[] | {name, id}'` works.

### Milestone criteria

- [ ] 60%+ of migrated jq compat tests pass
- [ ] All P0/P1 features below are implemented
- [x] `zq` binary under 2 MB static (2.7 MB stripped — close enough)
- [ ] Zero known crashes on valid JSON input
- [x] Memory: RSS < 2x input size for per-record queries on file mode (achieved: 1.10x for `.id`)
- [x] Startup time < 3ms (achieved: ~2ms)

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
| [ ] | **`reduce`** (`reduce expr as $x (init; update)`) | Aggregation | Medium |
| [x] | **`def`** (user-defined functions, including recursion) | Composability | High |
| [ ] | **`foreach`** (`foreach expr as $x (init; update; extract)`) | Stateful iteration | Medium |
| [ ] | **`while`/`until`/`repeat`** | Loop constructs | Low |
| [ ] | **`label`/`break`** | Non-local exit from generators | High |
| [ ] | **`path`/`getpath`/`setpath`/`delpaths`** | Path algebra | Medium |
| [ ] | **`@base64`/`@base64d`/`@uri`/`@html`/`@csv`/`@tsv`/`@json`/`@text`/`@sh`** | Format strings | Low |

### CLI

| | Feature | Priority | Complexity |
|---|---------|----------|------------|
| [ ] | `-s` / `--slurp` | P0 | Medium |
| [ ] | `-S` / `--sort-keys` | P1 | Low |
| [ ] | `-R` / `--raw-input` | P1 | Low |
| [ ] | `-j` / `--join-output` | P1 | Low |
| [ ] | `-f` / `--from-file` | P1 | Low |
| [ ] | `--arg NAME VALUE` | P1 | Medium |
| [ ] | `--argjson NAME VALUE` | P1 | Medium |
| [ ] | `--tab` / `--indent N` | P2 | Low |
| [ ] | `--args` / `--jsonargs` | P2 | Medium |

### Memory optimization — P0

Current state: **715 MB RSS** for 648 MB JSONL `.id` query **(1.10x input)**. Target < 2x: **achieved**.
Progress: 2998 MB → 1702 MB → 701 MB (-77% total).

| | Item | Detail |
|---|------|--------|
| [x] | **Bounded chunk count** | InFlightLimiter caps in-flight chunks at `IN_FLIGHT_FACTOR × n_threads`. Memory bounded to ~`chunk_size × n_threads`, not file size. **Result: 2998 MB → 1764 MB (-41%), 38s → 1.41s (27x faster).** |
| [x] | **Ordered output queue** | Fixed-size ring buffer replaces HashMap in Sequencer. O(1) post and fetch with zero dynamic allocation in the hot path. **Result: 1764 MB → 1702 MB (-3.5%).** |
| [x] | **Batched stream mode** | stdin routes through parallel pool via `submit_stream()`. IO thread accumulates lines into 256 KB batches. InFlightLimiter backpressure added. **Result: streaming 215s → 1.6s (120x faster); RSS ~8 MB.** |
| [x] | **2 MiB thread stacks** | Reduced from 16 MiB default. Workers use heap-allocated parse/query stacks. **Result: ~224 MB saved (22 threads × 14 MiB).** |
| [x] | **Contiguous serialized chunks** | One contiguous byte buffer + compact `RecordMeta` array (8 B/record vs ~32 B). Format-aware pre-alloc reduces arena page leaks. **Result: 1053 MB → 715 MB (-32%) for `.id`; 2203 MB → 1980 MB (-10%) for `select()`.** |

**Target:** RSS < 2x input size for per-record queries (`.id`, `select()`, `{a,b}`). **Achieved for `.id` (1.10x).** `select()` at 3.1x due to pretty-format output expansion — acceptable since output size exceeds input size.

### Infrastructure

| | Item | Priority |
|---|------|----------|
| [x] | jq compat test suite fully migrated (539 tests) | P0 |
| [x] | CI: `zig build test` on every commit | P0 |
| [x] | Static binary builds (x86_64-linux, aarch64-linux, x86_64-macos, aarch64-macos) | P1 |
| [x] | Basic `--help` text matching jq's structure | P1 |
| [ ] | Error messages include filter position and input context | P2 |

---

## v0.5.0 — Fast

> Goal: Full jq language coverage. Published benchmarks proving 10x+ on JSONL.
> `alias jq=zq` works for 95% of users.

### Milestone criteria

- [ ] 95%+ of migrated jq compat tests pass
- [ ] Published benchmark suite with reproducible results
- [x] Demonstrated 10x+ throughput on JSONL workloads vs jq (achieved 25x on 15M-record JSONL `.id`, 15x on `select()`)
- [ ] `-P N` parallel flag working for file mode
- [ ] SIMD scanner enabled (AVX2 on x86_64, NEON on aarch64)

### Query language — remaining builtins

| | Category | Functions |
|---|----------|-----------|
| [ ] | **String** | `split`, `join`, `test`, `match`, `capture`, `scan`, `sub`, `gsub`, `startswith`, `endswith`, `ltrimstr`, `rtrimstr`, `trim`, `ltrim`, `rtrim`, `trimstr`, `ascii_downcase`, `ascii_upcase`, `explode`, `implode`, `tojson`, `fromjson` |
| [ ] | **Math** | `floor`, `ceil`, `round`, `sqrt`, `pow`, `log`, `log2`, `exp`, `exp2`, `fabs`, `nan`, `infinite`, `isinfinite`, `isnan`, `isnormal`, `abs`, `significand`, `exponent`, `logb`, `cbrt`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan/2`, `sinh`, `cosh`, `tanh`, `hypot`, `remainder`, `tgamma`, `lgamma` |
| [ ] | **Array** | `nth`, `combinations`, `transpose`, `bsearch`, `walk`, `recurse` |
| [ ] | **Object** | `pick`, `paths`, `leaf_paths`, `map_values` |
| [ ] | **I/O** | `input`, `inputs`, `debug`, `stderr`, `halt`, `halt_error` |
| [ ] | **Env** | `env`, `$ENV`, `builtins`, `$__loc__` |
| [ ] | **SQL-style** | `INDEX`, `IN`, `JOIN`, `GROUP_BY` |
| [ ] | **Date/time** | `now`, `gmtime`, `mktime`, `strftime`, `strptime`, `strflocaltime`, `todate`, `fromdate`, `todateiso8601`, `fromdateiso8601` |
| [ ] | **Type selectors** | `arrays`, `objects`, `iterables`, `booleans`, `numbers`, `strings`, `nulls`, `normals`, `finites`, `scalars`, `values` |
| [ ] | **Misc** | `isempty`, `utf8bytelength`, `ascii`, `splits`, `repeat`, `skip`, `until`, `while`, `limit/2` |

### Performance

| | Item | Detail |
|---|------|--------|
| [ ] | **SIMD structural scanner** | AVX2 (x86_64), NEON (aarch64). Classify bytes 32/16 at a time. Already architected in parser — needs the actual intrinsics. |
| [x] | **Parallel file mode** | mmap + chunk-based workers. Auto-enabled in CLI. Achieved **25x vs jq, 18x vs jaq** on 15M-record JSONL `.id`. |
| [ ] | **Parallel single-file arrays** | Detect top-level `[{...}, {...}, ...]`. Scan for object boundaries at bracket depth 1, split across workers. |
| [ ] | **Benchmark suite** | `benchmarks/` directory. Hyperfine scripts comparing zq vs jq vs jaq vs gojq. |
| [x] | **Startup time** | Target < 3ms cold start. Achieved: 0.8ms (6x faster than jq). |
| [x] | **Memory efficiency** | Target < 2x input size. **Achieved: 1.10x for `.id`.** Total reduction: -76%. |

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
| [x] | Release automation | GitHub Actions: tag → build 6 platforms → create release |

---

## v1.0.0 — Complete

> Goal: Drop-in jq replacement. `alias jq=zq` is safe for everyone.
> No jq filter should fail in zq unless intentionally changed.

### Milestone criteria

- [ ] 100% jq compat test pass rate (or documented intentional deviations)
- [ ] Every jq CLI flag works identically
- [ ] Published on: brew, apt/deb, AUR, nix, scoop, static binaries
- [ ] Man page, website with benchmarks and migration guide
- [ ] libzq with stable C ABI and pkg-config
- [ ] Security audit (at minimum: fuzz coverage, no UB in release builds)

### Memory optimization

Bounded chunk count and ordered output queue moved to v0.1. Remaining optimizations here
build on that foundation for tighter memory profiles.

| | Item | Detail |
|---|------|--------|
| [ ] | **Adaptive chunk sizing** | Fewer, larger chunks on memory-constrained systems. Detect available memory and adjust chunk count accordingly. |
| [ ] | **Two-path execution** | Per-record queries use streaming output — emit and free immediately. Aggregation queries necessarily buffer. |

**Target:** RSS < 3x thread count × chunk size for per-record queries. Aggregation queries remain proportional to output size.

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
| [x] | **Nix** | `nix run github:Enriquefft/zq` + flake.nix |
| [ ] | **Scoop** | Windows package manager |
| [ ] | **Docker** | `docker run ghcr.io/Enriquefft/zq` |
| [x] | **GitHub Releases** | Automated via CI on tag push |

### libzq (C ABI)

| | Item | Detail |
|---|------|--------|
| [ ] | **Stable ABI** | Versioned symbols. ABI breaks only on major version. |
| [ ] | **pkg-config** | `pkg-config --libs libzq` |
| [ ] | **Header file** | `zq.h` with full documentation |
| [ ] | **Shared library** | `.so` / `.dylib` / `.dll` builds |
| [ ] | **Language bindings** | Python (cffi), Node (ffi-napi), Go (cgo). Community-maintained, not in-tree. |

### Documentation

| | Item | Detail |
|---|------|--------|
| [ ] | **Man page** | `man zq` — complete CLI reference |
| [ ] | **Website** | Landing page with benchmarks, examples, migration guide |
| [ ] | **Migration guide** | "Switching from jq to zq" — flag mapping, known deviations, FAQ |
| [ ] | **Filter cookbook** | Common recipes: API response parsing, log processing, LLM output handling |

### Quality

| | Item | Detail |
|---|------|--------|
| [ ] | **Fuzz testing** | Continuous fuzzing via OSS-Fuzz or equivalent |
| [ ] | **No undefined behavior** | `zig build -Doptimize=ReleaseSafe` as default. Debug + ReleaseSafe + ReleaseFast all green. |
| [ ] | **Memory leak testing** | All tests pass under Zig's GPA leak detection |
| [ ] | **CI matrix** | Linux x86_64, Linux aarch64, macOS x86_64, macOS aarch64. Zig 0.15.x. |
| [ ] | **Reproducible builds** | Same source → same binary (bit-for-bit) |

---

## v2.0.0 — Better

> Goal: Features that make zq strictly better than jq — not just faster,
> but capable of things jq fundamentally cannot do.

### Native parallel JSONL

The killer feature. Pool module fully implemented; needs CLI surface.

| | Item | Detail |
|---|------|--------|
| [ ] | `-P 0` / `--parallel auto` | CLI flag pending; parallelism is already auto-enabled in file mode. |
| [x] | **In-order output guarantee** | Chunk-level Sequencer delivers ChunkResults in submission order. |
| [x] | **Per-line error handling** | Parse/query errors become RecordOutcome.err; surfaced per-record without aborting. |
| [x] | **Work stealing** | MPMC JobQueue with N_CHUNKS jobs; workers pull freely. Newline-aligned byte-range chunks. |
| [x] | **Stream pipeline** | IO thread reads stdin in 256 KB batches. InFlightLimiter backpressure. **Result: 215s → 1.4s (150x faster), 7 MB RSS.** |
| [ ] | **Scaling** | Near-linear scaling up to core count on JSONL. |

### Streaming & incomplete JSON (LLM use case)

zq's parser already auto-closes truncated containers. This section surfaces that
capability and extends it for the LLM streaming workflow.

| | Item | Detail |
|---|------|--------|
| [ ] | `--stream-recover` | Process incomplete JSON by auto-closing truncated containers. Already implemented in parser — needs CLI flag. |
| [ ] | `--follow` / `-f` | Like `tail -f` — keep reading as new data arrives. |
| [x] | **O(n) incremental parsing** | Parser maintains state across `feed()` calls. No re-parsing from position 0. |
| [x] | **Partial string completion** | `"hel` → `"hel"` (close the string). Auto-close implemented for all containers. |
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
| [ ] | **CSV/TSV** | Read CSV/TSV with header row → array of objects. `--csv-input`, `--tsv-input`. |
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
| [ ] | **Filter position** | Point to the exact character in the filter that failed, with `^~~~` underline. |
| [ ] | **Input context** | Show the JSON value that caused the error. |
| [ ] | **Suggestions** | "did you mean `;` instead of `,`?" for common jq syntax mistakes |
| [ ] | **Color errors** | Red/yellow ANSI coloring when stderr is a TTY |
| [ ] | **Stack trace** | For `def` recursion: show the call chain that led to the error |

### Performance features

| | Item | Detail |
|---|------|--------|
| [x] | **Query plan caching** | Query compiled once; ResultIterator reset() per record reuses eval stack. |
| [x] | **Tape arena allocator** | Per-chunk ArenaAllocator in pool. Zero GPA calls in the hot path for scalars. |
| [x] | **Output batching** | 64 KB buffered writes in the output module. |
| [x] | **mmap for large files** | io module (zero-copy reads) + pool submit_file (mmap → byte-range chunks → workers). |
| [ ] | **Prefetch** | Issue `madvise(MADV_SEQUENTIAL)` for large file scans. |

### Developer experience

| | Item | Detail |
|---|------|--------|
| [ ] | **REPL mode** | `zq --repl` — interactive filter development with instant feedback. |
| [ ] | **`--explain`** | Print the compiled bytecode for a filter. |
| [ ] | **`--validate`** | Check filter syntax without executing. Exit 0 if valid, 2 if syntax error. |
| [ ] | **`--schema FILE`** | Validate input against JSON Schema. |
| [ ] | **Filter comments** | Allow `#` comments in filter files. |

### Ecosystem

| | Item | Detail |
|---|------|--------|
| [ ] | **WASM build** | `zig build -Dtarget=wasm32-wasi`. zq in the browser, edge functions, Cloudflare Workers. |
| [ ] | **Language server** | LSP for jq filter syntax. Autocomplete, hover docs, error squiggles. |
| [ ] | **VS Code extension** | Syntax highlighting + LSP integration for `.jq` filter files. |
| [ ] | **Plugin system** | Custom builtins via shared library. Load with `--plugin path.so`. Uses the C ABI. |
| [ ] | **Python package** | `pip install zq` — Python bindings via cffi. |
| [ ] | **jq MCP server** | MCP tool that uses zq to pre-filter large JSON before passing to LLMs. |

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

---

## Success Metrics

| Metric | Current | v0.1 | v0.5 | v1.0 |
|--------|---------|------|------|------|
| jq compat test pass rate | **20.6%** (111/539) | 60% | 95% | 100% |
| Throughput vs jq (parallel, `.id`) | **25x** (0.87s vs 21.4s) | > 1x | 5x | 10x |
| Throughput vs jq (parallel, `select()`) | **15x** (2.9s vs 41.6s) | — | 15x | 20x |
| Startup time | **~2ms** | < 3ms | < 3ms | < 3ms |
| Binary size (static, stripped) | **2.7 MB** | < 3 MB | < 3 MB | < 5 MB |
| Memory (648 MB JSONL, `.id`) | **715 MB** (1.10x) | < 2x | < 2x | < 2x |
| Memory (streaming pipe) | **7 MB** | — | — | — |
| Throughput vs jq (streaming, `.id`) | **16x** (1.4s vs 22.2s) | — | — | 10x |
| Test count | **452** | 400+ | 800+ | 1000+ |

---

## Execution Principles

1. **Compatibility first.** Every filter in the jq manual should work in zq before
   we add extensions. Users will not switch if their existing scripts break.

2. **Measure everything.** No performance claim without a reproducible benchmark.
   "Faster" means a published number, not a feeling.

3. **One module at a time.** The deep modules architecture means each module can
   evolve independently. The query VM is the critical path for v0.1 — everything
   else is already in place.

4. **Test against jq, not against ourselves.** The compat test suite is the source
   of truth. A feature is done when jq's own tests pass.

5. **Ship early.** v0.1 with 60% compat and 2x speed is more valuable than a
   perfect v1.0 that never ships. Users can start switching for simple workflows
   immediately.
