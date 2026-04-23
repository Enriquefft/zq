# zq Roadmap

> The JSON tool agents reach for first — 31x faster than jq, with structured errors,
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

## Quick Status (Updated 2026-04-16)

**Last updated:** Number-formatting + jq parity fixes. Rewrote `formatJqFloat` to match jq's `jvp_dtoa_fmt` (removed spurious i64 fast-path, ±inf→±DBL_MAX clamp, IGNORE_ZERO_SIGN). Rewrote `doMod` per jq's `binop_mod` with saturating `dtoiClamp` (inf%n, nan, INT64_MIN%-1). `doMul` nan/inf×string→null. Added `have_decnum`/`have_literal_numbers` builtins (return false). Added `Forkpoint.saved_stack` snapshots so binop left-operand survives generator backtrack inside array-collect (`[. * (a,b)]`). Fixed `insertRawInstr` off-by-one in jump-target shifting (`>=`→`>`) which silently skipped half the inner iterations in `(a,b)⊕(c,d,e)`.

```
Binary size:        2.7 MB (ReleaseFast, stripped)
Compat tests:       426/533 passing (80.0%)   <- jq compatibility suite
  +-- 107 failing, 3 skipped
Own tests:          443/443 passing (100%)    <- internal regression suite
Total:              869/976 passing (89.0%)
Startup:            ~2.4 ms (1.5x faster than jq)
Cold start:         sub-3ms

Parallel (file arg, .id, 15M-record JSONL, 1.3 GB):
  jq   32.3s   3.7 MB RSS
  jaq  20.9s   1312 MB RSS
  zq    1.05s   403 MB RSS  <- 31x faster than jq, 0.31x input RSS

Parallel (file arg, select(.id > 500000), 15M-record JSONL, 1.3 GB):
  jq   70.2s   3.6 MB RSS
  jaq  38.7s   1312 MB RSS
  zq    1.90s   831 MB RSS  <- 37x faster than jq, 0.64x input RSS

Parallel (file arg, complex transform, 15M-record JSONL, 1.3 GB):
  jq   94.8s   3.7 MB RSS
  jaq 163.0s   1312 MB RSS
  zq    2.22s              <- 43x faster than jq
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

*Goals — pure checklist. For live numbers see Quick Status above and Success Metrics below.*

- [x] 60%+ of migrated jq compat tests pass
- [x] 100% of internal regression tests pass
- [x] 75%+ compat **with parity** for assignment, paths, error semantics — remaining gaps are decnum-dependent (require jq's arbitrary-precision build)
- [ ] All P0/P1 query features below are implemented
- [x] `zq` binary under 3 MB static
- [ ] Zero known crashes on valid JSON input
- [x] Memory: RSS < 2x input size for per-record queries on file mode
- [x] Startup time < 3ms
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
| [x] | **Pipe expressions in brackets** (`.[.foo]`, `.["key"]`) | Lexer + Compiler | String key access, computed index. Comma generators (`.[0,1,2]`), variable-based pattern handles arbitrary inner expressions including generators. |

### Query language — P1

| | Feature | Scope | What it unlocks |
|---|---------|-------|-----------------|
| [x] | **Alternative operator** (`//`) | Compiler + VM | Null coalescing. `(.foo // "default")` |
| [x] | **Try/catch** (`try expr catch expr`) | Compiler + VM | Error recovery. The LLM streaming use case. |
| [x] | **Optional operator** (`expr?`) | Compiler + VM | Suppress errors on missing keys. `.foo?` |
| [x] | **Slicing** (`.[2:4]`, `.[2:]`, `.[:4]`) | Compiler + VM | Array and string slicing |
| [x] | **Update assignment** (`\|=`, `+=`, `-=`, `*=`, `/=`, `%=`, `//=`) | Compiler + VM | In-place modification. Mirrors jq's `_modify`/`_assign` desugar exactly. Handles: `.foo \|= . + 1`, `.[] += 2`, `def inc(x): x \|= .+1; inc(.[].a)`, generator lhs (`def x: .[1,2]; x=10`), `\|= empty` deletion, `(.[] \| select(...)) \|= empty` paren-grouped. Per-path empty detection routes through `delpaths` automatically. |
| [x] | **Negative indexing** (`.[-1]`, `.[-2:]`) | VM | Last element, tail slicing. Works in both read and assignment contexts. Sparse array creation on null base (`null \| .[2] = 5` → `[null,null,5]`). jq-compatible error messages: "Out of bounds negative array index", "Array index too large". |
| [x] | **Core builtins (tier 1)** | VM builtins table | `length`, `keys`, `values`, `has`, `in`, `type`, `empty`, `select`, `map`, `add`, `not`, `error`, `null`, `true`, `false`, `tostring`, `tonumber`, `range`, `keys_unsorted` |
| [~] | **Core builtins (tier 2)** | VM builtins table | `sort`, `sort_by`, `group_by`, `unique`, `unique_by`, `reverse`, `flatten`, `min`, `max`, `min_by`, `max_by`, `to_entries`, `from_entries`, `with_entries`, `del`, `contains`, `inside`, `any`, `all`, `limit`, `first`, `last`, `indices`, `index`, `rindex`. **Partial:** `del` fails with multiple/complex args (slices, generators, nan); `contains` fails on deep nested objects; `any`/`all` don't short-circuit on error; `first`/`last` with generator args fail. |

