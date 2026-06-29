#!/bin/sh
# mk-builder-image.sh — bake a pre-warmed Arch build image for tools/build-bpm-pkg.sh.
#
# Each package build otherwise runs `pacman -Syu base-devel + makedeps` from
# scratch in a fresh container (minutes of download+install per build). This bakes
# base-devel plus the recurring heavy toolchain into one image so builds only need
# the few package-specific makedeps. Use it with:
#
#   ENGINE=podman IMAGE=localhost/blueberry-builder tools/build-bpm-pkg.sh <out> <pkg>...
#
# Re-run occasionally to refresh against current Arch (the package recipes still
# pin their own source versions; this only affects the *build* toolchain).
set -eu
ENGINE=${ENGINE:-podman}
TAG=${TAG:-localhost/blueberry-builder}

# `podman commit` writes a multi-GB temp blob to $TMPDIR (default /var/tmp). On
# hosts where / is small, point it at the podman store's filesystem instead.
if [ -z "${TMPDIR:-}" ]; then
    store=$($ENGINE info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo "")
    [ -n "$store" ] && { TMPDIR="$store/tmp"; mkdir -p "$TMPDIR"; export TMPDIR; }
fi

# Recurring makedeps across the tree (toolchains, Qt6/KF6 build tooling, glib +
# its split-out codegen, doc/introspection tooling, common -devel libs).
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
echo "  use: IMAGE=$TAG tools/build-bpm-pkg.sh <out> <pkg>..."
