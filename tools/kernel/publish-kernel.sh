#!/bin/sh
# publish-kernel.sh — package a freshly compiled kernel into the pinned binary
# artifact and upload it to the repo server. Run this ONCE on a build box after
# `make kernel-rebuild` (or `make kernel-publish`, which chains both) whenever the
# kernel version or config is bumped. Normal builds then just fetch this artifact.
#
# Usage: publish-kernel.sh <bootdir> <stagedir> <linux_version> <localversion> <arch>
# Env:   REPO_HOST (root@192.168.0.79)  REPO_DIR (/srv/blueberry-repo)
#        ASKPASS (/tmp/askpass.sh — writes the repo password; see repo-deploy)
set -eu

BOOTDIR=${1:?usage: publish-kernel.sh <bootdir> <stagedir> <ver> <localversion> <arch>}
STAGEDIR=${2:?missing stagedir}
VER=${3:?missing linux_version}
LOCALVER=${4:?missing localversion}
ARCH=${5:?missing arch}
REPO_HOST=${REPO_HOST:-root@192.168.0.79}
REPO_DIR=${REPO_DIR:-/srv/blueberry-repo}
ASKPASS=${ASKPASS:-/tmp/askpass.sh}

[ -f "$BOOTDIR/vmlinuz" ] || { echo "ERROR: no $BOOTDIR/vmlinuz — run 'make kernel-rebuild' first" >&2; exit 1; }
MODROOT="$STAGEDIR/usr/lib/modules"
REL=$(ls "$MODROOT" 2>/dev/null | head -1)
[ -n "$REL" ] || { echo "ERROR: no modules under $MODROOT — run 'make kernel-rebuild' first" >&2; exit 1; }

ART="blueberry-kernel-${VER}${LOCALVER}-${ARCH}.tar.zst"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/boot" "$WORK/lib/modules"
cp "$BOOTDIR/vmlinuz" "$WORK/boot/vmlinuz"
for m in "$BOOTDIR"/System.map-*; do [ -e "$m" ] && cp "$m" "$WORK/boot/"; done
cp -a "$MODROOT/$REL" "$WORK/lib/modules/$REL"

echo "==> packing $ART (kernel $VER$LOCALVER, modules $REL)"
tar -C "$WORK" -cf - boot lib | zstd -19 -q -o "$WORK/$ART"
sha256sum "$WORK/$ART" | awk '{print $1}' > "$WORK/$ART.sha256"
echo "    $(du -h "$WORK/$ART" | cut -f1)  sha256=$(cat "$WORK/$ART.sha256")"

echo "==> uploading to $REPO_HOST:$REPO_DIR/kernel/"
export SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force
SSH="setsid -w ssh -o StrictHostKeyChecking=no"
SCP="setsid -w scp -o StrictHostKeyChecking=no"
$SSH "$REPO_HOST" "mkdir -p $REPO_DIR/kernel"
$SCP "$WORK/$ART" "$WORK/$ART.sha256" "$REPO_HOST:$REPO_DIR/kernel/"
echo "==> published https://repo.mmzsigmond.me/kernel/$ART"
