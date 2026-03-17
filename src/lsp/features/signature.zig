const std = @import("std");
const protocol = @import("../protocol.zig");
const builtins_mod = @import("../builtins.zig");
const ast = @import("ast");

pub const SignatureHelp = struct {
    label: []const u8,
    documentation: []const u8,
    active_parameter: u32,
};

/// Provide signature help at the given offset.
pub fn signatureHelp(
    source: []const u8,
    offset: u32,
) ?SignatureHelp {
    // Walk backwards to find the function name and count semicolons
    var paren_depth: i32 = 0;
    var semicolons: u32 = 0;
    var func_end: u32 = 0;
    var i: u32 = offset;

    while (i > 0) {
        i -= 1;
        const c = source[i];
        if (c == ')') paren_depth += 1;
        if (c == '(') {
            if (paren_depth == 0) {
                func_end = i;
                break;
            }
            paren_depth -= 1;
        }
        if (c == ';' and paren_depth == 0) semicolons += 1;
    }

    if (func_end == 0) return null;

    // Extract function name before (
    var name_start = func_end;
    while (name_start > 0 and isIdentChar(source[name_start - 1])) {
        name_start -= 1;
    }
    if (name_start == func_end) return null;

    const name = source[name_start..func_end];

    // Look up builtin
    if (builtins_mod.lookup(name)) |info| {
        return .{
            .label = info.signature,
            .documentation = info.doc,
            .active_parameter = semicolons,
        };
    }

    return null;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
