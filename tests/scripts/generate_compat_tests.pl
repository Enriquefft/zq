#!/usr/bin/perl
# generate_compat_tests.pl — regenerate tests/compat/ from jq's test suite.
#
# Usage:
#   perl tests/scripts/generate_compat_tests.pl [path/to/jq.test]
#
# Default source: ../jq/tests/jq.test (relative to the zq repo root).
# Output:        tests/compat/  (helpers.zig + root.zig + one file per section)
#
# Sections are defined by explicit line-number boundaries from jq.test.
# Update SECTIONS below when jq.test is updated.
#
# Generated file strategy:
#   helpers.zig     — shared utilities (runFilter, expectCompileError, etc.)
#   root.zig        — comptime-imports all section files
#   <section>.zig   — one file per section, named by topic
#
# QuerySyntaxError → test FAILS  (filter not yet implemented — fix it)
# Any other error  → test FAILS  (real compatibility gap)
# Wrong output     → assertion FAILS
# %%FAIL tests     → expectCompileError()

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Path qw(make_path);

my $script_dir   = dirname(abs_path($0));
my $zq_root      = dirname(dirname($script_dir));
my $projects_dir = dirname($zq_root);

my $jq_test = $ARGV[0] // "$projects_dir/jq/tests/jq.test";
my $out_dir  = "$script_dir/../compat";

make_path($out_dir);

# ── Section boundaries ────────────────────────────────────────────────────────
# Each entry: [start_line, stem]
# A test belongs to a section if its source line >= start_line of that section
# and < start_line of the next section.
# Update these line numbers when jq.test changes significantly.
my @SECTIONS = (
    [    1, 'literals'          ],  # Simple value tests / parser
    [  111, 'object_construction'],  # Dictionary construction syntax
    [  145, 'field_access'       ],  # Field access, piping
    [  210, 'array_indices'      ],  # Negative array indices / slices
    [  234, 'iteration'          ],  # Multiple outputs, iteration, generators
    [  495, 'variables'          ],  # Variables, destructuring, as-patterns
    [  574, 'builtins'           ],  # Builtin functions
    [  780, 'user_functions'     ],  # User-defined functions
    [ 1107, 'paths'              ],  # Paths, getpath, setpath, delpaths
    [ 1219, 'assignment'         ],  # Assignment operators
    [ 1311, 'conditionals'       ],  # Conditionals: if/elif/else
    [ 1389, 'comparisons'        ],  # Numeric comparison, equality
    [ 1447, 'try_catch'          ],  # Try/catch, ? operator, error handling
    [ 1740, 'string_ops'         ],  # String operations, format strings
    [ 1884, 'datetime'           ],  # Date/time functions
    [ 2057, 'numbers'            ],  # Number handling, precision, literals
    [ 2214, 'unary_negation'     ],  # Unary negation numerical precision
    [ 2293, 'object_merge'       ],  # Object construction & recursive merge
    [ 2415, 'regression'         ],  # Regression tests, edge cases
);

sub section_for_line {
    my ($n) = @_;
    my $stem = $SECTIONS[0][1];
    for my $s (@SECTIONS) {
        last if $s->[0] > $n;
        $stem = $s->[1];
    }
    return $stem;
}

# ── Parse all test cases ──────────────────────────────────────────────────────

open my $fh, '<:utf8', $jq_test or die "Cannot open $jq_test: $!\n";

my @tests;
my $line_num = 0;

while (defined(my $line = <$fh>)) {
    $line_num++;
    chomp $line;
    next if $line =~ /^\s*$/ || $line =~ /^#/;

    # %%FAIL: filter that must not compile.
    if ($line =~ /^%%FAIL/) {
        my $fail_line = $line_num;
        my $filter = '';
        while (defined($line = <$fh>)) {
            $line_num++;
            chomp $line;
            next if $line =~ /^\s*$/ || $line =~ /^#/;
            $filter = $line;
            last;
        }
        while (defined($line = <$fh>)) {
            $line_num++;
            chomp $line;
            last if $line =~ /^\s*$/;
        }
        push @tests, {
            line    => $fail_line,
            kind    => 'fail',
            filter  => $filter,
            input   => 'null',
            outputs => [],
            section => section_for_line($fail_line),
        };
        next;
    }

    # Normal test.
    my $filter_line = $line_num;
    my $filter      = $line;
    my $input       = '';

    while (defined($line = <$fh>)) {
        $line_num++;
        chomp $line;
        next if $line =~ /^#/;
        last if $line =~ /^\s*$/;
        $input = $line;
        last;
    }

    my @outputs;
    while (defined($line = <$fh>)) {
        $line_num++;
        chomp $line;
        last if $line =~ /^\s*$/;
        next if $line =~ /^#/;
        # Normalize to compact JSON: jq's test file sometimes has spaces
        # after commas/colons but jq -c (our target format) never does.
        $line =~ s/,\s+/,/g;
        $line =~ s/:\s+/:/g;
        push @outputs, $line;
    }

    push @tests, {
        line    => $filter_line,
        kind    => 'normal',
        filter  => $filter,
        input   => $input,
        outputs => [@outputs],
        section => section_for_line($filter_line),
    };
}
close $fh;

