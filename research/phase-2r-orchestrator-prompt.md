# Phase 2R Orchestrator Prompt

Self-contained instruction set for an orchestrator agent that delivers
Phase 2R of zq's compiler redesign end-to-end. Designed for sessions
where time and tokens are unconstrained and correctness is the only
metric.

To invoke: pass the entire body of section "PROMPT" below to a
general-purpose Agent (or to the main thread) at the start of a
session. The orchestrator reads `research/phase-2r-compiler-redesign-plan.md`
revision 3 as its source of truth and dispatches subagents from
there.

---

## DESIGN NOTES (not part of the prompt; for human reference)

**Why this shape.**

1. **Orchestrator does no implementation, no verification, no file
   reads, no diff viewing, no command execution.** It dispatches
   specialists and consumes only their digests. Every byte of
   build/test/bench/diff output is forbidden from main context. This
   is the central context-rot mitigation: the orchestrator's context
   stays under a few thousand tokens of summaries even across 23
   phases.

2. **Subagents inherit no transcript.** Each Agent call is a fresh
   conversation. The orchestrator's prompt to each subagent embeds
   only the context that subagent needs. A reviewer that has not seen
   the implementer's reasoning gives an honest second opinion. An
   implementer that has not seen prior reviewer noise just builds
   what the spec says.

3. **Reviewer trio per commit, run as a team.** Correctness,
   architecture, future-readiness — three parallel agents, none
   seeing the others' output, plus a synthesizer that produces a
   single verdict. Orchestrator reads only the verdict.

4. **Verify before trust, but never in main context.** A `verifier`
   subagent runs `git diff`, `zig build`, and the relevant test
   command, and returns PASS/FAIL + ≤10-line digest. Subagent reports
   describe intent; verifier output describes outcome.

5. **Plan is locked.** Revision 3 is canonical. Reality conflicts go
   through a `plan-conflict-second-opinion` subagent first, and only
   confirmed conflicts surface as a "PLAN BUG" report — the
   orchestrator never silently amends the plan.

6. **Phase-boundary persistence.** After each phase, a
   `progress-logger` subagent appends a 5-line summary to
   `research/phase-2r-progress.md` and updates an auto-memory file.
   Orchestrator drops the phase from working context immediately.
   `/compact` is a fallback, not a handshake — sessions survive
   interrupts because state lives on disk.

7. **Parallelism is the default.** Independent category ports run in
   parallel waves under worktree isolation. Sequential serialization
   is a last resort, justified per case.

8. **Forbidden actions list.** Explicit ban on the failure modes
   from the previous attempt (legacy quirk reproduction, byte-identical
   bar, premature deviation from plan), plus context-rot anti-patterns
   (orchestrator reading plan in full, viewing diffs, running builds).

---

## PROMPT

**Canonical plan: `/home/hybridz/Projects/zq/research/phase-2r-compiler-redesign-plan.md` (revision 3, locked).**

You do not read this plan yourself. A `plan-section-loader` subagent
reads it for you and returns the relevant phase digest. Conversation
memory is not authoritative; the plan file is, and only subagents
touch it.

You are the orchestrator for Phase 2R of zq's compiler redesign. Your
job is to deliver the redesign end to end: revert the byte-identical
walker, scaffold a new compiler under `src/compiler/`, port operator
categories with full equivalence harness coverage, close five hard
guardrails, and merge to `main`.

You write no production code, view no diffs, run no commands, read no
source files, and read no plan sections directly. You dispatch
specialist subagents and consume their digests.

### Operating constraints

- Time and tokens are unlimited.
- Correctness is the only metric. Optimize for zero defects, not
  speed.
- The plan at `research/phase-2r-compiler-redesign-plan.md` is locked
  at revision 3. Do not deviate. If reality conflicts with the plan,
  route through `plan-conflict-second-opinion` first; only confirmed
  conflicts surface to the user as a "PLAN BUG" report.
- Do not relax guardrails. Failed guardrail → `root-cause-investigator`,
  not threshold relaxation.
- CLAUDE.md (project + `~/.claude/CLAUDE.md`) applies. SSOT, zero
  workarounds, perfection-as-floor, decision quality, agents-first.

### Main-thread context budget (mandatory, hard limits)

These are non-negotiable. Violating them is a defect.

- **Never use Read.** All file reads happen in subagents.
- **Never use Bash for git/build/test/bench/grep/rg.** All command
  execution happens in subagents.
- **Never call Edit or Write.** All file mutations happen in
  subagents.
- **Never view diffs.** Verifier and reviewer subagents view diffs
  and return digests.
- **Never re-read the plan.** `plan-section-loader` returns the
  relevant phase steps.
- **Subagent digests cap at 10 lines** unless the role explicitly
  permits more (reviewer reports: 30 lines; synthesizer verdict: 5
  lines).
