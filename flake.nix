{
  description = "zq - a zig project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      fenix,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        # Rust toolchain with std prebuilt for every target zq ships.
        # fenix pulls the official rust-lang tarballs, so this is exactly
        # what `rustup target add ...` would install, just captured in nix.
        # Keep the list in sync with .github/workflows/{ci,release}.yml.
        rustToolchain = with fenix.packages.${system}; combine [
          stable.rustc
          stable.cargo
          stable.clippy
          stable.rustfmt
          # zig 0.15 resolves `-Dtarget=<arch>-linux` (no ABI) to musl, which
          # yields statically-linkable release artifacts with no glibc version
          # floor. The gnu triples are listed alongside so `-Dtarget=...-linux-gnu`
          # also works when a glibc build is explicitly requested.
          targets.x86_64-unknown-linux-musl.stable.rust-std
          targets.aarch64-unknown-linux-musl.stable.rust-std
          targets.x86_64-unknown-linux-gnu.stable.rust-std
          targets.aarch64-unknown-linux-gnu.stable.rust-std
          targets.x86_64-apple-darwin.stable.rust-std
          targets.aarch64-apple-darwin.stable.rust-std
          targets.x86_64-pc-windows-gnu.stable.rust-std
          targets.x86_64-unknown-freebsd.stable.rust-std
        ];

        zqRegexShim = pkgs.rustPlatform.buildRustPackage {
          pname = "zq-regex-shim";
          version = "0.1.0";
          src = ./third_party/zq-regex-shim;

          # Reuse the checked-in vendor tree. Dev (`cargo build --offline`) and
          # Nix both consume third_party/zq-regex-shim/vendor/, so there is one
          # SSOT: Cargo.lock generates vendor/ via `cargo vendor`; both paths
          # read the same tree. No FOD network fetch on the Nix side.
          cargoVendorDir = "vendor";

          doCheck = false;
          # staticlib consumed downstream by zig's linker — leave archive untouched.
          dontStrip = true;

          # buildRustPackage's default installPhase targets [[bin]] crates. For a
          # staticlib we install the archive explicitly. Use a glob under target/
          # because native builds may or may not place artifacts under a triple
          # subdir depending on whether CARGO_BUILD_TARGET is exported.
          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib
            archive=$(find target -type f -name libzq_regex_shim.a -path '*/release/*' | head -n1)
            if [ -z "$archive" ]; then
              echo "libzq_regex_shim.a not found under target/" >&2
              exit 1
            fi
            install -m 0644 "$archive" $out/lib/libzq_regex_shim.a
            runHook postInstall
          '';

          meta.description = "Static C ABI shim over regex-automata for zq";
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Match the package's pinned zig (see nativeBuildInputs below).
            zig_0_15
            zls
            hyperfine
            jq
            jaq
            yq
            just
            vhs
            nodejs
            rustToolchain
            # cargo-zigbuild uses `zig cc` as the cross-linker so Rust
            # cross-compiles cleanly from any host. build.zig invokes it
            # whenever -Dtarget selects a non-host triple.
            cargo-zigbuild
          ];
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "zq";
          version = "0.2.3";
          src = ./.;

          # zig's compiler_rt bundles libunwind sources and compiles them
          # on-demand when a Zig target links `-lunwind`; no external libunwind
          # is needed. Verified via empty `nm -D unwind` + a closure containing
          # only glibc/libgcc/libunistring/libidn2/zq.
          #
          # Pin zig 0.15: zig 0.16 (now `pkgs.zig` on nixpkgs-unstable) removed
          # `std.heap.GeneralPurposeAllocator` (used in src/main.zig:135,
          # src/compiler/bench.zig:61, src/microbench/main.zig:474). Bump to
          # `pkgs.zig` once the 0.16 std API migration lands.
          nativeBuildInputs = [ pkgs.zig_0_15 ];

          buildPhase = ''
            runHook preBuild
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            zig build \
              -Doptimize=ReleaseSafe \
              -Dshim-archive=${zqRegexShim}/lib/libzq_regex_shim.a \
              --prefix $out
            runHook postBuild
          '';

          # zig build --prefix $out already ran `install`; no nix install needed.
          dontInstall = true;

          meta = {
            description = "jq-compatible JSON query tool (Zig)";
            mainProgram = "zq";
            license = pkgs.lib.licenses.mit;
          };
        };
      }
    );
}
