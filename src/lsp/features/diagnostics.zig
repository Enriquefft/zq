const std = @import("std");
const ast = @import("ast");
const protocol = @import("../protocol.zig");
const analysis = @import("../analysis.zig");

/// Convert AST parse errors to LSP diagnostics.
pub fn fromParseResult(result: *const ast.ParseResult, alloc: std.mem.Allocator) []protocol.Diagnostic {
    const source = blk: {
        // We need the source to compute positions. It's available via the parse result's root span.
        // For now, we'll store source alongside the document.
        break :blk "";
    };
    _ = source;

    var diags = std.ArrayList(protocol.Diagnostic){};

    for (result.errors) |err| {
        diags.append(alloc, .{
            .range = spanToRange(err.span),
            .severity = .@"error",
            .message = err.message,
        }) catch continue;
    }

    return diags.toOwnedSlice(alloc) catch &[_]protocol.Diagnostic{};
}

/// Convert AST parse errors to LSP diagnostics with source text for position calculation.
pub fn fromParseErrors(errors: []const ast.ParseError, source: []const u8, alloc: std.mem.Allocator) []protocol.Diagnostic {
    var diags = std.ArrayList(protocol.Diagnostic){};

    for (errors) |err| {
        const start = protocol.byteOffsetToPosition(source, err.span.start);
        const end = protocol.byteOffsetToPosition(source, err.span.end);
        diags.append(alloc, .{
            .range = .{ .start = start, .end = end },
            .severity = .@"error",
            .message = err.message,
        }) catch continue;
    }

    return diags.toOwnedSlice(alloc) catch &[_]protocol.Diagnostic{};
}

fn spanToRange(span: ast.Span) protocol.Range {
    // Without source text, we use byte offsets as character positions
    // (correct for ASCII, which most jq filters are)
    return .{
        .start = .{ .line = 0, .character = span.start },
        .end = .{ .line = 0, .character = span.end },
    };
}
