# IR Text Format — Stable Spec

> **Revision**: 2 (Phase 8 — load_-prefix editorial pass). Plan §1.3 row 5 owns the names; spec mirrors. Subsequent changes require a new revision banner + user approval.

---

## 1. Purpose & scope

This document specifies the IR text dump format produced by `-Ddebug-ir=true` and
consumed by snapshot tests in R3 (Phase 5/6 in orchestrator schedule). The format is
the single canonical surface for human-readable IR inspection and automated snapshot
diffing. Out-of-scope: IR implementation (`ir.zig`), lowering rules (`lower.zig`),
fuse rewrite rules (`fuse.zig`), bytecode emission (`emit.zig`), and all performance
considerations.

---

## 2. Format overview

The dump is an indented tree. Every node occupies exactly one line; children appear
directly below their parent, indented +2 spaces per level. Blank lines are not
emitted. Lines starting with `#` are comments; snapshot diff tooling ignores them
(OPTIONAL — used for section banners and source headers only, never emitted by
normal node serialization).

**Line shape:**

```
<INDENT><op_tag>(<payload>) @<start>..<end>
```

- `INDENT` — two spaces per depth level; root nodes have no indent.
- `op_tag` — ASCII identifier; see §3 and §4.
- `(<payload>)` — present only when the node carries inline data; omitted entirely
  (no parens) when there is no payload.
- `@<start>..<end>` — source byte span; always emitted (never omitted).
- Fields are separated by a single space; no trailing spaces; UNIX newlines only.

**Example** (`.foo | .bar`, 11 bytes):

```
(* byte map: '.'=0 'f'=1 'o'=2 'o'=3 ' '=4 '|'=5 ' '=6 '.'=7 'b'=8 'a'=9 'r'=10 *)
pipe @0..11
  load_field("foo") @0..4
  load_field("bar") @7..11
```

---

## 3. Node syntax

```ebnf
dump       ::= ( directive | comment | node )* EOF
comment    ::= "#" [^\n]* NEWLINE
node       ::= INDENT op_tag payload? span NEWLINE child*
child      ::= node                  (* indented +2 from parent *)

INDENT     ::= "  " *               (* 0..N pairs of two spaces *)
op_tag     ::= ALPHA ( ALPHA | DIGIT | "_" )*
ALPHA      ::= [A-Za-z]
DIGIT      ::= [0-9]

payload    ::= "(" payload_item ( "," SPACE payload_item )* ")"
payload_item ::= string_lit           (* quoted string value — positional, comes first *)
               | index_lit            (* bare decimal u32 — positional, comes first *)
               | pool_ref             (* regex pool reference — positional, comes first *)
               | flag_set             (* flag bitset — keyword arg, always after positional items *)
               | extra_fallback       (* error-recovery fallback — keyword arg, always last *)

string_lit ::= DQUOTE char* DQUOTE   (* JSON-style escapes: \n \t \\ \" \uXXXX *)
index_lit  ::= UINT                  (* decimal u32, no prefix *)
pool_ref   ::= "re_" UINT SPACE string_lit  (* pool index + pattern source *)
flag_set   ::= "flags=" UINT         (* raw decimal bitset for update-assign op kind *)
extra_fallback ::= "extra=" UINT     (* error-recovery fallback; emitted only when inline
                                        resolution fails; well-formed IR never produces this *)

span       ::= "@" UINT ".." UINT    (* source byte range; start inclusive, end exclusive *)

UINT       ::= DIGIT+                (* decimal u32; no leading zeros except "0" itself *)
SPACE      ::= " "
DQUOTE     ::= "\""
NEWLINE    ::= "\n"
```

**Payload argument order (pinned):**
Positional args (string_lit, index_lit, pool_ref) always precede keyword args (flag_set,
extra_fallback). Example: `update_assign("k", flags=3)` — string arg first, then flag_set.

**Control-character escaping in string_lit:**
Raw control characters (bytes 0x00–0x1F, other than `\t` (0x09) and `\n` (0x0A)) MUST be
escaped as `\uXXXX` (four uppercase hex digits). Bytes ≥ 0x80 are forbidden inside op_tag
and INDENT tokens (ASCII-only), but are permitted inside string_lit as raw UTF-8 since they
originate from source text. The JSON-style escape rules for string_lit cover only the
characters listed above; all other bytes are emitted as-is.

