#!/bin/bash
# check-pkg-libs.sh — shared-library dependency-closure checker for a bpm repo.
#
# Catches the class of bug where a package, built in the Arch build container,
# auto-links an optional library that base-devel happened to provide but that
# Blueberry never packages — so `bpm install <pkg>` succeeds yet the binary
# dies at runtime with "libfoo.so.N: cannot open shared object file".
#
# It reports two things over a directory of built *.pkg.tar.zst:
#   A) UNSATISFIABLE — a NEEDED soname provided by no package and not present
#      in the base image (hard runtime breakage).
#   B) UNDECLARED    — a NEEDED soname provided by some package P that is not in
#      this package's declared depends (so `bpm install` won't pull it).
#
# Base-image libraries (glibc bundle, ncurses, ...) are read from a rootfs so
# deps on always-present libs aren't flagged.
#
# Usage: tools/check-pkg-libs.sh <pkgdir> [rootfs]
#   pkgdir  directory of *.pkg.tar.zst (e.g. a mirror of the repo)
#   rootfs  base-image root providing the always-present .so set
#           (default: ../blueberry-build/rootfs)
# Exit status is non-zero if any UNSATISFIABLE libs are found.
set -u

DIR=${1:?usage: $0 <pkgdir> [rootfs]}
TOPDIR=$(cd "$(dirname "$0")/.." && pwd)
ROOTFS=${2:-$(cd "$TOPDIR/.." && pwd)/blueberry-build/rootfs}
for t in readelf zstd tar; do command -v "$t" >/dev/null || { echo "need $t" >&2; exit 2; }; done
[ -d "$ROOTFS" ] || { echo "rootfs not found: $ROOTFS (run 'make install')" >&2; exit 2; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
soname() { readelf -d "$1" 2>/dev/null | awk -F'[][]' '/SONAME/{print $2}'; }
needed() { readelf -d "$1" 2>/dev/null | awk -F'[][]' '/NEEDED/{print $2}'; }
is_elf()  { [ "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; }

# Base-image provided sonames (+ the dynamic linker, always present).
{
  while IFS= read -r so; do soname "$so"; echo "${so##*/}"; done \
      < <(find "$ROOTFS" -name '*.so*' -type f 2>/dev/null)
  echo "ld-linux-x86-64.so.2"
} | sort -u > "$WORK/base"

: > "$WORK/provided"; : > "$WORK/needs"; : > "$WORK/deps"
for pkg in "$DIR"/*.pkg.tar.zst; do
    [ -f "$pkg" ] || continue
    ex="$WORK/x/$(basename "$pkg")"; mkdir -p "$ex"
    zstd -dcq "$pkg" | tar -x -C "$ex" 2>/dev/null
    name=$(awk -F' = ' '/^pkgname /{print $2; exit}' "$ex/.PKGINFO" 2>/dev/null)
    deps=$(awk -F' = ' '/^depend /{print $2}' "$ex/.PKGINFO" 2>/dev/null | paste -sd, -)
    printf '%s\t%s\n' "$name" "$deps" >> "$WORK/deps"
    while IFS= read -r f; do
        is_elf "$f" || continue
        s=$(soname "$f"); [ -n "$s" ] && printf '%s\t%s\n' "$s" "$name" >> "$WORK/provided"
        for n in $(needed "$f"); do printf '%s\t%s\n' "$name" "$n" >> "$WORK/needs"; done
    done < <(find "$ex" -type f 2>/dev/null)
    # ld.so/ldconfig also resolve a NEEDED entry by *filename* via the versioned
    # symlinks a package ships (some libs, e.g. sqlite-autoconf, carry no
    # DT_SONAME). Count every shipped libfoo.so* basename as provided too.
    while IFS= read -r so; do
        printf '%s\t%s\n' "${so##*/}" "$name" >> "$WORK/provided"
    done < <(find "$ex" -name '*.so*' 2>/dev/null)
done
sort -u -o "$WORK/provided" "$WORK/provided"
sort -u -o "$WORK/needs" "$WORK/needs"
{ cut -f1 "$WORK/provided"; cat "$WORK/base"; } | sort -u > "$WORK/satisfiable"

rc=0
echo "================ A) UNSATISFIABLE shared libs ================"
a=$(while IFS=$'\t' read -r pkg so; do
        grep -qxF "$so" "$WORK/satisfiable" || printf '  %-22s needs %s\n' "$pkg" "$so"
    done < "$WORK/needs" | sort -u)
if [ -n "$a" ]; then echo "$a"; rc=1; else echo "  (none)"; fi

echo "================ B) UNDECLARED package deps ================"
declare -A DEP
while IFS=$'\t' read -r p d; do DEP[$p]="$d"; done < "$WORK/deps"
b=$(while IFS=$'\t' read -r pkg so; do
        grep -qxF "$so" "$WORK/base" && continue
        for pp in $(awk -F'\t' -v s="$so" '$1==s{print $2}' "$WORK/provided" | sort -u); do
            [ "$pp" = "$pkg" ] && continue
            case ",${DEP[$pkg]:-}," in
                *",$pp,"*) : ;;
                *) printf '  %-22s links %-22s (from %s) undeclared\n' "$pkg" "$so" "$pp" ;;
            esac
        done
    done < "$WORK/needs" | sort -u)
if [ -n "$b" ]; then echo "$b"; else echo "  (none)"; fi

exit $rc
