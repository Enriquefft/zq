//! VM-equivalence harness for Phase 2R compiler.
//!
//! For each fixture: compile via legacy AND via new, then run both
//! resulting bytecodes against the input JSON and byte-compare the
//! emitted value streams. Mismatches surface a per-fixture diff line
//! and exit non-zero.
//!
//! Plan: research/phase-2r-compiler-redesign-plan.md §3 R3 step 4.
//! Spec:  research/compiler-ir-format.md (Phase 4).

const std = @import("std");
const query = @import("query");
const parser_mod = @import("parser");
const output_mod = @import("output");
const types_mod = @import("types");

const Fixture = struct {
    name: []const u8,
    filter: []const u8,
    /// JSON input fed through the production parser to build a Tape.
    input: []const u8,
    /// Reference value stream — one JSON value per emitted output, separated
    /// by '\n'. When set, BOTH backends must match this string AND each other
    /// (3-way comparison). When left empty (`""`), the harness only asserts
    /// legacy-vs-new equivalence and does not pin the absolute value stream.
    expected_output: []const u8 = "",
    /// When true, the legacy compiler is expected to fail. We then check
    /// the new compiler reports the same error class.
    expects_compile_err: bool = false,
};

const FIXTURES = [_]Fixture{
    .{ .name = "literal_null", .filter = "null", .input = "1", .expected_output = "null" },
    .{ .name = "literal_true", .filter = "true", .input = "1", .expected_output = "true" },
    .{ .name = "literal_false", .filter = "false", .input = "1", .expected_output = "false" },
    .{ .name = "literal_int", .filter = "42", .input = "1", .expected_output = "42" },
    .{ .name = "literal_float", .filter = "3.14", .input = "1", .expected_output = "3.14" },
    .{ .name = "literal_str", .filter = "\"hi\"", .input = "1", .expected_output = "\"hi\"" },
    .{ .name = "identity", .filter = ".", .input = "{\"foo\":1}", .expected_output = "{\"foo\":1}" },
    .{ .name = "recurse", .filter = "..", .input = "[1,2]", .expected_output = "[1,2]\n1\n2" },
    .{ .name = "neg", .filter = "-5", .input = "null", .expected_output = "-5" },
    .{ .name = "not_zero_arg", .filter = "not", .input = "null", .expected_output = "true" },
    .{ .name = "type_zero_arg", .filter = "type", .input = "[]", .expected_output = "\"array\"" },

    .{ .name = "field", .filter = ".foo", .input = "{\"foo\":1}", .expected_output = "1" },
    .{ .name = "nested", .filter = ".foo.bar", .input = "{\"foo\":{\"bar\":2}}", .expected_output = "2" },
    .{ .name = "pipe", .filter = ".foo | .bar", .input = "{\"foo\":{\"bar\":3}}", .expected_output = "3" },
    .{ .name = "index", .filter = ".[0]", .input = "[10,20]", .expected_output = "10" },
    .{ .name = "iterate_top", .filter = ".[]", .input = "[1,2,3]", .expected_output = "1\n2\n3" },
    .{ .name = "field_iterate", .filter = ".foo[]", .input = "{\"foo\":[10,20]}", .expected_output = "10\n20" },
    .{ .name = "slice_top", .filter = ".[1:3]", .input = "[10,20,30,40]", .expected_output = "[20,30]" },
    .{ .name = "slice_open_left", .filter = ".[:2]", .input = "[1,2,3,4]", .expected_output = "[1,2]" },
    .{ .name = "optional_missing", .filter = ".foo?", .input = "{}", .expected_output = "null" },
    .{ .name = "optional_type_err", .filter = ".foo?", .input = "[1,2]", .expected_output = "" },
    .{ .name = "field_quoted", .filter = ".[\"foo\"]", .input = "{\"foo\":42}", .expected_output = "42" },
    .{ .name = "neg_index", .filter = ".[-1]", .input = "[10,20,30]", .expected_output = "30" },
    .{ .name = "chain_index_field", .filter = ".[0].x", .input = "[{\"x\":7}]", .expected_output = "7" },
    .{ .name = "chain_field_index", .filter = ".a[1]", .input = "{\"a\":[10,20]}", .expected_output = "20" },
    .{ .name = "arith", .filter = "1+1", .input = "null", .expected_output = "2" },

    // ── Category 5 — arithmetic ───────────────────────────────────
    .{ .name = "arith_sub", .filter = "10-3", .input = "null", .expected_output = "7" },
    .{ .name = "arith_mul", .filter = "4*5", .input = "null", .expected_output = "20" },
    .{ .name = "arith_div", .filter = "20/4", .input = "null", .expected_output = "5" },
    .{ .name = "arith_mod", .filter = "10%3", .input = "null", .expected_output = "1" },
    .{ .name = "arith_chain", .filter = "1+2*3", .input = "null", .expected_output = "7" },
    .{ .name = "arith_field", .filter = ".x + .y", .input = "{\"x\":2,\"y\":3}", .expected_output = "5" },

    // ── Category 5 — comparison ───────────────────────────────────
    .{ .name = "cmp_eq_true", .filter = "1==1", .input = "null", .expected_output = "true" },
    .{ .name = "cmp_ne_true", .filter = "1!=2", .input = "null", .expected_output = "true" },
    .{ .name = "cmp_lt_true", .filter = "1<2", .input = "null", .expected_output = "true" },
    .{ .name = "cmp_le_true", .filter = "2<=2", .input = "null", .expected_output = "true" },
    .{ .name = "cmp_gt_true", .filter = "3>2", .input = "null", .expected_output = "true" },
    .{ .name = "cmp_ge_false", .filter = "1>=2", .input = "null", .expected_output = "false" },
    .{ .name = "cmp_field", .filter = ".id > 100", .input = "{\"id\":150}", .expected_output = "true" },

    // ── Category 5 — logical and/or ───────────────────────────────
    .{ .name = "logical_and_tt", .filter = "true and true", .input = "null", .expected_output = "true" },
    .{ .name = "logical_and_tf", .filter = "true and false", .input = "null", .expected_output = "false" },
    .{ .name = "logical_or_tf", .filter = "true or false", .input = "null", .expected_output = "true" },
    .{ .name = "logical_or_ff", .filter = "false or false", .input = "null", .expected_output = "false" },

    // ── Category 5 — alternative `//` ─────────────────────────────
    .{ .name = "alt_null_lhs", .filter = "null // 5", .input = "null", .expected_output = "5" },
    .{ .name = "alt_false_lhs", .filter = "false // 7", .input = "null", .expected_output = "7" },
    .{ .name = "alt_truthy_lhs", .filter = "1 // 5", .input = "null", .expected_output = "1" },

    // ── Category 7 — object constructor ───────────────────────────
    .{ .name = "obj_static", .filter = "{a: 1, b: 2}", .input = "null", .expected_output = "{\"a\":1,\"b\":2}" },
    .{ .name = "obj_field_value", .filter = "{x: .a, y: .b}", .input = "{\"a\":10,\"b\":20}", .expected_output = "{\"x\":10,\"y\":20}" },
    .{ .name = "obj_shorthand_pair", .filter = "{a, b}", .input = "{\"a\":1,\"b\":2,\"c\":9}", .expected_output = "{\"a\":1,\"b\":2}" },
    .{ .name = "obj_string_key", .filter = "{\"k\": .v}", .input = "{\"v\":42}", .expected_output = "{\"k\":42}" },
    .{ .name = "obj_computed_key", .filter = "{(.k): .v}", .input = "{\"k\":\"name\",\"v\":\"x\"}", .expected_output = "{\"name\":\"x\"}" },

    // ── Category 7 — array constructor ────────────────────────────
    .{ .name = "arr_static", .filter = "[1, 2, 3]", .input = "null", .expected_output = "[1,2,3]" },
    .{ .name = "arr_empty", .filter = "[]", .input = "null", .expected_output = "[]" },
    .{ .name = "arr_field", .filter = "[.a, .b]", .input = "{\"a\":1,\"b\":2}", .expected_output = "[1,2]" },
    .{ .name = "arr_iterate", .filter = "[.[]]", .input = "[1,2,3]", .expected_output = "[1,2,3]" },

    // ── Category 7 — string interpolation ─────────────────────────
    .{ .name = "interp_basic", .filter = "\"hello \\(.name)\"", .input = "{\"name\":\"world\"}", .expected_output = "\"hello world\"" },
    .{ .name = "interp_arith", .filter = "\"x=\\(1+2)\"", .input = "null", .expected_output = "\"x=3\"" },

    // ── Category 7 — format application ───────────────────────────
    .{ .name = "format_base64_lit", .filter = "@base64 \"hi\"", .input = "null", .expected_output = "\"hi\"" },
    .{ .name = "format_base64_interp", .filter = "@base64 \"\\(.)\"", .input = "\"hi\"", .expected_output = "\"aGk=\"" },

    .{ .name = "select", .filter = "select(.id > 100)", .input = "{\"id\":150}", .expected_output = "{\"id\":150}" },
    .{ .name = "map", .filter = "map(.id) | add", .input = "[{\"id\":1},{\"id\":2}]", .expected_output = "3" },
    .{ .name = "udf_simple", .filter = "def f: . + 1; f", .input = "10", .expected_output = "11" },
    .{ .name = "udf_semi", .filter = "def f(a;b): a + b; f(.x;.y)", .input = "{\"x\":2,\"y\":3}", .expected_output = "5" },
    .{ .name = "regex_lit", .filter = "test(\"^[a-z]+$\")", .input = "\"foobar\"", .expected_output = "true" },
    .{ .name = "reduce", .filter = "reduce range(10) as $i (0; . + $i)", .input = "null", .expected_output = "45" },

    .{ .name = "pipe_chain", .filter = ".a | .b | .c", .input = "{\"a\":{\"b\":{\"c\":7}}}", .expected_output = "7" },
    .{ .name = "comma_simple", .filter = ".a, .b", .input = "{\"a\":1,\"b\":2}", .expected_output = "1\n2" },
    .{ .name = "comma_chain", .filter = ".a, .b, .c", .input = "{\"a\":1,\"b\":2,\"c\":3}", .expected_output = "1\n2\n3" },

    // ── Category 8 — update assignments (fast path) ───────────────
    .{ .name = "assign_set_basic", .filter = ".a = 1", .input = "{\"a\":0}", .expected_output = "{\"a\":1}" },
    .{ .name = "assign_add", .filter = ".a += 1", .input = "{\"a\":5}", .expected_output = "{\"a\":6}" },
    .{ .name = "assign_sub", .filter = ".a -= 2", .input = "{\"a\":7}", .expected_output = "{\"a\":5}" },
    .{ .name = "assign_mul", .filter = ".a *= 3", .input = "{\"a\":4}", .expected_output = "{\"a\":12}" },
    .{ .name = "assign_div", .filter = ".a /= 2", .input = "{\"a\":10}", .expected_output = "{\"a\":5}" },
    .{ .name = "assign_mod", .filter = ".a %= 3", .input = "{\"a\":10}", .expected_output = "{\"a\":1}" },
    .{ .name = "assign_alt_falsy", .filter = ".a //= 99", .input = "{\"a\":null}", .expected_output = "{\"a\":99}" },
    .{ .name = "assign_alt_truthy", .filter = ".a //= 99", .input = "{\"a\":7}", .expected_output = "{\"a\":7}" },
    .{ .name = "assign_update", .filter = ".a |= . + 1", .input = "{\"a\":5}", .expected_output = "{\"a\":6}" },
    // ── Category 8 — update assignments (general LHS) ─────────────
    .{ .name = "assign_general_iterate", .filter = ".a[] = 0", .input = "{\"a\":[1,2,3]}", .expected_output = "{\"a\":[0,0,0]}" },

    // ── Category 6 — try / catch ──────────────────────────────────
    // No-handler form: error swallowed silently (empty stream).
    .{ .name = "try_success", .filter = "try .x", .input = "{\"x\":42}", .expected_output = "42" },
    .{ .name = "try_swallow", .filter = "try .x", .input = "[1,2]", .expected_output = "" },
    // catch-handler form: error binds to handler's input.
    .{ .name = "try_catch_caught", .filter = "try .x catch \"missing\"", .input = "[1,2]", .expected_output = "\"missing\"" },
    .{ .name = "try_catch_passthrough", .filter = "try .x catch \"missing\"", .input = "{\"x\":7}", .expected_output = "7" },

    // ── Category 6 — if / elif / else ─────────────────────────────
    .{ .name = "if_then_else_t", .filter = "if . > 3 then \"big\" else \"small\" end", .input = "5", .expected_output = "\"big\"" },
    .{ .name = "if_then_else_f", .filter = "if . > 3 then \"big\" else \"small\" end", .input = "1", .expected_output = "\"small\"" },
    .{ .name = "if_elif_else_top", .filter = "if . > 3 then \"big\" elif . == 0 then \"zero\" else \"small\" end", .input = "5", .expected_output = "\"big\"" },
    .{ .name = "if_elif_else_mid", .filter = "if . > 3 then \"big\" elif . == 0 then \"zero\" else \"small\" end", .input = "0", .expected_output = "\"zero\"" },
    .{ .name = "if_elif_else_low", .filter = "if . > 3 then \"big\" elif . == 0 then \"zero\" else \"small\" end", .input = "1", .expected_output = "\"small\"" },
    // Implicit-else (no `else` clause): falsy condition passes input through.
    .{ .name = "if_implicit_else", .filter = "if . > 3 then \"big\" end", .input = "1", .expected_output = "1" },

    // ── Category 6 — if/try nested in arr/obj/interp (parity probe) ──
    // These trigger the variadic-span append ordering: arr_ctor /
    // obj_ctor / interp wrap an `if` whose own variadic span must be
    // emitted before the outer span captures its start position.
    .{ .name = "if_then_generator", .filter = "[if 1 then 3,4 else 5 end]", .input = "null", .expected_output = "[3,4]" },
    .{ .name = "if_else_generator", .filter = "[if null then 3 else 5,6 end]", .input = "null", .expected_output = "[5,6]" },
    .{ .name = "if_in_obj", .filter = "{x: if .a then \"y\" else \"n\" end}", .input = "{\"a\":1}", .expected_output = "{\"x\":\"y\"}" },
    .{ .name = "if_in_interp", .filter = "\"x=\\(if 1 then 3 else 5 end)\"", .input = "null", .expected_output = "\"x=3\"" },

    // ── Category 6 — path() builtin ───────────────────────────────
    .{ .name = "path_simple", .filter = "path(.a.b)", .input = "null", .expected_output = "[\"a\",\"b\"]" },
    .{ .name = "path_iterate", .filter = "path(.[])", .input = "[10,20,30]", .expected_output = "[0]\n[1]\n[2]" },
    .{ .name = "path_index", .filter = "path(.[1])", .input = "[10,20,30]", .expected_output = "[1]" },

    // ── Category 6 — paren passthrough ────────────────────────────
    // Parens are AST-level grouping with no IR shape — verify the
    // dispatcher sees no SKIP and the output matches legacy.
    .{ .name = "paren_field", .filter = "(.x)", .input = "{\"x\":42}", .expected_output = "42" },
    .{ .name = "paren_arith", .filter = "(. + 1) * 2", .input = "5", .expected_output = "12" },

    // ── Category 4 — variables, as-pattern, destructure, ?// ──────
    // Variable load via plain as-bind.
    .{ .name = "var_load_simple", .filter = "1 as $x | $x", .input = "null", .expected_output = "1" },
    // Variable used in arithmetic — verifies load_var operand resolves.
    .{ .name = "as_bind_use", .filter = "5 as $x | $x + 1", .input = "null", .expected_output = "6" },
    // Identity LHS — destructure target sourced from current input.
    .{ .name = "as_identity_lhs", .filter = ". as $x | $x", .input = "42", .expected_output = "42" },
    // Array destructure: extract two elements and combine.
    .{ .name = "destructure_array_pair", .filter = ". as [$a, $b] | $a + $b", .input = "[10,20]", .expected_output = "30" },
    // Array destructure missing element → null-on-missing arm.
    .{ .name = "destructure_array_missing", .filter = ". as [$a, $b] | $b", .input = "[10]", .expected_output = "null" },
    // Object destructure: explicit `key: $var` pairs.
    .{ .name = "destructure_object_pair", .filter = ". as {a: $av, b: $bv} | $av + $bv", .input = "{\"a\":10,\"b\":20}", .expected_output = "30" },
    // Object destructure shorthand `{$a, $b}` (key+var both `a`).
    .{ .name = "destructure_object_shorthand", .filter = ". as {$a, $b} | $a + $b", .input = "{\"a\":3,\"b\":4}", .expected_output = "7" },
    // Nested array destructure — verifies recursive pattern emit.
    .{ .name = "destructure_nested", .filter = ". as [$a, [$b, $c]] | $a + $b + $c", .input = "[1,[2,3]]", .expected_output = "6" },
    // Alt-bind: first pattern matches, second skipped, body uses var
    // declared in P1.
    .{ .name = "alt_bind_first", .filter = ". as [$a, $b] ?// $x | $a", .input = "[5,7]", .expected_output = "5" },
    // Alt-bind: first pattern fails (non-array), fallback `$x` binds.
    .{ .name = "alt_bind_fallback", .filter = ". as [$a, $b] ?// $x | $x", .input = "42", .expected_output = "42" },

    // ── Category 10 — builtins (zero-arg) ─────────────────────────
    // One fixture per call-shape bucket with a representative name;
    // every name in the same bucket shares the same emit ladder, so
    // VM-equivalence on these fixtures certifies the entire bucket.
    .{ .name = "builtin_length_array", .filter = "length", .input = "[1,2,3,4]", .expected_output = "4" },
    .{ .name = "builtin_length_string", .filter = "length", .input = "\"hello\"", .expected_output = "5" },
    .{ .name = "builtin_keys", .filter = "keys", .input = "{\"b\":1,\"a\":2}", .expected_output = "[\"a\",\"b\"]" },
    .{ .name = "builtin_keys_unsorted", .filter = "keys_unsorted", .input = "{\"a\":1,\"b\":2}", .expected_output = "[\"a\",\"b\"]" },
    // jq `values` is a type-filter (returns input if non-null, else
    // empty) — NOT a dict-values function. Test against null input to
    // verify the empty-stream branch.
    .{ .name = "builtin_values_null", .filter = "values", .input = "null", .expected_output = "" },
    .{ .name = "builtin_empty", .filter = "empty", .input = "1", .expected_output = "" },
    .{ .name = "builtin_tostring", .filter = "tostring", .input = "42", .expected_output = "\"42\"" },
    .{ .name = "builtin_tonumber", .filter = "tonumber", .input = "\"42\"", .expected_output = "42" },
    .{ .name = "builtin_add_arr", .filter = "add", .input = "[1,2,3]", .expected_output = "6" },
    .{ .name = "builtin_sort", .filter = "sort", .input = "[3,1,2]", .expected_output = "[1,2,3]" },
    .{ .name = "builtin_reverse", .filter = "reverse", .input = "[1,2,3]", .expected_output = "[3,2,1]" },
    .{ .name = "builtin_min", .filter = "min", .input = "[3,1,2]", .expected_output = "1" },
    .{ .name = "builtin_max", .filter = "max", .input = "[3,1,2]", .expected_output = "3" },
    .{ .name = "builtin_to_entries", .filter = "to_entries", .input = "{\"a\":1}", .expected_output = "[{\"key\":\"a\",\"value\":1}]" },
    .{ .name = "builtin_unique", .filter = "unique", .input = "[3,1,2,1,3]", .expected_output = "[1,2,3]" },
    .{ .name = "builtin_floor", .filter = "floor", .input = "3.7", .expected_output = "3" },
    .{ .name = "builtin_ceil", .filter = "ceil", .input = "3.2", .expected_output = "4" },
    .{ .name = "builtin_sqrt", .filter = "sqrt", .input = "16", .expected_output = "4" },
    .{ .name = "builtin_abs", .filter = "abs", .input = "-5", .expected_output = "5" },
    .{ .name = "builtin_explode", .filter = "explode", .input = "\"hi\"", .expected_output = "[104,105]" },
    .{ .name = "builtin_ascii_upcase", .filter = "ascii_upcase", .input = "\"hi\"", .expected_output = "\"HI\"" },
    // Bare-ident builtins (`arrays`, `strings`, `numbers`,
    // `utf8bytelength`) reach the AST as `field_access` because the AST
    // parser's narrow zero-arg list rejects them. Cat-10 routes them
    // through the wider classifier — these fixtures exercise that path.
    .{ .name = "builtin_arrays_filter", .filter = "arrays", .input = "[1,2]", .expected_output = "[1,2]" },
    .{ .name = "builtin_strings_filter", .filter = "strings", .input = "\"x\"", .expected_output = "\"x\"" },
    .{ .name = "builtin_numbers_filter", .filter = "numbers", .input = "5", .expected_output = "5" },
    .{ .name = "builtin_utf8bytelength", .filter = "utf8bytelength", .input = "\"abc\"", .expected_output = "3" },

    // ── Category 10 — builtins (1-arg value) ──────────────────────
    .{ .name = "builtin_split", .filter = "split(\",\")", .input = "\"a,b,c\"", .expected_output = "[\"a\",\"b\",\"c\"]" },
    .{ .name = "builtin_join", .filter = "join(\"-\")", .input = "[\"a\",\"b\",\"c\"]", .expected_output = "\"a-b-c\"" },
    .{ .name = "builtin_startswith_t", .filter = "startswith(\"he\")", .input = "\"hello\"", .expected_output = "true" },
    .{ .name = "builtin_startswith_f", .filter = "startswith(\"xy\")", .input = "\"hello\"", .expected_output = "false" },
    .{ .name = "builtin_endswith_t", .filter = "endswith(\"lo\")", .input = "\"hello\"", .expected_output = "true" },
    .{ .name = "builtin_ltrimstr", .filter = "ltrimstr(\"foo\")", .input = "\"foobar\"", .expected_output = "\"bar\"" },
    .{ .name = "builtin_rtrimstr", .filter = "rtrimstr(\"bar\")", .input = "\"foobar\"", .expected_output = "\"foo\"" },
    .{ .name = "builtin_getpath", .filter = "getpath([\"a\",\"b\"])", .input = "{\"a\":{\"b\":42}}", .expected_output = "42" },
    .{ .name = "builtin_has_t", .filter = "has(\"a\")", .input = "{\"a\":1}", .expected_output = "true" },
    .{ .name = "builtin_has_f", .filter = "has(\"x\")", .input = "{\"a\":1}", .expected_output = "false" },
    .{ .name = "builtin_flatten1", .filter = "flatten(1)", .input = "[[1,2],[3,4]]", .expected_output = "[1,2,3,4]" },

    // ── Category 10 — builtins (1-arg filter) ─────────────────────
    .{ .name = "builtin_sort_by", .filter = "sort_by(.k)", .input = "[{\"k\":3},{\"k\":1},{\"k\":2}]", .expected_output = "[{\"k\":1},{\"k\":2},{\"k\":3}]" },
    .{ .name = "builtin_group_by", .filter = "group_by(.k)", .input = "[{\"k\":1,\"v\":1},{\"k\":1,\"v\":2},{\"k\":2,\"v\":3}]", .expected_output = "[[{\"k\":1,\"v\":1},{\"k\":1,\"v\":2}],[{\"k\":2,\"v\":3}]]" },
    .{ .name = "builtin_min_by", .filter = "min_by(.k)", .input = "[{\"k\":3},{\"k\":1},{\"k\":2}]", .expected_output = "{\"k\":1}" },
    .{ .name = "builtin_max_by", .filter = "max_by(.k)", .input = "[{\"k\":3},{\"k\":1},{\"k\":2}]", .expected_output = "{\"k\":3}" },
    .{ .name = "builtin_unique_by", .filter = "unique_by(.k)", .input = "[{\"k\":2},{\"k\":1},{\"k\":2}]", .expected_output = "[{\"k\":1},{\"k\":2}]" },
    .{ .name = "builtin_map_values", .filter = "map_values(. + 1)", .input = "{\"a\":1,\"b\":2}", .expected_output = "{\"a\":2,\"b\":3}" },

    // ── Category 10 — builtins (2-arg math/path) ──────────────────
    .{ .name = "builtin_pow", .filter = "pow(2; 8)", .input = "null", .expected_output = "256" },
    .{ .name = "builtin_atan2", .filter = "atan2(0; 1)", .input = "null", .expected_output = "0" },
    .{ .name = "builtin_setpath", .filter = "setpath([\"a\"]; 9)", .input = "{\"a\":1}", .expected_output = "{\"a\":9}" },

    // ── Category 10 — builtins (3-arg math) ───────────────────────
    .{ .name = "builtin_fma", .filter = "fma(2; 3; 4)", .input = "null", .expected_output = "10" },

    // ── Category 11 — regex builtins (literal pattern fast path) ──
    // Each fixture exercises one regex bid through a string-literal
    // pattern so the pool is populated at lower time. The new
    // compiler reads the pool index from the operand; the legacy
    // compiler did the same — VM-equivalence holds.
    .{ .name = "regex_test_t", .filter = "test(\"^[a-z]+$\")", .input = "\"foobar\"", .expected_output = "true" },
    .{ .name = "regex_test_f", .filter = "test(\"^[0-9]+$\")", .input = "\"foobar\"", .expected_output = "false" },
    .{ .name = "regex_test_flag_i", .filter = "test(\"FOO\"; \"i\")", .input = "\"foobar\"", .expected_output = "true" },
    .{ .name = "regex_match_obj", .filter = "match(\"o+\") | .offset", .input = "\"foobar\"", .expected_output = "1" },
    .{ .name = "regex_match_g_count", .filter = "[match(\"o\"; \"g\")] | length", .input = "\"foobar\"", .expected_output = "2" },
    .{ .name = "regex_capture", .filter = "capture(\"(?<n>[a-z]+)\")|.n", .input = "\"abc\"", .expected_output = "\"abc\"" },
    .{ .name = "regex_scan", .filter = "[scan(\"[a-z]+\")]", .input = "\"a1b2c\"", .expected_output = "[\"a\",\"b\",\"c\"]" },
    .{ .name = "regex_splits", .filter = "[splits(\"[0-9]+\")]", .input = "\"a1b22c\"", .expected_output = "[\"a\",\"b\",\"c\"]" },
    .{ .name = "regex_sub", .filter = "sub(\"o\"; \"X\")", .input = "\"foobar\"", .expected_output = "\"fXobar\"" },
    .{ .name = "regex_gsub", .filter = "gsub(\"o\"; \"X\")", .input = "\"foobar\"", .expected_output = "\"fXXbar\"" },
    .{ .name = "regex_sub_g_dispatches_gsub", .filter = "sub(\"o\"; \"X\"; \"g\")", .input = "\"foobar\"", .expected_output = "\"fXXbar\"" },

    // ── Category 11 — datetime builtins ──────────────────────────
    // Datetime values vary by clock; pick deterministic cases:
    //   - `gmtime` of a fixed timestamp → fixed broken-down array
    //   - `mktime | gmtime` round-trip → identity
    //   - `todate` of a fixed timestamp → fixed ISO string
    .{ .name = "datetime_gmtime_zero", .filter = "0 | gmtime", .input = "null", .expected_output = "[1970,0,1,0,0,0,4,0]" },
    .{ .name = "datetime_mktime_round_trip", .filter = "[1970,0,1,0,0,0,4,0] | mktime", .input = "null", .expected_output = "0" },
    .{ .name = "datetime_todate_zero", .filter = "0 | todate", .input = "null", .expected_output = "\"1970-01-01T00:00:00Z\"" },
    .{ .name = "datetime_fromdate_zero", .filter = "\"1970-01-01T00:00:00Z\" | fromdate", .input = "null", .expected_output = "0" },
    .{ .name = "datetime_strftime_iso", .filter = "0 | gmtime | strftime(\"%Y-%m-%d\")", .input = "null", .expected_output = "\"1970-01-01\"" },

    // ── Category 11 — extended arg-builtin surface ───────────────
    // Bare-name forms reaching AST as `field_access` (not in the
    // narrow `isZeroArgBuiltin` list — see `src/ast/parser.zig:1601`).
    .{ .name = "builtin_utf8bytelength_bare", .filter = "utf8bytelength", .input = "\"abc\"", .expected_output = "3" },
    .{ .name = "builtin_trim_bare", .filter = "trim", .input = "\"  hi  \"", .expected_output = "\"hi\"" },

    // ── Category 9 — user-defined functions + recursion + filter args ──
    // Simple zero-arg def — call resolves to inline expansion.
    .{ .name = "udf_simple_zero_arg", .filter = "def f: . + 1; f", .input = "10", .expected_output = "11" },
    // Filter arg — re-substitutes the caller's AST sub-tree.
    .{ .name = "udf_filter_arg_basic", .filter = "def double(x): x + x; double(. + 1)", .input = "5", .expected_output = "12" },
    // Filter arg used multiple times — substitution happens per use.
    .{ .name = "udf_filter_arg_multi", .filter = "def thrice(g): [g, g, g]; thrice(.+10)", .input = "5", .expected_output = "[15,15,15]" },
    // Value arg — `$x` form, captured into a fresh var_id at call site.
    .{ .name = "udf_value_arg_basic", .filter = "def myadd($x): . + $x; myadd(5)", .input = "10", .expected_output = "15" },
    // Two value args — both captured/popped around body.
    .{ .name = "udf_value_arg_two", .filter = "def f($a; $b): $a + $b; f(2; 3)", .input = "null", .expected_output = "5" },
    // Mixed filter + value args.
    .{ .name = "udf_mixed_args", .filter = "def f(g; $x): g + $x; f(.+1; 10)", .input = "5", .expected_output = "16" },
    // Direct self-recursion — fact(5) = 120.
    .{ .name = "udf_recursion_fact", .filter = "def fact: if . == 0 then 1 else . * (.-1 | fact) end; fact", .input = "5", .expected_output = "120" },
    // Counting recursion — `loop` increments until reaching the
    // hard-coded ceiling. Verifies the recursive body's `call_function`
    // jump emits cleanly with no value-arg captures interfering.
    .{ .name = "udf_recursion_loop", .filter = "def loop: if . == 5 then . else . + 1 | loop end; loop", .input = "0", .expected_output = "5" },
    // Two independent functions used in sequence (not mutually recursive,
    // but both registered + inline-expanded against shared scope).
    .{ .name = "udf_two_funcs", .filter = "def helper: . + 1; def main: helper * 2; main", .input = "5", .expected_output = "12" },
    // Function call inside an array constructor — generator semantics
    // surface through the filter arg.
    .{ .name = "udf_in_array_ctor", .filter = "def f(g): [g]; f(.[])", .input = "[1,2,3]", .expected_output = "[1,2,3]" },

    // ── Category 13 — generator-arg builtins ──────────────────────
    // range/limit/skip/nth/first/last share the streaming
    // save/restore + bounded-yield template; one fixture per
    // distinct shape covers the lowering+emit dispatch.
    .{ .name = "cat13_range_1", .filter = "[range(5)]", .input = "null", .expected_output = "[0,1,2,3,4]" },
    .{ .name = "cat13_range_2", .filter = "[range(2;7)]", .input = "null", .expected_output = "[2,3,4,5,6]" },
    .{ .name = "cat13_range_3", .filter = "[range(0;10;2)]", .input = "null", .expected_output = "[0,2,4,6,8]" },
    .{ .name = "cat13_range_neg_step", .filter = "[range(5;0;-1)]", .input = "null", .expected_output = "[5,4,3,2,1]" },
    .{ .name = "cat13_range_in_arr_len", .filter = "[range(3)] | length", .input = "null", .expected_output = "3" },
    .{ .name = "cat13_limit_basic", .filter = "[limit(2; range(100))]", .input = "null", .expected_output = "[0,1]" },
    .{ .name = "cat13_limit_zero", .filter = "[limit(0; range(5))]", .input = "null", .expected_output = "[]" },
    .{ .name = "cat13_first_arg1", .filter = "first(range(5))", .input = "null", .expected_output = "0" },
    .{ .name = "cat13_first_zero_arg", .filter = "first", .input = "[10,20,30]", .expected_output = "10" },
    .{ .name = "cat13_last_arg1", .filter = "last(range(5))", .input = "null", .expected_output = "4" },
    .{ .name = "cat13_last_zero_arg", .filter = "last", .input = "[10,20,30]", .expected_output = "30" },
    .{ .name = "cat13_nth_basic", .filter = "nth(3; range(10))", .input = "null", .expected_output = "3" },
    .{ .name = "cat13_skip_basic", .filter = "[skip(2; range(5))]", .input = "null", .expected_output = "[2,3,4]" },
    .{ .name = "cat13_skip_overrun", .filter = "[skip(10; range(5))]", .input = "null", .expected_output = "[]" },
    // Generator-form n: each value triggers a separate frame.
    .{ .name = "cat13_limit_n_gen", .filter = "[limit(1,2; range(5))]", .input = "null", .expected_output = "[0,0,1]" },

    // Cat-13 — error-case parity. Negative n in nth/skip/limit raises
    // UserError with the legacy-baked message strings (vm.zig:1719/1766/1768).
    // expected_output left empty: the harness compares both backends'
    // pre-error byte streams (both empty here, error fires before any
    // yield) AND the captured err.kind ("UserError"). 3-way pin would
    // require pinning a runtime error string the harness doesn't expose.
    .{ .name = "cat13_nth_negative", .filter = "nth(-1; range(5))", .input = "null", .expected_output = "" },
    .{ .name = "cat13_skip_negative", .filter = "skip(-1; range(5))", .input = "null", .expected_output = "" },
    .{ .name = "cat13_limit_negative", .filter = "limit(-1; range(5))", .input = "null", .expected_output = "" },

    // Cat-13 — edge-case parity.
    // range(from; to; 0) short-circuits in vm.zig:5354/5357 (by==0 →
    // empty stream); length of [empty] is 0.
    .{ .name = "cat13_range_zero_step", .filter = "[range(0;10;0)] | length", .input = "null", .expected_output = "0" },
    // last(empty) collects [] then loads -1 → null per .[-1] on empty array.
    .{ .name = "cat13_last_empty", .filter = "last(empty)", .input = "null", .expected_output = "null" },
    // Generator-form n in nth: each n triggers a separate frame, both
    // outputs concatenate into the surrounding array.
    .{ .name = "cat13_nth_gen_form_n", .filter = "[nth(0,2; range(5))]", .input = "null", .expected_output = "[0,2]" },

    // ── Category 17 — format builtins ─────────────────────────────
    // Two AST surfaces share the format-name table. Coverage matrix:
    //   1. Standalone `@fmt` (BuiltinCall) — applied to current value.
    //   2. `expr | @fmt` pipe shape — same BuiltinCall on a piped value.
    //   3. `@fmt "lit"` (format_string, single literal part) — emits
    //      bare push_string (legacy compiler.zig:6219-6225).
    //   4. `@fmt "lit\(expr)tail"` — interp ladder with format apply
    //      per expr part (legacy compileStringInterpolation).
    .{ .name = "cat17_csv_arr", .filter = "[1,2,3] | @csv", .input = "null", .expected_output = "\"1,2,3\"" },
    .{ .name = "cat17_json_obj", .filter = "{\"a\":1} | @json", .input = "null", .expected_output = "\"{\\\"a\\\":1}\"" },
    .{ .name = "cat17_uri_plain", .filter = "@uri", .input = "\"hello\"", .expected_output = "\"hello\"" },
    .{ .name = "cat17_uri_space", .filter = "@uri", .input = "\"a b\"", .expected_output = "\"a%20b\"" },
    .{ .name = "cat17_base64_enc", .filter = "@base64", .input = "\"world\"", .expected_output = "\"d29ybGQ=\"" },
    .{ .name = "cat17_base64_dec", .filter = "@base64d", .input = "\"d29ybGQ=\"", .expected_output = "\"world\"" },
    .{ .name = "cat17_text_int", .filter = "42 | @text", .input = "null", .expected_output = "\"42\"" },
    .{ .name = "cat17_html_escape", .filter = "@html", .input = "\"<a>\"", .expected_output = "\"&lt;a&gt;\"" },
    // Format-string interpolation: @uri-applies to the interpolated
    // expression (the literal prefix `key=` is push_string'd raw, the
    // `.foo` value flows through `call_builtin(.format_uri)` per
    // emitInterpLadder's format_bid arm).
    .{ .name = "cat17_uri_interp", .filter = "@uri \"key=\\(.foo)\"", .input = "{\"foo\":\"a b\"}", .expected_output = "\"key=a%20b\"" },
    // Multi-part interpolation: ≥2 \(...) expressions in one format
    // string. Exercises the interp ladder iterating multiple times
    // through the format-bid arm with literal segments between exprs.
    .{ .name = "cat17_uri_multi_interp", .filter = "@uri \"key1=\\(.a)&key2=\\(.b)\"", .input = "{\"a\":\"hello world\",\"b\":\"f&o=o\"}", .expected_output = "\"key1=hello%20world&key2=f%26o%3Do\"" },
    // Round-trip @base64 → @base64d.
    .{ .name = "cat17_base64_roundtrip", .filter = "@base64 | @base64d", .input = "\"hi\"", .expected_output = "\"hi\"" },
    // Format-string single literal part: emits bare push_string per
    // legacy compiler.zig:6219-6225 (the format name is dispatch-only;
    // no actual format apply runs because there is nothing to format).
    .{ .name = "cat17_csv_string_lit", .filter = "@csv \"hi\"", .input = "null", .expected_output = "\"hi\"" },
    // @sh shell-quotes a string.
    .{ .name = "cat17_sh_quote", .filter = "@sh", .input = "\"hi'lo\"", .expected_output = "\"'hi'\\\\''lo'\"" },
    // @tsv on an array of scalars — tab-separated output.
    .{ .name = "cat17_tsv_arr", .filter = "[1,\"two\",3] | @tsv", .input = "null", .expected_output = "\"1\\ttwo\\t3\"" },
    // @urid undoes @uri.
    .{ .name = "cat17_urid_decode", .filter = "@urid", .input = "\"hello%20world\"", .expected_output = "\"hello world\"" },
    // Error parity: @base64d on invalid base64 fires a type/decode
    // error; both backends must surface the same error class. Empty
    // expected_output: harness compares pre-error byte streams (both
    // empty) and err.kind tags.
    .{ .name = "cat17_base64d_invalid", .filter = "@base64d", .input = "\"not-valid-base64-==\"", .expected_output = "" },
    // ── Category 15 — control flow (label/break, until, while) ───────
    // label/break unwinds the LabelFrame on the fork stack; until/while
    // share a backward-jump pattern. All four match legacy bytecode
    // shapes byte-for-byte (ir.label / ir.break_ / ir.while_ / ir.until_).
    // until — apply update until cond, output final value only.
    .{ .name = "cat15_until_basic", .filter = "until(.>=10; .+1)", .input = "0", .expected_output = "10" },
    .{ .name = "cat15_until_already", .filter = "until(.>=10; .+1)", .input = "20", .expected_output = "20" },
    // while — emit current then update, until cond falsy.
    .{ .name = "cat15_while_basic", .filter = "[while(.<100; .*2)] | length", .input = "1", .expected_output = "7" },
    .{ .name = "cat15_while_collect", .filter = "[while(.<10; .+3)]", .input = "1", .expected_output = "[1,4,7]" },
    // while with cond initially false — generator yields nothing.
    .{ .name = "cat15_while_initially_false", .filter = "[while(.<0; .+1)]", .input = "5", .expected_output = "[]" },
    // label/break — break out of an iterator-driven generator. Yields
    // each range element until 2; then yields 2 once more and breaks
    // out so 3,4 are never produced.
    .{ .name = "cat15_label_break_range", .filter = "label $out | range(5) | if . == 2 then ., (. | break $out) else . end", .input = "null", .expected_output = "0\n1\n2" },
    // label without break — range yields all elements then label exits cleanly.
    .{ .name = "cat15_label_no_break", .filter = "[label $out | range(3)]", .input = "null", .expected_output = "[0,1,2]" },
    // Nested labels — break the OUTER label from inside the inner.
    .{ .name = "cat15_label_nested_outer", .filter = "[label $a | range(5) | label $b | if . == 2 then ., (. | break $a) else . end]", .input = "null", .expected_output = "[0,1,2]" },
    // break inside a label-bracketed limit — exits early via the outer label.
    .{ .name = "cat15_label_break_in_limit", .filter = "[label $out | limit(10; range(100) | if . == 4 then ., (. | break $out) else . end)]", .input = "null", .expected_output = "[0,1,2,3,4]" },
    // break unknown label — both backends surface a compile error.
    .{ .name = "cat15_break_undefined", .filter = "break $undefined", .input = "null", .expected_output = "", .expects_compile_err = true },
    // ── Cat-18 (P27) — dynamic regex + computed bracket access ──
    // Control: literal regex still works after dynamic guard removal.
    .{ .name = "cat18_regex_test_lit_control", .filter = "test(\"h.*\")", .input = "\"hello\"", .expected_output = "true" },
    // Dynamic 1-arg: pattern reaches value stack via REGEX_POOL_DYNAMIC.
    .{ .name = "cat18_regex_test_dyn_var", .filter = "\"abc123\" as $pat | \"test abc123\" | test($pat)", .input = "null", .expected_output = "true" },
    // Dynamic match($p) returning a single match — accesses .offset.
    .{ .name = "cat18_regex_match_dyn_offset", .filter = "\"o+\" as $p | \"foobar\" | match($p) | .offset", .input = "null", .expected_output = "1" },
    // Dynamic 2-arg sub($p; $r) — both args reach the value stack.
    .{ .name = "cat18_regex_sub_dyn", .filter = "\"-\" as $p | \":\" as $r | \"a-b\" | sub($p; $r)", .input = "null", .expected_output = "\"a:b\"" },
    // Dynamic gsub via the same path.
    .{ .name = "cat18_regex_gsub_dyn", .filter = "\"o\" as $p | \"X\" as $r | \"foobar\" | gsub($p; $r)", .input = "null", .expected_output = "\"fXXbar\"" },
    // Dynamic scan($pat) collected.
    .{ .name = "cat18_regex_scan_dyn", .filter = "\"[a-z]+\" as $p | \"a1b2c\" | [scan($p)]", .input = "null", .expected_output = "[\"a\",\"b\",\"c\"]" },
    // Dynamic capture using a $-bound pattern.
    .{ .name = "cat18_regex_capture_dyn", .filter = "\"(?<n>[a-z]+)\" as $p | \"abc\" | capture($p) | .n", .input = "null", .expected_output = "\"abc\"" },
    // Bracket control: literal index unaffected.
    .{ .name = "cat18_bracket_lit_control", .filter = "[10,20,30] | .[1]", .input = "null", .expected_output = "20" },
    // Standalone .[$x] — `__computed_access` AST shape via parser.zig:680-684.
    .{ .name = "cat18_bracket_standalone_var", .filter = "[10,20,30] as $arr | 1 as $i | $arr[$i]", .input = "null", .expected_output = "20" },
    // Object key lookup via $-bound key.
    .{ .name = "cat18_bracket_object_key_var", .filter = "{\"a\":1, \"b\":2} as $o | \"a\" as $k | $o[$k]", .input = "null", .expected_output = "1" },
    // Generator-form key — fork backtracks per yielded key, base survives
    // via the two-var capture pattern.
    .{ .name = "cat18_bracket_generator_key", .filter = "[10,20,30] | [.[(0,2)]]", .input = "null", .expected_output = "[10,30]" },
    // Negative index works — passthrough to legacy load_computed semantics.
    .{ .name = "cat18_bracket_negative_idx", .filter = "[10,20,30] as $arr | -1 as $i | $arr[$i]", .input = "null", .expected_output = "30" },
    // Computed expression key — exercises the `computed_index` shape
    // with a non-trivial key. Pipe-prepares the indexable array as
    // current; uses captured vars to compute the index (1 + 2 = 3 →
    // [10,20,30,40,50][3] = 40).
    .{ .name = "cat18_bracket_arith_key", .filter = "[10,20,30,40,50] as $arr | 1 as $a | 2 as $b | $arr[($a + $b)]", .input = "null", .expected_output = "40" },
    // Standalone `.[<lit>]` — exercises the parser's
    // `__computed_access(BuiltinCall)` AST shape with a literal key
    // arg. Confirms the new lower/emit path agrees with legacy's
    // `compileComputedBracket` for the literal-key case.
    .{ .name = "cat18_bracket_standalone_obj_lit", .filter = ".[\"foo\"]", .input = "{\"foo\":42}", .expected_output = "42" },
    // Standalone `.[<expr>]` where the expression yields a literal
    // index — exercises the `__computed_access` arm with a non-trivial
    // key (a paren-grouped int).
    .{ .name = "cat18_bracket_standalone_paren", .filter = ".[(0)]", .input = "[10,20,30]", .expected_output = "10" },
    // Standalone `.[(generator)]` — fork-backtrack over the key
    // generator yields multiple outputs from a single input lookup.
    .{ .name = "cat18_bracket_standalone_gen", .filter = "[.[(0,2)]]", .input = "[10,20,30]", .expected_output = "[10,30]" },
    // ── Cat-18 negative-case fixtures (runtime error parity) ──
    // Indexing an array with a non-numeric key raises TypeError on
    // both backends — `expected_output` left empty so the harness
    // only checks legacy↔new err.kind parity (no absolute pin).
    .{ .name = "cat18_bracket_index_type_error", .filter = "[1,2,3] as $arr | \"x\" as $i | $arr[$i]", .input = "null" },
    // Calling `test` with a non-string pattern raises TypeError on
    // both backends. Same legacy↔new parity check.
    .{ .name = "cat18_regex_pattern_type_error", .filter = "123 as $p | \"abc\" | test($p)", .input = "null" },
    // ── Cat-16 (P25) — error 0/1-arity, index/rindex/indices, del general ──
    // 0-arity `error` routes through the `zero_arg` class (added to
    // `isZeroArgBuiltin`); legacy maps it through `zeroArgBuiltinId`
    // → `BuiltinId.error_`. Caught by `try` so the user sees the
    // input value back; without `try` both backends raise UserError.
    .{ .name = "cat16_error_0arg_caught", .filter = "try error catch .", .input = "\"oops\"", .expected_output = "\"oops\"" },
    // 0-arity `error` on null — caught error returns null.
    .{ .name = "cat16_error_0arg_null", .filter = "try error catch .", .input = "null", .expected_output = "null" },
    // 1-arity `error("msg")` — pipe + call_builtin(error_) shape.
    // The message reaches current via the pipe; try-catch surfaces it.
    .{ .name = "cat16_error_1arg_msg", .filter = "try error(\"oops\") catch .", .input = "null", .expected_output = "\"oops\"" },
    // 1-arity `error(.)` — pass-through input as the error message.
    .{ .name = "cat16_error_1arg_input", .filter = "try error(.) catch .", .input = "{\"k\":1}", .expected_output = "{\"k\":1}" },
    // index — substring start position. Legacy `compileIndex` →
    // `compileValueArgBuiltin1(.index_)`.
    .{ .name = "cat16_index_string", .filter = "index(\"ll\")", .input = "\"hello\"", .expected_output = "2" },
    // rindex — substring last position. Legacy `compileRindex` →
    // `compileValueArgBuiltin1(.rindex)`.
    .{ .name = "cat16_rindex_string", .filter = "rindex(\"l\")", .input = "\"hello\"", .expected_output = "3" },
    // indices — all substring positions as an array.
    .{ .name = "cat16_indices_string", .filter = "indices(\"l\")", .input = "\"hello\"", .expected_output = "[2,3]" },
    // indices generator-arg form — `comma` SemOp child causes the
    // VM to fork per branch; each yield calls `call_builtin(indices)`
    // separately. Wrapped in `[...]` so the two outputs collect.
    .{ .name = "cat16_indices_generator", .filter = "[indices(\"a\", \"b\")]", .input = "\"abab\"", .expected_output = "[[0,2],[1,3]]" },
    // del simple — single field deletion. Mirrors legacy
    // `compileDel`'s path-collect + delpaths pipeline.
    .{ .name = "cat16_del_field", .filter = "del(.a)", .input = "{\"a\":1,\"b\":2}", .expected_output = "{\"b\":2}" },
    // del comma-arg — `del(.a, .c)` lowers to a `comma` body;
    // path_begin/path_end collects both paths into the same array,
    // then a single `delpaths` deletes them atomically.
    .{ .name = "cat16_del_multi_field", .filter = "del(.a, .c)", .input = "{\"a\":1,\"b\":2,\"c\":3}", .expected_output = "{\"b\":2}" },
    // del array slice — exercises the `slice` SemOp inside the
    // path expression child; legacy `delpaths` expands slice
    // components into normalized indices before deletion.
    .{ .name = "cat16_del_array_slice", .filter = "del(.[1:3])", .input = "[1,2,3,4,5]", .expected_output = "[1,4,5]" },
    // del with empty body — `empty` yields nothing, so the path
    // array is empty and `delpaths` is a no-op. Verifies the
    // emit-time scaffold doesn't crash on a zero-yield body.
    .{ .name = "cat16_del_empty", .filter = "del(empty)", .input = "{\"a\":1}", .expected_output = "{\"a\":1}" },
    // del with invalid path expression — legacy raises a structured
    // path error mid-evaluation; both backends surface the same
    // error class through try-catch.
    .{ .name = "cat16_del_invalid_path_caught", .filter = "try del(.a + 1) catch \"caught\"", .input = "{\"a\":1}", .expected_output = "\"caught\"" },
    // del nested path — multi-level path expression survives the
    // path-collect pipeline.
    .{ .name = "cat16_del_nested", .filter = "del(.a.b)", .input = "{\"a\":{\"b\":1,\"c\":2}}", .expected_output = "{\"a\":{\"c\":2}}" },

    // ── Cat-14 (P23) — foreach / reduce / as-pattern body fix ────
    // Reduce: classic accumulator over `.[]`.
    .{ .name = "cat14_reduce_sum_iter", .filter = "reduce .[] as $x (0; .+$x)", .input = "[1,2,3,4,5]", .expected_output = "15" },
    // Reduce over a generator (`range(N)`) — exercises cat-13 +
    // cat-14 composition; INIT is a literal int.
    .{ .name = "cat14_reduce_range", .filter = "reduce range(5) as $i (0; .+$i)", .input = "null", .expected_output = "10" },
    // Reduce with array destructure pattern — pattern var ladder
    // wired through pattern_capture.
    .{ .name = "cat14_reduce_array_destruct", .filter = "reduce .[] as [$a, $b] (0; . + $a + $b)", .input = "[[1,2],[3,4]]", .expected_output = "10" },
    // Foreach 2-arg form (no extract) — accumulates into the array.
    .{ .name = "cat14_foreach_2arg", .filter = "[foreach .[] as $x (0; .+$x)]", .input = "[1,2,3]", .expected_output = "[1,3,6]" },
    // Foreach 3-arg form (extract clause multiplies acc by 10).
    .{ .name = "cat14_foreach_3arg_extract", .filter = "[foreach .[] as $x (0; .+$x; . * 10)]", .input = "[1,2,3]", .expected_output = "[10,30,60]" },
    // Foreach over a generator with extract.
    .{ .name = "cat14_foreach_range_extract", .filter = "[foreach range(3) as $x (0; .+$x; .+10)]", .input = "null", .expected_output = "[10,11,13]" },
    // ── as-pattern body bug fix (cat-4 fix uncovered by P22) ─────
    // The bug: `expr as $k | body` was emitting an extra `pipe` op
    // between `expr` and the destructure ladder, clobbering current
    // with expr's result. body must run on the input that was
    // current BEFORE expr evaluated.
    .{ .name = "cat14_aspat_body_obj_key", .filter = "\"foo\" as $k | .[$k]", .input = "{\"foo\":42}", .expected_output = "42" },
    .{ .name = "cat14_aspat_body_arr_idx", .filter = "\"x\" as $unused | .[1]", .input = "[10,20,30]", .expected_output = "20" },
    // Body uses original input numerically — fix confirms current
    // is still 5 after `"lit" as $u`.
    .{ .name = "cat14_aspat_body_arith", .filter = "\"lit\" as $u | . + 1", .input = "5", .expected_output = "6" },
    // Composition: cat-15 label + cat-15 generator break out of an
    // iterated stream — exercises label/break stack survival across
    // a typical jq idiom. Mirrors a known-working legacy output.
    .{ .name = "cat14_label_break_iter", .filter = "[label $out | .[] | if . > 3 then break $out else . end]", .input = "[1,2,3,4,5]", .expected_output = "[1,2,3]" },
    // Composition: as-pattern body fix nested inside a reduce update.
    // The accumulator is the original value (current at INIT), and
    // each EXPR step binds an unrelated string into $u. After the
    // bug fix, the body of `"x" as $u | .+$x` runs against the acc
    // — proving the fix doesn't regress when as-pattern lives
    // inside a reduce update.
    .{ .name = "cat14_reduce_with_as_body", .filter = "reduce .[] as $x (0; \"x\" as $u | . + $x)", .input = "[1,2,3]", .expected_output = "6" },
    // ── $__loc__ magic var (Phase 2 P2 — variable-binding) ───────
    // `$__loc__` is jq's synthetic compile-time location object
    // (`{"file":"<top-level>","line":1}`). Legacy expands it inline
    // via `emitLocObject` (`src/query/src/compiler.zig:6461`); the
    // new compiler now mirrors that with a synthesised `obj_ctor`
    // IR node so the bytecode shape matches the legacy backend.
    .{ .name = "p2_loc_bare", .filter = "$__loc__", .input = "null", .expected_output = "{\"file\":\"<top-level>\",\"line\":1}" },
    .{ .name = "p2_loc_in_obj_merge", .filter = "{ a, $__loc__, c }", .input = "{\"a\":[1,2,3],\"c\":{\"hi\":\"hey\"}}", .expected_output = "{\"a\":[1,2,3],\"__loc__\":{\"file\":\"<top-level>\",\"line\":1},\"c\":{\"hi\":\"hey\"}}" },
    .{ .name = "p2_loc_pipe_field", .filter = "$__loc__ | .file", .input = "null", .expected_output = "\"<top-level>\"" },
    .{ .name = "p2_loc_pipe_line", .filter = "$__loc__.line", .input = "null", .expected_output = "1" },
};

