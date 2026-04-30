//! IR → bytecode emission — Phase 2R / R3.
//!
//! The emitter walks the IR tree recursively from the root. Op
//! handlers decide the relative order of child visits and own
//! instruction emission. Post-cutover every IR op produced by
//! lowering has a dedicated arm; reaching the exhaustiveness sink
//! is a compiler bug and is `unreachable`.
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
const lower_mod = @import("lower.zig");

/// Errors surfaced by emission. `OutOfMemory` from arena/instruction
/// allocs is the only recoverable failure. Post-cutover every IR op
/// has an emit arm, so unknown ops are `unreachable` rather than
/// recoverable errors.
pub const EmitError = error{
    OutOfMemory,
};

/// Per-function body-IP cache entry. Recursive user-functions emit
/// their body inline ONCE on the first `call_user` encounter; the
/// resulting body_ip is recorded here so subsequent `call_user`s
/// reuse the same IP (`call_function(body_ip)`). Mirrors legacy
/// `FunctionEntry.recursive_body_ip` at `compiler.zig:209`.
const FunctionBodyCache = struct {
    body_ip: u32 = 0,
    /// Set once the body has been emitted. Subsequent call sites
    /// short-circuit to `call_function(body_ip)` without re-emitting.
    emitted: bool = false,
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
    /// Per-function-id snapshot from the Lowerer. Indexed by `call_user`
    /// IR's `extra_data[extra + 0]`. Empty for compiles that don't
    /// register any user-functions (cat-9 inactive).
    function_table: []const lower_mod.FunctionEntry,
    /// Body-IP cache parallel to `function_table` — index-by-fn_id
    /// records whether the body has been emitted and its IP.
    fn_body_ip: []FunctionBodyCache,

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
    function_table: []const lower_mod.FunctionEntry,
    next_var_id_seed: u32,
    regex_pool: regex_mod.RegexPool,
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

    // Per-fn body-IP cache — initialized fresh, mutated as `call_user`
    // emit handlers fire. Lifetime tied to the emit call; freed before
    // returning. Empty for cat-9-inactive compiles.
    const fn_body_ip: []FunctionBodyCache = if (function_table.len == 0)
        &.{}
    else
        try allocator.alloc(FunctionBodyCache, function_table.len);
    defer if (function_table.len > 0) allocator.free(fn_body_ip);
    for (fn_body_ip) |*entry| entry.* = .{};

    // The IR root is the last-pushed node (lowering is post-order).
    // An empty IR is a programming error — lowering always produces
    // at least one node for a non-empty AST.
    if (ir_obj.nodes.items.len > 0) {
        const root_idx: u32 = @intCast(ir_obj.nodes.items.len - 1);
        // The next_var_id seed comes from the Lowerer (cat-9 allocates
        // canonical var_ids for value-arg captures BEFORE emit runs;
        // emit reserves any further var_ids above that watermark to
        // avoid collisions). Falls back to `external_var_count` when
        // cat-9 is inactive (no UDFs ⇒ Lowerer's seed equals the
        // external-var watermark).
        var emitter = Emitter{
            .instructions = &instructions,
            .source_map = &source_map,
            .ir_obj = ir_obj,
            .allocator = allocator,
            .next_var_id = if (next_var_id_seed > external_var_count)
                next_var_id_seed
            else
                @intCast(external_var_count),
            .function_table = function_table,
            .fn_body_ip = fn_body_ip,
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
        .regex_pool = regex_pool,
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
                .big_number => {
                    const slots = em.ir_obj.extra_data.items;
                    const offset: u32 = slots[node.extra + 1];
                    const len: u32 = slots[node.extra + 2];
                    try em.pushInstr(
                        .push_big_number,
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

        // Category-10 builtin call. The IR carries the builtin name
        // (interned in `string_buf` via `extra_data[node.extra..+2]`)
        // plus 0..N argument children in `(span_start, span_len)`. The
        // emitter looks up the `BuiltinId` from the name + classifies
        // the call shape using the same (name, arity) classifier the
        // lowerer used — single source of truth, plan §1.3 row 5.
        //
        // Five emission shapes (matching legacy):
        //   * 0-arg          → `call_builtin(bid)`
        //   * value_arg1     → `<arg> ; call_builtin(bid)` (no save/restore)
        //   * filter_arg1    → `save_input ; array_collect_start ; each ;
        //                       <f> ; yield_output ; array_collect_end ;
        //                       call_builtin(bid)` (mirrors
        //                       `compileFilterArgBuiltin`)
        //   * math2          → save+arg+restore (twice) ; call_builtin(bid)
        //                       (mirrors `compileTwoArgMath` /
        //                       `compileSetpath`)
        //   * math3          → save+arg+restore (three times) ;
        //                       call_builtin(bid) (mirrors
        //                       `compileThreeArgMath`)
        .call_builtin => try emitCallBuiltin(em, node),

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

        // ── EmitOp (fuse output) — Phase 2R / R3 step 8 ─────────────
        // load_path collapses a `.a | .b | .c` pipe-chain to a single
        // bytecode instruction. The IR payload is `(offset, len)` of a
        // dot-joined key sequence interned in `string_buf` — same
        // encoding as `load_field`, so the emit shape is identical
        // modulo the destination opcode (`.load_path` vs `.load_key`).
        // Mirrors the legacy fuse output at
        // `src/query/src/compiler.zig:7228`.
        .load_path => {
            const slots = em.ir_obj.extra_data.items;
            const offset: u32 = slots[node.extra];
            const len: u32 = slots[node.extra + 1];
            try em.pushInstr(
                .load_path,
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

        // Cat-18 (P27): computed bracket access. Two-var capture
        // pattern around the lowered key expression mirrors legacy
        // `compileComputedBracket` (`src/query/src/compiler.zig:7040`)
        // byte-for-byte: $base captures the input before key eval so
        // it survives generator-form key fork/backtrack iteration; the
        // per-iteration block re-saves the base and runs `load_computed`
        // for every yielded key.
        .computed_index => try emitComputedIndex(em, node),

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

        .computed_slice => try emitSliceComputed(em, node),

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
        // Two emission paths depending on whether either operand
        // contains a generator (.iterate node):
        //
        // NON-GENERATOR path (no .iterate in either child):
        //   <lhs> ; <rhs> ; op
        //   Matches the legacy `parseAdditive`/`parseMultiplicative`
        //   shape and is safe for recursive functions: the value_stack
        //   is saved by call_function frames so LHS values pushed onto
        //   the stack survive re-entrant calls.
        //
        // GENERATOR path (either child contains .iterate):
        //   lhs-temp idiom — emit RHS (outer generator loop) first,
        //   capture its result into $rhs_var via variable (survives
        //   fork backtracking because variable_store is NOT restored
        //   by fork frames), restore the original input via $input_var,
        //   emit LHS (inner generator loop), load $rhs_var onto the
        //   value_stack, then op.  Layout:
        //     op:  right = $rhs_var (popped), left = current (LHS)
        //       → result = left op right = lhs op rhs  ✓
        //   Variables are safe here because .iterate-based generators
        //   never appear inside recursive function bodies in practice
        //   (the recursive call is in the RHS via call_function, not
        //   via backtracking).  Using the value_stack for this case
        //   would fail because generators set it.current rather than
        //   pushing to the stack, leaving the stack empty at op time
        //   (→ TypeError).
        //
        //   This mirrors the idiom at :1280/:1303/:1677/:1737.
        .arith => {
            const slots = em.ir_obj.extra_data.items;
            const kind: ir.ArithKind = @enumFromInt(slots[node.extra]);
            const op: types_mod.Instruction.Op = switch (kind) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                .mod => .mod,
            };
            if (subtreeHasIterate(em.ir_obj, node.children[0]) or
                subtreeHasIterate(em.ir_obj, node.children[1]))
            {
                // Generator path.
                const input_var = em.allocVar();
                const rhs_var = em.allocVar();
                try em.pushInstr(.push_current, .{ .none = {} }, node);
                try em.pushInstr(.capture_variable, .{ .index = input_var }, node);
                try emitNode(em, node.children[1]);
                try em.pushInstr(.pipe, .{ .none = {} }, node);
                try em.pushInstr(.push_current, .{ .none = {} }, node);
                try em.pushInstr(.capture_variable, .{ .index = rhs_var }, node);
                try em.pushInstr(.load_variable, .{ .index = input_var }, node);
                try em.pushInstr(.pipe, .{ .none = {} }, node);
                try emitNode(em, node.children[0]);
                try em.pushInstr(.load_variable, .{ .index = rhs_var }, node);
            } else {
                // Non-generator path: preserve value_stack ordering
                // for recursive functions.
                try emitNode(em, node.children[0]);
                try emitNode(em, node.children[1]);
            }
            try em.pushInstr(op, .{ .none = {} }, node);
        },

        .cmp => {
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
            if (subtreeHasIterate(em.ir_obj, node.children[0]) or
                subtreeHasIterate(em.ir_obj, node.children[1]))
            {
                const input_var = em.allocVar();
                const rhs_var = em.allocVar();
                try em.pushInstr(.push_current, .{ .none = {} }, node);
                try em.pushInstr(.capture_variable, .{ .index = input_var }, node);
                try emitNode(em, node.children[1]);
                try em.pushInstr(.pipe, .{ .none = {} }, node);
                try em.pushInstr(.push_current, .{ .none = {} }, node);
                try em.pushInstr(.capture_variable, .{ .index = rhs_var }, node);
                try em.pushInstr(.load_variable, .{ .index = input_var }, node);
                try em.pushInstr(.pipe, .{ .none = {} }, node);
                try emitNode(em, node.children[0]);
                try em.pushInstr(.load_variable, .{ .index = rhs_var }, node);
            } else {
                try emitNode(em, node.children[0]);
                try emitNode(em, node.children[1]);
            }
            try em.pushInstr(op, .{ .none = {} }, node);
        },

        // Logical: same two-path idiom.  Legacy's VM
        // (`src/query/src/vm.zig:6575-6589`) evaluates both operands
        // eagerly and reduces to a boolean — jq does not short-circuit
        // at the bytecode layer.
        .logical => {
            const slots = em.ir_obj.extra_data.items;
            const kind: ir.LogicalKind = @enumFromInt(slots[node.extra]);
            const op: types_mod.Instruction.Op = switch (kind) {
                .and_ => .and_op,
                .or_ => .or_op,
            };
            if (subtreeHasIterate(em.ir_obj, node.children[0]) or
                subtreeHasIterate(em.ir_obj, node.children[1]))
            {
                const input_var = em.allocVar();
                const rhs_var = em.allocVar();
                try em.pushInstr(.push_current, .{ .none = {} }, node);
                try em.pushInstr(.capture_variable, .{ .index = input_var }, node);
                try emitNode(em, node.children[1]);
                try em.pushInstr(.pipe, .{ .none = {} }, node);
                try em.pushInstr(.push_current, .{ .none = {} }, node);
                try em.pushInstr(.capture_variable, .{ .index = rhs_var }, node);
                try em.pushInstr(.load_variable, .{ .index = input_var }, node);
                try em.pushInstr(.pipe, .{ .none = {} }, node);
                try emitNode(em, node.children[0]);
                try em.pushInstr(.load_variable, .{ .index = rhs_var }, node);
            } else {
                try emitNode(em, node.children[0]);
                try emitNode(em, node.children[1]);
            }
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
        //
        // Computed keys require special handling: `object_key` expects
        // the key on the value_stack (it calls `popValue` for the key),
        // and the value either on the stack (second entry) or as
        // `it.current`.  For static `load_const` keys the `push_string`
        // opcode already lands the key on the stack.  For computed keys
        // we need to:
        //   1. Capture the current input in a variable (survives
        //      generator backtracking, unlike the if_stack).
        //   2. Emit the key expression — result lands as `it.current`
        //      (generators) or on the value_stack (literals).
        //   3. Pipe (normalise stack → current for literal sub-exprs).
        //   4. push_current  — key value now on value_stack.
        //   5. load_variable + pipe — reset `it.current` to the saved
        //      input so the value expression evaluates against the
        //      same `.` the key did.
        // This mirrors the lhs-temp idiom at :1280/:1677.
        .obj_ctor => {
            try em.pushInstr(.object_construct_start, .{ .none = {} }, node);
            const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            // Pairs are (k, v); span_len is always even (lowering invariant).
            std.debug.assert(span.len % 2 == 0);
            var pi: usize = 0;
            while (pi < span.len) : (pi += 2) {
                const key_node = em.ir_obj.nodes.items[span[pi]];
                if (key_node.op == .load_const) {
                    // Static key: emits push_string → value_stack; no
                    // save/restore needed.
                    try emitNode(em, span[pi]);
                } else {
                    // Computed key: capture input, emit key, push to
                    // value_stack, restore input for value expression.
                    const input_var = em.allocVar();
                    try em.pushInstr(.push_current, .{ .none = {} }, node);
                    try em.pushInstr(.capture_variable, .{ .index = input_var }, node);
                    try emitNode(em, span[pi]);
                    // Normalise: if key expr was a literal it left its
                    // result on the stack — pipe moves it to current.
                    try em.pushInstr(.pipe, .{ .none = {} }, node);
                    // Key value → value_stack so object_key can pop it.
                    try em.pushInstr(.push_current, .{ .none = {} }, node);
                    // Restore original input for value expression.
                    try em.pushInstr(.load_variable, .{ .index = input_var }, node);
                    try em.pushInstr(.pipe, .{ .none = {} }, node);
                }
                try emitNode(em, span[pi + 1]);
                try em.pushInstr(.object_key, .{ .none = {} }, node);
            }
            try em.pushInstr(.object_construct_end, .{ .none = {} }, node);
        },

        // Array literal `[...]`. Emits the `array_collect_start ... end`
        // pair around a per-element `fork / <elem> / yield_output`
        // chain. Each element's `fork` `backtrack_ip` points to the
        // next element's `fork` (or to `array_collect_end` for the
        // last element); when an element backtracks (e.g. `empty` or
        // a failing predicate), the VM lands at the next element's
        // forkpoint instead of falling through to the collect-frame
        // floor and prematurely finalizing the array. The start
        // instruction's operand receives the IP of the matching
        // `array_collect_end` after backpatching. Matches legacy
        // `parseArrayConstruct` (`src/query/src/compiler.zig:6410`).
        .arr_ctor => {
            const start_pos = em.instructions.items.len;
            try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);
            const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            var prev_fork_pos: ?usize = null;
            for (span) |elem_idx| {
                const fork_pos: usize = em.instructions.items.len;
                if (prev_fork_pos) |prev| {
                    em.instructions.items[prev].operand = .{ .index = @intCast(fork_pos) };
                }
                try em.pushInstr(.fork, .{ .index = 0 }, node);
                try emitNode(em, elem_idx);
                try em.pushInstr(.yield_output, .{ .none = {} }, node);
                prev_fork_pos = fork_pos;
            }
            const end_pos: u32 = @intCast(em.instructions.items.len);
            if (prev_fork_pos) |prev| {
                em.instructions.items[prev].operand = .{ .index = end_pos };
            }
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
            // The IR carries the bare format name as written in the
            // source (e.g. `"base64"`); the AST parser `internName`
            // path strips the `@`. Older `internFormatName` paths
            // retained the prefix, so we strip defensively. Lowering
            // (`lower.zig` `.format_string` arm) has already rejected
            // unknown format names with a `query_syntax_error`
            // diagnostic — `formatBuiltinId` is therefore total here.
            const bare = if (fmt_name.len > 0 and fmt_name[0] == '@') fmt_name[1..] else fmt_name;
            const bid = formatBuiltinId(bare) orelse unreachable;

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
        //   push_current
        //   capture_variable($input)
        //   <cond>
        //   jump_if_false L_else
        //   load_variable($input) ; pipe
        //   <then>
        //   jump L_end
        //   L_else:
        //   load_variable($input) ; pipe
        //   <else>
        //   L_end:
        //
        // Variable-based input capture instead of save_input/restore_input.
        // save_input/restore_input use the if_stack which is reset to its
        // snapshot depth on fork-backtrack (root.zig:898,943). When the
        // condition is a generator (e.g. `1,null,2`) the first fork pushes
        // a forkpoint BEFORE save_input fires; on backtrack the if_stack
        // length is restored to the pre-fork snapshot, dropping the
        // save_input entry. The else-arm's restore_input then fires against
        // an empty if_stack → VM panic (root.zig:1292).
        // Variable store is NOT reset on backtrack, so $input survives every
        // fork leg. Each arm uses emitInputScopeReseed to reload $input.
        .if_ => {
            std.debug.assert(node.span_len == 3);
            const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            const cond_idx = span[0];
            const then_idx = span[1];
            const else_idx = span[2];

            const input_var = em.allocVar();
            try emitInputScopeBracket(em, node, input_var);
            try emitNode(em, cond_idx);

            // jump_if_false → start of the else branch (backpatched once
            // the then-arm and its trailing `jump` are emitted).
            const jif_pos: usize = em.instructions.items.len;
            try em.pushInstr(.jump_if_false, .{ .index = 0 }, node);

            // Then-arm: reseed the saved input, emit the body, then
            // unconditionally jump past the else-arm.
            try emitInputScopeReseed(em, node, input_var);
            try emitNode(em, then_idx);
            const jmp_pos: usize = em.instructions.items.len;
            try em.pushInstr(.jump, .{ .index = 0 }, node);

            // Else-arm entry — backpatch jif and emit.
            em.instructions.items[jif_pos].operand = .{ .index = @intCast(em.instructions.items.len) };
            try emitInputScopeReseed(em, node, input_var);
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

        // ── Category 4 ──────────────────────────────────────────────
        // Variable load `$name`. The IR carries the var-id resolved by
        // lowering — emit just stamps `load_variable(var_id)`. Mirrors
        // legacy `parseVariableReference`
        // (`src/query/src/compiler.zig:6442-6458`).
        .load_var => {
            const slots = em.ir_obj.extra_data.items;
            // extra_data layout: [name_offset, name_len, var_id]
            const var_id: i64 = @intCast(slots[node.extra + 2]);
            try em.pushInstr(.load_variable, .{ .index = var_id }, node);
        },

        // Destructure pattern. The kind discriminant in extra_data slot 0
        // selects between simple-as / array / object / alt_bind ladders;
        // each ladder mirrors the legacy `emitPatternCapture` /
        // `emitPatternCaptureStrict` / `parseDestructAlt` shapes
        // (`src/query/src/compiler.zig:594-754`, 2549-2654).
        .destructure => {
            const slots = em.ir_obj.extra_data.items;
            const kind: ir.PatternKind = @enumFromInt(slots[node.extra]);
            switch (kind) {
                .as => try emitPatternAs(em, node),
                .array => try emitPatternArray(em, node),
                .object => try emitPatternObject(em, node),
                .alt_bind => try emitPatternAltBind(em, node),
            }
        },

        // ── Category 9 — recursive user-function call ────────────────
        // The IR `call_user` op only appears for recursive self-calls;
        // non-recursive calls were inlined into a body-substituted
        // pipe ladder at lowering time. This handler emits the legacy
        // `<arg> ; capture_variable ; ... ; (jump-end ; body ;
        // return_function ; end:) ; call_function(body_ip) ;
        // pop_variable ; ...` shape from `compileExpand` /
        // `expandFunctionCall` (`compiler.zig:1066-1123`).
        .call_user => try emitCallUser(em, node),

        // ── Cat-15 — control-flow constructs ──────────────────────────
        .label => try emitLabel(em, node),
        .break_ => try emitBreak(em, node),
        .while_ => try emitWhile(em, node),
        .until_ => try emitUntil(em, node),

        // ── Cat-4 — `expr as PATTERN | body` (as_bind wrapper) ────────
        .as_bind => try emitAsBind(em, node),

        // ── Cat-14 — reduce / foreach iterating folds ─────────────────
        .reduce => try emitReduce(em, node),
        .foreach => try emitForeach(em, node),

        // Post-cutover invariant: every `ir.Op` lowering emits has an
        // explicit arm above. The remaining tags (`path_end`) are
        // emitted only as inline children inside their parent ops
        // (`path_begin`), never as standalone roots in `emitNode`.
        // Reaching this branch is a compiler bug.
        else => unreachable,
    }
}

// ── Cat-4 destructure ladders ─────────────────────────────────────
//
// Each emitter consumes a freshly-piped value on the value stack /
// current and writes the bytecode shape legacy emits for the same
// pattern shape. The IR's `destructure` op is the SemOp wrapper; its
// kind picks the ladder. Sub-patterns recurse via `emitNode` so a
// nested array-in-object pattern composes naturally.

/// `simple` (as) pattern: a single variable bind. Pops a value off the
/// value stack into `$var` (or uses current when the stack is empty —
/// see vm.zig `capture_variable` line 1537). Mirrors legacy
/// `emitPatternCapture(.simple)` at
/// `src/query/src/compiler.zig:603-605`.
fn emitPatternAs(em: *Emitter, node: ir.Node) EmitError!void {
    const slots = em.ir_obj.extra_data.items;
    // [kind, name_offset, name_len, var_id]
    const var_id: i64 = @intCast(slots[node.extra + 3]);
    try em.pushInstr(.capture_variable, .{ .index = var_id }, node);
}

/// `array` pattern: lift the destructure target onto current via `pipe`,
/// then for each element emit `save_input ; fork_try ; load_index ;
/// pop_try ; jump-past-catch ; push_null ; <recurse> ; restore_input`.
/// Mirrors legacy `emitPatternCapture(.array)` at
/// `src/query/src/compiler.zig:606-639`.
fn emitPatternArray(em: *Emitter, node: ir.Node) EmitError!void {
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
    for (span, 0..) |sub_idx, i| {
        try em.pushInstr(.save_input, .{ .none = {} }, node);

        const fork_pos: usize = em.instructions.items.len;
        try em.pushInstr(.fork_try, .{ .index = 0 }, node);
        try em.pushInstr(.load_index, .{ .index = @intCast(i) }, node);
        try em.pushInstr(.pop_try, .{ .none = {} }, node);

        const jump_pos: usize = em.instructions.items.len;
        try em.pushInstr(.jump, .{ .index = 0 }, node);

        const catch_ip: u32 = @intCast(em.instructions.items.len);
        em.instructions.items[fork_pos].operand = .{ .index = catch_ip };
        try em.pushInstr(.push_null, .{ .none = {} }, node);

        const continue_ip: u32 = @intCast(em.instructions.items.len);
        em.instructions.items[jump_pos].operand = .{ .index = continue_ip };

        try emitNode(em, sub_idx);
        try em.pushInstr(.restore_input, .{ .none = {} }, node);
    }
}

/// `object` pattern: lift the target onto current via `pipe`, then for
/// each (key, sub-pattern) pair emit a fork-try ladder pulling the
/// field out under null-on-missing. Static-key fields use `load_key`;
/// computed-key fields evaluate the key expression then `load_computed`.
/// Mirrors legacy `emitPatternCapture(.object)` at
/// `src/query/src/compiler.zig:640-700`.
fn emitPatternObject(em: *Emitter, node: ir.Node) EmitError!void {
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
    // Pairs are (key, sub-pattern); span_len is even.
    std.debug.assert(span.len % 2 == 0);

    var pi: usize = 0;
    while (pi < span.len) : (pi += 2) {
        const key_idx = span[pi];
        const sub_idx = span[pi + 1];
        const key_node = em.ir_obj.nodes.items[key_idx];

        try em.pushInstr(.save_input, .{ .none = {} }, node);

        const fork_pos: usize = em.instructions.items.len;
        try em.pushInstr(.fork_try, .{ .index = 0 }, node);

        if (key_node.op == .load_const) {
            // Static key: extract the (offset, len) from the synthesized
            // string literal and emit `load_key` directly. Avoids the
            // computed-key replay overhead for the common case.
            const value = ir.loadConstValue(&em.ir_obj, key_node);
            std.debug.assert(value == .string);
            const key_slots = em.ir_obj.extra_data.items;
            const k_off: u32 = key_slots[key_node.extra + 1];
            const k_len: u32 = key_slots[key_node.extra + 2];
            try em.pushInstr(
                .load_key,
                .{ .str_ref = .{ .offset = k_off, .len = k_len } },
                node,
            );
        } else {
            // Computed key: `save_input ; <expr> ; load_computed ;
            // push_current` so the destructure target is reset to the
            // current map for the sub-pattern. Mirrors legacy
            // `compiler.zig:666-693`.
            try em.pushInstr(.save_input, .{ .none = {} }, node);
            try emitNode(em, key_idx);
            try em.pushInstr(.load_computed, .{ .none = {} }, node);
            try em.pushInstr(.push_current, .{ .none = {} }, node);
        }

        try em.pushInstr(.pop_try, .{ .none = {} }, node);

        const jump_pos: usize = em.instructions.items.len;
        try em.pushInstr(.jump, .{ .index = 0 }, node);

        const catch_ip: u32 = @intCast(em.instructions.items.len);
        em.instructions.items[fork_pos].operand = .{ .index = catch_ip };
        try em.pushInstr(.push_null, .{ .none = {} }, node);

        const continue_ip: u32 = @intCast(em.instructions.items.len);
        em.instructions.items[jump_pos].operand = .{ .index = continue_ip };

        try emitNode(em, sub_idx);
        try em.pushInstr(.restore_input, .{ .none = {} }, node);
    }
}

/// `alt_bind` pattern: the desugar of `expr as P1 ?// P2 … | body`.
/// Variables are pre-null-initialised so non-matching alternatives
/// yield null; each alternative is wrapped in a fork-try with strict
/// capture. On the first successful match control jumps past the empty
/// handler; on total failure `backtrack` produces the empty stream.
/// Mirrors legacy `parseDestructAlt` at
/// `src/query/src/compiler.zig:2573-2654`.
fn emitPatternAltBind(em: *Emitter, node: ir.Node) EmitError!void {
    const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];

    // Phase 1: collect every unique var_id touched by ANY alternative.
    // The strict-capture ladder destroys variables that fail to match,
    // so legacy null-initialises them up-front to keep `body` safe.
    var seen = std.AutoHashMap(u32, void).init(em.allocator);
    defer seen.deinit();
    var ordered_ids: std.ArrayListUnmanaged(u32) = .{};
    defer ordered_ids.deinit(em.allocator);
    for (span) |sub_idx| {
        try collectAltVarIds(em.ir_obj, sub_idx, &seen, &ordered_ids, em.allocator);
    }

    for (ordered_ids.items) |var_id| {
        try em.pushInstr(.push_null, .{ .none = {} }, node);
        try em.pushInstr(.capture_variable, .{ .index = @intCast(var_id) }, node);
    }

    // Phase 2: pipe the destructure target into current, save_input
    // for each retry. Each alternative is wrapped in fork_try / strict
    // capture / pop_try / jump-to-body. The catch arm of fork_try
    // lands at the next alternative's restore_input (or the empty
    // handler after the last).
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.save_input, .{ .none = {} }, node);

    var jump_to_body: std.ArrayListUnmanaged(usize) = .{};
    defer jump_to_body.deinit(em.allocator);

    for (span, 0..) |sub_idx, i| {
        const is_last = (i == span.len - 1);

        if (i > 0) {
            // Catch landing: restore the saved input and re-save for
            // the next attempt (or for the empty handler's cleanup).
            try em.pushInstr(.restore_input, .{ .none = {} }, node);
            try em.pushInstr(.save_input, .{ .none = {} }, node);
        }

        const fork_try_pos: usize = em.instructions.items.len;
        try em.pushInstr(.fork_try, .{ .index = 0 }, node);

        // Push current to value_stack so the strict capture ladder
        // can pipe it. Mirrors legacy line 2625.
        try em.pushInstr(.push_current, .{ .none = {} }, node);
        try emitPatternStrict(em, sub_idx);

        try em.pushInstr(.pop_try, .{ .none = {} }, node);
        try em.pushInstr(.restore_input, .{ .none = {} }, node);

        const jmp_pos: usize = em.instructions.items.len;
        try em.pushInstr(.jump, .{ .index = 0 }, node);
        try jump_to_body.append(em.allocator, jmp_pos);

        const catch_ip: u32 = @intCast(em.instructions.items.len);
        em.instructions.items[fork_try_pos].operand = .{ .index = catch_ip };

        if (is_last) {
            // Empty handler: pop the saved input and produce empty.
            try em.pushInstr(.restore_input, .{ .none = {} }, node);
            try em.pushInstr(.backtrack, .{ .none = {} }, node);
        }
    }

    // Body lands here — backpatch the per-alternative jumps.
    const body_ip: u32 = @intCast(em.instructions.items.len);
    for (jump_to_body.items) |jmp_pos| {
        em.instructions.items[jmp_pos].operand = .{ .index = body_ip };
    }
}

/// Collect the var_ids declared by a (sub-)pattern in declaration order,
/// deduplicated. Used by `emitPatternAltBind` to seed the null-init
/// loop. Walks `destructure` IR nodes recursively — `as` carries one
/// id, `array` and `object` recurse, `alt_bind` is impossible at the
/// inner level (the AST nests alternatives only at the top).
fn collectAltVarIds(
    ir_obj: ir.IR,
    node_idx: u32,
    seen: *std.AutoHashMap(u32, void),
    ordered: *std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
) error{OutOfMemory}!void {
    const node = ir_obj.nodes.items[node_idx];
    if (node.op != .destructure) return;
    const slots = ir_obj.extra_data.items;
    const kind: ir.PatternKind = @enumFromInt(slots[node.extra]);
    switch (kind) {
        .as => {
            const var_id = slots[node.extra + 3];
            if (!seen.contains(var_id)) {
                try seen.put(var_id, {});
                try ordered.append(allocator, var_id);
            }
        },
        .array => {
            const span = ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            for (span) |sub| try collectAltVarIds(ir_obj, sub, seen, ordered, allocator);
        },
        .object => {
            const span = ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            // Skip key children (offset 0 in each pair); pattern children
            // live at offset 1.
            var pi: usize = 1;
            while (pi < span.len) : (pi += 2) {
                try collectAltVarIds(ir_obj, span[pi], seen, ordered, allocator);
            }
        },
        .alt_bind => {
            // Nested `?//` is not a legal AST shape today (parser only
            // emits one alt-bind per `as`); recurse defensively for
            // future-proofing.
            const span = ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            for (span) |sub| try collectAltVarIds(ir_obj, sub, seen, ordered, allocator);
        },
    }
}

/// Emit a pattern subtree under `?//`-strict semantics: load_index /
/// load_key are NOT wrapped in fork_try, so a TypeError mid-destructure
/// propagates out to the enclosing `fork_try` and triggers the next
/// alternative. Mirrors legacy `emitPatternCaptureStrict` at
/// `src/query/src/compiler.zig:704-755`.
fn emitPatternStrict(em: *Emitter, node_idx: u32) EmitError!void {
    const node = em.ir_obj.nodes.items[node_idx];
    std.debug.assert(node.op == .destructure);
    const slots = em.ir_obj.extra_data.items;
    const kind: ir.PatternKind = @enumFromInt(slots[node.extra]);
    switch (kind) {
        .as => {
            const var_id: i64 = @intCast(slots[node.extra + 3]);
            try em.pushInstr(.capture_variable, .{ .index = var_id }, node);
        },
        .array => {
            try em.pushInstr(.pipe, .{ .none = {} }, node);
            const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            for (span, 0..) |sub_idx, i| {
                try em.pushInstr(.save_input, .{ .none = {} }, node);
                try em.pushInstr(.load_index, .{ .index = @intCast(i) }, node);
                try emitPatternStrict(em, sub_idx);
                try em.pushInstr(.restore_input, .{ .none = {} }, node);
            }
        },
        .object => {
            try em.pushInstr(.pipe, .{ .none = {} }, node);
            const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            std.debug.assert(span.len % 2 == 0);
            var pi: usize = 0;
            while (pi < span.len) : (pi += 2) {
                const key_idx = span[pi];
                const sub_idx = span[pi + 1];
                const key_node = em.ir_obj.nodes.items[key_idx];
                try em.pushInstr(.save_input, .{ .none = {} }, node);
                if (key_node.op == .load_const) {
                    const value = ir.loadConstValue(&em.ir_obj, key_node);
                    std.debug.assert(value == .string);
                    const key_slots = em.ir_obj.extra_data.items;
                    const k_off: u32 = key_slots[key_node.extra + 1];
                    const k_len: u32 = key_slots[key_node.extra + 2];
                    try em.pushInstr(
                        .load_key,
                        .{ .str_ref = .{ .offset = k_off, .len = k_len } },
                        node,
                    );
                } else {
                    try em.pushInstr(.save_input, .{ .none = {} }, node);
                    try emitNode(em, key_idx);
                    try em.pushInstr(.load_computed, .{ .none = {} }, node);
                    try em.pushInstr(.push_current, .{ .none = {} }, node);
                }
                try emitPatternStrict(em, sub_idx);
                try em.pushInstr(.restore_input, .{ .none = {} }, node);
            }
        },
        // Strict semantics within an alt_bind nest is unreachable in the
        // current AST surface. The parser only accepts `?//` at the top
        // level of an `as` suffix (`compiler.zig:2510-2516`), and
        // `lowerPattern` (lower.zig:2698-2807) only ever emits the
        // `as` / `array` / `object` PatternKinds for sub-patterns. The
        // `alt_bind` PatternKind is exclusively produced by `destruct_alt`
        // at the outermost destructure node (lower.zig:1237-1289), which
        // is dispatched via `emitPatternAltBind` (not via this strict
        // ladder). If a future grammar extension nests `?//` inside a
        // pattern, the lowering must be revisited before this branch can
        // emit code; until then, reaching here is a compiler bug.
        .alt_bind => unreachable,
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
            .repeat_start,
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

// ── Cat-10: builtin call emission ───────────────────────────────────
//
// The IR carries the builtin name and argument count; the emitter
// re-classifies via `lower_mod.classifyBuiltin` (single source of truth)
// and dispatches to the corresponding bytecode shape. Each shape
// mirrors a specific legacy compile* helper:
//   * 0-arg          → direct `call_builtin(bid)`
//   * value_arg1     → `compileValueArgBuiltin1` simple-no-comma path
//   * filter_arg1    → `compileFilterArgBuiltin`
//   * math2          → `compileTwoArgMath` / `compileSetpath`
//   * math3          → `compileThreeArgMath`
//
// Every shape ends with `call_builtin(bid)` — the operand is the
// `BuiltinId` integer; non-regex builtins ignore the upper bits of the
// operand (regex builtins pack pool index + n-flag there, and that
// family lands in a later category).
fn emitCallBuiltin(em: *Emitter, node: ir.Node) EmitError!void {
    const slots = em.ir_obj.extra_data.items;
    const offset: u32 = slots[node.extra];
    const len: u32 = slots[node.extra + 1];
    const name = em.ir_obj.string_buf.items[offset .. offset + len];

    const arity: usize = node.span_len;
    const class = lower_mod.classifyBuiltin(name, arity);

    // Cat-13 generator-arg shapes do not pass through
    // `nameToBuiltinId` — they synthesize streaming-frame opcodes
    // (`limit_start`/`skip_start`/`nth_start`) and arity-keyed bids
    // (`range1_gen`/`range2_gen`/`range3_gen`) inline. The shared
    // helpers below own the per-name dispatch.
    //
    // Cat-17 standalone `@fmt` form (e.g. `@base64`, `@json`) also
    // bypasses `nameToBuiltinId` because the format-apply BIDs
    // (`.format_text` etc.) live in a different name table —
    // `formatBuiltinId` — keyed on the unprefixed name. Mirrors
    // legacy `compiler.zig:6227-6232`.
    switch (class) {
        .range_gen1, .range_gen2, .range_gen3 => return emitRange(em, node),
        .limit_skip_nth => return emitLimitSkipNth(em, node, name),
        .first_arg1 => return emitFirst(em, node),
        .last_arg1 => return emitLast(em, node),
        .repeat_arg1 => return emitRepeat(em, node),
        .format_apply => return emitFormatApply(em, node, name),
        // Cat-16 — `error(msg)` (1-arity), `del(path_expr)` (1-arity).
        // Both have a name that doesn't appear in `nameToBuiltinId`
        // (error is only registered there at 0-arity; del has no entry
        // at all) so we early-out before the bid lookup. The 0-arity
        // form `error` flows through `zero_arg` instead.
        .error_arg1 => return emitErrorArg1(em, node),
        .del_path => return emitDelPath(em, node),
        // P5 — `map(f)` / `select(f)` 1-arity. Both have dedicated
        // bytecode shapes that don't reduce to a flat `call_builtin`,
        // so they bypass `nameToBuiltinId` (`map` has no bid; `select`
        // doesn't either — its name reaches the IR but emits no
        // `call_builtin` runtime call).
        .map_arg1 => return emitMap(em, node),
        .select_arg1 => return emitSelect(em, node),
        else => {},
    }

    // Post-cutover: every (name, arity) tuple that reaches this lookup
    // is registered in `nameToBuiltinId`'s 0/1/2/3-arity branches. A
    // miss here is a name-table desync between lower and emit — a
    // compiler bug rather than a runtime SKIP.
    const bid = nameToBuiltinId(name, arity) orelse unreachable;

    switch (class) {
        .zero_arg => {
            try em.pushInstr(
                .call_builtin,
                .{ .index = @intFromEnum(bid) },
                node,
            );
        },
        .value_arg1, .value_arg1_gen => {
            // `<arg> ; call_builtin(bid)` — no save/restore, matches
            // legacy `compileValueArgBuiltin1` simple-no-comma path.
            // The argument expression's own emission may push to the
            // value stack; legacy semantics expect that result to be
            // consumed by the builtin (e.g. `split(",")` pops the
            // pattern off the stack).
            //
            // Cat-16 `value_arg1_gen` (`index/rindex/indices`) shares
            // this shape; comma-arg generators (`indices("a","b")`)
            // emit a `comma` SemOp child whose own fork/jump bytecode
            // yields one value-stack push per branch. The single
            // trailing `call_builtin` runs once per yield because the
            // VM iterates each fork branch separately. Mirrors the
            // legacy fork-with-call-per-branch shape semantically
            // (the IP layout differs — one trailing call vs one per
            // branch — but observable yields are identical).
            const arg_idx = em.ir_obj.extra_children.items[node.span_start];
            try emitNode(em, arg_idx);
            try em.pushInstr(
                .call_builtin,
                .{ .index = @intFromEnum(bid) },
                node,
            );
        },
        .filter_arg1 => {
            // `save_input ; array_collect_start ; each ; <f> ;
            //  yield_output ; array_collect_end ; call_builtin(bid)`.
            // Mirrors legacy `compileFilterArgBuiltin`
            // (`compiler.zig:4472`) — collect every iteration's filter
            // result into a fresh array, then hand the array + original
            // input to the builtin which uses the array as the
            // sort/group/min/max key set. The leading `save_input`
            // preserves the original array on the if_stack so the
            // builtin can pair keys with elements.
            //
            // By-key family (`sort_by`/`group_by`/`min_by`/`max_by`/
            // `unique_by`): per jq, the key for an element is the array
            // of every value `f` produces for it. We wrap `<f>` in an
            // inner `array_collect_start`/`yield_output`/`array_collect_end`
            // so the outer keys array contains one sub-array per
            // element (1:1 with elements, regardless of how many
            // outputs `f` produces). Single-output `f` yields a
            // single-element array and lexicographic comparison still
            // gives the same ordering, so existing tests are unaffected.
            //
            // `add(f)` special case: `add` evaluates `f` once over the
            // current input (no `each` iteration) and the resulting
            // array is fed straight to `add`. We emit `pipe` (the new
            // array becomes the current input) and a trailing
            // `restore_input` so the original input is restored after
            // the call returns. Skipping `each` means the fork chain
            // built by `arr_ctor` inside `f` is the only place
            // `empty` can backtrack to — the `add` arm itself does
            // not introduce another forkpoint.
            //
            // `map_values(f)` keeps the flat shape: each `f` output
            // replaces the slot, so per-element wrapping would change
            // its semantics.
            const is_add = std.mem.eql(u8, name, "add");
            const is_by_key = std.mem.eql(u8, name, "sort_by") or
                std.mem.eql(u8, name, "group_by") or
                std.mem.eql(u8, name, "min_by") or
                std.mem.eql(u8, name, "max_by") or
                std.mem.eql(u8, name, "unique_by");
            try em.pushInstr(.save_input, .{ .none = {} }, node);
            const start_pos = em.instructions.items.len;
            try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);
            if (!is_add) {
                try em.pushInstr(.each, .{ .none = {} }, node);
            }
            var inner_start_pos: usize = 0;
            if (is_by_key) {
                inner_start_pos = em.instructions.items.len;
                try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);
            }
            const arg_idx = em.ir_obj.extra_children.items[node.span_start];
            try emitNode(em, arg_idx);
            try em.pushInstr(.yield_output, .{ .none = {} }, node);
            if (is_by_key) {
                const inner_end_ip: u32 = @intCast(em.instructions.items.len);
                try em.pushInstr(.array_collect_end, .{ .none = {} }, node);
                em.instructions.items[inner_start_pos].operand = .{ .index = inner_end_ip };
                try em.pushInstr(.yield_output, .{ .none = {} }, node);
            }
            const end_ip: u32 = @intCast(em.instructions.items.len);
            try em.pushInstr(.array_collect_end, .{ .none = {} }, node);
            em.instructions.items[start_pos].operand = .{ .index = end_ip };
            if (is_add) {
                try em.pushInstr(.pipe, .{ .none = {} }, node);
            }
            try em.pushInstr(
                .call_builtin,
                .{ .index = @intFromEnum(bid) },
                node,
            );
            if (is_add) {
                try em.pushInstr(.restore_input, .{ .none = {} }, node);
            }
        },
        .math2 => {
            // `save_input ; <a> ; restore_input ; save_input ; <b> ;
            //  restore_input ; call_builtin(bid)`. Mirrors legacy
            //  `compileTwoArgMath` (`compiler.zig:3707`) and
            //  `compileSetpath` (`compiler.zig:3676`).
            const args = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            try em.pushInstr(.save_input, .{ .none = {} }, node);
            try emitNode(em, args[0]);
            try em.pushInstr(.restore_input, .{ .none = {} }, node);
            try em.pushInstr(.save_input, .{ .none = {} }, node);
            try emitNode(em, args[1]);
            try em.pushInstr(.restore_input, .{ .none = {} }, node);
            try em.pushInstr(
                .call_builtin,
                .{ .index = @intFromEnum(bid) },
                node,
            );
        },
        .math3 => {
            // Same as math2 but with three save/restore cycles.
            // Mirrors legacy `compileThreeArgMath` (`compiler.zig:3867`).
            const args = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            try em.pushInstr(.save_input, .{ .none = {} }, node);
            try emitNode(em, args[0]);
            try em.pushInstr(.restore_input, .{ .none = {} }, node);
            try em.pushInstr(.save_input, .{ .none = {} }, node);
            try emitNode(em, args[1]);
            try em.pushInstr(.restore_input, .{ .none = {} }, node);
            try em.pushInstr(.save_input, .{ .none = {} }, node);
            try emitNode(em, args[2]);
            try em.pushInstr(.restore_input, .{ .none = {} }, node);
            try em.pushInstr(
                .call_builtin,
                .{ .index = @intFromEnum(bid) },
                node,
            );
        },
        // The lowerer never produces these classes through `call_builtin`
        // (it routes them to dedicated SemOps), so emit unreachable —
        // hitting them indicates an upstream classifier drift. `not`
        // and `path` go to leaf SemOps; `while_until_2arg` lowers to
        // `while_`/`until_` SemOps directly (cat-15).
        .not, .path, .while_until_2arg => unreachable,
        // Cat-13 / cat-17 / cat-16 classes already handled by the
        // early-out switch above — reaching them here would mean
        // the early-out fell through.
        .range_gen1, .range_gen2, .range_gen3, .limit_skip_nth, .first_arg1, .last_arg1, .format_apply, .error_arg1, .del_path, .map_arg1, .select_arg1, .repeat_arg1 => unreachable,
        // Cat-18 — `any(f)` / `any(g;f)` / `all(f)` / `all(g;f)`.
        // These are fully desugared at lower time via `lowerAnyAllDesugar`
        // into standard AST + recursive lowerNode. They never produce a
        // `call_builtin` IR node with these class tags — the synthesized
        // subtree produces only `pipe`, `if_expr`, `builtin_call("first")`,
        // `array_construct`, and `comparison` nodes. Reaching here means
        // a classifier drift between lower.zig and emit.zig.
        .any_desugar1, .any_desugar2, .all_desugar1, .all_desugar2 => unreachable,
        // Cat-19 — pick_desugar1 is fully resolved at lower time into
        // as_pattern + reduce + path + setpath/getpath IR nodes. A
        // call_builtin node carrying this class must never reach emit.
        .pick_desugar1 => unreachable,
        // `with_entries(f)` is fully resolved at lower time into a pipe
        // chain of `to_entries | map(f) | from_entries`. A call_builtin
        // node carrying this class must never reach emit.
        .with_entries_desugar1 => unreachable,
        // ── Regex builtins (cat-11) ─────────────────────────────────
        // The lowerer wrote a 4-slot `extra_data` payload `(name_off,
        // name_len, pool_idx, n_flag)`; emit packs `(bid, pool_idx,
        // n_flag)` into the `call_builtin` operand via the legacy SSOT
        // helper so the VM bytecode shape is unchanged (BUG-006).
        .regex1 => {
            const pool_idx: u32 = slots[node.extra + 2];
            const n_flag: bool = slots[node.extra + 3] != 0;
            // Dynamic patterns push the pattern arg onto the value
            // stack before the call; literal patterns rely on the
            // pool index in the operand and have no value-stack arg.
            if (pool_idx == types_mod.REGEX_POOL_DYNAMIC and node.span_len >= 1) {
                const pat_idx = em.ir_obj.extra_children.items[node.span_start];
                try emitNode(em, pat_idx);
            }
            try em.pushInstr(
                .call_builtin,
                .{ .index = types_mod.packRegexBuiltinOperandFlags(bid, pool_idx, n_flag) },
                node,
            );
        },
        .regex2 => {
            const pool_idx: u32 = slots[node.extra + 2];
            const n_flag: bool = slots[node.extra + 3] != 0;
            const args = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            if (pool_idx == types_mod.REGEX_POOL_DYNAMIC) {
                // Dynamic pattern: span = [pat, repl]. Mirrors legacy
                // `compileRegexBuiltin2` slow path:
                //   save_input ; <pat> ; restore_input ;
                //   save_input ; <repl> ; restore_input ; call_builtin
                std.debug.assert(args.len == 2);
                try em.pushInstr(.save_input, .{ .none = {} }, node);
                try emitNode(em, args[0]);
                try em.pushInstr(.restore_input, .{ .none = {} }, node);
                try em.pushInstr(.save_input, .{ .none = {} }, node);
                try emitNode(em, args[1]);
                try em.pushInstr(.restore_input, .{ .none = {} }, node);
            } else {
                // Literal pattern: span = [repl] only. The pool index
                // supplies the regex; the pattern push is replaced by
                // an empty save/restore pair so the input-stack
                // bracketing matches legacy's fast-path shape exactly.
                std.debug.assert(args.len == 1);
                try em.pushInstr(.save_input, .{ .none = {} }, node);
                try em.pushInstr(.restore_input, .{ .none = {} }, node);
                try em.pushInstr(.save_input, .{ .none = {} }, node);
                try emitNode(em, args[0]);
                try em.pushInstr(.restore_input, .{ .none = {} }, node);
            }
            try em.pushInstr(
                .call_builtin,
                .{ .index = types_mod.packRegexBuiltinOperandFlags(bid, pool_idx, n_flag) },
                node,
            );
        },
        // Post-cutover: lowering never produces a `.not_implemented`
        // class for an emitted IR node — the same exhaustiveness
        // invariant that holds in lower's `lowerBuiltinCall` switch
        // applies here. A name-table desync is a compiler bug.
        .not_implemented => unreachable,
    }
}

// ── Cat-13: generator-arg builtin emission ──────────────────────────
//
// All six builtins share a "save/restore + bounded-yield" template
// per §3.5; each shape is a distinct legacy hand-written byte
// sequence. Helpers here mirror their legacy counterparts byte-for-byte:
//
//   * range(1/2/3 args)  → array_collect each arg, save_input
//                          between, call_builtin(rangeN_gen) | each
//   * limit/skip/nth     → scope + var-capture wrap; iterate over n
//                          values, *_start frame around body
//   * first(f)           → push_int 1, limit_start, body, yield
//   * last(f)            → array_collect [f] | load_index(-1)
//
// Source-of-truth references — `compileRange/Limit/Skip/Nth/First/Last`
// at `src/query/src/compiler.zig:4317-4974`.

/// Wrap an IR child in `array_collect_start ... array_collect_end`,
/// emitting a trailing `yield_output` so generator-form children flow
/// into the array. Mirrors legacy `parseArgToArray`
/// (`compiler.zig:3320`). Used by `emitRange` and `emitLimitSkipNth` to
/// flatten a generator argument into a single array value.
fn emitArgToArray(em: *Emitter, node: ir.Node, child_idx: u32) EmitError!void {
    const start_pos = em.instructions.items.len;
    try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);
    try emitNode(em, child_idx);
    try em.pushInstr(.yield_output, .{ .none = {} }, node);
    const end_pos: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(.array_collect_end, .{ .none = {} }, node);
    em.instructions.items[start_pos].operand = .{ .index = end_pos };
}

/// Emit `range(...)` for arity 1/2/3. Mirrors `compileRange`
/// (`compiler.zig:4317`). Each arg is collected to an array via
/// `parseArgToArray`-equivalent so generator forms (`range(2,5)` etc)
/// expand correctly. For multi-arity, intermediate arrays are saved
/// onto the if_stack via `save_input` so the builtin can pop them in
/// order. Final pattern emits `call_builtin(rangeN_gen) | each` to
/// flatten the synthesized output array into individual yields.
fn emitRange(em: *Emitter, node: ir.Node) EmitError!void {
    const args = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];

    // First arg always present (arity ≥ 1).
    try emitArgToArray(em, node, args[0]);
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    if (args.len == 1) {
        try em.pushInstr(
            .call_builtin,
            .{ .index = @intFromEnum(types_mod.BuiltinId.range1_gen) },
            node,
        );
        try em.pushInstr(.pipe, .{ .none = {} }, node);
        try em.pushInstr(.each, .{ .none = {} }, node);
        return;
    }

    // 2- or 3-arg: save the from-array on if_stack, emit second arg.
    try em.pushInstr(.save_input, .{ .none = {} }, node);
    try emitArgToArray(em, node, args[1]);
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    if (args.len == 2) {
        try em.pushInstr(
            .call_builtin,
            .{ .index = @intFromEnum(types_mod.BuiltinId.range2_gen) },
            node,
        );
        try em.pushInstr(.pipe, .{ .none = {} }, node);
        try em.pushInstr(.each, .{ .none = {} }, node);
        return;
    }

    // 3-arg form: save the to-array, emit by-array.
    try em.pushInstr(.save_input, .{ .none = {} }, node);
    try emitArgToArray(em, node, args[2]);
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    try em.pushInstr(
        .call_builtin,
        .{ .index = @intFromEnum(types_mod.BuiltinId.range3_gen) },
        node,
    );
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.each, .{ .none = {} }, node);
}

/// Emit `limit(n; f)`, `skip(n; f)`, or `nth(n; f)`. The three share
/// an identical scaffold — only the streaming-frame opcode differs
/// (`limit_start` / `skip_start` / `nth_start`), and `nth` further
/// nests an inner `limit_start` to grab exactly one output post-skip.
/// Mirrors `compileLimit` (`compiler.zig:4684`), `compileSkip`
/// (`:4874`), `compileNth` (`:4924`).
fn emitLimitSkipNth(em: *Emitter, node: ir.Node, name: []const u8) EmitError!void {
    std.debug.assert(node.span_len == 2);
    const args = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
    const n_idx = args[0];
    const body_idx = args[1];

    // Pick the streaming-frame opcode by name.
    const frame_op: types_mod.Instruction.Op = if (std.mem.eql(u8, name, "limit"))
        .limit_start
    else if (std.mem.eql(u8, name, "skip"))
        .skip_start
    else if (std.mem.eql(u8, name, "nth"))
        .nth_start
    else
        unreachable;

    const input_var = em.allocVar();

    // $orig = .
    try em.pushInstr(.push_current, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = input_var }, node);

    // [n_arg] | each — iterate over each n value (handles generators).
    try emitArgToArray(em, node, n_idx);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.each, .{ .none = {} }, node);

    // Push current n onto value_stack, restore original input as current.
    try em.pushInstr(.push_current, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = input_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    // Streaming frame opcode — pops n from value_stack, sets up
    // counter; backpatched with the IP past the body's yield_output.
    const frame_ip: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(frame_op, .{ .index = 0 }, node);

    // For nth, an inner limit_start(1) wraps the body so post-skip
    // exactly one output is taken. Mirrors `compileNth`
    // (`compiler.zig:4954-4957`).
    var inner_limit_ip: ?u32 = null;
    if (frame_op == .nth_start) {
        try em.pushInstr(.push_int, .{ .int = 1 }, node);
        inner_limit_ip = @intCast(em.instructions.items.len);
        try em.pushInstr(.limit_start, .{ .index = 0 }, node);
    }

    // Body.
    try emitNode(em, body_idx);
    try em.pushInstr(.yield_output, .{ .none = {} }, node);

    // Backpatch frame exit IPs. For nth, both inner limit and outer
    // skip frames target the same end-of-body IP — mirrors
    // `compileNth` (`compiler.zig:4969-4972`).
    const exit_ip: u32 = @intCast(em.instructions.items.len);
    if (inner_limit_ip) |ip| {
        em.instructions.items[ip].operand = .{ .index = exit_ip };
    }
    em.instructions.items[frame_ip].operand = .{ .index = exit_ip };

    // Pop the captured input — undoes the push_current at the top.
    // Intentional divergence from legacy compileLimit/Skip/Nth
    // (compiler.zig:4684/4874/4924), which call `popScope` at end —
    // a compile-time bookkeeping op that emits no runtime opcode and
    // leaves the binding live in the variable table. Our pop_variable
    // emits the runtime cleanup so the captured input slot doesn't
    // outlive the builtin call. vm-equiv confirms output parity; no
    // observable behavior change.
    try em.pushInstr(.pop_variable, .{ .index = input_var }, node);
}

