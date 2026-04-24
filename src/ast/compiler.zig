//! AST-walk compile pipeline — Phase 2 (Stage 0 + Stage 1 scaffold).
//!
//! Goal: walk the `src/ast/parser.zig`-produced AST and emit bytecode byte-for-byte
//! equivalent to the legacy token-driven compiler at `src/query/src/compiler.zig`.
//! This file is the future replacement for that compiler; for now it covers only
//! the scope documented in `research/phase-2-ast-walk-plan.md` §4 Stage 0/1:
//!   - `.literal` (int, float, string, bool, null)
//!   - `.identity` (bare `.`)
//!   - `.recurse` (`..` operator → `call_builtin(recurse)`)
//!   - `.unary_neg` over a numeric literal (bare negative literals)
//!
//! Every other node kind returns `error.AstCompilerStageIncomplete`. This is NOT
//! a workaround — it is the scaffold boundary, to be removed as later stages
//! (2–13) extend coverage. See the plan doc for the full stage breakdown.
//!
//! Production code is unaffected. The legacy compiler at
//! `src/query/src/compiler.zig` remains the definitional compiler until Stage 13
//! cutover.

const std = @import("std");
const ast = @import("ast");
const types = @import("types");
const err_mod = @import("error");
const regex_mod = @import("regex");
const Instruction = types.Instruction;
const Node = ast.Node;
const ParseResult = ast.ParseResult;

// ── Public surface ────────────────────────────────────────────────────────────

/// Re-export so callers can speak a single result shape regardless of which
/// compiler they invoked. Mirrors `compiler.zig:Compiled` field-for-field.
pub const Compiled = struct {
    instructions: []Instruction,
    function_table: []const types.FunctionDef,
    string_buf: []u8,
    external_var_ids: []u32,
    source_map: []u32,
    regex_pool: regex_mod.RegexPool,
    prefilter: ?void, // Stage 1 never populates prefilter; keep field for layout parity.

    pub fn deinit(c: *Compiled, alloc: std.mem.Allocator) void {
        alloc.free(c.instructions);
        alloc.free(c.string_buf);
        alloc.free(c.source_map);
        alloc.free(c.external_var_ids);
        c.regex_pool.deinit();
        _ = c.prefilter;
    }
};

pub const ExternalVarDecl = struct {
    name: []const u8,
};

pub const CompileResult = union(enum) {
    ok: Compiled,
    err: err_mod.CompileError,
};

/// Public scaffold-boundary error. Returned by the walker when it reaches an
/// AST node kind that Stage 1 does not yet cover. Later stages will remove
/// these one-by-one; when the full dispatch is complete this error disappears
/// from the public surface.
pub const WalkerError = error{AstCompilerStageIncomplete};

/// Compile a filter source via AST walk.
///
/// Signature matches `src/query/src/compiler.zig:compile` plus an optional
/// `filename` parameter (reserved for future diagnostic stages; unused in
/// Stage 0/1 but recorded here so the signature is stable).
///
/// Returns:
///   - `.ok` on success.
///   - `.err` when parse fails or when the walker hits a node kind outside
///     the Stage 1 scope (maps to `error.AstCompilerStageIncomplete` →
///     `query_syntax_error` for CompileResult compatibility; the Zig error
///     is what the harness matches on to distinguish scaffold misses from
///     real compile errors).
pub fn compile(
    alloc: std.mem.Allocator,
    src: []const u8,
    filename: ?[]const u8,
) (error{ OutOfMemory, AstCompilerStageIncomplete })!CompileResult {
    _ = filename;
    return compileWithExternals(alloc, src, &.{});
}

/// Variant that accepts pre-declared external variables — mirrors the legacy
/// compile entry point. External-var declaration is a Stage 4 concern, but the
/// parameter is kept here so that the harness signature lines up without churn
/// when Stage 4 lands.
pub fn compileWithExternals(
    alloc: std.mem.Allocator,
    src: []const u8,
    external_vars: []const ExternalVarDecl,
) (error{ OutOfMemory, AstCompilerStageIncomplete })!CompileResult {
    // Stage 1 does not support external variables; reject rather than silently
    // drop them. Stage 4 lifts this.
    if (external_vars.len > 0) return error.AstCompilerStageIncomplete;

    var parsed = ast.parse(src, alloc);
    defer parsed.deinit();

    if (parsed.hasErrors()) {
        // Stage 0/1 error mapping — everything routes to query_syntax_error.
        // Stage 9 (user functions) + Stage 10 (builtins) will widen this.
        const first = parsed.errors[0];
        return .{ .err = .{
            .kind = .query_syntax_error,
            .offset = first.span.start,
            .len = if (first.span.end > first.span.start) first.span.end - first.span.start else 0,
        } };
    }

    var walker: Walker = .{
        .alloc = alloc,
        .raw = .{},
        .intern = .{},
    };
    defer walker.raw.deinit(alloc);
    var intern_consumed = false;
    defer if (!intern_consumed) walker.intern.deinit(alloc);

    walker.walk(parsed.root) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AstCompilerStageIncomplete => return error.AstCompilerStageIncomplete,
    };

    // Append implicit yield_output if not already present (mirrors legacy at
    // `compiler.zig:1449-1453`).
    const needs_output = walker.raw.items.len == 0 or
        walker.raw.items[walker.raw.items.len - 1].op != .yield_output;
    if (needs_output) {
        try walker.raw.append(alloc, .{
            .op = .yield_output,
            .operand = .{ .none = {} },
            .src_offset = walker.last_emit_offset,
        });
    }

    const compiled = try fuse(alloc, walker.raw.items, &walker.intern);
    intern_consumed = true; // fuse took ownership via toOwnedSlice.
    return .{ .ok = compiled };
}

