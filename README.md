# Blueberry Linux

A minimal Linux distribution built from a single source tree in the BSD
tradition. `git clone` → `make world` → `make run` drops you into a live CLI
running entirely from RAM in QEMU.

```
Linux 7.0 kernel · musl libc · busybox · runit init
```

---

## Quick Start

```sh
# 1. Clone
git clone https://github.com/mmzsigmond/blueberry.git
cd blueberry

# 2. Check prerequisites (compiler, wget/curl, zstd, cpio, qemu)
make _check_tools

# 3. Build everything: kernel + musl + busybox + runit + initramfs
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
| C library | **musl 1.2.x** | Small, correct, static-friendly |
| Core utilities | **busybox 1.36.x** | Single binary, 300+ applets |
| Init | **runit 2.1.x** | Supervision tree, 35 KB, no DSL |
| Kernel | **Linux 7.0** | Server profile, serial console, PCI |
| Distro model | **BSD-style monorepo** | `git clone` → `make world` → bootable; build output in `../blueberry-build/` |

The system boots as a **live CLI**: the kernel loads an initramfs that runs
straight into an interactive shell. Booting a real disk install is optional —
pass `root=<device>` on the kernel command line and `/init` will mount it and
hand off to runit instead.

---

## Source Tree

```
GNUmakefile         Top-level build: make world / kernel / run / test / iso
Make.config         Tunable variables (arch, versions, jobs)

src/
  kernel/           Linux 7.0 config, patches, Makefile
  lib/musl/         musl libc build rules
  busybox/          busybox config + Makefile
  init/             runit stage scripts + service dirs (disk-boot path)
  initramfs/        /init live-CLI script, selftest, profile, Makefile

etc/                /etc skeleton (hostname, fstab, sysctl, accounts)
tools/              Host-only scripts: qemu.sh (run/test), mkiso.sh
doc/                Documentation
```

---

## How It Boots

```
QEMU ─► vmlinuz ─► initramfs /init (PID 1)
                     │
                     ├─ mount /proc /sys /dev, populate /dev (mdev)
                     ├─ bbtest on cmdline?  ─► run /etc/selftest, print result, halt
                     ├─ root= on cmdline?   ─► mount disk, switch_root to runit
                     └─ otherwise           ─► interactive busybox login shell
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
| [doc/KERNEL.md](doc/KERNEL.md) | Kernel config, customisation, patch workflow |
| [doc/INIT.md](doc/INIT.md) | The live-CLI init and the runit disk-boot path |
| [doc/CI.md](doc/CI.md) | CI pipeline: build world + QEMU boot test |
| [doc/CONTRIBUTING.md](doc/CONTRIBUTING.md) | How to contribute |
| [doc/SECURITY.md](doc/SECURITY.md) | Kernel hardening, SSH hardening |

---

## License

MIT — see `LICENSE`.

All kernel code remains under the Linux kernel license (GPL-2.0-only with
Linux-syscall-note). musl is MIT. busybox is GPL-2.0. runit is BSD-3-Clause.
