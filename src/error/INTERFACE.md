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
/// Zig error set for propagation through Zig's native error union mechanism.
/// Use this as the error type in all function signatures across zq modules:
///
///   fn peek(self: *IO) ZqError!SliceView
///   fn parse(src: []const u8) ZqError!Tape
///
/// ZqError mirrors ErrorKind 1:1. On the error path, convert the caught
/// ZqError into an Error (with Context) for user-facing display.
pub const ZqError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidUtf8,
    InvalidNumber,
    UnterminatedString,
    DepthLimitExceeded,
    /// An underlying OS call failed (fstat, mmap, read, etc.).
    /// Distinct from UnexpectedEof — the stream is not at a clean end.
    IoError,
    /// Malformed filter expression detected at compile time.
    QuerySyntaxError,
    /// Regex pattern failed to compile (bad syntax, unsupported construct,
    /// or shim internal error). Surfaced at filter-compile time for literal
    /// patterns, at runtime for dynamic ones.
    RegexCompileError,
    /// Regex engine not linked into this build (`-Dregex=false`).
    RegexNotCompiled,
    /// Regex engine raised an internal error at runtime.
    RegexInternalError,
    /// Operation applied to wrong JSON type at runtime.
    TypeError,
    /// Array index beyond array length at runtime.
    IndexOutOfBounds,
    /// Memory allocation failed during operation.
    OutOfMemory,
    /// User-raised error via the `error` builtin.
    UserError,
};

/// All error conditions zq can produce (mirrors ZqError 1:1).
/// Used only at the display layer — never in function signatures.
pub const ErrorKind = enum {
    unexpected_token,
    unexpected_eof,
    invalid_utf8,
    invalid_number,
    unterminated_string,
    depth_limit_exceeded,
    io_error,
    query_syntax_error,
    regex_compile_error,
    regex_not_compiled,
    regex_internal_error,
    type_error,
    index_out_of_bounds,
    out_of_memory,
    user_error,
};

/// Rich diagnostic context attached to every user-facing error.
///
/// `snippet` is a non-owning slice into the original source buffer.
/// The caller is responsible for keeping source alive for the duration
/// of the Error's use. This ownership model is shared by all view types
/// in zq (e.g. SliceView in the IO module): they are windows into
/// caller-owned memory, never independent copies.
pub const Context = struct {
    line:    u64,
    col:     u64,
    snippet: []const u8,
};

/// The user-facing error value. Build this on the error path only.
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

/// Structured compile-time error with source location.
/// Returned inside `query.CompileResult.err`.
pub const CompileError = struct {
    kind:   ErrorKind,
    offset: u32,
    len:    u32,
};

/// Output format selector for `formatDiagnostic`.
pub const DiagnosticFormat = enum { text, json };
```

### Functions

| Function            | Input → Output                                                                                                                        | Description                                                                               |
|---------------------|---------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------|
| `buildLineTable`    | `source: []const u8, alloc: Allocator → !LineTable`                                                                                   | Scan source once, record all `\n` offsets. Call only on error path.                      |
| `resolve`           | `table: LineTable, offset: u64 → struct{line, col}`                                                                                   | Binary-search `newlines` to compute 1-based line and col from byte offset.                |
| `raise`             | `kind: ErrorKind, ctx: Context → Error`                                                                                               | Assemble and return a display Error. Allocation-free and infallible.                      |
| `deinit`            | `table: LineTable, alloc: Allocator → void`                                                                                           | Free the `newlines` slice.                                                                |
| `kindFromZqError`   | `ZqError → ErrorKind`                                                                                                                 | Convert a propagated `ZqError` back to its matching `ErrorKind` (1:1 mapping).            |
| `kindToString`      | `ErrorKind → []const u8`                                                                                                              | Human-readable description ("type error", "regex compile error", …).                      |
| `formatDiagnostic`  | `writer, filter_src, kind, offset, len, input_preview?, user_message?, alloc, DiagnosticFormat → void`                                | Render a `text` or `json` diagnostic with caret underline. Infallible (write errors swallowed). |

### Error Propagation Pattern

All zq modules use `ZqError!T` for Zig-native propagation. The `Error` struct
is built once, at the outermost error-handling boundary, for display:

```zig
// Inside a module function — propagate with try:
fn tokenize(src: []const u8, offset: u64) ZqError!Token {
    if (src[offset] == 0xFF) return error.InvalidUtf8;
    ...
}

// At the display boundary — enrich with context:
const result = tokenize(source, off) catch |e| {
    const table = try err_mod.buildLineTable(source, allocator);
    defer err_mod.deinit(table, allocator);
    const pos = err_mod.resolve(table, off);
    const ctx = err_mod.Context{
        .line    = pos.line,
        .col     = pos.col,
        .snippet = source[snippet_start..snippet_end],
    };
    return err_mod.raise(errorKindFromZqError(e), ctx);
};
```

### Errors

| Error                         | When                                           | Return                  |
|-------------------------------|------------------------------------------------|-------------------------|
| `Allocator.Error.OutOfMemory` | `buildLineTable` fails to allocate             | propagate `!LineTable`  |

`formatDiagnostic` is infallible: if the `LineTable` allocation fails it emits
a bare error message (text) or a minimal `{"error":"..."}` object (json)
instead of returning an error.

## Dependencies
- `std.mem.Allocator` (stdlib only — no external dependencies)

## Constraints & Invariants
- `raise` is always allocation-free and infallible.
- `buildLineTable` is **never** called on the happy path.
- `resolve` returns 1-based line and col (matches editor convention).
- `snippet` is a non-owning slice into the original source; caller owns source lifetime.
- `LineTable.newlines` is always sorted ascending.
- `resolve` treats the `\n` character itself as the last column of its line.
- `ZqError` and `ErrorKind` are kept in sync — adding a variant requires updating both.
- All view types in zq (`snippet`, future `SliceView`, etc.) are non-owning windows into caller-managed source memory.
