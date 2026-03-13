# zq

> A drop-in replacement for jq — rewritten in Zig to be **25x faster**, with zero dependencies and native support for the streaming, high-throughput workloads that define modern AI pipelines.

---

## What is it?

[jq](https://jqlang.github.io/jq/) is the standard Unix tool for querying and transforming JSON. In the AI era, where every API response, model output, and data pipeline speaks JSON, it has become infrastructure. The problem: jq was built for a different era. It buckles under multi-gigabyte JSONL files, crashes on truncated JSON, and corrupts large integers above 2^53.

zq fixes all of that. Same filter syntax. Just faster — and built for what developers actually need in 2026.

---

## Benchmarks

**File mode — 648 MB / 15M-record JSONL**

| Tool | `.id` | `select(.id > 500000)` | RSS (`.id`) |
|------|-------|------------------------|-------------|
| jq | 21.8s | 42.6s | 3.6 MB |
| jaq | 15.3s | 27.7s | 666 MB |
| **zq** | **0.89s** | **3.1s** | **701 MB** |

**Streaming mode — `cat file \| zq .id`**

| Tool | Time | RSS |
|------|------|-----|
| jq | ~22s | 3.6 MB |
| **zq** | **1.6s** | **8 MB** |

**Startup time:** ~2ms (3x faster than jq)
**Binary size:** 2.7 MB static, stripped, zero dependencies

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

## Status

Early development. Core query engine and parallel runtime are complete.

| Metric | Value |
|--------|-------|
| jq compat tests | 111/539 (21%) — targeting 60% for v0.1 |
| Module tests | 452/880 passing |
| Architecture | `error`, `types`, `io`, `parser`, `query`, `output`, `pool`, `c_abi` |

The filter language already covers the most common real-world operators: field access, pipes, array/object construction, arithmetic, comparisons, conditionals, `try/catch`, `//`, `|=`, slicing, string interpolation, and recursive descent.

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

### Build from source

```sh
git clone https://github.com/Enriquefft/zq
cd zq
zig build -Doptimize=ReleaseFast
./zig-out/bin/zq '.foo' <<< '{"foo": 42}'
```

Requires [Zig 0.15.2](https://ziglang.org/download/).

**Alternative (Nix):** If you have Nix + direnv, just `direnv allow` — all dependencies are pinned.

**Using just:** `just build` (dev) or `just release` (optimized).

---

## Roadmap

**v0.1 — Useful:** 60%+ jq compat, all P0/P1 builtins, full CLI flags  
**v0.5 — Fast:** 95% compat, WASM build, Python bindings  
**v1.0 — Complete:** 100% compat, LSP, plugin system, MCP server integration

---

## License

MIT
