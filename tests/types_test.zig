const std = @import("std");
const types = @import("types");

const Tape = types.Tape;
const Value = types.Value;
const Instruction = types.Instruction;

// ─── Tape ────────────────────────────────────────────────────────────────────

test "Tape.getString: resolves StringRef to bytes" {
    const buf = "helloworld";
    const tape = Tape{
        .entries = &.{},
        .string_buf = buf,
    };
    const ref = Tape.StringRef{ .offset = 5, .len = 5 };
    try std.testing.expectEqualStrings("world", tape.getString(ref));
}

test "Tape.Tag: all variants are distinct" {
    const tags = [_]Tape.Tag{
        .object_start, .object_end,
        .array_start,  .array_end,
        .key,          .string,
        .int,          .float,
        .true_val,     .false_val,
        .null_val,
    };
    // Ensure no two adjacent tags share the same backing integer.
    for (0..tags.len - 1) |i| {
        try std.testing.expect(@intFromEnum(tags[i]) != @intFromEnum(tags[i + 1]));
    }
}

// ─── Value ───────────────────────────────────────────────────────────────────

test "Value: null round-trips through union tag" {
    const v = Value{ .null_val = {} };
    try std.testing.expect(v == .null_val);
}

test "Value: bool values" {
    const t = Value{ .bool_val = true };
    const f = Value{ .bool_val = false };
    try std.testing.expect(t.bool_val == true);
    try std.testing.expect(f.bool_val == false);
}

test "Value: int and float" {
    const vi = Value{ .int = -42 };
    const vf = Value{ .float = 3.14 };
    try std.testing.expectEqual(@as(i64, -42), vi.int);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), vf.float, 0.001);
}

test "Value: string holds slice" {
    const s = "hello";
    const v = Value{ .string = s };
    try std.testing.expectEqualStrings("hello", v.string);
}

// ─── Instruction ─────────────────────────────────────────────────────────────

test "Instruction: load_key with string operand" {
    const inst = Instruction{
        .op = .load_key,
        .operand = .{ .string = "foo" },
    };
    try std.testing.expectEqual(Instruction.Op.load_key, inst.op);
    try std.testing.expectEqualStrings("foo", inst.operand.string);
}

test "Instruction: load_index with index operand" {
    const inst = Instruction{
        .op = .load_index,
        .operand = .{ .index = 7 },
    };
    try std.testing.expectEqual(Instruction.Op.load_index, inst.op);
    try std.testing.expectEqual(@as(u32, 7), inst.operand.index);
}

test "Instruction: identity with no operand" {
    const inst = Instruction{
        .op = .identity,
        .operand = .{ .none = {} },
    };
    try std.testing.expectEqual(Instruction.Op.identity, inst.op);
}

// ─── Format ──────────────────────────────────────────────────────────────────

test "Format: all variants accessible" {
    const fmts = [_]types.Format{ .pretty, .compact, .raw, .jsonl };
    try std.testing.expectEqual(@as(usize, 4), fmts.len);
}
