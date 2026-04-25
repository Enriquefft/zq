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

/// Shared emission state. Holds the instruction stream, source map,
/// IR (for child lookup), allocator, and a running `next_var_id`
/// counter. The counter starts above `external_var_count` so externally
/// declared variables retain their pre-assigned ids (mirrors the legacy
/// compiler's `Ctx.next_var_id` initialization at
/// `src/query/src/compiler.zig:1319-1390`).
const Emitter = struct {
    instructions: *std.ArrayListUnmanaged(types_mod.Instruction),
    source_map: *std.ArrayListUnmanaged(u32),
    ir_obj: ir.IR,
    allocator: std.mem.Allocator,
    next_var_id: u32,

    fn allocVar(self: *Emitter) u32 {
        const id = self.next_var_id;
        self.next_var_id += 1;
        return id;
    }

    fn pushInstr(
        self: *Emitter,
        op: types_mod.Instruction.Op,
        operand: types_mod.Instruction.Operand,
        node: ir.Node,
    ) error{OutOfMemory}!void {
        try self.instructions.append(self.allocator, .{ .op = op, .operand = operand });
        try self.source_map.append(self.allocator, node.src_start);
    }
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
        var emitter = Emitter{
            .instructions = &instructions,
            .source_map = &source_map,
            .ir_obj = ir_obj,
            .allocator = allocator,
            .next_var_id = @intCast(external_var_count),
        };
        try emitNode(&emitter, root_idx);
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

fn emitNode(em: *Emitter, node_idx: u32) EmitError!void {
    const node = em.ir_obj.nodes.items[node_idx];
    switch (node.op) {
        .load_const => {
            const value = ir.loadConstValue(&em.ir_obj, node);
            switch (value) {
                .null_val => try em.pushInstr(.push_null, .{ .none = {} }, node),
                .bool_val => |b| try em.pushInstr(.push_bool, .{ .bool = b }, node),
                .int => |n| try em.pushInstr(.push_int, .{ .int = n }, node),
                .float => |f| try em.pushInstr(.push_float, .{ .float = f }, node),
                .string => {
                    const slots = em.ir_obj.extra_data.items;
                    const offset: u32 = slots[node.extra + 1];
                    const len: u32 = slots[node.extra + 2];
                    try em.pushInstr(
                        .push_string,
                        .{ .str_ref = .{ .offset = offset, .len = len } },
                        node,
                    );
                },
            }
        },

        .identity => try em.pushInstr(.push_current, .{ .none = {} }, node),

        .recurse => try em.pushInstr(
            .call_builtin,
            .{ .index = @intFromEnum(types_mod.BuiltinId.recurse) },
            node,
        ),

        .neg => {
            try emitNode(em, node.children[0]);
            try em.pushInstr(.negate, .{ .none = {} }, node);
        },

        .not => try em.pushInstr(.not, .{ .none = {} }, node),

        .call_builtin => {
            // Category 1 hits this only for `type` (the brief assigns
            // `type` to category 1 alongside `not`). Other builtins are
            // category 10's responsibility.
            const slots = em.ir_obj.extra_data.items;
            const offset: u32 = slots[node.extra];
            const len: u32 = slots[node.extra + 1];
            const name = em.ir_obj.string_buf.items[offset .. offset + len];

            const bid: types_mod.BuiltinId = if (std.mem.eql(u8, name, "type"))
                .type_
            else
                return error.NewCompilerNotImplemented;
            try em.pushInstr(
                .call_builtin,
                .{ .index = @intFromEnum(bid) },
                node,
            );
        },

        // ── Category 2 ──────────────────────────────────────────────
        .load_field => {
            const slots = em.ir_obj.extra_data.items;
            const offset: u32 = slots[node.extra];
            const len: u32 = slots[node.extra + 1];
            try em.pushInstr(
                .load_key,
                .{ .str_ref = .{ .offset = offset, .len = len } },
                node,
            );
        },

        .load_index => {
            const slots = em.ir_obj.extra_data.items;
            const lo: u64 = slots[node.extra];
            const hi: u64 = slots[node.extra + 1];
            const u: u64 = lo | (hi << 32);
            const n: i64 = @bitCast(u);
            try em.pushInstr(.load_index, .{ .index = n }, node);
        },

        .iterate => try em.pushInstr(.each, .{ .none = {} }, node),

        .slice => {
            const slots = em.ir_obj.extra_data.items;
            const from_u: u32 = slots[node.extra];
            const to_u: u32 = slots[node.extra + 1];
            const flags: u32 = slots[node.extra + 2];
            const args = types_mod.SliceArgs{
                .from = @bitCast(from_u),
                .to = @bitCast(to_u),
                .has_from = (flags & 1) != 0,
                .has_to = (flags & 2) != 0,
            };
            try em.pushInstr(.slice, .{ .slice_args = args }, node);
        },

        // Pipe: emit left, then `pipe` instruction, then right. The
        // legacy walker emits the same shape — `pipe` between adjacent
        // suffix elements, never bracketing both children.
        .pipe => {
            try emitNode(em, node.children[0]);
            try em.pushInstr(.pipe, .{ .none = {} }, node);
            try emitNode(em, node.children[1]);
        },

        // Comma: emit a fork bracketing the left arm with a jump-end so
        // backtracking from the left's last yield resumes at the right
        // arm's entry. Mirrors legacy `parseComma` (compiler.zig:2379):
        // fork target = right_start; jump target = end. Backpatch both
        // after the corresponding subtree has been emitted.
        .comma => {
            const fork_pos: usize = em.instructions.items.len;
            try em.pushInstr(.fork, .{ .index = 0 }, node);
            try emitNode(em, node.children[0]);
            const jump_pos: usize = em.instructions.items.len;
            try em.pushInstr(.jump, .{ .index = 0 }, node);
            const right_start: u32 = @intCast(em.instructions.items.len);
            em.instructions.items[fork_pos].operand = .{ .index = right_start };
            try emitNode(em, node.children[1]);
            const end_ip: u32 = @intCast(em.instructions.items.len);
            em.instructions.items[jump_pos].operand = .{ .index = end_ip };
        },

        // Try wrap: two shapes drive emission.
        //   span_len == 0 → handler-absent: postfix `?` / `try expr`.
        //                  Layout: `fork_try 0 ; <body> ; pop_try`. The
        //                  catch IP stays 0 — error is swallowed
        //                  silently. Mirrors legacy
        //                  `?`-segment-wrap.
        //   span_len == 2 → handler-present: `try expr catch handler`.
        //                  Layout: `fork_try L_catch ; <body> ; pop_try
        //                  ; jump L_end ; L_catch: <handler> ; L_end:`.
        //                  Mirrors legacy `parseTryCatch`
        //                  (`src/query/src/compiler.zig:6297`).
        // The shape distinction is encoded via `span_len` rather than
        // a separate `extra` flag — both children fit in the
        // variable-arity span when present, and the no-handler form
        // continues to use `children[0]` for cache-friendliness.
        .try_ => {
            if (node.span_len == 0) {
                // No-handler form (`try expr` or `expr?`):
                //   `fork_try L_after ; <body> ; pop_try ; L_after:`
                // Errors on the body are swallowed silently (legacy
                // `?`-segment-wrap shape).
                const start: usize = em.instructions.items.len;
                try emitNode(em, node.children[0]);
                try em.instructions.insert(em.allocator, start, .{ .op = .fork_try, .operand = .{ .index = 0 } });
                try em.source_map.insert(em.allocator, start, node.src_start);
                try em.pushInstr(.pop_try, .{ .none = {} }, node);
            } else {
                // Handler form (`try expr catch handler`):
                //   `fork_try L_catch ; <body> ; pop_try ; jump L_end ;
                //    L_catch: <handler> ; L_end:`.
                std.debug.assert(node.span_len == 2);
                const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
                const body_idx = span[0];
                const handler_idx = span[1];

                // fork_try with placeholder catch IP (backpatched once
                // the body completes and the handler's first IP is
                // known).
                const fork_pos: usize = em.instructions.items.len;
                try em.pushInstr(.fork_try, .{ .index = 0 }, node);

                // Body — yields normally on success.
                try emitNode(em, body_idx);

                // Success path: drop try-handler then jump past handler.
                try em.pushInstr(.pop_try, .{ .none = {} }, node);
                const jump_pos: usize = em.instructions.items.len;
                try em.pushInstr(.jump, .{ .index = 0 }, node);

                // Handler entry: backpatch fork_try to here.
                const catch_ip: u32 = @intCast(em.instructions.items.len);
                em.instructions.items[fork_pos].operand = .{ .index = catch_ip };
                try emitNode(em, handler_idx);

                // End: backpatch the jump past the handler.
                em.instructions.items[jump_pos].operand = .{ .index = @intCast(em.instructions.items.len) };
            }
        },

        // ── Category 5 ──────────────────────────────────────────────
        // Emit lhs (pushes its result on the value stack), then rhs
        // (pushes another), then the binary op (pops both, pushes the
        // result). Matches the legacy parser's
        // `parseAdditive`/`parseMultiplicative` shape at
        // `src/query/src/compiler.zig:2699-2729`.
        .arith => {
            try emitNode(em, node.children[0]);
            try emitNode(em, node.children[1]);
            const slots = em.ir_obj.extra_data.items;
            const kind: ir.ArithKind = @enumFromInt(slots[node.extra]);
            const op: types_mod.Instruction.Op = switch (kind) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                .mod => .mod,
            };
            try em.pushInstr(op, .{ .none = {} }, node);
        },

        .cmp => {
            try emitNode(em, node.children[0]);
            try emitNode(em, node.children[1]);
            const slots = em.ir_obj.extra_data.items;
            const kind: ir.CmpKind = @enumFromInt(slots[node.extra]);
            const op: types_mod.Instruction.Op = switch (kind) {
                .eq => .eq,
                .ne => .ne,
                .lt => .lt,
                .le => .le,
                .gt => .gt,
                .ge => .ge,
            };
            try em.pushInstr(op, .{ .none = {} }, node);
        },

        // Logical: emit lhs + rhs, then `and_op`/`or_op`. Legacy's VM
        // (`src/query/src/vm.zig:6575-6589`) evaluates both operands
        // eagerly and reduces to a boolean — jq does not short-circuit
        // at the bytecode layer.
        .logical => {
            try emitNode(em, node.children[0]);
            try emitNode(em, node.children[1]);
            const slots = em.ir_obj.extra_data.items;
            const kind: ir.LogicalKind = @enumFromInt(slots[node.extra]);
            const op: types_mod.Instruction.Op = switch (kind) {
                .and_ => .and_op,
                .or_ => .or_op,
            };
            try em.pushInstr(op, .{ .none = {} }, node);
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
            const fork_alt_pos: usize = em.instructions.items.len;
            try em.pushInstr(.fork_alt, .{ .index = 0 }, node);

            try emitNode(em, node.children[0]);

            try em.pushInstr(.pipe, .{ .none = {} }, node);
            try em.pushInstr(.push_current, .{ .none = {} }, node);

            const jif_pos: usize = em.instructions.items.len;
            try em.pushInstr(.jump_if_false, .{ .index = 0 }, node);

            // Truthy: drop alt-handler, re-push value, jump past RHS.
            try em.pushInstr(.pop_try, .{ .none = {} }, node);
            try em.pushInstr(.push_current, .{ .none = {} }, node);

            const jump_end_pos: usize = em.instructions.items.len;
            try em.pushInstr(.jump, .{ .index = 0 }, node);

            // Falsy: backtrack into the alt-handler, which jumps to RHS.
            em.instructions.items[jif_pos].operand = .{ .index = @intCast(em.instructions.items.len) };
            try em.pushInstr(.backtrack, .{ .none = {} }, node);

            const right_ip: u32 = @intCast(em.instructions.items.len);
            em.instructions.items[fork_alt_pos].operand = .{ .index = right_ip };

            try emitNode(em, node.children[1]);

            em.instructions.items[jump_end_pos].operand = .{ .index = @intCast(em.instructions.items.len) };
        },

        // ── Category 7 ──────────────────────────────────────────────
        // Object literal `{...}`. Variadic span carries (key, value)
        // pairs interleaved (k0, v0, k1, v1, ...). Emit
        // `object_construct_start` once, lower each pair followed by
        // `object_key`, then close with `object_construct_end`.
        // Matches legacy `parseObjectLiteral`
        // (`src/query/src/compiler.zig:6702`).
        .obj_ctor => {
            try em.pushInstr(.object_construct_start, .{ .none = {} }, node);
            const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            // Pairs are (k, v); span_len is always even (lowering invariant).
            std.debug.assert(span.len % 2 == 0);
            var pi: usize = 0;
            while (pi < span.len) : (pi += 2) {
                try emitNode(em, span[pi]);
                try emitNode(em, span[pi + 1]);
                try em.pushInstr(.object_key, .{ .none = {} }, node);
            }
            try em.pushInstr(.object_construct_end, .{ .none = {} }, node);
        },

        // Array literal `[...]`. Emits the `array_collect_start ... end`
        // pair around per-element `save_input / <elem> / yield_output /
        // restore_input` ladders. The start instruction's operand
        // receives the IP of the matching `array_collect_end` after
        // backpatching. Matches legacy `parseArrayConstruct`
        // (`src/query/src/compiler.zig:6410`).
        .arr_ctor => {
            const start_pos = em.instructions.items.len;
            try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);
            const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            for (span) |elem_idx| {
                try em.pushInstr(.save_input, .{ .none = {} }, node);
                try emitNode(em, elem_idx);
                try em.pushInstr(.yield_output, .{ .none = {} }, node);
                try em.pushInstr(.restore_input, .{ .none = {} }, node);
            }
            const end_pos: u32 = @intCast(em.instructions.items.len);
            try em.pushInstr(.array_collect_end, .{ .none = {} }, node);
            em.instructions.items[start_pos].operand = .{ .index = end_pos };
        },

        // String interpolation `"... \(expr) ..."`. The parts span is
        // `[lit0, expr0, lit1, expr1, ...]` (ladder always starts with a
        // literal — parser invariant). Emit a leading `push_string` for
        // `lit0`, then for each expr/lit-tail pair: `save_input ; <expr>
        // ; pipe ; call_builtin tostring ; add ; restore_input ;
        // push_string lit ; add`. Mirrors legacy
        // `compileStringInterpolation`
        // (`src/query/src/compiler.zig:5604`).
        .interp => {
            try emitInterpLadder(em, node, null);
        },

        // Format application `@fmt "..."`. Three legacy shapes:
        //   1. `@fmt "lit\(expr)..."` → interp ladder with format
        //                                builtin applied per expr part.
        //   2. `@fmt "literal"`       → bare `push_string` (no format).
        //   3. `@fmt` standalone     → call_builtin(format) on current.
        // Cat-7 owns shapes 1 and 2 (both arrive as `format_string`
        // AST). Shape 3 is `builtin_call` — cat-10's responsibility.
        .format => {
            const slots = em.ir_obj.extra_data.items;
            const offset: u32 = slots[node.extra];
            const len: u32 = slots[node.extra + 1];
            const fmt_name = em.ir_obj.string_buf.items[offset .. offset + len];
            // `fmt_name` carries a leading '@' (parser
            // `internFormatName`); legacy `formatBuiltinId` matches on
            // the unprefixed name.
            const bare = if (fmt_name.len > 0 and fmt_name[0] == '@') fmt_name[1..] else fmt_name;
            const bid = formatBuiltinId(bare) orelse return error.NewCompilerNotImplemented;

            // Shape 2: single literal part, no exprs → bare push_string.
            // Detect by inspecting the children: every part must be a
            // synthesized `load_const(string)` and there must be
            // exactly one such part.
            const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            if (span.len == 1) {
                const child = em.ir_obj.nodes.items[span[0]];
                if (child.op == .load_const) {
                    const value = ir.loadConstValue(&em.ir_obj, child);
                    if (value == .string) {
                        const c_slots = em.ir_obj.extra_data.items;
                        const c_off: u32 = c_slots[child.extra + 1];
                        const c_len: u32 = c_slots[child.extra + 2];
                        try em.pushInstr(
                            .push_string,
                            .{ .str_ref = .{ .offset = c_off, .len = c_len } },
                            node,
                        );
                        return;
                    }
                }
            }

            try emitInterpLadder(em, node, bid);
        },

        // ── Category 8 ──────────────────────────────────────────────
        // Update assignment. Single SemOp encoding the entire family
        // (=, +=, -=, *=, /=, %=, //=, |=) for both fast-path
        // (`update_assign` AST) and general-LHS (`assign_general` AST)
        // forms. The op-kind discriminant lives in
        // `extra_data[node.extra]`; a `.general` discriminant
        // additionally consumes `extra_data[node.extra + 1]` for the
        // inner operator alphabet. See `ir.UpdateOpKind`.
        .update_assign => {
            const slots = em.ir_obj.extra_data.items;
            const kind: ir.UpdateOpKind = @enumFromInt(slots[node.extra]);
            try emitUpdateAssign(em, node, kind);
        },

        // ── Category 6 — control flow ───────────────────────────────
        // if cond then A else B end. Variadic span carries exactly
        // three children: [cond, then_body, else_body]. elif chains
        // already nested the additional branches at lowering time
        // (`lowerIfElseChain`), so emit only ever sees a 3-child node.
        // Layout mirrors legacy `parseIfBody`
        // (`src/query/src/compiler.zig:6342`):
        //   save_input
        //   <cond>
        //   jump_if_false L_else
        //   restore_input
        //   <then>
        //   jump L_end
        //   L_else:
        //   restore_input
        //   <else>
        //   L_end:
        .if_ => {
            std.debug.assert(node.span_len == 3);
            const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            const cond_idx = span[0];
            const then_idx = span[1];
            const else_idx = span[2];

            try em.pushInstr(.save_input, .{ .none = {} }, node);
            try emitNode(em, cond_idx);

            // jump_if_false → start of the else branch (backpatched once
            // the then-arm and its trailing `jump` are emitted).
            const jif_pos: usize = em.instructions.items.len;
            try em.pushInstr(.jump_if_false, .{ .index = 0 }, node);

            // Then-arm: restore the saved input, emit the body, then
            // unconditionally jump past the else-arm.
            try em.pushInstr(.restore_input, .{ .none = {} }, node);
            try emitNode(em, then_idx);
            const jmp_pos: usize = em.instructions.items.len;
            try em.pushInstr(.jump, .{ .index = 0 }, node);

            // Else-arm entry — backpatch jif and emit.
            em.instructions.items[jif_pos].operand = .{ .index = @intCast(em.instructions.items.len) };
            try em.pushInstr(.restore_input, .{ .none = {} }, node);
            try emitNode(em, else_idx);

            // End: backpatch the post-then jump.
            em.instructions.items[jmp_pos].operand = .{ .index = @intCast(em.instructions.items.len) };
        },

        // path(expr): emit `path_begin <body> path_end`. The
        // `path_begin` operand is the IP of the `path_end` instruction
        // (the VM uses it to bound the path frame's effective range —
        // legacy `compilePath`, `src/query/src/compiler.zig:4733`).
        .path_begin => {
            const begin_pos: usize = em.instructions.items.len;
            try em.pushInstr(.path_begin, .{ .index = 0 }, node);
            try emitNode(em, node.children[0]);
            const end_pos: u32 = @intCast(em.instructions.items.len);
            try em.pushInstr(.path_end, .{ .none = {} }, node);
            em.instructions.items[begin_pos].operand = .{ .index = end_pos };
        },

        else => return error.NewCompilerNotImplemented,
    }
}

