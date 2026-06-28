# The Calamares Installer

Blueberry Desktop uses **Calamares** — a distribution-independent graphical
installer — as the "try then install" tool on the live ISO. This page covers
how it is configured and branded in Blueberry, for users who want to understand
or customize it.

## Where it lives

```
editions/desktop/calamares/
├── settings.conf            # the module sequence (show → exec → install)
├── branding/blueberry/
│   ├── branding.desc        # product name, colors, slideshow
│   └── show.qml             # the install-time slideshow
└── modules/
    ├── welcome.conf         # language, requirements
    ├── partition.conf       # partitioning options & defaults
    ├── users.conf           # account creation rules
    ├── displaymanager.conf  # SDDM as the installed DM
    ├── services-systemd.conf# services to enable on the target
    ├── bootloader.conf      # GRUB (UEFI)
    ├── unpackfs.conf        # squashfs → target
    └── fstab.conf           # fstab generation
```

The package itself is built from [`packages/calamares/`](../packages/calamares)
(Calamares 3.3.14, Qt 6), with `kpmcore` as the partitioning backend
([`packages/kpmcore/`](../packages/kpmcore)).

## The module sequence

Calamares runs three phases, defined in `settings.conf`:

- **show** — interactive pages: `welcome → locale → keyboard → partition →
  users → summary`.
- **exec** — the actual install: `partition → mount → unpackfs → fstab →
  locale → keyboard → users → displaymanager → services-systemd → grubcfg →
  bootloader → umount`.
- **install** — finished page with the reboot option.

## Branding

`branding.desc` sets the product name (*Blueberry Desktop*), the version string
(templated from the release at ISO-build time), the window behaviour, and the
slideshow QML. Tokens like `@@VERSION@@` and `@@DEFAULT_DM@@` are filled in by
`tools/mkdesktopiso.sh` so the same templates work for every release and both
spins.

To customize the look, edit `show.qml` (the slideshow) and the colors in
`branding.desc`, then rebuild the ISO.

## How the live ISO wires it up

`tools/mkdesktopiso.sh`:

1. Clones the staged desktop rootfs and overlays the **live session**
   ([`editions/desktop/live/`](../editions/desktop/live)): an SDDM autologin
   drop-in, a polkit rule letting the live user run the installer without a
   password, and an XDG autostart entry for the **Install Blueberry Desktop**
   launcher.
2. Squashes the rootfs (`zstd`) and templates the Calamares config/branding.
3. Builds a GRUB menu with **Try** and **Install** entries and produces a hybrid
   (BIOS+UEFI) ISO.

The initramfs honours `blueberry.live=1`: it finds the boot medium, mounts the
squashfs as an overlay lower layer with a tmpfs upper, and `switch_root`s into
systemd, which starts SDDM. See [Architecture](Architecture).

## Customizing the install flow

- **Add/remove a page:** edit the `show` list in `settings.conf`.
- **Change partition defaults:** `modules/partition.conf` (default filesystem,
  swap policy, EFI size).
- **Enable extra services on installed systems:** `modules/services-systemd.conf`.
- **Change the default display manager:** the `@@DEFAULT_DM@@` token (SDDM for
  KDE, GDM for the GNOME spin) — set by the edition.

After any change: `make desktop-iso` and re-test in a VM.
