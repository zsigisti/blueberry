# Kernel Configuration Guide

> **The kernel is a pinned, prebuilt artifact — `make` does not compile it.**
> `make kernel` downloads a fixed, signed `vmlinuz`+modules tarball (~20 MB) from
> the repo and verifies its SHA‑256 (see [BUILD.md](BUILD.md) and the
> [Kernel Model](../wiki/The-Kernel-Model.md)). Compiling is opt-in:
> `make kernel-rebuild` builds it locally; `make kernel-publish` builds **and**
> uploads a new pinned artifact. The sections below describe the config that
> those rebuilds use.
>
> **On an installed system the kernel is upgraded with `bpm upgrade`** — it is a
> normal, bpm-tracked package (`linux`). See [§10](#10-upgrading-the-kernel-with-bpm).

## 1. Configuration File

The Blueberry kernel configuration is at `src/kernel/config`. It is a
standard Linux `.config` file — the exact format produced by `make menuconfig`,
tuned for a headless server.

When a kernel **rebuild** runs (`make kernel-rebuild` / `make kernel-publish`),
this file is copied to the kernel source tree and `make olddefconfig` is run to
fill in any missing options added by a newer kernel version.

---

## 2. Philosophy

The kernel config follows these principles:

1. **Only what a server needs.** No graphics/DRM stack — this is a console
   system. Trimmed everywhere it doesn't cost server functionality.

   > **Wi-Fi is enabled** for real-hardware installs: `cfg80211`/`mac80211`
   > plus common drivers (`iwlwifi`, `rtw88`, …), paired with `linux-firmware`,
   > `wpa_supplicant`, and NetworkManager in the base image.
   >
   > **The legacy netfilter backend is required by `ufw`:** the `IP_NF_*` /
   > `IP6_NF_*` stack (built in). On kernel versions that gate the legacy iptables
   > backend behind `CONFIG_NETFILTER_XTABLES_LEGACY`, that symbol is set too;
   > `make olddefconfig` drops it on trees that predate it. Without the legacy
   > stack `ufw` reports "table does not exist."

2. **Everything a server does need.** ext4, xfs, btrfs, LVM, RAID, NVMe,
   virtio, nftables, WireGuard, eBPF, cgroups, namespaces — all built in
   or as modules.

3. **Hardened by default.** PTI, Retpoline, KASLR, SMAP, SMEP,
   stack protectors, init-on-alloc, kptr restriction. These add measurable
   overhead only under specific workloads and protect against the entire
   class of speculative execution attacks.

4. **VM-friendly.** KVM, Xen, VMware, and virtio paravirt interfaces are
   built in. The kernel boots bare-metal and inside all major hypervisors
   without separate config variants.

---

## 3. Key Config Sections Explained

### CPU and Platform

```
CONFIG_SMP=y              Multiple processor support
CONFIG_NR_CPUS=256        Maximum supported CPUs
CONFIG_X86_X2APIC=y       Required for systems with >255 CPUs
CONFIG_HYPERVISOR_GUEST=y Enable paravirt interface detection
CONFIG_PARAVIRT=y         Allow paravirt patching (reduces trap overhead)
CONFIG_KVM_GUEST=y        KVM paravirt clock + MMU
CONFIG_XEN=y              Xen PV interface
```

### Memory Management

```
CONFIG_TRANSPARENT_HUGEPAGE=y          THP: reduces TLB pressure for large allocations
CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y  Only use THP when explicitly requested (safer default)
CONFIG_NUMA=y                          NUMA topology awareness (essential for multi-socket)
CONFIG_KSM=y                           Kernel Same-page Merging (useful in VM-dense hosts)
```

### Security

```
CONFIG_PAGE_TABLE_ISOLATION=y    Kernel KAISER/PTI (Meltdown mitigation)
CONFIG_RETPOLINE=y               Spectre v2 mitigation
CONFIG_RANDOMIZE_BASE=y          KASLR: kernel address randomization
CONFIG_RANDOMIZE_MEMORY=y        Physical memory map randomization
CONFIG_STACKPROTECTOR_STRONG=y   -fstack-protector-strong for kernel
CONFIG_FORTIFY_SOURCE=y          String function bounds checking
CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y  Zero-initialize allocations (prevents info leak)
CONFIG_INIT_ON_FREE_DEFAULT_ON=y   Zero memory on free (prevents use-after-free leaks)
CONFIG_SECURITY_YAMA=y           Yama ptrace scope restriction
CONFIG_SECURITY_LOCKDOWN_LSM=y   Kernel lockdown mode (integrity protection)
CONFIG_IMA=y                     Integrity Measurement Architecture
```

**KSPP hardening baseline** (Kernel Self-Protection Project). These are all
config-only — no GCC-plugin options, so there is no toolchain dependency; any a
given tree lacks are dropped by `make olddefconfig`:

```
CONFIG_STRICT_KERNEL_RWX=y       No writable+executable kernel memory
CONFIG_DEBUG_WX=y                Warn on any W+X mapping at boot
CONFIG_HARDENED_USERCOPY=y       Bounds-check copy_to/from_user against slab/stack
CONFIG_VMAP_STACK=y              Guard-paged kernel stacks (catches overflow)
CONFIG_SCHED_STACK_END_CHECK=y   Detect stack overrun at schedule()
CONFIG_SLAB_FREELIST_RANDOM=y    Randomize slab free-list order
CONFIG_SLAB_FREELIST_HARDENED=y  Harden slab free-list pointers against overwrite
CONFIG_SHUFFLE_PAGE_ALLOCATOR=y  Randomize the page allocator free-list
CONFIG_RANDOM_KMALLOC_CACHES=y   Spread kmalloc across randomized caches
CONFIG_LIST_HARDENED=y           Sanity-check linked-list operations
CONFIG_BUG_ON_DATA_CORRUPTION=y  BUG() on detected list/refcount corruption
CONFIG_ZERO_CALL_USED_REGS=y     Zero call-clobbered registers on return (ROP defense)
CONFIG_SECURITY_DMESG_RESTRICT=y Restrict dmesg to root (hides kernel pointers)
CONFIG_DEFAULT_MMAP_MIN_ADDR=65536  Block low-address mmap (NULL-deref exploits)
```

> **No source patches — hardening is config-only.** Blueberry pins an **LTS**
> kernel line (currently 6.18 LTS) and takes its point releases for security, so
> carrying a hardened *patchset* (which would need rebasing every bump) is
> deliberately avoided; the KSPP config above captures the security win with zero
> maintenance cost, and the LTS branch already backports upstream fixes. See §5.

### Networking

```
CONFIG_NF_TABLES=y         nftables — the current kernel packet filter
CONFIG_NFT_*=y             nftables extensions (counter, log, limit, nat, reject)
CONFIG_IP_VS=y             IPVS for load balancing
CONFIG_WIREGUARD=y         WireGuard VPN built-in
CONFIG_TCP_CONG_BBR=y      BBR congestion control (better throughput than CUBIC at scale)
CONFIG_INET_TCP_DIAG=y     ss(8) socket statistics support
CONFIG_BRIDGE=y            Ethernet bridging (Docker networks, VMs)
CONFIG_TUN=y               TUN/TAP (OpenVPN, QEMU user-net)
CONFIG_VETH=y              Virtual ethernet pairs (containers)
CONFIG_BONDING=y           NIC bonding/teaming
```

### Storage and Block

```
CONFIG_MD=y                Linux Software RAID (mdadm)
CONFIG_MD_RAID1=y          RAID 1 (mirroring)
CONFIG_MD_RAID10=y         RAID 10
CONFIG_MD_RAID456=y        RAID 4/5/6
CONFIG_BLK_DEV_DM=y        Device Mapper (LVM foundation)
CONFIG_DM_CRYPT=y          dm-crypt (LUKS)
CONFIG_DM_THIN_PROVISIONING=y  Thin provisioning (Docker thin pool)
CONFIG_NVME_CORE=y         NVMe core
CONFIG_BLK_DEV_NVME=y      NVMe PCIe block driver
CONFIG_VIRTIO_BLK=y        virtio block (KVM/QEMU disk)
```

### Filesystems

```
CONFIG_EXT4_FS=y           ext4 — primary production filesystem
CONFIG_XFS_FS=y            XFS — high-performance, large files
CONFIG_BTRFS_FS=y          Btrfs — snapshots, checksums
CONFIG_OVERLAY_FS=y        OverlayFS (container layers)
CONFIG_FUSE_FS=y           FUSE (userspace filesystems)
CONFIG_TMPFS=y             tmpfs (/tmp, /run, Docker volumes)
CONFIG_DEVTMPFS=y          devtmpfs (automatic /dev population)
CONFIG_DEVTMPFS_MOUNT=y    Auto-mount devtmpfs at boot
```

### Containers and Namespaces

```
CONFIG_NAMESPACES=y        Enable all namespace types
CONFIG_UTS_NS=y            Hostname namespaces
CONFIG_IPC_NS=y            IPC namespaces
CONFIG_PID_NS=y            PID namespaces
CONFIG_NET_NS=y            Network namespaces
CONFIG_USER_NS=y           User namespaces (rootless containers)
CONFIG_CGROUPS=y           Control groups v2
CONFIG_MEMCG=y             Memory cgroup accounting
CONFIG_CGROUP_SCHED=y      CPU scheduling cgroups
CONFIG_CFS_BANDWIDTH=y     CPU bandwidth control
CONFIG_BLK_CGROUP=y        IO cgroup throttling
CONFIG_CGROUP_BPF=y        eBPF hooks on cgroup events
```

Note: `CONFIG_CGROUP_SYSTEMD` is intentionally disabled. The cgroup
hierarchy does not need the systemd-specific cgroup controller.

### eBPF

```
CONFIG_BPF=y               Berkeley Packet Filter
CONFIG_BPF_SYSCALL=y       bpf() system call
CONFIG_BPF_JIT=y           JIT compiler (essential for performance)
CONFIG_BPF_JIT_ALWAYS_ON=y Disable BPF interpreter (JIT only — more secure)
CONFIG_BPF_EVENTS=y        BPF tracing via perf events
```

---

## 4. Customising the Config

### Using menuconfig

```sh
# Extract the kernel source
make fetch

# Start the interactive configurator
make -C $OBJDIR/src/linux-6.18.38 \
    ARCH=x86_64 \
    menuconfig

# Copy the result back into the source tree
cp $OBJDIR/src/linux-6.18.38/.config src/kernel/config
```

### Adding a driver as a module

Find the config symbol with:
```sh
make -C $OBJDIR/src/linux-6.18.38 ARCH=x86_64 grep-config SEARCH=REALTEK_PHY
```

Then add to `src/kernel/config`:
```
CONFIG_REALTEK_PHY=m
```

Modules are installed to `obj/rootfs/lib/modules/6.18.38-blueberry/` by
`make kernel` and loaded at runtime via `modprobe`.

### Disabling something

Set to `n`:
```
# CONFIG_SOUND is not set
```

Or add:
```
CONFIG_SOUND=n
```

---

## 5. Kernel Patches

Put unified diff patches in `src/kernel/patches/`. They are applied in
alphabetical order before the kernel is configured.

Naming convention:
```
0001-fix-build-with-gcc-14.patch
0002-fix-build-with-clang-17.patch
```

Each patch is applied with `patch -p1 < file.patch` from the kernel root.

A `.blueberry-patched` sentinel file is created after patching to prevent
re-applying on incremental builds.

---

## 6. Building a Custom Kernel Outside the Build System

```sh
cd $OBJDIR/src/linux-6.18.38
cp ../../src/kernel/config .config
make ARCH=x86_64 olddefconfig
make ARCH=x86_64 -j$(nproc)
make ARCH=x86_64 INSTALL_MOD_PATH=/tmp/mods modules_install
cp arch/x86_64/boot/bzImage /boot/vmlinuz
```

---

## 7. Kernel Module Loading at Boot

Stage 1 (`etc/runit/1` / `src/init/1`) loads modules listed in
`/etc/modules`:

```
# /etc/modules
# Load at boot:
virtio_net
9p
9pnet_virtio
overlay
```

For automatic loading based on hardware: `mdev -s` (run in stage 1) sends
uevents that trigger module loading via the kernel hotplug mechanism.

---

## 8. Debug vs Production Kernel

| Setting | Debug | Production |
|---------|-------|-----------|
| `CONFIG_DEBUG_KERNEL` | y | **n** |
| `CONFIG_FTRACE` | y | **n** |
| `CONFIG_KASAN` | y | **n** |
| `CONFIG_UBSAN` | y | **n** |
| `CONFIG_LOCK_STAT` | y | **n** |
| `CONFIG_LOCALVERSION` | `-blueberry-debug` | `-blueberry` |

To build a debug kernel:
```sh
cp src/kernel/config src/kernel/config.debug
# Edit config.debug: enable CONFIG_DEBUG_KERNEL, CONFIG_FTRACE, etc.
make kernel KERNEL_CONFIG=src/kernel/config.debug
```

> **Localversion — set in exactly one place.** The `-blueberry` suffix comes
> **only** from `CONFIG_LOCALVERSION` in `src/kernel/config`. The artifact build
> (`src/kernel/Makefile`) passes `LOCALVERSION=` **empty** on purpose: passing
> `-blueberry` there too would append it a second time and produce
> `uname -r = 6.18.38-blueberry-blueberry`. Empty (not unset) also suppresses the
> kernel's `+` "scm-dirty" auto-suffix. Result: `uname -r = 6.18.38-blueberry`.

---

## 9. Kernel Version Policy & Publishing

**Blueberry pins an LTS kernel line** (currently **6.18 LTS**), Debian-style: the
base stays on one long-term-supported series and takes its **point releases** for
security, rather than chasing the newest mainline. LTS branches receive upstream
security backports, so a bump is just `6.18.x → 6.18.(x+1)` — no patchset, and no
config churn. Move to a newer LTS line only deliberately (e.g. for hardware
support), reviewing the config diff when you do.

The source tree targets a specific kernel version (`LINUX_VERSION` in
`Make.config`). Because the kernel ships as a **pinned prebuilt artifact**,
changing it means publishing a new artifact. On a build box:

1. Update `LINUX_VERSION` in `Make.config` and/or edit `src/kernel/config`.
2. Run `make kernel-publish` — compiles the new kernel (KERNEL_BUILD=1, runs
   `make olddefconfig`) **and** uploads the pinned
   `blueberry-kernel-<version>-blueberry-<arch>.tar.zst` (+ `.sha256`) to the repo.
   (`make kernel-rebuild` compiles without uploading.)
3. Also bump `packages/linux/bpm.toml` (version + `sha256` + `release`) and
   rebuild that installable `linux` **.bpm** (`tools/build-bpm-pkg.sh`), then
   publish + re-index it — this is what `bpm upgrade` pulls (see §10).
4. Commit the `Make.config` / `src/kernel/config` / `packages/linux/bpm.toml` change.

**Two gotchas when bumping the version** (both caused hard-to-see bugs):

- `$(OBJDIR)/.stamp-fetch-linux` is **not** version-keyed, so make thinks the old
  source is already fetched and the rebuild fails. Remove it first:
  `rm -f ../blueberry-build/.stamp-fetch-linux ../blueberry-build/.stamp-kernel`.
- `publish-kernel.sh` picks the modules dir with `ls | head -1`, so a leftover
  **old-version** module tree (alphabetically first) can be packed with the new
  bzImage. Purge stale module dirs before publishing:
  `rm -rf ../blueberry-build/rootfs/{,usr/}lib/modules/<oldver>*`.

Every other machine then just `make kernel`-fetches the new pinned artifact; no
one else recompiles. Because an **LTS** line is pinned, a bump is normally just
the next point release on the same series — which is also why no source patchset
is carried (§5): the LTS branch already backports fixes upstream.

---

## 10. Upgrading the Kernel with `bpm`

On an installed system the kernel is a normal, bpm-tracked package named
`linux`, so it upgrades like anything else:

```sh
bpm update      # refresh the signed repo index
bpm upgrade     # if the repo has a newer linux, it is pulled + installed
```

How it is wired (see `tools/seed-kernel-db.sh` and `packages/linux/bpm.toml`) —
deliberately minimal, because a single pinned LTS kernel needs no promotion,
fallback, or grub-regeneration machinery:

- The image build registers `linux` in the bpm DB
  (`var/lib/bpm/db/linux/{desc,files}`, owning `boot/vmlinuz`) at `make install`,
  because the running kernel comes from the pinned artifact copied by the
  installer, not from a package — without this seed, `bpm upgrade` could not see
  the kernel.
- The `linux` .bpm installs the kernel straight to `/boot/vmlinuz`. On upgrade
  `bpm` overwrites that file (atomic rename, safe even for the running kernel),
  and the **installer's grub.cfg already boots `/boot/vmlinuz` by root-fs UUID**
  (`src/installer/src/boot.rs`), so the new kernel boots on next reboot with **no
  grub.cfg change**.
- The initramfs is kernel-agnostic (busybox, no loadable modules), so it is not
  regenerated either — the same `/boot/initramfs.cpio.zst` boots any kernel.

That's the whole mechanism: overwrite one file. There is no `post_upgrade` hook
and no `grub-mkconfig` step — those were removed as unnecessary once the kernel
became a stable-path, single-LTS package.
