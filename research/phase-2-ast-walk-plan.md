# Phase 2 — AST-walk Compile Pipeline

Goal: replace the recursive-descent-on-tokens compile path in `src/query/src/compiler.zig` with an AST walker in a new `src/ast/compiler.zig`. The AST produced by `src/ast/parser.zig` becomes the canonical representation of a zq filter. The bytecode (`RawInstr` stream and then fused `Instruction` stream) produced by the new path must be byte-for-byte equal to the current path for every in-tree fixture, after which the old path is deleted in one commit.

No permanent dual-pipeline. Dual-compile is a verification bridge with an explicit delete commit.

Absolute file paths used below:
- `/home/hybridz/Projects/zq/src/ast/nodes.zig`
- `/home/hybridz/Projects/zq/src/ast/parser.zig`
- `/home/hybridz/Projects/zq/src/ast/root.zig`
- `/home/hybridz/Projects/zq/src/query/root.zig`
- `/home/hybridz/Projects/zq/src/query/src/compiler.zig`
- `/home/hybridz/Projects/zq/src/query/src/lexer.zig`
- `/home/hybridz/Projects/zq/src/query/src/prefilter.zig`
- `/home/hybridz/Projects/zq/src/types.zig`
- `/home/hybridz/Projects/zq/tests/compat/`
- `/home/hybridz/Projects/zq/tests/query_test.zig`
- `/home/hybridz/Projects/zq/tests/lsp_test.zig`
- `/home/hybridz/Projects/zq/build.zig`

---

## 1. Inventory: non-grammar work the current compile path does

The current `compile()` at `src/query/src/compiler.zig:1304` is not a pure grammar walker. It carries cross-cutting state. Each behavior below must be either preserved, moved, or proven redundant by the AST.

### 1.1 Prefilter harvester
Location: `src/query/src/compiler.zig:1370` (invocation) and `:1520-1607` (body).
Status: already AST-backed since `f01eeed`. `harvestPrefilterFromAst()` calls `ast.parse()` and matches `select( <pure-accessor> | test|scan("lit" [;"flags"]))`. The literal gating and flag handling live there.
Migration: keep the function; the new AST-walk compiler owns the same AST parse, so fold prefilter harvesting into a single AST pass — no second `ast.parse()` call.
AST sufficiency: sufficient. `BuiltinCall`, `Pipe`, `Suffix`, `literal.string` all resolve statically.

### 1.2 Regex flag emission and interning
Locations: `compileRegexBuiltin1` (`:3184`), `compileRegexBuiltin1FastLiteral` (`:3229`), `emitFlagPrefix` (`:3304`), `compileRegexBuiltin2` (`:3867`), `compileRegexBuiltinSlow` (`:3351`).
State:
- Fast-path probe via a cloned lexer looking for `(string_lit [; string_lit])` argument shape.
- `emitFlagPrefix` translates `i`/`x`/`m`/`s` → `(?ims...)` inline prefix, `g` → opcode switch, `n` → bit 48 in the `call_builtin` operand. `p`/`l` → compile error.
- `compileRegexBuiltin1FastLiteral` stashes `ctx.last_regex_pattern_offset/len` for diagnostic pointing at the literal; `RegexPool.intern` is called at compile time.
- `compileRegexBuiltinSlow` marks every `call_builtin` it produced with the `REGEX_POOL_DYNAMIC` sentinel.
AST sufficiency: sufficient. `BuiltinCall.args[0]` can be inspected: `literal.string` → fast path; anything else → slow/dynamic. `packRegexBuiltinOperandFlags` is a pure `types.zig` helper.
AST gap: the AST decodes string literals, so the **raw** source bytes (for jq-literal-exact regex pattern semantics) are still available only via `Span` into `ctx.src`. This is only a concern if jq-parity requires pattern bytes pre-escape-decode; today both paths decode before interning, so no gap.

### 1.3 Builtin resolution and operand packing
Location: the huge `parsePrimaryInner` dispatcher at `:5810`, especially `:5909-6051` (the builtin name-dispatch table) and the per-builtin `compileXxx` functions `:3079-5729`.
State: ~60 distinct builtins each with a bespoke lowering. Many inject `save_input`/`restore_input`/`capture_variable` frames, pattern-match on generator arguments, splice EXPR buffers via `rebaseExprBuf`, etc. Generator-aware dispatch (`range`, `in`, `limit`, `skip`, `nth`, `INDEX`, `IN`, `JOIN`, `del`, `add`, `first`, `last`).
Migration: each `compileXxx(ctx)` becomes `emitXxx(walker, node: *Node)`. The walker takes the `BuiltinCall` node and dispatches by `bc.name`. The lowering logic is largely a 1:1 port — operands are already parsed into `bc.args: []const *Node` so the `parseArgToArray`, `parsePipe`, semicolon-count scans, and generator detection become ordinary AST traversal.
AST sufficiency: mostly. See §2 for gaps.

