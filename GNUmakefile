# GNUmakefile — Blueberry Linux top-level build system
#
# Primary targets
#   make world        Build everything: musl, busybox, runit, bpm, kernel, initramfs
#   make kernel       Build the Linux kernel and modules
#   make userland     Build musl + busybox + runit + bpm
#   make initramfs    Build the initramfs image
#   make iso          Build a bootable ISO
#   make install      Install the built world into DESTDIR
#   make repo         Build a package repository from all BBUILD recipes
#   make fetch        Download all upstream sources
#   make clean        Remove all build artefacts
#   make distclean    Also remove all downloaded sources
#
# See Make.config for all tuneable variables.
# Copy Make.config to Make.local to override for your machine.

TOPDIR := $(CURDIR)

# Load defaults then local overrides
include $(TOPDIR)/Make.config
-include $(TOPDIR)/Make.local

# ── Computed paths ────────────────────────────────────────────────────────────
SRCDIR  := $(TOPDIR)/src
PKGSDIR := $(TOPDIR)/pkgs
ETCDIR  := $(TOPDIR)/etc

OBJDIR_SRC  := $(OBJDIR)/src
OBJDIR_BUILD := $(OBJDIR)/build
BOOTDIR     := $(OBJDIR)/boot
STAGEDIR    := $(DESTDIR)

LINUX_SRC      := $(OBJDIR_SRC)/linux-$(LINUX_VERSION)
MUSL_SRC       := $(OBJDIR_SRC)/musl-$(MUSL_VERSION)
BUSYBOX_SRC    := $(OBJDIR_SRC)/busybox-$(BUSYBOX_VERSION)
RUNIT_SRC      := $(OBJDIR_SRC)/runit-$(RUNIT_VERSION)
OPENSSL_SRC    := $(OBJDIR_SRC)/openssl-$(OPENSSL_VERSION)
ZLIB_SRC       := $(OBJDIR_SRC)/zlib-$(ZLIB_VERSION)

MUSL_SYSROOT   := $(OBJDIR)/sysroot
BPM_BIN        := $(OBJDIR)/bpm

# ── Stamp files (track completed build steps) ─────────────────────────────────
STAMP_FETCH_LINUX    := $(OBJDIR)/.stamp-fetch-linux
STAMP_FETCH_MUSL     := $(OBJDIR)/.stamp-fetch-musl
STAMP_FETCH_BUSYBOX  := $(OBJDIR)/.stamp-fetch-busybox
STAMP_FETCH_RUNIT    := $(OBJDIR)/.stamp-fetch-runit
STAMP_KERNEL_HEADERS := $(OBJDIR)/.stamp-kernel-headers
STAMP_MUSL           := $(OBJDIR)/.stamp-musl
STAMP_BUSYBOX        := $(OBJDIR)/.stamp-busybox
STAMP_RUNIT          := $(OBJDIR)/.stamp-runit
STAMP_BPM            := $(OBJDIR)/.stamp-bpm
STAMP_KERNEL         := $(OBJDIR)/.stamp-kernel
STAMP_INITRAMFS      := $(OBJDIR)/.stamp-initramfs
STAMP_INSTALL        := $(OBJDIR)/.stamp-install

# ── Kernel tarball URL (kernel.org CDN format) ────────────────────────────────
LINUX_MAJOR   := $(firstword $(subst ., ,$(LINUX_VERSION)))
LINUX_URL     := https://cdn.kernel.org/pub/linux/kernel/v$(LINUX_MAJOR).x/linux-$(LINUX_VERSION).tar.xz
MUSL_URL      := https://musl.libc.org/releases/musl-$(MUSL_VERSION).tar.gz
BUSYBOX_URL   := https://busybox.net/downloads/busybox-$(BUSYBOX_VERSION).tar.bz2
RUNIT_URL     := http://smarden.org/runit/runit-$(RUNIT_VERSION).tar.gz

# ── Utilities ─────────────────────────────────────────────────────────────────
# Download: wget -O outfile url  OR  curl -fL -o outfile url
ifneq ($(shell command -v wget 2>/dev/null),)
  WGET_CMD = wget -q --show-progress -O
else
  WGET_CMD = curl -fL -o
