# Module: ast

## Purpose
Error-tolerant recursive-descent parser for the jq filter language. Produces a
full AST rooted at `Node`, carrying a `Span` on every node and a collected
`ParseError` list. The parser never returns a Zig `error` from its public
entry — malformed input produces `error_node` AST fragments and an entry in
`ParseResult.errors`. This is the contract that makes `ast` safe to drive
from the LSP on every keystroke.

The AST is consumed by:
- `src/lsp/analysis.zig` — builds the `SemanticModel` for hover/definition/rename.
- `src/lsp/features/*` — completion, semantic tokens, formatting walk the tree.
- `legacy@22cd23c compiler.zig` — the prefilter-harvest pass (`harvestPrefilterFromAst`).

---

## Public Interface

### Types

```zig
const std = @import("std");

/// Byte range into the source buffer. UTF-8 byte offsets, NOT UTF-16 code
/// units. LSP conversion to `Position` is the LSP's responsibility (see
/// `src/lsp/protocol.zig#byteOffsetToPosition`).
pub const Span = struct {
    start: u32,
    end: u32,

    pub fn empty() Span;
    pub fn from(start: u32, end: u32) Span;
};

/// Arena-allocated AST node. Every node carries a source `Span`.
pub const Node = struct {
    kind: Kind,
    span: Span,

    pub const Kind = union(enum) {
        // Composition
        pipe: Pipe, comma: Comma, func_def: FuncDef,
        // Operators
        alternative: Binary, or_expr: Binary, and_expr: Binary,
        comparison: Comparison, arithmetic: Arithmetic, unary_neg: Unary,
        // Binding
        as_pattern: AsPattern, destruct_alt: DestructAlt,
        // Primary
        identity, recurse, field_access: FieldAccess, index_access: IndexAccess,
        iterate, slice: Slice, literal: Literal, paren: Unary,
        variable_ref: VarRef, optional: Unary,
        // Constructors
        array_construct: ArrayConstruct, object_construct: ObjectConstruct,
        string_interp: StringInterp, format_string: FormatString,
        // Calls
        builtin_call: BuiltinCall, func_call: FuncCall,
        // Control flow
        if_expr: IfExpr, try_catch: TryCatch, reduce: Reduce, foreach: Foreach,
        label_expr: LabelExpr, break_expr: BreakExpr,
        // Assignment
        update_assign: UpdateAssign,
        // Suffix chain
        suffix: Suffix,
        // Error recovery
        error_node: ErrorNode,
    };

    // Payload types re-exported for walkers (see nodes.zig for full list):
    // Pipe, Comma, FuncDef, FuncParam, Binary, Comparison (+ CmpOp),
    // Arithmetic (+ ArithOp), Unary, AsPattern, DestructAlt, FieldAccess,
    // IndexAccess, Slice, Literal, VarRef, ArrayConstruct, ObjectConstruct,
    // ObjectField, ObjectKey, StringInterp, FormatString, StringPart,
    // BuiltinCall, FuncCall, IfExpr, ElifChain, TryCatch, Reduce, Foreach,
    // LabelExpr, BreakExpr, UpdateAssign (+ AssignOp), PathStep, Suffix,
    // SuffixOp, ErrorNode.
};

/// Destructuring pattern used by `as`, `reduce`, `foreach`.
pub const Pattern = union(enum) {
    simple: []const u8,
    array: []const Pattern,
    object: []const ObjectPatternField,
};

pub const ObjectPatternField = struct {
    key: PatternKey,
    pattern: Pattern,
};

pub const PatternKey = union(enum) {
    static: []const u8,
    computed: *Node,
};

/// A single recoverable parse failure.
pub const ParseError = struct {
    message: []const u8,
    span: Span,
    kind: Kind,

    pub const Kind = enum {
        unexpected_token,
        missing_token,
        unterminated,
        invalid_literal,
        unknown,
    };
};

