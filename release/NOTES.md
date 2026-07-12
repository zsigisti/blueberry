## Blueberry Linux — v0.7.0-beta

The big one: a first-party **web console** to manage the box from a browser
(including installing it), plus base-image fixes and a **bootable btrfs
snapshot layout**. New ISOs — rebuild/reinstall to pick up the base changes;
the console is install-on-demand from the mirror.

### 🖥️ Blueberry Console — manage (and install) from a browser

```sh
bpm install blueberry-console
systemctl enable --now blueberry-console
# then browse to  https://<host-ip>:9090   (self-signed cert; sign in as root)
```

A small, privileged Rust daemon (HTTPS-native via rustls, no external web
stack) that wraps `systemctl`, `bpm`, `/proc`, btrfs/zfs and the installer
behind an authenticated, audited JSON API + a **pure HTML/JS** frontend (no
CSS/framework/build step). Panels:

- **Overview** — live per-core CPU / memory / load (auto-refreshing), host facts.
- **Services** — list + start/stop/restart (validated unit names).
- **Packages / Logs** — installed packages (bpm), journald with a level filter.
- **Storage** — filesystems + block devices, **ZFS** (pools/datasets/snapshots,
  scrub/snapshot) and **Btrfs** (usage, subvolumes, snapshots; scrub,
  read-only snapshot, subvolume create/delete, snapshot delete, rollback).
- **Network** — interfaces, MACs, addresses, gateway.
- **Updates** — the differentiator: lists upgradable packages (`bpm outdated`)
  and does **snapshot → `bpm upgrade`** in one click (a read-only btrfs
  pre-upgrade snapshot of `/` when the root is btrfs).
- **Install** — drive the unattended installer from the browser: pick disk /
  filesystem / bootloader / passwords → erase + install, with a live log.
  Gated to the live environment, so it can never format an installed box.

**Security:** HTTPS-only (RSA-4096 self-signed, SAN-correct); PAM login
(Proxmox-style) gated to root / the admin group; **bearer-token sessions**
(survive self-signed-cert browsers, CSRF-immune) with a cookie mirror + CSRF
token for cookie-authed writes; per-IP login throttle; 20 s socket timeouts +
connection cap (slow-loris/flood resistant); strict CSP; every write audited.
Went through a self-pen-test — argument-injection, path-traversal, DoS and
auth-bypass classes are all closed.

### 🗄️ Bootable btrfs snapshot layout

Choosing **btrfs** at install time now lays down the standard `@` (root) +
`@home` subvolumes (GRUB boots `/@/boot/…` with `rootflags=subvol=@`), so a
fresh install is snapshot-friendly and `/home` survives a root rollback.
Verified end-to-end (install → boot to multi-user) in CI.

### 🩹 Base image fixes (in the ISOs)

The base is assembled from a flat package list, and a few tools shipped without
their runtime libraries. Fixed and guarded so it can't regress:

- **`grep`, `ss`, `gawk`, `wpa_supplicant` were broken** — added `pcre2`,
  `mpfr`, `gdbm`, `libnl`. New `make check-base` scans every base binary's
  `DT_NEEDED` and fails the build on a missing library.
- **NetworkManager removed** from the base (unused — systemd-networkd is the
  stack; still `bpm install`-able), and **`ufw` fixed** (ships `python` +
  `iptables`; recipe moved off the removed `distutils`).
- The **live ISO** now ships a documented default password (`root` /
  `blueberry`) so ssh / the console work out of the box — change it with
  `passwd`; installed systems set their own via the installer.

### 📦 bpm 1.11.2

- `bpm outdated` — list upgradable packages without applying (powers the
  console Updates panel).
- Cleaner "not found in the repo index" message for unknown packages.

---

**Upgrade:** `bpm update && bpm upgrade` for the base + packages;
`bpm install blueberry-console` for the console. Fresh installs from the new
ISOs get the base fixes and the btrfs option.
