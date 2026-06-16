# src/kernel/Makefile — Linux kernel build rules
#
# Called by the top-level GNUmakefile with:
#   LINUX_SRC        path to extracted linux-X.Y source tree
#   LINUX_VERSION    e.g. 7.0
#   KERNEL_LOCALVERSION  e.g. -blueberry
#   BOOTDIR          destination for vmlinuz + System.map
#   STAGEDIR         destination for kernel modules
#   ARCH             e.g. x86_64
#   CROSS_COMPILE    cross-compiler prefix (may be empty)
#   JOBS             parallel jobs

THISDIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
CONFIG  := $(THISDIR)/config
PATCHES := $(THISDIR)/patches

KARCH   := $(ARCH)

.PHONY: all modules_install _patch _configure

all: _patch _configure
	@echo "[kernel] make -j$(JOBS)"
	@$(MAKE) -C $(LINUX_SRC) \
	    ARCH=$(KARCH) \
	    CROSS_COMPILE=$(CROSS_COMPILE) \
	    LOCALVERSION=$(KERNEL_LOCALVERSION) \
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
