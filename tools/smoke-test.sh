#!/bin/bash
# tools/smoke-test.sh — boot Blueberry in QEMU and verify SMOKE_TEST_RESULT=PASS
#
# Usage (called by 'make smoke-test'):
#   tools/smoke-test.sh
#
# Environment:
#   OBJDIR   — build output dir  (default: ../blueberry-build relative to repo root)
#   TOPDIR   — repo root         (default: directory containing this script's parent)
#   ARCH     — x86_64 or aarch64 (default: x86_64)
#   TIMEOUT  — seconds to wait   (default: 120)

set -euo pipefail

TOPDIR="$(cd "$(dirname "$0")/.." && pwd)"
OBJDIR="${OBJDIR:-$(cd "$TOPDIR/.." && pwd)/blueberry-build}"
ARCH="${ARCH:-x86_64}"
TIMEOUT="${TIMEOUT:-120}"

BOOTDIR="$OBJDIR/boot"
REPODIR="$OBJDIR/repo"
TEST_INIT="$TOPDIR/src/initramfs/test-init"
WORK_DIR="/tmp/blueberry-smoke-$$"
TEST_CPIO="$WORK_DIR/test.cpio.zst"
LOG="$WORK_DIR/qemu.log"

# ── Prerequisites ─────────────────────────────────────────────────────────────
for tool in qemu-system-x86_64 zstd cpio python3; do
    command -v "$tool" >/dev/null || { echo "ERROR: $tool not found — install it first"; exit 1; }
done

[ -f "$BOOTDIR/vmlinuz" ] || {
    echo "ERROR: $BOOTDIR/vmlinuz not found"
    echo "  Run 'make world' first (or 'make kernel' if you only need the kernel)"
    exit 1
}
[ -f "$BOOTDIR/initramfs.cpio.zst" ] || {
    echo "ERROR: $BOOTDIR/initramfs.cpio.zst not found — run 'make initramfs'"
    exit 1
}
[ -f "$TEST_INIT" ] || {
    echo "ERROR: $TEST_INIT not found — is this a complete source tree?"
    exit 1
}

# ── Build test initramfs ──────────────────────────────────────────────────────
echo "[smoke-test] building test initramfs..."
mkdir -p "$WORK_DIR/root"
zstd -d < "$BOOTDIR/initramfs.cpio.zst" | cpio -id --quiet -D "$WORK_DIR/root"
cp "$TEST_INIT" "$WORK_DIR/root/test-init"
chmod 755 "$WORK_DIR/root/test-init"
(cd "$WORK_DIR/root" && find . | sort | cpio -H newc -o --quiet | zstd -19 -q > "$TEST_CPIO")
echo "[smoke-test] test initramfs: $TEST_CPIO ($(du -sh "$TEST_CPIO" | cut -f1))"

# ── Ensure packages are built ─────────────────────────────────────────────────
if [ ! -f "$REPODIR/BBINDEX.zst" ]; then
    echo "[smoke-test] no package repo found — running 'make repo'..."
    make -C "$TOPDIR" repo OBJDIR="$OBJDIR"
fi

# ── Start HTTP server for packages ───────────────────────────────────────────
# Find a free port starting at 8080
HTTP_PORT=8080
while ss -tlnp 2>/dev/null | grep -q ":$HTTP_PORT "; do
    HTTP_PORT=$((HTTP_PORT + 1))
done
python3 -m http.server "$HTTP_PORT" --directory "$REPODIR" \
    --bind 127.0.0.1 > "$WORK_DIR/http.log" 2>&1 &
HTTP_PID=$!
trap 'kill $HTTP_PID 2>/dev/null; rm -rf "$WORK_DIR"' EXIT

# QEMU user networking: guest sees the host as 10.0.2.2, any port on 127.0.0.1
# maps in via the hostfwd or just directly since 10.0.2.2 is the SLIRP gateway.
# We need the HTTP server accessible at 10.0.2.2:$HTTP_PORT inside the guest.
# QEMU SLIRP always forwards 10.0.2.2 → host 127.0.0.1, so this works.
BPMREPO="http://10.0.2.2:$HTTP_PORT"

echo "[smoke-test] package server: $BPMREPO"
echo "[smoke-test] booting QEMU (timeout ${TIMEOUT}s)..."
echo "─────────────────────────────────────────────────────────"

# ── Boot ─────────────────────────────────────────────────────────────────────
timeout "$TIMEOUT" qemu-system-x86_64 \
    -kernel "$BOOTDIR/vmlinuz" \
    -initrd "$TEST_CPIO" \
    -append "console=ttyS0 init=/test-init BPMREPO=$BPMREPO" \
    -nographic -no-reboot -m 512M \
    -net nic,model=virtio -net user \
    2>&1 | tee "$LOG" || true

echo "─────────────────────────────────────────────────────────"

# ── Result ───────────────────────────────────────────────────────────────────
if grep -q "SMOKE_TEST_RESULT=PASS" "$LOG"; then
    echo ""
    echo "[smoke-test] RESULT: PASS"
    exit 0
else
    echo ""
    echo "[smoke-test] RESULT: FAIL"
    echo "  Last 20 lines of boot log:"
    tail -20 "$LOG" | sed 's/^/  /'
    echo ""
    echo "  Full log: $LOG (note: cleaned up on exit)"
    exit 1
fi
