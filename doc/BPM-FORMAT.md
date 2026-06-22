# The native Blueberry package format (`.bpm`) — DESIGN (experimental)

> **Status: EXPERIMENTAL — `feature/bpm-pkg-format` branch only.**
> Not used by the production build/repo until it is proven 100%. Production
> still uses `PKGBUILD` + `.pkg.tar.zst`.

This replaces the two Arch-derived pieces Blueberry currently borrows:

| Concern | Today (Arch-derived) | Native `.bpm` |
|---|---|---|
| Recipe | `PKGBUILD` (bash) | `bpm.toml` (declarative TOML + shell steps) |
| Package | `name-ver-arch.pkg.tar.zst` | `name-ver-rel-arch.bpm` |
| Metadata | `.PKGINFO` (key=value) | `.BPM` (TOML) inside the archive |
| Builder | `makepkg` | `bpmbuild` |

The goals: a recipe that's **parseable without a bash interpreter** (so tooling,
the recipe-hub, and the website can read/validate it), a package that is
**self-describing and signed end-to-end**, and an on-disk format bpm can still
**stream-install** in bounded memory.

---

## 1. The recipe: `bpm.toml`

One file per package directory (replaces `PKGBUILD`). Declarative metadata plus
two shell steps — `build` and `package` — for the parts that are inherently
imperative (configure/make/cmake). The escape-hatch shell keeps every build
expressible while the metadata stays machine-readable.

```toml
[package]
name     = "zlib"
version  = "1.3.1"
release  = 1
summary  = "Compression library implementing the deflate algorithm"
homepage = "https://www.zlib.net/"
license  = ["Zlib"]
arch     = ["x86_64"]

depends     = ["glibc"]
makedepends = ["gcc", "make"]
provides    = ["libz.so"]
options     = []            # e.g. ["!lto", "!strip"]

[[sources]]
url    = "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
sha256 = "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"

# Imperative steps. Provided env: $srcdir $pkgdir $name $version $release $arch.
build = '''
  cd "zlib-$version"
  ./configure --prefix=/usr
  make
'''

package = '''
  cd "zlib-$version"
  make DESTDIR="$pkgdir" install
'''

[scripts]                  # optional install-time hooks (sh)
post_install = "ldconfig"
post_upgrade = "ldconfig"
post_remove  = "ldconfig"
```

Field rules:
- `depends` are **Blueberry** package names (the runtime closure).
- `makedepends` are build-only and resolved by the builder's sandbox.
- `sha256` is **mandatory** for every source (or the literal `"SKIP"` for
  always-latest vendor binaries, mirroring the current escape hatch).
- `version`/`release` map to the package filename and version compare.

---

## 2. The package: `name-version-release-arch.bpm`

A `.bpm` is a **zstd-compressed tar** — the same proven container bpm already
stream-installs — with a Blueberry-native metadata member:

```
zstd( tar(
    .BPM              # TOML manifest, FIRST entry (so it streams first)
    usr/...           # the filesystem payload
) )
```

`.BPM` (TOML) is self-describing and is what bpm reads to build its DB entry:

```toml
format         = 1
name           = "zlib"
version        = "1.3.1"
release        = 1
arch           = "x86_64"
summary        = "Compression library ..."
depends        = ["glibc"]
provides       = ["libz.so"]
installed_size = 344160
build_date     = 1767225600          # SOURCE_DATE_EPOCH (reproducible)
payload_sha256 = "…"                 # sha256 of the uncompressed tar payload

[scripts]
post_install = "ldconfig"
```

Why keep zstd+tar rather than invent a byte format:
- bpm already streams it in a tiny, bounded working set (no full-archive buffering).
- Standard tools (`tar`, `zstd`, `bsdtar`) can still inspect a `.bpm`.
- The *format* is native (its own extension, its own TOML metadata, its own
  builder and signature chain) without re-deriving battle-tested compression.

The repo index and ed25519 signing are unchanged in spirit: the index lists
`.bpm` files with their sha256, and `bpm.index.sig` signs the index — so the
trust chain (signed index → per-file sha256 → TLS) carries over verbatim.

---

## 3. The builder: `bpmbuild`

`tools/bpmbuild.sh <recipe-dir> <out-dir>`:

1. Parse `bpm.toml` (TOML → JSON via a tiny embedded parser; no bash eval).
2. Fetch each `[[sources]]` URL into `$srcdir`, verify `sha256`.
3. Run `build` then `package` as `/bin/sh` with `$srcdir`/`$pkgdir` set,
   `package` under `fakeroot` so ownership is captured without root.
4. Synthesize `.BPM` from the recipe + the staged `$pkgdir` (installed_size,
   payload_sha256, build_date from `SOURCE_DATE_EPOCH`).
5. Emit `tar(.BPM, payload) | zstd` → `name-version-release-arch.bpm`.

It runs in the **same ephemeral container** the current pipeline uses; only the
recipe parser and the output packaging differ from `makepkg`.

---

## 4. bpm install support

`bpm` learns to recognise `.bpm`:
- The streaming installer already keys on a metadata member; it gains a `.BPM`
  branch that parses TOML (alongside the existing `.PKGINFO` branch, so both
  coexist during the transition).
- `bpm build <recipe-dir>` becomes a thin front-end to `bpmbuild`.

Nothing in the **production** path changes until `.bpm` round-trips
(build → index → sign → install → verify) cleanly for the whole package set.

---

## 5. Migration plan (when proven)

1. Generate `bpm.toml` for each `packages/<name>` from its `PKGBUILD` (one-time,
   scripted; the field mapping is mechanical).
2. Build the whole set to `.bpm`, index + sign, install-verify a desktop closure.
3. Flip the build/repo tooling to `.bpm`; keep `.pkg.tar.zst` readable for one
   release for rollback.
4. Remove `makepkg`/`PKGBUILD` from the pipeline.
