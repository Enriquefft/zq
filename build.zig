const std = @import("std");

const version = "0.2.1";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ver = b.option([]const u8, "version", "Version string") orelse version;
    const options = b.addOptions();
    options.addOption([]const u8, "version", ver);

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

    const lexer_module = b.createModule(.{
        .root_source_file = b.path("src/query/src/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    lexer_module.addImport("error", error_module);

    const ast_module = b.createModule(.{
        .root_source_file = b.path("src/ast/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_module.addImport("lexer", lexer_module);
    ast_module.addImport("error", error_module);
    ast_module.addImport("types", types_module);

    const query_module = b.createModule(.{
        .root_source_file = b.path("src/query/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    query_module.addImport("error", error_module);
    query_module.addImport("types", types_module);
    query_module.addImport("lexer", lexer_module);

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
    pool_module.addImport("output", output_module);

    const describe_module = b.createModule(.{
        .root_source_file = b.path("src/describe/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    describe_module.addImport("types", types_module);

    const c_abi_module = b.createModule(.{
        .root_source_file = b.path("src/c_abi/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_abi_module.addImport("error", error_module);
    c_abi_module.addImport("types", types_module);
    c_abi_module.addImport("query", query_module);
    c_abi_module.addImport("parser", parser_module);

    const lsp_module = b.createModule(.{
        .root_source_file = b.path("src/lsp/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_module.addImport("ast", ast_module);
    lsp_module.addImport("error", error_module);
    lsp_module.addImport("types", types_module);
    lsp_module.addImport("lexer", lexer_module);

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
    exe_mod.addImport("describe", describe_module);
    exe_mod.addImport("lsp", lsp_module);
    exe_mod.addOptions("build_options", options);

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

    const describe_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/describe_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    describe_test_mod.addImport("describe", describe_module);
    describe_test_mod.addImport("parser", parser_module);

    const describe_tests = b.addTest(.{ .root_module = describe_test_mod });
    test_step.dependOn(&b.addRunArtifact(describe_tests).step);

    const ast_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/ast_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_test_mod.addImport("ast", ast_module);

    const ast_tests = b.addTest(.{ .root_module = ast_test_mod });
    test_step.dependOn(&b.addRunArtifact(ast_tests).step);

    const lsp_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/lsp_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_test_mod.addImport("lsp", lsp_module);
    lsp_test_mod.addImport("ast", ast_module);

    const lsp_tests = b.addTest(.{ .root_module = lsp_test_mod });
    test_step.dependOn(&b.addRunArtifact(lsp_tests).step);

    // ── JSONTestSuite ──────────────────────────────────────────────────────
    const jts_options = b.addOptions();
    jts_options.addOptionPath("test_suite_dir", b.path("tests/JSONTestSuite"));

    const jts_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/json_test_suite_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    jts_test_mod.addImport("parser", parser_module);
    jts_test_mod.addOptions("build_options", jts_options);

    const jts_tests = b.addTest(.{ .root_module = jts_test_mod });
    test_step.dependOn(&b.addRunArtifact(jts_tests).step);

    // ── Fuzz steps (NOT in test_step) ────────────────────────────────────
    const fuzz_parser_step = b.step("fuzz-parser", "Fuzz the JSON parser");

    const fuzz_parser_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz_parser_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_parser_mod.addImport("parser", parser_module);

    const fuzz_parser_tests = b.addTest(.{ .root_module = fuzz_parser_mod });
    fuzz_parser_step.dependOn(&b.addRunArtifact(fuzz_parser_tests).step);

    const fuzz_query_step = b.step("fuzz-query", "Fuzz the query VM");

    const fuzz_query_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz_query_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_query_mod.addImport("parser", parser_module);
    fuzz_query_mod.addImport("query", query_module);

    const fuzz_query_tests = b.addTest(.{ .root_module = fuzz_query_mod });
    fuzz_query_step.dependOn(&b.addRunArtifact(fuzz_query_tests).step);

    const compat_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/compat/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    compat_test_mod.addImport("error", error_module);
    compat_test_mod.addImport("types", types_module);
    compat_test_mod.addImport("parser", parser_module);
    compat_test_mod.addImport("query", query_module);

    const compat_tests = b.addTest(.{ .root_module = compat_test_mod });
    test_step.dependOn(&b.addRunArtifact(compat_tests).step);

    // ── Isolated steps for faster iteration ──────────────────────────────
    const test_compat_step = b.step("test-compat", "Run jq compat tests only");
    test_compat_step.dependOn(&b.addRunArtifact(compat_tests).step);

    const query_tests2_mod = b.createModule(.{
        .root_source_file = b.path("tests/query_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    query_tests2_mod.addImport("query", query_module);
    query_tests2_mod.addImport("types", types_module);
    const query_tests2 = b.addTest(.{ .root_module = query_tests2_mod });
    const test_query_step = b.step("test-query", "Run query unit tests only");
    test_query_step.dependOn(&b.addRunArtifact(query_tests2).step);
}
