//! Leak regression for the compiler. Cycles `compile` with both
//! a non-empty `external_vars` slice and a single category-1 filter
//! through a `.safety = true` GPA, asserting `deinit` reports zero
//! leaked bytes. Guards against ownership drops on the `external_var_ids`
//! path and the emit-output bundle.

const std = @import("std");
const query = @import("query");

fn compileOnceAndCheck(filter: []const u8, opts: query.Opts) !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{ .safety = true }) = .{};
    const alloc = gpa.allocator();

    const result = query.CompiledQuery.compile(filter, opts, alloc) catch |e| switch (e) {
        error.OutOfMemory => {
            _ = gpa.deinit();
            return error.UnexpectedOom;
        },
    };
    var r = result;
    switch (r) {
        .ok => |*cq| cq.deinit(),
        .err => {},
    }

    const check = gpa.deinit();
    if (check == .leak) return error.LeakedOnSuccess;
}

test "compiler: success path is leak-clean (no external vars)" {
    try compileOnceAndCheck(".", .{});
}

test "compiler: success path is leak-clean (with external vars)" {
    const ext = [_]query.ExternalVarDecl{ .{ .name = "x" }, .{ .name = "y" } };
    try compileOnceAndCheck(".", .{ .external_vars = &ext });
}

test "compiler: field-access path is leak-clean" {
    try compileOnceAndCheck(".foo", .{});
}
