# src/lib/musl/Makefile — build musl libc and create a sysroot
#
# Inputs:
#   MUSL_SRC   path to extracted musl source
#   SYSROOT    destination sysroot directory
#   ARCH       target architecture
#   CC         host C compiler
#   CFLAGS

BUILD_DIR := $(MUSL_SRC)/build-blueberry

.PHONY: all

all: $(SYSROOT)/lib/libc.so

$(SYSROOT)/lib/libc.so: $(MUSL_SRC)/Makefile
	@mkdir -p $(BUILD_DIR) $(SYSROOT)
	@echo "[musl] configuring"
	@cd $(BUILD_DIR) && $(MUSL_SRC)/configure \
	    --prefix=$(SYSROOT)/usr \
	    --libdir=$(SYSROOT)/usr/lib \
	    --syslibdir=$(SYSROOT)/lib \
	    ARCH=$(ARCH) \
	    CC="$(CC)" \
	    CFLAGS="$(CFLAGS)"
	@echo "[musl] building"
	@$(MAKE) -C $(BUILD_DIR) -j$(JOBS)
	@echo "[musl] installing into sysroot"
	@$(MAKE) -C $(BUILD_DIR) install
	@# Create ld symlinks expected by the dynamic linker
	@mkdir -p $(SYSROOT)/lib
	@ln -sf $(SYSROOT)/usr/lib/libc.so $(SYSROOT)/lib/libc.musl-$(ARCH).so.1 2>/dev/null || true
	@ln -sf $(SYSROOT)/usr/lib/libc.so $(SYSROOT)/lib/ld-musl-$(ARCH).so.1   2>/dev/null || true
	@# Create musl-gcc wrapper explicitly — don't rely on --enable-wrapper=all
	@mkdir -p $(SYSROOT)/bin $(SYSROOT)/usr/bin
	@printf '#!/bin/sh\nexec "$(CC)" --sysroot="$(SYSROOT)/usr" -isystem "$(SYSROOT)/usr/include" -L "$(SYSROOT)/usr/lib" "$$@"\n' \
	    > $(SYSROOT)/bin/musl-gcc
	@chmod +x $(SYSROOT)/bin/musl-gcc
	@cp $(SYSROOT)/bin/musl-gcc $(SYSROOT)/usr/bin/musl-gcc
	@echo "[musl] sysroot ready at $(SYSROOT)"
