# Building Blueberry Linux

## Prerequisites

The following tools must be present on the **build host**:

| Tool | Minimum version | Purpose |
|------|----------------|---------|
| GCC or Clang | 12+ | C compiler for the host-built base bits (busybox/runit/dropbear) |
| glibc + headers | host | links the host-built base bits (busybox/runit/dropbear); `bpm` packages build in the Arch container, and glibc itself is fetched from the mirror |
| podman or docker | any | runs the Arch build container that compiles all `bpm` packages |
| GNU Make | 4.0 | build orchestration |
| wget or curl | any | source downloads |
| tar | any | archive extraction |
| xz | any | decompress kernel tarball |
| bzip2 | any | decompress busybox tarball |
| zstd | 1.4+ | compress initramfs |
| cpio | any | create initramfs CPIO image |
| perl | 5.x | Linux kernel build dep |
| bc | any | Linux kernel build dep |
| libelf-dev | any | Linux kernel build dep |
| flex + bison | any | Linux kernel build dep |
| openssl-dev | any | Linux kernel build dep |
| qemu-system | any | `make run` / `make test` |
| xorriso | any | `make iso` (optional) |
| mksquashfs | any | `make iso` (optional) |

### Installing prerequisites on common distros

**Debian / Ubuntu**
```sh
apt-get install -y build-essential wget tar \
    xz-utils bzip2 zstd cpio perl bc libelf-dev flex bison \
    libssl-dev qemu-system-x86 xorriso squashfs-tools
```

**Arch Linux**
```sh
pacman -S base-devel wget xz bzip2 zstd cpio bc \
          libelf flex bison openssl qemu-base xorriso squashfs-tools
```

**Fedora / RHEL**
```sh
dnf install -y gcc glibc-devel wget xz bzip2 zstd cpio bc \
              elfutils-libelf-devel flex bison openssl-devel \
              qemu-system-x86 xorriso squashfs-tools
```

Run `make _check_tools` to verify the essentials are present.

---

## Quick Build

```sh
git clone https://github.com/zsigisti/blueberry.git
cd blueberry
make world           # build everything → ../blueberry-build/
make run             # boot the initramfs live CLI in QEMU (Ctrl-A X to quit)
make test            # headless boot self-test (asserts BLUEBERRY_TEST=PASS)
```

### Server ISO and run/test

```sh
make server-iso      # systemd Server live ISO   → iso/blueberry-server-x86_64.iso
make iso             # busybox live-CLI / installer ISO
make run-server  / make test-server     # boot Server ISO  (window / headless assert)
make test-install                        # unattended install to a disk image, assert boot
```

`INIT=systemd` is the default (journald/logind/networkd/NetworkManager/OpenSSH);
`INIT=runit` builds the minimal RAM-first image.

---

## Build Targets

### `make fetch`

Downloads all upstream source archives into `../blueberry-build/src/` and
extracts them. Does NOT start compilation. Use this to pre-populate a machine
with internet access before building air-gapped.

```
../blueberry-build/src/linux-7.0.tar.xz
../blueberry-build/src/busybox-1.36.1.tar.bz2
../blueberry-build/src/runit-2.1.2.tar.gz
```

### `make busybox`

Compiles busybox with the host `$(CC)` (gcc), linked **dynamically against the
host glibc**, from `src/busybox/config`. Output:

- `../blueberry-build/rootfs/bin/busybox` (dynamic, ~1 MB + the glibc runtime)
- applet symlinks: `sh`, `ls`, `mount`, … (created in the initramfs)

The glibc runtime is added later (initramfs + `make install`) by **fetching the
pinned `glibc` `.bpm` from the mirror** (`tools/fetch-bpm.sh`, sha256-verified)
and extracting it into the image; `tools/bundle-glibc.sh` then stages the
runtime (linker, shared libs, NSS modules, `ld.so.cache`) from there. The mirror
glibc is the container-built one, so a host with an older glibc than the build
container still produces a bootable image. busybox is linked against the
(possibly older) host glibc, but that runs fine on the newer mirror glibc; the
reverse — bundling an old host glibc under container-built binaries — is the
boot-panic bug this avoids. Because glibc is fetched, `make world`/`make install`
need the mirror reachable (cached under `../blueberry-build/bpm-cache`), just
like the pinned kernel.

### `make runit`

Compiles runit and installs `runit`, `runsv`, `runsvdir`, `sv`, `svlogd`,
`chpst`, the stage scripts `etc/runit/{1,2,3}`, and the service definitions
from `src/init/sv/`. This is the init used on the optional disk-boot path.

