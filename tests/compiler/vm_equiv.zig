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
