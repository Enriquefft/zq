const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Modules ───────────────────────────────────────────────────────────────
    const types_module = b.createModule(.{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const error_module = b.createModule(.{
        .root_source_file = b.path("src/error/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const io_module = b.createModule(.{
        .root_source_file = b.path("src/io/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    io_module.addImport("error", error_module);

    const parser_module = b.createModule(.{
        .root_source_file = b.path("src/parser/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_module.addImport("error", error_module);
    parser_module.addImport("types", types_module);

    const query_module = b.createModule(.{
        .root_source_file = b.path("src/query/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    query_module.addImport("error", error_module);
    query_module.addImport("types", types_module);

    const output_module = b.createModule(.{
        .root_source_file = b.path("src/output/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    output_module.addImport("error", error_module);
    output_module.addImport("types", types_module);

    const pool_module = b.createModule(.{
        .root_source_file = b.path("src/pool/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    pool_module.addImport("error", error_module);
    pool_module.addImport("types", types_module);
    pool_module.addImport("io", io_module);
    pool_module.addImport("parser", parser_module);
    pool_module.addImport("query", query_module);

    const c_abi_module = b.createModule(.{
        .root_source_file = b.path("src/c_abi/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_abi_module.addImport("error", error_module);
    c_abi_module.addImport("types", types_module);
    c_abi_module.addImport("query", query_module);
    c_abi_module.addImport("parser", parser_module);

    // ── Executable ─────────────────────────────────────────────────────────────
    const is_release = optimize != .Debug;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (is_release) true else null,
    });
    exe_mod.addImport("error", error_module);
    exe_mod.addImport("types", types_module);
    exe_mod.addImport("io", io_module);
    exe_mod.addImport("parser", parser_module);
    exe_mod.addImport("query", query_module);
    exe_mod.addImport("output", output_module);
    exe_mod.addImport("pool", pool_module);

    const exe = b.addExecutable(.{
        .name = "zq",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // ── Tests ─────────────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run all tests");

    const error_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/error_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    error_test_mod.addImport("error", error_module);

    const error_tests = b.addTest(.{ .root_module = error_test_mod });
    test_step.dependOn(&b.addRunArtifact(error_tests).step);

    const types_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/types_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    types_test_mod.addImport("types", types_module);

    const types_tests = b.addTest(.{ .root_module = types_test_mod });
    test_step.dependOn(&b.addRunArtifact(types_tests).step);

    const io_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/io_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    io_test_mod.addImport("io", io_module);

    const io_tests = b.addTest(.{ .root_module = io_test_mod });
    test_step.dependOn(&b.addRunArtifact(io_tests).step);

    const parser_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/parser_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_test_mod.addImport("parser", parser_module);
    parser_test_mod.addImport("types", types_module);

    const parser_tests = b.addTest(.{ .root_module = parser_test_mod });
    test_step.dependOn(&b.addRunArtifact(parser_tests).step);

    const query_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/query_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    query_test_mod.addImport("query", query_module);
    query_test_mod.addImport("types", types_module);

    const query_tests = b.addTest(.{ .root_module = query_test_mod });
    test_step.dependOn(&b.addRunArtifact(query_tests).step);

    const output_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/output_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    output_test_mod.addImport("output", output_module);
    output_test_mod.addImport("types", types_module);

    const output_tests = b.addTest(.{ .root_module = output_test_mod });
    test_step.dependOn(&b.addRunArtifact(output_tests).step);

    const pool_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/pool_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pool_test_mod.addImport("pool", pool_module);
    pool_test_mod.addImport("query", query_module);
    pool_test_mod.addImport("types", types_module);
    pool_test_mod.addImport("io", io_module);

    const pool_tests = b.addTest(.{ .root_module = pool_test_mod });
    test_step.dependOn(&b.addRunArtifact(pool_tests).step);

    const c_abi_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/c_abi_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_abi_test_mod.addImport("c_abi", c_abi_module);

    const c_abi_tests = b.addTest(.{ .root_module = c_abi_test_mod });
    test_step.dependOn(&b.addRunArtifact(c_abi_tests).step);

    const compat_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/compat_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    compat_test_mod.addImport("error", error_module);
    compat_test_mod.addImport("types", types_module);
    compat_test_mod.addImport("parser", parser_module);
    compat_test_mod.addImport("query", query_module);

    const compat_tests = b.addTest(.{ .root_module = compat_test_mod });
    test_step.dependOn(&b.addRunArtifact(compat_tests).step);
}