### `make userland`

Alias for `make busybox runit dropbear` (all dynamic glibc).

### `make kernel`

**Fetches a pinned, prebuilt kernel — it does not compile.** Downloads the fixed
`blueberry-kernel-<version>-<arch>.tar.zst` (~20 MB: `vmlinuz` + `System.map` +
modules) from the repo, verifies its SHA‑256, and unpacks it. Cached under
`../blueberry-build/src/` (survives `make clean`), so it's a few seconds after
the first run. Small machines never compile a kernel.

Outputs:
- `../blueberry-build/boot/vmlinuz` — compressed kernel image
- `../blueberry-build/boot/System.map` — symbol map
- kernel modules into the staged rootfs

**Compiling (opt-in, build boxes only):**
- `make kernel-rebuild` — compile from source this once (`KERNEL_BUILD=1`);
  applies `src/kernel/patches/`, copies `src/kernel/config`, runs `olddefconfig`,
  then builds. Speed it up with `make kernel-rebuild JOBS=16`.
- `make kernel-publish` — compile **and** upload a new pinned artifact to the
  repo (do this when bumping `LINUX_VERSION` / `src/kernel/config`; see
  [KERNEL.md](KERNEL.md) §9).

### `make initramfs`

Assembles the live-CLI initramfs:
- `/bin/busybox` + applet symlinks (`sh`, `mount`, `cttyhack`, `setsid`, …)
- `/init` — the live-CLI entry point (`src/initramfs/init`)
- `/etc/selftest` — the in-guest self-test (`src/initramfs/selftest`)
- `/etc/profile`, `/etc/passwd`, `/etc/group`, `/etc/hostname`
- static device nodes (`/dev/console`, `/dev/null`, `/dev/tty`, …)

Packed as CPIO, compressed with zstd -19.
Output: `../blueberry-build/boot/initramfs.cpio.zst`

### `make world`

Runs `make userland kernel initramfs`. The default target.

### `make run`

Boots `vmlinuz` + initramfs in QEMU and drops you into the interactive live
CLI. Serial is wired to your terminal; quit with **Ctrl-A X**. Uses KVM
automatically when `/dev/kvm` is available, otherwise falls back to TCG.

The live CLI runs entirely from RAM, so no disk is attached by default. To test
the installer, set `DISK=<size>` to attach a persistent writable disk as
`/dev/sda` (created on first use, reused after):

```sh
make run DISK=4G      # /dev/sda present → run 'bb-install' inside the guest
```

### `make test`

Boots headless with `bbtest` on the kernel command line. The in-guest
self-test runs and prints `BLUEBERRY_TEST=PASS`; the runner asserts on it and
exits non-zero on failure. This is what CI runs. Override the watchdog with
`make test TIMEOUT=180`.

### `make install`

Copies the `etc/` skeleton into `../blueberry-build/rootfs/etc/`, creates the
FHS directory layout, and copies the boot assets. After `install`,
`../blueberry-build/rootfs/` is a complete root filesystem for `chroot` or
disk imaging.

### `make iso`

Requires `make world install`. Creates a hybrid UEFI+BIOS bootable ISO with
xorriso. Output: `blueberry-YYYYMMDD-x86_64.iso`.

---

## Init system (`INIT=runit` | `INIT=systemd`)

The **installed disk system** can run either init; the live initramfs is always
busybox-based. `INIT=systemd` is the **default**; select at build time and carry
the same flag through `install` and `iso`:

```sh
make iso               # INIT=systemd (default) full systemd PID 1 + OpenSSH
make iso INIT=runit    # minimal busybox + runit + dropbear (RAM-first)
```

`INIT=systemd` bakes the systemd runtime closure (systemd 256.7, util-linux,
dbus, kmod, libseccomp, cryptsetup, OpenSSH, …) into the base image, installs
the `src/systemd/` integration layer (networkd/resolved/timesyncd, sshd units,
`multi-user.target`), and points `/sbin/init` at `/usr/lib/systemd/systemd`. The
initramfs execs `/sbin/init`, so the same kernel + initramfs boot either image.

---

## Build Variables

Override any variable on the command line:

```sh
make JOBS=16 kernel
make run MEM=1G
make test TIMEOUT=180
```

