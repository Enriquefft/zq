# Architecture

## Overview

zq parses JSON into a flat tape, compiles jq filters into bytecode, and executes them via a stack-based VM. For JSONL workloads, a fixed-size worker pool splits the input into newline-aligned chunks and processes them in parallel, reordering results before output.

Zig 0.15.0 core. The vendored Rust `regex-automata` shim (`third_party/zq-regex-shim/`) is linked in when `-Dregex=true` (default); `-Dregex=false` builds are dependency-free and regex builtins return `regex_not_compiled`.

## Data Flow

```
Single-threaded (interactive / small input):

  stdin/file → io.Source → parser.feed() → Tape
                                             ↓
                              query.execute() → ResultIterator.next() → Value
                                                                          ↓
                                                          output.Writer.write_value() → stdout


Slurp mode (-s):

  stdin/file → io.Source → parser.feed() (loop) → RuntimeTape (accumulate array)
                                                       ↓
                                        query.execute() once → ResultIterator → stdout

  Raw slurp (-Rs):

  stdin/file → readAllBytes() → single string tape → query.execute() once → stdout


Parallel — file mode:

  file → mmap → split into ~64 newline-aligned byte-range chunks
                  ↓
          pool.submit_file() → JobQueue (MPMC)
                                  ↓
                  ┌───────────────┼───────────────┐
              worker 0        worker 1         worker N
              (own Parser,    (own Parser,     (own Parser,
               own Iterator)   own Iterator)    own Iterator)
                  │               │               │
                  └───────────────┼───────────────┘
                                  ↓
                    Sequencer ring buffer (reorder)
                                  ↓
                         collect_bytes() → main → stdout


Parallel — stream mode:

  stdin → io.Source → IO thread (accumulates 256 KB batches)
                          ↓
                      JobQueue → workers → Sequencer → collect_bytes() → stdout
```

## Modules

```
error    (no deps)          Zig error set, lazy line/col resolution
types    (no deps)          Tape, Value, OutputStyle, Instruction, Op, RuntimeTape, BuiltinId
io       → error            mmap (files) / ring buffer (pipes)
parser   → error, types     Streaming state machine → flat Tape
regex    → error            Vendored Rust regex-automata shim (gated on -Dregex)
lexer    → error            Tokenizer for jq filter strings
ast      → lexer, error,    Error-tolerant recursive-descent AST (LSP + prefilter harvester)
           types
prefilter → regex, ast      Literal set, AST-based harvestFromAstRoot, acceptance check
compiler → ast, types,      AST → IR (lower), fuse pass, IR → bytecode (emit)
           error, regex,
           prefilter
vm       → error, types,    Stack-based bytecode executor; unified fork stack
           regex
query    → error, types,    Compile dispatcher + bytecode VM execution
           lexer, regex, vm,
           ast, prefilter,
           compiler
output   → error, types     Buffered serialization, generic over sink type
describe → types            Schema inference for --describe
pool     → io, parser,      Worker pool, Sequencer, InFlightLimiter, madvise(MADV_DONTNEED)
           query, output
lsp      → ast, query       JSON-RPC server: diagnostics/completion/hover/...
c_abi    → error, types,    C ABI bridge: zq_compile/zq_compile_ext/zq_execute/...
           parser, query
main     → all              CLI arg parsing, routing, --lsp entry
```

Each module's public API, constraints, and invariants: `src/[module]/INTERFACE.md` (gaps: compiler, vm, lexer, prefilter, describe, microbench have no INTERFACE.md yet).

### error

`ZqError` error set for Zig-native `try`/`catch` propagation. `Error`/`Context` structs for display only — built at the outermost boundary, never on the hot path.

Lazy line/column resolution: byte offsets are tracked during parsing. When an error surfaces, a `LineTable` is built (scan for `\n` offsets) and the offset is resolved via binary search. Cost on the happy path: zero.

### types

Shared definitions used across all modules:
- `Tape` — flat array of `Tag + Payload` entries (the parsed JSON representation)
- `Value` — non-owning view into a Tape: tag + payload + span
- `OutputStyle` — output style packed struct (1 byte): three orthogonal axes — `compact`, `raw_strings`, `join`. All eight combinations are valid; pretty is the default (all-zero).
- `Instruction` / `Op` / `Operand` — bytecode format for the query VM
- `StringRef` — offset+length into tape's string buffer
- `RuntimeTape` — growable tape for constructing new JSON values at runtime. Provides `appendEntry()`, `internString()`, `copyFrom()`, `copySpan()`, and `asTape()` (immutable view). Used by the query VM for object/array construction and by main for external variable binding and `$ARGS` assembly.

