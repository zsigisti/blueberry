# bpm

The Blueberry Package Manager, written in Rust.

## What it does

Installs `.pkg.tar.zst` packages from an HTTP(S) repo. The repo `bpm.index`
records each package's SHA-256; every download is verified against it, and the
index is fetched over TLS. There is no index signing — integrity is the
per-package checksum plus the transport.

Extraction streams through the `zstd` + `tar` crates straight to disk, so even a
~200 MB package (gcc) installs in ~5 MB RSS — no buffering the whole archive in
memory. Files are written to a temp sibling and atomically renamed over the
target, so bpm can replace an in-use file (including its own running binary)
without ETXTBSY.

## Commands

`install`/`in`, `remove`/`rm`, `update`/`up`, `upgrade`, `search`/`se`,
`list`/`ls`, `info`, `files`, `owns`, `clean`. `-f/--force` skips the
space/conflict/reverse-dep checks. `BPM_ROOT=<dir>` installs into a staging root
(chrooting for scriptlets/ldconfig). `BPM_NO_SCRIPTLETS` skips `.INSTALL` hooks.

## Dependencies

`ureq` (rustls TLS), `zstd`, `tar`, `sha2`, `libc`. The release binary links
only libc + libgcc_s; libzstd is statically bundled.

## Build

```sh
cargo build --release        # target/release/bpm
cargo test                   # vercmp parity tests
```

Packaged for the repo by `packages/bpm/PKGBUILD` (built in the Arch container,
`makedepends=rust`); also built into the image/initramfs by `tools/pkg/build-bpm.sh`.
Install/update on a running system with `bpm install bpm`.
