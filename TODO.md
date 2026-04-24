# TODO

Items known to be unfinished but not yet promoted to `ROADMAP.md`. Each entry
should move to `ROADMAP.md` (if becoming a milestone goal) or to `bugs.md` (if
it turns into a named defect) as it matures. Delete entries as they resolve.

Last verified: 2026-04-23.

## Active

1. **AST-walk compile pipeline (Phase 2) — Stages 0–7 landed; 8–13 remaining.**
   The AST parser in `src/ast/` is the source of truth for the LSP
   (`src/lsp/`) and, since commit `f01eeed`, for the compiler's prefilter
   harvester (`harvestPrefilterFromAst` at
   `src/query/src/compiler.zig:1370 / 1520-1607` calls `ast.parse` directly).
   The main compile path still initializes a `Lexer` at
   `src/query/src/compiler.zig:1313` and runs recursive descent on tokens.
   Phase 2 replaces the compile path with an AST walk so there is one
   canonical representation (see `CLAUDE.md` §3).

   **Complete:** Stage 0 + Stage 1 + Stage 2 + Stage 3 + Stage 4 + Stage 5
   + Stage 6 + Stage 7. Walker covers: literal/identity/recurse/unary_neg
   (Stage 1), field_access/index_access/iterate/slice/suffix chains with `?`
   (Stage 2), pipe/comma chains (Stage 3 — including the legacy FORK/JUMP
   chain emission via `insertRawInstr`), variables/`as`-patterns/
   destructuring/`?//` (Stage 4 — mirrors legacy's pattern emit sequence
   with per-final-pattern-token src_offset stamping inside `?//` bodies),
   arithmetic/comparison/logical/alternative `//` (Stage 5 — including the
   legacy `parseAlternative` insertRawInstr+pipe/push_current/jif/pop_try/
   push_current/jump/backtrack pattern for each `//` in a chain),
   try/catch, if/elif/else/end, `path()`, and parens (Stage 6 — recursive
   elif emission mirroring legacy `parseIfBody`, path_begin/path_end with
   backpatched IP, `last_emit_offset` bumps at `)`/`end` to mirror legacy
   `last_tok_offset` stamping), and object/array constructors, string
   interpolation, format strings plus the `$__loc__` / `{__loc__}` marker
   shorthands (Stage 7 — includes the `@name "literal"` no-interp special
   case per plan §6.6, shorthand object fields via an AST parser fix that
   synthesizes the implicit value node, and BUG-005 d1 pipe-in-object-value
   coverage via the existing `.pipe` walker).
   The walker lives at `src/ast/compiler.zig`. The equivalence harness lives
   at `tests/ast_compile_equiv.zig` (+ `tests/ast_compile_equiv_fixtures.zig`)
   and runs via `zig build ast-compile-equiv`. Every other AST node kind
   returns `error.AstCompilerStageIncomplete` — explicit scaffold boundary,
   not a workaround.

   **Plan:** `research/phase-2-ast-walk-plan.md` — full stage breakdown,
   risk register, and cutover strategy.

   **Remaining stages (per plan §4):**
   - Stage 8: update assignments.
   - Stage 9: user-defined functions, filter args, recursion.
   - Stage 10: generators and reducing builtins.
   - Stage 11: regex builtins and string-ops remainder.
   - Stage 12: prefilter integration (fold into single AST pass).
   - Stage 13: cutover — delete legacy compiler, swap in walker.
