#!/bin/sh
# blueberry-repo-sync — build changed packages and publish the bpm repo.
#
# Incremental by content hash: a package is rebuilt only when the contents of
# its packages/<name>/ directory change (PKGBUILD, .install, patches, ...).
# Everything else is served straight from the build cache, so a sync that adds
# one package builds one package — not all of them.
#
# The build cache is a private directory, NEVER the webroot. The webroot is a
# pure publish target: we copy the current artifacts in, prune superseded ones,
# and regenerate bpm.index. Nothing in the webroot is ever used to decide what
# to (re)build, so a wiped or hand-edited webroot can't trigger a full rebuild
# and a half-built artifact can never be served.
#
# Integrity: the index records each package's sha256 and clients verify every
# download against it. The index is served over TLS. There is no index signing.
#
# Usage:  blueberry-repo-sync [-n] [pkg...]
#   With no package names, every packages/<name> is considered.
#   -n / --dry-run : show what would build/publish, change nothing.
#
# Env:
#   WEBROOT   publish dir served over HTTP   (default /srv/blueberry-repo)
#   CACHE     private build cache            (default /var/cache/blueberry-repo-sync)
#   ENGINE    podman|docker                  (default podman)
#   IMAGE     build container                (default archlinux:latest)
#   JOBS      makepkg parallelism            (default: all cores)

set -eu

TOPDIR=$(cd "$(dirname "$0")/.." && pwd)
WEBROOT=${WEBROOT:-/srv/blueberry-repo}
CACHE=${CACHE:-/var/cache/blueberry-repo-sync}
ENGINE=${ENGINE:-podman}
IMAGE=${IMAGE:-docker.io/library/archlinux:latest}
DRYRUN=0

log() { printf '==> %s\n' "$*"; }
err() { printf 'repo-sync: %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRYRUN=1; shift ;;
        --) shift; break ;;
        -*) err "unknown option: $1"; exit 2 ;;
        *) break ;;
    esac
done

