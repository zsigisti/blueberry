## Blueberry Linux — beta release

Blueberry Server: a minimal, rolling CLI system. Boots into the TUI installer
(BIOS + UEFI); installs systemd, OpenSSH, NetworkManager (nmcli/nmtui) with
wifi, ufw and a full GNU userland.

| image | what it is |
|---|---|
| `blueberry-<date>-x86_64.iso` | Blueberry Server installer |

Write to a USB stick: `dd if=<iso> of=/dev/sdX bs=4M oflag=sync` (whole device).

This is a **beta**: expect rough edges, report what you find.
