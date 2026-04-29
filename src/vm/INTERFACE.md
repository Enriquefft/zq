# Module: vm

## Purpose
Stack-based bytecode interpreter for compiled jq filters. Public surface is
intentionally tiny: callers see a single lazy `ResultIterator` plus the two
value types it consumes (`StackValue`, `ExternalVarBinding`). Everything else
— opcode dispatch, fork stack, runtime tape, regex caches, path tracking —
is module-private.

The iterator is the contract used by `query.CompiledQuery.execute`, the
C ABI in `src/c_api/`, the microbench rig, and the test suites. Its
lifecycle (`init` → `reset`* → `next`* → `deinit`) is the reuse pattern
that makes per-record overhead allocation-free.

---

## Public Interface

### Types

```zig
const std = @import("std");
const types = @import("types");
const regex_mod = @import("regex");

pub const Value = types.Value;
pub const Tape  = types.Tape;

/// A value on the evaluation stack. Numeric and immediate values inline;
/// objects, arrays, and strings are carried as `Value` views into the
/// (input or runtime) tape.
pub const StackValue = union(enum) {
    null_val,
    bool_val: bool,
    int: i64,
    float: f64,
    /// A view into the Tape for objects/arrays/strings.
    tape_value: Value,
};

/// Binding of an external variable (by compiler-assigned ID) to a concrete
/// value. The compiler assigns ids positionally from the
/// `ExternalVarDecl[]` passed to `compile`; bindings re-use those ids.
pub const ExternalVarBinding = struct {
    var_id: u32,
    value:  StackValue,
};

/// Lazy execution state. Yields one output `Value` per `next()` call. NOT
/// thread-safe. MUST NOT be moved after `init` returns: `Value.TapeSpan`
/// pointers reference `&self.tape`.
pub const ResultIterator = struct {
    /// Allocate every internal stack/store and bind the iterator to a
    /// (compiled-filter, input-tape) pair. `init` is the only allocating
    /// step in the lifecycle — `value_stack`, `variable_store`, fork
    /// stack, runtime tape, and per-pool regex clone slots are all sized
    /// here. Production code creates one iterator per query and uses
    /// `reset()` between records to amortize this cost.
    pub fn init(
        instructions:       []const Instruction,
        function_table:     []const types.FunctionDef,
        string_buf:         []const u8,
        opts_allow_null:    bool,
        tape:               Tape,
        external_bindings:  []const ExternalVarBinding,
        source_map:         []const u32,
        regex_pool:         ?*const regex_mod.RegexPool,
        allocator:          std.mem.Allocator,
    ) error{OutOfMemory}!ResultIterator;

    /// Rebind this iterator to a new tape from the SAME compiled filter.
    /// Zero allocations: every internal buffer retains its capacity.
    /// Returns to the initial state, ready for a new `next()` loop.
    /// MUST be called only when the previous run is complete (next()
    /// returned null or an error, or the caller decided to abandon).
    /// MUST NOT be called after `deinit`.
    pub fn reset(it: *ResultIterator, tape: Tape, external_bindings: []const ExternalVarBinding) void;

    /// Advance and return the next output value, or `null` when complete.
    /// Returned `Value`s are views into either the input tape or the
    /// iterator's runtime tape — both must outlive the value's use.
    pub fn next(it: *ResultIterator) ZqError!?Value;

    /// Free every internal stack, the runtime tape, the per-pool regex
    /// clones, and the dynamic regex LRU. Idempotent: safe to call after
    /// any `next()` outcome, including error.
    pub fn deinit(it: *ResultIterator) void;
};
```

### Errors

| Error           | When                                                                                                  |
|-----------------|-------------------------------------------------------------------------------------------------------|
| `OutOfMemory`   | `init`: any of the eight pre-sized stacks, the runtime tape, or the regex-clone slot array.           |
| `ZqError.*`     | `next`: surfaces every runtime error class — `TypeError`, `UserError`, `RegexInternalError`, etc.     |

---

## Constraints & Invariants

- **`init` allocates; `reset` does not.** `init` ensures capacity on every
  internal stack (value, variable, fork, collect, call, path, object
  construct ×3, runtime tape, regex-clone slots). `reset` clears with
  `clearRetainingCapacity` and re-injects external bindings. The
  `init`-once / `reset`-per-record pattern is the production model — see
  `src/microbench/main.zig:262-297` `measureCoord` for the canonical
  shape (one `init` outside the hot loop, `reset(tape, &.{})` inside).
- **Iterator must not be moved after `init`.** `Value.TapeSpan.tape`
  pointers reference `&self.tape`; relocating the struct invalidates
  every outstanding `Value`. Store on the heap or in a stable slot.
- **Yielded `Value`s borrow from the iterator.** A `Value` returned from
  `next()` may point into `self.tape` (input) OR `self.runtime_tape`
  (constructed objects/arrays/strings). Both are owned by the iterator.
  Consumers must serialize / copy before the next `next()` call if they
  need to retain the value beyond one step — `reset()` and the next
  `next()` may reuse runtime-tape slots.
- **`reset` requires a "same-shape" tape.** The new tape is a different
  input record for the same compiled filter. The instructions, function
  table, string buffer, regex pool, and allocator are NOT changeable
  across `reset` — for a different filter, deinit and init a new
  iterator.
- **`reset` keeps regex caches.** Per-pool clones and the dynamic-regex
  LRU survive reset because the compiled filter (and its regex pool) is
  unchanged between iterator runs. Recompiling would be pure waste.
- **`deinit` is idempotent on the contained sub-stacks** but not on the
  iterator itself; do not call it twice. It walks the live fork stack
  to release saved snapshots and dynamic-regex fork slots, so it must
  be called even after an error return from `next`.
- **`regex_pool` is borrowed.** The pool is owned by the `Compiled`
  artifact that produced the filter. Pass `null` only in unit tests
  that short-circuit the pool — every regex builtin will then error
  cleanly via the pool-index path.
- **Variable slots are bounded by `max_value_stack`.** External var ids
  beyond that bound are silently ignored on inject. The compiler is
  trusted to keep ids in range.
- **Not thread-safe.** Each thread / worker that wants concurrent
  execution must hold its own iterator. The iterator owns its arena,
  its regex clones, and its dynamic-regex LRU — sharing any of those
  across threads is undefined behavior.

---

## Dependencies

- `src/types.zig`        — `Value`, `Tape`, `RuntimeTape`, `FunctionDef`
- `src/regex/root.zig`   — `RegexPool`, `RegexClone`, `cache.LruCache`
- `src/error/root.zig`   — `ZqError`
- stdlib only beyond that: `std.ArrayList`, `std.mem.Allocator`
