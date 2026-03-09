# Module: error

## Purpose
Centralized error creation with rich diagnostic context. Provides a lazy
line/column resolution strategy: byte offsets are tracked during the hot path
(SIMD tokenization), and line/column numbers are computed only when an error
actually occurs via a pre-built LineTable. This saves ~1-2% CPU on the happy
path by eliminating `\n` counting during tokenization.

## Public Interface

### Types

```zig
/// All error conditions zq can produce.
pub const ErrorKind = enum {
    unexpected_token,
    unexpected_eof,
    invalid_utf8,
    invalid_number,
    unterminated_string,
    depth_limit_exceeded,
};

/// Rich diagnostic context attached to every error.
pub const Context = struct {
    line:    u64,
    col:     u64,
    snippet: []const u8, // source slice that caused the error
};

/// The error value returned to the caller.
pub const Error = struct {
    kind: ErrorKind,
    ctx:  Context,
};

/// Sparse lookup table: built once from source on error path.
/// Maps byte offsets of every '\n' to enable O(log n) line resolution.
pub const LineTable = struct {
    newlines: []const u64,  // sorted ascending; offsets of each '\n' in source
    source:   []const u8,
};
```

### Functions

| Function         | Input → Output                                        | Description                                                              |
|------------------|-------------------------------------------------------|--------------------------------------------------------------------------|
| `buildLineTable` | `source: []const u8, alloc: Allocator → !LineTable`  | Scan source once, record all `\n` offsets. Call only on error path.      |
| `resolve`        | `table: LineTable, offset: u64 → struct{line, col}`  | Binary-search `newlines` to compute 1-based line and col from byte offset.|
| `raise`          | `kind: ErrorKind, ctx: Context → Error`               | Assemble and return an Error. Allocation-free and infallible.            |
| `deinit`         | `table: LineTable, alloc: Allocator → void`           | Free the `newlines` slice.                                               |

### Usage Examples

```zig
// On the error path only — never in the hot loop:
const table = try error_mod.buildLineTable(source, allocator);
defer error_mod.deinit(table, allocator);

const pos = error_mod.resolve(table, failing_offset);
const ctx = error_mod.Context{
    .line    = pos.line,
    .col     = pos.col,
    .snippet = source[snippet_start..snippet_end],
};
return error_mod.raise(.unexpected_token, ctx);
```

### Errors

| Error                       | When                               | Return              |
|-----------------------------|------------------------------------|---------------------|
| `Allocator.Error.OutOfMemory` | `buildLineTable` fails to allocate | propagate `!LineTable` |

## Dependencies
- `std.mem.Allocator` (stdlib only — no external dependencies)

## Constraints & Invariants
- `raise` is always allocation-free and infallible.
- `buildLineTable` is **never** called on the happy path.
- `resolve` returns 1-based line and col (matches editor convention).
- `snippet` is a slice into the original source; caller owns source lifetime.
- `LineTable.newlines` is always sorted ascending.
- `resolve` treats the `\n` character itself as the last column of its line.
