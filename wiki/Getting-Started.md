# Getting Started

There are three ways to meet Blueberry, in increasing order of commitment.

## 1. Boot it from RAM (no install)

The fastest taste of the Server edition. You need a Linux host with a C
compiler, `curl`, `zstd`, `cpio`, and `qemu`.

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

## 2. Boot a full edition ISO

Both editions build a live ISO and have one-command **run** (QEMU window) and
**test** (headless pass/fail) targets:

```sh
make server-iso   && make run-server      # systemd Server CLI
make desktop-iso  && make run-desktop      # KDE Plasma Desktop
```

The Server ISO boots **systemd** to a multi-user login (autologin root):

![Blueberry Server — systemd live CLI](images/server-console.png)

The Desktop ISO boots into the **KDE Plasma (Wayland) greeter** — log in as
`live` (no password):

![Blueberry Desktop — SDDM greeter](images/desktop-greeter.png)

> **QEMU note:** software rendering (llvmpipe) needs AVX, so the desktop must be
> booted with **`-cpu host`** — `make run-desktop` does this for you. A bare
> `qemu … -cpu qemu64` shows a black screen.

To install the Desktop with the Blueberry installer, see
[Installing Blueberry Desktop](../desktop/Installing-Blueberry-Desktop); to install the
Server to disk, see [Installing Blueberry Server](Installing-Blueberry-Server).

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
