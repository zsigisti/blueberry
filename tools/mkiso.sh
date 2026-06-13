#!/bin/sh
# mkiso.sh — create a hybrid BIOS+UEFI bootable ISO of the Blueberry live CLI.
#
# The ISO boots the kernel + initramfs straight into the live CLI shell — no
# disk, no squashfs, no package manager. It is identical to what `make run`
# boots, just on real media (CD/USB) for bare metal.
#
# Usage: tools/mkiso.sh <rootfsdir> [output.iso]
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

# console=tty0 → physical monitor (VGA text); console=ttyS0 → serial / IPMI.
# ttyS0 is listed last so the interactive shell lands on the serial console
# (which is what QEMU -nographic and most headless servers use).
cat > "$ISO_ROOT/boot/grub/grub.cfg" <<'EOF'
set timeout=5
set default=0

if serial --unit=0 --speed=115200; then
    terminal_input  console serial
    terminal_output console serial
fi

menuentry "Blueberry Linux (live CLI)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200
    initrd /boot/initramfs.cpio.zst
}

menuentry "Blueberry Linux (live CLI, verbose)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 debug
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
