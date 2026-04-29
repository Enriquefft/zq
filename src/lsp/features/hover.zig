const std = @import("std");
const protocol = @import("../protocol.zig");
const builtins_mod = @import("../builtins.zig");
const analysis = @import("../analysis.zig");
const ast = @import("ast");

/// Generate hover information at the given byte offset.
pub fn hover(
    source: []const u8,
    offset: u32,
    root: *const ast.Node,
    model: *const analysis.SemanticModel,
    alloc: std.mem.Allocator,
) ?protocol.Hover {
    const node = analysis.SemanticModel.nodeAtOffset(root, offset) orelse return null;

    return switch (node.kind) {
        .builtin_call => |bc| hoverBuiltin(bc.name, node.span, source, alloc),
        .field_access => |fa| hoverField(fa.name, node.span, source),
        .variable_ref => |vr| hoverVariable(vr.name, node.span, source, model),
        .func_call => |fc| hoverUserFunc(fc.name, node.span, source, model),
        .literal => hoverLiteral(node, source),
        else => null,
    };
}

fn hoverBuiltin(name: []const u8, span: ast.Span, source: []const u8, alloc: std.mem.Allocator) ?protocol.Hover {
    const info = builtins_mod.lookup(name) orelse return null;

    var buf = std.ArrayList(u8){};
    const writer = buf.writer(alloc);
    writer.print("**{s}**\n\n", .{info.signature}) catch {};
    writer.print("{s}\n\n", .{info.doc}) catch {};
    writer.print("*Category: {s}*", .{@tagName(info.category)}) catch {};

    const value = buf.toOwnedSlice(alloc) catch info.doc;

    return .{
        .contents = .{ .value = value },
        .range = spanToRange(span, source),
    };
}

fn hoverField(name: []const u8, span: ast.Span, source: []const u8) ?protocol.Hover {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "**Field access:** `.{s}`", .{name}) catch return null;
    return .{
        .contents = .{ .value = text },
        .range = spanToRange(span, source),
    };
}

fn hoverVariable(name: []const u8, span: ast.Span, source: []const u8, model: *const analysis.SemanticModel) ?protocol.Hover {
    for (model.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, name) and (sym.kind == .variable or sym.kind == .parameter)) {
            var buf: [256]u8 = undefined;
            const kind_str = if (sym.kind == .parameter) "parameter" else "variable";
            const text = std.fmt.bufPrint(&buf, "**{s}** `${s}`", .{ kind_str, name }) catch return null;
            return .{
                .contents = .{ .value = text },
                .range = spanToRange(span, source),
            };
        }
    }
    return null;
}

fn hoverUserFunc(name: []const u8, span: ast.Span, source: []const u8, model: *const analysis.SemanticModel) ?protocol.Hover {
    // Check builtins first
    if (builtins_mod.lookup(name)) |_| {
        return hoverBuiltin(name, span, source, model.alloc);
    }

    for (model.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, name) and sym.kind == .function) {
            var buf: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "**User function:** `{s}`", .{name}) catch return null;
            return .{
                .contents = .{ .value = text },
                .range = spanToRange(span, source),
            };
        }
    }
    return null;
}

fn hoverLiteral(node: *const ast.Node, source: []const u8) ?protocol.Hover {
    _ = source;
    const info = switch (node.kind) {
        .literal => |lit| switch (lit) {
            .int => "**integer literal**",
            .float => "**float literal**",
            .big_number => "**out-of-range number literal**",
            .string => "**string literal**",
            .bool_val => "**boolean literal**",
            .null_val => "**null**",
        },
        else => return null,
    };
    return .{
        .contents = .{ .value = info },
    };
}

fn spanToRange(span: ast.Span, source: []const u8) protocol.Range {
    return .{
        .start = protocol.byteOffsetToPosition(source, span.start),
        .end = protocol.byteOffsetToPosition(source, span.end),
    };
}
