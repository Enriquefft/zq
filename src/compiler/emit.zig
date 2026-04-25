//! IR → bytecode emission — Phase 2R / R3.
//!
//! The emitter walks the IR tree recursively from the root. Op
//! handlers decide the relative order of child visits and own
//! instruction emission. AST shapes outside the supported category
//! surface as `error.NewCompilerNotImplemented`; the harness reports
//! SKIP for them.
//!
//! The output `Compiled` matches the legacy compiler's shape exactly
//! (plan §1.3 row 7). The instructions list is owned by the supplied
//! allocator, so callers must `Compiled.deinit(alloc)` once the query
//! is dropped.

const std = @import("std");
const types_mod = @import("types");
const err_mod = @import("error");
const regex_mod = @import("regex");
const prefilter_mod = @import("prefilter");
const ir = @import("ir.zig");
const ctypes = @import("types.zig");

/// Errors surfaced by emission. `OutOfMemory` from arena/instruction
/// allocs; `NewCompilerNotImplemented` for ops outside the supported
/// category set.
pub const EmitError = error{
    OutOfMemory,
    NewCompilerNotImplemented,
};

/// Emit bytecode from `ir_obj`. The emitter walks the IR tree
/// recursively from the root (the last-pushed node, since lowering
/// uses post-order construction). Each op handler decides the order
/// of child visits relative to its own instruction emission — binary
/// `pipe` interleaves (left, pipe, right); unary `try_` brackets its
/// child with `fork_try`/`pop_try`; leaves emit one instruction.
pub fn emit(
    ir_obj: ir.IR,
    external_var_count: usize,
    allocator: std.mem.Allocator,
) EmitError!ctypes.Compiled {
    var instructions: std.ArrayListUnmanaged(types_mod.Instruction) = .{};
    errdefer instructions.deinit(allocator);

    var source_map: std.ArrayListUnmanaged(u32) = .{};
    errdefer source_map.deinit(allocator);

    // The final `string_buf` blends two sources:
    //   1. Strings interned during lowering (in `ir_obj.string_buf`) —
    //      copied verbatim. The IR's `extra_data` already encodes
    //      `(offset, len)` against this buffer; we keep those offsets
    //      stable by appending to a fresh `string_buf` starting at 0.
    //   2. Newly-emitted strings (none today) — would append after the
    //      IR's bytes.
    var string_buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer string_buf.deinit(allocator);
    try string_buf.appendSlice(allocator, ir_obj.string_buf.items);

    // The IR root is the last-pushed node (lowering is post-order).
    // An empty IR is a programming error — lowering always produces
    // at least one node for a non-empty AST.
    if (ir_obj.nodes.items.len > 0) {
        const root_idx: u32 = @intCast(ir_obj.nodes.items.len - 1);
        try emitNode(&instructions, &source_map, ir_obj, root_idx, allocator);
    }

    // Trailing `yield_output` matches the legacy compiler's contract
    // (`src/query/src/compiler.zig:1448-1453`). The VM uses it to
    // surface results to the iterator boundary.
    try instructions.append(allocator, .{ .op = .yield_output, .operand = .{ .none = {} } });
    try source_map.append(allocator, 0);

    const instr_slice = try instructions.toOwnedSlice(allocator);
    errdefer allocator.free(instr_slice);

    const buf_slice = try string_buf.toOwnedSlice(allocator);
    errdefer allocator.free(buf_slice);

    const src_map_slice = try source_map.toOwnedSlice(allocator);
    errdefer allocator.free(src_map_slice);

    const function_defs: []const types_mod.FunctionDef = &.{};

    const ext_var_ids = try allocator.alloc(u32, external_var_count);
    errdefer allocator.free(ext_var_ids);
    for (ext_var_ids, 0..) |*id, i| id.* = @intCast(i);

    return .{
        .instructions = instr_slice,
        .function_table = function_defs,
        .string_buf = buf_slice,
        .external_var_ids = ext_var_ids,
        .source_map = src_map_slice,
        .regex_pool = regex_mod.RegexPool.init(allocator),
        .prefilter = null,
    };
}

