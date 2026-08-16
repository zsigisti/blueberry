# Status & Roadmap

Blueberry is a self-hosted, source-built, rolling **CLI server** distribution.
This is an honest snapshot of what is solid and what is still open. Updated
2026-08-16.

## Solid today

- **Bootable systemd server** — a live CLI ISO (systemd PID 1: journald, logind,
  networkd) that reaches `multi-user.target`, plus a busybox rescue ISO. Both
  boot-verified in the release gate.
- **~190-package userland** — toolchain (gcc/binutils/make), networking
  (iproute2/nftables/wireguard/openssh), storage (btrfs/lvm/mdadm/cryptsetup/
  xfs/e2fsprogs), databases (mariadb/postgresql/redis), containers (podman/crun/
  netavark/conmon), web (nginx), monitoring (node_exporter/sysstat), and the
  usual CLI staples. `check-closure` keeps the dependency graph closed.
- **bpm** — the native package manager (Rust): streaming installs, ed25519-signed
  repo index with replay protection, `install`/`upgrade`/`remove`/`downgrade`/
  `rollback`/`outdated`/`autoremove`, config-file (backup) preservation, self-
  tracked. Unit + end-to-end lifecycle tests in CI.
- **`.bpm` format + bpmbuild** — reproducible zstd-tar packages with a TOML
  manifest; `bpmbuild` builds from a recipe and `bpmbuild --check` verifies a
  package against its own manifest.
- **Installer** — Rust TUI/CLI/unattended, plus install-from-the-browser via the
  web console. `test-install` boots an unattended install to a disk image.
- **Blueberry Console (bbconsole)** — first-party web UI (Rust, HTTPS): services,
  packages, logs, storage (btrfs/zfs), network, snapshot→upgrade, and install.
- **BUR** — the AUR-like community recipe site + `bur` client (search/build/
  submit/publish/install/upgrade). Publishing verifies the uploaded `.bpm`
  against the approved recipe *and* against the manifest inside it (see below).
- **Mirror + release infra** — signed repo, keep-last-3 pruning, ISOs attached
  directly to GitHub releases (never the mirror).
- **CI** — `check-closure`, bpm unit + integration tests, `bpmbuild --check`
  tamper test, and advisory package-freshness + CVE-audit reports, on every push;
  a weekly `auto-bump` job opens per-package update PRs.
- **Functional tests** — `make test-services` starts each server service
  (redis/nginx/postgresql/…) and probes it (PING, HTTP GET, SQL SELECT), so
  "it installed" is backed by "it runs". Complements the boot + install tests.
- **Self-hosted build path (default)** — the whole build toolchain (gcc, binutils,
  make, autotools, meson/ninja, cmake, go, **rust 1.97**, **LLVM 22 + clang**,
  the Python build modules, …) is packaged in the tree: every recipe's
  makedependencies resolve to a Blueberry package or a provided host name — zero
  Arch tools. `tools/build/mk-blueberry-builder.sh` bakes a Blueberry build
  container (base rootfs + toolchain + dev headers), published at
  `ghcr.io/zsigisti/blueberry-builder:latest`. `build-bpm-pkg.sh` now **defaults**
  to building in it: each package's build closure (`makedep-closure.py`,
  provides-aware) is installed by extracting the already-built `.bpm` from
  `obj/bpm-out` — no pacman, no Arch. As of v0.9.3-beta the toolchains are no
  exception: gcc, glibc, LLVM and rust are all compiled from our recipes (rust
  bootstraps from the upstream pinned stage0 and links our libLLVM), and glibc
  and the kernel are built from source in that container and published to the
  mirror like any other package rather than being host-copied or pinned
  artifacts. The arch bootstrap path survives only as the `BASE=auto` safety
  net: if a makedep can't be satisfied self-hosted it falls back with a loud
  "self-hosting gap" warning. `BASE=blueberry` fails instead of falling back,
  which is what the release builds use.

## Open / decided

### Trust chain

- **BUR publish provenance — by-decision scope.** Publishing does not rebuild
  from source on the server. It unpacks the `.bpm` and checks it against (a) the
  approved recipe — identity, deps, provides, backup, install scripts, payload
  paths — and (b) the manifest inside it — `payload_sha256` + `installed_size`.
  This proves the artifact matches its recipe and is internally consistent, not
  that it was compiled from that recipe. A full server-side rebuild is explicitly
  **out of scope** for now.
