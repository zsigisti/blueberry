#!/bin/sh
# usage: seed-kernel-db.sh <stagedir>
#
# The kernel comes from fetch-kernel.sh, not a .bpm, so bpm has no idea it's
# installed and would never offer an upgrade. Write the db entry by hand,
# version taken from packages/linux/bpm.toml so it matches the repo.
# The linux .bpm just overwrites /boot/vmlinuz (what grub.cfg boots), so
# upgrades need no hooks or grub regeneration.
set -eu
STAGE=${1:?usage: seed-kernel-db.sh <stagedir>}
TOP=$(cd "$(dirname "$0")/../.." && pwd)
REC="$TOP/packages/linux/bpm.toml"
[ -f "$REC" ] || { echo "seed-kernel-db: no $REC" >&2; exit 1; }

ver=$(awk -F'"' '/^version[[:space:]]*=/{print $2; exit}' "$REC")
rel=$(awk -F'=' '/^release[[:space:]]*=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$REC")
summary=$(awk -F'"' '/^summary[[:space:]]*=/{print $2; exit}' "$REC")
[ -n "$ver" ] && [ -n "$rel" ] || { echo "seed-kernel-db: could not read version/release from $REC" >&2; exit 1; }

DB="$STAGE/var/lib/bpm/db/linux"
mkdir -p "$DB"
{
    printf 'pkgname = linux\n'
    printf 'pkgver = %s-%s\n' "$ver" "$rel"
    printf 'pkgdesc = %s\n' "$summary"
} > "$DB/desc"
printf 'boot/vmlinuz\n' > "$DB/files"

echo "[seed-kernel-db] registered linux $ver-$rel (bpm upgrade will track the kernel)"
