## Blueberry Linux v0.3.0-beta — a real server userland

Blueberry is a self-hosted, source-built **CLI server** distribution. This beta
fills out the server toolkit, adds a bunch of package-manager features, and
cleans house.

### Images (BIOS + UEFI)

| image | what it is |
|---|---|
| `blueberry-<date>-x86_64.iso` | Installer / rescue — boots to the TUI installer or a live shell |
| `blueberry-server-x86_64.iso` | Live systemd Server (CLI), boots straight to a root shell |

Write to USB: `dd if=<iso> of=/dev/sdX bs=4M oflag=sync` (whole device).

### New in the base image

The installed server now has a proper admin userland, not just busybox:
**procps-ng** (ps/top/free/uptime/vmstat/pkill/sysctl), **psmisc**
(killall/pstree/fuser), **lsof**, and a working **`man`** (mandoc + the Linux
man-pages). These are on by default.

### New on the mirror (`bpm install …`)

- **Storage:** `lvm2`, `xfsprogs`, `btrfs-progs`, `smartmontools`.
- **Network:** `bind-tools` (dig/host/nslookup), `socat`, `netcat`,
  `traceroute`, `whois`, `ethtool`.
- **Everyday:** `gnupg`, `xz`, `zstd`, `unzip`, `zip`, `bash-completion`.

### bpm 1.8.0

- `bpm rollback <pkg>` — revert to the previous cached version.
- `bpm downgrade <pkg>[=ver]` — install a specific older cached version.
- `bpm why <pkg>` — reverse dependencies / why it's installed.
- `bpm depends <pkg>` — dependency tree.
- `bpm clean [--all]` — now keeps the 2 newest versions per package (so
  rollback works); `--all` empties the cache.
- Man pages: ships `man bpm`, and re-indexes man pages after each transaction.

### Housekeeping

- Relicensed to **GPL-3.0-or-later** (a proper `LICENSE` file now exists).
- The mirror was pruned of ~287 stale desktop packages left over from the
  server-only pivot.

This is a **beta** — expect rough edges, and report what you find.