# Package set: the named ones, or every directory with a PKGBUILD.
if [ $# -gt 0 ]; then
    PKGS="$*"
else
    PKGS=$(cd "$TOPDIR/packages" && for d in */; do
               [ -f "${d}PKGBUILD" ] && printf '%s ' "${d%/}"; done)
fi
[ -n "$PKGS" ] || { err "no packages found"; exit 1; }

# Content hash of a package directory: sha256 over every file's hash, sorted so
# it's independent of readdir order. Captures PKGBUILD + .install + patches.
pkg_hash() {
    find "$TOPDIR/packages/$1" -type f -exec sha256sum {} + \
        | awk '{print $1}' | sort | sha256sum | cut -d' ' -f1
}

# ── 1. work out what actually needs building ─────────────────────────────────
need=
for p in $PKGS; do
    [ -f "$TOPDIR/packages/$p/PKGBUILD" ] || { err "no such package: $p"; exit 1; }
    h=$(pkg_hash "$p")
    if [ -f "$CACHE/$p/$h.stamp" ] && ls "$CACHE/$p/$h/"*.pkg.tar.zst >/dev/null 2>&1; then
        continue                          # cached build for this exact content
    fi
    need="$need $p"
done

if [ -z "$need" ]; then
    log "all ${PKGS# } packages up to date — nothing to build"
else
    log "to build:$need"
fi

if [ "$DRYRUN" = 1 ]; then
    log "(dry run) would publish to $WEBROOT and reindex"
    exit 0
fi

# ── 2. build the changed set in one ephemeral Arch container ─────────────────
# Each package builds into /out/<pkg>/ so artifacts are unambiguous. fakeroot
# under podman needs host IPC + relaxed seccomp (SysV message queues otherwise
# corrupt under SELinux); the container is ephemeral and trusted.
if [ -n "$need" ]; then
    BUILDOUT=$(mktemp -d "${TMPDIR:-/tmp}/bb-repo-sync.XXXXXX")
    trap 'rm -rf "$BUILDOUT"' EXIT
    jobs=${JOBS:-$(nproc 2>/dev/null || echo 1)}

    SCRIPT='
set -eu
pacman -Syu --noconfirm --needed base-devel git >/dev/null 2>&1
echo "MAKEFLAGS=\"-j'"$jobs"'\"" >> /etc/makepkg.conf
echo "OPTIONS+=(!debug)" >> /etc/makepkg.conf
# Reproducible builds: a fixed epoch makes builddate + file mtimes deterministic,
# so rebuilding an unchanged recipe yields the same sha256 (no spurious index
# churn / stale-CDN-cache mismatches). For bit-identical builds across time also
# pin IMAGE to a digest so the toolchain is frozen.
SDE=1767225600
useradd -m builder; echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
cp -a /repo /tmp/b; chown -R builder /tmp/b /out
fail=""
for p in '"$need"'; do
    mkdir -p /out/$p; chown builder /out/$p
    if ! su builder -c "cd /tmp/b/packages/$p && SOURCE_DATE_EPOCH=$SDE PACKAGER=\"Blueberry Linux <packages@blueberry.linux>\" PKGDEST=/out/$p makepkg -f --skippgpcheck --noconfirm -s" >/out/$p/build.log 2>&1; then
        echo "!! FAILED: $p"; tail -8 /out/$p/build.log; fail="$fail $p"
    fi
    rm -f /out/$p/*-debug-*.pkg.tar.zst
done
# makepkg ran as the unprivileged "builder"; hand the artifacts back to the
# container root so the host side (which maps root -> the invoking user under
# rootless podman) can read and clean them.
chown -R 0:0 /out
# Record failures but exit 0 so the host can still cache the successes — a
# rerun then only retries the failed recipes instead of rebuilding everything.
printf "%s\n" "$fail" > /out/.failed
'
    log "building in $ENGINE ($IMAGE), -j$jobs"
    "$ENGINE" run --rm --ipc=host --security-opt seccomp=unconfined \
        -v "$TOPDIR:/repo:ro,z" -v "$BUILDOUT:/out:z" "$IMAGE" bash -euc "$SCRIPT"

    failed=$(cat "$BUILDOUT/.failed" 2>/dev/null | tr -s ' ')
    failed=${failed# }; failed=${failed% }

    # Commit each package that actually produced an artifact into the cache
    # under its content hash. Failed recipes are skipped (retried next run).
    for p in $need; do
        ls "$BUILDOUT/$p"/*.pkg.tar.zst >/dev/null 2>&1 || continue
        h=$(pkg_hash "$p")
        dst="$CACHE/$p/$h"
        rm -rf "$dst"; mkdir -p "$dst"
        cp "$BUILDOUT/$p"/*.pkg.tar.zst "$dst"/
        printf '%s\n' "$h" > "$CACHE/$p/current"
        : > "$CACHE/$p/$h.stamp"
        log "cached $p ($h)"
    done
    if [ -n "$failed" ]; then
        err "build FAILED:$failed (successes cached; rerun retries these)"
        exit 1
    fi
else
    # Nothing built, but make sure every package has a current pointer so the
    # publish step below can find its artifact.
    for p in $PKGS; do
        h=$(pkg_hash "$p")
        [ -f "$CACHE/$p/current" ] || printf '%s\n' "$h" > "$CACHE/$p/current"
    done
fi

# ── 3. publish the current artifacts to the webroot ──────────────────────────
mkdir -p "$WEBROOT"
published=0
for p in $PKGS; do
    [ -f "$CACHE/$p/current" ] || { err "no cached build for $p (build failed?)"; continue; }
    h=$(cat "$CACHE/$p/current")
    for f in "$CACHE/$p/$h"/*.pkg.tar.zst; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        # Drop superseded versions of this package from the webroot. Match by
        # exact package base (strip -ver-rel-arch.pkg.tar.zst) so `gcc` never
        # prunes `gcc-libs`.
        pkgbase=${base%-*-*-*}
        for old in "$WEBROOT/$pkgbase"-*.pkg.tar.zst; do
            [ -f "$old" ] || continue
            ob=$(basename "$old")
            [ "$ob" = "$base" ] && continue
            [ "${ob%-*-*-*}" = "$pkgbase" ] || continue   # exact base, not a prefix
            log "prune $ob"
            rm -f "$old"
        done
        # Copy only if absent or changed (compare by hash).
        if [ ! -f "$WEBROOT/$base" ] || \
           [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$(sha256sum "$WEBROOT/$base" | cut -d' ' -f1)" ]; then
            cp "$f" "$WEBROOT/$base.tmp" && mv "$WEBROOT/$base.tmp" "$WEBROOT/$base"
            published=$((published + 1))
            log "publish $base"
        fi
    done
done
log "published $published artifact(s) to $WEBROOT"

# ── 4. regenerate the index (name|version|filename|sha256|deps) ──────────────
sh "$TOPDIR/tools/mkrepo.sh" "$WEBROOT"

# SELinux contexts so the web server can read fresh files (RHEL-family hosts).
command -v restorecon >/dev/null 2>&1 && restorecon -RF "$WEBROOT" 2>/dev/null || true
log "done"
