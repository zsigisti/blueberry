# Blueberry → systemd migration

Blueberry historically booted a custom busybox `/init` (live, from initramfs) and
runit (installed system), with dropbear for SSH. This document tracks the
migration to **systemd as PID 1** — journald, logind, systemd-udevd,
systemd-networkd/resolved, `.service` units, and OpenSSH.

It is deliberately phased; each phase is independently buildable and committed.

## Phase 0 — prerequisites (kernel + deps)
- [ ] Kernel config: `CONFIG_FHANDLE`, `CONFIG_AUTOFS_FS`, `CONFIG_TMPFS_XATTR`,
      `CONFIG_TMPFS_POSIX_ACL`, `CONFIG_SECCOMP`/`SECCOMP_FILTER`,
      `CONFIG_CRYPTO_HMAC`, `CONFIG_CRYPTO_SHA256` (have), `CONFIG_CGROUP_BPF`
      (have), `CONFIG_NET_NS`/`USER_NS` (have), `CONFIG_DMIID`, `CONFIG_EFIVAR_FS`
      (have). systemd needs the unified cgroup v2 hierarchy (default at runtime).
- [ ] Package **dbus** (system bus; systemd + many services need libdbus / the bus).
- [ ] Package **util-linux** — libmount/libblkid/libsmartcols/libfdisk + agetty,
      mount, login, etc. Resolve the libuuid/libblkid overlap with e2fsprogs
      (util-linux becomes the canonical provider; e2fsprogs built `--without-libuuid
      --without-libblkid` or kept for fsck only).
- [ ] Package **shadow** (useradd/passwd/login/su) — replaces busybox applets for a
      multiuser systemd system.
- [ ] Package **systemd** (meson build) with a Blueberry preset: enable
      journald/logind/udevd/networkd/resolved/timesyncd; disable
      homed/portabled/importd and other heavy extras initially.

## Phase 1 — installed-system init
- [ ] Replace runit (`src/init/*`, `/etc/sv`, `/var/service`) with systemd units.
- [ ] Provide units: getty@tty1, sshd (OpenSSH), systemd-networkd + a default
      `.network`, resolved, timesyncd, journald. Map the existing package service
      files (chrony, redis, nginx, dhcpcd) to `.service` units (or use networkd
      instead of dhcpcd).
- [ ] `/usr`-merge the rootfs layout; create machine-id, presets, default target
      (multi-user.target).

## Phase 2 — initramfs / boot
- [ ] Live image: boot systemd in the initramfs (systemd-in-initrd) or switch the
      live medium to a squashfs root that systemd mounts. Decide live vs installed
      parity.
- [ ] Installer (`blueberry-install.c`): install the systemd rootfs, write
      machine-id, enable default units, set up the ESP + bootloader entry
      (kernel cmdline `init=/usr/lib/systemd/systemd`, `rw`).

## Phase 3 — swap userland defaults
- [ ] OpenSSH replaces dropbear (sshd.service + sshd_config + host-key gen).
- [ ] journald replaces busybox syslogd; `systemctl`, `journalctl`, `loginctl`
      available. Drop the runit `sv`/`sv-enable`/`sv-disable` helpers.

## Phase 4 — verify + docs
- [ ] `make test` self-test updated for a systemd boot (assert `systemctl
      is-system-running`, sshd, networkd lease, journald).
- [ ] Update every doc (README, BUILD, INSTALL, architecture) to systemd.
- [ ] Update the package service files shipped by chrony/redis/nginx/dhcpcd to
      `.service` units.

## Notes / tensions
systemd reverses Blueberry's minimal/runit ethos and pulls in a meaningfully
larger base (dbus, util-linux, systemd). The monolithic, **module-less** kernel
is fine for systemd (udevd simply loads nothing), but cgroup v2 + FHANDLE are
mandatory. Image size will grow notably; that is an accepted consequence of the
"full systemd PID1" decision.
