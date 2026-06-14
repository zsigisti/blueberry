# GNUmakefile — Blueberry Linux top-level build system
#
# Primary targets
#   make world        Build everything: busybox, runit, dropbear, kernel, initramfs
#   make kernel       Build the Linux kernel and modules
#   make userland     Build busybox + runit + dropbear (glibc, dynamic)
#   make initramfs    Build the initramfs image
#   make run          Boot the live CLI in QEMU (interactive)
#   make test         Boot in QEMU, run self-tests, verify PASS (headless)
#   make iso          Build a bootable ISO
#   make install      Install the built world into DESTDIR
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
ETCDIR  := $(TOPDIR)/etc

OBJDIR_SRC  := $(OBJDIR)/src
OBJDIR_BUILD := $(OBJDIR)/build
BOOTDIR     := $(OBJDIR)/boot
STAGEDIR    := $(DESTDIR)

LINUX_SRC      := $(OBJDIR_SRC)/linux-$(LINUX_VERSION)
BUSYBOX_SRC    := $(OBJDIR_SRC)/busybox-$(BUSYBOX_VERSION)
RUNIT_SRC      := $(OBJDIR_SRC)/runit-$(RUNIT_VERSION)
DROPBEAR_SRC   := $(OBJDIR_SRC)/dropbear-$(DROPBEAR_VERSION)

# ── Stamp files (track completed build steps) ─────────────────────────────────
STAMP_FETCH_LINUX    := $(OBJDIR)/.stamp-fetch-linux
STAMP_FETCH_BUSYBOX  := $(OBJDIR)/.stamp-fetch-busybox
STAMP_FETCH_RUNIT    := $(OBJDIR)/.stamp-fetch-runit
STAMP_FETCH_DROPBEAR := $(OBJDIR)/.stamp-fetch-dropbear
STAMP_BUSYBOX        := $(OBJDIR)/.stamp-busybox
STAMP_RUNIT          := $(OBJDIR)/.stamp-runit
STAMP_DROPBEAR       := $(OBJDIR)/.stamp-dropbear
STAMP_KERNEL         := $(OBJDIR)/.stamp-kernel
STAMP_INITRAMFS      := $(OBJDIR)/.stamp-initramfs
STAMP_INSTALL        := $(OBJDIR)/.stamp-install

# ── Kernel tarball URL (kernel.org CDN format) ────────────────────────────────
LINUX_MAJOR   := $(firstword $(subst ., ,$(LINUX_VERSION)))
LINUX_URL     := https://cdn.kernel.org/pub/linux/kernel/v$(LINUX_MAJOR).x/linux-$(LINUX_VERSION).tar.xz
BUSYBOX_URL   := https://busybox.net/downloads/busybox-$(BUSYBOX_VERSION).tar.bz2
RUNIT_URL     := http://smarden.org/runit/runit-$(RUNIT_VERSION).tar.gz
DROPBEAR_URL  := https://matt.ucc.asn.au/dropbear/releases/dropbear-$(DROPBEAR_VERSION).tar.bz2

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
.PHONY: world kernel userland busybox runit dropbear initramfs \
        install iso disk run test fetch clean distclean help _check_tools

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
fetch: $(STAMP_FETCH_LINUX) $(STAMP_FETCH_BUSYBOX) $(STAMP_FETCH_RUNIT) $(STAMP_FETCH_DROPBEAR)

$(STAMP_FETCH_LINUX): | $(OBJDIR_SRC)
	@echo "[fetch] linux-$(LINUX_VERSION)"
	@if [ ! -f $(OBJDIR_SRC)/linux-$(LINUX_VERSION).tar.xz ]; then \
	    $(WGET_CMD) $(OBJDIR_SRC)/linux-$(LINUX_VERSION).tar.xz $(LINUX_URL); \
	fi
	@if [ ! -d $(LINUX_SRC) ]; then \
	    $(TAR) -xJf $(OBJDIR_SRC)/linux-$(LINUX_VERSION).tar.xz -C $(OBJDIR_SRC); \
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

$(STAMP_FETCH_DROPBEAR): | $(OBJDIR_SRC)
	@echo "[fetch] dropbear-$(DROPBEAR_VERSION)"
	@if [ ! -f $(OBJDIR_SRC)/dropbear-$(DROPBEAR_VERSION).tar.bz2 ]; then \
	    $(WGET_CMD) $(OBJDIR_SRC)/dropbear-$(DROPBEAR_VERSION).tar.bz2 $(DROPBEAR_URL); \
	fi
	@if [ ! -d $(DROPBEAR_SRC) ]; then \
	    $(TAR) -xjf $(OBJDIR_SRC)/dropbear-$(DROPBEAR_VERSION).tar.bz2 -C $(OBJDIR_SRC); \
	fi
	@touch $@

# ── busybox ───────────────────────────────────────────────────────────────────
busybox: $(STAMP_BUSYBOX)

