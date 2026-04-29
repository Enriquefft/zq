const std = @import("std");
const types = @import("types");

const Tape = types.Tape;
const Allocator = std.mem.Allocator;

/// Bitfield tracking which JSON types have been observed.
pub const TypeSet = packed struct(u8) {
    null: bool = false,
    boolean: bool = false,
    number: bool = false,
    string: bool = false,
    array: bool = false,
    object: bool = false,
    _pad: u2 = 0,

    pub fn count(self: TypeSet) u32 {
        var n: u32 = 0;
        if (self.null) n += 1;
        if (self.boolean) n += 1;
        if (self.number) n += 1;
        if (self.string) n += 1;
        if (self.array) n += 1;
        if (self.object) n += 1;
        return n;
    }
};

const FieldMap = std.StringArrayHashMapUnmanaged(*Schema);

/// Recursive schema node describing the shape of JSON data.
pub const Schema = struct {
    types: TypeSet = .{},
    /// Object field schemas (only populated when type includes object).
    fields: ?FieldMap = null,
    /// Array element schema (only populated when type includes array).
    elements: ?*Schema = null,
    /// How many records contained this field (for optional detection).
    presence_count: u64 = 0,

    fn deinit(self: *Schema, allocator: Allocator) void {
        if (self.fields) |*f| {
            for (f.values()) |child| {
                child.deinit(allocator);
                allocator.destroy(child);
            }
            for (f.keys()) |k| allocator.free(k);
            f.deinit(allocator);
            self.fields = null;
        }
        if (self.elements) |e| {
            e.deinit(allocator);
            allocator.destroy(e);
        }
    }
};

/// Streaming schema inferrer. Merges one record at a time, using O(unique_field_paths) memory.
pub const SchemaInferrer = struct {
    schema: Schema = .{},
    count: u64 = 0,
    max_depth: u32 = 12,
    allocator: Allocator,

    pub fn init(allocator: Allocator, max_depth: u32) SchemaInferrer {
        return .{
            .allocator = allocator,
            .max_depth = max_depth,
        };
    }

    pub fn deinit(self: *SchemaInferrer) void {
        self.schema.deinit(self.allocator);
    }

    /// Infer one record's schema from a tape (starting at entry 0) and merge into running schema.
    pub fn feedTape(self: *SchemaInferrer, tape: Tape) !void {
        self.count += 1;
        _ = try self.inferAndMerge(&self.schema, tape, 0, 0);
    }

    /// Walk a tape entry, infer its type, and merge into `schema`.
    /// Returns the next tape index after this entry.
    fn inferAndMerge(self: *SchemaInferrer, schema: *Schema, tape: Tape, idx: u32, depth: u32) !u32 {
        const entry = tape.entries[idx];
        switch (entry.tag) {
            .null_val => {
                schema.types.null = true;
                return idx + 1;
            },
            .true_val, .false_val => {
                schema.types.boolean = true;
                return idx + 1;
            },
            .int, .float, .big_number => {
                schema.types.number = true;
                return idx + 1;
            },
            .string => {
                schema.types.string = true;
                return idx + 1;
            },
            .object_start => {
                schema.types.object = true;
                const end_idx = entry.payload.skip;

                // If at depth cap, don't recurse into fields.
                if (self.max_depth > 0 and depth >= self.max_depth) {
                    return end_idx;
                }

                if (schema.fields == null) {
                    schema.fields = .{};
                }
                const fields = &schema.fields.?;

                var pos = idx + 1;
                while (pos < end_idx - 1) {
                    // key entry
                    const key_entry = tape.entries[pos];
                    const key_str = tape.getString(key_entry.payload.string);
                    pos += 1;

                    // Get or create child schema for this field.
                    const gop = try fields.getOrPut(self.allocator, key_str);
                    if (!gop.found_existing) {
                        // Need to dupe the key since it's borrowed from the tape.
                        const duped_key = try self.allocator.dupe(u8, key_str);
                        gop.key_ptr.* = duped_key;
                        const child = try self.allocator.create(Schema);
                        child.* = .{};
                        gop.value_ptr.* = child;
                    }
                    const child_schema = gop.value_ptr.*;
                    child_schema.presence_count += 1;

                    // Recurse into value.
                    pos = try self.inferAndMerge(child_schema, tape, pos, depth + 1);
                }
                return end_idx;
            },
            .array_start => {
                schema.types.array = true;
                const end_idx = entry.payload.skip;

                // If at depth cap, don't recurse into elements.
                if (self.max_depth > 0 and depth >= self.max_depth) {
                    return end_idx;
                }

                if (schema.elements == null) {
                    const elem = try self.allocator.create(Schema);
                    elem.* = .{};
                    schema.elements = elem;
                }
                const elem_schema = schema.elements.?;

                var pos = idx + 1;
                while (pos < end_idx - 1) {
                    pos = try self.inferAndMerge(elem_schema, tape, pos, depth + 1);
                }
                return end_idx;
            },
            else => {
                // object_end, array_end, key — should not be entry 0
                return idx + 1;
            },
        }
    }

    /// Serialize the inferred schema as JSON to a writer.
    pub fn serialize(self: *const SchemaInferrer, writer: anytype, sort_keys: bool) !void {
        if (self.count == 0) {
            try writer.writeAll("{\"type\":\"empty\",\"count\":0}");
            return;
        }
        try writer.writeByte('{');
        try serializeSchemaFields(writer, &self.schema, self.count, sort_keys);
        try writer.writeAll(",\"count\":");
        var buf: [20]u8 = undefined;
        const n = std.fmt.bufPrint(&buf, "{d}", .{self.count}) catch unreachable;
        try writer.writeAll(n);
        try writer.writeByte('}');
    }

    /// Serialize the inferred schema as pretty-printed JSON to a writer.
    pub fn serializePretty(self: *const SchemaInferrer, writer: anytype, sort_keys: bool, indent: Indent) !void {
        if (self.count == 0) {
            try writer.writeAll("{\n");
            try writeIndent(writer, 1, indent);
            try writer.writeAll("\"type\": \"empty\",\n");
            try writeIndent(writer, 1, indent);
            try writer.writeAll("\"count\": 0\n}");
            return;
        }
        try writer.writeAll("{\n");
        try serializeSchemaPrettyFields(writer, &self.schema, self.count, sort_keys, indent, 1);
        try writer.writeAll(",\n");
        try writeIndent(writer, 1, indent);
        try writer.writeAll("\"count\": ");
        var buf: [20]u8 = undefined;
        const n = std.fmt.bufPrint(&buf, "{d}", .{self.count}) catch unreachable;
        try writer.writeAll(n);
        try writer.writeAll("\n}");
    }
};

