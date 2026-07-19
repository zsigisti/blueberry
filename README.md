<p align="center">
  <img src="assets/banner.png" alt="Blueberry Linux" width="620">
</p>

<h1 align="center">Blueberry Linux</h1>

<p align="center">
  A self-hosted, source-built, rolling <strong>CLI server</strong> distribution — minimal, in the BSD tradition.
</p>

<p align="center">
  <a href="https://blueberrylinux.org">Website</a> ·
  <a href="https://repo.blueberrylinux.org">Repository</a> ·
  <a href="https://bur.blueberrylinux.org">BUR</a> ·
  <a href="../../releases">Releases</a>
</p>

---

A single source tree produces the base — a **6.18 LTS** (hardened) kernel, glibc,
the `bpm` package manager, and the build system — and every package is a recipe
in `packages/`, built from source and served from the project's own **signed**
repository at [repo.blueberrylinux.org](https://repo.blueberrylinux.org). There
are no upstream binary mirrors. The whole base is bpm-tracked, so `bpm upgrade`
keeps an installed system patched in place.

## What you find here

```
packages/     package recipes (bpm.toml, one directory per package)
src/          the base system: kernel config, initramfs, installer, bpm
tools/        build, image and repository tooling (pkg/ kernel/ image/ test/ …)
doc/          documentation
wiki/         the user wiki
assets/       branding (logo, banner, wallpaper)
```

## Documentation

Start with `doc/BUILD.md`. In short:

- `doc/BUILD.md` — building the world and the ISO
- `doc/ARCHITECTURE.md` — how the system fits together
- `doc/BPM.md` — the package manager and package format
- `doc/KERNEL.md` — the LTS pinned-kernel model
- `doc/CI.md` — the CI gate and how releases are cut
- `doc/ROADMAP.md` — what's solid, what's open, what's out of scope
- `wiki/` — user-facing guides (installing, networking, mirrors)

## Status

Beta, and usable: a bootable systemd server, ~190 source-built packages, a
signed-repo package manager (`bpm`) with rollback, an installer, a web console,
and a community recipe repo (BUR). Every push runs a CI gate (recipe closure,
bpm unit + lifecycle tests, `.bpm` tamper detection, an advisory freshness
report). Known-open items — Secure Boot, aarch64, BUR server-side rebuilds — and
the full picture are in [`doc/ROADMAP.md`](doc/ROADMAP.md).

## Installing

Download the installer ISO from the [Releases](../../releases) page and write it
to a USB stick with `dd` (to the whole device, not a partition):

```sh
dd if=blueberry-<...>.iso of=/dev/sdX bs=4M oflag=sync
```

Booting it lands in the TUI installer (BIOS and UEFI). It installs a rolling CLI
server: systemd, OpenSSH, systemd-networkd (wpa_supplicant for wifi), ufw, and a full
GNU userland.

## Building

```sh
make world          # build the base system
make run            # boot it in QEMU, from RAM
make iso            # build the installer ISO
make install        # install the built world into DESTDIR
```

See `doc/BUILD.md` for requirements and the full target list.

## Community packages — BUR

Beyond the curated base repo, the **Blueberry User Repository**
([bur.blueberrylinux.org](https://bur.blueberrylinux.org)) is the community
recipe site: anyone can submit a `bpm.toml`, get it reviewed, and publish it so
others can `bpm install` it. Its mirror is `repo1.blueberrylinux.org`.

## Releases

Releases are cut from this repository; the ISOs are attached directly as release
assets. Current releases are **beta** — expect rough edges and report what you
find.

## License

GPL-3.0-or-later — see `LICENSE`. Bundled components keep their own licenses
(Linux kernel GPL-2.0 + syscall-note, glibc LGPL-2.1, busybox GPL-2.0, …).

## Discord 

Our developers use discord every day, so please join it if you want to contribute, 
or if you just want to be updated about Blueberry Linux.

[Discord](https://discord.gg/GPfBnbDPHE)