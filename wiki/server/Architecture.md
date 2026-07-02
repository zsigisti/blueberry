# Architecture

How a Blueberry system is put together, from power-on to desktop.

## Boot sequence

```
firmware ─► GRUB ─► vmlinuz ─► initramfs /init (PID 1)
                                 │
                                 ├─ bbtest cmdline?     ─► run /etc/selftest, print result, halt
                                 ├─ bbinstall cmdline?  ─► unattended blueberry-install, halt
                                 ├─ blueberry.live=1?   ─► squashfs+overlay root → switch_root → systemd → SDDM → Plasma
                                 ├─ root= cmdline?      ─► resolve UUID, mount disk → switch_root → runit/systemd
                                 └─ otherwise           ─► interactive login shell
```

`/init` (in [`src/initramfs/`](../../src/initramfs)) is a small script that:

1. mounts `/proc`, `/sys`, `/dev` and populates `/dev`,
2. inspects the kernel cmdline to choose a path,
3. either drops to a live shell, runs the self-test/installer, mounts a disk
   install, or — on the Desktop live ISO — assembles an overlay root and hands
   off to systemd.

## The live desktop path (`blueberry.live=1`)

The Desktop ISO carries a squashfs image of the full rootfs. The initramfs:

1. finds the boot medium (`root=live:CDLABEL=...`),
2. mounts the squashfs **read-only** as an overlay *lower* layer,
3. stacks a **tmpfs** *upper* layer (so the session is writable but disposable),
4. keeps the medium at `/run/live/medium`,
5. `switch_root`s into **systemd**, which starts **SDDM**, which auto-logs into
   **Plasma**.

The kernel already builds in SQUASHFS (+zstd), OVERLAY_FS, ISO9660, LOOP, and
USB_STORAGE, so no modules are needed to boot the live image.

## Init systems

| | Used by |
|---|---|
| **systemd** | Default on both editions — journald, logind, networkd/resolved, OpenSSH |
| **runit** | Opt-in (`INIT=runit`) — a 35 KB supervision tree for RAM-first / minimal builds |

The runit stage scripts live in [`src/init/`](../../src/init); the systemd
integration (units, networkd, sshd) in [`src/systemd/`](../../src/systemd). See
[doc/INIT.md](../../doc/INIT.md).

## Package layers (Desktop)

The desktop stack is built bottom-up; each layer depends only on those below:

```
0–1  Foundation     glibc, toolchain, core libs
2    Session        pam, polkit, dbus, systemd
3    X11/XCB        libxcb, libx11, the libx* family
4    GPU/GL         libdrm, Mesa, LLVM, Vulkan, Wayland
5    Toolkits        Qt 6.11, GTK 3
6    Frameworks      KDE Frameworks 6.27
7    Desktop         Plasma 6.7 (KWin, workspace, …), SDDM, Breeze
8    Apps            Dolphin, Konsole, Firefox, Blender, …
9    Installer       the Blueberry installer (+ kpmcore)
```

## The supply chain

```
packages/<name>/bpm.toml
        │  tools/build-bpm-pkg.sh  (ephemeral container, bpmbuild)
        ▼
   .bpm  ──scp──►  mirror  ──tools/bpmrepo.sh──►  bpm.index (+ .sig)
                                                              │  HTTPS
                                                              ▼
                                                        bpm install (SHA-256 + ed25519 verified)
```

See [Self-Hosting Philosophy](Self-Hosting-Philosophy) and [doc/ARCHITECTURE.md](../../doc/ARCHITECTURE.md).
