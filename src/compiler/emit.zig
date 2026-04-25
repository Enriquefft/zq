//! IR → bytecode emission — Phase 2R / R3.
//!
//! Phase 7 (Cluster B) covers category 1 ops (`load_const`, `identity`,
//! `recurse`, `neg`, `not`, `call_builtin`/type). Other ops surface as
//! `error.NewCompilerNotImplemented`; the harness reports SKIP for them.
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
/// allocs; `NewCompilerNotImplemented` for ops outside category 1.
pub const EmitError = error{
    OutOfMemory,
    NewCompilerNotImplemented,
};

/// Lower-half of `Operand.str_ref` — used for `push_string` ops where
/// the operand encodes a slice into the final `string_buf`. We emit the
/// raw byte offsets directly, no special encoding.
const StringRef = types_mod.Tape.StringRef;

/// Emit bytecode from `ir_obj`. The emitter walks the IR node array in
/// order — Phase 7's lowering produces a post-order traversal so the
/// IR sequence already matches bytecode emission order. Variable-arity
/// ops (which span `extra_children`) will need an explicit traversal in
/// later categories; category 1 ops are fixed-arity (≤1 child) so the
/// linear walk suffices.
pub fn emit(
    ir_obj: ir.IR,
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
    //   2. Newly-emitted strings (none for category 1) — would append
    //      after the IR's bytes.
    //
    // Category 1 only owns `load_const`'s string-literal payload, which
    // is already in `ir_obj.string_buf`. Other categories will append
    // here as they emit `push_string`, `load_key`, etc.
    var string_buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer string_buf.deinit(allocator);
    try string_buf.appendSlice(allocator, ir_obj.string_buf.items);

    // Emit one bytecode instruction per IR node in linear order. The
    // post-order traversal of lowering means children appear before
    // their parent in `ir_obj.nodes` — matches the VM's stack-based
    // evaluation semantics exactly (push operand, then op).
    for (ir_obj.nodes.items) |node| {
        try emitNode(&instructions, &source_map, ir_obj, node, allocator);
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

    // Function table: empty (category 1 has no UDFs). Matches legacy
    // shape: `function_defs` allocated as zero-length slice via the
    // same allocator. The legacy compiler comments this is "kept for
    // interface compatibility" since bodies are inline-expanded.
    const function_defs = try allocator.alloc(types_mod.FunctionDef, 0);
    errdefer allocator.free(function_defs);

    const ext_var_ids = try allocator.alloc(u32, 0);
    errdefer allocator.free(ext_var_ids);

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
    node: ir.Node,
    allocator: std.mem.Allocator,
) EmitError!void {
    switch (node.op) {
        // ── load_const dispatch ──────────────────────────────────
        // Encoding contract (in sync with `lower.zig`):
        //   slot[extra] = literal-kind discriminant
        //     0 = null
        //     1 = false
        //     2 = true
        //     3 = int   (slot[extra+1] = lo32, slot[extra+2] = hi32)
        //     4 = float (slot[extra+1] = lo32, slot[extra+2] = hi32)
        //     5 = string (slot[extra+1] = offset, slot[extra+2] = len)
        .load_const => {
            const slots = ir_obj.extra_data.items;
            const tag = slots[node.extra];
            switch (tag) {
                0 => try push(instructions, source_map, .push_null, .{ .none = {} }, node, allocator),
                1 => try push(instructions, source_map, .push_bool, .{ .bool = false }, node, allocator),
                2 => try push(instructions, source_map, .push_bool, .{ .bool = true }, node, allocator),
                3 => {
                    const lo: u64 = slots[node.extra + 1];
                    const hi: u64 = slots[node.extra + 2];
                    const u: u64 = lo | (hi << 32);
                    const n: i64 = @bitCast(u);
                    try push(instructions, source_map, .push_int, .{ .int = n }, node, allocator);
                },
                4 => {
                    const lo: u64 = slots[node.extra + 1];
                    const hi: u64 = slots[node.extra + 2];
                    const u: u64 = lo | (hi << 32);
                    const f: f64 = @bitCast(u);
                    try push(instructions, source_map, .push_float, .{ .float = f }, node, allocator);
                },
                5 => {
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
                else => return error.NewCompilerNotImplemented,
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

        .neg => try push(instructions, source_map, .negate, .{ .none = {} }, node, allocator),

        .not => {
            // Legacy lowers `not` as a zero-arg builtin call. Match
            // VM-semantics by emitting the same bytecode shape — the
            // VM reads `BuiltinId.not_` and runs the builtin
            // (a single-value boolean negation). Plan §1.2: same
            // output stream + same error kinds, not a bytecode-shape
            // match — but reusing the legacy bytecode keeps the
            // VM-side identical and preserves the path-broken
            // bookkeeping inside `breaksPath`.
            try push(
                instructions,
                source_map,
                .call_builtin,
                .{ .index = @intFromEnum(types_mod.BuiltinId.not_) },
                node,
                allocator,
            );
        },

        .call_builtin => {
            // Category 1 hits this only for `type` (the brief assigns
            // `type` to category 1 alongside `not`). The IR's
            // `extra_data[extra]` and `extra_data[extra+1]` carry the
            // `(offset, len)` of the builtin name in
            // `ir_obj.string_buf`. We resolve that to a `BuiltinId`
            // and emit `call_builtin`.
            const slots = ir_obj.extra_data.items;
            const offset: u32 = slots[node.extra];
            const len: u32 = slots[node.extra + 1];
            const name = ir_obj.string_buf.items[offset .. offset + len];

            // Only a hardcoded category-1 set is allowed at this
            // stage; anything else means lowering admitted an op the
            // emitter doesn't know yet.
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