### io

Unified byte stream. Backend chosen at `init` based on file type:
- **mmap** for regular files — zero-copy, no syscalls after init
- **Ring buffer** for pipes/stdin/sockets — 64 KB, grows at most once

`peek()`/`consume()` are pointer arithmetic only. `refill()` is the sole syscall site.

Cross-platform: `std.fs.File` throughout (not POSIX fd_t). Windows uses `CreateFileMappingW`/`MapViewOfFile` via comptime branching.

### parser

Streaming state machine. `feed()` called repeatedly as chunks arrive, maintaining state across calls. Returns `FeedResult.done` (complete value) or `.need_more` (valid prefix, call again).

Produces a `Tape`: flat array of entries, no pointers, no hash maps. Container open tags store their entry count — O(1) skip.

SIMD scan (AVX2 on x86-64, NEON on AArch64) classifies structural characters 64 bytes at a time. Hidden behind platform-independent interface.

Auto-close: truncated containers at EOF are synthetically closed (`{"a":1` → `{"a":1}`). Unterminated strings always error — can't know the intended endpoint.

Depth limit: 512. Not thread-safe — each worker owns its own instance.

### query

Five stages (Phase 2R pipeline):

1. **Parse** — `ast.parse(src)` produces an error-tolerant AST (`src/ast/`).
2. **Lower** — AST → IR via `src/compiler/lower.zig`. Scope and variable resolution happen here.
3. **Fuse** — IR rewrite pass collapses `.a | .b | .c` into `load_path` (`src/compiler/fuse.zig`).
4. **Emit** — IR → bytecode (`Compiled`) via `src/compiler/emit.zig`.
5. **VM** — `src/vm/root.zig` executes bytecode; stack-based, unified fork stack for backtracking (subsumes former try/collect/if stacks).

`CompiledQuery` is immutable after compile — thread-safe for concurrent `execute()` calls. Each `execute()` produces an independent `ResultIterator`.

`ResultIterator.reset(tape)` rebinds to a new tape with zero allocations. Mirrors `Parser.reset()`.

**External variables**: Two-phase binding system. At compile time, `ExternalVarDecl` names are pre-declared in the root scope so `$NAME` references resolve during compilation. `CompiledQuery.external_var_ids` maps declaration order to compiler-assigned variable IDs. At execution time, `ExternalVarBinding` pairs each variable ID with a concrete `StackValue` (null, bool, int, float, or tape_value for strings/arrays/objects). Bindings are injected into the VM's `variable_store` at `execute()` and refreshed on each `reset()`.

Implemented operators: field access, pipes, iteration, arithmetic, comparisons, boolean logic, conditionals, variables, user-defined functions, string interpolation, recursive descent, alternative (`//`), try/catch, optional (`?`), slicing, update assignment (`|=`, `+=`, etc.), comma (generators), array/object construction, bracket expressions.

Builtins: see `src/types.zig:BuiltinId` — the canonical enum (~160 variants). Classes: core (length/keys/values/type/has/in/empty/select/map/add/not/error), path algebra (getpath/setpath/delpaths/paths/leaf_paths/del), math (floor/ceil/sqrt/pow/log/…, ~40 entries), type-check (arrays/objects/strings/numbers/…), string/ASCII (ascii_downcase/upcase/explode/implode/split/join/…), JSON (tojson/fromjson/tonumber/tostring), regex (test/match/match_g/capture/scan/sub/gsub/splits), date/time (now/gmtime/mktime/strftime/strptime/strflocaltime/todate/fromdate/todateiso8601/fromdateiso8601), I/O (input/inputs/debug/stderr/halt/halt_error/env/builtins), and `@format` encoders (base64/uri/html/csv/tsv/json/sh/text).

`runtime_tape` handles object/array construction — grows monotonically within a `next()` call, cleared only at `reset()`. Self-copy safety: pre-reserves exact capacity and refreshes view before copy loop.

### output

