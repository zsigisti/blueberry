# Overview

Blueberry Linux is a Linux distribution with an unusual property: **the whole
operating system, and every package in it, is built from source out of a single
git repository** — and shipped from a mirror that depends on no other distro.

## The shape of the project

```
blueberry/                 ← one git repo
├── src/                   ← the OS itself (kernel, init, bpm, installer)
├── packages/              ← ~280 from-source package recipes
├── editions/desktop/      ← Blueberry Desktop (release model, Calamares, live ISO)
├── tools/                 ← build & publish scripts
└── doc/ + wiki/           ← documentation
```

`make world` builds a bootable system. `tools/build-pkgs.sh` builds any package
from `packages/` into a `.pkg.tar.zst`. `tools/mkrepo.sh` indexes and signs a
mirror. That is the entire supply chain, and you own all of it.

## Two editions

| | Server | Desktop |
|---|---|---|
| Interface | Live CLI (busybox + bash) | KDE Plasma 6 (default) / GNOME |
| Init | runit or systemd | systemd |
| Releases | Rolling | Stable: `YY.04`/`YY.10`, LTS every even April |
| Kernel | Rolling `bpm` package | **Pinned per release** |
| Installer | `blueberry-install` (CLI) | Calamares (live ISO) |

They are not two repos or two forks — they are one tree with an edition overlay
in [`editions/desktop/`](../editions/desktop). See [Desktop Edition](Desktop-Edition).

## The package manager: bpm

`bpm` is a native package manager written in Rust. It installs `.pkg.tar.zst`
packages from an HTTP(S) repo, streaming and verifying each one:

- the repo **index is ed25519-signed** (`bpm.index.sig`), verified against a
  public key baked into the `bpm` binary;
- each package is checked against a **SHA-256** recorded in that signed index;
- everything is fetched over **TLS**.

See [Package Management](Package-Management).

## What's been built

The mirror carries the full stack, all from source:

- **Toolchain:** gcc, binutils, make, git.
- **Graphics:** Mesa, LLVM, Wayland, the X11/XCB libraries, Vulkan loader.
- **Qt 6.11:** base, declarative, wayland, svg, multimedia, and more.
- **KDE Frameworks 6.27:** ~66 frameworks.
- **KDE Plasma 6.7:** KWin, plasma-workspace, plasma-desktop, SDDM, Breeze, the
  full component set.
- **GTK 3 stack:** cairo, pango, gdk-pixbuf, at-spi2-core, gtk3.
- **Apps:** Dolphin, Konsole, Kate, Ark, Okular, Gwenview, Firefox, Brave,
  GIMP, Blender, Steam, Spotify.

Closed-source apps (Steam, Spotify, Brave) are packaged by wrapping the
**vendor's official binary** — see [Self-Hosting Philosophy](Self-Hosting-Philosophy).

## Where to go next

- New here? → [Getting Started](Getting-Started)
- Want the desktop? → [Installing Blueberry Desktop](Installing-Blueberry-Desktop)
- Curious how it works? → [Architecture](Architecture)
