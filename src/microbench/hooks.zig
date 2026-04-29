//! Comptime-gated hook interface for the per-stage microbench (Phase 0).
//!
//! Production modules that need to mark a phase boundary import this file and
//! call `markPhase(.<tag>)`. When the `-Dprofile=true` build flag is set, the
//! call resolves to a real counter increment; when the flag is unset (the
//! default) the function body is `comptime return;` and the compiler erases
//! the call site entirely.
//!
//! The harness itself (`src/microbench/main.zig`) does NOT need these hooks —
//! it measures phase boundaries from outside by driving the production modules
//! directly. The hooks exist so future in-flight probes inside a hot loop
//! (e.g. attributing time to a specific VM opcode dispatch) have a stable API
//! that costs zero when disabled.
//!
//! Single source of truth: the `profile_enabled` flag is read from
//! `build_options` exactly once here. Callers never touch `build_options`
//! directly for this purpose.

const std = @import("std");
const build_options = @import("build_options");

/// Compile-time flag: true when `-Dprofile=true` was passed to `zig build`.
/// When false, every function in this module is a comptime no-op.
pub const enabled: bool = build_options.profile_enabled;

/// Named phases the harness tracks. Mirrors `src/microbench/DESIGN.md`.
pub const PhaseTag = enum(u8) {
    parse_begin,
    parse_end,
    lookup_begin,
    lookup_end,
    predicate_begin,
    predicate_end,
    serialize_begin,
    serialize_end,
    coord_begin,
    coord_end,
};

/// Per-phase counter array. Indexed by `@intFromEnum(PhaseTag)`.
/// Thread-local so concurrent workers don't contend on a single cache line.
/// Only accessed when `enabled` is true; otherwise the variable is never
/// referenced and the linker drops it.
threadlocal var counters: [@typeInfo(PhaseTag).@"enum".fields.len]u64 = @splat(0);

/// Mark the occurrence of a named phase boundary.
///
/// `-Dprofile=false` (default): the body reduces to `comptime return;` and
/// every call site disappears at compile time. Production binary unchanged.
///
/// `-Dprofile=true`: increments the thread-local counter for `tag`. The
/// harness can poll counters via `read` / `reset` between measured passes.
pub inline fn markPhase(comptime tag: PhaseTag) void {
    if (comptime !enabled) return;
    counters[@intFromEnum(tag)] +%= 1;
}

/// Return the current counter value for `tag` on this thread. Returns 0 when
/// the profile flag is disabled.
pub fn read(tag: PhaseTag) u64 {
    if (comptime !enabled) return 0;
    return counters[@intFromEnum(tag)];
}

/// Reset every thread-local counter to 0. No-op when disabled.
pub fn reset() void {
    if (comptime !enabled) return;
    counters = @splat(0);
}
