# Builds $(BOOTDIR)/initramfs.cpio.zst: the live CLI + installer environment.
# Needs STAGEDIR (the staged rootfs), BOOTDIR and OBJDIR (scratch).

THISDIR    := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
INITRAMDIR := $(OBJDIR)/initramfs

.PHONY: all

all: $(BOOTDIR)/initramfs.cpio.zst

$(BOOTDIR)/initramfs.cpio.zst: $(THISDIR)/init $(THISDIR)/selftest \
                               $(THISDIR)/profile $(THISDIR)/udhcpc.script \
                               $(THISDIR)/shadow $(THISDIR)/Makefile \
                               $(THISDIR)/../bpm-rs/Cargo.toml \
                               $(wildcard $(THISDIR)/../bpm-rs/src/*.rs) \
                               $(THISDIR)/../installer/Cargo.toml \
                               $(wildcard $(THISDIR)/../installer/src/*.rs)
	@echo "[initramfs] assembling"
	@rm -rf $(INITRAMDIR)
	@mkdir -p $(INITRAMDIR)/bin $(INITRAMDIR)/sbin $(INITRAMDIR)/lib \
	          $(INITRAMDIR)/lib64 $(INITRAMDIR)/proc $(INITRAMDIR)/sys \
	          $(INITRAMDIR)/dev $(INITRAMDIR)/mnt/root $(INITRAMDIR)/run \
	          $(INITRAMDIR)/tmp

	@# A systemd rootfs has no busybox in it, so fall back to the one in the
	@# build dir. The initramfs has to work whatever got staged.
	@if [ -f $(STAGEDIR)/bin/busybox ]; then \
	    cp $(STAGEDIR)/bin/busybox $(INITRAMDIR)/bin/busybox; \
	elif bb=$$(ls -1 $(OBJDIR)/src/busybox-*/busybox 2>/dev/null | head -1) && [ -n "$$bb" ]; then \
	    echo "[initramfs] busybox from build dir: $$bb"; \
	    cp "$$bb" $(INITRAMDIR)/bin/busybox; \
	else \
	    echo "FATAL: no busybox in $(STAGEDIR)/bin or $(OBJDIR)/src/busybox-*/" >&2; exit 1; \
	fi

	@for app in sh ash mount umount switch_root mdev blkid sleep setsid \
	            modprobe insmod lsmod mkdir cp mv rm ln ls cat \
	            find grep sed awk echo printf head tail dmesg clear \
	            ip udhcpc wget ping halt poweroff reboot vi more \
	            uname ps free df hostname date cttyhack ntpd netstat \
	            getty login setsid clear reset \
	            tar chroot chmod chown mknod dd sync stat \
	            mkswap swapon swapoff fallocate partprobe \
	            passwd chpasswd adduser addgroup; do \
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

	@# (glibc gets bundled at the end, once every binary is in)

	@cp $(THISDIR)/init $(INITRAMDIR)/init
	@chmod 755 $(INITRAMDIR)/init

	@# self-test, run when the cmdline has bbtest
	@mkdir -p $(INITRAMDIR)/etc
	@cp $(THISDIR)/selftest $(INITRAMDIR)/etc/selftest
	@chmod 755 $(INITRAMDIR)/etc/selftest

	@cp $(THISDIR)/profile $(INITRAMDIR)/etc/profile

	@cp $(THISDIR)/udhcpc.script $(INITRAMDIR)/etc/udhcpc.script
	@chmod 755 $(INITRAMDIR)/etc/udhcpc.script

	@mkdir -p $(INITRAMDIR)/usr/bin $(INITRAMDIR)/etc/bpm
	@ARCH=$(ARCH) sh $(THISDIR)/../../tools/pkg/build-bpm.sh $(INITRAMDIR)/usr/bin/bpm
	@cp $(THISDIR)/../../etc/bpm/repos.conf $(INITRAMDIR)/etc/bpm/repos.conf
	@cp $(THISDIR)/../../etc/bpm/provided  $(INITRAMDIR)/etc/bpm/provided

	@mkdir -p $(INITRAMDIR)/etc/ssl/certs
	@cp -L /etc/ssl/certs/ca-certificates.crt $(INITRAMDIR)/etc/ssl/certs/ca-certificates.crt 2>/dev/null \
	    || echo "WARNING: host CA bundle not found; HTTPS repos won't verify"

	@# bpm has libzstd built in; this is just for people at the shell
	@cp $$(command -v zstd) $(INITRAMDIR)/usr/bin/zstd

	@# Everything the installer shells out to, so it works offline:
	@#   gptfdisk/dosfstools/e2fsprogs/xfsprogs/btrfs-progs  partition + mkfs
	@#   cryptsetup (+ device-mapper json-c openssl popt)    LUKS, at boot and install
	@#   lvm2 (+ libaio readline)                            LVM, and `vgchange -ay` at boot
	@#   grub                                                grub-install + both module trees
	@#   bash + ncurses                                      live shell = installed login shell
	@# liburcu/libinih/lzo are xfsprogs/btrfs-progs runtime deps.
	@echo "[initramfs] bundling installer + disk + crypto + grub + bash"
	@sh $(THISDIR)/../../tools/pkg/build-bpm-pkg.sh $(OBJDIR)/instpkgs \
	    popt e2fsprogs dosfstools gptfdisk json-c device-mapper openssl zlib cryptsetup \
	    grub kbd ncurses bash xfsprogs btrfs-progs liburcu libinih lzo lvm2 libaio readline
	@for p in popt e2fsprogs dosfstools gptfdisk json-c device-mapper openssl zlib cryptsetup \
	          grub kbd ncurses bash xfsprogs btrfs-progs liburcu libinih lzo lvm2 libaio readline; do \
	    f=$$(ls -t $(OBJDIR)/instpkgs/$$p-[0-9]*.bpm | head -1); \
	    zstd -dcq "$$f" | tar -x -C $(INITRAMDIR) --exclude .BPM 2>/dev/null; \
	done
	@# glibc from the mirror, into a side sysroot. There's no staged glibc yet
	@# at this point, and the host's can be older (Ubuntu 2.39 vs our 2.43) which
	@# panics at boot. Don't extract it straight into the initramfs: the full
	@# package is ~25 MB extra and low-RAM machines then can't unpack it.
	@# bundle-glibc copies just the libs that are needed.
	@echo "[initramfs] fetching glibc from mirror (into sysroot)"
	@rm -rf $(OBJDIR)/glibc-sysroot
	@sh $(THISDIR)/../../tools/pkg/fetch-bpm.sh glibc $(OBJDIR)/glibc-sysroot $(OBJDIR)/bpm-cache
	@# /bin/bash is what passwd says
	@ln -sf /usr/bin/bash $(INITRAMDIR)/bin/bash
	@# getty -l doesn't start a login shell, so bash skips /etc/profile and you
	@# get a bare "bash-5.2#". --login fixes the prompt and HOME.
	@printf '#!/bin/sh\nexec /usr/bin/bash --login\n' > $(INITRAMDIR)/usr/bin/bblogin
	@chmod 755 $(INITRAMDIR)/usr/bin/bblogin
	@# trim dev cruft
	@rm -rf $(INITRAMDIR)/usr/include $(INITRAMDIR)/usr/share/man \
	        $(INITRAMDIR)/usr/share/info $(INITRAMDIR)/usr/share/doc \
	        $(INITRAMDIR)/usr/share/locale $(INITRAMDIR)/usr/lib/pkgconfig
	@# grub themes/fonts and tools the installer never calls. It does need
	@# grub-install/-bios-setup/-probe/-mkimage/-editenv and the module trees.
	@rm -rf $(INITRAMDIR)/usr/share/grub
	@for g in mkfont mkrescue mkstandalone shell script-check syslinux2cfg \
	          mknetdir menulst2cfg fstest mount sparc64-setup ofpathname; do \
	    rm -f $(INITRAMDIR)/usr/bin/grub-$$g $(INITRAMDIR)/usr/sbin/grub-$$g; \
	done
	@find $(INITRAMDIR)/usr/lib -name '*.a' -delete 2>/dev/null || true
	@sh $(THISDIR)/../../tools/build/build-installer.sh $(INITRAMDIR)/usr/bin/blueberry-install
	@chmod 755 $(INITRAMDIR)/usr/bin/blueberry-install
	@# because people keep typing these
	@ln -sf blueberry-install $(INITRAMDIR)/usr/bin/bb-install
	@ln -sf blueberry-install $(INITRAMDIR)/usr/bin/bb-installer

	@# just enough for the prompt to say root@blueberry
	@printf 'root:x:0:0:root:/root:/bin/bash\n' > $(INITRAMDIR)/etc/passwd
	@printf 'root:x:0:\n'                     > $(INITRAMDIR)/etc/group
	@printf 'blueberry\n'                     > $(INITRAMDIR)/etc/hostname

	@# root password is "blueberry". It's a live CD.
	@cp $(THISDIR)/shadow $(INITRAMDIR)/etc/shadow
	@chmod 600 $(INITRAMDIR)/etc/shadow

	@mkdir -p $(INITRAMDIR)/usr/sbin $(INITRAMDIR)/usr/bin $(INITRAMDIR)/root/.ssh
	@# dropbear is only for the live environment (installs get OpenSSH), so a
	@# systemd stage won't have it - take it from the build dir then
	@db=$(STAGEDIR)/usr/sbin/dropbearmulti; \
	 [ -f "$$db" ] || db=$$(ls -1 $(OBJDIR)/src/dropbear-*/dropbearmulti 2>/dev/null | head -1); \
	 if [ -n "$$db" ] && [ -f "$$db" ]; then \
	    cp "$$db" $(INITRAMDIR)/usr/sbin/dropbearmulti; \
	    ln -sf dropbearmulti $(INITRAMDIR)/usr/sbin/dropbear; \
	    ln -sf dropbearmulti $(INITRAMDIR)/usr/sbin/dropbearkey; \
	    ln -sf ../sbin/dropbearmulti $(INITRAMDIR)/usr/bin/dbclient; \
	    ln -sf ../sbin/dropbearmulti $(INITRAMDIR)/usr/bin/scp; \
	    mkdir -p $(INITRAMDIR)/etc/dropbear; \
	 else \
	    echo "WARNING: dropbear not built, run 'make dropbear' (no SSH in image)"; \
	 fi

	@mknod -m 600 $(INITRAMDIR)/dev/console  c 5 1 2>/dev/null || true
	@mknod -m 666 $(INITRAMDIR)/dev/null     c 1 3 2>/dev/null || true
	@mknod -m 666 $(INITRAMDIR)/dev/zero     c 1 5 2>/dev/null || true
	@mknod -m 444 $(INITRAMDIR)/dev/urandom  c 1 9 2>/dev/null || true
	@mknod -m 444 $(INITRAMDIR)/dev/random   c 1 8 2>/dev/null || true
	@mknod -m 666 $(INITRAMDIR)/dev/tty      c 5 0 2>/dev/null || true

	@# ld.so + whatever these link, plus the compat libs and NSS modules so
	@# random prebuilt glibc binaries work too
	@echo "[initramfs] bundling glibc runtime (from mirror glibc, not the host)"
	@GLIBC_SYSROOT=$(OBJDIR)/glibc-sysroot bash $(THISDIR)/../../tools/image/bundle-glibc.sh $(INITRAMDIR) \
	    $(INITRAMDIR)/bin/busybox \
	    $(INITRAMDIR)/usr/sbin/dropbearmulti \
	    $(INITRAMDIR)/usr/bin/zstd \
	    $(INITRAMDIR)/usr/bin/bpm \
	    $(INITRAMDIR)/usr/bin/blueberry-install \
	    $(INITRAMDIR)/usr/sbin/grub-install \
	    $(INITRAMDIR)/usr/sbin/grub-bios-setup \
	    $(INITRAMDIR)/usr/bin/grub-probe \
	    $(INITRAMDIR)/usr/bin/grub-mkimage \
	    $(INITRAMDIR)/usr/bin/loadkeys \
	    $(INITRAMDIR)/usr/bin/sgdisk \
	    $(INITRAMDIR)/usr/sbin/mkfs.ext4 \
	    $(INITRAMDIR)/usr/sbin/mkfs.fat \
	    $(INITRAMDIR)/usr/bin/mkfs.xfs \
	    $(INITRAMDIR)/usr/bin/mkfs.btrfs \
	    $(INITRAMDIR)/usr/bin/lvm \
	    $(INITRAMDIR)/sbin/cryptsetup \
	    $(INITRAMDIR)/sbin/blkid

	@# -R 0:0 because we build as uid 1000; without it everything (setuid
	@# bits included) ends up owned by the build user
	@echo "[initramfs] packing"
	@cd $(INITRAMDIR) && \
	    find . | sort | \
	    cpio --create --format=newc -R 0:0 --quiet 2>/dev/null | \
	    zstd -19 -q > $(BOOTDIR)/initramfs.cpio.zst
	@echo "[initramfs] written to $(BOOTDIR)/initramfs.cpio.zst"
	@ls -lh $(BOOTDIR)/initramfs.cpio.zst
