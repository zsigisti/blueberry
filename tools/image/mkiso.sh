#!/bin/sh
# mkiso.sh — create a hybrid BIOS+UEFI bootable ISO of the Blueberry live CLI.
#
# The ISO boots the kernel + initramfs straight into the live CLI shell — no
# disk, no squashfs, no package manager. It is identical to what `make run`
# boots, just on real media (CD/USB) for bare metal.
#
# Usage: tools/image/mkiso.sh <rootfsdir> [output.iso]
#   <rootfsdir> must contain boot/vmlinuz and boot/initramfs.cpio.zst
#               (populated by `make install`)
#
# Requires: grub-mkrescue (grub2), xorriso, and mtools (for the UEFI image).

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

# ── Locate boot assets ────────────────────────────────────────────────────────
VMLINUZ="$ROOTFS/boot/vmlinuz"
INITRD="$ROOTFS/boot/initramfs.cpio.zst"
[ -f "$VMLINUZ" ] || VMLINUZ=$(find "$ROOTFS/boot" -name 'vmlinuz*' | head -1)
[ -f "$INITRD"  ] || INITRD=$(find "$ROOTFS/boot" \( -name 'initramfs*' -o -name 'initrd*' \) | head -1)
[ -f "$VMLINUZ" ] || die "no kernel found in $ROOTFS/boot (run 'make install')"
[ -f "$INITRD"  ] || die "no initramfs found in $ROOTFS/boot (run 'make install')"

# ── Stage the ISO tree ────────────────────────────────────────────────────────
ISO_ROOT="$BUILD_TMP/iso"
mkdir -p "$ISO_ROOT/boot/grub"
cp "$VMLINUZ" "$ISO_ROOT/boot/vmlinuz"
cp "$INITRD"  "$ISO_ROOT/boot/initramfs.cpio.zst"

# ── Installer payload ─────────────────────────────────────────────────────────
# Ship the full rootfs + boot assets + a GRUB EFI under /blueberry so the
# bundled `blueberry-install` can install Blueberry to a local disk offline.
if command -v zstd >/dev/null; then
    PAYLOAD="$ISO_ROOT/blueberry"
    mkdir -p "$PAYLOAD"
    log "Building installer payload (rootfs.tar.zst)"
    tar -C "$ROOTFS" \
        --exclude='./boot/vmlinuz' --exclude='./boot/initramfs.cpio.zst' \
        -cf - . | zstd -q -19 > "$PAYLOAD/rootfs.tar.zst"
    cp "$VMLINUZ" "$PAYLOAD/vmlinuz"
    cp "$INITRD"  "$PAYLOAD/initramfs.cpio.zst"
    # Prebuilt GRUB EFI: finds the installed ESP (the one holding /vmlinuz) and
    # runs the /grub/grub.cfg that blueberry-install writes (with root=UUID).
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
        log "WARNING: grub-mkstandalone missing — installer payload has no bootloader"
    fi
else
    log "WARNING: zstd missing — ISO will not include the installer payload"
fi

# console=tty0 → physical monitor (VGA text); console=ttyS0 → serial / IPMI.
# ttyS0 is listed last so the interactive shell lands on the serial console
# (which is what QEMU -nographic and most headless servers use).
cat > "$ISO_ROOT/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=5
# countdown (not the interactive menu) so a headless/serial console auto-boots
# instead of stalling forever waiting for a keypress.
set timeout_style=countdown

# Display payload depends on firmware:
#   UEFI -> keep the GOP framebuffer so the kernel's efifb can drive the screen
#           (modern laptops/desktops have no legacy VGA text console).
#   BIOS -> text mode for vgacon.
if [ "$grub_platform" = "efi" ]; then
    set gfxpayload=keep
else
    set gfxpayload=text
fi

# (No `serial` setup here — it errors on machines without a COM port. The kernel
# still gets console=ttyS0 for real serial/IPMI consoles after GRUB hands off.)

menuentry "Blueberry Linux (live CLI)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 bonding.max_bonds=0 dummy.numdummies=0
    initrd /boot/initramfs.cpio.zst
}

menuentry "Blueberry Linux (live CLI, verbose)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 bonding.max_bonds=0 dummy.numdummies=0 debug
    initrd /boot/initramfs.cpio.zst
}
EOF

# ── Build the hybrid ISO ──────────────────────────────────────────────────────
# grub-mkrescue emits a GRUB image that boots on both legacy BIOS (El Torito +
# embedded MBR) and UEFI (an embedded EFI System Partition), so the one ISO
# works on essentially any x86_64 machine and as a `dd`-able USB stick.
log "Building hybrid BIOS+UEFI ISO: $OUTPUT"
grub-mkrescue --output "$OUTPUT" "$ISO_ROOT" \
    -- -volid BLUEBERRY >/dev/null 2>&1 \
    || grub-mkrescue --output "$OUTPUT" "$ISO_ROOT" -- -volid BLUEBERRY

log "ISO written to $OUTPUT ($(du -sh "$OUTPUT" | cut -f1))"
log "Boot it:  qemu-system-x86_64 -cdrom $OUTPUT -m 512M -nographic"
log "Or write to USB:  dd if=$OUTPUT of=/dev/sdX bs=4M status=progress oflag=sync"
