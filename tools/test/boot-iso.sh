#!/bin/sh
# boot-iso.sh - boot a Blueberry ISO in QEMU, either to play with (run) or as a
# headless pass/fail test that waits for the edition's ready marker on serial.
# Used by `make run-*` and `make test-*`.
#
#   boot-iso.sh run  <iso> [server|desktop|install]   # interactive
#   boot-iso.sh test <iso> <server|desktop>           # headless, exit 0/1
#
# KVM gets -cpu host: llvmpipe on the desktop and modern guests in general
# want AVX, which qemu64 doesn't have.
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
        # Calamares wants a target disk or it complains about drive space.
        # reused across runs, so you can install once and boot it with -boot c
        DISK=${BLUEBERRY_DISK:-${ISO%.iso}-disk.qcow2}
        SIZE=${BLUEBERRY_DISK_SIZE:-20G}
        if [ ! -f "$DISK" ]; then
            echo "[run] creating $SIZE installer target disk: $DISK"
            qemu-img create -f qcow2 "$DISK" "$SIZE" >/dev/null
        fi
        echo "[run] booting $EDITION ISO in QEMU (close the window or Ctrl-A X to quit)"
        echo "[run] install target: $DISK  (boot the installed system with: -boot c)"
        exec qemu-system-x86_64 $ACCEL -m "$MEM" -smp "$SMP" -cdrom "$ISO" \
            -drive file="$DISK",if=virtio,format=qcow2 $VGA -boot d
    fi
    if [ "$EDITION" = install ]; then
        # same live shell as the server ISO, but blueberry-install needs a
        # blank disk to install onto. reused across runs.
        DISK=${BLUEBERRY_DISK:-${ISO%.iso}-target.qcow2}
        SIZE=${BLUEBERRY_DISK_SIZE:-20G}
        if [ ! -f "$DISK" ]; then
            echo "[run] creating $SIZE install target disk: $DISK"
            qemu-img create -f qcow2 "$DISK" "$SIZE" >/dev/null
        fi
        echo "[run] installer ISO, blank target disk attached: $DISK"
        echo "[run] at the shell, run:  blueberry-install        (full-screen TUI)"
        echo "[run]                 or:  blueberry-install --cli  (serial-safe prompts)"
        echo "[run] when it finishes: quit (Ctrl-A X), then boot the INSTALLED disk with:"
        echo "[run]   qemu-system-x86_64 -enable-kvm -m 2048 -drive file=$DISK,if=virtio,format=qcow2 -boot c"
        echo "[run] booting installer ISO headless on serial (Ctrl-A X to quit)"
        # shellcheck disable=SC2086
        exec qemu-system-x86_64 $ACCEL -m "$MEM" -smp "$SMP" -cdrom "$ISO" \
            -drive file="$DISK",if=virtio,format=qcow2 -nographic -boot d
    fi
    # server: serial on this terminal, root autologin on ttyS0 drops you in a shell
    NET=""
    if [ -n "${CONSOLE_FWD:-}" ]; then
        if [ -n "${BRIDGE:-}" ]; then
            # VM gets its own LAN IP. needs a host bridge + qemu-bridge-helper
            NET="-nic bridge,br=${BRIDGE},model=e1000"
            echo "[run] bridged on ${BRIDGE}: the VM gets its own LAN IP,"
            echo "      run 'ip a' in the VM, then browse to  https://<vm-ip>:9090"
        else
            # NAT, with forwards on all host interfaces so the LAN reaches the
            # console through this host's IP. BRIDGE=<iface> for a real VM IP.
            NET="-nic user,model=e1000,hostfwd=tcp:0.0.0.0:2222-:22,hostfwd=tcp:0.0.0.0:9090-:9090"
            hostip=$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')
            echo "[run] LAN access via this host: browse to  https://${hostip:-<host-ip>}:9090"
        fi
        echo "[run] first, in the VM shell, install + start the console:"
        echo "      bpm install -y blueberry-console && systemctl enable --now blueberry-console"
    fi
    echo "[run] booting $EDITION ISO headless on serial (Ctrl-A X to quit)"
    # shellcheck disable=SC2086
    exec qemu-system-x86_64 $ACCEL -m "$MEM" -smp "$SMP" -cdrom "$ISO" \
        $NET -nographic -boot d
    ;;
test)
    if [ "$EDITION" = desktop ]; then
        MARKER='Reached target Graphical Interface'; FAILRE='Attempted to kill init|Failed to mount.*sysroot|Kernel panic'
    else
        # `quiet` hides the target line, so the getty prompt counts too (getty
        # only starts once multi-user.target is up)
        MARKER='Reached target Multi-User System|blueberry login:'; FAILRE='Attempted to kill init|Kernel panic|emergency mode'
    fi
    WORK=$(mktemp -d); SER="$WORK/serial.log"; trap 'rm -rf "$WORK"' EXIT
    echo "[test] booting $EDITION ISO headless (marker: \"$MARKER\")"
    setsid qemu-system-x86_64 $ACCEL -m "$MEM" -smp "$SMP" -cdrom "$ISO" \
        -display none -serial "file:$SER" -boot d >/dev/null 2>&1 &
    QPID=$!
    # systemd colours unit names, which splits the marker with escape codes
    deansi() { sed 's/\x1b\[[0-9;:]*m//g' "$SER" 2>/dev/null; }
    i=0; rc=1
    while [ $i -lt 180 ]; do
        if deansi | grep -qE "$FAILRE"; then echo "[test] FAIL - boot error:"; deansi | grep -E "$FAILRE" | head -1; rc=1; break; fi
        if deansi | grep -qE "$MARKER"; then echo "[test] PASS - reached: $MARKER"; rc=0; break; fi
        sleep 1; i=$((i+1))
    done
    kill "$QPID" 2>/dev/null || true
    [ $rc -eq 0 ] || { echo "[test] last serial lines:"; tail -15 "$SER" 2>/dev/null | sed 's/\x1b\[[0-9;:]*m//g'; }
    exit $rc
    ;;
*) echo "boot-iso: unknown mode '$MODE'" >&2; exit 2 ;;
esac
