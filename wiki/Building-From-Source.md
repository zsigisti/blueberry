# Building From Source

Blueberry builds from one tree. This page is the make-target reference.

## Prerequisites

```sh
make _check_tools          # reports anything missing for the core build
```

| Task | Tools |
|------|-------|
| `make world` / `make run` | gcc, make, curl, zstd, cpio, qemu |
| building packages | `podman` (or `docker`) |
| `make desktop-iso` | xorriso, squashfs-tools |
| publishing | ssh/scp + an ed25519 repo key |

All build output goes to `../blueberry-build/` — **never** inside the tree.

## Core OS (Server)

```sh
make world          # kernel + busybox + runit + dropbear + initramfs
make kernel         # just the kernel
make install        # stage the rootfs (INIT=systemd by default)
make iso            # busybox live-CLI / installer ISO
make server-iso     # systemd Server live ISO  → iso/blueberry-server-x86_64.iso
make disk           # raw disk image
```

### Run & test

| Target | What it does |
|--------|--------------|
| `make run`          | boot the initramfs live CLI (interactive) |
| `make test`         | headless initramfs self-test (CI smoke) |
| `make run-server`   | boot the **Server** ISO in a QEMU window |
| `make test-server`  | boot Server ISO headless, assert `multi-user.target` |
| `make run-desktop`  | boot the **Desktop** ISO in a QEMU window |
| `make test-desktop` | boot Desktop ISO headless, assert `graphical.target` |

`run-*`/`test-*` build the ISO only if it's missing, and boot with `-cpu host`
(required for the desktop's software GL). Tunables live in `Make.config`
(arch, component versions, parallel jobs). `INIT=systemd` is the default;
`INIT=runit` builds the minimal RAM-first image.

## Packages

The native package format is **`.bpm`** (declarative `bpm.toml` recipes — see
[Package Management](Package-Management) and [Creating Packages](Creating-Packages)).
New packages should be authored as `bpm.toml`.

```sh
ENGINE=podman tools/build-bpm.sh  <out-dir> <pkg>...   # build .bpm   (recipes: bpm.toml)
ENGINE=podman tools/build-pkgs.sh <out-dir> <pkg>...   # build .pkg.tar.zst (legacy PKGBUILD)
```

Both run in an ephemeral Arch container (the self-hosted toolchain). Long builds
survive the shell with:

```sh
setsid bash -c 'ENGINE=podman tools/build-bpm.sh OUT pkg... > LOG 2>&1' </dev/null &
```

## Desktop edition

```sh
make desktop-info                  # resolve the KDE edition (no build)
make desktop-info DE=gnome         # resolve the GNOME spin
make desktop-pkgs                  # build the self-hosted package closure
make desktop-iso                   # assemble the live Calamares ISO
make desktop-version BBD_VERSION=26.04   # show resolved version/codename
```

`DE=kde` (default) or `DE=gnome` selects the spin. `BBD_VERSION` pins the
release; otherwise it's derived from the date (see [Release Process](Release-Process)).

The desktop targets force `INIT=systemd` and pull the graphical package closure
from `editions/desktop/packages/*.list`.

## Publishing to a mirror

```sh
tools/mkrepo.sh <repo-dir>                 # index + ed25519-sign
tools/blueberry-repo-sync.sh               # build + push a set of packages
tools/blueberry-build-server.sh            # one-command build server
```

See [Hosting a Mirror](Hosting-a-Mirror).

## Build output layout

```
../blueberry-build/
├── basepkgs/         built package artifacts (.bpm / .pkg.tar.zst)
├── desktop-rootfs/   staged Desktop rootfs (squashed into the live ISO)
├── boot/             kernel + initramfs images
└── *.log             build logs
```

## Tips

- **Parallelism:** the container build uses `-j$(nproc)`; set host jobs in
  `Make.config`.
- **Idempotent package builds:** `build-pkgs.sh` skips packages already built
  and newer than their `PKGBUILD`.
- **Reproducibility:** a fixed `SOURCE_DATE_EPOCH` makes rebuilds deterministic.

More: [doc/BUILD.md](../doc/BUILD.md), [doc/BUILDSERVER.md](../doc/BUILDSERVER.md).
