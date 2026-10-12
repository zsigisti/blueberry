#!/bin/sh
# bpm-extract-record.sh - extract a .bpm into a rootfs and record it in the bpm
# database (var/lib/bpm/db/<name>/{desc,files}) like `bpm install` would.
# Without the record, base packages baked into an image are invisible to bpm
# and `bpm upgrade` never offers fixes for openssl, sudo and friends.
#
# desc has the same .PKGINFO shape bpm writes (pkg.rs translate()), files is
# the payload paths without dirs, ./ or .BPM.
#
# usage: bpm-extract-record.sh <bpm-file> <stagedir> [--record-only]
#   --record-only  only write the DB entry (glibc: fetch-bpm.sh already unpacked it)
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

# has to match bpm's translate() byte for byte
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

# files: no dir entries, no .BPM, no leading ./ (same as bpm records)
zstd -dcq "$BPM" | tar -tf - \
    | grep -vE '/$' \
    | grep -vE '(^\./|^)\.BPM$' \
    | sed 's#^\./##' > "$DB/files"

if [ "$MODE" != "--record-only" ]; then
    # -p or the setuid bits vanish: as an unprivileged build user tar quietly
    # drops them and sudo/su/mount/passwd end up plain 0755. the image step
    # chowns to root later but keeps the mode.
    zstd -dcq "$BPM" | tar -xp -C "$STAGE" --exclude .BPM
fi

ver=$(python3 -c "import sys,tomllib;m=tomllib.load(open(sys.argv[1],'rb'));print(f\"{m.get('version','')}-{m.get('release','')}\")" "$tmp/.BPM")
echo "[bpm-record] $name $ver"
