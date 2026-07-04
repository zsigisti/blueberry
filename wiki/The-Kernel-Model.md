# The Kernel Model

In Blueberry the kernel is a **pinned, prebuilt binary artifact** — not a rolling
package, and **not compiled on your machine**. This is a deliberate design
decision.

## The kernel is prebuilt and pinned

`make` does **not** compile the kernel. Instead it downloads a fixed, versioned
artifact (`vmlinuz` + `System.map` + modules, ~20 MB) from the package repo and
verifies its SHA-256:

```sh
make kernel        # fetches the pinned prebuilt kernel — no multi-hour compile
```

The artifact lives at
`https://repo.mmzsigmond.me/kernel/blueberry-kernel-<version>-<arch>.tar.zst`
and is cached locally, so subsequent builds don't even re-download it. Small
machines never have to build a kernel.

**glibc follows the same model.** It is a pinned `.bpm` package on the mirror,
fetched (not compiled) on every build by `tools/fetch-bpm.sh` and extracted into
both the rootfs and the initramfs — so the C library is always the
container-built one, never the build host's (see
[Building From Source](Building-From-Source)). Bump it by rebuilding and
republishing `packages/glibc`.

## Bumping the kernel (maintainers)

Compiling is **opt-in** and done on a build box only when the kernel version or
config actually changes:

```sh
make kernel-rebuild   # compile from source this once (KERNEL_BUILD=1)
make kernel-publish   # compile + upload a NEW pinned artifact to the repo
```

To change the kernel you edit `Make.config` (`LINUX_VERSION`) and/or
`src/kernel/config`, then run `make kernel-publish` once. Every other build then
fetches the new pinned artifact. The kernel is therefore versioned and changes
**deliberately**, never silently and never on a rolling basis.

## Kernel vs userspace

The two move on different clocks:

| | Behaviour |
|---|---|
| Kernel | Pinned prebuilt artifact; advances when a new one is published |
| glibc | Pinned `.bpm` on the mirror; advances when republished |
| Compiled on your machine? | **No** (both fetched from the mirror) |
| Userspace / apps | **Rolling** — `bpm upgrade` updates everything else |
| How you get a new kernel/glibc | Fetch the new artifact / rebuild the image |

A routine `bpm upgrade` rolls the whole userland forward continuously, while the
kernel stays a known, pinned anchor until it is deliberately bumped. This keeps
a server's boot path predictable without freezing its userspace.

## What's in the kernel

The single config (`src/kernel/config`) is tuned for a server: virtio and
common storage/network drivers, ext4/FAT/overlay/squashfs, the netfilter stack
(including `CONFIG_NETFILTER_XTABLES_LEGACY=y` for the legacy iptables backend
that `ufw` uses), cfg80211/mac80211 + iwlwifi/rtw88 for Wi-Fi, and the crypto
needed for cryptsetup. There is **no** graphics/DRM requirement — it is a
console system.

## See also

- [Building From Source](Building-From-Source) — the prebuilt-kernel fetch and
  the `kernel-publish` workflow.
- [doc/KERNEL.md](../../doc/KERNEL.md) — kernel config and patch workflow.
