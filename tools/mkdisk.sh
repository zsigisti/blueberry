#!/bin/bash
# mkdisk.sh — build a dd-able, UEFI-bootable Blueberry disk image.
#
# Produces a GPT raw image with:
#   p1  ESP  (FAT32)  — GRUB (UEFI) + grub.cfg + vmlinuz + initramfs
#   p2  data (ext4, label "blueberry-data") — persistent storage for you to use
#
# It boots the live CLI from the initramfs (RAM), identically to the ISO, but
# from the machine's own disk — no install media needed. Deploy it by writing
# the image to the target disk:
#
#   dd if=blueberry.img of=/dev/sdX bs=4M status=progress oflag=sync
#
# Built entirely without root/loop devices (sgdisk + mkfs -d + mtools + dd),
# so it runs in any unprivileged environment / CI.
#
# Usage: tools/mkdisk.sh <output.img> [rootfsdir] [size]
#   rootfsdir  dir holding boot/vmlinuz + boot/initramfs.cpio.zst (make install)
#   size       total image size (default 2G)

set -euo pipefail

OUT=${1:?usage: $0 <output.img> [rootfsdir] [size]}
TOPDIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS=${2:-$(cd "$TOPDIR/.." && pwd)/blueberry-build/rootfs}
SIZE=${3:-2G}
WORK=$(mktemp -d /tmp/blueberry-disk.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

for t in sgdisk mkfs.fat mkfs.ext4 mmd mcopy grub-mkstandalone qemu-img; do
    command -v "$t" >/dev/null || die "$t not found"
done

VMLINUZ="$ROOTFS/boot/vmlinuz"
INITRD="$ROOTFS/boot/initramfs.cpio.zst"
[ -f "$VMLINUZ" ] || die "no kernel at $VMLINUZ (run 'make install')"
[ -f "$INITRD"  ] || die "no initramfs at $INITRD (run 'make install')"

SECTOR=512

# ── 1. Empty GPT image ────────────────────────────────────────────────────────
log "Creating ${SIZE} image: $OUT"
qemu-img create -q -f raw "$OUT" "$SIZE"
sgdisk --zap-all "$OUT" >/dev/null
# p1: 256 MiB ESP (EF00). p2: rest, Linux fs (8300), labelled blueberry-data.
sgdisk -n 1:1MiB:+256MiB -t 1:EF00 -c 1:EFI \
       -n 2:0:0          -t 2:8300 -c 2:blueberry-data \
       "$OUT" >/dev/null
log "Partition table:"
sgdisk -p "$OUT" | sed 's/^/    /'

# sgdisk -i prints e.g. "First sector: 2048 (at 1.0 MiB)" — the sector is $3.
part_start() { sgdisk -i "$1" "$OUT" | awk '/First sector/{print $3}'; }
part_size()  { # sectors = last - first + 1
    local f l
    f=$(sgdisk -i "$1" "$OUT" | awk '/First sector/{print $3}')
    l=$(sgdisk -i "$1" "$OUT" | awk '/Last sector/{print $3}')
    echo $(( l - f + 1 ))
}

ESP_START=$(part_start 1);  ESP_SECTORS=$(part_size 1)
DAT_START=$(part_start 2);  DAT_SECTORS=$(part_size 2)

# ── 2. Build the ESP (FAT32) with mtools — no mount needed ─────────────────────
log "Building EFI system partition"
ESP_IMG="$WORK/esp.img"
truncate -s $(( ESP_SECTORS * SECTOR )) "$ESP_IMG"
mkfs.fat -F32 -n EFI "$ESP_IMG" >/dev/null

# GRUB EFI binary: a standalone image whose embedded config finds the ESP (the
# partition that holds /vmlinuz) and boots the live CLI, on serial or monitor.
cat > "$WORK/grub.cfg" <<'EOF'
set timeout=3
set timeout_style=countdown
if serial --unit=0 --speed=115200; then
    terminal_input  console serial
    terminal_output console serial
fi
search --no-floppy --file --set=root /vmlinuz
menuentry "Blueberry Linux (live CLI)" {
    set gfxpayload=text
    linux /vmlinuz console=tty0 console=ttyS0,115200
    initrd /initramfs.cpio.zst
}
menuentry "Blueberry Linux (live CLI, verbose)" {
    set gfxpayload=text
    linux /vmlinuz console=tty0 console=ttyS0,115200 debug
    initrd /initramfs.cpio.zst
}
EOF

grub-mkstandalone -O x86_64-efi \
    -o "$WORK/BOOTX64.EFI" \
    "boot/grub/grub.cfg=$WORK/grub.cfg" >/dev/null 2>&1 \
    || grub-mkstandalone -O x86_64-efi -o "$WORK/BOOTX64.EFI" \
         "boot/grub/grub.cfg=$WORK/grub.cfg"

mmd   -i "$ESP_IMG" ::/EFI ::/EFI/BOOT
mcopy -i "$ESP_IMG" "$WORK/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP_IMG" "$WORK/grub.cfg"    ::/grub.cfg
mcopy -i "$ESP_IMG" "$VMLINUZ"          ::/vmlinuz
mcopy -i "$ESP_IMG" "$INITRD"           ::/initramfs.cpio.zst

dd if="$ESP_IMG" of="$OUT" bs=$SECTOR seek="$ESP_START" conv=notrunc status=none

# ── 3. Build the data partition (ext4) — populated from a dir, no mount ────────
log "Building data partition (ext4, label blueberry-data)"
DAT_IMG="$WORK/data.img"
truncate -s $(( DAT_SECTORS * SECTOR )) "$DAT_IMG"
mkdir -p "$WORK/dataroot"
printf 'Blueberry Linux persistent data partition.\n' > "$WORK/dataroot/README"
mkfs.ext4 -q -L blueberry-data -d "$WORK/dataroot" "$DAT_IMG"
dd if="$DAT_IMG" of="$OUT" bs=$SECTOR seek="$DAT_START" conv=notrunc status=none

log "Disk image written: $OUT ($(du -sh "$OUT" | cut -f1) on disk)"
log "Boot it (UEFI):  qemu-system-x86_64 -drive file=$OUT,format=raw -bios /usr/share/edk2/x64/OVMF.4m.fd -m 512M -nographic"
log "Deploy it:        dd if=$OUT of=/dev/sdX bs=4M status=progress oflag=sync"
