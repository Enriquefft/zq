const std = @import("std");

pub const Category = enum {
    array,
    object,
    string,
    math,
    type_check,
    io,
    path,
    control,
    format,
    misc,
};

pub const BuiltinInfo = struct {
    name: []const u8,
    arity: u8,
    signature: []const u8,
    doc: []const u8,
    category: Category,
};

/// Static table of all jq builtin functions with documentation.
pub const builtins = [_]BuiltinInfo{
    // ── Array builtins ──────────────────────────────────
    .{ .name = "length", .arity = 0, .signature = "length", .doc = "Returns the length of arrays, strings, objects, or null (0).", .category = .array },
    .{ .name = "keys", .arity = 0, .signature = "keys", .doc = "Returns sorted keys of an object, or indices of an array.", .category = .object },
    .{ .name = "keys_unsorted", .arity = 0, .signature = "keys_unsorted", .doc = "Returns keys of an object in original order.", .category = .object },
    .{ .name = "values", .arity = 0, .signature = "values", .doc = "Returns values of an object or array.", .category = .object },
    .{ .name = "has", .arity = 1, .signature = "has(k)", .doc = "Returns true if the input has the given key (objects) or index (arrays).", .category = .object },
    .{ .name = "in", .arity = 1, .signature = "in(obj)", .doc = "Returns true if the input key is in the given object.", .category = .object },
    .{ .name = "add", .arity = 0, .signature = "add", .doc = "Reduces array elements with `+`. Null for empty arrays.", .category = .array },
    .{ .name = "sort", .arity = 0, .signature = "sort", .doc = "Sorts an array.", .category = .array },
    .{ .name = "sort_by", .arity = 1, .signature = "sort_by(f)", .doc = "Sorts an array by the result of applying f to each element.", .category = .array },
    .{ .name = "group_by", .arity = 1, .signature = "group_by(f)", .doc = "Groups array elements by the result of f.", .category = .array },
    .{ .name = "reverse", .arity = 0, .signature = "reverse", .doc = "Reverses an array or string.", .category = .array },
    .{ .name = "flatten", .arity = 0, .signature = "flatten", .doc = "Flattens nested arrays.", .category = .array },
    .{ .name = "min", .arity = 0, .signature = "min", .doc = "Returns the minimum element of an array.", .category = .array },
    .{ .name = "max", .arity = 0, .signature = "max", .doc = "Returns the maximum element of an array.", .category = .array },
    .{ .name = "min_by", .arity = 1, .signature = "min_by(f)", .doc = "Returns the element with minimum f value.", .category = .array },
    .{ .name = "max_by", .arity = 1, .signature = "max_by(f)", .doc = "Returns the element with maximum f value.", .category = .array },
    .{ .name = "unique", .arity = 0, .signature = "unique", .doc = "Returns unique elements of a sorted array.", .category = .array },
    .{ .name = "unique_by", .arity = 1, .signature = "unique_by(f)", .doc = "Returns elements unique by the result of f.", .category = .array },
    .{ .name = "contains", .arity = 1, .signature = "contains(b)", .doc = "Returns true if input contains b (recursive for objects/arrays).", .category = .array },
    .{ .name = "inside", .arity = 1, .signature = "inside(b)", .doc = "Returns true if input is contained within b.", .category = .array },
    .{ .name = "indices", .arity = 1, .signature = "indices(s)", .doc = "Returns indices of occurrences of s in the input.", .category = .array },
    .{ .name = "index", .arity = 1, .signature = "index(s)", .doc = "Returns the first index of s, or null.", .category = .array },
    .{ .name = "rindex", .arity = 1, .signature = "rindex(s)", .doc = "Returns the last index of s, or null.", .category = .array },
    .{ .name = "transpose", .arity = 0, .signature = "transpose", .doc = "Transposes an array of arrays.", .category = .array },
    .{ .name = "first", .arity = 0, .signature = "first", .doc = "Returns the first element (.[0]).", .category = .array },
    .{ .name = "last", .arity = 0, .signature = "last", .doc = "Returns the last element (.[-1]).", .category = .array },
    .{ .name = "range", .arity = 1, .signature = "range(n)", .doc = "Generates integers from 0 to n-1.", .category = .array },
    .{ .name = "bsearch", .arity = 1, .signature = "bsearch(x)", .doc = "Binary search for x in a sorted array.", .category = .array },

    // ── Object builtins ─────────────────────────────────
    .{ .name = "to_entries", .arity = 0, .signature = "to_entries", .doc = "Converts object to array of {key, value} pairs.", .category = .object },
    .{ .name = "from_entries", .arity = 0, .signature = "from_entries", .doc = "Converts array of {key, value} pairs to object.", .category = .object },
    .{ .name = "with_entries", .arity = 1, .signature = "with_entries(f)", .doc = "Applies f to each {key, value} entry.", .category = .object },
    .{ .name = "del", .arity = 1, .signature = "del(path)", .doc = "Deletes the element at the given path.", .category = .object },
    .{ .name = "getpath", .arity = 1, .signature = "getpath(path)", .doc = "Retrieves the value at the given path.", .category = .path },
    .{ .name = "setpath", .arity = 2, .signature = "setpath(path; value)", .doc = "Sets the value at the given path.", .category = .path },
    .{ .name = "delpaths", .arity = 1, .signature = "delpaths(paths)", .doc = "Deletes values at multiple paths.", .category = .path },
    .{ .name = "paths", .arity = 0, .signature = "paths", .doc = "Enumerates all paths in the input.", .category = .path },
    .{ .name = "leaf_paths", .arity = 0, .signature = "leaf_paths", .doc = "Enumerates paths to leaf values.", .category = .path },

    // ── Type builtins ───────────────────────────────────
    .{ .name = "type", .arity = 0, .signature = "type", .doc = "Returns the type name as a string.", .category = .type_check },
    .{ .name = "empty", .arity = 0, .signature = "empty", .doc = "Produces no output.", .category = .control },
    .{ .name = "error", .arity = 0, .signature = "error", .doc = "Raises an error with the input as the message.", .category = .control },
    .{ .name = "not", .arity = 0, .signature = "not", .doc = "Logical negation (false and null → true, else false).", .category = .misc },
    .{ .name = "any", .arity = 0, .signature = "any", .doc = "Returns true if any element is truthy.", .category = .array },
    .{ .name = "all", .arity = 0, .signature = "all", .doc = "Returns true if all elements are truthy.", .category = .array },

    // ── String builtins ─────────────────────────────────
    .{ .name = "tostring", .arity = 0, .signature = "tostring", .doc = "Converts to string (strings unchanged, others to JSON).", .category = .string },
    .{ .name = "tonumber", .arity = 0, .signature = "tonumber", .doc = "Converts string to number.", .category = .string },
    .{ .name = "ascii_downcase", .arity = 0, .signature = "ascii_downcase", .doc = "Converts ASCII characters to lowercase.", .category = .string },
    .{ .name = "ascii_upcase", .arity = 0, .signature = "ascii_upcase", .doc = "Converts ASCII characters to uppercase.", .category = .string },
    .{ .name = "ascii", .arity = 0, .signature = "ascii", .doc = "Returns the ASCII value of the first character.", .category = .string },
    .{ .name = "explode", .arity = 0, .signature = "explode", .doc = "Converts string to array of codepoints.", .category = .string },
    .{ .name = "implode", .arity = 0, .signature = "implode", .doc = "Converts array of codepoints to string.", .category = .string },
    .{ .name = "split", .arity = 1, .signature = "split(sep)", .doc = "Splits string by separator.", .category = .string },
    .{ .name = "join", .arity = 1, .signature = "join(sep)", .doc = "Joins array elements with separator.", .category = .string },
    .{ .name = "startswith", .arity = 1, .signature = "startswith(str)", .doc = "Tests if string starts with prefix.", .category = .string },
    .{ .name = "endswith", .arity = 1, .signature = "endswith(str)", .doc = "Tests if string ends with suffix.", .category = .string },
    .{ .name = "ltrimstr", .arity = 1, .signature = "ltrimstr(str)", .doc = "Removes prefix if present.", .category = .string },
    .{ .name = "rtrimstr", .arity = 1, .signature = "rtrimstr(str)", .doc = "Removes suffix if present.", .category = .string },
    .{ .name = "test", .arity = 1, .signature = "test(regex)", .doc = "Tests if string matches regex pattern.", .category = .string },
    .{ .name = "match", .arity = 1, .signature = "match(regex)", .doc = "Returns match details for regex pattern.", .category = .string },
    .{ .name = "sub", .arity = 2, .signature = "sub(regex; replacement)", .doc = "Replaces first match of regex.", .category = .string },
    .{ .name = "gsub", .arity = 2, .signature = "gsub(regex; replacement)", .doc = "Replaces all matches of regex.", .category = .string },
    .{ .name = "tojson", .arity = 0, .signature = "tojson", .doc = "Serializes value to JSON string.", .category = .string },
    .{ .name = "fromjson", .arity = 0, .signature = "fromjson", .doc = "Parses JSON string to value.", .category = .string },

    // ── Math builtins ───────────────────────────────────
    .{ .name = "abs", .arity = 0, .signature = "abs", .doc = "Absolute value.", .category = .math },
    .{ .name = "floor", .arity = 0, .signature = "floor", .doc = "Floor (round down).", .category = .math },
    .{ .name = "ceil", .arity = 0, .signature = "ceil", .doc = "Ceiling (round up).", .category = .math },
    .{ .name = "round", .arity = 0, .signature = "round", .doc = "Round to nearest integer.", .category = .math },
    .{ .name = "sqrt", .arity = 0, .signature = "sqrt", .doc = "Square root.", .category = .math },
    .{ .name = "pow", .arity = 2, .signature = "pow(a; b)", .doc = "Raises a to the power b.", .category = .math },
    .{ .name = "log", .arity = 0, .signature = "log", .doc = "Natural logarithm.", .category = .math },
    .{ .name = "log2", .arity = 0, .signature = "log2", .doc = "Logarithm base 2.", .category = .math },
    .{ .name = "log10", .arity = 0, .signature = "log10", .doc = "Logarithm base 10.", .category = .math },
    .{ .name = "exp", .arity = 0, .signature = "exp", .doc = "e^x.", .category = .math },
    .{ .name = "sin", .arity = 0, .signature = "sin", .doc = "Sine.", .category = .math },
    .{ .name = "cos", .arity = 0, .signature = "cos", .doc = "Cosine.", .category = .math },
    .{ .name = "atan", .arity = 0, .signature = "atan", .doc = "Arctangent.", .category = .math },
    .{ .name = "atan2", .arity = 2, .signature = "atan2(y; x)", .doc = "Two-argument arctangent.", .category = .math },
    .{ .name = "nan", .arity = 0, .signature = "nan", .doc = "Returns NaN.", .category = .math },
    .{ .name = "infinite", .arity = 0, .signature = "infinite", .doc = "Returns positive infinity.", .category = .math },
    .{ .name = "isinfinite", .arity = 0, .signature = "isinfinite", .doc = "Tests if value is infinite.", .category = .math },
    .{ .name = "isnan", .arity = 0, .signature = "isnan", .doc = "Tests if value is NaN.", .category = .math },
    .{ .name = "isnormal", .arity = 0, .signature = "isnormal", .doc = "Tests if value is a normal number.", .category = .math },
    .{ .name = "fma", .arity = 3, .signature = "fma(a; b; c)", .doc = "Fused multiply-add: a*b+c.", .category = .math },

    // ── Control flow ────────────────────────────────────
    .{ .name = "select", .arity = 1, .signature = "select(f)", .doc = "Passes input through if f is true, otherwise produces empty.", .category = .control },
    .{ .name = "map", .arity = 1, .signature = "map(f)", .doc = "Applies f to each element of an array.", .category = .array },
    .{ .name = "map_values", .arity = 1, .signature = "map_values(f)", .doc = "Applies f to each value (arrays or objects).", .category = .array },
    .{ .name = "limit", .arity = 2, .signature = "limit(n; f)", .doc = "Takes at most n outputs from f.", .category = .control },
    .{ .name = "isempty", .arity = 1, .signature = "isempty(f)", .doc = "Returns true if f produces no output.", .category = .control },

    // ── Type filter builtins ────────────────────────────
    .{ .name = "arrays", .arity = 0, .signature = "arrays", .doc = "Selects arrays only.", .category = .type_check },
    .{ .name = "objects", .arity = 0, .signature = "objects", .doc = "Selects objects only.", .category = .type_check },
    .{ .name = "strings", .arity = 0, .signature = "strings", .doc = "Selects strings only.", .category = .type_check },
    .{ .name = "numbers", .arity = 0, .signature = "numbers", .doc = "Selects numbers only.", .category = .type_check },
    .{ .name = "booleans", .arity = 0, .signature = "booleans", .doc = "Selects booleans only.", .category = .type_check },
    .{ .name = "nulls", .arity = 0, .signature = "nulls", .doc = "Selects nulls only.", .category = .type_check },
    .{ .name = "values", .arity = 0, .signature = "values", .doc = "Selects non-null values.", .category = .type_check },
    .{ .name = "scalars", .arity = 0, .signature = "scalars", .doc = "Selects non-array, non-object values.", .category = .type_check },
    .{ .name = "iterables", .arity = 0, .signature = "iterables", .doc = "Selects arrays and objects.", .category = .type_check },

    // ── I/O builtins ────────────────────────────────────
    .{ .name = "debug", .arity = 0, .signature = "debug", .doc = "Passes through, prints to stderr.", .category = .io },
    .{ .name = "stderr", .arity = 0, .signature = "stderr", .doc = "Same as debug.", .category = .io },
    .{ .name = "input", .arity = 0, .signature = "input", .doc = "Reads one JSON value from stdin.", .category = .io },
    .{ .name = "inputs", .arity = 0, .signature = "inputs", .doc = "Reads all remaining JSON values from stdin.", .category = .io },
    .{ .name = "env", .arity = 0, .signature = "env", .doc = "Returns environment variables as an object.", .category = .io },
    .{ .name = "halt", .arity = 0, .signature = "halt", .doc = "Exits the program.", .category = .io },
    .{ .name = "halt_error", .arity = 1, .signature = "halt_error(code)", .doc = "Exits with the given error code.", .category = .io },
    .{ .name = "builtins", .arity = 0, .signature = "builtins", .doc = "Lists all builtin function names.", .category = .misc },

    // ── Format builtins ─────────────────────────────────
    .{ .name = "@text", .arity = 0, .signature = "@text", .doc = "Formats value as text.", .category = .format },
    .{ .name = "@json", .arity = 0, .signature = "@json", .doc = "Formats value as JSON.", .category = .format },
    .{ .name = "@html", .arity = 0, .signature = "@html", .doc = "HTML-escapes a string.", .category = .format },
    .{ .name = "@csv", .arity = 0, .signature = "@csv", .doc = "Formats array as CSV row.", .category = .format },
    .{ .name = "@tsv", .arity = 0, .signature = "@tsv", .doc = "Formats array as TSV row.", .category = .format },
    .{ .name = "@uri", .arity = 0, .signature = "@uri", .doc = "URI-encodes a string.", .category = .format },
    .{ .name = "@base64", .arity = 0, .signature = "@base64", .doc = "Base64-encodes a string.", .category = .format },
    .{ .name = "@base64d", .arity = 0, .signature = "@base64d", .doc = "Base64-decodes a string.", .category = .format },
    .{ .name = "@sh", .arity = 0, .signature = "@sh", .doc = "Shell-escapes a string.", .category = .format },
};

/// Look up a builtin by name.
pub fn lookup(name: []const u8) ?*const BuiltinInfo {
    for (&builtins) |*b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

/// Get all builtins matching a given category.
pub fn byCategory(category: Category, buf: []const *const BuiltinInfo) []const *const BuiltinInfo {
    var count: usize = 0;
    for (&builtins) |*b| {
        if (b.category == category and count < buf.len) {
            buf[count] = b;
            count += 1;
        }
    }
    return buf[0..count];
}
