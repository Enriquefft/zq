const std = @import("std");
const ast = @import("ast");
const Transport = @import("transport.zig").Transport;
const protocol = @import("protocol.zig");
const analysis = @import("analysis.zig");
const diagnostics_feat = @import("features/diagnostics.zig");
const completion_feat = @import("features/completion.zig");
const hover_feat = @import("features/hover.zig");
const definition_feat = @import("features/definition.zig");
const references_feat = @import("features/references.zig");
const rename_feat = @import("features/rename.zig");
const signature_feat = @import("features/signature.zig");
const semantic_feat = @import("features/semantic_tokens.zig");
const formatting_feat = @import("features/formatting.zig");

/// A document managed by the LSP server.
const Document = struct {
    uri: []const u8,
    source: []const u8,
    parse_result: ?ast.ParseResult,
    model: ?analysis.SemanticModel,

    fn deinit(self: *Document, alloc: std.mem.Allocator) void {
        alloc.free(self.uri);
        alloc.free(self.source);
        if (self.parse_result) |*pr| pr.deinit();
        if (self.model) |*m| m.deinit();
    }
};

pub const Server = struct {
    alloc: std.mem.Allocator,
    transport: Transport,
    documents: std.StringHashMap(Document),
    initialized: bool,
    shutdown_requested: bool,

    pub fn init(in_file: std.fs.File, out_file: std.fs.File, alloc: std.mem.Allocator) Server {
        return .{
            .alloc = alloc,
            .transport = Transport.init(in_file, out_file, alloc),
            .documents = std.StringHashMap(Document).init(alloc),
            .initialized = false,
            .shutdown_requested = false,
        };
    }

    pub fn deinit(self: *Server) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            var doc = entry.value_ptr;
            doc.deinit(self.alloc);
        }
        self.documents.deinit();
        self.transport.deinit();
    }

    pub fn run(self: *Server) !void {
        while (!self.shutdown_requested) {
            const body = self.transport.readMessage() catch |err| switch (err) {
                error.UnexpectedEof, error.ReadFailed => return,
                else => return err,
            };
            defer self.alloc.free(body);

            self.handleMessage(body);
        }
    }

    fn handleMessage(self: *Server, body: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, body, .{}) catch return;
        defer parsed.deinit();

        const root = parsed.value;
        const obj = switch (root) {
            .object => |o| o,
            else => return,
        };

        const method_val = obj.get("method") orelse return;
        const method = switch (method_val) {
            .string => |s| s,
            else => return,
        };

        const id = obj.get("id");
        const params = obj.get("params");

        if (std.mem.eql(u8, method, "initialize")) {
            self.handleInitialize(id);
        } else if (std.mem.eql(u8, method, "initialized")) {
            self.initialized = true;
        } else if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown_requested = true;
            self.sendResult(id, .null);
        } else if (std.mem.eql(u8, method, "exit")) {
            return;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            self.handleDidOpen(params);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            self.handleDidChange(params);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            self.handleDidClose(params);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            self.handleCompletion(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            self.handleHover(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            self.handleDefinition(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            self.handleReferences(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/rename")) {
            self.handleRename(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/prepareRename")) {
            self.handlePrepareRename(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
            self.handleSignatureHelp(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            self.handleSemanticTokens(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/formatting")) {
            self.handleFormatting(id, params);
        } else {
            // Unknown method — if it has an id, send method-not-found error
            if (id != null) {
                self.sendError(id, -32601, "Method not found");
            }
        }
    }

    fn handleInitialize(self: *Server, id: ?std.json.Value) void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.alloc);
        const w = buf.writer(self.alloc);

        w.writeAll(
            \\{"jsonrpc":"2.0","id":
        ) catch return;
        writeJsonValue(w, id) catch return;
        w.writeAll(
            \\,"result":{"capabilities":{
        ) catch return;
        w.writeAll(
            \\"textDocumentSync":1,
        ) catch return;
        w.writeAll(
            \\"completionProvider":{"triggerCharacters":[".","$","@","|"]},
        ) catch return;
        w.writeAll(
            \\"hoverProvider":true,
        ) catch return;
        w.writeAll(
            \\"definitionProvider":true,
        ) catch return;
        w.writeAll(
            \\"referencesProvider":true,
        ) catch return;
        w.writeAll(
            \\"renameProvider":{"prepareProvider":true},
        ) catch return;
        w.writeAll(
            \\"signatureHelpProvider":{"triggerCharacters":["(",";"]},"documentFormattingProvider":true,
        ) catch return;
        // Semantic tokens
        w.writeAll(
            \\"semanticTokensProvider":{"full":true,"legend":{"tokenTypes":["keyword","function","variable","string","number","operator","property","type"],"tokenModifiers":["declaration","builtin"]}}
        ) catch return;
        w.writeAll(
            \\},"serverInfo":{"name":"zq-lsp","version":"0.1.0"}}}
        ) catch return;

        self.transport.writeMessage(buf.items) catch {};
    }

    fn handleDidOpen(self: *Server, params: ?std.json.Value) void {
        const p = params orelse return;
        const td = getObject(p, "textDocument") orelse return;
        const uri = getString(td, "uri") orelse return;
        const text = getString(td, "text") orelse return;

        const uri_owned = self.alloc.dupe(u8, uri) catch return;
        const text_owned = self.alloc.dupe(u8, text) catch return;

        self.openDocument(uri_owned, text_owned);
    }

    fn handleDidChange(self: *Server, params: ?std.json.Value) void {
        const p = params orelse return;
        const td = getObject(p, "textDocument") orelse return;
        const uri = getString(td, "uri") orelse return;

        const changes = switch (p) {
            .object => |o| o.get("contentChanges") orelse return,
            else => return,
        };
        const arr = switch (changes) {
            .array => |a| a,
            else => return,
        };
        if (arr.items.len == 0) return;

        // Full document sync — use last change
        const last = arr.items[arr.items.len - 1];
        const new_text = getString(last, "text") orelse return;

        if (self.documents.getPtr(uri)) |doc| {
            self.alloc.free(doc.source);
            if (doc.parse_result) |*pr| pr.deinit();
            if (doc.model) |*m| m.deinit();

            doc.source = self.alloc.dupe(u8, new_text) catch return;
            self.reparse(doc);
        }
    }

    fn handleDidClose(self: *Server, params: ?std.json.Value) void {
        const p = params orelse return;
        const td = getObject(p, "textDocument") orelse return;
        const uri = getString(td, "uri") orelse return;

        if (self.documents.fetchRemove(uri)) |kv| {
            var doc = kv.value;
            doc.deinit(self.alloc);
        }
    }

    fn handleCompletion(self: *Server, id: ?std.json.Value, params: ?std.json.Value) void {
        const doc = self.getDocFromParams(params) orelse {
            self.sendResult(id, .null);
            return;
        };
        const offset = self.getOffset(params, doc) orelse {
            self.sendResult(id, .null);
            return;
        };

        const model_ptr: ?*const analysis.SemanticModel = if (doc.model) |*m| m else null;
        const pr_ptr: ?*const ast.ParseResult = if (doc.parse_result) |*pr| pr else null;
        const items = completion_feat.complete(doc.source, offset, model_ptr, pr_ptr, self.alloc);
        defer if (items.len > 0) self.alloc.free(items);

        self.sendCompletionItems(id, items);
    }

    fn handleHover(self: *Server, id: ?std.json.Value, params: ?std.json.Value) void {
        const doc = self.getDocFromParams(params) orelse {
            self.sendResult(id, .null);
            return;
        };
        const offset = self.getOffset(params, doc) orelse {
            self.sendResult(id, .null);
            return;
        };

        const pr = if (doc.parse_result) |*p| p else {
            self.sendResult(id, .null);
            return;
        };
        const model = if (doc.model) |*m| m else {
            self.sendResult(id, .null);
            return;
        };

        if (hover_feat.hover(doc.source, offset, pr.root, model, self.alloc)) |h| {
            self.sendHover(id, h);
        } else {
            self.sendResult(id, .null);
        }
    }

    fn handleDefinition(self: *Server, id: ?std.json.Value, params: ?std.json.Value) void {
        const doc = self.getDocFromParams(params) orelse {
            self.sendResult(id, .null);
            return;
        };
        const offset = self.getOffset(params, doc) orelse {
            self.sendResult(id, .null);
            return;
        };

        const pr = if (doc.parse_result) |*p| p else {
            self.sendResult(id, .null);
            return;
        };
        const model = if (doc.model) |*m| m else {
            self.sendResult(id, .null);
            return;
        };

        if (definition_feat.definition(doc.source, offset, pr.root, model, doc.uri)) |loc| {
            self.sendLocation(id, loc);
        } else {
            self.sendResult(id, .null);
        }
    }

    fn handleReferences(self: *Server, id: ?std.json.Value, params: ?std.json.Value) void {
        const doc = self.getDocFromParams(params) orelse {
            self.sendResult(id, .null);
            return;
        };
        const offset = self.getOffset(params, doc) orelse {
            self.sendResult(id, .null);
            return;
        };

        const pr = if (doc.parse_result) |*p| p else {
            self.sendResult(id, .null);
            return;
        };
        const model = if (doc.model) |*m| m else {
            self.sendResult(id, .null);
            return;
        };

        const locs = references_feat.findReferences(doc.source, offset, pr.root, model, doc.uri, self.alloc);
        defer if (locs.len > 0) self.alloc.free(locs);

        self.sendLocations(id, locs);
    }

    fn handleRename(self: *Server, id: ?std.json.Value, params: ?std.json.Value) void {
        const doc = self.getDocFromParams(params) orelse {
            self.sendResult(id, .null);
            return;
        };
        const offset = self.getOffset(params, doc) orelse {
            self.sendResult(id, .null);
            return;
        };
        const p = params orelse {
            self.sendResult(id, .null);
            return;
        };
        const new_name = getString(p, "newName") orelse {
            self.sendResult(id, .null);
            return;
        };

        const pr = if (doc.parse_result) |*pp| pp else {
            self.sendResult(id, .null);
            return;
        };
        const model = if (doc.model) |*m| m else {
            self.sendResult(id, .null);
            return;
        };

        const edits = rename_feat.rename(doc.source, offset, new_name, pr.root, model, self.alloc);
        defer if (edits.len > 0) self.alloc.free(edits);

        self.sendWorkspaceEdit(id, doc.uri, edits);
    }

    fn handlePrepareRename(self: *Server, id: ?std.json.Value, params: ?std.json.Value) void {
        const doc = self.getDocFromParams(params) orelse {
            self.sendResult(id, .null);
            return;
        };
        const offset = self.getOffset(params, doc) orelse {
            self.sendResult(id, .null);
            return;
        };

        const pr = if (doc.parse_result) |*p| p else {
            self.sendResult(id, .null);
            return;
        };
        const model = if (doc.model) |*m| m else {
            self.sendResult(id, .null);
            return;
        };

        if (rename_feat.prepareRename(doc.source, offset, pr.root, model)) |prep| {
            self.sendPrepareRename(id, prep);
        } else {
            self.sendResult(id, .null);
        }
    }

    fn handleSignatureHelp(self: *Server, id: ?std.json.Value, params: ?std.json.Value) void {
        const doc = self.getDocFromParams(params) orelse {
            self.sendResult(id, .null);
            return;
        };
        const offset = self.getOffset(params, doc) orelse {
            self.sendResult(id, .null);
            return;
        };

        if (signature_feat.signatureHelp(doc.source, offset)) |sig| {
            self.sendSignatureHelp(id, sig);
        } else {
            self.sendResult(id, .null);
        }
    }

    fn handleSemanticTokens(self: *Server, id: ?std.json.Value, params: ?std.json.Value) void {
        const doc = self.getDocFromParams(params) orelse {
            self.sendResult(id, .null);
            return;
        };

        const pr = if (doc.parse_result) |*p| p else {
            self.sendResult(id, .null);
            return;
        };

        const tokens = semantic_feat.encode(pr.root, doc.source, self.alloc);
        defer if (tokens.len > 0) self.alloc.free(tokens);

        self.sendSemanticTokens(id, tokens);
    }

    fn handleFormatting(self: *Server, id: ?std.json.Value, params: ?std.json.Value) void {
        const doc = self.getDocFromParams(params) orelse {
            self.sendResult(id, .null);
            return;
        };

        const pr = if (doc.parse_result) |*p| p else {
            self.sendResult(id, .null);
            return;
        };

        const formatted = formatting_feat.format(pr.root, self.alloc);
        if (formatted.len == 0) {
            self.sendResult(id, .null);
            return;
        }
        defer self.alloc.free(formatted);

        // Single edit replacing entire document
        const end_pos = protocol.byteOffsetToPosition(doc.source, @intCast(doc.source.len));
        self.sendTextEdits(id, .{
            .start = .{ .line = 0, .character = 0 },
            .end = end_pos,
        }, formatted);
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    fn openDocument(self: *Server, uri: []const u8, source: []const u8) void {
        var doc = Document{
            .uri = uri,
            .source = source,
            .parse_result = null,
            .model = null,
        };
        self.reparse(&doc);
        self.documents.put(uri, doc) catch {};
    }

    fn reparse(self: *Server, doc: *Document) void {
        doc.parse_result = ast.parse(doc.source, self.alloc);
        if (doc.parse_result) |*pr| {
            doc.model = analysis.SemanticModel.analyze(pr.root, self.alloc);
        }

        // Publish diagnostics
        if (doc.parse_result) |*pr| {
            const diags = diagnostics_feat.fromParseErrors(pr.errors, doc.source, self.alloc);
            defer if (diags.len > 0) self.alloc.free(diags);
            self.publishDiagnostics(doc.uri, diags);
        }
    }

    fn getDocFromParams(self: *Server, params: ?std.json.Value) ?*Document {
        const p = params orelse return null;
        const td = getObject(p, "textDocument") orelse return null;
        const uri = getString(td, "uri") orelse return null;
        return self.documents.getPtr(uri);
    }

    fn getOffset(self: *Server, params: ?std.json.Value, doc: *const Document) ?u32 {
        _ = self;
        const p = params orelse return null;
        const pos = getObject(p, "position") orelse return null;
        const line = getInt(pos, "line") orelse return null;
        const character = getInt(pos, "character") orelse return null;

        // Convert line/character to byte offset
        var byte_offset: u32 = 0;
        var current_line: u32 = 0;
        for (doc.source, 0..) |c, i| {
            if (current_line == line) {
                const utf8_offset = protocol.utf16ToUtf8Offset(doc.source[i..], character);
                return byte_offset + utf8_offset;
            }
            if (c == '\n') {
                current_line += 1;
            }
            byte_offset += 1;
        }
        if (current_line == line) return byte_offset;
        return null;
    }

    // ── JSON response helpers ───────────────────────────────────────────

    fn sendResult(self: *Server, id: ?std.json.Value, result: std.json.Value) void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.alloc);
        const w = buf.writer(self.alloc);

        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        writeJsonValue(w, id) catch return;
        w.writeAll(",\"result\":") catch return;
        writeJsonValue(w, result) catch return;
        w.writeAll("}") catch return;

        self.transport.writeMessage(buf.items) catch {};
    }

    fn sendError(self: *Server, id: ?std.json.Value, code: i32, message: []const u8) void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.alloc);
        const w = buf.writer(self.alloc);

        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        writeJsonValue(w, id) catch return;
        w.print(",\"error\":{{\"code\":{d},\"message\":", .{code}) catch return;
        writeJsonString(w, message) catch return;
        w.writeAll("}}") catch return;

        self.transport.writeMessage(buf.items) catch {};
    }

    fn publishDiagnostics(self: *Server, uri: []const u8, diags: []const protocol.Diagnostic) void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.alloc);
        const w = buf.writer(self.alloc);

        w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":") catch return;
        writeJsonString(w, uri) catch return;
        w.writeAll(",\"diagnostics\":[") catch return;

        for (diags, 0..) |d, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"source\":\"zq\",\"message\":", .{
                d.range.start.line,
                d.range.start.character,
                d.range.end.line,
                d.range.end.character,
                @intFromEnum(d.severity),
            }) catch return;
            writeJsonString(w, d.message) catch return;
            w.writeAll("}") catch return;
        }

        w.writeAll("]}}") catch return;
        self.transport.writeMessage(buf.items) catch {};
    }

    fn sendCompletionItems(self: *Server, id: ?std.json.Value, items: []const protocol.CompletionItem) void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.alloc);
        const w = buf.writer(self.alloc);

        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        writeJsonValue(w, id) catch return;
        w.writeAll(",\"result\":[") catch return;

        for (items, 0..) |item, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.print("{{\"label\":", .{}) catch return;
            writeJsonString(w, item.label) catch return;
            w.print(",\"kind\":{d}", .{@intFromEnum(item.kind)}) catch return;
            if (item.detail) |d| {
                w.writeAll(",\"detail\":") catch return;
                writeJsonString(w, d) catch return;
            }
            if (item.documentation) |d| {
                w.writeAll(",\"documentation\":") catch return;
                writeJsonString(w, d) catch return;
            }
            if (item.insertText) |t| {
                w.writeAll(",\"insertText\":") catch return;
                writeJsonString(w, t) catch return;
            }
            if (item.insertTextFormat) |f| {
                w.print(",\"insertTextFormat\":{d}", .{@intFromEnum(f)}) catch return;
            }
            w.writeAll("}") catch return;
        }

        w.writeAll("]}") catch return;
        self.transport.writeMessage(buf.items) catch {};
    }

    fn sendHover(self: *Server, id: ?std.json.Value, h: protocol.Hover) void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.alloc);
        const w = buf.writer(self.alloc);

        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        writeJsonValue(w, id) catch return;
        w.writeAll(",\"result\":{\"contents\":{\"kind\":\"markdown\",\"value\":") catch return;
        writeJsonString(w, h.contents.value) catch return;
        w.writeAll("}}}") catch return;

        self.transport.writeMessage(buf.items) catch {};
    }

    fn sendLocation(self: *Server, id: ?std.json.Value, loc: protocol.Location) void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.alloc);
        const w = buf.writer(self.alloc);

        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        writeJsonValue(w, id) catch return;
        w.writeAll(",\"result\":{\"uri\":") catch return;
        writeJsonString(w, loc.uri) catch return;
        writeRange(w, loc.range) catch return;
        w.writeAll("}}") catch return;

        self.transport.writeMessage(buf.items) catch {};
    }

    fn sendLocations(self: *Server, id: ?std.json.Value, locs: []const protocol.Location) void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.alloc);
        const w = buf.writer(self.alloc);

        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        writeJsonValue(w, id) catch return;
        w.writeAll(",\"result\":[") catch return;

        for (locs, 0..) |loc, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("{\"uri\":") catch return;
            writeJsonString(w, loc.uri) catch return;
            writeRange(w, loc.range) catch return;
            w.writeAll("}") catch return;
        }

        w.writeAll("]}") catch return;
        self.transport.writeMessage(buf.items) catch {};
    }

    fn sendWorkspaceEdit(self: *Server, id: ?std.json.Value, uri: []const u8, edits: []const rename_feat.RenameEdit) void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.alloc);
        const w = buf.writer(self.alloc);

        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        writeJsonValue(w, id) catch return;
        w.writeAll(",\"result\":{\"changes\":{") catch return;
        writeJsonString(w, uri) catch return;
        w.writeAll(":[") catch return;

        for (edits, 0..) |edit, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("{") catch return;
            writeRange(w, edit.range) catch return;
            w.writeAll(",\"newText\":") catch return;
            writeJsonString(w, edit.new_text) catch return;
            w.writeAll("}") catch return;
        }

        w.writeAll("]}}}") catch return;
        self.transport.writeMessage(buf.items) catch {};
    }

    fn sendPrepareRename(self: *Server, id: ?std.json.Value, prep: anytype) void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.alloc);
        const w = buf.writer(self.alloc);

        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        writeJsonValue(w, id) catch return;
        w.writeAll(",\"result\":{") catch return;
        writeRange(w, prep.range) catch return;
        w.writeAll(",\"placeholder\":") catch return;
        writeJsonString(w, prep.placeholder) catch return;
        w.writeAll("}}") catch return;

        self.transport.writeMessage(buf.items) catch {};
    }

    fn sendSignatureHelp(self: *Server, id: ?std.json.Value, sig: signature_feat.SignatureHelp) void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.alloc);
        const w = buf.writer(self.alloc);

        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        writeJsonValue(w, id) catch return;
        w.writeAll(",\"result\":{\"signatures\":[{\"label\":") catch return;
        writeJsonString(w, sig.label) catch return;
        w.writeAll(",\"documentation\":") catch return;
        writeJsonString(w, sig.documentation) catch return;
        w.print(",\"activeParameter\":{d}", .{sig.active_parameter}) catch return;
        w.writeAll("}],\"activeSignature\":0}}") catch return;

        self.transport.writeMessage(buf.items) catch {};
    }

    fn sendSemanticTokens(self: *Server, id: ?std.json.Value, tokens: []const u32) void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.alloc);
        const w = buf.writer(self.alloc);

        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        writeJsonValue(w, id) catch return;
        w.writeAll(",\"result\":{\"data\":[") catch return;

        for (tokens, 0..) |t, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.print("{d}", .{t}) catch return;
        }

        w.writeAll("]}}") catch return;
        self.transport.writeMessage(buf.items) catch {};
    }

    fn sendTextEdits(self: *Server, id: ?std.json.Value, range: protocol.Range, new_text: []const u8) void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.alloc);
        const w = buf.writer(self.alloc);

        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        writeJsonValue(w, id) catch return;
        w.writeAll(",\"result\":[{") catch return;
        writeRange(w, range) catch return;
        w.writeAll(",\"newText\":") catch return;
        writeJsonString(w, new_text) catch return;
        w.writeAll("}]}") catch return;

        self.transport.writeMessage(buf.items) catch {};
    }
};

// ── JSON writing utilities ──────────────────────────────────────────────

fn writeJsonValue(w: anytype, val: ?std.json.Value) !void {
    if (val) |v| {
        switch (v) {
            .integer => |i| try w.print("{d}", .{i}),
            .string => |s| try writeJsonString(w, s),
            .null => try w.writeAll("null"),
            .bool => |b| try w.writeAll(if (b) "true" else "false"),
            else => try w.writeAll("null"),
        }
    } else {
        try w.writeAll("null");
    }
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeAll("\"");
}

fn writeRange(w: anytype, range: protocol.Range) !void {
    try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
        range.start.line,
        range.start.character,
        range.end.line,
        range.end.character,
    });
}

fn getObject(val: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (val) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn getString(val: std.json.Value, key: []const u8) ?[]const u8 {
    const v = getObject(val, key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getInt(val: std.json.Value, key: []const u8) ?u32 {
    const v = getObject(val, key) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(@as(u64, @intCast(i))) else null,
        else => null,
    };
}
