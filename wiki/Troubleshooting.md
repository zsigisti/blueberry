# Troubleshooting

Common problems and fixes, grouped by area. See also the [FAQ](FAQ).

## Live ISO / boot

| Symptom | Try |
|---|---|
| **Black screen in QEMU** (no greeter) | Add **`-cpu host`** — software GL (llvmpipe) needs AVX, which the default `qemu64` CPU lacks. `make run-desktop` already does this. |
| Black screen on real hardware after login | Boot the **safe graphics / nomodeset** GRUB entry; ensure your GPU's kernel module/firmware is present |
| Greeter shows but logging in returns to the greeter | Known limitation: the live autologin→Plasma seat/DRM hand-off; the greeter renders and is usable, full-session work is in progress |
| Live session won't boot at all | Re-write the USB with `oflag=sync`; verify the ISO checksum; try another port/stick |
| "Cannot find live medium" | The USB label must match `root=live:CDLABEL=...`; re-flash with `dd` (not a file copy) |
| No Wi-Fi in the live session | Load firmware if your card needs it; connect from the Plasma system tray |

## Calamares (installer)

| Symptom | Try |
|---|---|
| Installer won't launch | Open Konsole: `sudo calamares -d` for a debug log |
| Partitioning fails | Ensure the disk isn't mounted/in use; for UEFI you need an EFI system partition |
| No network during install | Connect Wi-Fi in Plasma **before** starting Calamares — it uses the live connection |
| Install finishes but won't boot | Confirm UEFI vs BIOS matches how you booted the ISO; reinstall GRUB to the right target |

## Packages (bpm)

| Symptom | Try |
|---|---|
| `bpm update` fails to verify the index | Your `bpm` was built with a different public key than the mirror's signing key — see [Hosting a Mirror](Hosting-a-Mirror) |
| Stale index through a CDN | `curl -H 'Cache-Control: no-cache' …` / wait for cache TTL |
| `install` says a dependency is missing | The dep isn't on the mirror yet; build it (`tools/build-pkgs.sh`) or check the recipe's `depends` |
| SHA-256 mismatch | The package was re-built; `bpm update` then retry |

## Building from source

| Symptom | Try |
|---|---|
| `make _check_tools` reports missing tools | Install gcc/make/curl/zstd/cpio/qemu |
| Package build: C23/implicit-decl errors | GCC 16 strictness — add `-std=gnu17` or the needed includes ([Creating Packages](Creating-Packages)) |
| KDE framework: "Qml/LinguistTools not found" | Add `qt6-declarative` + `qt6-tools` makedeps |
| KDE framework: Shiboken6 required | Add `-DBUILD_PYTHON_BINDINGS=OFF` |
| "target not found: <pkg>" during a build | The makedep uses the wrong Arch name; correct it (e.g. `xf86-input-libinput`, `libaccounts-qt`) |
| Build hangs past the shell timeout | Run it detached: `setsid bash -c '… > LOG 2>&1' </dev/null &` |

## Desktop runtime

| Symptom | Try |
|---|---|
| App won't start, missing `libgtk-3` | Install the GTK stack (`gtk3` and deps) — needed by Firefox/Brave/Spotify |
| No system sounds / media in some apps | Ensure `qt6-multimedia` is installed |
| Kernel didn't update after `bpm upgrade` (Desktop) | **Expected** — the desktop kernel is pinned; upgrade to the next release ([The Kernel Model](The-Kernel-Model)) |

## Still stuck?

- Reproduce the build error in a one-off container to see the full log.
- Check the relevant `doc/` page (e.g. [doc/BUILD.md](../doc/BUILD.md),
  [doc/INIT.md](../doc/INIT.md)).
- Open an issue with the exact command and the full error output.
