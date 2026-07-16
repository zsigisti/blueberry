#!/bin/sh
# build-bpm-pkg.sh — build native .bpm packages from packages/<name>/bpm.toml in an
# ephemeral Arch container (the self-hosted build toolchain), driving
# tools/pkg/bpmbuild. This is the sole package builder: PKGBUILD/makepkg is retired.
#
# EXPERIMENTAL (feature/bpm-pkg-format). The .bpm format is not used in
# production until both CLI and GUI boot; this is the build-side counterpart so
# recipes can be migrated and tested end-to-end.
#
# Usage:  tools/pkg/build-bpm-pkg.sh <out-dir> <pkgname>...
# Env:    ENGINE=podman|docker   IMAGE=<arch image>
#
# For each package it reads bpm.toml's depends+makedepends, installs them (plus
# base-devel) from the build toolchain, then runs `bpmbuild packages/<name> <out>`.
# Idempotent: a package whose .bpm is newer than its bpm.toml is skipped.

set -eu
OUT=${1:?usage: build-bpm-pkg.sh <out-dir> <pkg>...}; shift
TOPDIR=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE=${ENGINE:-podman}
IMAGE=${IMAGE:-docker.io/library/archlinux:latest}
mkdir -p "$OUT"

need=
for p in "$@"; do
    rec="$TOPDIR/packages/$p/bpm.toml"
    [ -f "$rec" ] || { echo "build-bpm: no bpm.toml for package: $p" >&2; exit 1; }
    # Anchor on the version digit so "glibc" doesn't match "glibc-locales"
    # (and "lib" wouldn't match "libX"): artifact = <name>-<version>-<rel>-<arch>.bpm.
    built=$(ls -t "$OUT/$p"-[0-9]*.bpm 2>/dev/null | head -1)
    if [ -z "$built" ] || [ -n "$(find "$rec" -newer "$built" 2>/dev/null)" ]; then
        need="$need $p"
    fi
done
[ -n "$need" ] || { echo "build-bpm: all up to date"; exit 0; }

SDE=1767225600  # SOURCE_DATE_EPOCH, shared by both build modes

# ── Build mode: blueberry (self-hosted) vs arch (bootstrap) ───────────────────
# blueberry: run in the Blueberry builder image (its own gcc/toolchain, no
#   pacman); each package's build-time closure is installed by extracting the
#   already-built .bpm from the canonical store (DEPS, default obj/bpm-out).
# arch: the bootstrap path — an ephemeral Arch container, makedeps via pacman.
#   Used to build the world the first time (before obj/bpm-out is populated) or
#   when forced. Extraction bypasses bpm's DB/scriptlets, which is fine for a
#   throwaway build container (build-time makedeps need files in place, nothing
#   more) — the same mechanism mk-blueberry-builder.sh uses to bake the toolchain.
BASE=${BASE:-auto}
DEPS=${DEPS:-$TOPDIR/obj/bpm-out}
BUILDER_IMAGE=${BUILDER_IMAGE:-localhost/blueberry-builder:latest}
CLOSURE="$TOPDIR/tools/pkg/makedep-closure.py"

have_builder_image() { "$ENGINE" image exists "$BUILDER_IMAGE" 2>/dev/null; }
closure_complete() {  # every $need package's build closure is already built
    for p in "$@"; do
        python3 "$CLOSURE" --check "$DEPS" "$p" >/dev/null 2>&1 || return 1
    done
    return 0
}

# Which of a package set still lack a fresh .bpm in $OUT (i.e. failed to build).
still_missing() {
    sm=
    for p in "$@"; do
        rec="$TOPDIR/packages/$p/bpm.toml"
        b=$(ls -t "$OUT/$p"-[0-9]*.bpm 2>/dev/null | head -1)
        if [ -z "$b" ] || [ -n "$(find "$rec" -newer "$b" 2>/dev/null)" ]; then sm="$sm $p"; fi
    done
    echo $sm
}

