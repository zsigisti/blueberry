## Blueberry Linux — v0.9.3-beta

A self-hosting and security release. Every package now builds from our own
recipes with our own toolchain — including the toolchains themselves — and glibc
and the kernel are compiled from source on the mirror rather than pinned or
host-provided. A new CVE audit was run against the shipped set, and the four
packages carrying CRITICAL vulnerabilities are patched. The images are rebuilt
and pass the boot gate: a fresh server ISO built from the mirror boots to a root
shell on the patched glibc. On an existing system it is `bpm update && bpm
upgrade`.

### Full self-hosting restored — no Arch respin

An earlier experiment repackaged Arch binary packages as native .bpm. That is
reverted: `arch-import` is deleted and every package is built from our own recipe
by our own toolchain again. The build toolchains are no exception — rust, LLVM,
gcc, and glibc are all compiled from source, not fetched as prebuilts. rust in
particular now bootstraps from the upstream pinned stage0 (self-contained) and
links against our own libLLVM, instead of bootstrapping from the container's
system rustc, which clashed at the LLVM ABI. The build container itself is
Blueberry, not Arch: it is a Blueberry rootfs plus our toolchain, with no pacman,
regenerated from the purified package set.

### glibc and the kernel are built from source, on the mirror

glibc and the Linux kernel were previously pinned artifacts. They are now
compiled from source in our own build container and published to the mirror like
any other package. Building the kernel in-container surfaced one missing tool —
`bc`, which Kbuild uses to generate `timeconst.h` — so a dependency-light `bc`
(GavinHoward) is now a first-party package rather than an assumed host tool. The
`linux` package also installs `System.map` and the builtin-module metadata keyed
by the kernel release, so the pinned boot artifact is regenerated from exactly
the kernel we publish.

### Security: four CRITICAL CVEs patched

A new `bpm-audit` sweep queries NVD and OSV for known CVEs against the exact
versions we ship. It flagged CRITICALs in four packages, each now fixed:

- glibc: CVE-2026-5450 — a `scanf` `%mc`/`%mC` off-by-one heap overflow
  (BZ #34008). glibc 2.44 is not released yet, so the maintainer-reviewed fix is
  carried as a patch on the 2.43 branch (release 2 to 3).
- redis: CVE-2025-49844 "RediShell", a Lua use-after-free leading to remote code
  execution (CVSS 10.0). Updated 7.4.2 to 7.4.6.
- perl: CVE-2026-4176 and CVE-2026-13221. Updated 5.40.2 to 5.40.4. (CVE-2026-8376
  is 32-bit-only and does not affect the x86_64 build.)
- mariadb: CVE-2026-49261 and CVE-2026-44170. Updated 11.4.4 to 11.4.12, the
  latest 11.4 LTS point release.

All four were rebuilt self-hosted in the Blueberry container and republished
under new filenames so the immutable CDN serves them fresh.

### Mirror housekeeping

Mirror .bpm are served with a one-year immutable cache, so a rebuilt package must
always take a new filename (a bumped release) or the CDN keeps serving the old
bytes. Superseded packages left on the origin from earlier release bumps — 65
files, about 380 MB — were removed; they were already unreferenced by the signed
index, so nothing that resolves through bpm was affected.