/// Emit the `compileStringInterpolation` ladder for an `interp` or
/// `format` node. The parts span starts with a literal, alternates
/// literal/expr after, but the parser always guarantees a literal as
/// the first part (the tokenizer surfaces interpolations as
/// `string_part` mid-tokens, never leading-expr). When `format_bid`
/// is supplied (only for `format` nodes), each expr part funnels
/// through `call_builtin(format_bid)` before `tostring`.
fn emitInterpLadder(
    em: *Emitter,
    node: ir.Node,
    format_bid: ?types_mod.BuiltinId,
) EmitError!void {
    const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
    // First part is a literal — push it directly. Empty literal still
    // pushes the empty string so the trailing `add`s have a base.
    const first_idx = span[0];
    const first_node = em.ir_obj.nodes.items[first_idx];
    std.debug.assert(first_node.op == .load_const);
    const first_slots = em.ir_obj.extra_data.items;
    const first_off: u32 = first_slots[first_node.extra + 1];
    const first_len: u32 = first_slots[first_node.extra + 2];
    try em.pushInstr(
        .push_string,
        .{ .str_ref = .{ .offset = first_off, .len = first_len } },
        node,
    );

    var i: usize = 1;
    while (i < span.len) : (i += 1) {
        const child_idx = span[i];
        const child = em.ir_obj.nodes.items[child_idx];
        // Literal segment → push + add.
        if (child.op == .load_const) blk: {
            const value = ir.loadConstValue(&em.ir_obj, child);
            if (value != .string) break :blk; // not a literal segment — fall through
            const c_slots = em.ir_obj.extra_data.items;
            const c_off: u32 = c_slots[child.extra + 1];
            const c_len: u32 = c_slots[child.extra + 2];
            // Match legacy behavior: empty literal segments are
            // skipped (no push_string + add) so the bytecode shape
            // stays identical (`compileStringInterpolation` line
            // 5650/5660 guards on `tail_raw.len > 0`).
            if (c_len > 0) {
                try em.pushInstr(
                    .push_string,
                    .{ .str_ref = .{ .offset = c_off, .len = c_len } },
                    node,
                );
                try em.pushInstr(.add, .{ .none = {} }, node);
            }
            continue;
        }

        // Expr segment → save_input ; <expr> ; pipe ; [format_bid? ;
        // pipe ;] tostring ; add ; restore_input.
        try em.pushInstr(.save_input, .{ .none = {} }, node);
        try emitNode(em, child_idx);
        try em.pushInstr(.pipe, .{ .none = {} }, node);
        if (format_bid) |bid| {
            try em.pushInstr(
                .call_builtin,
                .{ .index = @intFromEnum(bid) },
                node,
            );
            try em.pushInstr(.pipe, .{ .none = {} }, node);
        }
        try em.pushInstr(
            .call_builtin,
            .{ .index = @intFromEnum(types_mod.BuiltinId.tostring) },
            node,
        );
        try em.pushInstr(.add, .{ .none = {} }, node);
        try em.pushInstr(.restore_input, .{ .none = {} }, node);
    }
}

