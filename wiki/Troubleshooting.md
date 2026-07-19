# Troubleshooting

Common problems and fixes, grouped by area. See also the [FAQ](FAQ).

## Live ISO / boot

| Symptom | Try |
|---|---|
| Live ISO won't boot in QEMU | Give it enough RAM (`-m 2G`); for the installer ISO use `make run-server`/`make run` which pass sane defaults |
| Live session won't boot on hardware | Re-write the USB with `oflag=sync`; verify the ISO checksum; try another port/stick |
| "Cannot find live medium" | The USB label must match `root=live:CDLABEL=...`; re-flash with `dd` (not a file copy) |
| Boots to a blank console | Add `console=tty0 console=ttyS0` if you're on serial; check the GRUB entry matches BIOS vs UEFI |

## Installer

| Symptom | Try |
|---|---|
| Installer can't find the payload (`rootfs.tar.zst`) | Give USB detection time (the installer retries ~40 s); re-flash the stick if the label is wrong |
| Partitioning fails | Ensure the disk isn't mounted/in use; for UEFI you need an EFI system partition |
| Install finishes but won't boot | Confirm UEFI vs BIOS matches how you booted the ISO; reinstall GRUB to the right target |
| Wrong console keymap | Pick the keymap in the installer, or set it later with `loadkeys` / `/etc/vconsole.conf` |

## Networking

| Symptom | Try |
|---|---|
| No Wi-Fi | The stack ships wpa_supplicant + linux-firmware; connect with `wpa_cli` or a `/etc/wpa_supplicant/wpa_supplicant-<if>.conf` |
| No DNS after connecting | Check `systemd-resolved` is up (`systemctl status systemd-resolved`) |
| Firewall blocks a port | `ufw allow <port>`; check `ufw status` (ufw uses the legacy iptables backend, enabled in the kernel) |

## Packages (bpm)

| Symptom | Try |
|---|---|
| `bpm update` fails to verify the index | Your `bpm` was built with a different public key than the mirror's signing key — see [Hosting a Mirror](Hosting-a-Mirror) |
| Stale index through a CDN | `curl -H 'Cache-Control: no-cache' …` / wait for cache TTL |
| `install` says a dependency is missing | The dep isn't on the mirror yet; build it (`tools/build-bpm-pkg.sh`) or check the recipe's `depends` |
| SHA-256 mismatch | The package was re-built; `bpm update` then retry |

## Building from source

| Symptom | Try |
|---|---|
| `make _check_tools` reports missing tools | Install gcc/make/curl/zstd/cpio/qemu |
| Package build: C23/implicit-decl errors | GCC 16 strictness — add `-std=gnu17` or the needed includes ([Creating Packages](Creating-Packages)) |
| `-Werror=format-security` fails a C build | Strip it from the recipe's CFLAGS (GCC 16 default) |
| "target not found: <pkg>" during a build | The makedep uses the wrong Arch name; correct it |
| Build hangs past the shell timeout | Run it detached: `setsid bash -c '… > LOG 2>&1' </dev/null &` |

## Still stuck?

- Reproduce the build error in a one-off container to see the full log.
- Check the relevant `doc/` page (e.g. [doc/BUILD.md](../../doc/BUILD.md),
  [doc/INIT.md](../../doc/INIT.md)).
- Open an issue with the exact command and the full error output.