# Self-hosted: Blueberry image, deps extracted from already-built .bpm. Never
# aborts the caller — collects failures so auto-mode can fall back per package.
run_blueberry() {
    [ $# -gt 0 ] || return 0
    echo "build-bpm: building $*   [mode: blueberry]"
    SCRIPT='
set -eu
SDE='"$SDE"'
# The builder image is a slim runtime rootfs: no shadow (useradd) and su/runuser
# abort on the minimal PAM stack. Make an unprivileged builder by hand and drop
# privileges with setpriv (no PAM). Ownership in the final .bpm is normalised to
# root by bpmbuild regardless of who built it.
id builder >/dev/null 2>&1 || {
    echo "builder:x:1000:1000::/home/builder:/bin/bash" >> /etc/passwd
    echo "builder:x:1000:" >> /etc/group
    mkdir -p /home/builder && chown 1000:1000 /home/builder
}
cp -a /repo /tmp/b; chown -R 1000:1000 /tmp/b /out
extract() {  # drop a built .bpm payload into / (no pacman, no DB — build inputs)
    for f in "$@"; do
        [ -e "$f" ] || continue
        zstd -dcq "$f" | tar -x -C / --exclude=.BPM 2>/dev/null || echo "  warn: extract $f" >&2
    done
    return 0
}
fail=""
for p in '"$*"'; do
    echo "build-bpm: $p closure: $(python3 /tmp/b/tools/pkg/makedep-closure.py "$p" | tr "\n" " ")"
    for dep in $(python3 /tmp/b/tools/pkg/makedep-closure.py "$p"); do
        extract /deps/"$dep"-[0-9]*.bpm
    done
    # setuid helpers not other-readable break the unprivileged builder (rust copies
    # the system sysroot); make them readable — throwaway container.
    find /usr/lib /usr/bin -xdev -type f -perm /6000 -exec chmod o+r {} + 2>/dev/null || true
    rm -f /out/$p-[0-9]*.bpm
    if ! setpriv --reuid=1000 --regid=1000 --init-groups \
            env HOME=/home/builder USER=builder SOURCE_DATE_EPOCH=$SDE BPM_ARCH=x86_64 \
            bash -c "cd /tmp/b && python3 tools/pkg/bpmbuild packages/$p /out" >/tmp/$p.log 2>&1; then
        echo "!! FAILED: $p"; tail -40 /tmp/$p.log; fail="$fail $p"
    else
        echo "build-bpm: built $p (blueberry, no arch)"
    fi
done
[ -z "$fail" ] || { echo "build-bpm: blueberry build failed:$fail" >&2; exit 1; }
'
    "$ENGINE" run --rm --ipc=host --security-opt seccomp=unconfined \
        -v "$TOPDIR:/repo:ro,z" -v "$OUT:/out:z" -v "$DEPS:/deps:ro,z" \
        "$BUILDER_IMAGE" /usr/bin/bash -euc "$SCRIPT"
}

# Bootstrap: ephemeral Arch container, makedeps via pacman.
run_arch() {
    [ $# -gt 0 ] || return 0
    echo "build-bpm: building $*   [mode: arch]"
    SCRIPT='
set -eu
grep -q "^\[multilib\]" /etc/pacman.conf || \
  printf "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" >> /etc/pacman.conf
pacman -Syu --noconfirm --needed base-devel git python zstd fakeroot curl >/dev/null 2>&1
echo "MAKEFLAGS=\"-j$(nproc)\"" >> /etc/makepkg.conf
SDE='"$SDE"'
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
for p in '"$*"'; do
    rec="/tmp/b/packages/$p/bpm.toml"
    deps=$(extract_deps "$rec" | sort -u | tr "\n" " ")
    echo "build-bpm: $p deps: $deps"
    for d in $deps; do
        pacman -S --noconfirm --needed "$d" >/dev/null 2>&1 || true
    done
    # Some deps ship setuid/setgid helpers that are not other-readable (the dbus
    # daemon-launch helper). rust bootstraps by copying the system rustc sysroot
    # (/usr/lib) as the unprivileged builder and fails to read them. Make them
    # readable here — this is a throwaway build container.
    find /usr/lib /usr/bin -xdev -type f -perm /6000 -exec chmod o+r {} + 2>/dev/null || true
    rm -f /out/$p-[0-9]*.bpm
    if ! su builder -c "cd /tmp/b && SOURCE_DATE_EPOCH=$SDE BPM_ARCH=x86_64 python3 tools/pkg/bpmbuild packages/$p /out" >/tmp/$p.log 2>&1; then
        echo "!! FAILED: $p"; tail -40 /tmp/$p.log; fail="$fail $p"
    else
        echo "build-bpm: built $p"
    fi
done
[ -z "$fail" ] || { echo "build-bpm: FAILED:$fail" >&2; exit 1; }
'
    # Persistent pacman package cache: makedeps download once, not every build.
    PACMAN_CACHE=${PACMAN_CACHE:-blueberry-pacman}
    "$ENGINE" run --rm --ipc=host --security-opt seccomp=unconfined \
        -v "$PACMAN_CACHE:/var/cache/pacman/pkg" \
        -v "$TOPDIR:/repo:ro,z" -v "$OUT:/out:z" "$IMAGE" bash -euc "$SCRIPT"
}

# ── Mode selection + orchestration ────────────────────────────────────────────
STRICT=
case "$BASE" in
    arch) mode=arch ;;
    blueberry)  # explicit: self-host or fail (no silent arch fallback)
        have_builder_image || { echo "build-bpm: BASE=blueberry but no image: $BUILDER_IMAGE (build it with tools/build/mk-blueberry-builder.sh)" >&2; exit 1; }
        closure_complete $need || { echo "build-bpm: BASE=blueberry but build closure is incomplete; run 'make repo-build' first" >&2; python3 "$CLOSURE" --check "$DEPS" $need >&2 || true; exit 1; }
        mode=blueberry; STRICT=1 ;;
    auto)  # prefer self-hosted; degrade to arch when it can't run yet
        if have_builder_image && closure_complete $need; then
            mode=blueberry
        else
            mode=arch
            if have_builder_image; then
                echo "build-bpm: builder image present but closure incomplete — using arch (run 'make repo-build' to self-host)" >&2
            else
                echo "build-bpm: no builder image ($BUILDER_IMAGE) — using the arch bootstrap path" >&2
            fi
        fi ;;
    *) echo "build-bpm: unknown BASE=$BASE (want auto|blueberry|arch)" >&2; exit 1 ;;
esac

if [ "$mode" = blueberry ]; then
    run_blueberry $need || true
    remain=$(still_missing $need)
    if [ -n "$remain" ]; then
        if [ -n "$STRICT" ]; then
            echo "build-bpm: FAILED (blueberry, no fallback):$remain" >&2; exit 1
        fi
        # A self-hosting gap (a masked makedep, or a makedep that strips its dev
        # files). Don't break the build — fall back to arch and flag it loudly.
        echo "build-bpm: WARNING self-hosting gap — blueberry could not build:$remain" >&2
        echo "build-bpm: falling back to arch for those; fix the recipe so they build self-hosted" >&2
        run_arch $remain
    fi
else
    run_arch $need
fi
echo "build-bpm: done ->$need"
