# Module: c_abi

## Purpose
Expose zq's parse-compile-execute pipeline to external runtimes (Python, Node,
Rust, etc.) through a stable C ABI, eliminating shell-process overhead for
programmatic callers.

All state is encapsulated in a heap-allocated `QueryHandle` that owns a
`CompiledQuery`, a reusable `Parser`, and a null-terminated result buffer.
Callers manage only an opaque pointer; memory ownership is entirely on zq's
side and is released atomically by `zq_free`.

---

## Public Interface

### Types

```zig
// Opaque handle. Callers hold a `?*QueryHandle`; never dereference directly.
// Owns: CompiledQuery, Parser, result buffer, error buffer, and the allocator
// used for all internal allocations.
pub const QueryHandle = struct {
    allocator:  std.mem.Allocator,
    query:      CompiledQuery,
    parser:     Parser,
    /// Null-terminated result buffer from the last successful zq_execute.
    result_buf: []u8,
    result_len: usize,
    /// Null-terminated JSON error object from the last failed zq_execute.
    /// Empty when the previous call succeeded.
    error_buf:  []u8,
    error_len:  usize,

    /// Initial capacities; both buffers grow via realloc as needed.
    const INITIAL_RESULT_CAP: usize = 4096;
    const INITIAL_ERROR_CAP:  usize = 512;
};

// ── C-visible exports ──────────────────────────────────────────────────────

/// Compile `query_str` (null-terminated C string) into a reusable handle.
/// Returns null on any error (syntax error, OOM). No error text is emitted.
export fn zq_compile(query_str: [*:0]const u8) ?*QueryHandle;

/// Compile `query_str` with optional error reporting.
///
/// On failure, if `error_out` is non-null it is set to a null-terminated JSON
/// string (thread-local buffer) describing the compile error. The pointer is
/// valid until the next `zq_compile_ext` call on the same thread.
export fn zq_compile_ext(
    query_str: [*:0]const u8,
    error_out: ?*[*:0]const u8,
) ?*QueryHandle;

/// Execute the compiled query against `input_ptr[0..input_len]`.
/// On success results are serialized into the handle's result buffer in
/// compact JSON (JSONL-style when multiple values are produced); returns 0.
/// On failure returns a negative error code and populates the handle's error
/// buffer with a JSON error object retrievable via `zq_get_error`.
export fn zq_execute(
    handle:    *QueryHandle,
    input_ptr: [*]const u8,
    input_len: usize,
) c_int;

/// Pointer to the null-terminated result string from the last successful
/// `zq_execute`. Valid until the next `zq_execute` or `zq_free` call.
export fn zq_get_result(handle: *QueryHandle) [*:0]const u8;

/// Pointer to the null-terminated JSON error string from the last failed
/// `zq_execute`. Empty when the last execute succeeded. Valid until the next
/// `zq_execute` or `zq_free` call.
export fn zq_get_error(handle: *QueryHandle) [*:0]const u8;

/// Release all resources owned by the handle and free the handle itself.
/// The pointer must not be used after this call.
export fn zq_free(handle: *QueryHandle) void;
```

### Functions

| Function          | Signature                                                           | Description                                                                                        |
|-------------------|---------------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| `zq_compile`      | `[*:0]const u8 → ?*QueryHandle`                                     | Compile query string; null on any error. Delegates to `zq_compile_ext(q, null)`.                   |
| `zq_compile_ext`  | `[*:0]const u8, ?*[*:0]const u8 → ?*QueryHandle`                    | Compile with optional thread-local JSON error reporting. Null on failure.                          |
| `zq_execute`      | `*QueryHandle, [*]const u8, usize → c_int`                          | Parse input, run query, serialize results to handle's result buffer. 0 = success.                  |
| `zq_get_result`   | `*QueryHandle → [*:0]const u8`                                      | Null-terminated result buffer from the last successful execute.                                    |
| `zq_get_error`    | `*QueryHandle → [*:0]const u8`                                      | Null-terminated JSON error object from the last failed execute (empty otherwise).                  |
| `zq_free`         | `*QueryHandle → void`                                               | Deinit all owned resources and free the handle. Must be called exactly once per compile.           |

