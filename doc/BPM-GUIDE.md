# The `.bpm` Package Format — Complete Guide

> **Status: EXPERIMENTAL — `feature/bpm-pkg-format` branch only.**
> Verified end-to-end (build → index → install → run → remove) but not yet used
> in production. Production still ships `PKGBUILD` + `.pkg.tar.zst`.

This is the full reference for Blueberry's native package format: the `.bpm`
file, the `bpm.toml` recipe, the build/index/install tools, and how it all fits
together. For the terse design rationale see [BPM-FORMAT.md](BPM-FORMAT.md).

---

## Table of contents

1. [What a `.bpm` file looks like](#1-what-a-bpm-file-looks-like)
2. [The `.BPM` manifest](#2-the-bpm-manifest)
3. [The `bpm.toml` recipe](#3-the-bpmtoml-recipe)
4. [Building a package: `bpmbuild`](#4-building-a-package-bpmbuild)
5. [Indexing a repo: `bpmrepo.sh`](#5-indexing-a-repo-bpmreposh)
6. [Installing: how `bpm` reads `.bpm`](#6-installing-how-bpm-reads-bpm)
7. [Converting PKGBUILD → bpm.toml](#7-converting-pkgbuild--bpmtoml)
8. [End-to-end walkthrough](#8-end-to-end-walkthrough)
9. [Reference tables](#9-reference-tables)
10. [Design decisions & FAQ](#10-design-decisions--faq)

---

## 1. What a `.bpm` file looks like

A `.bpm` is a **zstd-compressed tar archive** with one rule: the metadata member
`.BPM` is always **first**, so a streaming installer reads the manifest before a
single payload byte.

```
hello-2.12.1-1-x86_64.bpm
│
└─ zstd frame            magic 28 B5 2F FD  ("Zstandard compressed data")
   └─ tar stream
      ├─ .BPM            ← TOML manifest, FIRST member (321 bytes)
      ├─ ./usr/
      ├─ ./usr/bin/
      ├─ ./usr/bin/hello ← the payload (real files, root:root, mtime=epoch)
      ├─ ./usr/share/
      └─ ./usr/share/locale/…
```

Filename grammar:

```
<name>-<version>-<release>-<arch>.bpm
hello  -2.12.1   -1         -x86_64.bpm
```

- `name` — package name (matches `[package].name`)
- `version` — upstream version
- `release` — Blueberry packaging revision (bumped on recipe-only changes)
- `arch` — `x86_64` or `any`

Inspect one with standard tools (no special program needed):

```sh
file pkg.bpm                       # → Zstandard compressed data
zstd -dcq pkg.bpm | tar -tvf -     # list members
zstd -dcq pkg.bpm | tar -xO -f - .BPM   # print the manifest
```

The payload tar is **reproducible**: entries are sorted, `mtime` is pinned to
`SOURCE_DATE_EPOCH`, and ownership is forced to `root:root` — so the same recipe
and sources produce byte-identical output.

---

## 2. The `.BPM` manifest

`.BPM` is a small TOML document. It is the single source of truth bpm uses to
record the package in its database. Real example:

```toml
format = 1
name = "hello"
version = "2.12.1"
release = 1
arch = "x86_64"
summary = "The GNU Hello program"
depends = ["glibc"]
provides = []
installed_size = 317544
build_date = 1767225600
payload_sha256 = "a2860c92…ce25887"

[scripts]
post_install = "ldconfig 2>/dev/null || true"
```

| Key | Type | Meaning |
|---|---|---|
| `format` | int | Manifest schema version (currently `1`) |
| `name` | string | Package name |
| `version` | string | Upstream version |
| `release` | int | Blueberry packaging revision |
| `arch` | string | `x86_64` or `any` |
| `summary` | string | One-line description |
| `depends` | string[] | Runtime dependencies (Blueberry package names) |
| `provides` | string[] | Virtual names / sonames this package satisfies |
| `installed_size` | int | Sum of payload file sizes, bytes (used for the disk pre-check) |
| `build_date` | int | `SOURCE_DATE_EPOCH` at build time |
| `payload_sha256` | string | SHA-256 of the uncompressed payload tar |
| `[scripts]` | table | Optional `post_install` / `post_upgrade` / `post_remove` shell |

`payload_sha256` lets the manifest self-attest its payload; the **repo index**
additionally carries a SHA-256 of the whole `.bpm` and is ed25519-signed, so the
trust chain is: signed index → per-file hash → TLS → in-package payload hash.

---

## 3. The `bpm.toml` recipe

One `bpm.toml` per package directory replaces `PKGBUILD`. It is declarative
metadata plus two shell steps for the inherently-imperative build.

```toml
[package]
name     = "zlib"
version  = "1.3.1"
release  = 1
summary  = "Compression library implementing the deflate algorithm"
homepage = "https://www.zlib.net/"
license  = ["Zlib"]
arch     = ["x86_64"]

depends     = ["glibc"]          # runtime deps (Blueberry names)
makedepends = ["gcc", "make"]    # build-only (from the build sandbox)
provides    = ["libz.so"]
options     = []                 # e.g. ["!lto", "!strip"]

[[source]]
url    = "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
sha256 = "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"

[steps]
build = '''
  cd "zlib-$version"
  ./configure --prefix=/usr
  make
'''
package = '''
  cd "zlib-$version"
  make DESTDIR="$pkgdir" install
'''

[scripts]
post_install = "ldconfig 2>/dev/null || true"
post_upgrade = "ldconfig 2>/dev/null || true"
post_remove  = "ldconfig 2>/dev/null || true"
```

### Tables and keys

**`[package]`** — metadata:

| Key | Required | Notes |
|---|---|---|
| `name` | yes | |
| `version` | yes | |
| `release` | no (default 1) | |
| `summary` | recommended | |
| `homepage` | no | |
| `license` | no | array of SPDX ids |
| `arch` | no (default `["x86_64"]`) | `["any"]` for arch-independent |
| `depends` | no | runtime closure (Blueberry package names) |
| `makedepends` | no | build-only; resolved by the build sandbox |
| `provides` | no | sonames / virtuals |
| `options` | no | build toggles (`!lto`, `!strip`, …) |

**`[[source]]`** — one table per source (array-of-tables). Each has:
- `url` — download URL (`$version`, `$name`, `$release` are substituted)
- `sha256` — mandatory hash, or the literal `"SKIP"` for always-latest vendor
  binaries (the same escape hatch as today's `SKIP` sums)

**`[steps]`** — the imperative part:
- `build` — configure/compile. Runs with CWD = `$srcdir`.
- `package` — install into `$pkgdir`. Runs under `fakeroot` so ownership is
  captured without real root.

> **Why `[steps]` and not top-level `build`/`package`?** A top-level `package`
> key collides with the `[package]` table in TOML. The explicit `[steps]` table
> avoids the ambiguity. (This was the first bug found while building the
> prototype.)

**`[scripts]`** — optional install hooks, each a shell snippet:
`post_install`, `post_upgrade`, `post_remove`.

### Environment available to steps

| Var | Value |
|---|---|
| `$srcdir` | working dir; sources are fetched + auto-extracted here |
| `$pkgdir` | staging root; everything under it becomes the payload |
| `$name` `$version` `$release` | from `[package]` |
| `$arch` | resolved arch tag |
| `$SOURCE_DATE_EPOCH` | reproducible-build clock |

---

## 4. Building a package: `bpmbuild`

```sh
tools/bpmbuild <recipe-dir> <out-dir>
```

What it does, in order:

1. **Parse** `bpm.toml` with a real TOML parser (Python `tomllib`) — no bash
   `eval`, so tooling can read recipes safely.
2. **Fetch** each `[[source]]` to `$srcdir`, **verify** its `sha256` (or honor
   `SKIP`), and **auto-extract** tarballs so `build` can `cd` into them.
3. **Run** `[steps].build` then `[steps].package` (the latter under `fakeroot`).
4. **Synthesize** `.BPM` from the recipe + staged `$pkgdir` — computing
   `installed_size`, `payload_sha256`, and `build_date`.
5. **Emit** `tar(.BPM, payload) | zstd -19` → `name-version-release-arch.bpm`.

It runs inside the same ephemeral Arch build container the current pipeline
uses; the container needs `python fakeroot zstd curl` (plus whatever the
recipe's `makedepends` pull in).

```sh
# inside the build container:
python3 tools/bpmbuild experimental/recipes/zlib ./out
# → ./out/zlib-1.3.1-1-x86_64.bpm
```

---

## 5. Indexing a repo: `bpmrepo.sh`

```sh
tools/bpmrepo.sh <repo-dir>
```

Reads every `*.bpm` in the directory, extracts its `.BPM` manifest, and writes
`bpm.index` — **the exact same line format** the production indexer emits, so
`bpm`'s parser is unchanged:

```
name|version-release|filename|sha256|deps|installed_size|summary
zlib|1.3.1-1|zlib-1.3.1-1-x86_64.bpm|174a9dd9…|glibc|406181|Compression library …
```

If an ed25519 key is present (`BPM_SIGN_KEY`, default
`~/.config/bpm/repo-ed25519.pem`) it signs the index to `bpm.index.sig` — the
same detached raw-ed25519 signature `bpm` already verifies against the public
key baked into the binary. Serving and trust are identical to today.

---

## 6. Installing: how `bpm` reads `.bpm`

`bpm` gained `.bpm` support without disturbing the `.pkg.tar.zst` path — both
coexist during the transition:

- **Local file:** `bpm install ./foo-1.2.3-1-x86_64.bpm`
  (the CLI treats `*.bpm` like `*.pkg.tar.*` — a local package, not a repo name).
- **By name:** `bpm install foo` resolves it from the index like any package.

Internally, when the streaming installer hits the `.BPM` member it calls
`bpm_manifest_to_pkginfo()`, which translates the TOML manifest into the
internal representation the installer already uses:

```
.BPM (TOML)  ──translate──►  .PKGINFO-shape string   (name, version, size, deps…)
                              + synthesized install script  (post_install() { … })
```

So everything downstream — the disk-space pre-check, file-conflict detection,
atomic temp-rename writes, the database record, and the scriptlet runner — is
byte-for-byte the same code that installs a `.pkg.tar.zst`. Nothing in the
proven install path was rewritten; one branch was added.

The streaming property is preserved: because `.BPM` is the first tar member, bpm
reads the manifest, runs the disk pre-check, then streams payload files to disk
in bounded chunks (no full-archive buffering, even for a 200 MB package).

---

## 7. Converting PKGBUILD → bpm.toml

```sh
tools/pkgbuild2bpm packages/<name>/PKGBUILD > packages/<name>/bpm.toml
```

It **sources** the PKGBUILD in a sandboxed bash (so every `${pkgver%.*}`-style
expansion resolves exactly as makepkg would), captures the variables and the
bodies of `prepare()`/`build()`/`package()` via `declare -f`, maps
`$pkgver→$version` etc., and emits `bpm.toml`. `prepare()` is folded into the
front of `build`.

All **303** existing recipes convert without error. The output is a faithful
starting point to review — exotic bash (arrays built by loops, unusual quoting)
should be eyeballed, exactly like any automated port.

---

## 8. End-to-end walkthrough

The complete, verified loop (run inside the build container, then on a client):

```sh
# 1. Build two packages from recipes
python3 tools/bpmbuild experimental/recipes/hello ./repo
python3 tools/bpmbuild experimental/recipes/zlib  ./repo

# 2. Index + sign the repo
sh tools/bpmrepo.sh ./repo
#  → wrote ./repo/bpm.index (2 packages) [+ bpm.index.sig if key present]

# 3. Serve it
( cd ./repo && python3 -m http.server 8080 ) &

# 4. On a client: point at the repo and sync
echo 'myrepo http://server:8080/' > /etc/bpm/repos.conf
bpm update                 # :: 2 packages in index

# 5. Install by name — downloads, sha256-verifies, installs, runs scriptlets
bpm install zlib           # :: running post_install scriptlet for zlib
bpm install hello          # deps (glibc) resolve from the index
hello                      # → Hello, world!

# 6. Manage
bpm list                   # hello 2.12.1 / zlib 1.3.1
bpm remove hello
```

Every step above has been run and passes on the `feature/bpm-pkg-format` branch.

---

## 9. Reference tables

### Files & tools

| Path | Role |
|---|---|
| `doc/BPM-FORMAT.md` | Terse design spec |
| `doc/BPM-GUIDE.md` | This guide |
| `tools/bpmbuild` | recipe → `.bpm` (Python) |
| `tools/bpmrepo.sh` | `.bpm` dir → signed `bpm.index` (sh) |
| `tools/pkgbuild2bpm` | `PKGBUILD` → `bpm.toml` (Python) |
| `experimental/recipes/<name>/bpm.toml` | example recipes (zlib, hello) |
| `src/bpm-rs/src/pkg.rs` | `.BPM` translator + install path |

### `bpm.toml` vs `PKGBUILD`

| PKGBUILD | bpm.toml |
|---|---|
| `pkgname=` | `[package] name =` |
| `pkgver=` | `version =` |
| `pkgrel=` | `release =` |
| `pkgdesc=` | `summary =` |
| `depends=()` | `depends = [...]` |
| `makedepends=()` | `makedepends = [...]` |
| `source=()` + `sha256sums=()` | `[[source]]` `url=`/`sha256=` |
| `build() { … }` | `[steps] build = '''…'''` |
| `package() { … }` | `[steps] package = '''…'''` |
| `.install` `post_install()` | `[scripts] post_install = "…"` |

### `.bpm` vs `.pkg.tar.zst`

| | `.pkg.tar.zst` | `.bpm` |
|---|---|---|
| Container | zstd(tar) | zstd(tar) |
| Metadata member | `.PKGINFO` (key=value) | `.BPM` (TOML) |
| Member order | metadata early | `.BPM` first (guaranteed) |
| Payload hash in pkg | — | `payload_sha256` |
| Built by | `makepkg` | `bpmbuild` |
| Recipe | `PKGBUILD` (bash) | `bpm.toml` (TOML + steps) |

---

## 10. Design decisions & FAQ

**Why keep zstd+tar instead of a brand-new binary format?**
bpm already stream-installs it in a tiny, bounded working set; standard tools can
inspect it; and it sidesteps re-deriving battle-tested compression. The format is
"native" in what matters — extension, metadata, builder, and signature chain —
without reinventing containers.

**Why TOML for the manifest and recipe?**
It's parseable without a bash interpreter, so the recipe-hub, the website, and
CI can read and validate recipes; and it's unambiguous (the `[steps]` table fix).

**Why does the recipe still use shell for build/package?**
Building software is inherently imperative (configure/make/cmake). A declarative
wrapper around shell steps keeps metadata machine-readable while keeping every
build expressible — the same split makepkg uses, just with a parseable shell.

**Do both formats coexist?**
Yes, by design. bpm reads `.PKGINFO` and `.BPM`; the indexers and install path
handle either. This is what makes a gradual, reversible migration possible.

**What's left before production?**
Build the **whole** package set to `.bpm`, install-verify a desktop closure, then
flip the build/repo tooling — keeping `.pkg.tar.zst` readable for one release as
a rollback path. Until then this lives only on the dev branch.
