#!/bin/sh
# Pre-warmed Arch build image, so each package build doesn't spend minutes on
# `pacman -Syu base-devel ...` first. Then:
#
#   ENGINE=podman IMAGE=localhost/blueberry-builder tools/pkg/build-bpm-pkg.sh <out> <pkg>...
#
# Re-run now and then to pick up newer Arch. Only the build toolchain changes;
# recipes pin their own sources.
set -eu
ENGINE=${ENGINE:-podman}
TAG=${TAG:-localhost/blueberry-builder}

# commit writes a multi-GB temp blob to $TMPDIR (/var/tmp by default), which
# doesn't fit on a small /. Use the podman store's filesystem
if [ -z "${TMPDIR:-}" ]; then
    store=$($ENGINE info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo "")
    [ -n "$store" ] && { TMPDIR="$store/tmp"; mkdir -p "$TMPDIR"; export TMPDIR; }
fi

# makedeps that keep coming up across the tree
PKGS="base-devel git python python-gobject python-setuptools python-packaging \
zstd fakeroot curl meson ninja cmake pkgconf \
glib2 glib2-devel gobject-introspection vala gettext intltool \
extra-cmake-modules qt6-base qt6-declarative qt6-tools qt6-wayland \
libxml2 libxslt docbook-xsl docbook-xml \
wayland wayland-protocols nss nspr boost"

CTR="blueberry-builder-build"
$ENGINE rm -f "$CTR" >/dev/null 2>&1 || true
$ENGINE run --name "$CTR" docker.io/library/archlinux:latest bash -euc "
  grep -q '^\[multilib\]' /etc/pacman.conf || \
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
  pacman -Syu --noconfirm --needed $PKGS
  pacman -Scc --noconfirm >/dev/null 2>&1 || true
"
$ENGINE commit -q "$CTR" "$TAG"
$ENGINE rm -f "$CTR" >/dev/null 2>&1 || true
echo "mk-builder-image: wrote $TAG"
echo "  use: IMAGE=$TAG tools/pkg/build-bpm-pkg.sh <out> <pkg>..."
