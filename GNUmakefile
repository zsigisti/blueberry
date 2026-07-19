# GNUmakefile — Blueberry Linux top-level build system
#
# Primary targets
#   make world        Build everything: busybox, runit, dropbear, kernel, initramfs
#   make kernel       Fetch the pinned prebuilt kernel (NOT compiled by default)
#   make kernel-rebuild  Compile the kernel from source this once (needs a build box)
#   make kernel-publish  Compile + upload a new pinned kernel artifact (build box)
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

# Where the base packages come from at install/iso time:
#   mirror (default) — fetch each prebuilt, signed .bpm from the repo; nothing is
#                      compiled locally, so the ISO is reproducible from published
#                      packages (glibc + the kernel already work this way).
#   source           — build every base package from the recipe tree (dev: use
#                      when testing local recipe changes before publishing).
BASE_SRC    ?= mirror

# ── Init system selection ─────────────────────────────────────────────────────
# INIT=runit   (default) busybox + runit + dropbear, tiny RAM-first image.
# INIT=systemd full systemd PID 1 on the *installed* disk system: journald,
#              logind, networkd/resolved/timesyncd, udevd + OpenSSH. The live
#              initramfs stays busybox-based either way; only the installed
#              rootfs (STAGEDIR) changes. The systemd runtime closure below is
#              baked into the base image so PID 1 has everything it needs.
INIT ?= systemd
# xz/zstd/lz4 are proper tracked base packages: their CLIs + libs (liblzma/
# libzstd/liblz4) come from the container-built packages, so `bpm upgrade` can
# patch them (liblzma CVEs matter) and the versions are reproducible — not the
# build host's. bundle-glibc sources from the staged rootfs (SYSROOT=STAGEDIR),
# so it finds these package libs already in place and does not overwrite them.
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
                     e2fsprogs libtirpc btrfs-progs blueberry-snapshot
# procps-ng gives ps/top/free/uptime/vmstat/pgrep/pkill/sysctl (busybox has these
# only in the live initramfs; the installed systemd rootfs would have none).
# psmisc = killall/pstree/fuser, lsof = open-file/port inspection. mandoc is the
# man/apropos reader (no groff needed) and man-pages ships the actual content.
# Networking userland: ip/ss/tc/bridge (iproute2, needs libmnl) + ping/tracepath
# (iputils). The stack itself (systemd-networkd/resolved) is in systemd; these are
# the diagnostic CLI tools. The base extraction is flat (no dep resolution), so
# libmnl is listed explicitly; libcap (also needed) is already above.
# Same reason for the pcre2/mpfr/gdbm line: they are runtime libraries hard-linked
# by base tools but not otherwise pulled in — pcre2 = grep + iproute2's `ss`
# (libpcre2-8.so.0), mpfr = gawk (libmpfr.so.6), gdbm = pam's pam_userdb.so.
# shadow ships passwd/useradd/usermod/chage/gpasswd + newuidmap/newgidmap —
# without it there is no passwd on the system (util-linux has none, no busybox),
# so root cannot change any password. Its binaries link libbsd (→ libmd) and
# libxcrypt (libcrypt.so.2), which the flat base must list explicitly.
# Run `make check-base` (tools/pkg/check-base-closure.sh) after an install to
# report any base binary whose DT_NEEDED library the base list doesn't provide.
ifeq ($(INIT),systemd)
  BASE_PKGS += $(SYSTEMD_BASE_PKGS)
endif

# ── Desktop edition (Blueberry Desktop) ───────────────────────────────────────
# Opt-in downstream edition: a GUI, user-oriented distro with Ubuntu-style

