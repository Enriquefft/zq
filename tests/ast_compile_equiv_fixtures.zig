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
/// out of this list as coverage grows. Stage 3 absorbed the original pipe
/// fixture (`". | ."`); it now lives in `stage3_supported`.
pub const stage1_unsupported: []const []const u8 = &.{};

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

/// Supported in Stage 3 — pipes and commas. Every entry must yield
/// byte-identical `Instruction[]` + `source_map` across the legacy compiler
/// and the AST walker. See `research/phase-2-ast-walk-plan.md` §4 Stage 3.
///
/// Fixtures only use Stage 1/2 primaries as operands — no arithmetic,
/// variables, builtins, or parens (those are later stages). `|` binds looser
/// than `,`, so chains like `1, 2 | .` are exactly `pipe(comma(1, 2), .)`
/// in the AST and do NOT require a `paren` node.
pub const stage3_supported: []const []const u8 = &.{
    // Single pipe — Stage 1/2 primaries only.
    ". | .",
    ".a | .b",
    "1 | 2",
    ". | ..",
    "1 | .",
    ". | 1",
    ".a | .",
    ". | .a",

    // Pipe chains.
    ".a | .b | .c",
    ". | . | .",
    "1 | 2 | 3",
    ".a | .b | .c | .d",

    // Pipes to Stage-2-supported suffix operations.
    ".a | .b[0]",
    ".items | .[0]",
    ".data | .[0:3] | .[]",
    ".a.b | .c.d",
    ". | .[]",
    ".foo | .bar?",

    // Single comma.
    "1, 2",
    ".a, .b",
    ".a, .",
    "., .a",
    ". , .",

    // Comma chains of varying length.
    "1, 2, 3",
    "1, 2, 3, 4",
    "1, 2, 3, 4, 5",
    ".a, .b, .c",
    ".a, .b, .c, .d",

    // Pipe + comma interaction (no parens needed because `,` > `|` precedence).
    "1, 2 | .",
    "1, 2 | ., .",
    "., . | 1, 2",
    ".a, .b | .c",
    "1 | 2, 3",
};

/// Stage 3 fixtures that depend on a later-stage node kind.
pub const stage3_unsupported: []const []const u8 = &.{};
