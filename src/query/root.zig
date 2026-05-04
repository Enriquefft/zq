const std = @import("std");
const err_mod = @import("error");
const types = @import("types");
const vm = @import("vm");
const regex_mod = @import("regex");
const prefilter_mod = @import("prefilter");
// Phase 2R cutover: the new compiler at `src/compiler/` is the only
// backend. The pre-cutover backend dispatcher and build flag are gone;
// `compile()` is a thin wrapper over `new_compiler.compile`.
const new_compiler = @import("compiler");

pub const PrefilterSet = prefilter_mod.PrefilterSet;

pub const ZqError = err_mod.ZqError;
pub const Tape = types.Tape;
pub const Value = types.Value;

// Re-export ResultIterator as part of the public surface.
pub const ResultIterator = vm.ResultIterator;

// Re-export types needed for external variable support.
pub const ExternalVarDecl = new_compiler.ExternalVarDecl;
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

    /// Module search path (jq `-L` equivalent). Each entry is a directory
    /// to look up `import "x" as foo;` / `include "x";` paths in.
    module_search_path: []const []const u8 = &.{},

    /// Directory of the importing file. Used as the final fallback after
    /// explicit search paths exhaust.
    current_file_dir: ?[]const u8 = null,
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
    /// parsing each record.
    prefilter: ?prefilter_mod.PrefilterSet,

    /// Compile `src` into bytecode. Returns a CompileResult union:
    /// `.ok` on success, `.err` with source location on compile error.
    ///
    /// Phase 2R cutover: dispatches unconditionally to the new compiler
    /// at `src/compiler/`. The pre-cutover backend dispatcher and build
    /// flag are gone.
    pub fn compile(
        src: []const u8,
        opts: Opts,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!CompileResult {
        // Translate the query-module's `ExternalVarDecl` slice into the
        // compiler-module's shape. They are field-equivalent today; an
        // explicit copy keeps the cross-module contract crisp.
        var ext_decls: []new_compiler.ExternalVarDecl = &.{};
        if (opts.external_vars.len > 0) {
            ext_decls = try allocator.alloc(new_compiler.ExternalVarDecl, opts.external_vars.len);
            for (opts.external_vars, ext_decls) |src_decl, *dst| {
                dst.* = .{ .name = src_decl.name };
            }
        }
        defer if (ext_decls.len > 0) allocator.free(ext_decls);

        // Phase 2R cutover: the compiler covers every operator category;
        // unhandled cases panic inside the compiler. Only OOM propagates.
        const module_opts: new_compiler.ModuleOpts = .{
            .module_search_path = opts.module_search_path,
            .current_file_dir = opts.current_file_dir,
        };
        const result = try new_compiler.compile(src, ext_decls, module_opts, allocator);
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
            q.opts.module_search_path,
            q.opts.current_file_dir,
            allocator,
        );
    }
};