# Stable ISO paths (no datestamp) so `make run-*`/`test-*` can find the artifact.
SERVER_ISO  := $(TOPDIR)/iso/blueberry-server-$(ARCH).iso
# The installer/rescue ISO (`make iso`) is datestamped and is the medium that
# actually carries the install payload (rootfs.tar.zst) — test-install uses it.
INSTALLER_ISO := $(TOPDIR)/iso/blueberry-$(shell date +%Y%m%d)-$(ARCH).iso

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
        install iso server-iso disk run test \
        run-server test-server test-e2e \
        fetch clean distclean help _check_tools

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
# The kernel is NOT rolling and NOT compiled on every build. It is a pinned,
# prebuilt binary artifact (vmlinuz + System.map + modules) hosted on the repo,
# so small machines never have to compile the kernel. Compiling is opt-in:
#   make kernel                  fetch the pinned prebuilt artifact (default)
#   make kernel-rebuild          compile from source this once (KERNEL_BUILD=1)
#   make kernel-publish          compile + upload a new pinned artifact (build box)
# Bump LINUX_VERSION / src/kernel/config, then `make kernel-publish` to release it.
KERNEL_BUILD ?= 0
kernel: $(STAMP_KERNEL)

ifeq ($(KERNEL_BUILD),1)
$(STAMP_KERNEL): $(STAMP_FETCH_LINUX) $(TOPDIR)/src/kernel/config | $(BOOTDIR)
	@echo "[build] linux-$(LINUX_VERSION) (compiling from source — KERNEL_BUILD=1)"
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

# Compile the kernel from source (opt-in; needs a real build box + the linux tree).
.PHONY: kernel-rebuild kernel-publish
kernel-rebuild:
	@rm -f $(STAMP_KERNEL)
	@$(MAKE) kernel KERNEL_BUILD=1

# Compile + upload a new pinned artifact so every other build can fetch it.
kernel-publish: kernel-rebuild
	@sh $(TOPDIR)/tools/kernel/publish-kernel.sh \
	    $(BOOTDIR) $(STAGEDIR) $(LINUX_VERSION) $(KERNEL_LOCALVERSION) $(ARCH)

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

# Verify the assembled base rootfs is self-contained: every base binary can
# resolve its DT_NEEDED shared libraries from within the base itself. Catches the
# "flat list forgot a runtime lib" class of bug (grep→pcre2, gawk→mpfr, …).
.PHONY: check-base
check-base:
	@sh $(TOPDIR)/tools/pkg/check-base-closure.sh $(STAGEDIR)

