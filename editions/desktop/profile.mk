# profile.mk — Blueberry Desktop edition build fragment.
#
# Included by the top-level GNUmakefile. Adds the desktop package sets and the
# `desktop-iso` target, which produces a live, ISO built
# on the same base (kernel, glibc, systemd, bpm) as the CLI distro.
#
# The desktop edition implies INIT=systemd: GNOME and Plasma both require
# logind/seat management, so selecting it here is non-negotiable.
#
# Usage:
#   make desktop-iso              # KDE Plasma (default), current release
#   make desktop-iso DE=gnome     # GNOME spin
#   make desktop-iso DE=kde BBD_VERSION=26.04 BBD_CODENAME="Bright Bilberry"

include $(TOPDIR)/editions/desktop/release.mk

DESKTOPDIR := $(TOPDIR)/editions/desktop

# ── Desktop environment selection ─────────────────────────────────────────────
# KDE is the default per project decision; GNOME is the documented alternative.
DE ?= kde
ifeq ($(filter $(DE),kde gnome),)
  $(error DE must be 'kde' or 'gnome' (got '$(DE)'))
endif

# A desktop is a graphical, logind-backed system: force systemd.
INIT := systemd

# ── Resolve the package closure from the manifests ────────────────────────────
# Strip comments/blank lines from common.list + the chosen DE list.
_list = $(shell sed -e 's/#.*//' -e '/^[[:space:]]*$$/d' $(1) 2>/dev/null)
DESKTOP_COMMON_PKGS := $(call _list,$(DESKTOPDIR)/packages/common.list)
DESKTOP_DE_PKGS     := $(call _list,$(DESKTOPDIR)/packages/$(DE).list)
DESKTOP_PKGS        := $(DESKTOP_COMMON_PKGS) $(DESKTOP_DE_PKGS)

# NOTE: the desktop set is NOT folded into BASE_PKGS — the base image stays the
# CLI base; desktop-stage layers the DE closure onto a clone of it, and the
# online/netinstall image fetches the set from the repo at install time.

.PHONY: desktop-iso desktop-iso-online desktop-pkgs desktop-stage desktop-info

desktop-info: desktop-version
	@echo "  edition : $(DE)   init: $(INIT)"
	@echo "  packages: $(words $(DESKTOP_PKGS)) ($(words $(DESKTOP_COMMON_PKGS)) common + $(words $(DESKTOP_DE_PKGS)) $(DE))"

# Build (or skip-if-fresh) every desktop package as .bpm into $(OBJDIR)/bpm-out.
# This populates the local cache stage-desktop reads before falling back to the
# repo; the .pkg.tar.zst/makepkg path is fully retired.
desktop-pkgs:
	@echo "[desktop] building $(words $(DESKTOP_PKGS)) packages for the $(DE) spin"
	@sh $(TOPDIR)/tools/build-bpm-pkg.sh $(OBJDIR)/bpm-out $(DESKTOP_PKGS)

# The desktop gets its OWN rootfs, cloned from the clean base, so layering the
# graphical (systemd, no-busybox) closure never clobbers the CLI/initramfs rootfs
# at $(STAGEDIR). The initramfs is built once from the base; the ISO squashes
# this desktop rootfs.
DESKTOP_STAGEDIR := $(OBJDIR)/desktop-rootfs

# Layer the graphical package closure onto a clone of the base rootfs.
desktop-stage: install
	@echo "[desktop] cloning base rootfs → $(DESKTOP_STAGEDIR)"
	@rm -rf $(DESKTOP_STAGEDIR)
	@cp -al $(STAGEDIR) $(DESKTOP_STAGEDIR) 2>/dev/null || cp -a $(STAGEDIR) $(DESKTOP_STAGEDIR)
	@echo "[desktop] staging $(words $(DESKTOP_PKGS)) packages (+deps) into $(DESKTOP_STAGEDIR)"
	@STAGEDIR="$(DESKTOP_STAGEDIR)" PKGDIR="$(OBJDIR)/bpm-out" \
	 bash $(TOPDIR)/tools/stage-desktop.sh $(DESKTOP_PKGS)

# Desktop installer ISOs (TUI, no live session — Calamares is gone).
#   desktop-iso        offline: full installed-desktop payload, no network needed
#   desktop-iso-online netinstall: base payload + manifest, fetches DE via bpm
DESKTOP_ONLINE_ISO := $(TOPDIR)/iso/blueberry-desktop-$(BBD_VERSION)-$(DE)-netinstall-$(ARCH).iso

define _mkinstiso
	@MODE=$(1) DE=$(DE) \
	 BBD_NAME="$(BBD_NAME)" \
	 BBD_VERSION="$(BBD_VERSION)" \
	 BBD_FULLVERSION="$(BBD_FULLVERSION)" \
	 BBD_CODENAME="$(BBD_CODENAME)" \
	 BBD_CHANNEL="$(BBD_CHANNEL)" \
	 STAGEDIR="$(2)" \
	 DESKTOPDIR="$(DESKTOPDIR)" \
	 BOOTDIR="$(BOOTDIR)" \
	 ARCH="$(ARCH)" \
	 bash $(TOPDIR)/tools/mkdesktopinstiso.sh $(3)
endef

desktop-iso: desktop-stage
	@echo "[desktop] assembling installer ISO (offline): $(BBD_NAME) $(BBD_FULLVERSION) ($(DE))"
	$(call _mkinstiso,offline,$(DESKTOP_STAGEDIR),$(DESKTOP_ISO))

desktop-iso-online: install
	@echo "[desktop] assembling installer ISO (online/netinstall): $(BBD_NAME) $(BBD_FULLVERSION) ($(DE))"
	$(call _mkinstiso,online,$(STAGEDIR),$(DESKTOP_ONLINE_ISO))
