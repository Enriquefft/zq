const std = @import("std");
const protocol = @import("../protocol.zig");
const analysis = @import("../analysis.zig");
const ast = @import("ast");

pub const RenameEdit = struct {
    range: protocol.Range,
    new_text: []const u8,
};

/// Check if the symbol at offset is renameable. Returns the current name or null.
pub fn prepareRename(
    source: []const u8,
    offset: u32,
    root: *const ast.Node,
    model: *const analysis.SemanticModel,
) ?struct { range: protocol.Range, placeholder: []const u8 } {
    const node = analysis.SemanticModel.nodeAtOffset(root, offset) orelse return null;

    const name = switch (node.kind) {
        .variable_ref => |vr| vr.name,
        .func_call => |fc| fc.name,
        .func_def => |fd| fd.name,
        else => return null,
    };

    // Builtins cannot be renamed
    const builtins_mod = @import("../builtins.zig");
    if (builtins_mod.lookup(name) != null) return null;

    // Must be a user-defined symbol
    for (model.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, name) and sym.span.start != 0) {
            return .{
                .range = .{
                    .start = protocol.byteOffsetToPosition(source, node.span.start),
                    .end = protocol.byteOffsetToPosition(source, node.span.end),
                },
                .placeholder = name,
            };
        }
    }
    return null;
}

/// Compute rename edits for the symbol at offset.
pub fn rename(
    source: []const u8,
    offset: u32,
    new_name: []const u8,
    root: *const ast.Node,
    model: *const analysis.SemanticModel,
    alloc: std.mem.Allocator,
) []RenameEdit {
    const node = analysis.SemanticModel.nodeAtOffset(root, offset) orelse return &[_]RenameEdit{};

    const name = switch (node.kind) {
        .variable_ref => |vr| vr.name,
        .func_call => |fc| fc.name,
        .func_def => |fd| fd.name,
        else => return &[_]RenameEdit{},
    };

    // Find the symbol ID
    var target_sym_id: ?u32 = null;
    for (model.symbols.items, 0..) |sym, i| {
        if (std.mem.eql(u8, sym.name, name) and sym.span.start != 0) {
            target_sym_id = @intCast(i);
            break;
        }
    }
    const sym_id = target_sym_id orelse return &[_]RenameEdit{};

    var edits = std.ArrayList(RenameEdit){};
    for (model.references.items) |ref| {
        if (ref.symbol_id == sym_id) {
            edits.append(alloc, .{
                .range = .{
                    .start = protocol.byteOffsetToPosition(source, ref.span.start),
                    .end = protocol.byteOffsetToPosition(source, ref.span.end),
                },
                .new_text = new_name,
            }) catch continue;
        }
    }
    return edits.toOwnedSlice(alloc) catch &[_]RenameEdit{};
}