### Query language — P2

| | Feature | Scope | Complexity |
|---|---------|-------|------------|
| [x] | **`def`** (user-defined functions, including recursion) | Composability | High |
| [x] | **`while`/`until`/`repeat`** | Loop constructs | Low |
| [x] | **`label`/`break`** | Non-local exit from generators | High |
| [x] | **`reduce`** (`reduce expr as $x (init; update)`) | Aggregation | Medium |
| [x] | **`foreach`** (`foreach expr as $x (init; update; extract)`) | Stateful iteration | Medium |
| [x] | **`getpath`/`setpath`/`delpaths`/`paths`/`leaf_paths`** | Path algebra | Medium |
| [~] | **Variable destructuring** (`as [$a,$b]`, `as {a: $x}`) | Pattern matching in bindings | Medium | **Partial:** simple patterns work; complex patterns (`. as {$a, $b:[$c, $d]}`, computed key destructuring) fail. |
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

Current state: **403 MB RSS** for 1.3 GB JSONL `.id` query **(0.31x input)**. Target < 2x: **achieved**. Target ~1x: **achieved**.
Progress: 2998 MB -> 1702 MB -> 701 MB -> 403 MB (-87% total).

| | Item | Detail |
|---|------|--------|
| [x] | **Bounded chunk count** | InFlightLimiter caps in-flight chunks at `IN_FLIGHT_FACTOR x n_threads`. Memory bounded to ~`chunk_size x n_threads`, not file size. **Result: 2998 MB -> 1764 MB (-41%), 38s -> 1.41s (27x faster).** |
| [x] | **Ordered output queue** | Fixed-size ring buffer replaces HashMap in Sequencer. O(1) post and fetch with zero dynamic allocation in the hot path. **Result: 1764 MB -> 1702 MB (-3.5%).** |
| [x] | **Batched stream mode** | stdin routes through parallel pool via `submit_stream()`. IO thread accumulates lines into 256 KB batches. InFlightLimiter backpressure added. **Result: streaming 215s -> 1.6s (120x faster); RSS ~8 MB.** |
| [x] | **2 MiB thread stacks** | Reduced from 16 MiB default. Workers use heap-allocated parse/query stacks. **Result: ~224 MB saved (22 threads x 14 MiB).** |
| [x] | **Contiguous serialized chunks** | One contiguous byte buffer + compact `RecordMeta` array (8 B/record vs ~32 B). Format-aware pre-alloc reduces arena page leaks. **Result: 1053 MB -> 715 MB (-32%) for `.id`; 2203 MB -> 1980 MB (-10%) for `select()`.** |
| [x] | **`madvise(MADV_DONTNEED)` on processed chunks** | After workers serialize a chunk's output into the arena buffer, call `madvise(MADV_DONTNEED)` on the mmap pages. Releases physical pages immediately, bounding mmap RSS to `in_flight × chunk_size` instead of `file_size`. Linux-only; no-op elsewhere. **Result: 1648 MB -> 396 MB for `.id` (-76%); 0.31x input RSS.** |

**Target:** RSS < 2x input size for per-record queries (`.id`, `select()`, `{a,b}`). **Achieved and exceeded:**
- `.id`: **0.31x input** (403 MB for 1.3 GB file)
- `select(.id > 500000)`: **0.64x input** (831 MB) — higher because output ≈ input for high-selectivity filters

### Infrastructure

