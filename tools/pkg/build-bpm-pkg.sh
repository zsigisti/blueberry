#!/bin/sh
# build-bpm-pkg.sh - build .bpm packages from packages/<name>/bpm.toml in a
# throwaway container by running tools/pkg/bpmbuild. The only package builder,
# makepkg is gone.
#
# usage: tools/pkg/build-bpm-pkg.sh <out-dir> <pkgname>...
# env:   ENGINE=podman|docker  IMAGE=<arch image>  BASE=auto|blueberry|arch
#        DEPS=<store>  BUILDER_IMAGE=<image>  PACMAN_CACHE=<volume>
#
# Installs each package's depends + makedepends, then builds it. A package
# whose .bpm is newer than its bpm.toml is skipped.

set -eu
OUT=${1:?usage: build-bpm-pkg.sh <out-dir> <pkg>...}; shift
TOPDIR=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE=${ENGINE:-podman}
IMAGE=${IMAGE:-docker.io/library/archlinux:latest}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)  # podman reads a relative -v source as a named volume

need=
for p in "$@"; do
    rec="$TOPDIR/packages/$p/bpm.toml"
    [ -f "$rec" ] || { echo "build-bpm: no bpm.toml for package: $p" >&2; exit 1; }
    # <name>-<digit> so glibc doesn't match glibc-locales
    built=$(ls -t "$OUT/$p"-[0-9]*.bpm 2>/dev/null | head -1)
    if [ -z "$built" ] || [ -n "$(find "$rec" -newer "$built" 2>/dev/null)" ]; then
        need="$need $p"
    fi
done
[ -n "$need" ] || { echo "build-bpm: all up to date"; exit 0; }

SDE=1767225600  # SOURCE_DATE_EPOCH for both modes

# two modes:
#   blueberry  self-hosted. the Blueberry builder image (own toolchain, no
#              pacman); the build closure is unpacked straight from the built
#              .bpm files in DEPS (obj/bpm-out). skipping bpm's DB and
#              scriptlets is fine in a throwaway container, same trick
#              mk-blueberry-builder.sh uses.
#   arch       bootstrap. an Arch container with makedeps from pacman, for the
#              very first world build or when asked for.
BASE=${BASE:-auto}
DEPS=${DEPS:-$TOPDIR/obj/bpm-out}
BUILDER_IMAGE=${BUILDER_IMAGE:-localhost/blueberry-builder:latest}
CLOSURE="$TOPDIR/tools/pkg/makedep-closure.py"

have_builder_image() { "$ENGINE" image exists "$BUILDER_IMAGE" 2>/dev/null; }
closure_complete() {  # is every package's build closure already built?
    for p in "$@"; do
        python3 "$CLOSURE" --check "$DEPS" "$p" >/dev/null 2>&1 || return 1
    done
    return 0
}

# which of these still have no fresh .bpm in $OUT, i.e. failed
still_missing() {
    sm=
    for p in "$@"; do
        rec="$TOPDIR/packages/$p/bpm.toml"
        b=$(ls -t "$OUT/$p"-[0-9]*.bpm 2>/dev/null | head -1)
        if [ -z "$b" ] || [ -n "$(find "$rec" -newer "$b" 2>/dev/null)" ]; then sm="$sm $p"; fi
    done
    echo $sm
}

