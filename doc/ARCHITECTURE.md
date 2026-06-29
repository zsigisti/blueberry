# Blueberry Linux — Architecture

## 1. Overview

Blueberry Linux is a **self-hosted, build-from-source distribution** produced
from a single monorepo. One source tree builds two editions that share a base —
a pinned prebuilt kernel, the host-provided glibc runtime, the `bpm` package
manager, and the build system:

- **Server** — a minimal, **rolling** CLI system. systemd PID 1 (runit optional),
  headless, always the latest tested userspace.
- **Desktop** — KDE Plasma 6 with **Ubuntu-style stable releases** and a live
  Calamares installer ([`editions/desktop/`](../editions/desktop)).

Two things make the base: `make world` assembles the bootable base image
(kernel + initramfs + a systemd or runit rootfs), and the **package set** in
[`packages/`](../packages) (~390 recipes) is built from source into one
ed25519-signed mirror at `https://repo.mmzsigmond.me/`, installed by `bpm`.
There is **no third-party binary mirror** at runtime.

```
┌──────────────────────────────────────────────────────────────────────┐
│                     Blueberry Linux Source Tree                        │
│                                                                        │
│  GNUmakefile ─ top-level BSD-style build orchestrator                  │
│  Make.config ─ tunable build variables (arch, jobs, versions)          │
│                                                                        │
│  src/kernel/      pinned prebuilt Linux 7.0 (fetch+verify; build opt-in)│
│  src/busybox/     busybox 1.36.x → /bin/busybox (live-CLI userland)     │
│  src/init/        runit stage scripts (INIT=runit path)                 │
│  src/systemd/     systemd integration: units, networkd, sshd (default)  │
│  src/initramfs/   live-CLI /init + selftest + live-desktop overlay      │
│  src/dropbear/    tiny SSH server/client (runit path)                   │
│  src/bpm-rs/      the bpm package manager (Rust)                        │
│  src/installer/   blueberry-install (guided CLI installer)              │
│                                                                        │
│  packages/<name>/bpm.toml  ~390 from-source recipes → .bpm             │
│  editions/desktop/         KDE/GNOME spin: package lists, Calamares     │
│  tools/                    bundle-glibc.sh, build-bpm-pkg.sh,           │
│                            bpmrepo.sh, stage-desktop.sh, check-*.py     │
│  etc/                      /etc skeleton overlaid onto the rootfs       │
│  doc/                      this documentation                          │
└──────────────────────────────────────────────────────────────────────┘
```

## 2. Two build pipelines

Blueberry has two distinct pipelines that meet at the rootfs:

**A. The base image (`make world` / `make install`)** — the BSD-style part.
The kernel, glibc runtime, busybox, and init are assembled from the source tree:

```
make world
  ├─ fetch       linux (pinned prebuilt), busybox, runit, dropbear
  ├─ busybox     gcc (dynamic glibc) → rootfs/bin/busybox
  ├─ runit       gcc → rootfs/sbin/runit*           (INIT=runit only)
  ├─ dropbear    gcc → rootfs/usr/sbin/dropbearmulti (INIT=runit only)
  ├─ kernel      fetch+verify pinned vmlinuz + modules (no compile)
  └─ initramfs   bundle-glibc.sh + pack busybox + /init → initramfs.cpio.zst

make install   stage the base packages (systemd, util-linux, coreutils, …)
               as .bpm and extract them into the rootfs (DESTDIR)
```

**B. The package set (`make repo-build` / `build-bpm-pkg.sh`)** — the
distribution part. Every `packages/<name>/bpm.toml` is built from upstream
source in an ephemeral Arch **build** container (the build toolchain only — no
Arch binaries ship), producing a native `.bpm`:

```
packages/<name>/bpm.toml
        │  tools/build-bpm-pkg.sh  (ephemeral container → tools/bpmbuild)
        ▼
   name-ver-rel-arch.bpm  ──scp──►  mirror  ──tools/bpmrepo.sh──►  bpm.index (+ .sig)
                                                                        │  HTTPS + TLS
                                                                        ▼
                                                bpm install  (ed25519 index + per-pkg SHA-256)
```

