# TODO

Items known to be unfinished but not yet promoted to `ROADMAP.md`. Each entry
should move to `ROADMAP.md` (if becoming a milestone goal) or to `bugs.md` (if
it turns into a named defect) as it matures. Delete entries as they resolve.

Last verified: 2026-05-05.

## Active

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
