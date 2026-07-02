## Blueberry Linux — beta release

First public beta. Images (BIOS + UEFI, all boot into the TUI installer):

| image | what it is |
|---|---|
| `blueberry-<date>-x86_64.iso` | Server (rolling CLI) |
| `blueberry-desktop-<ver>-kde-x86_64.iso` | Desktop, offline install |
| `blueberry-desktop-<ver>-kde-netinstall-x86_64.iso` | Desktop, netinstall |

Write to a USB stick: `dd if=<iso> of=/dev/sdX bs=4M oflag=sync`

This is a **beta**: expect rough edges, report what you find.
