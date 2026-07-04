#!/bin/bash
# bundle-glibc.sh — stage the glibc runtime into a destination root so the image
# can run dynamically-linked glibc binaries: the system's own (busybox / runit /
# dropbear / systemd) AND external prebuilt software (the whole point of using
# glibc instead of musl).
#
# Usage: bundle-glibc.sh <destroot> [binary ...]
#   Copies the ELF interpreter, the ldd deps of each <binary>, a compat set of
#   common shared libs, and the dlopen-only NSS modules; then builds ld.so.cache.
#
# WHERE THE LIBS COME FROM (this is the whole point):
#   Blueberry is built inside an Arch container, so every packaged binary is
#   linked against the CONTAINER's glibc (currently 2.43). If we bundled the
#   *build host's* glibc instead, a host with an older glibc than the container
#   (e.g. Ubuntu 24.04 ships 2.39) would stage a too-old libc and the image
#   would panic at boot ("libncursesw.so.6 requires glibc 2.42", …).
#
#   So the fix: prefer a STAGED SYSROOT — the assembled rootfs, which contains
#   the container-built `glibc` package — over the host. Set GLIBC_SYSROOT to
#   that rootfs (the top-level Makefiles pass GLIBC_SYSROOT=$(STAGEDIR)). Any
#   soname found there wins; anything not staged (ABI-stable libgcc_s, libcrypt…)
#   falls back to the host. With GLIBC_SYSROOT unset the old host-only behaviour
#   is preserved, so building on an Arch host still works unchanged.

set -eu

DEST=${1:?usage: $0 <destroot> [binary ...]}
shift || true

# The staged rootfs to source libraries from (container-built glibc lives here).
# Unset → host-only (legacy behaviour). A trailing slash is harmless.
SYSROOT=${GLIBC_SYSROOT:-}
# Don't source from ourselves: if DEST == SYSROOT the finds still work (the libs
# are already in place), but skip self-copies for clarity.

LIBDIR="$DEST/usr/lib"
mkdir -p "$DEST/lib64" "$LIBDIR" "$DEST/etc"
# Merged-usr layout: /lib -> usr/lib. /lib64 stays a real dir for the linker.
[ -e "$DEST/lib" ] || ln -sf usr/lib "$DEST/lib"

# find_lib SONAME → absolute path. Prefer the staged sysroot (container-built
# glibc), fall back to the build host. This is what makes the build reproducible
# regardless of the host distro's glibc version.
find_lib() {
    local soname="$1" d
    if [ -n "$SYSROOT" ]; then
        for d in usr/lib lib64 usr/lib64 lib; do
            if [ -e "$SYSROOT/$d/$soname" ]; then
                printf '%s\n' "$SYSROOT/$d/$soname"; return 0
            fi
        done
    fi
    ldconfig -p 2>/dev/null | awk -v s="$soname" '$1==s {print $NF; exit}'
}

copy_lib() {
    local src="$1" base
    [ -n "$src" ] && [ -e "$src" ] || return 0
    base=$(basename "$src")
    [ -e "$LIBDIR/$base" ] && return 0
    # SYSROOT may equal DEST (glibc extracted straight into the target); never
    # copy a file onto itself — cp errors and, under set -e, would abort.
    [ "$src" -ef "$LIBDIR/$base" ] && return 0
    cp -Lf "$src" "$LIBDIR/$base"
}

copy_soname() {  # resolve a SONAME (staged-first) and stage it
    copy_lib "$(find_lib "$1")"
}

# The ELF interpreter path is hard-coded into every dynamic binary
# (/lib64/ld-linux-x86-64.so.2). Take it from the staged glibc if present.
ld=""
if [ -n "$SYSROOT" ]; then
    for c in "$SYSROOT/usr/lib/ld-linux-x86-64.so.2" "$SYSROOT/lib64/ld-linux-x86-64.so.2"; do
        [ -e "$c" ] && { ld="$c"; break; }
    done
fi
[ -n "$ld" ] || ld="/lib64/ld-linux-x86-64.so.2"
# Skip if the linker is already in place (SYSROOT == DEST): cp onto self errors.
[ "$ld" -ef "$DEST/lib64/ld-linux-x86-64.so.2" ] || cp -Lf "$ld" "$DEST/lib64/ld-linux-x86-64.so.2"

# 1. Transitive dependency SONAMEs of the binaries we ship, sourced staged-first.
#    Use ldd for the (transitive) NEEDED list, but resolve each name ourselves so
#    the staged glibc wins over whatever the host happens to have.
for bin in "$@"; do
    [ -e "$bin" ] || continue
    ldd "$bin" 2>/dev/null | awk '{print $1}' | while read -r soname; do
        case "$soname" in
            /*|linux-vdso.so*|"") continue ;;   # skip abs paths (the ld) + vdso
            *.so*) copy_soname "$soname" ;;
        esac
    done
done

# 2. Compat set: common libs external glibc software expects, plus the
#    runtime-dlopen'd NSS modules (which ldd never reports). Without nss_files /
#    nss_dns, getpwnam() and DNS resolution silently fail. Staged-first, so the
#    glibc-owned members here come from the container-built package.
for soname in \
    libc.so.6 libm.so.6 libdl.so.2 librt.so.1 libpthread.so.0 \
    libresolv.so.2 libcrypt.so.2 libz.so.1 \
    libstdc++.so.6 libgcc_s.so.1 \
    libnss_files.so.2 libnss_dns.so.2 ; do
    copy_soname "$soname"
done

# 3. ld.so.cache so the interpreter finds everything in /usr/lib at runtime.
ldconfig -r "$DEST" 2>/dev/null || true

src="host"; [ -n "$SYSROOT" ] && src="sysroot:$SYSROOT (host fallback)"
echo "[bundle-glibc] staged $(ls "$LIBDIR" | wc -l) libs + linker into $DEST (from $src)"