// ── Walker ────────────────────────────────────────────────────────────────────

/// Byte range within the intern buffer. Matches `compiler.zig:StrRef` layout so
/// the two compilers produce the same operand bytes for `.push_string`.
const StrRef = extern struct { offset: u32, len: u32 };

const RawOp = extern union {
    str_ref: StrRef,
    index: i64,
    bool: bool,
    int: i64,
    float: f64,
    none: void,
    slice_args: types.SliceArgs,
};

const RawInstr = extern struct {
    op: Instruction.Op,
    operand: RawOp,
    src_offset: u32 = 0,
};

const Walker = struct {
    alloc: std.mem.Allocator,
    raw: std.ArrayList(RawInstr),
    intern: std.ArrayList(u8),
    /// Tracks the `src_offset` of the most recently emitted raw instruction.
    /// Used for the trailing implicit `yield_output`, matching the legacy
    /// compiler's "stamp with last consumed token offset" convention.
    last_emit_offset: u32 = 0,

    const Error = error{ OutOfMemory, AstCompilerStageIncomplete };

    fn emit(w: *Walker, op: Instruction.Op, operand: RawOp, src_offset: u32) error{OutOfMemory}!void {
        try w.raw.append(w.alloc, .{ .op = op, .operand = operand, .src_offset = src_offset });
        w.last_emit_offset = src_offset;
    }

    fn walk(w: *Walker, node: *const Node) Error!void {
        switch (node.kind) {
            .identity => {
                // Bare `.` — push current. Legacy stamps offset of the `.`
                // token; AST `identity.span.start` is the same byte.
                try w.emit(.push_current, .{ .none = {} }, node.span.start);
            },

            .recurse => {
                // `..` → call_builtin(recurse). See compiler.zig:6293.
                try w.emit(.call_builtin, .{ .index = @intFromEnum(types.BuiltinId.recurse) }, node.span.start);
            },

            .literal => |lit| switch (lit) {
                .null_val => {
                    try w.emit(.push_null, .{ .none = {} }, node.span.start);
                },
                .bool_val => |b| {
                    try w.emit(.push_bool, .{ .bool = b }, node.span.start);
                },
                .int => |n| {
                    try w.emit(.push_int, .{ .int = n }, node.span.start);
                },
                .float => |f| {
                    try w.emit(.push_float, .{ .float = f }, node.span.start);
                },
                .string => |s| {
                    // The AST parser already decoded escapes; intern the
                    // decoded bytes directly. Matches legacy's
                    // internDecodedStr outcome because both paths store the
                    // post-decode content.
                    const ref = try internStr(&w.intern, w.alloc, s);
                    try w.emit(.push_string, .{ .str_ref = ref }, node.span.start);
                },
            },

            .unary_neg => |u| {
                // Stage 1 supports ONLY `unary_neg` wrapping a literal — the
                // bare-negative-literal case (e.g. `-1`, `-0.5`). The legacy
                // compiler at compiler.zig:5834 emits:
                //     push_<num>(N) [src_offset = literal_offset]
                //     negate        [src_offset = literal_offset]
                // because `ctx.last_tok_offset` after recursing through
                // `parsePrimary` sits on the numeric literal. The operand's
                // `span.start` is that same literal offset, so we reuse it
                // for byte-identical emission.
                switch (u.operand.kind) {
                    .literal => |lit| switch (lit) {
                        .int => |n| {
                            try w.emit(.push_int, .{ .int = n }, u.operand.span.start);
                            try w.emit(.negate, .{ .none = {} }, u.operand.span.start);
                        },
                        .float => |f| {
                            try w.emit(.push_float, .{ .float = f }, u.operand.span.start);
                            try w.emit(.negate, .{ .none = {} }, u.operand.span.start);
                        },
                        else => return error.AstCompilerStageIncomplete,
                    },
                    else => return error.AstCompilerStageIncomplete,
                }
            },

            // ── Scaffold boundary: every other kind is a future stage. ──
            .pipe,
            .comma,
            .func_def,
            .alternative,
            .or_expr,
            .and_expr,
            .comparison,
            .arithmetic,
            .as_pattern,
            .destruct_alt,
            .field_access,
            .index_access,
            .iterate,
            .slice,
            .paren,
            .variable_ref,
            .optional,
            .array_construct,
            .object_construct,
            .string_interp,
            .format_string,
            .builtin_call,
            .func_call,
            .if_expr,
            .try_catch,
            .reduce,
            .foreach,
            .label_expr,
            .break_expr,
            .update_assign,
            .suffix,
            .error_node,
            => return error.AstCompilerStageIncomplete,
        }
    }
};

