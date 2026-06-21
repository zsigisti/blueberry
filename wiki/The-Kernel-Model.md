# The Kernel Model

Blueberry treats the kernel **differently in each edition**. This is a
deliberate design decision, and it is the single biggest difference between
Server and Desktop.

## Server: the kernel rolls

On **Blueberry Server**, the kernel is just another `bpm` package named `linux`.

- `bpm upgrade` moves it forward continuously, along with the rest of userspace.
- You always run the newest kernel that has passed the build/boot test.
- This suits servers and builders, where you want current drivers, current
  hardware support, and a single update stream.

```sh
bpm upgrade          # may pull a newer linux package + everything else
```

## Desktop: the kernel is pinned per release

On **Blueberry Desktop**, the kernel is **not a rolling package**. Each stable
release (e.g. `26.04 LTS`) ships **one kernel**, baked into the release image
and validated for the life of that release.

- A routine `bpm upgrade` updates **userspace and apps**, but **never the
  kernel**. The desktop edition does not publish the kernel as a rolling
  package, so your graphics stack and boot path stay on a known-good
  combination.
- You get a newer kernel by **upgrading to the next release** — exactly how
  Ubuntu ships a new kernel with each `YY.MM` (and how an LTS keeps a stable
  kernel for two years).

```
26.04 LTS  ─ kernel A (pinned, 24 months)
26.10      ─ kernel B (pinned, 9 months)
27.04      ─ kernel C …
```

### Why pin it?

The desktop's value is *stability you can trust*. A user should be able to run
`bpm upgrade` every day without ever worrying that an automatic kernel bump
breaks their NVIDIA/AMD/Intel graphics, their Wi-Fi, or their ability to boot.
Pinning the kernel makes the kernel + driver + Mesa combination a **fixed,
tested anchor** for the whole release — the same contract Ubuntu, Debian
stable, and RHEL make.

It also keeps the desktop's `common.list` honest: it contains the graphical
base (Wayland, Mesa, SDDM, PipeWire…) but **no `linux` entry**, because the
kernel is part of the *release*, not the *rolling repo*.

## Summary

| | Server | Desktop |
|---|---|---|
| Kernel delivery | Rolling `bpm` package | Pinned in the release image |
| `bpm upgrade` touches kernel? | **Yes** | **No** |
| How you get a new kernel | Automatically | By upgrading to the next release |
| Best for | Servers, current hardware | Stable daily-driver desktops |

## See also

- [Release Process](Release-Process) — how desktop releases (and their pinned
  kernels) are cut.
- [Package Management](Package-Management) — what `bpm upgrade` does on each
  edition.
- [doc/KERNEL.md](../doc/KERNEL.md) — kernel config and patch workflow.
