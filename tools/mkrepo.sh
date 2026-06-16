#!/bin/sh
# mkrepo.sh — build a bpm repository index from a directory of .pkg.tar.zst files.
#
# Usage: tools/mkrepo.sh <repo-dir>
#   Reads every *.pkg.tar.zst in <repo-dir>, extracts its .PKGINFO, and writes
#   <repo-dir>/bpm.index. Serve <repo-dir> over HTTP and point a client's
#   /etc/bpm/repos.conf at it; `bpm update` fetches bpm.index from there.
#
# Index line:  name|version|filename|sha256|dep1,dep2,...
#
# Integrity is the per-package sha256 recorded here: clients verify every
# download against it, and the index is served over TLS. No index signing.

set -eu
REPO="${1:-.}"
[ -d "$REPO" ] || { echo "mkrepo: no such dir: $REPO" >&2; exit 1; }
for t in zstd tar sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { echo "mkrepo: need $t" >&2; exit 1; }
done

field() { awk -v k="$1" -F ' = ' '$1==k{print $2}'; }
pkginfo() { zstd -dcq "$1" | tar -xO -f - .PKGINFO 2>/dev/null \
            || zstd -dcq "$1" | tar -xO -f - ./.PKGINFO 2>/dev/null; }

out="$REPO/bpm.index"
: > "$out.tmp"
n=0
for pkg in "$REPO"/*.pkg.tar.zst; do
    [ -f "$pkg" ] || continue
    info=$(pkginfo "$pkg") || { echo "mkrepo: skip (no .PKGINFO): $pkg" >&2; continue; }
    name=$(printf '%s\n' "$info" | field pkgname)
    ver=$(printf '%s\n' "$info" | field pkgver)
    [ -n "$name" ] || { echo "mkrepo: skip (no pkgname): $pkg" >&2; continue; }
    deps=$(printf '%s\n' "$info" | field depend | paste -sd, -)
    sha=$(sha256sum "$pkg" | cut -d' ' -f1)
    printf '%s|%s|%s|%s|%s\n' "$name" "$ver" "$(basename "$pkg")" "$sha" "$deps" >> "$out.tmp"
    n=$((n + 1))
done
sort -o "$out.tmp" "$out.tmp"
mv "$out.tmp" "$out"
# Drop any stale signature from older signed repos.
rm -f "$out.sig"
echo "mkrepo: wrote $out ($n packages)"
