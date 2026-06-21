# Installing Blueberry Server

Blueberry Server installs from a small ISO using **`blueberry-install`**, a
guided CLI installer. (To run it without installing, see
[Getting Started](Getting-Started) — `make run` boots a live CLI from RAM.)

## 1. Build or get the ISO

```sh
make iso          # → ../blueberry-build/blueberry-*.iso
```

Write it to a USB stick:

```sh
sudo dd if=blueberry-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

## 2. Boot and run the installer

Boot the ISO. You land in a live shell with networking up. Run:

```sh
blueberry-install
```

It guides you through a **GPT/UEFI** install:

1. **Select the target disk** (everything on it will be erased).
2. **Partition** — GPT with an EFI system partition + a root partition.
3. **Format** — FAT32 (EFI) + ext4 (root).
4. **Extract** the root filesystem to the target.
5. **Install GRUB** (UEFI).
6. **Write `fstab`**.
7. **Set the root password**.

The installed system boots GRUB → kernel → **runit** (or systemd with
`INIT=systemd`), with **bash** as the login shell.

## 3. Unattended installs

Pass `bbinstall` on the kernel cmdline to run the installer non-interactively
(this is what the QEMU end-to-end test uses). Useful for provisioning.

## 4. First boot

Log in as `root` (the password you set). Set up packages:

```sh
bpm update
bpm install git gcc make        # the toolchain, for example
bpm upgrade                     # rolling: updates userspace AND the kernel
```

On Server, `bpm upgrade` rolls the kernel forward like everything else — see
[The Kernel Model](The-Kernel-Model).

## SSH

The live system starts Dropbear SSH. Default login is `root` / `blueberry` —
**change it** for any real deployment. Hardening notes are in
[doc/SECURITY.md](../doc/SECURITY.md).

## Deploying to real hardware

See [doc/DEPLOY.md](../doc/DEPLOY.md) for ISO, raw disk image, and `dd`
workflows.
