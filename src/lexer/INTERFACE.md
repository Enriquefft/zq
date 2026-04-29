# Module: lexer

## Purpose
Hand-written byte-level tokenizer for the jq filter language. Single pass,
zero allocation: every `Token` is a `(tag, offset, len)` triple referencing
the original source slice. The lexer is stateless beyond its current
position and one explicit hook (`scanStringTail`) for resuming inside a
string after a `\(...)` interpolation.

Consumed by:
- `src/ast/root.zig` — drives the recursive-descent parser via `peek` /
  `next` / `scanStringTail`.
- `src/lsp/features/semantic_tokens.zig` — produces LSP semantic tokens
  by scanning the buffer directly with `Lexer`.

---

## Public Interface

### Types

```zig
const std = @import("std");
const ZqError = @import("error").ZqError;

/// One lexical token. Carries no string content — `slice(src)` recovers
/// the source bytes on demand. Offsets are UTF-8 byte indices into the
/// source buffer the lexer was initialized with.
pub const Token = struct {
    tag:    Tag,
    offset: u32,
    len:    u32,

    /// Discriminator over every recognized token shape. Ordered by
    /// category in the source: punctuation → arithmetic → comparison →
    /// braces → var/func syntax → keywords → conditionals → strings →
    /// format strings → alt → try/catch → label/break → optional →
    /// assignment operators.
    pub const Tag = enum {
        // Punctuation
        dot, dot_dot, pipe, lbracket, rbracket,
        ident, int_lit, float_lit, eof,

        // Arithmetic
        plus, minus, star, slash, percent,

        // Comparison
        eq, ne, lt, le, gt, ge,

        // Parens & braces
        lparen, rparen, lbrace, rbrace,

        // Variable / function syntax
        dollar, colon, semicolon, comma,

        // Keywords
        and_kw, or_kw, not_kw, true_kw, false_kw,
        def_kw, as_kw, reduce_kw,

        // Conditional keywords
        if_kw, then_kw, elif_kw, else_kw, end_kw,

        // Strings
        string_lit,

        // Format strings & interpolation
        at, string_part, string_end,

        // Alternative
        double_slash,

        // Try / catch
        try_kw, catch_kw,

        // Label / break
        label_kw, break_kw,

        // Optional postfix
        question,

        // Assignment operators
        eq_assign, pipe_eq, plus_eq, minus_eq,
        star_eq, slash_eq, percent_eq, double_slash_eq,
    };

    /// Recover the source bytes covered by this token.
    pub fn slice(tok: Token, src: []const u8) []const u8;
};

/// Lexer handle. Owns nothing — `src` is borrowed for the lexer's
/// lifetime. Construct fresh for each parse; `Lexer` values are cheap.
pub const Lexer = struct {
    src: []const u8,
    pos: u32,

    /// Construct a lexer at the start of `src`.
    pub fn init(src: []const u8) Lexer;

    /// Return the next token without consuming it. Implemented by
    /// snapshotting `pos`, calling `next`, and restoring.
    pub fn peek(l: *Lexer) ZqError!Token;

    /// Consume and return the next token. Skips ASCII whitespace and
    /// `# ... \n` line comments. Returns `.eof` (with `len == 0`) at
    /// end of buffer; never advances past `eof`.
    pub fn next(l: *Lexer) ZqError!Token;

    /// Resume scanning string content after the parser has consumed the
    /// closing `)` of a `\(...)` interpolation. Returns either another
    /// `.string_part` (followed by another interpolation) or `.string_end`
    /// (followed by the closing `"`). The parser drives this hook directly
    /// — calling `next` would re-tokenize from scratch and miss the
    /// in-flight string state.
    pub fn scanStringTail(l: *Lexer) ZqError!Token;
};
```

### Functions

| Function              | Signature                          | Description                                                              |
|-----------------------|------------------------------------|--------------------------------------------------------------------------|
| `Lexer.init`          | `[]const u8 → Lexer`               | Wrap a source buffer; non-owning.                                        |
| `Lexer.peek`          | `*Lexer → ZqError!Token`           | Look at the next token without advancing.                                |
| `Lexer.next`          | `*Lexer → ZqError!Token`           | Consume and return the next token; emits `.eof` past end of buffer.      |
| `Lexer.scanStringTail`| `*Lexer → ZqError!Token`           | Resume string scan after an interpolation close-paren.                   |
| `Token.slice`         | `Token, []const u8 → []const u8`   | Recover the source bytes a token covers.                                 |

### Errors

| Error              | When                                                                                                   |
|--------------------|--------------------------------------------------------------------------------------------------------|
| `QuerySyntaxError` | `!` not followed by `=`; unterminated `"..."`; `\` at end of buffer; malformed numeric literal (no digit after `.` / `e` / `E`); any byte that doesn't begin a recognized token. |

The lexer never raises `OutOfMemory` — it allocates nothing.

---

## Constraints & Invariants

- **Zero allocation.** No state is heap-allocated. The lexer is a
  `(src_ptr, pos)` pair. `Token` carries `(tag, offset, len)` only; the
  source slice must outlive every consumed `Token`.
- **`Span` offsets are UTF-8 bytes.** Identical to `ast.Span` semantics.
  LSP consumers must convert to UTF-16 code units via
  `lsp/protocol.byteOffsetToPosition`.
- **`peek` is non-mutating.** Implemented as `(saved = pos; tok = next(); pos = saved)`,
  so calling `peek` twice in a row returns the same token without
  side effects. Repeatedly peeking is O(token-length) each time — the
  parser keeps a one-token lookahead instead of relying on this.
- **String interpolation requires the parser's collaboration.** When
  `next` encounters a `\(` inside `"..."`, it returns `.string_part`
  covering the bytes between the opening `"` and the `\` and leaves
  `pos` pointing one byte past the `(`. The parser then parses the
  interpolation expression and calls `scanStringTail` after consuming
  the closing `)`. The lexer alone CANNOT lex a string with
  interpolations correctly — `next` will desynchronize.
- **Comments are jq-style only.** `#` to end-of-line. No block comments,
  no nested comments. Inside a `"..."` string `#` is just a byte.
- **Identifiers are ASCII.** `[a-zA-Z_][a-zA-Z0-9_]*` exactly. UTF-8
  identifiers are not jq syntax and the lexer will reject the leading
  byte with `QuerySyntaxError`.
- **`eof` is sticky.** Once `pos >= src.len`, `next` returns `.eof`
  forever; it never advances past the end. Useful for the parser's
  recovery paths.
- **Not thread-safe.** Mutates `pos` on every call. Each tokenization
  uses its own `Lexer` value; concurrent lexes on independent buffers
  are fine because they share no state.

---

## Dependencies

- `src/error/root.zig` — `ZqError` (`QuerySyntaxError` raise)
- stdlib only beyond that: `std.ascii`, `std.mem.eql`
