#!/bin/sh
# bpmrepo.sh — build a bpm repository index from a directory of native .bpm files.
#
# EXPERIMENTAL (feature/bpm-pkg-format). The .bpm sibling of tools/mkrepo.sh:
# it reads each .bpm's TOML `.BPM` manifest instead of a `.PKGINFO`, and emits
# the SAME index line format, so bpm's existing index parser + ed25519 signing
# work unchanged.
#
# Usage: tools/bpmrepo.sh <repo-dir>
#   Index line:  name|version|filename|sha256|deps|size|desc
set -eu
REPO="${1:-.}"
[ -d "$REPO" ] || { echo "bpmrepo: no such dir: $REPO" >&2; exit 1; }
for t in zstd tar sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { echo "bpmrepo: need $t" >&2; exit 1; }
done
SIGN_KEY="${BPM_SIGN_KEY:-$HOME/.config/bpm/repo-ed25519.pem}"

# Read the .BPM TOML member of a .bpm.
bpmmeta() { zstd -dcq "$1" | tar -xO -f - .BPM 2>/dev/null \
            || zstd -dcq "$1" | tar -xO -f - ./.BPM 2>/dev/null; }
# Scalar string:  key = "value"  → value
tval() { awk -v k="$1" -F' = ' '$1==k{v=$2; gsub(/^"|"$/,"",v); print v; exit}'; }
# Int:  key = 123 → 123
tint() { awk -v k="$1" -F' = ' '$1==k{print $2; exit}'; }
# String array:  key = ["a", "b"] → a,b
tarr() { awk -v k="$1" -F' = ' '$1==k{print $2; exit}' \
         | sed 's/^\[//;s/\]$//;s/"//g;s/, */,/g;s/^ *//;s/ *$//'; }
clean() { tr '|\n' '  '; }

out="$REPO/bpm.index"
: > "$out.tmp"
n=0
for pkg in "$REPO"/*.bpm; do
    [ -f "$pkg" ] || continue
    meta=$(bpmmeta "$pkg") || { echo "bpmrepo: skip (no .BPM): $pkg" >&2; continue; }
    name=$(printf '%s\n' "$meta" | tval name)
    ver=$(printf '%s\n'  "$meta" | tval version)
    rel=$(printf '%s\n'  "$meta" | tint release)
    [ -n "$name" ] || { echo "bpmrepo: skip (no name): $pkg" >&2; continue; }
    [ -n "$rel" ] && ver="$ver-$rel"
    deps=$(printf '%s\n' "$meta" | tarr depends)
    size=$(printf '%s\n' "$meta" | tint installed_size); size=${size:-0}
    desc=$(printf '%s\n' "$meta" | tval summary | clean)
    sha=$(sha256sum "$pkg" | cut -d' ' -f1)
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$name" "$ver" "$(basename "$pkg")" "$sha" "$deps" "$size" "$desc" >> "$out.tmp"
    n=$((n + 1))
done
sort -o "$out.tmp" "$out.tmp"
mv "$out.tmp" "$out"
echo "bpmrepo: wrote $out ($n packages)"

if [ -f "$SIGN_KEY" ] && command -v openssl >/dev/null 2>&1; then
    openssl pkeyutl -sign -inkey "$SIGN_KEY" -rawin -in "$out" -out "$out.sig"
    echo "bpmrepo: signed $out.sig with $SIGN_KEY"
else
    echo "bpmrepo: no signing key at $SIGN_KEY — index left UNSIGNED" >&2
fi
