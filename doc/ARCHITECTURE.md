# Blueberry Linux — Architecture

## 1. Overview

Blueberry Linux is a monolithic-source Linux distribution. The kernel, C
library, core utilities, and init system live in a single source tree and are
built together from a top-level GNUmakefile, in the tradition of BSD operating
systems.

The system boots as a **live CLI**: the kernel loads an initramfs that runs
straight into an interactive busybox shell, entirely from RAM. Booting a real
disk install is an optional path triggered by `root=` on the kernel command
line.

```
┌──────────────────────────────────────────────────────────────────────┐
│                     Blueberry Linux Source Tree                       │
│                                                                       │
│  GNUmakefile ─ top-level BSD-style build orchestrator                 │
│  Make.config ─ tunable build variables (arch, jobs, versions)         │
│                                                                       │
│  src/kernel/    Linux 7.0 fetch + patch + build → vmlinuz             │
│  tools/bundle-glibc.sh  stage host glibc runtime into the image        │
│  src/busybox/   busybox 1.36.x → /bin/busybox + applet symlinks       │
│  src/init/      runit 2.1.x → /sbin/runit-init + stage scripts        │
│  src/initramfs/ live-CLI /init + selftest + build rules → initramfs   │
│                                                                       │
│  etc/           /etc skeleton overlaid onto the assembled rootfs      │
│  tools/         host-only scripts (qemu.sh, mkiso.sh)                 │
│  doc/           this documentation                                    │
└──────────────────────────────────────────────────────────────────────┘
```

## 2. Component Relationships

```
Build host
  └─ make world
       ├─ fetch      downloads linux, busybox, runit, dropbear tarballs
       ├─ busybox    gcc (dynamic glibc) → obj/rootfs/bin/busybox
       ├─ runit      gcc (dynamic glibc) → obj/rootfs/sbin/runit*
       ├─ dropbear   gcc (dynamic glibc) → obj/rootfs/usr/sbin/dropbearmulti
       ├─ kernel     builds Linux → obj/boot/vmlinuz + modules in rootfs
       └─ initramfs  bundle-glibc.sh + pack busybox/dropbear + /init → initramfs.cpio.zst

Runtime (live CLI — the default)
  kernel → initramfs:/init (PID 1)
             ├─ mount /proc /sys /dev, populate /dev (mdev)
             └─ exec interactive busybox login shell

Runtime (optional disk boot — root= on cmdline)
  kernel → initramfs:/init → mount root → switch_root → /sbin/runit-init
                                              ↑
                                       runs stage 1, 2, 3
```

## 3. Design Decisions

### 3.1  glibc for binary compatibility

The userland is built dynamically against **glibc** so that prebuilt,
glibc-only software (proprietary binaries, language runtimes, GPU/driver
userspace, etc.) runs on Blueberry without a compatibility shim. The glibc
runtime — the ELF interpreter `/lib64/ld-linux-x86-64.so.2`, the shared libs,
the dlopen-only NSS modules, and `ld.so.cache` — is staged into the image at the
standard ABI paths by `tools/bundle-glibc.sh`.

No libc is built from source: the build links against the host's glibc with
`$(CC)` and bundles that runtime. Trade-off vs musl: larger image (the glibc
runtime is a few MB), dynamic linking instead of a single static binary, and the
build is tied to the host glibc version (less hermetic). The win is drop-in
compatibility with the vast ecosystem of glibc binaries.

### 3.2  busybox for base utilities

busybox combines 300+ Unix utilities into a single binary — small and
auditable. The applet configuration (`src/busybox/config`) is tuned so that the
single (dynamic glibc) binary provides the entire live-CLI userland: shell, coreutils,
`mdev`, `switch_root`, `cttyhack`, networking tools, and an editor.

### 3.3  runit as the init (disk-boot path)

runit is not systemd. Three stages, a supervision model, and nothing else.
Service definitions are executable shell scripts in a directory — inspectable,
editable, and version-controllable. It is used when Blueberry boots a real root
filesystem; the live CLI does not need it. There is no plan to support systemd.

### 3.4  Single source tree (BSD-style)

The base system is versioned together, so `git clone` gives you everything
needed to build a bootable OS, CI can verify the entire base on every commit,
and kernel/libc/init are known-compatible combinations. The trade-off is that
upstream releases require a deliberate update commit.

### 3.5  No package manager

Blueberry ships as a self-contained image, not a set of installable packages.
Everything in the running system comes from `make world`. Adding software means
adding it to the source tree (a busybox applet, a kernel option, or a binary
baked into the initramfs/rootfs) and rebuilding — keeping the whole system
reproducible from one `make`.

## 4. Boot Sequence

### Live CLI (default — `make run`)

```
1. QEMU/BIOS/UEFI loads vmlinuz + initramfs.cpio.zst
2. Kernel decompresses initramfs, mounts it as rootfs, runs /init
3. initramfs/init (PID 1):
     a. Mounts /proc /sys /dev /dev/pts /run /tmp
     b. Populates /dev from sysfs (mdev -s)
     c. Applies the hostname
     d. Parses the kernel command line
     e. No root= → exec an interactive busybox login shell
4. You are at a prompt, running from RAM
```

### Self-test (`make test`, kernel cmdline `bbtest`)

```
3e. bbtest present → run /etc/selftest, print BLUEBERRY_TEST=PASS|FAIL, halt
```

### Disk boot (optional, kernel cmdline `root=<dev>`)

```
3e. root= present → mount it, move /proc /sys /dev /run, switch_root → init
4.  /sbin/runit-init (PID 1 in real root)
5.  /etc/runit/1 — stage 1: remount rw, mdev, hwclock, sysctl
6.  /etc/runit/2 — stage 2: runsvdir (supervise services: getty, syslogd, sshd)
7.  On shutdown: runit → /etc/runit/3 (drain, sync, unmount, halt)
```

## 5. Security Model

- Userspace compiled with `-fstack-protector-strong`.
- Kernel has PTI, Retpoline, KASLR, SMAP/SMEP enabled.
- sysctl defaults in `etc/sysctl.d/10-blueberry.conf` enforce network
  hardening, `dmesg` restriction, `kptr_restrict`, ASLR level 2.
- On the disk-boot path, sshd ships with `PermitRootLogin no` and
  `PasswordAuthentication no`, and the root filesystem is mounted read-only by
  the initramfs until stage 1 remounts it read-write after fsck.

## 6. Directory Reference

| Path | Description |
|------|-------------|
| `GNUmakefile` | Top-level build entry point |
| `Make.config` | Default build variables |
| `Make.local` | Machine-local overrides (gitignored) |
| `src/kernel/` | Linux kernel config, patches, Makefile |
| `tools/bundle-glibc.sh` | stage the host glibc runtime into the image |
| `src/busybox/` | busybox config + Makefile |
| `src/init/` | runit stage scripts + service definitions (disk-boot path) |
| `src/initramfs/` | live-CLI `/init`, `selftest`, `profile`, Makefile |
| `etc/` | /etc skeleton (copied to rootfs at install time) |
| `tools/` | Host-only scripts: `qemu.sh`, `mkiso.sh` |
| `doc/` | All documentation |
| `../blueberry-build/` | Build artefacts (outside the source tree) |
| `../blueberry-build/src/` | Extracted upstream source tarballs |
| `../blueberry-build/boot/` | vmlinuz, System.map, initramfs.cpio.zst |
| `../blueberry-build/rootfs/` | Assembled root filesystem (DESTDIR) |
