const std = @import("std");

pub const server = @import("server.zig");
pub const transport = @import("transport.zig");
pub const protocol = @import("protocol.zig");
pub const analysis = @import("analysis.zig");
pub const builtins = @import("builtins.zig");
/// Re-export feature namespaces so test code and downstream consumers can
/// invoke diagnostics / completion / hover / … without reaching through
/// the server. Thin pass-through, no behavioral change.
pub const features = struct {
    pub const diagnostics = @import("features/diagnostics.zig");
};

pub const Server = server.Server;

/// Start the LSP server on stdin/stdout.
pub fn run(alloc: std.mem.Allocator) !void {
    var srv = Server.init(std.fs.File.stdin(), std.fs.File.stdout(), alloc);
    defer srv.deinit();
    try srv.run();
}
