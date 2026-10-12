# Blueberry Linux top-level build. `make help` lists the targets.
# Knobs live in Make.config; put your own overrides in Make.local.

TOPDIR := $(CURDIR)

include $(TOPDIR)/Make.config
-include $(TOPDIR)/Make.local

SRCDIR  := $(TOPDIR)/src
ETCDIR  := $(TOPDIR)/etc

OBJDIR_SRC  := $(OBJDIR)/src
OBJDIR_BUILD := $(OBJDIR)/build
BOOTDIR     := $(OBJDIR)/boot
STAGEDIR    := $(DESTDIR)

# Packages baked into the base image. bash is the login shell, ncurses is
# there for it (and for terminfo).
BASE_PKGS   ?= ncurses bash

# Where base packages come from:
#   mirror  fetch the signed .bpm files from the repo, compile nothing (default)
#   source  build them from packages/ - for testing recipe changes before publishing
BASE_SRC    ?= mirror

# INIT only changes the installed rootfs; the live initramfs is busybox either way.
#   systemd  systemd PID 1 + journald/logind/networkd/resolved/timesyncd + OpenSSH (default)
#   runit    busybox + runit + dropbear, the tiny RAM-first image
INIT ?= systemd
# The base extraction is flat - no dependency resolution - so every runtime lib
# a base binary links has to be listed here by hand. Ones that bit us:
#   pcre2   grep and iproute2's ss (libpcre2-8.so.0)
#   mpfr    gawk (libmpfr.so.6)
#   gdbm    pam_userdb.so
#   libmnl  iproute2
#   libbsd/libmd/libxcrypt  shadow (passwd, useradd, newuidmap...)
# xz/zstd/lz4 are real packages rather than host copies so `bpm upgrade` can
# patch them (liblzma CVEs). bundle-glibc reads from the stage, so it won't
# stomp on them.
# shadow is the only thing that gives you passwd - util-linux has none.
# procps-ng/psmisc/lsof: the installed system has no busybox, so without them
# there's no ps/top/killall at all. mandoc + man-pages make `man` work.
# blueberry-console (web UI) ships disabled; `systemctl enable --now
# blueberry-console` turns it on. Its deps are already in the base.
# After an install, `make check-base` reports anything missing from this list.
SYSTEMD_BASE_PKGS := systemd util-linux coreutils libseccomp kmod dbus acl \
                     cryptsetup libcap libcap-ng readline file zlib xz zstd lz4 lzo bzip2 expat \
                     pcre2 mpfr gdbm \
                     attr device-mapper json-c openssl popt openssh pam glibc-locales gmp \
                     shadow libxcrypt libbsd libmd \
                     ca-certificates \
                     iproute2 iputils libmnl wpa_supplicant libnl linux-firmware wireless-regdb ufw \
                     python libffi mpdecimal sqlite \
                     iptables libnftnl libnetfilter_conntrack libnfnetlink \
                     grep sed gawk findutils gzip tar diffutils less which nano vim sudo tzdata kbd \
                     procps-ng psmisc lsof mandoc man-pages \
                     e2fsprogs libtirpc btrfs-progs blueberry-snapshot blueberry-console
ifeq ($(INIT),systemd)
  BASE_PKGS += $(SYSTEMD_BASE_PKGS)
endif

# No datestamp, so run-server/test-server can find it.
SERVER_ISO  := $(TOPDIR)/iso/blueberry-server-$(ARCH).iso
# `make iso` output. This one carries the install payload (rootfs.tar.zst).
INSTALLER_ISO := $(TOPDIR)/iso/blueberry-$(shell date +%Y%m%d)-$(ARCH).iso

LINUX_SRC      := $(OBJDIR_SRC)/linux-$(LINUX_VERSION)
BUSYBOX_SRC    := $(OBJDIR_SRC)/busybox-$(BUSYBOX_VERSION)
RUNIT_SRC      := $(OBJDIR_SRC)/runit-$(RUNIT_VERSION)
DROPBEAR_SRC   := $(OBJDIR_SRC)/dropbear-$(DROPBEAR_VERSION)

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

