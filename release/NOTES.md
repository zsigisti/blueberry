## Blueberry Linux — v0.4.1-beta

A bugfix + branding release on top of v0.4.0-beta.

### Fixes
- **Low-RAM boot panic.** The initramfs had ballooned because it extracted the
  whole glibc package (gconv modules, static libs, glibc tools), so on a 512 MB
  machine it failed to unpack (`Initramfs unpacking failed: write error`) and
  panicked (`libncursesw.so.6: cannot open`). glibc now goes into a build-time
  sysroot and only the runtime libs are bundled — the initramfs is back to ~43 MB
  and boots in 512 MB again, still using the pinned container glibc.

### Branding / identity
- Ships `/etc/os-release` (systemd now greets **"Welcome to Blueberry Linux!"**,
  and `neofetch`/`fastfetch`/`hostnamectl` identify the distro), a branded
  `/etc/motd` login banner, and `/etc/issue` pre-login banners.
- `bpm --version` prints a branded banner; `/etc/default/grub` sets
  `GRUB_DISTRIBUTOR="Blueberry Linux"`.
- New package: **`fastfetch`** (`bpm install fastfetch`) — the system-info tool,
  minimal server build.

### Images

| image | what it is |
|---|---|
| `blueberry-<date>-x86_64.iso` | Installer / rescue ISO (carries the install payload) |
| `blueberry-server-x86_64.iso` | Live systemd Server (CLI) ISO |

Both are hybrid BIOS + UEFI. Write to USB: `dd if=<iso> of=/dev/sdX bs=4M oflag=sync`.
