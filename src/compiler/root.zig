//! Phase 2R compiler — public entry point. Wired into the production
//! `query.CompiledQuery.compile` dispatcher, but only invoked when the
//! build is configured with `-Dcompile=new`.
//!
//! Phase 5 returns `error.NewCompilerNotImplemented`; R3 will fill in the
//! pipeline (`lower → fuse → emit`) and refine the return type to match
//! the legacy compiler's `CompileResult`. The legacy backend remains the
//! production default; see `build.zig`'s `-Dcompile=` option and
//! `src/query/root.zig`'s dispatch.
const std = @import("std");

const ir = @import("ir.zig");
const lower_mod = @import("lower.zig");
const fuse_mod = @import("fuse.zig");
const emit_mod = @import("emit.zig");

// Re-export for downstream callers / tests that may want the IR types.
pub const Op = ir.Op;
pub const Node = ir.Node;
pub const IR = ir.IR;

/// Compile a filter source string with the new VM-semantics compiler.
///
/// Phase 5: always returns `error.NewCompilerNotImplemented`. The new path
/// is wired through `build.zig` + `query.CompiledQuery.compile` so the
/// dispatch type-checks end-to-end, but no operators are ported yet.
///
/// TODO(R3): tighten return type to `error{OutOfMemory}!CompileResult`
/// once lowering / fuse / emit are real. The success branch is currently
/// elided via the `noreturn` payload — Zig allows error unions whose
/// success type is `noreturn` and treats the function as error-only.
pub fn compile(
    src: []const u8,
    allocator: std.mem.Allocator,
) error{ NewCompilerNotImplemented, OutOfMemory }!noreturn {
    _ = src;
    _ = allocator;
    // Touch the pipeline imports so unused-import warnings don't fire and
    // to make the call graph visible in the generated IR. The arena is
    // discarded immediately; R3 replaces this with the real pipeline.
    _ = &lower_mod;
    _ = &fuse_mod;
    _ = &emit_mod;
    return error.NewCompilerNotImplemented;
}