pub const Indent = union(enum) {
    spaces: u8,
    tab,
};

fn writeIndent(writer: anytype, depth: u32, indent: Indent) !void {
    switch (indent) {
        .spaces => |n| {
            var i: u32 = 0;
            while (i < depth * n) : (i += 1) {
                try writer.writeByte(' ');
            }
        },
        .tab => {
            var i: u32 = 0;
            while (i < depth) : (i += 1) {
                try writer.writeByte('\t');
            }
        },
    }
}

/// Write the "type" and content fields of a schema node (no outer braces).
fn serializeSchemaFields(writer: anytype, schema: *const Schema, record_count: u64, sort_keys: bool) anyerror!void {
    const type_count = schema.types.count();
    if (type_count == 0) return;

    // Write type field.
    try writer.writeAll("\"type\":");
    if (type_count == 1) {
        try writer.writeByte('"');
        try writeTypeName(writer, schema.types);
        try writer.writeByte('"');
    } else {
        try writer.writeByte('[');
        try writeTypeNames(writer, schema.types);
        try writer.writeByte(']');
    }

    // Write fields for object type (skip if empty map).
    if (schema.fields) |fields| {
        if (fields.count() > 0) {
            try writer.writeAll(",\"fields\":{");
            const keys = fields.keys();
            const values = fields.values();

            if (sort_keys) {
                var sorted_indices = std.ArrayList(usize){};
                defer sorted_indices.deinit(std.heap.page_allocator);
                try sorted_indices.ensureTotalCapacity(std.heap.page_allocator, keys.len);
                for (0..keys.len) |ki| sorted_indices.appendAssumeCapacity(ki);
                std.mem.sort(usize, sorted_indices.items, keys, struct {
                    fn lessThan(k: []const []const u8, a: usize, b_idx: usize) bool {
                        return std.mem.order(u8, k[a], k[b_idx]) == .lt;
                    }
                }.lessThan);

                var first = true;
                for (sorted_indices.items) |ki| {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try writeFieldEntry(writer, keys[ki], values[ki], record_count, sort_keys);
                }
            } else {
                var first = true;
                for (keys, values) |k, v| {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try writeFieldEntry(writer, k, v, record_count, sort_keys);
                }
            }
            try writer.writeByte('}');
        }
    }

    // Write elements for array type (skip if no element types observed).
    if (schema.elements) |elem| {
        if (elem.types.count() > 0) {
            try writer.writeAll(",\"elements\":");
            try serializeSchemaValue(writer, elem, record_count, sort_keys);
        }
    }
}