_do_install:
	@# Copy /etc skeleton
	@mkdir -p $(STAGEDIR)/etc
	@cp -a $(ETCDIR)/. $(STAGEDIR)/etc/
	@# Create FHS directories
	@for d in proc sys dev dev/pts dev/shm run tmp var/tmp var/log var/cache \
	          var/empty var/spool/cron/crontabs root home mnt srv boot \
	          usr/local/bin usr/local/sbin usr/local/lib; do \
	    mkdir -p $(STAGEDIR)/$$d; \
	done
	@chmod 1777 $(STAGEDIR)/tmp
	@chmod 1777 $(STAGEDIR)/var/tmp
	@chmod 700  $(STAGEDIR)/root
	@chmod 711  $(STAGEDIR)/var/empty
	@# /init → runit-init
	@ln -sf /sbin/runit-init $(STAGEDIR)/init 2>/dev/null || true
	@# bpm package manager (Rust, src/bpm-rs) + zstd helper
	@ARCH=$(ARCH) sh $(TOPDIR)/tools/pkg/build-bpm.sh $(STAGEDIR)/usr/bin/bpm
	@# Register bpm in its own DB so `bpm list`/`bpm upgrade` track the package
	@# manager itself (it is built from source here, not extracted from a .bpm).
	@sh $(TOPDIR)/tools/pkg/seed-installed-db.sh $(STAGEDIR) $(TOPDIR)/packages/bpm/bpm.toml usr/bin/bpm
	@install -Dm755 $$(command -v zstd) $(STAGEDIR)/usr/bin/zstd
	@# Bootstrap CA bundle so bpm can verify HTTPS (rustls) before any package is
	@# extracted. The ca-certificates PACKAGE (in BASE_PKGS, extracted below) then
	@# overwrites this with the pinned Mozilla bundle and — crucially — also lays
	@# down /etc/ssl/cert.pem, OpenSSL's default CAfile. Without that file nothing
	@# using OpenSSL's default verify paths (python/pip/bpmbuild) trusts anything,
	@# since the bundle alone gives no hashed CApath. Host-copy is a fallback only.
	@install -Dm644 $$(readlink -f /etc/ssl/certs/ca-certificates.crt) \
	    $(STAGEDIR)/etc/ssl/certs/ca-certificates.crt 2>/dev/null \
	    || echo "WARNING: host CA bundle not found; HTTPS repos won't verify"
	@# Base packages shipped in the image. bash is the default interactive shell
	@# (busybox ash stays as /bin/sh for scripts); ncurses backs it + provides
	@# the terminfo database. Built once, then extracted into the rootfs.
	@echo "[install] bundling base packages [BASE_SRC=$(BASE_SRC)] ($(BASE_PKGS))"
	@# Each .bpm is a zstd tarball of ./usr… plus a .BPM manifest. Both paths extract
	@# it into the rootfs AND record it in the bpm DB, so the base userland is
	@# bpm-tracked and `bpm upgrade` can pull security/version updates (openssl,
	@# openssh, sudo, …) — not just the kernel.
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
	@# glibc: ALWAYS fetch the pinned, container-built package from the MIRROR —
	@# never build it here or copy the build host's libc. Same rationale as the
	@# initramfs: a host older than the container (Ubuntu 2.39 vs 2.43) would
	@# otherwise stage a too-old libc and panic at boot. bundle-glibc below sources
	@# the runtime from here (GLIBC_SYSROOT=$(STAGEDIR)).
	@echo "[install] fetching glibc from mirror"
	@sh $(TOPDIR)/tools/pkg/fetch-bpm.sh glibc $(STAGEDIR) $(OBJDIR)/bpm-cache
	@# Record glibc in the bpm DB too (fetch-bpm already extracted it).
	@sh $(TOPDIR)/tools/pkg/bpm-extract-record.sh \
	    $$(ls -t $(OBJDIR)/bpm-cache/glibc-[0-9]*.bpm | head -1) $(STAGEDIR) --record-only
	@# trim dev cruft (headers, static libs, info, pkgconfig). Keep /usr/share/man:
	@# mandoc + man-pages are in the base so `man`/apropos work on the server.
	@rm -rf $(STAGEDIR)/usr/include \
	        $(STAGEDIR)/usr/share/info $(STAGEDIR)/usr/lib/pkgconfig
	@find $(STAGEDIR)/usr/lib -name '*.a' -delete 2>/dev/null || true
	@# Register the pinned kernel as an installed bpm package so `bpm upgrade`
	@# can pull + install a newer linux .bpm from the repo (the kernel is a
	@# prebuilt artifact, not a base package, so bpm otherwise can't see it).
	@sh $(TOPDIR)/tools/kernel/seed-kernel-db.sh $(STAGEDIR)
	@# Init-system integration on the installed rootfs.
ifeq ($(INIT),systemd)
	@echo "[install] INIT=systemd — installing systemd integration layer"
	@$(MAKE) -C $(SRCDIR)/systemd STAGEDIR=$(STAGEDIR)
	@# Convert the rootfs to merged-usr (everything in /usr/bin + /usr/lib).
	@# systemd 256 requires it: the glibc linker only searches /usr/lib and PID 1
	@# has compiled-in /usr/sbin/{mount,sulogin} paths, so a split rootfs panics /
	@# drops to emergency mode. /lib64 keeps the ELF interpreter and stays real.
	@sh $(TOPDIR)/tools/image/usr-merge.sh $(STAGEDIR)
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
	@# GLIBC_SYSROOT=$(STAGEDIR): source glibc from the mirror package fetched
	@# above into the rootfs, NOT the build host (host may be older — Ubuntu 2.39).
	@GLIBC_SYSROOT=$(STAGEDIR) bash $(TOPDIR)/tools/image/bundle-glibc.sh $(STAGEDIR) \
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
	@$(TOPDIR)/tools/image/mkiso.sh $(STAGEDIR) \
	    $(TOPDIR)/iso/blueberry-$(shell date +%Y%m%d)-$(ARCH).iso

