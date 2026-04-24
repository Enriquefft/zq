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

/// Supported in Stage 4 — variables, `as`-pattern, destructuring, `?//`.
/// Every entry here must yield byte-identical `Instruction[]` + `source_map`
/// across the legacy compiler and the AST walker. See
/// `research/phase-2-ast-walk-plan.md` §4 Stage 4.
///
/// Fixtures are restricted to Stage 1/2/3 primaries + variable refs + `as`
/// patterns + `?//`. No arithmetic, comparison, builtins, parens, array/
/// object constructors — those are later stages. Every `expr as PAT | body`
/// fixture uses a Stage 1/2/3 primary as the LHS expression.
pub const stage4_supported: []const []const u8 = &.{
    // Simple pattern: `expr as $x | body`.
    ". as $x | $x",
    "1 as $n | $n",
    ".a as $y | $y.b",
    ".items as $i | $i",
    ". as $x | $x.foo",
    "42 as $n | $n",
    ".foo as $v | $v",

    // Array pattern — LHS is `.` (Stage 2), a literal, or a field access.
    ". as [$a, $b] | $a",
    ". as [$a, $b] | $b",
    ". as [$a, $b, $c] | $a",
    ". as [$a, $b, $c] | $c",
    ". as [$x] | $x",
    ".items as [$a, $b] | $a",

    // Object pattern — explicit `key: $var` form.
    ". as {a: $x} | $x",
    ". as {a: $x, b: $y} | $x",
    ". as {a: $x, b: $y} | $y",
    ".config as {a: $x} | $x",

    // Object pattern — `$k` shorthand.
    ". as {$a} | $a",
    ". as {$a, $b} | $a",
    ". as {$a, $b} | $b",

    // Nested patterns.
    ". as [$a, [$b]] | $b",
    ". as {a: [$x, $y]} | $x",
    ". as {a: {b: $z}} | $z",
    ". as [[$a, $b], $c] | $a",
    ". as {a: $x, b: [$y, $z]} | $y",

    // ?// destructure alt — two-pattern.
    ". as {$a} ?// [$a] | $a",
    ". as [$a] ?// {$a} | $a",
    ". as [$a, $b] ?// {a: $a, b: $b} | $a",

    // ?// destructure alt — three-pattern.
    ". as {$a} ?// [$a] ?// $a | $a",

    // Variable references in comma/pipe bodies (Stage 3 comma + pipe).
    "1 as $x | $x, $x",
    ". as [$a, $b] | $a, $b",
    ". as $x | .a | $x",
    ". as $x | . as $y | $x, $y",
    ". as $x | . as $y | $y, $x",

    // Shadowing: inner `$x` rebinding gets a fresh id; the inner body's
    // `$x` resolves to the new slot.
    "1 as $x | 2 as $x | $x",
    ". as $x | 1 as $x | $x",
};

/// Stage 4 fixtures blocked by later stages.
///
/// `$__loc__` lowers to an `object_construct_*` opcode sequence in the
/// legacy compiler (`src/query/src/compiler.zig:6574-6577` + `emitLocObject`
/// at `:6586-6605`). Those opcodes are Stage 7 scope, so Stage 4's walker
/// rejects `$__loc__` with `AstCompilerStageIncomplete` — legacy accepts it,
/// the walker doesn't yet, which is exactly what this list records.
pub const stage4_unsupported: []const []const u8 = &.{
    "$__loc__",
};

/// Supported in Stage 5 — arithmetic, comparison, logical, alternative (`//`),
/// and non-literal `unary_neg`. Every entry must yield byte-identical
/// `Instruction[]` + `source_map` across the legacy compiler and the AST
/// walker. See `research/phase-2-ast-walk-plan.md` §4 Stage 5.
///
/// Fixtures are restricted to Stage 1/2/3/4 primaries + Stage 5 operators.
/// Parens are Stage 6 and therefore avoided; chains use natural precedence
/// (`* /` tighter than `+ -` tighter than `< > == …` tighter than `and`
/// tighter than `or` tighter than `//`).
pub const stage5_supported: []const []const u8 = &.{
    // Arithmetic — single binops.
    "1+2",
    "5-3",
    "4*6",
    "10/2",
    "7%3",

    // Arithmetic — left-associative same-precedence chains.
    "1+2+3",
    "10-1-2",
    "2*3*4",

    // Arithmetic — mixed precedence.
    "1+2*3",
    "10-2*3",
    "1*2+3*4",

    // Arithmetic with path primaries.
    ".a+1",
    ".a+.b",
    ".items[0] * 2",
    ".x+.y-.z",

    // Arithmetic with patterns.
    "1 as $x | $x+2",
    ". as [$a,$b] | $a+$b",
    ". as [$a,$b,$c] | $a+$b+$c",

    // Unary neg over non-literal primaries.
    "-.x",
    "-.[0]",
    "- .items[0]",

    // Comparison — simple.
    "1 < 2",
    "2 >= 2",
    "1 == 1",
    "1 != 2",
    "\"a\" < \"b\"",

    // Comparison with path primaries.
    ".a < 10",
    ".x == null",
    ".items[0] > 0",

    // Logical — simple.
    "true and false",
    "true or false",

    // Logical — precedence: `and` tighter than `or`.
    "true and true or false",
    "false or true and true",

    // Logical with comparisons.
    ".a > 0 and .b > 0",
    ".x == null or .y == null",
    "1 < 2 and 2 < 3",

    // Logical with patterns.
    "1 as $x | $x > 0 and $x < 10",

    // Alternative `//` — simple.
    ". // 0",
    ".missing // \"default\"",
    ".a // .b",

    // Alternative chains.
    ".a // .b // .c",
    ". // 1 // 2",

    // Alternative with path primaries.
    ".items[0] // -1",
    ".data.value // null",

    // Alternative precedence (`//` is loosest — lower than `+`).
    ".a + 1 // 0",
    ".a // 0 + 1",
};

/// Stage 5 fixtures that depend on a later stage. Currently none — every
/// Stage 5 node kind is handled; nested interactions with later-stage nodes
/// (parens, builtins) are filtered out of the fixture list above.
pub const stage5_unsupported: []const []const u8 = &.{};
