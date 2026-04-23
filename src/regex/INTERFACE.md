# Module: regex

## Purpose
Zig-side wrapper over the `zq-regex-shim` static Rust library. Provides compiled
`Regex` values, per-worker `RegexClone` search handles, a Sparser-style literal
prefilter set, a filter-compile-time interning pool, and a runtime LRU for
dynamic patterns built by `test($var)`-style filters.

Every FFI call is guarded by the shim's `catch_unwind`: a Rust panic surfaces as
`error.RegexInternalError` with the message retrievable via `lastError(&buf)`.

When the build flag `-Dregex=false`, every type collapses to a compile-time
stub whose methods return `error.RegexNotCompiled`; callers stay source-compatible
and the Rust shim is not linked.

---

## Public Interface

### Types

```zig
const std = @import("std");

/// True when built with `-Dregex=true` (default). When false, every public
/// method returns `Error.RegexNotCompiled` and no shim is linked.
pub const enabled: bool;

pub const Error = error{
    RegexNotCompiled,
    RegexCompileFailed,
    RegexInternalError,
    OutOfMemory,
};

/// Suggested stack-buffer size for `lastError`.
pub const error_buffer_size: usize = 512;

/// Layout-compatible with the Rust `ZqMatchSlot`. One byte-range per capture
/// group, slot 0 = full match. Optional groups that did not participate
/// receive `start == SLOT_UNMATCHED`.
pub const MatchSlot = extern struct {
    start: usize,
    end: usize,
};
pub const SLOT_UNMATCHED: usize = std.math.maxInt(usize);

/// Immutable compiled regex. Sync: may be shared across threads.
/// Each thread that actually searches must obtain its own `RegexClone`.
pub const Regex = struct {
    pub fn compile(pattern: []const u8) Error!Regex;
    pub fn deinit(self: *Regex) void;
    pub fn captureCount(self: Regex) usize;
    pub fn groupName(self: Regex, idx: usize) ?[]const u8;
    pub fn groupIndexByName(self: Regex, name: []const u8) ?usize;
    pub fn clone(self: Regex) Error!RegexClone;
    /// Borrow the shim's cached literal set. Lifetime tied to `self`.
    pub fn requiredLiterals(self: Regex) ?Literals;
};

/// Per-worker search handle. NOT Sync — owns internal scratch state.
/// Cheap to construct (Arc bump + fresh Cache); still worth amortizing
/// over a whole chunk.
pub const RegexClone = struct {
    pub fn deinit(self: *RegexClone) void;
    pub fn isMatch(self: RegexClone, hay: []const u8) Error!bool;
    pub fn find(self: RegexClone, hay: []const u8, start: usize) Error!?Match;
    pub fn findCaptures(self: RegexClone, hay: []const u8, start: usize, slots: []MatchSlot) Error!bool;
    /// Scan-style iterator. Advances `cursor` past each match; returns
    /// `false` when exhausted. Zero-width matches bump `cursor` by one
    /// UTF-8 boundary, so looping is bounded.
    pub fn iterNext(self: RegexClone, hay: []const u8, cursor: *usize, slots: []MatchSlot) Error!bool;

    pub const Match = struct { start: usize, end: usize };
};

/// Prefilter literal set. Borrowed from the parent `Regex`; never freed
/// independently.
///
/// `isExhaustive() == true`  → every literal must appear (AND).
/// `isExhaustive() == false` → at least one literal must appear (OR).
/// In both cases, a negative answer proves the regex cannot match — zero
/// false negatives, bounded false positives. This is the Sparser contract.
pub const Literals = struct {
    pub fn count(self: Literals) usize;
    pub fn at(self: Literals, idx: usize) []const u8;
    pub fn isExhaustive(self: Literals) bool;
};

/// Read the shim's thread-local last-error into `buf`. Returns the written
/// slice (no null terminator). Empty when regex is disabled.
pub fn lastError(buf: []u8) []const u8;

/// Filter-compile-time regex interner. Each distinct pattern compiles
/// exactly once; `intern` returns a stable `u32` id the VM embeds in the
/// opcode payload. Owned by `CompiledQuery`.
pub const cache.RegexPool = struct {
    pub fn init(allocator: std.mem.Allocator) RegexPool;
    pub fn deinit(self: *RegexPool) void;
    pub fn intern(self: *RegexPool, pattern: []const u8) Error!u32;
    pub fn get(self: *const RegexPool, idx: u32) *const Regex;
    pub fn len(self: *const RegexPool) usize;
};

/// Bounded LRU for dynamic patterns. Each entry bundles a `Regex` and its
/// per-iterator `RegexClone`; eviction frees both in lockstep. Not Sync —
/// one instance per `ResultIterator`.
pub fn cache.LruCache(comptime cap: u32) type; // produces:

pub const cache.DynamicEntry = struct {
    regex: *Regex,
    clone: *RegexClone,
};
// Methods on LruCache(cap):
//   init(allocator)         → Self
//   deinit(self)            → void
//   getOrCompile(pattern)   → Error!DynamicEntry   — promotes MRU, evicts on overflow
//   size(self)              → u32
//   contains(self, pattern) → bool                  (test helper)
```

