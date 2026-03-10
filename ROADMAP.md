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

## Quick Status (Updated 2026-03-10)

**Last updated:** Commit 590666f

```
Binary size:        203 KB (ReleaseFast, stripped)
Module tests:       249/249 passing ✓
Compat tests:       42/533 passing (8%)
  ├─ 450 skipped (unimplemented features)
  └─ 41 failing (real gaps)
Performance:        11.6x jq on 15M-line JSONL (parallel)
```

**Architecture:** error | types | io | parser | query | output | pool | c_abi | main.zig — all modules complete, all module tests green.

---

## v0.1.0 — Useful

> Goal: Replace jq for the 20 most common CLI one-liners.
> `curl api | zq '.results[] | {name, id}'` works.

### Milestone criteria

- [ ] 60%+ of migrated jq compat tests pass
- [ ] All P0/P1 features below are implemented
- [ ] `zq` binary under 2 MB static
- [ ] Zero known crashes on valid JSON input

### Query language — P0

These are table-stakes. Without them, zq cannot process real-world filters.

| Feature | Scope | What it unlocks |
|---------|-------|-----------------|
| [x] **Arithmetic** (`+`, `-`, `*`, `/`, `%`) | Compiler + VM | Object merge (`+`), string concat, array concat, numeric math. Unblocks ~40% of failing tests. |
| [ ] **Unary negation** (`-expr`) | Compiler + VM | `-1`, `-.foo` |
| [x] **Comparisons** (`==`, `!=`, `<`, `>`, `<=`, `>=`) | Compiler + VM | Required for `select`, `if/then`, sorting |
| [x] **Boolean operators** (`and`, `or`, `not`) | Compiler + VM | Required for any conditional logic |
| [ ] **Conditionals** (`if/then/elif/else/end`) | Compiler + VM | Control flow. ~20 blocked tests. |
| [x] **Variables** (`expr as $x \| ...`) | Compiler + VM (scope stack) | Required for object construction, reduce, def, and most non-trivial filters |
| [x] **Comma operator** (`a, b`) | Compiler + VM (generator stack) | Multiple outputs from a single expression. Required for array/object construction. |
| [x] **Object construction** (`{a: .b, c: .d}`) | Compiler + VM | The #1 real-world use case. Shorthand `{a}` = `{a: .a}`. Computed keys `{(.k): .v}`. |
| [ ] **Array construction** (`[expr]`) | Compiler + VM | Collect generator outputs into array. `[.[] \| .name]`. |
| [x] **String interpolation** (`"hello \(.name)"`) | Lexer + Compiler + VM | Very common in practice. Required for readable output. |
| [x] **Recursive descent** (`..`) | Compiler + VM | Deep search. `.. \| .name?` |
| [ ] **Pipe expressions in brackets** (`.[.foo]`, `.["key"]`) | Lexer + Compiler | String key access, computed index |

### Query language — P1

| Feature | Scope | What it unlocks |
|---------|-------|-----------------|
| [ ] **Alternative operator** (`//`) | Compiler + VM | Null coalescing. `(.foo // "default")` |
| [ ] **Try/catch** (`try expr catch expr`) | Compiler + VM | Error recovery. The LLM streaming use case. |
| [ ] **Optional operator** (`expr?`) | Compiler + VM | Suppress errors on missing keys. `.foo?` |
| [ ] **Slicing** (`.[2:4]`, `.[2:]`, `.[:4]`) | Compiler + VM | Array and string slicing |
| [ ] **Update assignment** (`\|=`, `+=`, `-=`, `*=`, `/=`, `%=`, `//=`) | Compiler + VM | In-place modification. `.foo \|= . + 1` |
| [ ] **Negative indexing** (`.[-1]`, `.[-2:]`) | VM | Last element, tail slicing |
| [ ] **Core builtins (tier 1)** | VM builtins table | `length`, `keys`, `values`, `has`, `in`, `type`, `empty`, `select`, `map`, `add`, `not`, `error`, `null`, `true`, `false`, `tostring`, `tonumber`, `range`, `keys_unsorted` |
| [ ] **Core builtins (tier 2)** | VM builtins table | `sort`, `sort_by`, `group_by`, `unique`, `unique_by`, `reverse`, `flatten`, `min`, `max`, `min_by`, `max_by`, `to_entries`, `from_entries`, `with_entries`, `del`, `contains`, `inside`, `any`, `all`, `limit`, `first`, `last`, `indices`, `index`, `rindex` |

