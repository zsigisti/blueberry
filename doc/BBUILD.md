# BBUILD Reference

A `BBUILD` is a shell script that defines how to build and package a piece
of software for Blueberry Linux. It consists of **variable declarations**
followed by two shell functions: `build()` and `package()`.

## 1. File Structure

```sh
# ── Header variables ─────────────────────────────────────────────────────────
name=example
version=1.0.0
release=1
description="Example package"
url="https://example.com/"
license="MIT"
arch=("x86_64" "aarch64")
depends=("musl" "zlib")
makedepends=("gcc" "make")
source=("https://example.com/example-$version.tar.gz")
checksums=("sha256:abc123...")
packager="Your Name <you@example.com>"

# ── Build function ───────────────────────────────────────────────────────────
build() {
    cd "$name-$version"
    ./configure --prefix=/usr
    make
}

# ── Package function ─────────────────────────────────────────────────────────
package() {
    cd "$name-$version"
    make DESTDIR="$pkgdir" install
}
```

---

## 2. Header Variables

### Required

| Variable | Type | Description |
|----------|------|-------------|
| `name` | string | Package name. `[a-z0-9][a-z0-9+._-]*`. Must match directory name. |
| `version` | string | Upstream version string. |
| `description` | string | One-line description, < 80 characters. |
| `url` | string | Upstream home page. |
| `license` | string | SPDX identifier: `MIT`, `GPL-2.0`, `Apache-2.0`, etc. |
| `source` | array | Source archive URLs or local paths. |

### Optional

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `release` | integer | `1` | Increment when packaging changes but version doesn't. |
| `arch` | array | `("x86_64" "aarch64")` | Supported architectures. Use `("noarch")` for scripts/data. |
| `depends` | array | `()` | Runtime dependencies. May include version constraints. |
| `makedepends` | array | `()` | Build-time-only dependencies. Not installed on target. |
| `checkdepends` | array | `()` | Dependencies required only for `bpm check`. |
| `provides` | array | `()` | Virtual packages this provides, e.g. `("sh")`. |
| `conflicts` | array | `()` | Packages that cannot be installed simultaneously. |
| `replaces` | array | `()` | Packages this supersedes (triggers automatic replacement). |
| `checksums` | array | `()` | Checksums for each source, in order. Use `"SKIP"` to skip. |
| `backup` | array | `()` | Config files preserved during upgrade: `etc/foo/bar.conf` |
| `install` | string | `""` | Path to an install script (alternative to inline functions). |
| `packager` | string | `""` | `Name <email>` of the maintainer. |
| `options` | array | `()` | Build options: `!strip`, `!docs`, `staticlibs`, etc. |

---

## 3. Build Environment

When `bpm build` executes `build()` and `package()`, the following variables
are in scope:

| Variable | Value | Description |
|----------|-------|-------------|
| `srcdir` | `<workdir>/src` | Source directory. Archives are extracted here. |
| `pkgdir` | `<workdir>/pkg` | Staging root. Install files here with DESTDIR. |
| `name` | from header | Package name. |
| `version` | from header | Package version. |
| `release` | from header | Release number. |
| `MAKEFLAGS` | `-j<JOBS>` | Passed to make automatically. |
| `CC` | `musl-gcc` | C compiler (wraps host gcc with musl paths). |
| `CXX` | `musl-g++` | C++ compiler. |
| `CFLAGS` | `-Os -pipe` | Default optimization flags. |
| `CXXFLAGS` | same | C++ flags. |
| `LDFLAGS` | `-Wl,-z,relro,-z,now` | Linker hardening flags. |
| `ARCH` | e.g. `x86_64` | Target architecture. |
| `PATH` | standard path | Includes sysroot bin. |

The `build()` function runs with the current directory set to `srcdir`.

---

## 4. Source Handling

Each entry in `source` is:

- **A URL**: downloaded with `wget` to `srcdir/` and extracted if it is a
  recognized archive format (`.tar.gz`, `.tar.bz2`, `.tar.xz`, `.tar.zst`,
  `.zip`).
- **A local path**: relative to the BBUILD's directory. Copied into `srcdir/`.
- **A bare filename**: looked up in `srcdir/`.

URLs may contain `$name` and `$version` interpolations:

```sh
source=("https://example.com/$name-$version.tar.gz")
```

### Checksums

`checksums` has one entry per `source` entry. Use `sha256:` prefix:

```sh
checksums=("sha256:a1b2c3d4...")
```

To skip checksum verification for a source (e.g. local patches):

```sh
checksums=("sha256:abc..." "SKIP")
```

---

## 5. The `build()` Function

`build()` must compile the software. It should:
- `cd` into the unpacked source directory.
- Run `./configure`, `cmake`, `meson setup`, etc.
- Run `make`, `ninja`, `cargo build`, `go build`, etc.

Do **not** install anything in `build()`. Installation happens in `package()`.

```sh
build() {
    cd "$name-$version"
    ./configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var
    make
}
```

For Go packages:
```sh
build() {
    export GOPATH="$srcdir/go"
    CGO_ENABLED=0 go build \
        -trimpath \
        -ldflags "-s -w" \
        -o "$srcdir/$name" .
}
```

