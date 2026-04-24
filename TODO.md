# TODO

Items known to be unfinished but not yet promoted to `ROADMAP.md`. Each entry
should move to `ROADMAP.md` (if becoming a milestone goal) or to `bugs.md` (if
it turns into a named defect) as it matures. Delete entries as they resolve.

Last verified: 2026-04-23.

## Active

1. **Regex `n` flag — implement jq semantics.**
   Currently rejected at compile time (commit `e69b413`, verified: the `n`
   branch falls into the `else` arm of `emitFlagPrefix`'s flag-character
   switch at `src/query/src/compiler.zig:3318-3324` and surfaces
   `error.RegexCompileError`). jq's `n` alters match and capture output for
   unmatched optional groups across every regex builtin (`test`, `match`,
   `capture`, `scan`, `sub`, `gsub`, `splits`). A correct implementation
   needs either an operand bit, `_n` opcode variants, or a runtime flag
   threaded through `ResultIterator`. Rejection is loud, not silent —
   reversing it when the semantics are ready is trivial. See also the `n`
   flag row under ROADMAP.md's "Regex" section.

2. **AST-walk compile pipeline (Phase 2).**
   The AST parser in `src/ast/` is already the source of truth for the LSP
   (`src/lsp/`) and, since commit `f01eeed`, for the compiler's prefilter
   harvester (`harvestPrefilterFromAst` at
   `src/query/src/compiler.zig:1370 / 1520-1607` calls `ast.parse` directly).
   The main compile path still initializes a `Lexer` at
   `src/query/src/compiler.zig:1313` and runs recursive descent on tokens.
   Phase 2 replaces the compile path with an AST walk so there is one
   canonical representation (see `CLAUDE.md` §3). `src/ast/compiler.zig`
   does not yet exist. Tracked further in auto-memory under
   "Pending (Phase 2)".

3. **Full per-stage microbench (Phase 0 of research track).**
   `justfile:19-21` routes `just bench` to `zig build bench-regex`, which
   works today (the earlier "broken" framing was incorrect — there is no
   dangling reference to a removed `./zig-out/bin/microbench`). What is
   actually missing: a per-stage microbench covering
   parse / lookup / predicate / serialize / coord, gated behind
   `-Dprofile=true` comptime hooks. Neither the harness nor the design
   writeup (`research/phase-0-design.md`, referenced previously but
   nonexistent as of 2026-04-23) has landed. Historical per-record
   numbers (parse 1.30 µs, lookup 0.32 µs, output 0.38 µs) came from an
   earlier `src/microbench.zig` that is no longer in the tree.

4. **`tests/fuzz_regex.zig` portability — `memfd_create` comptime gate.**
   `tests/fuzz_regex.zig:346` still calls
   `std.posix.memfd_create("zq_fuzz_pf", 0)` unconditionally; stdlib emits a
   `@compileError` on non-Linux. Apply the same comptime-gate pattern that
   `tests/pool_test.zig:32-38` now uses
   (`if (comptime @import("builtin").os.tag == .linux) { … }`). Only
   reachable via `zig build fuzz-regex` (`build.zig:426`), which is not in
   the default `test_step`, so CI never hits it. The sibling
   `/tmp/zq_fuzz_regex_input.json` race was already fixed in commit
   `f62c8e0` — the path is now suffixed with `currentPid()`
   (`tests/fuzz_regex.zig:182-183`).

5. **`path()` validation — close the two remaining gaps.**
   `f43d8b3` shipped validation via `breaksPath`/`clearsPathBroken` tables
   on `Op` (`src/types.zig:943-1028` and `:1040-1057`; VM enforcement at
   `src/query/src/vm.zig:815-821` and the `path_end` check at
   `:1682-1689`). Two gaps remain vs jq; the previously-listed third gap
   (`$x | path($x.a)`) is a phantom — jq and zq both accept it and return
   `["a"]`, so `load_variable` being PRESERVING is correct.
   - **Nested `path(path(.a))`** returns `["a"]`; jq errors
     `Invalid path expression with result ...`. Fix: treat `path_end`'s
     pushed array as path-breaking for the outer frame (e.g., a post-op
     clear exception, or set `path_broken` on the outer frame inside
     `path_end` when `path_stack.len >= 2`).
   - **`path(recurse)`** returns `["recurse"]`; jq emits all paths. Fix:
     whitelist `recurse`, `paths`, `leaf_paths`, `..` as preserving when
     called inside a `path()` frame (per-builtin table, or recognize their
     `call_builtin` variants).

6. **Surface `user_error_msg` in stdin (pool) and file-arg modes.**
   `src/main.zig:554` passes `null` for `user_message` in the pool branch,
   so `error("msg")` and `"Invalid path expression with result X"` never
   reach the user on stdin inputs. The `-n` branch (`src/main.zig:519`),
   slurp branch (`:527`), and file-arg branch (`:580`) already pass
   `diag.user_error_msg` through to `formatDiagnostic()`. The pool path
   does not carry `iterator.user_error_msg` into its `RecordMeta`
   (`src/pool/root.zig:142`), so the message is lost between worker and
   collector even though `formatDiagnostic` (`src/error/root.zig:219-221`)
   already prints it when non-null. Wire a per-chunk diagnostic out of
   `pool` so the pool branch can pass the real message.
