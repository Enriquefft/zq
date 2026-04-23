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

4. **`tests/fuzz_regex.zig` portability + test-race hygiene.**
   Two pre-existing issues, only reachable via `zig build fuzz-regex` (not
   `test_step`), so CI never hits them today. Both surface if the fuzz step
   ever enters CI or runs on non-Linux:
   - Line 346 calls `std.posix.memfd_create` unconditionally; stdlib emits a
     `@compileError` on non-Linux. Apply the same comptime-gate pattern that
     `tests/pool_test.zig:30-42` now uses.
   - The input path `/tmp/zq_fuzz_regex_input.json` is fixed, so two
     concurrent fuzz invocations race on the same file. Suffix with the PID
     (the harness already has a `currentPid()` helper since commit `f62c8e0`).