### Query language — P2

| Feature | Scope |
|---------|-------|
| [ ] **`reduce`** (`reduce expr as $x (init; update)`) | Aggregation |
| [x] **`def`** (user-defined functions, including recursion) | Composability |
| [ ] **`foreach`** (`foreach expr as $x (init; update; extract)`) | Stateful iteration |
| [ ] **`while`/`until`/`repeat`** | Loop constructs |
| [ ] **`label`/`break`** | Non-local exit from generators |
| [ ] **`path`/`getpath`/`setpath`/`delpaths`** | Path algebra |
| [ ] **`@base64`/`@base64d`/`@uri`/`@html`/`@csv`/`@tsv`/`@json`/`@text`/`@sh`** | Format strings |

### CLI

| Feature | Priority |
|---------|----------|
| [ ] `-s` / `--slurp` | P0 — read all inputs into array |
| [ ] `-S` / `--sort-keys` | P1 — alphabetical key ordering in output |
| [ ] `-R` / `--raw-input` | P1 — read lines as strings |
| [ ] `-j` / `--join-output` | P1 — raw output without trailing newline |
| [ ] `-f` / `--from-file` | P1 — read filter from file |
| [ ] `--arg NAME VALUE` | P1 — bind string variable |
| [ ] `--argjson NAME VALUE` | P1 — bind JSON variable |
| [ ] `--tab` / `--indent N` | P2 — indentation control |
| [ ] `--args` / `--jsonargs` | P2 — positional arguments via `$ARGS` |

### Infrastructure

| Item | Priority |
|------|----------|
| [x] jq compat test suite fully migrated (533 tests) | P0 |
| [ ] CI: `zig build test` on every commit | P0 |
| [ ] Static binary builds (x86_64-linux, aarch64-linux, x86_64-macos, aarch64-macos) | P1 |
| [ ] Basic `--help` text matching jq's structure | P1 |
| [ ] Error messages include filter position and input context | P2 |

---

## v0.5.0 — Fast

> Goal: Full jq language coverage. Published benchmarks proving 10x+ on JSONL.
> `alias jq=zq` works for 95% of users.

### Milestone criteria

- [ ] 95%+ of migrated jq compat tests pass
- [ ] Published benchmark suite with reproducible results
- [x] Demonstrated 10x+ throughput on JSONL workloads vs jq (achieved 11.6x on 15M-record JSONL, 7.9x vs jaq)
- [ ] `-P N` parallel flag working for file mode
- [ ] SIMD scanner enabled (AVX2 on x86_64, NEON on aarch64)

### Query language — remaining builtins

