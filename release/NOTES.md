## Blueberry Linux v0.1.1-beta

Second beta. Fixes and verification since v0.1.0-beta:

- **Console/serial login fixed** — `agetty` couldn't exec `/bin/login`
  (merged-usr gap) and `login(1)` had no `/etc/login.defs`; both fixed. TTY
  and serial login now work (graphical SDDM login already did).
- **WiFi verified working** — NetworkManager (`nmcli` 1.50, `nmtui`),
  `wpa_supplicant` 2.11 and the full `linux-firmware` set. Tested live: NM
  starts, manages and connects an interface.
- **Firewall (ufw) working** — kernel gained the legacy netfilter/iptables
  tables (`NETFILTER_XTABLES_LEGACY`); `ufw enable` now installs and enforces
  rules. Tested live: default-deny incoming with an allow rule active.

Images (BIOS + UEFI, all boot into the TUI installer):

| image | what it is |
|---|---|
| `blueberry-20260702-x86_64.iso` | Server (rolling CLI) |
| `blueberry-desktop-26.10-kde-x86_64.iso` | Desktop, offline install |
| `blueberry-desktop-26.10-kde-netinstall-x86_64.iso` | Desktop, netinstall |

Write to USB: `dd if=<iso> of=/dev/sdX bs=4M oflag=sync`. Still beta.