/// Parse output. Always non-null root; `errors` empty on a clean parse.
pub const ParseResult = struct {
    root: *Node,
    errors: []const ParseError,
    arena: std.heap.ArenaAllocator,
    alloc: std.mem.Allocator,

    /// Free the errors slice (allocator-owned) and the arena.
    /// Invalidates every `Node`, `Pattern`, and slice previously reached via
    /// `root`.
    pub fn deinit(self: *ParseResult) void;
    pub fn hasErrors(self: *const ParseResult) bool;
};

/// Low-level parser handle. `parse` below is the only entry most callers need.
pub const Parser = struct {
    pub fn create(source: []const u8, alloc: std.mem.Allocator) Parser;
    pub fn parse(source: []const u8, alloc: std.mem.Allocator) ParseResult;
};
```

### Functions

| Function      | Signature                                                  | Description                                                                      |
|---------------|------------------------------------------------------------|----------------------------------------------------------------------------------|
| `parse`       | `[]const u8, std.mem.Allocator → ParseResult`              | Top-level entry. Always succeeds; errors in `result.errors`.                    |
| `Parser.parse`| `[]const u8, std.mem.Allocator → ParseResult`              | Same contract; reachable under `ast.parser.Parser.parse` for explicit callers.  |
| `Parser.create`| `[]const u8, std.mem.Allocator → Parser`                 | Construct a parser without invoking it. Rarely used directly.                  |

### Errors

None at the public surface. `parse` is **total**: it never returns a Zig
`error`. Syntactic problems are reported as `ParseError` entries in
`result.errors` and as `error_node` fragments inside the AST. `OutOfMemory`
during parsing is silently dropped by an internal `catch {}` on the error
list; the resulting `errors` slice may be empty or truncated, and the AST
partial. This mirrors the LSP-first design: the language server must always
be able to move forward, even under memory pressure.

---

## Constraints & Invariants

- **`parse` is total.** No Zig `error` escapes. A malformed filter still
  produces a `*Node` (possibly an `error_node` at the failure site) and a
  populated `errors` slice. LSP diagnostics, completion, and semantic tokens
  all rely on this guarantee.
- **`Span` offsets are UTF-8 bytes into the original source.** They do NOT
  account for UTF-16 code units. Any LSP consumer must translate via
  `protocol.byteOffsetToPosition`. Internal walkers that stay in byte-offset
  land can use spans directly.
- **Source text is borrowed.** `Parser.create` / `parse` store `source` as a
  non-owning slice. `Node.FieldAccess.name`, `VarRef.name`, `Literal.string`,
  and similar string fields are all slices into this buffer (or, for some
  nodes, into the parser's arena). The caller must keep `source` alive for
  the full lifetime of `ParseResult`.
- **AST memory is arena-owned.** Every `*Node`, every `[]const Pattern`, and
  every payload slice comes from `ParseResult.arena`. `deinit` frees them en
  masse. Do not free individual nodes; do not copy pointers out.
- **`errors` is allocator-owned (NOT arena).** `ParseResult.deinit` calls
  `alloc.free(errors)` before tearing down the arena. Callers who want to
  retain diagnostic data after `deinit` must copy the slice.
- **`Parser` is not thread-safe.** Each parse run creates its own `Parser`
  value; concurrent `parse` calls on independent source buffers are fine
  because they share no mutable state.
- **Depth of recursion is bounded by source nesting.** The parser is direct
  recursive descent; deeply nested `(((...)))` input can exhaust the host
  stack. Input length is the de facto depth bound — consistent with jq's own
  behavior.
- **Used by the prefilter harvester.** `legacy@22cd23c compiler.zig` walks the
  AST to lift literal regex patterns into the Sparser prefilter set. AST
  shape changes (new `Kind` variants, renamed payload fields) ripple there
  as well as through the LSP feature modules.

---

## Dependencies

- `src/lexer/root.zig` — `Lexer`, `Token` for tokenization
- stdlib only beyond that: `std.mem.Allocator`, `std.heap.ArenaAllocator`, `std.ArrayList`