printf "Parsed %d test cases\n", scalar @tests;

# ── Escaping helpers ──────────────────────────────────────────────────────────

sub zig_str {
    my ($s) = @_;
    my $r = '';
    for my $c (split //, $s) {
        my $o = ord($c);
        if    ($c eq '"')  { $r .= '\\"'   }
        elsif ($c eq '\\') { $r .= '\\\\'  }
        elsif ($c eq "\n") { $r .= '\\n'   }
        elsif ($c eq "\r") { $r .= '\\r'   }
        elsif ($c eq "\t") { $r .= '\\t'   }
        elsif ($o == 0x08) { $r .= '\\x08' }
        elsif ($o == 0x0C) { $r .= '\\x0c' }
        elsif ($o < 0x20)  { $r .= sprintf('\\x%02x', $o) }
        else               { $r .= $c }
    }
    return $r;
}

sub test_name {
    my ($s) = @_;
    my $r = '';
    for my $c (split //, $s) {
        my $o = ord($c);
        if ($c eq '"' || $c eq '\\') { $r .= '_' }
        elsif ($o >= 0x20 && $o < 0x7F) { $r .= $c }
        else { $r .= '_' }
    }
    $r = substr($r, 0, 57) . '...' if length($r) > 60;
    return $r;
}

# ── Group tests by section ────────────────────────────────────────────────────

my %sections;
my @section_order = map { $_->[1] } @SECTIONS;

for my $t (@tests) {
    push @{ $sections{$t->{section}} }, $t;
}

# ── helpers.zig ───────────────────────────────────────────────────────────────

my $helpers_src = <<'ZIG';
// !! GENERATED FILE — do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// Shared utilities for all compat test sections.
// Each section file does:  const h = @import("helpers.zig");

const std = @import("std");
const parser_mod = @import("parser");
const query_mod = @import("query");
const types = @import("types");

const Parser = parser_mod.Parser;
const CompiledQuery = query_mod.CompiledQuery;
const Value = types.Value;
const Tape = types.Tape;

pub const alloc = std.testing.allocator;

// ── Tape helpers ──────────────────────────────────────────────────────────────

pub fn entryToValue(tape: *const Tape, idx: u32) Value {
    const entry = tape.entries[idx];
    return switch (entry.tag) {
        .null_val     => .null_val,
        .true_val     => .{ .bool_val = true },
        .false_val    => .{ .bool_val = false },
        .int          => .{ .int    = entry.payload.int },
        .float        => .{ .float  = entry.payload.float },
        .string       => .{ .string = tape.getString(entry.payload.string) },
        .array_start  => .{ .array  = .{ .tape = tape, .start = idx, .end = entry.payload.skip } },
        .object_start => .{ .object = .{ .tape = tape, .start = idx, .end = entry.payload.skip } },
        else          => unreachable,
    };
}

pub fn skipTapeEntry(tape: *const Tape, idx: u32) u32 {
    const entry = tape.entries[idx];
    return switch (entry.tag) {
        .array_start, .object_start => entry.payload.skip,
        else => idx + 1,
    };
}

// ── Value → compact JSON ──────────────────────────────────────────────────────

