# Nix packaging

`nix build .#default` is hermetic: no network, no cargo/rustc at build time.

## Layout

Two derivations in `flake.nix`:

- `zqRegexShim` — `rustPlatform.buildRustPackage` pointing at the checked-in
  vendor tree via `cargoVendorDir = "vendor"`. Dev (`cargo build --offline`
  driven by `build.zig`) and Nix both consume the same
  `third_party/zq-regex-shim/vendor/`. Single source of truth: `Cargo.lock`
  generates that tree via `cargo vendor`.
- `packages.default` — `stdenv.mkDerivation` running `zig build` with
  `-Dshim-archive=${zqRegexShim}/lib/libzq_regex_shim.a`. The flag skips the
  in-tree cargo invocation in `build.zig` and links the pre-built archive.

## Refreshing `Cargo.lock`

```
cd third_party/zq-regex-shim
cargo update
cargo vendor            # regenerates vendor/ from the new lockfile
git add Cargo.lock vendor/
git commit
```

Nix reads `vendor/` directly — no SRI hashes to update, no FOD fetch. If
`vendor/` drifts from `Cargo.lock`, BOTH dev and Nix break in the same way
(no silent divergence).

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
