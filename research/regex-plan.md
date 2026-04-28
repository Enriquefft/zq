# Regex Strategy for zq

**Status**: Design — approved, Phase A starting.
**Date**: 2026-04-22.
**Revision**: 3 (size/speed/parity tuning + build gate).
**Scope**: Implements jq regex builtins (`test`, `match`, `capture`, `scan`, `sub`, `gsub`) in zq. Replaces current substring-based stubs in `legacy@22cd23c vm.zig:7038-7174`.

## Revision 3 deltas
- Profile: `opt-level = 3` (not `z`). Speed > 200 KB. LTO+1cgu already gives 80% of size reduction.
- Feature flags: keep full Unicode (parity). Drop `unicode-age`, `unicode-segment` only.
- Size projection: +1.5-2.5 MB. Total zq ~2.8-3 MB static. Still ≤ `jq-static`.
- New gate: `-Dregex=false` for Rust-free build (Alpine minimal, packagers). Builtins return clear error.
- Binary baseline corrected: zq today 1.3 MB stripped (not 1-2 MB). jq's real code footprint ~1.18 MB (libjq 440 KB + libonig 707 KB). Parity, not 10x gap.

## Problem

`capture` and `scan` are the last missing jq string builtins. They cannot be faked with substring matching because they require named groups and subgroup contents. Shipping them forces the larger decision: pick a real regex engine. Current `test`/`match`/`sub`/`gsub` stubs must be upgraded in the same pass — the upgrade is structural, not additive.

## Engine choice: custom Rust shim over `regex-automata`

Not raw `rure`. A deliberate shim crate (`zq-regex-shim/`) vendored in-tree, exposing exactly what zq needs. Justified in depth below; summary:

**In 2026, the set of regex engines that satisfy [linear-time + full captures + actively maintained + reasonable build cost] is exactly one: the Rust `regex`/`regex-automata` family.** Every other option fails at least one criterion.

