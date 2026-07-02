## Blueberry Linux v0.2.0-beta — server-only

Blueberry is now a single, focused **CLI server** distribution — the desktop
edition has been removed. One installer image, the TUI installer, BIOS + UEFI.

Installed server ships: systemd, OpenSSH, **NetworkManager (nmcli / nmtui)**
with wifi (full linux-firmware + wpa_supplicant), **ufw** firewall, a complete
**GNU userland** (grep/sed/gawk/findutils/tar/gzip/diff/less/vim/nano/…),
sudo, tzdata, and console keymaps (loadkeys/kbd).

| image | what it is |
|---|---|
| `blueberry-20260702-x86_64.iso` | Blueberry Server installer |

Write to USB: `dd if=<iso> of=/dev/sdX bs=4M oflag=sync` (whole device). Beta.
