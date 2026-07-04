# Blueberry Linux Wiki

Blueberry is a **self-hosted Linux distribution built entirely from source** —
a minimal, rolling **CLI server** system in the BSD tradition. One monorepo
produces the base (a pinned prebuilt kernel and glibc, the `bpm` package manager,
the build system) and every package is a recipe in [`packages/`](../packages),
built from source into one ed25519-signed mirror at
`https://repo.mmzsigmond.me/`. There are **no upstream binary mirrors**.

## Start here

- [Overview](Overview) — what Blueberry is and how it's put together
- [Getting Started](Getting-Started) — download, write to USB, install
- [Installing Blueberry Server](Installing-Blueberry-Server) — the TUI installer
- [Architecture](Architecture) · [The Kernel Model](The-Kernel-Model) ·
  [Package Management](Package-Management) · [Building From Source](Building-From-Source)
- [Creating Packages](Creating-Packages) · [Hosting a Mirror](Hosting-a-Mirror)
- [FAQ](FAQ) · [Troubleshooting](Troubleshooting) · [Contributing](Contributing)