/// Map a format name (without the leading `@`) to the matching
/// `BuiltinId`. Single source of truth — cat-7 emit dispatches here
/// instead of duplicating the legacy `formatBuiltinId` table.
fn formatBuiltinId(name: []const u8) ?types_mod.BuiltinId {
    if (std.mem.eql(u8, name, "text")) return .format_text;
    if (std.mem.eql(u8, name, "json")) return .format_json;
    if (std.mem.eql(u8, name, "csv")) return .format_csv;
    if (std.mem.eql(u8, name, "tsv")) return .format_tsv;
    if (std.mem.eql(u8, name, "html")) return .format_html;
    if (std.mem.eql(u8, name, "uri")) return .format_uri;
    if (std.mem.eql(u8, name, "urid")) return .format_urid;
    if (std.mem.eql(u8, name, "sh")) return .format_sh;
    if (std.mem.eql(u8, name, "base64")) return .format_base64;
    if (std.mem.eql(u8, name, "base64d")) return .format_base64d;
    return null;
}

// ── Update-assign emission (cat-8) ───────────────────────────────────────────
//
// Both fast-path (`update_assign` AST) and general-LHS
// (`assign_general` AST) forms route through the single `update_assign`
// SemOp. The op-kind discriminant in `extra_data[node.extra]` selects
// between {set, add, sub, mul, div, mod, alt, update, general}; for
// `general` the inner operator alphabet lives in
// `extra_data[node.extra + 1]`.
//
// The emit ladders mirror the legacy compiler's
// `parseUpdateAssign` (fast path) and `compilePathExprUpdate`
// (general path) at `src/query/src/compiler.zig:1610-1909`. VM
// semantics are preserved byte-for-byte against legacy.