### Error Codes

Defined in `src/c_abi/root.zig`; returned by `zq_execute`. The underlying
`ZqError → code` mapping lives in `errorToCode`.

| Code | Constant      | Triggered by                                                                                                 |
|------|---------------|--------------------------------------------------------------------------------------------------------------|
|  `0` | success       | `zq_execute` completed; result available via `zq_get_result`.                                                |
| `-1` | `ERR_PARSE`   | Any parser `ZqError` (`UnexpectedToken`, `UnexpectedEof`, `InvalidUtf8`, `InvalidNumber`, `UnterminatedString`, `DepthLimitExceeded`, `IoError`) **and** `QuerySyntaxError`, `RegexCompileError`, `RegexNotCompiled`, `RegexInternalError`. |
| `-2` | `ERR_TYPE`    | `TypeError` during query evaluation.                                                                          |
| `-3` | `ERR_OOM`     | `OutOfMemory` during parser feed, iterator init, or buffer growth.                                            |
| `-4` | `ERR_INDEX`   | `IndexOutOfBounds` during query evaluation.                                                                   |
| `-5` | `ERR_USER`    | `UserError` raised via the `error` builtin; user message forwarded into the JSON error object when available. |

---

## Dependencies

- `src/error/root.zig`  — `ZqError`, `kindFromZqError` for error classification
- `src/query/root.zig`  — `CompiledQuery`, `Opts`, `CompileResult`, `ResultIterator`
- `src/parser/root.zig` — `Parser`, `FeedResult`
- `src/types.zig`       — `Value`, `Format`, `formatJqFloat`
- `std.heap.page_allocator` — backing allocator for all handle memory; available
  without libc and survives across Zig function boundaries

---

## Constraints & Invariants

- **Handle owns everything.** The `QueryHandle` is the single allocation root.
  All internal objects (`CompiledQuery`, `Parser`, result buffer, error buffer)
  are allocated with the handle's allocator and freed by `zq_free`. No memory
  crosses the boundary unowned.
- **Result and error buffers are null-terminated.** The byte at index
  `result_len` (resp. `error_len`) is always `0`, satisfying C string
  conventions. Both buffers grow via `realloc` as needed.
- **Buffer pointer lifetime.** Pointers returned by `zq_get_result` and
  `zq_get_error` are valid only until the next `zq_execute` or `zq_free` call.
  Callers must copy the data if they need it to outlive either event.
- **Result buffer is preserved on failure.** `zq_execute` accumulates output
  into a temporary list and commits to `result_buf` only on success; a failed
  execute leaves the previous successful result intact.
- **Parser is reset between executions.** `zq_execute` calls `Parser.reset()`
  before `Parser.feed()`, enabling safe reuse across multiple calls.
- **`zq_compile` returns null on any error** without emitting error text.
  Callers that want a structured compile error must use `zq_compile_ext` with a
  non-null `error_out`; the string lives in a thread-local buffer and is
  overwritten by the next `zq_compile_ext` call from the same thread.
- **`zq_execute` is not thread-safe.** Each concurrent caller must use its own
  `QueryHandle`.
- **No new `ZqError` variants.** This module adds no new error kinds; every
  `ZqError` value is classified into one of the six exit codes by `errorToCode`.
  `QuerySyntaxError` and the regex error family all collapse to `-1 ERR_PARSE`.
- **`zq_free` must be called exactly once.** Double-free or use-after-free is
  undefined behaviour; the module provides no protection against it.
- **Compact JSON serialization.** Results are always serialized in compact
  format, with a single `\n` appended after each value when more than one
  result is produced (JSONL-style). Single-result output has no trailing
  newline.
