const std = @import("std");
const build_options = @import("build_options");

/// Comptime flag mirroring `-Dlsp`. When false, the sub-modules below
/// collapse into empty structs and `run` returns `error.LspDisabled`,
/// so none of the LSP implementation is compiled into the binary.
pub const enabled: bool = build_options.lsp_enabled;

pub const server = if (enabled) @import("server.zig") else struct {};
pub const transport = if (enabled) @import("transport.zig") else struct {};
pub const protocol = if (enabled) @import("protocol.zig") else struct {};
pub const analysis = if (enabled) @import("analysis.zig") else struct {};
pub const builtins = if (enabled) @import("builtins.zig") else struct {};
/// Re-export feature namespaces so test code and downstream consumers can
/// invoke diagnostics / completion / hover / … without reaching through
/// the server. Thin pass-through, no behavioral change.
pub const features = if (enabled) struct {
    pub const diagnostics = @import("features/diagnostics.zig");
} else struct {};

pub const Server = if (enabled) server.Server else struct {};

pub const Error = error{LspDisabled};

/// Start the LSP server on stdin/stdout.
pub fn run(alloc: std.mem.Allocator) !void {
    if (!enabled) return error.LspDisabled;
    var srv = Server.init(std.fs.File.stdin(), std.fs.File.stdout(), alloc);
    defer srv.deinit();
    try srv.run();
}
