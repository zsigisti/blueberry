#!/bin/sh
# bpm-extract-record.sh — extract a .bpm into the rootfs AND record it in the
# local bpm database (var/lib/bpm/db/<name>/{desc,files}), exactly as a normal
# `bpm install` would. This is what makes the base packages baked into an image
# first-class, bpm-tracked packages, so `bpm upgrade` on the installed system can
# pull security/version updates for them from the repo (openssl, openssh, sudo,
# expat, …). Previously the base was extracted with `--exclude .BPM` and never
# recorded, so bpm treated it as unmanaged and never offered upgrades.
#
# The desc is the same .PKGINFO shape bpm writes (src/bpm-rs/src/pkg.rs::translate):
# pkgname / pkgver=ver-rel / size / arch / pkgdesc / depend= / provides=. The files
# list is the payload paths (no directories, no leading ./ , excluding .BPM).
#
# Usage: bpm-extract-record.sh <bpm-file> <stagedir> [--record-only]
#   --record-only : just write the DB entry; the payload is already extracted
#                   (used for glibc, which fetch-bpm.sh already unpacked).
set -eu
BPM=${1:?usage: bpm-extract-record.sh <bpm-file> <stagedir> [--record-only]}
STAGE=${2:?missing stagedir}
MODE=${3:-}

command -v python3 >/dev/null 2>&1 || { echo "bpm-extract-record: need python3" >&2; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
zstd -dcq "$BPM" | tar -xf - -C "$tmp" .BPM 2>/dev/null \
    || zstd -dcq "$BPM" | tar -xf - -C "$tmp" ./.BPM 2>/dev/null || true
[ -f "$tmp/.BPM" ] || { echo "bpm-extract-record: no .BPM manifest in $BPM" >&2; exit 1; }

name=$(python3 -c "import sys,tomllib;print(tomllib.load(open(sys.argv[1],'rb')).get('name',''))" "$tmp/.BPM")
[ -n "$name" ] || { echo "bpm-extract-record: no package name in $BPM" >&2; exit 1; }

DB="$STAGE/var/lib/bpm/db/$name"
mkdir -p "$DB"

# desc — byte-compatible with bpm's own translate() output.
python3 - "$tmp/.BPM" > "$DB/desc" <<'PY'
import sys, tomllib
m = tomllib.load(open(sys.argv[1], "rb"))
out = [f"pkgname = {m.get('name','')}"]
ver, rel = m.get("version", ""), m.get("release", "")
out.append(f"pkgver = {ver}-{rel}" if rel != "" else f"pkgver = {ver}")
if "installed_size" in m: out.append(f"size = {m['installed_size']}")
if "arch" in m:           out.append(f"arch = {m['arch']}")
if "summary" in m:        out.append(f"pkgdesc = {m['summary']}")
for d in m.get("depends", []):  out.append(f"depend = {d}")
for p in m.get("provides", []): out.append(f"provides = {p}")
print("\n".join(out))
PY

# files — payload paths only: drop directory entries (trailing /), the .BPM
# manifest, and the leading ./ , matching what bpm records.
zstd -dcq "$BPM" | tar -tf - \
    | grep -vE '/$' \
    | grep -vE '(^\./|^)\.BPM$' \
    | sed 's#^\./##' > "$DB/files"

if [ "$MODE" != "--record-only" ]; then
    zstd -dcq "$BPM" | tar -x -C "$STAGE" --exclude .BPM
fi

ver=$(python3 -c "import sys,tomllib;m=tomllib.load(open(sys.argv[1],'rb'));print(f\"{m.get('version','')}-{m.get('release','')}\")" "$tmp/.BPM")
echo "[bpm-record] $name $ver"