endif
TAR  := tar

# ── Default goal ─────────────────────────────────────────────────────────────
.DEFAULT_GOAL := world
.PHONY: world kernel kernel-headers userland musl busybox runit bpm initramfs install \
        iso repo pkg upgrade-pkg smoke-test fetch clean distclean help _check_tools

world: userland kernel initramfs
	@echo ""
	@echo "  ╔══════════════════════════════════════════════╗"
	@echo "  ║  Blueberry Linux — build complete            ║"
	@echo "  ║  build dir: $(OBJDIR)"
	@echo "  ║  vmlinuz:   $(BOOTDIR)/vmlinuz"
	@echo "  ║  initramfs: $(BOOTDIR)/initramfs.cpio.zst"
	@echo "  ║  rootfs:    $(STAGEDIR)"
	@echo "  ╚══════════════════════════════════════════════╝"
	@echo ""
	@echo "  Run 'make iso'     to create a bootable ISO"
	@echo "  Run 'make install' to install into DESTDIR=$(STAGEDIR)"

# ── Fetch ─────────────────────────────────────────────────────────────────────
fetch: $(STAMP_FETCH_LINUX) $(STAMP_FETCH_MUSL) $(STAMP_FETCH_BUSYBOX) $(STAMP_FETCH_RUNIT)

$(STAMP_FETCH_LINUX): | $(OBJDIR_SRC)
	@echo "[fetch] linux-$(LINUX_VERSION)"
	@if [ ! -f $(OBJDIR_SRC)/linux-$(LINUX_VERSION).tar.xz ]; then \
	    $(WGET_CMD) $(OBJDIR_SRC)/linux-$(LINUX_VERSION).tar.xz $(LINUX_URL); \
	fi
	@if [ ! -d $(LINUX_SRC) ]; then \
	    $(TAR) -xJf $(OBJDIR_SRC)/linux-$(LINUX_VERSION).tar.xz -C $(OBJDIR_SRC); \
	fi
	@touch $@

$(STAMP_FETCH_MUSL): | $(OBJDIR_SRC)
	@echo "[fetch] musl-$(MUSL_VERSION)"
	@if [ ! -f $(OBJDIR_SRC)/musl-$(MUSL_VERSION).tar.gz ]; then \
	    $(WGET_CMD) $(OBJDIR_SRC)/musl-$(MUSL_VERSION).tar.gz $(MUSL_URL); \
	fi
	@if [ ! -d $(MUSL_SRC) ]; then \
	    $(TAR) -xzf $(OBJDIR_SRC)/musl-$(MUSL_VERSION).tar.gz -C $(OBJDIR_SRC); \
	fi
	@touch $@

$(STAMP_FETCH_BUSYBOX): | $(OBJDIR_SRC)
	@echo "[fetch] busybox-$(BUSYBOX_VERSION)"
	@if [ ! -f $(OBJDIR_SRC)/busybox-$(BUSYBOX_VERSION).tar.bz2 ]; then \
	    $(WGET_CMD) $(OBJDIR_SRC)/busybox-$(BUSYBOX_VERSION).tar.bz2 $(BUSYBOX_URL); \
	fi
	@if [ ! -d $(BUSYBOX_SRC) ]; then \
	    $(TAR) -xjf $(OBJDIR_SRC)/busybox-$(BUSYBOX_VERSION).tar.bz2 -C $(OBJDIR_SRC); \
	fi
	@touch $@

$(STAMP_FETCH_RUNIT): | $(OBJDIR_SRC)
	@echo "[fetch] runit-$(RUNIT_VERSION)"
	@if [ ! -f $(OBJDIR_SRC)/runit-$(RUNIT_VERSION).tar.gz ]; then \
	    $(WGET_CMD) $(OBJDIR_SRC)/runit-$(RUNIT_VERSION).tar.gz $(RUNIT_URL); \
	fi
	@if [ ! -d $(OBJDIR_SRC)/admin ]; then \
	    $(TAR) -xzf $(OBJDIR_SRC)/runit-$(RUNIT_VERSION).tar.gz -C $(OBJDIR_SRC); \
	fi
	@touch $@