$(STAMP_BUSYBOX): $(STAMP_FETCH_BUSYBOX) $(SRCDIR)/busybox/config.full | $(STAGEDIR)
	@echo "[build] busybox-$(BUSYBOX_VERSION)"
	@$(MAKE) -C $(SRCDIR)/busybox \
	    BUSYBOX_SRC=$(BUSYBOX_SRC) \
	    CC="$(CC)" \
	    STAGEDIR=$(STAGEDIR) \
	    ARCH=$(ARCH) \
	    -j$(JOBS)
	@touch $@

# ── runit ─────────────────────────────────────────────────────────────────────
runit: $(STAMP_RUNIT)

$(STAMP_RUNIT): $(STAMP_FETCH_RUNIT) | $(STAGEDIR)
	@echo "[build] runit-$(RUNIT_VERSION)"
	@$(MAKE) -C $(SRCDIR)/init \
	    RUNIT_SRC=$(OBJDIR_SRC)/admin/runit-$(RUNIT_VERSION) \
	    CC="$(CC)" \
	    STAGEDIR=$(STAGEDIR) \
	    ARCH=$(ARCH) \
	    -j$(JOBS)
	@touch $@

# ── dropbear (SSH server + client) ────────────────────────────────────────────
dropbear: $(STAMP_DROPBEAR)

$(STAMP_DROPBEAR): $(STAMP_FETCH_DROPBEAR) $(SRCDIR)/dropbear/Makefile | $(STAGEDIR)
	@echo "[build] dropbear-$(DROPBEAR_VERSION)"
	@$(MAKE) -C $(SRCDIR)/dropbear \
	    DROPBEAR_SRC=$(DROPBEAR_SRC) \
	    CC="$(CC)" \
	    STAGEDIR=$(STAGEDIR) \
	    -j$(JOBS)
	@touch $@

# ── userland ──────────────────────────────────────────────────────────────────
userland: busybox runit dropbear

# ── Linux kernel ─────────────────────────────────────────────────────────────
kernel: $(STAMP_KERNEL)

$(STAMP_KERNEL): $(STAMP_FETCH_LINUX) $(TOPDIR)/src/kernel/config | $(BOOTDIR)
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

