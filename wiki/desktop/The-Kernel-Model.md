# The Kernel Model

In Blueberry the kernel is a **pinned, prebuilt binary artifact** — not a rolling
package, and **not compiled on your machine**. This is the same for both editions,
and it is a deliberate design decision.

## The kernel is prebuilt and pinned

`make` does **not** compile the kernel. Instead it downloads a fixed, versioned
artifact (`vmlinuz` + `System.map` + modules, ~20 MB) from the package repo and
verifies its SHA‑256:

```sh
make kernel        # fetches the pinned prebuilt kernel — no multi-hour compile
```

The artifact lives at
`https://repo.mmzsigmond.me/kernel/blueberry-kernel-<version>-<arch>.tar.zst`
and is cached locally, so subsequent builds don't even re-download it. Small
machines never have to build a kernel (nor gcc/glibc — those are host-provided
too; see [Building From Source](Building-From-Source)).

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

## Per-edition delivery

The kernel artifact is shared; what differs is **how often it is bumped** and how
userspace around it moves:

| | Server | Desktop |
|---|---|---|
| Kernel | Pinned prebuilt artifact | Pinned prebuilt artifact |
| Compiled on your machine? | **No** | **No** |
| Userspace / apps | **Rolling** (`bpm upgrade`) | **Pinned per release** (`YY.04`/`YY.10`) |
| Kernel bumps | When a new artifact is published | Once per stable release, validated for its life |
| How you get a new kernel | New image / artifact | Upgrade to the next release |

On **Desktop** the kernel + driver + Mesa combination is a **fixed, tested
anchor** for the whole release — the same contract Ubuntu, Debian stable, and
RHEL make. A routine `bpm upgrade` updates apps and libraries but never the
kernel, so your graphics and boot path stay on a known-good combination.

On **Server**, userspace rolls continuously, but the kernel is still the pinned
prebuilt anchor — it advances when a new artifact is published, not on every
`bpm upgrade`.

This also keeps the desktop's `common.list` honest: it lists the graphical base
(Wayland, Mesa, SDDM, PipeWire…) but **no `linux` package**, because the kernel
is a release artifact, not a repo package.

## What's in the kernel

The single config (`src/kernel/config`) serves both editions. Notable
desktop-critical options that **must** stay enabled:

- **DRM stack** (`CONFIG_DRM`, `VIRTIO_GPU`, `SIMPLEDRM`, …) — KWin/Wayland needs
  a DRM device to render.
- **`CONFIG_INPUT_EVDEV`** — creates `/dev/input/event*`; without it libinput has
  no pointer/keyboard and the GUI has an invisible cursor and dead input.

## See also

- [Building From Source](Building-From-Source) — the prebuilt-kernel fetch and
  the `kernel-publish` workflow.
- [Release Process](Release-Process) — how desktop releases pin a kernel.
- [doc/KERNEL.md](../doc/KERNEL.md) — kernel config and patch workflow.
