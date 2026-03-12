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