fn emitNode(
    instructions: *std.ArrayListUnmanaged(types_mod.Instruction),
    source_map: *std.ArrayListUnmanaged(u32),
    ir_obj: ir.IR,
    node_idx: u32,
    allocator: std.mem.Allocator,
) EmitError!void {
    const node = ir_obj.nodes.items[node_idx];
    switch (node.op) {
        .load_const => {
            const value = ir.loadConstValue(&ir_obj, node);
            switch (value) {
                .null_val => try push(instructions, source_map, .push_null, .{ .none = {} }, node, allocator),
                .bool_val => |b| try push(instructions, source_map, .push_bool, .{ .bool = b }, node, allocator),
                .int => |n| try push(instructions, source_map, .push_int, .{ .int = n }, node, allocator),
                .float => |f| try push(instructions, source_map, .push_float, .{ .float = f }, node, allocator),
                .string => {
                    const slots = ir_obj.extra_data.items;
                    const offset: u32 = slots[node.extra + 1];
                    const len: u32 = slots[node.extra + 2];
                    try push(
                        instructions,
                        source_map,
                        .push_string,
                        .{ .str_ref = .{ .offset = offset, .len = len } },
                        node,
                        allocator,
                    );
                },
            }
        },

        .identity => try push(instructions, source_map, .identity, .{ .none = {} }, node, allocator),

        .recurse => try push(
            instructions,
            source_map,
            .call_builtin,
            .{ .index = @intFromEnum(types_mod.BuiltinId.recurse) },
            node,
            allocator,
        ),

        .neg => {
            try emitNode(instructions, source_map, ir_obj, node.children[0], allocator);
            try push(instructions, source_map, .negate, .{ .none = {} }, node, allocator);
        },

        .not => try push(instructions, source_map, .not, .{ .none = {} }, node, allocator),

        .call_builtin => {
            // Category 1 hits this only for `type` (the brief assigns
            // `type` to category 1 alongside `not`). Other builtins are
            // category 10's responsibility.
            const slots = ir_obj.extra_data.items;
            const offset: u32 = slots[node.extra];
            const len: u32 = slots[node.extra + 1];
            const name = ir_obj.string_buf.items[offset .. offset + len];

            const bid: types_mod.BuiltinId = if (std.mem.eql(u8, name, "type"))
                .type_
            else
                return error.NewCompilerNotImplemented;
            try push(
                instructions,
                source_map,
                .call_builtin,
                .{ .index = @intFromEnum(bid) },
                node,
                allocator,
            );
        },

        // ── Category 2 ──────────────────────────────────────────────
        .load_field => {
            const slots = ir_obj.extra_data.items;
            const offset: u32 = slots[node.extra];
            const len: u32 = slots[node.extra + 1];
            try push(
                instructions,
                source_map,
                .load_key,
                .{ .str_ref = .{ .offset = offset, .len = len } },
                node,
                allocator,
            );
        },

        .load_index => {
            const slots = ir_obj.extra_data.items;
            const lo: u64 = slots[node.extra];
            const hi: u64 = slots[node.extra + 1];
            const u: u64 = lo | (hi << 32);
            const n: i64 = @bitCast(u);
            try push(instructions, source_map, .load_index, .{ .index = n }, node, allocator);
        },

        .iterate => try push(instructions, source_map, .each, .{ .none = {} }, node, allocator),

        .slice => {
            const slots = ir_obj.extra_data.items;
            const from_u: u32 = slots[node.extra];
            const to_u: u32 = slots[node.extra + 1];
            const flags: u32 = slots[node.extra + 2];
            const args = types_mod.SliceArgs{
                .from = @bitCast(from_u),
                .to = @bitCast(to_u),
                .has_from = (flags & 1) != 0,
                .has_to = (flags & 2) != 0,
            };
            try push(instructions, source_map, .slice, .{ .slice_args = args }, node, allocator);
        },

        // Pipe: emit left, then `pipe` instruction, then right. The
        // legacy walker emits the same shape — `pipe` between adjacent
        // suffix elements, never bracketing both children.
        .pipe => {
            try emitNode(instructions, source_map, ir_obj, node.children[0], allocator);
            try push(instructions, source_map, .pipe, .{ .none = {} }, node, allocator);
            try emitNode(instructions, source_map, ir_obj, node.children[1], allocator);
        },

        // Comma: emit a fork bracketing the left arm with a jump-end so
        // backtracking from the left's last yield resumes at the right
        // arm's entry. Mirrors legacy `parseComma` (compiler.zig:2379):
        // fork target = right_start; jump target = end. Backpatch both
        // after the corresponding subtree has been emitted.
        .comma => {
            const fork_pos: usize = instructions.items.len;
            try push(instructions, source_map, .fork, .{ .index = 0 }, node, allocator);
            try emitNode(instructions, source_map, ir_obj, node.children[0], allocator);
            const jump_pos: usize = instructions.items.len;
            try push(instructions, source_map, .jump, .{ .index = 0 }, node, allocator);
            const right_start: u32 = @intCast(instructions.items.len);
            instructions.items[fork_pos].operand = .{ .index = right_start };
            try emitNode(instructions, source_map, ir_obj, node.children[1], allocator);
            const end_ip: u32 = @intCast(instructions.items.len);
            instructions.items[jump_pos].operand = .{ .index = end_ip };
        },

        // Try wrap: record the start IP, emit the inner expression,
        // insert `fork_try` at the recorded start, then append
        // `pop_try`. Mirrors the legacy `?`-segment-wrap
        // (`insertRawInstr(segment_start, fork_try)` + emit `pop_try`).
        // The catch IP stays 0 — postfix `?` swallows errors silently.
        .try_ => {
            const start: usize = instructions.items.len;
            try emitNode(instructions, source_map, ir_obj, node.children[0], allocator);
            try instructions.insert(allocator, start, .{ .op = .fork_try, .operand = .{ .index = 0 } });
            try source_map.insert(allocator, start, node.src_start);
            try push(instructions, source_map, .pop_try, .{ .none = {} }, node, allocator);
        },

        // ── Category 5 ──────────────────────────────────────────────
        // Emit lhs (pushes its result on the value stack), then rhs
        // (pushes another), then the binary op (pops both, pushes the
        // result). Matches the legacy parser's
        // `parseAdditive`/`parseMultiplicative` shape at
        // `src/query/src/compiler.zig:2699-2729`.
        .arith => {
            try emitNode(instructions, source_map, ir_obj, node.children[0], allocator);
            try emitNode(instructions, source_map, ir_obj, node.children[1], allocator);
            const slots = ir_obj.extra_data.items;
            const kind: ir.ArithKind = @enumFromInt(slots[node.extra]);
            const op: types_mod.Instruction.Op = switch (kind) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                .mod => .mod,
            };
            try push(instructions, source_map, op, .{ .none = {} }, node, allocator);
        },

        .cmp => {
            try emitNode(instructions, source_map, ir_obj, node.children[0], allocator);
            try emitNode(instructions, source_map, ir_obj, node.children[1], allocator);
            const slots = ir_obj.extra_data.items;
            const kind: ir.CmpKind = @enumFromInt(slots[node.extra]);
            const op: types_mod.Instruction.Op = switch (kind) {
                .eq => .eq,
                .ne => .ne,
                .lt => .lt,
                .le => .le,
                .gt => .gt,
                .ge => .ge,
            };
            try push(instructions, source_map, op, .{ .none = {} }, node, allocator);
        },

        // Logical: emit lhs + rhs, then `and_op`/`or_op`. Legacy's VM
        // (`src/query/src/vm.zig:6575-6589`) evaluates both operands
        // eagerly and reduces to a boolean — jq does not short-circuit
        // at the bytecode layer.
        .logical => {
            try emitNode(instructions, source_map, ir_obj, node.children[0], allocator);
            try emitNode(instructions, source_map, ir_obj, node.children[1], allocator);
            const slots = ir_obj.extra_data.items;
            const kind: ir.LogicalKind = @enumFromInt(slots[node.extra]);
            const op: types_mod.Instruction.Op = switch (kind) {
                .and_ => .and_op,
                .or_ => .or_op,
            };
            try push(instructions, source_map, op, .{ .none = {} }, node, allocator);
        },

        // Alternative `//`: mirror the legacy `parseAlternative` shape at
        // `src/query/src/compiler.zig:2453-2491`. Legacy emits the LHS
        // first then `insertRawInstr(chain_start, fork_alt)` because
        // parser-driven compilation cannot peek `//` until after LHS is
        // already in the buffer. Tree-walking emission can place the
        // `fork_alt` first directly — semantically identical, and it
        // avoids the IP-rebase that nested `//` would otherwise need
        // (each nested alt's recorded chain_start overlaps the outer
        // one and `insert` would shift sibling fork_alts' operands).
        // Layout:
        //   fork_alt L_right       ← backpatch to RHS start
        //   <LHS>
        //   pipe                   ← lift value-stack top to current
        //   push_current           ← dup current for truthiness check
        //   jump_if_false L_falsy
        //   pop_try                ← truthy: drop alt-handler
        //   push_current           ← truthy: re-push committed value
        //   jump L_end
        //   L_falsy:
        //   backtrack              ← alt-handler runs; jumps to L_right
        //   L_right:
        //   <RHS>
        //   L_end:
        .alt => {
            const fork_alt_pos: usize = instructions.items.len;
            try push(
                instructions,
                source_map,
                .fork_alt,
                .{ .index = 0 },
                node,
                allocator,
            );

            try emitNode(instructions, source_map, ir_obj, node.children[0], allocator);

            try push(instructions, source_map, .pipe, .{ .none = {} }, node, allocator);
            try push(instructions, source_map, .push_current, .{ .none = {} }, node, allocator);

            const jif_pos: usize = instructions.items.len;
            try push(
                instructions,
                source_map,
                .jump_if_false,
                .{ .index = 0 },
                node,
                allocator,
            );

            // Truthy: drop alt-handler, re-push value, jump past RHS.
            try push(instructions, source_map, .pop_try, .{ .none = {} }, node, allocator);
            try push(instructions, source_map, .push_current, .{ .none = {} }, node, allocator);

            const jump_end_pos: usize = instructions.items.len;
            try push(
                instructions,
                source_map,
                .jump,
                .{ .index = 0 },
                node,
                allocator,
            );

            // Falsy: backtrack into the alt-handler, which jumps to RHS.
            instructions.items[jif_pos].operand = .{ .index = @intCast(instructions.items.len) };
            try push(instructions, source_map, .backtrack, .{ .none = {} }, node, allocator);

            const right_ip: u32 = @intCast(instructions.items.len);
            instructions.items[fork_alt_pos].operand = .{ .index = right_ip };

            try emitNode(instructions, source_map, ir_obj, node.children[1], allocator);

            instructions.items[jump_end_pos].operand = .{ .index = @intCast(instructions.items.len) };
        },

        else => return error.NewCompilerNotImplemented,
    }
}

fn push(
    instructions: *std.ArrayListUnmanaged(types_mod.Instruction),
    source_map: *std.ArrayListUnmanaged(u32),
    op: types_mod.Instruction.Op,
    operand: types_mod.Instruction.Operand,
    node: ir.Node,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!void {
    try instructions.append(allocator, .{ .op = op, .operand = operand });
    try source_map.append(allocator, node.src_start);
}
