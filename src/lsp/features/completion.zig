const std = @import("std");
const protocol = @import("../protocol.zig");
const builtins_mod = @import("../builtins.zig");
const analysis = @import("../analysis.zig");
const ast = @import("ast");

/// Generate completions at the given byte offset.
pub fn complete(
    source: []const u8,
    offset: u32,
    model: ?*const analysis.SemanticModel,
    parse_result: ?*const ast.ParseResult,
    alloc: std.mem.Allocator,
) []protocol.CompletionItem {
    var items = std.ArrayList(protocol.CompletionItem){};

    const context = getContext(source, offset);

    switch (context) {
        .after_dot => {
            // Field access patterns
            items.append(alloc, .{
                .label = ".[]",
                .kind = .property,
                .detail = "Iterate all elements",
            }) catch {};
        },
        .after_dollar => {
            // Variables in scope
            if (model) |m| {
                addScopeVariables(m, &items, alloc);
            }
        },
        .after_at => {
            // Format builtins
            addFormatCompletions(&items, alloc);
        },
        .general => {
            // All builtins + keywords + user functions
            addBuiltinCompletions(&items, alloc);
            addKeywordCompletions(&items, alloc);
            if (model) |m| {
                addScopeVariables(m, &items, alloc);
                addUserFunctions(m, &items, alloc);
            }
        },
    }

    _ = parse_result;

    return items.toOwnedSlice(alloc) catch &[_]protocol.CompletionItem{};
}

const Context = enum { after_dot, after_dollar, after_at, general };

fn getContext(source: []const u8, offset: u32) Context {
    if (offset == 0 or offset > source.len) return .general;
    const prev = source[offset - 1];
    return switch (prev) {
        '.' => .after_dot,
        '$' => .after_dollar,
        '@' => .after_at,
        else => .general,
    };
}

fn addBuiltinCompletions(items: *std.ArrayList(protocol.CompletionItem), alloc: std.mem.Allocator) void {
    for (builtins_mod.builtins) |b| {
        const insert = if (b.arity > 0) blk: {
            var buf = std.ArrayList(u8){};
            buf.appendSlice(alloc, b.name) catch break :blk b.name;
            buf.appendSlice(alloc, "($1)") catch break :blk b.name;
            break :blk buf.toOwnedSlice(alloc) catch b.name;
        } else b.name;

        items.append(alloc, .{
            .label = b.name,
            .kind = .function,
            .detail = b.signature,
            .documentation = b.doc,
            .insertText = if (b.arity > 0) insert else null,
            .insertTextFormat = if (b.arity > 0) .snippet else null,
        }) catch continue;
    }
}

fn addKeywordCompletions(items: *std.ArrayList(protocol.CompletionItem), alloc: std.mem.Allocator) void {
    const keywords = [_]struct { label: []const u8, detail: []const u8 }{
        .{ .label = "if", .detail = "if COND then BODY [elif COND then BODY]* [else BODY] end" },
        .{ .label = "def", .detail = "def NAME[(PARAMS)]: BODY;" },
        .{ .label = "as", .detail = "EXPR as $VAR | BODY" },
        .{ .label = "reduce", .detail = "reduce EXPR as $VAR (INIT; UPDATE)" },
        .{ .label = "foreach", .detail = "foreach EXPR as $VAR (INIT; UPDATE[; EXTRACT])" },
        .{ .label = "try", .detail = "try EXPR [catch HANDLER]" },
        .{ .label = "label", .detail = "label $NAME | BODY" },
        .{ .label = "true", .detail = "boolean true" },
        .{ .label = "false", .detail = "boolean false" },
        .{ .label = "null", .detail = "null value" },
        .{ .label = "and", .detail = "logical and" },
        .{ .label = "or", .detail = "logical or" },
        .{ .label = "not", .detail = "logical not" },
    };
    for (keywords) |kw| {
        items.append(alloc, .{
            .label = kw.label,
            .kind = .keyword,
            .detail = kw.detail,
        }) catch continue;
    }
}

fn addFormatCompletions(items: *std.ArrayList(protocol.CompletionItem), alloc: std.mem.Allocator) void {
    const formats = [_]struct { label: []const u8, doc: []const u8 }{
        .{ .label = "text", .doc = "Format as text" },
        .{ .label = "json", .doc = "Format as JSON" },
        .{ .label = "html", .doc = "HTML-escape" },
        .{ .label = "csv", .doc = "Format as CSV" },
        .{ .label = "tsv", .doc = "Format as TSV" },
        .{ .label = "uri", .doc = "URI-encode" },
        .{ .label = "base64", .doc = "Base64-encode" },
        .{ .label = "base64d", .doc = "Base64-decode" },
        .{ .label = "sh", .doc = "Shell-escape" },
    };
    for (formats) |f| {
        items.append(alloc, .{
            .label = f.label,
            .kind = .value,
            .documentation = f.doc,
        }) catch continue;
    }
}

fn addScopeVariables(model: *const analysis.SemanticModel, items: *std.ArrayList(protocol.CompletionItem), alloc: std.mem.Allocator) void {
    for (model.symbols.items) |sym| {
        if (sym.kind == .variable or sym.kind == .parameter) {
            items.append(alloc, .{
                .label = sym.name,
                .kind = .variable,
            }) catch continue;
        }
    }
}

fn addUserFunctions(model: *const analysis.SemanticModel, items: *std.ArrayList(protocol.CompletionItem), alloc: std.mem.Allocator) void {
    for (model.symbols.items) |sym| {
        if (sym.kind == .function and sym.span.start != 0) { // skip builtins (span=empty)
            items.append(alloc, .{
                .label = sym.name,
                .kind = .function,
            }) catch continue;
        }
    }
}
