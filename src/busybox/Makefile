# busybox, dynamic against the host glibc. Called from the top GNUmakefile
# with BUSYBOX_SRC, CC, STAGEDIR and ARCH set.

THISDIR      := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
# config.full is a complete .config (1.36.1 defconfig + our changes), so no
# kconfig run is needed.
BB_CONFIG    := $(THISDIR)/config.full

CC ?= gcc

.PHONY: all

all: $(STAGEDIR)/bin/busybox

$(STAGEDIR)/bin/busybox: $(BUSYBOX_SRC)/Makefile $(BB_CONFIG)
	@echo "[busybox] installing config"
	@cp $(BB_CONFIG) $(BUSYBOX_SRC)/.config
	@echo "[busybox] building (dynamic, glibc)"
	@$(MAKE) -C $(BUSYBOX_SRC) \
	    CC="$(CC)" \
	    EXTRA_CFLAGS="-Os -pipe" \
	    -j$(JOBS)
	@echo "[busybox] installing applets"
	@$(MAKE) -C $(BUSYBOX_SRC) \
	    CC="$(CC)" \
	    CONFIG_PREFIX=$(STAGEDIR) \
	    install
	@echo "[busybox] done"
