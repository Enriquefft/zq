const std = @import("std");
const err_mod = @import("error");
const types = @import("types");
const compiler = @import("src/compiler.zig");
const vm = @import("src/vm.zig");

pub const ZqError = err_mod.ZqError;
pub const Tape = types.Tape;
pub const Value = types.Value;

// Re-export ResultIterator as part of the public surface.
pub const ResultIterator = vm.ResultIterator;

// Re-export types needed for external variable support.
pub const ExternalVarDecl = compiler.ExternalVarDecl;
pub const ExternalVarBinding = vm.ExternalVarBinding;
pub const StackValue = vm.StackValue;

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
    opts: Opts,

    /// Compile `src` into bytecode.
    ///
    /// The allocator is stored internally and used by deinit().
    /// Returns QuerySyntaxError for malformed filters; OutOfMemory if buffers
    /// cannot be allocated.
    pub fn compile(
        src: []const u8,
        opts: Opts,
        allocator: std.mem.Allocator,
    ) (ZqError || error{OutOfMemory})!CompiledQuery {
        const compiled = try compiler.compile(src, opts.external_vars, allocator);
        return CompiledQuery{
            .allocator = allocator,
            .instructions = compiled.instructions,
            .function_table = compiled.function_table,
            .string_buf = compiled.string_buf,
            .external_var_ids = compiled.external_var_ids,
            .opts = opts,
        };
    }

    /// Free bytecode and string-intern buffer.
    pub fn deinit(q: *CompiledQuery) void {
        q.allocator.free(q.instructions);
        q.allocator.free(q.string_buf);
        if (q.external_var_ids.len > 0) q.allocator.free(q.external_var_ids);
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
            allocator,
        );
    }
};
