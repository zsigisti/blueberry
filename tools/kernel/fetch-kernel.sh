#!/bin/sh
# usage: fetch-kernel.sh <bootdir> <stagedir> <linux_version> <localversion> <arch>
#
# Downloads the pinned prebuilt kernel (~20 MB) instead of compiling for hours.
# It only changes when someone runs `make kernel-publish`.
# KERNEL_BASE_URL overrides https://repo.blueberrylinux.org/kernel.
#
# The artifact is a zstd tarball, checked against a .sha256 next to it:
#   boot/vmlinuz
#   boot/System.map-<ver><localversion>
#   lib/modules/<release>/...
set -eu

BOOTDIR=${1:?usage: fetch-kernel.sh <bootdir> <stagedir> <ver> <localversion> <arch>}
STAGEDIR=${2:?missing stagedir}
VER=${3:?missing linux_version}
LOCALVER=${4:?missing localversion}
ARCH=${5:?missing arch}
BASE_URL=${KERNEL_BASE_URL:-https://repo.blueberrylinux.org/kernel}

ART="blueberry-kernel-${VER}${LOCALVER}-${ARCH}.tar.zst"
URL="$BASE_URL/$ART"
CACHE_DIR="$(dirname "$BOOTDIR")/src"
CACHE="$CACHE_DIR/$ART"
mkdir -p "$BOOTDIR" "$CACHE_DIR" "$STAGEDIR/usr/lib/modules"

# marker says which artifact is unpacked here
MARKER="$BOOTDIR/.kernel-artifact"
if [ -f "$BOOTDIR/vmlinuz" ] && [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$ART" ]; then
    echo "[kernel] prebuilt $ART already installed"
    exit 0
fi

if [ ! -f "$CACHE" ]; then
    echo "[kernel] fetching prebuilt $ART"
    curl -fL --retry 3 -o "$CACHE.tmp" "$URL" || {
        echo "ERROR: could not download $URL" >&2
        echo "       The pinned kernel artifact is missing from the repo." >&2
        echo "       Build + publish it on a build box with: make kernel-publish" >&2
        echo "       Or compile locally this once with:       make kernel-rebuild" >&2
        rm -f "$CACHE.tmp"; exit 1
    }
    mv "$CACHE.tmp" "$CACHE"
fi
if curl -fsL "$URL.sha256" -o "$CACHE.sha256" 2>/dev/null; then
    want=$(awk '{print $1}' "$CACHE.sha256")
    got=$(sha256sum "$CACHE" | awk '{print $1}')
    [ "$want" = "$got" ] || { echo "ERROR: sha256 mismatch for $ART (want $want got $got)" >&2; rm -f "$CACHE"; exit 1; }
    echo "[kernel] sha256 verified"
else
    echo "[kernel] WARNING: no .sha256 published for $ART, skipping integrity check" >&2
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
zstd -dcq "$CACHE" | tar -x -C "$TMP"
install -Dm644 "$TMP/boot/vmlinuz" "$BOOTDIR/vmlinuz"
for m in "$TMP"/boot/System.map-*; do
    [ -e "$m" ] || continue
    install -Dm644 "$m" "$BOOTDIR/$(basename "$m")"
    ln -sf "$(basename "$m")" "$BOOTDIR/System.map"
done
if [ -d "$TMP/lib/modules" ]; then
    cp -a "$TMP/lib/modules/." "$STAGEDIR/usr/lib/modules/"
fi
echo "$ART" > "$MARKER"
echo "[kernel] installed prebuilt $ART -> vmlinuz + modules"
