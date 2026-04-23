# Nix packaging

`nix build .#default` is hermetic: no network, no cargo/rustc at build time.

## Layout

Two derivations in `flake.nix`:

- `zqRegexShim` — `rustPlatform.buildRustPackage`. Vendors crates from
  `third_party/zq-regex-shim/Cargo.lock` via fixed-output derivations and
  produces `libzq_regex_shim.a`.
- `packages.default` — `stdenv.mkDerivation` running `zig build` with
  `-Dshim-archive=${zqRegexShim}/lib/libzq_regex_shim.a`. The flag skips the
  in-tree cargo invocation in `build.zig` and links the pre-built archive.

## Refreshing `Cargo.lock`

`cargoLock.lockFile` reads the committed file at eval — just
`cd third_party/zq-regex-shim && cargo update && git commit`. If a new crate's
hash is unknown, Nix prints the expected SRI hash; add it to
`cargoLock.outputHashes` and re-run.

## Refreshing `build.zig.zon`

Deferred. `build.zig.zon` is currently empty. When it gains entries, introduce
`zon2nix` or nixpkgs' `zigHook` + pre-populated `.zig-cache`.

## Cross builds

`nix build .#default` is host-only. The CI cross matrix (musl/Darwin/Windows-gnu/FreeBSD) stays on `cargo-zigbuild` in `.github/workflows/{ci,release}.yml`.

## Hermeticity guarantees

- No network: `sandbox = true` in `.github/workflows/nix.yml`; fetches flow
  through fixed-output derivations only.
- No `$HOME` reads: `HOME=$TMPDIR`, `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
- Reproducible archive: `rustPlatform.buildRustPackage` sets
  `SOURCE_DATE_EPOCH` so `ar` mtimes are deterministic; rebuilds produce the
  same store path.