| Engine | Linear-time | Captures | Maintained 2026 | Build reasonable | Verdict |
|---|---|---|---|---|---|
| **`regex-automata`** (custom shim) | ✅ | ✅ | ✅ state-of-the-art | ✅ cargo + cargo-zigbuild | **chosen** |
| `rure` raw C API | ✅ | ✅ | ✅ | ✅ cargo | rejected — no literal extractor in C API, forces shim anyway (be honest about it) |
| RE2 | ✅ | ✅ | ✅ | ❌ Abseil C++17 + CMake | rejected on build sanity |
| Hyperscan/Vectorscan | ✅ | ❌ no subgroups | ✅ (Vectorscan fork) | ❌ CMake+Boost+Ragel | rejected — cannot implement `capture`/`match.captures[]`/backref sub |
| PCRE2+JIT | ❌ ReDoS | ✅ | ⚠️ single maintainer | ✅ | rejected — ReDoS is shipped workaround (violates principle #4) |
| Oniguruma | ❌ ReDoS | ✅ | ❌ **archived 2025-04** | ✅ | rejected — unmaintained |
| Pure-Zig (tiehuis) | partial | ❌ | ❌ unmaintained since Zig 0.11 | ✅ | rejected — incomplete + dead |
| Pure-Zig rewrite | — | — | — | ❌ multi-month | rejected — regex not on zq's critical path |

### Long-term-robustness justification

**#4 (zero workarounds):** ReDoS-vulnerable is shipped workaround. A jq user writes `test($user_pattern)` against untrusted data → attacker constructs pathological pattern → 40-second match on 200 B input × 15M records. "jq has this problem too" is a 2010 argument. Linear-time is the correctness floor for a 2026+ JSON tool.

**#5 (production-grade floor):** Maintenance trajectory is decisive on a 5–10 year horizon.
- `regex`/`regex-automata`: Andrew Gallant (BurntSushi), rewritten 2023 (1.10) with state-of-the-art architecture (lazy DFA + Teddy + aho-corasick + one-pass NFA). Most-studied engine in the industry.
- PCRE2: Philip Hazel, single maintainer, succession risk real.
- Oniguruma: archived April 2025 — cautionary tale.

**#6 (build for 2026+):** Rust+Zig is a supported pattern. `cargo-zigbuild` (VictoriaMetrics) makes Zig the linker for Rust, bridges the cross-compile toolchain. Betting on ecosystem trajectory, not fighting it.

**#7 (agents as users):** Agents construct regex dynamically when using zq as a command surface. ReDoS-vulnerable engine = agents can accidentally DoS themselves. Linear-time = agents regex freely without reliability failures.

**#2 (own the critical path):** Only principle arguing against Rust — would favor pure-Zig rewrite. Counter: zq's critical path is parser/VM/SIMD/chunk-parallel. Regex runs on already-parsed string fields. A multi-month Zig regex rewrite spends critical-path budget on a non-critical-path problem.

**#3 (single source of truth):** Custom shim forces honesty — the Sparser prefilter needs `regex-syntax::hir::literal::Extractor`, which is Rust-only. Raw `rure` pretends this isn't needed; we'd end up writing Rust anyway. Deliberate shim is strictly better than accumulating workarounds around the rure C API.

### Compat delta from jq

jq inherits Oniguruma: backrefs + lookaround + more. `regex-automata` has neither. Documented, not hidden.

- **No backrefs** (`(\w+) \1`). Pattern-compile returns clear error. Rare in jq programs.
- **No lookaround** (`(?=...)`, `(?<=...)`). Pattern-compile returns clear error. Common enough to warrant a doc section with rewrite patterns.
- **No Oniguruma-only syntax** (POSIX bracket classes `[:alpha:]` work in both; `\p{...}` Unicode properties work in both; `\g<name>` subroutine calls: no).
- **`sub`/`gsub` replacement model differs** — jq evaluates the replacement as a full jq filter with `.` bound to the match object, so `\(.captures[0].string)` interpolation works. zq supports `\1..\9` / `\g<name>` backref substitution in the replacement string. Concrete divergence:
  - jq: `"abc" | sub("(?<x>.)"; "\(.captures[0].string | ascii_upcase)")` → `"Abc"`.
  - zq: same input is a compile error (the jq-filter replacement grammar is not parsed). User workaround: `match` + manual string build. **Status: accepted as permanent delta** — implementing jq's replacement-as-filter pulls the full filter evaluator into the sub/gsub path, which violates the clean VM boundary of the regex pipeline for a rarely-used feature. Revisit if user demand surfaces.
- Failure mode: compile error with construct pointed at, not silent semantic change.

## Custom shim: `zq-regex-shim/`

Vendored Rust crate. Minimal surface. Owns exactly the integration points zq needs. Stable C ABI.

### Rust-side crate

```
third_party/zq-regex-shim/
├── Cargo.toml            # crate-type = ["staticlib"], panic = "unwind"
├── Cargo.lock            # vendored, --locked --offline in build
├── .cargo/config.toml    # [source.crates-io] replaced by vendor/
├── vendor/               # cargo vendor — all deps offline-buildable
└── src/lib.rs            # ~300 LoC: FFI wrappers + panic catching
```

Depends on: `regex-automata` (direct), `regex-syntax`. No `regex` top-level. No `rure`. We own the surface.

### Cargo profile + features (Rev. 3)

```toml
[lib]
crate-type = ["staticlib"]

[profile.release]
opt-level = 3            # speed priority; do NOT use "z"
lto = "fat"
codegen-units = 1
strip = true
panic = "unwind"         # required so catch_unwind works in FFI wrappers

[dependencies.regex-automata]
version = "0.4"
default-features = false
features = [
    "std",
    "syntax",
    "meta",
    "nfa-pikevm",        # captures
    "hybrid",            # lazy DFA
    "perf-literal",      # Teddy + memmem — KEEP, speed
    "unicode-perl",      # \w \d \s Unicode — jq parity
    "unicode-case",      # (?i) Unicode fold — jq parity
    "unicode-gencat",    # \p{L} \p{N} — jq parity
    "unicode-script",    # \p{Greek} — jq parity (niche but onig has it)
    "unicode-bool",      # \p{White_Space} — jq parity
    # DROP: "unicode-age", "unicode-segment" — unused, saves ~50-100 KB
    # DROP: "dfa-build", "dfa-search" — full DFA, meta engine doesn't use
]

[dependencies.regex-syntax]
version = "0.8"
default-features = false
features = ["std", "unicode"]
```

### C ABI surface

```c
// Opaque handle. Owned by caller. Thread-safe to share; each worker clones.
typedef struct ZqRegex ZqRegex;
typedef struct ZqRegexClone ZqRegexClone;  // per-worker cheap clone

// Compile. Returns NULL on error; err_buf populated with null-terminated message.
ZqRegex* zq_regex_compile(const uint8_t* pat, size_t pat_len, char* err_buf, size_t err_cap);
void     zq_regex_free(ZqRegex*);

// Per-worker clone — amortizes internal cache pool allocation.
// Cheap: shares compiled DFA, clones cache only.
ZqRegexClone* zq_regex_clone(const ZqRegex*);
void          zq_regex_clone_free(ZqRegexClone*);

// Fast path: bool match. Returns 0/1, or -1 on internal error.
int zq_regex_is_match(ZqRegexClone*, const uint8_t* hay, size_t hay_len);

// Find first match. Returns 0 if no match, 1 if matched, -1 on error.
// On match, out_start/out_end are byte offsets.
int zq_regex_find(ZqRegexClone*, const uint8_t* hay, size_t hay_len,
                  size_t start_offset, size_t* out_start, size_t* out_end);

// Find first with captures. Caller provides slots array sized to capture_group_count.
// slot[i] = {start, end}; start == SIZE_MAX means "unmatched optional group".
// Returns 0/1/-1 as above.
int zq_regex_find_captures(ZqRegexClone*, const uint8_t* hay, size_t hay_len,
                           size_t start_offset, ZqMatchSlot* slots, size_t slot_count);

// Iterator for scan. One call = one match. Returns 0 = no more, 1 = got match, -1 = error.
int zq_regex_iter_next(ZqRegexClone*, const uint8_t* hay, size_t hay_len,
                       size_t* in_out_cursor, ZqMatchSlot* slots, size_t slot_count);

// Metadata
size_t      zq_regex_capture_count(const ZqRegex*);
int         zq_regex_group_name(const ZqRegex*, size_t idx, const char** out_name, size_t* out_len);
int         zq_regex_group_index_by_name(const ZqRegex*, const uint8_t* name, size_t name_len);

// Literal extraction for Sparser prefilter. Returns array of literal byte strings
// that MUST appear SOMEWHERE in any matching input (OR-semantics). NULL if pattern
// has no extractable literals (e.g., `.+`, `\d+`) — caller bypasses prefilter.
typedef struct ZqLiterals ZqLiterals;
ZqLiterals*  zq_regex_required_literals(const ZqRegex*);
size_t       zq_literals_count(const ZqLiterals*);
const uint8_t* zq_literals_at(const ZqLiterals*, size_t idx, size_t* out_len);
int          zq_literals_is_exhaustive(const ZqLiterals*);  // true = match requires ALL; false = OR
void         zq_literals_free(ZqLiterals*);
```

### Panic safety

Every entry point wraps the Rust body in `std::panic::catch_unwind`. `Cargo.toml` sets `panic = "unwind"` (not abort — specifically so we can catch). On caught panic:

- Log to stderr (feature-gated).
- Return `-1` from int-returning functions.
- Return `NULL` from pointer-returning functions.
- Zig side maps `-1`/`NULL` to `error.RegexInternalError`.

A panic does NOT abort the zq process, does NOT kill worker threads, does NOT corrupt shared state (we never hand rure a pointer into zq memory that outlives the call). The parallel-chunk architecture survives.

### Thread model

- `ZqRegex` = compiled pattern. Shared across workers. `Sync`. Immutable.
- `ZqRegexClone` = per-worker wrapper that pre-clones the `regex-automata::meta::Regex` for that worker. Avoids the internal `Pool<Cache>` contention that BurntSushi calls out on short-haystack multi-threaded workloads (rust-lang/regex#960). Allocated at worker startup; freed at worker shutdown. Not hot-path.

## Zig-side integration

### Module layout

- `src/regex/root.zig` — Zig wrapper over the shim's C ABI. **Single source of truth** for regex in zq.
- `src/regex/cache.zig` — pattern-compile cache (filter-compile-time interning + LRU for dynamic patterns).
- `src/regex/offset.zig` — byte→char offset conversion for jq-compat match objects.
- `build.zig` — cargo step + static link.
- `build.zig.zon` — pins shim source (it lives in-tree under `third_party/` conceptually; path dep).
- `src/types.zig` — add `capture_`, `scan_` opcodes.
- `legacy@22cd23c compiler.zig` — dispatch new builtins.
- `legacy@22cd23c vm.zig` — rewrite `builtinTest/Match/Sub/Gsub`, add `builtinCapture/Scan`.
- `src/lsp/builtins.zig` — doc table entries.

### Zig API (`src/regex/root.zig`)

```zig
pub const Regex = struct {
    handle: *c.ZqRegex,
    pub fn compile(pattern: []const u8) !Regex;
    pub fn deinit(self: *Regex) void;
    pub fn captureCount(self: Regex) usize;
    pub fn groupName(self: Regex, idx: usize) ?[]const u8;
    pub fn groupIndexByName(self: Regex, name: []const u8) ?usize;
    pub fn requiredLiterals(self: Regex) ?Literals;
    pub fn clone(self: Regex) !RegexClone;  // per-worker
};

pub const RegexClone = struct {
    handle: *c.ZqRegexClone,
    pub fn deinit(self: *RegexClone) void;
    pub fn isMatch(self: RegexClone, hay: []const u8) !bool;
    pub fn find(self: RegexClone, hay: []const u8, start: usize) !?Match;
    pub fn findCaptures(self: RegexClone, hay: []const u8, start: usize, slots: []MatchSlot) !bool;
    pub fn iterNext(self: RegexClone, hay: []const u8, cursor: *usize, slots: []MatchSlot) !bool;
};

pub const MatchSlot = extern struct { start: usize, end: usize };
pub const SLOT_UNMATCHED: usize = std.math.maxInt(usize);
```

### Lifetime + ownership

- Compiled `Regex` for patterns known at filter-compile-time: lifetime = compiled filter lifetime. Stored in the compiled-filter struct, freed when the filter is freed. Opcode payload stores an index into that struct's regex array — NOT a raw pointer.
- LSP recompiles on document edit → old filter struct freed → old `Regex` freed. No leak.
- Dynamic patterns (`test($var)`): LRU cache owned by the `ResultIterator`. Bounded 64 entries. Freed at iterator teardown.
- `RegexClone` per worker: allocated at worker start, freed at worker end. Not per-record.
- Match results: rure returns `(start, end)` byte offsets into the **caller's input buffer**. No allocation in rure returned to us. String views are always slices of the original JSON record's string field — which lives in the chunk arena. Arena lifetime = chunk processing lifetime. Capture strings in the output tape are copied into `runtime_tape`'s string buffer (standard zq path).

### Match object shape (jq-compat)

`match` output shape:
```json
{"offset": N, "length": N, "string": "...",
 "captures": [
   {"offset": N, "length": N, "string": "...", "name": "groupname" | null},
   ...
 ]}
```

Edge cases:
- **Unmatched optional group** `(foo)?`: slot.start == `SLOT_UNMATCHED`. Emit `{"offset": -1, "length": 0, "string": null, "name": "..."}`. Matches jq.
- **Empty (zero-width) capture**: slot.start == slot.end, valid offset. Emit `{"offset": N, "length": 0, "string": "", "name": ...}`. Matches jq.
- **Nested groups**: ordered by open-paren position. `regex-automata`'s group indexing matches Oniguruma's for valid patterns (verified against jq tests in Phase E).
- **Duplicate named groups**: `regex-automata` errors at compile. jq errors too (onig rejects duplicate names unless `(?J)` flag). Compat.
- **`offset` semantics**: jq docs define `offset` as **character count (not bytes, not codepoints)**. `regex-automata` returns byte offsets. Shim returns byte offsets; `src/regex/offset.zig` converts to character count on demand when building match object. UTF-8 prefix scan is O(prefix_length); bounded by field length (typically <1 KB). Acceptable overhead; measured in Phase E.

`capture` output:
```json
{"groupname1": "matched_text1", "groupname2": "matched_text2"}
```
Only named groups. Unnamed groups skipped. Unmatched optional named group emits `"name": null`.

`scan` output:
- No captures: yields a string per match.
- With captures: yields an array of capture strings per match (jq behavior).

### `scan` VM integration

zq's VM uses a **fork stack** for generator builtins (`range`, `.[]`, `path`, `..`). Pattern in `legacy@22cd23c vm.zig:4561` (`builtinRange1`):

1. Push a fork frame with `aux = .range = RangeState { current, end, step, ... }`.
2. Set `current` value to first iteration result.
3. Set `ip` past the generator opcode.
4. On backtrack, `doBacktrack` pops back to the fork frame, advances `current_int`, resumes.

`scan` follows the **identical pattern**:

```zig
const ScanState = struct {
    regex_index: u32,        // index into compiled filter's regex array
    input_ref: StringRef,    // view into arena-owned input
    cursor: usize,           // next byte position to search from
};
```

1. `fork_stack.append(.{ .aux = .{ .scan = ... }, .saved_value_stack_len = ..., .backtrack_ip = ip, ... })`.
2. Call `regex.iterNext(input, &cursor, slots)`. If false → no matches → backtrack immediately.
3. Build match value (string or [captures]) → set as `it.current`.
4. Advance `ip` past `scan_` opcode.
5. On backtrack: `doBacktrack` sees `.scan` aux, calls `iterNext` again with saved cursor. If false → pop frame, continue backtrack.

Add `.scan` to `ForkType` enum (`legacy@22cd23c vm.zig:33`) and `FrameAux` union (`legacy@22cd23c vm.zig:100`). Add backtrack case alongside `.range`. ~80 LoC addition, follows exact existing pattern. Zero new VM infrastructure.

## Sparser-style raw-byte prefilter

For `select(.field | test(pattern))` idiom:

1. At filter-compile time, walk AST for `select` wrapping regex builtin. If present, call `regex.requiredLiterals()`.
2. If shim returns `NULL` (pattern has no extractable literals, e.g. `.+`, `\d+`) → prefilter disabled for this query, fall through to normal path.
3. If shim returns literals with `is_exhaustive == false` (OR-semantics, e.g. alternation): need ANY literal to appear.
4. If `is_exhaustive == true` (AND-semantics): need ALL literals to appear.
5. Raw-record scan: for each chunk of parsed bytes, SIMD memchr/aho-corasick over the required literal set BEFORE full parse. Miss → skip record entirely.
6. Reuses zq's existing SIMD infra in `src/parser/src/simd.zig`.
7. Correctness: false positives OK (full parse + regex still runs to confirm). False negatives impossible — if the pattern can match, all required literals must appear.

Separate phase (F); wire after core regex lands and works.

## Build integration

### Cargo-in-Zig-build via `cargo-zigbuild`

`cargo-zigbuild` uses Zig as the C linker for Rust, bridges cross-compile toolchain, solves musl/macOS-universal/mingw linking pain.

### Build gate: `-Dregex`

- `zig build -Dregex=true` (default): builds shim via cargo-zigbuild, links static `.a`, full regex.
- `zig build -Dregex=false`: skips cargo step, no Rust required. All regex builtins return `error.RegexNotCompiled` with clear message. For Alpine minimal / embedded / Rust-refusing packagers.
- Release binaries default to `-Dregex=true`.
- Contributor `zig build` with rustc missing: fails fast with message pointing at `-Dregex=false` escape hatch or flake devshell.

### build.zig sketch
```zig
const shim_build = b.addSystemCommand(&.{
    "cargo", "zigbuild",
    "--release",
    "--locked", "--offline",
    "--manifest-path", "third_party/zq-regex-shim/Cargo.toml",
    "--target", zig_target_to_rust_triple(target),
});
shim_build.addArg("--target-dir");
const target_dir = b.makeTempPath();
shim_build.addArg(target_dir);

const shim_lib = b.path(target_dir).join("release/libzq_regex_shim.a");
exe.addObjectFile(shim_lib);
exe.linkLibC();
exe.step.dependOn(&shim_build.step);
```

Dependencies vendored under `third_party/zq-regex-shim/vendor/` via `cargo vendor`. `Cargo.lock` committed. Build is fully offline and reproducible.

### Cross-compile matrix (Phase A validation)

Target list with known issues:

| Target | Status | Notes |
|---|---|---|
| linux-x86_64-gnu | easy | rustup target |
| linux-x86_64-musl | easy | cargo-zigbuild strength |
| linux-aarch64-gnu | easy | |
| linux-aarch64-musl | easy | |
| macos-x86_64 | medium | rustup target + Apple SDK |
| macos-aarch64 | medium | same |
| windows-x86_64-msvc | **hard** | need MSVC CRT matching; cargo-zigbuild handles mingw but MSVC requires Windows host or xwin |
| windows-x86_64-gnu (mingw) | medium | cargo-zigbuild target |
| freebsd-x86_64 | medium | rustup support partial |
| alpine-native | medium | `apk add rust cargo` pins version; accept MSRV pin |
| nixos | medium | nixpkgs has `rustc`, `buildRustPackage` wrapper; plumb through `flake.nix` |

Phase A blocker: every row must smoke-test (compile + run `zq_regex_is_match` on sample input) before Phase B starts.

**Distribution strategy**: Prebuilt binaries for release (GitHub release artifacts per platform). "Download single static binary" UX preserved. From-source builds require rustc, documented in CONTRIBUTING.md. For agent/CI use, prebuilt is default.

## Performance

### Targets (per-call, with per-worker clone)

| Pattern | Target | Notes |
|---|---|---|
| Literal `"foo"` | 30–80 ns | `regex-automata` memmem fast path |
| Anchored prefix `"^GET "` | 30–80 ns | anchor-aware scan |
| Simple class `"[a-z]+"` | 80–200 ns | one-pass NFA |
| Named capture `"(?<y>\d{4})"` | 300 ns–1 µs | meta engine dispatch |
| Alternation `"foo\|bar\|baz"` | 80–200 ns | Teddy SIMD |
| `select(... \| test("X"))` + Sparser | ≪ 1 µs avg at low selectivity | most records skip parse |

FFI overhead: Zig→C→Rust call is ~10–30 ns; counted in the above.

Measured via the phase-0 microbench tool (`research/phase-0-design.md` §4). Regex is a first-class microbench phase.

### Pattern compile cache

- Filter-compile time: each distinct string-literal regex in the filter AST is compiled once, stored in the compiled-filter struct's `regex_pool: []Regex`. Opcode payload is `regex_index: u32`.
- Runtime `test($var)` with dynamic pattern: per-worker `LRUCache(64, pattern_bytes → Regex)`. Bounded to prevent adversarial-input unbounded allocation. On eviction, `Regex.deinit` called.
- Compiled `Regex` is immutable — shared across workers via `RegexClone`.

## Implementation sequence

**Phase A — shim + build integration** (2–3 days):
- Scaffold `third_party/zq-regex-shim/` crate with minimum API (compile, is_match, free).
- `cargo vendor` transitive deps; commit `Cargo.lock`.
- `build.zig` step via `cargo-zigbuild`.
- Cross-compile matrix green on all targets in the table above.
- Smoke test: compile + run trivial match from `main.zig`.
- **Phase A gate**: full matrix passes, or go-no-go decision to drop specific targets.

**Phase B — shim full surface + Zig wrapper** (2 days):
- All C ABI functions above.
- `src/regex/root.zig` Zig wrapper.
- Panic catching exercise: include a shim test that deliberately panics, verify zq process survives.
- Pattern compile cache.

**Phase C — opcodes + compiler wiring** (1 day):
- `src/types.zig` add `capture_`, `scan_`.
- `legacy@22cd23c compiler.zig` name table (2770-2773) + emit path (5307-5313) for `capture`, `scan`.
- Filter-compile-time regex pool: walk AST, intern literal-string regex args, emit opcode with `regex_index`.
- `src/lsp/builtins.zig` doc entries.

**Phase D — VM rewrite** (2 days):
- Rewrite `builtinTest/Match/Sub/Gsub` on real engine.
- Implement `builtinCapture` (named-group object).
- Implement `builtinScan` via fork stack (ScanState aux, backtrack resume).
- `src/regex/offset.zig` byte→char conversion for match offsets.
- `sub`/`gsub` replacement string: support `\1..\9` and `\g<name>` backref substitution in replacement (not in pattern — pattern backrefs still unsupported).
- Unmatched-optional-group sentinel handling.

**Phase E — tests** (1–2 days):
- Port jq's regex test suite to `tests/regex_test.zig`. Skip backref/lookaround patterns, mark as known compat delta.
- Fuzz harness: `regex-syntax::generate` random patterns + random UTF-8 strings, run both zq and jq, compare output.
- Benchmark harness: per-builtin cost via microbench tool.
- Document compat delta in `ROADMAP.md` + `llms.txt`.

**Phase F — Sparser prefilter** (2–3 days, separate roadmap item):
- Literal extraction via shim API.
- AST walk to detect `select`-wraps-regex idiom.
- SIMD raw-byte prefilter integration.
- Benchmark high-selectivity workloads.

## Rollback plan

If a later phase surfaces a true blocker (e.g., FFI overhead measured at 5x budget on small strings, or Windows MSVC cross-compile proves intractable), rollback is:

1. Replace `zq-regex-shim/` implementation with **PCRE2 bindings** (via `pcre2-sys` equivalent, but in pure C from `build.zig`). The Zig-side wrapper at `src/regex/root.zig` API contract is unchanged — only the shim swaps.
2. Accept ReDoS as a documented compat-parity regression (same as jq).
3. No VM, compiler, or test code changes. Single-source-of-truth pays off.

Bail-out trigger: If after Phase A + Phase B we cannot demonstrate <200 ns per-call for literal match on 100-byte inputs, stop and reconsider. Expected is <100 ns; 2x miss = reconsider.

## Open questions

- **rustc in prerelease CI for PRs**: add `rustup` install step (~30s cold) or pre-bake into CI image. Pre-bake preferred.
- **Cargo.lock drift**: `dependabot` updates shim's `Cargo.lock`; test matrix catches regressions before merge.
- **Release binary distribution**: prebuilt per platform via GitHub Actions. `zq-install.sh` downloads the right binary. From-source `cargo install` path requires rustc; documented.
- **Unicode mode**: `regex-automata` defaults Unicode-aware. jq/onig also Unicode-default. Match defaults.
- **`(?i)` and other flags**: `regex-automata` supports the same flag set as PCRE-ish minus backrefs/lookaround. No semantic differences expected.

## Non-goals

- Supporting backrefs or lookaround. Hard compat delta, documented.
- Hyperscan-style multi-pattern batching across a filter. Real jq programs have 0–2 regex calls.
- JIT. `regex-automata` lazy DFA + SIMD literal prefilters exceed JIT'd backtracking on realistic workloads.
- Zig-native regex engine. Not where zq's critical-path value lives.
- Runtime engine swap. Shim abstraction exists for rollback, not for runtime choice.
