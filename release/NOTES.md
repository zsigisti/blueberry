## Blueberry Linux — v0.4.0-beta

A rolling, source-built, self-hosted **CLI server** distro. This release is about
the **installer** and **build portability**.

### Installer
- **Choose your root filesystem** — ext4 (default), xfs, or btrfs. All three boot
  without an initramfs fs module.
- **Optional LVM root** — put root on a logical volume (VG `blueberry`, LV `root`);
  combines with LUKS as LVM-on-LUKS.
- **Network stack is a guided choice** — `systemd-networkd` (lightweight, wired
  servers), `NetworkManager` (Wi-Fi / roaming), or `auto` (picks NetworkManager
  when the machine has a Wi-Fi card, else networkd). Every installer question now
  carries an inline explanation. Also settable unattended via `BLUEBERRY_NET`.

### Build & packaging
- **Build from any Linux host.** glibc is now a pinned artifact fetched from the
  mirror (like the kernel) and bundled from there — never the build host's libc.
  Building on a host with an older glibc than the Arch build container (e.g.
  Ubuntu 24.04) no longer produces an image that panics at boot.
- **Daemon packages ship systemd units.** `nginx`, `redis`, `chrony`, `dcron`
  (cron!), and `dhcpcd` now install a `/usr/lib/systemd/system/*.service`
  (shipped, not auto-enabled) — `systemctl enable <svc>` just works.
- Dependency-closure fixes: `grub` and `krb5` no longer declare runtime deps on
  unpackaged libraries.

### Images

| image | what it is |
|---|---|
| `blueberry-<date>-x86_64.iso` | Installer / rescue ISO (carries the install payload) |
| `blueberry-server-x86_64.iso` | Live systemd Server (CLI) ISO |

Both are hybrid BIOS + UEFI and boot into the installer. Write to USB:
`dd if=<iso> of=/dev/sdX bs=4M oflag=sync`.

This is a **beta** — expect rough edges and report what you find.
