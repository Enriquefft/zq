// SSOT: zq feature flags mirrored on the test side.
//
// These constants mirror the corresponding jq builtins exposed by the runtime.
// They exist so the compat test generator can decide, at codegen time, when a
// jq test is gated on a builtin that zq deliberately does not implement, and
// emit an `error.SkipZigTest` guard for that test.
//
// Single source of truth: the runtime returns `.bool_val = false` for
// `have_decnum` (and treats `have_literal_numbers` identically) at:
//
//   src/vm/root.zig:4176
//       .have_decnum_ => return .{ .bool_val = false },
//
// Rationale: ROADMAP.md "Deliberate Deviations from jq" — Number representation
// row (~line 588) — zq uses f64 everywhere; arbitrary-precision (decnum) and
// jq's literal-number preservation are explicitly out of scope. If the runtime
// ever flips either flag to `true`, flip the matching constant here in the
// same commit so the generator stops emitting skip guards.
//
// This file is hand-edited (not generated). The compat generator imports it
// via `@import("zq_features.zig")` from the per-section files it emits.

pub const have_decnum: bool = false;
pub const have_literal_numbers: bool = false;
