#!/bin/sh
# mkrepo.sh — build a bpm repository index from a directory of .pkg.tar.zst files.
#
# Usage: tools/mkrepo.sh <repo-dir>
#   Reads every *.pkg.tar.zst in <repo-dir>, extracts its .PKGINFO, and writes
#   <repo-dir>/bpm.index. Serve <repo-dir> over HTTP and point a client's
#   /etc/bpm/repos.conf at it; `bpm update` fetches bpm.index from there.
#
# Index line:  name|version|filename|sha256|deps|size|desc
#   size = installed size in bytes (from .PKGINFO); desc = one-line description.
#   bpm appends a |repo column per line on `bpm update`.
#
# Integrity: the per-package sha256 here is verified on every download, AND the
# whole index is signed with ed25519 (bpm.index.sig) if a key is available
# (BPM_SIGN_KEY, default ~/.config/bpm/repo-ed25519.pem). bpm verifies the
# signature against the public key baked into src/bpm-rs/src/repokey.rs
# (regenerate with tools/mkrepokey.sh after rotating the key).

set -eu
REPO="${1:-.}"
[ -d "$REPO" ] || { echo "mkrepo: no such dir: $REPO" >&2; exit 1; }
for t in zstd tar sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { echo "mkrepo: need $t" >&2; exit 1; }
done
SIGN_KEY="${BPM_SIGN_KEY:-$HOME/.config/bpm/repo-ed25519.pem}"

field() { awk -v k="$1" -F ' = ' '$1==k{print $2}'; }
pkginfo() { zstd -dcq "$1" | tar -xO -f - .PKGINFO 2>/dev/null \
            || zstd -dcq "$1" | tar -xO -f - ./.PKGINFO 2>/dev/null; }
# Strip the field separator from free text so a description can't corrupt the row.
clean() { tr '|\n' '  '; }

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
    size=$(printf '%s\n' "$info" | field size); size=${size:-0}
    desc=$(printf '%s\n' "$info" | field pkgdesc | clean)
    sha=$(sha256sum "$pkg" | cut -d' ' -f1)
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$name" "$ver" "$(basename "$pkg")" "$sha" "$deps" "$size" "$desc" >> "$out.tmp"
    n=$((n + 1))
done
sort -o "$out.tmp" "$out.tmp"
mv "$out.tmp" "$out"
echo "mkrepo: wrote $out ($n packages)"

# Sign the index (detached raw ed25519 over the index bytes).
if [ -f "$SIGN_KEY" ] && command -v openssl >/dev/null 2>&1; then
    openssl pkeyutl -sign -inkey "$SIGN_KEY" -rawin -in "$out" -out "$out.sig"
    echo "mkrepo: signed $out.sig with $SIGN_KEY"
else
    echo "mkrepo: no signing key at $SIGN_KEY — index left UNSIGNED" >&2
    echo "mkrepo: clients without BPM_ALLOW_UNSIGNED will reject it" >&2
    rm -f "$out.sig"
fi
