Blueberry Linux
===============

Blueberry is a self-hosted, source-built Linux distribution: a minimal, rolling
CLI **server** system in the BSD tradition. A single source tree produces the
base (a pinned prebuilt kernel and glibc, the `bpm` package manager, the build
system) and every package is a recipe in `packages/`, built from source and
served from the project's own signed repository. There are no upstream binary
mirrors.

What you find here
------------------

    packages/     package recipes (bpm.toml, one directory per package)
    src/          the base system: kernel config, initramfs, installer, bpm
    tools/        build, image and repository tooling
    doc/          documentation
    wiki/         the user wiki

Documentation
-------------

Start with `doc/BUILD.md`. In short:

  - `doc/BUILD.md`         building the world and the ISO
  - `doc/ARCHITECTURE.md`  how the system fits together
  - `doc/BPM.md`           the package manager and package format
  - `doc/KERNEL.md`        the pinned-kernel model
  - `doc/CONTRIBUTING.md`  patches, style, workflow
  - `wiki/`                user-facing guides (installing, networking, mirrors)

Installing
----------

Download the installer ISO from the Releases page and write it to a USB stick
with `dd` (to the whole device, not a partition):

    dd if=blueberry-<...>.iso of=/dev/sdX bs=4M oflag=sync

Booting it lands in the TUI installer (BIOS and UEFI). It installs a rolling
CLI server: systemd, OpenSSH, NetworkManager (nmcli/nmtui) with wifi, ufw, and
a full GNU userland.

Building
--------

    make world          build the base system
    make run            boot it in QEMU, from RAM
    make iso            build the installer ISO
    make install        install the built world into DESTDIR

See `doc/BUILD.md` for requirements and the full target list.

Releases
--------

Releases are cut from this repository; images are published as release assets.
Current releases are **beta** — expect rough edges and report what you find.

License
-------

GPL-3.0-or-later — see `LICENSE`. Bundled components keep their own licenses
(Linux kernel GPL-2.0 + syscall-note, glibc LGPL-2.1, busybox GPL-2.0, …).
