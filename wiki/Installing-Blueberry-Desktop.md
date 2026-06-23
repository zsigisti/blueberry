# Installing Blueberry Desktop

Blueberry Desktop installs from a **live ISO**: you boot into a real KDE Plasma
session, try the system, and then run **Calamares** to install it. Nothing is
written to disk until you finish the installer.

## 1. Get the ISO

Download a release ISO, or build one:

```sh
make desktop-iso                 # KDE Plasma (default)
make desktop-iso DE=gnome        # GNOME spin
# → iso/blueberry-desktop-<version>-kde-x86_64.iso
```

Write it to a USB stick (replace `sdX` with your device):

```sh
sudo dd if=iso/blueberry-desktop-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Or test it in a VM — `make run-desktop` is the easy path:

```sh
make run-desktop
# equivalent to:
qemu-system-x86_64 -enable-kvm -cpu host -m 4G -smp 4 \
  -cdrom iso/blueberry-desktop-*.iso -vga virtio
```

> **`-cpu host` is required.** The live desktop renders with software OpenGL
> (Mesa llvmpipe), which needs AVX; the default `qemu64` CPU lacks it and the
> screen stays black.

## 2. Boot the live session

The ISO boots through GRUB → kernel → initramfs, which mounts the squashfs root
as a read-only lower layer with a tmpfs upper layer (so the live session is
writable but disposable). systemd reaches `graphical.target` and **SDDM shows
the KDE Plasma (Wayland) greeter** — log in as **`live`** (no password).

![Blueberry Desktop — SDDM Breeze greeter](images/desktop-greeter.png)

> **Try before you install.** Wi-Fi, trackpad, display scaling, sound — verify
> them in the live session. What works live will work installed.

## 3. Run Calamares

Double-click **Install Blueberry Desktop** on the desktop (or launch it from the
panel). Calamares walks you through:

1. **Welcome** — language.
2. **Location** — region & timezone (auto-detected where possible).
3. **Keyboard** — layout.
4. **Partitions** — *Erase disk* (guided), *Replace a partition*, or *Manual*
   (a full KDE-Partition-Manager-style editor, backed by `kpmcore`). Supports
   ext4, btrfs, swap, and an EFI system partition on UEFI.
5. **Users** — your name, username, hostname, password, and whether to log in
   automatically.
6. **Summary** — review every change. **Nothing has been written yet.**
7. **Install** — Calamares unpacks the squashfs to the target, installs GRUB,
   writes `fstab`, creates your user, and enables services, with a slideshow
   while it runs.
8. **Finish** — reboot into your installed system.

## 4. First boot

Your installed system boots GRUB → **pinned kernel** → systemd → SDDM → Plasma.
Log in with the account you created.

Update userspace any time:

```sh
bpm update && bpm upgrade
```

Remember: on Desktop, `bpm upgrade` updates apps and userspace but **not the
kernel** — that comes with the next release. See [The Kernel Model](The-Kernel-Model).

## Troubleshooting

- **Black screen after login (live):** try the *nomodeset* GRUB entry, or the
  X11 session from the SDDM session menu.
- **Calamares won't start:** open Konsole and run `sudo calamares -d` to see a
  debug log.
- **No network in Calamares:** connect Wi-Fi from the Plasma system tray first;
  the installer uses the live session's connection.

More in [Troubleshooting](Troubleshooting). Installer internals are in
[The Calamares Installer](The-Calamares-Installer).