| Category | Functions |
|----------|-----------|
| [ ] **String** | `split`, `join`, `test`, `match`, `capture`, `scan`, `sub`, `gsub`, `startswith`, `endswith`, `ltrimstr`, `rtrimstr`, `trim`, `ltrim`, `rtrim`, `trimstr`, `ascii_downcase`, `ascii_upcase`, `explode`, `implode`, `tojson`, `fromjson` |
| [ ] **Math** | `floor`, `ceil`, `round`, `sqrt`, `pow`, `log`, `log2`, `exp`, `exp2`, `fabs`, `nan`, `infinite`, `isinfinite`, `isnan`, `isnormal`, `abs`, `significand`, `exponent`, `logb`, `cbrt`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan/2`, `sinh`, `cosh`, `tanh`, `hypot`, `remainder`, `tgamma`, `lgamma` |
| [ ] **Array** | `nth`, `combinations`, `transpose`, `bsearch`, `walk`, `recurse` |
| [ ] **Object** | `pick`, `paths`, `leaf_paths`, `map_values` |
| [ ] **I/O** | `input`, `inputs`, `debug`, `stderr`, `halt`, `halt_error` |
| [ ] **Env** | `env`, `$ENV`, `builtins`, `$__loc__` |
| [ ] **SQL-style** | `INDEX`, `IN`, `JOIN`, `GROUP_BY` |
| [ ] **Date/time** | `now`, `gmtime`, `mktime`, `strftime`, `strptime`, `strflocaltime`, `todate`, `fromdate`, `todateiso8601`, `fromdateiso8601` |
| [ ] **Type selectors** | `arrays`, `objects`, `iterables`, `booleans`, `numbers`, `strings`, `nulls`, `normals`, `finites`, `scalars`, `values` |
| [ ] **Misc** | `isempty`, `utf8bytelength`, `ascii`, `splits`, `repeat`, `skip`, `until`, `while`, `limit/2` |

### Performance

| Item | Detail |
|------|--------|
| [ ] **SIMD structural scanner** | AVX2 (x86_64), NEON (aarch64). Classify bytes (structural, whitespace, string, escape) 32/16 at a time. Already architected in parser — needs the actual intrinsics. |
| [x] **Parallel file mode** | mmap + chunk-based workers. Pool module fully implemented and auto-enabled in CLI. `-P N` explicit flag still pending. Achieved **11.6x vs jq, 7.9x vs jaq** on 15M-record JSONL. |
| [ ] **Parallel single-file arrays** | Detect top-level `[{...}, {...}, ...]` in non-JSONL JSON files. Scan for object boundaries at bracket depth 1, split across workers using existing chunk infrastructure. Falls back to single-threaded for non-array inputs — no regression. Closes the biggest gap in the parallelism story (API responses, data dumps). |
| [ ] **Benchmark suite** | `benchmarks/` directory. Hyperfine scripts comparing zq vs jq vs jaq vs gojq on: citylots.json (181MB), github events (JSONL), twitter sample (nested), synthetic 1M-line JSONL. |
| [ ] **Startup time** | Target < 3ms cold start. Measure with `hyperfine --warmup 5 'echo null | zq .'`. jq is ~10ms, jaq is ~3ms. |
| [ ] **Memory efficiency** | Tape format should use < 2x input size in memory. Measure with `/usr/bin/time -v`. |

### CLI — remaining flags

| Feature | Detail |
|---------|--------|
| [ ] `-P N` / `--parallel N` | **zq extension.** Process JSONL with N worker threads. Default: auto. `-P 0` = auto-detect CPU count. |
| [ ] `--stream` | Streaming path-value event output |
| [ ] `--seq` | RFC 7464 JSON Sequence support |
| [ ] `-C` / `--color-output` | ANSI color for TTY |
| [ ] `-M` / `--monochrome-output` | Disable color |
| [ ] `--slurpfile NAME FILE` | Read file into variable as array |
| [ ] `--rawfile NAME FILE` | Read file into variable as string |
| [ ] `--unbuffered` | Flush after each value |

### Module system

| Item | Detail |
|------|--------|
| [ ] `import "path" as name;` | Load module definitions |
| [ ] `include "path";` | Inline module definitions |
| [ ] `-L dir` | Module search path |
| [ ] `modulemeta` | Module metadata access |

### Infrastructure

| Item | Detail |
|------|--------|
| [ ] Man page (`zq.1`) | Generated from structured source |
| [ ] Shell completions | bash, zsh, fish |
| [ ] CI benchmark regression | Fail CI if throughput drops > 10% vs previous release |
| [ ] Fuzz testing | AFL/libfuzzer on parser + query compiler |
| [ ] Release automation | GitHub Actions: tag → build static binaries → create release |

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

Current state: zq uses ~1.4 GB RSS for a 648 MB JSONL file (parallel mode). jq uses 3.5 MB. The parallelism speedup is worth the tradeoff today, but for v1.0 the memory profile should be competitive.

| Item | Detail |
|------|--------|
| [ ] **Ordered output queue** | Ring buffer of chunk slots that flushes sequentially. Chunks emit results in input order as each completes, freeing their arena immediately instead of buffering all results. Well-understood pattern — bounded memory regardless of file size. |
| [ ] **Bounded chunk count** | Cap in-flight chunks rather than splitting the entire file upfront. Workers pull the next chunk when they finish the current one. Memory is proportional to `chunk_size × thread_count`, not file size. |
| [ ] **Adaptive chunk sizing** | Fewer, larger chunks on memory-constrained systems. Detect available memory and adjust chunk count accordingly. Preserves parallelism while respecting system limits. |
| [ ] **Two-path execution** | Per-record queries (`.id`, `select()`) use streaming output — emit and free immediately. Aggregation queries (`group_by`, `sort_by`, `unique`) necessarily buffer — accept the memory cost, same as jq. |

**Target:** RSS < 3x thread count × chunk size for per-record queries. Aggregation queries remain proportional to output size.

### Conformance

| Item | Detail |
|------|--------|
| [ ] **100% test pass rate** | All ~600 jq tests pass, or deviations documented in `DEVIATIONS.md` |
| [ ] **Intentional deviations** | Documented improvements over jq (e.g., large integer handling). Each deviation has a rationale. |
| [ ] **Edge case parity** | `nan`/`infinite` arithmetic, division by zero, negative zero, empty input, duplicate keys, deeply nested structures |
| [ ] **Error message parity** | Error messages need not be identical but must convey the same information |

### Distribution

| Channel | Detail |
|---------|--------|
| [ ] **Static binaries** | x86_64-linux, aarch64-linux, x86_64-macos, aarch64-macos, x86_64-windows. Single file, no dependencies. |
| [ ] **Homebrew** | `brew install zq` |
| [ ] **APT/DEB** | PPA or direct .deb |
| [ ] **AUR** | `yay -S zq` |
| [ ] **Nix** | `nix run github:user/zq` + nixpkgs PR |
| [ ] **Scoop** | Windows package manager |
| [ ] **Docker** | `docker run ghcr.io/user/zq` |
| [ ] **GitHub Releases** | Automated via CI on tag push |

### libzq (C ABI)

| Item | Detail |
|------|--------|
| [ ] **Stable ABI** | Versioned symbols. ABI breaks only on major version. |
| [ ] **pkg-config** | `pkg-config --libs libzq` |
| [ ] **Header file** | `zq.h` with full documentation |
| [ ] **Shared library** | `.so` / `.dylib` / `.dll` builds |
| [ ] **Language bindings** | Python (cffi), Node (ffi-napi), Go (cgo). Community-maintained, not in-tree. |

### Documentation

| Item | Detail |
|------|--------|
| [ ] **Man page** | `man zq` — complete CLI reference |
| [ ] **Website** | Landing page with benchmarks, examples, migration guide |
| [ ] **Migration guide** | "Switching from jq to zq" — flag mapping, known deviations, FAQ |
| [ ] **Filter cookbook** | Common recipes: API response parsing, log processing, LLM output handling |

### Quality

| Item | Detail |
|------|--------|
| [ ] **Fuzz testing** | Continuous fuzzing via OSS-Fuzz or equivalent |
| [ ] **No undefined behavior** | `zig build -Doptimize=ReleaseSafe` as default. Debug + ReleaseSafe + ReleaseFast all green. |
| [ ] **Memory leak testing** | All tests pass under Zig's GPA leak detection |
| [ ] **CI matrix** | Linux x86_64, Linux aarch64, macOS x86_64, macOS aarch64. Zig 0.15.x. |
| [ ] **Reproducible builds** | Same source → same binary (bit-for-bit) |

---

## v2.0.0 — Better

> Goal: Features that make zq strictly better than jq — not just faster,
> but capable of things jq fundamentally cannot do.

### Native parallel JSONL

The killer feature. Pool module fully implemented; needs CLI surface.

| Item | Detail |
|------|--------|
| [ ] `-P 0` / `--parallel auto` | CLI flag pending; parallelism is already auto-enabled in file mode (pool uses `getCpuCount()`). |
| [x] **In-order output guarantee** | Chunk-level Sequencer delivers ChunkResults in submission order. collect() cursor walks records/values in order. |
| [x] **Per-line error handling** | Parse/query errors become RecordOutcome.err; collect() surfaces them per-record without aborting the pipeline. |
| [x] **Work stealing** | MPMC JobQueue with N_CHUNKS jobs; workers pull freely. Newline-aligned byte-range chunks prevent record splits. |
| [x] **Stream pipeline** | IO thread reads lines from stdin/pipe; each line is a single-record ChunkResult posted to the worker queue. |
| [ ] **Scaling** | Near-linear scaling up to core count on JSONL. Measured: 11.6x jq at 11 cores (1103% CPU). |

### Streaming & incomplete JSON (LLM use case)

zq's parser already auto-closes truncated containers. This section surfaces that
capability and extends it for the LLM streaming workflow.

| Item | Detail |
|------|--------|
| [ ] `--stream-recover` | Process incomplete JSON by auto-closing truncated containers. Already implemented in parser — needs CLI flag. |
| [ ] `--follow` / `-f` | Like `tail -f` — keep reading as new data arrives. For watching LLM streaming endpoints. |
| [x] **O(n) incremental parsing** | Parser maintains state across `feed()` calls. No re-parsing from position 0 on each chunk. |
| [x] **Partial string completion** | `"hel` → `"hel"` (close the string). Auto-close implemented in parser for all containers. |
| [ ] **SSE parsing** | Parse `data: {...}` lines from Server-Sent Events. Strip the `data: ` prefix automatically when detected. |

