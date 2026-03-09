# ZQ Architecture Specification

**Design Philosophy:** Deep Modules (Ousterhout).
**Goal:** 10x-20x performance improvement over `jq` via parallelization, SIMD, and zero-allocation parsing, with first-class support for JSONL and streaming/incomplete data.

---

## Module 1: IO (The Gateway)
**Responsibility:** Abstract data source (File, Stdin, Network) and present a unified byte stream view. Handle the messy reality of OS buffers so the parser never waits.

### Interface
```zig
pub const Source = struct {
    // Returns a slice of available bytes.
    // If .is_eof is true, this is the final chunk.
    // Does NOT copy memory; returns a view into the internal ring buffer.
    pub fn peek(s: *Source) Error!SliceView;

    // Advances the read cursor by 'len' bytes.
    // Called by Parser after consuming data.
    pub fn consume(s: *Source, len: usize) void;

    // Refills the internal buffer.
    // Returns true if more data was read, false if EOF.
    pub fn refill(s: *Source) bool;
};
```

### Deep Implementation Details (Hidden)
1.  **Hybrid Backend:** Automatically detects if input is a regular file (uses `mmap` for zero-copy) or a pipe/socket (uses a reusable `RingBuffer`).
2.  **Ring Buffer Strategy:** For streaming inputs (LLM output), the IO module maintains a sliding window. If the Parser consumes data, `consume()` moves the window head. If the buffer fills up faster than consumption (slow query, fast input), it triggers backpressure or dynamic resizing.
3.  **No Syscalls in Hot Path:** `refill()` is the only syscall point. The Parser calls `peek()` and `consume()` millions of times, which are just pointer arithmetic.

---

## Module 2: Parser (The Resilient Core)
**Responsibility:** Convert byte streams into a Tape (Structural Index). Handle UTF-8, number parsing, and critically, **Incomplete JSON recovery**.

### Interface
```zig
pub const Parser = struct {
    // Initializes parser state. Must be reused per record.
    pub fn init(allocator: Allocator) Parser;

    // Feeds a byte slice into the parser.
    // Returns:
    //   .Done(Tape) -> Valid JSON object finished.
    //   .NeedMore   -> JSON is valid so far but incomplete (streaming).
    //   .Error      -> Invalid syntax.
    pub fn feed(p: *Parser, input: []const u8, is_eof: bool) Result;

    // Resets the internal state for the next record.
    pub fn reset(p: *Parser) void;
};
```

### Deep Implementation Details (Hidden)
1.  **Tape Format (The Output):**
    Instead of a generic DOM (hashmaps), output a linear `Tape`.
    ```
    [Header][OpCode][Value][OpCode][Value]...
    ```
    *Example:* `{"a":1}` -> `[StartObj, Key("a"), Int(1), EndObj]`.
    This allows O(1) skipping of values (critical for `.foo.bar` lookups) and minimizes cache misses.

2.  **Partial JSON Tolerance (The LLM Feature):**
    The Parser is a state machine. When `feed()` returns `.NeedMore`:
    *   It freezes its internal stack (list of open `{` or `[`).
    *   It returns control to the Worker.
    *   **Recovery Strategy:** If `is_eof=true` but the stack isn't empty (incomplete JSON), the parser enters "Auto-Close Mode". It synthetically injects `EndObj` / `EndArray` tokens to close the tape.
    *   *Result:* A truncated LLM response `{"thought": "I need to` is parsed as `{"thought": "I need to"}`. It allows downstream logic to inspect partial outputs rather than crashing.

3.  **SIMD Tokenization:**
    Uses SIMD (AVX2/Neon) to scan for structural characters (`{ } [ ] : ,`) in 64-byte chunks. This happens deep inside `feed()`. The interface remains simple, but the implementation is high-performance.

---

## Module 3: Query (The Compiler)
**Responsibility:** Compile text queries into bytecode. Execute bytecode against a Tape.

### Interface
```zig
pub const Query = struct {
    // Compiles source string to bytecode.
    // Errors reported via Error module.
    pub fn compile(src: []const u8, opts: Opts) Error!*CompiledQuery;

    // Executes the compiled bytecode against a Tape.
    // Returns an iterator to yield multiple results (jq filters can output 0..N items).
    pub fn execute(q: *CompiledQuery, tape: *Tape, allocator: Allocator) ResultIterator;
};

pub const ResultIterator = struct {
    // Yields the next value from the execution.
    // Returns null when finished.
    pub fn next(it: *ResultIterator) ?Value;
};
```

### Deep Implementation Details (Hidden)
1.  **Bytecode VM:**
    Queries like `.foo | .bar` compile to `[OP_LOAD_KEY "foo", OP_LOAD_KEY "bar", OP_OUTPUT]`.
    *   *Why?* An AST walker is slow (pointer chasing). A tight `switch` loop over bytecode is CPU-cache friendly and fits in the instruction cache (i-cache).
2.  **Optimization Pass:**
    The compiler performs a "Fuse" pass. `.a | .b` is fused into a single `OP_LOAD_PATH "a.b"` instruction, reducing interpreter overhead by 50%.

