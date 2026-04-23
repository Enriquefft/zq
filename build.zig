const std = @import("std");

const version = "0.2.3";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ver = b.option([]const u8, "version", "Version string") orelse version;
    const regex_enabled = b.option(bool, "regex", "Enable regex builtins (requires rustc+cargo)") orelse true;
    const lsp_enabled = b.option(bool, "lsp", "Enable LSP server (--lsp flag). Disable to shrink CLI binary.") orelse true;
    // Absolute path to a pre-built libzq_regex_shim.a. When set, skip the
    // in-tree cargo invocation and link this archive directly. Used by Nix
    // packaging so `nix build` stays hermetic (no cargo/rustc at build time).
    const shim_archive_opt = b.option([]const u8, "shim-archive", "Path to prebuilt libzq_regex_shim.a (skips cargo)");
    const strip_opt = b.option(bool, "strip", "Strip symbols from release binary (default: true in release, false in debug)");
    const options = b.addOptions();
    options.addOption([]const u8, "version", ver);
    options.addOption(bool, "regex_enabled", regex_enabled);
    options.addOption(bool, "lsp_enabled", lsp_enabled);
    // One concrete options module, imported everywhere via addImport. Using
    // `addOptions(...)` on each consumer module would create *separate*
    // modules backed by the same generated source file — that collides when
    // two such modules reach the same executable compilation.
    const build_options_module = options.createModule();

    // ── Regex shim (Rust staticlib) ───────────────────────────────────────────
    // When -Dregex=true (default), invoke cargo on the vendored shim crate and
    // link the produced static archive into every Zig artifact that needs regex.
    // When -Dregex=false, skip cargo entirely — regex builtins compile to stubs
    // that return error.RegexNotCompiled at runtime.
    //
    // Cross-compile story: plain `cargo build` produces host-only archives, so
    // cross-compiling zq from Linux to macOS/Windows/FreeBSD/ARM would link a
    // Linux x86_64 archive into a foreign Mach-O/PE/ELF and fail. When the
    // requested zig target is not the host, we invoke `cargo zigbuild` — a
    // drop-in wrapper that uses `zig cc` as the cross-linker, so the Rust
    // archive matches the zig target exactly. Native-host builds still use
    // plain `cargo build` to avoid the zigbuild wrapper's startup overhead.
    const rust_triple_opt = rustTripleFromTarget(target.result);
    const is_host = target.query.isNative();
    const shim_archive_path: []const u8 = if (shim_archive_opt) |p|
        p
    else if (!is_host and rust_triple_opt != null)
        b.fmt("third_party/zq-regex-shim/target/{s}/release/libzq_regex_shim.a", .{rust_triple_opt.?})
    else
        "third_party/zq-regex-shim/target/release/libzq_regex_shim.a";
    // Absolute paths (from -Dshim-archive) bypass the source-root lookup
    // that `b.path` performs. Use `.cwd_relative` in that case; fall back
    // to `b.path` for the in-tree cargo-produced location.
    const shim_lazy: std.Build.LazyPath = if (shim_archive_opt != null)
        .{ .cwd_relative = shim_archive_path }
    else
        b.path(shim_archive_path);

    const shim_build_step: ?*std.Build.Step.Run = if (regex_enabled and shim_archive_opt == null) blk: {
        const cmd = if (!is_host) cross: {
            const triple = rust_triple_opt orelse {
                std.debug.panic(
                    "regex shim cross-compile requires a known rust triple; zig target {s}-{s}-{s} is unmapped. Either add a mapping in build.zig or pass -Dregex=false.",
                    .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag), @tagName(target.result.abi) },
                );
            };
            const c = b.addSystemCommand(&.{
                "cargo",
                "zigbuild",
                "--release",
                "--locked",
                "--offline",
                b.fmt("--target={s}", .{triple}),
            });
            break :cross c;
        } else b.addSystemCommand(&.{
            "cargo",
            "build",
            "--release",
            "--locked",
            "--offline",
        });
        // Run cargo from the shim directory so it discovers the crate's
        // `.cargo/config.toml` and its `[source.crates-io] replace-with =
        // "vendored-sources"` entry. `--manifest-path` from the repo root
        // does NOT trigger config discovery in ancestors of the manifest,
        // which breaks the offline build on CI (cargo bug/design: config
        // discovery is rooted at CWD, not at the manifest path).
        cmd.setCwd(b.path("third_party/zq-regex-shim"));
        break :blk cmd;
    } else null;

    const regex_module = b.createModule(.{
        .root_source_file = b.path("src/regex/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    regex_module.addImport("build_options", build_options_module);
    if (regex_enabled) {
        regex_module.addObjectFile(shim_lazy);
        regex_module.link_libc = true;
        // Rust panic=unwind requires libunwind symbols; Zig ships one in its
        // sysroot so `-lunwind` resolves without extra system dependencies.
        regex_module.linkSystemLibrary("unwind", .{});
    }

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
    query_module.addImport("regex", regex_module);
    // Prefilter harvest walks the AST from src/ast/. Single source of truth:
    // the same parser the LSP uses — no second source-byte scanner.
    query_module.addImport("ast", ast_module);
    // The regex module already carries the shim as an object file and links
    // libc/libunwind. The query module picks those up transitively via
    // `addImport`, so no extra link options are needed here. Avoid adding
    // a second `build_options` module here — regex already exposes it, and
    // duplicating the options here triggers "file exists in two modules".

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
    // The LSP surfaces compile errors (including regex compile errors) by
    // invoking the real compiler. Import the query module so diagnostics
    // reflect production behaviour — single source of truth.
    lsp_module.addImport("query", query_module);
    lsp_module.addImport("build_options", build_options_module);

    // ── Executable ─────────────────────────────────────────────────────────────
    const is_release = optimize != .Debug;
    const strip = strip_opt orelse is_release;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
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
    exe_mod.addImport("regex", regex_module);
    exe_mod.addImport("build_options", build_options_module);

    const exe = b.addExecutable(.{
        .name = "zq",
        .root_module = exe_mod,
    });
    if (shim_build_step) |step| exe.step.dependOn(&step.step);
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
    query_test_mod.addImport("regex", regex_module);
    query_test_mod.addImport("error", error_module);
    query_test_mod.addImport("build_options", build_options_module);

    const query_tests = b.addTest(.{ .root_module = query_test_mod });
    if (shim_build_step) |step| query_tests.step.dependOn(&step.step);
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
    pool_test_mod.addImport("regex", regex_module);

    const pool_tests = b.addTest(.{ .root_module = pool_test_mod });
    if (shim_build_step) |step| pool_tests.step.dependOn(&step.step);
    test_step.dependOn(&b.addRunArtifact(pool_tests).step);

    const c_abi_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/c_abi_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_abi_test_mod.addImport("c_abi", c_abi_module);

    const c_abi_tests = b.addTest(.{ .root_module = c_abi_test_mod });
    // c_abi imports query which imports regex; the test binary links the shim
    // archive transitively, so the test compile must wait for cargo.
    if (shim_build_step) |step| c_abi_tests.step.dependOn(&step.step);
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

    if (lsp_enabled) {
        const lsp_test_mod = b.createModule(.{
            .root_source_file = b.path("tests/lsp_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        lsp_test_mod.addImport("lsp", lsp_module);
        lsp_test_mod.addImport("ast", ast_module);

        const lsp_tests = b.addTest(.{ .root_module = lsp_test_mod });
        if (shim_build_step) |step| lsp_tests.step.dependOn(&step.step);
        test_step.dependOn(&b.addRunArtifact(lsp_tests).step);
    }

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
    if (shim_build_step) |step| fuzz_query_tests.step.dependOn(&step.step);
    fuzz_query_step.dependOn(&b.addRunArtifact(fuzz_query_tests).step);

    // ── Regex fuzz (NOT in test_step) ─────────────────────────────────────
    // Differential harness against jq. Not in default test step because it
    // shells out to an external binary on every iteration; run with
    //   `zig build fuzz-regex` (optionally `ZQ_FUZZ_ITERS=5000`).
    const fuzz_regex_step = b.step("fuzz-regex", "Fuzz the regex engine against jq");
    const fuzz_regex_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz_regex.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_regex_mod.addImport("regex", regex_module);
    fuzz_regex_mod.addImport("query", query_module);
    fuzz_regex_mod.addImport("pool", pool_module);
    fuzz_regex_mod.addImport("types", types_module);
    fuzz_regex_mod.addImport("io", io_module);
    const fuzz_regex_tests = b.addTest(.{ .root_module = fuzz_regex_mod });
    if (shim_build_step) |step| fuzz_regex_tests.step.dependOn(&step.step);
    fuzz_regex_step.dependOn(&b.addRunArtifact(fuzz_regex_tests).step);

    // ── Regex bench (NOT in test_step) ────────────────────────────────────
    // Latency probe. Prints median/p99 per pattern class to stderr. Not part
    // of the default test step to keep CI runs fast. Invoke with
    //   `zig build bench-regex` — in release mode for meaningful numbers.
    const bench_regex_step = b.step("bench-regex", "Regex latency probe");
    const bench_regex_mod = b.createModule(.{
        .root_source_file = b.path("tests/regex_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_regex_mod.addImport("regex", regex_module);
    bench_regex_mod.addImport("parser", parser_module);
    bench_regex_mod.addImport("query", query_module);
    const bench_regex_tests = b.addTest(.{ .root_module = bench_regex_mod });
    if (shim_build_step) |step| bench_regex_tests.step.dependOn(&step.step);
    bench_regex_step.dependOn(&b.addRunArtifact(bench_regex_tests).step);

    const compat_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/compat/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    compat_test_mod.addImport("error", error_module);
    compat_test_mod.addImport("types", types_module);
    compat_test_mod.addImport("parser", parser_module);
    compat_test_mod.addImport("query", query_module);
    compat_test_mod.addImport("regex", regex_module);

    const compat_tests = b.addTest(.{ .root_module = compat_test_mod });
    if (shim_build_step) |step| compat_tests.step.dependOn(&step.step);
    test_step.dependOn(&b.addRunArtifact(compat_tests).step);

    // ── Regex tests ───────────────────────────────────────────────────────────
    // root.zig's test block reffs cache.zig so all regex tests run from here.
    const regex_test_mod = b.createModule(.{
        .root_source_file = b.path("src/regex/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    regex_test_mod.addImport("build_options", build_options_module);
    if (regex_enabled) {
        regex_test_mod.addObjectFile(shim_lazy);
        regex_test_mod.link_libc = true;
        regex_test_mod.linkSystemLibrary("unwind", .{});
    }

    const regex_tests = b.addTest(.{ .root_module = regex_test_mod });
    if (shim_build_step) |step| regex_tests.step.dependOn(&step.step);
    test_step.dependOn(&b.addRunArtifact(regex_tests).step);
}

/// Map a zig target to the rust target triple the Cargo crate is built against.
///
/// Only the triples in our CI/release matrix are mapped — anything else returns
/// null and the shim build panics with a clear message rather than silently
/// linking the wrong archive. Keep this table in sync with:
///   - `.github/workflows/ci.yml` cross-compile matrix
///   - `.github/workflows/release.yml` build matrix
///   - `flake.nix` fenix `targets.*` entries
///
/// Windows uses the `-gnu` ABI because cargo-zigbuild drives `zig cc` which
/// targets mingw-w64, not MSVC. Linux picks musl vs gnu based on zig's ABI
/// resolution: bare `-Dtarget=x86_64-linux` resolves to musl (static, no
/// glibc floor — preferred for release tarballs) while explicit `-linux-gnu`
/// uses the glibc triple.
fn rustTripleFromTarget(t: std.Target) ?[]const u8 {
    const arch = t.cpu.arch;
    return switch (t.os.tag) {
        // Linux: follow zig's ABI choice. When `-Dtarget=x86_64-linux` is
        // passed without an explicit ABI, zig 0.15 resolves it to musl, which
        // gives statically-linkable artifacts with no glibc version
        // dependency — ideal for release tarballs. Respect an explicit `.gnu`
        // if the caller asked for glibc.
        .linux => switch (t.abi) {
            .gnu, .gnueabi, .gnueabihf, .gnuabin32, .gnuabi64, .gnux32 => switch (arch) {
                .x86_64 => "x86_64-unknown-linux-gnu",
                .aarch64 => "aarch64-unknown-linux-gnu",
                else => null,
            },
            else => switch (arch) {
                .x86_64 => "x86_64-unknown-linux-musl",
                .aarch64 => "aarch64-unknown-linux-musl",
                else => null,
            },
        },
        .macos => switch (arch) {
            .x86_64 => "x86_64-apple-darwin",
            .aarch64 => "aarch64-apple-darwin",
            else => null,
        },
        .windows => switch (arch) {
            .x86_64 => "x86_64-pc-windows-gnu",
            else => null,
        },
        .freebsd => switch (arch) {
            .x86_64 => "x86_64-unknown-freebsd",
            else => null,
        },
        else => null,
    };
}
