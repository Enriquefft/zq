//! IR rewrite passes — Phase 2R / R3.
//!
//! Phase 7 ships an identity pass: `fuse(input) == input`. R3 lands the
//! rewrite rules listed in plan §1.3 row 6 (load_path fold, `keys | length`
//! → `key_count`, etc.) and emits `EmitOp` nodes (currently a reserved-but-
//! empty namespace; see `ir.zig`'s `Op` enum comment).
const std = @import("std");
const ir = @import("ir.zig");

/// Apply fuse passes to `input`. Phase 7 returns the input unchanged so
/// the lowering→emit chain has a stable seam for later passes (`load_path`
/// fold, `keys|length` → `key_count`).
pub fn fuse(
    input: ir.IR,
) error{OutOfMemory}!ir.IR {
    return input;
}
