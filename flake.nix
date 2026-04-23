{
  description = "zq - a zig project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
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
            rustc
            cargo
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
