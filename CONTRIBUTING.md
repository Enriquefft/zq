# Contributing to zq

## Prerequisites

- **Zig 0.15.2** — [ziglang.org/download](https://ziglang.org/download/)
- **Optional:** Nix + direnv (`direnv allow`) for a reproducible dev environment

## Building

```sh
zig build                          # dev build
zig build -Doptimize=ReleaseFast   # release build
just build                         # shortcut (requires just)
```

## Testing

```sh
zig build test    # run all tests
just test         # shortcut
```

## Code style

```sh
zig fmt src/ tests/
```

CI enforces formatting. Run this before pushing.

## Project structure

```
src/
  error/       # error types and reporting
  types/       # value types (tape-based)
  io/          # input handling (mmap, streaming)
  parser/      # JSON parser (SIMD-accelerated)
  query/       # filter compiler + VM
  output/      # serialization and buffering
  pool/        # parallel worker pool
  c_abi/       # C ABI for embedding
  main.zig     # CLI entry point
```

Each module has an `INTERFACE.md` describing its public API. Start there when exploring a module.

For the overall architecture, see `.claude/context/ARCHITECTURE.md`.

## What to work on

- Check [GitHub Issues](https://github.com/Enriquefft/zq/issues) for open tasks
- See `ROADMAP.md` for the bigger picture and milestone priorities

## Pull request guidelines

1. Fork the repo and create a feature branch
2. Make your changes — one logical change per PR
3. Run `zig fmt src/ tests/` and `zig build test`
4. Open a PR against `main`
5. Describe **why** the change is needed, not just what changed
6. Add tests for new functionality

## Reporting issues

Use [GitHub Issues](https://github.com/Enriquefft/zq/issues). Include:

- zq version (`zq --version`)
- OS and architecture
- The filter you ran
- Input JSON (minimal reproducer)
- Expected vs actual output
