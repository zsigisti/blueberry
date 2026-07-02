# GNOME Spin

KDE Plasma is Blueberry Desktop's default, but a **GNOME** spin is a documented
alternative built from the same tree.

## Building it

Add `DE=gnome` to any desktop target:

```sh
make desktop-info DE=gnome        # resolve the GNOME edition (no build)
make desktop-pkgs DE=gnome        # build the GNOME package closure
make desktop-iso  DE=gnome        # GNOME live the Blueberry installer ISO
```

The package set comes from
[`editions/desktop/packages/gnome.list`](../../editions/desktop/packages/gnome.list),
layered on the shared
[`common.list`](../../editions/desktop/packages/common.list) graphical base.

## What changes vs KDE

| | KDE (default) | GNOME |
|---|---|---|
| Shell | Plasma 6 (KWin) | GNOME Shell (Mutter) |
| Toolkit | Qt 6 | GTK 4 / libadwaita (on the GTK stack) |
| Display manager | SDDM | GDM (`@@DEFAULT_DM@@`) |
| File manager | Dolphin | Nautilus |
| the Blueberry installer default DM token | `sddm` | `gdm` |

The shared base (Wayland, Mesa, PipeWire, the GTK stack, the Blueberry installer, kpmcore) is
identical; only the desktop-shell layer differs.

## Status

The GNOME package tree is the documented second spin. The KDE Plasma tree is the
one fully built out in the mirror today (see [Desktop Edition](Desktop-Edition));
the GNOME shell layer (Mutter → GNOME Shell → core apps) follows the same
from-source recipe pattern as everything else — see
[Creating Packages](Creating-Packages).

## Same everything else

Release model, kernel pinning, the installer flow, and `bpm` are identical to
the KDE edition — only the desktop environment changes. See
[Release Process](Release-Process) and [The Kernel Model](The-Kernel-Model).
