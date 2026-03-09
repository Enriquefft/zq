# Module: parser

## Purpose
Convert raw byte slices from the IO module into a linear `Tape` (Structural Index).
Implements a streaming state machine: `feed()` may be called repeatedly as chunks arrive
from `Source.peek()`, accumulating parse state across calls. Handles UTF-8 validation,
number parsing, and incomplete-JSON auto-recovery for truncated LLM streams.

The Tape format (`types.Tape`) is a flat array of opcode+payload entries — no hash maps,
no pointer chasing — enabling O(1) value skipping and minimal cache misses for the Query
module that consumes it.

---

## Public Interface

### Types

```zig
const err   = @import("error");
const types = @import("types");

pub const ZqError = err.ZqError;
pub const Tape    = types.Tape;

/// The outcome of a single `feed()` call.
pub const FeedResult = union(enum) {
    /// A complete, top-level JSON value was parsed.
    /// `tape` is a non-owning view into parser-internal memory;
    /// valid until the next `reset()` or `deinit()` call.
    done: Tape,

    /// The bytes consumed so far are valid JSON, but the value is not yet complete.
    /// Call `feed()` again with the next chunk from `Source`.
    need_more,
};

pub const Parser = struct {
    /// Allocate internal buffers (tape entries, string bytes, structural stack).
    /// Call once; reuse the Parser across records via `reset()`.
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Parser;

    /// Release all internally-owned memory. Do not call `feed()` after this.
    pub fn deinit(p: *Parser) void;

    /// Feed a byte chunk into the parser state machine.
    ///
    /// `is_eof` must be `true` on the final chunk for a given record, and only
    /// then. Passing `is_eof = false` when the source is actually exhausted
    /// produces `UnexpectedEof` on the next call.
    ///
    /// Returns:
    ///   `.done(tape)` — a complete JSON value was parsed. `tape` is valid until `reset()`.
    ///   `.need_more`  — valid so far but incomplete; call again with the next chunk.
    ///   error.*       — malformed JSON; call `reset()` before reusing the Parser.
    ///
    /// Auto-Close: when `is_eof = true` and the structural stack is non-empty
    /// (truncated JSON such as `{"a":1`), the parser synthetically closes all
    /// open containers and returns `.done` rather than an error. The only
    /// exception is an unterminated string literal, which cannot be closed
    /// safely — that always returns `error.UnterminatedString`.
    pub fn feed(
        p:      *Parser,
        input:  []const u8,
        is_eof: bool,
    ) (ZqError || error{OutOfMemory})!FeedResult;

    /// Reset cursor and entry counts for the next record. Reuses all allocations.
    /// Invalidates any `Tape` previously returned from `.done`.
    /// Idempotent and infallible.
    pub fn reset(p: *Parser) void;
};
```

### Functions

| Function       | Signature                                                  | Description                                                                      |
|----------------|------------------------------------------------------------|----------------------------------------------------------------------------------|
| `Parser.init`  | `allocator → error{OutOfMemory}!Parser`                   | Allocates tape buf, string buf, structural stack with initial capacities.        |
| `Parser.deinit`| `*Parser → void`                                           | Frees all internal allocations; safe to call in `defer` immediately after init.  |
| `Parser.feed`  | `*Parser, []const u8, bool → (ZqError\|\|OOM)!FeedResult` | Tokenize chunk, update state machine, emit Tape entries or signal need-more.     |
| `Parser.reset` | `*Parser → void`                                           | Resets state for next record without freeing; reuses backing memory.             |

### Errors

| Error                  | Condition                                                                                          |
|------------------------|----------------------------------------------------------------------------------------------------|
| `UnexpectedToken`      | Character is not valid at the current parse position (e.g. `{1}`, `[,]`, trailing `,` before `}`). |
| `UnexpectedEof`        | `is_eof = true` but the current value is incomplete and not recoverable via Auto-Close (e.g. bare `,`, `:` without a value). |
| `InvalidUtf8`          | Byte sequence inside a string is not valid UTF-8.                                                  |
| `InvalidNumber`        | Malformed numeric literal: `1.2.3`, `1e`, `--1`, `0123`.                                          |
| `UnterminatedString`   | `is_eof = true` with an open string (`"`). Auto-Close does **not** apply to strings.              |
| `DepthLimitExceeded`   | Structural nesting exceeds 512 levels (`{` / `[` stack overflow).                                 |
| `error{OutOfMemory}`   | Internal tape or string buffer could not grow (extremely large input).                             |

---

## Dependencies

- `src/error/root.zig` — `ZqError` for propagation
- `src/types.zig`      — `Tape`, `Tape.Entry`, `Tape.Tag`, `Tape.Payload`, `Tape.StringRef`

---

## Constraints & Invariants

- **No allocation on the hot path.** All buffers are pre-allocated in `init()`. Buffer growth
  (via the stored allocator) may happen at most logarithmically if input exceeds initial
  capacity; growth is not expected for typical JSON records.
- **`Tape` is non-owning.** The slice fields (`entries`, `string_buf`) point into
  parser-internal memory. The caller must not retain them across `reset()` or `deinit()`.
  This matches the non-ownership convention of `SliceView` (io) and `snippet` (error).
- **Auto-Close scope.** Only structural containers (`{` / `[`) are auto-closed. An
  unterminated string always returns `error.UnterminatedString`; a dangling `:` or `,`
  always returns `error.UnexpectedEof`.
- **Depth limit is 512.** The structural stack is fixed at 512 slots. `DepthLimitExceeded`
  is returned on the 513th `{` or `[`.
- **SIMD is a hidden implementation detail.** The parser uses AVX2 (x86-64) or NEON
  (AArch64) to scan 64-byte chunks for structural characters. The public interface is
  platform-independent; callers observe no difference.
- **`reset()` is idempotent and infallible.** It zeros entry/byte counts and clears the
  structural stack; it does not free or reallocate memory.
- **`Parser` is not thread-safe.** Each worker thread must own its own `Parser` instance.
  The Worker Pool creates one Parser per thread.
- **`ZqError` and `ErrorKind` parity.** No new `ZqError` variants are added by this module;
  all errors raised by parser are already present in the error module's set.