/// One step of an update-assign fast-path navigation chain. Decoded
/// inline from `extra_data` by `decodeFastPath`. The kind discriminant
/// matches the lowering encoding (0 = key, 1 = index).
const FastPathStep = union(enum) {
    key: types_mod.Tape.StringRef,
    index: i64,
};

/// Decode the fast-path payload starting at `extra_idx`. The first slot
/// is the op-kind discriminant; the second is the step count; then 3
/// slots per step (kind + 2-slot payload).
fn decodeFastPath(
    em: *Emitter,
    extra_idx: u32,
    out_steps: *std.ArrayListUnmanaged(FastPathStep),
) error{OutOfMemory}!void {
    const slots = em.ir_obj.extra_data.items;
    const num_steps = slots[extra_idx + 1];
    var i: u32 = 0;
    while (i < num_steps) : (i += 1) {
        const base = extra_idx + 2 + 3 * i;
        const step_kind = slots[base];
        const lo: u64 = slots[base + 1];
        const hi: u64 = slots[base + 2];
        if (step_kind == 0) {
            try out_steps.append(em.allocator, .{
                .key = .{ .offset = @intCast(lo), .len = @intCast(hi) },
            });
        } else {
            const u: u64 = lo | (hi << 32);
            const n: i64 = @bitCast(u);
            try out_steps.append(em.allocator, .{ .index = n });
        }
    }
}

