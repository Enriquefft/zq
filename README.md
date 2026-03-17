# zq — 25x faster jq

<!-- badges -->
[![CI](https://github.com/Enriquefft/zq/actions/workflows/ci.yml/badge.svg)](https://github.com/Enriquefft/zq/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Drop-in replacement for jq. Same filter syntax, 25x faster on large files, with native JSONL streaming and LLM-safe truncated JSON recovery.

```sh
curl -fsSL https://raw.githubusercontent.com/Enriquefft/zq/main/install.sh | sh
```

---

## Benchmarks

**File mode — 648 MB / 15M-record JSONL**

| Tool | `.id` | `select(.id > 500000)` | RSS (`.id`) |
|------|-------|------------------------|-------------|
| jq | 21.4s | 41.6s | 3.7 MB |
| jaq | 15.3s | 27.7s | 666 MB |
| **zq** | **0.87s** | **2.9s** | **715 MB** |

**Streaming mode — `cat file | zq .id`**

| Tool | Time | RSS |
|------|------|-----|
| jq | 22.2s | 3.7 MB |
| **zq** | **1.4s** | **7 MB** |

**Startup time:** ~2ms (2x faster than jq)
**Binary size:** 2.7 MB static, stripped, zero dependencies

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
```

---

## Features

- **Drop-in compatible** — same jq filter language, same CLI flags
- **Parallel by default** — mmap + fixed worker pool saturates all cores
- **SIMD parsing** — AVX2/NEON accelerated JSON scanning
- **LLM stream recovery** — auto-closes truncated JSON mid-stream; never crashes on partial data
- **Exact integers** — i64 storage; no silent precision loss above 2^53 (unlike jq)
- **Sub-millisecond startup** — 0.8ms cold start
- **C ABI** — embed zq in any language via `zq_compile`/`zq_execute`

---

## For AI Agents

zq is designed for programmatic use. Key integration points:

- **Capability discovery:** `zq -n 'builtins'` lists all built-in functions
- **Structured errors:** `--json-errors` outputs diagnostics as JSON on stderr
- **Granular exit codes:** 0=success, 1=false(-e), 2=usage, 3=compile error, 4=runtime error, 5=system error
- **jq compatible:** same filter syntax — any jq knowledge transfers directly
- **C ABI:** embed via `zq_compile`/`zq_execute`/`zq_get_error` for structured error details

---

## Deliberate differences from jq

| Behavior | jq | zq |
|----------|----|----|
| Large integers | Silently converted to f64, corrupting values > 2^53 | Stored as i64, exact to 2^63 |
| Division by zero | Inconsistent | Consistent IEEE 754 (`nan`, `infinite`) |
| Truncated JSON | Crashes | Auto-closes containers (opt-in via `--stream-recover`) |
| Duplicate object keys | Silent last-wins | Last-wins + optional `--warn-duplicate-keys` |

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
zig build -Doptimize=ReleaseFast
```

Requires [Zig 0.15.2](https://ziglang.org/download/). Or with Nix: `direnv allow`.

---

## Roadmap

**v0.1** ✅ — Core query engine, parallel runtime, agent-ready diagnostics, CLI parity
**v0.2** ✅ — Unified fork/backtrack VM (61% jq compat — try-catch, alternative, label/break, limit)
**v0.5** — WASM build, Python bindings, auto-detect JSON error output
**v1.0** — Full jq compatibility, plugin system, MCP server integration

---

## License

MIT
