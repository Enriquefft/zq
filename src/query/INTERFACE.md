# Module: query

## Purpose
Compile text filter expressions (jq-compatible subset) into a bytecode `CompiledQuery`,
then execute that bytecode against a `Tape` produced by the parser module.

A single `CompiledQuery` is immutable and reusable across many `Tape` inputs. Each call
to `execute` produces an independent `ResultIterator`; a filter may yield 0..N output
values (e.g. `.[]` on a 5-element array yields 5).

---

## Public Interface

### Types

```zig
const std   = @import("std");
const err   = @import("error");
const types = @import("types");

pub const ZqError = err.ZqError;
pub const Tape    = types.Tape;
pub const Value   = types.Value;

/// Compilation options. All fields have safe defaults.
pub const Opts = struct {
    /// When true, two specific non-error conditions propagate as null instead of error:
    ///   1. Missing key on an object: `.foo` where key "foo" is absent → null.
    ///   2. Field access on a null value: `.foo.bar` where `.foo` is null → null.
    ///
    /// All other type mismatches remain hard errors regardless of this flag:
    ///   - Key lookup on a non-object (array, number, …) → TypeError.
    ///   - Iteration (.[]) on a non-array                → TypeError.
    ///   - Array index on a non-array                    → TypeError.
    ///
    /// This matches the semantics of jq's `?` suffix applied globally.
    /// Default: false (strict).
    allow_null_propagation: bool = false,
};

/// An immutable compiled filter. Thread-safe for concurrent execute() calls.
/// Owns its bytecode buffer and string-intern table; must be freed via deinit().
/// Follows the same init/deinit convention as Parser.
pub const CompiledQuery = struct {
    /// Compile `src` into bytecode using `allocator`.
    /// The allocator is stored internally and used by deinit().
    ///
    /// Returns:
    ///   CompiledQuery   — compilation succeeded.
    ///   QuerySyntaxError — malformed filter: bare `|`, trailing `.`,
    ///                      unbalanced `(` / `[` / `{`, unknown operator, etc.
    ///   OutOfMemory      — bytecode or intern buffer allocation failed.
    pub fn compile(
        src:       []const u8,
        opts:      Opts,
        allocator: std.mem.Allocator,
    ) (ZqError || error{OutOfMemory})!CompiledQuery;

    /// Free bytecode buffer and string-intern table.
    /// Safe to call in `defer` immediately after compile.
    pub fn deinit(q: *CompiledQuery) void;

    /// Bind `tape` to this query and allocate an eval stack for iteration.
    /// `tape` and `q` must both outlive the returned ResultIterator.
    /// Only the eval stack is allocated here — no execution occurs yet.
    pub fn execute(
        q:         *const CompiledQuery,
        tape:      Tape,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!ResultIterator;
};

/// Lazy execution state. One per execute() call. Not thread-safe.
pub const ResultIterator = struct {
    /// Free the internal eval stack.
    /// Idempotent and infallible. Safe to call after any error from next().
    pub fn deinit(it: *ResultIterator) void;

    /// Advance the VM and return the next output value.
    ///
    /// Returns:
    ///   .{value}          — a non-owning view into the Tape passed to execute().
    ///                       Valid until the Tape is freed; not invalidated by next().
    ///   null              — iteration complete; no more values. Call deinit().
    ///   TypeError         — operation applied to the wrong JSON type (always fatal).
    ///   IndexOutOfBounds  — array index beyond array length (always fatal).
    ///
    /// After any error the iterator is spent; call deinit() and discard it.
    pub fn next(it: *ResultIterator) ZqError!?Value;
};
```

### Functions

| Function                 | Signature                                                               | Description                                                          |
|--------------------------|-------------------------------------------------------------------------|----------------------------------------------------------------------|
| `CompiledQuery.compile`  | `[]const u8, Opts, Allocator → (ZqError\|\|OOM)!CompiledQuery`         | Lex, parse, optimize the filter. Returns bytecode or syntax error.  |
| `CompiledQuery.deinit`   | `*CompiledQuery → void`                                                 | Free bytecode buffer and string-intern table.                        |
| `CompiledQuery.execute`  | `*const CompiledQuery, Tape, Allocator → OOM!ResultIterator`            | Allocate eval stack. No execution yet.                               |
| `ResultIterator.deinit`  | `*ResultIterator → void`                                                | Free the eval stack. Idempotent.                                     |
| `ResultIterator.next`    | `*ResultIterator → ZqError!?Value`                                      | Step the VM; yield next output value, null when done, or an error.  |

### Errors

| Error               | Phase   | Condition                                                                          |
|---------------------|---------|------------------------------------------------------------------------------------|
| `QuerySyntaxError`  | Compile | Malformed filter: bare `\|`, trailing `.`, unbalanced delimiters, unknown operator.|
| `TypeError`         | Execute | Operation on wrong JSON type: key on array, iterate a number, etc. Never silenced.|
| `IndexOutOfBounds`  | Execute | Array index beyond array length. Never silenced.                                   |
| `OutOfMemory`       | Both    | Bytecode buffer or eval-stack allocation failed.                                   |

*(Other `ZqError` variants are not raised by this module.)*

---

## Dependencies

- `src/error/root.zig` — `ZqError` (`QuerySyntaxError`, `TypeError`, `IndexOutOfBounds`)
- `src/types.zig`      — `Tape`, `Value`, `Instruction` (bytecode format, `Op`, `Operand`)

---

## Constraints & Invariants

- **`CompiledQuery` is immutable after compile.** Multiple threads may call `execute`
  concurrently on the same `CompiledQuery`; each `ResultIterator` is fully independent.
- **`Value` is non-owning.** All values from `next()` are views into the `Tape` passed to
  `execute`. The Tape must outlive the iterator. This matches the non-ownership convention
  shared by `snippet` (error), `SliceView` (io), and `Tape` itself.
- **Eval stack depth limit is 512.** Matches the parser's structural depth limit.
  `DepthLimitExceeded` is returned if nesting exceeds this during execution.
- **Iterator is single-use.** After `next()` returns `null` or any error, the iterator is
  spent. Call `deinit()` and discard.
- **Fuse pass is an implementation detail.** `.a | .b` compiles internally to a single
  `OP_LOAD_PATH "a.b"` instruction (`types.Instruction.Op.load_path`). Callers observe no
  difference; the `Instruction` type in `types.zig` documents this as a possible opcode.
- **`allow_null_propagation` scope is narrow.** Only missing-key-on-object and
  field-access-on-null are suppressed. All other type errors are unconditional.
- **`execute` allocates only the eval stack.** The bound `Tape` is read-only; no copies
  are made of tape entries or string bytes during iteration.
- **`ZqError` and `ErrorKind` parity.** This module raises only variants already present
  in the error module; it adds no new variants of its own.
