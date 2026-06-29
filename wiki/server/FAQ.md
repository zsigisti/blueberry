# FAQ

### Is Blueberry based on Arch / Debian / Ubuntu?

No. Blueberry is built **from source** out of one repository, with its own
package manager (`bpm`) and its own signed mirror. Recipes are declarative
`bpm.toml`, and an Arch container is used only to *build* packages, but a running
Blueberry system depends on no other distro's mirror. See
[Self-Hosting Philosophy](Self-Hosting-Philosophy).

### What's the difference between Server and Desktop?

Server is a rolling CLI system; Desktop is a stable-release GUI (KDE Plasma 6).
The biggest difference is the kernel: Server rolls it, Desktop pins it per
release. See [Overview](Overview) and [The Kernel Model](The-Kernel-Model).

### Why is the kernel pinned on Desktop but rolling on Server?

So a routine `bpm upgrade` on a desktop can never break your graphics or boot.
Desktop ships a tested kernel + driver stack per release (like Ubuntu); you get a
new kernel by upgrading to the next release. Servers want current drivers, so
there the kernel rolls. Full reasoning: [The Kernel Model](The-Kernel-Model).

### How do I get a newer kernel on Desktop?

Upgrade to the next release (e.g. `26.04` → `26.10`). Apps and userspace keep
updating from the rolling repo in the meantime.

### KDE or GNOME?

KDE Plasma 6 is the default and the fully-built spin. GNOME is a documented
alternative (`DE=gnome`). See [GNOME Spin](GNOME-Spin).

### Can I run Steam / Spotify / Brave? They're not open source.

Yes. Those are packaged by wrapping the **vendor's official binary** and hosting
it on the Blueberry mirror — the same thing every distro does. Steam also wants a
32-bit (multilib) layer for its runtime. See
[Self-Hosting Philosophy](Self-Hosting-Philosophy).

### How do I install software?

`bpm update && bpm install <name>`. See [Package Management](Package-Management).

### How do I add a package that isn't in the repo?

Write a `packages/<name>/bpm.toml` and build it with `tools/build-bpm-pkg.sh`, then
install the resulting file or publish it to a mirror. See
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

### Where do I report bugs or contribute?

Open an issue or PR with your recipe. See [Contributing](Contributing).

### What does "Blueberry" run on — how big is it?

The Server live system boots from RAM in seconds and is tiny (busybox + bash +
runit). The Desktop is a full KDE Plasma 6 stack (~390 packages on the mirror).
Recommended for Desktop: a 64-bit UEFI machine, 4 GB RAM, a few GB of disk.
