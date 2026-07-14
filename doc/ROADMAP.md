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
  tamper test, and an advisory package-freshness report, on every push.

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

### Coverage

- **Architecture: x86_64 only.** aarch64 is not started (deliberately deferred).
- **Package freshness.** `check-updates.py` reports drift, and the userland was
  swept up to current upstream in July 2026 (≈45 recipes: the coreutils family,
  the CLI tools, and the soname-stable shared libraries). Four bumps are held
  back on purpose because each needs a full `make world` + boot/stack test, not
  a single-package build: **systemd** (256→261, five majors), **binutils**
  (toolchain — bump with gcc/glibc/gmp/mpfr/mpc as a set), **nettle** (3→4, a
  libnettle soname break that also needs gnutls rebuilt), and
  **containers-common** (0→1, verify against podman). Bumps are still applied by
  hand; recipes with unusual upstream tag schemes need an `[upstream]` override
  to be tracked.
- **BUR end-to-end test.** The publish validator's logic is unit-tested, but the
  full authenticated publish flow can't be self-tested (2FA to the owner's email).

## Not planned

- **Desktop edition.** Removed in v0.2.0-beta. Blueberry is server-only.
