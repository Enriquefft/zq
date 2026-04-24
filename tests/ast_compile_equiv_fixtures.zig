//! Hand-maintained fixture list for the AST-walk compile equivalence harness.
//!
//! Each stage of Phase 2 (see `research/phase-2-ast-walk-plan.md` §4) appends
//! to this file. Stage 0/1 covers: identity, recurse, pure literals (int /
//! float / string / bool / null), and bare negative literals. Stage 2 adds
//! field access, index access, iterate, slices, suffix chains, and `?`.
//!
//! The harness at `tests/ast_compile_equiv.zig` compiles every entry in
//! `stageN_supported` via both the legacy compiler and the AST walker and
//! asserts byte-identical `Instruction[]` + `source_map`. Entries in
//! `stageN_unsupported` MUST compile successfully via the legacy path and
//! MUST return `error.AstCompilerStageIncomplete` from the walker — that
//! boundary is how the scaffold asserts its stage scope.

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

/// Supported in Stage 2 — field/index/iterate/slice/suffix chains with `?`.
/// Every entry here must yield byte-identical `Instruction[]` + `source_map`
/// across the legacy compiler and the AST walker.
pub const stage2_supported: []const []const u8 = &.{
    // Simple field access.
    ".foo",
    ".foo.bar",
    ".foo.bar.baz",

    // Simple index access.
    ".[0]",
    ".[1]",
    ".[-1]",
    ".[42]",

    // String index access via `.[\"...\"]` bracket form.
    ".[\"key\"]",

    // Iterate.
    ".[]",

    // Slices — various bound combinations.
    ".[0:5]",
    ".[:5]",
    ".[0:]",
    ".[:]",

    // Field + index chains.
    ".foo[]",
    ".foo[0]",
    ".foo[\"k\"]",

    // Optional (`?`) on simple primaries.
    ".foo?",
    ".foo.bar?",
    ".[]?",
    ".[0]?",

    // Mixed `?` placement in chains.
    ".foo?.bar?",
    ".foo.bar?.baz",

    // Complex chains.
    ".a.b[0].c[1:3].d?",
    ".items[].name",
    ".data[0][\"nested\"][-1]?",
};

/// Stage 2 shapes not yet covered by the walker. `.[expr]` with a dynamic
/// expression (e.g. `.[foo]`, `.[1,2]`) is a SuffixOp.bracket_expr in the AST
/// and lowers via the legacy `compileComputedBracket` helper — that is Stage
/// 10 territory (depends on computed-access semantics and generator support).
pub const stage2_unsupported: []const []const u8 = &.{
    // `.[expr]` dynamic bracket — deferred to a later stage.
    ".[.x]",
};
