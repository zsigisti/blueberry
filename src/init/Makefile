# src/init/Makefile — build and install runit
#
# Inputs:
#   RUNIT_SRC   path to admin/runit-X.Y source
#   CC          host C compiler (glibc)
#   STAGEDIR    install root

CC ?= gcc

.PHONY: all install_services

all: $(RUNIT_SRC)/command/runit
	@echo "[runit] installing binaries"
	@install -Dm755 $(RUNIT_SRC)/command/runit      $(STAGEDIR)/sbin/runit
	@install -Dm755 $(RUNIT_SRC)/command/runit-init $(STAGEDIR)/sbin/runit-init
	@install -Dm755 $(RUNIT_SRC)/command/runsvdir   $(STAGEDIR)/sbin/runsvdir
	@install -Dm755 $(RUNIT_SRC)/command/runsv      $(STAGEDIR)/sbin/runsv
	@install -Dm755 $(RUNIT_SRC)/command/sv         $(STAGEDIR)/sbin/sv
	@install -Dm755 $(RUNIT_SRC)/command/svlogd     $(STAGEDIR)/sbin/svlogd
	@install -Dm755 $(RUNIT_SRC)/command/chpst      $(STAGEDIR)/sbin/chpst
	@install -Dm755 $(RUNIT_SRC)/command/utmpset    $(STAGEDIR)/sbin/utmpset
	@ln -sf runit-init $(STAGEDIR)/sbin/init 2>/dev/null || true
	@# service enable/disable helpers (manage /etc/sv/enabled + /var/service)
	@install -Dm755 $(dir $(abspath $(lastword $(MAKEFILE_LIST))))/sv-enable  $(STAGEDIR)/usr/bin/sv-enable
	@install -Dm755 $(dir $(abspath $(lastword $(MAKEFILE_LIST))))/sv-disable $(STAGEDIR)/usr/bin/sv-disable
	@$(MAKE) install_services

$(RUNIT_SRC)/command/runit:
	@echo "[runit] building (dynamic, glibc)"
	@printf '%s -std=gnu11 -Wno-incompatible-pointer-types -Wno-implicit-function-declaration -Wno-implicit-int\n' "$(CC)" > $(RUNIT_SRC)/src/conf-cc
	@printf '%s\n' "$(CC)" > $(RUNIT_SRC)/src/conf-ld
	@# runit's src/Makefile hard-codes `-static` on the runit/runit-init link
	@# lines; strip it so they link dynamically against glibc.
	@sed -i 's/ -static//g' $(RUNIT_SRC)/src/Makefile
	@cd $(RUNIT_SRC) && sh package/compile

install_services:
	@THISDIR=$(dir $(abspath $(lastword $(MAKEFILE_LIST)))); \
	install -Dm755 $$THISDIR/1 $(STAGEDIR)/etc/runit/1; \
	install -Dm755 $$THISDIR/2 $(STAGEDIR)/etc/runit/2; \
	install -Dm755 $$THISDIR/3 $(STAGEDIR)/etc/runit/3; \
	for svc in $$THISDIR/sv/*/; do \
	    name=$$(basename $$svc); \
	    install -dm755 $(STAGEDIR)/etc/sv/$$name; \
	    install -Dm755 $$svc/run $(STAGEDIR)/etc/sv/$$name/run; \
	    [ -f $$svc/finish ] && \
	        install -Dm755 $$svc/finish $(STAGEDIR)/etc/sv/$$name/finish || true; \
	done; \
	mkdir -p $(STAGEDIR)/var/service; \
	mkdir -p $(STAGEDIR)/etc/sv/enabled; \
	ln -sf /etc/sv/getty-tty1 $(STAGEDIR)/etc/sv/enabled/getty-tty1 2>/dev/null || true; \
	ln -sf /etc/sv/syslogd    $(STAGEDIR)/etc/sv/enabled/syslogd    2>/dev/null || true; \
	ln -sf /etc/sv/ntpd       $(STAGEDIR)/etc/sv/enabled/ntpd       2>/dev/null || true; \
	ln -sf /etc/sv/sshd       $(STAGEDIR)/etc/sv/enabled/sshd       2>/dev/null || true
