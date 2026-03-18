const std = @import("std");
const types = @import("types");

const Tape = types.Tape;
const Value = types.Value;
const Instruction = types.Instruction;
const RuntimeTape = types.RuntimeTape;
const formatJqFloat = types.formatJqFloat;

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

test "Instruction: load_key with str_ref operand" {
    const inst = Instruction{
        .op = .load_key,
        .operand = .{ .str_ref = .{ .offset = 0, .len = 3 } },
    };
    try std.testing.expectEqual(Instruction.Op.load_key, inst.op);
    try std.testing.expectEqual(@as(u32, 0), inst.operand.str_ref.offset);
    try std.testing.expectEqual(@as(u32, 3), inst.operand.str_ref.len);
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

// ─── RuntimeTape.copySpan ────────────────────────────────────────────────────

test "copySpan: empty range produces no entries" {
    const t = Tape{ .entries = &.{}, .string_buf = "" };
    var rt = try RuntimeTape.init(std.testing.allocator);
    defer rt.deinit(std.testing.allocator);
    try rt.copySpan(t, 0, 0, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), rt.entries.items.len);
}

test "copySpan: flat scalars copy correctly" {
    const entries = [_]Tape.Entry{
        .{ .tag = .int, .payload = .{ .int = 42 } },
        .{ .tag = .string, .payload = .{ .string = .{ .offset = 0, .len = 5 } } },
        .{ .tag = .true_val, .payload = .{ .none = {} } },
    };
    const t = Tape{ .entries = &entries, .string_buf = "hello" };

    var rt = try RuntimeTape.init(std.testing.allocator);
    defer rt.deinit(std.testing.allocator);
    try rt.copySpan(t, 0, 3, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), rt.entries.items.len);
    try std.testing.expectEqual(Tape.Tag.int, rt.entries.items[0].tag);
    try std.testing.expectEqual(@as(i64, 42), rt.entries.items[0].payload.int);
    try std.testing.expectEqual(Tape.Tag.string, rt.entries.items[1].tag);
    const rt_tape = rt.asTape();
    try std.testing.expectEqualStrings("hello", rt_tape.getString(rt.entries.items[1].payload.string));
    try std.testing.expectEqual(Tape.Tag.true_val, rt.entries.items[2].tag);
}

test "copySpan: simple object skip pointer is rebased" {
    // {"a":1} → object_start(skip=4), key("a"), int(1), object_end
    const entries = [_]Tape.Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 4 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = Tape{ .entries = &entries, .string_buf = "a" };

    var rt = try RuntimeTape.init(std.testing.allocator);
    defer rt.deinit(std.testing.allocator);
    try rt.copySpan(t, 0, 4, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), rt.entries.items.len);
    // base=0, orig_skip=4, start=0 → rebased skip = 0+(4-0) = 4
    try std.testing.expectEqual(@as(u32, 4), rt.entries.items[0].payload.skip);
    const rt_tape = rt.asTape();
    try std.testing.expectEqualStrings("a", rt_tape.getString(rt.entries.items[1].payload.string));
}

test "copySpan: simple array skip pointer is rebased" {
    // [1,2,3] → array_start(skip=5), int(1), int(2), int(3), array_end
    const entries = [_]Tape.Entry{
        .{ .tag = .array_start, .payload = .{ .skip = 5 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .int, .payload = .{ .int = 2 } },
        .{ .tag = .int, .payload = .{ .int = 3 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
    };
    const t = Tape{ .entries = &entries, .string_buf = "" };

    var rt = try RuntimeTape.init(std.testing.allocator);
    defer rt.deinit(std.testing.allocator);
    try rt.copySpan(t, 0, 5, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), rt.entries.items.len);
    try std.testing.expectEqual(@as(u32, 5), rt.entries.items[0].payload.skip);
}

test "copySpan: nested containers have correct skip pointers" {
    // {"a":[1,2],"b":{"c":3}}
    //  0: object_start(skip=12)
    //  1: key "a"
    //  2: array_start(skip=6)
    //  3: int 1
    //  4: int 2
    //  5: array_end
    //  6: key "b"
    //  7: object_start(skip=11)
    //  8: key "c"
    //  9: int 3
    // 10: object_end
    // 11: object_end
    const sb = "abc";
    const entries = [_]Tape.Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 12 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .array_start, .payload = .{ .skip = 6 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .int, .payload = .{ .int = 2 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 1, .len = 1 } } },
        .{ .tag = .object_start, .payload = .{ .skip = 11 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 2, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 3 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = Tape{ .entries = &entries, .string_buf = sb };

    var rt = try RuntimeTape.init(std.testing.allocator);
    defer rt.deinit(std.testing.allocator);
    try rt.copySpan(t, 0, 12, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 12), rt.entries.items.len);
    try std.testing.expectEqual(@as(u32, 12), rt.entries.items[0].payload.skip);
    try std.testing.expectEqual(@as(u32, 6), rt.entries.items[2].payload.skip);
    try std.testing.expectEqual(@as(u32, 11), rt.entries.items[7].payload.skip);
    const rt_tape = rt.asTape();
    try std.testing.expectEqualStrings("a", rt_tape.getString(rt.entries.items[1].payload.string));
    try std.testing.expectEqualStrings("b", rt_tape.getString(rt.entries.items[6].payload.string));
    try std.testing.expectEqualStrings("c", rt_tape.getString(rt.entries.items[8].payload.string));
}

test "copySpan: deeply nested arrays (100 levels) — no stack overflow" {
    const depth = 100;
    const n_entries = depth * 2;
    var entries: [n_entries]Tape.Entry = undefined;
    for (0..depth) |i| {
        entries[i] = .{ .tag = .array_start, .payload = .{ .skip = @as(u32, @intCast(n_entries - i)) } };
    }
    for (depth..n_entries) |i| {
        entries[i] = .{ .tag = .array_end, .payload = .{ .none = {} } };
    }
    const t = Tape{ .entries = &entries, .string_buf = "" };

    var rt = try RuntimeTape.init(std.testing.allocator);
    defer rt.deinit(std.testing.allocator);
    try rt.copySpan(t, 0, n_entries, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, n_entries), rt.entries.items.len);
    for (0..depth) |i| {
        try std.testing.expectEqual(
            @as(u32, @intCast(n_entries - i)),
            rt.entries.items[i].payload.skip,
        );
    }
}

test "copySpan: partial span copies sub-range with rebased skips" {
    // Source tape: {"a":[1,2],"b":3} — copy just the inner array [1,2]
    const entries = [_]Tape.Entry{
        .{ .tag = .object_start, .payload = .{ .skip = 9 } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 0, .len = 1 } } },
        .{ .tag = .array_start, .payload = .{ .skip = 6 } },
        .{ .tag = .int, .payload = .{ .int = 1 } },
        .{ .tag = .int, .payload = .{ .int = 2 } },
        .{ .tag = .array_end, .payload = .{ .none = {} } },
        .{ .tag = .key, .payload = .{ .string = .{ .offset = 1, .len = 1 } } },
        .{ .tag = .int, .payload = .{ .int = 3 } },
        .{ .tag = .object_end, .payload = .{ .none = {} } },
    };
    const t = Tape{ .entries = &entries, .string_buf = "ab" };

    var rt = try RuntimeTape.init(std.testing.allocator);
    defer rt.deinit(std.testing.allocator);
    // Copy just the inner array [1,2] at indices [2,6)
    try rt.copySpan(t, 2, 6, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), rt.entries.items.len);
    // array_start at index 0, rebased: base=0, orig_skip=6, start=2 → 0+(6-2) = 4
    try std.testing.expectEqual(Tape.Tag.array_start, rt.entries.items[0].tag);
    try std.testing.expectEqual(@as(u32, 4), rt.entries.items[0].payload.skip);
    try std.testing.expectEqual(@as(i64, 1), rt.entries.items[1].payload.int);
    try std.testing.expectEqual(@as(i64, 2), rt.entries.items[2].payload.int);
    try std.testing.expectEqual(Tape.Tag.array_end, rt.entries.items[3].tag);
}

