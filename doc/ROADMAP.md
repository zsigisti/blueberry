# Status & Roadmap

Blueberry is a self-hosted, source-built, rolling **CLI server** distribution.
This is an honest snapshot of what is solid and what is still open. Updated
2026-07-14.

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
  `obj/bpm-out` — no pacman, no Arch (proven with openssh/curl/shadow). Any
  package it can't yet build self-hosted (a makedep only Arch's base-devel
  supplied) falls back to the arch bootstrap path with a loud "self-hosting gap"
  warning, so the flip is regression-proof while gaps close one recipe at a time.
  Reaching **zero fallback** needs `make repo-build` (so every dep's `.bpm`
  exists); self-seeding gcc/glibc from a bootstrap is the deepest remaining layer.

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
- **Secure Boot.** GRUB is present but the boot chain is unsigned (no shim /
  sbsign). Open.
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
  untracked, never silently passed.

### Coverage

- **Architecture: x86_64 only.** aarch64 is not started (deliberately deferred).
- **Package freshness.** `check-updates.py` reports drift, and the whole tree was
  swept up to current upstream in July 2026 (≈50 recipes). The userland (coreutils
  family, CLI tools, soname-stable shared libraries) went via single-package
  builds; the four high-blast-radius bumps — **systemd** 256→261, **nettle** 3→4
  (+ a gnutls rebuild for the soname change), **binutils** 2.44→2.46.1, and
  **containers-common** 0→1 — went through a full base rebuild + boot test
  (systemd 261 reaches multi-user.target) + `check-base` closure check. Bumps are
  still applied by hand; recipes with unusual upstream tag schemes need an
  `[upstream]` override to be tracked, and `mpc` is pinned (its latest is 1.3.1;
  it moves with the gcc toolchain).
- **BUR end-to-end test.** The publish validator's logic is unit-tested, but the
  full authenticated publish flow can't be self-tested (2FA to the owner's email).

## Not planned

- **Desktop edition.** Removed in v0.2.0-beta. Blueberry is server-only.
