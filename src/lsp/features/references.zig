const std = @import("std");
const protocol = @import("../protocol.zig");
const analysis = @import("../analysis.zig");
const ast = @import("ast");

/// Find all references to the symbol at the given offset.
pub fn findReferences(
    source: []const u8,
    offset: u32,
    root: *const ast.Node,
    model: *const analysis.SemanticModel,
    uri: []const u8,
    alloc: std.mem.Allocator,
) []protocol.Location {
    const node = analysis.SemanticModel.nodeAtOffset(root, offset) orelse return &[_]protocol.Location{};

    const name = switch (node.kind) {
        .variable_ref => |vr| vr.name,
        .func_call => |fc| fc.name,
        .func_def => |fd| fd.name,
        else => return &[_]protocol.Location{},
    };

    // Find the symbol ID
    var target_sym_id: ?u32 = null;
    for (model.symbols.items, 0..) |sym, i| {
        if (std.mem.eql(u8, sym.name, name)) {
            target_sym_id = @intCast(i);
            break;
        }
    }
    const sym_id = target_sym_id orelse return &[_]protocol.Location{};

    var locations = std.ArrayList(protocol.Location){};
    for (model.references.items) |ref| {
        if (ref.symbol_id == sym_id) {
            locations.append(alloc, .{
                .uri = uri,
                .range = .{
                    .start = protocol.byteOffsetToPosition(source, ref.span.start),
                    .end = protocol.byteOffsetToPosition(source, ref.span.end),
                },
            }) catch continue;
        }
    }
    return locations.toOwnedSlice(alloc) catch &[_]protocol.Location{};
}
