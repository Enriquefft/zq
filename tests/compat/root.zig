// !! GENERATED FILE â do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// Root entry point: imports all section files so their tests run as one binary.

comptime {
    _ = @import("literals.zig");
    _ = @import("object_construction.zig");
    _ = @import("field_access.zig");
    _ = @import("array_indices.zig");
    _ = @import("iteration.zig");
    _ = @import("variables.zig");
    _ = @import("builtins.zig");
    _ = @import("user_functions.zig");
    _ = @import("paths.zig");
    _ = @import("assignment.zig");
    _ = @import("conditionals.zig");
    _ = @import("comparisons.zig");
    _ = @import("try_catch.zig");
    _ = @import("string_ops.zig");
    _ = @import("datetime.zig");
    _ = @import("numbers.zig");
    _ = @import("unary_negation.zig");
    _ = @import("object_merge.zig");
    _ = @import("regression.zig");
    _ = @import("regex.zig");
    _ = @import("repeat_builtin.zig");
}
