# Porting Blueberry to aarch64

Status: **groundwork present, not yet a verified build.** The build is already
parameterized by `ARCH` (see `Make.config`), and `tools/qemu.sh` already selects
`qemu-system-aarch64` with the `virt` machine. What remains is a cross-toolchain
and the arch-specific values below. This is a dedicated effort — each piece must
be cross-built and the result boot-tested under QEMU TCG — so it is tracked
separately rather than half-landed.

## Prerequisites (build host)

The build host is x86_64, so aarch64 is a **cross-compile**:

```sh
# Debian/Ubuntu
sudo apt-get install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
# then build with:
make world ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu-
```

`Make.config` already exposes `ARCH` and a `CROSS_COMPILE` placeholder.

## Arch-specific touch-points

| Area | x86_64 | aarch64 |
|------|--------|---------|
| Kernel config | `src/kernel/*.config` (x86 defconfig + opts) | needs an arm64 defconfig + the same Blueberry options (VIRTIO, EXT4, VFAT, EFI, DM_CRYPT, serial `ttyAMA0`) |
| Dynamic linker | `/lib64/ld-linux-x86-64.so.2` | `/lib/ld-linux-aarch64.so.1` — update `tools/bundle-glibc.sh` |
| GRUB EFI target | `grub-mkstandalone -O x86_64-efi` → `bootx64.efi` | `-O arm64-efi` → `bootaa64.efi` — update `tools/mkiso.sh` and the installer's `BOOTX64.EFI` copy (glob `boot*.efi`) |
| Serial console | `console=ttyS0,115200` | `console=ttyAMA0,115200` — update init + installer grub.cfg |
| QEMU | `qemu-system-x86_64` | `qemu-system-aarch64 -M virt -cpu cortex-a72` + UEFI (`QEMU_EFI.fd`) — **already handled in `tools/qemu.sh`** |
| Packages | x86_64 Arch container | an `aarch64` build container (native arm64 host, or `qemu-user` + `binfmt` under an arm64 image); `.pkg` files are per-arch |

## Suggested order

1. Cross-build kernel + busybox + runit + dropbear (`make world ARCH=aarch64`).
2. Cross-stage the glibc runtime (`bundle-glibc.sh` ld-linux path).
3. Boot the live CLI under `qemu-system-aarch64` (`make run ARCH=aarch64`) and
   pass the self-test (`make test ARCH=aarch64`).
4. arm64-efi GRUB + installer EFI naming; verify the install→UEFI-boot path.
5. Stand up an aarch64 package build container so `bpm` has an arm64 repo.

Steps 1–4 are independent of the package set; step 5 is the largest and can
follow once the base system boots on arm64.

## Packaging: a fully separate aarch64 repo (no mixing)

Each architecture is built and published completely separately — its own
container image, build cache, webroot and signed index. An aarch64 box never
sees an x86_64 package and vice versa.

`tools/blueberry-repo-sync.sh` is arch-aware via `ARCH`:

```sh
# x86_64 (default) — Arch container, publishes /var/www/html/x86_64
tools/blueberry-repo-sync.sh

# aarch64 — Arch Linux ARM container under qemu, publishes /var/www/html/aarch64
ARCH=aarch64 tools/blueberry-repo-sync.sh
```

`ARCH=aarch64` selects an arm64 image (`docker.io/menci/archlinuxarm`) and runs
it with `--platform linux/arm64`, so packages build natively-emulated and land
as `*-aarch64.pkg.tar.zst`. The build host needs qemu-user + binfmt registered
once (root):

```sh
podman run --rm --privileged docker.io/multiarch/qemu-user-static --reset -p yes
```

On the client side, one `repos.conf` works for every arch: bpm expands `$arch`
in repo URLs to the machine architecture, e.g.

```
core https://repo.mmzsigmond.me/$arch
```

so an x86_64 box pulls `/x86_64/bpm.index` and an aarch64 box pulls
`/aarch64/bpm.index` — never each other's. The per-arch index is signed with the
same maintainer key, so signatures verify identically on both.