LINUX_MAJOR   := $(firstword $(subst ., ,$(LINUX_VERSION)))
LINUX_URL     := https://cdn.kernel.org/pub/linux/kernel/v$(LINUX_MAJOR).x/linux-$(LINUX_VERSION).tar.xz
BUSYBOX_URL   := https://busybox.net/downloads/busybox-$(BUSYBOX_VERSION).tar.bz2
RUNIT_URL     := http://smarden.org/runit/runit-$(RUNIT_VERSION).tar.gz
DROPBEAR_URL  := https://matt.ucc.asn.au/dropbear/releases/dropbear-$(DROPBEAR_VERSION).tar.bz2

ifneq ($(shell command -v wget 2>/dev/null),)
  WGET_CMD = wget -q --show-progress -O
else
  WGET_CMD = curl -fL -o
endif
TAR  := tar

.DEFAULT_GOAL := world
.PHONY: world kernel userland busybox runit dropbear initramfs \
        install iso server-iso disk run test \
        run-server test-server test-e2e \
        fetch clean distclean help _check_tools

world: userland kernel initramfs
	@echo ""
	@echo "  Blueberry Linux built."
	@echo "    build dir: $(OBJDIR)"
	@echo "    vmlinuz:   $(BOOTDIR)/vmlinuz"
	@echo "    initramfs: $(BOOTDIR)/initramfs.cpio.zst"
	@echo "    rootfs:    $(STAGEDIR)"
	@echo ""
	@echo "  Run 'make iso'     to create a bootable ISO"
	@echo "  Run 'make install' to install into DESTDIR=$(STAGEDIR)"

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

dropbear: $(STAMP_DROPBEAR)

$(STAMP_DROPBEAR): $(STAMP_FETCH_DROPBEAR) $(SRCDIR)/dropbear/Makefile | $(STAGEDIR)
	@echo "[build] dropbear-$(DROPBEAR_VERSION)"
	@$(MAKE) -C $(SRCDIR)/dropbear \
	    DROPBEAR_SRC=$(DROPBEAR_SRC) \
	    CC="$(CC)" \
	    STAGEDIR=$(STAGEDIR) \
	    -j$(JOBS)
	@touch $@

userland: busybox runit dropbear

# The kernel is a pinned prebuilt (vmlinuz + System.map + modules) on the repo,
# so nobody has to compile it on a laptop. Compiling is opt-in:
#   make kernel          fetch the pinned one
#   make kernel-rebuild  compile it here, once
#   make kernel-publish  compile and upload a new pinned one (build box)
# To change kernels: bump LINUX_VERSION / src/kernel/config, then kernel-publish.
KERNEL_BUILD ?= 0
kernel: $(STAMP_KERNEL)

ifeq ($(KERNEL_BUILD),1)
$(STAMP_KERNEL): $(STAMP_FETCH_LINUX) $(TOPDIR)/src/kernel/config | $(BOOTDIR)
	@echo "[build] linux-$(LINUX_VERSION) (compiling from source, KERNEL_BUILD=1)"
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
else
$(STAMP_KERNEL): $(TOPDIR)/tools/kernel/fetch-kernel.sh | $(BOOTDIR)
	@echo "[kernel] using pinned prebuilt linux-$(LINUX_VERSION)$(KERNEL_LOCALVERSION) (set KERNEL_BUILD=1 to compile)"
	@sh $(TOPDIR)/tools/kernel/fetch-kernel.sh \
	    $(BOOTDIR) $(STAGEDIR) $(LINUX_VERSION) $(KERNEL_LOCALVERSION) $(ARCH)
	@touch $@
endif

.PHONY: kernel-rebuild kernel-publish
kernel-rebuild:
	@rm -f $(STAMP_KERNEL)
	@$(MAKE) kernel KERNEL_BUILD=1

kernel-publish: kernel-rebuild
	@sh $(TOPDIR)/tools/kernel/publish-kernel.sh \
	    $(BOOTDIR) $(STAGEDIR) $(LINUX_VERSION) $(KERNEL_LOCALVERSION) $(ARCH)

initramfs: $(STAMP_INITRAMFS)