| Variable | Default | Description |
|----------|---------|-------------|
| `ARCH` | `x86_64` | Target architecture (x86_64 only) |
| `JOBS` | `nproc` | Parallel build jobs |
| `DESTDIR` | `../blueberry-build/rootfs` | Install root |
| `INIT` | `systemd` | Installed-system init: `systemd` or `runit` |
| `OBJDIR` | `../blueberry-build` | All build artefacts |
| `LINUX_VERSION` | `7.0` | Linux kernel version |
| `BUSYBOX_VERSION` | `1.36.1` | busybox version |
| `RUNIT_VERSION` | `2.1.2` | runit version |
| `DROPBEAR_VERSION` | `2024.86` | Dropbear SSH version |
| `CROSS_COMPILE` | _(empty)_ | Cross-compiler prefix |
| `CC` | `gcc` | C compiler |
| `CFLAGS` | `-Os -pipe -fstack-protector-strong` | C compiler flags |
| `KERNEL_LOCALVERSION` | `-blueberry` | Kernel version suffix |
| `MEM` | `512M` | QEMU guest RAM (`make run`/`test`) |
| `DISK` | _(none)_ | `make run` disk size, e.g. `4G`, attached as `/dev/sda`; unset = diskless |
| `TIMEOUT` | `90` | QEMU self-test watchdog seconds (`make test`) |

---

## Machine-Local Configuration

To avoid repeating flags, create `Make.local` (it is `.gitignore`d):

```sh
cp Make.config Make.local
$EDITOR Make.local
```

```makefile
# Make.local
JOBS          = 16
ARCH          = x86_64
LINUX_VERSION = 7.0
```

---

## Incremental Builds

Stamp files in `../blueberry-build/.stamp-*` track completed steps; only the
affected component rebuilds. The initramfs stamp also depends on
`src/initramfs/{init,selftest,profile,Makefile}`, so editing the live CLI
retriggers a rebuild automatically.

Force a full rebuild of a component:

```sh
rm ../blueberry-build/.stamp-busybox && make busybox
rm ../blueberry-build/.stamp-kernel  && make kernel          # re-fetches the pinned artifact
rm ../blueberry-build/.stamp-kernel  && make kernel-rebuild  # re-compiles from source instead
```

---

## Air-Gapped Builds

1. On a networked machine:
   ```sh
   make fetch          # busybox/runit/dropbear/linux sources
   make kernel         # also caches the prebuilt kernel artifact into src/
   tar -czf blueberry-sources.tar.gz -C .. blueberry-build/src/
   ```
   (`make kernel` is what pulls `blueberry-kernel-*.tar.zst` into `src/`; without
   it the air-gapped build can't fetch the pinned kernel — use `kernel-rebuild`
   there instead, which needs the linux source `make fetch` already cached.)
2. Copy `blueberry-sources.tar.gz` across.
3. On the air-gapped machine:
   ```sh
   tar -xzf blueberry-sources.tar.gz -C ..
   make world    # no downloads — sources already in ../blueberry-build/src/
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
| busybox | 1 min |
| runit | < 1 min |
| kernel | 8–15 min |
| initramfs | < 1 min |
| **world** | **11–19 min** |
| test (QEMU, KVM) | a few seconds |

---

## Troubleshooting

### A bundled glibc binary fails to run (`No such file or directory` on a valid ELF)

That error usually means the dynamic linker is missing. The image must contain
`/lib64/ld-linux-x86-64.so.2`, the libs in `/usr/lib`, and `/etc/ld.so.cache` —
all staged by `tools/bundle-glibc.sh` during the initramfs build and
`make install`, from the glibc `.bpm` fetched from the mirror. Rebuild the
initramfs (`rm ../blueberry-build/.stamp-initramfs && make initramfs`) and
confirm those paths are present. If the fetch itself failed (`fetch-bpm: … not
found` / sha mismatch / network error), the mirror is unreachable or the pinned
glibc is missing from it — check `https://repo.mmzsigmond.me/bpm.index`.

### Kernel build fails: `elfutils not found`

Install `libelf-dev` (Debian) or `elfutils-libelf-devel` (Fedora).

### `make test` hangs / times out

The self-test kills QEMU as soon as it prints its verdict, so a timeout means
the guest never reached `/etc/selftest`. Run `make run` and watch the boot —
a missing kernel option (serial console, initramfs, PCI) is the usual cause.
The serial log from a failed `make test` is saved to `/tmp/blueberry-test.*.log`.

### QEMU exits immediately with no output

Ensure the kernel has `CONFIG_SERIAL_8250_CONSOLE=y` and the initramfs was
built (`ls ../blueberry-build/boot/`). Rebuild with
`rm ../blueberry-build/.stamp-initramfs && make initramfs`.