/// Emit `first` / `first(f)`. The 0-arg form (bare `first`) lowers
/// to `.[0]` directly — mirrors legacy
/// `compiler.zig:5930-5933`. The 1-arg form desugars to
/// `limit(1; f)`; n is a literal so no scope/var-capture is needed,
/// matching `compileFirst` (`compiler.zig:4633`).
fn emitFirst(em: *Emitter, node: ir.Node) EmitError!void {
    if (node.span_len == 0) {
        try em.pushInstr(.load_index, .{ .index = 0 }, node);
        return;
    }
    std.debug.assert(node.span_len == 1);
    const body_idx = em.ir_obj.extra_children.items[node.span_start];

    // Push n=1 then start streaming-limit frame.
    try em.pushInstr(.push_int, .{ .int = 1 }, node);
    const limit_ip: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(.limit_start, .{ .index = 0 }, node);

    try emitNode(em, body_idx);
    try em.pushInstr(.yield_output, .{ .none = {} }, node);

    const exit_ip: u32 = @intCast(em.instructions.items.len);
    em.instructions.items[limit_ip].operand = .{ .index = exit_ip };
}

/// Emit `repeat(f)` — jq's infinite generator
/// `def repeat(exp): def _r: exp, _r; _r;`. The body re-runs against
/// the original input each iteration, yielding every value the body
/// produces, indefinitely. Termination is delegated to an enclosing
/// `limit_start` counter (matching jq's `limit(N; repeat(f))` idiom);
/// without one the loop runs forever — matching jq's bare-`repeat`
/// semantics.
///
/// Layout (mirrors the streaming-frame shape of `limit_start`):
///   ip0: repeat_start exit_ip   ; pushes RepeatFrame fork; saves current
///   body_start = ip0+1:
///     <f>                       ; produces value(s)
///     yield_output              ; yields each (counts against any
///                               ; enclosing `limit` frame)
///     backtrack                 ; pops inner generator forks first;
///                               ; on reaching the RepeatFrame, restores
///                               ; the saved input and re-enters body
///   exit_ip:
///     repeat_end                ; only reached if an enclosing scope
///                               ; truncates the fork stack past us
///
/// No explicit save/restore_input needed: the RepeatFrame's
/// `saved_current` is the canonical input source, restored every
/// time `backtrack` falls through to the frame.
fn emitRepeat(em: *Emitter, node: ir.Node) EmitError!void {
    std.debug.assert(node.span_len == 1);
    const body_idx = em.ir_obj.extra_children.items[node.span_start];

    const repeat_ip: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(.repeat_start, .{ .index = 0 }, node);

    try emitNode(em, body_idx);
    try em.pushInstr(.yield_output, .{ .none = {} }, node);
    try em.pushInstr(.backtrack, .{ .none = {} }, node);

    const exit_ip: u32 = @intCast(em.instructions.items.len);
    em.instructions.items[repeat_ip].operand = .{ .index = exit_ip };
    try em.pushInstr(.repeat_end, .{ .none = {} }, node);
}

