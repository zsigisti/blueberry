#!/bin/sh
# usr-merge.sh <rootfs>
#
# systemd 256 won't boot a split /usr: it has /usr/sbin/mount and
# /usr/sbin/sulogin compiled in and the linker only looks in /usr/lib. Our
# stage comes out split, so fold it into /usr/bin + /usr/lib (Arch layout) and
# symlink the rest. On a clash /usr/bin wins, i.e. util-linux beats a busybox
# applet. Safe to run twice. /lib64 stays real (ELF interpreter).
set -eu

R=${1:?usage: usr-merge.sh <rootfs>}
mkdir -p "$R/usr/bin" "$R/usr/lib"

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

for d in usr/sbin sbin bin; do fold_into_usrbin "$d"; done

if [ -d "$R/lib" ] && [ ! -L "$R/lib" ]; then
    cp -a "$R/lib/." "$R/usr/lib/"
    rm -rf "$R/lib"
fi

[ -L "$R/usr/sbin" ] || { rm -rf "$R/usr/sbin"; ln -s bin     "$R/usr/sbin"; }
[ -L "$R/sbin" ]     || { rm -rf "$R/sbin";     ln -s usr/bin "$R/sbin"; }
[ -L "$R/bin" ]      || { rm -rf "$R/bin";      ln -s usr/bin "$R/bin"; }
[ -L "$R/lib" ]      || { rm -rf "$R/lib";      ln -s usr/lib "$R/lib"; }
[ -e "$R/lib64" ]    || ln -s usr/lib "$R/lib64"

echo "[usr-merge] $R is now merged-usr (/usr/bin + /usr/lib)"