INITRAMFS_SRC := $(wildcard $(SRCDIR)/initramfs/init $(SRCDIR)/initramfs/selftest \
                            $(SRCDIR)/initramfs/profile $(SRCDIR)/initramfs/udhcpc.script \
                            $(SRCDIR)/initramfs/shadow $(SRCDIR)/initramfs/Makefile \
                            $(SRCDIR)/bpm-rs/Cargo.toml $(wildcard $(SRCDIR)/bpm-rs/src/*.rs) \
                            $(SRCDIR)/installer/Cargo.toml $(wildcard $(SRCDIR)/installer/src/*.rs) \
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

install: world
	@echo "[install] rootfs -> $(STAGEDIR)"
	@$(MAKE) -f $(TOPDIR)/GNUmakefile _do_install
	@touch $(STAMP_INSTALL)

# Is the staged base self-contained? Every DT_NEEDED has to resolve inside it
# (the "forgot pcre2 again" check), and there must be exactly one libc.
.PHONY: check-base
check-base:
	@sh $(TOPDIR)/tools/pkg/check-base-closure.sh $(STAGEDIR)
	@sh $(TOPDIR)/tools/image/check-libc-single.sh $(STAGEDIR)

_do_install:
	@mkdir -p $(STAGEDIR)/etc
	@cp -a $(ETCDIR)/. $(STAGEDIR)/etc/
	@for d in proc sys dev dev/pts dev/shm run tmp var/tmp var/log var/cache \
	          var/empty var/spool/cron/crontabs root home mnt srv boot \
	          usr/local/bin usr/local/sbin usr/local/lib; do \
	    mkdir -p $(STAGEDIR)/$$d; \
	done
	@chmod 1777 $(STAGEDIR)/tmp
	@chmod 1777 $(STAGEDIR)/var/tmp
	@chmod 700  $(STAGEDIR)/root
	@chmod 711  $(STAGEDIR)/var/empty
	@ln -sf /sbin/runit-init $(STAGEDIR)/init 2>/dev/null || true
	@ARCH=$(ARCH) sh $(TOPDIR)/tools/pkg/build-bpm.sh $(STAGEDIR)/usr/bin/bpm
	@# bpm is built from source rather than extracted from a .bpm, so register
	@# it by hand or `bpm upgrade` won't know it exists.
	@sh $(TOPDIR)/tools/pkg/seed-installed-db.sh $(STAGEDIR) $(TOPDIR)/packages/bpm/bpm.toml usr/bin/bpm
	@install -Dm755 $$(command -v zstd) $(STAGEDIR)/usr/bin/zstd
	@# Host CA bundle, just so bpm can do HTTPS before anything is extracted.
	@# The ca-certificates package replaces it below and also adds
	@# /etc/ssl/cert.pem - without that, anything on OpenSSL's default paths
	@# (python, pip, bpmbuild) trusts nothing at all.
	@install -Dm644 $$(readlink -f /etc/ssl/certs/ca-certificates.crt) \
	    $(STAGEDIR)/etc/ssl/certs/ca-certificates.crt 2>/dev/null \
	    || echo "WARNING: host CA bundle not found; HTTPS repos won't verify"
	@echo "[install] bundling base packages [BASE_SRC=$(BASE_SRC)] ($(BASE_PKGS))"
	@# Both branches also record each package in the bpm DB, otherwise
	@# `bpm upgrade` could never patch openssl/openssh/sudo on an installed box.
	@if [ "$(BASE_SRC)" = source ]; then \
	    sh $(TOPDIR)/tools/pkg/build-bpm-pkg.sh $(OBJDIR)/bpm-out $(BASE_PKGS); \
	    for p in $(BASE_PKGS); do \
	        f=$$(ls -t $(OBJDIR)/bpm-out/$$p-[0-9]*.bpm | head -1); \
	        sh $(TOPDIR)/tools/pkg/bpm-extract-record.sh "$$f" $(STAGEDIR); \
	    done; \
	else \
	    for p in $(BASE_PKGS); do \
	        sh $(TOPDIR)/tools/pkg/fetch-bpm.sh "$$p" $(STAGEDIR) $(OBJDIR)/bpm-cache; \
	        f=$$(ls -t $(OBJDIR)/bpm-cache/$$p-[0-9]*.bpm | head -1); \
	        sh $(TOPDIR)/tools/pkg/bpm-extract-record.sh "$$f" $(STAGEDIR) --record-only; \
	    done; \
	fi
	@# glibc always comes from the mirror, never from the build host: an older
	@# host (Ubuntu's 2.39 vs our 2.43) stages a too-old libc and the box
	@# panics at boot.
	@echo "[install] fetching glibc from mirror"
	@# Wipe any libc already in the stage first. STAGEDIR is reused between
	@# builds, and the 2026-08-16 ISO shipped a stale 2.43 in /usr/lib next to
	@# the packaged 2.44. See check-libc-single.sh.
	@find $(STAGEDIR) -type f \( -name 'libc.so.6' -o -name 'libm.so.6' \
	        -o -name 'ld-linux-x86-64.so.2' \) -delete 2>/dev/null || true
	@sh $(TOPDIR)/tools/pkg/fetch-bpm.sh glibc $(STAGEDIR) $(OBJDIR)/bpm-cache
	@sh $(TOPDIR)/tools/pkg/bpm-extract-record.sh \
	    $$(ls -t $(OBJDIR)/bpm-cache/glibc-[0-9]*.bpm | head -1) $(STAGEDIR) --record-only
	@# drop dev cruft, but keep /usr/share/man - man-pages is in the base
	@rm -rf $(STAGEDIR)/usr/include \
	        $(STAGEDIR)/usr/share/info $(STAGEDIR)/usr/lib/pkgconfig
	@find $(STAGEDIR)/usr/lib -name '*.a' -delete 2>/dev/null || true
	@# same deal as bpm: the kernel isn't a base package, so register it or
	@# `bpm upgrade` never offers a newer one
	@sh $(TOPDIR)/tools/kernel/seed-kernel-db.sh $(STAGEDIR)
ifeq ($(INIT),systemd)
	@echo "[install] INIT=systemd, adding the systemd bits"
	@$(MAKE) -C $(SRCDIR)/systemd STAGEDIR=$(STAGEDIR)
	@# systemd 256 needs merged-usr: the linker only looks in /usr/lib and PID 1
	@# has /usr/sbin/{mount,sulogin} compiled in, so a split rootfs ends up in
	@# emergency mode. /lib64 stays a real dir (it holds the ELF interpreter).
	@sh $(TOPDIR)/tools/image/usr-merge.sh $(STAGEDIR)
	@# The initramfs execs /sbin/init after switch_root, so this link is what
	@# picks the init. Absolute on purpose: it resolves inside the new root, and
	@# the initramfs's `-L` check accepts a link it can't follow yet.
	@ln -sf /usr/lib/systemd/systemd $(STAGEDIR)/sbin/init
	@ln -sf /usr/lib/systemd/systemd $(STAGEDIR)/init
endif
	@# Pull in the glibc runtime these need. Binaries that don't exist on this
	@# INIT are skipped. GLIBC_SYSROOT points at the stage so it uses the mirror
	@# glibc from above, not the host's.
	@GLIBC_SYSROOT=$(STAGEDIR) bash $(TOPDIR)/tools/image/bundle-glibc.sh $(STAGEDIR) \
	    $(STAGEDIR)/bin/busybox \
	    $(STAGEDIR)/sbin/runit-init \
	    $(STAGEDIR)/usr/sbin/dropbearmulti \
	    $(STAGEDIR)/usr/lib/systemd/systemd \
	    $(STAGEDIR)/usr/sbin/sshd \
	    $(STAGEDIR)/usr/bin/zstd \
	    $(STAGEDIR)/usr/bin/bpm \
	    $(STAGEDIR)/usr/bin/bash
	@# mkiso.sh picks these up from rootfs/boot
	@cp $(BOOTDIR)/vmlinuz              $(STAGEDIR)/boot/vmlinuz
	@cp $(BOOTDIR)/initramfs.cpio.zst   $(STAGEDIR)/boot/initramfs.cpio.zst
	@echo "[install] done -> $(STAGEDIR)"

iso: install
	@echo "[iso] building bootable image"
	@mkdir -p $(TOPDIR)/iso
	@$(TOPDIR)/tools/image/mkiso.sh $(STAGEDIR) \
	    $(TOPDIR)/iso/blueberry-$(shell date +%Y%m%d)-$(ARCH).iso

# Live server ISO: the full systemd rootfs squashed and booted through the
# blueberry.live=1 overlay, autologin root at multi-user. Needs INIT=systemd.
server-iso: install
	@echo "[server-iso] assembling systemd live CLI ISO"
	@mkdir -p $(TOPDIR)/iso
	@INIT=systemd BOOTDIR=$(BOOTDIR) $(TOPDIR)/tools/image/mkserveriso.sh $(STAGEDIR) \
	    $(SERVER_ISO)

# Raw UEFI disk image (ESP + data). dd if=disk/blueberry-*.img of=/dev/sdX bs=4M oflag=sync
disk: install
	@echo "[disk] building UEFI disk image"
	@mkdir -p $(TOPDIR)/disk
	@$(TOPDIR)/tools/image/mkdisk.sh \
	    $(TOPDIR)/disk/blueberry-$(shell date +%Y%m%d)-$(ARCH).img \
	    $(STAGEDIR)

# GitHub release with iso/*.iso attached as assets (ISOs never go on the
# mirror). Edit release/NOTES.md first, then: make release TAG=v0.5.2-beta
.PHONY: release release-stage
release release-stage:
	@bash $(TOPDIR)/tools/release/stage-release.sh $(TAG) $(if $(TITLE),"$(TITLE)",)

# run-* opens a QEMU window, test-* boots headless and checks it came up.
# They only build the ISO if it's missing. Plain run/test boot just the
# initramfs - that's the quick one CI uses.
run:
	@BOOTDIR=$(BOOTDIR) ARCH=$(ARCH) bash $(TOPDIR)/tools/test/qemu.sh run
test:
	@BOOTDIR=$(BOOTDIR) ARCH=$(ARCH) bash $(TOPDIR)/tools/test/qemu.sh test

run-server:
	@[ -f $(SERVER_ISO) ] || $(MAKE) server-iso
	@bash $(TOPDIR)/tools/test/boot-iso.sh run  $(SERVER_ISO) server

# run-server, but with the console (9090) and SSH (2222) forwarded to the LAN,
# so https://<this-host>:9090 works from other machines. BRIDGE=<iface> gives
# the VM its own LAN IP instead.
.PHONY: run-server-console
run-server-console:
	@[ -f $(SERVER_ISO) ] || $(MAKE) server-iso
	@CONSOLE_FWD=1 bash $(TOPDIR)/tools/test/boot-iso.sh run $(SERVER_ISO) server
test-server:
	@[ -f $(SERVER_ISO) ] || $(MAKE) server-iso
	@bash $(TOPDIR)/tools/test/boot-iso.sh test $(SERVER_ISO) server

# Installer ISO plus a blank disk, for driving blueberry-install by hand. The
# disk sticks around next to the ISO, so you can boot the result afterwards:
#   qemu ... -drive file=iso/*-target.qcow2 -boot c
.PHONY: run-install
run-install:
	@[ -f $(INSTALLER_ISO) ] || $(MAKE) iso
	@bash $(TOPDIR)/tools/test/boot-iso.sh run $(INSTALLER_ISO) install

# test-server only waits for "blueberry login:", which shows up before PAM
# runs. This one checks the autologin actually lands in a shell.
.PHONY: test-login
test-login:
	@[ -f $(SERVER_ISO) ] || $(MAKE) server-iso
	@sh $(TOPDIR)/tools/test/boot-login-check.sh $(SERVER_ISO) $(OBJDIR)/serial-login.log

$(OBJDIR_SRC) $(STAGEDIR) $(BOOTDIR) $(OBJDIR):
	@mkdir -p $@

# every packages/<name> with a bpm.toml
ALL_BPM_PKGS := $(notdir $(patsubst %/bpm.toml,%,$(wildcard $(TOPDIR)/packages/*/bpm.toml)))