64 KB buffered writes to file descriptors. Output style is three orthogonal axes (`OutputStyle` packed struct): `compact` (single-line bodies, no whitespace), `raw_strings` (emit string values without quotes — `-r`), and `join` (suppress per-value newline — `-j`, also implies `-r`). Default (all-zero) = pretty (2-space indent). The serializer reads `compact` and `raw_strings`; the dispatch loop reads `join` to decide whether to emit `\n` between values.

Serialization is generic via Zig's `anytype` — parameterized on `writeByte`/`writeSlice` methods. Same code powers `Writer` (fd-backed, used by main thread) and `BufferSink` (ArrayList-backed, used by pool workers).

`SerializeOpts` controls formatting: `sort_keys` (sort object keys before output, dual-path — stack buffer for ≤256 keys, heap fallback for larger), `indent` (spaces with configurable width 0–8, or tab character). Threaded through all serialization paths including pool workers.

ANSI color output when stdout is a TTY. `-C` forces color, `-M` disables, `NO_COLOR` env var respected. Color state shared via `*const Color` pointer across main thread and workers.

### regex

Thin Zig wrapper around the vendored Rust `regex-automata` crate at `third_party/zq-regex-shim/`. Linked as a static archive (`libzq_regex_shim.a`) into every artifact that needs regex when `-Dregex=true` (default). `-Dregex=false` swaps in stubs — regex builtins then return `RegexNotCompiled` and no Rust is invoked.

Capabilities: compile, match, named captures, replace with `\1..\9` and `\g<name>` backrefs, required-literal extraction (used by the query prefilter). Linear time in input × pattern size; no catastrophic backtracking.

Flag surface matches jq/Onig where feasible: `i` (case-insensitive), `x` (extended), `s` (dotall), `m` (multi-line), `g` (generator mode for `match`), `p` (pattern-level no-op). The `n` flag is **rejected at compile time** with `RegexCompileError` — jq's `n` semantics require per-builtin zero-width handling that would diverge silently from correct jq behavior.

Compat delta vs jq/Onig: no backreferences in patterns, no lookaround, no `\g<name>` subroutine calls in the pattern, no replacement-as-filter evaluation. Documented as a permanent delta.

### ast

Error-tolerant recursive-descent parser (`src/ast/`). One AST, two consumers:

1. **LSP** — drives diagnostics, hover, completion, definition, references, rename, signature help, semantic tokens, formatting. The AST survives partial input so the editor gets useful suggestions mid-keystroke.
2. **Query compiler's literal-prefilter harvester** — two paths: legacy AST-walk in `src/prefilter/root.zig` (`harvestFromAstRoot`) and Phase-2R IR-walk in `src/compiler/harvest.zig` (walks IR after lower+fuse, avoids re-parsing). Both find `select(X | test("literal"))` idioms, decode `\uXXXX` escapes, and hand the byte sequence(s) to the pool for pre-parse raw-byte scanning.

Single source of truth: both surfaces consume the same parser. A fix to AST handling improves LSP diagnostics and prefilter accuracy simultaneously.

### describe

Schema inference for `--describe`. Walks parsed values, unifies types across records, emits a JSON schema object: `{"type": ..., "fields": ..., "elements": ..., "count": N}`. `--depth N` bounds recursion (default 12, 0 = unlimited). Fields seen in some records but not others are marked `"optional": true`.

### lsp

JSON-RPC server over stdin/stdout, launched by `--lsp`. Capabilities advertised on `initialize`:

- `textDocument/publishDiagnostics` — compile errors surfaced inline; memoized on source hash so identical edits don't recompile.
- `textDocument/completion` — triggered on `.`, `$`, `@`, `|`.
- `textDocument/hover` — builtin docs and inferred types.
- `textDocument/definition` / `references` / `rename` — works on user-defined functions and bound variables.
- `textDocument/signatureHelp` — triggered on `(` and `;`.
- `textDocument/semanticTokens/full` — keyword/function/variable/string/number/operator/property/type classes with `declaration`/`builtin` modifiers.
- `textDocument/formatting` — `zq fmt` over the LSP surface.

Document store keeps source per URI. Features receive `(source, offset, ast_root, semantic_model, alloc)`. No network I/O, no threads — a single request loop over `File.reader()`.

### pool

Fixed-size worker pool. Orchestrates io → parser → query → output in parallel.