pub fn serializeValue(buf: *std.ArrayList(u8), val: Value) error{OutOfMemory}!void {
    switch (val) {
        .null_val  => try buf.appendSlice(alloc, "null"),
        .bool_val  => |b| try buf.appendSlice(alloc, if (b) "true" else "false"),
        .int       => |n| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
            try buf.appendSlice(alloc, s);
        },
        .float     => |f| {
            const formatted = types.formatJqFloat(f);
            try buf.appendSlice(alloc, formatted.slice());
        },
        .string    => |s| {
            try buf.append(alloc, '"');
            try writeEscaped(buf, s);
            try buf.append(alloc, '"');
        },
        .array     => |span| {
            try buf.append(alloc, '[');
            const tape = span.tape;
            var idx = span.start + 1;
            var first = true;
            while (idx < span.end - 1) {
                if (!first) try buf.append(alloc, ',');
                first = false;
                try serializeValue(buf, entryToValue(tape, idx));
                idx = skipTapeEntry(tape, idx);
            }
            try buf.append(alloc, ']');
        },
        .object    => |span| {
            try buf.append(alloc, '{');
            const tape = span.tape;
            var idx = span.start + 1;
            var first = true;
            while (idx < span.end - 1) {
                const key_ref = tape.entries[idx].payload.string;
                const key_str = tape.getString(key_ref);
                if (!first) try buf.append(alloc, ',');
                first = false;
                try buf.append(alloc, '"');
                try writeEscaped(buf, key_str);
                try buf.appendSlice(alloc, "\":");
                idx += 1;
                try serializeValue(buf, entryToValue(tape, idx));
                idx = skipTapeEntry(tape, idx);
            }
            try buf.append(alloc, '}');
        },
    }
}

/// jq-compatible escaping: uses standard JSON escape sequences (\n, \t, \r, \b, \f)
/// for common control characters, \uXXXX for other control characters, and outputs
/// valid multi-byte UTF-8 sequences as literal bytes (matching jq's output format).
pub fn writeEscaped(buf: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const byte = s[i];
        if (byte < 0x80) {
            switch (byte) {
                '"'          => try buf.appendSlice(alloc, "\\\""),
                '\\'         => try buf.appendSlice(alloc, "\\\\"),
                '\n'         => try buf.appendSlice(alloc, "\\n"),
                '\t'         => try buf.appendSlice(alloc, "\\t"),
                '\r'         => try buf.appendSlice(alloc, "\\r"),
                0x08         => try buf.appendSlice(alloc, "\\b"),
                0x0C         => try buf.appendSlice(alloc, "\\f"),
                0x20, 0x21,
                0x23...0x5B,
                0x5D...0x7E => try buf.append(alloc, byte),
                else        => {
                    var tmp: [6]u8 = undefined;
                    const seq = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{byte}) catch unreachable;
                    try buf.appendSlice(alloc, seq);
                },
            }
            i += 1;
        } else {
            // Non-ASCII: output valid UTF-8 sequences as literal bytes (jq behavior).
            const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
                try buf.appendSlice(alloc, "\\ufffd"); i += 1; continue;
            };
            if (i + seq_len > s.len) {
                try buf.appendSlice(alloc, "\\ufffd"); i += 1; continue;
            }
            _ = std.unicode.utf8Decode(s[i..][0..seq_len]) catch {
                try buf.appendSlice(alloc, "\\ufffd"); i += seq_len; continue;
            };
            // Valid UTF-8 sequence: output as literal bytes
            try buf.appendSlice(alloc, s[i..][0..seq_len]);
            i += seq_len;
        }
    }
}

// ── Structural JSON comparison ────────────────────────────────────────────────

/// Return the numeric value of a Value as f64, or null if not numeric.
fn numericAsF64(v: Value) ?f64 {
    return switch (v) {
        .int   => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        else   => null,
    };
}

/// Count the number of key-value pairs in an object span.
fn objectLen(span: Value.TapeSpan) usize {
    var count: usize = 0;
    var idx = span.start + 1;
    while (idx < span.end - 1) {
        count += 1;
        idx += 1; // skip key
        idx = skipTapeEntry(span.tape, idx); // skip value
    }
    return count;
}

/// Find the value associated with `key` in an object span.
/// Returns the Value if found, null otherwise.
fn objectGet(span: Value.TapeSpan, key: []const u8) ?Value {
    var idx = span.start + 1;
    while (idx < span.end - 1) {
        const key_ref = span.tape.entries[idx].payload.string;
        const k = span.tape.getString(key_ref);
        idx += 1;
        const val = entryToValue(span.tape, idx);
        idx = skipTapeEntry(span.tape, idx);
        if (std.mem.eql(u8, k, key)) return val;
    }
    return null;
}

