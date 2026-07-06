#!/bin/sh
# fetch-kernel.sh — install a PREBUILT, pinned Blueberry kernel instead of
# compiling it. Blueberry's kernel is not rolling: it's a fixed binary artifact
# (vmlinuz + System.map + modules) hosted on the package repo, bumped only when
# someone runs `make kernel-publish` on a build box. A normal `make` just
# downloads ~20 MB and unpacks it — no multi-hour kernel compile on small boxes.
#
# Usage: fetch-kernel.sh <bootdir> <stagedir> <linux_version> <localversion> <arch>
# Env:   KERNEL_BASE_URL  (default https://repo.mmzsigmond.me/kernel)
#
# Layout of the artifact (zstd tarball, rooted):
#   boot/vmlinuz
#   boot/System.map-<ver><localversion>
#   lib/modules/<release>/...
# It is verified against a sibling .sha256 before unpacking.
set -eu

BOOTDIR=${1:?usage: fetch-kernel.sh <bootdir> <stagedir> <ver> <localversion> <arch>}
STAGEDIR=${2:?missing stagedir}
VER=${3:?missing linux_version}
LOCALVER=${4:?missing localversion}
ARCH=${5:?missing arch}
BASE_URL=${KERNEL_BASE_URL:-https://repo.mmzsigmond.me/kernel}

ART="blueberry-kernel-${VER}${LOCALVER}-${ARCH}.tar.zst"
URL="$BASE_URL/$ART"
CACHE_DIR="$(dirname "$BOOTDIR")/src"
CACHE="$CACHE_DIR/$ART"
mkdir -p "$BOOTDIR" "$CACHE_DIR" "$STAGEDIR/usr/lib/modules"

# Already installed? vmlinuz present and a marker matching this exact artifact.
MARKER="$BOOTDIR/.kernel-artifact"
if [ -f "$BOOTDIR/vmlinuz" ] && [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$ART" ]; then
    echo "[kernel] prebuilt $ART already installed"
    exit 0
fi

# Download (cached) + verify sha256.
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
    echo "[kernel] WARNING: no .sha256 published for $ART — skipping integrity check" >&2
fi

# Unpack: vmlinuz/System.map → bootdir, modules → stagedir.
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
echo "[kernel] installed prebuilt $ART → vmlinuz + modules"
