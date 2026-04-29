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

## Quick Status (Updated 2026-04-28)

**Last updated:** Phase 2R AST-walk pipeline shipped (e4ef917, ee3d62f): AST → lower → fuse → emit → VM replaces the old single-pass recursive-descent compiler. K2 regression fixes landed: def-scope close-after-rest + recursive-self shadow guard asymmetry (5abfab2), expanding_stack push gated on is_recursive (ec21f78), Fix-C multi-element bracket access (7bcef99), Fix-D while(cond;update) inside arr_ctor fork-chain (464966b).

```
Binary size:        2.7 MB (ReleaseFast, stripped)
Compat tests:       426/533 passing (80.0%)   <- jq compatibility suite
  +-- 107 failing, 3 skipped
Own tests:          443/443 passing (100%)    <- internal regression suite
Top-20 agent patterns: 20/20 (100%)            <- usage-weighted compat
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

**Architecture:** error | types | io | lexer | parser | ast | compiler | vm | query | prefilter | output | describe | pool | lsp | c_abi | main.zig — all modules complete.
**Agent interface:** `--json-errors`, `--describe`, `--validate`, exit codes, C ABI errors, `llms.txt`, 134 builtins, LSP.

---

## Roadmap Structure

Ordered by **usage-weighted priority**: what unlocks the most real-world users, soonest.
Version milestones (v0.1 shipped, v0.5, v1.0, v2.0) are annotated per item where still
informative; the canonical ordering is the tier.

- **[Tier 1: Drop-In jq Parity (99% of users)](#tier-1-drop-in-jq-parity-99-of-users)** — closing these makes `alias jq=zq` work for virtually every real script, pipeline, and agent shell call.
- **[Tier 2: Agent-First Interface](#tier-2-agent-first-interface)** — capabilities that make agents prefer zq even when jq also works. The moat.
- **[Tier 3: Long-Tail jq Parity (the last 1%)](#tier-3-long-tail-jq-parity-the-last-1)** — edge-case features that close the remaining compat test gap. Low agent frequency; finish for 100% test pass, not for usability.
- **[Tier 4: Strictly Better Than jq](#tier-4-strictly-better-than-jq)** — features jq fundamentally cannot do.
- **[Tier 5: Ecosystem & Distribution](#tier-5-ecosystem--distribution)** — integrations, bindings, packaging, docs.

The remaining sections (Performance & Memory, Research-Backed Optimizations, Deliberate Deviations, Regex, Version Milestones, Success Metrics, Execution Principles) are orthogonal — either shipped achievements, forward-looking research, or reference material — and are not part of the tier priority ordering.

---

## Tier 1: Drop-In jq Parity (99% of users)

> The top-20 most-used jq patterns already pass in zq (20/20). This tier lists the
> items blocking the 21st…10,000th pattern — the specific gaps agents and scripts
> *actually hit* in real use. Ordered within each subsection by agent frequency.
>
> **Completing Tier 1 = `alias jq=zq` is safe for 99% of users.**

### 1.1 Query semantics — blocking

Ranked by observed agent usage.

| | Feature | Tests blocked | Impact | Detail |
|---|---------|---------------|--------|--------|
| [x] | **`del()` with complex args** | ~6 | High | `del(.[2:4],.[0],.[-2:])`, `del(.[nan])`, `del(.), del(empty)`. Desugared to `. as $orig \| [path(f)] as $paths \| $orig \| delpaths($paths)`. |
| [x] | **`contains` deep comparison** | ~2 | High | Root cause was object-literal evaluation: `object_construct_start`/`object_key` clobbered `it.current` with `it.input_value`, so any object literal preceded by a pipe (including `contains()`'s argument) lost its `.`. Fix: per-frame `it.current` snapshot stack mirroring `object_construct_depth`. |
| [~] | **Variable destructuring — complex patterns** | ~3 | Medium | Most patterns work; remaining gaps: nested array-destructure patterns (`. as {$a, $b:[$c, $d]}`) and some computed-key shapes. Computed non-string guard fixed (2091aa1), `?//` alt_bind codegen added (f48ebcf). |
| [ ] | **`any`/`all` short-circuit** | ~2 | Medium | `any(true, error; .)` should not evaluate the error expression. Eager evaluation today. |
| [~] | **Core builtins — generator args** | ~4 | Medium | `first`/`last` with generator-expression arguments fail; single-value arguments work. |
| [~] | **User function scoping** | ~3 | Medium | Two sub-bugs fixed: def scope close-after-rest + recursive-self shadow guard asymmetry (5abfab2); expanding_stack push gated on is_recursive (ec21f78). Complex closure capture in deeply-nested non-recursive defs may still surface edge cases (no current test exercises). |
| [ ] | **`path_intact` validation** | ~3 | Low | `try ((map(select(.a == 1))[].a) \|= .+1) catch .` should error with "Invalid path expression near attempt to iterate through ...". Requires VM addition: per-fork `value_at_path` snapshot + `path_intact` check at INDEX/EACH/PATH_END. |

### 1.2 CLI — common flags not yet shipped

| | Feature | Detail |
|---|---------|--------|
| [ ] | `--slurpfile NAME FILE` | Read file into variable as array. |
| [ ] | `--rawfile NAME FILE` | Read file into variable as string. |
| [ ] | `--unbuffered` | Flush after each value. |

### 1.3 Drop-in foundation — already shipped

The core language surface required for drop-in use is complete. Kept as a flat
reference list; see git history for implementation details.

**Query language (P0/P1/P2):**
arithmetic (`+`,`-`,`*`,`/`,`%`), unary negation, comparisons, booleans, conditionals,
variables (`as $x`), comma generator, object construction (incl. shorthand + computed
keys), array construction, string interpolation, recursive descent (`..`), bracket
pipe expressions (`.[expr]`), alternative (`//`), try/catch, optional (`?`), slicing,
update assignment (`|=`, `+=`, `-=`, `*=`, `/=`, `%=`, `//=`), negative indexing,
core builtins tier 1 + most of tier 2, `def`/recursion, `while`/`until`/`repeat`,
`label`/`break`, `reduce`, `foreach`, path algebra (`getpath`/`setpath`/`delpaths`/
`paths`/`leaf_paths`), `?//` destructuring alt, builtin overloads, `contains` on
strings, format strings (`@base64`/`@base64d`/`@uri`/`@html`/`@csv`/`@tsv`/`@json`/
`@text`/`@sh`), assignment with complex lhs, comma generators in brackets.