/// Emit `last` / `last(f)`. The 0-arg form lowers to `.[-1]`
/// directly — mirrors legacy `compiler.zig:5934-5937`. The 1-arg
/// form desugars to `[f] | .[-1]` per `compileLast`
/// (`compiler.zig:4658`).
///
/// Empty-stream guard: `last(empty)` must produce nothing, matching
/// jq's contract.  The naive `[f] | .[-1]` desugaring would return
/// `null` for an empty array (VM's load_index on `[]` returns null).
/// We guard against this by checking the collected array's length:
///   call_builtin(length) → pushed to value_stack; current=[f] unchanged
///   push_int 0 ; eq       → value_stack=[(len==0)]
///   jump_if_false L_ok    → skip if non-empty
///   backtrack             → empty stream: produce nothing
/// L_ok:
///   load_index -1         → last element
fn emitLast(em: *Emitter, node: ir.Node) EmitError!void {
    if (node.span_len == 0) {
        try em.pushInstr(.load_index, .{ .index = -1 }, node);
        return;
    }
    std.debug.assert(node.span_len == 1);
    const body_idx = em.ir_obj.extra_children.items[node.span_start];

    try emitArgToArray(em, node, body_idx);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    // current = [f]; check for empty stream.
    // call_builtin(length) pushes len to value_stack; current unchanged.
    try em.pushInstr(
        .call_builtin,
        .{ .index = @intFromEnum(types_mod.BuiltinId.length) },
        node,
    );
    try em.pushInstr(.push_int, .{ .int = 0 }, node);
    try em.pushInstr(.eq, .{ .none = {} }, node);
    const jif_pos: usize = em.instructions.items.len;
    try em.pushInstr(.jump_if_false, .{ .index = 0 }, node);
    // Empty: produce nothing.
    try em.pushInstr(.backtrack, .{ .none = {} }, node);
    // Non-empty: load last element.
    const ok_ip: u32 = @intCast(em.instructions.items.len);
    em.instructions.items[jif_pos].operand = .{ .index = ok_ip };
    try em.pushInstr(.load_index, .{ .index = -1 }, node);
}

