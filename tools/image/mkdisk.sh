#!/bin/bash
# usage: tools/image/mkdisk.sh <output.img> [rootfsdir] [size=2G]
#
# Raw GPT image that boots the same live CLI as the ISO, straight off a disk:
#   p1  ESP, FAT32: GRUB + grub.cfg + vmlinuz + initramfs
#   p2  ext4 "blueberry-data", yours to use
# rootfsdir needs boot/vmlinuz and boot/initramfs.cpio.zst (make install).
# No root or loop devices (sgdisk, mkfs -d, mtools, dd), so it runs in CI.
#
#   dd if=blueberry.img of=/dev/sdX bs=4M status=progress oflag=sync

set -euo pipefail

OUT=${1:?usage: $0 <output.img> [rootfsdir] [size]}
TOPDIR="$(cd "$(dirname "$0")/../.." && pwd)"
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

# SECUREBOOT_KEYDIR (from `blueberry-secureboot keygen`) signs the whole chain:
# GRUB gets sbsigned with db and enforces GPG sigs on the kernel + initramfs.
# Unset = plain unsigned image.
SB_KEYDIR=${SECUREBOOT_KEYDIR:-}
SB=0
if [ -n "$SB_KEYDIR" ]; then
    { [ -f "$SB_KEYDIR/db.key" ] && [ -f "$SB_KEYDIR/grub-gpg.pub" ]; } \
        || die "SECUREBOOT_KEYDIR=$SB_KEYDIR lacks db.key/grub-gpg.pub (run: blueberry-secureboot keygen)"
    for t in sbsign gpg; do command -v "$t" >/dev/null || die "$t not found (needed for Secure Boot)"; done
    SB=1
fi

SECTOR=512

log "Creating ${SIZE} image: $OUT"
qemu-img create -q -f raw "$OUT" "$SIZE"
sgdisk --zap-all "$OUT" >/dev/null
sgdisk -n 1:1MiB:+256MiB -t 1:EF00 -c 1:EFI \
       -n 2:0:0          -t 2:8300 -c 2:blueberry-data \
       "$OUT" >/dev/null
log "Partition table:"
sgdisk -p "$OUT" | sed 's/^/    /'

# sgdisk -i prints "First sector: 2048 (at 1.0 MiB)", we want $3
part_start() { sgdisk -i "$1" "$OUT" | awk '/First sector/{print $3}'; }
part_size()  {
    local f l
    f=$(sgdisk -i "$1" "$OUT" | awk '/First sector/{print $3}')
    l=$(sgdisk -i "$1" "$OUT" | awk '/Last sector/{print $3}')
    echo $(( l - f + 1 ))
}

ESP_START=$(part_start 1);  ESP_SECTORS=$(part_size 1)
DAT_START=$(part_start 2);  DAT_SECTORS=$(part_size 2)

log "Building EFI system partition"
ESP_IMG="$WORK/esp.img"
truncate -s $(( ESP_SECTORS * SECTOR )) "$ESP_IMG"
mkfs.fat -F32 -n EFI "$ESP_IMG" >/dev/null

cat > "$WORK/grub.cfg" <<'EOF'
set timeout=3
set timeout_style=countdown
# keep the GOP framebuffer for efifb
set gfxpayload=keep
search --no-floppy --file --set=root /vmlinuz
menuentry "Blueberry Linux (live CLI)" {
    linux /vmlinuz console=tty0 console=ttyS0,115200 bonding.max_bonds=0 dummy.numdummies=0
    initrd /initramfs.cpio.zst
}
menuentry "Blueberry Linux (live CLI, verbose)" {
    linux /vmlinuz console=tty0 console=ttyS0,115200 bonding.max_bonds=0 dummy.numdummies=0 debug
    initrd /initramfs.cpio.zst
}
EOF

# mkstandalone leaves out filesystem drivers, so without these the embedded
# grub.cfg can't even read the ESP it lives on
GRUB_MODS="part_gpt fat search search_fs_file normal linux echo all_video gfxterm test configfile"
GRUB_SBOPTS=""
if [ "$SB" = 1 ]; then
    # pgp + embedded key = GRUB refuses anything without a good .sig.
    # --disable-shim-lock: we have no Microsoft shim, and GRUB's shim_lock
    # verifier then rejects the linux handoff ("shim protocols not found")
    # even with our own keys. See grub-core/kern/efi/sb.c.
    GRUB_MODS="$GRUB_MODS pgp"
    GRUB_SBOPTS="--pubkey=$SB_KEYDIR/grub-gpg.pub --disable-shim-lock"
fi
grub-mkstandalone -O x86_64-efi \
    --modules="$GRUB_MODS" $GRUB_SBOPTS \
    -o "$WORK/BOOTX64.EFI" \
    "boot/grub/grub.cfg=$WORK/grub.cfg"
KIMG="$VMLINUZ"
if [ "$SB" = 1 ]; then
    log "Secure Boot: sbsign BOOTX64.EFI + kernel (db) + GPG-sign kernel/initramfs"
    sbsign --key "$SB_KEYDIR/db.key" --cert "$SB_KEYDIR/db.crt" \
        --output "$WORK/BOOTX64.EFI" "$WORK/BOOTX64.EFI"
    # GRUB hands the kernel to firmware LoadImage, which checks it against
    # db, so the kernel needs an sbsign too, not just a GPG sig
    sbsign --key "$SB_KEYDIR/db.key" --cert "$SB_KEYDIR/db.crt" \
        --output "$WORK/vmlinuz.signed" "$VMLINUZ"
    KIMG="$WORK/vmlinuz.signed"
    gpg --homedir "$SB_KEYDIR/gpg" --batch --yes --detach-sign -o "$WORK/vmlinuz.sig"   "$KIMG"
    gpg --homedir "$SB_KEYDIR/gpg" --batch --yes --detach-sign -o "$WORK/initramfs.sig" "$INITRD"
fi

mmd   -i "$ESP_IMG" ::/EFI ::/EFI/BOOT
mcopy -i "$ESP_IMG" "$WORK/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP_IMG" "$WORK/grub.cfg"    ::/grub.cfg
mcopy -i "$ESP_IMG" "$KIMG"             ::/vmlinuz
mcopy -i "$ESP_IMG" "$INITRD"           ::/initramfs.cpio.zst
if [ "$SB" = 1 ]; then
    mcopy -i "$ESP_IMG" "$WORK/vmlinuz.sig"   ::/vmlinuz.sig
    mcopy -i "$ESP_IMG" "$WORK/initramfs.sig" ::/initramfs.cpio.zst.sig
fi

dd if="$ESP_IMG" of="$OUT" bs=$SECTOR seek="$ESP_START" conv=notrunc status=none

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
