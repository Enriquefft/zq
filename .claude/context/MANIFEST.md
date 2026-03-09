# Project Manifest

> Auto-maintained by /status. Do not edit manually.

## Overview
| Metric | Value |
|--------|-------|
| Total Modules | 4 |
| Active | 2 |
| Interface-only | 2 |

## Module Inventory
| Module | Purpose | Status | Dependencies | Last Updated |
|--------|---------|--------|--------------|--------------|
| `error` | Centralized error creation with rich diagnostic context. `ZqError` error set for Zig-native propagation; `Error`/`Context` structs for display only. Lazy line/col resolution via binary-search LineTable — never computed on the hot path. | Active | stdlib only | 2026-03-09 |
| `io` | Unified byte stream over file/stdin/socket. mmap for regular files (zero-copy), ring buffer for pipes/sockets (64 KiB, grows once). `peek`/`consume` are syscall-free; `refill` is the only syscall site. | Active | `error` | 2026-03-09 |
| `parser` | Convert raw byte chunks from `io` into a flat `Tape` (structural index). Streaming state machine: `feed()` called repeatedly per chunk. Auto-closes truncated containers for LLM-stream recovery. SIMD scan (AVX2/NEON) hidden behind platform-independent interface. | Interface only | `error`, `types` | 2026-03-09 |
| `query` | Compile jq-compatible filter expressions into bytecode `CompiledQuery`; execute against a `Tape` via lazy `ResultIterator`. Fuse pass collapses `.a \| .b` chains into single `load_path` instructions. `CompiledQuery` is immutable and safe for concurrent `execute()` calls. | Interface only | `error`, `types` | 2026-03-09 |

## Dependency Graph
```
error (no deps)
types (no deps)
io     → error
parser → error, types
query  → error, types
```

## Recent Changes
| Date | Module | Action | Details |
|------|--------|--------|---------|
| 2026-03-09 | `error` | Created | Scaffolded module with LineTable, resolve, raise. 14 boundary tests pass. |
| 2026-03-09 | `error` | Evolved | Added ZqError error set + kindFromZqError for Zig-native propagation. Clarified snippet/SliceView non-ownership semantics. 17 tests pass. |
| 2026-03-09 | `io` | Created | Scaffolded mmap + ring buffer backends behind unified Source interface. 6 boundary tests pass. |
| 2026-03-09 | `error` | Evolved | Added IoError to ZqError/ErrorKind/kindFromZqError for OS-level failures. |
| 2026-03-09 | `io` | Evolved | refill() changed to ZqError!bool; IoError propagated from ring read/realloc and init fstat/mmap failures. |
| 2026-03-09 | `error` | Evolved | Added QuerySyntaxError, TypeError, IndexOutOfBounds to ZqError/ErrorKind/kindFromZqError. |
| 2026-03-09 | `parser` | Interface | INTERFACE.md drafted: streaming feed(), FeedResult, auto-close, SIMD detail. |
| 2026-03-09 | `query` | Interface | INTERFACE.md drafted: compile/execute/ResultIterator, Opts.allow_null_propagation, fuse pass. |

## Gaps & TODOs
| Priority | Gap | Suggestion |
|----------|-----|------------|
| High | `parser` has no implementation | Implement src/parser/root.zig + boundary tests next |
| High | `query` has no implementation | Implement after parser is complete and tested |
| — | `types.Instruction.Operand` is a plain union | Consider tagged union if debug/serialization is needed |
