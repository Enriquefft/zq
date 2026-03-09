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
}
