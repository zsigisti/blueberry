# Desktop Edition

Blueberry Desktop is a GUI edition built on the Blueberry base — same kernel,
glibc, systemd, and `bpm` — with a graphical stack, **Ubuntu-style stable
releases**, and a live Calamares installer. It lives in-monorepo at
[`editions/desktop/`](../editions/desktop); there is no separate fork.

- **KDE Plasma 6** is the default experience.
- **GNOME** is the documented alternative (`DE=gnome`) — see [GNOME Spin](GNOME-Spin).
- The installer is a **live ISO**: boot, try, install.

## Layout

```
editions/desktop/
├── release.mk          # version / LTS / codename derivation
├── codenames           # version → codename roll
├── profile.mk          # DE selection, package closure, make targets
├── packages/
│   ├── common.list     # graphical base (Wayland, Mesa, SDDM, PipeWire, …)
│   ├── kde.list        # KDE Plasma 6 spin (default)
│   └── gnome.list      # GNOME spin (optional)
├── calamares/          # installer sequence, modules, Blueberry branding
└── live/               # live-session overlay (autologin, installer launcher)
```

> **No kernel in `common.list`.** The desktop's package lists carry the
> graphical base but **not** the kernel — on Desktop the kernel is pinned into
> the *release image*, not shipped as a rolling package. See
> [The Kernel Model](The-Kernel-Model).

## The stack

Built from source into the mirror:

- **Toolkit:** Qt 6.11 (base, declarative, wayland, svg, multimedia, 5compat,
  shadertools, positioning, …) and the **GTK 3** stack (cairo, pango,
  gdk-pixbuf, at-spi2-core, gtk3).
- **Frameworks:** KDE Frameworks 6.27 (~66).
- **Plasma 6.7:** KWin (Wayland compositor), plasma-workspace, plasma-desktop,
  SDDM, Breeze, kscreen, powerdevil, systemsettings, plasma-nm, plasma-pa,
  polkit-kde-agent, xdg-desktop-portal-kde.
- **Apps:** Dolphin, Konsole, Kate, Ark, Okular, Gwenview; Firefox, Brave; GIMP,
  Blender; Steam, Spotify.

## Building

```sh
make desktop-info                  # KDE
make desktop-info DE=gnome         # GNOME
make desktop-pkgs                  # build the package closure
make desktop-iso                   # live Calamares ISO
```

## Live session

`tools/mkdesktopiso.sh` overlays [`editions/desktop/live/`](../editions/desktop/live)
onto the staged rootfs: SDDM autologin, a polkit rule for the installer, and an
**Install Blueberry Desktop** launcher. The initramfs `blueberry.live=1` path
mounts the squashfs as an overlay and boots into Plasma. Details:
[The Calamares Installer](The-Calamares-Installer), [Architecture](Architecture).

## See also

- [Release Process](Release-Process) — the `YY.MM`/LTS cadence.
- [Installing Blueberry Desktop](Installing-Blueberry-Desktop).
- [editions/desktop/README.md](../editions/desktop/README.md).