// ── Intern / fuse (Stage 1 minimum) ───────────────────────────────────────────

fn internStr(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}!StrRef {
    const off: u32 = @intCast(buf.items.len);
    try buf.appendSlice(alloc, s);
    return .{ .offset = off, .len = @intCast(s.len) };
}

/// Stage-1 fuse. Stage 1 emits no `load_key` sequences, so the fuse is a
/// straight 1:1 translation from `RawInstr` to `Instruction`. Later stages
/// will extend this (load_key/load_path collapse, jump-target remapping,
/// etc.) — for now, the dispatch table below mirrors the subset of
/// `compiler.zig:fuse` that Stage 1 exercises.
fn fuse(
    alloc: std.mem.Allocator,
    raw: []const RawInstr,
    intern: *std.ArrayList(u8),
) error{OutOfMemory}!Compiled {
    var src_offsets = try alloc.alloc(u32, raw.len);
    errdefer alloc.free(src_offsets);
    for (raw, 0..) |r, i| src_offsets[i] = r.src_offset;

    const instructions = try alloc.alloc(Instruction, raw.len);
    errdefer alloc.free(instructions);

    for (raw, instructions) |r, *out| {
        out.* = .{
            .op = r.op,
            .operand = switch (r.op) {
                .push_null, .push_current, .identity, .negate => .{ .none = {} },
                .push_bool => .{ .bool = r.operand.bool },
                .push_int => .{ .int = r.operand.int },
                .push_float => .{ .float = r.operand.float },
                .push_string => .{ .str_ref = .{
                    .offset = r.operand.str_ref.offset,
                    .len = r.operand.str_ref.len,
                } },
                .call_builtin => .{ .index = r.operand.index },
                .yield_output => .{ .none = {} },
                // Any other op reaching this fuse is a Stage > 1 leak. Route
                // to `.none` rather than panic so the equivalence harness
                // surfaces the mismatch instead of crashing.
                else => .{ .none = {} },
            },
        };
    }

    const string_buf = try intern.toOwnedSlice(alloc);
    errdefer alloc.free(string_buf);

    const function_defs = try alloc.alloc(types.FunctionDef, 0);
    errdefer alloc.free(function_defs);

    const external_var_ids = try alloc.alloc(u32, 0);
    errdefer alloc.free(external_var_ids);

    return Compiled{
        .instructions = instructions,
        .function_table = function_defs,
        .string_buf = string_buf,
        .external_var_ids = external_var_ids,
        .source_map = src_offsets,
        .regex_pool = regex_mod.RegexPool.init(alloc),
        .prefilter = null,
    };
}

// ── Tests: Stage 1 sanity checks. The full equivalence harness lives at
//    `tests/ast_compile_equiv.zig` and is exercised via
//    `zig build ast-compile-equiv`. ────────────────────────────────────────────

test "walker: identity emits push_current + yield_output" {
    const alloc = std.testing.allocator;
    var result = try compile(alloc, ".", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    const ins = result.ok.instructions;
    try std.testing.expectEqual(@as(usize, 2), ins.len);
    try std.testing.expectEqual(Instruction.Op.push_current, ins[0].op);
    try std.testing.expectEqual(Instruction.Op.yield_output, ins[1].op);
}

test "walker: recurse emits call_builtin(recurse)" {
    const alloc = std.testing.allocator;
    var result = try compile(alloc, "..", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    const ins = result.ok.instructions;
    try std.testing.expectEqual(Instruction.Op.call_builtin, ins[0].op);
    try std.testing.expectEqual(
        @as(i64, @intFromEnum(types.BuiltinId.recurse)),
        ins[0].operand.index,
    );
}

test "walker: negative integer emits push_int + negate" {
    const alloc = std.testing.allocator;
    var result = try compile(alloc, "-42", null);
    defer switch (result) {
        .ok => |*c| @constCast(c).deinit(alloc),
        .err => {},
    };
    try std.testing.expect(result == .ok);
    const ins = result.ok.instructions;
    try std.testing.expectEqual(Instruction.Op.push_int, ins[0].op);
    try std.testing.expectEqual(@as(i64, 42), ins[0].operand.int);
    try std.testing.expectEqual(Instruction.Op.negate, ins[1].op);
}

test "walker: pipe is scaffold-boundary (Stage 1 unsupported)" {
    const alloc = std.testing.allocator;
    const res = compile(alloc, ". | .", null);
    try std.testing.expectError(error.AstCompilerStageIncomplete, res);
}