/// Write pretty-printed schema fields.
fn serializeSchemaPrettyFields(writer: anytype, schema: *const Schema, record_count: u64, sort_keys: bool, indent: Indent, depth: u32) anyerror!void {
    const type_count = schema.types.count();
    if (type_count == 0) return;

    try writeIndent(writer, depth, indent);
    try writer.writeAll("\"type\": ");
    if (type_count == 1) {
        try writer.writeByte('"');
        try writeTypeName(writer, schema.types);
        try writer.writeByte('"');
    } else {
        try writer.writeByte('[');
        try writeTypeNamesPretty(writer, schema.types);
        try writer.writeByte(']');
    }

    if (schema.fields) |fields| {
        if (fields.count() > 0) {
            try writer.writeAll(",\n");
            try writeIndent(writer, depth, indent);
            try writer.writeAll("\"fields\": {\n");
            const keys = fields.keys();
            const values = fields.values();

            if (sort_keys) {
                var sorted_indices = std.ArrayList(usize){};
                defer sorted_indices.deinit(std.heap.page_allocator);
                try sorted_indices.ensureTotalCapacity(std.heap.page_allocator, keys.len);
                for (0..keys.len) |ki| sorted_indices.appendAssumeCapacity(ki);
                std.mem.sort(usize, sorted_indices.items, keys, struct {
                    fn lessThan(k: []const []const u8, a: usize, b_idx: usize) bool {
                        return std.mem.order(u8, k[a], k[b_idx]) == .lt;
                    }
                }.lessThan);

                var first = true;
                for (sorted_indices.items) |ki| {
                    if (!first) {
                        try writer.writeAll(",\n");
                    }
                    first = false;
                    try writeFieldEntryPretty(writer, keys[ki], values[ki], record_count, sort_keys, indent, depth + 1);
                }
            } else {
                var first = true;
                for (keys, values) |k, v| {
                    if (!first) {
                        try writer.writeAll(",\n");
                    }
                    first = false;
                    try writeFieldEntryPretty(writer, k, v, record_count, sort_keys, indent, depth + 1);
                }
            }
            try writer.writeByte('\n');
            try writeIndent(writer, depth, indent);
            try writer.writeByte('}');
        }
    }

    if (schema.elements) |elem| {
        if (elem.types.count() > 0) {
            try writer.writeAll(",\n");
            try writeIndent(writer, depth, indent);
            try writer.writeAll("\"elements\": ");
            try serializeSchemaValuePretty(writer, elem, record_count, sort_keys, indent, depth);
        }
    }
}

fn writeFieldEntry(writer: anytype, key: []const u8, child: *const Schema, record_count: u64, sort_keys: bool) anyerror!void {
    try writer.writeByte('"');
    try writeEscaped(writer, key);
    try writer.writeAll("\":");
    try serializeSchemaValue(writer, child, record_count, sort_keys);
}

fn writeFieldEntryPretty(writer: anytype, key: []const u8, child: *const Schema, record_count: u64, sort_keys: bool, indent: Indent, depth: u32) anyerror!void {
    try writeIndent(writer, depth, indent);
    try writer.writeByte('"');
    try writeEscaped(writer, key);
    try writer.writeAll("\": ");
    try serializeSchemaValuePretty(writer, child, record_count, sort_keys, indent, depth);
}

