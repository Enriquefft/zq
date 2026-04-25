const std = @import("std");
const err_mod = @import("error");
const types = @import("types");
const compiler = @import("src/compiler.zig");
const vm = @import("src/vm.zig");
const regex_mod = @import("regex");
const prefilter_mod = @import("prefilter");
const build_options = @import("build_options");
// Phase 2R scaffold. Imported unconditionally so the symbol is reachable
// when `-Dcompile=new` is selected. Today the new path always returns
// `error.NewCompilerNotImplemented`; R3 fills it in.
const new_compiler = @import("compiler");

pub const PrefilterSet = prefilter_mod.PrefilterSet;

pub const ZqError = err_mod.ZqError;
pub const Tape = types.Tape;
pub const Value = types.Value;

// Re-export ResultIterator as part of the public surface.
pub const ResultIterator = vm.ResultIterator;

// Re-export types needed for external variable support.
pub const ExternalVarDecl = compiler.ExternalVarDecl;
pub const ExternalVarBinding = vm.ExternalVarBinding;
pub const StackValue = vm.StackValue;

/// Compile result: either a ready-to-execute CompiledQuery, or a structured
/// compile error with source location.
pub const CompileResult = union(enum) {
    ok: CompiledQuery,
    err: err_mod.CompileError,
};

/// Compilation options. All fields have safe defaults.
pub const Opts = struct {
    /// When true, two specific conditions yield null instead of TypeError:
    ///   1. Missing key on an object (.foo where "foo" is absent).
    ///   2. Field access on a null value (.foo.bar where .foo is null).
    ///
    /// All other type mismatches remain TypeError regardless:
    ///   key on array/number/bool, .[] on non-array, .[n] on non-array.
    ///
    /// Default: false (strict mode).
    allow_null_propagation: bool = false,

    /// External variable declarations to pre-declare in the root scope.
    external_vars: []const ExternalVarDecl = &.{},
};

/// Immutable compiled filter. Thread-safe for concurrent execute() calls.
/// Owns its instruction bytecode and string-intern buffer.
pub const CompiledQuery = struct {
    allocator: std.mem.Allocator,
    instructions: []types.Instruction,
    function_table: []const types.FunctionDef,
    string_buf: []u8,
    external_var_ids: []u32,
    source_map: []u32,
    opts: Opts,
    /// Filter-compile-time regex pool. Owns every `Regex` compiled for a
    /// string-literal pattern in this query. Freed on `deinit`. Opcodes
    /// reference entries by `u32` index in the packed `call_builtin` operand.
    regex_pool: regex_mod.RegexPool,
    /// Sparser raw-byte prefilter — populated at compile time when the
    /// source matches the exact shape `select(PATH | regex_builtin("lit"))`.
    /// `null` otherwise. The parallel chunk worker consults this before
    /// parsing each record; see `src/query/src/prefilter.zig`.
    prefilter: ?prefilter_mod.PrefilterSet,

    /// Compile `src` into bytecode. Returns a CompileResult union:
    /// `.ok` on success, `.err` with source location on compile error.
    ///
    /// Backend dispatch is comptime-keyed off `-Dcompile=`. Default
    /// (`legacy`) hits the production compiler at `src/query/src/compiler.zig`.
    /// `new` (Phase 2R scaffold) routes to `src/compiler/` and currently
    /// always returns `error.NewCompilerNotImplemented` — R3 will refine.
    ///
    /// TODO(R3): when the new compiler returns a real `CompileResult`,
    /// drop the `NewCompilerNotImplemented` member from the error set and
    /// merge the two arms into one.
    /// TODO(R3): `src/main.zig`'s catch on this call (line ~195) prints
    /// "out of memory" for any error from this set. Acceptable while the
    /// new path is gated behind `-Dcompile=new`; surface a clearer message
    /// when the new backend becomes a runtime-selectable option.
    pub fn compile(
        src: []const u8,
        opts: Opts,
        allocator: std.mem.Allocator,
    ) error{ OutOfMemory, NewCompilerNotImplemented }!CompileResult {
        switch (comptime build_options.compile_backend) {
            .legacy => return compileLegacy(src, opts, allocator),
            .new => {
                // The new pipeline returns `!noreturn` today (errors only).
                // The `try` propagates `NewCompilerNotImplemented` /
                // `OutOfMemory` straight to the caller.
                try new_compiler.compile(src, allocator);
            },
        }
    }

    /// Production compile path — extracted so the dispatcher above stays
    /// trivial. Body is the original (legacy) implementation.
    fn compileLegacy(
        src: []const u8,
        opts: Opts,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!CompileResult {
        const result = try compiler.compile(src, opts.external_vars, allocator);
        switch (result) {
            .ok => |compiled| return .{ .ok = CompiledQuery{
                .allocator = allocator,
                .instructions = compiled.instructions,
                .function_table = compiled.function_table,
                .string_buf = compiled.string_buf,
                .external_var_ids = compiled.external_var_ids,
                .source_map = compiled.source_map,
                .opts = opts,
                .regex_pool = compiled.regex_pool,
                .prefilter = compiled.prefilter,
            } },
            .err => |ce| return .{ .err = ce },
        }
    }

    /// Free bytecode and string-intern buffer.
    pub fn deinit(q: *CompiledQuery) void {
        q.allocator.free(q.instructions);
        q.allocator.free(q.string_buf);
        q.allocator.free(q.source_map);
        q.allocator.free(q.external_var_ids);
        q.regex_pool.deinit();
        if (q.prefilter) |*p| p.deinit();
    }

    /// Bind `tape` to this query and allocate an iterator eval stack.
    /// `tape` and `q` must both outlive the returned ResultIterator.
    /// No execution occurs until the first next() call.
    pub fn execute(
        q: *const CompiledQuery,
        tape: Tape,
        external_bindings: []const ExternalVarBinding,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!ResultIterator {
        return ResultIterator.init(
            q.instructions,
            q.function_table,
            q.string_buf,
            q.opts.allow_null_propagation,
            tape,
            external_bindings,
            q.source_map,
            &q.regex_pool,
            allocator,
        );
    }
};
