<div align="center">

# 🫐 Blueberry Linux

**A self-hosted Linux distribution built entirely from source — one monorepo, two editions.**

`git clone` → `make world` → `make run` boots a live system from RAM.
No upstream binary mirrors. Every package is built from source in `packages/`,
hosted on our own signed repository, and installed by a native Rust package
manager.

[Server (rolling CLI)](#-blueberry-server) ·
[Desktop (stable GUI)](#-blueberry-desktop) ·
[Packages & mirror](#-packages--the-mirror) ·
[Documentation](#-documentation)

</div>

---

## Two editions, one source tree

Blueberry ships from a single repository the way Fedora builds Workstation and
its spins from one tree. You pick the edition; the base — kernel, glibc, the
`bpm` package manager, the build system — is shared.

| | **🖥️ Blueberry Server** | **🪟 Blueberry Desktop** |
|---|---|---|
| **Audience** | Servers, headless boxes, builders | Workstations, laptops, daily drivers |
| **Interface** | Live CLI (busybox + bash) | KDE Plasma 6 (default) · GNOME (optional) |
| **Init** | systemd (default) · runit (`INIT=runit`) | systemd |
| **Release model** | **Rolling** — always latest | **Stable releases** — `YY.04` / `YY.10`, Ubuntu-style |
| **Kernel** | **Rolling** `linux` package — `bpm upgrade` moves it forward | **Pinned per release** — *not* a rolling package; a new kernel arrives with the next release |
| **Install** | `blueberry-install` (guided CLI) | **Live Calamares ISO** — boot, try, install |
| **Cadence** | Continuous | Two/year · April of even years is **LTS** (24 mo) |

> **Why the kernel differs.** On **Server**, the kernel is just another `bpm`
> package and rolls forward continuously — you always run the newest tested
> kernel. On **Desktop** we deliberately **do not ship the kernel as a rolling
> package**: each stable release pins one kernel + driver stack, validated for
> the life of that release, exactly like Ubuntu. You get a newer kernel by
> **upgrading to the next release** — userspace and apps still update from the
> rolling repo, but the kernel stays a stable, known-good anchor so a routine
> `bpm upgrade` can never break your graphics or boot.

---

## The philosophy: self-hosted, from source

Blueberry depends on **no third-party binary mirror** at runtime. There is no
Arch mirror, no Debian pool, no Flathub requirement.

- **Every package is a recipe in [`packages/`](packages/)** built from upstream
  source (or, for closed apps, the official vendor binary — see below).
- **One signed mirror.** Artifacts are published to
  `https://repo.mmzsigmond.me/`, indexed, and the index is **ed25519-signed**.
- **Verified installs.** `bpm` checks every package against a SHA-256 in the
  signed index, fetched over TLS, before it touches your disk.
- **Reproducible.** Builds run in an ephemeral container with a fixed
  `SOURCE_DATE_EPOCH`, so the same recipe yields the same bytes.

The toolchain (gcc, binutils), the graphics stack (Mesa, LLVM, Wayland), all of
Qt 6 and KDE Plasma 6, the GTK stack — **~280 packages and counting** — were
each compiled from source into this repo. The only exceptions are
closed-source desktop apps (Steam, Spotify, Brave), which are packaged by
wrapping the **vendor's own official binary** and hosting it on our mirror — the
standard, only-possible approach for non-free software.

---

## 🖥️ Blueberry Server

A minimal, rolling CLI system in the BSD tradition: clone the tree, build a
world, boot it from RAM.

```sh
git clone https://github.com/zsigisti/blueberry.git
cd blueberry
make _check_tools     # verify compiler, curl, zstd, cpio, qemu
make world            # kernel + busybox + runit + dropbear + initramfs
make run              # boot the live CLI in QEMU (Ctrl-A X to quit)
make test             # headless boot self-test (used by CI)
```

`make run` boots straight into an interactive shell — no disk image, no install
step, no network required. It brings up DHCP on every NIC and starts SSH
(Dropbear) and time sync.

**Install to disk:** boot the ISO (`make iso`) and run `blueberry-install` — a
guided GPT/UEFI installer that partitions (EFI + root), formats (FAT + ext4),
extracts the rootfs, installs GRUB, writes `fstab`, and sets the root password.
Unattended installs work via the `bbinstall` kernel cmdline.

| Component | Choice | Why |
|-----------|--------|-----|
| C library | **glibc** | Binary compatibility with prebuilt glibc software |
| Core utils | **busybox 1.36** | One binary, 300+ applets, standalone `/bin/sh` |
| Shell | **bash 5.2** | Default interactive shell on installs |
| Init | **systemd** (default) · runit (`INIT=runit`) | journald/logind/networkd; runit for RAM-first builds |
| SSH | **Dropbear** | Tiny static SSH server + client |
| Kernel | **Linux 7.0** | SATA/NVMe/USB, NICs, UEFI, serial console |

---

## 🪟 Blueberry Desktop

A polished, user-oriented GUI edition with **Ubuntu-style stable releases** and
a **live Calamares installer**. KDE Plasma 6 is the default; GNOME is a
documented alternative. It lives in [`editions/desktop/`](editions/desktop/) —
same base, same `bpm`, same mirror.

### The install experience

1. **Boot the live ISO.** systemd reaches `graphical.target` and SDDM shows the
   KDE Plasma (Wayland) greeter — log in as `live` (no password) — running from
   a squashfs+overlay root, the real desktop, not a stripped installer shell.
2. **Try it.** Browse the web, open Dolphin, poke around — nothing is written to
   disk yet.
3. **Install Blueberry Desktop.** A welcome icon launches **Calamares**: a
   guided, branded flow — language → location → keyboard → partition (with a
   manual KDE-Partition-Manager backend via `kpmcore`) → user account →
   summary → install, with a slideshow while it copies.
4. **Reboot into your system.** GRUB → pinned kernel → systemd → SDDM → Plasma.

### Release model

| Field | Rule |
|-------|------|
| Version | `YY.MM` — `.04` (April) and `.10` (October), two per year |
| LTS | The **April** release of every **even** year (e.g. **26.04 LTS**) |
| Support | LTS: **24 months** · standard: **9 months** |
| Codename | Alliterative *adjective + berry* (e.g. *Bright Bilberry*) |
| Kernel | **Pinned** into the release image; updated only on release upgrade |

```sh
make desktop-info                  # resolve the KDE edition (no build)
make desktop-pkgs                  # build the self-hosted package closure
make desktop-iso                   # assemble the live Calamares ISO
make desktop-iso DE=gnome          # the GNOME spin
make desktop-version BBD_VERSION=26.04   # → "26.04 LTS (Bright Bilberry)"
```

### What's in the box

- **Desktop:** KDE Plasma 6.7 — KWin (Wayland), plasma-workspace, panel,
  notifications, system settings, network & audio applets, power management,
  Breeze theme, SDDM login.
- **KDE apps:** Dolphin (files), Konsole (terminal), Kate (editor), Ark
  (archives), Okular (documents), Gwenview (images).
- **Browsers:** Firefox, Brave.
- **Creative:** GIMP, Blender.
- **Gaming & media:** Steam, Spotify.
- **Toolkits for everything else:** the full Qt 6.11 and GTK 3 runtime stacks,
  so third-party apps just work.

---

## 📦 Packages & the mirror

```sh
bpm update                 # refresh the signed index
bpm install firefox        # verified, TLS, SHA-256 checked
bpm search plasma
bpm upgrade                # roll userspace forward (kernel too, on Server)
```

- **Recipes:** [`packages/`](packages/) — declarative `bpm.toml` (native `.bpm`;
  legacy `PKGBUILD` still supported), one dir per package.
- **Mirror:** `https://repo.mmzsigmond.me/` — ~280 packages, ed25519-signed index.
- **Host your own:** `tools/mkrepo.sh`, `tools/blueberry-repo-sync.sh`, or the
  one-command `tools/blueberry-build-server.sh` (see [doc/BPM.md](doc/BPM.md)).

Build any package from source into the mirror:

```sh
ENGINE=podman tools/build-pkgs.sh <out-dir> firefox kate kwin
```

---

## 🗂️ Source tree

```
GNUmakefile          Top-level: make world / run / test / iso / desktop-*
Make.config          Tunables (arch, versions, jobs)

src/
  kernel/            Linux config, patches, Makefile
  busybox/           busybox config (dynamic glibc)
  init/              runit stage scripts + services (disk-boot path)
  systemd/           systemd integration (INIT=systemd; Desktop default)
  dropbear/          Dropbear SSH build rules
  initramfs/         /init — live-CLI, selftest, and blueberry.live= squashfs boot
  bpm-rs/            bpm — native package manager (Rust)
  installer/         blueberry-install — guided CLI disk installer (C)

packages/            ~280 bpm recipes: toolchain, Qt6, KDE Plasma 6, GTK, apps
editions/desktop/    Blueberry Desktop: release model, Calamares, live overlay
etc/                 /etc skeleton (hostname, fstab, accounts, bpm config)
tools/               Host scripts: qemu.sh, mkiso.sh, mkdesktopiso.sh, mkrepo.sh
doc/                 Documentation
```

---

## 🚀 How it boots

```
firmware ─► vmlinuz ─► initramfs /init (PID 1)
                         │
                         ├─ bbtest cmdline?        ─► self-test, print result, halt
                         ├─ bbinstall cmdline?     ─► unattended blueberry-install, halt
                         ├─ blueberry.live=1?      ─► squashfs+overlay root → switch_root → systemd → SDDM → Plasma   (Desktop live ISO)
                         ├─ root= cmdline?         ─► resolve UUID, mount disk → switch_root → runit/systemd          (installed system)
                         └─ otherwise              ─► interactive login shell                                          (Server live CLI)
```

---

## 📚 Documentation

| Document | Contents |
|----------|----------|
| [editions/desktop/README.md](editions/desktop/README.md) | **Blueberry Desktop** — release cadence, Calamares, live ISO, GNOME spin |
| [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md) | System design, boot sequence, components |
| [doc/BUILD.md](doc/BUILD.md) | Building the OS, prerequisites, all make targets |
| [doc/DEPLOY.md](doc/DEPLOY.md) | Real hardware: ISO, disk image, `dd` |
| [doc/BPM.md](doc/BPM.md) | The `bpm` package manager, repos, mirrors |
| [doc/KERNEL.md](doc/KERNEL.md) | Kernel config, the rolling-vs-pinned model, patch workflow |
| [doc/INIT.md](doc/INIT.md) | The live-CLI init and the runit/systemd disk-boot paths |
| [doc/CI.md](doc/CI.md) | CI: build world + QEMU boot test |
| [doc/WEBSITE.md](doc/WEBSITE.md) | The React site + release automation |
| [doc/CONTRIBUTING.md](doc/CONTRIBUTING.md) | How to contribute recipes and code |
| [doc/SECURITY.md](doc/SECURITY.md) | Kernel & SSH hardening |

---

## License

MIT — see [`LICENSE`](LICENSE). Bundled components keep their own licenses:
Linux kernel (GPL-2.0 + syscall-note), glibc (LGPL-2.1), busybox (GPL-2.0),
runit (BSD-3-Clause), Dropbear (MIT), Qt 6 (LGPL-3.0), KDE Plasma & Frameworks
(GPL/LGPL). Repackaged closed apps remain under their vendors' terms.