### 1.4 Object-literal parser
Locations: `parseObjectLiteral` (`:6827`), `parseObjectKey` (`:6913`), `parseObjectFieldValue` (`:6804`); `emitLocObject` (`:6586`); BUG-005 value-parse fix lives here.
State: produces `object_construct_start` / (key + value)* / `object_construct_end`. Handles `{$var}`, `{$var: expr}`, dynamic key via replay of key-producing instrs between `save_input` and `load_computed`, `{__loc__}`, string-interp keys.
AST sufficiency: sufficient. `ObjectConstruct.fields` is `[]const ObjectField`; `ObjectKey` is `.ident`/`.string`/`.expr`. The AST is the post-BUG-005 shape (see `src/ast/parser.zig:688-762`).
Caveat: the compiler emits the **key-producing instructions** to compute the key value, then replays them between `save_input` / `load_computed`. The walker must do the same by compiling the key subtree twice or saving the emitted range. Straightforward.

### 1.5 `path()` validation state
Locations referenced by TODO: VM-side (`src/query/src/vm.zig:815-821`, `:1682-1689`); compile-time `breaksPath`/`clearsPathBroken` tables at `src/types.zig:943-1028` / `:1040-1057`; compilePath at `src/query/src/compiler.zig:4858`.
State: compile-time this is purely opcode-classification; there is **no** per-compile state in the token walker for this. Validation fires at runtime via the Op predicates.
Migration: no work. The walker emits the same `path_begin` / `path_end` brackets, and the opcodes remain classified at `types.zig`.

### 1.6 Fork / forkpoint / `saved_stack` / `saved_object` emission
Not compile-time state. `Forkpoint.saved_stack` is a VM concept; the compiler just emits `fork`, `fork_try`, `fork_alt`, `backtrack`, `pop_try`, `path_begin`, `path_end`. Carry straight over.

### 1.7 User-defined functions and filter args
Locations: `parseFunctionDef` (`:6614`), `expandFunctionCall`, `lookupFunction`, the reParse mechanism, `FilterArgBinding`, `scanning_body` / `expanding_recursive_func` / `func_hidden_start/_end`.
State (critical): jq's lexical scoping and filter-arg re-parsing on each expansion are driven **by source-range byte offsets**. Concretely: when a function body references a filter arg `f`, the compiler re-parses the arg's source range via `ctx.lex.pos = binding.src_start; try parsePipe(ctx)` (`:6217-6220`), then restores. That loop is what today relies on a tokenizer.
Migration path: the AST walker must do the same by *recompiling the caller's AST-arg subtree in-place* instead of re-parsing source. Mechanics:
- `FuncDef` captures a body AST subtree once.
- On a call site, each filter arg is the caller's AST argument subtree (a `*Node`). Bind it to the parameter name in a `FilterArgBinding` that points to `*Node` instead of source offsets.
- When the body walker hits a `FuncCall`/`FieldAccess`/`BuiltinCall` identifier whose name matches a filter-arg binding, recursively emit the arg's subtree, with the walker's scope snapshot restored to the caller's scope (to avoid body-local variables leaking into the arg).
- Recursion detection (is_recursive, `expanding_recursive_func`, `call_function`) stays identical — it is a function-table bookkeeping pass on body instructions.
- Inner `def` hiding ranges (`func_table_snapshot`) carry over unchanged.

This removes the lexer-rewind and the `scanning_body` mode entirely; both exist only because the current compiler re-tokenizes.

### 1.8 Update-assignment dispatch
Locations: `peekIsUpdateAssign` (`:1691`), `parseUpdateAssign` (`:1735`), `compilePathExprUpdate` (`:1951`).
State: the lookahead scans for an assignment operator at depth-0 via the raw lexer. The fast path only fires for a leading `.` followed by simple path steps; anything richer bails to `compilePathExprUpdate`, which re-parses the LHS inside `path_begin/path_end`.
Migration: `parser.zig:peekIsUpdateAssign` (at `:1167`) already surfaces this as the `update_assign` AST node with a parsed `[]PathStep`. The walker:
- For `update_assign`: use the `PathStep` slice when simple; otherwise synthesize `compilePathExprUpdate` by re-walking the LHS as a path-expression under `path_begin`/`path_end`.
- Subtle: the current `peekIsUpdateAssign` (compiler-side, `:1691`) is *more permissive* than the AST's `peekIsUpdateAssign` (parser.zig `:1167`). The current parser sees things like `1+2 = 3` as valid at parse time and lets runtime `path_intact` catch them; the AST `peekIsUpdateAssign` only matches a strict `.path` LHS and otherwise builds an `arithmetic` / `comparison` AST. Bytecode-equivalence for such over-accepted filters must be audited. See Risk 6.2.

### 1.9 String interpolation
Locations: `compileStringInterpolation` (`:5729`), `parsePrimaryInner` at `.at` / `.string_part` (`:6330-6363`).
State: walks the raw string bytes, splitting at `\(...)` escapes, re-entering `parsePipe` for each interpolation. AST already splits into `StringInterp.parts: []StringPart` with variants `.literal` / `.expr`.
Migration: one-for-one port. AST wins here: escape decoding already happened in `src/ast/parser.zig:decodeString` (`:1378`).

### 1.10 Format strings (`@html`, `@json`, …)
Locations: `.at` branch in `parsePrimaryInner` (`:6330`), `formatBuiltinId` (`:5698`).
AST: `FormatString { format, parts }` and standalone `builtin_call` with name `@name`. Sufficient.

