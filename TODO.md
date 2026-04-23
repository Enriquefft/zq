# TODO

Items known to be unfinished but not yet promoted to `ROADMAP.md`. Each entry
should move to `ROADMAP.md` (if becoming a milestone goal) or to `bugs.md` (if
it turns into a named defect) as it matures. Delete entries as they resolve.

## Active

1. **Regex `n` flag — implement jq semantics.**
   Currently rejected at compile time (commit `e69b413`). jq's `n` alters match
   and capture output for unmatched optional groups across every regex builtin
   (`test`, `match`, `capture`, `scan`, `sub`, `gsub`, `splits`). A correct
   implementation needs either an operand bit, `_n` opcode variants, or a
   runtime flag threaded through `ResultIterator`. Rejection is loud, not
   silent — reversing it when the semantics are ready is trivial. See also the
   `n` flag row under ROADMAP.md's "Regex" section.

2. **AST-walk compile pipeline (Phase 2).**
   The AST parser in `src/ast/` is already the source of truth for the LSP
   (`src/lsp/`) and for the compiler's prefilter harvester, but the main
   compile path still runs recursive-descent directly on tokens. Phase 2
   replaces the compile path with an AST walk so there is one canonical
   representation (see `CLAUDE.md` §3). Tracked further in the auto-memory
   under "Pending (Phase 2)".

3. **Phase 0 full microbench.**
   `just bench` currently routes to the regex latency probe (`zig build
   bench-regex`), which covers one class of work. Phase 0 of the research
   roadmap rebuilds a full per-stage microbench covering parse / lookup /
   predicate / serialize / coord — see `research/phase-0-design.md` §4.
   Noted in auto-memory on 2026-04-07.
