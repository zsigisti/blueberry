# Building Blueberry Linux

## Prerequisites

The following tools must be present on the **build host**:

| Tool | Minimum version | Purpose |
|------|----------------|---------|
| GCC or Clang | 12+ | C compiler |
| musl-gcc | any | musl-linked binaries (install: `musl-tools` on Debian/Ubuntu) |
| Go | 1.22 | build bpm |
| GNU Make | 4.0 | build orchestration |
| wget or curl | any | source downloads |
| tar | any | archive extraction |
| xz | any | decompress kernel tarball |
| bzip2 | any | decompress busybox tarball |
| zstd | 1.4+ | compress initramfs + packages |
| cpio | any | create initramfs CPIO image |
| perl | 5.x | Linux kernel build dep |
| bc | any | Linux kernel build dep |
| libelf-dev | any | Linux kernel build dep |
| flex + bison | any | Linux kernel build dep |
| openssl-dev | any | Linux kernel build dep |
| xorriso | any | create bootable ISO |
| mksquashfs | any | ISO rootfs squashfs |

### Installing prerequisites on common distros

**Debian / Ubuntu**
```sh
apt-get install -y build-essential musl-tools golang-go wget tar \
    xz-utils bzip2 zstd cpio perl bc libelf-dev flex bison \
    libssl-dev xorriso squashfs-tools
```

**Arch Linux**
```sh
pacman -S base-devel musl go wget xz bzip2 zstd cpio bc \
          libelf flex bison openssl xorriso squashfs-tools
```

**Fedora / RHEL**
```sh
dnf install -y gcc musl-gcc golang wget xz bzip2 zstd cpio bc \
              elfutils-libelf-devel flex bison openssl-devel \
              xorriso squashfs-tools
```

---

## Quick Build

```sh
git clone https://github.com/mmzsigmond/blueberry.git
cd blueberry
make world           # build everything → ../blueberry-build/
make install         # install into ../blueberry-build/rootfs/
make iso             # create bootable ISO
```

---

## Build Targets

### `make fetch`

Downloads all upstream source archives into `../blueberry-build/src/` and extracts them.
Does NOT start any compilation. Use this to pre-populate on a machine with
internet access before building air-gapped.

```
../blueberry-build/src/linux-7.0.tar.xz
../blueberry-build/src/musl-1.2.5.tar.gz
../blueberry-build/src/busybox-1.36.1.tar.bz2
../blueberry-build/src/runit-2.1.2.tar.gz
../blueberry-build/src/linux-7.0/
../blueberry-build/src/musl-1.2.5/
../blueberry-build/src/busybox-1.36.1/
../blueberry-build/src/admin/runit-2.1.2/
```

### `make musl`

Builds musl libc from `../blueberry-build/src/musl-$(MUSL_VERSION)` and installs it into
`../blueberry-build/sysroot/`. This sysroot provides:

- `../blueberry-build/sysroot/usr/include/` — musl headers
- `../blueberry-build/sysroot/usr/lib/libc.so` — shared libc
- `../blueberry-build/sysroot/lib/ld-musl-x86_64.so.1` — dynamic linker symlink
- `../blueberry-build/sysroot/bin/musl-gcc` — compiler wrapper

This target must complete before busybox, runit, or any C package can be
built. The sysroot isolates the OS build from the host's glibc.

### `make busybox`

Compiles busybox using `musl-gcc` from the sysroot. Configuration comes
from `src/busybox/config`. Output:

- `../blueberry-build/rootfs/bin/busybox` (static binary, typically 1.2–1.8 MB)
- `../blueberry-build/rootfs/bin/sh`, `.../bin/ls`, ... (symlinks to busybox)

### `make runit`

Compiles runit using `musl-gcc`. Installs binaries and stage scripts:

- `../blueberry-build/rootfs/sbin/runit`, `runsv`, `runsvdir`, `sv`, `svlogd`, `chpst`
- `../blueberry-build/rootfs/etc/runit/1`, `/2`, `/3`
- `../blueberry-build/rootfs/etc/sv/*/run` (service definitions from `src/init/sv/`)

### `make bpm`

Compiles the package manager with `CGO_ENABLED=0` using the Go toolchain.
Output: `../blueberry-build/bpm` (a single static binary, typically 4–7 MB before strip).

### `make userland`

Alias for `make musl busybox runit bpm` in dependency order.

### `make kernel`

Downloads Linux $(LINUX_VERSION) if not already present, applies patches
from `src/kernel/patches/`, copies `src/kernel/config`, runs `olddefconfig`,
then builds the kernel with `$(JOBS)` parallel jobs.

Outputs:
- `../blueberry-build/boot/vmlinuz` — compressed kernel image
- `../blueberry-build/boot/System.map` — symbol map
- `../blueberry-build/rootfs/lib/modules/$(LINUX_VERSION)-blueberry/` — kernel modules

This is the longest step (~10 minutes on a modern machine with `JOBS=8`).
Use `make kernel JOBS=16` to speed it up.

### `make initramfs`

Assembles a minimal initramfs containing:
- `/bin/busybox` (from `../blueberry-build/rootfs`)
- Essential symlinks: `sh`, `mount`, `switch_root`, `mdev`, `blkid`, etc.
- `/init` (from `src/initramfs/init`)
- Static device nodes: `/dev/console`, `/dev/null`, `/dev/tty`, `/dev/urandom`

