const std = @import("std");
const parser_mod = @import("parser");

const Parser = parser_mod.Parser;

test "fuzz parser - no crashes on any input" {
    const Context = struct {
        fn testOne(_: @This(), input: []const u8) anyerror!void {
            var p = try Parser.init(std.testing.allocator);
            defer p.deinit();
            _ = p.feed(input, true) catch {};
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{
        .corpus = &.{
            "null",
            "true",
            "false",
            "0",
            "42",
            "-1",
            "3.14",
            "1e10",
            "\"hello\"",
            "\"\"",
            "\"\\n\\t\\r\"",
            "\"\\u0041\"",
            "\"\\uD83D\\uDC08\"",
            "[]",
            "[1,2,3]",
            "{}",
            "{\"a\":1}",
            "{\"a\":{\"b\":[1,2,3]}}",
            "[{},{},[],null,true,false,0,\"x\"]",
            // Edge cases
            "[[[[[[[[[[]]]]]]]]]",
            "{\"\":0}",
            "0.0",
            "-0",
            "1e-10",
            "1E+10",
        },
    });
}
