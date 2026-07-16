#!/bin/sh
# mk-blueberry-builder.sh — assemble a self-hosted Blueberry build container.
#
# The package build container has always been Arch (docker.io/library/archlinux
# + pacman for the toolchain). This bakes a Blueberry image instead: the base
# runtime rootfs + Blueberry's own toolchain packages, so builds compile with
# Blueberry's gcc/binutils/make/rust/… and never touch Arch.
#
# Prereqs (build them first):
#   make install                 # produces the base rootfs ($STAGEDIR)
#   bbdev build <toolchain…>     # or `make repo-build` — .bpm into obj/bpm-out
# The pinned glibc .bpm is taken from the install cache (headers included; the
# base rootfs is runtime-only and has them stripped).
#
# Usage:  tools/build/mk-blueberry-builder.sh
#         ENGINE=podman TAG=localhost/blueberry-builder tools/build/mk-blueberry-builder.sh
set -eu

cd "$(dirname "$0")/../.."
TOP=$(pwd)
ENGINE=${ENGINE:-podman}
TAG=${TAG:-localhost/blueberry-builder}
OUT=${OUT:-$TOP/obj/bpm-out}
ROOTFS=${ROOTFS:-$TOP/../blueberry-build/rootfs}
CACHE=${CACHE:-$TOP/../blueberry-build/bpm-cache}

# podman/import writes multi-GB temp blobs; keep them off a small / .
if [ -z "${TMPDIR:-}" ] && [ -d /tmp ]; then export TMPDIR=/tmp; fi

# The toolchain to bake in: everything a typical recipe's build needs beyond the
# runtime base. Package-specific makedeps are installed per-build on top.
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
# Skip packages not present (tar/python/… come from the runtime base, not
# obj/bpm-out); never let a missing/failed extract abort the whole layering.
extract() {
    for f in "$@"; do
        [ -e "$f" ] || continue
        zstd -dcq "$f" | tar -x -C / --exclude=.BPM 2>/dev/null || echo "  warn: extract $f failed" >&2
    done
    return 0
}
# glibc (headers; the runtime base strips /usr/include) + kernel headers first
extract /cache/glibc-*.bpm /out/glibc-*.bpm /out/linux-api-headers-*.bpm
for p in '"$TOOLCHAIN"'; do extract /out/"$p"-[0-9]*.bpm; done
# smoke test: the compiler works end to end
printf "int main(void){return 0;}\n" > /tmp/t.c
gcc -o /tmp/t /tmp/t.c && echo "  gcc: $(gcc --version | head -1) — compiles + links OK"
command -v pacman >/dev/null && { echo "  ERROR: pacman present"; exit 1; } || echo "  no pacman — pure Blueberry"
')
"$ENGINE" wait "$cid" >/dev/null
"$ENGINE" logs "$cid" 2>&1 | sed 's/^/    /'
"$ENGINE" commit -q "$cid" "$TAG:latest" >/dev/null
"$ENGINE" rm "$cid" >/dev/null

echo "==> built $TAG:latest ($("$ENGINE" images --format '{{.Size}}' "$TAG:latest" 2>/dev/null))"
echo "    build a package in it, no Arch:"
echo "      $ENGINE run --rm --network=host -v \$PWD:/repo:ro,z $TAG python3 /repo/tools/pkg/bpmbuild /repo/packages/<pkg> /tmp/out"