test "copySpan: strings are re-interned at new offsets" {
    const entries = [_]Tape.Entry{
        .{ .tag = .string, .payload = .{ .string = .{ .offset = 0, .len = 3 } } },
        .{ .tag = .string, .payload = .{ .string = .{ .offset = 3, .len = 3 } } },
    };
    const t = Tape{ .entries = &entries, .string_buf = "foobar" };

    var rt = try RuntimeTape.init(std.testing.allocator);
    defer rt.deinit(std.testing.allocator);

    // Pre-populate runtime tape string buffer so copied offsets differ from source
    _ = try rt.internString(std.testing.allocator, "prefix");

    try rt.copySpan(t, 0, 2, std.testing.allocator);

    const rt_tape = rt.asTape();
    const ref0 = rt.entries.items[0].payload.string;
    const ref1 = rt.entries.items[1].payload.string;
    // Source offsets were 0 and 3; after "prefix" (6 bytes), new offsets are 6 and 9
    try std.testing.expectEqual(@as(u32, 6), ref0.offset);
    try std.testing.expectEqual(@as(u32, 9), ref1.offset);
    try std.testing.expectEqualStrings("foo", rt_tape.getString(ref0));
    try std.testing.expectEqualStrings("bar", rt_tape.getString(ref1));
}

// ─── formatJqFloat ──────────────────────────────────────────────────────────

test "formatJqFloat: integer-valued floats" {
    const f = formatJqFloat;
    try std.testing.expectEqualStrings("2", f(2.0).slice());
    try std.testing.expectEqualStrings("100", f(100.0).slice());
    try std.testing.expectEqualStrings("0", f(0.0).slice());
    try std.testing.expectEqualStrings("0", f(-0.0).slice());
    try std.testing.expectEqualStrings("-1", f(-1.0).slice());
}

test "formatJqFloat: simple decimals" {
    const f = formatJqFloat;
    try std.testing.expectEqualStrings("0.5", f(0.5).slice());
    try std.testing.expectEqualStrings("1.5", f(1.5).slice());
    try std.testing.expectEqualStrings("1.23", f(1.23).slice());
    try std.testing.expectEqualStrings("-0.001", f(-0.001).slice());
}

test "formatJqFloat: scientific notation" {
    const f = formatJqFloat;
    // 1e17 fits in i64, so it's formatted as integer
    try std.testing.expectEqualStrings("100000000000000000", f(1e17).slice());
    // Non-integer floats use shortest representation with jq thresholds
    try std.testing.expectEqualStrings("1.1e-19", f(1.1e-19).slice());
    try std.testing.expectEqualStrings("1.05e-19", f(1.05e-19).slice());
    try std.testing.expectEqualStrings("1.7976931348623157e+308", f(1.7976931348623157e+308).slice());
    // Large integer-valued floats that overflow i64 use jvp_dtoa_fmt
    try std.testing.expectEqualStrings("1e+20", f(1e20).slice());
}

test "formatJqFloat: NaN and Inf" {
    const f = formatJqFloat;
    try std.testing.expectEqualStrings("null", f(std.math.nan(f64)).slice());
    try std.testing.expectEqualStrings("null", f(std.math.inf(f64)).slice());
    try std.testing.expectEqualStrings("null", f(-std.math.inf(f64)).slice());
}