/// Emit a standalone `@fmt` form (cat-17) — `@base64`, `@json`, etc.
/// when not followed by a string literal. Mirrors legacy
/// `compiler.zig:6227-6232`: a single `call_builtin(format_bid)`
/// applied to the current value. The IR carries the format name with
/// its leading `@` (parser `internFormatName`); strip it here before
/// consulting `formatBuiltinId`. `classifyBuiltin` only routes to
/// `format_apply` after `isFormatApplyName` confirms the suffix is in
/// the SSOT registry (`isKnownFormatName`), so the lookup is total.
fn emitFormatApply(em: *Emitter, node: ir.Node, name: []const u8) EmitError!void {
    std.debug.assert(node.span_len == 0);
    std.debug.assert(name.len >= 2 and name[0] == '@');
    const bid = formatBuiltinId(name[1..]) orelse unreachable;
    try em.pushInstr(
        .call_builtin,
        .{ .index = @intFromEnum(bid) },
        node,
    );
}

// ── Cat-16 — error/del 1-arity emission ─────────────────────────────
//
// Two distinct shapes share this category:
//
//   * `error(msg)` — pipe the evaluated message into current, then
//     fire `call_builtin(error_)`. Mirrors legacy `compileErrorArg`
//     (`src/query/src/compiler.zig:3956`) byte-for-byte.
//   * `del(path_expr)` — desugar to the `[path(f)]`/`delpaths`
//     pipeline at emit time. Mirrors legacy `compileDel`
//     (`src/query/src/compiler.zig:5529`) byte-for-byte: two hidden
//     vars (`$orig`, `$paths`) allocated via `Emitter.allocVar` in
//     legacy's allocation order so generated bytecode matches the
//     legacy var indices for any sibling frame layout.
//
// `index/rindex/indices` are not handled here — they share the
// `value_arg1` shape (`<arg> ; call_builtin(bid)`) and route through
// the unified `value_arg1, value_arg1_gen` arm in `emitCallBuiltin`.