### Number precision

| Item | Detail |
|------|--------|
| [x] **i64 integers** | Tape stores integers as i64. Integers up to 2^63 - 1 are exact. No silent float promotion. |
| [ ] **Literal passthrough** | Numbers never modified by arithmetic output verbatim from source bytes. Requires storing original byte range in Tape entries. |
| [ ] **i128 / bigint for arithmetic** | When i64 overflows during `+`/`-`/`*`, promote to i128 or arbitrary precision rather than silently wrapping. |
| [ ] **Precision loss warning** | When a number must be converted to f64 and precision is lost, emit a warning to stderr (opt-in via `--warn-precision`). |

### Extended input formats

| Format | Detail |
|--------|--------|
| [x] **NDJSON / JSONL** | Newline-delimited JSON. Already the default multi-document mode. |
| [ ] **JSONC** | JSON with `//` and `/* */` comments. Strip comments during parsing. Very common in config files. |
| [ ] **YAML** | Read YAML input, apply jq filters, output JSON. Single-document and multi-document. |
| [ ] **TOML** | Read TOML input, apply jq filters, output JSON. |
| [ ] **CSV/TSV** | Read CSV/TSV with header row → array of objects. `--csv-input`, `--tsv-input`. |
| [ ] **MessagePack** | Binary JSON. Read MessagePack, apply jq filters, output JSON or MessagePack. |
| [ ] **CBOR** | Binary JSON (IETF standard). Similar to MessagePack support. |

