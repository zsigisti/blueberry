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
make run            # boot the live CLI in QEMU
make test           # headless boot self-test (CI uses this)
make iso            # Server install ISO
make disk           # raw disk image
```

Tunables live in `Make.config` (arch, component versions, parallel jobs).

## Packages

```sh
ENGINE=podman tools/build-pkgs.sh <out-dir> <pkg>...   # build specific packages
```

Builds run in an ephemeral Arch container. Long builds survive the shell with:

```sh
setsid bash -c 'ENGINE=podman tools/build-pkgs.sh OUT pkg... > LOG 2>&1' </dev/null &
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
├── basepkgs/         built .pkg.tar.zst artifacts
├── initramfs/        staged initramfs
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
