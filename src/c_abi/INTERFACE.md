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
// Owns: CompiledQuery, Parser, result buffer, and the allocator used for all
// internal allocations.
pub const QueryHandle = struct { ... };

// ── C-visible exports ──────────────────────────────────────────────────────

/// Compile `query_str` (null-terminated C string) into a reusable handle.
/// Returns null on any error (syntax error, OOM).
export fn zq_compile(query_str: [*:0]const u8) ?*QueryHandle;

/// Execute the compiled query against `input_ptr[0..input_len]`.
/// Results are serialized into the handle's internal buffer (compact JSON,
/// one value per line when multiple results are produced).
/// Returns 0 on success, or a negative error code on failure.
export fn zq_execute(
    handle:    *QueryHandle,
    input_ptr: [*]const u8,
    input_len: usize,
) c_int;

/// Return a pointer to the null-terminated result string from the most recent
/// successful `zq_execute` call.
/// The pointer is valid until the next `zq_execute` or `zq_free` call.
export fn zq_get_result(handle: *QueryHandle) [*:0]const u8;

/// Release all resources owned by the handle, including the handle itself.
/// The pointer must not be used after this call.
export fn zq_free(handle: *QueryHandle) void;
```

### Functions

| Function       | Signature                                                                 | Description                                                                               |
|----------------|---------------------------------------------------------------------------|-------------------------------------------------------------------------------------------|
| `zq_compile`   | `[*:0]const u8 → ?*QueryHandle`                                           | Compile query string; allocate and return a handle. Null on any error.                    |
| `zq_execute`   | `*QueryHandle, [*]const u8, usize → c_int`                                | Parse input, run query, serialize results to handle's result buffer. 0 = success.         |
| `zq_get_result`| `*QueryHandle → [*:0]const u8`                                            | Return pointer to null-terminated result buffer from last successful execute.             |
| `zq_free`      | `*QueryHandle → void`                                                     | Deinit all owned resources and free the handle. Must be called exactly once per compile.  |

### Error Codes

| Code | Constant             | Meaning                                                            |
|------|----------------------|--------------------------------------------------------------------|
|  `0` | success              | `zq_execute` completed; result available via `zq_get_result`.      |
| `-1` | parse error          | Input JSON was malformed (any parser `ZqError`).                   |
| `-2` | query execution error| `TypeError` or `IndexOutOfBounds` during query evaluation.         |
| `-3` | out of memory        | Allocation failed inside `zq_execute` (parser, iterator, or buffer). |

---

## Dependencies

- `src/error/root.zig`  — `ZqError` for error classification
- `src/query/root.zig`  — `CompiledQuery`, `Opts`, `ResultIterator`
- `src/parser/root.zig` — `Parser`, `FeedResult`
- `src/types.zig`       — `Value`, `Format`
- `std.heap.c_allocator` — GPA-backed allocator for cross-boundary heap safety

---

## Constraints & Invariants

- **Handle owns everything.** The `QueryHandle` is the single allocation root.
  All internal objects (`CompiledQuery`, `Parser`, result buffer) are allocated
  with the handle's allocator and freed by `zq_free`. No memory crosses the
  boundary unowned.
- **Result buffer is null-terminated.** The byte at index `result_len` is
  always `0`, satisfying C string conventions.
- **Result pointer lifetime.** The pointer returned by `zq_get_result` is
  valid only until the next `zq_execute` or `zq_free` call. Callers must copy
  the data if they need it to outlive either event.
- **Parser is reset between executions.** `zq_execute` calls `Parser.reset()`
  before `Parser.feed()`, enabling safe reuse across multiple calls.
- **`zq_compile` returns null on any error.** Errors are not communicated to
  the caller; null is the single failure signal. Callers must treat null as an
  unrecoverable compile failure.
- **`zq_execute` is not thread-safe.** Each concurrent caller must use its own
  `QueryHandle`.
- **No new `ZqError` variants.** This module adds no new error kinds; all
  `ZqError` values that can appear are classified into the three negative codes.
- **`zq_free` must be called exactly once.** Double-free or use-after-free is
  undefined behaviour; the module provides no protection against it.
- **Compact JSON serialization.** Results are always serialized in compact
  format, with a single `\n` appended after each value when more than one
  result is produced (JSONL-style). Single-result output has no trailing
  newline.
