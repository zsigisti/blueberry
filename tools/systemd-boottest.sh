#!/bin/bash
# systemd-boottest.sh — assemble the INIT=systemd rootfs, build a bootable ext4
# test image, boot it headless in QEMU, and report how far systemd got.
# Not part of the build; a developer aid for verifying the systemd migration.
set -u
TOP=/home/mmzs/projects/blueberry
BD=/home/mmzs/projects/blueberry-build
LOG=$BD/systemd-boot.log
IMG=$BD/systemd-test.img

step() { echo "[boottest] $*"; }

if [ "${REBUILD:-1}" = 1 ]; then
    step "clean rootfs + userland stamps (force reinstall of busybox into rootfs)"
    rm -rf "$BD/rootfs" "$BD/.stamp-install" \
           "$BD/.stamp-busybox" "$BD/.stamp-runit" "$BD/.stamp-dropbear"
    step "make install INIT=systemd"
    ( cd "$TOP" && ENGINE=podman make install INIT=systemd ) || { echo "install failed"; exit 1; }
fi

R=$BD/rootfs
step "inject a single-partition test fstab (real installs get UUIDs from the installer)"
cat > "$R/etc/fstab" <<EOF
LABEL=blueberry-root  /     ext4   rw,relatime              0 1
tmpfs                 /tmp  tmpfs  nosuid,nodev,size=256M   0 0
EOF

step "build ext4 image"
rm -f "$IMG"; truncate -s 1G "$IMG"
mkfs.ext4 -q -F -L blueberry-root -d "$R" "$IMG" || { echo "mkfs failed"; exit 1; }

step "boot in QEMU (headless, ${TIMEOUT:-120}s)"
rm -f "$LOG"
KVM=""; [ -w /dev/kvm ] && KVM="-enable-kvm -cpu host"
PORT=$(( (RANDOM % 4000) + 22000 ))
timeout "${TIMEOUT:-120}" qemu-system-x86_64 $KVM -m 1024 -smp 2 \
    -kernel "$BD/boot/vmlinuz" -initrd "$BD/boot/initramfs.cpio.zst" \
    -device ahci,id=ahci -drive file="$IMG",if=none,id=disk0,format=raw \
    -device ide-hd,drive=disk0,bus=ahci.0 \
    -nic user,model=e1000,hostfwd=tcp::${PORT}-:22 \
    -append "root=/dev/sda rootfstype=ext4 rw console=ttyS0,115200 systemd.unified_cgroup_hierarchy=1 systemd.show_status=1 bonding.max_bonds=0 dummy.numdummies=0" \
    -nographic -no-reboot > "$LOG" 2>&1
echo "=== QEMU EXIT rc=$? (ssh port was $PORT) ==="