### 1.11 Source-offset diagnostics
Every `ctx.emit()` stamps `src_offset = ctx.last_tok_offset`, which is the offset of the token just consumed. `fuse()` preserves this per fused instruction and it eventually becomes `CompiledQuery.source_map`.
Migration: the AST node carries a `Span { start: u32, end: u32 }`. Use `node.span.start` as `src_offset`. **Byte-identical to the old compiler only when the "last token consumed" in the old path is the first token of the AST node.** For most nodes this is true (the token whose start position is `node.span.start`). Audit edge cases: arithmetic operators (old compiler stamps the operator position? or the right-operand first-token position?), `pipe` emissions, pattern captures. See Risk 6.2.

### 1.12 External variables
`compile()` pre-declares `external_vars` in the root scope (`:1391-1406`). Pure table bookkeeping, carries straight over.

### 1.13 Implicit trailing `yield_output`
At `:1449-1453`, appended if last op isn't `yield_output`. Copy verbatim.

### 1.14 Fuse pass
`fuse()` at `:7311` collapses `load_key; pipe; load_key; ...` into `load_path`. Independent of the compile front-end and can stay as-is. Fed from the walker's `RawInstr` list.

---

## 2. AST node surface gap analysis

Compiler productions that lack a dedicated AST node or where the AST loses information the compiler needs:

| Production / behavior | AST status | Gap | Resolution |
|---|---|---|---|
| Raw source range for filter-arg re-parsing | Not needed if §1.7 moves to subtree cloning. | None when subtree cloning replaces source re-parse. | No AST change. |
| Update-assign LHS that isn't a simple `.path.path[n]` chain | Falls out of `update_assign` and would hit the else-branch (`arithmetic`, `comparison`, …). | The AST's `update_assign` only fires for a strict leading `.` chain (`:1167-1204`); anything else is a different node. The walker must detect `eq_assign`/`pipe_eq`/... at the root of any expression and dispatch to the complex path. | Extend AST: either (a) parse any `Expr OP Expr` with assignment ops into a new `assign_general` node, or (b) when the old path is preserved behaviorally via the walker's own dispatch on AST shape. Preferred: add `ASSIGN_GENERAL` node variant capturing `lhs: *Node`, `op`, `rhs: *Node`. |
| `__loc__` marker object for `$__loc__` | None. `VarRef.name == "__loc__"` collides with any user binding. | Today the compiler has a name-match on `__loc__` in `parsePrimaryInner`/`parseObjectLiteral`. | AST treats `__loc__` as a normal `variable_ref`; walker applies the same name check. No AST change required. |
| `first`/`last` bare (no parens) meaning `.[0]` / `.[-1]` | AST emits `field_access` for bare `first`/`last`, because they aren't in `isZeroArgBuiltin` AST-side (see `src/ast/parser.zig:1454-1476`). Today the compiler hard-codes them in `parsePrimaryInner:6055-6062`. | Bug vs gap: AST currently loses this semantics — `first` as a bare ident becomes `field_access("first")`. | Walker checks for `field_access("first")` / `field_access("last")` and emits `load_index(0)`/`load_index(-1)`. Or add `first`/`last` to `isZeroArgBuiltin` and special-case in the walker. Preferred: walker-side check to preserve AST generality. |
| `not` as bare ident and as postfix | AST has `builtin_call("not")` for both. | Compiler emits `.not` opcode for bare `not` (`:6390-6394`). Walker maps `builtin_call("not", 0 args)` → `.not`. | Sufficient. |
| `foreach` as ident (not keyword) | AST handles it inside `parseIdentPrimary`, emitting `foreach` node. | Sufficient. |
| Builtin-vs-user-function arity shadowing | AST emits `builtin_call` or `func_call` based on name (`isBuiltinName`); the compiler performs a name-ref + arity check against the live function table (`:5886-5895`). | The AST can't know about user defs that shadow builtins. | Walker resolves names against its own function table first; the AST node's tag (`builtin_call` vs `func_call`) is a hint, not a decision. |
| `fork_alt` / `fork_try` sentinels; fused `load_path` | Compile-time/VM, no AST role. | None. | No AST change. |
| Exact token byte-position for diagnostics | Every AST node carries `Span`. The old compiler uses `ctx.last_tok_offset` which is the offset of the most recently consumed token. | For most productions `node.span.start` equals that; for some (arithmetic operators, assignment ops) the compiler stamps the operator's offset, not the left-operand's. | Either accept a documented offset drift, or extend AST: add explicit operator-span fields to `Comparison`, `Arithmetic`, `UpdateAssign`. Minimum: store `op_span: Span` on these nodes. This also helps the LSP. |
| AST `error_node` recovery | AST is error-tolerant; the compiler must still reject. | On `errors.len > 0`, the walker must convert the first error into a `CompileError` with the same offset/length as the old path would have produced. | Bridge layer: if `parsed.errors.len > 0`, pick the first error whose span overlaps the AST subtree being compiled and map it to the matching `ZqError` kind. See §6.1. |
| Dynamic-key object field (parenthesized key) | AST: `ObjectKey.expr: *Node`. | Sufficient. |
| Destructuring alternative `?//` | AST: `destruct_alt`. | Sufficient. |
| `try`/`catch` with catch-less form | AST: `try_catch { body, catch_body: ?*Node }`. | Sufficient. |
| Bare `.` at end of a chain (`push_current` vs noop) | AST: `identity`. | Walker emits `push_current` when the context requires it. |
| Suffix chain `?` wrapping the immediately preceding segment | AST: `Suffix.ops` is a flat array; `?` is an op. The old compiler's `insertRawInstr` with `fork_try`/`pop_try` operates on the last segment since the previous `?`. | The AST doesn't carry the segment boundary, but the walker can re-derive it: each `?` wraps the slice of ops since the last `?`, which is trivially recoverable from the ops array. | Sufficient. |

