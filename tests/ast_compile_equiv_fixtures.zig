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
/// `$__loc__` moved to `stage7_supported` once the Stage 7 walker gained
/// `emitLocObject`; this list stays so later stages can re-use it.
pub const stage4_unsupported: []const []const u8 = &.{};

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

/// Supported in Stage 6 — try/catch, if/elif/else, `path()`, and parens.
/// Every entry must yield byte-identical `Instruction[]` + `source_map`
/// across the legacy compiler and the AST walker. See
/// `research/phase-2-ast-walk-plan.md` §4 Stage 6.
///
/// Fixtures are restricted to Stage 1–5 primaries plus the Stage 6 nodes.
/// Object/array constructors, string interpolation, builtins beyond `path()`,
/// user functions, and update-assign remain Stage 7+.
pub const stage6_supported: []const []const u8 = &.{
    // ── try/catch — simple forms. ──────────────────────────────────
    "try .a",
    "try .a catch null",
    "try .a catch \"err\"",
    "try .",
    "try 1",

    // Catch-less with path navigation (error-swallowing).
    ". | try .a | .",
    "try .items[0]",
    "try .a.b.c",

    // With explicit handler expressions.
    "try .a catch .b",
    "try .a catch 0",

    // Nested try/catch.
    "try try .a catch .b",
    "try try .a catch null catch .c",

    // try with a pattern binding (Stage 4 intersection).
    ". as $x | try $x.a catch null",

    // try inside `//` chains — `//` is Stage 5; verify the emission is
    // unchanged when `try` produces the left-hand value.
    "try .a // 0",

    // ── if/elif/else/end — simple forms. ───────────────────────────
    "if true then 1 else 2 end",
    "if false then 1 else 2 end",
    "if .a then \"yes\" else \"no\" end",
    "if . then 1 else 0 end",

    // No else — legacy emits `.identity` at end.offset.
    "if .a then 1 end",
    "if true then 1 end",

    // Single elif.
    "if .a then 1 elif .b then 2 else 3 end",
    "if .a then 1 elif .b then 2 end",

    // Multiple elif chains.
    "if .a then 1 elif .b then 2 elif .c then 3 else 4 end",
    "if .a then 1 elif .b then 2 elif .c then 3 end",

    // Short-circuit logic in condition (Stage 5 intersection).
    "if .a and .b then 1 else 0 end",
    "if .a or .b then 1 else 0 end",
    "if .a == .b then 1 else 2 end",

    // ── parens — grouping for precedence. ──────────────────────────
    "(1+2)*3",
    "(.a + .b) * 2",
    "1 + (2 * 3)",
    "(1, 2, 3) | .",
    ".x | (.a, .b)",

    // Nested parens around simple primary.
    "((1))",
    "(((.a)))",
    "(.)",

    // Parens forcing explicit `//` grouping (Stage 5 intersection).
    "(try .a) // 0",
    "(.a // .b) + 1",

    // ── path() — pure AST arg forms. ───────────────────────────────
    "path(.)",
    "path(.a)",
    "path(.a.b)",
    "path(.a[0])",
    "path(.[])",
    "path(.foo)",
    "path(.items[0])",

    // path() with pipe inside.
    "path(.a | .b)",

    // path() with pattern binding (Stage 4 intersection).
    ". as $x | path($x.a)",

    // Nested path() — legacy compiles both layers; runtime rejects but
    // compile-equivalence holds.
    "path(path(.a))",
};

/// Stage 6 fixtures that depend on a later stage. Currently none — every
/// Stage 6 node kind (try_catch, if_expr, paren, path()) is handled.
/// Builtin paths inside `path()` (e.g. `path(getpath([...]))`) depend on
/// builtin lowering (Stage 10/11) and are deferred.
///
/// Latent AST shape note: `path` is missing from `isBuiltinName` at
/// `src/ast/parser.zig:1484-1503`, so `path(.a)` parses as a `func_call`
/// node rather than `builtin_call`. The Stage 6 walker handles both
/// node shapes so the existing AST behavior is preserved; if a later
/// parser fix moves `path` into `isBuiltinName`, the `.builtin_call`
/// branch already has the emission.
pub const stage6_unsupported: []const []const u8 = &.{};

