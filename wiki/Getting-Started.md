# Getting Started

There are three ways to meet Blueberry, in increasing order of commitment.

## 1. Boot it from RAM (no install)

The fastest taste. You need a Linux host with a C compiler, `curl`, `zstd`,
`cpio`, and `qemu`.

```sh
git clone https://github.com/zsigisti/blueberry.git
cd blueberry
make _check_tools     # verify prerequisites
make world            # build kernel + initramfs + userland (~minutes)
make run              # boot the live CLI in QEMU
```

You land in an interactive shell with networking up. `Ctrl-A X` quits QEMU.
Nothing touches your disk. See [Building From Source](Building-From-Source) for
every make target.

## 2. Boot the Server ISO

```sh
make server-iso   && make run-server      # systemd Server CLI, QEMU window
make test-server                          # …or headless pass/fail (multi-user.target)
```

The Server ISO boots **systemd** to a multi-user login (autologin root), with
`systemctl`, `journalctl`, and OpenSSH available:

![Blueberry Server — systemd live CLI](images/server-console.png)

## 3. Install to disk

Build the installer ISO, write it to a USB stick, boot it, and run the
installer:

```sh
make iso          # installer ISO → iso/blueberry-<date>-x86_64.iso
sudo dd if=iso/blueberry-*-x86_64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Boot it and run `blueberry-install` (or select the TUI installer entry). See
[Installing Blueberry Server](Installing-Blueberry-Server) for the full walk-through.

## After installing

Set up packages on a running system:

```sh
bpm update                  # fetch the signed index
bpm search <term>
bpm install <package>
bpm upgrade                 # apply updates (rolling userspace)
```

See [Package Management](Package-Management). For how kernel updates work, read
[The Kernel Model](The-Kernel-Model).

## Prerequisites cheat-sheet

| Task | Needs |
|------|-------|
| `make world` / `make run` | gcc, make, curl, zstd, cpio, qemu |
| building packages | `podman` (or `docker`) |
| `make iso` / `make server-iso` | the above + `xorriso` |
| Publishing to a mirror | `ssh`/`scp`, an ed25519 repo key |

`make _check_tools` reports anything missing for the core build.
