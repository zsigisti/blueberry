#!/bin/sh
# fetch-bpm.sh - grab a prebuilt .bpm from the mirror and unpack it into a root.
# Looks it up in the index, checks the sha256, caches it, extracts without .BPM.
#
# This is how glibc gets into the initramfs without using the build host's.
# The initramfs is put together at `make world` time, before the rootfs has a
# staged glibc, and a host older than the container (Ubuntu 24.04 has 2.39,
# the container 2.43) would bundle its own too-old libc and panic at boot.
#
# usage: fetch-bpm.sh <pkgname> <destroot> [cachedir]
#   destroot "-" only downloads + verifies into the cache (to seed obj/bpm-out)
#   BPM_MIRROR  default https://repo.blueberrylinux.org
set -eu

PKG=${1:?usage: fetch-bpm.sh <pkgname> <destroot> [cachedir]}
DEST=${2:?missing destroot}
CACHE=${3:-${BPM_CACHE:-${TMPDIR:-/tmp}/blueberry-bpm-cache}}
MIRROR=${BPM_MIRROR:-https://repo.blueberrylinux.org}

for t in curl zstd tar sha256sum awk; do
    command -v "$t" >/dev/null 2>&1 || { echo "fetch-bpm: need $t" >&2; exit 1; }
done
mkdir -p "$CACHE"
[ "$DEST" = "-" ] || mkdir -p "$DEST"

# index line: name|version|filename|sha256|deps|size|desc
# read the whole index first. piping curl into awk '...{exit}' closes the pipe
# on the first match and curl whines "(23) Failure writing output"
index=$(curl -fsSL -H 'Cache-Control: no-cache' "$MIRROR/bpm.index") \
    || { echo "fetch-bpm: cannot fetch $MIRROR/bpm.index" >&2; exit 1; }
line=$(printf '%s\n' "$index" | awk -F'|' -v p="$PKG" '$1==p {print; exit}')
[ -n "$line" ] || { echo "fetch-bpm: '$PKG' not found in $MIRROR/bpm.index" >&2; exit 1; }
file=$(printf '%s' "$line" | cut -d'|' -f3)
want=$(printf '%s' "$line" | cut -d'|' -f4)
[ -n "$file" ] && [ -n "$want" ] || { echo "fetch-bpm: malformed index line for '$PKG'" >&2; exit 1; }
cached="$CACHE/$file"

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

if [ "$DEST" = "-" ]; then
    echo "fetch-bpm: cached $file (no extract) -> $cached"
    exit 0
fi

echo "fetch-bpm: extracting $file -> $DEST"
# -p keeps setuid/setgid/sticky bits (see bpm-extract-record.sh)
zstd -dcq "$cached" | tar -xp -C "$DEST" --exclude .BPM 2>/dev/null