### Extended output formats

| Format | Flag | Detail |
|--------|------|--------|
| [ ] YAML | `--yaml-output` | Output as YAML instead of JSON |
| [ ] CSV | `--csv-output` | Output as CSV (requires flat objects) |
| [ ] TSV | `--tsv-output` | Output as TSV |
| [ ] MessagePack | `--msgpack-output` | Binary JSON output |
| [ ] Table | `--table` | ASCII table for terminal display |

### Better errors

| Item | Detail |
|------|--------|
| [ ] **Filter position** | Error messages point to the exact character in the filter that failed. `error: TypeError at '.foo \| .bar': expected object, got array` with a `^~~~` underline. |
| [ ] **Input context** | Show the JSON value that caused the error: `input value: [1, 2, 3]` |
| [ ] **Suggestions** | "did you mean `;` instead of `,`?" for common jq syntax mistakes |
| [ ] **Color errors** | Red/yellow ANSI coloring when stderr is a TTY |
| [ ] **Stack trace** | For `def` recursion: show the call chain that led to the error |

### Performance features

| Item | Detail |
|------|--------|
| [x] **Query plan caching** | Query compiled once; ResultIterator reset() per record reuses eval stack — zero alloc/free in steady state. |
| [x] **Tape arena allocator** | Per-chunk ArenaAllocator in pool: all OwnedValue copies arena-allocated, freed atomically on chunk exhaustion. Zero GPA calls in the hot path for scalars. |
| [x] **Output batching** | 64 KB buffered writes in the output module. |
| [x] **mmap for large files** | io module (zero-copy reads) + pool submit_file (mmap → byte-range chunks → workers). |
| [ ] **Prefetch** | Issue `madvise(MADV_SEQUENTIAL)` for large file scans. |