/// One JSON-encoded value per emitted iterator output, separated by '\n'.
/// Compact format — matches the `--compact-output` mode jq users diff
/// against. The runtime error (if any) is captured as a structured tag so
/// we can compare error kinds + offsets across backends without leaking
/// `ZqError` enum names through `@tagName` mismatches.
const RunResult = struct {
    output: []u8,
    err: ?ErrInfo,

    const ErrInfo = struct {
        kind: []const u8,
    };

    fn deinit(self: *RunResult, alloc: std.mem.Allocator) void {
        alloc.free(self.output);
    }
};

fn runQuery(
    cq: *const query.CompiledQuery,
    tape: types_mod.Tape,
    alloc: std.mem.Allocator,
) !RunResult {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(alloc);

    var sink: output_mod.BufferSink = .{ .list = &buf, .aa = alloc };
    var first: bool = true;

    var it = try cq.execute(tape, &.{}, alloc);
    defer it.deinit();

    while (true) {
        const v_opt = it.next() catch |e| {
            const owned = try buf.toOwnedSlice(alloc);
            return .{ .output = owned, .err = .{ .kind = @errorName(e) } };
        };
        const v = v_opt orelse break;
        if (!first) try sink.writeByte('\n');
        first = false;
        try output_mod.serialize(&sink, v, .compact, null, .{});
    }

    const owned = try buf.toOwnedSlice(alloc);
    return .{ .output = owned, .err = null };
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var match: u32 = 0;
    var mismatch: u32 = 0;
    var skipped: u32 = 0;
    var compile_err: u32 = 0;

    var stdout_buf: std.ArrayList(u8) = .{};
    defer stdout_buf.deinit(alloc);
    const w = stdout_buf.writer(alloc);

    for (FIXTURES) |fx| {
        // Legacy compile (always legacy regardless of -Dcompile=).
        var legacy_result = try query.CompiledQuery.compileLegacy(fx.filter, .{}, alloc);
        defer switch (legacy_result) {
            .ok => |*cq| cq.deinit(),
            .err => {},
        };

        switch (legacy_result) {
            .err => |ce| {
                if (!fx.expects_compile_err) {
                    try w.print("LEGACY_COMPILE_ERR name={s} filter={s} kind={s}\n", .{ fx.name, fx.filter, @tagName(ce.kind) });
                    compile_err += 1;
                    continue;
                }
                skipped += 1;
                try w.print("SKIP name={s} reason=expected-compile-err\n", .{fx.name});
                continue;
            },
            .ok => {},
        }

        const new_result = query.CompiledQuery.compileNew(fx.filter, .{}, alloc) catch |e| switch (e) {
            error.NewCompilerNotImplemented => {
                skipped += 1;
                try w.print("SKIP name={s} reason=new-compiler-not-implemented\n", .{fx.name});
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        var new_compiled = new_result;
        defer switch (new_compiled) {
            .ok => |*cq| cq.deinit(),
            .err => {},
        };

        switch (new_compiled) {
            .err => |ce| {
                try w.print("NEW_COMPILE_ERR name={s} filter={s} kind={s}\n", .{ fx.name, fx.filter, @tagName(ce.kind) });
                compile_err += 1;
                continue;
            },
            .ok => {},
        }

        // Both backends compiled. Build a Tape from `fx.input` and run
        // each compiled query through the VM, capturing its full output
        // stream (or runtime error). Byte-diff the streams.
        var legacy_parser = parser_mod.Parser.init(alloc) catch |e| return e;
        defer legacy_parser.deinit();
        const legacy_feed = try legacy_parser.feed(fx.input, true);
        const legacy_tape = switch (legacy_feed) {
            .done => |d| d.tape,
            .need_more => {
                try w.print("INPUT_PARSE_ERR name={s} input={s}\n", .{ fx.name, fx.input });
                compile_err += 1;
                continue;
            },
        };

        var new_parser = parser_mod.Parser.init(alloc) catch |e| return e;
        defer new_parser.deinit();
        const new_feed = try new_parser.feed(fx.input, true);
        const new_tape = switch (new_feed) {
            .done => |d| d.tape,
            .need_more => {
                try w.print("INPUT_PARSE_ERR name={s} input={s}\n", .{ fx.name, fx.input });
                compile_err += 1;
                continue;
            },
        };

        const legacy_cq = legacy_result.ok;
        const new_cq = new_compiled.ok;

        var legacy_run = try runQuery(&legacy_cq, legacy_tape, alloc);
        defer legacy_run.deinit(alloc);
        var new_run = try runQuery(&new_cq, new_tape, alloc);
        defer new_run.deinit(alloc);

        const same_bytes = std.mem.eql(u8, legacy_run.output, new_run.output);
        const legacy_err_name: ?[]const u8 = if (legacy_run.err) |e| e.kind else null;
        const new_err_name: ?[]const u8 = if (new_run.err) |e| e.kind else null;
        const same_err = blk: {
            if (legacy_err_name == null and new_err_name == null) break :blk true;
            if (legacy_err_name == null or new_err_name == null) break :blk false;
            break :blk std.mem.eql(u8, legacy_err_name.?, new_err_name.?);
        };

        // 3-way comparison: when `expected_output` is set, both backends
        // must match it AND each other. When empty, fall back to the
        // legacy-vs-new pairwise check (backward-compatible default).
        const has_expected = fx.expected_output.len > 0;
        const matches_expected = !has_expected or
            (std.mem.eql(u8, legacy_run.output, fx.expected_output) and
                std.mem.eql(u8, new_run.output, fx.expected_output));

        if (same_bytes and same_err and matches_expected) {
            match += 1;
            try w.print("MATCH name={s} filter={s}\n", .{ fx.name, fx.filter });
        } else {
            mismatch += 1;
            try w.print(
                "MISMATCH name={s} filter={s} input={s}\n  legacy_out=`{s}` legacy_err={s}\n  new_out=   `{s}` new_err=   {s}\n  expected=  `{s}`\n",
                .{
                    fx.name,
                    fx.filter,
                    fx.input,
                    legacy_run.output,
                    legacy_err_name orelse "<none>",
                    new_run.output,
                    new_err_name orelse "<none>",
                    fx.expected_output,
                },
            );
        }
    }

    try w.print("\nvm_equiv: total={d} match={d} mismatch={d} skipped={d} compile_err={d}\n", .{
        FIXTURES.len,
        match,
        mismatch,
        skipped,
        compile_err,
    });

    try std.fs.File.stdout().writeAll(stdout_buf.items);

    if (mismatch > 0 or compile_err > 0) std.process.exit(1);
}
