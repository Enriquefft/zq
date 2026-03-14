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
| `query` | Compile jq-compatible filter expressions into bytecode `CompiledQuery`; execute against a `Tape` via lazy `ResultIterator`. Supports arithmetic (+,-,*,/,%), comparisons (==,!=,<,<=,>,>=), boolean operators (and,or,not), unary negation (-expr), alternative operator (`//`), try/catch error recovery, optional operator (`expr?`), array/string slicing, update assignment (`\|=`,`+=`,etc.), and 58 builtins (type selectors, math, string, collection ops). Arithmetic extended: `object*object` recursive merge, `string/string` split, float-aware `%`. | Active | `error`, `types` | 2026-03-14 |
| `output` | Serialize `Value` to fd with 64 KB buffered writes. Supports pretty, compact, raw, and JSONL formats. TTY detection cached at init. | Active | `error`, `types` | 2026-03-09 |
| `pool` | Fixed-size worker pool with mmap chunk-based file mode and stream pipeline mode. Ring-buffer Sequencer (capacity = max(IN_FLIGHT_FACTOR×n_threads, QUEUE_CAP+n_threads); O(1) post/fetch, zero allocs in hot path) replaces HashMap reorder buffer. InFlightLimiter backpressure: feeder thread lazily enqueues chunks, blocking when IN_FLIGHT_FACTOR×n_threads chunks are live. collect() releases slots on arena free. Multi-value collect() cursor. Persistent ResultIterator reset() per record. 1.42s / 1702 MB RSS for 648 MB / 15M-record file. | Active | `error`, `types`, `io`, `parser`, `query` | 2026-03-10 |
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
| 2026-03-10 | `query` | Evolved | Added optional operator `expr?`: lexer `question` token; compiler `parseSuffixes` retroactively wraps segment in `try_begin`/`try_end`; VM `handleCaughtError` sets `ip=instructions.len` instead of `done=true` so outer iterators continue; `copyTapeSpanToRuntimeTape` interns `.key` and `.string` entries into runtime_tape. 8 boundary tests added. |
| 2026-03-10 | `query` | Evolved | Added slicing (`.[a:b]`, `.[a:]`, `.[:b]`): `SliceArgs` extern struct in types.zig; `colon` detection in `parseBracket`; `parseSliceTail` helper; `slice` opcode in VM's `doSlice` — negative indices, clamping, array/string support. 9 boundary tests pass (383/856 total). |
| 2026-03-10 | `query` | Fixed | Fixed nested object/array construction: `runtime_tape` now grows monotonically within a `next()` call (no `clearRetainingCapacity` mid-execution); `copyTapeSpanToRuntimeTape` pre-reserves exact entry+string capacity and refreshes `runtime_tape_view` before each copy, eliminating ArrayList reallocation during self-copy. Fixes L1656 SIGABRT. Total: 374/847 (up from 337/815). |
| 2026-03-09 | `query` | Interface | INTERFACE.md drafted: compile/execute/ResultIterator, Opts.allow_null_propagation, fuse pass. |
| 2026-03-10 | `query` | Evolved | Added update assignment (`\|=`, `+=`, `-=`, `*=`, `/=`, `%=`, `//=`): 7 new lexer tokens; `navigate_key`/`navigate_index` opcodes (path nav without value_stack push); `update_key`/`update_index` opcodes (reconstruct object/array into runtime_tape); `peekIsUpdateAssign` lookahead + `parseUpdateAssign` compiler function; `doUpdateKey`/`doUpdateIndex` VM methods. 6 boundary tests pass. |
| 2026-03-09 | `query` | Created | Implemented lexer, compiler (recursive descent + fuse pass), stack-based VM with lazy ResultIterator. 26 boundary tests pass, zero leaks. |
| 2026-03-09 | `query` | Evolved | Added arithmetic (+, -, *, /, %), comparisons (==, !=, <, <=, >, >=), and boolean operators (and, or, not). Added value stack to VM for expression evaluation. 13 new compat tests passing. |
| 2026-03-09 | `query` | Fixed | Fixed compilation error (skipEntry pointer mismatch). Fixed `load_key` to read from `it.current` (enables chained access like `.[0].id`). Fixed object construction context: `object_construct_start` and `object_key` reset `current` to `input_value` so each field's value expression is evaluated against the same input. All 4 core scenarios pass. |
| 2026-03-09 | `output` | Created | Buffered Writer with pretty/compact/raw/jsonl formats, JSON escaping, tape traversal. 56 tests pass. |
| 2026-03-09 | `pool` | Created | Worker pool with job queue, sequencer, file chunking, stream pipeline (IO thread), ref-counted SharedCtx. 21 tests pass. |
| 2026-03-09 | `c_abi` | Created | Opaque QueryHandle, in-memory compact serializer, 4 exported C functions. 37 tests pass. |
| 2026-03-09 | `query` | Evolved | Added `ResultIterator.reset(tape)`: zero-allocation rebind for JSONL workloads. Mirrors Parser.reset() pattern. 3 new boundary tests. |
| 2026-03-10 | `query` | Evolved | Added unary negation (`-expr`): new `negate` opcode in types.zig preserves int/float types. Fixed float_lit lexer bug (was tagged as .ident). Removed broken `push_int -1; mul` hack. 6 new boundary tests pass. |
| 2026-03-10 | `query` | Evolved | Added conditionals (`if/then/elif/else/end`): 4 new opcodes (jump, jump_if_false, save_input, restore_input) in types.zig; if/then/elif/else/end keywords in lexer; parseIfBody with backpatching in compiler; if_stack + branch dispatch in VM. jq-correct truthiness (only false/null are falsy). 13 new boundary tests pass. |
| 2026-03-10 | `query` | Evolved | Added array construction (`[expr]`): 2 new opcodes (array_collect_start, array_collect_end) in types.zig; parseArrayConstruct with backpatching in compiler; collect_stack + CollectFrame in VM intercepts output in collect mode, buffers values, builds array via runtime_tape. Fixed fuse pass index_map to fill entries for all consumed raw instructions in fusion chains. 7 new boundary tests pass (56 total). |
| 2026-03-10 | `query` | Evolved | Added bracket pipe expressions (`.["key"]`, `.[.foo]`): `string_lit` lexer token; `load_computed` opcode; refactored `parseBracket` (peek-first): `string_lit` → `load_key`, computed else → `save_input; expr; load_computed`; VM `load_computed` pops base from if_stack, key from value_stack/current, applies with span.tape for runtime-tape safety. 6 new boundary tests (62 total); compat 55/533. |
| 2026-03-10 | `query` | Evolved | Added alternative operator (`//`): `double_slash` lexer token; `alt_start`+`alt_check` opcodes in types.zig; `insertRawInstr` helper + `parseAlternative` in compiler (retroactive `alt_start` insertion with jump-target fixup for chained `//`); `alt_null_depth` counter in VM enables implicit null propagation on left side (missing keys → null, matching jq semantics); `nullAllowed()` helper replaces bare `opts_allow_null` reads; `string_lit` and soft `null` literal support added to `parsePrimary`. 12 new boundary tests (74 total); compat 55/533. |
| 2026-03-10 | `query` | Evolved | Added try/catch error recovery (`try expr catch expr`): `try_begin`+`try_end` opcodes in types.zig; `try_kw`+`catch_kw` lexer tokens; `parseTryCatch` compiler function (primary-level body/handler preserving jq term precedence); `TryFrame` struct + `try_stack` in VM; VM loop refactored into `step`+`execOne`+`handleCaughtError` — errors trapped per-instruction, stacks unwound to saved depths, current set to error name string for catch handler. Also fixed div/mod by zero (guard returns TypeError instead of panicking). 12 new boundary tests (86 total); compat 57/533. |
| 2026-03-09 | `pool` | Evolved | Workers now own a persistent `ResultIterator` (init once, reset() per record). Eliminated 6 alloc/free cycles per record. `serialise_span` comma tracking moved to stack. |
| 2026-03-09 | `pool` | Reworked | Complete rewrite: chunk-level Sequencer batching (N_CHUNKS ≤ 64 ops vs 15M), arena-per-chunk memory (freed atomically on chunk exhaustion), multi-value collect() cursor (rec_idx/val_idx). Fixed OwnedValue to copy tape spans instead of JSON-serializing. Build mode ReleaseFast. Result: 2.24s for 15M records (11.6x jq, 7.9x jaq). |
| 2026-03-10 | `pool` | Evolved | Bounded chunk count: feeder thread + InFlightLimiter replaces upfront all-at-once enqueue. Feeder acquires slot before each push; collect() releases on arena deinit. max_in_flight = IN_FLIGHT_FACTOR(2) × n_threads. Result for 648 MB / 15M records: 1764 MB RSS (was 2998 MB, -41%), 1.41s (was 38s, 27× faster — eliminated memory pressure). |
| 2026-03-10 | `pool` | Evolved | Ordered output queue: replaced HashMap reorder buffer in Sequencer with a fixed-size ring buffer (capacity = max(IN_FLIGHT_FACTOR×n_threads, QUEUE_CAP+n_threads)). post() is a direct array write; next_in_order() is a direct array read — zero dynamic allocations in the hot path. Ring-slot invariant (no two live chunks share an index) enforced by InFlightLimiter (file mode) and QUEUE_CAP (stream mode). 1702 MB RSS (was 1764 MB, -3.5%). |

| 2026-03-14 | `query` | Evolved | Added 58 builtins: type selectors (arrays/objects/strings/numbers/booleans/nulls/values/scalars/iterables), math (floor/ceil/round/sqrt/fabs/abs/nan/infinite/isnan/isinfinite/isnormal/pow/log2/log/exp/exp2/trig/significand/exponent/logb), string (ascii_downcase/ascii_upcase/ltrimstr/rtrimstr/startswith/endswith/split/join/explode/implode/tojson/fromjson/toboolean/ascii), misc (utf8bytelength/transpose/builtins/have_decnum/bsearch/isempty/map_values/add(f)). Extended arithmetic: object*object recursive merge, string/string division (split), float-aware modulo. |

## Gaps & TODOs
| Priority | Gap | Suggestion |
|----------|-----|------------|
| High | No CLI entry point (`main.zig`) | Wire all modules into arg-parsing CLI matching jq's flags |
| High | No jq conformance harness | Build test runner that reads jq's `jq.test` format directly |
| Medium | `pool.submit_stream` returns `void` — stream IO errors deferred to `collect()`? | Clarify: are IO-thread errors posted to sequencer or silently dropped? |
| — | `types.Instruction.Operand` is a plain union | Consider tagged union if debug/serialization is needed |
