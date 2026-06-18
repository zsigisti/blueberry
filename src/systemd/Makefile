# src/systemd/Makefile — install Blueberry's systemd integration layer.
#
# The systemd package already ships PID 1, the unit tree, journald, logind,
# networkd/resolved/timesyncd, udevd and getty@.service. This step layers
# Blueberry's policy on top: default network config, the OpenSSH units, the
# default target, resolv.conf wiring, and the "enable" symlinks that a running
# `systemctl enable` would otherwise create (we make them statically at build
# time because there is no running systemd during image assembly).
#
# Inputs:
#   STAGEDIR   install root (the rootfs)
#   SYSTEMD_UNITDIR  where the systemd package installed its units
#                    (default /usr/lib/systemd/system)

STAGEDIR        ?= $(error STAGEDIR must be set)
SYSTEMD_UNITDIR ?= /usr/lib/systemd/system
THISDIR         := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.PHONY: all
all:
	@echo "[systemd] installing Blueberry integration layer"
	@# ── networkd: DHCP on all wired interfaces ──────────────────────────
	@install -Dm644 $(THISDIR)/network/20-wired.network \
	    $(STAGEDIR)/etc/systemd/network/20-wired.network
	@# ── OpenSSH units + drop-in config ──────────────────────────────────
	@install -Dm644 $(THISDIR)/system/sshd.service \
	    $(STAGEDIR)/etc/systemd/system/sshd.service
	@install -Dm644 $(THISDIR)/system/sshd-keygen.service \
	    $(STAGEDIR)/etc/systemd/system/sshd-keygen.service
	@install -Dm644 $(THISDIR)/system/10-blueberry.conf \
	    $(STAGEDIR)/etc/ssh/sshd_config.d/10-blueberry.conf
	@# ── tmpfiles: sshd privsep dir ──────────────────────────────────────
	@install -Dm644 $(THISDIR)/tmpfiles/blueberry.conf \
	    $(STAGEDIR)/etc/tmpfiles.d/blueberry.conf
	@# ── mask units that don't apply to a Blueberry image ────────────────
	@# systemd-firstboot: interactive wizard (ConditionFirstBoot=yes) that
	@#   blocks boot on the console; the installer provisions hostname/root pw.
	@# ldconfig: the linker cache is prebuilt at image-assembly time and glibc
	@#   ships no ldconfig binary in the image.
	@# systemd-vconsole-setup: needs kbd (setfont/loadkeys), not shipped.
	@mkdir -p $(STAGEDIR)/etc/systemd/system
	@for u in systemd-firstboot.service ldconfig.service systemd-vconsole-setup.service; do \
	    ln -sf /dev/null $(STAGEDIR)/etc/systemd/system/$$u; \
	done
	@# Default locale so nothing prompts; empty machine-id → systemd-machine-id
	@# -setup commits a unique id on first boot (firstboot itself stays masked).
	@printf 'LANG=C.UTF-8\n' > $(STAGEDIR)/etc/locale.conf
	@: > $(STAGEDIR)/etc/machine-id
	@# ── default target = multi-user (no graphical) ──────────────────────
	@mkdir -p $(STAGEDIR)/etc/systemd/system
	@ln -sf $(SYSTEMD_UNITDIR)/multi-user.target \
	    $(STAGEDIR)/etc/systemd/system/default.target
	@# ── resolv.conf → resolved stub resolver ────────────────────────────
	@ln -sf /run/systemd/resolve/stub-resolv.conf $(STAGEDIR)/etc/resolv.conf
	@# ── enable units (statically create the [Install] symlinks) ─────────
	@mkdir -p $(STAGEDIR)/etc/systemd/system/multi-user.target.wants \
	          $(STAGEDIR)/etc/systemd/system/sockets.target.wants \
	          $(STAGEDIR)/etc/systemd/system/sysinit.target.wants \
	          $(STAGEDIR)/etc/systemd/system/getty.target.wants \
	          $(STAGEDIR)/etc/systemd/system/network-online.target.wants
	@# networkd (+ socket, wait-online, dbus alias)
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-networkd.service \
	    $(STAGEDIR)/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-networkd.socket \
	    $(STAGEDIR)/etc/systemd/system/sockets.target.wants/systemd-networkd.socket
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-networkd-wait-online.service \
	    $(STAGEDIR)/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-networkd.service \
	    $(STAGEDIR)/etc/systemd/system/dbus-org.freedesktop.network1.service
	@# resolved (+ dbus alias)
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-resolved.service \
	    $(STAGEDIR)/etc/systemd/system/multi-user.target.wants/systemd-resolved.service
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-resolved.service \
	    $(STAGEDIR)/etc/systemd/system/dbus-org.freedesktop.resolve1.service
	@# timesyncd (+ dbus alias)
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-timesyncd.service \
	    $(STAGEDIR)/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-timesyncd.service \
	    $(STAGEDIR)/etc/systemd/system/dbus-org.freedesktop.timesync1.service
	@# getty on tty1 + OpenSSH
	@ln -sf $(SYSTEMD_UNITDIR)/getty@.service \
	    $(STAGEDIR)/etc/systemd/system/getty.target.wants/getty@tty1.service
	@ln -sf $(STAGEDIR)/etc/systemd/system/sshd.service \
	    $(STAGEDIR)/etc/systemd/system/multi-user.target.wants/sshd.service 2>/dev/null; \
	    ln -sf /etc/systemd/system/sshd.service \
	    $(STAGEDIR)/etc/systemd/system/multi-user.target.wants/sshd.service
	@ln -sf /etc/systemd/system/sshd-keygen.service \
	    $(STAGEDIR)/etc/systemd/system/multi-user.target.wants/sshd-keygen.service
	@echo "[systemd] integration layer installed"