Recommended AST extensions (ordered by blocking-ness):
1. `assign_general` node variant (or walker-internal detection): required to cover non-`.`-prefixed update assignments without source rewind.
2. `Comparison.op_span`, `Arithmetic.op_span`, `UpdateAssign.op_span`: required only if byte-identical diagnostic offsets are non-negotiable; otherwise deferrable with a documented drift.

---

## 3. Equivalence harness design

### 3.1 Harness shape
A new test binary `tests/ast_compile_equiv.zig` (and the Zig test or build step invoking it) that, for each filter string in the fixture pool:
1. Calls the old compiler (rename to `compiler_legacy.compile`) → `RawInstr[]` A (before `fuse()`), and `Compiled` A' (after `fuse()`).
2. Calls the new AST compiler (`compiler_ast.compile`) → `RawInstr[]` B and `Compiled` B'.
3. Diffs A vs B, and A' vs B', field-wise:
   - Same length.
   - Same `Op` at each index.
   - Same `Operand` union inhabitant and payload (compare by tag + bitwise payload comparison on `extern union`).
   - Same `src_offset` (or: flagged drift — a separate counter reported, not a failure, if we accept documented diagnostic-offset drift).
4. Emits a diff report for the first mismatching index with pretty-printed opcodes plus the source-offset window.

### 3.2 Fixture sources
Enumerate filters from:
- `/home/hybridz/Projects/zq/tests/compat/*.zig` — the jq compat suite. Filter strings are the first argument to `h.runFilter(...)` (see `tests/compat/helpers.zig:151`) and to `h.expectCompileError(...)`. Extract these via a small build-time script or a comptime reflection pass that scans the source text for `runFilter("...",` / `expectCompileError("...")` literal prefixes. There are ~533 fixtures today (see ROADMAP "Compat tests: 426/533").
- `/home/hybridz/Projects/zq/tests/query_test.zig` — internal regression suite (~443 tests).
- `/home/hybridz/Projects/zq/tests/lsp_test.zig` — LSP fixtures, many of which are partial/malformed (useful stress input for error-tolerance vs rejection).
- `/home/hybridz/Projects/zq/benchmarks/scenarios/` — benchmark filters used by `run_all.sh`.
- `/home/hybridz/Projects/zq/demo/` — demo filters.
- `/home/hybridz/Projects/zq/ROADMAP.md`, `/home/hybridz/Projects/zq/llms.txt` — illustrative filters embedded in docs.

The extraction step is mechanical (grep for the specific `runFilter(" / "` pattern), and the output is a generated `tests/ast_compile_equiv_fixtures.zig` file enumerating a `const filters: []const []const u8`.

### 3.3 Build step
New `zig build ast-compile-equiv` target (mirroring `fuzz-query` / `fuzz-parser` wiring at `build.zig:412-427`):
- Not attached to `test_step`.
- Iterates every fixture, reports a summary count at the end.
- Nonzero exit when any mismatch.
- Optional `-Dast-equiv-verbose=true` to emit per-mismatch raw instruction dumps.

The equivalence binary links both `compiler_legacy` and `compiler_ast`. This requires temporarily exposing both as sibling modules during Phase 2.

### 3.4 Success bar before swap
- 100% bytecode equivalence (A == B and A' == B') on every fixture.
- Decision on `src_offset` drift: prefer 100% byte-identical, accept a documented allowlist only for operator-position cases captured in the Risk 6.2 audit table.
- Equivalence holds across `CompileResult` shape too: both paths return `.err` for the same inputs with the same `CompileError.kind`, and offset/length within an agreed tolerance.

---

## 4. Staged migration plan

Each stage:
- Lands independently.
- Adds fixtures to the equivalence harness pass-list; post-stage, the listed fixtures must be byte-identical across both paths.
- Uses `-Dast-compile-enabled=<scope>` (build flag) to choose which AST features the AST-walker handles; unhandled nodes defer to the legacy compiler via a shim. By the end of Stage 11, the shim accepts every node.

### Stage 0 — Scaffolding
Scope: create `src/ast/compiler.zig` with a `Walker` struct; it produces the same `RawInstr` type as `compiler.zig` does internally. Implement only `yield_output` for the root (empty filter `. `). Add the equivalence harness (§3) with one fixture: `"."`. Wire `-Dcompile-via-ast=false` default.
Predecessor deps: none; the harness can call `compiler.compile` and a placeholder `ast_compiler.compile`.
Coverage: the trivial `.` filter.
Risk: none; pure plumbing.

