const std = @import("std");

/// JSON-RPC 2.0 transport over stdin/stdout with Content-Length framing.
pub const Transport = struct {
    in_file: std.fs.File,
    out_file: std.fs.File,
    alloc: std.mem.Allocator,
    file_buf: [4096]u8 = undefined,

    pub fn init(in_file: std.fs.File, out_file: std.fs.File, alloc: std.mem.Allocator) Transport {
        return .{
            .in_file = in_file,
            .out_file = out_file,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Transport) void {
        _ = self;
    }

    /// Read one JSON-RPC message. Returns the JSON body as owned slice.
    pub fn readMessage(self: *Transport) ![]u8 {
        var content_length: ?usize = null;

        // Parse headers
        while (true) {
            const line = try self.readLine();
            defer self.alloc.free(line);

            if (line.len == 0) break; // empty line = end of headers

            if (std.mem.startsWith(u8, line, "Content-Length: ")) {
                const val = line["Content-Length: ".len..];
                content_length = std.fmt.parseInt(usize, val, 10) catch continue;
            }
        }

        const len = content_length orelse return error.MissingContentLength;
        if (len > 10 * 1024 * 1024) return error.ContentTooLarge; // 10MB limit

        const body = try self.alloc.alloc(u8, len);
        errdefer self.alloc.free(body);

        var total: usize = 0;
        while (total < len) {
            const n = self.in_file.read(body[total..]) catch return error.ReadFailed;
            if (n == 0) return error.UnexpectedEof;
            total += n;
        }

        return body;
    }

    /// Write a JSON-RPC message with Content-Length header.
    pub fn writeMessage(self: *Transport, body: []const u8) !void {
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;
        self.out_file.writeAll(header) catch return error.WriteFailed;
        self.out_file.writeAll(body) catch return error.WriteFailed;
    }

    fn readLine(self: *Transport) ![]u8 {
        var line_buf: std.ArrayList(u8) = .{};
        errdefer line_buf.deinit(self.alloc);

        while (true) {
            var byte_buf: [1]u8 = undefined;
            const n = self.in_file.read(&byte_buf) catch return error.ReadFailed;
            if (n == 0) break;

            const byte = byte_buf[0];
            if (byte == '\n') {
                // Strip trailing \r
                const items = line_buf.items;
                const end = if (items.len > 0 and items[items.len - 1] == '\r')
                    items.len - 1
                else
                    items.len;
                const result = try self.alloc.dupe(u8, items[0..end]);
                line_buf.deinit(self.alloc);
                return result;
            }
            try line_buf.append(self.alloc, byte);
        }

        const result = try self.alloc.dupe(u8, line_buf.items);
        line_buf.deinit(self.alloc);
        return result;
    }
};
