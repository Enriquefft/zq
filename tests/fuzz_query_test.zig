const std = @import("std");
const parser_mod = @import("parser");
const query_mod = @import("query");

const Parser = parser_mod.Parser;
const CompiledQuery = query_mod.CompiledQuery;

const test_inputs = [_][]const u8{
    "null",
    "42",
    "\"hello\"",
    "true",
    "[1,2,3]",
    "{\"a\":1,\"b\":2}",
    "{\"a\":{\"b\":[1,{\"c\":null},true]}}",
};

fn parseTape(allocator: std.mem.Allocator, json: []const u8) !struct { parser: Parser, tape: parser_mod.Tape } {
    var p = try Parser.init(allocator);
    errdefer p.deinit();

    const result = try p.feed(json, true);
    switch (result) {
        .done => |d| return .{ .parser = p, .tape = d.tape },
        .need_more => {
            p.deinit();
            return error.UnexpectedNeedMore;
        },
        // `.dropped` only flows from `feedPlanned`; this is plain `feed`.
        .dropped => unreachable,
    }
}

test "fuzz query VM - no crashes on any filter" {
    const Context = struct {
        fn testOne(_: @This(), input: []const u8) anyerror!void {
            const alloc = std.testing.allocator;

            // Try to compile the fuzzed filter string
            const compile_result = CompiledQuery.compile(input, .{}, alloc) catch return;
            var q = switch (compile_result) {
                .ok => |cq| cq,
                .err => return, // Compile error is fine
            };
            defer q.deinit();

            // Execute against each known-good JSON input
            for (&test_inputs) |json| {
                const parsed = parseTape(alloc, json) catch continue;
                var p = parsed.parser;
                defer p.deinit();

                var it = q.execute(parsed.tape, &.{}, alloc) catch continue;
                defer it.deinit();

                // Drain all results — runtime errors are fine, crashes are not
                while (true) {
                    const val = it.next() catch break;
                    if (val == null) break;
                }
            }
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{
        .corpus = &.{
            ".",
            ".foo",
            ".[0]",
            "keys",
            "length",
            ".[]",
            "select(.a > 1)",
            ".a.b.c",
            "type",
            "not",
            "add",
            "map(. + 1)",
            "to_entries",
            "from_entries",
            "has(\"a\")",
            "in({\"a\":1})",
            "empty",
            "range(10)",
            "null",
            "if . then . else . end",
            ". as $x | $x",
            "[.[] | . * 2]",
            "{a: .b, c: .d}",
            "split(\",\")",
            "test(\"abc\")",
            "ascii_downcase",
            "tostring",
            "tonumber",
            "recurse",
            "flatten",
            "group_by(.a)",
            "sort_by(.a)",
            "unique",
            "limit(3; .[])",
            "first(.[])",
            "last(.[])",
            "min",
            "max",
            "indices(\"a\")",
            "ltrimstr(\"a\")",
            "rtrimstr(\"a\")",
            "startswith(\"a\")",
            "endswith(\"a\")",
            "gsub(\"a\"; \"b\")",
            "def f: .; f",
            "try . catch .",
            "label $out | ., break $out",
            "path(.a)",
            "getpath([\"a\"])",
            "setpath([\"a\"]; 1)",
            "delpaths([[\"a\"]])",
            "env",
            "input",
            "debug",
            "@base64",
            "@uri",
            "@html",
            "@json",
            "@csv",
            "@tsv",
            "@text",
        },
    });
}
