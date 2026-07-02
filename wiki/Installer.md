# The Blueberry Installer

`blueberry-install` is Blueberry's own installer — a single Rust binary with
three front-ends over one engine:

| Front-end | When | How |
|---|---|---|
| **TUI** (default) | Booting any installer ISO (`bbtui` menu entry) | Full-screen form: disk, bootloader, keyboard, users, swap, LUKS — with a Help panel and a summary confirm |
| **CLI** | `blueberry-install --cli` from the rescue shell | dialoguer prompts, serial-safe |
| **Unattended** | Kernel cmdline / CI | `bbinstall blueberry.target=/dev/sda blueberry.rootpw=… blueberry.keymap=hu …` — prints `BLUEBERRY_INSTALL=OK` and powers off |

## What it does

GPT partitioning (BIOS boot part or 512M ESP) → optional **LUKS2** → ext4 →
payload extraction (offline) or **`bpm` netinstall** from the signed repo
(online) → GRUB (i386-pc or x86_64-efi, firmware auto-detected) → fstab,
hostname, machine-id → passwords written directly to `/etc/shadow` (SHA-512) →
user in `wheel/video/audio/render/input` → keyboard layout persisted for
console (`vconsole.conf`), Wayland/KDE (`kxkbrc`, localed) and X11.

## Keymaps

Selecting a layout in the TUI runs `loadkeys` **immediately** — what you type
next (passwords!) already matches. Shipped layouts: us hu de fr uk es it pl cz
ro (the `kbd` package carries the full database).

## Images

| Image | Contents |
|---|---|
| `blueberry-<date>-x86_64.iso` | Server: CLI base payload |
| `blueberry-desktop-<ver>-kde-x86_64.iso` | Desktop **offline**: full KDE payload, no network needed |
| `blueberry-desktop-<ver>-kde-netinstall-x86_64.iso` | Desktop **netinstall**: base payload + manifest, fetches KDE via `bpm` |

Write to USB with `dd if=<iso> of=/dev/sdX bs=4M oflag=sync` (the **whole
device**, not a partition). All images boot BIOS and UEFI and land in the TUI.

## Networking & firewall (installed systems)

- **NetworkManager** ships in both editions: `nmtui` (friendly TUI), `nmcli`,
  and the Plasma applet on the desktop. WPA/WPA2/WPA3 via wpa_supplicant with
  the **full linux-firmware** set — wifi works out of the box.
  `systemctl enable --now NetworkManager`, then `nmtui`.
- **ufw**: `ufw enable`, `ufw allow ssh`, etc. (iptables backend; kernel ships
  netfilter/nf_tables).