/// Deep structural equality matching jq's == semantics:
///   - null, bool: exact tag match
///   - numbers: compare as f64 (so int 2 == float 2.0)
///   - strings: byte-equal (parser has already decoded all escape sequences)
///   - arrays: element-wise recursive
///   - objects: key-order-insensitive (jq's == is unordered for objects)
fn valuesEqual(a: Value, b: Value) bool {
    // Both numeric? Compare as f64.
    if (numericAsF64(a)) |fa| {
        if (numericAsF64(b)) |fb| {
            return fa == fb;
        }
        return false; // a is numeric, b is not
    }
    if (numericAsF64(b) != null) return false; // b is numeric, a is not

    switch (a) {
        .null_val  => return b == .null_val,
        .bool_val  => |ba| return switch (b) { .bool_val => |bb| ba == bb, else => false },
        .string    => |sa| return switch (b) { .string => |sb| std.mem.eql(u8, sa, sb), else => false },
        .array     => |spa| {
            const spb = switch (b) { .array => |s| s, else => return false };
            // Compare element by element
            var ia = spa.start + 1;
            var ib = spb.start + 1;
            while (ia < spa.end - 1 and ib < spb.end - 1) {
                const va = entryToValue(spa.tape, ia);
                const vb = entryToValue(spb.tape, ib);
                if (!valuesEqual(va, vb)) return false;
                ia = skipTapeEntry(spa.tape, ia);
                ib = skipTapeEntry(spb.tape, ib);
            }
            // Both must be exhausted simultaneously
            return (ia >= spa.end - 1) and (ib >= spb.end - 1);
        },
        .object    => |spa| {
            const spb = switch (b) { .object => |s| s, else => return false };
            // Object equality is key-order-insensitive (jq behavior).
            // Check same number of keys and every key in a exists in b with equal value.
            if (objectLen(spa) != objectLen(spb)) return false;
            var ia = spa.start + 1;
            while (ia < spa.end - 1) {
                const key_ref = spa.tape.entries[ia].payload.string;
                const key = spa.tape.getString(key_ref);
                ia += 1;
                const va = entryToValue(spa.tape, ia);
                ia = skipTapeEntry(spa.tape, ia);
                const vb = objectGet(spb, key) orelse return false;
                if (!valuesEqual(va, vb)) return false;
            }
            return true;
        },
        // int and float are handled by the numeric fast-path above
        .int       => unreachable,
        .float     => unreachable,
    }
}

/// Structural JSON equality assertion.
/// Parses both `expected_json` and `actual_json` with the zq Parser,
/// then compares resulting Values structurally (jq == semantics):
///   - Numbers: compared as f64 (so 2 == 2.0 == 20e-1)
///   - Strings: compared after escape decoding (all escape sequences decoded by parser)
///   - Objects: key-order-insensitive (jq == is unordered)
///   - Arrays: ordered, element-wise recursive
pub fn expectJsonEqual(expected_json: []const u8, actual_json: []const u8) !void {
    // Parse both sides, keeping the Tape alive in this frame.
    // Value.TapeSpan.tape is a non-owning pointer into the Parser's internal
    // buffers via the Tape struct on the stack — the Tape must outlive the Value.
    var p_exp = try Parser.init(alloc);
    defer p_exp.deinit();
    const tape_exp = switch (p_exp.feed(expected_json, true) catch {
        std.debug.print("\nexpectJsonEqual: failed to parse expected JSON: {s}\n", .{expected_json});
        return error.TestExpectedEqual;
    }) {
        .done      => |d| d.tape,
        .need_more => {
            std.debug.print("\nexpectJsonEqual: expected JSON incomplete: {s}\n", .{expected_json});
            return error.TestExpectedEqual;
        },
    };
    const exp_val = entryToValue(&tape_exp, 0);

    var p_act = try Parser.init(alloc);
    defer p_act.deinit();
    const tape_act = switch (p_act.feed(actual_json, true) catch {
        std.debug.print("\nexpectJsonEqual: failed to parse actual JSON: {s}\n", .{actual_json});
        return error.TestExpectedEqual;
    }) {
        .done      => |d| d.tape,
        .need_more => {
            std.debug.print("\nexpectJsonEqual: actual JSON incomplete: {s}\n", .{actual_json});
            return error.TestExpectedEqual;
        },
    };
    const act_val = entryToValue(&tape_act, 0);

    if (!valuesEqual(exp_val, act_val)) {
        std.debug.print("\nexpectJsonEqual mismatch:\n  expected: {s}\n  actual:   {s}\n", .{ expected_json, actual_json });
        return error.TestExpectedEqual;
    }
}

// ── Core runners ──────────────────────────────────────────────────────────────