### §3a. Snapshot file directives

Snapshot files use structured `#`-prefixed directive lines. The dumper emits these
directives; generic comment lines (non-directive `#` lines) MUST NOT be emitted by the
dumper and are tolerated only for human annotation in committed snapshots.

```ebnf
directive      ::= "#" SPACE directive_name (":" (SPACE directive_arg)?)? NEWLINE
directive_name ::= "source" | "before" | "after" | "SemOp" | "EmitOp"
directive_arg  ::= string_lit | filter_text
filter_text    ::= ( PRINTABLE_ASCII )+   (* any printable ASCII, no NEWLINE *)
```

**Placement rules:**

| Directive | File type | Position |
|---|---|---|
| `# source: <filter>` | lower, fuse | First line of the file |
| `# before` | fuse only | Before the pre-rewrite IR dump (after `# source:`) |
| `# after` | fuse only | Before the post-rewrite IR dump |
| `# SemOp` | lower, fuse | Opening banner of a SemOp IR block |
| `# EmitOp` | fuse only | Opening banner of an EmitOp IR block |

**Delimiter conventions (pinned):**
- Payload is always wrapped in `(` `)` when present; no brackets elsewhere.
- Multi-field payloads use `, ` (comma + one space) between items.
- `span` is introduced by `@` immediately after a single space following the closing `)`,
  or after the `op_tag` when there is no payload. No other separators.
- Pool references encode both the pool index (for round-trip debugging) and the
  pattern source (for human readability): `re_4 "/^foo/"`.
- All characters in `op_tag` are ASCII; no Unicode, no hyphens.
- Numbers are decimal; no hex, no octal.

---

## 4. Op namespace split

Plan §1.3 row 6 (verbatim):

