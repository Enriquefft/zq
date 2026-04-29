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
const regex = @import("regex");

pub const ZqError             = err.ZqError;
pub const Tape                = types.Tape;
pub const Value               = types.Value;

// Re-exports (see `src/query/root.zig` for canonical list):
pub const PrefilterSet        = prefilter.PrefilterSet;
pub const ExternalVarDecl     = compiler.ExternalVarDecl;
pub const ExternalVarBinding  = vm.ExternalVarBinding;
pub const StackValue          = vm.StackValue;

/// Compilation result: either a ready CompiledQuery or a structured
/// compile error with source location. See `error.CompileError`.
pub const CompileResult = union(enum) {
    ok:  CompiledQuery,
    err: err.CompileError,
};

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

    /// External variable declarations to pre-declare in the root scope
    /// (`--arg` / `--argjson` / `--slurpfile` equivalents).
    external_vars: []const ExternalVarDecl = &.{},
};

/// An immutable compiled filter. Thread-safe for concurrent execute() calls.
/// Owns its bytecode buffer, string-intern table, regex pool, and (optional)
/// prefilter set; all are freed by `deinit()`.
pub const CompiledQuery = struct {
    // …instruction/string/source-map fields elided; see root.zig…

    /// Filter-compile-time regex pool. Owns every `Regex` compiled for a
    /// string-literal pattern in this query. Opcodes reference entries by
    /// `u32` index in the packed `call_builtin` operand.
    regex_pool: regex.RegexPool,

    /// Sparse raw-byte prefilter populated at compile time when the source
    /// matches a shape the parallel chunk worker can prescreen (e.g.
    /// `select(PATH | regex_builtin("lit"))`). `null` otherwise.
    prefilter: ?PrefilterSet,

    /// Compile `src` into bytecode using `allocator`.
    /// The allocator is stored internally and used by deinit().
    ///
    /// Returns a `CompileResult` union:
    ///   .ok(CompiledQuery) — compilation succeeded.
    ///   .err(CompileError) — structured compile error (syntax, regex
    ///                        literal rejected, etc.) with source location.
    ///
    /// Only `error.OutOfMemory` is raised as a Zig error; all other compile
    /// failures are reported via the `.err` branch.
    pub fn compile(
        src:       []const u8,
        opts:      Opts,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!CompileResult;

    /// Free bytecode, string-intern table, regex pool, and prefilter.
    /// Safe to call in `defer` immediately after compile.
    pub fn deinit(q: *CompiledQuery) void;

    /// Bind `tape` to this query and allocate an eval stack for iteration.
    /// `tape`, `q`, and each `ExternalVarBinding` must outlive the iterator.
    /// Only the eval stack is allocated here — no execution occurs yet.
    pub fn execute(
        q:                 *const CompiledQuery,
        tape:              Tape,
        external_bindings: []const ExternalVarBinding,
        allocator:         std.mem.Allocator,
    ) error{OutOfMemory}!ResultIterator;
};

/// Lazy execution state. One per execute() call. Not thread-safe.
pub const ResultIterator = struct {
    /// Free the internal eval stack.
    /// Idempotent and infallible. Safe to call after any error from next().
    pub fn deinit(it: *ResultIterator) void;

    /// Rebind this iterator to a new tape (and refreshed bindings) from the
    /// same query. All internal buffers retain their capacity — zero allocations.
    /// The iterator returns to the initial state, ready for a new next() loop.
    ///
    /// Use this to reuse the same iterator across multiple records (e.g. JSONL),
    /// avoiding the per-record heap allocations that execute() + deinit() incur.
    /// This mirrors the Parser.reset() contract.
    ///
    /// Must be called only when the previous run is complete (next() returned
    /// null or an error) or abandoned. Must NOT be called after deinit().
    pub fn reset(
        it:                *ResultIterator,
        tape:              Tape,
        external_bindings: []const ExternalVarBinding,
    ) void;

    /// Advance the VM and return the next output value.
    ///
    /// Returns:
    ///   .{value}          — a non-owning view into the Tape passed to execute().
    ///                       Valid until the Tape is freed; not invalidated by next().
    ///   null              — iteration complete; no more values. Call deinit() or reset().
    ///   TypeError         — operation applied to the wrong JSON type (always fatal).
    ///   IndexOutOfBounds  — array index beyond array length (always fatal).
    ///
    /// After any error the iterator is spent; call deinit() or reset() before reuse.
    pub fn next(it: *ResultIterator) ZqError!?Value;
};
```

### Functions

| Function                 | Signature                                                                                           | Description                                                                                            |
|--------------------------|-----------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| `CompiledQuery.compile`  | `[]const u8, Opts, Allocator → OOM!CompileResult`                                                   | Run the Phase-2R pipeline: `ast.parse → lower → IR → fuse → emit`. Success → `.ok`; compile failure → `.err` with source location. |
| `CompiledQuery.deinit`   | `*CompiledQuery → void`                                                                             | Free bytecode, string-intern table, regex pool, and prefilter.                                         |
| `CompiledQuery.execute`  | `*const CompiledQuery, Tape, []const ExternalVarBinding, Allocator → OOM!ResultIterator`            | Allocate eval stack and bind external variables. No execution yet.                                     |
| `ResultIterator.deinit`  | `*ResultIterator → void`                                                                            | Free the eval stack. Idempotent.                                                                       |
| `ResultIterator.reset`   | `*ResultIterator, Tape, []const ExternalVarBinding → void`                                          | Rebind to a new tape and bindings; zero allocations. Reuse across JSONL records.                       |
| `ResultIterator.next`    | `*ResultIterator → ZqError!?Value`                                                                  | Step the VM; yield next output value, null when done, or an error.                                     |

### Errors

`QuerySyntaxError` is delivered through `CompileResult.err`, **not** as a Zig
error — `compile()` only raises `OutOfMemory`. Every other variant below is
raised natively through the `ZqError` union returned by `next()`.

| Error                | Phase   | Condition                                                                                   |
|----------------------|---------|---------------------------------------------------------------------------------------------|
| `QuerySyntaxError`   | Compile | Malformed filter: bare `\|`, trailing `.`, unbalanced delimiters, unknown operator. Returned via `.err`. |
| `RegexCompileError`  | Compile | Literal regex pattern rejected by the engine. Returned via `.err`.                         |
| `RegexNotCompiled`   | Execute | `test`/`match`/`scan` invoked while regex support is disabled (`-Dregex=false`).           |
| `RegexInternalError` | Execute | Regex engine raised a runtime/shim error.                                                   |
| `TypeError`          | Execute | Operation on wrong JSON type: key on array, iterate a number, etc.                          |
| `IndexOutOfBounds`   | Execute | Array index beyond array length.                                                            |
| `UserError`          | Execute | `error` builtin invoked by the filter. Message available on the iterator.                   |
| `OutOfMemory`        | Both    | Bytecode buffer, eval-stack, or regex-pool allocation failed.                               |

*(Other `ZqError` variants are not raised by this module.)*

---

## Dependencies

- `src/error/root.zig` — `ZqError`, `CompileError` (used by `CompileResult.err`)
- `src/types.zig`      — `Tape`, `Value`, `Instruction` (bytecode format, `Op`, `Operand`)
- `src/regex/root.zig` — `RegexPool` used for literal-pattern compilation

---

## Constraints & Invariants

- **`CompiledQuery` is immutable after compile.** Multiple threads may call `execute`
  concurrently on the same `CompiledQuery`; each `ResultIterator` is fully independent.
- **`Value` is non-owning.** All values from `next()` are views into the `Tape` passed to
  `execute`. The Tape must outlive the iterator. This matches the non-ownership convention
  shared by `snippet` (error), `SliceView` (io), and `Tape` itself.
- **Eval stack depth limit is 512.** Matches the parser's structural depth limit.
  `DepthLimitExceeded` is returned if nesting exceeds this during execution.
- **Iterator is single-use per binding.** After `next()` returns `null` or any error for a
  given tape, the iterator is spent for that binding. Either call `deinit()` to free all
  resources, or call `reset(new_tape)` to rebind to a new tape with the same query. After
  `reset()`, the iterator starts fresh as if `execute()` had been called again, but without
  any heap allocation. This pattern (init once, reset per record) is identical to `Parser`.
- **Fuse pass is an implementation detail.** `.a | .b` compiles internally to a single
  `OP_LOAD_PATH "a.b"` instruction (`types.Instruction.Op.load_path`). Callers observe no
  difference; the `Instruction` type in `types.zig` documents this as a possible opcode.
- **`allow_null_propagation` scope is narrow.** Only missing-key-on-object and
  field-access-on-null are suppressed. All other type errors are unconditional.
- **`execute` allocates only the eval stack.** The bound `Tape` is read-only; no copies
  are made of tape entries or string bytes during iteration.
- **`ZqError` and `ErrorKind` parity.** This module raises only variants already present
  in the error module; it adds no new variants of its own.
