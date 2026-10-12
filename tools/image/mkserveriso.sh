#!/bin/sh
# usage: mkserveriso.sh <systemd-rootfs> <output.iso>
#
# Live server ISO: the whole systemd rootfs as a squashfs, booted through the
# initramfs's blueberry.live=1 overlay path to multi-user with root autologin.
# mkiso.sh is the busybox one.
set -eu
STAGEDIR=${1:?usage: mkserveriso.sh <rootfs> <output.iso>}
OUTPUT=${2:?usage: mkserveriso.sh <rootfs> <output.iso>}
TOPDIR=$(cd "$(dirname "$0")/../.." && pwd)
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

log "cloning systemd rootfs -> live root"
cp -al "$STAGEDIR/." "$LIVEROOT/" 2>/dev/null || cp -a "$STAGEDIR/." "$LIVEROOT/"

log "wiring systemd PID 1 + multi-user target + autologin getty"
mkdir -p "$LIVEROOT/sbin" "$LIVEROOT/usr/sbin"
ln -sf /usr/lib/systemd/systemd "$LIVEROOT/sbin/init"
# the systemd base has bash but no sh
[ -e "$LIVEROOT/usr/bin/sh" ] || ln -sf bash "$LIVEROOT/usr/bin/sh"
[ -e "$LIVEROOT/bin/sh" ]     || { mkdir -p "$LIVEROOT/bin"; ln -sf /usr/bin/bash "$LIVEROOT/bin/sh"; }
# make /usr/sbin/x and /sbin/x resolve too, units hard-code those (mount, sulogin...)
for b in "$LIVEROOT"/usr/bin/*; do [ -e "$b" ] || continue; n=$(basename "$b")
  [ -e "$LIVEROOT/usr/sbin/$n" ] || ln -sf "../bin/$n" "$LIVEROOT/usr/sbin/$n"
  [ -e "$LIVEROOT/sbin/$n" ] || ln -sf "/usr/bin/$n" "$LIVEROOT/sbin/$n"; done

# no firstboot wizard on a live CD
systemd-machine-id-setup --root="$LIVEROOT" >/dev/null 2>&1 \
  || (head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$LIVEROOT/etc/machine-id")
ln -sf /dev/null "$LIVEROOT/etc/systemd/system/systemd-firstboot.service"
echo "blueberry" > "$LIVEROOT/etc/hostname"

# Consoles autologin, but ssh, su and the web console go through PAM and need
# a real password, and the base has no /etc/shadow at all. So the live ISO
# gets root/blueberry (LIVE_ROOT_PW to change). Installs set their own.
LIVE_ROOT_PW=${LIVE_ROOT_PW:-blueberry}
if command -v openssl >/dev/null 2>&1; then
  ROOT_HASH=$(openssl passwd -6 "$LIVE_ROOT_PW")
else
  ROOT_HASH='$6$blueberrylive$Hw2pz1XWymm71QCIM5QwbMS/yj3QzvWDDmD7VKtfzQ.KiWP/CrpHw/ZriCm7zZM/tiyBjg.6zZAVZHrRU5c8m.'  # "blueberry"
fi
DAY=$(( $(date +%s) / 86400 ))
: > "$LIVEROOT/etc/shadow"
while IFS=: read -r U _; do
  [ -n "$U" ] || continue
  if [ "$U" = root ]; then
    printf 'root:%s:%s:0:99999:7:::\n' "$ROOT_HASH" "$DAY" >> "$LIVEROOT/etc/shadow"
  else
    printf '%s:!:%s:0:99999:7:::\n' "$U" "$DAY" >> "$LIVEROOT/etc/shadow"   # locked
  fi
done < "$LIVEROOT/etc/passwd"
cp "$LIVEROOT/etc/shadow" "$LIVEROOT/etc/shadow-"
chmod 0640 "$LIVEROOT/etc/shadow" "$LIVEROOT/etc/shadow-"
printf 'LANG=en_US.UTF-8\n' > "$LIVEROOT/etc/locale.conf"
mkdir -p "$LIVEROOT/etc/systemd/system.conf.d"
printf '[Manager]\nDefaultEnvironment=LANG=en_US.UTF-8\n' > "$LIVEROOT/etc/systemd/system.conf.d/10-locale.conf"

ln -sf /usr/lib/systemd/system/multi-user.target "$LIVEROOT/etc/systemd/system/default.target"
# autologin on tty1 and ttyS0 (so run-server works with -nographic)
mkdir -p "$LIVEROOT/etc/systemd/system/getty@tty1.service.d"
cat > "$LIVEROOT/etc/systemd/system/getty@tty1.service.d/10-autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin root --noclear %I 38400 linux
EOF
mkdir -p "$LIVEROOT/etc/systemd/system/serial-getty@ttyS0.service.d" \
         "$LIVEROOT/etc/systemd/system/getty.target.wants"
cat > "$LIVEROOT/etc/systemd/system/serial-getty@ttyS0.service.d/10-autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin root --keep-baud 115200,57600,38400,9600 %I $TERM
EOF
ln -sf /usr/lib/systemd/system/serial-getty@ttyS0.service \
  "$LIVEROOT/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"
# ESC c resets the terminal, so the login banner lands on a clean screen
# instead of under the boot log. \S = PRETTY_NAME, \r kernel, \m arch, \l tty.
printf '\033c\\S \\r (\\m) \\l\n\n' > "$LIVEROOT/etc/issue"
printf '# live\ntmpfs /tmp tmpfs nosuid,nodev,size=512M 0 0\n' > "$LIVEROOT/etc/fstab"
for u in sshd.service systemd-networkd.service systemd-resolved.service; do
  [ -e "$LIVEROOT/usr/lib/systemd/system/$u" ] && \
    ln -sf "/usr/lib/systemd/system/$u" "$LIVEROOT/etc/systemd/system/multi-user.target.wants/$u" 2>/dev/null || true
done
# DHCP out of the box. resolv.conf points at resolved's real file rather than
# the stub, so plain glibc nss works without nss-resolve.
mkdir -p "$LIVEROOT/etc/systemd/network"
cat > "$LIVEROOT/etc/systemd/network/10-dhcp.network" <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF
ln -sf /run/systemd/resolve/resolv.conf "$LIVEROOT/etc/resolv.conf"
mkdir -p "$LIVEROOT/run/systemd/resolve"

log "building squashfs (zstd)"
# -all-root: we build as uid 1000, and without it every setuid binary (mount,
# su, sudo...) is setuid-to-1000 and tmp.mount fails at boot
mksquashfs "$LIVEROOT" "$ISO_ROOT/live/filesystem.squashfs" \
  -comp zstd -Xcompression-level 19 -noappend -quiet -all-root \
  -e boot/vmlinuz boot/initramfs.cpio.zst
cp "$VMLINUZ" "$ISO_ROOT/boot/vmlinuz"
cp "$INITRD"  "$ISO_ROOT/boot/initramfs.cpio.zst"

cat > "$ISO_ROOT/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5
menuentry "Blueberry Server (systemd live)" {
    linux /boot/vmlinuz blueberry.live=1 root=live:CDLABEL=$VOLID console=tty0 console=ttyS0,115200 systemd.firstboot=0 quiet loglevel=3 systemd.show_status=0
    initrd /boot/initramfs.cpio.zst
}
EOF
log "building hybrid ISO: $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
grub-mkrescue --output "$OUTPUT" "$ISO_ROOT" -- -volid "$VOLID" >/dev/null 2>&1 \
  || grub-mkrescue --output "$OUTPUT" "$ISO_ROOT" -- -volid "$VOLID"
log "ISO written: $OUTPUT ($(du -sh "$OUTPUT" | cut -f1))"