# doesn't abort the caller on failure, still_missing works out what broke
run_blueberry() {
    [ $# -gt 0 ] || return 0
    echo "build-bpm: building $*   [mode: blueberry]"
    SCRIPT='
set -eu
SDE='"$SDE"'
# slim image: no useradd, and su/runuser die on the minimal PAM stack. so add
# the builder user by hand and drop privileges with setpriv. bpmbuild makes
# everything root-owned in the .bpm anyway.
id builder >/dev/null 2>&1 || {
    echo "builder:x:1000:1000::/home/builder:/bin/bash" >> /etc/passwd
    echo "builder:x:1000:" >> /etc/group
    mkdir -p /home/builder && chown 1000:1000 /home/builder
}
cp -a /repo /tmp/b; chown -R 1000:1000 /tmp/b /out
extract() {  # unpack .bpm payloads into /, no DB, they are just build inputs
    for f in "$@"; do
        [ -e "$f" ] || continue
        zstd -dcq "$f" | tar -x -C / --exclude=.BPM 2>/dev/null || echo "  warn: extract $f" >&2
    done
    return 0
}
fail=""
# every build gets fakeroot (bpmbuild runs package() under it so chown/setgid
# work unprivileged). until fakeroot itself is built this is a no-op.
extract /deps/fakeroot-[0-9]*.bpm
# the image has msgfmt but not the libs it links (libxml2, libunistring...),
# and anything with po/*.mo runs it, so every build gets the gettext closure
for gdep in gettext $(python3 /tmp/b/tools/pkg/makedep-closure.py gettext); do
    extract /deps/"$gdep"-[0-9]*.bpm
done
for p in '"$*"'; do
    echo "build-bpm: $p closure: $(python3 /tmp/b/tools/pkg/makedep-closure.py "$p" | tr "\n" " ")"
    for dep in $(python3 /tmp/b/tools/pkg/makedep-closure.py "$p"); do
        extract /deps/"$dep"-[0-9]*.bpm
    done
    # see run_arch, same setuid-helper problem
    find /usr/lib /usr/bin -xdev -type f -perm /6000 -exec chmod o+r {} + 2>/dev/null || true
    rm -f /out/$p-[0-9]*.bpm
    if ! setpriv --reuid=1000 --regid=1000 --init-groups \
            env HOME=/home/builder USER=builder SOURCE_DATE_EPOCH=$SDE BPM_ARCH=x86_64 \
            M4=/usr/bin/m4 \
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
    # some deps ship setuid helpers that are not other-readable (the dbus
    # daemon-launch-helper). rust copies the system sysroot (/usr/lib) as the
    # unprivileged builder and chokes on them. throwaway container, so chmod.
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
    # keep the pacman cache around so makedeps download once
    PACMAN_CACHE=${PACMAN_CACHE:-blueberry-pacman}
    "$ENGINE" run --rm --ipc=host --security-opt seccomp=unconfined \
        -v "$PACMAN_CACHE:/var/cache/pacman/pkg" \
        -v "$TOPDIR:/repo:ro,z" -v "$OUT:/out:z" "$IMAGE" bash -euc "$SCRIPT"
}

# BASE=blueberry never falls back. BASE=auto (the default) quietly uses the
# Arch path when there's no builder image or the closure isn't built yet, so
# "it built" doesn't mean "it built self-hosted" - read the warnings.
STRICT=
case "$BASE" in
    arch) mode=arch ;;
    blueberry)  # self-host or fail
        have_builder_image || { echo "build-bpm: BASE=blueberry but no image: $BUILDER_IMAGE (build it with tools/build/mk-blueberry-builder.sh)" >&2; exit 1; }
        closure_complete $need || { echo "build-bpm: BASE=blueberry but build closure is incomplete; run 'make repo-build' first" >&2; python3 "$CLOSURE" --check "$DEPS" $need >&2 || true; exit 1; }
        mode=blueberry; STRICT=1 ;;
    auto)  # self-host if we can, else arch
        if have_builder_image && closure_complete $need; then
            mode=blueberry
        else
            mode=arch
            if have_builder_image; then
                echo "build-bpm: builder image present but closure incomplete, using arch (run 'make repo-build' to self-host)" >&2
            else
                echo "build-bpm: no builder image ($BUILDER_IMAGE), using the arch bootstrap path" >&2
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
        # a self-hosting gap (masked makedep, or one that strips its dev files).
        # don't break the build, fall back to arch and complain loudly
        echo "build-bpm: WARNING self-hosting gap - blueberry could not build:$remain" >&2
        echo "build-bpm: falling back to arch for those; fix the recipe so they build self-hosted" >&2
        run_arch $remain
    fi
else
    run_arch $need
fi
echo "build-bpm: done ->$need"
