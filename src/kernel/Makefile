# Kernel compile, only used with KERNEL_BUILD=1 (normally we fetch a prebuilt).
# The top GNUmakefile passes LINUX_SRC, LINUX_VERSION, KERNEL_LOCALVERSION,
# BOOTDIR (vmlinuz, System.map), STAGEDIR (modules), ARCH, CROSS_COMPILE, JOBS.

THISDIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
CONFIG  := $(THISDIR)/config
PATCHES := $(THISDIR)/patches

KARCH   := $(ARCH)

.PHONY: all modules_install _patch _configure

all: _patch _configure
	@echo "[kernel] make -j$(JOBS)"
	@# LOCALVERSION stays empty: the suffix already comes from
	@# CONFIG_LOCALVERSION, and passing it here too gives you
	@# 7.1.3-blueberry-blueberry. Empty rather than unset also kills the "+".
	@$(MAKE) -C $(LINUX_SRC) \
	    ARCH=$(KARCH) \
	    CROSS_COMPILE=$(CROSS_COMPILE) \
	    LOCALVERSION= \
	    -j$(JOBS)
	@echo "[kernel] installing bzImage"
	@install -Dm644 \
	    $(LINUX_SRC)/arch/$(KARCH)/boot/bzImage \
	    $(BOOTDIR)/vmlinuz
	@install -Dm644 \
	    $(LINUX_SRC)/System.map \
	    $(BOOTDIR)/System.map-$(LINUX_VERSION)$(KERNEL_LOCALVERSION)
	@ln -sf System.map-$(LINUX_VERSION)$(KERNEL_LOCALVERSION) \
	    $(BOOTDIR)/System.map
	@echo "[kernel] installing modules"
	@$(MAKE) -C $(LINUX_SRC) \
	    ARCH=$(KARCH) \
	    CROSS_COMPILE=$(CROSS_COMPILE) \
	    INSTALL_MOD_PATH=$(STAGEDIR) \
	    modules_install

_patch:
	@if [ ! -f $(LINUX_SRC)/.blueberry-patched ]; then \
	    echo "[kernel] applying patches"; \
	    for p in $(PATCHES)/*.patch; do \
	        [ -f "$$p" ] || continue; \
	        echo "  applying $$p"; \
	        patch -d $(LINUX_SRC) -p1 < $$p || exit 1; \
	    done; \
	    touch $(LINUX_SRC)/.blueberry-patched; \
	fi

_configure:
	@if [ ! -f $(LINUX_SRC)/.config ] || \
	   [ $(CONFIG) -nt $(LINUX_SRC)/.config ]; then \
	    echo "[kernel] installing config"; \
	    cp $(CONFIG) $(LINUX_SRC)/.config; \
	    $(MAKE) -C $(LINUX_SRC) \
	        ARCH=$(KARCH) \
	        CROSS_COMPILE=$(CROSS_COMPILE) \
	        olddefconfig; \
	fi
