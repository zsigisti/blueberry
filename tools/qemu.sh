#!/bin/bash
# tools/qemu.sh — boot Blueberry's kernel + initramfs in QEMU.
#
# Usage:
#   tools/qemu.sh run     interactive live CLI (serial on your terminal)
#   tools/qemu.sh test    headless self-test; asserts BLUEBERRY_TEST=PASS
#
# Environment:
#   BOOTDIR   directory with vmlinuz + initramfs.cpio.zst
#             (default: ../blueberry-build/boot relative to this script)
#   ARCH      x86_64 (default)
#   MEM       guest RAM (default 512M)
#   TIMEOUT   seconds before the test run is killed (default 90)

set -euo pipefail

MODE="${1:-run}"
TOPDIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOTDIR="${BOOTDIR:-$(cd "$TOPDIR/.." && pwd)/blueberry-build/boot}"
ARCH="${ARCH:-x86_64}"
MEM="${MEM:-512M}"
TIMEOUT="${TIMEOUT:-90}"

KERNEL="$BOOTDIR/vmlinuz"
INITRD="$BOOTDIR/initramfs.cpio.zst"

# ── Per-arch QEMU invocation ──────────────────────────────────────────────────
case "$ARCH" in
    x86_64)
        QEMU=qemu-system-x86_64
        MACHINE_ARGS=()
        CONSOLE="ttyS0"
        # KVM is a big speedup when the host supports it; harmless to skip.
        [ -w /dev/kvm ] && MACHINE_ARGS+=(-enable-kvm -cpu host)
        ;;
    *)
        echo "qemu.sh: unsupported ARCH=$ARCH (x86_64 only)" >&2; exit 1 ;;
esac

# ── Prerequisites ─────────────────────────────────────────────────────────────
command -v "$QEMU" >/dev/null || { echo "ERROR: $QEMU not found — install QEMU"; exit 1; }
[ -f "$KERNEL" ] || { echo "ERROR: $KERNEL not found — run 'make kernel'";     exit 1; }
[ -f "$INITRD" ] || { echo "ERROR: $INITRD not found — run 'make initramfs'";  exit 1; }

# User-mode networking with an e1000 NIC. QEMU's SLIRP stack runs a DHCP server
# (hands the guest 10.0.2.15), so /init's udhcpc gets a real lease — networking
# works with zero host setup and no privileges. e1000 is used over virtio-net
# because virtio-net has caused silent QEMU exits in this kernel/QEMU combo.
# hostfwd maps host :2222 -> guest :22 so you can `ssh -p 2222 root@localhost`.
SSH_PORT="${SSH_PORT:-2222}"
NET_ARGS=(-nic "user,model=e1000,hostfwd=tcp::${SSH_PORT}-:22")

# Built-in bonding/dummy drivers each auto-create a device (bond0/dummy0) at
# init. Suppress them so only real NICs show up. Kept as a shared cmdline
# fragment so run/test match the ISO and disk-image boot configs.
HW_QUIET="bonding.max_bonds=0 dummy.numdummies=0"

case "$MODE" in
# ──────────────────────────────────────────────────────────────────────────────
run)
    echo "[qemu] booting Blueberry live CLI ($ARCH) — Ctrl-A X to quit"
    echo "[qemu] SSH:  ssh -p ${SSH_PORT} root@localhost   (password: blueberry)"
    echo "──────────────────────────────────────────────────────────"
    exec "$QEMU" "${MACHINE_ARGS[@]}" "${NET_ARGS[@]}" \
        -kernel "$KERNEL" -initrd "$INITRD" \
        -append "console=$CONSOLE $HW_QUIET" \
        -m "$MEM" -no-reboot \
        -nographic
    ;;

# ──────────────────────────────────────────────────────────────────────────────
test)
    LOG="$(mktemp -t blueberry-test.XXXXXX.log)"
    echo "[qemu] booting headless self-test ($ARCH, timeout ${TIMEOUT}s)"
    echo "──────────────────────────────────────────────────────────"

    touch "$LOG"
    "$QEMU" "${MACHINE_ARGS[@]}" "${NET_ARGS[@]}" \
        -kernel "$KERNEL" -initrd "$INITRD" \
        -append "console=$CONSOLE bbtest quiet $HW_QUIET" \
        -m "$MEM" -no-reboot \
        -display none -serial "file:$LOG" -monitor none &
    QEMU_PID=$!

    # Stream the serial log live while QEMU runs.
    tail -n +1 -f "$LOG" & TAIL_PID=$!

    # Poll the serial log: as soon as the self-test prints its verdict we
    # kill QEMU ourselves. This does not rely on the guest being able to
    # power itself off (ACPI poweroff is flaky under QEMU), and it keeps the
    # run fast — we stop the instant the result is known.
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

    echo "──────────────────────────────────────────────────────────"
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