/// Emit `error(msg)` 1-arity. Mirrors `compileErrorArg`
/// (`compiler.zig:3956`):
///   <msg>                        ; evaluate message expression
///   pipe                         ; transfer value-stack top to current
///   call_builtin(error_)         ; raise with current as the message
///
/// The pipe is required because legacy `parsePipe` leaves the message
/// on the value stack, then `pipe` advances current to the message
/// before the VM's `error_` handler reads it. Distinct from `value_arg1`
/// (which emits no pipe — its arg lives on the value stack and the
/// builtin pops it directly) because `error_` reads its arg from
/// current, not the stack.
fn emitErrorArg1(em: *Emitter, node: ir.Node) EmitError!void {
    std.debug.assert(node.span_len == 1);
    const arg_idx = em.ir_obj.extra_children.items[node.span_start];
    try emitNode(em, arg_idx);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(
        .call_builtin,
        .{ .index = @intFromEnum(types_mod.BuiltinId.error_) },
        node,
    );
}

/// Emit `del(path_expr)` 1-arity. Mirrors `compileDel`
/// (`compiler.zig:5529`) byte-for-byte:
///
/// ```
/// push_current
/// capture_variable($orig)
/// array_collect_start <ace_end>     ; outer [path(f)] collect
///   path_begin <path_end_ip>
///     <body>                         ; path expression (may comma-fork)
///   path_end
///   yield_output
/// array_collect_end
/// capture_variable($paths)
/// load_variable($orig)
/// pipe
/// load_variable($paths)
/// call_builtin(delpaths)
/// ```
///
/// The path-collect inner pattern reuses `emitPathCollection` (already
/// used by general-update assigns); the var allocation order
/// (`$orig` before `$paths`) matches legacy's `next_var_id` sequence
/// so the resulting bytecode is byte-identical when the surrounding
/// var frame is identical.
///
/// No new SemOp is required — every primitive
/// (`push_current`/`capture_variable`/`array_collect_*`/`path_*`/
/// `yield_output`/`load_variable`/`pipe`/`call_builtin`) already has
/// an IR-side counterpart, and emit-time hidden-var allocation via
/// `Emitter.allocVar` matches legacy's compile-time `next_var_id`
/// accounting (cat-13's `emitLimitSkipNth` / cat-18's
/// `emitComputedIndex` precedent).
fn emitDelPath(em: *Emitter, node: ir.Node) EmitError!void {
    std.debug.assert(node.span_len == 1);
    const body_idx = em.ir_obj.extra_children.items[node.span_start];

    const orig_var: i64 = @intCast(em.allocVar());
    const paths_var: i64 = @intCast(em.allocVar());

    try em.pushInstr(.push_current, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = orig_var }, node);

    try emitPathCollection(em, node, body_idx);

    try em.pushInstr(.capture_variable, .{ .index = paths_var }, node);

    try em.pushInstr(.load_variable, .{ .index = orig_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = paths_var }, node);
    try em.pushInstr(
        .call_builtin,
        .{ .index = @intFromEnum(types_mod.BuiltinId.delpaths) },
        node,
    );
}

// ── P5 — `map(f)` / `select(f)` 1-arity emission ────────────────────
//
// Two desugars share this category. Neither reduces to a flat
// `call_builtin`, so both bypass `nameToBuiltinId` and emit their
// legacy bytecode shape inline.
//
//   * `map(f)`   — `array_collect_start <end_ip> ; each ; <f> ;
//                   yield_output ; array_collect_end`. No leading
//                   `save_input` and no trailing `call_builtin` —
//                   `map` is purely a comprehension over the input
//                   array; the array-collect bracket alone produces
//                   the result. Mirrors `compileMap`
//                   (`src/query/src/compiler.zig:3338`) byte-for-byte.
//                   Distinct from `filter_arg1` (`sort_by`/`group_by`/
//                   etc.) which DOES emit `save_input`+trailing
//                   `call_builtin(bid)` because those builtins pair
//                   the collected keys with the original array.
//
//   * `select(f)`— `save_input ; <f> ; jump_if_false skip ;
//                   restore_input ; jump done ; skip: restore_input ;
//                   backtrack ; done:`. Mirrors `compileSelect`
//                   (`src/query/src/compiler.zig:3376`) byte-for-byte.
//                   The `backtrack` opcode replaces the legacy
//                   `call_builtin(empty)` reference in the doc-comment;
//                   they're observationally identical (both consume
//                   the current branch without emitting), and the
//                   actual legacy emission at line 3405 is
//                   `ctx.emit(.backtrack, ...)`.

/// Emit `map(f)` 1-arity. Mirrors legacy `compileMap`
/// (`src/query/src/compiler.zig:3338`):
///
/// ```
/// array_collect_start <end_ip>     ; placeholder, backpatched
///   each                           ; iterate over current
///   <f>                            ; per-element body
///   yield_output                   ; collect each element
/// array_collect_end                ; <end_ip> = this position
/// ```
fn emitMap(em: *Emitter, node: ir.Node) EmitError!void {
    std.debug.assert(node.span_len == 1);
    const body_idx = em.ir_obj.extra_children.items[node.span_start];

    const start_pos = em.instructions.items.len;
    try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);
    try em.pushInstr(.each, .{ .none = {} }, node);

    try emitNode(em, body_idx);

    try em.pushInstr(.yield_output, .{ .none = {} }, node);
    const end_pos: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(.array_collect_end, .{ .none = {} }, node);
    em.instructions.items[start_pos].operand = .{ .index = end_pos };
}

/// Emit `select(f)` 1-arity. Mirrors legacy `compileSelect`
/// (`src/query/src/compiler.zig:3376`):
///
/// ```
/// save_input                       ; preserve original for output
/// <f>                              ; predicate result on value stack
/// jump_if_false -> skip
/// restore_input                    ; truthy: original becomes output
/// jump -> done
/// skip:
/// restore_input                    ; falsy: pop save_input frame
/// backtrack                        ; produce no output for this branch
/// done:
/// ```
///
/// The closing label `done:` is materialized by backpatching the
/// `jump` operand to the post-`backtrack` IP; no instruction is
/// emitted there (legacy ends `compileSelect` the same way — the
/// next outer instruction occupies the `done` IP).
fn emitSelect(em: *Emitter, node: ir.Node) EmitError!void {
    std.debug.assert(node.span_len == 1);
    const body_idx = em.ir_obj.extra_children.items[node.span_start];

    try em.pushInstr(.save_input, .{ .none = {} }, node);
    try emitNode(em, body_idx);

    const jif_pos = em.instructions.items.len;
    try em.pushInstr(.jump_if_false, .{ .index = 0 }, node);

    try em.pushInstr(.restore_input, .{ .none = {} }, node);

    const jmp_pos = em.instructions.items.len;
    try em.pushInstr(.jump, .{ .index = 0 }, node);

    const skip_ip: u32 = @intCast(em.instructions.items.len);
    em.instructions.items[jif_pos].operand = .{ .index = skip_ip };
    try em.pushInstr(.restore_input, .{ .none = {} }, node);
    try em.pushInstr(.backtrack, .{ .none = {} }, node);

    const done_ip: u32 = @intCast(em.instructions.items.len);
    em.instructions.items[jmp_pos].operand = .{ .index = done_ip };
}