# every `depends` must have a recipe (or be host-provided)
.PHONY: check-closure build-world repo-build audit-deps
check-closure:
	@python3 $(TOPDIR)/tools/pkg/check-closure.py

# Check what every built package actually links against vs. what its recipe
# declares. Needs a populated obj/bpm-out (e.g. after `make repo-selfhost`).
AUDIT_ENGINE ?= podman
AUDIT_IMAGE  ?= localhost/blueberry-builder:latest
AUDIT_STORE  ?= $(TOPDIR)/obj/bpm-out
audit-deps:
	@$(AUDIT_ENGINE) run --rm --security-opt seccomp=unconfined \
	    -v $(TOPDIR):/repo:ro,z -v $(AUDIT_STORE):/deps:ro,z \
	    $(AUDIT_IMAGE) python3 /repo/tools/pkg/audit-runtime-deps.py

# Build every .bpm (skips up-to-date ones). Takes a while - build box material.
repo-build:
	@echo "[repo] building all $(words $(ALL_BPM_PKGS)) .bpm packages"
	@sh $(TOPDIR)/tools/pkg/build-bpm-pkg.sh $(OBJDIR)/bpm-out $(ALL_BPM_PKGS)

# Rebuild the whole repo on Blueberry's own toolchain (BASE=blueberry, no Arch),
# in dependency order. Seeds from the mirror, restores from it if something
# fails, and resumes via obj/.selfhost-done. FORCE=1 redoes everything.
.PHONY: repo-selfhost
repo-selfhost:
	@sh $(TOPDIR)/tools/pkg/repo-selfhost.sh

