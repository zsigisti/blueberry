#!/bin/bash
# usage: bundle-glibc.sh <destroot> [binary ...]
# Copies ld.so, everything the binaries link, a compat set for random prebuilt
# software, and the NSS modules into <destroot>, then runs ldconfig on it.
#
# Where the libs come from matters. Our packages are linked against the build
# container's glibc (2.43). Take libc from an older host instead (Ubuntu 24.04
# has 2.39) and the image panics at boot with "requires glibc 2.42" errors.
# So GLIBC_SYSROOT (the Makefiles pass the stage) wins for any soname it has,
# and the host is only a fallback for the ABI-stable stuff like libgcc_s.
# Unset GLIBC_SYSROOT = host only, which is fine on an Arch host.

set -eu

DEST=${1:?usage: $0 <destroot> [binary ...]}
shift || true

SYSROOT=${GLIBC_SYSROOT:-}

LIBDIR="$DEST/usr/lib"
mkdir -p "$DEST/lib64" "$LIBDIR" "$DEST/etc"
# merged-usr: /lib -> usr/lib, but /lib64 stays real for the linker
[ -e "$DEST/lib" ] || ln -sf usr/lib "$DEST/lib"

# soname -> path, sysroot first, then the host
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
    # SYSROOT is often DEST itself, and cp onto itself errors (set -e = dead)
    [ "$src" -ef "$LIBDIR/$base" ] && return 0
    cp -Lf "$src" "$LIBDIR/$base"
}

copy_soname() {
    copy_lib "$(find_lib "$1")"
}

# every binary has /lib64/ld-linux-x86-64.so.2 baked in
ld=""
if [ -n "$SYSROOT" ]; then
    for c in "$SYSROOT/usr/lib/ld-linux-x86-64.so.2" "$SYSROOT/lib64/ld-linux-x86-64.so.2"; do
        [ -e "$c" ] && { ld="$c"; break; }
    done
fi
[ -n "$ld" ] || ld="/lib64/ld-linux-x86-64.so.2"
[ "$ld" -ef "$DEST/lib64/ld-linux-x86-64.so.2" ] || cp -Lf "$ld" "$DEST/lib64/ld-linux-x86-64.so.2"

# ldd for the list of names, but resolve them ourselves - ldd would answer
# with the host's paths
for bin in "$@"; do
    [ -e "$bin" ] || continue
    ldd "$bin" 2>/dev/null | awk '{print $1}' | while read -r soname; do
        case "$soname" in
            /*|linux-vdso.so*|"") continue ;;   # the ld itself, vdso
            *.so*) copy_soname "$soname" ;;
        esac
    done
done

# Stuff prebuilt software expects, plus the NSS modules. Those are dlopen'd so
# ldd never mentions them, and without nss_files/nss_dns getpwnam() and DNS
# quietly fail.
for soname in \
    libc.so.6 libm.so.6 libdl.so.2 librt.so.1 libpthread.so.0 \
    libresolv.so.2 libcrypt.so.2 libz.so.1 \
    libstdc++.so.6 libgcc_s.so.1 \
    libnss_files.so.2 libnss_dns.so.2 ; do
    copy_soname "$soname"
done

ldconfig -r "$DEST" 2>/dev/null || true

src="host"; [ -n "$SYSROOT" ] && src="sysroot:$SYSROOT (host fallback)"
echo "[bundle-glibc] staged $(ls "$LIBDIR" | wc -l) libs + linker into $DEST (from $src)"