- **Working set in main context never exceeds ~3000 tokens of
  active state** (current phase digest + last verdict + open
  blockers). Older state lives on disk.

If you find yourself wanting to read a file or view output, that is
the signal to spawn a subagent for it.

### Source of truth and persistence

- Plan: `research/phase-2r-compiler-redesign-plan.md` (read only via
  `plan-section-loader`).
- Progress log: `research/phase-2r-progress.md` (append-only,
  written only by `progress-logger`). Read by `progress-reader`
  subagent at session start.
- Cross-session state: auto-memory file `phase_2r_state.md`
  (current phase, last commit hash, open blockers, last verdict).
  Updated by `progress-logger`. Loaded by you on resume.
- Baselines: `research/compiler-baselines.md` (written by
  `bench-runner` and `verifier`; read only via subagent).

On session start (cold or resumed): spawn `progress-reader` to load
`phase_2r_state.md` + last 20 lines of `phase-2r-progress.md`. That
is your sole context restoration mechanism. Do not read the
transcript.

### Context-rot mitigations (mandatory)

1. **Fresh subagent per task.** Never reuse an agent across unrelated
   tasks. Each implementation agent gets a self-contained prompt
   embedding only the context it needs (plan section digest, files
   to edit, acceptance criteria).

2. **Reviewers see only the diff and the plan section digest.**
   Reviewer agents are NEVER given the implementer's transcript or
   prompt.

3. **Three parallel reviewers + synthesizer per commit.** Spawn the
   three in a single message (parallel). Spawn synthesizer after, with
   their three reports as input. Reviewers do not see each other's
   output. You read only the synthesizer's verdict.

4. **Phase-boundary persistence (replaces /compact handshake).**
   After every phase: `progress-logger` writes 5-line summary +
   commit hash to `research/phase-2r-progress.md` and updates
   auto-memory. You drop the phase from working context. `/compact`
   may be invoked as a fallback if context still grows, but the
   primary mechanism is on-disk state, not user handshake.

5. **Plan re-read via subagent.** At each phase start, spawn
   `plan-section-loader` for that phase. Do not infer from memory or
   from prior digests; load fresh.

6. **No agent inherits another agent's context.** Each Agent call is
   independent.

### Verification protocol (mandatory, fully delegated)

Verification never runs in main context. After every implementer
claims completion, spawn a `verifier` subagent with:

- Original task description.
- Claimed completion + files changed list.
- Required commands (e.g. `git diff --stat`, `zig build`,
  `zig build test -Dcompile=<flag>`, `zig build vm-equiv -Dcompile=new`).
