//! AST → IR lowering — Phase 2R / R3.
//!
//! Phase 5 (this commit) ships only the scaffold; the body returns
//! `error.NewCompilerNotImplemented`. R3 lands per-operator-category
//! lowering rules that match the AST shape produced by `src/ast/parser.zig`.
//! The text-dump shapes that snapshot tests will diff against are pinned in
//! `research/compiler-ir-format.md` §10.
const std = @import("std");
const ir = @import("ir.zig");

/// Lower an AST root into IR. Phase 5 placeholder; real implementation
/// lands per category across Phase 6 + later (plan §3 R3).
///
/// TODO(R3): replace `*const anyopaque` with the concrete AST root type
/// once the lowering rules import `ast` directly. Phase 5 deliberately
/// avoids that coupling so this scaffold compiles without dragging the
/// AST module into the compiler module's import set.
///
/// TODO(R3): the placeholder `opts: anytype` will become a concrete
/// `LowerOpts` struct (likely containing `allow_null_propagation` and the
/// external-var declaration slice) once lowering needs them.
pub fn lower(
    arena: *std.heap.ArenaAllocator,
    ast_root: *const anyopaque,
    opts: anytype,
) error{ NewCompilerNotImplemented, OutOfMemory }!ir.IR {
    _ = arena;
    _ = ast_root;
    _ = opts;
    return error.NewCompilerNotImplemented;
}
