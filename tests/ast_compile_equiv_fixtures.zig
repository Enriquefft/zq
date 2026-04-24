//! Hand-maintained fixture list for the AST-walk compile equivalence harness.
//!
//! Each stage of Phase 2 (see `research/phase-2-ast-walk-plan.md` §4) appends
//! to this file. Stage 0/1 covers: identity, recurse, pure literals (int /
//! float / string / bool / null), and bare negative literals.
//!
//! The harness at `tests/ast_compile_equiv.zig` compiles every entry in
//! `stage1_supported` via both the legacy compiler and the AST walker and
//! asserts byte-identical `Instruction[]` + `source_map`. Entries in
//! `stage1_unsupported` MUST compile successfully via the legacy path and
//! MUST return `error.AstCompilerStageIncomplete` from the walker — that
//! boundary is how the scaffold asserts its stage-1 scope.

/// Supported in Stage 0+1 — both compilers must agree byte-for-byte.
pub const stage1_supported: []const []const u8 = &.{
    // Stage 0 — identity.
    ".",
    // Stage 1 — recurse.
    "..",
    // Stage 1 — keyword literals.
    "null",
    "true",
    "false",
    // Stage 1 — integer literals.
    "0",
    "1",
    "42",
    // Stage 1 — bare negative literals (lexer emits `minus; int_lit`;
    // legacy compiles as `push_int; negate`, AST walker must match).
    "-1",
    "-42",
    // Stage 1 — float literals.
    "0.5",
    "-0.5",
    "1e10",
    // Stage 1 — string literals (empty, plain, and one with a decoded escape).
    "\"hello\"",
    "\"\"",
    "\"with \\n escape\"",
};

/// Intentionally outside Stage 0+1. Both compilers must *accept* the input at
/// the tokenizer level (legacy compiles successfully; AST walker returns
/// `error.AstCompilerStageIncomplete`). Later stages will move each fixture
/// out of this list as coverage grows.
pub const stage1_unsupported: []const []const u8 = &.{
    // Stage 3 — pipe.
    ". | .",
};