# closure check + build every package. Nightly/build-box only, way too slow per push.
build-world: check-closure repo-build
	@echo "[build-world] all $(words $(ALL_BPM_PKGS)) packages built; recipe closure green"

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
	@echo "  kernel         Fetch pinned prebuilt Linux $(LINUX_VERSION) (not compiled)"
	@echo "  kernel-rebuild Compile Linux $(LINUX_VERSION) from source (opt-in; build box)"
	@echo "  kernel-publish Compile + upload a new pinned kernel artifact (build box)"
	@echo "  userland       Build busybox + runit + dropbear (glibc, dynamic)"
	@echo "  busybox        Build busybox"
	@echo "  runit          Build runit init"
	@echo "  dropbear       Build Dropbear SSH"
	@echo "  initramfs      Build initramfs image"
	@echo "  install        Install world into DESTDIR=$(STAGEDIR)"
	@echo "  iso            Build the busybox live-CLI rescue ISO"
	@echo "  server-iso     Build the systemd Server live ISO (CLI)"
	@echo "  disk           Build a dd-able UEFI disk image (ESP + data)"
	@echo ""
	@echo "QEMU targets:"
	@echo "  run            Boot the initramfs live CLI (interactive; Ctrl-A X)"
	@echo "  test           Boot headless, run self-tests, assert BLUEBERRY_TEST=PASS"
	@echo "  run-server     Boot the Server ISO in a QEMU window"
	@echo "  test-server    Boot the Server ISO headless, assert multi-user.target"
	@echo "  test-bpm       Fast bpm unit tests (install/upgrade/config/remove; no QEMU)"
	@echo "  test-install   Unattended install in QEMU, boot the disk, assert service health"
	@echo "  test-e2e       Full smoke test: bpm tests + both ISOs + boot + install + boot"
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

