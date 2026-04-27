//! Throwaway probe — used during Phase 6 implementation to discover the
//! exact `kind/offset/len` triples emitted by the legacy compiler for a
//! curated list of malformed filters. The output of this probe is then
//! transcribed into `tests/vm_equiv_errpos.zig`. Build with the same
//! module imports as `vm-equiv` then delete after transcription.
const std = @import("std");
const query = @import("query");

const FILTERS = [_][]const u8{
    "\"foo",
    ". |",
    ".[",
    "1 +",
    "if .x then .y",
    "{",
    "[",
    "def f",
    ".foo +",
    "(",
    // Phase 4 — format-builtin unknown-name diagnostics.
    "@xyz",
    "@xyz \"lit\"",
    "@xyz \"\\(.)\"",
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var stdout_buf: std.ArrayList(u8) = .{};
    defer stdout_buf.deinit(alloc);
    const w = stdout_buf.writer(alloc);

    for (FILTERS) |f| {
        var res = try query.CompiledQuery.compileLegacy(f, .{}, alloc);
        defer switch (res) {
            .ok => |*cq| cq.deinit(),
            .err => {},
        };
        switch (res) {
            .ok => try w.print("OK   filter={s}\n", .{f}),
            .err => |ce| try w.print("ERR  filter={s} kind={s} offset={d} len={d}\n", .{ f, @tagName(ce.kind), ce.offset, ce.len }),
        }
    }
    try std.fs.File.stdout().writeAll(stdout_buf.items);
}
