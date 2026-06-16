# Blueberry Linux

A minimal Linux distribution built from a single source tree in the BSD
tradition. `git clone` → `make world` → `make run` drops you into a live CLI
running entirely from RAM in QEMU.

```
Linux 7.0 kernel · glibc · busybox · bash · runit init · Dropbear SSH · bpm packages
```

It ships a native package manager (`bpm`, written in Rust) that installs from an
HTTP(S) repository with per-package SHA-256 verification, a guided disk
**installer** (`blueberry-install`), and a growing
package set including the GNU **toolchain** (gcc, binutils, git, make).

---

## Quick Start

```sh
# 1. Clone
git clone https://github.com/mmzsigmond/blueberry.git
cd blueberry

# 2. Check prerequisites (compiler, wget/curl, zstd, cpio, qemu)
make _check_tools

# 3. Build everything: kernel + busybox + runit + dropbear + initramfs
make world          # all output goes to ../blueberry-build/ (never in the tree)

# 4. Boot the live CLI in QEMU (interactive — Ctrl-A X to quit)
make run

# 5. Run the automated boot test (headless, used by CI)
make test
```

`make run` boots the kernel and initramfs and hands you an interactive
busybox shell. No disk image, no install step, no network required.

---

## Design

| Component | Choice | Why |
|-----------|--------|-----|
| C library | **glibc** (host) | Binary compatibility — runs prebuilt glibc software |
| Core utilities | **busybox 1.36.x** | Single binary, 300+ applets, standalone shell (`/bin/sh`) |
| Login shell | **bash 5.2** | Default interactive shell on installed systems |
| Init | **runit 2.1.x** | Supervision tree, 35 KB, no DSL |
| SSH | **Dropbear 2024.x** | Tiny static SSH server + client |
| Packages | **bpm** | Native package manager (Rust); installs from an HTTP(S) repo (`.pkg.tar.zst`), per-package SHA-256 |
| Installer | **blueberry-install** | Guided GPT/UEFI install: partition, format, GRUB, root password |
| Kernel | **Linux 7.0** | Server profile: SATA/NVMe/USB, NICs, UEFI, serial console |
| Distro model | **BSD-style monorepo** | `git clone` → `make world` → bootable; build output in `../blueberry-build/` |

The system boots as a **live CLI**: the kernel loads an initramfs that runs
straight into an interactive shell, brings up networking (DHCP on every NIC),
and starts SSH (Dropbear) and time sync (ntpd). Booting a real disk install is
optional — pass `root=<device>` on the kernel command line and `/init` will
mount it and hand off to runit instead.

Log in over SSH as `root` (default password `blueberry` — change it for real
deployments). Deploy to bare metal with `make iso` or `make disk`; see
[doc/DEPLOY.md](doc/DEPLOY.md).

### Installing to disk

The ISO carries a guided installer. Boot it and run `blueberry-install`: it
partitions the target (GPT: EFI + root), formats (FAT + ext4), extracts the
root filesystem, installs GRUB (UEFI), writes `fstab`, and sets the root
password. The installed system boots GRUB → kernel → runit, with **bash** as
the login shell. Unattended installs are supported via the `bbinstall` kernel
cmdline (used by the QEMU end-to-end test).

### Packages

`bpm update && bpm install <pkg>` pulls from the configured repo
(`/etc/bpm/repos.conf`). Every package is verified against the SHA-256 recorded
in the repo index, and the index is fetched over TLS (no index signing).
Recipes live in [packages/](packages/); host the repo yourself with
`tools/mkrepo.sh`, `tools/blueberry-repo-sync.sh`, or the one-command
`tools/blueberry-build-server.sh` (see [doc/BPM.md](doc/BPM.md)).

---

## Source Tree

```
GNUmakefile         Top-level build: make world / kernel / run / test / iso
Make.config         Tunable variables (arch, versions, jobs)

src/
  kernel/           Linux 7.0 config, patches, Makefile
  busybox/          busybox config + Makefile (dynamic glibc)
  init/             runit stage scripts + service dirs (disk-boot path)
  dropbear/         Dropbear SSH build rules
  initramfs/        /init live-CLI script, selftest, profile, udhcpc, Makefile
  bpm-rs/           Native package manager (Rust): streaming installs, SHA-256
  installer/        blueberry-install — guided GPT/UEFI disk installer (C)

packages/           bpm package recipes (PKGBUILD format)
etc/                /etc skeleton (hostname, fstab, sysctl, accounts, bpm config)
tools/              Host-only scripts: qemu.sh, mkiso.sh, mkdisk.sh, build-pkgs.sh,
                    mkrepo.sh, blueberry-repo-sync.sh, blueberry-build-server.sh
doc/                Documentation
```

---

## How It Boots

```
QEMU ─► vmlinuz ─► initramfs /init (PID 1)
                     │
                     ├─ mount /proc /sys /dev, populate /dev (mdev)
                     ├─ bbtest on cmdline?    ─► run /etc/selftest, print result, halt
                     ├─ bbinstall on cmdline? ─► run blueberry-install unattended, halt
                     ├─ root= on cmdline?     ─► resolve UUID, mount disk, switch_root to runit
                     └─ otherwise             ─► interactive login shell
```

`make run` boots with no special cmdline → you land in the live shell.
`make test` boots with `bbtest` → the in-guest self-test prints
`BLUEBERRY_TEST=PASS`, which the runner asserts on.

---

## Documentation

| Document | Contents |
|----------|---------|
| [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md) | System design, boot sequence, components |
| [doc/BUILD.md](doc/BUILD.md) | Building the OS, prerequisites, all make targets |
| [doc/DEPLOY.md](doc/DEPLOY.md) | Deploying on real hardware: ISO, disk image, `dd` |
| [doc/BPM.md](doc/BPM.md) | `bpm` package manager + repos/mirrors; see also [packages/](packages/) |
| [doc/KERNEL.md](doc/KERNEL.md) | Kernel config, customisation, patch workflow |
| [doc/INIT.md](doc/INIT.md) | The live-CLI init and the runit disk-boot path |
| [doc/CI.md](doc/CI.md) | CI pipeline: build world + QEMU boot test |
| [doc/WEBSITE.md](doc/WEBSITE.md) | Build & deploy spec for the React site (self-hosted on Rocky/LAN) + release automation |
| [doc/CONTRIBUTING.md](doc/CONTRIBUTING.md) | How to contribute |
| [doc/SECURITY.md](doc/SECURITY.md) | Kernel hardening, SSH hardening |

---

## License

MIT — see `LICENSE`.

All kernel code remains under the Linux kernel license (GPL-2.0-only with
Linux-syscall-note). glibc is LGPL-2.1. busybox is GPL-2.0. runit is
BSD-3-Clause. Dropbear is MIT.
