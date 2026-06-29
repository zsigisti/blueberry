#!/bin/bash
# stage-desktop.sh — install the Blueberry Desktop package closure into a
# staged rootfs, ready for tools/mkdesktopiso.sh to squash into a live ISO.
#
# `make install` stages the *base* system (kernel, glibc, systemd, bpm). This
# step layers the *graphical* closure on top: it resolves the dependency tree of
# the named desktop packages from the signed repo index, then extracts each
# package's payload into the rootfs (the same tar+zstd layout bpm installs).
#
# Usage:  STAGEDIR=<rootfs> PKGDIR=<basepkgs> INDEX=<bpm.index> \
#         tools/stage-desktop.sh <pkg>...
#
#   STAGEDIR  the staged rootfs to extend         (required)
#   PKGDIR    dir of built .bpm files              (default ../blueberry-build/bpm-out)
#   INDEX     repo index for dependency resolution (default $PKGDIR/bpm.index, else fetch)
#   REPO_URL  fall back to this mirror for missing packages
#             (default https://repo.mmzsigmond.me)
set -euo pipefail

TOPDIR=$(cd "$(dirname "$0")/.." && pwd)
STAGEDIR=${STAGEDIR:?set STAGEDIR to the staged rootfs}
PKGDIR=${PKGDIR:-$TOPDIR/../blueberry-build/bpm-out}
REPO_URL=${REPO_URL:-https://repo.mmzsigmond.me}
INDEX=${INDEX:-$PKGDIR/bpm.index}
PROVIDED=${PROVIDED:-$TOPDIR/etc/bpm/provided}

log()  { printf '\033[1;35m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$#" -gt 0 ] || die "no packages given"
[ -d "$STAGEDIR" ] || die "STAGEDIR '$STAGEDIR' is not a directory (run 'make install' first)"

WORK=$(mktemp -d /tmp/bbd-stage.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ── Obtain the index (name|ver|file|sha|deps|size|desc) ───────────────────────
if [ ! -f "$INDEX" ]; then
    log "fetching repo index from $REPO_URL"
    curl -fsSL -o "$WORK/bpm.index" "$REPO_URL/bpm.index" || die "cannot fetch index"
    INDEX="$WORK/bpm.index"
fi

# Names already provided by the base image / rootfs are not re-staged.
provided_set=" glibc gcc-libs "
[ -f "$PROVIDED" ] && provided_set+=" $(tr '\n' ' ' <"$PROVIDED") "

dep_field()  { awk -F'|' -v n="$1" '$1==n{print $5; exit}' "$INDEX"; }
file_field() { awk -F'|' -v n="$1" '$1==n{print $3; exit}' "$INDEX"; }

# ── Resolve the transitive closure (BFS over the deps field) ──────────────────
log "resolving dependency closure for: $*"
declare -A seen=()
queue=("$@"); closure=()
while [ "${#queue[@]}" -gt 0 ]; do
    pkg="${queue[0]}"; queue=("${queue[@]:1}")
    [ -n "${seen[$pkg]:-}" ] && continue
    case "$provided_set" in *" $pkg "*) continue ;; esac
    seen[$pkg]=1
    if ! grep -q "^$pkg|" "$INDEX"; then
        warn "no index entry for '$pkg' — skipping (host-provided or stale name)"
        continue
    fi
    closure+=("$pkg")
    deps=$(dep_field "$pkg")
    IFS=',' read -ra ds <<<"$deps"
    for d in "${ds[@]}"; do [ -n "$d" ] && queue+=("$d"); done
done
log "closure: ${#closure[@]} packages"

# ── Extract each package payload into the rootfs ──────────────────────────────
staged=0
for pkg in "${closure[@]}"; do
    file=$(file_field "$pkg")
    src="$PKGDIR/$file"
    if [ ! -f "$src" ]; then
        log "  fetch $pkg ($file)"
        curl -fsSL -o "$WORK/$file" "$REPO_URL/$file" || { warn "cannot fetch $pkg"; continue; }
        src="$WORK/$file"
    fi
    # bsdtar handles tar+zstd; drop package metadata, keep the filesystem payload.
    bsdtar -xpf "$src" -C "$STAGEDIR" \
        --exclude '.BPM' --exclude '.PKGINFO' --exclude '.BUILDINFO' \
        --exclude '.MTREE' --exclude '.INSTALL' --exclude '.CHANGELOG' 2>/dev/null \
        || { warn "extract failed: $pkg"; continue; }
    staged=$((staged+1))
done

log "staged $staged/${#closure[@]} packages into $STAGEDIR"
[ -e "$STAGEDIR/usr/bin/sddm" ] || [ -e "$STAGEDIR/usr/bin/gdm" ] \
    || warn "no display manager in the rootfs — check that sddm/gdm are in the closure"

# ── systemd owns udev/libudev: re-extract it LAST so it wins over eudev ────────
# Some KDE deps (solid → eudev) pull eudev, whose older udevadm/libudev (v251)
# overwrites systemd's own (v256) depending on extraction order. On a systemd
# image systemd's udev MUST win, or systemd-udevd.service dies (status=2) and the
# desktop never reaches a graphical session. Re-extract systemd over the closure.
sysd_pkg=""
for cand in "$PKGDIR"/systemd-[0-9]*.bpm; do [ -f "$cand" ] && sysd_pkg="$cand"; done
if [ -z "$sysd_pkg" ]; then
    sysd_file=$(file_field systemd)
    [ -n "$sysd_file" ] && [ -f "$WORK/$sysd_file" ] && sysd_pkg="$WORK/$sysd_file"
fi
if [ -n "$sysd_pkg" ] && [ -f "$sysd_pkg" ]; then
    log "re-asserting systemd's udev/libudev over the closure ($(basename "$sysd_pkg"))"
    bsdtar -xpf "$sysd_pkg" -C "$STAGEDIR" \
        --exclude '.BPM' --exclude '.PKGINFO' --exclude '.BUILDINFO' \
        --exclude '.MTREE' --exclude '.INSTALL' --exclude '.CHANGELOG' 2>/dev/null || warn "systemd re-extract failed"
fi

# ── Resolve stale base-bundle libs shadowing the staged ones ──────────────────
# The base rootfs bundles a few old util-linux libraries in /usr/lib (e.g.
# libblkid.so.1.0 with no version symbols). The full util-linux package staged
# here installs the proper, versioned copies to /lib. Because /lib and /usr/lib
# are separate dirs (not merged-usr) and /usr/lib sorts first in the cache, the
# stale copy shadows the good one — and systemd's libsystemd-shared needs the
# versioned blkid symbols, so PID 1 dies. For every util-linux soname present in
# /lib, drop the stale /usr/lib duplicate and point it at the /lib version.
if [ -d "$STAGEDIR/lib" ] && [ -d "$STAGEDIR/usr/lib" ]; then
    for base in libblkid.so libmount.so libuuid.so libsmartcols.so libfdisk.so; do
        if [ -e "$STAGEDIR/lib/$base.1" ] || ls "$STAGEDIR/lib/$base".* >/dev/null 2>&1; then
            # Remove the stale /usr/lib copies entirely — both the soname symlink
            # AND the actual versioned library file (e.g. libblkid.so.1.0), or
            # ldconfig will just rescan the leftover file and recreate the link.
            rm -f "$STAGEDIR/usr/lib/$base" "$STAGEDIR/usr/lib/$base".*
            # Point the soname at the /lib (util-linux, versioned) copy.
            [ -e "$STAGEDIR/lib/$base.1" ] && ln -sf "/lib/$base.1" "$STAGEDIR/usr/lib/$base.1"
            log "  deduped $base.* → /lib (purged stale /usr/lib files)"
        fi
    done
fi

# ── Rebuild the dynamic-linker cache for the whole desktop closure ────────────
# The base rootfs ships an ld.so.cache for ~35 libs only. After layering hundreds
# of desktop libraries the cache is stale, and systemd's private libs in
# /usr/lib/systemd are NOT found transitively (libsystemd-core has no RUNPATH) —
# so systemd (PID 1) exits 127 and the boot panics. Ensure the systemd lib dir is
# on the loader path and regenerate the cache rooted at the staged rootfs.
log "refreshing ld.so.cache for the desktop closure"
mkdir -p "$STAGEDIR/etc/ld.so.conf.d"
printf '/usr/lib\n/usr/lib/systemd\n/lib\n/usr/local/lib\n' \
    > "$STAGEDIR/etc/ld.so.conf.d/blueberry-desktop.conf"
[ -f "$STAGEDIR/etc/ld.so.conf" ] || echo 'include /etc/ld.so.conf.d/*.conf' > "$STAGEDIR/etc/ld.so.conf"
if command -v ldconfig >/dev/null 2>&1; then
    ldconfig -r "$STAGEDIR" 2>/dev/null \
        && log "ld.so.cache rebuilt ($(wc -c <"$STAGEDIR/etc/ld.so.cache" 2>/dev/null) bytes)" \
        || warn "ldconfig -r failed; systemd may not start"
else
    warn "ldconfig not on host — cannot rebuild the rootfs cache"
fi
log "desktop staging complete"
