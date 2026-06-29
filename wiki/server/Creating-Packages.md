# Creating Packages

A package is a recipe in [`packages/<name>/`](../../packages). Every recipe is a
declarative **`bpm.toml`**, built into a native `.bpm` by `tools/build-bpm-pkg.sh`
(which drives `bpmbuild` in an ephemeral Arch container). The old `PKGBUILD` /
`makepkg` path has been fully retired.

## Anatomy of a `bpm.toml` recipe

```toml
# packages/hello/bpm.toml
[package]
name     = "hello"
version  = "2.12.1"
release  = 1
summary  = "GNU Hello — example package"
license  = ["GPL-3.0-or-later"]
arch     = ["x86_64"]
depends     = ["glibc"]            # runtime — Blueberry package names
makedepends = ["cmake", "ninja"]  # build-only — pulled from Arch in the container
enable      = ["hello.service"]   # optional: systemd units to enable on install

[[source]]
url    = "https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz"
sha256 = "..."                     # pin the source (or "SKIP")

[steps]
build = '''
cd "$name-$version"
./configure --prefix=/usr
make
'''
package = '''
cd "$name-$version"
make DESTDIR="$pkgdir" install
'''
```

The shell steps get `$srcdir $pkgdir $name $version $release $arch`. Build it:

```sh
ENGINE=podman tools/build-bpm-pkg.sh ../out hello
# → ../out/hello-2.12.1-1-x86_64.bpm
bpm install ../out/hello-2.12.1-1-x86_64.bpm
```

Key rules:

- **`depends` are runtime deps** and must be Blueberry package names (resolved
  from our mirror at install). **`makedepends` are build-only** and are pulled
  from Arch inside the throwaway build container.
- **Pin `sha256` per `[[source]]`** for reproducibility. For vendor binaries that
  should always fetch "latest," `SKIP` is acceptable.
- Install into `$pkgdir` with a `/usr` prefix.

`build-bpm-pkg.sh`:

- spins up `archlinux:latest`, installs `base-devel` + the recipe's `makedepends`,
- runs `bpmbuild` as a non-root builder with a fixed `SOURCE_DATE_EPOCH`,
- writes the `.bpm` to your out-dir,
- is **idempotent** — a package whose `.bpm` is newer than its `bpm.toml` is
  skipped.

## Patterns that come up a lot

This repo bootstrapped Qt 6, KDE Plasma, and GTK from source; the recurring
fixes are worth knowing:

- **GCC 16 strictness.** The build container ships GCC 16. Old C may need
  `-std=gnu17`; some C++ needs a forced `-include cstdint`. C23 is the default.
- **KDE Frameworks 6.** Need `qt6-tools` (LinguistTools) and `qt6-declarative`
  (Qml) as makedeps, and `-DBUILD_PYTHON_BINDINGS=OFF` to skip PySide.
- **Version matching.** Qt modules must build against the **exact** Qt version
  the container provides; KDE Frameworks must all share one version.
- **Wayland/X11 libs.** Compositor/desktop packages often need `vulkan-headers`,
  `wayland-protocols`, `plasma-wayland-protocols`, and specific `libx*` headers
  as makedeps.
- **Optional backends.** KDE apps expose `-DFORCE_NOT_REQUIRED_DEPENDENCIES=...`
  and feature flags (e.g. `-DGWENVIEW_IMAGEANNOTATOR=OFF`) to drop heavy optional
  deps.
- **Arch name mismatches.** A Blueberry package name may differ from Arch's
  (e.g. `polkit-kde-agent` vs `polkit-kde-agent-1`); use `provides=()` and the
  Arch name where the build needs it.

## Submitting a recipe

Open a pull request adding `packages/<name>/`. See [Contributing](Contributing).
