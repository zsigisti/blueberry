# Blueberry Desktop

A GUI, user-oriented Linux **edition** built on the Blueberry base — the same
self-hosted kernel, glibc, systemd, and `bpm` package manager as the CLI distro,
with a graphical stack, Ubuntu-style stable releases, and a live **the Blueberry installer**
installer. It lives in-monorepo (no separate fork repo): one source of truth,
the way Fedora ships Workstation and KDE spins from a single tree.

- **KDE Plasma 6** is the **default** experience.
- **GNOME** is the documented alternative (`DE=gnome`).
- The installer is a **live ISO**: boot it, try the desktop, then install.

## Release model (Ubuntu-style)

| Field        | Rule                                                          |
|--------------|--------------------------------------------------------------|
| Version      | `YY.MM` — `.04` (April) and `.10` (October), two per year     |
| LTS          | The **April** release of every **even** year (e.g. 26.04 LTS) |
| Support      | LTS: **24 months** · standard: **9 months**                  |
| Codename     | Alliterative *adjective + berry* (see `codenames`)            |

Computed in `release.mk` (override any `BBD_*` to pin a build):

```
$ make desktop-version
Blueberry Desktop 26.10 (Crisp Cranberry)
  channel : stable   support: 9 months

$ make desktop-version BBD_VERSION=26.04
Blueberry Desktop 26.04 LTS (Bright Bilberry)
  channel : lts   support: 24 months
```

## Layout

```
editions/desktop/
├── release.mk          # version/LTS/codename derivation
├── codenames           # version → codename roll
├── profile.mk          # DE selection, package closure, make targets
├── packages/
│   ├── common.list     # graphical base (Wayland, Mesa, SDDM, PipeWire, …)
│   ├── kde.list        # KDE Plasma 6 spin (default)
│   └── gnome.list      # GNOME spin (optional)
├── calamares/          # installer sequence, modules, Blueberry branding
└── live/               # live-session overlay (autologin, installer launcher)
```

The ISO builder is `tools/mkdesktopiso.sh`; the live-boot path is in
`src/initramfs/init` (`blueberry.live=1`).

## Building

```bash
# Inspect the resolved edition (no build):
make desktop-info                 # KDE
make desktop-info DE=gnome        # GNOME

# Build the desktop package closure (self-hosted, from packages/<name>):
make desktop-pkgs                 # or: make desktop-pkgs DE=gnome

# Build a live, installable ISO (implies INIT=systemd):
make desktop-iso                  # KDE Plasma, current release
make desktop-iso DE=gnome
make desktop-iso BBD_VERSION=26.04 BBD_CODENAME="Bright Bilberry"
```

`desktop-iso` boots in QEMU with, e.g.:

```bash
qemu-system-x86_64 -cdrom iso/blueberry-desktop-26.10-kde-x86_64.iso \
    -m 4096 -enable-kvm -vga virtio
```

## Status & roadmap

The **framework is complete and wired in**: release cadence, DE selection,
the Blueberry installer config + branding, the live-boot initramfs path, and the ISO builder
all work today. What remains is **populating the self-hosted DE package tree** —
the manifests in `packages/` are the build roadmap, and each entry needs a
`packages/<name>/PKGBUILD` before `desktop-iso` can bundle it.

Per the project's no-upstream-mirrors rule, the graphical stack is built from
source into `packages/` like everything else. Bring-up order:

1. **Graphics base** — `wayland`, `libdrm`, `mesa`, `libglvnd`, `xorg-xwayland`.
2. **Session plumbing** — `pam`, `polkit`, `pipewire`, `wireplumber`,
   `xdg-desktop-portal`, `sddm`, `networkmanager`.
3. **Qt 6** → **KDE Frameworks 6** → **Plasma** (the default spin first).
4. **the Blueberry installer** (Qt/KPMcore based) — the installer binary itself.
5. **GNOME** stack (`glib2` → `gtk4`/`libadwaita` → `mutter`/`gnome-shell`).

`mkdesktopiso.sh` refuses to label a DM-less image "desktop" (set `FORCE=1` to
build the scaffolding-only ISO for testing the live/installer plumbing).
