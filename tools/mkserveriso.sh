#!/bin/sh
# mkserveriso.sh — build a live ISO of the Blueberry Server/CLI running systemd.
#
# Unlike mkiso.sh (busybox-from-RAM rescue shell), this squashes a full systemd
# rootfs and boots it via the same blueberry.live=1 overlay path the desktop
# uses, but to multi-user.target with an autologin getty (no GUI). This is the
# "systemd CLI": systemctl/journalctl/logind all work.
#
# Usage: mkserveriso.sh <systemd-rootfs> <output.iso>
set -eu
STAGEDIR=${1:?usage: mkserveriso.sh <rootfs> <output.iso>}
OUTPUT=${2:?usage: mkserveriso.sh <rootfs> <output.iso>}
TOPDIR=$(cd "$(dirname "$0")/.." && pwd)
VOLID=${VOLID:-BLUEBERRY_SRV}
BOOTDIR=${BOOTDIR:-$STAGEDIR/boot}
log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

[ -x "$STAGEDIR/usr/lib/systemd/systemd" ] || die "no systemd in $STAGEDIR (build with INIT=systemd)"
VMLINUZ="$BOOTDIR/vmlinuz"; INITRD="$BOOTDIR/initramfs.cpio.zst"
[ -f "$VMLINUZ" ] && [ -f "$INITRD" ] || die "no kernel/initramfs in $BOOTDIR (run make install)"

WORK=$(mktemp -d "$(dirname "$OUTPUT")/.bbsrv.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
LIVEROOT="$WORK/liveroot"; ISO_ROOT="$WORK/iso"
mkdir -p "$ISO_ROOT/boot/grub" "$ISO_ROOT/live" "$LIVEROOT"

log "cloning systemd rootfs → live root"
cp -al "$STAGEDIR/." "$LIVEROOT/" 2>/dev/null || cp -a "$STAGEDIR/." "$LIVEROOT/"

log "wiring systemd PID 1 + multi-user target + autologin getty"
mkdir -p "$LIVEROOT/sbin" "$LIVEROOT/usr/sbin"
ln -sf /usr/lib/systemd/systemd "$LIVEROOT/sbin/init"
# Merge /usr/bin → /usr/sbin + /sbin so unit ExecStarts (mount, sulogin…) resolve.
for b in "$LIVEROOT"/usr/bin/*; do [ -e "$b" ] || continue; n=$(basename "$b")
  [ -e "$LIVEROOT/usr/sbin/$n" ] || ln -sf "../bin/$n" "$LIVEROOT/usr/sbin/$n"
  [ -e "$LIVEROOT/sbin/$n" ] || ln -sf "/usr/bin/$n" "$LIVEROOT/sbin/$n"; done

# Already-set-up live system: machine-id + no interactive firstboot.
systemd-machine-id-setup --root="$LIVEROOT" >/dev/null 2>&1 \
  || (head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$LIVEROOT/etc/machine-id")
ln -sf /dev/null "$LIVEROOT/etc/systemd/system/systemd-firstboot.service"
echo "blueberry" > "$LIVEROOT/etc/hostname"
printf 'LANG=en_US.UTF-8\n' > "$LIVEROOT/etc/locale.conf"
mkdir -p "$LIVEROOT/etc/systemd/system.conf.d"
printf '[Manager]\nDefaultEnvironment=LANG=en_US.UTF-8\n' > "$LIVEROOT/etc/systemd/system.conf.d/10-locale.conf"

# Boot to a text login, not graphical.
ln -sf /usr/lib/systemd/system/multi-user.target "$LIVEROOT/etc/systemd/system/default.target"
# Autologin root on tty1 so the live CLI drops straight to a shell.
mkdir -p "$LIVEROOT/etc/systemd/system/getty@tty1.service.d"
cat > "$LIVEROOT/etc/systemd/system/getty@tty1.service.d/10-autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin root --noclear %I 38400 linux
EOF
# Live-only fstab (no disk).
printf '# live\ntmpfs /tmp tmpfs nosuid,nodev,size=512M 0 0\n' > "$LIVEROOT/etc/fstab"
# Enable sshd + networkd-ish basics if present (best-effort).
for u in sshd.service systemd-networkd.service systemd-resolved.service; do
  [ -e "$LIVEROOT/usr/lib/systemd/system/$u" ] && \
    ln -sf "/usr/lib/systemd/system/$u" "$LIVEROOT/etc/systemd/system/multi-user.target.wants/$u" 2>/dev/null || true
done

log "building squashfs (zstd)"
mksquashfs "$LIVEROOT" "$ISO_ROOT/live/filesystem.squashfs" \
  -comp zstd -Xcompression-level 19 -noappend -quiet \
  -e boot/vmlinuz boot/initramfs.cpio.zst
cp "$VMLINUZ" "$ISO_ROOT/boot/vmlinuz"
cp "$INITRD"  "$ISO_ROOT/boot/initramfs.cpio.zst"

cat > "$ISO_ROOT/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5
menuentry "Blueberry Server (systemd live)" {
    linux /boot/vmlinuz blueberry.live=1 root=live:CDLABEL=$VOLID console=tty0 console=ttyS0,115200 systemd.firstboot=0
    initrd /boot/initramfs.cpio.zst
}
EOF
log "building hybrid ISO: $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
grub-mkrescue --output "$OUTPUT" "$ISO_ROOT" -- -volid "$VOLID" >/dev/null 2>&1 \
  || grub-mkrescue --output "$OUTPUT" "$ISO_ROOT" -- -volid "$VOLID"
log "ISO written: $OUTPUT ($(du -sh "$OUTPUT" | cut -f1))"