For Meson packages:
```sh
build() {
    cd "$name-$version"
    meson setup \
        --prefix=/usr \
        --buildtype=plain \
        build
    ninja -C build
}
```

---

## 6. The `package()` Function

`package()` must install files into `$pkgdir`. Everything under `$pkgdir`
becomes a file in the `.bb` archive, installed at the same path relative to
`/` on the target system.

**Golden rules:**
1. Always use `DESTDIR="$pkgdir"` with `make install`.
2. Never install to `/` — only to `$pkgdir`.
3. Remove files that are not wanted: static libs, Perl modules, test suites.
4. Fix permissions explicitly rather than assuming `make install` does it right.

```sh
package() {
    cd "$name-$version"
    make DESTDIR="$pkgdir" install

    # Remove static libraries (we ship shared only)
    find "$pkgdir" -name '*.a' -delete

    # Remove info/locale files we don't ship
    rm -rf "$pkgdir/usr/share/info"
    rm -rf "$pkgdir/usr/share/locale"

    # Fix ownership (DESTDIR may carry host UID)
    find "$pkgdir" -exec chown root:root {} +
}
```

---

## 7. Subpackages

A single BBUILD can produce multiple `.bb` files by defining additional
`package_<subname>()` functions:

```sh
name=libfoo
version=1.0
...

package() {
    cd "$name-$version"
    make DESTDIR="$pkgdir" install
    # Main package: runtime library only
    rm -rf "$pkgdir/usr/include"
    rm -rf "$pkgdir/usr/lib/pkgconfig"
}

package_dev() {
    pkgname="libfoo-dev"
    pkgdesc="development files for libfoo"
    depends=("libfoo=$version-$release")
    # Move headers and .pc into this subpackage
    mkdir -p "$pkgdir/usr/include" "$pkgdir/usr/lib/pkgconfig"
    mv "$srcdir/$name-$version/pkgdir_main/usr/include/"* "$pkgdir/usr/include/"
    mv "$srcdir/$name-$version/pkgdir_main/usr/lib/pkgconfig/"* \
       "$pkgdir/usr/lib/pkgconfig/"
}
```

bpm produces `libfoo-1.0-1-x86_64.bb` and `libfoo-dev-1.0-1-x86_64.bb`.

---

## 8. Install Scripts

Create lifecycle hooks as files next to BBUILD and reference them:

```
pkgs/core/openssh/
  BBUILD
  openssh.pre-install     # run before installing
  openssh.post-install    # run after installing
  openssh.pre-remove      # run before removing
  openssh.post-remove     # run after removing
```

In BBUILD:
```sh
install=openssh
```

bpm bundles these as `.SCRIPTS/` entries in the archive.

Example `openssh.post-install`:
```sh
#!/bin/sh
# Create sshd privilege separation user if it doesn't exist
id sshd >/dev/null 2>&1 || \
    adduser -D -H -h /var/empty -s /sbin/nologin sshd

# Create privilege separation directory
install -dm 0755 /var/empty
chown root:sshd /var/empty
```

---

## 9. The `options` Array

| Option | Effect |
|--------|--------|
| `!strip` | Do not strip debug symbols from binaries |
| `!docs` | Do not remove doc files |
| `!emptydirs` | Do not remove empty directories after install |
| `staticlibs` | Keep `.a` static libraries (removed by default) |
| `debug` | Package debug symbols in a `-dbg` subpackage |

Example:
```sh
options=("!strip" "staticlibs")
```

---

## 10. `backup` — Protecting Config Files

Files listed in `backup` are preserved during `bpm upgrade`. If the user has
modified the file, the new version is installed as `file.bpmnew` and a
warning is printed.

```sh
backup=("etc/openssh/sshd_config"
        "etc/openssh/ssh_config")
```

---

## 11. Best Practices

**Do:**
- Use `--prefix=/usr` for configure scripts.
- Use `--sysconfdir=/etc` and `--localstatedir=/var`.
- Strip binaries unless debug info is needed.
- Remove `.la` (libtool archive) files.
- Use `install -Dm755` instead of `cp` for executables.
- Set `makedepends` for anything only needed to compile.

**Don't:**
- Call `sudo` in build or package functions.
- Hardcode paths like `/home/user/blueberry`.
- Download additional sources during `build()` — put them in `source`.
- Install to `/usr/local/` — that prefix is for the user.

---

## 12. Complete Example: zlib

```sh
name=zlib
version=1.3.1
release=1
description="a massively spiffy yet delicately unobtrusive compression library"
url="https://zlib.net/"
license="Zlib"
arch=("x86_64" "aarch64" "riscv64")
depends=("musl")
makedepends=()
source=("https://zlib.net/zlib-$version.tar.gz")
checksums=("sha256:9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23")
packager="Blueberry Maintainers <maintainers@blueberry.mmzsigmond.me>"

build() {
    cd "$name-$version"
    CC=musl-gcc ./configure --prefix=/usr --shared
    make
}

package() {
    cd "$name-$version"
    make DESTDIR="$pkgdir" install
    rm -f "$pkgdir/usr/lib/libz.a"
    rm -rf "$pkgdir/usr/share/man"
}
```