| | Item | Priority |
|---|------|----------|
| [x] | jq compat test suite fully migrated (533 tests) | P0 |
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
- [x] Demonstrated 10x+ throughput on JSONL workloads vs jq
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
| [x] | **String (regex)** | `capture`, `scan`, `splits`, `match(re; "g")` generator mode (Phases A–F) |
| [x] | **String (new)** | `trim`, `ltrim`, `rtrim`, `trimstr`, `toboolean` |
| [x] | **Math** | `floor`, `ceil`, `round`, `sqrt`, `pow`, `log`, `log2`, `exp`, `exp2`, `fabs`, `nan`, `infinite`, `isinfinite`, `isnan`, `isnormal`, `abs`, `significand`, `logb`, `cbrt`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `hypot`, `remainder`, `tgamma`, `lgamma`, `j0`, `j1`, `nearbyint`, `rint`, `trunc`, `scalb`, `scalbln`, `ldexp`, `fma`, `drem`, `exp10`, `log10` |
| [x] | **Array** | `transpose`, `bsearch`, `recurse` |
| [ ] | **Array (remaining)** | `combinations` |
| [x] | **Array (new)** | `nth`, `walk`, `skip` |
| [x] | **Object** | `paths`, `leaf_paths`, `map_values`, `getpath`, `setpath`, `delpaths` |
| [x] | **Object (new)** | `pick`, `path` |
| [x] | **I/O** | `input`, `inputs`, `debug`, `stderr`, `halt`, `halt_error` |
| [x] | **Env** | `env`, `builtins` |
| [ ] | **Env (remaining)** | `$ENV` |
| [x] | **Env (new)** | `$__loc__` |
| [ ] | **SQL-style (remaining)** | `GROUP_BY` |
| [x] | **SQL-style (new)** | `INDEX`, `IN`, `JOIN` |
| [x] | **Date/time** | `now`, `gmtime`, `mktime`, `strftime`, `strptime`, `strflocaltime`, `todate`, `fromdate`, `todateiso8601`, `fromdateiso8601` |
| [x] | **Type selectors** | `arrays`, `objects`, `iterables`, `booleans`, `numbers`, `strings`, `nulls`, `normals`, `scalars`, `values` |
| [ ] | **Type selectors (remaining)** | `finites` |
| [x] | **Misc** | `isempty`, `ascii`, `first`, `last` |
| [ ] | **Misc (remaining)** | `repeat`, `limit/2` |
| [x] | **Misc (new)** | `utf8bytelength`, `add(expr)` |

### Query language — compat gaps

Issues found during compat test analysis. These are gaps in features marked
complete above, tracked here for visibility. Goal is **75%+ compat tests** and
**100% internal tests** — both currently met (see Quick Status for live numbers).

| | Feature | Tests blocked | Detail |
|---|---------|---------------|--------|
| [x] | **Assignment with complex lhs** | ~15 fixed | All forms now work: `.[-1] = 5`, `.[] += 2`, `.[2][3] = 1`, `.foo[2].bar = 1`, `def inc(x): x \|= .+1`, `\|= empty`, generator lhs (`def x: .[1,2]; x=10`), paren-grouped (`(.[] \| select(...)) \|= empty`), per-path deletion (`.[] \|= select(. > 5)`). Implementation: fork-aware path tracking + general `compilePathExprUpdate` desugaring to jq's `_modify`/`_assign`. |
| [x] | **Comma generators in brackets** | ~5 fixed | `.[0,1,2]`, `.[-4,-3,-2,-1,0,1,2,3]`, `path(.foo[0,1])` all work. New `compileComputedBracket` uses a variable-based pattern that survives generator iteration. Path tracking with generators now records one path per fork output. |
| [ ] | **`path_intact` validation** | ~3 | `try ((map(select(.a == 1))[].a) \|= .+1) catch .` should error with "Invalid path expression near attempt to iterate through ...". jq tracks `value_at_path` identity to detect when a non-path-preserving operation (`map`, `+`, `reverse`, `length`, etc.) intervenes inside a `path()` scope. Requires VM addition: per-fork `value_at_path` snapshot + `path_intact` check at INDEX/EACH/PATH_END. |
| [ ] | **`del()` with complex args** | ~6 | `del(.[2:4],.[0],.[-2:])`, `del(.[nan])`, `del(.), del(empty)`. Current `compileDel` handles single static keys/indices only. Should desugar to canonical `delpaths([path(arg)])` to use the new path-tracking infrastructure. |
| [x] | **Number output formatting** | ~10 fixed | Rewrote `formatJqFloat` to match jq's `jvp_dtoa_fmt`: removed i64 fast-path (large integer-valued floats like `1/1e-17` now → `1e+17` via scientific threshold), ±inf→±DBL_MAX clamp, IGNORE_ZERO_SIGN. Added `have_decnum`/`have_literal_numbers` builtins (=false), `doMod` per jq's `binop_mod` (inf%n, nan, INT64_MIN%-1), nan/inf×string→null in `doMul`, `Forkpoint.saved_stack` snapshots for generator backtracking. Remaining non-fixable failures (L593, L661, L674, L2195) require jq's decnum build — fundamentally incompatible with f64. |
| [ ] | **Float index truncation** | ~5 | `.[1.5]` should truncate to `.[1]`, `.[nan]` should error, `.[1.2:3.5]` should truncate slice bounds. (`load_computed` already handles `.[nan]` for path tracking; runtime truncation for slice bounds is the remaining piece.) |
| [ ] | **Error message compatibility** | ~8 | `try (1/0) catch .`, `try -. catch .` — error strings don't match jq's exact wording. |
| [ ] | **`contains` deep comparison** | ~2 | Nested object containment check fails. |
| [ ] | **`any`/`all` short-circuit** | ~2 | `any(true, error; .)` should not evaluate error. |
| [ ] | **User function scoping** | ~5 | Nested `def` shadowing, closure capture in complex contexts. |
| [ ] | **JSON parser: extended literals** | ~3 | `Infinity`, `-Infinity`, `NaN`, `-NaN` as input JSON literals are not accepted. jq accepts these as extension. Affects `.[] = 1` test on `[1,null,Infinity,...]`. |

