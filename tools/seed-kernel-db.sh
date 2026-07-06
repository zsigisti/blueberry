#!/bin/sh
# seed-kernel-db.sh — register the pinned kernel as an installed bpm package in
# the rootfs, so `bpm upgrade` on the running system can later pull a newer linux
# .bpm from the repo and install it. The kernel ships as a prebuilt artifact (it
# is NOT built per image — see tools/fetch-kernel.sh), so bpm would otherwise not
# know it is installed and would never offer to upgrade it.
#
# Writes the bpm local-db entry (var/lib/bpm/db/linux/{desc,files}, the same
# .PKGINFO shape bpm records on a normal install). The linux .bpm installs the
# kernel straight to /boot/vmlinuz — the stable path the installer's grub.cfg
# boots by UUID — so an upgrade just overwrites that file; no hook or grub
# regeneration is involved. Version/release are read from packages/linux/bpm.toml
# so the seed always matches the published package.
#
# Usage: seed-kernel-db.sh <stagedir>
set -eu
STAGE=${1:?usage: seed-kernel-db.sh <stagedir>}
TOP=$(cd "$(dirname "$0")/.." && pwd)
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
# The kernel owns /boot/vmlinuz; a `bpm upgrade` overwrites it in place.
printf 'boot/vmlinuz\n' > "$DB/files"

echo "[seed-kernel-db] registered linux $ver-$rel (bpm upgrade will track the kernel)"