The Desktop edition layers its graphical closure (`editions/desktop/packages/*.list`)
onto a clone of the base rootfs via `tools/stage-desktop.sh`, then squashes it
into the live ISO.

## 3. Design Decisions

### 3.1  glibc for binary compatibility

The userland builds dynamically against **glibc** so prebuilt, glibc-only
software (proprietary binaries, language runtimes, GPU/driver userspace) runs
without a shim. The glibc runtime — the loader `/lib64/ld-linux-x86-64.so.2`,
the shared libs, the dlopen-only NSS modules, `ld.so.cache` — is staged at the
standard ABI paths by `tools/bundle-glibc.sh`. No libc is built from source; the
build links against the host glibc and bundles that runtime. Trade-off vs musl:
a few MB larger and tied to the host glibc version, in exchange for drop-in
compatibility with the glibc ecosystem.

### 3.2  busybox for the base utilities

busybox combines 300+ utilities into one auditable binary. Its applet config
(`src/busybox/config`) provides the entire **live-CLI** userland: shell,
coreutils, `mdev`, `switch_root`, networking tools, an editor. On an *installed*
system the full GNU coreutils/util-linux from `packages/` take over.

### 3.3  systemd by default, runit optional

The installed disk system runs **systemd** as PID 1 by default (`INIT=systemd`):
journald, logind (the seats/sessions the GUI needs), networkd/resolved/
timesyncd, and OpenSSH. The integration layer is in `src/systemd/`. A minimal
**runit** scheme (`INIT=runit`) remains for RAM-first / embedded builds — three
shell stages and `runsvdir`, with Dropbear for SSH. The live initramfs is
busybox-based either way; only the installed rootfs changes. See
[INIT.md](INIT.md).

### 3.4  Single source tree (BSD-style base)

The *base* (kernel config, glibc bundling, busybox, init) is versioned together,
so `git clone` gives everything needed to build a bootable base, and CI can
verify it on every commit. Upstream base bumps are deliberate, reviewable
commits. The *package set* extends this with per-package recipes.

### 3.5  A self-hosted package manager (`bpm`)

Beyond the base image, software is packaged and installed by **`bpm`** — a small
Rust program ([`src/bpm-rs/`](../src/bpm-rs)) that installs native `.bpm`
archives from Blueberry's own signed mirror. Every package is a from-source
recipe in `packages/`; the `bpm.index` is ed25519-signed and verified against a
key compiled into `bpm`, and each package is SHA-256-checked before install.
This keeps the supply chain end-to-end controlled — pinned source → reproducible
container build (fixed `SOURCE_DATE_EPOCH`) → signed mirror → verified install —
with no dependency on any other distro's mirror at runtime. See
[BPM.md](BPM.md), [BPM-FORMAT.md](BPM-FORMAT.md).

### 3.6  A closed dependency graph (enforced)

Because every runtime dependency must itself be a package in the repo, the set
has to stay **self-contained**: no recipe may declare a dependency that nothing
provides, and no staged binary may need a shared library that was never built.
Two gates enforce this (see §7).

## 4. Boot Sequence

### Live CLI (`make run` / Server ISO)

```
1. firmware/QEMU loads vmlinuz + initramfs.cpio.zst
2. kernel decompresses the initramfs, runs /init (PID 1)
3. src/initramfs/init:
     a. mount /proc /sys /dev /run, populate /dev (mdev)
     b. parse the kernel cmdline
     c. bbtest      → run /etc/selftest, print BLUEBERRY_TEST=PASS|FAIL, halt
        bbinstall   → unattended blueberry-install, halt
        root=<dev>  → mount disk → switch_root → /sbin/init (systemd | runit)
        otherwise   → exec an interactive login shell (runs from RAM)
```

### Live Desktop (`blueberry.live=1`, Desktop ISO)

