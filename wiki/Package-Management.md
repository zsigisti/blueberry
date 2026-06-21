# Package Management (bpm)

`bpm` is Blueberry's native package manager, written in Rust. It installs
`.pkg.tar.zst` packages from an HTTP(S) repository, verifying every one.

## Everyday commands

```sh
bpm update                 # refresh the signed package index
bpm search firefox         # search the index
bpm info kwin              # show a package's version, size, dependencies
bpm install dolphin        # install (with dependencies)
bpm remove dolphin         # uninstall
bpm upgrade                # update everything installed
bpm list                   # list installed packages
bpm clean                  # clear the download cache
bpm verify                 # re-check installed files against their hashes
```

## How a package is trusted

Every install passes three checks before anything touches your disk:

1. **Signed index.** The repo's `bpm.index` is accompanied by
   `bpm.index.sig`, an **ed25519 signature** verified against a public key
   compiled into the `bpm` binary. A tampered index is rejected.
2. **Per-package SHA-256.** The index records a SHA-256 for each
   `.pkg.tar.zst`. `bpm` streams the package and checks the hash as it goes.
3. **TLS.** Everything is fetched over HTTPS.

If any check fails, the operation aborts and nothing is written.

## Where packages come from

`bpm` reads `/etc/bpm/repos.conf`. The default points at the official mirror:

```
https://repo.mmzsigmond.me/
```

You can add or replace mirrors — including your own (see
[Hosting a Mirror](Hosting-a-Mirror)).

## The `provided` base set

Some base-image libraries (zlib, zstd, xz, lz4, ca-certificates) are part of the
root filesystem rather than separate packages. They are listed in
`etc/bpm/provided` so the dependency solver treats them as already-satisfied and
doesn't try to install them.

## What `bpm upgrade` does on each edition

| | Server | Desktop |
|---|---|---|
| Userspace & apps | Updated | Updated |
| Kernel | **Updated** (rolling `linux` package) | **Not updated** (pinned per release) |

On Desktop, a newer kernel arrives only when you upgrade to the next release.
This is intentional — see [The Kernel Model](The-Kernel-Model).

## Installing from a local package

```sh
bpm install ./firefox-152.0.1-1-x86_64.pkg.tar.zst
```

Useful when testing a recipe you just built (see [Creating Packages](Creating-Packages)).

## Building packages

Any recipe in [`packages/`](../packages) can be built into a package:

```sh
ENGINE=podman tools/build-pkgs.sh <out-dir> firefox kate kwin
```

This runs `makepkg` inside an ephemeral container, fetching build dependencies,
compiling from source, and emitting `.pkg.tar.zst` files. Full details:
[Creating Packages](Creating-Packages).