> **Op-namespace split.** Single IR struct, but `Op` enum has two subranges in the
> same file:
> - `SemOp` (lowered from AST — semantic ops)
> - `EmitOp` (produced by fuse for emission shortcuts: `load_path`, `key_exists`,
>   etc. — none today; reserved namespace for fuse's output and future passes)
> Switch tables enumerate one namespace at a time.

**Convention chosen: flat tag names.** Op tags are emitted without a namespace
prefix (e.g., `load_field`, `pipe`, `key_count`). The dump separates namespaces with a
comment banner line so the split is visible without verbose prefixes:

```
# SemOp
pipe @0..11
  load_field("foo") @0..4
  load_field("bar") @7..11
# EmitOp
key_count @0..13
```

The `# SemOp` / `# EmitOp` banners are emitted once per dump at the boundary
between the two namespaces. Within a single-namespace dump (R3 phase — no EmitOp
nodes yet) only `# SemOp` is emitted as the opening banner.

**Cross-namespace tag uniqueness:** Op tag names are unique across all namespaces
(SemOp, EmitOp, future). A tag in `# EmitOp` namespace must not collide with any tag
in `# SemOp` or any other namespace, ensuring an unambiguous flat dump.

---

## 5. Span encoding

**Syntax:** `@<start>..<end>` where `start` and `end` are decimal `u32` source byte
offsets (start inclusive, end exclusive), counting from byte 0 of the filter string.

**Span coverage rules:**
- For leaf nodes the span covers the source token range exactly, including any leading
  `.` for `load_field` nodes (e.g., `.foo` → `@0..4`, not `@1..4`).
- For composite nodes the span covers the entire source range governed by the node,
  from the first byte of the first child to one past the last byte of the last child.

**Stability contract** (plan §1.2, verbatim):

> Compile-error source position must match on the curated error-fixture set defined
> in §1.4 row 5; elsewhere positions are free.

The IR text format **always emits spans** — they are never omitted. Snapshot files
therefore always carry spans. This means snapshot regeneration is required when
span emission changes, but there is no ambiguity about whether a span is present.

---

## 6. Extra-data encoding

For nodes that carry non-child scalars via `Node.extra → extra_data[]` (plan §1.3
row 5: "string-buf ids, regex-pool ids, flag bitsets"), the dump renders values
**inline** inside the payload parentheses — opaque indices are not emitted alone.

| Data type | Dump form | Example |
|---|---|---|
| String-buf id | resolved literal, quoted | `load_field("foo")` |
| Regex pool id | pool index + pattern source | `match(re_4 "/^foo/i")` |
| Update-assign op kind | `flags=` + decimal bitset | `update_assign("k", flags=3)` |
| Format-spec id | resolved format name, quoted | `format("@base64")` |
| Unresolved extra index (fallback) | `extra=` + decimal index | `some_op(extra=7)` |

**Rationale:** diffable strings beat opaque indices for snapshot review. When both
the pool index and the pattern source are needed (regex), both are emitted (see
`pool_ref` in §3).

When an inline value cannot be resolved (e.g., during a partial dump of a malformed
IR), the fallback form `extra=<UINT>` (bare index, `extra_fallback` in §3 EBNF) is
emitted. This is an error-recovery path only; well-formed IR never produces bare
`extra=` in snapshots. It is a valid `payload_item` for round-trip safety.

### Regex pool refs

Pool ref form: `re_<UINT> SPACE STRING_LIT` where:

- `<UINT>` is the pool index (decimal).
- `STRING_LIT` content is `/<pattern>/<flags>` — literal slashes delimit the pattern
  from the flags. Inner forward slashes in `<pattern>` are NOT escaped (the surrounding
  string_lit's JSON escape rules are applied independently of the regex syntax).
- `<pattern>` is the source text exactly as written by the user (pre-compile form).
- `<flags>` is the literal flag suffix (e.g., `i`, `imsx`); empty string if no flags,
  but the trailing `/` is still required: `"/^foo/"` (no flags), `"/^foo/i"` (flag `i`).
- The `STRING_LIT` uses JSON-style escapes: `\\` (backslash), `\"` (double-quote),
  `\n`, `\t`, `\uXXXX`. A backslash in the regex source becomes `\\` in the
  string_lit; a forward slash in the source stays as `/` (no escaping needed).

**Worked example:** regex source `/foo\/bar/i` (user wrote a backslash-escaped slash):
- `<pattern>` = `foo\/bar` (source text verbatim, backslash preserved)
- `<flags>` = `i`
- string_lit content = `/foo\/bar/i` → JSON-escaped → `"/foo\\/bar/i"`
- Pool ref render: `re_3 "/foo\\/bar/i"`

(The `\` in source becomes `\\` per JSON string_lit escaping; the `/` stays raw.)

---

## 7. Variable-arity children

Nodes with ≥ 3 children store their children in `extra_children` (plan §1.3 row 5).
The dump renders all children as indented child lines below the parent node,
regardless of whether the IR stores them in `Node.children[0..1]` or in a
`(start, len)` span into `extra_children`. This is an implementation detail
invisible to the dump.

**Example** (`if .a then .b else .c end`, 25 bytes):

```
(* byte map: 'i'=0 'f'=1 ' '=2 '.'=3 'a'=4 ' '=5 't'=6 'h'=7 'e'=8 'n'=9
             ' '=10 '.'=11 'b'=12 ' '=13 'e'=14 'l'=15 's'=16 'e'=17 ' '=18
             '.'=19 'c'=20 ' '=21 'e'=22 'n'=23 'd'=24 *)
if @0..25
  load_field("a") @3..5
  load_field("b") @11..13
  load_field("c") @19..21
```

The `arr_ctor`, `obj_ctor`, `interp`, `foreach`, and `call_user`/`call_builtin`
nodes follow the same rule: all children appear indented below the parent, ordered
as the IR stores them in `extra_children`.

---

## 8. Snapshot test usage

Plan §3 R3 step 9 (verbatim):

> **Snapshot tests:**
> - For each new IR shape: `tests/compiler/snapshots/lower/<name>.txt`
>   (AST source string → IR dump in indented-tree format).
> - For each fuse rewrite: `tests/compiler/snapshots/fuse/<name>.txt`
>   (IR before → IR after).
> - IR text format: indented tree, one node per line, child indent +2 spaces,
>   payload after node tag. Spec: `research/compiler-ir-format.md`.
> - Regeneration: `zig build snapshots-update` rewrites every snapshot from
>   current new-compiler output. Intended for deliberate IR changes only; CI
>   fails on any uncommitted snapshot diff.

**File conventions:**

- **Lower snapshot** (`tests/compiler/snapshots/lower/<name>.txt`):
  ```
  # source: .foo | .bar
  # SemOp
  pipe @0..11
    load_field("foo") @0..4
    load_field("bar") @7..11
  ```

- **Fuse snapshot** (`tests/compiler/snapshots/fuse/<name>.txt`):
  ```
  # source: keys | length
  # before
  # SemOp
  pipe @0..13
    call_builtin("keys") @0..4
    call_builtin("length") @7..13
  # after
  # EmitOp
  key_count @0..13
  ```

- The `# source:` header line(s) come first; the body (starting with the namespace
  banner) follows immediately.
- Snapshot filenames are snake_case ASCII, e.g., `load_field.txt`,
  `pipe_chain.txt`, `keys_length_fuse.txt`.

---

## 9. Stability guarantees

The format is **append-only**:

- New op tags MAY be added without requiring user signoff; snapshot regeneration is
  expected and acceptable for the affected tests.
- Existing op tag names MAY NOT be renamed or repurposed.
- Payload structure for any existing op tag MAY NOT change (field order, quoting,
  delimiter).
- Span and extra encoding rules (§5, §6) are frozen.
- The indent step (2 spaces), delimiter conventions (§3), and comment marker (`#`)
  are frozen.
- Bulk regenerations that touch ≥ 10 snapshot files require explicit user signoff
  (commit message must include `SNAPSHOT-BULK-REGEN: <reason>`).

---

## 10. Examples

### Trivial: `.foo`

```
# source: .foo
# SemOp
load_field("foo") @0..4
```

### Pipe: `.foo | .bar`

```
# source: .foo | .bar
# SemOp
pipe @0..11
  load_field("foo") @0..4
  load_field("bar") @7..11
```

### Array index: `.[0]`

```
# source: .[0]
# SemOp
load_index(0) @0..4
```

### Fuse rewrite: `keys | length` → `key_count`

```
# source: keys | length
# before
# SemOp
pipe @0..13
  call_builtin("keys") @0..4
  call_builtin("length") @7..13
# after
# EmitOp
key_count @0..13
```

### Regex match: `test("^foo")`

```
# source: test("^foo")
# SemOp
call_builtin("test", re_0 "/^foo/") @0..13
```

### Label / break: `label $out | <body>`, `break $out` (cat-15 / Phase 24)

The `label` SemOp wraps a body with a named non-local-exit binding.
Lowering allocates a fresh `var_id` for `$name` via `declareLabelVar`,
which records the id in `Lowerer.label_var_ids` so `break $name` can
verify the binding is a label (not a regular `as` binding). The body
lowers under a scope that sees `$name`; the binding pops once lowering
returns. `extra_data[node.extra]` holds the var_id; `children[0]` is
the body IR-node index.

Emit (`emit.zig:emitLabel`) mirrors legacy `compileLabel`
(`src/query/src/compiler.zig:3628`) byte-for-byte:
`label_begin(exit_ip) ; capture_variable($var_id) ; pipe ; <body>` then
backpatches `exit_ip` to one past the body. No `label_end` /
`pop_variable` are emitted — iterate-loops would re-execute them on
every backtracking pass and prematurely clear the LabelFrame +
break-token (legacy makes the same omission at `compiler.zig:3661-3667`).

The `break_` SemOp is a leaf — `extra_data[node.extra]` carries the
resolved label var_id; no children. Lookup happens at lower time via
`lookupLabelVar`, which surfaces `LowerDiagnostic` with
`query_syntax_error` when the name is undefined or refers to a
non-label binding (mirrors legacy `compiler.zig:6252-6261`). Emit
(`emit.zig:emitBreak`) writes `load_variable($var_id) ; break_op`,
matching legacy's `parsePipe` `.break_kw` arm at `compiler.zig:6245`.

```
# source: label $out | .
# SemOp
label("out") @0..14
  identity @13..14
```

```
# source: label $out | break $out
# SemOp
label("out") @0..23
  break("out") @13..23
```

The dump renders `label("name")` / `break("name")` (source-level name,
quoted) for the AST-walking dumper so snapshots stay readable. The
IR-walking dumper renders `label(var_id=N)` / `break(var_id=N)` —
emit's resolved binding is the contract there. Both forms quote the
name through `writeStringLit` so escape handling is uniform with
other string-bearing payloads.

Invariant: every `break` SemOp's var_id is present in some enclosing
`label` SemOp's `label_var_ids` entry at lower time. Lowering enforces
this; emit assumes it. Nested labels stack (the inner-label binding
shadows the outer name in `var_table`, but both ids remain in
`label_var_ids` so `break $outer` from within the inner body still
resolves through the outer name).

### While / until: `while(cond; update)`, `until(cond; update)` (cat-15 / Phase 24)

Both 2-arg loop builtins lower from `BuiltinCall{name, args=[cond,
update]}` into dedicated SemOps `while_` / `until_` (the `while_until_2arg`
class in `lower.zig:classifyBuiltin`). Children are fixed-arity:
`children[0] = cond`, `children[1] = update`. No `extra_data` payload —
the SemOp tag carries the discriminant.

Why dedicated SemOps rather than `call_builtin`: both shapes carry
backward-jump patch-table semantics (`loop_top` target, `jump_if_false`
fork, in-loop yield/pipe sequence) that don't reduce to a flat
`call_builtin` operand. The IR shape is fixed so emit can wire the
patches without re-decoding.

Emit (`emit.zig:emitWhile`) mirrors legacy `compileWhile`
(`src/query/src/compiler.zig:3428`):

```
loop_top:
  save_input ; <cond> ; jump_if_false → loop_exit
  restore_input ; yield_output ; <update> ; pipe
  jump → loop_top
loop_exit:
  restore_input ; backtrack
```

Emit (`emit.zig:emitUntil`) mirrors legacy `compileUntil`
(`src/query/src/compiler.zig:3495`):

```
loop_top:
  save_input ; <cond> ; jump_if_false → loop_body
  restore_input ; jump → loop_done
loop_body:
  restore_input ; <update> ; pipe ; jump → loop_top
loop_done:
  push_current
```

Invariant: `loop_top` is the IP at the start of the SemOp's emission,
captured before any instruction is pushed. `jump_if_false` /
`jump → loop_done` operands are placeholder-zero at push time and
backpatched after the corresponding target IP is known. The fixed-arity
`children` slot keeps the cond/update wiring stable across snapshot
regeneration.

```
# source: while(.<100; .*2)
# SemOp
while @0..17
  cmp(lt) @6..11
    identity @6..7
    load_const(100) @8..11
  arith(mul) @13..16
    identity @13..14
    load_const(2) @15..16
```

```
# source: until(.>=10; .+1)
# SemOp
until @0..17
  cmp(ge) @6..11
    identity @6..7
    load_const(10) @9..11
  arith(add) @13..16
    identity @13..14
    load_const(1) @15..16
```

The AST-walking dumper recognizes `while` / `until` by name+arity in
`builtin_call` and renders the IR-shape directly (op tag without
parens, two indented children). The dumped op tag strips the trailing
underscore from the IR enum (`while_` → `while`, `until_` → `until`)
per the §3 op-name convention.

---

## 11. Out-of-scope

The following concerns are explicitly out of scope for this document:

- **Op enum definitions / count** — defined in `src/compiler/ir.zig` (R3 / Phase 5).
- **Lowering rules** (AST → IR) — defined in `src/compiler/lower.zig` (R3).
- **Fuse rewrite rules** — defined in `src/compiler/fuse.zig` (R3).
- **Bytecode emission** — defined in `src/compiler/emit.zig` (R3).
- **IR implementation** — node struct layout, `extra_children` / `extra_data` arrays,
  arena scoping, comptime size assert — all in `ir.zig`.
- **Snapshot directory creation** — directories exist only after R3 scaffolding.
- **Performance considerations** of any kind.
