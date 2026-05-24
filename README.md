# Blueberry Linux

A minimal, server-focused Linux distribution built from a single source tree
in the BSD tradition.

```
Linux 7.0 kernel · musl libc · busybox · runit init · bpm package manager
```

---

## Quick Start

```sh
# 1. Clone
git clone https://github.com/mmzsigmond/blueberry.git
cd blueberry

# 2. Check prerequisites
make _check_tools

# 3. Build everything
make world        # kernel + musl + busybox + runit + bpm + initramfs
                  # all output goes to ../blueberry-build/ (never inside the source tree)

# 4. Install into a rootfs
make install      # populates ../blueberry-build/rootfs/

# 5. Create a bootable ISO
make iso          # writes blueberry-YYYYMMDD-x86_64.iso
```

---

## Design

| Component | Choice | Why |
|-----------|--------|-----|
| C library | **musl 1.2.x** | Small, correct, static-friendly |
| Core utilities | **busybox 1.36.x** | Single binary, 300+ applets |
| Init | **runit 2.1.x** (default) | Supervision tree, 35 KB, no DSL |
| Package manager | **bpm** (custom Go) | `.bb` binary packages, BFS solver |
| Kernel | **Linux 7.0** | LTS, server profile |
| Distro model | **BSD-style monorepo** | `git clone` → `make world` → bootable; build output in `../blueberry-build/` |

Init freedom is a first-class feature. runit is the default; s6, OpenRC,
and dinit are supported via the package system. systemd is not supported.

---

## Source Tree

```
GNUmakefile         Top-level build: make world / kernel / install / iso
Make.config         Tunable variables (arch, versions, jobs)

src/
  kernel/           Linux 7.0 config, patches, Makefile
  lib/musl/         musl libc build rules
  busybox/          busybox config + Makefile
  init/             runit stage scripts, service dirs, Makefile
  bpm/              Package manager (Go source)
  initramfs/        /init script + Makefile

etc/                /etc skeleton (hostname, fstab, sysctl, bpm config)
pkgs/               BBUILD package recipes
  core/             Base system packages
  extra/            Extended packages
  community/        Community packages
tools/              Host-only build scripts (mkiso, mkrepo, bootstrap)
doc/                Documentation
```

---

## Documentation

| Document | Contents |
|----------|---------|
| [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md) | System design, boot sequence, component relationships |
| [doc/BUILD.md](doc/BUILD.md) | Building the OS, prerequisites, all make targets |
| [doc/KERNEL.md](doc/KERNEL.md) | Kernel config, customisation, patch workflow |
| [doc/PACKAGES.md](doc/PACKAGES.md) | `.bb` format spec, BBINDEX format, database layout |
| [doc/BBUILD.md](doc/BBUILD.md) | BBUILD recipe authoring guide and variable reference |
| [doc/INIT.md](doc/INIT.md) | runit deep dive, service management, alternative inits |
| [doc/BPM.md](doc/BPM.md) | bpm user guide and command reference |
| [doc/BPM-INTERNALS.md](doc/BPM-INTERNALS.md) | bpm module architecture for contributors |
| [doc/CONTRIBUTING.md](doc/CONTRIBUTING.md) | How to contribute packages and code |
| [doc/HOSTING.md](doc/HOSTING.md) | GitHub Actions CI + Nginx repo server setup |
| [doc/SECURITY.md](doc/SECURITY.md) | Package signing, kernel hardening, SSH hardening |

---

## Package Manager

```sh
bpm update               # sync repo indices
bpm install openssh      # install with dep resolution
bpm remove openssh       # remove
bpm upgrade              # upgrade all packages
bpm search nginx         # search available packages
bpm verify               # check installed file integrity
bpm build pkgs/core/openssh/BBUILD   # build a .bb from source
bpm repo list            # list configured repositories
```

Packages are `.bb` files — zstd-compressed tar archives — served from an
Nginx-backed repository at `https://repo.blueberry.linux/`.

---

## Contributing

See [doc/CONTRIBUTING.md](doc/CONTRIBUTING.md).

TL;DR:
1. Fork on GitHub
2. Write a `BBUILD` in `pkgs/extra/<name>/`
3. `make bpm && ../blueberry-build/bpm build pkgs/extra/<name>/BBUILD`
4. Open a Pull Request

---

## License

MIT — see `LICENSE`.

All kernel code remains under the Linux kernel license (GPL-2.0-only with
Linux-syscall-note). musl is MIT. busybox is GPL-2.0. runit is BSD-3-Clause.
