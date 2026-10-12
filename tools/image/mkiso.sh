#!/bin/sh
# usage: tools/image/mkiso.sh <rootfsdir> [output.iso]
#
# Hybrid BIOS+UEFI ISO of the live CLI (same thing `make run` boots), plus
# the install payload under /blueberry. <rootfsdir> needs boot/vmlinuz and
# boot/initramfs.cpio.zst from `make install`.
# Needs grub-mkrescue, xorriso and mtools.

set -e

ROOTFS=${1:?usage: $0 <rootfsdir> [output.iso]}
OUTPUT=${2:-blueberry-$(date +%Y%m%d).iso}
BUILD_TMP=$(mktemp -d /tmp/blueberry-iso.XXXXXX)
trap 'rm -rf "$BUILD_TMP"' EXIT

log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

[ -d "$ROOTFS" ] || die "rootfs directory not found: $ROOTFS"
command -v grub-mkrescue >/dev/null || die "grub-mkrescue not found (install grub2)"
command -v xorriso       >/dev/null || die "xorriso not found"
command -v mformat       >/dev/null || die "mtools not found (needed for the UEFI image)"

VMLINUZ="$ROOTFS/boot/vmlinuz"
INITRD="$ROOTFS/boot/initramfs.cpio.zst"
[ -f "$VMLINUZ" ] || VMLINUZ=$(find "$ROOTFS/boot" -name 'vmlinuz*' | head -1)
[ -f "$INITRD"  ] || INITRD=$(find "$ROOTFS/boot" \( -name 'initramfs*' -o -name 'initrd*' \) | head -1)
[ -f "$VMLINUZ" ] || die "no kernel found in $ROOTFS/boot (run 'make install')"
[ -f "$INITRD"  ] || die "no initramfs found in $ROOTFS/boot (run 'make install')"

ISO_ROOT="$BUILD_TMP/iso"
mkdir -p "$ISO_ROOT/boot/grub"
cp "$VMLINUZ" "$ISO_ROOT/boot/vmlinuz"
cp "$INITRD"  "$ISO_ROOT/boot/initramfs.cpio.zst"

# rootfs + kernel + a GRUB EFI under /blueberry, so blueberry-install works offline
if command -v zstd >/dev/null; then
    PAYLOAD="$ISO_ROOT/blueberry"
    mkdir -p "$PAYLOAD"
    log "Building installer payload (rootfs.tar.zst)"
    # --owner=0 matters: we build as uid 1000, and without it the installer
    # restores that uid verbatim. Every setuid binary (mount, su, sudo, passwd,
    # ping) then ends up setuid-to-1000, tmp.mount fails at boot and sudo
    # quietly stops working.
    tar -C "$ROOTFS" \
        --owner=0 --group=0 --numeric-owner \
        --exclude='./boot/vmlinuz' --exclude='./boot/initramfs.cpio.zst' \
        -cf - . | zstd -q -19 > "$PAYLOAD/rootfs.tar.zst"
    cp "$VMLINUZ" "$PAYLOAD/vmlinuz"
    cp "$INITRD"  "$PAYLOAD/initramfs.cpio.zst"
    # finds the ESP with /vmlinuz on it and chains to the grub.cfg the
    # installer writes there
    if command -v grub-mkstandalone >/dev/null; then
        cat > "$BUILD_TMP/inst-grub.cfg" <<'GEOF'
search --no-floppy --file --set=root /vmlinuz
configfile ($root)/grub/grub.cfg
GEOF
        grub-mkstandalone -O x86_64-efi \
            --modules="part_gpt fat search search_fs_file normal linux echo all_video gfxterm test configfile" \
            -o "$PAYLOAD/bootx64.efi" \
            "boot/grub/grub.cfg=$BUILD_TMP/inst-grub.cfg" 2>/dev/null
        log "installer payload ready ($(du -sh "$PAYLOAD" | cut -f1))"
    else
        log "WARNING: grub-mkstandalone missing, installer payload has no bootloader"
    fi
else
    log "WARNING: zstd missing, ISO will not include the installer payload"
fi

# ttyS0 goes last so it's the main console - QEMU -nographic and headless
# boxes live on serial. tty0 still gets a shell too.
cat > "$ISO_ROOT/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=5
# countdown, so a headless box doesn't sit at the menu forever
set timeout_style=countdown

# UEFI: keep the GOP framebuffer (new machines have no VGA text mode at all).
# BIOS: plain text for vgacon.
if [ "$grub_platform" = "efi" ]; then
    set gfxpayload=keep
else
    set gfxpayload=text
fi

# no `serial` command here, it errors on machines without a COM port

menuentry "Blueberry Linux (live CLI)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 bonding.max_bonds=0 dummy.numdummies=0
    initrd /boot/initramfs.cpio.zst
}

menuentry "Blueberry Linux (live CLI, verbose)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 bonding.max_bonds=0 dummy.numdummies=0 debug
    initrd /boot/initramfs.cpio.zst
}
EOF

# grub-mkrescue does El Torito + MBR + an embedded ESP, so one ISO covers BIOS,
# UEFI and dd-to-USB
log "Building hybrid BIOS+UEFI ISO: $OUTPUT"
grub-mkrescue --output "$OUTPUT" "$ISO_ROOT" \
    -- -volid BLUEBERRY >/dev/null 2>&1 \
    || grub-mkrescue --output "$OUTPUT" "$ISO_ROOT" -- -volid BLUEBERRY

log "ISO written to $OUTPUT ($(du -sh "$OUTPUT" | cut -f1))"
log "Boot it:  qemu-system-x86_64 -cdrom $OUTPUT -m 512M -nographic"
log "Or write to USB:  dd if=$OUTPUT of=/dev/sdX bs=4M status=progress oflag=sync"