### Stage 1 — Literals, identity, recurse, bare `.`
Scope: `literal` (int/float/string/bool/null), `identity`, `recurse` (→ `call_builtin(recurse)`), bare `-N` (`unary_neg` over `literal.int`).
Predecessor deps: AST already has these.
Coverage: `tests/compat/literals.zig`, numeric fixtures in `tests/compat/numbers.zig` that are pure-literal.
Risk: negative-literal tokenizer vs AST treatment. Today the lexer emits `int_lit("−N")` for `-1` (no space) and separately `minus; int_lit` for `- 1`. AST may or may not fold both into `literal.int(-N)` vs `unary_neg(literal.int(N))`. Verify and align.

### Stage 2 — Field access, index access, iterate, slices, bare dot, suffix chain
Scope: `field_access`, `index_access`, `iterate`, `slice`, `suffix` (all op variants: `.field`, `.[n]`, `.[]`, `.[a:b]`, `.["k"]`, `?`, `.[expr]`). Implements `parseSuffixes` logic including `?` wrapping segments between last `?`.
Predecessor deps: Stage 1.
Coverage: `tests/compat/field_access.zig`, `tests/compat/array_indices.zig`, `tests/compat/iteration.zig`.
Risk: segment-boundary logic for `?` needs a careful re-derivation from `Suffix.ops[]`. The AST records the `?` as an op inline; the walker rebuilds "segment since last ?" by index.

### Stage 3 — Pipes and commas
Scope: `pipe`, `comma`. Implements the `fork` / `jump` pattern in `parseComma` at `:2504-2558`, including the "point previous fork at this new fork" chaining. Single `pipe` opcode is trivial.
Predecessor deps: Stages 1-2.
Coverage: `tests/compat/iteration.zig` comma cases, pipe chains throughout.
Risk: comma's `insertRawInstr` path and jump-fixup list must preserve exact IP numbering. The inserted `fork` shifts all later jump targets; the walker emits in tree order so a naive emit won't need `insertRawInstr` — but the byte-identical bar forces it. Strategy: emit `FORK`, then EXPR_A with its jumps relative to the post-FORK base, exactly reproducing the legacy sequence. This is straightforward since the AST already knows both children before emission.

### Stage 4 — Variables, `as`, destructuring, `?//`
Scope: `variable_ref`, `as_pattern`, `destruct_alt`. Includes all pattern variants (`simple`, `array`, `object` with static and computed keys). Ports `scanAndDeclarePattern`, `emitPatternCapture`, `emitPatternCaptureStrict`, `collectPatternVarIds`.
Predecessor deps: Stages 1-3.
Coverage: `tests/compat/variables.zig`.
Risk: variable-id allocation order. The legacy compiler allocates ids during a token walk that interleaves variables and hidden-temporaries in a specific order (`saved_input_id`, `acc_id`, etc.). The AST walker must allocate in the same order. This is tractable because pattern variable IDs are only observable in emitted `capture_variable/load_variable/pop_variable` operands — the equivalence harness catches any divergence immediately.

### Stage 5 — Arithmetic, comparison, logical, alternative (`//`)
Scope: `arithmetic`, `comparison`, `or_expr`, `and_expr`, `alternative`, `unary_neg`.
Predecessor deps: Stage 3.
Coverage: `tests/compat/comparisons.zig`, arithmetic filters in many sections.
Risk: `parseAlternative`'s `insertRawInstr` for the `fork_alt` at chain start and the specific pipe/push_current/jump_if_false pattern (`:2578-2617`). Byte-identical emission is required.

### Stage 6 — Try/catch, if/elif/else/end, `path()`, parens
Scope: `try_catch`, `if_expr`, `paren`, `compilePath` (which wraps in `path_begin`/`path_end`).
Predecessor deps: Stages 1-5.
Coverage: `tests/compat/try_catch.zig`, `tests/compat/conditionals.zig`, `tests/compat/paths.zig`.
Risk: `parseTryCatch` uses primary-level precedence for both body and handler (`:6422-6453`); the AST already parses correspondingly (`src/ast/parser.zig:839-860`). Verify equivalence for chained `?` around try.

### Stage 7 — Object literals, array constructors, string interpolation, format strings
Scope: `object_construct`, `array_construct`, `string_interp`, `format_string`, `emitLocObject` for `__loc__`.
Predecessor deps: Stages 1-6.
Coverage: `tests/compat/object_construction.zig`, `tests/compat/object_merge.zig`, `tests/compat/string_ops.zig`.
Risk: object dynamic-key replay (the `save_input` + replay + `load_computed` dance) needs careful byte equivalence. The walker compiles the key subtree twice: once to produce the key-producing instrs, once more to prefix `save_input` and suffix `load_computed`. Verify no intern-side-effects differ (string literals get the same `StrRef`).

### Stage 8 — Update assignments
Scope: `update_assign` (simple `.path` LHS) + complex-LHS fallback re-implementing `compilePathExprUpdate`.
Predecessor deps: Stages 1-7.
Coverage: `tests/compat/assignment.zig`, `tests/compat/paths.zig`.
Risk: the legacy "peek looks like `.path OP=`" fast path vs the AST's narrower `update_assign` shape. If the AST doesn't produce `update_assign` for some complex LHS that the legacy fast-path accepted, the walker must detect `=`/`|=`/etc. on a non-`update_assign` AST root and dispatch to the `compilePathExprUpdate` port. A small AST extension (`assign_general` node) eliminates this ambiguity cleanly; preferred.

