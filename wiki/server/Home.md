# Blueberry Server Wiki

**Blueberry Server** is a minimal, **rolling** CLI Linux system — built entirely
from source, with no upstream binary mirrors. systemd by default (runit
optional), a native Rust package manager (`bpm`), and a pinned prebuilt kernel.

> Looking for the GUI edition? See the **[Blueberry Desktop wiki](../desktop/Home)**.

## Start here

| If you want to… | Read |
|---|---|
| Understand the project in 5 minutes | [Overview](Overview) |
| Try Blueberry on your machine | [Getting Started](Getting-Started) |
| Install the server / CLI | [Installing Blueberry Server](Installing-Blueberry-Server) |
| Manage software | [Package Management (bpm)](Package-Management) |
| Build the OS yourself | [Building From Source](Building-From-Source) |
| Write a package recipe | [Creating Packages](Creating-Packages) |
| Run your own mirror | [Hosting a Mirror](Hosting-a-Mirror) |
| Understand kernel updates | [The Kernel Model](The-Kernel-Model) |
| Look under the hood | [Architecture](Architecture) |
| Fix a problem | [Troubleshooting](Troubleshooting) · [FAQ](FAQ) |

## Server at a glance

- **Rolling** — `bpm upgrade` always moves userspace to the latest tested build.
- **Pinned prebuilt kernel** — fetched, never compiled locally; see
  [The Kernel Model](The-Kernel-Model).
- **systemd** (default) or **runit** (`INIT=runit`).
- **Self-hosted** — every package built from source into one ed25519-signed
  mirror at `https://repo.mmzsigmond.me/`.

## Wiki map

- **Concepts** — [Overview](Overview) · [Architecture](Architecture) ·
  [The Kernel Model](The-Kernel-Model) · [Self-Hosting Philosophy](Self-Hosting-Philosophy)
- **Using the server** — [Getting Started](Getting-Started) ·
  [Installing Blueberry Server](Installing-Blueberry-Server) ·
  [Package Management](Package-Management)
- **Building & contributing** — [Building From Source](Building-From-Source) ·
  [Creating Packages](Creating-Packages) · [Hosting a Mirror](Hosting-a-Mirror) ·
  [Contributing](Contributing)
- **Help** — [Troubleshooting](Troubleshooting) · [FAQ](FAQ)
