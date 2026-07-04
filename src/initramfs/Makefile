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

	@# Copy busybox (static binary — provides everything we need). The initramfs
	@# must not depend on the rootfs being in CLI state: the Desktop edition's
	@# rootfs is systemd-based and carries no busybox. Prefer the rootfs copy,
	@# but fall back to the freshly-built binary in OBJDIR so the initramfs is
	@# always self-contained regardless of which edition staged the rootfs.
	@if [ -f $(STAGEDIR)/bin/busybox ]; then \
	    cp $(STAGEDIR)/bin/busybox $(INITRAMDIR)/bin/busybox; \
	elif bb=$$(ls -1 $(OBJDIR)/src/busybox-*/busybox 2>/dev/null | head -1) && [ -n "$$bb" ]; then \
	    echo "[initramfs] busybox from build dir: $$bb"; \
	    cp "$$bb" $(INITRAMDIR)/bin/busybox; \
	else \
	    echo "FATAL: no busybox in $(STAGEDIR)/bin or $(OBJDIR)/src/busybox-*/" >&2; exit 1; \
	fi

	@# Create busybox applet symlinks needed in initramfs
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

	@# bpm package manager (Rust, src/bpm-rs) + default repo config
	@mkdir -p $(INITRAMDIR)/usr/bin $(INITRAMDIR)/etc/bpm
	@ARCH=$(ARCH) sh $(THISDIR)/../../tools/build-bpm.sh $(INITRAMDIR)/usr/bin/bpm
	@cp $(THISDIR)/../../etc/bpm/repos.conf $(INITRAMDIR)/etc/bpm/repos.conf
	@cp $(THISDIR)/../../etc/bpm/provided  $(INITRAMDIR)/etc/bpm/provided

	@# CA trust store so bpm and curl can verify HTTPS (rustls TLS in bpm).
	@mkdir -p $(INITRAMDIR)/etc/ssl/certs
	@cp -L /etc/ssl/certs/ca-certificates.crt $(INITRAMDIR)/etc/ssl/certs/ca-certificates.crt 2>/dev/null \
	    || echo "WARNING: host CA bundle not found; HTTPS repos won't verify"

	@# zstd binary — handy on the live system (the Rust bpm bundles libzstd
	@# statically, so it doesn't need the shared lib). Picked up by bundle-glibc.
	@cp $$(command -v zstd) $(INITRAMDIR)/usr/bin/zstd

	@# blueberry-install + its disk tools (sgdisk, mkfs.fat, mkfs.ext4) plus
	@# cryptsetup + its libs (device-mapper, json-c, openssl, popt) for LUKS
	@# unlock at boot and luksFormat at install. Bundled so it works offline.
	@# bash + ncurses (libtinfo) so the live shell is bash, not busybox sh —
	@# matching the installed system's default login shell.
	@# Native .bpm toolchain (build-pkgs.sh / .pkg.tar.zst was retired). grub gives
	@# the Rust installer grub-install + both module trees (i386-pc/x86_64-efi).
	@echo "[initramfs] bundling installer + disk + crypto + grub + bash"
	@# xfsprogs/btrfs-progs (+ their lib deps liburcu/libinih/lzo) give the
	@# installer mkfs.xfs / mkfs.btrfs so root can be XFS or Btrfs, not just ext4.
	@# lvm2 (+ libaio/readline) gives the installer pvcreate/vgcreate/lvcreate and
	@# the boot-time `vgchange -ay` for LVM (and LVM-on-LUKS) roots.
	@sh $(THISDIR)/../../tools/build-bpm-pkg.sh $(OBJDIR)/instpkgs \
	    popt e2fsprogs dosfstools gptfdisk json-c device-mapper openssl zlib cryptsetup \
	    grub kbd ncurses bash xfsprogs btrfs-progs liburcu libinih lzo lvm2 libaio readline
	@for p in popt e2fsprogs dosfstools gptfdisk json-c device-mapper openssl zlib cryptsetup \
	          grub kbd ncurses bash xfsprogs btrfs-progs liburcu libinih lzo lvm2 libaio readline; do \
	    f=$$(ls -t $(OBJDIR)/instpkgs/$$p-[0-9]*.bpm | head -1); \
	    zstd -dcq "$$f" | tar -x -C $(INITRAMDIR) --exclude .BPM 2>/dev/null; \
	done
	@# glibc: pull the pinned, container-built package straight from the MIRROR and
	@# extract it here. The initramfs is assembled before the rootfs is populated,
	@# so there is no staged glibc to bundle yet — fetching it from the mirror is
	@# what makes the initramfs runtime independent of the build host's glibc
	@# (an older host libc, e.g. Ubuntu 2.39 vs the container's 2.43, would panic
	@# at boot). bundle-glibc below then sources the runtime from here.
	@echo "[initramfs] fetching glibc from mirror"
	@sh $(THISDIR)/../../tools/fetch-bpm.sh glibc $(INITRAMDIR) $(OBJDIR)/bpm-cache
	@# bash lands in /usr/bin; make /bin/bash resolve too (login shell path).
	@ln -sf /usr/bin/bash $(INITRAMDIR)/bin/bash
	@# Login wrapper: getty -l runs its program non-login, so bash would skip
	@# /etc/profile and show the bare "bash-5.2#" prompt. Exec bash --login so it
	@# reads /etc/profile (PS1 = \u@\h:\w\$$, sets HOME) -> root@blueberry:~#.
	@printf '#!/bin/sh\nexec /usr/bin/bash --login\n' > $(INITRAMDIR)/usr/bin/bblogin
	@chmod 755 $(INITRAMDIR)/usr/bin/bblogin
	@# trim dev cruft from the bundled tools (keep binaries + shared libs)
	@rm -rf $(INITRAMDIR)/usr/include $(INITRAMDIR)/usr/share/man \
	        $(INITRAMDIR)/usr/share/info $(INITRAMDIR)/usr/share/doc \
	        $(INITRAMDIR)/usr/share/locale $(INITRAMDIR)/usr/lib/pkgconfig
	@# grub: drop themes/fonts + image-authoring tools the installer never calls
	@# (keep grub-install/-bios-setup/-probe/-mkimage/-editenv + both module trees).
	@rm -rf $(INITRAMDIR)/usr/share/grub
	@for g in mkfont mkrescue mkstandalone shell script-check syslinux2cfg \
	          mknetdir menulst2cfg fstest mount sparc64-setup ofpathname; do \
	    rm -f $(INITRAMDIR)/usr/bin/grub-$$g $(INITRAMDIR)/usr/sbin/grub-$$g; \
	done
	@find $(INITRAMDIR)/usr/lib -name '*.a' -delete 2>/dev/null || true
	@# blueberry-install is now the Rust guided CLI installer (src/installer/,
	@# built like bpm via cargo). It links glibc+libgcc_s, picked up by bundle-glibc.
	@sh $(THISDIR)/../../tools/build-installer.sh $(INITRAMDIR)/usr/bin/blueberry-install
	@chmod 755 $(INITRAMDIR)/usr/bin/blueberry-install
	@# short aliases — people reach for `bb-install` / `bb-installer` at the shell
	@ln -sf blueberry-install $(INITRAMDIR)/usr/bin/bb-install
	@ln -sf blueberry-install $(INITRAMDIR)/usr/bin/bb-installer

	@# Minimal account + hostname so \u resolves and the prompt reads root@blueberry
	@printf 'root:x:0:0:root:/root:/bin/bash\n' > $(INITRAMDIR)/etc/passwd
	@printf 'root:x:0:\n'                     > $(INITRAMDIR)/etc/group
	@printf 'blueberry\n'                     > $(INITRAMDIR)/etc/hostname

	@# Default root credentials for SSH (password: blueberry — change in production)
	@cp $(THISDIR)/shadow $(INITRAMDIR)/etc/shadow
	@chmod 600 $(INITRAMDIR)/etc/shadow

	@# Dropbear SSH server + client (single static multi-call binary)
	@mkdir -p $(INITRAMDIR)/usr/sbin $(INITRAMDIR)/usr/bin $(INITRAMDIR)/root/.ssh
	@# The installed system uses OpenSSH; Dropbear is the initramfs SSH server
	@# only (small static multi-call binary for the live/installer environment).
	@# The systemd rootfs doesn't stage it, so fall back to the freshly-built
	@# binary in OBJDIR so the initramfs always has SSH.
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
	@echo "[initramfs] bundling glibc runtime (from mirror glibc, not the host)"
	@GLIBC_SYSROOT=$(INITRAMDIR) bash $(THISDIR)/../../tools/bundle-glibc.sh $(INITRAMDIR) \
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

	@# Pack as CPIO
	@echo "[initramfs] packing"
	@cd $(INITRAMDIR) && \
	    find . | sort | \
	    cpio --create --format=newc --quiet 2>/dev/null | \
	    zstd -19 -q > $(BOOTDIR)/initramfs.cpio.zst
	@echo "[initramfs] written to $(BOOTDIR)/initramfs.cpio.zst"
	@ls -lh $(BOOTDIR)/initramfs.cpio.zst
