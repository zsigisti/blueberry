#!/bin/sh
# test-install.sh — automated end-to-end Desktop install smoke-test.
#
# Boots the Desktop live ISO headless with a blank target disk, drives Calamares
# through a default "erase disk" install via the QEMU monitor (button
# accelerators + typed user fields), captures a screenshot at every step, then
# boots the *installed disk* and asserts it reaches graphical.target.
#
# This is a smoke-test, not a fuzzer: it exercises the real path the user clicks
# (welcome→locale→keyboard→partition→users→summary→install→reboot) so the
# unpack→GRUB→fstab→first-boot chain is actually verified once.
#
# Usage: tools/test-install.sh [ISO]
#   ISO   desktop ISO (default: iso/blueberry-desktop-26.10-kde-x86_64.iso)
# Env:
#   WORK        scratch dir (default: ../blueberry-build/installtest)
#   BOOT_WAIT   seconds to wait for boot→Plasma→Calamares (default 180)
#   INSTALL_WAIT seconds to wait for unpackfs+config to finish (default 600)
#   USER_NAME / USER_PASS  the account Calamares creates (default blueberry/blueberry)
set -eu

TOPDIR=$(cd "$(dirname "$0")/.." && pwd)
ISO=${1:-$TOPDIR/iso/blueberry-desktop-26.10-kde-x86_64.iso}
WORK=${WORK:-$TOPDIR/../blueberry-build/installtest}
BOOT_WAIT=${BOOT_WAIT:-180}
INSTALL_WAIT=${INSTALL_WAIT:-600}
USER_NAME=${USER_NAME:-blueberry}
USER_PASS=${USER_PASS:-blueberry}
DISK="$WORK/target.qcow2"
MON="$WORK/monitor.sock"
SHOTS="$WORK/shots"
SERIAL="$WORK/disk-serial.log"
LIVESERIAL="$WORK/live-serial.log"   # blueberry-install tees calamares -d here

[ -f "$ISO" ] || { echo "test-install: no ISO at $ISO (run 'make desktop-iso')" >&2; exit 2; }
for t in qemu-system-x86_64 socat qemu-img; do
    command -v "$t" >/dev/null 2>&1 || { echo "test-install: need $t" >&2; exit 2; }
done

rm -rf "$WORK"; mkdir -p "$SHOTS"
qemu-img create -f qcow2 "$DISK" 20G >/dev/null
ACCEL=""; [ -e /dev/kvm ] && ACCEL="-enable-kvm -cpu host"

