# zq — up to 48x faster jq

<!-- badges -->
[![CI](https://github.com/Enriquefft/zq/actions/workflows/ci.yml/badge.svg)](https://github.com/Enriquefft/zq/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Drop-in replacement for jq. Same filter syntax, parallel execution on JSONL, native LLM-safe truncated JSON recovery, and a linear-time regex engine with a Sparser-style literal prefilter that skips entire records before parsing.

```sh
curl -fsSL https://raw.githubusercontent.com/Enriquefft/zq/main/install.sh | sh
```

---

## Benchmarks

![zq vs jq benchmark](demo/benchmark/benchmark.gif)

**File mode — 15M-record JSONL (1.3 GB), ReleaseFast, x86_64, regex enabled**

| Tool | `.id` | `select(.id > 500k)` | Complex query | RSS (`.id`) |
|------|-------|----------------------|---------------|-------------|
| jq 1.8.1 | 20.4s | — | — | 3.6 MB |
| **zq** | **0.83s ± 0.04** | **1.52s** | **1.96s** | **440 MB** |

> 24.6x faster than jq on field extraction. Up to 48x on regex-heavy end-to-end queries (`test()` with literal prefilter). **0.31x input RSS** — uses less RAM than the file itself, thanks to per-chunk arenas + `madvise(MADV_DONTNEED)` on processed mmap pages.

**Stream mode (stdin):** 1.76s, 7 MB RSS (11.6x faster than jq). **Startup:** 1.5 ms. **Binary:** 2.78 MB stripped with regex (`-Dregex=false` → 1.29 MB, no Rust dep); dynamically linked against libc + the vendored Rust `regex-automata` shim.

---

## Quick Demo

```sh
# Field access
echo '{"name":"zq","fast":true}' | zq '.name'
# "zq"

# Filter + transform
cat api_response.json | zq '[.results[] | select(.score > 0.9) | {id, label: .name}]'

# Parallel JSONL — processes 15M records in under a second
zq '.id' massive_dataset.jsonl > ids.txt

# Regex with literal prefilter — scans raw bytes before parsing
zq 'select(.message | test("CRITICAL"))' logs.jsonl
```

---

## Features

- **Drop-in compatible** — same jq filter language, same CLI flags
- **Parallel by default** — mmap + fixed worker pool saturates all cores
- **SIMD parsing** — AVX2/NEON accelerated JSON scanning
- **Linear-time regex** — backed by vendored Rust `regex-automata`; no ReDoS; Sparser-style literal prefilter skips whole records before parsing
- **Date/time builtins** — `now`, `gmtime`, `mktime`, `strftime`, `strptime`, `strflocaltime`, `todate`, `fromdate`, `todateiso8601`, `fromdateiso8601`
- **LLM stream recovery** — auto-closes truncated JSON mid-stream; never crashes on partial data
- **Exact integers** — i64 storage; no silent precision loss above 2^53 (unlike jq)
- **jq-compatible number formatting** — `formatJqFloat` matches jq's `jvp_dtoa_fmt` (Inf clamps to DBL_MAX, `-0` prints as `0`, `1e17` as `1e+17`)
- **Sub-millisecond startup** — 1.5 ms cold start
- **Language Server Protocol** — `--lsp` starts a JSON-RPC server on stdin/stdout with diagnostics, completion, hover, definition, references, rename, signature help, semantic tokens, and formatting
- **C ABI** — embed zq in any language via `zq_compile`/`zq_compile_ext`/`zq_execute`/`zq_get_result`/`zq_get_error`/`zq_free`

---

## For AI Agents

zq is designed for programmatic use. Key integration points:

- **Data shape inspection:** `--describe` shows input structure before you write a filter; tune with `--depth N`
- **Filter validation:** `--validate` checks syntax without executing — fail fast, no wasted runs
- **Structured errors:** `--json-errors` outputs diagnostics as JSON on stderr
- **Editor-grade tooling:** `--lsp` exposes the same compiler/analyzer surface used internally, so agents can drive diagnostics and completion over JSON-RPC
- **Granular exit codes:** 0=success, 1=false(-e), 2=usage, 3=compile error, 4=runtime error, 5=system error
- **Capability discovery:** `zq -n 'builtins'` lists all built-in functions
- **jq compatible:** same filter syntax — any jq knowledge transfers directly
- **C ABI:** embed via `zq_compile`/`zq_compile_ext`/`zq_execute`/`zq_get_error` for structured error details

---

## Deliberate differences from jq

| Behavior | jq | zq |
|----------|----|----|
| Large integers | Silently converted to f64, corrupting values > 2^53 | Stored as i64, exact to 2^63 |
| Division by zero | Inconsistent | Consistent IEEE 754 (`nan`, `infinite`) |
| Truncated JSON | Crashes | Auto-closes containers unconditionally |
| Regex `n` flag | Silently accepted | Rejected at compile time (no jq-incompatible silent output) |
| Regex engine | Oniguruma (PCRE-style, ReDoS-prone) | `regex-automata` (linear time, no backreferences or lookaround) |

---

## Installation

### Quick install

```sh
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/Enriquefft/zq/main/install.sh | sh

# Windows (PowerShell)
irm https://raw.githubusercontent.com/Enriquefft/zq/main/install.ps1 | iex
```

### Package managers

```sh
brew install Enriquefft/zq/zq        # Homebrew (macOS + Linux)
yay -S zq-bin                         # AUR (Arch Linux)
nix run github:Enriquefft/zq          # Nix
docker run -i ghcr.io/enriquefft/zq '.'   # Docker
```

### From source

```sh
git clone https://github.com/Enriquefft/zq && cd zq
zig build -Doptimize=ReleaseFast                      # full build (regex on)
zig build -Doptimize=ReleaseFast -Dregex=false        # dependency-free build, 1.29 MB
```

Requires [Zig 0.15.2](https://ziglang.org/download/). Full build also requires `rustc`+`cargo` (for the vendored `regex-automata` shim under `third_party/zq-regex-shim/`). Or with Nix: `direnv allow`.

---

## Roadmap

See [ROADMAP.md](ROADMAP.md) for milestone tracking. Current status: ~80% jq compat-suite coverage.

---

## License

MIT
