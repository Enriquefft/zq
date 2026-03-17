const std = @import("std");
const ast = @import("ast");
const Node = ast.Node;
const Span = ast.Span;
const builtins_mod = @import("builtins.zig");

/// A symbol in the semantic model.
pub const Symbol = struct {
    name: []const u8,
    kind: Kind,
    span: Span, // declaration site
    scope_id: u32,

    pub const Kind = enum {
        variable,
        function,
        parameter,
        label,
    };
};

/// A reference to a symbol.
pub const Reference = struct {
    symbol_id: u32,
    span: Span,
    is_definition: bool,
};

/// Scope in the scope tree.
pub const Scope = struct {
    parent: ?u32,
    symbols: std.ArrayList(u32), // indices into SemanticModel.symbols
};

/// Semantic model built from an AST walk.
pub const SemanticModel = struct {
    symbols: std.ArrayList(Symbol),
    references: std.ArrayList(Reference),
    scopes: std.ArrayList(Scope),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) SemanticModel {
        return .{
            .symbols = std.ArrayList(Symbol){},
            .references = std.ArrayList(Reference){},
            .scopes = std.ArrayList(Scope){},
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *SemanticModel) void {
        for (self.scopes.items) |*scope| {
            scope.symbols.deinit(self.alloc);
        }
        self.scopes.deinit(self.alloc);
        self.references.deinit(self.alloc);
        self.symbols.deinit(self.alloc);
    }

    /// Build semantic model from an AST.
    pub fn analyze(root: *const Node, alloc: std.mem.Allocator) SemanticModel {
        var model = SemanticModel.init(alloc);

        // Create root scope with builtins
        const root_scope = model.pushScope(null);

        // Add builtin symbols to root scope
        for (builtins_mod.builtins) |b| {
            const sym_id = model.addSymbol(.{
                .name = b.name,
                .kind = .function,
                .span = Span.empty(),
                .scope_id = root_scope,
            });
            model.addToScope(root_scope, sym_id);
        }

        // Walk the AST
        model.walkNode(root, root_scope);

        return model;
    }

    fn pushScope(self: *SemanticModel, parent: ?u32) u32 {
        const id: u32 = @intCast(self.scopes.items.len);
        self.scopes.append(self.alloc, .{
            .parent = parent,
            .symbols = std.ArrayList(u32){},
        }) catch {};
        return id;
    }

    fn addSymbol(self: *SemanticModel, sym: Symbol) u32 {
        const id: u32 = @intCast(self.symbols.items.len);
        self.symbols.append(self.alloc, sym) catch {};
        return id;
    }

    fn addToScope(self: *SemanticModel, scope_id: u32, sym_id: u32) void {
        if (scope_id < self.scopes.items.len) {
            self.scopes.items[scope_id].symbols.append(self.alloc, sym_id) catch {};
        }
    }

    fn addReference(self: *SemanticModel, sym_id: u32, span: Span, is_def: bool) void {
        self.references.append(self.alloc, .{
            .symbol_id = sym_id,
            .span = span,
            .is_definition = is_def,
        }) catch {};
    }

    fn lookupInScope(self: *SemanticModel, name: []const u8, scope_id: u32) ?u32 {
        var current: ?u32 = scope_id;
        while (current) |sid| {
            if (sid >= self.scopes.items.len) break;
            const scope = &self.scopes.items[sid];
            // Search backwards for most recent declaration
            var i = scope.symbols.items.len;
            while (i > 0) {
                i -= 1;
                const sym_id = scope.symbols.items[i];
                if (sym_id < self.symbols.items.len) {
                    if (std.mem.eql(u8, self.symbols.items[sym_id].name, name)) {
                        return sym_id;
                    }
                }
            }
            current = scope.parent;
        }
        return null;
    }

    fn walkNode(self: *SemanticModel, node: *const Node, scope_id: u32) void {
        switch (node.kind) {
            .pipe => |pipe| {
                self.walkNode(pipe.left, scope_id);
                self.walkNode(pipe.right, scope_id);
            },
            .comma => |comma| {
                self.walkNode(comma.left, scope_id);
                self.walkNode(comma.right, scope_id);
            },
            .func_def => |fd| {
                // Register function in current scope
                const sym_id = self.addSymbol(.{
                    .name = fd.name,
                    .kind = .function,
                    .span = node.span,
                    .scope_id = scope_id,
                });
                self.addToScope(scope_id, sym_id);
                self.addReference(sym_id, node.span, true);

                // Create child scope for function body
                const body_scope = self.pushScope(scope_id);
                for (fd.params) |param| {
                    const param_id = self.addSymbol(.{
                        .name = param.name,
                        .kind = .parameter,
                        .span = param.span,
                        .scope_id = body_scope,
                    });
                    self.addToScope(body_scope, param_id);
                    self.addReference(param_id, param.span, true);
                }
                self.walkNode(fd.body, body_scope);
                self.walkNode(fd.rest, scope_id);
            },
            .alternative => |bin| {
                self.walkNode(bin.left, scope_id);
                self.walkNode(bin.right, scope_id);
            },
            .or_expr => |bin| {
                self.walkNode(bin.left, scope_id);
                self.walkNode(bin.right, scope_id);
            },
            .and_expr => |bin| {
                self.walkNode(bin.left, scope_id);
                self.walkNode(bin.right, scope_id);
            },
            .comparison => |cmp| {
                self.walkNode(cmp.left, scope_id);
                self.walkNode(cmp.right, scope_id);
            },
            .arithmetic => |arith| {
                self.walkNode(arith.left, scope_id);
                self.walkNode(arith.right, scope_id);
            },
            .unary_neg => |un| self.walkNode(un.operand, scope_id),
            .paren => |un| self.walkNode(un.operand, scope_id),
            .optional => |un| self.walkNode(un.operand, scope_id),
            .as_pattern => |ap| {
                self.walkNode(ap.expr, scope_id);
                const child_scope = self.pushScope(scope_id);
                self.walkPattern(&ap.pattern, child_scope);
                self.walkNode(ap.body, child_scope);
            },
            .destruct_alt => |da| {
                self.walkNode(da.expr, scope_id);
                const child_scope = self.pushScope(scope_id);
                for (da.patterns) |*pat| {
                    self.walkPattern(pat, child_scope);
                }
                self.walkNode(da.body, child_scope);
            },
            .variable_ref => |vr| {
                if (self.lookupInScope(vr.name, scope_id)) |sym_id| {
                    self.addReference(sym_id, node.span, false);
                }
            },
            .func_call => |fc| {
                if (self.lookupInScope(fc.name, scope_id)) |sym_id| {
                    self.addReference(sym_id, node.span, false);
                }
                for (fc.args) |arg| self.walkNode(arg, scope_id);
            },
            .builtin_call => |bc| {
                for (bc.args) |arg| self.walkNode(arg, scope_id);
            },
            .if_expr => |ie| {
                self.walkNode(ie.cond, scope_id);
                self.walkNode(ie.then_body, scope_id);
                for (ie.elif_chains) |chain| {
                    self.walkNode(chain.cond, scope_id);
                    self.walkNode(chain.body, scope_id);
                }
                if (ie.else_body) |eb| self.walkNode(eb, scope_id);
            },
            .try_catch => |tc| {
                self.walkNode(tc.body, scope_id);
                if (tc.catch_body) |cb| self.walkNode(cb, scope_id);
            },
            .reduce => |red| {
                self.walkNode(red.expr, scope_id);
                const child_scope = self.pushScope(scope_id);
                self.walkPattern(&red.pattern, child_scope);
                self.walkNode(red.init, child_scope);
                self.walkNode(red.update, child_scope);
            },
            .foreach => |fe| {
                self.walkNode(fe.expr, scope_id);
                const child_scope = self.pushScope(scope_id);
                self.walkPattern(&fe.pattern, child_scope);
                self.walkNode(fe.init, child_scope);
                self.walkNode(fe.update, child_scope);
                if (fe.extract) |ext| self.walkNode(ext, child_scope);
            },
            .label_expr => |le| {
                const child_scope = self.pushScope(scope_id);
                const sym_id = self.addSymbol(.{
                    .name = le.name,
                    .kind = .label,
                    .span = node.span,
                    .scope_id = child_scope,
                });
                self.addToScope(child_scope, sym_id);
                self.walkNode(le.body, child_scope);
            },
            .break_expr => |be| {
                if (self.lookupInScope(be.name, scope_id)) |sym_id| {
                    self.addReference(sym_id, node.span, false);
                }
            },
            .array_construct => |ac| {
                if (ac.expr) |expr| self.walkNode(expr, scope_id);
            },
            .object_construct => |oc| {
                for (oc.fields) |field| {
                    switch (field.key) {
                        .expr => |expr| self.walkNode(expr, scope_id),
                        else => {},
                    }
                    self.walkNode(field.value, scope_id);
                }
            },
            .string_interp => |si| {
                for (si.parts) |part| {
                    switch (part) {
                        .expr => |expr| self.walkNode(expr, scope_id),
                        .literal => {},
                    }
                }
            },
            .format_string => |fs| {
                for (fs.parts) |part| {
                    switch (part) {
                        .expr => |expr| self.walkNode(expr, scope_id),
                        .literal => {},
                    }
                }
            },
            .update_assign => |ua| {
                self.walkNode(ua.rhs, scope_id);
            },
            .suffix => |suf| {
                self.walkNode(suf.base, scope_id);
                for (suf.ops) |op| {
                    switch (op) {
                        .bracket_expr => |expr| self.walkNode(expr, scope_id),
                        else => {},
                    }
                }
            },
            .identity, .recurse, .field_access, .index_access, .iterate, .slice, .literal, .error_node => {},
        }
    }

    fn walkPattern(self: *SemanticModel, pattern: *const ast.Pattern, scope_id: u32) void {
        switch (pattern.*) {
            .simple => |name| {
                const sym_id = self.addSymbol(.{
                    .name = name,
                    .kind = .variable,
                    .span = Span.empty(),
                    .scope_id = scope_id,
                });
                self.addToScope(scope_id, sym_id);
            },
            .array => |elements| {
                for (elements) |*elem| {
                    self.walkPattern(elem, scope_id);
                }
            },
            .object => |fields| {
                for (fields) |*field| {
                    switch (field.key) {
                        .computed => |expr| self.walkNode(expr, scope_id),
                        .static => {},
                    }
                    self.walkPattern(&field.pattern, scope_id);
                }
            },
        }
    }

    /// Find the AST node at the given byte offset.
    pub fn nodeAtOffset(root: *const Node, offset: u32) ?*const Node {
        return findNodeAt(root, offset);
    }
};

