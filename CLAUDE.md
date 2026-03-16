# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

zq — A high-performance jq replacement in Zig. Targets 10x-20x speedup over jq via parallelization, SIMD, and zero-allocation parsing, with first-class JSONL and streaming support.

## Build & Test Commands

```bash
zig build                          # Dev build (unoptimized)
zig build -Doptimize=ReleaseFast   # Release build (2.7 MB stripped binary)
zig build test                     # Run all 9 test suites (module + compat)
zig fmt src/ tests/                # Format code (CI enforced)
```

There is no way to run a single test file independently — `zig build test` compiles and runs all test targets defined in `build.zig`.

## Architecture

**Tech stack:** Zig 0.15.2, no external dependencies.

**Module system:** Each module lives in `src/<module>/` with:
- `root.zig` — public interface (re-exports from `src/`)
- `INTERFACE.md` — API docs, types, constraints, invariants
- `src/*.zig` — implementation

Read `src/<module>/INTERFACE.md` before modifying any module.

**Dependency graph:**
```text
error  (no deps)          types  (no deps)
  ↓                         ↓
io → error              parser → error, types
                        query  → error, types, parser
                        output → error, types
pool   → error, types, io, parser, query, output
c_abi  → error, types, parser, query
main   → all modules
```

**Data flow:** `io` (byte stream) → `parser` (streaming `feed()` → `Tape`) → `query` (compile filter → `ResultIterator`) → `output` (serialize `Value` → fd). `pool` orchestrates this across worker threads with chunk-level parallelism.

**Key types** (defined in `src/types.zig`):
- `Tape` — flat structural index of JSON (array of Tag+Payload entries)
- `Value` — result type wrapping null/bool/int/float/string/tape-span
- `Instruction` — query bytecode opcode
- `RuntimeTape` — mutable tape for constructed values during query execution

**LLM context files:**
- `.claude/context/ARCHITECTURE.md` — tech stack and module organization
- `.claude/context/MANIFEST.md` — auto-maintained module inventory with status, deps, and recent changes

**Tests:** `tests/*_test.zig` (one per module) + `tests/compat/*.zig` (jq compatibility suite, 21 files by feature area).

## Key Design Patterns

- **Non-owning views everywhere.** `Tape`, `Value`, slices are borrowed — caller owns source lifetime. `Parser.reset()` invalidates previously returned Tapes.
- **Zero-allocation hot path.** Buffers are pre-allocated; `ResultIterator.reset(tape)` rebinds without allocating; arena allocators in pool freed atomically per chunk.
- **Lazy generator pattern.** `ResultIterator.next()` yields one value at a time (supports multi-value outputs like `.[]`).
- **Thread safety.** `CompiledQuery` is immutable and safe for concurrent use. `Parser`, `ResultIterator`, `Writer` are NOT thread-safe — pool allocates one per worker.

## Code Standards

- Avoid workarounds or bandaids. Only production-ready, scalable code with proper practices.
- Always pick the correct way to do things.

