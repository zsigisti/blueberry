# Deploying Blueberry on Real Hardware

Blueberry boots as a **live CLI**: the kernel loads an initramfs that runs
straight into a busybox shell from RAM. "Installing" it means putting that
kernel + initramfs onto bootable media. There are two products, both built
from `make world`:

| Target | Command | Media | Boot |
|--------|---------|-------|------|
| ISO | `make iso` | CD/DVD or `dd`'d USB | hybrid BIOS + UEFI |
| Disk image | `make disk` | `dd`'d to an internal disk or USB | UEFI (GPT) |

Both boot the *same* live CLI you get from `make run`.

---

## Option A — Bootable ISO (BIOS or UEFI)

```sh
make iso        # -> iso/blueberry-YYYYMMDD-x86_64.iso
```

Boot it in a VM:

```sh
qemu-system-x86_64 -cdrom iso/blueberry-*.iso -m 512M -nographic
```

Write it to a USB stick and boot any x86_64 machine (legacy BIOS or UEFI):

```sh
dd if=iso/blueberry-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

The ISO is built with `grub-mkrescue`, so a single image works on both legacy
BIOS (El Torito + embedded MBR) and UEFI (embedded EFI System Partition). GRUB
auto-boots after a 3–5 s countdown on both the physical monitor (`tty0`) and a
serial/IPMI console (`ttyS0`, 115200 8N1).

---

## Option B — Disk image (UEFI)

```sh
make disk       # -> disk/blueberry-YYYYMMDD-x86_64.img
```

This is a GPT raw image with two partitions:

| # | Type | FS | Purpose |
|---|------|----|---------|
| 1 | EFI System | FAT32 | GRUB (UEFI) + `vmlinuz` + `initramfs.cpio.zst` |
| 2 | Linux | ext4, label `blueberry-data` | persistent storage for you to use |

Deploy it to the target machine's disk (or a USB drive):

```sh
dd if=disk/blueberry-*.img of=/dev/sdX bs=4M status=progress oflag=sync
```

Boot it in a VM with UEFI firmware:

```sh
qemu-system-x86_64 -drive file=disk/blueberry-*.img,format=raw,if=virtio \
    -bios /usr/share/edk2/x64/OVMF.4m.fd -m 512M -nographic
```

The image is built **without root or loop devices** (`sgdisk`, `mkfs.ext4 -d`,
`mtools`, `dd`), so it works in any unprivileged environment and in CI.

---

## Console behaviour

Both products pass `console=tty0 console=ttyS0,115200` and set
`gfxpayload=text` in GRUB. That means:

- **Physical monitor** → output on `tty0` in VGA text mode. (The kernel has no
  framebuffer driver — server profile — so a graphics console is intentionally
  avoided; text mode keeps the monitor working.)
- **Headless / IPMI / serial** → output on `ttyS0`.

`/init` spawns an interactive root shell on **every** active console (the VGA
`tty1` *and* `ttyS0`), so you get a prompt whether you're at the machine's
monitor or on a serial/IPMI console — not just on `/dev/console`.

---

## Hardware support baked into the kernel

The kernel is built for real bare metal, not just VMs:

- **Storage:** AHCI/SATA, SCSI, NVMe, USB mass storage (UAS), virtio-blk.
- **NICs:** e1000/e1000e, igb, ixgbe, mlx4/mlx5, vmxnet3, virtio-net.
- **Firmware loading** (`CONFIG_FW_LOADER`) for devices that need
  `/lib/firmware` blobs — drop blobs into the rootfs and rebuild the initramfs
  if your NIC needs them.
- **USB:** xHCI/EHCI/OHCI + HID, so USB keyboards and install media work.
- **UEFI + GPT** (`EFI_STUB`, `EFI_PARTITION`) and FAT for the ESP.

---

## Persistence

The live CLI runs from RAM, so by default nothing you do survives a reboot.
The disk image's second partition (`blueberry-data`, ext4) is there for you to
mount and use for persistent files:

```sh
mkdir -p /mnt/data
mount LABEL=blueberry-data /mnt/data
```

Wiring that mount (or an `/etc` overlay) into boot automatically is a future
enhancement; for now mount it by hand or from a startup script.

---

## Networking & SSH

`/init` brings up loopback and runs DHCP (`udhcpc`) on every Ethernet NIC at
boot, and starts the **Dropbear** SSH server on port 22 (host keys are
generated on first use into `/etc/dropbear`).

The image ships with a **default root password: `blueberry`** (in
`/etc/shadow`). Log in with:

```sh
ssh root@<the-box-ip>          # password: blueberry
```

> **Change this before any real deployment.** Set a new password with
> `passwd` (interactive) or replace `/etc/shadow`, and/or drop your key in
> `/root/.ssh/authorized_keys` and disable password auth.

Under `make run` the guest's SSH is forwarded to the host:

```sh
ssh -p 2222 root@localhost     # password: blueberry
```

## What this is *not* (yet)

- No partitioning installer that runs *on* the target and carves up an existing
  disk — you `dd` a prebuilt image instead.
- The live CLI runs from RAM, so SSH host keys and any password change are
  ephemeral unless you persist them on the data partition.
