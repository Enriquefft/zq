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
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            zig
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
          version = "0.1.0-dev";
          src = ./.;

          nativeBuildInputs = with pkgs; [ zig ];

          buildPhase = ''
            export HOME=$TMPDIR
            zig build -Doptimize=ReleaseSafe
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp zig-out/bin/zq $out/bin/
          '';
        };
      }
    );
}
