# Module: lsp

## Purpose
Language Server Protocol implementation for the jq filter language. Runs a
single-threaded JSON-RPC message loop on stdin/stdout with Content-Length
framing and exposes diagnostics, completion, hover, definition, references,
rename, signature help, semantic tokens, and formatting.

The server is AST-backed: the `src/ast/` parser is the single source of truth
for structure, and `src/query/` compiles the filter for compile-error
diagnostics — the same pipeline the CLI runs. No bespoke re-implementation
of either.

Entry point: `lsp.run(allocator)` — invoked by `main.zig` when the binary is
launched with `--lsp`.

---

## Public Interface

### Top-level

```zig
const std = @import("std");

/// Start the LSP server on the process's stdin/stdout and loop until shutdown.
pub fn run(alloc: std.mem.Allocator) !void;

/// Re-exported submodules.
pub const server:    @import("server.zig");
pub const transport: @import("transport.zig");
pub const protocol:  @import("protocol.zig");
pub const analysis:  @import("analysis.zig");
pub const builtins:  @import("builtins.zig");
pub const features = struct {
    pub const diagnostics: @import("features/diagnostics.zig");
};
pub const Server = server.Server;
```

### `server.Server`

```zig
pub const Server = struct {
    pub fn init(in_file: std.fs.File, out_file: std.fs.File, alloc: std.mem.Allocator) Server;
    pub fn deinit(self: *Server) void;

    /// Block on the transport, dispatching every inbound message until
    /// `shutdown` + `exit` (or a transport EOF) is received.
    pub fn run(self: *Server) !void;

    /// Test-only hook. Inject a single JSON-RPC message as if it had come
    /// from the transport. Stable API — exercised by `tests/lsp_test.zig`
    /// to validate didOpen/didChange behavior without spawning a pipe pair.
    pub fn dispatchForTest(self: *Server, body: []const u8) void;

    /// Test-visible counter bumped every time the server actually re-runs
    /// the compiler to refresh diagnostics. A no-op didChange (same source
    /// bytes) must leave this unchanged.
    compile_count: u32,
};
```

### `transport.Transport`

```zig
/// JSON-RPC 2.0 transport: Content-Length framed payloads on two file
/// handles. Bodies are bounded at 10 MiB; oversize inputs raise
/// `error.ContentTooLarge`.
pub const Transport = struct {
    pub fn init(in: std.fs.File, out: std.fs.File, alloc: std.mem.Allocator) Transport;
    pub fn deinit(self: *Transport) void;
    pub fn readMessage(self: *Transport) ![]u8;       // caller frees
    pub fn writeMessage(self: *Transport, body: []const u8) !void;
};
```

### `protocol` — LSP wire types and offset helpers

```zig
pub const Position  = struct { line: u32, character: u32 };
pub const Range     = struct { start: Position, end: Position };
pub const Location  = struct { uri: []const u8, range: Range };

pub const DiagnosticSeverity = enum(u8) { @"error" = 1, warning, information, hint };
pub const Diagnostic = struct {
    range: Range,
    severity: DiagnosticSeverity,
    message: []const u8,
    source: []const u8 = "zq",
};

pub const CompletionItemKind = enum(u8) { /* 1..25, LSP spec values */ };
pub const InsertTextFormat   = enum(u8) { plain_text = 1, snippet = 2 };
pub const CompletionItem     = struct { label, kind, detail, documentation, insertText, insertTextFormat };
pub const Hover              = struct { contents: MarkupContent, range: ?Range };
pub const MarkupContent      = struct { kind: []const u8 = "markdown", value: []const u8 };

pub const SemanticTokenTypes     = struct { keyword, function, variable, string, number, operator, property, type_ }; // u32 indices
pub const SemanticTokenModifiers = struct { declaration, builtin };                                                    // u32 indices

pub const TextDocumentIdentifier         = struct { uri: []const u8 };
pub const TextDocumentItem               = struct { uri, languageId, version, text };
pub const VersionedTextDocumentIdentifier= struct { uri: []const u8, version: i64 };
pub const TextDocumentContentChangeEvent = struct { text: []const u8 };

/// Column conversion — LSP Positions are UTF-16 code units, AST spans are
/// UTF-8 bytes. These are the only two places in the server that bridge.
pub fn utf8ToUtf16Offset(text: []const u8, byte_offset: u32) u32;
pub fn utf16ToUtf8Offset(text: []const u8, utf16_offset: u32) u32;
pub fn byteOffsetToPosition(source: []const u8, byte_offset: u32) Position;
```

### `analysis.SemanticModel`

```zig
pub const Symbol    = struct { name: []const u8, kind: Kind, span: Span, scope_id: u32;
                               pub const Kind = enum { variable, function, parameter, label }; };
pub const Reference = struct { symbol_id: u32, span: Span, is_definition: bool };
pub const Scope     = struct { parent: ?u32, symbols: std.ArrayList(u32) };

pub const SemanticModel = struct {
    symbols:    std.ArrayList(Symbol),
    references: std.ArrayList(Reference),
    scopes:     std.ArrayList(Scope),

    pub fn init(alloc: std.mem.Allocator) SemanticModel;
    pub fn deinit(self: *SemanticModel) void;

    /// Build a model from an AST root. Seeds the root scope with every
    /// builtin from `builtins.zig` so unqualified references resolve.
    pub fn analyze(root: *const ast.Node, alloc: std.mem.Allocator) SemanticModel;

    /// Smallest-enclosing-node lookup for hover/definition/etc.
    pub fn nodeAtOffset(root: *const ast.Node, byte_offset: u32) ?*const ast.Node;
};
```

