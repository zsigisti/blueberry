#!/bin/sh
# boot-iso.sh — boot a Blueberry ISO in QEMU, interactively (run) or as a
# headless pass/fail test that waits for the edition's "ready" marker on the
# serial console. Shared by `make run-*` and `make test-*`.
#
# Usage:
#   boot-iso.sh run  <iso> [server|desktop]   # windowed, interactive
#   boot-iso.sh test <iso> <server|desktop>   # headless, assert ready, exit 0/1
#
# QEMU needs -cpu host: the desktop's software GL (llvmpipe) and modern guests
# assume AVX, which the default qemu64 CPU lacks.
set -eu
MODE=${1:?usage: boot-iso.sh run|test <iso> [edition]}
ISO=${2:?need iso path}
EDITION=${3:-server}
[ -f "$ISO" ] || { echo "boot-iso: no such ISO: $ISO" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "boot-iso: qemu-system-x86_64 not found" >&2; exit 1; }

MEM=2048; SMP=2; VGA="-vga std"
if [ "$EDITION" = desktop ]; then MEM=4096; SMP=4; VGA="-vga virtio"; fi
ACCEL=""; [ -e /dev/kvm ] && ACCEL="-enable-kvm -cpu host"

case "$MODE" in
run)
    if [ "$EDITION" = desktop ]; then
        echo "[run] booting $EDITION ISO in QEMU (close the window or Ctrl-A X to quit)"
        exec qemu-system-x86_64 $ACCEL -m "$MEM" -smp "$SMP" -cdrom "$ISO" $VGA -boot d
    fi
    # Server is headless: route the serial console to this terminal (-nographic).
    # The ISO autologins root on ttyS0, so it drops straight to a shell. Ctrl-A X
    # quits.
    echo "[run] booting $EDITION ISO headless on serial (Ctrl-A X to quit)"
    exec qemu-system-x86_64 $ACCEL -m "$MEM" -smp "$SMP" -cdrom "$ISO" \
        -nographic -boot d
    ;;
test)
    # ready marker per edition
    if [ "$EDITION" = desktop ]; then
        MARKER='Reached target Graphical Interface'; FAILRE='Attempted to kill init|Failed to mount.*sysroot|Kernel panic'
    else
        MARKER='Reached target Multi-User System'; FAILRE='Attempted to kill init|Kernel panic|emergency mode'
    fi
    WORK=$(mktemp -d); SER="$WORK/serial.log"; trap 'rm -rf "$WORK"' EXIT
    echo "[test] booting $EDITION ISO headless (marker: \"$MARKER\")"
    setsid qemu-system-x86_64 $ACCEL -m "$MEM" -smp "$SMP" -cdrom "$ISO" \
        -display none -serial "file:$SER" -boot d >/dev/null 2>&1 &
    QPID=$!
    # systemd colourises unit names, so strip ANSI escapes before matching or
    # the literal marker is broken mid-word by colour codes.
    deansi() { sed 's/\x1b\[[0-9;:]*m//g' "$SER" 2>/dev/null; }
    i=0; rc=1
    while [ $i -lt 180 ]; do
        if deansi | grep -qE "$FAILRE"; then echo "[test] FAIL — boot error:"; deansi | grep -E "$FAILRE" | head -1; rc=1; break; fi
        if deansi | grep -q "$MARKER"; then echo "[test] PASS — reached: $MARKER"; rc=0; break; fi
        sleep 1; i=$((i+1))
    done
    kill "$QPID" 2>/dev/null || true
    [ $rc -eq 0 ] || { echo "[test] last serial lines:"; tail -15 "$SER" 2>/dev/null | sed 's/\x1b\[[0-9;:]*m//g'; }
    exit $rc
    ;;
*) echo "boot-iso: unknown mode '$MODE'" >&2; exit 2 ;;
esac