/// Emit `computed_index(base, key)` (cat-18 / Phase 27). Implements
/// jq's `EXPR[key]` semantics: the key expression resolves against
/// the OUTER input (the input the suffix chain receives), not
/// against the result of `EXPR`. Standalone `.[key]` reuses this
/// path with `base = identity`, where the captured outer input and
/// the base value are equal.
///
/// ```
/// push_current               ; preserve outer input
/// capture_variable($outer)
/// <base expression>          ; may be a generator (fork/backtrack)
/// capture_variable($base)    ; per-iteration: capture each base
/// load_variable($outer)      ; restore current = outer input
/// pipe                       ; advance to key phase
/// <key expression>           ; eval key against outer input
/// capture_variable($key)     ; per-iteration: capture each key
/// load_variable($base)       ; restore base value
/// pipe                       ; advance to lookup phase
/// save_input                 ; bracket the load_computed
/// load_variable($key)
/// load_computed              ; .[$key] on the base
/// ```
///
/// The three var_ids are allocated from the emitter (above the
/// `next_var_id_seed` watermark) so the captures don't collide with
/// any outer cat-9 / cat-13 frame variables. No SemOp `pop_variable`
/// is emitted: legacy uses `popScope` here, which is a compile-time
/// bookkeeping op with no runtime opcode — same divergence rationale
/// as `emitLimitSkipNth`'s comment.
fn emitComputedIndex(em: *Emitter, node: ir.Node) EmitError!void {
    const outer_var: i64 = @intCast(em.allocVar());
    const base_var: i64 = @intCast(em.allocVar());
    const key_var: i64 = @intCast(em.allocVar());

    // Capture outer input.
    try em.pushInstr(.push_current, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = outer_var }, node);

    // Evaluate base against outer input. Generator-form bases
    // (`(.a, .b)[k]`) fork here; the per-iteration block below
    // re-runs for every yielded base.
    try emitNode(em, node.children[0]);

    try em.pushInstr(.capture_variable, .{ .index = base_var }, node);
    try em.pushInstr(.load_variable, .{ .index = outer_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    // Mark the key-eval region as meta-level for any enclosing
    // `path(f)` / path-assign frame: descent ops inside the key
    // expression must not append to the outer path. The matching
    // `load_computed` below clears the flag and records the actual
    // key as the single path component. No-op outside a path frame.
    try em.pushInstr(.mark_computed_key, .{ .none = {} }, node);

    // Evaluate key against outer input. Generator-form keys fork
    // here; lookup runs once per (base × key) combination.
    try emitNode(em, node.children[1]);

    try em.pushInstr(.capture_variable, .{ .index = key_var }, node);
    try em.pushInstr(.load_variable, .{ .index = base_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.save_input, .{ .none = {} }, node);
    try em.pushInstr(.load_variable, .{ .index = key_var }, node);
    try em.pushInstr(.load_computed, .{ .none = {} }, node);
}

/// Emit `computed_slice` (cat-18 sibling of `computed_index`).
/// Implements `.[<from_expr>:<to_expr>]` where either bound is a
/// non-integer-literal expression. Mirrors `emitComputedIndex`'s
/// capture pattern — the base (slice input) is preserved across bound
/// evaluations via a captured variable, and the base is restored
/// between exprs so each evaluates against the original input rather
/// than the previous bound's result.
///
/// Sequence (when both bounds are exprs):
/// ```
/// push_current               ; value_stack ← current (base)
/// capture_variable($base)
/// <from_expr>                ; current = from result
/// capture_variable($from)
/// load_variable($base)       ; restore current = base
/// pipe
/// <to_expr>                  ; current = to result
/// capture_variable($to)
/// load_variable($base)       ; restore current = base for slice phase
/// pipe
/// save_input                 ; if_stack ← base
/// load_variable($from)       ; value_stack ← from
/// load_variable($to)         ; value_stack ← to (top)
/// slice_computed <flags>     ; pops to, from from value_stack;
///                              base from if_stack
/// ```
///
/// When only one bound is an expr, the literal-bound side is encoded
/// in `slice_args.from` / `slice_args.to` and skipped on the
/// value-stack path. The four flag bits (has_from, has_to,
/// has_from_expr, has_to_expr) tell the VM which slots to consume.
fn emitSliceComputed(em: *Emitter, node: ir.Node) EmitError!void {
    const slots = em.ir_obj.extra_data.items;
    const from_u: u32 = slots[node.extra];
    const to_u: u32 = slots[node.extra + 1];
    const flags: u32 = slots[node.extra + 2];
    const has_from = (flags & 1) != 0;
    const has_to = (flags & 2) != 0;
    const has_from_expr = (flags & 4) != 0;
    const has_to_expr = (flags & 8) != 0;

    const base_var: i64 = @intCast(em.allocVar());
    const from_var: i64 = if (has_from_expr) @intCast(em.allocVar()) else 0;
    const to_var: i64 = if (has_to_expr) @intCast(em.allocVar()) else 0;

    try em.pushInstr(.push_current, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = base_var }, node);

    if (has_from_expr) {
        try emitNode(em, node.children[0]);
        try em.pushInstr(.capture_variable, .{ .index = from_var }, node);
        // Restore base for the next evaluation phase (to_expr or
        // the slice itself).
        try em.pushInstr(.load_variable, .{ .index = base_var }, node);
        try em.pushInstr(.pipe, .{ .none = {} }, node);
    }
    if (has_to_expr) {
        try emitNode(em, node.children[1]);
        try em.pushInstr(.capture_variable, .{ .index = to_var }, node);
        try em.pushInstr(.load_variable, .{ .index = base_var }, node);
        try em.pushInstr(.pipe, .{ .none = {} }, node);
    }

    // Surrounding capture for the slice itself: if_stack ← base.
    // Bound values pushed onto value_stack in from-then-to order so
    // the VM pops `to` first, then `from`.
    try em.pushInstr(.save_input, .{ .none = {} }, node);
    if (has_from_expr) try em.pushInstr(.load_variable, .{ .index = from_var }, node);
    if (has_to_expr) try em.pushInstr(.load_variable, .{ .index = to_var }, node);

    const args = types_mod.SliceArgs{
        .from = @bitCast(from_u),
        .to = @bitCast(to_u),
        .has_from = has_from,
        .has_to = has_to,
        .has_from_expr = has_from_expr,
        .has_to_expr = has_to_expr,
    };
    try em.pushInstr(.slice_computed, .{ .slice_args = args }, node);
}

/// Map a (jq-visible) builtin name + arity to its `BuiltinId`. Single
/// source of truth shared by emit + the cat-10 classifier — every entry
/// here corresponds to a class arm in `lower_mod.classifyBuiltin`. The
/// (name, arity) tuple disambiguates overloaded names (e.g. `flatten`
/// has both 0-arg and 1-arg forms mapping to different ids).
fn nameToBuiltinId(name: []const u8, arity: usize) ?types_mod.BuiltinId {
    // Regex builtins (cat-11) — dispatch by name alone, regardless
    // of IR arity. Lowering may produce span_len ∈ {0, 1, 2}
    // depending on literal/dynamic pattern + 1-arg/2-arg form, so a
    // uniform arity check would mis-route. The synthesized
    // `match__g` name (from `match("pat";"g")`) maps to the internal
    // generator-mode bid `match_g_`.
    if (std.mem.eql(u8, name, "test")) return .test_;
    if (std.mem.eql(u8, name, "match")) return .match_;
    if (std.mem.eql(u8, name, "match__g")) return .match_g_;
    if (std.mem.eql(u8, name, "capture")) return .capture_;
    if (std.mem.eql(u8, name, "scan")) return .scan_;
    if (std.mem.eql(u8, name, "splits")) return .splits_;
    if (std.mem.eql(u8, name, "sub")) return .sub_;
    if (std.mem.eql(u8, name, "gsub")) return .gsub_;

    if (arity == 0) {
        if (std.mem.eql(u8, name, "length")) return .length;
        if (std.mem.eql(u8, name, "keys")) return .keys;
        if (std.mem.eql(u8, name, "keys_unsorted")) return .keys_unsorted;
        if (std.mem.eql(u8, name, "values")) return .values;
        if (std.mem.eql(u8, name, "type")) return .type_;
        if (std.mem.eql(u8, name, "empty")) return .empty;
        if (std.mem.eql(u8, name, "tostring")) return .tostring;
        if (std.mem.eql(u8, name, "tonumber")) return .tonumber;
        // Cat-16 — `error` 0-arity. Maps to `BuiltinId.error_` per
        // legacy `zeroArgBuiltinId` (`compiler.zig:2758`). The 1-arity
        // form `error(msg)` is owned by `error_arg1`, which goes
        // through `emitErrorArg1` (early-out before `nameToBuiltinId`).
        if (std.mem.eql(u8, name, "error")) return .error_;
        if (std.mem.eql(u8, name, "add")) return .add;
        if (std.mem.eql(u8, name, "sort")) return .sort;
        if (std.mem.eql(u8, name, "reverse")) return .reverse;
        if (std.mem.eql(u8, name, "flatten")) return .flatten;
        if (std.mem.eql(u8, name, "min")) return .min;
        if (std.mem.eql(u8, name, "max")) return .max;
        if (std.mem.eql(u8, name, "to_entries")) return .to_entries;
        if (std.mem.eql(u8, name, "from_entries")) return .from_entries;
        if (std.mem.eql(u8, name, "unique")) return .unique;
        if (std.mem.eql(u8, name, "paths")) return .paths;
        if (std.mem.eql(u8, name, "leaf_paths")) return .leaf_paths;
        if (std.mem.eql(u8, name, "recurse")) return .recurse;
        if (std.mem.eql(u8, name, "tojson")) return .tojson;
        if (std.mem.eql(u8, name, "fromjson")) return .fromjson;
        if (std.mem.eql(u8, name, "transpose")) return .transpose_;
        if (std.mem.eql(u8, name, "ascii_downcase")) return .ascii_downcase;
        if (std.mem.eql(u8, name, "ascii_upcase")) return .ascii_upcase;
        if (std.mem.eql(u8, name, "ascii")) return .ascii_;
        if (std.mem.eql(u8, name, "explode")) return .explode_;
        if (std.mem.eql(u8, name, "implode")) return .implode_;
        if (std.mem.eql(u8, name, "abs")) return .abs;
        if (std.mem.eql(u8, name, "floor")) return .floor_;
        if (std.mem.eql(u8, name, "ceil")) return .ceil_;
        if (std.mem.eql(u8, name, "round")) return .round_;
        if (std.mem.eql(u8, name, "sqrt")) return .sqrt_;
        if (std.mem.eql(u8, name, "fabs")) return .fabs_;
        if (std.mem.eql(u8, name, "nan")) return .nan_;
        if (std.mem.eql(u8, name, "infinite")) return .infinite_;
        if (std.mem.eql(u8, name, "isinfinite")) return .isinfinite_;
        if (std.mem.eql(u8, name, "isnan")) return .isnan_;
        if (std.mem.eql(u8, name, "isnormal")) return .isnormal_;
        if (std.mem.eql(u8, name, "have_decnum")) return .have_decnum_;
        if (std.mem.eql(u8, name, "have_literal_numbers")) return .have_decnum_;
        if (std.mem.eql(u8, name, "exp")) return .exp_;
        if (std.mem.eql(u8, name, "exp2")) return .exp2_;
        if (std.mem.eql(u8, name, "exp10")) return .exp10_;
        if (std.mem.eql(u8, name, "log")) return .log_;
        if (std.mem.eql(u8, name, "log2")) return .log2_;
        if (std.mem.eql(u8, name, "log10")) return .log10_;
        if (std.mem.eql(u8, name, "cbrt")) return .cbrt_;
        if (std.mem.eql(u8, name, "sin")) return .sin_;
        if (std.mem.eql(u8, name, "cos")) return .cos_;
        if (std.mem.eql(u8, name, "tan")) return .tan_;
        if (std.mem.eql(u8, name, "asin")) return .asin_;
        if (std.mem.eql(u8, name, "acos")) return .acos_;
        if (std.mem.eql(u8, name, "atan")) return .atan_;
        if (std.mem.eql(u8, name, "rint")) return .rint_;
        if (std.mem.eql(u8, name, "nearbyint")) return .nearbyint_;
        if (std.mem.eql(u8, name, "trunc")) return .trunc_;
        if (std.mem.eql(u8, name, "significand")) return .significand_;
        if (std.mem.eql(u8, name, "logb")) return .logb_;
        if (std.mem.eql(u8, name, "j0")) return .j0_;
        if (std.mem.eql(u8, name, "j1")) return .j1_;
        if (std.mem.eql(u8, name, "lgamma")) return .lgamma_;
        if (std.mem.eql(u8, name, "tgamma")) return .tgamma_;
        if (std.mem.eql(u8, name, "arrays")) return .arrays_;
        if (std.mem.eql(u8, name, "objects")) return .objects_;
        if (std.mem.eql(u8, name, "strings")) return .strings_;
        if (std.mem.eql(u8, name, "numbers")) return .numbers_;
        if (std.mem.eql(u8, name, "booleans")) return .booleans_;
        if (std.mem.eql(u8, name, "nulls")) return .nulls_;
        if (std.mem.eql(u8, name, "scalars")) return .scalars_;
        if (std.mem.eql(u8, name, "normals")) return .normals_;
        if (std.mem.eql(u8, name, "iterables")) return .iterables_;
        if (std.mem.eql(u8, name, "builtins")) return .builtins_;
        if (std.mem.eql(u8, name, "stderr")) return .stderr_;
        if (std.mem.eql(u8, name, "input")) return .input_;
        if (std.mem.eql(u8, name, "inputs")) return .inputs_;
        if (std.mem.eql(u8, name, "env")) return .env_;
        if (std.mem.eql(u8, name, "halt")) return .halt_;
        if (std.mem.eql(u8, name, "toboolean")) return .toboolean;
        if (std.mem.eql(u8, name, "utf8bytelength")) return .utf8bytelength;
        if (std.mem.eql(u8, name, "trim")) return .trim_;
        if (std.mem.eql(u8, name, "ltrim")) return .ltrim_;
        if (std.mem.eql(u8, name, "rtrim")) return .rtrim_;
        if (std.mem.eql(u8, name, "now")) return .now_;
        if (std.mem.eql(u8, name, "gmtime")) return .gmtime_;
        if (std.mem.eql(u8, name, "mktime")) return .mktime_;
        if (std.mem.eql(u8, name, "todate")) return .todate_;
        if (std.mem.eql(u8, name, "fromdate")) return .fromdate_;
        if (std.mem.eql(u8, name, "todateiso8601")) return .todateiso8601_;
        if (std.mem.eql(u8, name, "fromdateiso8601")) return .fromdateiso8601_;
        // 0-arity `any`/`all` — VM native builtins (root.zig:4111-4140).
        // The 1/2-arity forms are desugared in lowering and never reach here.
        if (std.mem.eql(u8, name, "any")) return .any;
        if (std.mem.eql(u8, name, "all")) return .all;
        return null;
    }

    if (arity == 1) {
        // `add(f)` 1-arity: the lowerer reclassifies `add` as a
        // filter_arg1 builtin so `add(empty)` is emitted with the
        // fork-chain-friendly `array_collect`/`each`/`yield_output`
        // sequence (see `.filter_arg1` arm in `emitCallBuiltin` —
        // `add` takes the special path that skips `each` over the
        // input and emits a `pipe` after `array_collect_end`). The
        // `add` BID is shared with the 0-arity form.
        if (std.mem.eql(u8, name, "add")) return .add;
        if (std.mem.eql(u8, name, "split")) return .split_;
        if (std.mem.eql(u8, name, "join")) return .join_;
        if (std.mem.eql(u8, name, "startswith")) return .startswith_;
        if (std.mem.eql(u8, name, "endswith")) return .endswith_;
        if (std.mem.eql(u8, name, "ltrimstr")) return .ltrimstr_;
        if (std.mem.eql(u8, name, "rtrimstr")) return .rtrimstr_;
        if (std.mem.eql(u8, name, "trimstr")) return .trimstr_;
        if (std.mem.eql(u8, name, "getpath")) return .getpath;
        if (std.mem.eql(u8, name, "delpaths")) return .delpaths;
        if (std.mem.eql(u8, name, "bsearch")) return .bsearch_;
        if (std.mem.eql(u8, name, "strftime")) return .strftime_;
        if (std.mem.eql(u8, name, "strptime")) return .strptime_;
        if (std.mem.eql(u8, name, "strflocaltime")) return .strflocaltime_;
        if (std.mem.eql(u8, name, "flatten")) return .flatten_n;
        if (std.mem.eql(u8, name, "has")) return .has;
        if (std.mem.eql(u8, name, "contains")) return .contains;
        if (std.mem.eql(u8, name, "inside")) return .inside;
        // Cat-16 — `index/rindex/indices` 1-arity. Mirrors legacy
        // `compileIndex/Rindex/Indices` (`compiler.zig:4456-4468`),
        // which delegate to `compileValueArgBuiltin1(<bid>)`. The new
        // compiler routes these via the `value_arg1_gen` class so
        // comma-arg generators work through the natural `comma`
        // SemOp emission.
        if (std.mem.eql(u8, name, "index")) return .index_;
        if (std.mem.eql(u8, name, "rindex")) return .rindex;
        if (std.mem.eql(u8, name, "indices")) return .indices;

        // Filter-arg builtins.
        if (std.mem.eql(u8, name, "sort_by")) return .sort_by;
        if (std.mem.eql(u8, name, "group_by")) return .group_by;
        if (std.mem.eql(u8, name, "min_by")) return .min_by;
        if (std.mem.eql(u8, name, "max_by")) return .max_by;
        if (std.mem.eql(u8, name, "unique_by")) return .unique_by;
        if (std.mem.eql(u8, name, "map_values")) return .map_values_;
        return null;
    }

    if (arity == 2) {
        if (std.mem.eql(u8, name, "pow")) return .pow_;
        if (std.mem.eql(u8, name, "atan2")) return .atan2_;
        if (std.mem.eql(u8, name, "remainder")) return .remainder_;
        if (std.mem.eql(u8, name, "hypot")) return .hypot_;
        if (std.mem.eql(u8, name, "scalb")) return .scalb_;
        if (std.mem.eql(u8, name, "scalbln")) return .scalbln_;
        if (std.mem.eql(u8, name, "ldexp")) return .ldexp_;
        if (std.mem.eql(u8, name, "drem")) return .drem_;
        if (std.mem.eql(u8, name, "setpath")) return .setpath;
        return null;
    }

    if (arity == 3) {
        if (std.mem.eql(u8, name, "fma")) return .fma_;
        return null;
    }

    return null;
}

// ── Cat-9 — user-function call emit ─────────────────────────────────────────
//
// Two layouts dispatched by the IS_INLINE flag in the IR's extra_data:
//
// INLINE (non-recursive) — `extra_data[node.extra+3] == CALL_USER_INLINE`:
//   span = [value_arg_0, ..., body_idx]
//
//   <value_arg_0> ; capture_variable(canonical_var_id_0)
//   <value_arg_1> ; capture_variable(canonical_var_id_1)
//   ...
//   <body>                                ; body emitted directly
//   pop_variable(canonical_var_id_N) ; ... ; pop_variable(canonical_var_id_0)
//
// RECURSIVE — `extra_data[node.extra+3] == CALL_USER_RECURSIVE`:
//   span = [value_arg_0, ..., value_arg_M]   (no body in span)
//
//   <value_arg_0> ; capture_variable(canonical_var_id_0)
//   ...
//   (first call only:)
//   jump end_placeholder
//   body_ip:
//   <body IR emitted once>                 ; body comes from entry.body_ir_root
//   return_function
//   end_placeholder = current IP
//   call_function(body_ip)
//   pop_variable(canonical_var_id_N) ; ... ; pop_variable(canonical_var_id_0)
//
// Both shapes preserve OUTER current — there are NO `pipe` instructions
// between the value-arg expressions and `capture_variable`, mirroring
// legacy's `expandFunctionCall` (`compiler.zig:1066-1123`).

const CALL_USER_INLINE: u32 = 1;
const CALL_USER_RECURSIVE: u32 = 0;

fn emitCallUser(em: *Emitter, node: ir.Node) EmitError!void {
    const slots = em.ir_obj.extra_data.items;
    const fn_id: u32 = slots[node.extra];
    // slots[node.extra + 1..2] = (name_offset, name_len)
    const flag = slots[node.extra + 3];

    std.debug.assert(fn_id < em.function_table.len);
    const entry = em.function_table[fn_id];

    // Collect canonical var_ids for value-args from the function entry.
    var value_var_ids: std.ArrayListUnmanaged(u32) = .{};
    defer value_var_ids.deinit(em.allocator);
    for (entry.params) |param| {
        if (!param.is_filter) try value_var_ids.append(em.allocator, param.var_id);
    }
    const num_value_args = value_var_ids.items.len;

    const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];

    if (flag == CALL_USER_INLINE) {
        // Span layout: [value_arg_0, ..., value_arg_M, body_idx].
        std.debug.assert(span.len == num_value_args + 1);
        const body_idx = span[span.len - 1];

        // Detect whether any value-arg contains a generator.  When true we
        // need the input-scope bracket (each arg must see the original `.`)
        // AND we must NOT emit pop_variable at the end.  pop_variable clears
        // the slot immediately after the first body execution; if the arg is
        // a generator the VM backtracks to an IP before the pop and
        // subsequent load_variable calls find a null slot (root.zig:853).
        // Omitting pop is safe because the INLINE body is re-lowered fresh
        // per call site — the canonical var_ids live only within this call's
        // generator lifecycle.  Non-generator calls retain pop_variable so
        // sequential calls to the same function don't see stale values.
        var has_generator_arg = false;
        for (span[0..num_value_args]) |arg_idx| {
            if (subtreeHasIterate(em.ir_obj, arg_idx)) {
                has_generator_arg = true;
                break;
            }
        }

        // Phase 1 — save input ONCE, then emit each value arg with input
        // reseeded before every evaluation. Without the bracket, arg_1
        // would evaluate against `it.current` as mutated by arg_0 (e.g.
        // when arg_0 is a generator like `.[]`). Each arg must see the
        // original `.` at the call site. This mirrors the `emitAsBind`
        // input-scope pattern (`src/compiler/emit.zig:emitAsBind`).
        if (has_generator_arg) {
            const input_var = em.allocVar();
            try emitInputScopeBracket(em, node, input_var);
            for (span[0..num_value_args], value_var_ids.items) |arg_idx, var_id| {
                try emitInputScopeReseed(em, node, input_var);
                try emitNode(em, arg_idx);
                try em.pushInstr(.capture_variable, .{ .index = @intCast(var_id) }, node);
            }
            // Restore original input for the body so filter-arg
            // substitutions (inlined in body_idx) see the correct `.`.
            try emitInputScopeReseed(em, node, input_var);
        } else if (num_value_args > 0) {
            // Non-generator path: emit args sequentially without input
            // bracket (preserves legacy behaviour for the common case).
            for (span[0..num_value_args], value_var_ids.items) |arg_idx, var_id| {
                try emitNode(em, arg_idx);
                try em.pushInstr(.capture_variable, .{ .index = @intCast(var_id) }, node);
            }
        }

        // Phase 2 — body inline.
        try emitNode(em, body_idx);

        // Phase 3 — pop value-arg variables in reverse order, but ONLY when
        // no arg is a generator.  With generator args the body may be
        // re-entered via backtrack; the pop would already have cleared the
        // slot on the first pass, causing load_variable to return null.
        if (!has_generator_arg) {
            var i: usize = num_value_args;
            while (i > 0) {
                i -= 1;
                try em.pushInstr(.pop_variable, .{ .index = @intCast(value_var_ids.items[i]) }, node);
            }
        }
        return;
    }

    // RECURSIVE shape — entry.is_recursive must be true; the body is
    // emitted ONCE (cached in `fn_body_ip[fn_id]`) and subsequent
    // call sites resolve to `call_function(body_ip)`.
    std.debug.assert(flag == CALL_USER_RECURSIVE);
    std.debug.assert(entry.is_recursive);
    std.debug.assert(span.len == num_value_args);

    // Same input-scope bracket as INLINE: each value-arg evaluates
    // against the original `.` at the call site, and the body entry
    // sees the original `.` too.
    if (num_value_args > 0) {
        const input_var = em.allocVar();
        try emitInputScopeBracket(em, node, input_var);
        for (span, value_var_ids.items) |arg_idx, var_id| {
            try emitInputScopeReseed(em, node, input_var);
            try emitNode(em, arg_idx);
            try em.pushInstr(.capture_variable, .{ .index = @intCast(var_id) }, node);
        }
        // Restore original input before calling the recursive body.
        try emitInputScopeReseed(em, node, input_var);
    }

    const cache = &em.fn_body_ip[fn_id];
    if (!cache.emitted) {
        const jump_pos: usize = em.instructions.items.len;
        try em.pushInstr(.jump, .{ .index = 0 }, node);

        const body_ip: u32 = @intCast(em.instructions.items.len);
        cache.body_ip = body_ip;
        cache.emitted = true;

        std.debug.assert(entry.body_ir_root != lower_mod.BODY_IR_NOT_LOWERED);
        try emitNode(em, entry.body_ir_root);
        try em.pushInstr(.return_function, .{ .none = {} }, node);

        em.instructions.items[jump_pos].operand = .{ .index = @intCast(em.instructions.items.len) };
    }

    try em.pushInstr(.call_function, .{ .index = @intCast(cache.body_ip) }, node);

    var i: usize = num_value_args;
    while (i > 0) {
        i -= 1;
        try em.pushInstr(.pop_variable, .{ .index = @intCast(value_var_ids.items[i]) }, node);
    }
}