### Performance

| | Item | Detail |
|---|------|--------|
| [x] | **SIMD structural scanner** | AVX2 (x86_64), NEON (aarch64). Classify bytes 32/16 at a time. String scanning and whitespace skipping via SIMD fast paths. |
| [x] | **Parallel file mode** | mmap + chunk-based workers. Auto-enabled in CLI. Achieved **31x vs jq, 20x vs jaq** on 15M-record JSONL `.id`. |
| [ ] | **Parallel single-file arrays** | Detect top-level `[{...}, {...}, ...]`. Scan for object boundaries at bracket depth 1, split across workers. |
| [x] | **Benchmark suite (code)** | `benchmarks/` directory. Hyperfine scripts comparing zq vs jq vs jaq. 5 scenarios: parallelism, memory, startup, streaming, complex query. |
| [ ] | **Benchmark suite (published)** | Reproducible published results — PR/post with comparison tables, methodology, datasets. |
| [x] | **Startup time** | Target < 3ms cold start. Achieved: ~2.4ms (1.5x faster than jq); sub-ms without shell overhead. |
| [x] | **Memory efficiency** | Target < 2x input size. **Achieved: 0.31x for `.id`, 0.64x for `select()` on 1.3 GB file.** Total reduction: -87%. |

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

All v1.0 memory targets met in v0.1 — see v0.1 "Memory optimization — P0" for
the full breakdown (bounded chunks, ordered ring buffer, batched streaming,
madvise page reclaim, 0.31x/0.64x RSS on 1.3 GB).

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

## Research-Backed Optimizations

> Goal: Engineering improvements that simultaneously advance zq's performance.
> Each item is grounded in verified codebase analysis and positioned against
> existing literature.
>
> **Engineering verdict:** Each item is tagged with one of:
> - **Implement** — unconditional engineering win, do regardless of paper
> - **Profile first** — promising but needs workload data before committing
> - **Paper only** — academic value but not worth the engineering complexity
>
> **Summary: 9 implement, 5 profile first, 6 paper only.**

---

### Track A: Push Query Semantics into the Parser

zq currently parses every field in every record, even when
the query touches one field. These optimizations fuse query knowledge into the parsing
stage, eliminating work before values are ever constructed.

**Prior art:** Mison (VLDB 2017), Sparser (VLDB 2018), simdjson On-Demand (SPE 2024), dsJSON (SIGMOD 2023)