# ── Server ISO (systemd live CLI) ─────────────────────────────────────────────
# A live ISO of the Server/CLI running systemd PID 1 (journald/logind/networkd),
# booting to multi-user.target with an autologin root shell. Requires the
# systemd base (INIT=systemd, now the default). Unlike `iso` (busybox rescue),
# this squashes a full systemd rootfs via the blueberry.live=1 overlay path.
server-iso: install
	@echo "[server-iso] assembling systemd live CLI ISO"
	@mkdir -p $(TOPDIR)/iso
	@INIT=systemd BOOTDIR=$(BOOTDIR) $(TOPDIR)/tools/image/mkserveriso.sh $(STAGEDIR) \
	    $(SERVER_ISO)

# ── Disk image ────────────────────────────────────────────────────────────────
# Build a dd-able, UEFI-bootable raw disk image (ESP + data partition).
# Deploy with: dd if=disk/blueberry-*.img of=/dev/sdX bs=4M oflag=sync
disk: install
	@echo "[disk] building UEFI disk image"
	@mkdir -p $(TOPDIR)/disk
	@$(TOPDIR)/tools/image/mkdisk.sh \
	    $(TOPDIR)/disk/blueberry-$(shell date +%Y%m%d)-$(ARCH).img \
	    $(STAGEDIR)

# ── QEMU: run + test ──────────────────────────────────────────────────────────
# run-*  : boot the edition's ISO in a QEMU window (interactive).
# test-* : boot it headless and assert the edition reached its ready target.
# Each builds the ISO only if it is missing (no forced world rebuild). The bare
# `run`/`test` keep the fast initramfs smoke path (what CI runs).
# Cut a GitHub release with iso/*.iso attached DIRECTLY as assets (never on the
# mirror). Edit release/NOTES.md first, then: make release TAG=v0.5.2-beta
.PHONY: release release-stage
release release-stage:
	@bash $(TOPDIR)/tools/release/stage-release.sh $(TAG) $(if $(TITLE),"$(TITLE)",)

run:
	@BOOTDIR=$(BOOTDIR) ARCH=$(ARCH) bash $(TOPDIR)/tools/test/qemu.sh run
test:
	@BOOTDIR=$(BOOTDIR) ARCH=$(ARCH) bash $(TOPDIR)/tools/test/qemu.sh test

run-server:
	@[ -f $(SERVER_ISO) ] || $(MAKE) server-iso
	@bash $(TOPDIR)/tools/test/boot-iso.sh run  $(SERVER_ISO) server

# Like run-server, but forwards the console (9090) + SSH (2222) to the LAN so you
# can reach the Blueberry Console at https://<this-host-ip>:9090 from any machine
# on the network. Set BRIDGE=<iface> to instead give the VM its own LAN IP.
.PHONY: run-server-console
run-server-console:
	@[ -f $(SERVER_ISO) ] || $(MAKE) server-iso
	@CONSOLE_FWD=1 bash $(TOPDIR)/tools/test/boot-iso.sh run $(SERVER_ISO) server
test-server:
	@[ -f $(SERVER_ISO) ] || $(MAKE) server-iso
	@bash $(TOPDIR)/tools/test/boot-iso.sh test $(SERVER_ISO) server

# Stronger than test-server: proves the root autologin reaches an actual shell
# (test-server only waits for the "blueberry login:" prompt, which prints BEFORE
# login/PAM runs — so it cannot catch a PAM abort at login).
.PHONY: test-login
test-login:
	@[ -f $(SERVER_ISO) ] || $(MAKE) server-iso
	@sh $(TOPDIR)/tools/test/boot-login-check.sh $(SERVER_ISO) $(OBJDIR)/serial-login.log


# ── Directory creation ────────────────────────────────────────────────────────
$(OBJDIR_SRC) $(STAGEDIR) $(BOOTDIR) $(OBJDIR):
	@mkdir -p $@