mon() { printf '%s\n' "$*" | socat - "unix-connect:$MON" >/dev/null 2>&1 || true; }
shot() { mon "screendump $SHOTS/$1.ppm"; }
# type an ASCII string as individual sendkey events (lowercase/digits only)
typestr() { s=$1; i=0; while [ $i -lt ${#s} ]; do c=$(printf '%s' "$s" | cut -c$((i+1))); mon "sendkey $c"; i=$((i+1)); sleep 0.05; done; }
key() { mon "sendkey $1"; sleep 0.4; }
# Absolute mouse click at screen pixel (x y) — usb-tablet maps to 0..32767.
SW=1280; SH=800
click() {
    ax=$(( $1 * 32767 / SW )); ay=$(( $2 * 32767 / SH ))
    mon "mouse_move $ax $ay 0"; sleep 0.3
    mon "mouse_button 1"; sleep 0.2; mon "mouse_button 0"; sleep 0.4
}

echo "[install-test] booting live ISO with blank disk (headless)…"
: > "$LIVESERIAL"
qemu-system-x86_64 $ACCEL -m 4096 -smp 4 \
    -cdrom "$ISO" -drive file="$DISK",if=virtio,format=qcow2 \
    -vga virtio -display none -vnc :21 \
    -serial "file:$LIVESERIAL" -nic user,model=virtio-net-pci \
    -device usb-ehci -device usb-tablet \
    -monitor "unix:$MON,server,nowait" -boot d &
QPID=$!
trap 'kill $QPID 2>/dev/null || true' EXIT

# Wait for boot → SDDM autologin → Plasma → Calamares autostart.
echo "[install-test] waiting ${BOOT_WAIT}s for Plasma + Calamares…"
i=0; while [ $i -lt "$BOOT_WAIT" ]; do sleep 10; i=$((i+10)); [ -S "$MON" ] && shot "boot-$i"; done
shot "01-welcome"

echo "[install-test] driving Calamares (erase-disk default install)…"
# Drive by CLICKING the Next button (same screen position on every page) with
# generous waits — blind accelerator keys get dropped while the partition page
# scans the disk. Next/Install/Done button centre ≈ (1007,657) at 1280x800.
NEXT_X=1007; NEXT_Y=657
click 640 400                  # focus the Calamares window first
click $NEXT_X $NEXT_Y; sleep 8;  shot "02-locale"
click $NEXT_X $NEXT_Y; sleep 8;  shot "03-keyboard"
click $NEXT_X $NEXT_Y; sleep 12; shot "04-partition"   # partition: scans disk, slow
click $NEXT_X $NEXT_Y; sleep 10; shot "05-users"
# Users page: click the name field, type (auto-fills login/hostname), then Tab to
# the password fields. Field Y positions are approximate for this branding.
click 700 250; sleep 0.5; typestr "$USER_NAME"; sleep 0.5
key "tab"; key "tab"; key "tab"                        # name→login→hostname→password
typestr "$USER_PASS"; key "tab"; typestr "$USER_PASS"
sleep 0.5; shot "06-users-filled"
click $NEXT_X $NEXT_Y; sleep 6;  shot "07-summary"
click $NEXT_X $NEXT_Y; sleep 4;  shot "08-confirm"     # → Install
key "ret"; click $NEXT_X $NEXT_Y; sleep 4; shot "09-confirm2"  # confirm "Install now"

echo "[install-test] installing — polling disk growth (≤${INSTALL_WAIT}s)…"
last=0; stable=0; i=0
while [ $i -lt "$INSTALL_WAIT" ]; do
    sleep 20; i=$((i+20)); shot "10-install-$i"
    cur=$(qemu-img info "$DISK" 2>/dev/null | awk '/disk size/{print $3}')
    sz=$(stat -c%s "$DISK" 2>/dev/null || echo 0)
    echo "  …${i}s disk=${sz}B"
    if [ "$sz" = "$last" ]; then stable=$((stable+1)); else stable=0; fi
    last=$sz
    # stable for ~60s after writing >1.5G ≈ unpackfs done + config finishing
    [ $stable -ge 3 ] && [ "$sz" -gt 1500000000 ] && break
done
sleep 20; shot "11-finished"

# Surface what Calamares actually did (it tees `calamares -d` to the serial).
echo "[install-test] Calamares view-step / error highlights:"
sed 's/\x1b\[[0-9;:]*m//g' "$LIVESERIAL" 2>/dev/null \
    | grep -iE "ViewModule .* loading|Running step|requirement|fatal|crash|terminate|installation (failed|complete)|Unpack|bootloader" \
    | tail -25 | sed 's/^/    /' || true

echo "[install-test] powering off the VM…"
mon "system_powerdown"; sleep 8; kill $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true
trap - EXIT

echo "[install-test] booting the INSTALLED disk (no CD)…"
: > "$SERIAL"
qemu-system-x86_64 $ACCEL -m 4096 -smp 4 \
    -drive file="$DISK",if=virtio,format=qcow2 \
    -vga virtio -display none -vnc :22 \
    -serial "file:$SERIAL" -nic user,model=virtio-net-pci -boot c &
DPID=$!
trap 'kill $DPID 2>/dev/null || true' EXIT
deansi() { sed 's/\x1b\[[0-9;:]*m//g' "$SERIAL" 2>/dev/null; }
i=0; rc=1
while [ $i -lt 180 ]; do
    sleep 5; i=$((i+5))
    if deansi | grep -qiE "Reached target Graphical Interface|Reached target .*graphical|Starting SDDM|sddm-greeter"; then
        echo "[install-test] PASS — installed disk reached the graphical target"; rc=0; break
    fi
    if deansi | grep -qiE "Kernel panic|Attempted to kill init|Failed to mount.*sysroot|Cannot open root"; then
        echo "[install-test] FAIL — installed disk failed to boot:"; deansi | grep -iE "panic|kill init|Failed to mount|Cannot open root" | head -2; break
    fi
done
kill $DPID 2>/dev/null || true; trap - EXIT
[ $rc -eq 0 ] || { echo "[install-test] last serial lines:"; tail -20 "$SERIAL" 2>/dev/null | sed 's/\x1b\[[0-9;:]*m//g'; }
echo "[install-test] screenshots: $SHOTS"
exit $rc
