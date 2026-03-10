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
| `query` | Compile jq-compatible filter expressions into bytecode `CompiledQuery`; execute against a `Tape` via lazy `ResultIterator`. Supports arithmetic (+,-,*,/,%), comparisons (==,!=,<,<=,>,>=), boolean operators (and,or,not), and unary negation (-expr). Fuse pass collapses `.a \| .b` chains into single `load_path` instructions. `CompiledQuery` is immutable and safe for concurrent `execute()` calls. `ResultIterator.reset(tape)` rebinds to a new tape with zero allocations — mirrors `Parser.reset()` for JSONL workloads. | Active | `error`, `types` | 2026-03-10 |
| `output` | Serialize `Value` to fd with 64 KB buffered writes. Supports pretty, compact, raw, and JSONL formats. TTY detection cached at init. | Active | `error`, `types` | 2026-03-09 |
| `pool` | Fixed-size worker pool with mmap chunk-based file mode and stream pipeline mode. Chunk-level Sequencer (N_CHUNKS ops, not 15M) with arena-per-chunk memory model. Multi-value collect() cursor. Persistent ResultIterator reset() per record. 11x faster than jq in ReleaseFast. | Active | `error`, `types`, `io`, `parser`, `query` | 2026-03-09 |
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
| 2026-03-09 | `query` | Fixed | Fixed compilation error (skipEntry pointer mismatch). Fixed `load_key` to read from `it.current` (enables chained access like `.[0].id`). Fixed object construction context: `object_construct_start` and `object_key` reset `current` to `input_value` so each field's value expression is evaluated against the same input. All 4 core scenarios pass. |
| 2026-03-09 | `output` | Created | Buffered Writer with pretty/compact/raw/jsonl formats, JSON escaping, tape traversal. 56 tests pass. |
| 2026-03-09 | `pool` | Created | Worker pool with job queue, sequencer, file chunking, stream pipeline (IO thread), ref-counted SharedCtx. 21 tests pass. |
| 2026-03-09 | `c_abi` | Created | Opaque QueryHandle, in-memory compact serializer, 4 exported C functions. 37 tests pass. |
| 2026-03-09 | `query` | Evolved | Added `ResultIterator.reset(tape)`: zero-allocation rebind for JSONL workloads. Mirrors Parser.reset() pattern. 3 new boundary tests. |
| 2026-03-10 | `query` | Evolved | Added unary negation (`-expr`): new `negate` opcode in types.zig preserves int/float types. Fixed float_lit lexer bug (was tagged as .ident). Removed broken `push_int -1; mul` hack. 6 new boundary tests pass. |
| 2026-03-09 | `pool` | Evolved | Workers now own a persistent `ResultIterator` (init once, reset() per record). Eliminated 6 alloc/free cycles per record. `serialise_span` comma tracking moved to stack. |
| 2026-03-09 | `pool` | Reworked | Complete rewrite: chunk-level Sequencer batching (N_CHUNKS ≤ 64 ops vs 15M), arena-per-chunk memory (freed atomically on chunk exhaustion), multi-value collect() cursor (rec_idx/val_idx). Fixed OwnedValue to copy tape spans instead of JSON-serializing. Build mode ReleaseFast. Result: 2.24s for 15M records (11.6x jq, 7.9x jaq). |

## Gaps & TODOs
| Priority | Gap | Suggestion |
|----------|-----|------------|
| High | No CLI entry point (`main.zig`) | Wire all modules into arg-parsing CLI matching jq's flags |
| High | No jq conformance harness | Build test runner that reads jq's `jq.test` format directly |
| Medium | `pool.submit_stream` returns `void` — stream IO errors deferred to `collect()`? | Clarify: are IO-thread errors posted to sequencer or silently dropped? |
| — | `types.Instruction.Operand` is a plain union | Consider tagged union if debug/serialization is needed |
