# profile.mk — Blueberry Desktop edition build fragment.
#
# Included by the top-level GNUmakefile. Adds the desktop package sets and the
# `desktop-iso` target, which produces a live, Calamares-installable ISO built
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

# These add to the base image's BASE_PKGS so the installed system has the DE.
BASE_PKGS += $(DESKTOP_PKGS)

.PHONY: desktop-iso desktop-pkgs desktop-stage desktop-info

desktop-info: desktop-version
	@echo "  edition : $(DE)   init: $(INIT)"
	@echo "  packages: $(words $(DESKTOP_PKGS)) ($(words $(DESKTOP_COMMON_PKGS)) common + $(words $(DESKTOP_DE_PKGS)) $(DE))"

# Build (or skip-if-fresh) every desktop package into $(OBJDIR)/basepkgs.
desktop-pkgs:
	@echo "[desktop] building $(words $(DESKTOP_PKGS)) packages for the $(DE) spin"
	@sh $(TOPDIR)/tools/build-pkgs.sh $(OBJDIR)/basepkgs $(DESKTOP_PKGS)

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
	@STAGEDIR="$(DESKTOP_STAGEDIR)" PKGDIR="$(OBJDIR)/basepkgs" \
	 bash $(TOPDIR)/tools/stage-desktop.sh $(DESKTOP_PKGS)

# Full live ISO: base install (systemd) + DE closure + SDDM autostart → Calamares.
desktop-iso: desktop-stage
	@echo "[desktop] assembling live ISO: $(BBD_NAME) $(BBD_FULLVERSION) ($(DE))"
	@DE=$(DE) \
	 BBD_NAME="$(BBD_NAME)" \
	 BBD_VERSION="$(BBD_VERSION)" \
	 BBD_FULLVERSION="$(BBD_FULLVERSION)" \
	 BBD_CODENAME="$(BBD_CODENAME)" \
	 BBD_CHANNEL="$(BBD_CHANNEL)" \
	 STAGEDIR="$(DESKTOP_STAGEDIR)" \
	 DESKTOPDIR="$(DESKTOPDIR)" \
	 BOOTDIR="$(BOOTDIR)" \
	 ARCH="$(ARCH)" \
	 bash $(TOPDIR)/tools/mkdesktopiso.sh \
	    $(DESKTOP_ISO)
