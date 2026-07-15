#!/bin/bash
# test-install.sh — automated end-to-end install smoke-test (QEMU, BIOS).
#
# Boots the kernel+initramfs in unattended-install mode (`bbinstall`) with the
# given installer ISO attached as the payload medium and a blank virtio disk as
# the target; asserts BLUEBERRY_INSTALL=OK on serial, then boots the installed
# disk and asserts it reaches multi-user with a login prompt.
#
# Usage: tools/test/test-install.sh <installer.iso>   (desktop or server payload)
set -u

ISO=${1:?usage: $0 <installer.iso>}
# Optional: pick the target filesystem (ext4 default | xfs | btrfs). Setting
# BLUEBERRY_TEST_FS=btrfs exercises the @/@home/@snapshots subvolume layout.
FSARG=""; [ -n "${BLUEBERRY_TEST_FS:-}" ] && FSARG="blueberry.fs=${BLUEBERRY_TEST_FS}"
BOOTDIR=${BOOTDIR:-$(dirname "$0")/../../../blueberry-build/boot}
WORK=${WORK:-$(dirname "$ISO")/../../blueberry-build/installtest}
[ -f "$ISO" ] || { echo "FAIL: ISO not found: $ISO"; exit 1; }
VMLINUZ="$BOOTDIR/vmlinuz"; INITRD="$BOOTDIR/initramfs.cpio.zst"
[ -f "$VMLINUZ" ] || { echo "FAIL: $VMLINUZ missing (run 'make install')"; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"
DISK="$WORK/target.qcow2"; ILOG="$WORK/install-serial.log"; BLOG="$WORK/boot-serial.log"
qemu-img create -f qcow2 "$DISK" 12G >/dev/null
ACCEL="-enable-kvm -cpu host"; [ -w /dev/kvm ] || ACCEL="-cpu max"

echo "[install-test] unattended install ($ISO)…"
timeout 900 qemu-system-x86_64 $ACCEL -m 3072 -smp 2 \
    -kernel "$VMLINUZ" -initrd "$INITRD" \
    -append "bbinstall blueberry.target=/dev/vda blueberry.bootloader=bios $FSARG blueberry.rootpw=blueberry blueberry.hostname=bbtest blueberry.user=blueberry blueberry.userpw=blueberry console=ttyS0,115200" \
    -cdrom "$ISO" -drive "file=$DISK,if=virtio,format=qcow2" \
    -nic user,model=virtio-net-pci \
    -serial "file:$ILOG" -display none -no-reboot

if ! grep -qaE "BLUEBERRY_INSTALL=OK|BLUEBERRY_INSTALL_EXIT=0" "$ILOG"; then
    echo "[install-test] FAIL — install did not complete. Serial tail:"
    tail -25 "$ILOG" | sed 's/\x1b\[[0-9;]*m//g'
    exit 1
fi
echo "[install-test] install OK — booting the INSTALLED disk…"

timeout 180 qemu-system-x86_64 $ACCEL -m 3072 -smp 2 \
    -drive "file=$DISK,if=virtio,format=qcow2" -boot c \
    -serial "file:$BLOG" -display none -no-reboot &
QP=$!
for i in $(seq 1 55); do
    sleep 3
    if grep -qaE "login:|Reached target Multi-User System" "$BLOG" 2>/dev/null; then
        RESULT=multiuser; break
    fi
done
# Give the system time to settle before tearing the VM down: multi-user.target
# prints while its wants are still starting, and services with Restart=on-failure
# (e.g. dbus racing its first start) need a restart cycle (RestartSec ~5s) to
# recover. Without this we'd snapshot a transient failure and misreport it.
[ "${RESULT:-none}" = multiuser ] && sleep 18
kill -9 $QP 2>/dev/null; wait 2>/dev/null

if [ "${RESULT:-none}" != multiuser ]; then
    echo "[install-test] FAIL — installed disk did not reach a ready target. Serial tail:"
    tail -25 "$BLOG" | sed 's/\x1b\[[0-9;]*m//g'
    exit 1
fi
echo "[install-test] reached multi-user — checking service health…"

# strip ANSI once for the health greps
CLEAN="$WORK/boot-clean.log"; sed 's/\x1b\[[0-9;]*m//g' "$BLOG" > "$CLEAN"

# Recovery-aware failed-unit check (mirrors `systemctl is-system-running`): a unit
# that printed "Failed to start/mount X" but *later* reached "Started/Mounted X"
# was recovered by Restart= and is healthy — only a unit left in a failed state
# is a real problem. We collect the failed descriptions and subtract recovered.
genuine=
while IFS= read -r desc; do
    [ -n "$desc" ] || continue
    grep -qaF "Started $desc." "$CLEAN" && continue    # service recovered
    grep -qaF "Mounted $desc." "$CLEAN" && continue     # mount recovered
    genuine="$genuine
    - $desc"
done <<EOF
$(grep -aoE "Failed to (start|mount) [^.]+" "$CLEAN" | sed -E 's/^Failed to (start|mount) //' | sort -u)
EOF
if [ -n "$genuine" ]; then
    echo "[install-test] FAIL — service(s) left in a failed state on the installed system:$genuine"
    echo "  (transient failures that later recovered via Restart= are ignored)"
    exit 1
fi

# Positively confirm the two services the server image enables actually came up.
miss=
grep -qaE "Started OpenSSH server daemon|Reached target .*Login|sshd" "$CLEAN" || miss="$miss sshd"
grep -qaE "Started Network Configuration|Reached target Network|systemd-networkd" "$CLEAN" || miss="$miss networkd"
if [ -n "$miss" ]; then
    echo "[install-test] FAIL — expected service(s) never started:$miss"
    echo "  (serial log had no start marker; tail below)"
    tail -25 "$CLEAN"
    exit 1
fi

echo "[install-test] PASS — installed disk reached multi-user; sshd + networkd up, no failed units"
