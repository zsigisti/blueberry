# Blueberry Desktop Wiki

**Blueberry Desktop** is a polished GUI edition with **Ubuntu-style stable
releases** and a live **Calamares** installer — KDE Plasma 6 by default (GNOME
optional). Built entirely from source, no upstream binary mirrors.

> Looking for the headless CLI edition? See the **[Blueberry Server wiki](../server/Home)**.

## Start here

| If you want to… | Read |
|---|---|
| Understand the project in 5 minutes | [Overview](Overview) |
| Try the desktop on your machine | [Getting Started](Getting-Started) |
| Install the GUI desktop | [Installing Blueberry Desktop](Installing-Blueberry-Desktop) |
| Know what's in the desktop | [Desktop Edition](Desktop-Edition) |
| Understand the installer | [The Calamares Installer](The-Calamares-Installer) |
| Learn the release cycle | [Release Process](Release-Process) |
| Manage software | [Package Management (bpm)](Package-Management) |
| Build the OS yourself | [Building From Source](Building-From-Source) |
| Understand kernel updates | [The Kernel Model](The-Kernel-Model) |
| Fix a problem | [Troubleshooting](Troubleshooting) · [FAQ](FAQ) |

## Desktop at a glance

- **Stable releases** — `YY.04` / `YY.10`, Ubuntu-style; April of even years is
  an **LTS** (24 months). See [Release Process](Release-Process).
- **Pinned kernel per release** — a validated kernel + driver + Mesa anchor for
  the release's life; `bpm upgrade` updates apps, never the kernel. See
  [The Kernel Model](The-Kernel-Model).
- **KDE Plasma 6** default · **GNOME** optional ([GNOME Spin](GNOME-Spin)).
- **Live Calamares ISO** — boot, try, install.
- **Self-hosted** — every package built from source into one ed25519-signed
  mirror at `https://repo.mmzsigmond.me/`.

## Wiki map

- **Concepts** — [Overview](Overview) · [Architecture](Architecture) ·
  [The Kernel Model](The-Kernel-Model) · [Self-Hosting Philosophy](Self-Hosting-Philosophy)
- **Using the desktop** — [Getting Started](Getting-Started) ·
  [Installing Blueberry Desktop](Installing-Blueberry-Desktop) ·
  [Desktop Edition](Desktop-Edition) · [Package Management](Package-Management)
- **Releases & installer** — [Release Process](Release-Process) ·
  [The Calamares Installer](The-Calamares-Installer) · [GNOME Spin](GNOME-Spin)
- **Building & contributing** — [Building From Source](Building-From-Source) ·
  [Creating Packages](Creating-Packages) · [Hosting a Mirror](Hosting-a-Mirror) ·
  [Contributing](Contributing)
- **Help** — [Troubleshooting](Troubleshooting) · [FAQ](FAQ)
