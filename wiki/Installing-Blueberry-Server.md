# Installing Blueberry Server

Blueberry Server is a minimal, rolling CLI system. It runs **systemd** as PID 1
(journald, logind, networkd, OpenSSH) — `INIT=systemd` is the default. There are
two ISOs: a **live systemd CLI** to try it, and the **installer** ISO.

![Blueberry Server — systemd live CLI (autologin root shell)](images/server-console.png)

## 1. Build or get the ISO

```sh
make server-iso   # systemd live CLI ISO → iso/blueberry-server-x86_64.iso
make run-server   # …or boot it straight in a QEMU window
make test-server  # …or boot headless and assert it reaches multi-user.target

make iso          # the installer/rescue ISO → iso/blueberry-<date>-x86_64.iso
```

The live ISO boots systemd to a `multi-user.target` login (autologin `root`),
with `systemctl`, `journalctl`, and OpenSSH available. Write either to a USB
stick:

```sh
sudo dd if=iso/blueberry-server-x86_64.iso of=/dev/sdX bs=4M status=progress oflag=sync
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

The installed system boots GRUB → kernel → **systemd** (PID 1), with **bash** as
the login shell. (A minimal **runit** build is still available with
`make … INIT=runit` for RAM-first / embedded use.)

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

The systemd Server runs **OpenSSH** (`sshd.service`, host keys generated on
first boot). The RAM-first `INIT=runit` build uses Dropbear instead. Change any
default credentials before exposing a host; hardening notes are in
[doc/SECURITY.md](../doc/SECURITY.md).

## Deploying to real hardware

See [doc/DEPLOY.md](../doc/DEPLOY.md) for ISO, raw disk image, and `dd`
workflows.