### Stage 9 — User-defined functions, filter args, recursion
Scope: `func_def`, `func_call`, including:
- Param table (`ParamInfo`, filter vs value).
- Scope snapshot (`func_table_snapshot`) and inner-def hiding.
- Filter-arg binding resolution by **AST subtree substitution** (replacing source-range re-parse).
- Recursion detection and `call_function` IP patching.
- Zero-arg user functions shadowing builtins.
Predecessor deps: Stages 1-8.
Coverage: `tests/compat/user_functions.zig`.
Risk: this is the highest-risk stage. The legacy path's `scanning_body` mode exists to suppress expansion during body tokenization; the walker doesn't need it because the body is already an AST subtree. But producing byte-identical bytecode requires:
- Same variable-id allocation order during expansion (see Stage 4 risk, amplified).
- Same processed-body rewriting (`load_key`-with-matching-name → `call_filter_arg` at `:6728-6750`). The AST equivalent is: when walking a body, any `field_access(name)` matching a filter param name emits `call_filter_arg` instead. The walker does this without the post-pass rewrite the legacy compiler does; verify bytecode matches.
- Same per-call filter-arg substitution semantics: the legacy path re-parses source at each expansion, so each expansion can see the caller's lexical state. Subtree substitution does the same if the walker tracks caller scope at binding time.
- `is_recursive` detection: legacy uses a `load_key` name-match on the processed body; AST walker uses a `field_access`/`func_call` name-match on the body AST. Same result in the common case; audit jq-tricky cases.

### Stage 10 — Generators and reducing builtins (`reduce`, `foreach`, `label`/`break`, `limit`, `skip`, `nth`, `first`, `last`, `walk`, `range`, `select`, `map`, `map_values`, `any`/`all`, `del`, `pick`, `INDEX`/`IN`/`JOIN`)
Scope: port each `compileXxx`. Critical cases:
- `compileReduce` / `compileForeach` reorder EXPR after INIT via `rebaseExprBuf`. AST walker can emit INIT first, then EXPR, avoiding the rebase — but to stay byte-identical, we must replicate the legacy order **exactly**. Either (a) mimic the legacy order including the reorder, or (b) prove the alternate order produces the same `Instruction[]` (unlikely — `fork` IPs shift). Choose (a): emit EXPR to a temp buffer, then INIT, then splice — same as legacy.
- `compilePathExprUpdate` is still needed for general LHS.
- `compileRange`'s single-arg-vs-multi-arg lookahead: the AST already distinguishes via `BuiltinCall.args.len`, so no lookahead needed. Same bytecode outcome when walker chooses the same branch.
Predecessor deps: Stages 1-9.
Coverage: `tests/compat/builtins.zig`, `tests/compat/iteration.zig`, `tests/compat/conditionals.zig` (while/until/repeat).
Risk: very high. Many fixture-specific edge cases. This stage will be where most equivalence-harness diffs surface.

### Stage 11 — Regex builtins and string-ops remainder
Scope: `compileRegexBuiltin1`, `compileRegexBuiltin1FastLiteral`, `compileRegexBuiltin2`, `emitFlagPrefix`, regex-pool interning, string-decode into patterns. Also datetime, remaining `format_*`, base64.
Predecessor deps: Stages 1-10.
Coverage: `tests/compat/regex.zig`, `tests/compat/datetime.zig`, `tests/compat/string_ops.zig`.
Risk: `last_regex_pattern_offset/len` must point at the string-literal `Span` in the AST — which is exactly `call.args[0].span`. Verify error paths surface the same offset.

### Stage 12 — Prefilter integration
Scope: fold `harvestPrefilterFromAst` into the single AST pass. Remove the second `ast.parse()` call.
Predecessor deps: Stage 11 + equivalence at 100%.
Coverage: pool benchmarks, any regex fixtures exercising the prefilter.
Risk: low; the harvest logic is already AST-driven.

### Stage 13 — Cutover
Scope: see §5 below.

---

## 5. Swap strategy

### 5.1 Dual-compile mode
Behind `-Dcompile-dual=true`:
- `CompiledQuery.compile` calls both compilers, `std.debug.assert`s equivalence (`RawInstr[]` pre-fuse, `Instruction[]` post-fuse, `source_map`, `function_table`, `external_var_ids`).
- On mismatch, panic with a diff dump.

When to run:
- **Not the default CI run** — it doubles compile time.
- Enabled on the `zig build test -Dcompile-dual=true` invocation in a dedicated nightly CI job.
- Enabled as the default for `zig build ast-compile-equiv`.
- Every developer running the equivalence harness locally sees both compilers execute per fixture.

### 5.2 Cutover commit
Preconditions (must all hold on `main`):
1. Equivalence harness green on every fixture (`zig build ast-compile-equiv` exit 0).
2. `zig build test` green with `-Dcompile-dual=true`.
3. Nightly dual-compile CI green for 3 consecutive runs.
4. No open bug marked `dual-compile-diff`.

