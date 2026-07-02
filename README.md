Blueberry Linux
===============

Blueberry is a self-hosted Linux distribution built entirely from source.
One source tree produces two editions: a rolling CLI **Server** and a
KDE Plasma **Desktop** with stable releases. There are no upstream binary
mirrors — every package is a recipe in `packages/`, built from source and
served from the project's own signed repository by `bpm`, the native
package manager.

What you find here
------------------

    packages/     package recipes (bpm.toml, one directory per package)
    src/          the base system: kernel config, initramfs, installer, bpm
    editions/     desktop edition (package sets, system configuration)
    tools/        build, image and repository tooling
    doc/          documentation
    wiki/         the user wiki

Documentation
-------------

Start with `doc/BUILD.md`. In short:

  - `doc/BUILD.md`         building the world and the images
  - `doc/EDITIONS.md`      the two editions in detail
  - `doc/ARCHITECTURE.md`  how the system fits together
  - `doc/BPM.md`           the package manager and package format
  - `doc/KERNEL.md`        the pinned-kernel model
  - `doc/CONTRIBUTING.md`  patches, style, workflow
  - `wiki/`                user-facing guides (installing, networking, mirrors)

Installing
----------

Download an installer ISO from the Releases page and write it to a USB
stick with `dd` (to the whole device, not a partition):

    dd if=blueberry-<...>.iso of=/dev/sdX bs=4M oflag=sync

Booting it lands in the installer. Server, desktop (offline) and desktop
netinstall images are provided; all boot BIOS and UEFI.

Building
--------

    make world          build the base system
    make run            boot it in QEMU, from RAM
    make iso            server installer ISO
    make desktop-iso    desktop installer ISO (offline)

See `doc/BUILD.md` for requirements and the full target list.

Releases
--------

Releases are cut from this repository; images are published as release
assets. Current releases are **beta** — expect rough edges and report
what you find.

License
-------

MIT — see `LICENSE`. Bundled components keep their own licenses (Linux
kernel GPL-2.0 + syscall-note, glibc LGPL-2.1, busybox GPL-2.0, …).