| | Item | What it does | Why it's publishable | Verified bottleneck |
|---|------|-------------|---------------------|---------------------|
| [ ] | **Projection pushdown** | `.id` on a 50-field object skips parsing 49 fields. Build SIMD structural index (colon/comma bitmaps per nesting level) to jump directly to queried fields. Fuse pass already identifies needed fields — feed that back to parser. | Mison showed 3.6-10.2x speedup. Novel integration: projection pushdown in a parallel tape-based system with SIMD structural indexing. No prior work combines all three. | `lookupKey()` iterates linearly through all object entries (`vm.zig`). Full tape always built regardless of query. | **Implement** |
| [ ] | **Raw byte pre-filtering (Sparser-style)** | For `select(.status == "active")`, scan raw bytes for `"active"` with SIMD before any parsing. Records that don't contain the substring are skipped entirely. False positives are cheap (just parse normally); false negatives are impossible. Cascade multiple cheap filters for compound predicates. | Sparser showed 22x over Mison on high-selectivity queries. zq already has SIMD infrastructure — adding raw filters is a natural extension. Novel: Sparser + chunk-parallel architecture. | `select()` parses entire record then evaluates in VM (`compiler.zig`). No early rejection. | **Profile first** — only helps high-selectivity on large records. Adds complexity for a narrow case. |
| [ ] | **Predicate pushdown into parser** | For `select(.age > 30)`, evaluate the predicate during parsing. Once `.age` is found and its value parsed, reject immediately without constructing the rest of the tape. Requires compiler to emit "parse-and-filter" plans for simple predicates on top-level fields. | dsJSON (SIGMOD 2023) introduced projection trees for distributed JSON. Fusing predicate evaluation with tape construction in a bytecode VM is novel. | Full tape constructed before any filtering. VM evaluates predicate on complete value. | **Implement** |
| [ ] | **Speculative schema caching** | JSONL records typically share structure. Cache field byte-offsets from record N, speculatively jump directly to that offset in record N+1. Validate with a single comparison. Cache miss falls back to structural index traversal. | Mison introduced speculation (10.2x with vs 3.6x without). Novel: speculation in a multi-threaded chunk-parallel system where each worker maintains its own speculative cache. | Records parsed independently. No cross-record optimization. | **Profile first** — fragile; one heterogeneous dataset breaks the cache. Measure schema stability on real workloads before committing. |
| [ ] | **On-demand / lazy materialization** | After structural indexing, don't build tape entries for fields the query doesn't access. Materialize values lazily on first access. For `.id` on wide objects, only one tape entry is created. | simdjson On-Demand (SPE 2024) showed this outperforms both DOM and SAX. Novel: lazy materialization integrated with parallel pool + sequencer architecture. | Full tape always constructed in parser (`parser.zig`). | **Paper only** — massive tape format refactor for marginal gain once projection pushdown exists. They solve the same problem; projection pushdown is simpler. |

**Implementation order:** Projection pushdown first (clearest gain, simplest to measure), then predicate pushdown (compounds with projection). Sparser and speculation only after profiling on real workloads justifies them. On-demand is paper-track only.

**Expected combined gain:** 2-5x for selective queries (`.id`, `select()`, `has()`) on wide objects.

---

### Track B: Adaptive Execution

zq has two fast execution modes (streaming, parallel file) but no principled mechanism
to choose between strategies or adapt mid-execution. Academic work on adaptive query
processing (Eddies, Spark AQE) shows runtime adaptation outperforms static plans on
heterogeneous workloads.

**Prior art:** Eddies (SIGMOD 2000), Adaptive Query Processing survey (FnT Databases 2007), Spark AQE (2020), Learned Cost Models (SIGMOD 2020-2025)

