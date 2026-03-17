const std = @import("std");
const protocol = @import("../protocol.zig");
const analysis = @import("../analysis.zig");
const ast = @import("ast");

/// Find the definition of the symbol at the given offset.
pub fn definition(
    source: []const u8,
    offset: u32,
    root: *const ast.Node,
    model: *const analysis.SemanticModel,
    uri: []const u8,
) ?protocol.Location {
    const node = analysis.SemanticModel.nodeAtOffset(root, offset) orelse return null;

    const name = switch (node.kind) {
        .variable_ref => |vr| vr.name,
        .func_call => |fc| fc.name,
        else => return null,
    };

    // Find the definition reference
    for (model.references.items) |ref| {
        if (!ref.is_definition) continue;
        if (ref.symbol_id >= model.symbols.items.len) continue;
        const sym = &model.symbols.items[ref.symbol_id];
        if (std.mem.eql(u8, sym.name, name)) {
            if (sym.span.start == 0 and sym.span.end == 0) return null; // builtin
            return .{
                .uri = uri,
                .range = .{
                    .start = protocol.byteOffsetToPosition(source, sym.span.start),
                    .end = protocol.byteOffsetToPosition(source, sym.span.end),
                },
            };
        }
    }
    return null;
}
