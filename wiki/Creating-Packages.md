# Creating Packages

Every package in Blueberry is a recipe in [`packages/<name>/PKGBUILD`](../packages).
The format is the familiar `PKGBUILD`; the build runs in an ephemeral container
via `tools/build-pkgs.sh`.

## Anatomy of a recipe

```sh
# packages/hello/PKGBUILD
pkgname=hello
pkgver=2.12.1
pkgrel=1
pkgdesc='GNU Hello — example package'
arch=('x86_64')
url='https://www.gnu.org/software/hello/'
license=('GPL-3.0-or-later')
depends=('glibc')                       # Blueberry package names (runtime)
makedepends=('cmake' 'ninja')           # pulled from Arch during the build only
source=("https://ftp.gnu.org/gnu/hello/hello-$pkgver.tar.gz")
sha256sums=('...')                       # pin the source

build() {
  cd "hello-$pkgver"
  ./configure --prefix=/usr
  make
}

package() {
  cd "hello-$pkgver"
  make DESTDIR="$pkgdir" install
}
```

Key rules:

- **`depends` are runtime deps** and must be Blueberry package names (resolved
  from our mirror at install). **`makedepends` are build-only** and are pulled
  from Arch inside the throwaway build container.
- **Pin `sha256sums`** for reproducibility. For vendor binaries that should
  always fetch "latest," `SKIP` is acceptable.
- Install into `$pkgdir` with a `/usr` prefix.

## Building it

```sh
ENGINE=podman tools/build-pkgs.sh ../out hello
# → ../out/hello-2.12.1-1-x86_64.pkg.tar.zst
```

`build-pkgs.sh`:

- spins up `archlinux:latest`, installs `base-devel`,
- runs `makepkg -s` as a non-root builder with a fixed `SOURCE_DATE_EPOCH`,
- writes the `.pkg.tar.zst` to your out-dir,
- is **idempotent** — a package already built and newer than its `PKGBUILD` is
  skipped.

Test the result locally:

```sh
bpm install ../out/hello-2.12.1-1-x86_64.pkg.tar.zst
```

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
