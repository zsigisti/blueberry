## Blueberry Linux — v0.9.2-beta

A feature + fix release. The interactive installer now actually ships the
current code (a build bug had been freezing it at an old build), NetworkManager
is gone in favour of systemd-networkd everywhere, the web console can manage
containers, and the fish shell is packaged. The images are rebuilt and pass the
end-to-end gate: the server ISO boots to a root shell, and an unattended install
boots to multi-user with sshd and networkd up and no failed units. On an existing
system it is `bpm update && bpm upgrade`.

### The installer on the ISO is current again

The bootable ISOs bundle the guided installer (`blueberry-install`) inside the
initramfs. Its rebuild trigger pointed at the long-dead C installer source
instead of the Rust sources it is actually built from, so editing the installer
never rebuilt the initramfs — and the ISOs kept shipping a months-old build. That
stale installer still offered a NetworkManager "network stack" choice and
referenced the removed desktop edition. The dependency now tracks the real Rust
sources, the dead C installer is deleted, and the initramfs (and both ISOs)
rebuild whenever the installer changes. Verified: the shipped installer has no
NetworkManager left in it and lays down a clean networkd system.

A new `make run-install` boots the installer ISO in QEMU with a blank target disk
attached, so the installer can be driven by hand (TUI or `--cli`) rather than
only through the headless unattended path.

### NetworkManager removed — systemd-networkd only

NetworkManager never built self-hosted and pulled an unmet dependency chain, so
it is removed entirely. systemd-networkd (+resolved) is the sole, default network
stack, shipped enabled in the base image with DHCP on every wired interface. For
Wi-Fi, `wpa_supplicant`/`wpa_cli` remain in the base. The installer no longer
offers a network-stack choice, and all docs point at networkd.

### Container management in the web console

The Blueberry Console gains a Containers panel backed by podman: it lists running
and stopped containers and images, tails a container's logs, and offers
start / stop / restart / remove. All actions are argument-validated and passed as
argv (never a shell string); `remove` refuses a running container (no accidental
kill). When podman is not installed the panel degrades gracefully with an install
hint. Images that podman reports once per tag are de-duplicated so each image
shows a single row.

### fish shell packaged

The friendly interactive shell fish 4.8.1 is available: `bpm install fish`. It
builds against the system PCRE2 and ships its own terminfo, so it is fully
self-contained.

### Also in this release

- `blueberry-console` is now part of the base image (the service stays opt-in:
  `systemctl enable --now blueberry-console`).
- `bind-tools` builds with DoH disabled (libnghttp2 is not packaged), so `dig`
  and friends build cleanly self-hosted.
- Internal cleanups: dead code removed from the console and installer, and the
  console's documented security posture (binds `0.0.0.0:9090` with its own TLS)
  now matches the code.
