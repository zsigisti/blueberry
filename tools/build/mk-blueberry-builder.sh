#!/bin/sh
# Build container made of Blueberry itself: the base rootfs plus our own
# toolchain packages, no Arch anywhere. (mk-builder-image.sh is the old Arch one.)
#
# Needs `make install` (the rootfs) and the toolchain .bpms in obj/bpm-out
# (`bbdev build ...` or `make repo-build`). glibc comes from the install cache
# because the rootfs copy has its headers stripped.
#
# usage: [ENGINE=podman] [TAG=localhost/blueberry-builder] tools/build/mk-blueberry-builder.sh
set -eu

cd "$(dirname "$0")/../.."
TOP=$(pwd)
ENGINE=${ENGINE:-podman}
TAG=${TAG:-localhost/blueberry-builder}
OUT=${OUT:-$TOP/obj/bpm-out}
ROOTFS=${ROOTFS:-$TOP/../blueberry-build/rootfs}
CACHE=${CACHE:-$TOP/../blueberry-build/bpm-cache}

# import writes multi-GB temp blobs
if [ -z "${TMPDIR:-}" ] && [ -d /tmp ]; then export TMPDIR=/tmp; fi

# what most recipes need; per-package makedeps get added at build time
TOOLCHAIN="gcc binutils make m4 autoconf automake libtool bison flex gperf pkgconf \
patch diffutils findutils gawk gzip xz zstd tar sed grep coreutils bash \
gettext texinfo help2man meson ninja cmake go rust llvm python curl \
gmp mpfr mpc zlib ncurses libffi readline"

[ -d "$ROOTFS" ] || { echo "mk-blueberry-builder: no base rootfs at $ROOTFS (run 'make install')" >&2; exit 1; }

echo "==> importing base rootfs as ${TAG}-base"
tar -C "$ROOTFS" -cf - . | "$ENGINE" import --change 'CMD ["/usr/bin/bash"]' - "${TAG}-base:latest"

echo "==> layering toolchain + dev headers"
cid=$("$ENGINE" run -d -v "$OUT:/out:ro,z" -v "$CACHE:/cache:ro,z" "${TAG}-base:latest" /usr/bin/bash -c '
set -e
# some of these (tar, python...) are already in the base and not in /out.
# a missing or broken one is a warning, not a reason to stop
extract() {
    for f in "$@"; do
        [ -e "$f" ] || continue
        zstd -dcq "$f" | tar -x -C / --exclude=.BPM 2>/dev/null || echo "  warn: extract $f failed" >&2
    done
    return 0
}
# headers first: glibc (base has no /usr/include) and the kernel ones
extract /cache/glibc-*.bpm /out/glibc-*.bpm /out/linux-api-headers-*.bpm
for p in '"$TOOLCHAIN"'; do extract /out/"$p"-[0-9]*.bpm; done
rm -rf /usr/lib/firmware /usr/lib/modules /lib/firmware \
       /usr/share/man /usr/share/doc /usr/share/info /usr/share/gtk-doc \
       /usr/share/locale /var/cache/* /var/log/* /usr/lib/systemd/system/*.target.wants \
       /usr/lib/linux-firmware* 2>/dev/null || true
# build tools only need the C locales
[ -d /usr/lib/locale ] && find /usr/lib/locale -mindepth 1 -maxdepth 1 ! -name 'C.*' -exec rm -rf {} + 2>/dev/null || true
printf "int main(void){return 0;}\n" > /tmp/t.c
gcc -o /tmp/t /tmp/t.c && echo "  gcc: $(gcc --version | head -1), compiles + links OK"
command -v pacman >/dev/null && { echo "  ERROR: pacman present"; exit 1; } || echo "  no pacman, pure Blueberry"
')
"$ENGINE" wait "$cid" >/dev/null
"$ENGINE" logs "$cid" 2>&1 | sed 's/^/    /'
# export|import, not commit: commit keeps the deleted files in the lower layer
# and the image doesn't shrink at all
echo "==> flattening (export|import) to apply the slim"
"$ENGINE" export "$cid" | "$ENGINE" import --change 'CMD ["/usr/bin/bash"]' - "$TAG:latest" >/dev/null
"$ENGINE" rm "$cid" >/dev/null
"$ENGINE" rmi "${TAG}-base:latest" >/dev/null 2>&1 || true

echo "==> built $TAG:latest ($("$ENGINE" images --format '{{.Size}}' "$TAG:latest" 2>/dev/null))"
echo "    build a package in it, no Arch:"
echo "      $ENGINE run --rm --network=host -v \$PWD:/repo:ro,z $TAG python3 /repo/tools/pkg/bpmbuild /repo/packages/<pkg> /tmp/out"
