# Blueberry Linux Wiki

Blueberry is a **self-hosted Linux distribution built entirely from source**.
One monorepo produces two editions that share a base (a pinned prebuilt kernel,
glibc, the `bpm` package manager, the build system). There are **no upstream
binary mirrors** — every package is a recipe in [`packages/`](../packages), built
from source into one ed25519-signed mirror at `https://repo.mmzsigmond.me/`.

The wiki is split by edition — pick yours:

## 🖥️ [Blueberry Server →](server/Home)

A minimal, **rolling** CLI system. systemd (or runit), headless, always latest.

## 🪟 [Blueberry Desktop →](desktop/Home)

A polished GUI edition with **Ubuntu-style stable releases** (KDE Plasma 6
default, GNOME optional). Installs via Blueberry's own full-screen **TUI
installer** — offline (complete payload) or netinstall (fetches the desktop
from the signed repo) ISOs, BIOS + UEFI, optional LUKS2.

---

Both editions share the same concepts — [Overview](server/Overview),
[Architecture](server/Architecture), [The Kernel Model](server/The-Kernel-Model),
[Package Management](server/Package-Management), and
[Building From Source](server/Building-From-Source) — so those pages appear in
both edition wikis.
