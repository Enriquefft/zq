pub const nodes = @import("nodes.zig");
pub const parser = @import("parser.zig");

// Re-exports for convenience
pub const Node = nodes.Node;
pub const Span = nodes.Span;
pub const Pattern = nodes.Pattern;
pub const PatternKey = nodes.PatternKey;
pub const ObjectPatternField = nodes.ObjectPatternField;
pub const ParseError = nodes.ParseError;
pub const ParseResult = nodes.ParseResult;
pub const Parser = parser.Parser;

/// Parse a jq filter expression into an AST. Always succeeds — errors are
/// collected in the result's `errors` slice.
pub fn parse(source: []const u8, alloc: @import("std").mem.Allocator) ParseResult {
    return Parser.parse(source, alloc);
}
