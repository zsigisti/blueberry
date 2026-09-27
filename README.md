<p align="center">
  <img src="assets/banner.png" alt="blueberry linux" width="620">
</p>

<h1 align="center">blueberry linux</h1>

<p align="center">
  small rolling linux distro for servers, built from source
</p>

<p align="center">
  <a href="https://repo.blueberrylinux.org">repo</a> ·
  <a href="https://github.com/zsigisti/blueberry/releases">releases</a> ·
  <a href="https://discord.gg/GPfBnbDPHE">discord</a>
</p>

---

everything in the base gets built out of this repo. kernel (6.18 lts, hardened),
glibc, `bpm` (our package manager), the build scripts. packages are recipes in
`packages/`. we compile them ourselves and sign them, then they go up on
[repo.blueberrylinux.org](https://repo.blueberrylinux.org). none of the
packages are someone else's binaries.

`bpm` knows about the whole base system, not just the stuff you installed on
top. so `bpm upgrade` updates the kernel and glibc too and you never have to
reinstall.

## status

it's beta. it boots, installs and updates fine, but some stuff is still rough.
if something breaks tell us on discord.

what we have right now:

- systemd server + a tui installer (bios and uefi both work)
- around 225 package recipes
- `bpm` with signed repos and rollback
- a web console
- bur, where people can submit their own recipes

ci runs on every push. it checks that recipe deps actually resolve, runs the
`bpm` tests, checks `.bpm` files for tampering, and prints which packages are
behind upstream (that last one doesn't fail the build).

not done yet: secure boot, aarch64, bur rebuilding stuff on the server. more
in [`doc/ROADMAP.md`](doc/ROADMAP.md).

## install

get the iso from [releases](https://github.com/zsigisti/blueberry/releases).
dd it to the usb stick itself, `/dev/sdX` not `/dev/sdX1`:

```sh
dd if=blueberry-<version>.iso of=/dev/sdX bs=4M oflag=sync
```

boot it and the installer comes up. you get systemd, openssh, systemd-networkd,
wpa_supplicant if you need wifi, ufw and the normal gnu tools. no desktop, it's
a server.

## build

```sh
make world      # build the base system
make run        # boot it in qemu, from ram
make iso        # build the installer iso
make install    # install the built world into DESTDIR
```

what you need installed and the other make targets are in
[`doc/BUILD.md`](doc/BUILD.md).

## docs

| file | what's in it |
|------|--------------|
| [`doc/BUILD.md`](doc/BUILD.md) | building everything + the iso, read this first |
| [`doc/ARCHITECTURE.md`](doc/ARCHITECTURE.md) | how it's put together |
| [`doc/BPM.md`](doc/BPM.md) | bpm and the `.bpm` format |
| [`doc/KERNEL.md`](doc/KERNEL.md) | how we pin the lts kernel |
| [`doc/CI.md`](doc/CI.md) | ci and how we do releases |
| [`doc/ROADMAP.md`](doc/ROADMAP.md) | done / todo / not doing |
| [`wiki/`](wiki/) | installing, networking, running a mirror |

## license

gpl-3.0-or-later, see [`LICENSE`](LICENSE). stuff we bundle keeps its own
license (linux is gpl-2.0 with the syscall note, glibc lgpl-2.1, busybox
gpl-2.0, etc).
