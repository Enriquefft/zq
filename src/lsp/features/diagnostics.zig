const std = @import("std");
const ast = @import("ast");
const err_mod = @import("error");
const query = @import("query");
const protocol = @import("../protocol.zig");
const analysis = @import("../analysis.zig");

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

/// Run the real compiler against `source` and, on failure, convert the
/// structured `CompileError` into an LSP diagnostic. The compiler is the
/// single source of truth for regex-pattern validation — a literal pattern
/// that won't compile at runtime won't compile here either, and the error
/// span will point at the string literal.
///
/// Diagnostic message strings are owned by a caller-provided allocator; free
/// them alongside the returned slice.
pub fn fromCompileErrors(source: []const u8, alloc: std.mem.Allocator) []protocol.Diagnostic {
    var diags = std.ArrayList(protocol.Diagnostic){};

    // compile() only returns OutOfMemory as a Zig error; everything else is
    // reported via the `.err` variant of the union. Swallow OOM to keep the
    // LSP alive; the caller surfaces the absence of diagnostics as "no known
    // problems", matching other transient-resource failures.
    const result = query.CompiledQuery.compile(source, .{}, alloc) catch {
        return diags.toOwnedSlice(alloc) catch &[_]protocol.Diagnostic{};
    };
    switch (result) {
        .ok => |ok| {
            var mut = ok;
            mut.deinit();
        },
        .err => |ce| {
            // Only emit compile-error diagnostics that aren't already covered
            // by the AST parser (which catches plain syntax errors with better
            // spans). Regex compile errors are the primary motivator here.
            if (ce.kind != .regex_compile_error and ce.kind != .regex_not_compiled) {
                return diags.toOwnedSlice(alloc) catch &[_]protocol.Diagnostic{};
            }
            const message = std.fmt.allocPrint(alloc, "{s}", .{err_mod.kindToString(ce.kind)}) catch {
                return diags.toOwnedSlice(alloc) catch &[_]protocol.Diagnostic{};
            };
            const start = protocol.byteOffsetToPosition(source, ce.offset);
            const end_offset: u32 = if (ce.len > 0) ce.offset + ce.len else ce.offset;
            const end = protocol.byteOffsetToPosition(source, end_offset);
            diags.append(alloc, .{
                .range = .{ .start = start, .end = end },
                .severity = .@"error",
                .message = message,
            }) catch {};
        },
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
