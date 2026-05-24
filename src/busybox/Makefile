# src/busybox/Makefile — build busybox linked against musl
#
# Inputs:
#   BUSYBOX_SRC  path to extracted busybox source
#   SYSROOT      musl sysroot (for CC wrapper)
#   STAGEDIR     install root (the OS rootfs being assembled)
#   ARCH

THISDIR  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
BB_CONFIG := $(THISDIR)/config

# musl-gcc wrapper puts -I/-L for musl automatically
MUSL_GCC := $(SYSROOT)/bin/musl-gcc

.PHONY: all

all: $(STAGEDIR)/bin/busybox

$(STAGEDIR)/bin/busybox: $(BUSYBOX_SRC)/Makefile
	@echo "[busybox] installing config"
	@cp $(BB_CONFIG) $(BUSYBOX_SRC)/.config
	@# Inject musl-gcc as the compiler
	@sed -i "s|^CONFIG_CROSS_COMPILER_PREFIX=.*|CONFIG_CROSS_COMPILER_PREFIX=\"\"|" \
	    $(BUSYBOX_SRC)/.config
	@# Accept defaults for any new/unknown symbols — avoids interactive prompts in CI
	@$(MAKE) -C $(BUSYBOX_SRC) CC="$(MUSL_GCC)" olddefconfig
	@echo "[busybox] building"
	@$(MAKE) -C $(BUSYBOX_SRC) \
	    CC="$(MUSL_GCC)" \
	    EXTRA_CFLAGS="-Os -pipe" \
	    LDFLAGS="--static" \
	    -j$(JOBS)
	@echo "[busybox] installing applets"
	@$(MAKE) -C $(BUSYBOX_SRC) \
	    CC="$(MUSL_GCC)" \
	    CONFIG_PREFIX=$(STAGEDIR) \
	    install
	@echo "[busybox] done"