**File mode**: mmap the file, scan for newline boundaries to split into ~64 byte-range chunks. Workers steal chunks from an MPMC `JobQueue`.

**Stream mode**: dedicated IO thread reads from `Source`, accumulates complete lines into 256 KB batches (`STREAM_BATCH_SIZE`), posts as Jobs. Flush on pipe stall (peek returns 0 bytes, not EOF) preserves interactive latency.

**Execution paths**:
- Structured (`style=null`): workers copy values into arena-backed `OwnedValue`. Caller uses `collect()`.
- Serialized (`style!=null`): workers serialize directly into arena byte buffers while tape is live, bypassing `OwnedValue`. Caller uses `collect_bytes()`.

**Sequencer**: fixed-size ring buffer. `post()` is a direct array write at `chunk_id % capacity`. `next_in_order()` is a direct array read. Zero dynamic allocations in hot path.

**Stream-mode partial publish** (infinite-generator unblock): each stream-mode Job reserves `STREAM_SEQ_RANGE = 8` consecutive sub-ids `[seq_base .. seq_base + N)`. When `process_line_serialized` accumulates more than `STREAM_FLUSH_THRESHOLD = 64 KiB` of output for a single record at a value-boundary, the worker calls `partial_flush`: posts the current arena/buf/meta to the Sequencer with `end_of_range = false`, allocates a fresh arena, and continues the iterator drain into the next sub-id. The Job's final post sets `end_of_range = true` so the Sequencer skips any unused trailing sub-ids in the reservation (preserving the dense `next_chunk_id` advance invariant). File-mode Jobs use `seq_range_size = 1` and a single post — behavior unchanged. This unblocks downstream consumers for `repeat(.+1) | head -100` and similar infinite-generator pipelines that previously emitted zero bytes.

**InFlightLimiter**: feeder thread acquires a slot before enqueuing each chunk, blocks when `IN_FLIGHT_FACTOR × n_threads` chunks are live. `collect()` releases slots on arena free. Stream-mode workers acquire one extra slot per partial flush so peak in-flight memory stays bounded across sub-id partials. Caps peak RSS to a bounded function of thread count, not file size.

**Raw input mode**: when `raw_input=true`, workers skip JSON parsing and construct a synthetic tape from each raw line via `make_raw_tape()` — zero-copy, zero-allocation. Each line becomes a string value in the tape.

**External bindings**: `submit_file()` and `submit_stream()` accept `external_bindings` and `SerializeOpts`, threaded to all workers. Workers pass bindings to `ResultIterator.reset()` on each record.

**Memory model**: arena-per-chunk, freed atomically when chunk is fully consumed. Workers own persistent `Parser` + `ResultIterator` — init once, `reset()` per record. 2 MiB thread stacks (reduced from 16 MiB default). After a file-mode chunk's output is serialized into the arena buffer, the worker calls `madvise(MADV_DONTNEED)` on the mmap pages it consumed; the kernel drops them from RSS immediately. Linux-only; gated on `builtin.os.tag == .linux`. This alone dropped `.id` RSS from 1.29x to 0.31x input size on a 1.3 GB file.

`n_threads = 0` is valid — calling thread executes all work inline.

### c_abi

Six exported C functions: `zq_compile`, `zq_compile_ext`, `zq_execute`, `zq_get_result`, `zq_get_error`, `zq_free`.

- `zq_compile_ext` adds a `[*:0]const u8` out-param that receives a descriptive error message on compile failure.
- `zq_get_error` returns a null-terminated JSON error object (`{"error_code": ..., "kind": "...", ...}`) for the most recent failure on the handle.

Opaque `QueryHandle` owns everything: `CompiledQuery`, `Parser`, null-terminated result buffer, last-error buffer. Error codes: `0` ok, `-1` ERR_PARSE, `-2` ERR_TYPE, `-3` ERR_OOM, `-4` ERR_INDEX, `-5` ERR_USER.

Handles allocate via `std.heap.page_allocator` (not `c_allocator`) — avoids pulling in libc malloc when the host binary doesn't already link it.

Not thread-safe per handle. Each concurrent caller needs its own handle.

### main

