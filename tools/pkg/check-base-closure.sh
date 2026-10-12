#!/bin/sh
# check-base-closure.sh - every ELF in a base rootfs must find all its
# DT_NEEDED libs inside that same rootfs.
#
# The base image comes from a flat package list with no dep resolution
# (SYSTEMD_BASE_PKGS in GNUmakefile), so shipping grep without libpcre2 or gawk
# without libmpfr is easy. Better to find out here than on a booted system.
#
# usage: check-base-closure.sh <rootdir>
# exit 0 ok, 1 missing libs, 2 usage/tooling problem
set -eu
ROOT=${1:?usage: check-base-closure.sh <rootdir>}
[ -d "$ROOT" ] || { echo "check-base-closure: no such rootdir: $ROOT" >&2; exit 2; }
command -v readelf >/dev/null 2>&1 || { echo "check-base-closure: readelf not found" >&2; exit 2; }

provided=$(mktemp); fail=$(mktemp)
trap 'rm -f "$provided" "$fail"' EXIT

# every shared lib the rootfs ships, by basename
for d in usr/lib usr/lib64 lib lib64 usr/lib/security; do
    [ -d "$ROOT/$d" ] && find "$ROOT/$d" -maxdepth 3 \( -name '*.so' -o -name '*.so.*' \) -printf '%f\n' 2>/dev/null
done | sort -u > "$provided"
# the kernel finds ld.so, not DT_NEEDED, but list it anyway
printf 'ld-linux-x86-64.so.2\nld-linux.so.2\n' >> "$provided"

find "$ROOT" -type f \( -path '*/bin/*' -o -path '*/sbin/*' -o -name '*.so' -o -name '*.so.*' \) 2>/dev/null \
| while IFS= read -r f; do
    needed=$(readelf -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p') || continue
    [ -n "$needed" ] || continue
    for lib in $needed; do
        grep -qxF "$lib" "$provided" || printf '%s\tneeds\t%s\n' "${f#"$ROOT"}" "$lib" >> "$fail"
    done
done

if [ -s "$fail" ]; then
    echo "check-base-closure: FAIL - base ELFs need libraries the base does not ship:" >&2
    sort -u "$fail" | sed 's/^/  /' >&2
    echo "  -> add the owning package(s) to SYSTEMD_BASE_PKGS in GNUmakefile." >&2
    exit 1
fi
echo "check-base-closure: OK - every DT_NEEDED library is provided by the base rootfs"
