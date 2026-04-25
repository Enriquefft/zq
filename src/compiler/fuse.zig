//! IR rewrite passes — Phase 2R / R3.
//!
//! Phase 5 ships an identity pass: `fuse(input) == input`. R3 lands the
//! rewrite rules listed in plan §1.3 row 6 (load_path fold, `keys | length`
//! → `key_count`, etc.) and emits `EmitOp` nodes (currently a reserved-but-
//! empty namespace; see `ir.zig`'s `Op` enum comment).
const std = @import("std");
const ir = @import("ir.zig");

/// Apply fuse passes to `input`. Phase 5 returns the input unchanged so the
/// scaffold pipeline (`lower → fuse → emit`) type-checks end-to-end.
///
/// TODO(R3): real rewrites will consume `arena` to allocate replacement
/// nodes; the parameter is retained today to fix the eventual signature.
pub fn fuse(
    arena: *std.heap.ArenaAllocator,
    input: ir.IR,
) error{OutOfMemory}!ir.IR {
    _ = arena;
    return input;
}
