# Getting Started

There are three ways to meet Blueberry, in increasing order of commitment.

## 1. Boot it from RAM (no install)

The fastest taste of the Server edition. You need a Linux host with a C
compiler, `curl`, `zstd`, `cpio`, and `qemu`.

```sh
git clone https://github.com/mmzsigmond/blueberry.git
cd blueberry
make _check_tools     # verify prerequisites
make world            # build kernel + initramfs + userland (~minutes)
make run              # boot the live CLI in QEMU
```

You land in an interactive shell with networking up. `Ctrl-A X` quits QEMU.
Nothing touches your disk. See [Building From Source](Building-From-Source) for
every make target.

## 2. Install the Desktop from a live ISO

The full GUI experience: boot a live KDE Plasma session, try it, then install
with Calamares.

```sh
make desktop-iso                  # build the live ISO (KDE, the default)
# → ../blueberry-build/blueberry-desktop-<version>-x86_64.iso
```

Write it to a USB stick and boot, or test in QEMU:

```sh
qemu-system-x86_64 -enable-kvm -m 4G -smp 4 \
  -drive file=../blueberry-build/blueberry-desktop-*.iso,media=cdrom \
  -vga virtio -display gtk
```

The live session auto-logs into Plasma; double-click **Install Blueberry
Desktop** to launch Calamares. Full walkthrough:
[Installing Blueberry Desktop](Installing-Blueberry-Desktop).

## 3. Install the Server to disk

```sh
make iso                          # build the Server install ISO
```

Boot it and run `blueberry-install` — a guided GPT/UEFI installer. Full
walkthrough: [Installing Blueberry Server](Installing-Blueberry-Server).

## After installing

Set up packages on a running system:

```sh
bpm update                  # fetch the signed index
bpm search <term>
bpm install <package>
bpm upgrade                 # apply updates
```

See [Package Management](Package-Management). To understand how kernel updates
differ between editions, read [The Kernel Model](The-Kernel-Model).

## Prerequisites cheat-sheet

| Task | Needs |
|------|-------|
| `make world` / `make run` | gcc, make, curl, zstd, cpio, qemu |
| `make desktop-pkgs` / building packages | `podman` (or `docker`) |
| `make desktop-iso` | the above + `xorriso`, `squashfs-tools` |
| Publishing to a mirror | `ssh`/`scp`, an ed25519 repo key |

`make _check_tools` reports anything missing for the core build.
