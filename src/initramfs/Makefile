# src/initramfs/Makefile — build the initramfs CPIO image
#
# Produces $(BOOTDIR)/initramfs.cpio.zst
#
# Inputs:
#   STAGEDIR   the assembled OS rootfs (provides busybox + runit)
#   BOOTDIR    where to write initramfs.cpio.zst
#   OBJDIR     scratch space

THISDIR    := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
INITRAMDIR := $(OBJDIR)/initramfs

.PHONY: all

all: $(BOOTDIR)/initramfs.cpio.zst

$(BOOTDIR)/initramfs.cpio.zst: $(THISDIR)/init $(THISDIR)/selftest \
                               $(THISDIR)/profile $(THISDIR)/udhcpc.script \
                               $(THISDIR)/shadow $(THISDIR)/Makefile \
                               $(wildcard $(THISDIR)/../bpm/*.c $(THISDIR)/../bpm/*.h) \
                               $(THISDIR)/../bpm/Makefile \
                               $(THISDIR)/../installer/blueberry-install.c \
                               $(THISDIR)/../installer/Makefile
	@echo "[initramfs] assembling"
	@rm -rf $(INITRAMDIR)
	@mkdir -p $(INITRAMDIR)/bin $(INITRAMDIR)/sbin $(INITRAMDIR)/lib \
	          $(INITRAMDIR)/lib64 $(INITRAMDIR)/proc $(INITRAMDIR)/sys \
	          $(INITRAMDIR)/dev $(INITRAMDIR)/mnt/root $(INITRAMDIR)/run \
	          $(INITRAMDIR)/tmp

	@# Copy busybox (static binary — provides everything we need)
	@if [ -f $(STAGEDIR)/bin/busybox ]; then \
	    cp $(STAGEDIR)/bin/busybox $(INITRAMDIR)/bin/busybox; \
	else \
	    echo "WARNING: busybox not found in $(STAGEDIR)/bin/busybox"; \
	fi

	@# Create busybox applet symlinks needed in initramfs
	@for app in sh ash mount umount switch_root mdev blkid sleep setsid \
	            modprobe insmod lsmod mkdir cp mv rm ln ls cat \
	            find grep sed awk echo printf head tail dmesg clear \
	            ip udhcpc wget ping halt poweroff reboot vi more \
	            uname ps free df hostname date cttyhack ntpd netstat \
	            getty login setsid clear reset; do \
	    ln -sf /bin/busybox $(INITRAMDIR)/bin/$$app 2>/dev/null || true; \
	done
	@for app in cryptsetup vgchange; do \
	    [ -f $(STAGEDIR)/sbin/$$app ] && \
	        cp $(STAGEDIR)/sbin/$$app $(INITRAMDIR)/sbin/ 2>/dev/null || true; \
	done
	@mkdir -p $(INITRAMDIR)/sbin
	@for app in blkid; do \
	    [ -f $(STAGEDIR)/sbin/$$app ] && \
	        cp $(STAGEDIR)/sbin/$$app $(INITRAMDIR)/sbin/ 2>/dev/null || true; \
	done

	@# (glibc runtime is bundled near the end, once all binaries are in place)

	@# Install /init (live CLI entry point)
	@cp $(THISDIR)/init $(INITRAMDIR)/init
	@chmod 755 $(INITRAMDIR)/init

	@# Install the in-guest self-test (run via kernel cmdline: bbtest)
	@mkdir -p $(INITRAMDIR)/etc
	@cp $(THISDIR)/selftest $(INITRAMDIR)/etc/selftest
	@chmod 755 $(INITRAMDIR)/etc/selftest

	@# Install /etc/profile so the interactive shell has a nice prompt
	@cp $(THISDIR)/profile $(INITRAMDIR)/etc/profile

	@# DHCP lease handler for udhcpc
	@cp $(THISDIR)/udhcpc.script $(INITRAMDIR)/etc/udhcpc.script
	@chmod 755 $(INITRAMDIR)/etc/udhcpc.script

	@# bpm package manager (compiled C binary) + default repo config
	@mkdir -p $(INITRAMDIR)/usr/bin $(INITRAMDIR)/etc/bpm
	@$(MAKE) --no-print-directory -C $(THISDIR)/../bpm \
	    CC="$(CC)" CFLAGS="$(CFLAGS)" \
	    OBJDIR=$(OBJDIR)/bpm BPM_OUT=$(OBJDIR)/bpm/bpm
	@cp $(OBJDIR)/bpm/bpm $(INITRAMDIR)/usr/bin/bpm
	@chmod 755 $(INITRAMDIR)/usr/bin/bpm
	@cp $(THISDIR)/../../etc/bpm/repos.conf $(INITRAMDIR)/etc/bpm/repos.conf
	@cp $(THISDIR)/../../etc/bpm/provided  $(INITRAMDIR)/etc/bpm/provided

	@# CA trust store so bpm can verify HTTPS repos (TLS via BearSSL).
	@mkdir -p $(INITRAMDIR)/etc/ssl/certs
	@cp -L /etc/ssl/certs/ca-certificates.crt $(INITRAMDIR)/etc/ssl/certs/ca-certificates.crt 2>/dev/null \
	    || echo "WARNING: host CA bundle not found; HTTPS repos won't verify"

	@# zstd binary — handy on the live system; its libs (libzstd/liblz4/liblzma/
	@# libz) also satisfy the C bpm, which links libzstd. Picked up by bundle-glibc.
	@cp $$(command -v zstd) $(INITRAMDIR)/usr/bin/zstd

	@# blueberry-install + its disk tools (sgdisk, mkfs.fat, mkfs.ext4) plus
	@# cryptsetup + its libs (device-mapper, json-c, openssl, popt) for LUKS
	@# unlock at boot and luksFormat at install. Bundled so it works offline.
	@echo "[initramfs] bundling installer + disk + crypto tools"
	@sh $(THISDIR)/../../tools/build-pkgs.sh $(OBJDIR)/instpkgs \
	    popt e2fsprogs dosfstools gptfdisk json-c device-mapper openssl cryptsetup
	@for p in popt e2fsprogs dosfstools gptfdisk json-c device-mapper openssl cryptsetup; do \
	    zstd -dcq $(OBJDIR)/instpkgs/$$p-*.pkg.tar.zst \
	        | tar -x -C $(INITRAMDIR) --exclude .PKGINFO --exclude .MTREE \
	          --exclude .BUILDINFO --exclude .INSTALL 2>/dev/null; \
	done
	@# trim dev cruft from the bundled tools (keep binaries + shared libs)
	@rm -rf $(INITRAMDIR)/usr/include $(INITRAMDIR)/usr/share/man \
	        $(INITRAMDIR)/usr/share/info $(INITRAMDIR)/usr/lib/pkgconfig
	@find $(INITRAMDIR)/usr/lib -name '*.a' -delete 2>/dev/null || true
	@$(MAKE) --no-print-directory -C $(THISDIR)/../installer \
	    CC="$(CC)" CFLAGS="$(CFLAGS)" \
	    OBJDIR=$(OBJDIR)/installer OUT=$(OBJDIR)/installer/blueberry-install
	@cp $(OBJDIR)/installer/blueberry-install $(INITRAMDIR)/usr/bin/blueberry-install
	@chmod 755 $(INITRAMDIR)/usr/bin/blueberry-install

	@# Minimal account + hostname so \u resolves and the prompt reads root@blueberry
	@printf 'root:x:0:0:root:/root:/bin/sh\n' > $(INITRAMDIR)/etc/passwd
	@printf 'root:x:0:\n'                     > $(INITRAMDIR)/etc/group
	@printf 'blueberry\n'                     > $(INITRAMDIR)/etc/hostname

	@# Default root credentials for SSH (password: blueberry — change in production)
	@cp $(THISDIR)/shadow $(INITRAMDIR)/etc/shadow
	@chmod 600 $(INITRAMDIR)/etc/shadow

	@# Dropbear SSH server + client (single static multi-call binary)
	@mkdir -p $(INITRAMDIR)/usr/sbin $(INITRAMDIR)/usr/bin $(INITRAMDIR)/root/.ssh
	@if [ -f $(STAGEDIR)/usr/sbin/dropbearmulti ]; then \
	    cp $(STAGEDIR)/usr/sbin/dropbearmulti $(INITRAMDIR)/usr/sbin/dropbearmulti; \
	    ln -sf dropbearmulti $(INITRAMDIR)/usr/sbin/dropbear; \
	    ln -sf dropbearmulti $(INITRAMDIR)/usr/sbin/dropbearkey; \
	    ln -sf ../sbin/dropbearmulti $(INITRAMDIR)/usr/bin/dbclient; \
	    ln -sf ../sbin/dropbearmulti $(INITRAMDIR)/usr/bin/scp; \
	    mkdir -p $(INITRAMDIR)/etc/dropbear; \
	else \
	    echo "WARNING: dropbear not built — run 'make dropbear' (no SSH in image)"; \
	fi

	@# Create device nodes
	@mknod -m 600 $(INITRAMDIR)/dev/console  c 5 1 2>/dev/null || true
	@mknod -m 666 $(INITRAMDIR)/dev/null     c 1 3 2>/dev/null || true
	@mknod -m 666 $(INITRAMDIR)/dev/zero     c 1 5 2>/dev/null || true
	@mknod -m 444 $(INITRAMDIR)/dev/urandom  c 1 9 2>/dev/null || true
	@mknod -m 444 $(INITRAMDIR)/dev/random   c 1 8 2>/dev/null || true
	@mknod -m 666 $(INITRAMDIR)/dev/tty      c 5 0 2>/dev/null || true

	@# Bundle the glibc runtime: the ELF interpreter + the shared libs every
	@# binary here needs, plus the compat set + NSS modules, so the dynamic
	@# busybox/dropbear run AND external prebuilt glibc software works.
	@echo "[initramfs] bundling glibc runtime"
	@bash $(THISDIR)/../../tools/bundle-glibc.sh $(INITRAMDIR) \
	    $(INITRAMDIR)/bin/busybox \
	    $(INITRAMDIR)/usr/sbin/dropbearmulti \
	    $(INITRAMDIR)/usr/bin/zstd \
	    $(INITRAMDIR)/usr/bin/bpm

	@# Pack as CPIO
	@echo "[initramfs] packing"
	@cd $(INITRAMDIR) && \
	    find . | sort | \
	    cpio --create --format=newc --quiet 2>/dev/null | \
	    zstd -19 -q > $(BOOTDIR)/initramfs.cpio.zst
	@echo "[initramfs] written to $(BOOTDIR)/initramfs.cpio.zst"
	@ls -lh $(BOOTDIR)/initramfs.cpio.zst