/// Emit the fast-path navigation ladder: `save_input` then
/// `navigate_key`/`navigate_index` per step.
fn emitNavigation(em: *Emitter, node: ir.Node, steps: []const FastPathStep) error{OutOfMemory}!void {
    for (steps) |step| {
        try em.pushInstr(.save_input, .{ .none = {} }, node);
        switch (step) {
            .key => |sr| try em.pushInstr(.navigate_key, .{ .str_ref = sr }, node),
            .index => |i| try em.pushInstr(.navigate_index, .{ .index = i }, node),
        }
    }
}

/// Emit the fast-path update ladder: `update_key`/`update_index` per
/// step in REVERSE order (innermost first), matching legacy's
/// `emitUpdateChain`.
fn emitUpdateChain(em: *Emitter, node: ir.Node, steps: []const FastPathStep) error{OutOfMemory}!void {
    var i = steps.len;
    while (i > 0) {
        i -= 1;
        switch (steps[i]) {
            .key => |sr| try em.pushInstr(.update_key, .{ .str_ref = sr }, node),
            .index => |idx| try em.pushInstr(.update_index, .{ .index = idx }, node),
        }
    }
}

/// Top-level `update_assign` dispatcher. Routes between fast path
/// (kind != .general) and general path (kind == .general).
fn emitUpdateAssign(em: *Emitter, node: ir.Node, kind: ir.UpdateOpKind) EmitError!void {
    if (kind == .general) {
        // For general form, the operator alphabet is in slot+1.
        const slots = em.ir_obj.extra_data.items;
        const inner: ir.UpdateOpKind = @enumFromInt(slots[node.extra + 1]);
        try emitGeneralUpdate(em, node, inner);
        return;
    }
    try emitFastPathUpdate(em, node, kind);
}

/// Fast-path update emission. Mirrors legacy `parseUpdateAssign`
/// (`src/query/src/compiler.zig:1610-1782`).
fn emitFastPathUpdate(em: *Emitter, node: ir.Node, kind: ir.UpdateOpKind) EmitError!void {
    var steps: std.ArrayListUnmanaged(FastPathStep) = .{};
    defer steps.deinit(em.allocator);
    try decodeFastPath(em, node.extra, &steps);

    const rhs_idx = node.children[1];

    switch (kind) {
        // `|= rhs` — navigate first, then evaluate RHS against
        // navigated value, then update.
        .update => {
            try emitNavigation(em, node, steps.items);
            try emitNode(em, rhs_idx);
            try emitUpdateChain(em, node, steps.items);
        },
        // `= rhs` — evaluate RHS against original input first, THEN
        // navigate, THEN update.
        .set => {
            try emitNode(em, rhs_idx);
            try emitNavigation(em, node, steps.items);
            try emitUpdateChain(em, node, steps.items);
        },
        // Compound `+=` `-=` `*=` `/=` `%=` — captured-orig pattern.
        .add, .sub, .mul, .div, .mod => {
            const tmp_var = em.allocVar();
            try em.pushInstr(.push_current, .{ .none = {} }, node);
            try em.pushInstr(.capture_variable, .{ .index = tmp_var }, node);

            // Navigate to target
            try emitNavigation(em, node, steps.items);

            // Push navigated value (left operand)
            try em.pushInstr(.push_current, .{ .none = {} }, node);

            // Restore original input as current for RHS evaluation
            try em.pushInstr(.load_variable, .{ .index = tmp_var }, node);
            try em.pushInstr(.pipe, .{ .none = {} }, node);

            // Evaluate RHS against original input
            try emitNode(em, rhs_idx);

            // Apply arithmetic
            const arith_op: types_mod.Instruction.Op = switch (kind) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                .mod => .mod,
                else => unreachable,
            };
            try em.pushInstr(arith_op, .{ .none = {} }, node);

            // Update chain
            try emitUpdateChain(em, node, steps.items);
        },
        // `//=` — alternative-assignment.
        .alt => {
            const tmp_var = em.allocVar();
            try em.pushInstr(.push_current, .{ .none = {} }, node);
            try em.pushInstr(.capture_variable, .{ .index = tmp_var }, node);

            // Navigate
            try emitNavigation(em, node, steps.items);

            // Alt fork: . // rhs
            const fork_alt_pos = em.instructions.items.len;
            try em.pushInstr(.fork_alt, .{ .index = 0 }, node);
            try em.pushInstr(.push_current, .{ .none = {} }, node);
            const jif_pos = em.instructions.items.len;
            try em.pushInstr(.jump_if_false, .{ .index = 0 }, node);
            // Truthy: keep value, jump to end
            try em.pushInstr(.pop_try, .{ .none = {} }, node);
            try em.pushInstr(.push_current, .{ .none = {} }, node);
            const jump_end_pos = em.instructions.items.len;
            try em.pushInstr(.jump, .{ .index = 0 }, node);
            // Falsy: backtrack to alt-handler (right side)
            em.instructions.items[jif_pos].operand = .{ .index = @intCast(em.instructions.items.len) };
            try em.pushInstr(.backtrack, .{ .none = {} }, node);
            // Right side: restore original input + evaluate RHS
            const right_ip: u32 = @intCast(em.instructions.items.len);
            em.instructions.items[fork_alt_pos].operand = .{ .index = right_ip };
            try em.pushInstr(.load_variable, .{ .index = tmp_var }, node);
            try em.pushInstr(.pipe, .{ .none = {} }, node);
            try emitNode(em, rhs_idx);
            em.instructions.items[jump_end_pos].operand = .{ .index = @intCast(em.instructions.items.len) };

            // Update chain
            try emitUpdateChain(em, node, steps.items);
        },
        .general => unreachable, // dispatcher routes general elsewhere
    }
}