| | Item | What it does | Why it's publishable | Verified bottleneck |
|---|------|-------------|---------------------|---------------------|
| [ ] | **Per-chunk adaptive strategy** | After processing the first N chunks, measure actual selectivity and parse cost. If selectivity is low (<5% of records pass), switch remaining chunks to Sparser-style raw filtering. If records are simpler than expected, adjust chunk sizing. | Per-chunk granularity is novel — Eddies operates per-tuple, Spark AQE per-stage. Chunk-level is the natural unit for parallel JSON processing. | `computeParams()` uses static memory-based formula. No runtime adaptation. Strategy fixed at query start. | **Profile first** — switching logic itself adds overhead. Only worth it if workloads are genuinely heterogeneous within a single run. |
| [ ] | **Cost model for mode selection** | Predict optimal execution mode (single-threaded / pool-file / pool-stream) and parameters (chunk size, batch size, in-flight limit) from input characteristics (size, record density, query complexity). Even a simple heuristic model, if well-evaluated, is a contribution. | Cross-engine cost models (SIGMOD 2025) showed 25-30% gains from learned routing. Novel: applying cost model principles to a specialized JSON processor's mode selection. | `MemoryBudget` considers only memory, not query cost or record complexity. Stream batch size (256 KB) has no sensitivity analysis. | **Paper only** — a few `if` statements on file size and query type gets 95% of the way. A formal model is over-engineering. |
| [ ] | **Close the streaming/file gap** | Streaming is 3.3x slower than file mode (3.47s vs 1.05s). Root causes: single IO thread serializes all reading, per-batch heap allocation (`allocator.dupe` per 256KB batch), `JobQueue.signal()` wakes only one thread. Fix: multiple IO threads, zero-copy batch handoff, `broadcast()` on queue drain. | Systematic analysis of streaming vs mmap performance in a real system, with principled fixes, is a systems contribution. | Single IO thread (`pool/root.zig` io_thread_fn). Per-batch `dupe()` allocation. File mode is zero-copy from mmap. | **Implement** |

**Expected combined gain:** 1.5-3x on streaming workloads; smarter strategy selection across diverse inputs.

---

### Track C: Compiler Optimizations for JSON Query Bytecode

zq's compiler emits bytecode with a single fuse pass (collapsing `.a | .b | .c`). Standard
compiler optimizations — constant folding, CSE, specialized instruction emission — are
entirely absent. Applying these to a JSON query bytecode VM is a novel domain.

**Prior art:** Compiled vs Vectorized Queries (PVLDB 2018), general compiler optimization literature

| | Item | What it does | Why it's publishable | Verified bottleneck |
|---|------|-------------|---------------------|---------------------|
| [ ] | **Constant folding** | `.x + 5 - 2` compiles to `.x + 3` (saves 2 instructions). `select(true)` becomes identity. `expr and false` short-circuits. Boolean/arithmetic simplification at compile time. | Standard optimization applied to novel domain. Combined with other compiler opts, forms coherent "optimizing compiler for JSON queries" story. | No constant folding. Literals emitted as separate push instructions. | **Implement** |
| [ ] | **Common subexpression elimination** | `(.x + .y) + (.x + .y)` computes `.x + .y` once, reuses result. Build expression DAG during compilation, detect duplicates. | CSE on a filter-language bytecode is novel. 10-20% instruction reduction on complex filters. | Each subexpression compiled independently. No DAG or deduplication. | **Paper only** — JSON queries are rarely complex enough. Implementation cost (expression DAG) far exceeds gain on real filters. |
| [ ] | **Monomorphic selector specialization** | Detect `select(.field == literal)` at compile time. Emit specialized bytecode that branches on field value directly, eliminating generic comparison dispatch + fork setup. | JIT-like specialization for interpreted JSON queries. 10-30% speedup on filter-heavy workloads. | `select()` compiles as: save_input, evaluate predicate generically, jump_if_false, restore (`compiler.zig`). | **Profile first** — nice but adds compiler complexity for one pattern. |
| [ ] | **Extended fuse pass** | Fuse `.key \| has()` → `key_exists` opcode. Fuse `.key \| length` → `key_length`. Fuse `.key \| type` → `key_type`. Current fuse pass only handles consecutive `load_key` chains. | Systematic instruction fusion for JSON query VMs — generalizes simdjson's on-demand approach to bytecode. | Fuse pass limited to `.a \| .b \| .c` → `load_path` (`compiler.zig`). | **Implement** |
| [ ] | **Tail call optimization** | Recursive `def` functions (e.g., `def fact(n): if n <= 1 then 1 else n * fact(n-1) end`) converted to loops. Detect tail-position calls, eliminate call frames. | TCO for a JSON query language. 80-90% speedup on recursive user-defined functions. | No TCO. Each recursive call allocates a full call frame. | **Paper only** — very few people write recursive `def` in jq. Not an engineering priority. |

**Expected combined gain:** 15-35% on complex queries; eliminates pathological performance on recursive functions.

---

### Track D: Data Structure Optimizations

Targeted improvements to the tape format, value representation, and hot builtin
implementations. Individually small, but collectively significant and measurable.

