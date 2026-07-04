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
| `make iso` / `make server-iso` | the above + xorriso |
| publishing | ssh/scp + an ed25519 repo key |

All build output goes to `../blueberry-build/` — **never** inside the tree.

## Core OS

```sh
make world          # busybox + runit + dropbear + initramfs + (fetch) kernel
make kernel         # fetch the PINNED PREBUILT kernel (~20 MB) — does NOT compile
make install        # stage the rootfs (INIT=systemd by default)
make iso            # busybox live-CLI / installer ISO
make server-iso     # systemd Server live ISO  → iso/blueberry-server-x86_64.iso
make disk           # raw disk image
```

> The kernel is **not compiled** on a normal build — `make kernel` downloads a
> fixed prebuilt artifact and verifies its hash (so a small machine never has to
> build a kernel). **glibc works the same way**: it's a pinned `.bpm` fetched
> from the mirror (`tools/fetch-bpm.sh`) and never built locally, so the C
> library is always the container-built one and never the build host's. Both
> need the mirror reachable (results are cached). To compile the kernel yourself
> use `make kernel-rebuild`, or `make kernel-publish` to release a new pinned
> artifact; bump glibc by rebuilding + republishing `packages/glibc`. See
> [The Kernel Model](The-Kernel-Model).

### Run & test

| Target | What it does |
|--------|--------------|
| `make run`          | boot the initramfs live CLI (interactive) |
| `make test`         | headless initramfs self-test (CI smoke) |
| `make run-server`   | boot the **Server** ISO in a QEMU window |
| `make test-server`  | boot Server ISO headless, assert `multi-user.target` |
| `make test-install` | unattended install into a disk image, assert it boots to login |

`run-*`/`test-*` build the ISO only if it's missing. Tunables live in
`Make.config` (arch, component versions, parallel jobs). `INIT=systemd` is the
default; `INIT=runit` builds the minimal RAM-first image.

## Packages

The native package format is **`.bpm`** (declarative `bpm.toml` recipes — see
[Package Management](Package-Management) and [Creating Packages](Creating-Packages)).

```sh
ENGINE=podman tools/build-bpm-pkg.sh <out-dir> <pkg>...   # build .bpm from bpm.toml
```

This runs in an ephemeral Arch container (the self-hosted toolchain). Long
builds survive the shell with:

```sh
setsid bash -c 'ENGINE=podman tools/build-bpm-pkg.sh OUT pkg... > LOG 2>&1' </dev/null &
```

## Publishing to a mirror

```sh
make repo-build                            # build every bpm.toml → obj/bpm-out
tools/bpmrepo.sh <repo-dir>                 # index + ed25519-sign a repo dir
```

`scp` the resulting `.bpm` files to the mirror, then re-index there. See
[Hosting a Mirror](Hosting-a-Mirror).

## Build output layout

```
../blueberry-build/
├── bpm-out/          built package artifacts (.bpm)
├── rootfs/           staged installed rootfs
├── initramfs/        live initramfs tree
├── boot/             kernel + initramfs images
└── *.log             build logs
```

## Tips

- **Parallelism:** the container build uses `-j$(nproc)`; set host jobs in
  `Make.config`.
- **Idempotent package builds:** `build-bpm-pkg.sh` skips packages already built
  and newer than their `bpm.toml`.
- **Reproducibility:** a fixed `SOURCE_DATE_EPOCH` makes rebuilds deterministic.

More: [doc/BUILD.md](../../doc/BUILD.md), [doc/BPM.md](../../doc/BPM.md).