/// Capture a slice of recently-emitted instructions and truncate the
/// stream back to `start`. Mirrors legacy `captureAndTruncate` —
/// returns an owned buffer the caller must free. Used to copy the
/// LHS bytecode (which gets re-emitted inside `path_begin`/`path_end`)
/// or the RHS bytecode (re-emitted under `$orig` redirect).
const CapturedInstrs = struct {
    instrs: []types_mod.Instruction,
    src_offsets: []u32,
    original_start: u32,

    fn deinit(self: *CapturedInstrs, alloc: std.mem.Allocator) void {
        alloc.free(self.instrs);
        alloc.free(self.src_offsets);
    }
};

fn captureAndTruncate(em: *Emitter, start: usize) error{OutOfMemory}!CapturedInstrs {
    const slice = em.instructions.items[start..];
    const off_slice = em.source_map.items[start..];
    const buf = try em.allocator.alloc(types_mod.Instruction, slice.len);
    errdefer em.allocator.free(buf);
    const off_buf = try em.allocator.alloc(u32, off_slice.len);
    errdefer em.allocator.free(off_buf);
    @memcpy(buf, slice);
    @memcpy(off_buf, off_slice);
    em.instructions.items.len = start;
    em.source_map.items.len = start;
    return .{ .instrs = buf, .src_offsets = off_buf, .original_start = @intCast(start) };
}

/// Append a captured instruction buffer at the current emit position,
/// rebasing internal jump targets. Mirrors legacy `appendRebasedInstrsCopy`
/// at `src/query/src/compiler.zig:2314`.
fn appendRebasedInstrs(em: *Emitter, captured: CapturedInstrs) error{OutOfMemory}!void {
    const new_start: i64 = @intCast(em.instructions.items.len);
    const offset: i64 = new_start - @as(i64, @intCast(captured.original_start));
    const copy = try em.allocator.alloc(types_mod.Instruction, captured.instrs.len);
    defer em.allocator.free(copy);
    @memcpy(copy, captured.instrs);
    rebaseInstrs(copy, offset);
    try em.instructions.appendSlice(em.allocator, copy);
    try em.source_map.appendSlice(em.allocator, captured.src_offsets);
}

/// Shift internal jump targets in a copied instruction buffer by
/// `offset` so the buffer can be replayed at a different IP.
/// Targets internal to the buffer (relative jumps) are untouched —
/// jq bytecode uses absolute IPs only, so we recompute every relevant
/// `.index` operand. Conservative: every op carrying an `.index`
/// operand that the VM treats as an instruction pointer is shifted.
fn rebaseInstrs(buf: []types_mod.Instruction, offset: i64) void {
    for (buf) |*instr| {
        switch (instr.op) {
            .jump,
            .jump_if_false,
            .fork,
            .fork_try,
            .fork_alt,
            .array_collect_start,
            .limit_start,
            .label_begin,
            => {
                if (offset != 0) {
                    const cur: i64 = @intCast(instr.operand.index);
                    instr.operand = .{ .index = @intCast(cur + offset) };
                }
            },
            else => {},
        }
    }
}

/// Emit the `[path(LHS)]` collection — captures every path the LHS
/// expression yields against the current input. The IR's LHS subtree
/// has already been lowered as a regular expression; we re-emit it
/// here under `path_begin`/`path_end` brackets.
fn emitPathCollection(em: *Emitter, node: ir.Node, lhs_idx: u32) EmitError!void {
    const ace_start = em.instructions.items.len;
    try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);

    const path_begin_ip = em.instructions.items.len;
    try em.pushInstr(.path_begin, .{ .index = 0 }, node);

    try emitNode(em, lhs_idx);

    try em.pushInstr(.path_end, .{ .none = {} }, node);
    em.instructions.items[path_begin_ip].operand = .{ .index = @intCast(em.instructions.items.len - 1) };

    try em.pushInstr(.yield_output, .{ .none = {} }, node);

    const ace_end: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(.array_collect_end, .{ .none = {} }, node);
    em.instructions.items[ace_start].operand = .{ .index = ace_end };
}

/// Emit `[]` (empty array literal).
fn emitEmptyArray(em: *Emitter, node: ir.Node) error{OutOfMemory}!void {
    const start = em.instructions.items.len;
    try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);
    const end: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(.array_collect_end, .{ .none = {} }, node);
    em.instructions.items[start].operand = .{ .index = end };
}

