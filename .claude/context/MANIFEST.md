# Project Manifest

> Auto-maintained by /status. Do not edit manually.

## Overview
| Metric | Value |
|--------|-------|
| Total Modules | 7 |
| Active | 7 |

## Module Inventory
| Module | Purpose | Status | Dependencies | Last Updated |
|--------|---------|--------|--------------|--------------|
| `error` | Centralized error creation with rich diagnostic context. `ZqError` error set for Zig-native propagation; `Error`/`Context` structs for display only. Lazy line/col resolution via binary-search LineTable — never computed on the hot path. | Active | stdlib only | 2026-03-09 |
| `io` | Unified byte stream over file/stdin/socket. mmap for regular files (zero-copy), ring buffer for pipes/sockets (64 KiB, grows once). `peek`/`consume` are syscall-free; `refill` is the only syscall site. | Active | `error` | 2026-03-09 |
| `parser` | Convert raw byte chunks from `io` into a flat `Tape` (structural index). Streaming state machine: `feed()` called repeatedly per chunk. Auto-closes truncated containers for LLM-stream recovery. SIMD scan (AVX2/NEON) hidden behind platform-independent interface. | Active | `error`, `types` | 2026-03-09 |
| `query` | Compile jq-compatible filter expressions into bytecode `CompiledQuery`; execute against a `Tape` via lazy `ResultIterator`. Supports arithmetic (+,-,*,/,%), comparisons (==,!=,<,<=,>,>=), and boolean operators (and,or,not). Fuse pass collapses `.a \| .b` chains into single `load_path` instructions. `CompiledQuery` is immutable and safe for concurrent `execute()` calls. | Active | `error`, `types` | 2026-03-09 |
| `output` | Serialize `Value` to fd with 64 KB buffered writes. Supports pretty, compact, raw, and JSONL formats. TTY detection cached at init. | Active | `error`, `types` | 2026-03-09 |
| `pool` | Fixed-size worker pool with file chunking (work stealing) and stream pipeline modes. Sequencer guarantees in-order result delivery via `collect()`. Each worker owns its own Parser; CompiledQuery is shared read-only. | Active | `error`, `types`, `io`, `parser`, `query` | 2026-03-09 |
| `c_abi` | C ABI bridge: `zq_compile/zq_execute/zq_get_result/zq_free`. Opaque `QueryHandle` owns CompiledQuery + Parser + result buffer. Error codes: 0=ok, -1=parse, -2=query, -3=OOM. | Active | `error`, `types`, `parser`, `query` | 2026-03-09 |

## Dependency Graph
```
error  (no deps)
types  (no deps)
io     → error
parser → error, types
query  → error, types
output → error, types
pool   → error, types, io, parser, query
c_abi  → error, types, parser, query
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
| 2026-03-09 | `parser` | Created | Implemented streaming state machine: root.zig + src/parser.zig. 58 boundary tests pass. |
| 2026-03-09 | `query` | Interface | INTERFACE.md drafted: compile/execute/ResultIterator, Opts.allow_null_propagation, fuse pass. |
| 2026-03-09 | `query` | Created | Implemented lexer, compiler (recursive descent + fuse pass), stack-based VM with lazy ResultIterator. 26 boundary tests pass, zero leaks. |
| 2026-03-09 | `query` | Evolved | Added arithmetic (+, -, *, /, %), comparisons (==, !=, <, <=, >, >=), and boolean operators (and, or, not). Added value stack to VM for expression evaluation. 13 new compat tests passing. |
| 2026-03-09 | `output` | Created | Buffered Writer with pretty/compact/raw/jsonl formats, JSON escaping, tape traversal. 56 tests pass. |
| 2026-03-09 | `pool` | Created | Worker pool with job queue, sequencer, file chunking, stream pipeline (IO thread), ref-counted SharedCtx. 21 tests pass. |
| 2026-03-09 | `c_abi` | Created | Opaque QueryHandle, in-memory compact serializer, 4 exported C functions. 37 tests pass. |

## Gaps & TODOs
| Priority | Gap | Suggestion |
|----------|-----|------------|
| High | No CLI entry point (`main.zig`) | Wire all modules into arg-parsing CLI matching jq's flags |
| High | No jq conformance harness | Build test runner that reads jq's `jq.test` format directly |
| Medium | `pool.submit_stream` returns `void` — stream IO errors deferred to `collect()`? | Clarify: are IO-thread errors posted to sequencer or silently dropped? |
| — | `types.Instruction.Operand` is a plain union | Consider tagged union if debug/serialization is needed |
