# TODO

Items known to be unfinished but not yet promoted to `ROADMAP.md`. Each entry
should move to `ROADMAP.md` (if becoming a milestone goal) or to `bugs.md` (if
it turns into a named defect) as it matures. Delete entries as they resolve.

Last verified: 2026-04-23.

## Active

1. **AST-walk compile pipeline (Phase 2) — Stages 0–9 landed; 10–13 remaining.**
   The AST parser in `src/ast/` is the source of truth for the LSP
   (`src/lsp/`) and, since commit `f01eeed`, for the compiler's prefilter
   harvester (`harvestPrefilterFromAst` at
   `src/query/src/compiler.zig:1370 / 1520-1607` calls `ast.parse` directly).
   The main compile path still initializes a `Lexer` at
   `src/query/src/compiler.zig:1313` and runs recursive descent on tokens.
   Phase 2 replaces the compile path with an AST walk so there is one
   canonical representation (see `CLAUDE.md` §3).

   **Complete:** Stage 0 + Stage 1 + Stage 2 + Stage 3 + Stage 4 + Stage 5
   + Stage 6 + Stage 7 + Stage 8 + Stage 9. Walker covers: literal/identity/
   recurse/unary_neg (Stage 1), field_access/index_access/iterate/slice/
   suffix chains with `?` (Stage 2), pipe/comma chains (Stage 3 — including
   the legacy FORK/JUMP chain emission via `insertRawInstr`),
   variables/`as`-patterns/destructuring/`?//` (Stage 4 — mirrors legacy's
   pattern emit sequence with per-final-pattern-token src_offset stamping
   inside `?//` bodies), arithmetic/comparison/logical/alternative `//`
   (Stage 5 — including the legacy `parseAlternative`
   insertRawInstr+pipe/push_current/jif/pop_try/push_current/jump/backtrack
   pattern for each `//` in a chain), try/catch, if/elif/else/end, `path()`,
   and parens (Stage 6 — recursive elif emission mirroring legacy
   `parseIfBody`, path_begin/path_end with backpatched IP,
   `last_emit_offset` bumps at `)`/`end` to mirror legacy `last_tok_offset`
   stamping), object/array constructors, string interpolation, format
   strings plus the `$__loc__` / `{__loc__}` marker shorthands (Stage 7),
   and update assignments (Stage 8 — both the strict `.path OP= rhs` fast
   path via the AST's `update_assign` node and the complex-LHS path via a
   new `assign_general` node covering `(.a, .b) = 1`, `.items[] |= f`,
   `(.a | .b) = v` etc., with legacy byte-identical src_offset stamping
   via a source-byte scanner that reproduces `parseUpdateAssign`'s
   partial-consume-then-fallback behavior), and user-defined functions
   with value/filter params, recursion detection + `call_function` IP
   patching, inner-def lexical scoping, and filter-arg AST subtree
   substitution (Stage 9 — replaces legacy's source-range re-parse with
   AST subtree re-walk; scanning_body mode keeps `next_var_id` in
   lock-step with legacy during func_def body-scan pass; zero-arg
   builtin dispatch via `zeroArgBuiltinId` routes `length`/`keys`/etc.
   to `call_builtin` with the same shadowing-is-inert semantics as
   legacy).
   The walker lives at `src/ast/compiler.zig`. The equivalence harness lives
   at `tests/ast_compile_equiv.zig` (+ `tests/ast_compile_equiv_fixtures.zig`)
   and runs via `zig build ast-compile-equiv`. Every other AST node kind
   returns `error.AstCompilerStageIncomplete` — explicit scaffold boundary,
   not a workaround.

   **Plan:** `research/phase-2-ast-walk-plan.md` — full stage breakdown,
   risk register, and cutover strategy.

   **Remaining stages (per plan §4):**
   - Stage 10: generators and reducing builtins.
   - Stage 11: regex builtins and string-ops remainder.
   - Stage 12: prefilter integration (fold into single AST pass).
   - Stage 13: cutover — delete legacy compiler, swap in walker.