# ── Kernel headers (needed by musl and busybox) ───────────────────────────────
kernel-headers: $(STAMP_KERNEL_HEADERS)

$(STAMP_KERNEL_HEADERS): $(STAMP_FETCH_LINUX) | $(MUSL_SYSROOT)
	@echo "[kernel-headers] installing to $(MUSL_SYSROOT)/usr"
	@$(MAKE) -C $(LINUX_SRC) \
	    ARCH=$(ARCH) \
	    INSTALL_HDR_PATH=$(MUSL_SYSROOT)/usr \
	    headers_install
	@touch $@

# ── musl libc ─────────────────────────────────────────────────────────────────
musl: $(STAMP_MUSL)

$(STAMP_MUSL): $(STAMP_FETCH_MUSL) $(STAMP_KERNEL_HEADERS) | $(MUSL_SYSROOT)
	@echo "[build] musl-$(MUSL_VERSION)"
	@$(MAKE) -C $(SRCDIR)/lib/musl \
	    MUSL_SRC=$(MUSL_SRC) \
	    SYSROOT=$(MUSL_SYSROOT) \
	    ARCH=$(ARCH) \
	    CC="$(CC)" CFLAGS="$(CFLAGS)" \
	    -j$(JOBS)
	@touch $@

# ── busybox ───────────────────────────────────────────────────────────────────
busybox: $(STAMP_BUSYBOX)

$(STAMP_BUSYBOX): $(STAMP_FETCH_BUSYBOX) $(STAMP_MUSL) | $(STAGEDIR)
	@echo "[build] busybox-$(BUSYBOX_VERSION)"
	@$(MAKE) -C $(SRCDIR)/busybox \
	    BUSYBOX_SRC=$(BUSYBOX_SRC) \
	    SYSROOT=$(MUSL_SYSROOT) \
	    STAGEDIR=$(STAGEDIR) \
	    ARCH=$(ARCH) \
	    -j$(JOBS)
	@touch $@

# ── runit ─────────────────────────────────────────────────────────────────────
runit: $(STAMP_RUNIT)

$(STAMP_RUNIT): $(STAMP_FETCH_RUNIT) $(STAMP_MUSL) | $(STAGEDIR)
	@echo "[build] runit-$(RUNIT_VERSION)"
	@$(MAKE) -C $(SRCDIR)/init \
	    RUNIT_SRC=$(OBJDIR_SRC)/admin/runit-$(RUNIT_VERSION) \
	    SYSROOT=$(MUSL_SYSROOT) \
	    STAGEDIR=$(STAGEDIR) \
	    ARCH=$(ARCH) \
	    -j$(JOBS)
	@touch $@

# ── bpm ───────────────────────────────────────────────────────────────────────
bpm: $(STAMP_BPM)

$(STAMP_BPM): $(shell find $(SRCDIR)/bpm -name '*.go') $(SRCDIR)/bpm/go.mod
	@echo "[build] bpm"
	@$(MAKE) -C $(SRCDIR)/bpm \
	    OUT=$(BPM_BIN) \
	    GO=$(GO) \
	    GOFLAGS="$(GOFLAGS)" \
	    GO_LDFLAGS="$(GO_LDFLAGS)" \
	    ARCH=$(ARCH)
	@touch $@

# ── userland ──────────────────────────────────────────────────────────────────
userland: musl busybox runit bpm

# ── Linux kernel ─────────────────────────────────────────────────────────────
kernel: $(STAMP_KERNEL)

$(STAMP_KERNEL): $(STAMP_FETCH_LINUX) | $(BOOTDIR)
	@echo "[build] linux-$(LINUX_VERSION)"
	@$(MAKE) -C $(SRCDIR)/kernel \
	    LINUX_SRC=$(LINUX_SRC) \
	    LINUX_VERSION=$(LINUX_VERSION) \
	    KERNEL_LOCALVERSION=$(KERNEL_LOCALVERSION) \
	    BOOTDIR=$(BOOTDIR) \
	    STAGEDIR=$(STAGEDIR) \
	    ARCH=$(ARCH) \
	    CROSS_COMPILE="$(CROSS_COMPILE)" \
	    JOBS=$(JOBS)
	@touch $@