// ── Cat-15 emission helpers ────────────────────────────────────────
//
// Each helper mirrors its legacy counterpart at
// `src/query/src/compiler.zig` byte-for-byte:
//   * label  → compileLabel  (3628)
//   * break  → parsePipe `.break_kw` (6245)
//   * while  → compileWhile  (3428)
//   * until  → compileUntil  (3495)
//
// Single source of truth: legacy bytecode shape is the contract;
// vm-equiv runs both backends through the same VM and byte-compares.

/// Emit `label $name | <body>`. The IR carries `var_id` in
/// `extra_data[node.extra]` and the body in `children[0]`. Mirrors
/// `compileLabel` (`compiler.zig:3628`):
///   label_begin(exit_ip)         — backpatched after body emission
///   capture_variable($var_id)
///   pipe                         — separates label header from body
///   <body>
///   exit_ip:                      — VM `handleBreak` jump target
///
/// No `label_end` / `pop_variable` are emitted because iterate loops
/// would re-execute them on every backtracking pass and prematurely
/// clear the label frame + break-token variable. Legacy makes the
/// same intentional omission (`compiler.zig:3661-3667`); cleanup
/// happens via `handleBreak` (on break) or per-record `reset()`
/// (no break).
fn emitLabel(em: *Emitter, node: ir.Node) EmitError!void {
    const slots = em.ir_obj.extra_data.items;
    const var_id: u32 = slots[node.extra];
    const body_idx = node.children[0];

    // label_begin with placeholder exit_ip (backpatched below).
    const label_begin_ip = em.instructions.items.len;
    try em.pushInstr(.label_begin, .{ .index = 0 }, node);

    // capture_variable($name) — store break token into the label var.
    try em.pushInstr(.capture_variable, .{ .index = var_id }, node);

    // pipe — separates the label header from the body. Mirrors legacy
    // `compileLabel`'s `try ctx.emit(.pipe, ...)` after the
    // `capture_variable` (`compiler.zig:3655`).
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    // Body.
    try emitNode(em, body_idx);

    // Backpatch label_begin's exit_ip to the instruction past the body.
    em.instructions.items[label_begin_ip].operand = .{
        .index = @intCast(em.instructions.items.len),
    };
}

/// Emit `break $name`. The IR carries `var_id` in
/// `extra_data[node.extra]`; lookup-time validation already confirmed
/// the var is a label binding (see `lookupLabelVar` in `lower.zig`).
/// Mirrors legacy `parsePipe` `.break_kw` arm (`compiler.zig:6245`):
///   load_variable($var_id)
///   break_op
fn emitBreak(em: *Emitter, node: ir.Node) error{OutOfMemory}!void {
    const slots = em.ir_obj.extra_data.items;
    const var_id: u32 = slots[node.extra];
    try em.pushInstr(.load_variable, .{ .index = var_id }, node);
    try em.pushInstr(.break_op, .{ .none = {} }, node);
}

/// Emit `while(cond; update)`. The IR carries `children[0]=cond` and
/// `children[1]=update`. Mirrors legacy `compileWhile`
/// (`compiler.zig:3428`).
///
/// The naive imperative approach (`yield_output ; jmp → loop_top`) breaks
/// when `while` is wrapped in an arr_ctor element fork, because `yield_output`
/// sees an active fork above the enclosing collect frame's `outer_fork_depth`
/// and takes the generator-backtrack path instead of the imperative-continue
/// path, causing only the first iteration to be collected.
///
/// Fix: establish a dedicated inner `array_collect_start/end` frame around the
/// imperative loop. Inside that frame, the arr_ctor element fork is AT
/// `outer_fork_depth` (not above it), so `yield_output` sees
/// `fork_stack.len == ACE_w.outer_fork_depth` and takes the imperative path.
/// After the inner frame finalizes (via backtrack when cond is false), `each`
/// iterates the collected array as a generator, allowing the outer arr_ctor's
/// fork chain to proceed normally.
///
/// Layout:
///   array_collect_start(ACE_w)   ; inner frame — outer_fork_depth = current fork_stack.len
///   loop:
///     save_input
///     <cond>
///     jump_if_false → L_cond_false
///     restore_input              ; cond true: restore before yielding
///     yield_output               ; imperative: fork_stack.len == ACE_w.outer_fork_depth
///     <update>                   ; advance current value
///     pipe                       ; transfer updated value to current
///     jmp → loop
///   L_cond_false:
///     restore_input              ; balance save_input
///     backtrack                  ; signals ACE_w finalization via step() loop
///   array_collect_end(ACE_w)     ; builds collected [v0, v1, ...]
///   pipe                         ; current = array
///   each                         ; iterate as generator for downstream
fn emitWhile(em: *Emitter, node: ir.Node) EmitError!void {
    const cond_idx = node.children[0];
    const update_idx = node.children[1];

    // Establish an inner collect frame. Inside this frame, the imperative
    // while loop runs; yield_output takes the imperative (ip+1) path because
    // fork_stack.len == ACE_w.outer_fork_depth (any element fork from an
    // enclosing arr_ctor is counted in outer_fork_depth, not above it).
    const ace_start_pos = em.instructions.items.len;
    try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);

    const loop_top: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(.save_input, .{ .none = {} }, node);
    try emitNode(em, cond_idx);

    // jump_if_false → L_cond_false (placeholder; backpatched below).
    const jif_pos = em.instructions.items.len;
    try em.pushInstr(.jump_if_false, .{ .index = 0 }, node);

    // Cond true: restore current, yield it, apply update, transfer to current, loop.
    try em.pushInstr(.restore_input, .{ .none = {} }, node);
    try em.pushInstr(.yield_output, .{ .none = {} }, node);
    try emitNode(em, update_idx);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.jump, .{ .index = loop_top }, node);

    // L_cond_false: cond is false — balance save_input and signal ACE_w
    // finalization by backtracking. step() will finalize ACE_w and advance
    // ip to array_collect_end + 1.
    const l_cond_false: u32 = @intCast(em.instructions.items.len);
    em.instructions.items[jif_pos].operand = .{ .index = l_cond_false };
    try em.pushInstr(.restore_input, .{ .none = {} }, node);
    try em.pushInstr(.backtrack, .{ .none = {} }, node);

    // array_collect_end — ACE_w end. Backpatch start with this IP.
    const ace_end_pos: u32 = @intCast(em.instructions.items.len);
    em.instructions.items[ace_start_pos].operand = .{ .index = ace_end_pos };
    try em.pushInstr(.array_collect_end, .{ .none = {} }, node);

    // Transfer collected array to current, then expose as generator.
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.each, .{ .none = {} }, node);
}