### `builtins`

```zig
pub const Category = enum { array, object, string, math, type_check, io, path, control, format, misc };

pub const BuiltinInfo = struct {
    name:      []const u8,
    arity:     u8,
    signature: []const u8,
    doc:       []const u8,
    category:  Category,
};

/// Static table. Drives completion, hover, and semantic-token classification.
pub const builtins: [N]BuiltinInfo;

pub fn lookup(name: []const u8) ?*const BuiltinInfo;
pub fn byCategory(cat: Category, buf: []const *const BuiltinInfo) []const *const BuiltinInfo;
```

### `features/*` — one module per LSP capability

| Module              | Public surface (abbreviated)                                                              |
|---------------------|-------------------------------------------------------------------------------------------|
| `diagnostics`       | `fromParseResult`, `fromParseErrors`, `fromCompileErrors` (runs `query.CompiledQuery.compile`) |
| `completion`        | `complete(...)` — context-aware completion from `SemanticModel` + `builtins`              |
| `hover`             | `hover(...)` — MarkupContent for the node at offset                                       |
| `definition`        | `definition(...)` — `Location` of the declaration for the symbol at offset                |
| `references`        | `findReferences(...)` — all `Location`s (optionally including the declaration)            |
| `rename`            | `prepareRename`, `rename`, `RenameEdit`                                                   |
| `signature`         | `signatureHelp`, `SignatureHelp` struct                                                   |
| `semantic_tokens`   | `token_types`, `token_modifiers` string arrays; `encode(root, source, alloc) []u32`       |
| `formatting`        | `format(root, alloc) []const u8`                                                          |

---

## Errors

The server catches transport and JSON-decode failures internally and keeps
running; only fatal transport errors bubble out of `Server.run`.

| Error                          | Source                 | When                                                            |
|--------------------------------|------------------------|-----------------------------------------------------------------|
| `error.ReadFailed`             | Transport              | stdin I/O error.                                                |
| `error.WriteFailed`            | Transport              | stdout I/O error.                                               |
| `error.UnexpectedEof`          | Transport              | Client closed before a full body arrived. Loop exits cleanly.   |
| `error.MissingContentLength`   | Transport              | Malformed framing on an inbound message.                        |
| `error.ContentTooLarge`        | Transport              | Body exceeds 10 MiB.                                            |

Diagnostic generation itself never raises: `fromCompileErrors` swallows
`OutOfMemory` from the compiler and returns an empty slice, keeping the
server alive under memory pressure.

---

## Constraints & Invariants

- **Single-threaded message loop.** `Server.run` processes one message at a
  time. The document store is NOT thread-safe and relies on this.
- **AST is the single source of truth for structure.** Every feature
  (diagnostics, completion, hover, …) walks the AST produced by `src/ast/`.
  There is no bespoke lexer/parser in the LSP.
- **Compile-error diagnostics go through the real compiler.** `diagnostics
  .fromCompileErrors` calls `query.CompiledQuery.compile` with the same
  options the CLI uses, so regex compile failures, arity mismatches, and
  everything else render identically in the editor and at runtime.
- **Per-document diagnostic memoization.** `Server.Document.compile_cache`
  keys on a 64-bit Wyhash of the source. Unchanged source → no recompile.
  The cache holds the flat `Diagnostic` slice only, never a live
  `CompiledQuery` — regex pools are intentionally short-lived.
  `compile_count` is the test-visible proof of this property.
- **Document store lifetime.** Per `textDocument/didOpen` the server owns a
  duplicated `uri` and `source`, the `ast.ParseResult`, and the
  `SemanticModel`. All are freed on `didClose` or `Server.deinit`.
- **Positions are UTF-16 on the wire, UTF-8 in the AST.** Every crossing
  goes through `protocol.utf8ToUtf16Offset` /
  `protocol.byteOffsetToPosition`. Features receive byte offsets and return
  LSP ranges; the bridge is centralized so the rule doesn't leak.
- **`dispatchForTest` is a stable contract.** It is used exclusively by
  `tests/lsp_test.zig` to exercise the dispatcher without a real transport;
  callers MUST NOT rely on it in production code, but its shape (a single
  JSON-RPC message in, side-effects only) is held fixed across refactors.
- **Unknown methods are handled gracefully.** Requests with an `id` get a
  JSON-RPC `-32601` "Method not found" reply; notifications are ignored.

---

## Dependencies

- `src/ast/root.zig`   — `Node`, `Span`, `ParseResult`, `ParseError`, `parse`
- `src/lexer/root.zig` — lexer types (imported transitively for span/token work)
- `src/query/root.zig` — `CompiledQuery.compile`, `CompileResult` (diagnostics)
- `src/error/root.zig` — error formatting helpers
- `src/types.zig`      — `BuiltinId` for completion classification
- stdlib: `std.json`, `std.fs.File`, `std.StringHashMap`, `std.hash.Wyhash`, `std.ArrayList`
