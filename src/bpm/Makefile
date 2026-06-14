# src/bpm/Makefile — build the bpm package manager binary.
#
# Outputs $(BPM_OUT). Standalone `make` builds ./bpm here; the top-level build
# overrides BPM_OUT and OBJDIR to keep artefacts under the project OBJDIR.
#
# Links libc + libzstd only (tar, HTTP and SHA-256 are implemented in-tree).

THISDIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

CC      ?= cc
CFLAGS  ?= -Os -pipe -fstack-protector-strong
CFLAGS  += -Wall -Wextra -std=gnu11
LDFLAGS ?=
LDLIBS  := -lzstd

OBJDIR  ?= $(THISDIR).obj
BPM_OUT ?= $(OBJDIR)/bpm

SRCS := main.c util.c sha256.c archive.c net.c pkginfo.c repo.c db.c install.c cmd.c
OBJS := $(addprefix $(OBJDIR)/,$(SRCS:.c=.o))

.PHONY: all clean
all: $(BPM_OUT)

$(BPM_OUT): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

$(OBJDIR)/%.o: $(THISDIR)%.c $(THISDIR)bpm.h | $(OBJDIR)
	$(CC) $(CFLAGS) -c -o $@ $<

$(OBJDIR):
	@mkdir -p $@

clean:
	rm -rf $(OBJDIR)