# ── Repo: build-the-world + closure gate ──────────────────────────────────────
# Every name under packages/ that has a bpm.toml.
ALL_BPM_PKGS := $(notdir $(patsubst %/bpm.toml,%,$(wildcard $(TOPDIR)/packages/*/bpm.toml)))

# Assert the recipe tree is dependency-closed (every `depends` has a recipe or is
# host-provided). Catches "declared but never packaged" before it ships.
.PHONY: check-closure build-world repo-build audit-deps
check-closure:
	@python3 $(TOPDIR)/tools/pkg/check-closure.py

# Audit real ELF linkage of every built package against the self-hosted store and
# report any runtime dependency a recipe fails to declare. Needs the store
# (obj/bpm-out) populated — e.g. after `make repo-selfhost`.
#   ENGINE=podman|docker  BUILDER_IMAGE=...  STORE=<dir>
AUDIT_ENGINE ?= podman
AUDIT_IMAGE  ?= localhost/blueberry-builder:latest
AUDIT_STORE  ?= $(TOPDIR)/obj/bpm-out
audit-deps:
	@$(AUDIT_ENGINE) run --rm --security-opt seccomp=unconfined \
	    -v $(TOPDIR):/repo:ro,z -v $(AUDIT_STORE):/deps:ro,z \
	    $(AUDIT_IMAGE) python3 /repo/tools/pkg/audit-runtime-deps.py


# Build every .bpm package (idempotent: skips up-to-date ones). The bulk of the
# repo; run on a build box. ENGINE=podman|docker.
repo-build:
	@echo "[repo] building all $(words $(ALL_BPM_PKGS)) .bpm packages"
	@sh $(TOPDIR)/tools/pkg/build-bpm-pkg.sh $(OBJDIR)/bpm-out $(ALL_BPM_PKGS)

# Rebuild every package self-hosted (BASE=blueberry, zero Arch), in runtime-
# dependency order, so the whole mirror is produced by Blueberry's own toolchain.
# Seeds the store from the mirror first, restores from it on any failure, and is
# resumable (obj/.selfhost-done). FORCE=1 rebuilds everything.
.PHONY: repo-selfhost
repo-selfhost:
	@sh $(TOPDIR)/tools/pkg/repo-selfhost.sh

# "Build the world" gate: recipe closure must hold, then build every package
# from source (fails if any recipe doesn't build). Run on a build box / nightly
# CI — far too slow for per-push checks.
build-world: check-closure repo-build
	@echo "[build-world] all $(words $(ALL_BPM_PKGS)) packages built; recipe closure green"

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

# Fast, self-contained test of the bpm package manager: install / upgrade /
# config-preservation (.bpmnew) / remove, against a throwaway BPM_ROOT. No QEMU;
# runs in seconds. The cheap gate to run before the expensive e2e QEMU steps.
.PHONY: test-bpm
test-bpm:
	@sh $(TOPDIR)/tools/test/test-bpm.sh

# Functional smoke test of the server services: build each service .bpm, start
# the daemon and probe it (redis PING, HTTP GET, SQL SELECT). Proves the software
# runs, which a boot test can't. Optional: test-services SERVICES="redis nginx".
.PHONY: test-services
test-services:
	@sh $(TOPDIR)/tools/test/service-smoke.sh $(SERVICES)

# Own-keys UEFI Secure Boot end-to-end under QEMU+OVMF: build a signed disk
# image, enroll Blueberry keys with Secure Boot on, assert the signed image boots
# and an unsigned one is rejected. Skips cleanly if OVMF/qemu/virt-fw-vars or the
# rootfs/sbsigntools .bpm are unavailable.
.PHONY: test-secureboot
test-secureboot:
	@bash $(TOPDIR)/tools/test/secureboot-test.sh

# Unattended install of the server ISO in QEMU, then boot the installed disk
# and assert it reaches multi-user with a login prompt.
.PHONY: test-install
test-install:
	@[ -f $(INSTALLER_ISO) ] || $(MAKE) iso
	@bash $(TOPDIR)/tools/test/test-install.sh $(INSTALLER_ISO)

# Full end-to-end smoke test: build the world + both ISOs, boot the live Server
# ISO to multi-user, then do an unattended install and boot the installed disk.
# This is the gate CI runs (nightly / on demand) and the one command to run on a
# build box before a release. Any step failing fails the whole target.
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
	@echo "[test-e2e] PASS — bpm tests green, Server ISO boots, install boots with sshd+networkd up"
