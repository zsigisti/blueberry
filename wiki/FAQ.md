# FAQ

### Is Blueberry based on Arch / Debian / Ubuntu?

No. Blueberry is built **from source** out of one repository, with its own
package manager (`bpm`) and its own signed mirror. Recipes are declarative
`bpm.toml`, and an Arch container is used only to *build* packages — a running
Blueberry system depends on no other distro's mirror. See [Overview](Overview).

### What is Blueberry Server?

A minimal, rolling, source-built **CLI server** distribution. systemd is PID 1
by default (journald, logind, networkd/resolved, OpenSSH); a smaller
**runit** build exists for RAM-first use. There is no desktop — it is a server
OS.

### How is the kernel handled?

The kernel is a **pinned, prebuilt artifact** fetched from the mirror and
verified by SHA-256 — it is *not* compiled on your machine. Userspace rolls
continuously with `bpm upgrade`; the kernel advances when a new artifact is
published. Full reasoning: [The Kernel Model](The-Kernel-Model).

### How do I install software?

`bpm update && bpm install <name>`. See [Package Management](Package-Management).

### How do I add a package that isn't in the repo?

Write a `packages/<name>/bpm.toml` and build it with `tools/build-bpm-pkg.sh`,
then install the resulting file or publish it to a mirror. See
[Creating Packages](Creating-Packages).

### Can I run my own mirror / fork the distro?

Yes — that's a first-class use case. Point `bpm` at your mirror (built with your
own ed25519 key) and you have an independent distribution. See
[Hosting a Mirror](Hosting-a-Mirror).

### What architectures are supported?

x86-64 today. The build system is arch-parameterized (`Make.config`), but the
mirror and ISOs are x86-64.

### Is it reproducible?

Builds use a fixed `SOURCE_DATE_EPOCH` and pinned source checksums, so a recipe
yields the same bytes each time.

### How big is it / what does it need?

The live system boots from RAM in seconds and is tiny. A disk install is a
minimal systemd server. Recommended: a 64-bit machine (BIOS or UEFI), ~512 MB
RAM, a couple of GB of disk.

### Where do I report bugs or contribute?

Open an issue or PR with your recipe. See [Contributing](Contributing).