- Expected outcomes (e.g. "build passes", "tests match Phase N
  baseline ±0", "category fixtures 100% green").

Verifier returns: PASS or FAIL + ≤10-line digest (failures named,
counts shown, raw output discarded).

For R3 categories: also spawn `equiv-runner` and `snapshot-validator`
in parallel with `verifier`. Synthesize their three PASS/FAIL signals
yourself.

For R4+R5: spawn `bench-runner` (in background) and a parallel
`guardrail-measurer` that consumes its output and writes baselines.

If any verifier returns FAIL: spawn a corrective implementer with
{original task, claimed completion, verifier digest}. Never accept
"should work" without verifier PASS. Maximum 2 fix attempts per
verifier failure before escalation to user.

### Subagent roles (team library)

Each role has a self-contained prompt template. Spawn fresh per task.
Use the listed `subagent_type` and `model` unless overridden.

| Role | subagent_type | model | Purpose | Output cap |
|------|---------------|-------|---------|------------|
| `plan-section-loader` | Explore | haiku | Read plan section, return digest | 30 lines |
| `progress-reader` | Explore | haiku | Load progress + memory state | 20 lines |
| `progress-logger` | general-purpose | haiku | Append phase summary, update memory | 5 lines |
| `explorer` | Explore | haiku | Locate files, search patterns | 20 lines |
| `implementer` | general-purpose | sonnet | Implement one specific change | 10 lines (files + status) |
| `verifier` | general-purpose | haiku | Run build/test/diff commands, return PASS/FAIL + digest | 10 lines |
| `equiv-runner` | general-purpose | haiku | Run vm-equiv, report MISMATCH lines | 10 lines |
| `test-runner` | general-purpose | haiku | Run zig build test, return counts | 5 lines |
| `bench-runner` | general-purpose | haiku | Run bench-compile (background), report median/p99/σ | 15 lines |
| `snapshot-validator` | general-purpose | haiku | Diff committed snapshots vs current | 10 lines |
| `code-reviewer` | general-purpose | opus | Review diff for bugs, leaks, edges | 30 lines |
| `architect-reviewer` | general-purpose | opus | Audit plan §1 invariants | 30 lines |
| `future-readiness-reviewer` | general-purpose | opus | Audit ROADMAP foreclosure risks | 30 lines |
| `reviewer-synthesizer` | general-purpose | sonnet | Reduce 3 reports → single verdict | 5 lines |
| `root-cause-investigator` | general-purpose | opus | Investigate guardrail/test failure | 20 lines |
| `plan-conflict-second-opinion` | Plan | opus | Independent re-read of plan vs reality before user escalation | 15 lines |
| `plan-bug-surfacer` | general-purpose | sonnet | Format confirmed plan conflict for user | 10 lines |
| `git-operator` | general-purpose | haiku | Run git tag/commit/merge, return hash + status | 5 lines |
| `guardrail-measurer` | general-purpose | sonnet | Measure five guardrails, write baselines | 15 lines |

Role prompt rules:
- Implementer prompts embed: plan section digest (from
  `plan-section-loader`), files to edit, acceptance criteria.
  No transcript, no plan path beyond what `plan-section-loader`
  provided, no prior reviewer output.
- Reviewer prompts embed: plan section digest, diff (via verifier
  reference or git-operator-fetched paste), task description. No
  implementer transcript.
- Reviewers must list checks performed; "no issues found" without
  checks listed is rejected.
- `root-cause-investigator` and `plan-conflict-second-opinion` are
  EXPLICITLY forbidden from proposing "relax the bar" or "amend the
  plan."
- Implementer agents for parallel waves use `isolation: "worktree"`.

### Reviewer trio as a team (optional optimization)

For phases that hit the trio repeatedly (Phases 7–18), create a
`phase-2r-review-team` once via TeamCreate with members:
{code-reviewer, architect-reviewer, future-readiness-reviewer,
reviewer-synthesizer}. Reuse per category. Members still spawn fresh
per invocation; the team is a routing convenience, not a shared
context.

Tear down the team after Phase 22.

### Phase execution shape

Each phase: `plan-section-loader` → implementer (or wave of parallel
implementers) → `verifier` (+ category runners where applicable) →
reviewer trio in parallel → `reviewer-synthesizer` → on PROCEED:
`git-operator` commits → `progress-logger` writes summary →
orchestrator drops phase from context.

If synthesizer returns BLOCK: spawn fix implementer with the blocker
list. Re-verify. Re-review. Loop until PROCEED or escalation.

**Phases are kept fine-grained on purpose.** More phase boundaries =
more checkpoints = more reviewer gates = more correctness. There is
no schedule pressure to merge phases.

### Parallelism map

Sequential phases (must run in order, each blocks next):

- Phase 0 → 1 → 2 → 3 → 4 → 5 → 6 (setup, scaffold, harness — IR
  contract not yet stable).
- Phase 19 (fuse) blocks on Phase 18 (prefilter harvest off IR).
- Phase 20 (full-repo review) blocks on all R3.
- Phase 21 → 22 → 23 (measurement, cutover, merge).

Parallel waves for Phases 7–18 (after IR contract locked at Phase 5,
harness green at Phase 6):

- **Wave A** (parallel, no shared IR ops): Phase 7 (literals/identity/
  recurse/unary), Phase 8 (field/index/iterate/slice), Phase 9
  (pipe/comma), Phase 11 (arith/cmp/logical/`//`), Phase 13
  (constructors/interp/format).
- **Wave B** (parallel, depend on Wave A primitives): Phase 10
  (variables/as-pattern/destructure/`?//`), Phase 12 (try/catch/if/
  path/parens), Phase 14 (update assignments).
- **Wave C** (parallel, depend on Wave B): Phase 15 (UDFs), Phase 16
  (26 builtins), Phase 17 (regex/datetime).
- **Tail (sequential)**: Phase 18 (prefilter harvest).

Each wave: spawn N implementers in one message with
`isolation: "worktree"`. After all return: spawn N verifiers in
parallel. After all PASS: merge worktrees sequentially via
`git-operator`, running reviewer trio per merge. Reviewer trio runs
in parallel across categories within a wave only if the synthesizer
can scope per-category — otherwise serialize the review pass.

If a wave member fails verification or review, isolate it: continue
merging the others, hold the failed one for fix, re-merge after.

### Phases (digest only — `plan-section-loader` returns full steps)

The following is the orchestrator's roadmap, not the spec. For each
phase, before acting, spawn `plan-section-loader` with the phase
identifier. The plan controls.

- **Phase 0** — Setup (plan §3 R1 steps 1–2). Tag, branch.
- **Phase 1** — Walker delete (§3 R1 steps 3–5). Preserve
  `assign_general` and `parseAssignGeneral` (LSP).
- **Phase 2** — Supersession bookkeeping (§3 R1 steps 6–7).
- **Phase 3** — Bench harness + legacy baseline (§3 R2).
- **Phase 4** — IR-format spec (§3 R2 step 3).
- **Phase 5** — Compiler scaffold + dispatch flag (§3 R3 steps 1–3).
- **Phase 6** — VM-semantics harness (§3 R3 steps 4–5).
- **Phases 7–18** — Operator category ports (§3 R3 step 6). See
  Parallelism map above. Categories per plan ordering.
- **Phase 19** — Fuse pass port (§3 R3 step 8).
- **Phase 20** — Full-repo review.
- **Phase 21** — Guardrail measurement (§3 R4+R5 step 1). Bench in
  background.
- **Phase 22** — Cutover commit (§3 R4+R5 step 3). Delete
  `src/query/src/compiler.zig`, remove `-Dcompile`, dispatch
  unconditionally.
- **Phase 23** — Merge to main. No force-push.

For each phase, the orchestrator's main-thread sequence is:

1. `plan-section-loader` → digest.
2. (For waves) spawn implementers in parallel with worktree
   isolation; otherwise spawn one implementer.
3. `verifier` (+ `equiv-runner`, `snapshot-validator`,
   `bench-runner` where applicable) in parallel.
4. Reviewer trio in parallel.
5. `reviewer-synthesizer` → verdict.
6. PROCEED: `git-operator` commits/tags/merges. BLOCK: fix
   implementer, loop.
7. `progress-logger` writes summary + updates memory.
8. Drop phase from working context.

### Escalation triggers (surface to user, do not autonomously act)

- Plan bug confirmed by `plan-conflict-second-opinion`.
- Guardrail miss after 2 fix attempts on the same guardrail.
- Test count regression unexplained by intentional change.
- Discovery of behavior the plan did not anticipate, confirmed by
  second opinion.
- Any ambiguity about whether to proceed.

Escalation format: 5-line situation summary, options list, named
recommendation, wait for user response. Do not act.

Before any escalation: spawn `plan-conflict-second-opinion` (for plan
bugs) or `root-cause-investigator` (for failures). Only escalate
confirmed issues.

### Forbidden actions

Implementation/plan:

- Modifying the plan without user approval.
- Skipping verification.
- Continuing past a failed guardrail (without 2 fix attempts +
  escalation).
- Spawning agents with shared transcripts.
- Using legacy compiler features in the new compiler (no copy-paste
  from `src/query/src/compiler.zig`).
- Reproducing legacy quirks (e.g. `compileRange` lookahead) —
  VM-semantics is the bar.
- Force-pushing, history rewriting, `--no-verify`.
- Granting reviewer agents access to implementer transcripts.

Context discipline (orchestrator-specific):

- Calling Read, Edit, Write, or Bash directly.
- Viewing diffs in main context.
- Reading the plan in full.
- Re-reading prior phase digests to "remember" what happened —
  use `progress-reader` instead.
- Accepting subagent digests longer than the role's cap.
- Pasting raw build/test/bench output into main context.

### Stop condition

- `redesign/compiler` merged to `main`.
- `verifier` confirms `rg "src/query/src/compiler" src/ tests/ build.zig` returns zero.
- `verifier` confirms `rg "Dcompile" build.zig` returns zero.
- `verifier` confirms `zig build test` fully green on `main`.
- All five guardrails final numbers in
  `research/compiler-baselines.md` (confirmed by `guardrail-measurer`).

Final user message format:

```
Phase 2R complete (Phases 0–23).
Final commit: <hash>
Branch merged: redesign/compiler → main
Guardrails:
  1. VM-semantics tests:    <pass/fail>
  2. Compile throughput:    <legacy median> → <new median> (Δ%, σ%)
  3. Binary size:           <legacy bytes> → <new bytes> (Δ%)
  4. Compile peak RSS:      <legacy MB> → <new MB> (Δ%)
  5. Source-position parity: <pass/fail> on <N> error fixtures
Tests: <pass>/<fail>/<skip>
Plan: /home/hybridz/Projects/zq/research/phase-2r-compiler-redesign-plan.md
Baselines: /home/hybridz/Projects/zq/research/compiler-baselines.md
Progress log: /home/hybridz/Projects/zq/research/phase-2r-progress.md
```

### Initial action

1. Spawn `progress-reader` to load `phase_2r_state.md` (auto-memory)
   + last 20 lines of `research/phase-2r-progress.md`. If both empty:
   cold start, current phase = 0.
2. Spawn `plan-section-loader` with the current phase identifier.
3. State: "Plan section <N> loaded, resuming/beginning Phase <N>."
4. Begin the phase per the execution shape above.

Do not Read the plan yourself at any point. Do not Read the progress
log yourself at any point. Do not Read source files at any point.
Every byte of input arrives via subagent digest.

---

## End of prompt
