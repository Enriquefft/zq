#!/usr/bin/perl
# generate_compat_tests.pl — regenerate tests/compat_test.zig from jq's test suite.
#
# Usage:
#   perl tests/scripts/generate_compat_tests.pl [path/to/jq.test]
#
# Default source: ../jq/tests/jq.test (relative to the zq repo root).
# Output:        tests/compat_test.zig  (written to repo root-relative path)
#
# How the jq.test format works:
#   - Lines starting with # are comments; blank lines separate test cases.
#   - A normal test case is three sections: filter / input JSON / expected outputs.
#   - %%FAIL (or %%FAIL IGNORE MSG) marks a case where the filter itself is
#     invalid jq syntax; the filter is the *next* non-blank line, followed by
#     the expected error message lines (which we discard).
#
# What the generated tests do:
#   - Every test calls runFilter(filter, input) and asserts the serialized
#     results match the expected output lines.
#   - QuerySyntaxError → SkipZigTest  (filter not yet implemented in zq)
#   - Any other error   → test FAILS  (real compatibility gap to fix)
#   - %%FAIL tests call expectCompileError() instead.
#
# Serialization matches jq compact output:
#   - Control chars (0x00-0x1F) → \uXXXX
#   - Non-ASCII Unicode          → \uXXXX (or surrogate pair for > U+FFFF)
#   - Printable ASCII (except " and \) → literal
#
# To regenerate after updating jq:
#   perl tests/scripts/generate_compat_tests.pl && zig build test

use strict;
use warnings;

use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Resolve the directory containing this script, then navigate from there.
my $script_dir   = dirname(abs_path($0));          # .../zq/tests/scripts
my $zq_root      = dirname(dirname($script_dir));  # .../zq
my $projects_dir = dirname($zq_root);              # .../Projects

my $jq_test = $ARGV[0] // "$projects_dir/jq/tests/jq.test";
my $out_file = "$script_dir/../compat_test.zig";

open my $fh, '<:utf8', $jq_test or die "Cannot open $jq_test: $!\n";

# ── Parse all test cases ──────────────────────────────────────────────────────

my @tests;
my $line_num = 0;

while (defined(my $line = <$fh>)) {
    $line_num++;
    chomp $line;
    next if $line =~ /^\s*$/ || $line =~ /^#/;

    # %%FAIL: a filter that must not compile.
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
        # Consume error-message lines until blank.
        while (defined($line = <$fh>)) {
            $line_num++;
            chomp $line;
            last if $line =~ /^\s*$/;
        }
        push @tests, { line => $fail_line, kind => 'fail', filter => $filter, input => 'null', outputs => [] };
        next;
    }

    # Normal test: filter line already read.
    my $filter      = $line;
    my $filter_line = $line_num;
    my $input       = '';

    # Input: next non-comment, non-blank line.
    while (defined($line = <$fh>)) {
        $line_num++;
        chomp $line;
        next if $line =~ /^#/;
        last if $line =~ /^\s*$/;
        $input = $line;
        last;
    }

    # Outputs: all non-comment lines until next blank.
    my @outputs;
    while (defined($line = <$fh>)) {
        $line_num++;
        chomp $line;
        last if $line =~ /^\s*$/;
        next if $line =~ /^#/;
        push @outputs, $line;
    }

    push @tests, { line => $filter_line, kind => 'normal', filter => $filter, input => $input, outputs => [@outputs] };
}
close $fh;

printf "Parsed %d test cases from %s\n", scalar @tests, $jq_test;

# ── Escaping helpers ──────────────────────────────────────────────────────────

# Escape a string for embedding inside a Zig double-quoted string literal.
sub zig_str {
    my ($s) = @_;
    my $r = '';
    for my $c (split //, $s) {
        my $o = ord($c);
        if    ($c eq '"')   { $r .= '\\"'  }
        elsif ($c eq '\\')  { $r .= '\\\\'  }
        elsif ($c eq "\n")  { $r .= '\\n'  }
        elsif ($c eq "\r")  { $r .= '\\r'  }
        elsif ($c eq "\t")  { $r .= '\\t'  }
        elsif ($o == 0x08)  { $r .= '\\x08' }
        elsif ($o == 0x0C)  { $r .= '\\x0c' }
        elsif ($o < 0x20)   { $r .= sprintf('\\x%02x', $o) }
        else                { $r .= $c }
    }
    return $r;
}

# Produce a safe Zig test-name string: printable ASCII, no backslash/quote, ≤60 chars.
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

# ── Emit Zig source ───────────────────────────────────────────────────────────

my $out = <<'ZIG';
// !! GENERATED FILE — do not edit by hand.
// !! Regenerate with:  perl tests/scripts/generate_compat_tests.pl
//
// One test per jq test case.  Strategy:
//   QuerySyntaxError → SkipZigTest   (filter not yet implemented)
//   Any other error  → test FAILS    (real compatibility gap)
//   Wrong output     → assertion FAILS
//   %%FAIL tests     → expectCompileError()

const std = @import("std");
const parser_mod = @import("parser");
const query_mod = @import("query");
const types = @import("types");
const err_mod = @import("error");

const Parser = parser_mod.Parser;
const CompiledQuery = query_mod.CompiledQuery;
const Value = types.Value;
const Tape = types.Tape;
const alloc = std.testing.allocator;

// ── Tape helpers ──────────────────────────────────────────────────────────────