/// Supported in Stage 7 — object literals, array constructors, string
/// interpolation, format strings, and the `$__loc__` marker-object shorthand.
/// Every entry must yield byte-identical `Instruction[]` + `source_map`
/// across the legacy compiler and the AST walker. See
/// `research/phase-2-ast-walk-plan.md` §4 Stage 7.
pub const stage7_supported: []const []const u8 = &.{
    // ── Array construct ────────────────────────────────────────────
    "[]",
    "[1]",
    "[1,2,3]",
    "[\"a\",\"b\"]",
    "[.a, .b, .c]",
    "[.items[0], .items[1]]",
    "[.items[]]",
    "[1,2,3] | [.[]]",
    "[[1,2],[3,4]]",
    "[[]]",
    "[1+2, 3*4]",
    "[.a+1, .b-1]",
    "[if .a then 1 else 2 end]",
    "[try .a catch 0]",

    // ── Object construct — static keys ─────────────────────────────
    "{}",
    "{a: 1}",
    "{a: 1, b: 2}",
    "{\"key\": .value}",
    "{a: 1, b: .c, c: [1,2]}",

    // ── Object construct — shorthand ───────────────────────────────
    "{a}",
    "{a, b}",
    ". as $x | {$x}",
    ". as $x | {$x, y: 1}",

    // ── Object construct — computed key ────────────────────────────
    "{(.name): .value}",
    "{(.k): 1}",
    "{(.key): 42}",

    // ── Object construct — pipe value (BUG-005 d1 coverage) ────────
    "{a: . | 1}",
    "{a: .x | .y}",
    "{a: .items[0] | .name}",

    // ── Object construct — __loc__ marker ──────────────────────────
    "$__loc__",

    // ── String interpolation ───────────────────────────────────────
    "\"\\(.a)\"",
    "\"hello \\(.name)\"",
    "\"\\(.a) and \\(.b)\"",
    "\"\\(.x)-\\(.y)-\\(.z)\"",
    "\"\\(.items[0].name)\"",
    "\"\\(.a + .b)\"",

    // ── Format string — standalone (pipe target) ───────────────────
    ". | @base64",
    ". | @uri",
    ". | @json",
    ". | @tsv",
    ". | @text",
    ". | @csv",
    ". | @html",
    ". | @sh",
    ". | @base64d",

    // ── Format string — with plain literal (no interp) ─────────────
    "@text \"literal\"",
    "@json \"hello\"",

    // ── Format string — with interpolation ─────────────────────────
    "@json \"\\(.a)\"",
    "@uri \"\\(.path)\"",
    "@text \"\\(.name)\"",
    "@csv \"\\(.a),\\(.b)\"",

    // ── Pipe composition of format builtins ────────────────────────
    ". | @base64 | @base64d",
};

/// Stage 7 fixtures that depend on a later stage. Currently none — every
/// Stage 7 node kind (object_construct, array_construct, string_interp,
/// format_string) is handled.
pub const stage7_unsupported: []const []const u8 = &.{};

/// Supported in Stage 8 — update assignments. Every entry must yield
/// byte-identical `Instruction[]` + `source_map` across the legacy compiler
/// and the AST walker. See `research/phase-2-ast-walk-plan.md` §4 Stage 8.
///
/// Covers both the simple `.path.chain OP= rhs` fast path (AST `update_assign`)
/// and the complex-LHS fallback (AST `assign_general`), for every assignment
/// operator the jq grammar defines: `=`, `|=`, `+=`, `-=`, `*=`, `/=`, `%=`,
/// `//=`.
pub const stage8_supported: []const []const u8 = &.{
    // ── Simple `.path = rhs` ───────────────────────────────────────
    ".a = 1",
    ".a.b = 2",
    ".a[0] = null",

    // ── `|=` update with a Stage 5 RHS ─────────────────────────────
    ".a |= . + 1",
    ".a |= . * 2",
    ".items |= . + [99]",
    ".a |= if . > 0 then . else 0 end",

    // ── Compound arithmetic updates ────────────────────────────────
    ".a += 1",
    ".a -= 1",
    ".a *= 2",
    ".a /= 2",
    ".a %= 3",

    // ── `//=` alternative-assignment ───────────────────────────────
    ".a //= 0",
    ".a //= \"default\"",

    // ── Pattern LHS / RHS pipe (Stage 3/4 intersections) ───────────
    ".a = .b | .c",
    ". as $x | $x.a = 1",

    // ── Complex LHS — comma/pipe/iterate routed to assign_general ──
    "(.a, .b) = 1",
    "(.a | .b) = 1",
    ".a.b.c |= . + 1",
    ".items[] |= . * 2",

    // ── Generator RHS ──────────────────────────────────────────────
    ".a = (1, 2)",
    ".a |= (1, 2)",

    // ── Extra complex-LHS coverage ─────────────────────────────────
    "(.a, .b) |= . + 1",
    ".items[] = 0",
    "(.a // .b) = 1",
};

/// Stage 8 fixtures that depend on a later stage. Currently none — every
/// Stage 8 assignment shape is handled by either `update_assign` (simple
/// `.path` LHS) or `assign_general` (complex LHS). `.[] = 1` (bare
/// iterate LHS) routes through `assign_general` because the AST's strict
/// `peekIsUpdateAssign` returns false for the `]`-bare form; the walker
/// emits the same `compilePathExprUpdate` bytecode.
pub const stage8_unsupported: []const []const u8 = &.{};