### Developer experience

| Item | Detail |
|------|--------|
| [ ] **REPL mode** | `zq --repl` — interactive filter development with instant feedback. Load a JSON file, type filters, see results. |
| [ ] **`--explain`** | Print the compiled bytecode for a filter (for debugging/learning). |
| [ ] **`--validate`** | Check filter syntax without executing. Exit 0 if valid, 2 if syntax error. |
| [ ] **`--schema FILE`** | Validate input against JSON Schema. Exit 0 if valid, 1 if invalid. |
| [ ] **Filter comments** | Allow `#` comments in filter files (stripped during compilation). |

### Ecosystem

| Item | Detail |
|------|--------|
| [ ] **WASM build** | `zig build -Dtarget=wasm32-wasi`. zq in the browser, edge functions, Cloudflare Workers. |
| [ ] **Language server** | LSP for jq filter syntax. Provides autocomplete, hover docs, error squiggles in VS Code / Neovim. |
| [ ] **VS Code extension** | Syntax highlighting + LSP integration for `.jq` filter files. |
| [ ] **Plugin system** | Custom builtins via shared library. Load with `--plugin path.so`. Uses the C ABI. |
| [ ] **Python package** | `pip install zq` — Python bindings via cffi. `import zq; zq.first('.foo', '{"foo": 42}')`. |
| [ ] **jq MCP server** | MCP tool that uses zq to pre-filter large JSON before passing to LLMs. Reduces context/cost. |

---

## Deliberate Deviations from jq

These are cases where zq intentionally behaves differently from jq, because jq's
behavior is considered a bug, a footgun, or a missed opportunity.

| Behavior | jq | zq | Rationale |
|----------|----|----|-----------|
| Large integers | Silently converted to f64, losing precision above 2^53 | Stored as i64 (exact to 2^63). Arithmetic overflow returns error, not silent corruption. | Data integrity. Snowflake IDs, tweet IDs, nanosecond timestamps must not be silently mangled. |
| Division by zero | Returns error or `nan` inconsistently | Returns `nan` for `0/0`, `infinite` for `n/0` (n>0), `-infinite` for `n/0` (n<0). Consistent IEEE 754. | Consistency. |
| `input` with no remaining input | Error | Empty output (no values) | Composability with generators. Matches jaq behavior. |
| Duplicate object keys | Last value wins silently | Last value wins, but `--warn-duplicate-keys` emits stderr warning | Data integrity. |
| Streaming incomplete JSON | Error | Auto-close truncated containers (opt-in via `--stream-recover`) | LLM streaming use case. |
| Filter comments | Not supported | `#` comments in filter files | Developer experience. |

---

## Success Metrics

| Metric | Current | v0.1 | v0.5 | v1.0 |
|--------|---------|------|------|------|
| jq compat test pass rate | 8% (42/533) · 85% skipped (unimplemented) | 60% | 95% | 100% |
| Throughput vs jq (single-threaded, citylots.json) | — | 2x | 5x | 10x |
| Throughput vs jq (parallel, 15M-line JSONL, 11 cores) | **11.6x** (2.24s vs 25.9s) | — | 15x | 20x |
| Startup time | — | < 10ms | < 5ms | < 3ms |
| Binary size (static, stripped) | — | < 2 MB | < 3 MB | < 5 MB |
| Memory (citylots.json, 181MB) | — | < 500 MB | < 400 MB | < 360 MB (2x input) |
| Test count | 408+ | 400+ | 800+ | 1000+ |

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
