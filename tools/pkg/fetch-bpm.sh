#!/bin/sh
# fetch-bpm.sh — download a prebuilt .bpm package from the Blueberry mirror and
# extract it into a destination root. Looks the package up in the signed index,
# verifies its sha256, caches the download, and unpacks it (dropping the .BPM
# manifest member).
#
# This is how the pinned, container-built glibc gets into the initramfs without
# depending on the BUILD HOST's glibc. The build compiles every package in an
# Arch container (glibc 2.43); the initramfs is assembled at `make world` time,
# before the rootfs is populated, so there is no staged glibc to bundle yet. A
# host with an older glibc than the container (Ubuntu 24.04 ships 2.39) would
# otherwise get its own too-old libc bundled and panic at boot. Fetching the
# canonical glibc .bpm from the mirror makes the initramfs host-independent.
#
# Usage: fetch-bpm.sh <pkgname> <destroot> [cachedir]
# Env:   BPM_MIRROR (default https://repo.mmzsigmond.me)
set -eu

PKG=${1:?usage: fetch-bpm.sh <pkgname> <destroot> [cachedir]}
DEST=${2:?missing destroot}
CACHE=${3:-${BPM_CACHE:-${TMPDIR:-/tmp}/blueberry-bpm-cache}}
MIRROR=${BPM_MIRROR:-https://repo.mmzsigmond.me}

for t in curl zstd tar sha256sum awk; do
    command -v "$t" >/dev/null 2>&1 || { echo "fetch-bpm: need $t" >&2; exit 1; }
done
mkdir -p "$CACHE" "$DEST"

# Index line: name|version|filename|sha256|deps|size|desc
# Fetch the whole index into a variable first, THEN parse — piping curl straight
# into `awk '…{exit}'` makes awk close the pipe on the first match, so curl fails
# writing the rest of the index with a noisy "(23) Failure writing output".
index=$(curl -fsSL -H 'Cache-Control: no-cache' "$MIRROR/bpm.index") \
    || { echo "fetch-bpm: cannot fetch $MIRROR/bpm.index" >&2; exit 1; }
line=$(printf '%s\n' "$index" | awk -F'|' -v p="$PKG" '$1==p {print; exit}')
[ -n "$line" ] || { echo "fetch-bpm: '$PKG' not found in $MIRROR/bpm.index" >&2; exit 1; }
file=$(printf '%s' "$line" | cut -d'|' -f3)
want=$(printf '%s' "$line" | cut -d'|' -f4)
[ -n "$file" ] && [ -n "$want" ] || { echo "fetch-bpm: malformed index line for '$PKG'" >&2; exit 1; }
cached="$CACHE/$file"

# Download (cached) + verify sha256 against the index.
if [ ! -f "$cached" ] || [ "$(sha256sum "$cached" | cut -d' ' -f1)" != "$want" ]; then
    echo "fetch-bpm: downloading $file from $MIRROR"
    curl -fL --retry 3 -o "$cached.tmp" "$MIRROR/$file"
    got=$(sha256sum "$cached.tmp" | cut -d' ' -f1)
    [ "$got" = "$want" ] || {
        echo "fetch-bpm: sha256 mismatch for $file (want $want got $got)" >&2
        rm -f "$cached.tmp"; exit 1
    }
    mv "$cached.tmp" "$cached"
else
    echo "fetch-bpm: using cached $file"
fi

echo "fetch-bpm: extracting $file -> $DEST"
zstd -dcq "$cached" | tar -x -C "$DEST" --exclude .BPM 2>/dev/null