# bpm install/upgrade/.bpmnew/remove against a throwaway BPM_ROOT. Seconds, no QEMU.
.PHONY: test-bpm
test-bpm:
	@sh $(TOPDIR)/tools/test/test-bpm.sh

# Build each service .bpm, start it and poke it (redis PING, HTTP GET, SQL
# SELECT). A boot test can't tell you the daemon works. SERVICES="redis nginx"
# to pick.
.PHONY: test-services
test-services:
	@sh $(TOPDIR)/tools/test/service-smoke.sh $(SERVICES)

# Secure Boot with our own keys under OVMF: signed image must boot, unsigned
# must get rejected. Skips if OVMF/qemu/virt-fw-vars or the .bpms aren't there.
.PHONY: test-secureboot
test-secureboot:
	@bash $(TOPDIR)/tools/test/secureboot-test.sh

# unattended install in QEMU, then boot the disk and check services came up
.PHONY: test-install
test-install:
	@[ -f $(INSTALLER_ISO) ] || $(MAKE) iso
	@bash $(TOPDIR)/tools/test/test-install.sh $(INSTALLER_ISO)

# The whole thing: bpm tests, both ISOs, boot, install, boot the install.
# Run this before a release.
.PHONY: test-e2e
test-e2e:
	@echo "[test-e2e] 1/5 bpm package-manager unit tests"
	@$(MAKE) test-bpm
	@echo "[test-e2e] 2/5 build + install rootfs"
	@$(MAKE) install
	@echo "[test-e2e] 3/5 build ISOs"
	@$(MAKE) iso server-iso
	@echo "[test-e2e] 4/5 boot the Server ISO"
	@$(MAKE) test-server
	@echo "[test-e2e] 5/5 unattended install + boot the installed disk (asserts service health)"
	@$(MAKE) test-install
	@echo "[test-e2e] PASS: bpm tests green, server ISO boots, installed disk boots with sshd+networkd up"
