# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| latest `main` | Yes |

Once tagged releases begin, this table will track which versions receive security fixes.

## Reporting a vulnerability

**Do not open a public issue for security vulnerabilities.**

Instead, report them privately via [GitHub Security Advisories](https://github.com/Enriquefft/zq/security/advisories/new).

Include:

- Description of the vulnerability
- Steps to reproduce (filter, input JSON, CLI flags)
- Impact assessment (crash, memory disclosure, arbitrary code execution, etc.)
- OS, architecture, and zq version (`zq --version`)

You should receive an acknowledgment within **72 hours**. If the issue is confirmed, a fix will be developed privately and released as a patch with a coordinated disclosure.

## Scope

The following are in scope:

- **Memory safety** — out-of-bounds reads/writes, use-after-free, buffer overflows in the parser, query VM, or pool
- **Input-driven crashes** — any JSON input or filter expression that causes a segfault or undefined behavior
- **C ABI boundary** — memory corruption or UB reachable through `zq_compile`/`zq_execute`/`zq_get_result`/`zq_free`
- **Integer overflow** — arithmetic bugs in the query VM that produce silently incorrect results

The following are out of scope:

- Denial of service via intentionally large inputs (expected: bounded by available memory)
- Behavior differences from jq that are documented in [README.md](README.md#deliberate-differences-from-jq)

## Disclosure policy

- Confirmed vulnerabilities will be fixed before public disclosure.
- Credit will be given to reporters in the release notes unless they request otherwise.
- CVEs will be requested for issues with significant impact.

## Verifying release artifacts

Every release ships three layers of integrity proof:

1. **SHA-256 checksums** — `checksums-sha256.txt` lists hashes for every
   binary archive. Verify with `sha256sum -c checksums-sha256.txt`.
2. **SLSA build provenance** — every archive is attested via
   [GitHub Artifact Attestations][gh-attest] using sigstore-backed OIDC
   signatures. The attestation proves the binary was produced by
   `.github/workflows/release.yml` from a specific commit in this repo.

   ```
   gh attestation verify zq-<version>-<os>-<arch>.<ext> \
     --repo Enriquefft/zq
   ```

   This requires the [GitHub CLI][gh-cli]. No PGP keys, no trust-on-first-use.
3. **Software Bill of Materials (SBOM)** — `zq-sbom.cyclonedx.json`
   enumerates every direct and transitive dependency in CycloneDX 1.6
   format. Feed it into Grype, Trivy, or Dependency-Track to scan for
   known CVEs.

[gh-attest]: https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds
[gh-cli]: https://cli.github.com/