| | Item | What it does | Expected gain | Verified bottleneck |
|---|------|-------------|---------------|---------------------|
| [ ] | **Object key indexing** | For objects with >N keys (e.g., N=16), build a compact hash table mapping keys to tape offsets during parsing. `has()`, `lookupKey()`, field access become O(1) instead of O(fields). | 20-40% on `has()`/field access for wide objects | `lookupKey()` linear scans all entries (`vm.zig`). `has()` also linear (`vm.zig`). | **Implement** |
| [ ] | **Cached array/object length** | Store element count in tape during parsing. `length` builtin returns cached value instead of re-walking tape. Zero cost at parse time (counter already maintained). | 8-15% on `length`-heavy queries | `length` re-walks tape on every call (`vm.zig`). | **Implement** |
| [ ] | **String deduplication** | Build per-chunk hash map of `{string bytes → string_buf offset}`. Reuse offsets for duplicate keys/values. High impact on logs/configs with repeated field names. | 10-30% memory on repetitive data | Strings always copied to string_buf. No deduplication (`parser.zig`). | **Profile first** — hash table per chunk adds CPU cost. Only wins on highly repetitive data (logs). |
| [ ] | **COW strings** | For unescaped strings, store pointer into input buffer instead of copying to string_buf. Only copy strings that need escape processing. Requires input buffer to outlive tape (already true for mmap). | 20-30% memory on large-string JSON; ~5% parse speed | All strings copied regardless of escape status (`parser.zig`). | **Implement** |
| [ ] | **Inline small strings** | Embed strings <=8 bytes directly in the tape entry payload. Eliminates string_buf indirection for short keys like `"id"`, `"name"`, `"type"`. | 10-15% on short-key-heavy JSON | All strings go through string_buf indirection (`types.zig`). | **Paper only** — changes tape layout for marginal cache improvement. High blast radius. |
| [ ] | **Type-aware arithmetic opcodes** | `add_int`, `add_float`, `add_string` instead of generic `add` with runtime type dispatch. Compiler detects operand types, emits specialized opcode. | 5-8% on numeric-heavy queries | Generic `add` dispatches through type switch every call. | **Paper only** — adds opcode count + compiler complexity for 5-8% on numeric queries that barely exist in practice. |

---

### Track E: Evaluation Infrastructure

No paper without rigorous evaluation. This track is table-stakes.

| | Item | What it does | Why it matters |
|---|------|-------------|---------------|
| [ ] | **Multi-system benchmark suite** | Compare against jq, jaq, gojq, simdjson (with custom query layer), DuckDB `read_json`, ClickHouse JSON, Polars JSON. Varied workloads: wide records, deep nesting, high/low selectivity, small/large files, streaming vs file. | No rigorous academic benchmark exists for this space. Filling this gap is itself a contribution. Current benchmarks only compare jq and jaq. | **Implement** |
| [ ] | **Microbenchmark harness** | Isolate and measure individual components: parse time, field lookup, predicate evaluation, serialization, thread coordination. Before/after for each optimization. | Reviewers want to see where time goes, not just end-to-end numbers. Required to attribute gains to specific optimizations. | **Implement** |
| [ ] | **Workload characterization** | Curate diverse JSON datasets: API responses (GitHub, Twitter), logs (CloudWatch, ELK), configs (package.json, Terraform), geospatial (GeoJSON), scientific (nested arrays). Characterize record width, nesting depth, string ratio, schema stability. | Optimization effectiveness varies by workload. A paper needs to show gains aren't cherry-picked. | **Implement** |
| [ ] | **Scalability analysis** | Measure throughput as function of: core count (1-64), file size (1MB-100GB), record size (50B-50KB), selectivity (0.1%-100%), nesting depth (1-20). | Establishes where zq's architecture excels and where it breaks down. Required for a systems paper. | **Implement** |

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
| Regex engine | Oniguruma (archived 2025; ReDoS-vulnerable) | `regex-automata` (linear-time, unicode-aware, panic-safe) | Security, maintenance trajectory. |

## Regex

zq's regex builtins run on Rust's `regex-automata` via a vendored shim
(`third_party/zq-regex-shim/`). Linear-time guarantees eliminate ReDoS. Build
with `-Dregex=true` (default) for full support, or `-Dregex=false` to ship a
Rust-free binary where every regex builtin surfaces `regex_not_compiled`.

**Supported builtins:**
`test(re)`, `test(re; flags)`, `match(re)`, `capture(re)`, `capture(re; flags)`,
`scan(re)`, `scan(re; flags)`, `sub(re; repl)`, `sub(re; repl; flags)`,
`gsub(re; repl)`, `gsub(re; repl; flags)`.

