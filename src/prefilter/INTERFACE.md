# Module: prefilter

## Purpose
Sparser-style raw-byte literal prefilter for low-selectivity
`select(... | regex(lit))` queries. Records whose raw bytes cannot satisfy
every required literal group are skipped before the JSON parser ever sees
them — the full parse + regex run never happens.

The prefilter is a strict necessary condition: it MUST NEVER produce false
negatives. Every accept path is conservative — when the raw byte scan can't
prove a miss (e.g. the record contains `\` and an escape-encoded
occurrence is plausible), the record proceeds to full parse. False
positives are paid for by the normal regex path; they don't compromise
correctness.

When built with `-Dregex=false`, `enabled` is `false` and the harvest /
group-construction paths short-circuit; `PrefilterSet` is still usable as
a no-op container.

## Dual-harvest design

Two independent harvesters produce the same `LiteralGroup` shape from two
different inputs:

- **AST-walk harvest — this module.** `harvestFromAstRoot` walks an
  already-parsed AST root. Used by the legacy token-walk compiler which
  re-parses for harvest, and by any caller that has an AST in hand.
- **IR-walk harvest — `src/compiler/harvest.zig`.** `harvestFromIr` walks
  the post-fuse IR. Used by the Phase 2R compiler (`src/compiler/`) which
  already has a lowered IR and skips the second AST parse.

Both harvesters target the same idiom (`select(<accessor> | test|scan(...))`)
and observe identical prefilter output by construction — the harvest
matches a shape, not a representation. The IR harvester is the
`compiler` module's surface, not `prefilter`'s; it's mentioned here only
to explain why this module exposes only the AST-walk variant.

---

## Public Interface

### Types

```zig
const std = @import("std");
const regex_mod = @import("regex");
const ast = @import("ast");

/// True when built with `-Dregex=true` (default). Aliases
/// `regex.enabled`. When false, `harvestFromAstRoot` and `groupFromRegex`
/// short-circuit; `PrefilterSet.accept` still works as a no-op gate
/// (an empty `groups` slice trivially passes).
pub const enabled: bool;

/// One literal group — the requirement produced by a single regex call.
/// `literals` is heap-owned (each entry is a separate dupe) by the
/// containing `PrefilterSet`.
pub const LiteralGroup = struct {
    literals: [][]const u8,
    /// true  → all literals must appear (AND — from `is_exhaustive`).
    /// false → at least one literal must appear (OR — alternation).
    all_required: bool,
};

/// A prefilter for one compiled filter. All groups must individually be
/// satisfied for a record to proceed to full parse. (Groups come from
/// distinct regex calls chained under the same `select` — each regex is
/// a necessary condition, and each regex's literal set is a necessary
/// condition for that regex.)
pub const PrefilterSet = struct {
    allocator: std.mem.Allocator,
    groups:    []LiteralGroup,

    /// Free every literal byte slice, every group's `literals` array,
    /// and the outer `groups` slice. Sets `groups = &.{}` so the
    /// destructor is idempotent.
    pub fn deinit(self: *PrefilterSet) void;

    /// Deep-copy `src_groups` into a fresh owned `PrefilterSet`. Returns
    /// `null` if the input slice is empty (lets callers attach
    /// `compiled.prefilter = ?PrefilterSet` cleanly). Errdefers free
    /// any partial copy on failure — no leaks on OOM.
    pub fn ownFrom(
        allocator: std.mem.Allocator,
        src_groups: []const LiteralGroup,
    ) error{OutOfMemory}!?PrefilterSet;

    /// Test `bytes` against every group. Returns true iff the record
    /// CANNOT be soundly rejected on the basis of missing literals.
    /// Escape-aware: a literal is "possibly present" if its raw bytes
    /// appear, OR the record contains any `\` (0x5C) byte (because any
    /// JSON escape form requires `\`). See module doc for the soundness
    /// argument.
    pub fn accept(self: PrefilterSet, bytes: []const u8) bool;
};
```

### Functions

| Function               | Signature                                                                                       | Description                                                                                  |
|------------------------|-------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------|
| `canPrefilterLiteral`  | `[]const u8 → bool`                                                                             | True iff the literal is long enough to be worth prefiltering (currently `len >= 2`).         |
| `groupFromRegex`       | `std.mem.Allocator, *const regex.Regex → error{OutOfMemory}!?LiteralGroup`                      | Process a `Regex.requiredLiterals()` result into an owned `LiteralGroup`. `null` on no-go.   |
| `harvestFromAstRoot`   | `std.mem.Allocator, *const ast.Node, *std.ArrayList(LiteralGroup) → error{OutOfMemory}!void`    | Walk an AST root and append zero-or-one groups for the supported `select(...)` idiom.        |

### Errors

| Error          | When                                                                                       |
|----------------|--------------------------------------------------------------------------------------------|
| `OutOfMemory`  | `ownFrom` (group / literal copies), `groupFromRegex` (literal dupes), `harvestFromAstRoot` (pattern buffer + group append). |

No other errors escape. Regex compile failures inside the harvester are
caught and treated as "no prefilter for this filter" — the full path
will surface the same error during the actual compile.

---

## Constraints & Invariants

- **Zero false negatives.** The escape-aware byte scan in `accept` is
  the formal contract: if the record's full-parse-then-regex result
  would be a match, `accept` MUST return `true`. The fallback `\`
  presence check closes the `\uXXXX` / short-escape hole without length
  caps or per-encoding variants. See the module doc-comment for the
  soundness argument anchored on RFC 8259 §7.
- **Soundness under literal dropping (in `groupFromRegex`).**
  `MIN_LITERAL_LEN = 2` filters out single-byte literals whose
  selectivity isn't worth a SIMD pass. The drop policy preserves
  soundness: an exhaustive (AND) set with any drop is downgraded to
  OR over the survivors (strictly weaker, still sound); an OR set
  with any drop loses coverage and the whole group is rejected
  (returns `null`).
- **`LiteralGroup` ownership flows through `PrefilterSet`.** Every
  `[]const u8` in `literals` is heap-owned by the containing set's
  allocator. `ownFrom` deep-copies on construction; `deinit` frees
  every layer. Direct `LiteralGroup` values (e.g. those returned by
  `groupFromRegex`) own their own bytes and the caller must free them
  before discarding — see `compile()` in `src/compiler/root.zig` for
  the canonical defer pattern.
- **Harvest is idiom-narrow on purpose.** `harvestFromAstRoot` only
  matches `select( <pure-accessor> | <test|scan>("<lit>" [; "<flags>"]) )`.
  Anything else — boolean combinators, `//`, trailing pipes,
  `map(...)`, arithmetic, function calls, variable refs —
  invalidates the "no regex match ⇒ no select output" invariant the
  raw-byte prescreen relies on, and the harvester bails (safe default:
  no prefilter).
- **`test` and `scan` only.** `match` / `capture` raise on no-match
  (skipping silently swallows the error); `splits` yields the original
  string on no-match (so `select(.x | splits(...))` outputs even
  without the literal); `sub` / `gsub` are mutators, not filters.
- **Statically known patterns only.** The pattern argument must be a
  literal string; interpolation or pipe expressions yield no
  statically-known literal and the harvester returns nothing for
  those calls.
- **Flag handling matches the regex compile path.** Recognized regex
  flags (`i x m s`) are inlined as `(?flags)` so the harvested probe
  compiles to the same regex the runtime will see; ignored runtime
  flags (`g n`) are dropped; unknown flags abort the harvest so the
  full compile path surfaces the diagnostic.
- **AST shape stability matters.** `harvestFromAstRoot` and
  `isPureAccessorNode` walk specific `Node.Kind` variants
  (`builtin_call`, `pipe`, `field_access`, `iterate`, `index_access`,
  `slice`, `optional`, `paren`, `recurse`, `suffix` with its `SuffixOp`
  variants). Renaming or restructuring any of these in `ast` ripples
  here — the harvester silently bails for unrecognized kinds rather
  than failing loud, so missed harvests after an AST change show up
  only as a perf regression. Cross-module diff vigilance required.

---

## Dependencies

- `src/regex/root.zig` — `Regex`, `Regex.requiredLiterals`, `enabled`
- `src/ast/root.zig`   — `Node`, `Node.Kind`, `SuffixOp`
- stdlib only beyond that: `std.ArrayList`, `std.mem.indexOf`,
  `std.mem.indexOfScalar`