The cutover commit:
- Switches `src/query/root.zig:compile` to call `compiler_ast.compile` only.
- Deletes `src/query/src/compiler.zig` and its file-level tests.
- Renames `src/ast/compiler.zig` → `src/query/src/compiler.zig` if preferred layout is keep-the-path. Alternative: leave the walker at `src/ast/compiler.zig` per the TODO text — but the filter-bytecode compiler's natural home is under `query/`. Decide once.
- Deletes the `-Dcompile-dual` build option and the dual-call path.
- Deletes `src/query/src/lexer.zig` **only if** no one else imports it. Audit: the AST parser imports `lexer` (`src/ast/parser.zig:3`), so it stays. If the lexer module already lives at `src/lexer/` (yes, per `src/ast/INTERFACE.md:189`), `src/query/src/lexer.zig` may or may not exist as its own file; verify before deleting.
- Removes `zig build ast-compile-equiv` (the target's purpose is gone).

Verification:
- Full `zig build test` green on the cutover commit.
- Benchmark suite (`benchmarks/run_all.sh`) shows no regression within noise (3-run median).
- Fuzz targets (`fuzz-query`, `fuzz-parser`) run 10 minutes each.

Rollback:
- Revert the cutover commit. The deleted lexer-based compiler returns. The AST walker stays available behind `compile_via_ast = true` (the flag must be preserved on the rollback).
- If a bug surfaces **after** the deletion in a way that the revert loses progress, cherry-pick individual walker fixes onto the revert.

---

## 6. Risk register

### 6.1 AST error-tolerance vs compile-time rejection
The AST parser is total — it never returns a Zig error. The compile path must REJECT and produce a `CompileError` with offset+len matching jq's diagnostic.

Mitigation:
- After `ast.parse(src, alloc)`, if `result.errors.len > 0`, map the first error to a `CompileError`:
  - `ParseError.kind` → `ZqError` via a small mapping table (`unexpected_token`, `missing_token`, `unterminated`, `invalid_literal`, `unknown` → `.query_syntax_error`).
  - `ParseError.span` → `offset`/`len` on the `CompileError`.
- Treat any `error_node` reached during the walk as a hard abort returning the node's span.
- Audit which fixtures expect a compile error (via `h.expectCompileError`) and add those as explicit equivalence-harness fixtures: both paths must return `.err` with the same `kind` and an offset within an agreed tolerance.

### 6.2 Diagnostic position drift
The legacy compiler's `src_offset` is the token position at emit time. The AST uses `node.span.start` — typically the start of the leading token for that subtree, but not always the token that the legacy compiler was sitting on when it called `ctx.emit`.

Known cases likely to drift:
- Arithmetic: legacy stamps `+`/`-`/`*`/`/` position on the emitted opcode? (Verify by reading `parseAdditive` / `parseMultiplicative` emit sites.)
- Comparison and `or`/`and`: same question.
- `path_end`: legacy stamps the closing `)`; AST walker can stamp the call's full span end.
- Error nodes (e.g. `ctx.syntaxErr(ctx.last_tok_offset, 0)` vs AST's span start).

Mitigation:
- Before Stage 5 begins, build an offset-audit fixture set that compiles filters, prints every instruction's `src_offset`, and diffs. Document every legitimate drift.
- Consider a policy: `src_offset` must equal `node.span.start` by default; any deviation is an explicit exception. This simplifies the walker and the LSP consumes `Span` anyway.
- If byte-identical is non-negotiable: add operator-span fields to `Comparison`, `Arithmetic`, `UpdateAssign` AST nodes (one-line struct additions).

### 6.3 Performance: AST allocation overhead
The AST allocates from `std.heap.ArenaAllocator`. Every `*Node` is a heap allocation. Compile-during-tokenize paid no such cost.

Mitigation:
- Measure first. `harvestPrefilterFromAst` has been in prod since `f01eeed` with "tens of microseconds on typical filters" (compiler.zig:1512-1514). That's a single parse. Phase 2 adds zero extra parses if §1.1 folds the harvest into the compile walk.
- Arena: keep the parser's arena alive for the walker's lifetime; the walker allocates only its `RawInstr` and `intern` buffers (same as legacy).
- Perf bar: compile throughput must not regress >5% on the compile-heavy benchmark (`benchmarks/scenarios/*` cold-start). If it does, pursue one of:
  - Pool the arena across compiles (per-thread AST arena reset instead of free).
  - Re-tune `Parser.parse`'s upfront `ensureTotalCapacity`.
  - Profile for any O(n²) walk pattern.

### 6.4 Interaction with recent fixes
- **BUG-005 object-field parser (`|` inside object values)**: already in AST via `parseObjectFieldValue` at `src/ast/parser.zig:732-762`. Walker emits from `ObjectField.value` — no regression path.
- **Regex `n` flag**: AST preserves `BuiltinCall` args as nodes; walker calls the same `emitFlagPrefix`/`packRegexBuiltinOperandFlags` helpers.
- **BUG-006 forkpoint**: VM-side, no compiler-facing change.
- **`path()` validation**: VM-side; compiler only emits `path_begin`/`path_end`. No change.

### 6.5 Cutover-time regressions in prod
Once the legacy compiler is deleted (Stage 13), a regression surfaces only as a failed compat test.

Mitigation:
- Keep the equivalence harness as a build target even after deletion (it degenerates to legacy-vs-itself but serves as a fixture-driven compile smoke test). OR: delete the harness but keep the extracted fixture list as a dedicated compile-smoke test.
- The first week post-cutover, run `zig build test` under `-Dcompile-dual=true` in CI by resurrecting the legacy compiler temporarily. Only do this if the rollback plan needs teeth — otherwise it undermines the single-source-of-truth principle.

### 6.6 AST gaps for uncommon jq syntax
Some jq corner cases the token compiler handles by fallback (e.g. `def if: 1; if`) may or may not be faithfully represented by the AST. Audit:
- `def` with keyword-name (`def if: ...`): AST accepts any `isVarNameToken` token as a function name (parser.zig:1033). Compiler does the same. OK.
- `@name "literal"` with no interpolation: AST emits `format_string` with a single literal part. Compiler emits `push_string`. Bytecode equivalence: likely a mismatch unless the walker special-cases zero-interpolation format strings as `push_string`. Audit.
- `{__loc__}` shorthand: AST emits a `variable_ref("__loc__")` inside the object; the walker must translate.

---

## 7. Deliverables per stage

Numbers refer to the stages in §4.

| Stage | Files created | Files modified | Files deleted | Tests added |
|---|---|---|---|---|
| 0 | `src/ast/compiler.zig` (skeleton), `tests/ast_compile_equiv.zig`, `tests/ast_compile_equiv_fixtures.zig` | `build.zig` (new step) | — | 1 fixture |
| 1 | — | `src/ast/compiler.zig` | — | literals fixtures |
| 2 | — | `src/ast/compiler.zig` | — | field/index/suffix fixtures |
| 3 | — | `src/ast/compiler.zig` | — | pipe/comma fixtures |
| 4 | — | `src/ast/compiler.zig` | — | variables/pattern fixtures |
| 5 | — | `src/ast/compiler.zig` (maybe `src/ast/nodes.zig` op_span) | — | arith/cmp fixtures |
| 6 | — | `src/ast/compiler.zig` | — | try/if/path fixtures |
| 7 | — | `src/ast/compiler.zig` | — | object/array/interp fixtures |
| 8 | — | `src/ast/compiler.zig`, possibly `src/ast/parser.zig` + `src/ast/nodes.zig` (add `assign_general`) | — | assignment fixtures |
| 9 | — | `src/ast/compiler.zig` | — | user-function fixtures |
| 10 | — | `src/ast/compiler.zig` | — | reduce/foreach/label/break fixtures |
| 11 | — | `src/ast/compiler.zig` | — | regex/datetime fixtures |
| 12 | — | `src/ast/compiler.zig` (fold harvest) | — | prefilter equivalence |
| 13 | — | `src/query/root.zig` (swap), `build.zig` (remove steps) | `src/query/src/compiler.zig`, `tests/ast_compile_equiv.zig`, `tests/ast_compile_equiv_fixtures.zig` | — |

After Stage 13 the AST walker is the only compiler. A post-cutover cleanup commit may rename `src/ast/compiler.zig` → `src/query/src/compiler.zig` for locality; weigh against import churn.

---

## 8. Open questions

**Status (2026-04-23):** Stage 0 and Stage 1 landed. The walker at
`src/ast/compiler.zig` covers `literal` / `identity` / `recurse` /
`unary_neg`-over-literal; every other AST node kind returns
`error.AstCompilerStageIncomplete`. The equivalence harness at
`tests/ast_compile_equiv.zig` (+ `tests/ast_compile_equiv_fixtures.zig`)
runs via `zig build ast-compile-equiv` and confirms byte-identical
`Instruction[]` + `source_map` on all 16 supported Stage-1 fixtures,
with the one Stage-1 unsupported fixture (`. | .`) asserting the scaffold
boundary. No production code changed.

1. **File placement** after cutover: keep walker at `src/ast/compiler.zig` (reflects source-of-truth) or move it under `src/query/src/compiler.zig` (reflects consumer). The TODO text reads "src/ast/compiler.zig does not yet exist", suggesting the former.
2. **AST-node additions**: is it acceptable to extend `Node.Kind` with `assign_general` and to add `op_span` fields to `Comparison`/`Arithmetic`/`UpdateAssign`, or must the walker be purely consumer-side? LSP and the compiler both benefit from op_span; recommend yes.
3. **Diagnostic-offset policy**: byte-identical-or-bust, or publish a small allowlist of drifted cases? Affects Stage 5 and Stage 8 scope.
4. **Legacy-compiler deletion commit authority**: auto-delete once equivalence harness is green, or require human sign-off on the benchmark-parity run? The zero-workarounds principle argues for delete-the-moment-it's-safe; operational hygiene argues for one explicit review.
5. **Test `ast_compile_equiv_fixtures.zig` generation**: hand-maintained or generated at build time? Generated avoids drift as compat tests grow; hand-maintained is simpler to debug. Recommend generated, invoked from `build.zig` using a small zig-build tool that scans the compat files.
6. **Performance budget**: what is the acceptable compile-time overhead for an AST pass vs token walk? Current harvester pays "tens of microseconds" per compile; the full walk will be higher. Need a target number before Stage 1 starts.
7. **Filter-arg substitution semantics**: does subtree-substitution at expansion time produce bytecode byte-identical to source-range re-parse? A minor difference in `StrRef` offsets could appear if the intern buffer is written in a different order. This must be verified mid-Stage 9, not at the end.

---

End of plan.
