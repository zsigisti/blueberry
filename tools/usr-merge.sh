#!/bin/sh
# usr-merge.sh <rootfs> — convert a split-usr rootfs to merged-usr.
#
# systemd 256 requires merged-usr: it has compiled-in paths like
# /usr/sbin/mount and /usr/sbin/sulogin (recorded from the merged build host),
# and its glibc linker only searches /usr/lib. Blueberry's image is assembled
# split (busybox in /bin, util-linux libs in /lib, package sbin tools in
# /usr/sbin), which makes PID 1 fail at boot.
#
# This folds everything into /usr/bin + /usr/lib (the Arch layout) and replaces
# /bin, /sbin, /usr/sbin, /lib with symlinks. On a name clash the binary already
# in /usr/bin wins (prefer the full util-linux tool over a busybox applet).
# Idempotent. /lib64 keeps the hard-coded ELF interpreter and stays real.
set -eu

R=${1:?usage: usr-merge.sh <rootfs>}
mkdir -p "$R/usr/bin" "$R/usr/lib"

# Fold a directory's entries into /usr/bin, never overwriting an existing target.
fold_into_usrbin() {
    d=$1
    [ -d "$R/$d" ] && [ ! -L "$R/$d" ] || return 0
    for f in "$R/$d/"* "$R/$d/".[!.]*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        b=${f##*/}
        if [ -e "$R/usr/bin/$b" ] || [ -L "$R/usr/bin/$b" ]; then continue; fi
        cp -a "$f" "$R/usr/bin/$b"
    done
}

# /usr/sbin first (real dir today), then the root-level split dirs.
for d in usr/sbin sbin bin; do fold_into_usrbin "$d"; done

# Libraries → /usr/lib.
if [ -d "$R/lib" ] && [ ! -L "$R/lib" ]; then
    cp -a "$R/lib/." "$R/usr/lib/"
    rm -rf "$R/lib"
fi

# Replace the split dirs with symlinks into the merged tree.
[ -L "$R/usr/sbin" ] || { rm -rf "$R/usr/sbin"; ln -s bin     "$R/usr/sbin"; }
[ -L "$R/sbin" ]     || { rm -rf "$R/sbin";     ln -s usr/bin "$R/sbin"; }
[ -L "$R/bin" ]      || { rm -rf "$R/bin";      ln -s usr/bin "$R/bin"; }
[ -L "$R/lib" ]      || { rm -rf "$R/lib";      ln -s usr/lib "$R/lib"; }
[ -e "$R/lib64" ]    || ln -s usr/lib "$R/lib64"

echo "[usr-merge] $R is now merged-usr (/usr/bin + /usr/lib)"
