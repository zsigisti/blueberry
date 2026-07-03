# Overview

Blueberry Linux is a Linux distribution with an unusual property: **the whole
operating system, and every package in it, is built from source out of a single
git repository** — and shipped from a mirror that depends on no other distro.

It is a minimal, rolling **CLI server** system in the BSD tradition: one tree,
one package manager, one signed mirror, and no upstream binary dependencies.

## The shape of the project

```
blueberry/                 ← one git repo
├── src/                   ← the OS itself: kernel, busybox, init/systemd,
│                            initramfs, bpm-rs, installer
├── packages/              ← ~130 from-source package recipes (bpm.toml)
├── tools/                 ← build & publish scripts
└── doc/ + wiki/           ← documentation
```

`make world` builds a bootable system. `tools/build-bpm-pkg.sh` builds any
package from `packages/` into a `.bpm`. `tools/bpmrepo.sh` indexes and signs a
mirror. That is the entire supply chain, and you own all of it.

## What Blueberry Server is

- **From source, self-hosted.** Every package is a recipe built from upstream
  source. A running system pulls only from the Blueberry mirror — never an Arch,
  Debian, or Ubuntu repo. (An Arch container is used only as the *build*
  toolchain; it is not part of the installed system.)
- **Rolling.** Userspace advances continuously via `bpm upgrade`.
- **systemd by default.** PID 1 is systemd — journald, logind,
  networkd/resolved, NetworkManager, and OpenSSH. A minimal **runit** build
  (`INIT=runit`) is available for RAM-first / embedded use.
- **CLI only.** No X11, no Wayland, no desktop. Just a real GNU/Linux server
  userland: `ps`/`top`/`free`, `ss`/`ip`, `systemctl`/`journalctl`, `ufw`,
  `nmcli`/`nmtui`, editors, and the toolchain.

## The package manager: bpm

`bpm` is a native package manager written in Rust. It installs `.bpm`
packages from an HTTP(S) repo, streaming and verifying each one:

- the repo **index is ed25519-signed** (`bpm.index.sig`), verified against a
  public key baked into the `bpm` binary;
- each package is checked against a **SHA-256** recorded in that signed index;
- everything is fetched over **TLS**.

See [Package Management](Package-Management).

## What's on the mirror

The full server stack, all from source:

- **Toolchain:** gcc, binutils, make, git, python.
- **Base userland:** glibc, coreutils, util-linux, bash, the GNU tools
  (grep/sed/gawk/findutils/tar/gzip), procps-ng, psmisc, lsof, less, vim, nano.
- **Init & services:** systemd, dbus, polkit, OpenSSH, chrony, dcron, logrotate,
  rsync, nginx, redis.
- **Networking:** NetworkManager, wpa_supplicant, iproute2, iputils, dhcpcd,
  wireguard-tools, nftables, iptables, ufw, tcpdump.
- **Storage & crypto:** e2fsprogs, dosfstools, cryptsetup, mdadm,
  device-mapper, openssl, gnutls, krb5.
- **Firmware:** linux-firmware (the full blob set for real hardware).

## Where to go next

- New here? → [Getting Started](Getting-Started)
- Installing to disk? → [Installing Blueberry Server](Installing-Blueberry-Server)
- Curious how it works? → [Architecture](Architecture)
