#!/bin/sh
# build-bpm-pkg.sh — build native .bpm packages from packages/<name>/bpm.toml in an
# ephemeral Arch container (the self-hosted build toolchain), driving
# tools/bpmbuild. This is the sole package builder: PKGBUILD/makepkg is retired.
#
# EXPERIMENTAL (feature/bpm-pkg-format). The .bpm format is not used in
# production until both CLI and GUI boot; this is the build-side counterpart so
# recipes can be migrated and tested end-to-end.
#
# Usage:  tools/build-bpm-pkg.sh <out-dir> <pkgname>...
# Env:    ENGINE=podman|docker   IMAGE=<arch image>
#
# For each package it reads bpm.toml's depends+makedepends, installs them (plus
# base-devel) from the build toolchain, then runs `bpmbuild packages/<name> <out>`.
# Idempotent: a package whose .bpm is newer than its bpm.toml is skipped.

set -eu
OUT=${1:?usage: build-bpm-pkg.sh <out-dir> <pkg>...}; shift
TOPDIR=$(cd "$(dirname "$0")/.." && pwd)
ENGINE=${ENGINE:-podman}
IMAGE=${IMAGE:-docker.io/library/archlinux:latest}
mkdir -p "$OUT"

need=
for p in "$@"; do
    rec="$TOPDIR/packages/$p/bpm.toml"
    [ -f "$rec" ] || { echo "build-bpm: no bpm.toml for package: $p" >&2; exit 1; }
    built=$(ls -t "$OUT/$p"-*.bpm 2>/dev/null | head -1)
    if [ -z "$built" ] || [ -n "$(find "$rec" -newer "$built" 2>/dev/null)" ]; then
        need="$need $p"
    fi
done
[ -n "$need" ] || { echo "build-bpm: all up to date"; exit 0; }

echo "build-bpm: building$need"
SCRIPT='
set -eu
grep -q "^\[multilib\]" /etc/pacman.conf || \
  printf "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" >> /etc/pacman.conf
pacman -Syu --noconfirm --needed base-devel git python zstd fakeroot curl >/dev/null 2>&1
echo "MAKEFLAGS=\"-j$(nproc)\"" >> /etc/makepkg.conf
SDE=1767225600
useradd -m builder; echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
cp -a /repo /tmp/b; chown -R builder /tmp/b /out
extract_deps() {
    python3 - "$1" <<"PY"
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    r = tomllib.load(f)
pkg = r.get("package", {})
deps = list(pkg.get("depends", [])) + list(pkg.get("makedepends", []))
for d in deps:
    print(d.split(">=")[0].split("=")[0].split("<")[0].strip())
PY
}
fail=""
for p in '"$need"'; do
    rec="/tmp/b/packages/$p/bpm.toml"
    deps=$(extract_deps "$rec" | sort -u | tr "\n" " ")
    echo "build-bpm: $p deps: $deps"
    for d in $deps; do
        pacman -S --noconfirm --needed "$d" >/dev/null 2>&1 || true
    done
    rm -f /out/$p-*.bpm
    if ! su builder -c "cd /tmp/b && SOURCE_DATE_EPOCH=$SDE BPM_ARCH=x86_64 python3 tools/bpmbuild packages/$p /out" >/tmp/$p.log 2>&1; then
        echo "!! FAILED: $p"; tail -8 /tmp/$p.log; fail="$fail $p"
    else
        echo "build-bpm: built $p"
    fi
done
[ -z "$fail" ] || { echo "build-bpm: FAILED:$fail" >&2; exit 1; }
'
# Persistent pacman package cache: makedeps download once, not every build.
# Pair with a pre-warmed IMAGE (tools/mk-builder-image.sh) to also skip install.
PACMAN_CACHE=${PACMAN_CACHE:-blueberry-pacman}
"$ENGINE" run --rm --ipc=host --security-opt seccomp=unconfined \
    -v "$PACMAN_CACHE:/var/cache/pacman/pkg" \
    -v "$TOPDIR:/repo:ro,z" -v "$OUT:/out:z" "$IMAGE" bash -euc "$SCRIPT"
echo "build-bpm: done ->$need"