**Builtins (beyond tier 1/2):**
string ops + regex + trim family, full math library, array extras (`transpose`,
`bsearch`, `recurse`, `nth`, `walk`, `skip`), object path algebra + `pick`/`path`,
I/O (`input`/`inputs`/`debug`/`stderr`/`halt`/`halt_error`), env (`env`, `builtins`,
`$__loc__`), SQL-style (`INDEX`, `IN`, `JOIN`), date/time, type selectors, misc
(`isempty`/`ascii`/`first`/`last`/`utf8bytelength`/`add(expr)`).

**CLI:** `-s`/`--slurp`, `-S`/`--sort-keys`, `-R`/`--raw-input`, `-j`/`--join-output`,
`-f`/`--from-file`, `--arg`, `--argjson`, `--tab`/`--indent N`, `--args`/`--jsonargs`,
`-C`/`--color-output`, `-M`/`--monochrome-output`.

---

## Tier 2: Agent-First Interface

> Where zq wins even when jq also works. The reason an agent reaches for zq first.

### 2.1 Shipped — the moat today

| | Feature | What it does |
|---|---------|--------------|
| [x] | **`--json-errors`** | Errors as JSON to stderr: `{"error": "type_error", "line": 1, "col": 5, "offset": 4, "len": 0, "filter": "...", "message": "...", "description": "..."}`. Agents can parse, understand, and self-correct. |
| [x] | **`--describe`** | Print input data shape to stdout: `{"type": "object", "fields": {...}, "count": N}`. Agents inspect data before writing a query. |
| [x] | **`--validate FILTER`** | Check filter syntax, exit 0 if valid, exit 3 with JSON error if not. No input required. |
| [x] | **Documented exit codes** | 0=success, 1=false/null (-e), 2=usage, 3=compile error, 4=runtime error, 5=system error. |
| [x] | **`llms.txt`** | Machine-readable documentation file at repo root. Structured reference of all flags, builtins, and query syntax. |
| [x] | **C ABI error details** | `zq_execute` returns granular error codes (-1 to -5). `zq_get_error` returns JSON error string. `zq_compile_ext` reports compile errors. |
| [x] | **LSP (Language Server)** | `zq --lsp`. Autocomplete, hover docs, diagnostics, references, rename, semantic tokens, formatting. Source: `src/lsp/`. |

### 2.2 Agent usability — pending

| | Feature | What it does | Why agents need it |
|---|---------|-------------|-------------------|
| [ ] | **`--strict`** | Error on null field access instead of propagating null. `.foo` on `{"bar": 1}` is an error, not `null`. | Unambiguous pass/fail. Silent null propagation causes subtle bugs agents can't detect without inspecting every output value. |
| [ ] | **`--suggest`** | On field-not-found errors, include available fields: `"available": ["foos", "foo_count"]`. On function errors, suggest closest builtin. | Agents self-correct in a single retry instead of blind guessing. |
| [ ] | **`--explain FILTER`** | Output a plain-english description of what a filter does. | Agents can verify their own query intent before executing. |
| [ ] | **Structured `--help`** | `--help --json` outputs help as structured JSON: flags, builtins, examples, all machine-parseable. | Agents programmatically understand zq's full capabilities without parsing human-readable text. |
| [ ] | **`--json-output` default detection** | When stdout is not a TTY (agent/pipe context), default to compact JSON + `--json-errors`. | Agents get machine-readable output by default without needing to remember flags. |
| [ ] | **`--schema FILE`** | Validate input against JSON Schema before processing. Exit with structured error on mismatch. | Agents can enforce data contracts in pipelines. |

### 2.3 Integration surfaces

| | Feature | Detail |
|---|---------|--------|
| [ ] | **Python bindings** | `pip install zq` — cffi bindings wrapping the C ABI. `zq.query('.id', data)` returns Python objects. Agents run in Python; direct library calls beat shelling out. |
| [ ] | **WASM build** | `zig build -Dtarget=wasm32-wasi`. zq in browsers, edge functions, sandboxed agent environments. |
| [ ] | **MCP server** | zq as a Model Context Protocol tool. Agents call `query_json`, `describe_json`, `validate_filter` as structured tool calls. |
| [ ] | **`--tool-spec`** | Output a JSON tool definition (OpenAPI-compatible) describing zq's capabilities, flags, and builtins. Universal discovery beyond MCP. |
| [ ] | **Agent framework integrations** | Pre-built tool definitions for LangChain, CrewAI, AutoGen, Claude Agent SDK. |
| [ ] | **`zq serve`** | Long-running HTTP/gRPC server mode. POST JSON + filter, get results. Connection pooling, compiled query caching. |
| [ ] | **Plugin system** | Custom builtins via shared library. Load with `--plugin path.so`. Uses the C ABI. |
| [ ] | **Telemetry hooks** | Optional structured logging of queries, errors, and performance to stderr or a file. |
| [ ] | **MCP registry listing** | List zq in Anthropic's MCP registry and other agent tool directories after MCP server stabilizes. |

---

## Tier 3: Long-Tail jq Parity (the last 1%)

> Edge cases agents and scripts almost never hit. Required for 100% compat test
> pass rate, not for usability. Every item here is a rare corner.

### 3.1 Number/literal edge cases

| | Feature | Tests blocked | Detail |
|---|---------|---------------|--------|
| [ ] | **Float index truncation** | ~5 | `.[1.5]` should truncate to `.[1]`, `.[nan]` should error, `.[1.2:3.5]` should truncate slice bounds. |
| [ ] | **JSON parser: extended literals** | ~3 | `Infinity`, `-Infinity`, `NaN`, `-NaN` as input JSON literals not accepted. jq accepts these as extension. |
| [ ] | **Error message wording parity** | ~8 | `try (1/0) catch .`, `try -. catch .` — error strings don't match jq's exact wording. |