fn findNodeAt(node: *const Node, offset: u32) ?*const Node {
    if (offset < node.span.start or offset >= node.span.end) return null;

    // Try children first (more specific match)
    switch (node.kind) {
        .pipe => |pipe| {
            if (findNodeAt(pipe.left, offset)) |n| return n;
            if (findNodeAt(pipe.right, offset)) |n| return n;
        },
        .comma => |comma| {
            if (findNodeAt(comma.left, offset)) |n| return n;
            if (findNodeAt(comma.right, offset)) |n| return n;
        },
        .func_def => |fd| {
            if (findNodeAt(fd.body, offset)) |n| return n;
            if (findNodeAt(fd.rest, offset)) |n| return n;
        },
        .alternative, .or_expr, .and_expr => |bin| {
            if (findNodeAt(bin.left, offset)) |n| return n;
            if (findNodeAt(bin.right, offset)) |n| return n;
        },
        .comparison => |cmp| {
            if (findNodeAt(cmp.left, offset)) |n| return n;
            if (findNodeAt(cmp.right, offset)) |n| return n;
        },
        .arithmetic => |arith| {
            if (findNodeAt(arith.left, offset)) |n| return n;
            if (findNodeAt(arith.right, offset)) |n| return n;
        },
        .unary_neg, .paren, .optional => |un| {
            if (findNodeAt(un.operand, offset)) |n| return n;
        },
        .if_expr => |ie| {
            if (findNodeAt(ie.cond, offset)) |n| return n;
            if (findNodeAt(ie.then_body, offset)) |n| return n;
            if (ie.else_body) |eb| if (findNodeAt(eb, offset)) |n| return n;
        },
        .try_catch => |tc| {
            if (findNodeAt(tc.body, offset)) |n| return n;
            if (tc.catch_body) |cb| if (findNodeAt(cb, offset)) |n| return n;
        },
        .suffix => |suf| {
            if (findNodeAt(suf.base, offset)) |n| return n;
        },
        else => {},
    }

    return node;
}
