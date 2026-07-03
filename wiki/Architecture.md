# Architecture

How a Blueberry system is put together, from power-on to login shell.

## Boot sequence

```
firmware ─► GRUB ─► vmlinuz ─► initramfs /init (PID 1)
                                 │
                                 ├─ bbtest cmdline?     ─► run /etc/selftest, print result, halt
                                 ├─ bbinstall cmdline?  ─► unattended blueberry-install, halt
                                 ├─ bbtui cmdline?      ─► interactive TUI installer
                                 ├─ root= cmdline?      ─► resolve UUID, mount disk → switch_root → systemd/runit
                                 └─ otherwise           ─► interactive live login shell
```

`/init` (in [`src/initramfs/`](../../src/initramfs)) is a small script that:

1. mounts `/proc`, `/sys`, `/dev` and populates `/dev`,
2. inspects the kernel cmdline to choose a path,
3. either drops to a live shell, runs the self-test, launches the installer, or
   mounts a disk install and hands off to PID 1.

## Init systems

| | Used by |
|---|---|
| **systemd** | Default — journald, logind, networkd/resolved, NetworkManager, OpenSSH |
| **runit** | Opt-in (`INIT=runit`) — a small supervision tree for RAM-first / minimal builds |

The live initramfs is busybox-based either way; only the **installed** rootfs
(`STAGEDIR`) changes with `INIT`. The runit stage scripts live in
[`init/`](../../init); the systemd units in [`systemd/`](../../systemd). See
[doc/INIT.md](../../doc/INIT.md).

## The installed server

A disk install boots GRUB → kernel → **systemd** (PID 1) with **bash** as the
login shell. The base image carries the systemd runtime closure plus a real
server userland (procps-ng, psmisc, lsof, GNU tools, networking, `ufw`,
`man`) so the machine is usable with nothing extra installed. Everything else
comes from the mirror via `bpm`.

## The supply chain

```
packages/<name>/bpm.toml
        │  tools/build-bpm-pkg.sh  (ephemeral Arch container, bpmbuild)
        ▼
   .bpm  ──scp──►  mirror  ──tools/bpmrepo.sh──►  bpm.index (+ .sig)
                                                              │  HTTPS
                                                              ▼
                                                        bpm install (SHA-256 + ed25519 verified)
```

The Arch container is the build toolchain only; the installed system depends on
no external mirror. See [Overview](Overview) and
[doc/ARCHITECTURE.md](../../doc/ARCHITECTURE.md).