# ── initramfs ─────────────────────────────────────────────────────────────────
initramfs: $(STAMP_INITRAMFS)

$(STAMP_INITRAMFS): $(STAMP_BUSYBOX) $(STAMP_RUNIT) | $(BOOTDIR)
	@echo "[build] initramfs"
	@$(MAKE) -C $(SRCDIR)/initramfs \
	    STAGEDIR=$(STAGEDIR) \
	    BOOTDIR=$(BOOTDIR) \
	    OBJDIR=$(OBJDIR) \
	    ARCH=$(ARCH)
	@touch $@

# ── install ───────────────────────────────────────────────────────────────────
install: world
	@echo "[install] rootfs → $(STAGEDIR)"
	@$(MAKE) -f $(TOPDIR)/GNUmakefile _do_install
	@touch $(STAMP_INSTALL)

_do_install:
	@# Copy /etc skeleton
	@mkdir -p $(STAGEDIR)/etc
	@cp -a $(ETCDIR)/. $(STAGEDIR)/etc/
	@# Install bpm binary
	@install -Dm755 $(BPM_BIN) $(STAGEDIR)/usr/bin/bpm
	@# Create FHS directories
	@for d in proc sys dev dev/pts dev/shm run tmp var/log var/empty \
	          var/spool/cron/crontabs root home mnt srv boot \
	          usr/local/bin usr/local/sbin usr/local/lib; do \
	    mkdir -p $(STAGEDIR)/$$d; \
	done
	@chmod 1777 $(STAGEDIR)/tmp
	@chmod 700  $(STAGEDIR)/root
	@chmod 711  $(STAGEDIR)/var/empty
	@# /init → runit-init
	@ln -sf /sbin/runit-init $(STAGEDIR)/init 2>/dev/null || true
	@# Copy boot assets (kernel + initramfs) into rootfs/boot for mkiso.sh
	@cp $(BOOTDIR)/vmlinuz              $(STAGEDIR)/boot/vmlinuz
	@cp $(BOOTDIR)/initramfs.cpio.zst   $(STAGEDIR)/boot/initramfs.cpio.zst
	@echo "[install] done → $(STAGEDIR)"

# ── ISO ───────────────────────────────────────────────────────────────────────
iso: install
	@echo "[iso] building bootable image"
	@$(TOPDIR)/tools/mkiso.sh $(STAGEDIR) \
	    blueberry-$(shell date +%Y%m%d)-$(ARCH).iso

# ── Package repository ────────────────────────────────────────────────────────
repo: bpm
	@command -v musl-gcc >/dev/null 2>&1 || \
	    PATH="$(MUSL_SYSROOT)/bin:$$PATH" command -v musl-gcc >/dev/null 2>&1 || { \
	    echo ""; \
	    echo "ERROR: musl-gcc not found."; \
	    echo "  On Ubuntu/Debian:  sudo apt install musl-tools"; \
	    echo "  On other systems:  run 'make musl' first (builds sysroot + wrapper)"; \
	    echo ""; \
	    exit 1; }
	@echo "[repo] building package index"
	@mkdir -p $(OBJDIR)/repo
	@for bbuild in $(shell find $(PKGSDIR) -name BBUILD | sort); do \
	    PATH="$(MUSL_SYSROOT)/bin:$$PATH" \
	    $(BPM_BIN) build \
	        --output $(OBJDIR)/repo \
	        --arch $(ARCH) \
	        --topdir $(TOPDIR) \
	        $$bbuild || exit 1; \
	done
	@$(TOPDIR)/tools/mkrepo.sh $(OBJDIR)/repo
	@echo "[repo] index written to $(OBJDIR)/repo/BBINDEX.zst"

# ── Single-package build ──────────────────────────────────────────────────────
# Build one package from source without running the full repo target.
# Usage:  make pkg PKG=musl
#         make pkg PKG=zlib ARCH=aarch64
pkg: bpm
	$(if $(PKG),,$(error PKG is not set. Usage: make pkg PKG=<name>))
	@BBUILD=$$(find $(PKGSDIR) -path "*/$(PKG)/BBUILD" | head -1); \
	[ -n "$$BBUILD" ] || { echo "Package '$(PKG)' not found in pkgs/"; exit 1; }; \
	echo "[pkg] building $(PKG)"; \
	PATH="$(MUSL_SYSROOT)/bin:$$PATH" \
	$(BPM_BIN) build \
	    --output $(OBJDIR)/repo \
	    --arch $(ARCH) \
	    --topdir $(TOPDIR) \
	    $$BBUILD

