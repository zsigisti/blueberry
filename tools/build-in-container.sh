#!/bin/sh
# build-in-container.sh — build (and test) Blueberry inside a reproducible Arch
# container, so ANY Linux machine with podman/docker can build the OS: no Arch
# host, no host toolchain, no per-distro dependency hunting. This is the
# supported "contribute from any Linux" path.
#
# Usage:
#   tools/build-in-container.sh                 # make world
#   tools/build-in-container.sh install iso     # any make target(s)
#   tools/build-in-container.sh test-e2e        # full boot/install smoke test
#   tools/build-in-container.sh shell           # interactive shell in the env
#
# Env:
#   ENGINE=podman|docker   IMAGE=blueberry-build   BUILD=<build dir on host>
set -eu

TOPDIR=$(cd "$(dirname "$0")/.." && pwd)
ENGINE=${ENGINE:-podman}
# Fully-qualified so podman doesn't try short-name registry resolution.
IMAGE=${IMAGE:-localhost/blueberry-build}
BUILD=${BUILD:-$TOPDIR/../blueberry-build}
mkdir -p "$BUILD"

command -v "$ENGINE" >/dev/null 2>&1 || {
    echo "error: '$ENGINE' not found — install podman (or set ENGINE=docker)" >&2
    exit 1
}

# Build the image once (rebuild by removing it, or `$ENGINE build` by hand).
if ! "$ENGINE" image exists "$IMAGE" >/dev/null 2>&1; then
    echo "==> building $IMAGE from Containerfile (first run only)"
    # `$ENGINE build` writes a multi-GB temp layer to $TMPDIR (default /var/tmp).
    # On hosts where / is small that fails with ENOSPC; point it at the image
    # store's filesystem, which is where the big layers live anyway.
    if [ -z "${TMPDIR:-}" ]; then
        store=$("$ENGINE" info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo "")
        [ -n "$store" ] && { TMPDIR="$store/tmp"; mkdir -p "$TMPDIR"; export TMPDIR; }
    fi
    "$ENGINE" build -t "$IMAGE" -f "$TOPDIR/Containerfile" "$TOPDIR"
fi

# Pass /dev/kvm through when present so the QEMU boot/install tests run fast;
# harmless to omit (they fall back to software emulation).
KVM=""
[ -e /dev/kvm ] && KVM="--device /dev/kvm"

# Interactive shell, or run make targets (default: world). The repo is mounted
# at /src (rw: cargo/git write here, same as a host build); the build tree at
# /build so artifacts land on the host and persist between runs.
TTY=""
[ -t 1 ] && TTY="-it"

if [ "${1:-}" = "shell" ]; then
    set -- bash
else
    [ $# -gt 0 ] || set -- world
    set -- make OBJDIR=/build "$@"
fi

exec "$ENGINE" run --rm $TTY $KVM \
    --security-opt seccomp=unconfined --ipc=host \
    -v "$TOPDIR:/src:z" -v "$BUILD:/build:z" \
    -w /src -e BLUEBERRY_INLINE=1 \
    "$IMAGE" "$@"