/// General-LHS update emission. Routes `LHS OP= rhs` for arbitrary
/// LHS expressions via the `_modify`/`_assign` desugar pattern. The
/// IR has children: `[lhs_idx, rhs_idx]`; the inner operator alphabet
/// is the second extra slot.
fn emitGeneralUpdate(em: *Emitter, node: ir.Node, inner: ir.UpdateOpKind) EmitError!void {
    const lhs_idx = node.children[0];
    const rhs_idx = node.children[1];

    // Pre-allocate temp vars matching legacy's slot order
    // (`compilePathExprUpdate` at compiler.zig:1827-1838). The slot
    // order ensures bytecode-level identity for the var ids.
    const orig_var = em.allocVar();
    const paths_var = em.allocVar();
    const acc_var = em.allocVar();
    const dels_var = em.allocVar();
    const p_var = em.allocVar();
    _ = em.allocVar(); // r_var (not used in some forms)

    // $orig = current input
    try em.pushInstr(.push_current, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = orig_var }, node);

    // $paths = [path(LHS)]
    try emitPathCollection(em, node, lhs_idx);
    try em.pushInstr(.capture_variable, .{ .index = paths_var }, node);

    // Capture RHS bytecode for re-emission inside the loop body.
    const rhs_capture_start = em.instructions.items.len;
    try emitNode(em, rhs_idx);
    var rhs = try captureAndTruncate(em, rhs_capture_start);
    defer rhs.deinit(em.allocator);

    switch (inner) {
        // `LHS |= f` — _modify desugar.
        .update => {
            try emitGeneralPipeEq(em, node, orig_var, paths_var, acc_var, dels_var, p_var, rhs);
        },
        // `LHS = v` — set every path to v(orig).
        .set => {
            try emitGeneralEq(em, node, orig_var, paths_var, acc_var, p_var, rhs);
        },
        // `LHS op= v` for arith ops.
        .add, .sub, .mul, .div, .mod => {
            const arith_op: types_mod.Instruction.Op = switch (inner) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                .mod => .mod,
                else => unreachable,
            };
            try emitGeneralCompound(em, node, orig_var, paths_var, acc_var, p_var, arith_op, rhs);
        },
        // `LHS //= f` — alternative-assignment.
        .alt => {
            try emitGeneralAlt(em, node, orig_var, paths_var, acc_var, p_var, rhs);
        },
        .general => unreachable, // nested general unreachable — discriminant excludes
    }
}

/// `LHS |= f` general-form ladder. Mirrors legacy
/// `emitGeneralPipeEqUpdate` (`src/query/src/compiler.zig:1981`).
fn emitGeneralPipeEq(
    em: *Emitter,
    node: ir.Node,
    orig_var: u32,
    paths_var: u32,
    acc_var: u32,
    dels_var: u32,
    p_var: u32,
    rhs: CapturedInstrs,
) EmitError!void {
    const r_var = em.allocVar();

    // $acc = $orig
    try em.pushInstr(.load_variable, .{ .index = orig_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = acc_var }, node);

    // $dels = []
    try emitEmptyArray(em, node);
    try em.pushInstr(.capture_variable, .{ .index = dels_var }, node);

    // For each $p in $paths:
    try em.pushInstr(.load_variable, .{ .index = paths_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    const inner_ace_start = em.instructions.items.len;
    try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);
    try em.pushInstr(.each, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = p_var }, node);

    // $r = [ ($acc | getpath($p)) | f ]
    try em.pushInstr(.load_variable, .{ .index = acc_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = p_var }, node);
    try em.pushInstr(.call_builtin, .{ .index = @intFromEnum(types_mod.BuiltinId.getpath) }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    const r_ace_start = em.instructions.items.len;
    try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);
    try appendRebasedInstrs(em, rhs);
    try em.pushInstr(.yield_output, .{ .none = {} }, node);
    const r_ace_end: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(.array_collect_end, .{ .none = {} }, node);
    em.instructions.items[r_ace_start].operand = .{ .index = r_ace_end };
    try em.pushInstr(.capture_variable, .{ .index = r_var }, node);

    // if length($r) == 0 then $dels += [$p] else $acc = setpath($acc; $p; $r[0])
    try em.pushInstr(.load_variable, .{ .index = r_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.call_builtin, .{ .index = @intFromEnum(types_mod.BuiltinId.length) }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.push_int, .{ .int = 0 }, node);
    try em.pushInstr(.eq, .{ .none = {} }, node);

    const jif_pos = em.instructions.items.len;
    try em.pushInstr(.jump_if_false, .{ .index = 0 }, node);

    // THEN: $dels = $dels + [$p]
    try em.pushInstr(.load_variable, .{ .index = dels_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.push_current, .{ .none = {} }, node);
    const p_arr_start = em.instructions.items.len;
    try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);
    try em.pushInstr(.load_variable, .{ .index = p_var }, node);
    try em.pushInstr(.yield_output, .{ .none = {} }, node);
    const p_arr_end: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(.array_collect_end, .{ .none = {} }, node);
    em.instructions.items[p_arr_start].operand = .{ .index = p_arr_end };
    try em.pushInstr(.add, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = dels_var }, node);
    const jump_end_pos = em.instructions.items.len;
    try em.pushInstr(.jump, .{ .index = 0 }, node);

    // ELSE: $acc = setpath($acc; $p; $r[0])
    em.instructions.items[jif_pos].operand = .{ .index = @intCast(em.instructions.items.len) };
    try em.pushInstr(.load_variable, .{ .index = acc_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.save_input, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = p_var }, node);
    try em.pushInstr(.restore_input, .{ .none = {} }, node);
    try em.pushInstr(.save_input, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = r_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.load_index, .{ .index = 0 }, node);
    try em.pushInstr(.restore_input, .{ .none = {} }, node);
    try em.pushInstr(.call_builtin, .{ .index = @intFromEnum(types_mod.BuiltinId.setpath) }, node);
    try em.pushInstr(.capture_variable, .{ .index = acc_var }, node);

    em.instructions.items[jump_end_pos].operand = .{ .index = @intCast(em.instructions.items.len) };

    try em.pushInstr(.backtrack, .{ .none = {} }, node);

    const inner_ace_end: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(.array_collect_end, .{ .none = {} }, node);
    em.instructions.items[inner_ace_start].operand = .{ .index = inner_ace_end };

    try em.pushInstr(.pipe, .{ .none = {} }, node);

    // Apply pending deletions: $acc | delpaths($dels)
    try em.pushInstr(.load_variable, .{ .index = acc_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = dels_var }, node);
    try em.pushInstr(.call_builtin, .{ .index = @intFromEnum(types_mod.BuiltinId.delpaths) }, node);
}