/// Parse input JSON, compile filter, execute, collect serialized results.
/// Caller owns the returned slice and each string within it.
pub fn runFilter(filter: []const u8, input_json: []const u8) ![][]const u8 {
    var p = try Parser.init(alloc);
    defer p.deinit();

    const tape = switch (try p.feed(input_json, true)) {
        .done      => |d| d.tape,
        .need_more => return error.ParseIncomplete,
    };

    const result = try CompiledQuery.compile(filter, .{}, alloc);
    var q = switch (result) {
        .ok  => |cq| cq,
        .err => return error.QuerySyntaxError,
    };
    defer q.deinit();

    var it = try q.execute(tape, &.{}, alloc);
    defer it.deinit();

    var result_list = std.ArrayList([]const u8){};
    errdefer {
        for (result_list.items) |s| alloc.free(s);
        result_list.deinit(alloc);
    }

    while (it.next() catch return error.QueryRuntimeError) |val| {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(alloc);
        try serializeValue(&buf, val);
        try result_list.append(alloc, try buf.toOwnedSlice(alloc));
    }

    return result_list.toOwnedSlice(alloc);
}

/// Verify that compiling `filter` returns a compile error (%%FAIL tests).
pub fn expectCompileError(filter: []const u8) !void {
    const result = try CompiledQuery.compile(filter, .{}, alloc);
    switch (result) {
        .ok => |cq| {
            var q = cq;
            q.deinit();
            return error.ExpectedCompileError;
        },
        .err => return,
    }
}
ZIG

# ── Emit section files ────────────────────────────────────────────────────────

my @written_stems;

for my $stem (@section_order) {
    my $sec_tests = $sections{$stem} // [];
    next unless @$sec_tests;

    my $count = scalar @$sec_tests;
    my $file  = "$out_dir/${stem}.zig";

    my $src = <<"ZIG";
// !! GENERATED FILE — do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// jq compat — $stem ($count tests)
// QuerySyntaxError → test FAILS  (filter not yet implemented — fix it)
// Any other error  → test FAILS  (real compatibility gap)

const std = \@import("std");
const h = \@import("helpers.zig");

ZIG

    for my $t (@$sec_tests) {
        my $name   = test_name($t->{filter});
        my $fl     = $t->{line};
        my $filter = zig_str($t->{filter});
        my $input  = zig_str($t->{input});
        my @outs   = @{$t->{outputs}};

        $src .= "test \"jq:L${fl} ${name}\" {\n";

        if ($t->{kind} eq 'fail') {
            $src .= "    // %%FAIL: filter should not compile\n";
            $src .= "    try h.expectCompileError(\"${filter}\");\n";
        } else {
            my $n = scalar @outs;
            $src .= "    const results = try h.runFilter(\n";
            $src .= "        \"${filter}\",\n";
            $src .= "        \"${input}\",\n";
            $src .= "    );\n";
            $src .= "    defer {\n";
            $src .= "        for (results) |s| h.alloc.free(s);\n";
            $src .= "        h.alloc.free(results);\n";
            $src .= "    }\n";
            $src .= "    try std.testing.expectEqual(\@as(usize, ${n}), results.len);\n";
            for my $i (0..$#outs) {
                my $expected = zig_str($outs[$i]);
                $src .= "    try h.expectJsonEqual(\"${expected}\", results[${i}]);\n";
            }
        }

        $src .= "}\n\n";
    }

    open my $fh_out, '>:utf8', $file or die "Cannot write $file: $!\n";
    print $fh_out $src;
    close $fh_out;

    push @written_stems, $stem;
    printf "  %-24s  %3d tests\n", "${stem}.zig", $count;
}

# ── helpers.zig ───────────────────────────────────────────────────────────────

open my $fh_h, '>:utf8', "$out_dir/helpers.zig"
    or die "Cannot write helpers.zig: $!\n";
print $fh_h $helpers_src;
close $fh_h;
print "  helpers.zig\n";

# ── root.zig ──────────────────────────────────────────────────────────────────

my $root = <<'ZIG';
// !! GENERATED FILE — do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// Root entry point: imports all section files so their tests run as one binary.

comptime {
ZIG

$root .= "    _ = \@import(\"${_}.zig\");\n" for @written_stems;
# Hand-written project-specific test sections (not generated from jq.test).
my @extra_stems = ('regex', 'repeat_builtin');
$root .= "    _ = \@import(\"${_}.zig\");\n" for @extra_stems;
$root .= "}\n";

open my $fh_r, '>:utf8', "$out_dir/root.zig"
    or die "Cannot write root.zig: $!\n";
print $fh_r $root;
close $fh_r;

printf "\n%d sections, %d total tests → %s\n",
    scalar @written_stems, scalar @tests, $out_dir;