CLI entry point. Parses jq-compatible flags into `Config` struct. Routes to:
- Null input mode (`-n`) — execute filter once on `null`, no input read
- Slurp mode (`-s`) — single-threaded collection of all inputs into an array, then one filter execution. Two sub-paths: JSON slurp (parse each value, accumulate via `RuntimeTape`) and raw slurp (`-Rs`, concatenate all bytes into a single string)
- Pool file path — parallel `submit_file()` when input is a regular file
- Pool stream path — parallel `submit_stream()` when input is stdin
- Single-threaded fallback

**External variable binding**: after compilation, main constructs bindings for `--arg`/`--argjson` values. Scalars (null, bool, int, float) bind directly. Compound types (string, array, object) are copied into a persistent `RuntimeTape` that outlives all query executions. The `$ARGS` variable is assembled as `{"positional": [...], "named": {...}}` in the same `RuntimeTape`.

Flags: `-r` (raw), `-c` (compact), `-e` (exit status), `-n` (null input), `-s` (slurp), `-R` (raw input), `-S` (sort keys), `-j` (join output), `-f` (filter from file), `-C`/`-M` (color), `--tab`, `--indent N`, `--arg NAME VALUE`, `--argjson NAME VALUE`, `--args`, `--jsonargs`, `--json-errors`, `--lsp`, `--validate`, `--describe`, `--depth N`.

## Design Decisions

### Tape over tree

Parse JSON into a flat array of `Tag + Payload` entries instead of a tree of heap-allocated nodes.

Trees require one allocation per node, pointer chasing on every traversal, and O(n) skip to walk past a container. A flat tape gives O(1) skip (container open tag stores entry count), sequential memory access (cache-friendly), and zero per-node allocations.

Tradeoff: mutation requires rebuilding. Handled by `runtime_tape` in the query VM — object/array construction writes new entries into a separate growable tape.

### Chunk-level parallelism, not record-level

Split files into ~64 byte-range chunks, not one job per JSON record.

Record-level parallelism on a 15M-line file means 15M sequencer operations, 15M arena alloc/free cycles, and 15M job queue interactions. Chunk-level batching reduces all of this to ~64 — same order of magnitude regardless of record count. Each chunk contains thousands of records processed sequentially within a single worker, amortizing orchestration overhead.

Initial implementation enqueued one job per line (2.16M jobs, 38s). Rewrite to chunk-level: 2.24s. Further optimization with InFlightLimiter: 1.41s.

### Literal prefilter (Sparser-style)

When a filter matches the shape `select(<pure-accessor> | <regex-builtin>("literal"))`, the compiler extracts the must-contain literal(s) via `regex-syntax`'s required-literal API and attaches them to the compiled query. Pool workers then scan the raw chunk bytes for each literal before parsing JSON. Records that cannot contain any match are discarded without ever being handed to the parser.

The prefilter MUST NEVER produce false negatives. Two guarantees make this safe:

1. `regex-syntax`'s literal set is either exhaustive (every listed literal must appear for a match) or a covering set of alternatives (at least one must appear). Both are sound rejection bases.
2. JSON string escapes can hide a literal's bytes (`"A"` contains `A`, not `\x41`). Fallback: if a record contains any `\` byte, we do not prefilter it — we let the full parse + regex run decide.

The net effect on low-selectivity queries like `select(.message | test("CRITICAL"))` is that the slow paths (JSON parse, regex engine) only run on candidate records. End-to-end `test()` speedups reach ~47x vs jq on workloads where most records lack the literal.

Implementation: `src/prefilter/root.zig` (literal set data structure, AST-based `harvestFromAstRoot`, acceptance check); `src/compiler/harvest.zig` (IR-based harvest for Phase-2R compile path). Pool integration: `src/pool/root.zig` (`prefilter_stats` counters and the per-chunk acceptance loop).

### Arena-per-chunk with atomic deallocation

Each chunk gets its own arena allocator, freed atomically when `collect()` / `collect_bytes()` advances past it.

Per-record alloc/free creates millions of GPA round-trips. Arena allocation is O(1) bump-pointer with no per-object bookkeeping. The arena outlives all records in its chunk, so no dangling references within a chunk's lifetime.

### Serialized execution path

When the output style is known at submit time, workers serialize values directly into byte buffers while the tape is still live, bypassing `OwnedValue` entirely.