### Errors

| Error                 | Condition                                                                              |
|-----------------------|----------------------------------------------------------------------------------------|
| `RegexNotCompiled`    | Any call in a `-Dregex=false` build.                                                   |
| `RegexCompileFailed`  | `Regex.compile` rejected the pattern. Diagnostic in `lastError`.                       |
| `RegexInternalError`  | Shim returned an unexpected code or caught a Rust panic. Message in `lastError`.       |
| `OutOfMemory`         | `RegexPool.intern` / `LruCache.getOrCompile`: key dup, entries array, or hashmap grow.|

---

## Constraints & Invariants

- **`Regex` is Sync; `RegexClone` is not.** The shim's `regex_automata` search
  state is per-worker. Sharing a clone between threads is undefined behavior.
- **`Literals` lifetime ≤ `Regex` lifetime.** The handle aliases memory inside
  the parent `ZqRegex`; there is no separate free routine. Must not outlive
  the regex that produced it, and therefore must not outlive the `RegexPool`
  that owns that regex.
- **`RegexPool` owns both the pattern-key strings and the compiled entries.**
  `intern` duplicates the caller's `pattern` slice so transient buffers are safe.
  Returned `u32` indices are stable for the lifetime of the pool. `get` panics
  on out-of-range input; the VM emits indices from `intern` and is trusted.
- **`LruCache` capacity is the comptime `cap` parameter.** The roadmap default
  is 64. On overflow the tail (LRU) entry is evicted: its `Regex`, `RegexClone`,
  and key bytes are freed in a single pass — no external hooks, no parallel
  keyed-by-pointer store. `DynamicEntry` pointers are stable until that entry
  is evicted or the cache is deinit'd.
- **`OffsetCursor` (in `offset.zig`) is forward-only for scan/iter.** Going
  backward is correct but triggers a full rescan from zero. `scan` on large
  haystacks relies on the monotonic path to stay linear.
- **Byte ≠ character.** `find` / `findCaptures` / `iterNext` return **byte**
  offsets. jq's `match/capture/scan` report character offsets (Unicode scalars);
  `offset.byteToChar` / `OffsetCursor.charAt` convert. Invalid UTF-8 is counted
  leniently (lead-byte count) — never panics.
- **Panic safety is the shim's contract, not Zig's.** The shim is built with
  `panic = "unwind"` plus `catch_unwind` on every `extern "C"` entry. Every
  non-success return is mapped to `RegexInternalError`; the panic message is
  parked in a thread-local and retrieved via `lastError`.
- **Disabled-build stubs have `@sizeOf > 0`.** `DisabledRegex` and
  `DisabledRegexClone` carry a one-byte placeholder because Zig 0.15's
  `std.ArrayList` / `std.StringHashMap` capacity math divides by element
  size at comptime; a zero-sized element type crashes the stdlib.

---

## Dependencies

- `third_party/zq-regex-shim` — static Rust library (linked when `enabled`)
- `build_options` — comptime `regex_enabled` flag
- stdlib only: `std.ArrayList`, `std.StringHashMap`, `std.heap`, `std.mem`