# Bump a package to its latest upstream version, then build it.
# Usage:  make upgrade-pkg PKG=musl
#         make upgrade-pkg PKG=zlib VERSION=1.3.2
upgrade-pkg:
	$(if $(PKG),,$(error PKG is not set. Usage: make upgrade-pkg PKG=<name> [VERSION=x.y.z]))
	@bash $(TOPDIR)/tools/bump-package.sh $(PKG) $(VERSION)
	@$(MAKE) pkg PKG=$(PKG)

# Boot Blueberry in QEMU with a smoke-test init and verify PASS.
# Requires: make world (or at least make kernel + make initramfs)
# The packages repo is built automatically if not already present.
smoke-test:
	@bash $(TOPDIR)/tools/smoke-test.sh

# ── Directory creation ────────────────────────────────────────────────────────
$(OBJDIR_SRC) $(MUSL_SYSROOT) $(STAGEDIR) $(BOOTDIR) $(OBJDIR):
	@mkdir -p $@

# ── Utility targets ───────────────────────────────────────────────────────────
clean:
	@echo "[clean] removing build artefacts"
	@rm -rf $(OBJDIR)/build $(OBJDIR)/boot $(OBJDIR)/rootfs \
	        $(OBJDIR)/sysroot $(OBJDIR)/bpm $(OBJDIR)/repo \
	        $(OBJDIR)/.stamp-* $(OBJDIR_SRC)/admin
	@$(MAKE) -C $(SRCDIR)/bpm clean 2>/dev/null || true

distclean: clean
	@echo "[distclean] removing all downloaded sources"
	@rm -rf $(OBJDIR)

_check_tools:
	@command -v $(CC) >/dev/null   || { echo "ERROR: $(CC) not found"; exit 1; }
	@command -v $(GO)  >/dev/null  || { echo "ERROR: go not found (need >=1.22)"; exit 1; }
	@command -v wget   >/dev/null  || command -v curl >/dev/null || \
	    { echo "ERROR: wget or curl required"; exit 1; }
	@echo "Toolchain OK"

help:
	@echo "Blueberry Linux build system"
	@echo ""
	@echo "OS build targets:"
	@echo "  world          Build everything (default)"
	@echo "  kernel         Build Linux $(LINUX_VERSION) kernel + modules"
	@echo "  userland       Build musl + busybox + runit + bpm"
	@echo "  musl           Build musl libc sysroot"
	@echo "  busybox        Build busybox"
	@echo "  runit          Build runit init"
	@echo "  bpm            Build the package manager"
	@echo "  initramfs      Build initramfs image"
	@echo "  install        Install world into DESTDIR=$(STAGEDIR)"
	@echo "  iso            Build a bootable ISO"
	@echo "  smoke-test     Boot in QEMU and verify SMOKE_TEST_RESULT=PASS"
	@echo ""
	@echo "Package repository targets:"
	@echo "  repo           Build all packages from pkgs/ (needs musl-gcc)"
	@echo "  pkg PKG=<n>    Build a single package by name"
	@echo "  upgrade-pkg PKG=<n> [VERSION=x.y.z]"
	@echo "                 Bump a package to latest (or given) version and build"
	@echo ""
	@echo "Utility targets:"
	@echo "  fetch          Download all upstream OS sources"
	@echo "  clean          Remove build artefacts (keep downloads)"
	@echo "  distclean      Remove everything including downloads"
	@echo "  _check_tools   Verify required tools are installed"
	@echo ""
	@echo "Variables (override with VAR=value):"
	@echo "  ARCH=$(ARCH)  JOBS=$(JOBS)  DESTDIR=$(DESTDIR)"
	@echo "  LINUX_VERSION=$(LINUX_VERSION)  MUSL_VERSION=$(MUSL_VERSION)"
	@echo "  CROSS_COMPILE=$(CROSS_COMPILE)"
