## Blueberry Linux — v0.5.1-beta

A point release on top of v0.5.0-beta, shipping **bpm 1.9.0** by default.

### Package manager (bpm 1.9.0)
- **Download progress bar** — `bpm install` / `bpm upgrade` now show a live
  pacman-style meter across the parallel downloads: packages done/total, MiB
  done/total, percent, and speed, e.g.

      :: downloading  12/13 pkgs  63.4/63.4 MiB  100%  5.9 MiB/s

- **`bpm` is now self-tracked.** It's registered in its own database
  (`/var/lib/bpm/db/bpm`), so `bpm list` shows it and `bpm upgrade` keeps the
  package manager itself up to date.
- **Removed `bpm owns <path>`** (little-used reverse path lookup); `bpm files
  <name>` still lists a package's files.

### Fixes
- `linux-api-headers` realigned to the running kernel (6.18.38), clearing the
  "not in repo index" warning on `bpm install gcc` and similar.

### Base (unchanged from v0.5.0-beta)
- 6.18 LTS kernel (KSPP-hardened), bpm-tracked base, in-place security updates
  via `bpm upgrade`.

### Images

| image | what it is |
|---|---|
| `blueberry-<date>-x86_64.iso` | Installer / rescue ISO (carries the install payload) |
| `blueberry-server-x86_64.iso` | Live systemd Server (CLI) ISO |

Both are hybrid BIOS + UEFI. Write to USB: `dd if=<iso> of=/dev/sdX bs=4M oflag=sync`.

Already on v0.5.0? Just `bpm update && bpm install bpm` to get 1.9.0 without
reinstalling.
