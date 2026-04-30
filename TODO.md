# TODO

Items known to be unfinished but not yet promoted to `ROADMAP.md`. Each entry
should move to `ROADMAP.md` (if becoming a milestone goal) or to `bugs.md` (if
it turns into a named defect) as it matures. Delete entries as they resolve.

Last verified: 2026-04-30.

## Active

### SSOT: VM int→float coercion duplicated

`src/vm/root.zig` has `toFloat(val: StackValue)` (the canonical
StackValue → f64 coercion) but arithmetic ops open-code
`@floatFromInt(i)` 25+ times instead of calling it. Sites include
L2726, L2731, L2901, L2905, L3165, L3173, L3397, L3401, L3408, L3453,
L3458, L5350, L5355, L5427, L5432, L5437, L5601, L5606, L5654, L5659,
L5664, L7452, L7493, L7501, L7608, L7618. Route every int→float coercion
through `toFloat` so type semantics live in one place.

### SSOT: LSP server bypasses typed protocol structs

`src/lsp/protocol.zig` defines `TextDocumentItem`,
`VersionedTextDocumentIdentifier`, `TextDocumentContentChangeEvent` per
the LSP spec. `src/lsp/server.zig` parses `didOpen`/`didChange`/
`didClose` payloads ad-hoc via `getString` / `getObject` helpers (see
L230-260 for didChange). Wire payload parsing through the typed structs
so the LSP wire format has a single source of truth.

### Feature gap: completion floods all builtins

`src/lsp/features/completion.zig:addBuiltinCompletions` emits all 134
builtins flat regardless of context. `src/lsp/builtins.zig:byCategory`
is the correct primitive for category-aware filtering but is never
called. Wire `byCategory` (or richer scoring) into completion so
results match the cursor context.

