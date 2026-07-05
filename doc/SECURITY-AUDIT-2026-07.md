# Security / Version Audit — 2026-07-05

Point-in-time audit of the shipped package set (`packages/*/bpm.toml`) against
current upstream releases. Focus: network-facing daemons, the crypto/TLS stack,
and parsers — the components where a stale version means real, known-CVE
exposure. Versions were checked against upstream release pages / endoflife.date.

**Headline:** the base userland was largely assembled around late-2024 / early-2025
and has since drifted roughly 1–1.5 years behind upstream. Several
security-critical components carry known-CVE exposure. Kernel is being bumped to
7.1.3 separately (tracked); this audit covers userland.

## Outdated — action recommended (worst first)

| Package | Shipped | Latest | Why it matters |
|---|---|---|---|
| **curl** | 8.11.1 | 8.21.0 (2026-06-24) | ~35 CVEs fixed since 8.11.1. Network client used across the system. **Critical.** |
| **openssh** | 9.9p2 | 10.3p1 (2026-04-02) | SSH daemon, directly network-facing. Major bump — recipe may need review. **Critical.** |
| **openssl** | 3.4.0 | 3.4.6 (2026-06-09) | Crypto core; six security/bugfix point releases behind. (3.5.x LTS also available.) **Critical.** |
| **expat** | 2.6.4 | 2.8.2 (2026-06-25) | XML parser; 13 vulns fixed since, incl. CVE-2026-45186. Pulled in transitively. **High.** |
| **sudo** | 1.9.16p2 | 1.9.17p2 (2025-07-26) | Predates the mid-2025 chroot local-priv-esc fixes (CVE-2025-32462 / -32463). **High (LPE).** |
| **xz** | 5.6.3 | 5.8.3 (2026-03-31) | liblzma; CVE-2026-34743 affects all ≥5.0.0. (5.6.3 is already post-backdoor.) **High.** |
| **gnutls** | 3.8.8 | 3.8.13 (2026-04-29) | Alternate TLS library; several security releases behind. **Medium/High.** |
| **nginx** | 1.26.3 | 1.31.2 (2026-06-17) | Web server; 1.26 branch is EOL (2025-04-23). Major bump. **Medium/High.** |
| **postgresql** | 17.2 | 17.10 (2026-05-11) | DB server; eight security/patch releases behind on the 17 line. **Medium.** |
| **gnupg** | 2.4.7 | 2.5.21 (2026-07-02) | 2.4 branch reached EOL 2026-06-30; move to 2.5 LTS. Major bump. **Medium.** |
| **sqlite** | 3.49.1 | 3.53.3 (2026-06-26) | Embedded DB; many releases behind. **Medium.** |
| **git** | 2.49.0 | 2.55.0 (2026-06-29) | Historically CVE-prone (clone/submodule paths). **Medium.** |
| **redis** | 7.4.2 | 7.4.9 (2026-05-05) | Stay on the 7.4 line (7.4.9); 8.x is a major bump. **Low/Medium.** |

## Current — no action

- **python** 3.14.6 — current (supported until 2027).
- **glibc** 2.43 — current (Feb-2026 release; next is ~2.44 in Aug).
- **libxml2** 2.15.3 — current (2026-04-15).
- **wget** 1.25.0 — current (latest 1.x).
- **mariadb** 11.4.4 — recent LTS (just built).

## Not verified this pass — recommend checking

krb5 1.22.2, libgcrypt 1.11.0, nettle 3.10, p11-kit 0.25.5, libtasn1 4.19.0,
nss 3.108 / nspr 4.36, pcre2 10.47, zlib 1.3.1, zstd 1.5.6, systemd 256.7,
dbus 1.16.0, polkit 126, wpa_supplicant 2.11, ncurses 6.5, readline 8.2.
(Most are slow-moving; zlib/zstd/pcre2 are likely current.)

## Suggested remediation order

1. **Transport & remote access:** curl, openssh, openssl — highest blast radius, network-facing.
2. **Local priv-esc:** sudo (chroot CVEs).
3. **Parsers pulled in everywhere:** expat, xz, sqlite.
4. **TLS / services:** gnutls, nginx, postgresql, gnupg.
5. **Tooling:** git, redis.

Bumps 1–3 are point releases (low-risk recipe edits: version + sha256 + rebuild).
openssh 10.x, nginx 1.31, gnupg 2.5 are major-branch moves and want a recipe
review before rebuilding.

## Delivery mechanism (in place as of 2026-07-05)

The whole base userland is now bpm-tracked: `make install` records every base
package (and glibc, and the `linux` kernel) in the image's bpm database, so
`bpm upgrade` maintains the entire system — see [BPM.md](BPM.md) and
[KERNEL.md §10](KERNEL.md). So the remediation for each row above is:

1. bump the recipe (`version` + `sha256`, and `release` if same version),
2. rebuild the `.bpm` and publish + re-index it on the mirror,

and every installed system picks it up on its next `bpm upgrade` — no reinstall.
The version bumps themselves are still pending.