- **repo1 tunnel routing.** The community repo is still served through the
  `bur.blueberrylinux.org` tunnel as a workaround; a dedicated
  `repo1.blueberrylinux.org` route is not wired up. (Its `bpm.index` is 0-byte
  only because nothing is published yet — not a bug.)
- **Secure Boot — own keys (done).** Blueberry signs its own boot chain with a
  Blueberry key set you enroll once (no Microsoft-signed shim — that is a
  months-long external process, out of scope). `blueberry-secureboot` does
  keygen / enroll-artifacts / sign-boot / verify; `sbsigntools` + `gnu-efi` are
  packaged. `mkdisk` signs opt-in via `SECUREBOOT_KEYDIR`: GRUB is built with an
  embedded GPG key + `--disable-shim-lock`, GRUB **and** the kernel are sbsigned
  (db), and the kernel + initramfs are GPG-signed. Chain: firmware —(db)→ GRUB
  —(db + gpg check_signatures)→ kernel → initramfs. `make test-secureboot` proves
  it under QEMU+OVMF (signed boots, unsigned is rejected). See
  [doc/SECUREBOOT.md](SECUREBOOT.md). A signed shim, if ever added, slots in front
  of GRUB without changing the rest.
- **Boot-level rollback — `blueberry-snapshot` (done).** On btrfs installs the
  layout now includes `@snapshots`; `bpm upgrade` takes a writable pre-upgrade
  snapshot and `blueberry-snapshot grub` adds a grub-btrfs-style boot entry per
  snapshot (each self-contained: its own `/boot` kernel + `rootflags=subvol=@snapshots/…`).
  If an upgrade won't boot, pick the snapshot in GRUB and run
  `blueberry-snapshot rollback <name>` to swap `@`. Package-level `bpm rollback`
  still handles the single-package case.
- **CVE awareness — `bpm audit` (done).** `bpm audit` reports known CVEs against
  the installed versions (NVD for C/system software, OSV for Go/Rust), with an
  advisory CI job (`bpm-audit.py --recipes`) auditing what the tree ships. It is
  triage, not gospel: NVD's CPE data over-reports, so the tool drops open-ended
  ranges (a match is kept only when the CVE records a fix version or names the
  exact version). Not every package is mapped yet — unmapped ones are reported as
  untracked, never silently passed. The last sweep (2026-07-31, shipped in
  v0.9.3-beta) found CRITICALs in four packages — glibc (CVE-2026-5450, carried
  as a patch on the 2.43 branch), redis "RediShell", perl, mariadb — all patched
  and republished.

### Coverage

- **Architecture: x86_64 only.** aarch64 is not started (deliberately deferred).
- **Package freshness.** `check-updates.py` reports drift, and the whole tree was
  swept up to current upstream in July 2026 (≈50 recipes). The userland (coreutils
  family, CLI tools, soname-stable shared libraries) went via single-package
  builds; the four high-blast-radius bumps — **systemd** 256→261, **nettle** 3→4
  (+ a gnutls rebuild for the soname change), **binutils** 2.44→2.46.1, and
  **containers-common** 0→1 — went through a full base rebuild + boot test
  (systemd 261 reaches multi-user.target) + `check-base` closure check.

  The report itself covered only 97 of 225 recipes until 2026-08-16: 114 had no
  detectable upstream and 11 tag schemes failed to parse, so openssl, curl,
  openssh, sudo, perl, redis, mariadb, nginx and postgresql were silently
  untracked. It now covers **every** recipe — 0 unknown, 0 errors — via four
  auto-detected providers (directory listing, sourceforge, pypi, plus the
  existing github/gitlab/gnu) and 43 explicit `[upstream]` tables. Packages held
  on a series on purpose declare it (`track = "6.18"` for linux, `11.4` mariadb,
  `17` postgresql, `3.14` python); `mpc` stays pinned (latest is 1.3.1; it moves
  with the gcc toolchain).

  **Bumps are still applied by hand.** ~97 recipes are currently behind upstream
  and the weekly `auto-bump` queue is capped at 12 open PRs, so the backlog
  drains at review speed, not upstream's release speed. That queue is the honest
  bottleneck: freshness is now *measured* everywhere, not *maintained*
  everywhere.
- **BUR end-to-end test.** The publish validator's logic is unit-tested, but the
  full authenticated publish flow can't be self-tested (2FA to the owner's email).

## Not planned

- **Desktop edition.** Removed in v0.2.0-beta. Blueberry is server-only.
