# Our bits on top of the systemd package: network config, OpenSSH units,
# default target, resolv.conf, and the enable symlinks. There's no running
# systemd while we build the image, so `systemctl enable` is done by hand
# with ln.
# STAGEDIR is required; SYSTEMD_UNITDIR is where the package put its units.

STAGEDIR        ?= $(error STAGEDIR must be set)
SYSTEMD_UNITDIR ?= /usr/lib/systemd/system
THISDIR         := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.PHONY: all
all:
	@echo "[systemd] installing Blueberry integration layer"
	@install -Dm644 $(THISDIR)/network/20-wired.network \
	    $(STAGEDIR)/etc/systemd/network/20-wired.network
	@install -Dm644 $(THISDIR)/system/sshd.service \
	    $(STAGEDIR)/etc/systemd/system/sshd.service
	@install -Dm644 $(THISDIR)/system/sshd-keygen.service \
	    $(STAGEDIR)/etc/systemd/system/sshd-keygen.service
	@install -Dm644 $(THISDIR)/system/10-blueberry.conf \
	    $(STAGEDIR)/etc/ssh/sshd_config.d/10-blueberry.conf
	@install -Dm644 $(THISDIR)/tmpfiles/blueberry.conf \
	    $(STAGEDIR)/etc/tmpfiles.d/blueberry.conf
	@# masked:
	@#   firstboot - interactive wizard that hangs the console; the installer
	@#     already set hostname and root password
	@#   ldconfig - cache is prebuilt and the image has no ldconfig binary
	@#   vconsole-setup - wants kbd's setfont/loadkeys
	@mkdir -p $(STAGEDIR)/etc/systemd/system
	@for u in systemd-firstboot.service ldconfig.service systemd-vconsole-setup.service; do \
	    ln -sf /dev/null $(STAGEDIR)/etc/systemd/system/$$u; \
	done
	@# empty machine-id = systemd-machine-id-setup makes a fresh one on first boot
	@printf 'LANG=C.UTF-8\n' > $(STAGEDIR)/etc/locale.conf
	@: > $(STAGEDIR)/etc/machine-id
	@mkdir -p $(STAGEDIR)/etc/systemd/system
	@ln -sf $(SYSTEMD_UNITDIR)/multi-user.target \
	    $(STAGEDIR)/etc/systemd/system/default.target
	@ln -sf /run/systemd/resolve/stub-resolv.conf $(STAGEDIR)/etc/resolv.conf
	@# the [Install] symlinks systemctl enable would make
	@mkdir -p $(STAGEDIR)/etc/systemd/system/multi-user.target.wants \
	          $(STAGEDIR)/etc/systemd/system/sockets.target.wants \
	          $(STAGEDIR)/etc/systemd/system/sysinit.target.wants \
	          $(STAGEDIR)/etc/systemd/system/getty.target.wants \
	          $(STAGEDIR)/etc/systemd/system/network-online.target.wants
	@# logind needs the system bus
	@ln -sf $(SYSTEMD_UNITDIR)/dbus.socket \
	    $(STAGEDIR)/etc/systemd/system/sockets.target.wants/dbus.socket
	@ln -sf $(SYSTEMD_UNITDIR)/dbus.service \
	    $(STAGEDIR)/etc/systemd/system/multi-user.target.wants/dbus.service
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-networkd.service \
	    $(STAGEDIR)/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-networkd.socket \
	    $(STAGEDIR)/etc/systemd/system/sockets.target.wants/systemd-networkd.socket
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-networkd-wait-online.service \
	    $(STAGEDIR)/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-networkd.service \
	    $(STAGEDIR)/etc/systemd/system/dbus-org.freedesktop.network1.service
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-resolved.service \
	    $(STAGEDIR)/etc/systemd/system/multi-user.target.wants/systemd-resolved.service
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-resolved.service \
	    $(STAGEDIR)/etc/systemd/system/dbus-org.freedesktop.resolve1.service
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-timesyncd.service \
	    $(STAGEDIR)/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service
	@ln -sf $(SYSTEMD_UNITDIR)/systemd-timesyncd.service \
	    $(STAGEDIR)/etc/systemd/system/dbus-org.freedesktop.timesync1.service
	@ln -sf $(SYSTEMD_UNITDIR)/getty@.service \
	    $(STAGEDIR)/etc/systemd/system/getty.target.wants/getty@tty1.service
	@ln -sf $(STAGEDIR)/etc/systemd/system/sshd.service \
	    $(STAGEDIR)/etc/systemd/system/multi-user.target.wants/sshd.service 2>/dev/null; \
	    ln -sf /etc/systemd/system/sshd.service \
	    $(STAGEDIR)/etc/systemd/system/multi-user.target.wants/sshd.service
	@ln -sf /etc/systemd/system/sshd-keygen.service \
	    $(STAGEDIR)/etc/systemd/system/multi-user.target.wants/sshd-keygen.service
	@echo "[systemd] integration layer installed"
