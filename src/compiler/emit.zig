//! IR → bytecode emission — Phase 2R / R3.
//!
//! Phase 5 returns `error.NewCompilerNotImplemented`. R3 lands per-operator-
//! category emission and refines the return type to a real `CompileResult`-
//! shaped value (see TODO below). The legacy emitter remains the production
//! path until Phase 6+ flips the default backend.
const std = @import("std");
const ir = @import("ir.zig");

/// Emit bytecode from `input` IR. Phase 5 placeholder.
///
/// TODO(R3): return type tightens to `error{OutOfMemory}!CompileResult`
/// once R3 wires emission into `query.CompiledQuery.compile`. The Phase 5
/// `void` return is deliberate — keeping the success branch out of the
/// signature avoids importing `query` into `compiler` (circular module
/// graph: `query` already imports `compiler`).
pub fn emit(
    arena: *std.heap.ArenaAllocator,
    input: ir.IR,
    allocator: std.mem.Allocator,
) error{ NewCompilerNotImplemented, OutOfMemory }!void {
    _ = arena;
    _ = input;
    _ = allocator;
    return error.NewCompilerNotImplemented;
}