INITRAMFS_SRC := $(wildcard $(SRCDIR)/initramfs/init $(SRCDIR)/initramfs/selftest \
                            $(SRCDIR)/initramfs/profile $(SRCDIR)/initramfs/udhcpc.script \
                            $(SRCDIR)/initramfs/shadow $(SRCDIR)/initramfs/Makefile \
                            $(SRCDIR)/bpm/Makefile \
                            $(SRCDIR)/bpm/bpm.h $(wildcard $(SRCDIR)/bpm/*.c) \
                            $(ETCDIR)/bpm/repos.conf $(ETCDIR)/bpm/provided)
$(STAMP_INITRAMFS): $(STAMP_BUSYBOX) $(STAMP_RUNIT) $(STAMP_DROPBEAR) $(INITRAMFS_SRC) | $(BOOTDIR)
	@echo "[build] initramfs"
	@$(MAKE) -C $(SRCDIR)/initramfs \
	    STAGEDIR=$(STAGEDIR) \
	    BOOTDIR=$(BOOTDIR) \
	    OBJDIR=$(OBJDIR) \
	    ARCH=$(ARCH) \
	    CC="$(CC)" CFLAGS="$(CFLAGS)"
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
	@# bpm package manager (compiled C binary) + zstd helper
	@$(MAKE) --no-print-directory -C $(SRCDIR)/bpm \
	    CC="$(CC)" CFLAGS="$(CFLAGS)" \
	    OBJDIR=$(OBJDIR)/bpm BPM_OUT=$(OBJDIR)/bpm/bpm
	@install -Dm755 $(OBJDIR)/bpm/bpm $(STAGEDIR)/usr/bin/bpm
	@install -Dm755 $$(command -v zstd) $(STAGEDIR)/usr/bin/zstd
	@# CA trust store so bpm can verify HTTPS repos (TLS via BearSSL).
	@install -Dm644 $$(readlink -f /etc/ssl/certs/ca-certificates.crt) \
	    $(STAGEDIR)/etc/ssl/certs/ca-certificates.crt 2>/dev/null \
	    || echo "WARNING: host CA bundle not found; HTTPS repos won't verify"
	@# Bundle the glibc runtime into the rootfs (disk-boot path + external
	@# prebuilt glibc software). bpm links libzstd, so include it too.
	@bash $(TOPDIR)/tools/bundle-glibc.sh $(STAGEDIR) \
	    $(STAGEDIR)/bin/busybox \
	    $(STAGEDIR)/sbin/runit-init \
	    $(STAGEDIR)/usr/sbin/dropbearmulti \
	    $(STAGEDIR)/usr/bin/zstd \
	    $(STAGEDIR)/usr/bin/bpm
	@# Copy boot assets (kernel + initramfs) into rootfs/boot for mkiso.sh
	@cp $(BOOTDIR)/vmlinuz              $(STAGEDIR)/boot/vmlinuz
	@cp $(BOOTDIR)/initramfs.cpio.zst   $(STAGEDIR)/boot/initramfs.cpio.zst
	@echo "[install] done → $(STAGEDIR)"

# ── ISO ───────────────────────────────────────────────────────────────────────
iso: install
	@echo "[iso] building bootable image"
	@mkdir -p $(TOPDIR)/iso
	@$(TOPDIR)/tools/mkiso.sh $(STAGEDIR) \
	    $(TOPDIR)/iso/blueberry-$(shell date +%Y%m%d)-$(ARCH).iso

# ── Disk image ────────────────────────────────────────────────────────────────
# Build a dd-able, UEFI-bootable raw disk image (ESP + data partition).
# Deploy with: dd if=disk/blueberry-*.img of=/dev/sdX bs=4M oflag=sync
disk: install
	@echo "[disk] building UEFI disk image"
	@mkdir -p $(TOPDIR)/disk
	@$(TOPDIR)/tools/mkdisk.sh \
	    $(TOPDIR)/disk/blueberry-$(shell date +%Y%m%d)-$(ARCH).img \
	    $(STAGEDIR)

# ── QEMU: boot the live CLI ───────────────────────────────────────────────────
# Boot the kernel + initramfs in QEMU and drop straight into an interactive
# Blueberry shell. Ctrl-A X quits QEMU. Requires: make kernel + make initramfs.
run:
	@BOOTDIR=$(BOOTDIR) ARCH=$(ARCH) bash $(TOPDIR)/tools/qemu.sh run

# ── QEMU: automated self-test ─────────────────────────────────────────────────
# Boot headless, run the in-guest self-tests, and assert BLUEBERRY_TEST=PASS.
# This is what CI runs. Exits non-zero on failure.
test:
	@BOOTDIR=$(BOOTDIR) ARCH=$(ARCH) bash $(TOPDIR)/tools/qemu.sh test

# ── Directory creation ────────────────────────────────────────────────────────
$(OBJDIR_SRC) $(STAGEDIR) $(BOOTDIR) $(OBJDIR):
	@mkdir -p $@

# ── Utility targets ───────────────────────────────────────────────────────────
clean:
	@echo "[clean] removing build artefacts"
	@rm -rf $(OBJDIR)/build $(OBJDIR)/boot $(OBJDIR)/rootfs \
	        $(OBJDIR)/sysroot $(OBJDIR)/initramfs \
	        $(OBJDIR)/.stamp-* $(OBJDIR_SRC)/admin \
	        $(TOPDIR)/iso $(TOPDIR)/disk

distclean: clean
	@echo "[distclean] removing all downloaded sources"
	@rm -rf $(OBJDIR)

_check_tools:
	@command -v $(CC) >/dev/null   || { echo "ERROR: $(CC) not found"; exit 1; }
	@command -v wget   >/dev/null  || command -v curl >/dev/null || \
	    { echo "ERROR: wget or curl required"; exit 1; }
	@command -v zstd   >/dev/null  || { echo "ERROR: zstd required (initramfs)"; exit 1; }
	@command -v cpio   >/dev/null  || { echo "ERROR: cpio required (initramfs)"; exit 1; }
	@echo "Toolchain OK"

help:
	@echo "Blueberry Linux build system"
	@echo ""
	@echo "OS build targets:"
	@echo "  world          Build everything (default)"
	@echo "  kernel         Build Linux $(LINUX_VERSION) kernel + modules"
	@echo "  userland       Build busybox + runit + dropbear (glibc, dynamic)"
	@echo "  busybox        Build busybox"
	@echo "  runit          Build runit init"
	@echo "  dropbear       Build Dropbear SSH"
	@echo "  initramfs      Build initramfs image"
	@echo "  install        Install world into DESTDIR=$(STAGEDIR)"
	@echo "  iso            Build a bootable hybrid BIOS+UEFI ISO"
	@echo "  disk           Build a dd-able UEFI disk image (ESP + data)"
	@echo ""
	@echo "QEMU targets:"
	@echo "  run            Boot the live CLI in QEMU (interactive; Ctrl-A X to quit)"
	@echo "  test           Boot headless, run self-tests, assert BLUEBERRY_TEST=PASS"
	@echo ""
	@echo "Utility targets:"
	@echo "  fetch          Download all upstream OS sources"
	@echo "  clean          Remove build artefacts (keep downloads)"
	@echo "  distclean      Remove everything including downloads"
	@echo "  _check_tools   Verify required tools are installed"
	@echo ""
	@echo "Variables (override with VAR=value):"
	@echo "  ARCH=$(ARCH)  JOBS=$(JOBS)  DESTDIR=$(DESTDIR)"
	@echo "  LINUX_VERSION=$(LINUX_VERSION)  BUSYBOX_VERSION=$(BUSYBOX_VERSION)"
	@echo "  CROSS_COMPILE=$(CROSS_COMPILE)"
