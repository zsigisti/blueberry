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

# Packages baked into the base image (built from packages/<name> and extracted
# into the rootfs at install time). bash = default login shell; ncurses backs
# it and supplies the terminfo database.
BASE_PKGS   ?= ncurses bash

# ── Init system selection ─────────────────────────────────────────────────────
# INIT=runit   (default) busybox + runit + dropbear, tiny RAM-first image.
# INIT=systemd full systemd PID 1 on the *installed* disk system: journald,
#              logind, networkd/resolved/timesyncd, udevd + OpenSSH. The live
#              initramfs stays busybox-based either way; only the installed
#              rootfs (STAGEDIR) changes. The systemd runtime closure below is
#              baked into the base image so PID 1 has everything it needs.
INIT ?= systemd
# xz/zstd/lz4 are not standalone packages — their libs (liblzma/libzstd/liblz4)
# are bundled into the base image from the host (see etc/bpm/provided) and pulled
# into the rootfs via systemd's ldd closure in bundle-glibc.
SYSTEMD_BASE_PKGS := systemd util-linux libseccomp kmod dbus acl \
                     cryptsetup libcap libcap-ng readline file zlib bzip2 expat \
                     attr device-mapper json-c openssl popt openssh
ifeq ($(INIT),systemd)
  BASE_PKGS += $(SYSTEMD_BASE_PKGS)
endif

# ── Desktop edition (Blueberry Desktop) ───────────────────────────────────────
# Opt-in downstream edition: a GUI, user-oriented distro with Ubuntu-style
# releases and a live Calamares installer (KDE Plasma default, GNOME optional).
# Only active for `make desktop-*` goals or EDITION=desktop, so the minimal CLI
# build is untouched otherwise. See editions/desktop/.
ifneq ($(filter desktop desktop-%,$(MAKECMDGOALS))$(filter desktop,$(EDITION)),)
  include $(TOPDIR)/editions/desktop/profile.mk
endif

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

RUNIT_FILES := $(wildcard $(SRCDIR)/init/[123] $(SRCDIR)/init/Makefile \
                          $(SRCDIR)/init/sv-enable $(SRCDIR)/init/sv-disable \
                          $(SRCDIR)/init/sv/*/run $(SRCDIR)/init/sv/*/finish)
$(STAMP_RUNIT): $(STAMP_FETCH_RUNIT) $(RUNIT_FILES) | $(STAGEDIR)
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
                            $(SRCDIR)/bpm-rs/Cargo.toml $(wildcard $(SRCDIR)/bpm-rs/src/*.rs) \
                            $(SRCDIR)/installer/Makefile $(SRCDIR)/installer/blueberry-install.c \
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
	@# bpm package manager (Rust, src/bpm-rs) + zstd helper
	@ARCH=$(ARCH) sh $(TOPDIR)/tools/build-bpm.sh $(STAGEDIR)/usr/bin/bpm
	@install -Dm755 $$(command -v zstd) $(STAGEDIR)/usr/bin/zstd
	@# CA trust store so bpm and curl can verify HTTPS (rustls TLS in bpm).
	@install -Dm644 $$(readlink -f /etc/ssl/certs/ca-certificates.crt) \
	    $(STAGEDIR)/etc/ssl/certs/ca-certificates.crt 2>/dev/null \
	    || echo "WARNING: host CA bundle not found; HTTPS repos won't verify"
	@# Base packages shipped in the image. bash is the default interactive shell
	@# (busybox ash stays as /bin/sh for scripts); ncurses backs it + provides
	@# the terminfo database. Built once, then extracted into the rootfs.
	@echo "[install] bundling base packages ($(BASE_PKGS))"
	@sh $(TOPDIR)/tools/build-pkgs.sh $(OBJDIR)/basepkgs $(BASE_PKGS)
	@for p in $(BASE_PKGS); do \
	    f=$$(ls -t $(OBJDIR)/basepkgs/$$p-[0-9]*.pkg.tar.zst | head -1); \
	    zstd -dcq "$$f" \
	        | tar -x -C $(STAGEDIR) --exclude .PKGINFO --exclude .MTREE \
	          --exclude .BUILDINFO --exclude .INSTALL 2>/dev/null; \
	done
	@# trim dev cruft (headers, static libs, man/info, pkgconfig)
	@rm -rf $(STAGEDIR)/usr/include $(STAGEDIR)/usr/share/man \
	        $(STAGEDIR)/usr/share/info $(STAGEDIR)/usr/lib/pkgconfig
	@find $(STAGEDIR)/usr/lib -name '*.a' -delete 2>/dev/null || true
	@# Init-system integration on the installed rootfs.
ifeq ($(INIT),systemd)
	@echo "[install] INIT=systemd — installing systemd integration layer"
	@$(MAKE) -C $(SRCDIR)/systemd STAGEDIR=$(STAGEDIR)
	@# Convert the rootfs to merged-usr (everything in /usr/bin + /usr/lib).
	@# systemd 256 requires it: the glibc linker only searches /usr/lib and PID 1
	@# has compiled-in /usr/sbin/{mount,sulogin} paths, so a split rootfs panics /
	@# drops to emergency mode. /lib64 keeps the ELF interpreter and stays real.
	@sh $(TOPDIR)/tools/usr-merge.sh $(STAGEDIR)
	@# /sbin/init → systemd PID 1 (the initramfs execs /sbin/init on switch_root,
	@# so this is the single indirection that selects the installed init system).
	@# Absolute target: switch_root resolves it inside the new root, and the
	@# initramfs accepts a symlink it can't pre-resolve (the `-L` check).
	@ln -sf /usr/lib/systemd/systemd $(STAGEDIR)/sbin/init
	@ln -sf /usr/lib/systemd/systemd $(STAGEDIR)/init
endif
	@# Bundle the glibc runtime into the rootfs (disk-boot path + external
	@# prebuilt glibc software). bpm links libzstd, so include it too. Missing
	@# binaries (e.g. runit/dropbear on a systemd image) are skipped by the script.
	@bash $(TOPDIR)/tools/bundle-glibc.sh $(STAGEDIR) \
	    $(STAGEDIR)/bin/busybox \
	    $(STAGEDIR)/sbin/runit-init \
	    $(STAGEDIR)/usr/sbin/dropbearmulti \
	    $(STAGEDIR)/usr/lib/systemd/systemd \
	    $(STAGEDIR)/usr/sbin/sshd \
	    $(STAGEDIR)/usr/bin/zstd \
	    $(STAGEDIR)/usr/bin/bpm \
	    $(STAGEDIR)/usr/bin/bash
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

# ── Server ISO (systemd live CLI) ─────────────────────────────────────────────
# A live ISO of the Server/CLI running systemd PID 1 (journald/logind/networkd),
# booting to multi-user.target with an autologin root shell. Requires the
# systemd base (INIT=systemd, now the default). Unlike `iso` (busybox rescue),
# this squashes a full systemd rootfs via the blueberry.live=1 overlay path.
server-iso: install
	@echo "[server-iso] assembling systemd live CLI ISO"
	@mkdir -p $(TOPDIR)/iso
	@INIT=systemd BOOTDIR=$(BOOTDIR) $(TOPDIR)/tools/mkserveriso.sh $(STAGEDIR) \
	    $(TOPDIR)/iso/blueberry-server-$(shell date +%Y%m%d)-$(ARCH).iso

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