/// Emit `until(cond; update)`. The IR carries `children[0]=cond` and
/// `children[1]=update`. Mirrors legacy `compileUntil`
/// (`compiler.zig:3495`):
///   loop_top:
///     save_input
///     <cond>
///     jump_if_false → loop_body
///     restore_input                ; true path: cond met, exit
///     jump → loop_done
///   loop_body:
///     restore_input                ; false path: keep iterating
///     <update>
///     pipe
///     jump → loop_top
///   loop_done:
///     push_current                 ; place final value on stack
fn emitUntil(em: *Emitter, node: ir.Node) EmitError!void {
    const cond_idx = node.children[0];
    const update_idx = node.children[1];

    // loop_top:
    const loop_top: u32 = @intCast(em.instructions.items.len);

    try em.pushInstr(.save_input, .{ .none = {} }, node);
    try emitNode(em, cond_idx);

    // jump_if_false → loop_body (placeholder).
    const jif_pos = em.instructions.items.len;
    try em.pushInstr(.jump_if_false, .{ .index = 0 }, node);

    // True path: cond met, restore + jump to done.
    try em.pushInstr(.restore_input, .{ .none = {} }, node);
    const jmp_done_pos = em.instructions.items.len;
    try em.pushInstr(.jump, .{ .index = 0 }, node);

    // loop_body:
    const loop_body: u32 = @intCast(em.instructions.items.len);
    em.instructions.items[jif_pos].operand = .{ .index = loop_body };

    // False path: restore, apply update, loop back.
    try em.pushInstr(.restore_input, .{ .none = {} }, node);
    try emitNode(em, update_idx);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try em.pushInstr(.jump, .{ .index = loop_top }, node);

    // loop_done:
    const loop_done: u32 = @intCast(em.instructions.items.len);
    em.instructions.items[jmp_done_pos].operand = .{ .index = loop_done };

    try em.pushInstr(.push_current, .{ .none = {} }, node);
}

// ── Cat-4 — `as_bind` wrapper ──────────────────────────────────────
//
// Emit `expr as PATTERN | body` mirroring legacy `parseLogical` +
// `parsePipe` (`compiler.zig:2499-2517`). Layout:
//   push_current
//   capture_variable($orig)  ; save original input (survives fork)
//   <expr>                   ; current = expr_result (generators OK)
//   <destructure ladder>     ; pops current/vstack into pattern vars
//   load_variable($orig)
//   pipe                     ; current = original input restored
//   <body>
//
// The original input is saved in a variable (not the if_stack) so it
// survives generator backtracking: fork frames do not restore
// variable_store, meaning $orig persists across every backtrack
// from the generator in <expr>.  This fixes the bug where body
// inherited the mutated `it.current` from the generator expression
// (e.g. `.[] as $x | [$x == .[]]` — the inner `.[...]` was
// iterating the single element $x instead of the original array).
fn emitAsBind(em: *Emitter, node: ir.Node) EmitError!void {
    std.debug.assert(node.span_len == 3);
    const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
    const expr_idx = span[0];
    const dx_idx = span[1];
    const body_idx = span[2];

    const orig_var = em.allocVar();
    // Capture original input before expr so body always sees the
    // correct `.`.  Variable survives fork/backtrack.
    try em.pushInstr(.push_current, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = orig_var }, node);

    try emitNode(em, expr_idx);
    try emitNode(em, dx_idx);

    // Restore original input for body.
    try em.pushInstr(.load_variable, .{ .index = orig_var }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    try emitNode(em, body_idx);
}

// ── Cat-14 — `reduce` ──────────────────────────────────────────────
//
// Mirror legacy `compileReduce` (`src/query/src/compiler.zig:3965`)
// byte-for-byte. The IR carries (expr, pattern, init, update) in span
// + (saved_input_id, acc_id) in extra_data.
//
// Layout:
//   push_current
//   capture_variable($saved)
//   <INIT>
//   capture_variable($acc)
//   load_variable($saved)
//   pipe                       ; current = original input
//   fork L_done                ; sentinel: EXPR exhaustion
//     <EXPR>                   ; generators push their own forkpoints
//     <pattern destructure>    ; bind EXPR result into pattern vars
//     load_variable($acc)
//     pipe                     ; current = accumulator
//     <UPDATE>
//     capture_variable($acc)
//     backtrack                ; advance EXPR via fork stack
//   L_done:
//   load_variable($acc)        ; push final acc as result
//   pop pattern vars (reverse decl order)
//   pop_variable($acc)
//
// $saved is intentionally NOT popped — if INIT is a generator (e.g.
// `0,1`), the comma fork backtracks after pop and load_variable($saved)
// must still find the saved value on the second INIT pass (legacy
// note at compiler.zig:4063-4065).
fn emitReduce(em: *Emitter, node: ir.Node) EmitError!void {
    std.debug.assert(node.span_len == 4);
    const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
    const expr_idx = span[0];
    const pattern_idx = span[1];
    const init_idx = span[2];
    const update_idx = span[3];

    const slots = em.ir_obj.extra_data.items;
    const saved_input_id: i64 = @intCast(slots[node.extra]);
    const acc_id: i64 = @intCast(slots[node.extra + 1]);

    try em.pushInstr(.push_current, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = saved_input_id }, node);

    try emitNode(em, init_idx);
    try em.pushInstr(.capture_variable, .{ .index = acc_id }, node);

    try em.pushInstr(.load_variable, .{ .index = saved_input_id }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    const fork_pos = em.instructions.items.len;
    try em.pushInstr(.fork, .{ .index = 0 }, node);

    try emitNode(em, expr_idx);
    try emitNode(em, pattern_idx);
    try em.pushInstr(.load_variable, .{ .index = acc_id }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try emitNode(em, update_idx);
    try em.pushInstr(.capture_variable, .{ .index = acc_id }, node);
    try em.pushInstr(.backtrack, .{ .none = {} }, node);

    const l_done: u32 = @intCast(em.instructions.items.len);
    em.instructions.items[fork_pos].operand = .{ .index = l_done };

    try em.pushInstr(.load_variable, .{ .index = acc_id }, node);

    // Cleanup: pop pattern vars (reverse declaration order) + acc.
    var pvar_ids: std.ArrayListUnmanaged(u32) = .{};
    defer pvar_ids.deinit(em.allocator);
    try collectPatternVarIdsFromIR(em.ir_obj, pattern_idx, &pvar_ids, em.allocator);
    var pi = pvar_ids.items.len;
    while (pi > 0) {
        pi -= 1;
        try em.pushInstr(.pop_variable, .{ .index = @intCast(pvar_ids.items[pi]) }, node);
    }
    try em.pushInstr(.pop_variable, .{ .index = acc_id }, node);
}

// ── Cat-14 — `foreach` ─────────────────────────────────────────────
//
// Mirror legacy `compileForeach` (`src/query/src/compiler.zig:4121`).
// 2-arg form (no extract): outputs accumulator after each UPDATE.
// 3-arg form (extract): outputs EXTRACT(accumulator) after each UPDATE.
// Layout (2-arg form):
//   push_current
//   capture_variable($saved)
//   <INIT>
//   capture_variable($acc)
//   load_variable($saved)
//   pipe                       ; current = original input
//   array_collect_start(ACE)   ; collect intermediate outputs
//   fork L_done
//     <EXPR>
//     <pattern destructure>
//     load_variable($acc)
//     pipe
//     <UPDATE>
//     capture_variable($acc)
//     load_variable($acc)
//     yield_output             ; buffer intermediate acc in ACE
//     backtrack
//   L_done:
//   ACE: array_collect_end
//   pipe                       ; current = collected array
//   pop pattern vars + acc
//   each                       ; iterate as generator for downstream
//
// 3-arg form replaces the inner output section with:
//   capture_variable($acc); load_variable($acc); pipe; <EXTRACT>;
//   yield_output; backtrack
fn emitForeach(em: *Emitter, node: ir.Node) EmitError!void {
    std.debug.assert(node.span_len == 4 or node.span_len == 5);
    const span = em.ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
    const expr_idx = span[0];
    const pattern_idx = span[1];
    const init_idx = span[2];
    const update_idx = span[3];
    const has_extract = node.span_len == 5;
    const extract_idx: u32 = if (has_extract) span[4] else 0;

    const slots = em.ir_obj.extra_data.items;
    const saved_input_id: i64 = @intCast(slots[node.extra]);
    const acc_id: i64 = @intCast(slots[node.extra + 1]);

    try em.pushInstr(.push_current, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = saved_input_id }, node);

    try emitNode(em, init_idx);
    try em.pushInstr(.capture_variable, .{ .index = acc_id }, node);

    try em.pushInstr(.load_variable, .{ .index = saved_input_id }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);

    const ace_start = em.instructions.items.len;
    try em.pushInstr(.array_collect_start, .{ .index = 0 }, node);

    const fork_pos = em.instructions.items.len;
    try em.pushInstr(.fork, .{ .index = 0 }, node);

    try emitNode(em, expr_idx);
    try emitNode(em, pattern_idx);
    try em.pushInstr(.load_variable, .{ .index = acc_id }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
    try emitNode(em, update_idx);
    try em.pushInstr(.capture_variable, .{ .index = acc_id }, node);

    if (has_extract) {
        try em.pushInstr(.load_variable, .{ .index = acc_id }, node);
        try em.pushInstr(.pipe, .{ .none = {} }, node);
        try emitNode(em, extract_idx);
        try em.pushInstr(.yield_output, .{ .none = {} }, node);
    } else {
        try em.pushInstr(.load_variable, .{ .index = acc_id }, node);
        try em.pushInstr(.yield_output, .{ .none = {} }, node);
    }

    try em.pushInstr(.backtrack, .{ .none = {} }, node);

    const l_done: u32 = @intCast(em.instructions.items.len);
    em.instructions.items[fork_pos].operand = .{ .index = l_done };

    const ace_end: u32 = @intCast(em.instructions.items.len);
    try em.pushInstr(.array_collect_end, .{ .none = {} }, node);
    em.instructions.items[ace_start].operand = .{ .index = ace_end };

    try em.pushInstr(.pipe, .{ .none = {} }, node);

    // Pop pattern vars + acc BEFORE the `each` generator (legacy line
    // 4248-4262: cleanup must happen once, not per element).
    var pvar_ids: std.ArrayListUnmanaged(u32) = .{};
    defer pvar_ids.deinit(em.allocator);
    try collectPatternVarIdsFromIR(em.ir_obj, pattern_idx, &pvar_ids, em.allocator);
    var pi = pvar_ids.items.len;
    while (pi > 0) {
        pi -= 1;
        try em.pushInstr(.pop_variable, .{ .index = @intCast(pvar_ids.items[pi]) }, node);
    }
    try em.pushInstr(.pop_variable, .{ .index = acc_id }, node);

    try em.pushInstr(.each, .{ .none = {} }, node);
}

/// Collect pattern var_ids in declaration order from a `destructure`
/// IR subtree. Used by `emitReduce` / `emitForeach` cleanup. Mirrors
/// legacy `collectPatternVarIds` (`src/query/src/compiler.zig:565`).
fn collectPatternVarIdsFromIR(
    ir_obj: ir.IR,
    node_idx: u32,
    out: *std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
) error{OutOfMemory}!void {
    const node = ir_obj.nodes.items[node_idx];
    if (node.op != .destructure) return;
    const slots = ir_obj.extra_data.items;
    const kind: ir.PatternKind = @enumFromInt(slots[node.extra]);
    switch (kind) {
        .as => try out.append(allocator, slots[node.extra + 3]),
        .array => {
            const span = ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            for (span) |sub| try collectPatternVarIdsFromIR(ir_obj, sub, out, allocator);
        },
        .object => {
            const span = ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            // Pairs (key, sub-pattern); only sub-patterns carry vars.
            var pi: usize = 1;
            while (pi < span.len) : (pi += 2) {
                try collectPatternVarIdsFromIR(ir_obj, span[pi], out, allocator);
            }
        },
        .alt_bind => {
            // Reduce/foreach patterns never use `?//` — alt_bind only
            // appears at top-level as_pattern via destruct_alt. Recurse
            // defensively.
            const span = ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
            for (span) |sub| try collectPatternVarIdsFromIR(ir_obj, sub, out, allocator);
        },
    }
}

// ── Input-scope bracket helpers ──────────────────────────────────────────────
//
// These two helpers implement the input-scope bracketing pattern: capture
// `it.current` (the active `.`) into a fresh variable before an expression
// that may clobber `.` (e.g. a generator or a multi-arg call), then reseed
// `it.current` from the saved variable before consuming the captured value.
//
// emitInputScopeBracket: emits `push_current ; capture_variable(var_id)`
//   Call once before the expression. `var_id` must come from `em.allocVar()`.
//
// emitInputScopeReseed: emits `load_variable(var_id) ; pipe`
//   Call before each consumer that must see the original `.`.
//
// Together they replace any save_input/restore_input pair that straddles a
// fork-point (generator, comma, etc.) — `if_stack` is reset on backtrack, so
// a save_input pushed before a generator cond is popped before the else-arm's
// restore_input fires, causing a VM panic (root.zig:1292).  Variable store
// is NOT reset on backtrack, so the variable survives across every fork.

/// Emit `push_current ; capture_variable(var_id)`. Captures the current `.`
/// into a variable that survives fork/backtrack. Pair with `emitInputScopeReseed`.
fn emitInputScopeBracket(em: *Emitter, node: ir.Node, var_id: u32) EmitError!void {
    try em.pushInstr(.push_current, .{ .none = {} }, node);
    try em.pushInstr(.capture_variable, .{ .index = var_id }, node);
}

/// Emit `load_variable(var_id) ; pipe`. Restores `it.current` from the
/// variable captured by `emitInputScopeBracket`. Safe across fork-backtrack.
fn emitInputScopeReseed(em: *Emitter, node: ir.Node, var_id: u32) EmitError!void {
    try em.pushInstr(.load_variable, .{ .index = var_id }, node);
    try em.pushInstr(.pipe, .{ .none = {} }, node);
}

/// Return true if the IR subtree rooted at `node_idx` contains any
/// `.iterate` node (i.e., the expression can generate multiple values
/// via `each` by iterating `it.current`).  Used by the binary-op
/// emitter to select between the safe variable-isolation path (needed
/// when generators are present) and the original value-stack path
/// (safe for recursive functions where fixed variable IDs would be
/// clobbered by re-entrant calls).
fn subtreeHasIterate(ir_obj: ir.IR, node_idx: u32) bool {
    const node = ir_obj.nodes.items[node_idx];
    if (node.op == .iterate) return true;
    // Two fixed children.
    if (node.children[0] != 0 and subtreeHasIterate(ir_obj, node.children[0])) return true;
    if (node.children[1] != 0 and subtreeHasIterate(ir_obj, node.children[1])) return true;
    // Variable-arity span children.
    const span = ir_obj.extra_children.items[node.span_start .. node.span_start + node.span_len];
    for (span) |child| {
        if (child != 0 and subtreeHasIterate(ir_obj, child)) return true;
    }
    return false;
}