/// `LHS = v` general-form ladder. Mirrors legacy
/// `emitGeneralEqUpdate` (`src/query/src/compiler.zig:2095`).
fn emitGeneralEq(
    em: *Emitter,
    node: ir.Node,
    orig_var: u32,
    paths_var: u32,
    acc_var: u32,
    p_var: u32,
    rhs: CapturedInstrs,
) EmitError!void {
    const value_var = em.allocVar();

    // $value = $orig | v
    try em.pushInstr(.load_variable, .{ .index = orig_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try appendRebasedInstrs(em, rhs);
    try em.pushInstr(.capture_variable, .{ .index = value_var }, node);

    // $acc = $orig
    try em.pushInstr(.load_variable, .{ .index = orig_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = acc_var }, node);

    // For each $p in $paths: $acc = setpath($acc; $p; $value)
    try em.pushInstr(.load_variable, .{ .index = paths_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    const inner_ace_start = em.instructions.items.len;
    try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);
    try em.pushInstr(.each, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = p_var }, node);

    try em.pushInstr(.load_variable, .{ .index = acc_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.save_input, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = p_var }, node);
    try em.pushInstr(.restore_input, .{ .none = {} }, node);
    try em.pushInstr(.save_input, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = value_var }, node);
    try em.pushInstr(.restore_input, .{ .none = {} }, node);
    try em.pushInstr(.call_builtin, .{ .index = @intFromEnum(types_mod.BuiltinId.setpath) }, node);
    try em.pushInstr(.capture_variable, .{ .index = acc_var }, node);

    try em.pushInstr(.backtrack, .{ .none = {} }, node);

    const inner_ace_end: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(.array_collect_end, .{ .none = {} }, node);
    em.instructions.items[inner_ace_start].operand = .{ .index = inner_ace_end };

    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = acc_var }, node);
}

/// `LHS op= v` general-form compound ladder. Mirrors legacy
/// `emitGeneralCompoundUpdate` (`src/query/src/compiler.zig:2151`).
fn emitGeneralCompound(
    em: *Emitter,
    node: ir.Node,
    orig_var: u32,
    paths_var: u32,
    acc_var: u32,
    p_var: u32,
    arith_op: types_mod.Instruction.Op,
    rhs: CapturedInstrs,
) EmitError!void {
    const tmp_var = em.allocVar();

    // $tmp = $orig | v
    try em.pushInstr(.load_variable, .{ .index = orig_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try appendRebasedInstrs(em, rhs);
    try em.pushInstr(.capture_variable, .{ .index = tmp_var }, node);

    // $acc = $orig
    try em.pushInstr(.load_variable, .{ .index = orig_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = acc_var }, node);

    // For each $p
    try em.pushInstr(.load_variable, .{ .index = paths_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    const inner_ace_start = em.instructions.items.len;
    try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);
    try em.pushInstr(.each, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = p_var }, node);

    try em.pushInstr(.load_variable, .{ .index = acc_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    // Stage path
    try em.pushInstr(.save_input, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = p_var }, node);
    try em.pushInstr(.restore_input, .{ .none = {} }, node);
    // Stage value: getpath($acc; $p) op $tmp
    try em.pushInstr(.save_input, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = p_var }, node);
    try em.pushInstr(.call_builtin, .{ .index = @intFromEnum(types_mod.BuiltinId.getpath) }, node);
    try em.pushInstr(.load_variable, .{ .index = tmp_var }, node);
    try em.pushInstr(arith_op, .{ .none = {} }, node);
    try em.pushInstr(.restore_input, .{ .none = {} }, node);
    try em.pushInstr(.call_builtin, .{ .index = @intFromEnum(types_mod.BuiltinId.setpath) }, node);
    try em.pushInstr(.capture_variable, .{ .index = acc_var }, node);

    try em.pushInstr(.backtrack, .{ .none = {} }, node);

    const inner_ace_end: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(.array_collect_end, .{ .none = {} }, node);
    em.instructions.items[inner_ace_start].operand = .{ .index = inner_ace_end };

    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = acc_var }, node);
}

/// `LHS //= v` general-form alternative-assignment ladder. Mirrors
/// legacy `emitGeneralAlternativeUpdate`
/// (`src/query/src/compiler.zig:2211`).
fn emitGeneralAlt(
    em: *Emitter,
    node: ir.Node,
    orig_var: u32,
    paths_var: u32,
    acc_var: u32,
    p_var: u32,
    rhs: CapturedInstrs,
) EmitError!void {
    const tmp_var = em.allocVar();

    // $tmp = $orig | f
    try em.pushInstr(.load_variable, .{ .index = orig_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try appendRebasedInstrs(em, rhs);
    try em.pushInstr(.capture_variable, .{ .index = tmp_var }, node);

    // $acc = $orig
    try em.pushInstr(.load_variable, .{ .index = orig_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = acc_var }, node);

    // For each $p
    try em.pushInstr(.load_variable, .{ .index = paths_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    const inner_ace_start = em.instructions.items.len;
    try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);
    try em.pushInstr(.each, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = p_var }, node);

    // current = getpath($acc; $p)
    try em.pushInstr(.load_variable, .{ .index = acc_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = p_var }, node);
    try em.pushInstr(.call_builtin, .{ .index = @intFromEnum(types_mod.BuiltinId.getpath) }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    try em.pushInstr(.push_current, .{ .none = {} }, node);
    const jif_pos = em.instructions.items.len;
    try em.pushInstr(.jump_if_false, .{ .index = 0 }, node);
    // THEN: keep — no change to $acc, just backtrack
    const jump_end_pos = em.instructions.items.len;
    try em.pushInstr(.jump, .{ .index = 0 }, node);

    // ELSE: $acc = setpath($acc; $p; $tmp)
    em.instructions.items[jif_pos].operand = .{ .index = @intCast(em.instructions.items.len) };
    try em.pushInstr(.load_variable, .{ .index = acc_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.save_input, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = p_var }, node);
    try em.pushInstr(.restore_input, .{ .none = {} }, node);
    try em.pushInstr(.save_input, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = tmp_var }, node);
    try em.pushInstr(.restore_input, .{ .none = {} }, node);
    try em.pushInstr(.call_builtin, .{ .index = @intFromEnum(types_mod.BuiltinId.setpath) }, node);
    try em.pushInstr(.capture_variable, .{ .index = acc_var }, node);

    em.instructions.items[jump_end_pos].operand = .{ .index = @intCast(em.instructions.items.len) };

    try em.pushInstr(.backtrack, .{ .none = {} }, node);

    const inner_ace_end: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(.array_collect_end, .{ .none = {} }, node);
    em.instructions.items[inner_ace_start].operand = .{ .index = inner_ace_end };

    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = acc_var }, node);
}