---

## Module 4: Worker Pool (The Orchestrator)
**Responsibility:** Manage threads, distribute work, and **preserve order**.

### Interface
```zig
pub const Pool = struct {
    pub fn init(n_threads: usize) Pool;
    pub fn deinit(p: *Pool) void;

    // Submits a file descriptor for processing.
    // This function returns immediately.
    pub fn submit_file(p: *Pool, fd: os.fd_t, query: *CompiledQuery) void;

    // Submits a stream (stdin/pipe).
    // This handles partial JSON coordination.
    pub fn submit_stream(p: *Pool, src: *Source, query: *CompiledQuery) void;

    // Collects results.
    // BLOCKS until the next result is ready.
    // Guarantees order: Result 1 corresponds to Input Record 1.
    pub fn collect(p: *Pool) ?Result;
};
```

### Deep Implementation Details (Hidden)
1.  **Work Stealing (Files):**
    For `zq '.' huge.jsonl`:
    The main thread splits the file into chunks (based on `\n` scanning).
    Workers steal chunks.
    *   *Hidden complexity:* A chunk might cut a JSON object in half. The Worker handles boundary checks (finding the next `\n`) to ensure clean processing.

2.  **Stream Pipeline (Stdin/LLM):**
    If input is a stream, parallelism is limited by line availability.
    The Pool detects stream mode and switches to a **Pipeline Strategy**:
    *   Thread 1 (IO): Reads stdin, buffers lines.
    *   Thread 2-N (Workers): Grab complete lines, parse, execute.
    This ensures that even with a slow, trickling LLM stream, the UI remains responsive and processes records as soon as they arrive.

3.  **Ordering Logic:**
    Workers write to a `Sequencer`.
    Worker 3 finishes before Worker 2. Worker 3's result is held in a buffer. `collect()` waits for Worker 2's result, outputs it, then outputs Worker 3's.

---

## Module 5: Output (The Encoder)
**Responsibility:** Format values for stdout/files.

### Interface
```zig
pub const Writer = struct {
    // Writes a Value to the output buffer.
    pub fn write_value(w: *Writer, val: Value, format: Format) Error!void;

    // Flushes internal buffer to OS.
    pub fn flush(w: *Writer) void;
};
```

### Hidden Details
1.  **Buffered Output:** Accumulates 64KB of output before calling `write()`. This reduces syscalls from millions to a few dozen.
2.  **Color/Format:** Detects TTY automatically. Handles `@base64`, `@csv` formatters via a strategy pattern, hidden from the core logic.

---

## Module 6: Error (The Context)
**Responsibility:** Centralized error creation with rich context.

### Interface
```zig
pub const Context = struct {
    line: u64,
    col: u64,
    snippet: []const u8, // The code snippet causing error
};

pub fn raise(kind: ErrorKind, ctx: Context) Error;
```

### Hidden Details
Tracks line/column numbers lazily. We don't count `\n` during the hot path (SIMD tokenization). We only calculate line numbers if an error actually occurs, using a lookup table. This saves 1-2% CPU in the happy path.

---

## Module 7: C ABI Bridge
**Responsibility:** Allow external runtimes (Python, Node, Rust) to use ZQ without shell overhead.

### Interface
```zig
// Standard C signature
export fn zq_compile(query: [*:0]const u8) ?*QueryHandle;
export fn zq_execute(handle: *QueryHandle, input: [*]const u8, len: usize) c_int;
export fn zq_get_result(handle: *QueryHandle) [*:0]const u8;
export fn zq_free(handle: *QueryHandle) void;
```

### Hidden Details
Handles memory ownership translation between ZQ's arena allocators and the caller's heap. Ensures no memory leaks across the boundary.

---

## Data Flow Summary

### Scenario A: Processing a 1GB JSONL Log File (Batch Mode)
1.  **IO:** `mmap("file.jsonl")`. Zero copy.
2.  **Worker Pool:** Main thread identifies 4 chunks.
3.  **Workers:**
    *   Claim chunk offset.
    *   Scan to next `\n`.
    *   Call `Parser.feed()`.
    *   Parser returns `Tape`.
    *   `Query.execute()` runs bytecode on Tape.
    *   Write to `Output` buffer.
4.  **Output:** Merged in order. `flush()` happens once at end.

### Scenario B: LLM Streaming (Partial/Slow Mode)
1.  **IO:** `Source` wraps `stdin`. `refill()` blocks waiting for data.
2.  **Worker Pool:** Single pipeline mode.
3.  **Parser:**
    *   `feed()` called with partial chunk.
    *   Returns `.NeedMore`.
    *   Worker waits.
    *   Next chunk arrives.
    *   `feed()` continues parsing.
    *   Final chunk arrives with `is_eof=true`.
    *   If stack is open, Parser auto-closes brackets.
    *   Returns `Done(Tape)`.
4.  **Query:** Executes on the recovered JSON.
5.  **Output:** Prints immediately.