```
3. src/initramfs/init:
     a. find the boot medium (root=live:CDLABEL=…)
     b. mount the squashfs read-only as an overlay lower layer
     c. stack a tmpfs upper layer (writable, disposable)
     d. switch_root into systemd → SDDM autologin → KDE Plasma (Wayland)
```

### Installed disk system

```
firmware → GRUB → pinned vmlinuz → initramfs (root=UUID=…) → switch_root
  └─ systemd (default): journald, logind, networkd/resolved, multi-user.target
                        (Desktop adds SDDM → graphical.target → Plasma)
  └─ runit (INIT=runit): /etc/runit/{1,2,3}, runsvdir, getty/sshd/syslogd
```

## 5. Security Model

- Userspace compiled with `-fstack-protector-strong`; kernel has PTI, Retpoline,
  KASLR, SMAP/SMEP.
- `etc/sysctl.d/10-blueberry.conf` hardens networking, restricts `dmesg`,
  `kptr_restrict`, ASLR level 2.
- **Package supply chain:** the `bpm.index` is ed25519-signed and verified
  against the key in `src/bpm-rs/src/repokey.rs`; every `.bpm` is SHA-256-checked
  against that signed index over TLS before install. Builds are reproducible
  (fixed `SOURCE_DATE_EPOCH`) in an ephemeral container. See [SECURITY.md](SECURITY.md).
- On the runit disk path, sshd ships `PermitRootLogin no` /
  `PasswordAuthentication no`, and the root fs is mounted read-only until stage 1
  remounts it rw after fsck.

## 6. Directory Reference

| Path | Description |
|------|-------------|
| `GNUmakefile` / `Make.config` | Build entry point + default variables |
| `Make.local` | Machine-local overrides (gitignored) |
| `src/kernel/` | Kernel config, patches, fetch/publish of the pinned artifact |
| `src/busybox/` | busybox config + Makefile (live-CLI userland) |
| `src/init/` | runit stage scripts + services (`INIT=runit`) |
| `src/systemd/` | systemd integration: units, networkd, sshd (`INIT=systemd`) |
| `src/initramfs/` | live-CLI `/init`, `selftest`, live-desktop overlay |
| `src/bpm-rs/` | the `bpm` package manager (Rust) |
| `src/installer/` | `blueberry-install` guided CLI installer |
| `packages/<name>/` | from-source `.bpm` recipes (`bpm.toml`) |
| `editions/desktop/` | KDE/GNOME spin: package lists, Calamares, branding |
| `tools/` | `bundle-glibc.sh`, `build-bpm-pkg.sh`, `bpmrepo.sh`, `stage-desktop.sh`, `check-closure.py`, `check-runtime-closure.py`, `qemu.sh`, `mkiso.sh` |
| `etc/` | /etc skeleton overlaid onto the rootfs |
| `doc/` | All documentation |
| `../blueberry-build/` | Build artefacts (outside the source tree): `boot/`, `rootfs/`, `desktop-rootfs/`, `bpm-out/`, `src/` |

## 7. Dependency-closure gates

The package graph must stay closed, or `bpm install` fails at runtime and the
desktop session breaks (a missing applet, no audio, no network stack). Two
checks enforce it:

- **`tools/check-closure.py`** (static, per-push CI) — asserts every recipe's
  `depends` resolves to another recipe or a host-provided name in
  `etc/bpm/provided`. Catches "declared but never packaged."
- **`tools/check-runtime-closure.py`** (against a staged desktop rootfs) — walks
  `DT_NEEDED` from the session binaries and every dlopen'd Qt/Plasma plugin and
  reports any shared-library soname that isn't present. Catches a missing soname
  even when a recipe nominally exists (wrong package list, unbuilt dep, soname
  bump).

`make build-world` (and `.github/workflows/build-world.yml`, weekly / on a
self-hosted builder) builds every package and runs both checks, so the closure
can't silently regress. See [CI.md](CI.md).