Number-formatting failures L593, L661, L674, L2195 require jq's arbitrary-precision decnum build and are fundamentally incompatible with zq's f64 representation. Tracked as a documented deviation, not a TODO — see [Deliberate Deviations](#deliberate-deviations-from-jq).

### 3.2 Remaining builtins

| | Category | Functions |
|---|----------|-----------|
| [ ] | **Env** | `$ENV` (env builtin covers same need) |
| [ ] | **Type selectors** | `finites` |
| [ ] | **SQL-style** | `GROUP_BY` |
| [ ] | **Array** | `combinations` |
| [x] | **Misc** | `limit/2` (src/vm/root.zig:34, 1711–1753) |
| [ ] | **Misc** | `repeat` (parser-only stub at src/ast/parser.zig:1681; no IR/emit/VM opcode) |

### 3.3 Module system

| | Item | Detail |
|---|------|--------|
| [ ] | `import "path" as name;` | Load module definitions. |
| [ ] | `include "path";` | Inline module definitions. |
| [ ] | `-L dir` | Module search path. |
| [ ] | `modulemeta` | Module metadata access. |

### 3.4 Remaining CLI flags

| | Feature | Detail |
|---|---------|--------|
| [ ] | `--stream` | Streaming path-value event output. |
| [ ] | `--seq` | RFC 7464 JSON Sequence support. |

---

## Tier 4: Strictly Better Than jq

> Features jq fundamentally cannot do. Where zq is the obvious choice for new work.

### 4.1 Parallel JSONL

Pool module fully implemented; CLI surface pending.

| | Item | Detail |
|---|------|--------|
| [x] | **In-order output guarantee** | Chunk-level Sequencer delivers ChunkResults in submission order. |
| [x] | **Per-line error handling** | Parse/query errors become `RecordOutcome.err`; surfaced per-record without aborting. |
| [x] | **Work stealing** | MPMC JobQueue with N_CHUNKS jobs; workers pull freely. Newline-aligned byte-range chunks. |
| [x] | **Stream pipeline** | IO thread reads stdin in 256 KB batches. InFlightLimiter backpressure. **215s → 1.4s (150x faster), 7 MB RSS.** |
| [ ] | `-P N` / `--parallel N` / `-P 0` / `--parallel auto` | CLI flag pending; parallelism is already auto-enabled in file mode. |
| [ ] | **Parallel single-file arrays** | Detect top-level `[{...}, {...}, ...]`. Scan for object boundaries at bracket depth 1, split across workers. |
| [ ] | **Near-linear scaling** | Up to core count on JSONL. |

### 4.2 Streaming & incomplete JSON (LLM use case)

| | Item | Detail |
|---|------|--------|
| [x] | **O(n) incremental parsing** | Parser maintains state across `feed()` calls. No re-parsing from position 0. |
| [x] | **Partial string completion** | `"hel` → `"hel"`. Auto-close implemented for all containers. |
| [ ] | **`--stream-recover`** | Process incomplete JSON by auto-closing truncated containers. Already implemented in parser — needs CLI flag. |
| [ ] | **`--follow` / `-f`** | Like `tail -f`. |
| [ ] | **SSE parsing** | Parse `data: {...}` lines from Server-Sent Events. Strip `data: ` prefix automatically. |

### 4.3 Number precision beyond jq

| | Item | Detail |
|---|------|--------|
| [x] | **i64 integers** | Tape stores integers as i64. Exact to 2^63 - 1. No silent float promotion. |
| [ ] | **Literal passthrough** | Numbers not modified by arithmetic are output verbatim from source bytes — no reformatting. |
| [ ] | **i128 / bigint for arithmetic** | When i64 overflows, promote to i128 or arbitrary precision rather than silently wrapping. |
| [ ] | **`--warn-precision`** | Emit stderr warning when precision is lost (opt-in). |

### 4.4 Extended input formats

| | Format | Detail |
|---|--------|--------|
| [x] | **NDJSON / JSONL** | Newline-delimited JSON. Default multi-document mode. |
| [ ] | **JSONC** | JSON with `//` and `/* */` comments. Common in config files. |
| [ ] | **YAML** | Read YAML input, apply jq filters, output JSON. |
| [ ] | **TOML** | Read TOML input, apply jq filters, output JSON. |
| [ ] | **CSV/TSV** | Read CSV/TSV with header row → array of objects. `--csv-input`, `--tsv-input`. |
| [ ] | **MessagePack** | Binary JSON. Read MessagePack, apply jq filters, output JSON or MessagePack. |
| [ ] | **CBOR** | Binary JSON (IETF standard). Similar to MessagePack support. |

### 4.5 Extended output formats

| | Format | Flag | Detail |
|---|--------|------|--------|
| [ ] | YAML | `--yaml-output` | Output as YAML instead of JSON. |
| [ ] | CSV | `--csv-output` | Output as CSV (requires flat objects). |
| [ ] | TSV | `--tsv-output` | Output as TSV. |
| [ ] | MessagePack | `--msgpack-output` | Binary JSON output. |
| [ ] | Table | `--table` | ASCII table for terminal display. |

### 4.6 Better errors

| | Item | Detail |
|---|------|--------|
| [x] | **Filter position** | Points to the exact character in the filter that failed, with `^~~~` underline. |
| [x] | **Input context** | Shows the JSON value that caused the error (input_preview in diagnostics). |
| [x] | **User error surfacing** | `error("msg")` surfaces the message in stderr output and JSON errors. |
| [ ] | **Suggestions** | "did you mean `;` instead of `,`?" for common jq syntax mistakes. |
| [ ] | **Color errors** | Red/yellow ANSI coloring when stderr is a TTY. |
| [ ] | **Stack trace** | For `def` recursion: show the call chain that led to the error. |

### 4.7 Developer experience

| | Item | Detail |
|---|------|--------|
| [ ] | **REPL mode** | `zq --repl` — interactive filter development with instant feedback. |
| [x] | **Filter comments** | `#` to end-of-line. jq-compatible. |

---

## Tier 5: Ecosystem & Distribution

### 5.1 Distribution — shipped

| | Channel | Detail |
|---|---------|--------|
| [x] | **Static binaries** | All 6 platforms via GitHub Releases. |
| [x] | **Homebrew** | `brew install Enriquefft/zq/zq`. |
| [x] | **AUR** | `yay -S zq-bin`. |
| [x] | **Nix** | `nix run github:Enriquefft/zq`. |
| [x] | **Docker** | `docker run ghcr.io/enriquefft/zq`. |
| [x] | **GitHub Releases** | Automated via CI on tag push. |
| [x] | **npm** | `npx @zqjson/zq` — for Node/JS agent environments. |
| [x] | **PyPI** | `pip install zq-json` — for Python agent environments. |
| [x] | **Release automation** | GitHub Actions: tag → build 6 platforms → release → npm + PyPI + Homebrew + AUR. |

### 5.2 Distribution — pending

| | Channel | Detail |
|---|---------|--------|
| [ ] | **APT/DEB** | PPA or direct `.deb`. |
| [ ] | **Scoop** | Windows package manager. |
| [ ] | **asdf / mise plugin** | Version-managed install for polyglot dev environments. Low maintenance once published. |
| [ ] | **conda-forge recipe** | Surfaces zq in scientific-Python / data-engineering environments where `conda` is the default. |
| [ ] | **MacPorts** | Parallel to Homebrew on macOS; some users prefer it. |

### 5.3 libzq (C ABI)

| | Item | Detail |
|---|------|--------|
| [ ] | **Stable ABI** | Versioned symbols. ABI breaks only on major version. |
| [ ] | **pkg-config** | `pkg-config --libs libzq`. |
| [ ] | **Header file** | `zq.h` with full documentation. |
| [ ] | **Shared library** | `.so` / `.dylib` / `.dll` builds. |
| [ ] | **Language bindings** | Python (cffi, in-tree — see Tier 2.3), Node (ffi-napi), Go (cgo). Node/Go community-maintained. |

### 5.4 Documentation

| | Item | Detail |
|---|------|--------|
| [ ] | **Man page** | `man zq` — complete CLI reference. |
| [ ] | **Website** | Landing page with benchmarks, examples, migration guide. Server-rendered HTML, not SPA (crawlers + LLM scrapers must read markup directly). |
| [ ] | **Website: SEO & AI discoverability** | schema.org `SoftwareApplication` + `FAQPage` markup, Open Graph meta, canonical URLs, sitemap.xml, `robots.txt` whitelisting GPTBot / ClaudeBot / anthropic-ai / PerplexityBot / Google-Extended (default-block on some hosts). First-page H1 keywords: "jq alternative", "drop-in jq replacement" (gated on 99% compat), "fast JSON CLI". |
| [ ] | **Public live compat matrix page** | Rendered from CI artifacts on every release. Citeable URL distinct from `ROADMAP.md` — evergreen authority artifact that external-project PRs (jq README, awesome-lists) and Wikipedia edits will cite as evidence for the "drop-in" claim. |
| [ ] | **Migration guide** | "Switching from jq to zq" — flag mapping, known deviations, FAQ. |
| [ ] | **Filter cookbook** | Common recipes: API response parsing, log processing, LLM output handling. |
| [ ] | **Agent integration guide** | "Using zq in automated workflows" — MCP setup, Python bindings, error handling patterns. |
| [ ] | **Shell completions** | bash, zsh, fish. Shipped in the Nix derivation + release tarball. Surfaces zq at tab-time for any shell user. |
| [ ] | **Asciinema cast (embedded on landing)** | Terminal recording demonstrating core flows. Mark "pre-1.0 preview" until 1.0. Evergreen once uploaded; embedded on the landing page and referenced from the launch blog. |

### 5.5 IDE / editor

| | Item | Detail |
|---|------|--------|
| [x] | **LSP** | Shipped in v0.1 (see Tier 2.1). |
| [ ] | **VS Code extension** | Syntax highlighting + LSP integration for `.jq` filter files. |

### 5.6 Quality & engineering infrastructure

| | Item | Detail |
|---|------|--------|
| [x] | **jq compat test suite** | Fully migrated (569 tests; 547 passing, 22 known-fail tracked separately). |
| [x] | **Snapshot test suite** | Compiler IR + fuse-pass snapshot tests in `tests/compiler/` (snapshots_test.zig, snapshots_fuse_test.zig). Post-cutover regression coverage. |
| [x] | **CI: `zig build test`** | Every commit. |
| [x] | **Error messages with filter position + input context** | Done. |
| [ ] | **CI benchmark regression** | Fail CI if throughput drops > 10% vs previous release. |
| [ ] | **Fuzz testing** | AFL/libfuzzer on parser + query compiler; continuous fuzzing via OSS-Fuzz or equivalent. |
| [ ] | **Differential fuzz vs jq (generalized)** | Extends existing `zig build fuzz-regex` harness to the full filter surface. Randomly generated filter/input pairs; diffs `zq` output vs `jq` reference. Divergences auto-filed as compat issues. Turns 99%-compat closure into an unattended CI loop — the highest-leverage "grows on its own" investment for crossing the passive-discovery gate in Tier 5.7. |
| [ ] | **Memory leak testing** | All tests pass under Zig's GPA leak detection. |
| [ ] | **No undefined behavior** | `zig build -Doptimize=ReleaseSafe` as default. Debug + ReleaseSafe + ReleaseFast all green. |
| [ ] | **CI matrix** | Linux x86_64, Linux aarch64, macOS x86_64, macOS aarch64. Zig 0.15.x. |
| [ ] | **Reproducible builds** | Same source → same binary (bit-for-bit). |
| [ ] | **OpenSSF Scorecard badge** | Auto-runs weekly via GitHub Action; surfaces score on README + landing. Signals supply-chain hygiene to downstream packagers (Debian, Fedora, Homebrew-core) and trust to agents scanning the repo. One-time setup, runs forever. |
| [ ] | **OpenSSF Best Practices badge** | One-time self-assessment against the CII Best Practices criteria; badge permanent once earned. Passive authority signal referenced by nixpkgs / distro packaging reviews. |

### 5.7 Passive Discovery & Corpus Seeding

> One-time investments that surface zq to strangers (and agents) without ongoing
> maintenance. Grouped by **compat gate** — firing these prematurely burns one-shot
> impressions and poisons the corpus with "zq is a buggy jq wannabe" instead of
> seeding "zq is the fast drop-in". Gate-respect is load-bearing.

**Gate legend:**

- **Any** — safe at current compat level; infrastructure-only, no "drop-in" claim.
- **CLI frozen (~v0.9)** — Tier 1.2 flags shipped, flag names stable (submission fossilizes them).
- **99% compat + 1.0** — "drop-in jq replacement" claim holds under adversarial scrutiny.
- **1.0 + production** — proven in real use; notability and long-term stability established.

| | Item | Gate | Detail |
|---|------|------|--------|
| [ ] | **awesome-zig list PR** | Any | Zig community lenient on pre-1.0 tooling. Low-bar immediate backlink. |
| [ ] | **tldr-pages entry** | CLI frozen | `tldr zq` lives in every dev box's tldr cache. Flag names fossilize on submit — wait until Tier 1.2 closes to avoid stale entries. |
| [ ] | **DevDocs.io submission** | CLI frozen | Integrates docs into the offline reference app used by devs and IDE plugins. |
| [ ] | **cheat.sh entry** | CLI frozen | `curl cheat.sh/zq`. Passive reference surface scraped by tooling. |
| [ ] | **explainshell.com integration** | CLI frozen | Teaches explainshell zq's flag grammar. Agents scanning shell commands pick it up. |
| [ ] | **HN "Show HN" launch** | 99% compat + 1.0 | One-shot. Blown impression at pre-1.0 compat is permanent — HN will not re-look at v1.0 later. Needs landing page, compat matrix, asciinema cast, and launch blog ready as linked assets. |
| [ ] | **jq README "alternatives" section PR** | 99% compat + 1.0 | Read by every jq user and crawled into future training corpora. Upstream maintainers reject "drop-in" framing unless compat is proven. |
| [ ] | **awesome-cli / awesome-json / awesome-nix list PRs** | 99% compat + 1.0 | Most list maintainers reject alpha-stage tools. High-PageRank backlinks. |
| [ ] | **Wikipedia `jq` article edit mentioning zq** | 99% compat + 1.0 | WP:RS requires secondary citations (HN, blog, benchmark post) to survive. Reverts are the default for non-notable additions. |
| [ ] | **Launch blog post (methodology + benchmarks)** | 99% compat + 1.0 | Academic-style citeable artifact. Becomes the substrate future Wikipedia / awesome-list / press references cite. Published on zq's own domain for authority. |
| [ ] | **YouTube demo + comparison video** | 99% compat + 1.0 | Evergreen in YouTube search for "jq alternative", "fast jq". One-time upload, permanent SEO tail. |
| [ ] | **Debian / Fedora / Alpine official repos** | 1.0 + production | Long maintainer cycles; worth the latency only once zq is stable and already shipped downstream (nixpkgs / homebrew-core). |
| [ ] | **Standalone Wikipedia article for zq** | 1.0 + production | Notability threshold requires accumulated citations from prior gate-gated items (HN, blog, press). Article gets speedy-deleted without them. |
| [ ] | **Conference talks (FOSDEM, NixCon, Zig meetup, StrangeLoop)** | 1.0 + production | Each talk is a one-shot artifact that lives in YouTube / proceedings indefinitely. |
| [ ] | **nixpkgs `jq → zq` alias PR** | 1.0 + production | Distro-level name-capture. Referenced by user's own `/etc/nixos/flake.nix:89` disabled overlay — re-enable globally once nixpkgs maintainers accept. Highest-reach zero-user-awareness discovery mechanism. |

**Why gating matters:** compat claims are load-bearing. The moment "drop-in jq replacement"
appears on HN / Wikipedia / jq README, every gap becomes adversarial feedback from
strangers — not collaborative feedback from contributors. Hold 99%-compat-or-1.0-gated
items until the public compat matrix (Tier 5.4) crosses 99%.

**What accelerates crossing the gate:** the generalized differential fuzz harness
(Tier 5.6) turns compat closure into an unattended CI loop. That is the truest
"grows on its own" passive-discovery investment. Everything else in 5.7 waits on
the fuzz harness finding and closing the long tail.

---

## Performance & Memory (shipped)

### Memory optimization — v0.1 target met and exceeded

Current state: **403 MB RSS** for 1.3 GB JSONL `.id` query **(0.31x input)**. Target < 2x: **achieved**. Target ~1x: **achieved**.
Progress: 2998 MB → 1702 MB → 701 MB → 403 MB (-87% total).

| | Item | Detail |
|---|------|--------|
| [x] | **Bounded chunk count** | InFlightLimiter caps in-flight chunks at `IN_FLIGHT_FACTOR x n_threads`. Memory bounded to ~`chunk_size x n_threads`, not file size. **2998 MB → 1764 MB (-41%), 38s → 1.41s (27x faster).** |
| [x] | **Ordered output queue** | Fixed-size ring buffer replaces HashMap in Sequencer. O(1) post and fetch with zero dynamic allocation in the hot path. **1764 MB → 1702 MB (-3.5%).** |
| [x] | **Batched stream mode** | stdin routes through parallel pool via `submit_stream()`. IO thread accumulates lines into 256 KB batches. InFlightLimiter backpressure. **Streaming 215s → 1.4s (150x faster); RSS ~7 MB.** |
| [x] | **2 MiB thread stacks** | Reduced from 16 MiB default. Workers use heap-allocated parse/query stacks. **~224 MB saved.** |
| [x] | **Contiguous serialized chunks** | One contiguous byte buffer + compact `RecordMeta` array (8 B/record vs ~32 B). Format-aware pre-alloc reduces arena page leaks. **1053 MB → 715 MB (-32%) for `.id`; 2203 MB → 1980 MB (-10%) for `select()`.** |
| [x] | **`madvise(MADV_DONTNEED)`** | After workers serialize a chunk's output into the arena buffer, call `madvise(MADV_DONTNEED)` on mmap pages. Bounds mmap RSS to `in_flight × chunk_size` instead of `file_size`. Linux-only; no-op elsewhere. **1648 MB → 396 MB for `.id` (-76%); 0.31x input RSS.** |

**Results:**
- `.id`: **0.31x input** (403 MB for 1.3 GB file)
- `select(.id > 500000)`: **0.64x input** (831 MB)

### Performance — shipped

| | Item | Detail |
|---|------|--------|
| [x] | **SIMD structural scanner** | AVX2 (x86_64), NEON (aarch64). Classify bytes 32/16 at a time. SIMD fast paths for string scanning and whitespace. |
| [x] | **Parallel file mode** | mmap + chunk-based workers. Auto-enabled in CLI. **31x vs jq, 20x vs jaq** on 15M-record JSONL `.id`. |
| [x] | **Query plan caching** | Query compiled once; ResultIterator `reset()` per record reuses eval stack. |
| [x] | **Tape arena allocator** | Per-chunk ArenaAllocator in pool. Zero GPA calls in the hot path for scalars. |
| [x] | **Output batching** | 64 KB buffered writes. |
| [x] | **mmap for large files** | io module (zero-copy reads) + pool submit_file (mmap → byte-range chunks → workers). |
| [x] | **Benchmark suite (code)** | `benchmarks/` directory. Hyperfine scripts comparing zq vs jq vs jaq. 5 scenarios. |
| [x] | **Startup time** | **~2.4 ms** (1.5x faster than jq); sub-ms without shell overhead. |

### Performance — pending

| | Item | Detail |
|---|------|--------|
| [ ] | **Published benchmark suite** | Reproducible published results — PR/post with comparison tables, methodology, datasets. |
| [ ] | **Prefetch** | Issue `madvise(MADV_SEQUENTIAL)` for large file scans. |

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

| | Item | What it does | Why it's publishable | Verified bottleneck | Verdict |
|---|------|-------------|---------------------|---------------------|---------|
| [ ] | **Projection pushdown** | `.id` on a 50-field object skips parsing 49 fields. Build SIMD structural index (colon/comma bitmaps per nesting level) to jump directly to queried fields. Fuse pass already identifies needed fields — feed that back to parser. | Mison showed 3.6-10.2x speedup. Novel integration: projection pushdown in a parallel tape-based system with SIMD structural indexing. | `lookupKey()` iterates linearly through all object entries (`vm.zig`). Full tape always built regardless of query. | **Implement** |
| [ ] | **Raw byte pre-filtering (Sparser-style)** | For `select(.status == "active")`, scan raw bytes for `"active"` with SIMD before any parsing. Records that don't contain the substring are skipped entirely. False positives are cheap; false negatives are impossible. Cascade multiple cheap filters for compound predicates. | Sparser showed 22x over Mison on high-selectivity queries. Novel: Sparser + chunk-parallel architecture. | `select()` parses entire record then evaluates in VM. No early rejection. | **Profile first** — only helps high-selectivity on large records. |
| [ ] | **Predicate pushdown into parser** | For `select(.age > 30)`, evaluate the predicate during parsing. Once `.age` is found and its value parsed, reject immediately without constructing the rest of the tape. | dsJSON (SIGMOD 2023) introduced projection trees for distributed JSON. Fusing predicate evaluation with tape construction in a bytecode VM is novel. | Full tape constructed before any filtering. VM evaluates predicate on complete value. | **Implement** |
| [ ] | **Speculative schema caching** | JSONL records typically share structure. Cache field byte-offsets from record N, speculatively jump directly to that offset in record N+1. Validate with a single comparison. | Mison introduced speculation (10.2x with vs 3.6x without). Novel: speculation in a multi-threaded chunk-parallel system where each worker maintains its own speculative cache. | Records parsed independently. No cross-record optimization. | **Profile first** — fragile; one heterogeneous dataset breaks the cache. |
| [ ] | **On-demand / lazy materialization** | After structural indexing, don't build tape entries for fields the query doesn't access. Materialize values lazily on first access. | simdjson On-Demand (SPE 2024) showed this outperforms both DOM and SAX. Novel: lazy materialization integrated with parallel pool + sequencer architecture. | Full tape always constructed in parser. | **Paper only** — massive tape format refactor for marginal gain once projection pushdown exists. |

**Implementation order:** Projection pushdown first (clearest gain, simplest to measure), then predicate pushdown (compounds with projection). Sparser and speculation only after profiling on real workloads justifies them. On-demand is paper-track only.

**Expected combined gain:** 2-5x for selective queries (`.id`, `select()`, `has()`) on wide objects.

---

### Track B: Adaptive Execution

zq has two fast execution modes (streaming, parallel file) but no principled mechanism
to choose between strategies or adapt mid-execution. Academic work on adaptive query
processing (Eddies, Spark AQE) shows runtime adaptation outperforms static plans on
heterogeneous workloads.

**Prior art:** Eddies (SIGMOD 2000), Adaptive Query Processing survey (FnT Databases 2007), Spark AQE (2020), Learned Cost Models (SIGMOD 2020-2025)

| | Item | What it does | Why it's publishable | Verified bottleneck | Verdict |
|---|------|-------------|---------------------|---------------------|---------|
| [ ] | **Per-chunk adaptive strategy** | After processing the first N chunks, measure actual selectivity and parse cost. If selectivity is low (<5% of records pass), switch remaining chunks to Sparser-style raw filtering. If records are simpler than expected, adjust chunk sizing. | Per-chunk granularity is novel — Eddies operates per-tuple, Spark AQE per-stage. | `computeParams()` uses static memory-based formula. No runtime adaptation. | **Profile first** — switching logic itself adds overhead. |
| [ ] | **Cost model for mode selection** | Predict optimal execution mode (single-threaded / pool-file / pool-stream) and parameters (chunk size, batch size, in-flight limit) from input characteristics. | Cross-engine cost models (SIGMOD 2025) showed 25-30% gains from learned routing. | `MemoryBudget` considers only memory, not query cost or record complexity. | **Paper only** — a few `if` statements on file size and query type gets 95% of the way. |
| [ ] | **Close the streaming/file gap** | Streaming is 3.3x slower than file mode (3.47s vs 1.05s). Root causes: single IO thread serializes all reading, per-batch heap allocation (`allocator.dupe` per 256KB batch), `JobQueue.signal()` wakes only one thread. Fix: multiple IO threads, zero-copy batch handoff, `broadcast()` on queue drain. | Systematic analysis of streaming vs mmap performance in a real system, with principled fixes. | Single IO thread (`pool/root.zig` io_thread_fn). Per-batch `dupe()` allocation. | **Implement** |

**Expected combined gain:** 1.5-3x on streaming workloads; smarter strategy selection across diverse inputs.

---

### Track C: Compiler Optimizations for JSON Query Bytecode

zq's compiler emits bytecode with a single fuse pass (collapsing `.a | .b | .c`). Standard
compiler optimizations — constant folding, CSE, specialized instruction emission — are
entirely absent.

**Prior art:** Compiled vs Vectorized Queries (PVLDB 2018), general compiler optimization literature

| | Item | What it does | Why it's publishable | Verified bottleneck | Verdict |
|---|------|-------------|---------------------|---------------------|---------|
| [ ] | **Constant folding** | `.x + 5 - 2` compiles to `.x + 3` (saves 2 instructions). `select(true)` becomes identity. `expr and false` short-circuits. | Standard optimization applied to novel domain. | No constant folding. Literals emitted as separate push instructions. | **Implement** |
| [ ] | **Common subexpression elimination** | `(.x + .y) + (.x + .y)` computes `.x + .y` once. Build expression DAG during compilation, detect duplicates. | CSE on a filter-language bytecode is novel. 10-20% instruction reduction on complex filters. | Each subexpression compiled independently. No DAG or deduplication. | **Paper only** — JSON queries rarely complex enough. |
| [ ] | **Monomorphic selector specialization** | Detect `select(.field == literal)` at compile time. Emit specialized bytecode that branches on field value directly, eliminating generic comparison dispatch + fork setup. | JIT-like specialization for interpreted JSON queries. 10-30% speedup on filter-heavy workloads. | `select()` compiles as: save_input, evaluate predicate generically, jump_if_false, restore. | **Profile first** |
| [ ] | **Extended fuse pass** | Fuse `.key \| has()` → `key_exists` opcode. Fuse `.key \| length` → `key_length`. Fuse `.key \| type` → `key_type`. | Systematic instruction fusion for JSON query VMs. | Fuse pass limited to `.a \| .b \| .c` → `load_path`. | **Implement** |
| [ ] | **Tail call optimization** | Recursive `def` functions converted to loops. Detect tail-position calls, eliminate call frames. | TCO for a JSON query language. 80-90% speedup on recursive user-defined functions. | No TCO. Each recursive call allocates a full call frame. | **Paper only** — very few people write recursive `def` in jq. |

**Expected combined gain:** 15-35% on complex queries; eliminates pathological performance on recursive functions.

---

### Track D: Data Structure Optimizations

Targeted improvements to the tape format, value representation, and hot builtin
implementations.

| | Item | What it does | Expected gain | Verified bottleneck | Verdict |
|---|------|-------------|---------------|---------------------|---------|
| [ ] | **Object key indexing** | For objects with >N keys (e.g., N=16), build a compact hash table mapping keys to tape offsets during parsing. `has()`, `lookupKey()`, field access become O(1) instead of O(fields). | 20-40% on `has()`/field access for wide objects | `lookupKey()` linear scans all entries. `has()` also linear. | **Implement** |
| [ ] | **Cached array/object length** | Store element count in tape during parsing. `length` builtin returns cached value. Zero cost at parse time. | 8-15% on `length`-heavy queries | `length` re-walks tape on every call. | **Implement** |
| [ ] | **String deduplication** | Build per-chunk hash map of `{string bytes → string_buf offset}`. High impact on logs/configs with repeated field names. | 10-30% memory on repetitive data | Strings always copied to string_buf. No deduplication. | **Profile first** — only wins on highly repetitive data. |
| [ ] | **COW strings** | For unescaped strings, store pointer into input buffer instead of copying. Only copy strings that need escape processing. | 20-30% memory on large-string JSON; ~5% parse speed | All strings copied regardless of escape status. | **Implement** |
| [ ] | **Inline small strings** | Embed strings <=8 bytes directly in the tape entry payload. Eliminates string_buf indirection for short keys like `"id"`, `"name"`, `"type"`. | 10-15% on short-key-heavy JSON | All strings go through string_buf indirection. | **Paper only** — changes tape layout for marginal cache improvement. |
| [ ] | **Type-aware arithmetic opcodes** | `add_int`, `add_float`, `add_string` instead of generic `add`. Compiler detects operand types, emits specialized opcode. | 5-8% on numeric-heavy queries | Generic `add` dispatches through type switch every call. | **Paper only** — numeric-heavy JSON queries barely exist. |

---

### Track E: Evaluation Infrastructure

No paper without rigorous evaluation. Table-stakes.

| | Item | What it does | Why it matters | Verdict |
|---|------|-------------|----------------|---------|
| [ ] | **Multi-system benchmark suite** | Compare against jq, jaq, gojq, simdjson (with custom query layer), DuckDB `read_json`, ClickHouse JSON, Polars JSON. Varied workloads. | No rigorous academic benchmark exists for this space. | **Implement** |
| [ ] | **Microbenchmark harness** | Isolate and measure individual components: parse time, field lookup, predicate evaluation, serialization, thread coordination. | Reviewers want to see where time goes. | **Implement** |
| [ ] | **Workload characterization** | Curate diverse JSON datasets: API responses, logs, configs, geospatial, scientific. Characterize record width, nesting depth, string ratio, schema stability. | Optimization effectiveness varies by workload. | **Implement** |
| [ ] | **Scalability analysis** | Measure throughput as function of: core count, file size, record size, selectivity, nesting depth. | Establishes where zq's architecture excels. | **Implement** |

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
| Error output | Human-readable text only | `--json-errors` for structured JSON errors | Agent integration. |
| Null propagation | Silent null on missing fields | `--strict` errors on null field access | Agent reliability. |
| Regex engine | Oniguruma (archived 2025; ReDoS-vulnerable) | `regex-automata` (linear-time, unicode-aware, panic-safe) | Security, maintenance trajectory. |
| Number representation (decnum edge cases) | Arbitrary-precision via optional decnum build | f64 everywhere. ~4 compat tests (L593, L661, L674, L2195) produce different output on extreme magnitudes. `have_decnum`/`have_literal_numbers` report `false`. | Performance and memory footprint. Ruled out by design; not a TODO. |

---

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
`s` (dotall / `.` matches `\n`), `x` (ignore whitespace), `g` (global — dispatches
to the generator-mode match opcode at compile time; no-op for scan/sub/gsub/
splits which already match globally), `n` (ignore zero-width overall matches —
implemented across every regex builtin: `test`/`match`/`capture`/`scan`/`sub`/
`gsub`/`splits`, threaded through via a `call_builtin` operand bit). Unknown
flag letters are a compile error.

**Compat delta vs jq (deliberate, documented):**

| Feature | jq/onig | zq | User workaround |
|---|---|---|---|
| Pattern backrefs (`(\w+) \1`) | works | compile error | rewrite without backref |
| Positive/negative lookaround | works | compile error | alternation + anchors |
| `\g<name>` subroutine calls in pattern | works | compile error | repeat the subpattern inline |
| Replacement-as-filter (`\(.field)` in repl) | jq evaluates the replacement as a full filter with `.` bound to the match object | `\1..\9` and `\g<name>` backref substitution only | compose with `match` + manual concat. **Accepted as permanent delta** — pulling the full jq evaluator into the sub/gsub path violates the VM boundary for a rarely-used feature. |
| `match(re; "g")` global-generator mode | yields all matches | yields all matches (implemented) | — |
| `match([re, flags])` array overload | works | compile error | `match(re; flags)` |
| `splits(re; flags)` regex split | works | works (implemented) | — |
| `n` flag: empty-first alternation (`match("\|a"; "n")`) | Oniguruma's `ONIG_OPTION_FIND_NOT_EMPTY` retries non-empty alternatives at the same position, so `match("\|a"; "n")` lands on `"a"`. | `regex-automata` has no equivalent option — the engine commits to the empty alternative and the n-flag skip advances past it, yielding no match at that position. Rare pattern shape (leading empty alternative); all other `n`-flag semantics match jq. | rewrite the alternation with the non-empty branch first (`match("a\|"; "n")`) or use `scan`/`match`+`"g"` and filter manually. |

**Performance targets vs measured** (release build, isMatch, per-worker clone, x86_64 ReleaseFast):

| Pattern | Target | Measured median |
|---|---|---|
| Literal `"foo"` | 30–80 ns | 22 ns |
| Alternation `"foo\|bar\|baz\|qux"` | 80–200 ns | 35 ns |
| Anchored prefix `"^GET "` | 30–80 ns | 37 ns |
| Simple class `"[a-z]+"` | 80–200 ns | 32 ns |
| Named capture `"(?<year>\d{4})"` | 300 ns – 1 µs | 42 ns (isMatch path) |

All pattern classes meet or exceed plan targets. Run `zig build bench-regex
-Doptimize=ReleaseFast` to reproduce.

**Prefilter speedup on miss path** (`select(.endpoint | test("/v1/login"))` against
a 90-byte log record that does not contain the literal, 50k iterations,
iterator reused across records exactly as in `src/pool/root.zig: process_line`):

| Path | Median | p99 |
|---|---|---|
| full parse + query bytecode + no-match output | 461 ns | 884 ns |
| prefilter literal scan (record rejected before parse) | 59 ns | 62 ns |
| **speedup** | **7.8×** | 14× |

Honest measurement caveat: earlier drafts of this bench rebuilt the
`ResultIterator` per iteration (via `cq.execute` + `it.deinit`), which
inflated the "full path" median by two orders of magnitude and produced a
bogus ~2600× ratio. Production reuses the iterator — the bench now does too.
The 7.8× figure is the real parse-avoidance benefit per record; the whole-pipeline
end-to-end win depends on how often the prefilter fires (workload selectivity).

**Differential fuzz:** `zig build fuzz-regex` runs a small-grammar harness that
compares zq vs jq on randomly generated pattern/haystack pairs. 1000 iterations
produce 0 divergences. A second fuzz test diffs zq-with-prefilter vs
zq-without-prefilter vs jq across random `select(.k | test("LIT"))` queries and
records containing raw, `\uXXXX`-escaped, and short-escape-containing string
values — 1000 iterations, 0 divergences.

---

## Version Milestones (history)

The tiers above are the canonical priority order. These milestones remain useful
to mark completion waves and guide external release cadence.

### v0.1.0 — Useful (Agent Quick Wins) — shipped

- [x] 60%+ of migrated jq compat tests pass (currently 80%)
- [x] 100% of internal regression tests pass (443/443)
- [x] 75%+ compat with parity for assignment, paths, error semantics
- [x] All P0 query features (arithmetic, comparisons, conditionals, variables, object/array construction, string interpolation, recursive descent)
- [x] `zq` binary under 3 MB static (2.7 MB)
- [x] RSS < 2x input size for per-record file queries (0.31x achieved)
- [x] Startup time < 3ms (2.4ms)
- [x] `--json-errors`, `--describe`, `--validate`
- [x] Core builtins (jq's P1 tier-2 set — `sort`, `group_by`, `to_entries`/`from_entries`, `del`, `contains`, etc.), with the complex-arg gaps tracked in Tier 1.1

### v0.5.0 — Agent Ready — in progress

- [ ] 95%+ jq compat test pass rate (requires Tier 1.1 complete + Tier 3.1/3.2)
- [ ] Published benchmark suite
- [x] Demonstrated 10x+ throughput on JSONL workloads vs jq (31–43x)
- [ ] `--strict` + `--suggest` + `--explain` (Tier 2.2)
- [ ] WASM build (Tier 2.3)
- [ ] Python bindings (Tier 2.3)

### v1.0.0 — Agent Native

- [ ] 100% jq compat (or documented intentional deviations) — requires Tier 1 + Tier 3 complete
- [ ] Every jq CLI flag works identically
- [ ] Published on: brew ✓, apt/deb, AUR ✓, nix ✓, scoop, static binaries ✓, Docker ✓
- [ ] Man page, website with benchmarks and migration guide
- [ ] libzq with stable C ABI and pkg-config
- [ ] Security audit (minimum: fuzz coverage, no UB in release builds)
- [ ] Language bindings: Python, Node, Go (community-maintained)
- [ ] Corpus seeding fired: HN Show HN, jq README "alternatives" PR, Wikipedia edit, awesome-lists PRs, launch blog, YouTube demo (Tier 5.7 at 99% compat + 1.0 gate)
