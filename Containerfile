# Containerfile — the reproducible Blueberry build environment.
#
# Blueberry compiles its packages inside an Arch container already; this image
# extends that to the WHOLE build so the OS can be built and tested from ANY
# Linux machine with podman/docker — no Arch host, no host toolchain, no
# per-distro dependency hunting. Run it via tools/build-in-container.sh (or
# `make container`), which mounts the repo and drives `make` inside here.
#
#   podman build -t blueberry-build -f Containerfile .
#   tools/build-in-container.sh world      # or: make container
#
# BLUEBERRY_INLINE=1 tells tools/build-bpm-pkg.sh to build packages in-place
# instead of spawning a nested container.

FROM docker.io/library/archlinux:latest

# Enable multilib (some package builds expect it), then install the toolchain the
# non-package parts of the build need: gcc/make for busybox/runit/dropbear, the
# Rust toolchain for bpm + the installer, source-unpack + image tools, and QEMU
# for `make test-server` / `make test-install` / `make test-e2e`. Per-package
# makedeps are pulled on demand by tools/build-bpm-pkg.sh at build time.
RUN sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf && \
    pacman -Syu --noconfirm --needed \
        base-devel git python zstd fakeroot curl wget \
        gcc make bison flex bc pkgconf \
        rust \
        cpio xz bzip2 \
        openssl \
        xorriso squashfs-tools dosfstools \
        qemu-base && \
    rm -rf /var/cache/pacman/pkg/*

# build-bpm-pkg.sh builds in-place here rather than spawning a nested container.
ENV BLUEBERRY_INLINE=1
WORKDIR /src