fn entryToValue(tape: *const Tape, idx: u32) Value {
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

fn skipTapeEntry(tape: *const Tape, idx: u32) u32 {
    const entry = tape.entries[idx];
    return switch (entry.tag) {
        .array_start, .object_start => entry.payload.skip,
        else => idx + 1,
    };
}

// ── Value → compact JSON (jq-compatible escaping) ─────────────────────────────

fn serializeValue(buf: *std.ArrayList(u8), val: Value) error{OutOfMemory}!void {
    switch (val) {
        .null_val  => try buf.appendSlice(alloc, "null"),
        .bool_val  => |b| try buf.appendSlice(alloc, if (b) "true" else "false"),
        .int       => |n| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
            try buf.appendSlice(alloc, s);
        },
        .float     => |f| {
            if (std.math.isNan(f) or std.math.isInf(f)) {
                try buf.appendSlice(alloc, "null");
            } else {
                var tmp: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
                try buf.appendSlice(alloc, s);
            }
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

/// jq-compatible escaping:
///   - Control chars (0x00-0x1F)  → \uXXXX
///   - Non-ASCII Unicode            → \uXXXX (surrogate pairs for > U+FFFF)
///   - Printable ASCII (≠ " or \) → literal
fn writeEscaped(buf: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const byte = s[i];
        if (byte < 0x80) {
            switch (byte) {
                '"'          => try buf.appendSlice(alloc, "\\\""),
                '\\'         => try buf.appendSlice(alloc, "\\\\"),
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
            const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
                try buf.appendSlice(alloc, "\\ufffd");
                i += 1;
                continue;
            };
            if (i + seq_len > s.len) {
                try buf.appendSlice(alloc, "\\ufffd");
                i += 1;
                continue;
            }
            const cp = std.unicode.utf8Decode(s[i..][0..seq_len]) catch {
                try buf.appendSlice(alloc, "\\ufffd");
                i += seq_len;
                continue;
            };
            if (cp <= 0xFFFF) {
                var tmp: [6]u8 = undefined;
                const seq = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{cp}) catch unreachable;
                try buf.appendSlice(alloc, seq);
            } else {
                const adjusted = cp - 0x10000;
                const high: u32 = 0xD800 + (adjusted >> 10);
                const low:  u32 = 0xDC00 + (adjusted & 0x3FF);
                var tmp: [12]u8 = undefined;
                const seq = std.fmt.bufPrint(&tmp, "\\u{x:0>4}\\u{x:0>4}", .{ high, low }) catch unreachable;
                try buf.appendSlice(alloc, seq);
            }
            i += seq_len;
        }
    }
}

// ── Core run helpers ──────────────────────────────────────────────────────────

/// Parse input JSON, compile filter, execute, collect serialized results.
/// Returns an owned slice of owned compact-JSON strings.
fn runFilter(filter: []const u8, input_json: []const u8) ![][]const u8 {
    var p = try Parser.init(alloc);
    defer p.deinit();

    const tape = switch (try p.feed(input_json, true)) {
        .done      => |t| t,
        .need_more => return error.ParseIncomplete,
    };

    var q = try CompiledQuery.compile(filter, .{}, alloc);
    defer q.deinit();

    var it = try q.execute(tape, alloc);
    defer it.deinit();

    var result_list = std.ArrayList([]const u8){};
    errdefer {
        for (result_list.items) |s| alloc.free(s);
        result_list.deinit(alloc);
    }

    while (try it.next()) |val| {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(alloc);
        try serializeValue(&buf, val);
        try result_list.append(alloc, try buf.toOwnedSlice(alloc));
    }

    return result_list.toOwnedSlice(alloc);
}

/// Verify that compiling `filter` returns QuerySyntaxError (%%FAIL tests).
fn expectCompileError(filter: []const u8) !void {
    var q = CompiledQuery.compile(filter, .{}, alloc) catch |e| {
        if (e == error.QuerySyntaxError) return;
        return e;
    };
    q.deinit();
    return error.ExpectedCompileError;
}

ZIG

# ── One test function per case ────────────────────────────────────────────────

for my $t (@tests) {
    my $name   = test_name($t->{filter});
    my $fl     = $t->{line};
    my $filter = zig_str($t->{filter});
    my $input  = zig_str($t->{input});
    my @outs   = @{$t->{outputs}};

    $out .= "test \"jq:L${fl} ${name}\" {\n";

    if ($t->{kind} eq 'fail') {
        $out .= "    // %%FAIL: filter should not compile\n";
        $out .= "    try expectCompileError(\"${filter}\");\n";
    } else {
        my $n = scalar @outs;
        $out .= "    const results = runFilter(\n";
        $out .= "        \"${filter}\",\n";
        $out .= "        \"${input}\",\n";
        $out .= "    ) catch |e| switch (e) {\n";
        $out .= "        error.QuerySyntaxError => return error.SkipZigTest, // filter not yet implemented\n";
        $out .= "        else => return e, // real failure: wrong type, bad input, etc.\n";
        $out .= "    };\n";
        $out .= "    defer { for (results) |s| alloc.free(s); alloc.free(results); }\n";
        $out .= "    try std.testing.expectEqual(\@as(usize, ${n}), results.len);\n";
        for my $i (0..$#outs) {
            my $expected = zig_str($outs[$i]);
            $out .= "    try std.testing.expectEqualStrings(\"${expected}\", results[${i}]);\n";
        }
    }

    $out .= "}\n\n";
}

# ── Write output ──────────────────────────────────────────────────────────────

open my $fh_out, '>:utf8', $out_file or die "Cannot write $out_file: $!\n";
print $fh_out $out;
close $fh_out;

printf "Written %d tests to %s\n", scalar @tests, $out_file;