/// Serialize a child schema value — either as a simple type string or as a nested object.
fn serializeSchemaValue(writer: anytype, schema: *const Schema, record_count: u64, sort_keys: bool) anyerror!void {
    const type_count = schema.types.count();
    const has_fields = schema.fields != null and schema.fields.?.count() > 0;
    const has_elements = schema.elements != null and schema.elements.?.types.count() > 0;
    const is_optional = schema.presence_count > 0 and schema.presence_count < record_count;

    if (type_count == 0) {
        try writer.writeAll("\"unknown\"");
    } else if (!has_fields and !has_elements and !is_optional) {
        // Simple — no nested structure or optionality.
        if (type_count == 1) {
            try writer.writeByte('"');
            try writeTypeName(writer, schema.types);
            try writer.writeByte('"');
        } else {
            try writer.writeByte('[');
            try writeTypeNames(writer, schema.types);
            try writer.writeByte(']');
        }
    } else {
        // Complex — write as object with type, fields, elements, optional.
        try writer.writeByte('{');
        try serializeSchemaFields(writer, schema, record_count, sort_keys);
        if (is_optional) {
            try writer.writeAll(",\"optional\":true");
        }
        try writer.writeByte('}');
    }
}

/// Pretty-print a child schema value.
fn serializeSchemaValuePretty(writer: anytype, schema: *const Schema, record_count: u64, sort_keys: bool, indent: Indent, depth: u32) anyerror!void {
    const type_count = schema.types.count();
    const has_fields = schema.fields != null and schema.fields.?.count() > 0;
    const has_elements = schema.elements != null and schema.elements.?.types.count() > 0;
    const is_optional = schema.presence_count > 0 and schema.presence_count < record_count;

    if (type_count == 0) {
        try writer.writeAll("\"unknown\"");
    } else if (!has_fields and !has_elements and !is_optional) {
        if (type_count == 1) {
            try writer.writeByte('"');
            try writeTypeName(writer, schema.types);
            try writer.writeByte('"');
        } else {
            try writer.writeByte('[');
            try writeTypeNamesPretty(writer, schema.types);
            try writer.writeByte(']');
        }
    } else {
        try writer.writeAll("{\n");
        try serializeSchemaPrettyFields(writer, schema, record_count, sort_keys, indent, depth + 1);
        if (is_optional) {
            try writer.writeAll(",\n");
            try writeIndent(writer, depth + 1, indent);
            try writer.writeAll("\"optional\": true");
        }
        try writer.writeByte('\n');
        try writeIndent(writer, depth, indent);
        try writer.writeByte('}');
    }
}

/// Write the single type name for a TypeSet with exactly one bit set.
fn writeTypeName(writer: anytype, ts: TypeSet) !void {
    if (ts.null) try writer.writeAll("null") else if (ts.boolean) try writer.writeAll("boolean") else if (ts.number) try writer.writeAll("number") else if (ts.string) try writer.writeAll("string") else if (ts.array) try writer.writeAll("array") else if (ts.object) try writer.writeAll("object");
}

/// Write comma-separated type names for a TypeSet with multiple bits set (compact).
fn writeTypeNames(writer: anytype, ts: TypeSet) !void {
    var first = true;
    inline for (.{ .{ ts.null, "\"null\"" }, .{ ts.boolean, "\"boolean\"" }, .{ ts.number, "\"number\"" }, .{ ts.string, "\"string\"" }, .{ ts.array, "\"array\"" }, .{ ts.object, "\"object\"" } }) |pair| {
        if (pair[0]) {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll(pair[1]);
        }
    }
}

/// Write comma-separated type names for pretty output (with spaces after commas).
fn writeTypeNamesPretty(writer: anytype, ts: TypeSet) !void {
    var first = true;
    inline for (.{ .{ ts.null, "\"null\"" }, .{ ts.boolean, "\"boolean\"" }, .{ ts.number, "\"number\"" }, .{ ts.string, "\"string\"" }, .{ ts.array, "\"array\"" }, .{ ts.object, "\"object\"" } }) |pair| {
        if (pair[0]) {
            if (!first) try writer.writeAll(", ");
            first = false;
            try writer.writeAll(pair[1]);
        }
    }
}

/// Write JSON-escaped string content (no surrounding quotes).
fn writeEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\t' => try writer.writeAll("\\t"),
            '\r' => try writer.writeAll("\\r"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const seq = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try writer.writeAll(seq);
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}
