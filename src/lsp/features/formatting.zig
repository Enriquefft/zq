const std = @import("std");
const ast = @import("ast");

/// Format a jq filter expression with consistent style.
pub fn format(root: *const ast.Node, alloc: std.mem.Allocator) []const u8 {
    var buf = std.ArrayList(u8){};
    formatNode(root, &buf, alloc, 0);
    return buf.toOwnedSlice(alloc) catch "";
}

fn formatNode(node: *const ast.Node, buf: *std.ArrayList(u8), alloc: std.mem.Allocator, indent: u32) void {
    switch (node.kind) {
        .pipe => |pipe| {
            formatNode(pipe.left, buf, alloc, indent);
            buf.appendSlice(alloc, " | ") catch {};
            formatNode(pipe.right, buf, alloc, indent);
        },
        .comma => |comma| {
            formatNode(comma.left, buf, alloc, indent);
            buf.appendSlice(alloc, ", ") catch {};
            formatNode(comma.right, buf, alloc, indent);
        },
        .identity => buf.appendSlice(alloc, ".") catch {},
        .recurse => buf.appendSlice(alloc, "..") catch {},
        .field_access => |fa| {
            buf.append(alloc, '.') catch {};
            buf.appendSlice(alloc, fa.name) catch {};
        },
        .index_access => |ia| {
            buf.appendSlice(alloc, ".[") catch {};
            var num_buf: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{ia.index}) catch "";
            buf.appendSlice(alloc, s) catch {};
            buf.append(alloc, ']') catch {};
        },
        .iterate => buf.appendSlice(alloc, ".[]") catch {},
        .literal => |lit| {
            switch (lit) {
                .int => |n| {
                    var num_buf: [20]u8 = undefined;
                    const s = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch "";
                    buf.appendSlice(alloc, s) catch {};
                },
                .float => |f| {
                    var num_buf: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&num_buf, "{d}", .{f}) catch "";
                    buf.appendSlice(alloc, s) catch {};
                },
                .string => |s| {
                    buf.append(alloc, '"') catch {};
                    buf.appendSlice(alloc, s) catch {};
                    buf.append(alloc, '"') catch {};
                },
                .bool_val => |b| buf.appendSlice(alloc, if (b) "true" else "false") catch {},
                .null_val => buf.appendSlice(alloc, "null") catch {},
            }
        },
        .variable_ref => |vr| {
            buf.append(alloc, '$') catch {};
            buf.appendSlice(alloc, vr.name) catch {};
        },
        .paren => |un| {
            buf.append(alloc, '(') catch {};
            formatNode(un.operand, buf, alloc, indent);
            buf.append(alloc, ')') catch {};
        },
        .unary_neg => |un| {
            buf.append(alloc, '-') catch {};
            formatNode(un.operand, buf, alloc, indent);
        },
        .optional => |un| {
            formatNode(un.operand, buf, alloc, indent);
            buf.append(alloc, '?') catch {};
        },
        .alternative => |bin| {
            formatNode(bin.left, buf, alloc, indent);
            buf.appendSlice(alloc, " // ") catch {};
            formatNode(bin.right, buf, alloc, indent);
        },
        .or_expr => |bin| {
            formatNode(bin.left, buf, alloc, indent);
            buf.appendSlice(alloc, " or ") catch {};
            formatNode(bin.right, buf, alloc, indent);
        },
        .and_expr => |bin| {
            formatNode(bin.left, buf, alloc, indent);
            buf.appendSlice(alloc, " and ") catch {};
            formatNode(bin.right, buf, alloc, indent);
        },
        .comparison => |cmp| {
            formatNode(cmp.left, buf, alloc, indent);
            const op_str: []const u8 = switch (cmp.op) {
                .eq => " == ",
                .ne => " != ",
                .lt => " < ",
                .le => " <= ",
                .gt => " > ",
                .ge => " >= ",
            };
            buf.appendSlice(alloc, op_str) catch {};
            formatNode(cmp.right, buf, alloc, indent);
        },
        .arithmetic => |arith| {
            formatNode(arith.left, buf, alloc, indent);
            const op_str: []const u8 = switch (arith.op) {
                .add => " + ",
                .sub => " - ",
                .mul => " * ",
                .div => " / ",
                .mod => " % ",
            };
            buf.appendSlice(alloc, op_str) catch {};
            formatNode(arith.right, buf, alloc, indent);
        },
        .builtin_call => |bc| {
            buf.appendSlice(alloc, bc.name) catch {};
            if (bc.args.len > 0) {
                buf.append(alloc, '(') catch {};
                for (bc.args, 0..) |arg, i| {
                    if (i > 0) buf.appendSlice(alloc, "; ") catch {};
                    formatNode(arg, buf, alloc, indent);
                }
                buf.append(alloc, ')') catch {};
            }
        },
        .func_call => |fc| {
            buf.appendSlice(alloc, fc.name) catch {};
            if (fc.args.len > 0) {
                buf.append(alloc, '(') catch {};
                for (fc.args, 0..) |arg, i| {
                    if (i > 0) buf.appendSlice(alloc, "; ") catch {};
                    formatNode(arg, buf, alloc, indent);
                }
                buf.append(alloc, ')') catch {};
            }
        },
        .func_def => |fd| {
            buf.appendSlice(alloc, "def ") catch {};
            buf.appendSlice(alloc, fd.name) catch {};
            if (fd.params.len > 0) {
                buf.append(alloc, '(') catch {};
                for (fd.params, 0..) |param, i| {
                    if (i > 0) buf.appendSlice(alloc, "; ") catch {};
                    if (!param.is_filter) buf.append(alloc, '$') catch {};
                    buf.appendSlice(alloc, param.name) catch {};
                }
                buf.append(alloc, ')') catch {};
            }
            buf.appendSlice(alloc, ": ") catch {};
            formatNode(fd.body, buf, alloc, indent + 1);
            buf.appendSlice(alloc, "; ") catch {};
            formatNode(fd.rest, buf, alloc, indent);
        },
        .if_expr => |ie| {
            buf.appendSlice(alloc, "if ") catch {};
            formatNode(ie.cond, buf, alloc, indent);
            buf.appendSlice(alloc, " then ") catch {};
            formatNode(ie.then_body, buf, alloc, indent + 1);
            for (ie.elif_chains) |chain| {
                buf.appendSlice(alloc, " elif ") catch {};
                formatNode(chain.cond, buf, alloc, indent);
                buf.appendSlice(alloc, " then ") catch {};
                formatNode(chain.body, buf, alloc, indent + 1);
            }
            if (ie.else_body) |eb| {
                buf.appendSlice(alloc, " else ") catch {};
                formatNode(eb, buf, alloc, indent + 1);
            }
            buf.appendSlice(alloc, " end") catch {};
        },
        .try_catch => |tc| {
            buf.appendSlice(alloc, "try ") catch {};
            formatNode(tc.body, buf, alloc, indent);
            if (tc.catch_body) |cb| {
                buf.appendSlice(alloc, " catch ") catch {};
                formatNode(cb, buf, alloc, indent);
            }
        },
        .array_construct => |ac| {
            buf.append(alloc, '[') catch {};
            if (ac.expr) |expr| formatNode(expr, buf, alloc, indent);
            buf.append(alloc, ']') catch {};
        },
        .object_construct => |oc| {
            buf.append(alloc, '{') catch {};
            for (oc.fields, 0..) |field, i| {
                if (i > 0) buf.appendSlice(alloc, ", ") catch {};
                switch (field.key) {
                    .ident => |name| buf.appendSlice(alloc, name) catch {},
                    .string => |s| {
                        buf.append(alloc, '"') catch {};
                        buf.appendSlice(alloc, s) catch {};
                        buf.append(alloc, '"') catch {};
                    },
                    .expr => |expr| {
                        buf.append(alloc, '(') catch {};
                        formatNode(expr, buf, alloc, indent);
                        buf.append(alloc, ')') catch {};
                    },
                }
                buf.appendSlice(alloc, ": ") catch {};
                formatNode(field.value, buf, alloc, indent);
            }
            buf.append(alloc, '}') catch {};
        },
        .reduce => |red| {
            buf.appendSlice(alloc, "reduce ") catch {};
            formatNode(red.expr, buf, alloc, indent);
            buf.appendSlice(alloc, " as ") catch {};
            formatPattern(&red.pattern, buf, alloc);
            buf.appendSlice(alloc, " (") catch {};
            formatNode(red.init, buf, alloc, indent);
            buf.appendSlice(alloc, "; ") catch {};
            formatNode(red.update, buf, alloc, indent);
            buf.append(alloc, ')') catch {};
        },
        .label_expr => |le| {
            buf.appendSlice(alloc, "label $") catch {};
            buf.appendSlice(alloc, le.name) catch {};
            buf.appendSlice(alloc, " | ") catch {};
            formatNode(le.body, buf, alloc, indent);
        },
        .break_expr => |be| {
            buf.appendSlice(alloc, "break $") catch {};
            buf.appendSlice(alloc, be.name) catch {};
        },
        .suffix => |suf| {
            formatNode(suf.base, buf, alloc, indent);
            for (suf.ops) |op| {
                switch (op) {
                    .field => |name| {
                        buf.append(alloc, '.') catch {};
                        buf.appendSlice(alloc, name) catch {};
                    },
                    .index => |idx| {
                        buf.append(alloc, '[') catch {};
                        var num_buf: [20]u8 = undefined;
                        const s = std.fmt.bufPrint(&num_buf, "{d}", .{idx}) catch "";
                        buf.appendSlice(alloc, s) catch {};
                        buf.append(alloc, ']') catch {};
                    },
                    .iterate => buf.appendSlice(alloc, "[]") catch {},
                    .optional => buf.append(alloc, '?') catch {},
                    .slice => |sl| {
                        buf.append(alloc, '[') catch {};
                        if (sl.has_from) {
                            var num_buf: [20]u8 = undefined;
                            const s = std.fmt.bufPrint(&num_buf, "{d}", .{sl.from}) catch "";
                            buf.appendSlice(alloc, s) catch {};
                        }
                        buf.append(alloc, ':') catch {};
                        if (sl.has_to) {
                            var num_buf: [20]u8 = undefined;
                            const s = std.fmt.bufPrint(&num_buf, "{d}", .{sl.to}) catch "";
                            buf.appendSlice(alloc, s) catch {};
                        }
                        buf.append(alloc, ']') catch {};
                    },
                    .bracket_str => |name| {
                        buf.appendSlice(alloc, "[\"") catch {};
                        buf.appendSlice(alloc, name) catch {};
                        buf.appendSlice(alloc, "\"]") catch {};
                    },
                    .bracket_expr => |expr| {
                        buf.append(alloc, '[') catch {};
                        formatNode(expr, buf, alloc, indent);
                        buf.append(alloc, ']') catch {};
                    },
                }
            }
        },
        .as_pattern => |ap| {
            formatNode(ap.expr, buf, alloc, indent);
            buf.appendSlice(alloc, " as ") catch {};
            formatPattern(&ap.pattern, buf, alloc);
            buf.appendSlice(alloc, " | ") catch {};
            formatNode(ap.body, buf, alloc, indent);
        },
        .string_interp => |si| {
            buf.append(alloc, '"') catch {};
            for (si.parts) |part| {
                switch (part) {
                    .literal => |s| buf.appendSlice(alloc, s) catch {},
                    .expr => |expr| {
                        buf.appendSlice(alloc, "\\(") catch {};
                        formatNode(expr, buf, alloc, indent);
                        buf.append(alloc, ')') catch {};
                    },
                }
            }
            buf.append(alloc, '"') catch {};
        },
        .format_string => |fs| {
            buf.append(alloc, '@') catch {};
            buf.appendSlice(alloc, fs.format) catch {};
            buf.append(alloc, ' ') catch {};
            buf.append(alloc, '"') catch {};
            for (fs.parts) |part| {
                switch (part) {
                    .literal => |s| buf.appendSlice(alloc, s) catch {},
                    .expr => |expr| {
                        buf.appendSlice(alloc, "\\(") catch {};
                        formatNode(expr, buf, alloc, indent);
                        buf.append(alloc, ')') catch {};
                    },
                }
            }
            buf.append(alloc, '"') catch {};
        },
        .update_assign => |ua| {
            buf.append(alloc, '.') catch {};
            for (ua.path) |step| {
                switch (step) {
                    .key => |name| {
                        buf.appendSlice(alloc, name) catch {};
                        buf.append(alloc, '.') catch {};
                    },
                    .index => |idx| {
                        buf.append(alloc, '[') catch {};
                        var num_buf: [20]u8 = undefined;
                        const s = std.fmt.bufPrint(&num_buf, "{d}", .{idx}) catch "";
                        buf.appendSlice(alloc, s) catch {};
                        buf.append(alloc, ']') catch {};
                    },
                    .iterate => buf.appendSlice(alloc, "[]") catch {},
                }
            }
            const op_str: []const u8 = switch (ua.op) {
                .pipe_eq => " |= ",
                .eq => " = ",
                .plus_eq => " += ",
                .minus_eq => " -= ",
                .star_eq => " *= ",
                .slash_eq => " /= ",
                .percent_eq => " %= ",
                .double_slash_eq => " //= ",
            };
            buf.appendSlice(alloc, op_str) catch {};
            formatNode(ua.rhs, buf, alloc, indent);
        },
        .foreach => |fe| {
            buf.appendSlice(alloc, "foreach ") catch {};
            formatNode(fe.expr, buf, alloc, indent);
            buf.appendSlice(alloc, " as ") catch {};
            formatPattern(&fe.pattern, buf, alloc);
            buf.appendSlice(alloc, " (") catch {};
            formatNode(fe.init, buf, alloc, indent);
            buf.appendSlice(alloc, "; ") catch {};
            formatNode(fe.update, buf, alloc, indent);
            if (fe.extract) |ext| {
                buf.appendSlice(alloc, "; ") catch {};
                formatNode(ext, buf, alloc, indent);
            }
            buf.append(alloc, ')') catch {};
        },
        .destruct_alt => |da| {
            formatNode(da.expr, buf, alloc, indent);
            buf.appendSlice(alloc, " as ") catch {};
            for (da.patterns, 0..) |*pat, i| {
                if (i > 0) buf.appendSlice(alloc, " ?// ") catch {};
                formatPattern(pat, buf, alloc);
            }
            buf.appendSlice(alloc, " | ") catch {};
            formatNode(da.body, buf, alloc, indent);
        },
        .error_node => buf.appendSlice(alloc, "/* error */") catch {},
        .slice => |sl| {
            buf.appendSlice(alloc, ".[") catch {};
            if (sl.has_from) {
                var num_buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{sl.from}) catch "";
                buf.appendSlice(alloc, s) catch {};
            }
            buf.append(alloc, ':') catch {};
            if (sl.has_to) {
                var num_buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{sl.to}) catch "";
                buf.appendSlice(alloc, s) catch {};
            }
            buf.append(alloc, ']') catch {};
        },
    }
}

fn formatPattern(pattern: *const ast.Pattern, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) void {
    switch (pattern.*) {
        .simple => |name| {
            buf.append(alloc, '$') catch {};
            buf.appendSlice(alloc, name) catch {};
        },
        .array => |elements| {
            buf.append(alloc, '[') catch {};
            for (elements, 0..) |*elem, i| {
                if (i > 0) buf.appendSlice(alloc, ", ") catch {};
                formatPattern(elem, buf, alloc);
            }
            buf.append(alloc, ']') catch {};
        },
        .object => |fields| {
            buf.append(alloc, '{') catch {};
            for (fields, 0..) |*field, i| {
                if (i > 0) buf.appendSlice(alloc, ", ") catch {};
                switch (field.key) {
                    .static => |name| buf.appendSlice(alloc, name) catch {},
                    .computed => |expr| {
                        buf.append(alloc, '(') catch {};
                        formatNode(expr, buf, alloc, 0);
                        buf.append(alloc, ')') catch {};
                    },
                }
                buf.appendSlice(alloc, ": ") catch {};
                formatPattern(&field.pattern, buf, alloc);
            }
            buf.append(alloc, '}') catch {};
        },
    }
}