Packs as CPIO, compresses with zstd level 19.

Output: `../blueberry-build/boot/initramfs.cpio.zst`

### `make world`

Runs `make userland kernel initramfs` in the correct dependency order.
This is the default target.

### `make install`

Copies the `etc/` skeleton into `../blueberry-build/rootfs/etc/`, installs bpm into
`../blueberry-build/rootfs/usr/bin/bpm`, and creates remaining FHS directories.

After `install`, `../blueberry-build/rootfs/` is a complete root filesystem ready for
`chroot` or disk imaging.

### `make iso`

Requires: `make world install`

Creates a hybrid UEFI+BIOS bootable ISO using xorriso. The rootfs is
packed as a squashfs image inside the ISO. GRUB is used as the bootloader.

Output: `blueberry-YYYYMMDD-x86_64.iso`

### `make repo`

Builds all BBUILD recipes under `pkgs/` and indexes them:

```sh
make repo
# Produces:
#   ../blueberry-build/repo/*.bb        — built packages
#   ../blueberry-build/repo/BBINDEX.zst — package index
```

---

## Build Variables

Override any variable on the command line:

```sh
make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-musl- world
make JOBS=16 kernel
make DESTDIR=/mnt/blueberry install
make LINUX_VERSION=7.1 kernel
```

| Variable | Default | Description |
|----------|---------|-------------|
| `ARCH` | `x86_64` | Target architecture |
| `JOBS` | `nproc` | Parallel build jobs |
| `DESTDIR` | `../blueberry-build/rootfs` | Install root |
| `OBJDIR` | `../blueberry-build` | All build artefacts |
| `LINUX_VERSION` | `7.0` | Linux kernel version |
| `MUSL_VERSION` | `1.2.5` | musl libc version |
| `BUSYBOX_VERSION` | `1.36.1` | busybox version |
| `RUNIT_VERSION` | `2.1.2` | runit version |
| `CROSS_COMPILE` | _(empty)_ | Cross-compiler prefix |
| `CC` | `gcc` | C compiler |
| `CFLAGS` | `-Os -pipe -fstack-protector-strong` | C compiler flags |
| `GO` | `go` | Go compiler |
| `KERNEL_LOCALVERSION` | `-blueberry` | Kernel version suffix |

---

## Machine-Local Configuration

To avoid repeating flags on every `make` invocation, create `Make.local`:

```sh
cp Make.config Make.local
$EDITOR Make.local
```

`Make.local` is `.gitignore`d. Example:

```makefile
# Make.local
JOBS       = 16
ARCH       = x86_64
LINUX_VERSION = 7.0
DESTDIR    = /mnt/blueberry
GO         = /usr/local/go/bin/go
```

---

## Cross-Compilation

Cross-compiling for `aarch64`:

```sh
# Install cross toolchain
apt-get install gcc-aarch64-linux-gnu

# Build musl cross sysroot
make musl ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu-

# Build everything else
make world ARCH=aarch64 CROSS_COMPILE=aarch64-linux-musl-
```

For Go cross-compilation, the build system automatically sets `GOARCH` based
on `ARCH`. No separate Go cross-compiler is needed.

---

## Incremental Builds

The build system uses stamp files in `../blueberry-build/.stamp-*` to track completed
steps. If you change a source file, only the affected component rebuilds.

Force a full rebuild of a specific component:

```sh
rm ../blueberry-build/.stamp-busybox && make busybox
rm ../blueberry-build/.stamp-kernel  && make kernel
```

---

## Air-Gapped Builds

1. On a machine with internet access:
   ```sh
   make fetch
   tar -czf blueberry-sources.tar.gz -C .. blueberry-build/src/
   ```

2. Copy `blueberry-sources.tar.gz` to the air-gapped machine.

3. On the air-gapped machine:
   ```sh
   tar -xzf blueberry-sources.tar.gz -C ..
   make world    # no downloads needed — sources are in ../blueberry-build/src/
   ```

---

## Clean Targets

```sh
make clean       # remove build artefacts, keep downloaded sources
make distclean   # remove everything including ../blueberry-build/ (full reset)
```

---

## Build Time Estimates

On an 8-core machine with `JOBS=8`:

| Target | Approximate time |
|--------|-----------------|
| musl | 1–2 min |
| busybox | 1 min |
| runit | < 1 min |
| bpm | < 1 min |
| kernel | 8–15 min |
| initramfs | < 1 min |
| **world** | **12–20 min** |

---

## Troubleshooting

### `musl-gcc: command not found`

Install musl-tools: `apt-get install musl-tools` or compile musl manually
and add `obj/sysroot/bin` to your PATH.

### Kernel build fails: `elfutils not found`

Install `libelf-dev` (Debian) or `elfutils-libelf-devel` (Fedora).

### Go version too old

Blueberry requires Go 1.22+. Download from https://go.dev/dl/ and set:
```sh
export PATH=/usr/local/go/bin:$PATH
# or
make bpm GO=/usr/local/go/bin/go
```

### bpm build reports `go: go.mod file not found`

You must run `make bpm` from the repo root, not from inside `src/bpm/`.
The GNUmakefile passes the correct `-C` flags automatically.