For scalar queries (`.id`, `select()`), `OwnedValue` copies ~150 bytes/record (tape entries + string data). Serialized output is ~3 bytes/record (`"42\n"`). On 15M records: ~700 MB vs ~50 MB of arena memory.

Result: RSS for `.id` query dropped from ~2.6x to ~1.1x input size (serialized path alone). Contiguous byte buffer + compact `RecordMeta` array (8 B/record vs ~32 B per `RecordOutcome`) further reduced allocation count. A subsequent `madvise(MADV_DONTNEED)` pass on consumed mmap pages (see **pool**) took RSS to **0.31x input size** — now less than the file itself.

Implementation detail: `meta_list` is pre-allocated before `chunk_buf` so the chunk buffer (always the arena's last allocation) can resize in-place when output exceeds input size (e.g. pretty style). Uses `.items` directly instead of `toOwnedSlice` — arena owns the memory.

### InFlightLimiter backpressure

Feeder thread acquires a slot before enqueuing each chunk, blocks when `IN_FLIGHT_FACTOR × n_threads` chunks are live.

Without backpressure, all chunks are allocated simultaneously. For a 648 MB file: 64 arenas alive at once, RSS ~3 GB. With backpressure (factor=2, 16 threads): at most 32 chunks live, RSS bounded regardless of file size.

Result: 2998 MB → 1764 MB (-41%). Speed also improved from 38s → 1.41s — memory pressure was causing thrashing.

### Ring buffer sequencer

Fixed-size ring buffer replaces HashMap-based reorder buffer.

HashMap has allocation overhead per insert and hash collision overhead. Ring buffer is direct array index (`chunk_id % capacity`), O(1) guaranteed, zero dynamic allocations in hot path. Capacity = `max(IN_FLIGHT_FACTOR × n_threads, QUEUE_CAP + n_threads)`. The ring-slot invariant (no two live chunks share an index) is naturally enforced by InFlightLimiter (file mode) and QUEUE_CAP (stream mode).

### Stream batching

IO thread accumulates complete lines into 256 KB batches before creating a Job, rather than one Job per line.

Per-line jobs caused 2.16M sequencer operations for a 648 MB file. Batching reduces this to ~2,540 — same order of magnitude as file mode. Flush on pipe stall preserves interactive latency for small/slow inputs.

Result: streaming stdin 215s → 1.8s (120x faster), 7 MB RSS.

### Auto-close for truncated JSON

When `is_eof=true` and the parser's structural stack is non-empty, synthetically close all open containers and return `.done` instead of error.

LLM streaming produces truncated JSON mid-response (`{"tool": "search", "args": {`). jq crashes. zq auto-closes to `{"tool": "search", "args": {}}` and keeps going.

Unterminated strings are the exception — the parser cannot know where the string was supposed to end. Always returns `error.UnterminatedString`.

### Lazy error resolution

Track byte offsets during SIMD tokenization. Compute line/column numbers only on the error path.

Counting `\n` during tokenization costs ~1-2% CPU on every record. Errors are rare — one per millions of records in production. A `LineTable` (array of `\n` offsets, binary search) is built only when an error needs to be surfaced. Cost on the happy path: zero.

### Fuse pass

Post-compilation pass collapses `.a | .b | .c` chains into single `load_path` instructions.

Without fusion: 3 opcode dispatches with value stack push/pop between each. Fused: single opcode walks the tape directly. This is the most common filter pattern in real-world jq usage. The fuse pass also updates the instruction index map so that jump targets remain valid after collapsing.

### i64 integers, not f64

Store integers as i64 in the tape. Exact to 2^63 - 1.

jq uses f64 for all numbers, silently corrupting integers above 2^53. API responses with snowflake IDs, database primary keys, or blockchain values get mangled. i64 preserves exact values. Arithmetic overflow returns an error instead of silently wrapping.

Deliberate deviation from jq.

### IEEE 754 division semantics

`0/0 = nan`, `n/0 = infinite` (n>0), `n/0 = -infinite` (n<0).

jq's division-by-zero behavior is inconsistent across versions and platforms. IEEE 754 is well-defined and portable.

Deliberate deviation from jq.

### Non-owning views everywhere

All cross-module data references — `SliceView`, `snippet`, `Tape`, `Value` — are non-owning views into caller-managed memory.

Eliminates copy overhead and ownership ambiguity. Every module follows the same contract: view is valid until backing memory is freed/recycled. Documented consistently across all INTERFACE.md files.

### Per-worker persistent state

Each worker thread inits a `Parser` and `ResultIterator` once, then calls `reset()` per record.

`Parser.init()` involves 3+ allocations (tape buffer, string buffer, structural stack). `ResultIterator` via `execute()` involves 6 allocations (eval stack, value stack, etc.). On 15M records, resetting instead of init/deinit avoids ~135M alloc/free cycles.

### Cross-platform via std.fs.File

Replaced `std.posix.fd_t` with `std.fs.File` throughout io, output, pool, and main modules.

Enables Windows compilation without POSIX shims. Platform-specific APIs (mmap vs CreateFileMappingW, posix.getenv vs process.getenvW) selected via comptime branching — no runtime dispatch.

### Generic serialization via anytype

Output serialization functions take `anytype` requiring `writeByte`/`writeSlice` methods.

Same serialization code powers both `Writer` (fd-backed, 64 KB buffered, used by main thread) and `BufferSink` (ArrayList-backed, used by pool workers for serialized path). No code duplication, no vtable overhead — monomorphized at comptime.

### 2 MiB thread stacks

Reduced worker thread stack size from 16 MiB default to 2 MiB.

Workers use heap-allocated buffers for parse/query work. 2 MiB gives 4x margin over measured worst-case stack recursion. On 16 threads: 224 MB saved.

### Slurp bypasses pool

Slurp mode (`-s`) collects all inputs into a single array, then executes the filter once. This is inherently single-threaded — the array must be fully assembled before the query runs. Bypassing the pool avoids unnecessary worker/sequencer overhead and simplifies the implementation. JSON slurp accumulates parsed values into a `RuntimeTape`; raw slurp (`-Rs`) reads all bytes into a buffer and wraps them as a single string tape entry.

### Single source of truth for version

Version defined in `build.zig` with `-Dversion` override for release CI. Install scripts, Homebrew formula, AUR PKGBUILD, and release workflow all derive from this.

## Deliberate Deviations from jq

| Behavior | jq | zq | Rationale |
|----------|----|----|-----------|
| Large integers | f64, loses precision above 2^53 | i64, exact to 2^63 | Data integrity |
| Division by zero | Inconsistent | IEEE 754 (nan/infinite) | Consistency |
| Truncated JSON | Crashes | Auto-close containers | LLM streaming |
| Regex `n` flag | Silently accepted (no-op) | Rejected at compile time with `RegexCompileError` | Refuse to silently produce jq-incompatible output |
| Regex engine | Oniguruma (PCRE-style) | `regex-automata` (linear time, no backrefs/lookaround) | No ReDoS; safe on untrusted input |

## Performance Snapshot

1.3 GB / 15M-record JSONL, ReleaseFast, x86_64, regex enabled, vs jq 1.8.1:

```
File mode (.id):         0.83s ± 0.04,  440 MB RSS   (24.6x vs jq, 0.31x input)
File mode (select>500k): 1.52s,         845 MB RSS   (0.64x input)
File mode (complex):     1.96s
Stream mode (.id):       1.76s,           7 MB RSS   (11.6x vs jq)
Regex end-to-end:                                    up to 47x vs jq test()
Startup:                 1.5 ms
Binary (regex on):       2.78 MB stripped (libc + Rust shim, dynamically linked)
Binary (-Dregex=false):  1.29 MB stripped (dependency-free)
```

Memory optimization progression (historical — earlier rows measured on 648 MB file, pre-SIMD; the madvise row is on the current 1277 MB / 15M workload):
```
Initial (all chunks live):        2998 MB
+ InFlightLimiter:                1764 MB  (-41%)
+ Ring buffer sequencer:          1702 MB  (-3.5%)
+ Serialized path:                1124 MB  (-34%)
+ 2 MiB stacks + contiguous:      792 MB  (-29%)
+ Arena interleaving fix:          715 MB  (-10%)
+ madvise(MADV_DONTNEED):          396 MB  (-45%, 1277 MB file, .id → 0.31x input)
                          Total:          -87%
```

## Considered and rejected

- Predicate pushdown evaluated and rejected (2026-05-09): see `research/09-pushdown-doesnt-transfer.md` on the `research` branch.
