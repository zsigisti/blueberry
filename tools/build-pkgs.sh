#!/bin/sh
# build-pkgs.sh — build selected packages/<name> in an Arch container.
#
# Used by the image build to bundle a few bpm packages (the installer's tools,
# bash, ...) into the live image. Builds each named package with makepkg inside
# an ephemeral Arch container (same toolchain as blueberry-repo-sync), writing
# the .pkg.tar.zst files to <out-dir>. Idempotent: a package whose .pkg.tar.zst
# is already present and newer than its PKGBUILD is skipped.
#
# Usage: tools/build-pkgs.sh <out-dir> <pkgname>...
# Env:   ENGINE=podman|docker  IMAGE=<arch image>

set -eu
OUT=${1:?usage: build-pkgs.sh <out-dir> <pkg>...}; shift
TOPDIR=$(cd "$(dirname "$0")/.." && pwd)
ENGINE=${ENGINE:-podman}
IMAGE=${IMAGE:-docker.io/library/archlinux:latest}
mkdir -p "$OUT"

# Figure out which packages actually need building (missing or stale).
need=
for p in "$@"; do
    pb="$TOPDIR/packages/$p/PKGBUILD"
    [ -f "$pb" ] || { echo "build-pkgs: no such package: $p" >&2; exit 1; }
    if ! ls "$OUT/$p"-*.pkg.tar.zst >/dev/null 2>&1 \
       || [ "$pb" -nt "$(ls -t "$OUT/$p"-*.pkg.tar.zst 2>/dev/null | head -1)" ]; then
        need="$need $p"
    fi
done
[ -n "$need" ] || { echo "build-pkgs: all up to date"; exit 0; }

echo "build-pkgs: building$need"
SCRIPT='
set -eu
pacman -Syu --noconfirm --needed base-devel git >/dev/null 2>&1
useradd -m builder; echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
cp -a /repo /tmp/b; chown -R builder /tmp/b /out
fail=""
for p in '"$need"'; do
    if ! su builder -c "cd /tmp/b/packages/$p && PKGDEST=/out makepkg -f --skippgpcheck --noconfirm -s" >/tmp/$p.log 2>&1; then
        echo "!! FAILED: $p"; tail -5 /tmp/$p.log; fail="$fail $p"
    fi
done
rm -f /out/*-debug-*.pkg.tar.zst
[ -z "$fail" ] || { echo "build-pkgs: FAILED:$fail" >&2; exit 1; }
'
# --ipc=host + seccomp=unconfined: makepkg's fakeroot uses SysV-IPC message
# queues that corrupt ("payload not recognized") in podman's private IPC
# namespace, esp. under Rocky's SELinux/seccomp. The build container is
# ephemeral and trusted.
"$ENGINE" run --rm --ipc=host --security-opt seccomp=unconfined \
    -v "$TOPDIR:/repo:ro,z" -v "$OUT:/out:z" "$IMAGE" bash -euc "$SCRIPT"
echo "build-pkgs: done ->$need"
