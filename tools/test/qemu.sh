#!/bin/bash
# qemu.sh - boot the Blueberry kernel + initramfs in QEMU.
#
#   tools/test/qemu.sh run     live CLI, serial on your terminal
#   tools/test/qemu.sh test    headless self-test, wants BLUEBERRY_TEST=PASS
#
#   BOOTDIR   where vmlinuz + initramfs.cpio.zst are (default ../blueberry-build/boot)
#   ARCH      x86_64, the only one
#   MEM       guest RAM (default 512M)
#   DISK      run mode only: attach a persistent /dev/sda of this size (4G) to
#             try bb-install on. empty/"none" = no disk, all in RAM.
#             DISK_IMG sets the image path.
#   SSH_PORT  host port forwarded to guest :22 (default 2222)
#   TIMEOUT   test mode timeout in seconds (default 90)

set -euo pipefail

MODE="${1:-run}"
TOPDIR="$(cd "$(dirname "$0")/../.." && pwd)"
BOOTDIR="${BOOTDIR:-$(cd "$TOPDIR/.." && pwd)/blueberry-build/boot}"
ARCH="${ARCH:-x86_64}"
MEM="${MEM:-512M}"
TIMEOUT="${TIMEOUT:-90}"

KERNEL="$BOOTDIR/vmlinuz"
INITRD="$BOOTDIR/initramfs.cpio.zst"

case "$ARCH" in
    x86_64)
        QEMU=qemu-system-x86_64
        MACHINE_ARGS=()
        CONSOLE="ttyS0"
        [ -w /dev/kvm ] && MACHINE_ARGS+=(-enable-kvm -cpu host)
        ;;
    *)
        echo "qemu.sh: unsupported ARCH=$ARCH (x86_64 only)" >&2; exit 1 ;;
esac

command -v "$QEMU" >/dev/null || { echo "ERROR: $QEMU not found, install QEMU"; exit 1; }
[ -f "$KERNEL" ] || { echo "ERROR: $KERNEL not found, run 'make kernel'";     exit 1; }
[ -f "$INITRD" ] || { echo "ERROR: $INITRD not found, run 'make initramfs'";  exit 1; }

# user-mode net: SLIRP's DHCP hands out 10.0.2.15, no host setup needed.
# e1000 because virtio-net made QEMU exit silently with this kernel.
# ssh -p 2222 root@localhost reaches the guest.
SSH_PORT="${SSH_PORT:-2222}"
NET_ARGS=(-nic "user,model=e1000,hostfwd=tcp::${SSH_PORT}-:22")

# stop the built-in bonding/dummy drivers from creating bond0/dummy0.
# same as the ISO and disk image cmdlines.
HW_QUIET="bonding.max_bonds=0 dummy.numdummies=0"

case "$MODE" in
run)
    # no disk unless DISK= is set; the image is created once and reused
    DISK_ARGS=()
    DISK_SIZE="${DISK:-}"
    case "$DISK_SIZE" in ""|none|no|0) DISK_SIZE="" ;; esac
    if [ -n "$DISK_SIZE" ]; then
        DISK_IMG="${DISK_IMG:-$(dirname "$BOOTDIR")/run-disk.qcow2}"
        if [ ! -f "$DISK_IMG" ]; then
            echo "[qemu] creating $DISK_SIZE disk: $DISK_IMG"
            qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE" >/dev/null
        fi
        DISK_ARGS=(-drive "file=$DISK_IMG,if=none,format=qcow2,id=hd0"
                   -device ahci,id=ahci -device ide-hd,drive=hd0,bus=ahci.0)
    fi
    echo "[qemu] booting Blueberry live CLI ($ARCH), Ctrl-A X to quit"
    echo "[qemu] SSH:  ssh -p ${SSH_PORT} root@localhost   (password: blueberry)"
    if [ -n "$DISK_SIZE" ]; then
        echo "[qemu] disk: $DISK_IMG ($DISK_SIZE) -> /dev/sda  (run 'bb-install' to install)"
    else
        echo "[qemu] disk: none (set DISK=4G to attach an install target)"
    fi
    echo "----------------------------------------------------------"
    exec "$QEMU" "${MACHINE_ARGS[@]}" "${NET_ARGS[@]}" "${DISK_ARGS[@]}" \
        -kernel "$KERNEL" -initrd "$INITRD" \
        -append "console=$CONSOLE $HW_QUIET" \
        -m "$MEM" -no-reboot \
        -nographic
    ;;

test)
    LOG="$(mktemp -t blueberry-test.XXXXXX.log)"
    echo "[qemu] booting headless self-test ($ARCH, timeout ${TIMEOUT}s)"
    echo "----------------------------------------------------------"

    touch "$LOG"
    "$QEMU" "${MACHINE_ARGS[@]}" "${NET_ARGS[@]}" \
        -kernel "$KERNEL" -initrd "$INITRD" \
        -append "console=$CONSOLE bbtest quiet $HW_QUIET" \
        -m "$MEM" -no-reboot \
        -display none -serial "file:$LOG" -monitor none &
    QEMU_PID=$!

    tail -n +1 -f "$LOG" & TAIL_PID=$!

    # kill QEMU ourselves as soon as the verdict shows up. ACPI poweroff
    # under QEMU is flaky, and this is faster anyway
    deadline=$(( $(date +%s) + TIMEOUT ))
    while kill -0 "$QEMU_PID" 2>/dev/null; do
        if grep -q "BLUEBERRY_TEST=" "$LOG"; then break; fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "[qemu] timeout after ${TIMEOUT}s" >&2; break
        fi
        sleep 0.5
    done

    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    kill "$TAIL_PID" 2>/dev/null || true
    sleep 0.2

    echo "----------------------------------------------------------"
    if grep -q "BLUEBERRY_TEST=PASS" "$LOG"; then
        echo "[qemu] RESULT: PASS"
        rm -f "$LOG"
        exit 0
    fi
    echo "[qemu] RESULT: FAIL"
    echo "  serial log saved to: $LOG"
    exit 1
    ;;

*)
    echo "usage: $0 {run|test}" >&2; exit 1 ;;
esac
