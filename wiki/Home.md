# Blueberry Linux Wiki

Welcome to the Blueberry Linux wiki — the complete reference for both editions,
the package ecosystem, and the build system.

Blueberry is a **self-hosted Linux distribution built entirely from source**.
One monorepo produces two editions that share a base (kernel, glibc, the `bpm`
package manager, the build system):

- **🖥️ Blueberry Server** — a minimal, **rolling** CLI system.
- **🪟 Blueberry Desktop** — a polished GUI edition with **Ubuntu-style stable
  releases** and a live Calamares installer (KDE Plasma 6 default, GNOME
  optional).

There are **no upstream binary mirrors**. Every package is a recipe in
[`packages/`](../packages), built from source into one ed25519-signed mirror at
`https://repo.mmzsigmond.me/`.

## Start here

| If you want to… | Read |
|---|---|
| Understand the project in 5 minutes | [Overview](Overview) |
| Try Blueberry on your machine | [Getting Started](Getting-Started) |
| Install the GUI desktop | [Installing Blueberry Desktop](Installing-Blueberry-Desktop) |
| Install the server/CLI | [Installing Blueberry Server](Installing-Blueberry-Server) |
| Manage software | [Package Management (bpm)](Package-Management) |
| Build the OS yourself | [Building From Source](Building-From-Source) |
| Write a package recipe | [Creating Packages](Creating-Packages) |
| Run your own mirror | [Hosting a Mirror](Hosting-a-Mirror) |
| Understand kernel updates | [The Kernel Model](The-Kernel-Model) |
| Learn the desktop release cycle | [Release Process](Release-Process) |
| Look under the hood | [Architecture](Architecture) |
| Fix a problem | [Troubleshooting](Troubleshooting) · [FAQ](FAQ) |

## Wiki map

- **Concepts** — [Overview](Overview) · [Architecture](Architecture) ·
  [The Kernel Model](The-Kernel-Model) · [Self-Hosting Philosophy](Self-Hosting-Philosophy)
- **Using Blueberry** — [Getting Started](Getting-Started) ·
  [Installing Blueberry Desktop](Installing-Blueberry-Desktop) ·
  [Installing Blueberry Server](Installing-Blueberry-Server) ·
  [Package Management](Package-Management)
- **Blueberry Desktop** — [Desktop Edition](Desktop-Edition) ·
  [Release Process](Release-Process) · [The Calamares Installer](The-Calamares-Installer) ·
  [GNOME Spin](GNOME-Spin)
- **Building & contributing** — [Building From Source](Building-From-Source) ·
  [Creating Packages](Creating-Packages) · [Hosting a Mirror](Hosting-a-Mirror) ·
  [Contributing](Contributing)
- **Help** — [Troubleshooting](Troubleshooting) · [FAQ](FAQ)