**Supported pattern features:** POSIX classes (`[:alpha:]`), Unicode properties
(`\p{L}`, `\p{Greek}`), unicode-aware `\w`/`\d`/`\s`/`\b`, named captures
(`(?<name>...)`), non-capturing groups, alternation, anchors, greedy/lazy
quantifiers, inline flag groups (`(?i:foo)`).

**Supported flags (as 2nd/3rd arg):** `i` (case-insensitive), `m` (multi-line),
`s` (dotall / `.` matches `\n`), `x` (ignore whitespace). `g`/`n` are accepted
and treated as pattern-level no-ops. Unknown flag letters are a compile error.

**Compat delta vs jq (deliberate, documented):**

| Feature | jq/onig | zq | User workaround |
|---|---|---|---|
| Pattern backrefs (`(\w+) \1`) | works | compile error | rewrite without backref |
| Positive/negative lookaround | works | compile error | alternation + anchors |
| `\g<name>` subroutine calls in pattern | works | compile error | repeat the subpattern inline |
| Replacement-as-filter (`\(.field)` in repl) | jq evaluates the replacement as a full filter with `.` bound to the match object — e.g. `sub("(?<x>.)"; "\(.captures[0].string \| ascii_upcase)")` | `\1..\9` and `\g<name>` backref substitution only | compose with `match` + manual concat. **Accepted as permanent delta** — pulling the full jq evaluator into the sub/gsub path violates the VM boundary for a rarely-used feature. |
| `match(re; "g")` global-generator mode | yields all matches | yields all matches (implemented) | — |
| `match([re, flags])` array overload | works | compile error | `match(re; flags)` |
| `splits(re; flags)` regex split | works | works (implemented) | — |
| `n` flag (ignore empty matches) | filters zero-width matches | currently a no-op | accepted silently |

**Performance targets vs measured** (release build, isMatch, per-worker clone, x86_64 ReleaseFast):

| Pattern | Target | Measured median |
|---|---|---|
| Literal `"foo"` | 30–80 ns | 33 ns |
| Alternation `"foo\|bar\|baz\|qux"` | 80–200 ns | 46 ns |
| Anchored prefix `"^GET "` | 30–80 ns | 49 ns |
| Simple class `"[a-z]+"` | 80–200 ns | 44 ns |
| Named capture `"(?<year>\d{4})"` | 300 ns – 1 µs | 57 ns (isMatch path) |

All pattern classes meet or exceed plan targets. Run `zig build bench-regex
-Doptimize=ReleaseFast` to reproduce.

**Differential fuzz:** `zig build fuzz-regex` runs a small-grammar harness that
compares zq vs jq on randomly generated pattern/haystack pairs. 1000 iterations
produce 0 divergences (patterns jq rejects are skipped as documented compat
delta). Override iteration count with `ZQ_FUZZ_ITERS=N`.

---

## Success Metrics

| Metric | Current | v0.1 | v0.5 | v1.0 |
|--------|---------|------|------|------|
| jq compat test pass rate | **80.0%** (426/533) | 60% | 95% | 100% |
| Throughput vs jq (parallel, `.id`) | **31x** (1.05s vs 32.3s) | > 1x | 5x | 10x |
| Throughput vs jq (parallel, `select()`) | **37x** (1.90s vs 70.2s) | -- | 15x | 20x |
| Throughput vs jq (parallel, complex) | **43x** (2.22s vs 94.8s) | -- | -- | -- |
| Startup time | **~2.4ms** | < 3ms | < 3ms | < 3ms |
| Binary size (static, stripped) | **2.7 MB** | < 3 MB | < 3 MB | < 5 MB |
| Memory (1.3 GB JSONL, `.id`) | **403 MB** (0.31x) | < 2x | < 2x | < 2x |
| Memory (1.3 GB JSONL, `select()`) | **831 MB** (0.64x) | < 2x | < 2x | < 2x |
| Memory (streaming pipe) | **7 MB** | -- | -- | -- |
| Throughput vs jq (streaming, `.id`) | **9x** (3.47s vs 32.6s) | -- | -- | 10x |
| Test count | **426 compat + 443 module** | 400+ | 800+ | 1000+ |
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

4. **One module at a time.** The deep modules architecture means each module can
   evolve independently. The query VM is the critical path for v0.1 — everything
   else is already in place.

5. **Test against jq, not against ourselves.** The compat test suite is the source
   of truth. A feature is done when jq's own tests pass.
