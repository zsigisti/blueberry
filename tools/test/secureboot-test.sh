#!/bin/bash
# secureboot-test.sh - own-keys Secure Boot under QEMU + OVMF, end to end.
#
# Generates a Blueberry key set, builds a signed and an unsigned disk image,
# enrolls the keys into an OVMF varstore with Secure Boot on, then checks:
#   - the signed image boots the kernel (firmware -> GRUB -> kernel verified)
#   - the unsigned one is refused by the firmware
#
# Signing happens in a throwaway container (sbsigntools .bpm, gnupg, grub,
# mtools). Enrolling and booting happen on the host: qemu, OVMF secboot
# firmware, and virt-fw-vars (pulled into a venv if it's missing).
set -euo pipefail

TOPDIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE=${ENGINE:-podman}
OUT="$TOPDIR/obj/bpm-out"
ROOTFS=${ROOTFS:-$(cd "$TOPDIR/.." && pwd)/blueberry-build/rootfs}
WORK=${WORK:-$TOPDIR/obj/secureboot-test}
export TMPDIR=${TMPDIR:-/tmp}

skip() { echo "[sb-test] SKIP: $*"; exit 0; }
fail() { echo "[sb-test] FAIL: $*"; exit 1; }

command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not found"
command -v "$ENGINE" >/dev/null || skip "$ENGINE not found"
[ -f "$ROOTFS/boot/vmlinuz" ] || skip "no rootfs kernel at $ROOTFS/boot/vmlinuz (run 'make install')"
ls "$OUT"/sbsigntools-*.bpm >/dev/null 2>&1 || skip "sbsigntools .bpm not built (bbdev build sbsigntools)"

# OVMF secboot firmware, code + vars template
CODE=""; for c in /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
                  /usr/share/edk2-ovmf/x64/OVMF_CODE.secboot.4m.fd \
                  /usr/share/OVMF/OVMF_CODE.secboot.fd \
                  /usr/share/OVMF/OVMF_CODE_4M.secboot.fd; do
    [ -f "$c" ] && { CODE="$c"; break; }
done
[ -n "$CODE" ] || skip "no OVMF secboot firmware found"
VARS=""; for v in "${CODE%CODE*}VARS.4m.fd" "${CODE%CODE*}VARS.fd" \
                  /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [ -f "$v" ] && { VARS="$v"; break; }
done
[ -n "$VARS" ] || skip "no OVMF_VARS template found"

# virt-fw-vars does the key enrollment
VFW=$(command -v virt-fw-vars || true)
if [ -z "$VFW" ]; then
    VENV="$WORK/vfw-venv"
    [ -x "$VENV/bin/virt-fw-vars" ] || {
        python3 -m venv "$VENV" 2>/dev/null || skip "python3 venv unavailable"
        "$VENV/bin/pip" install --quiet virt-firmware 2>/dev/null || skip "could not install virt-firmware (offline?)"
    }
    VFW="$VENV/bin/virt-fw-vars"
fi

rm -rf "$WORK"/keys "$WORK"/*.img "$WORK"/*.fd "$WORK"/*.log 2>/dev/null || true
mkdir -p "$WORK"

# 1. keygen + signed and unsigned images, in a container
echo "[sb-test] building signed + unsigned images (in $ENGINE)..."
"$ENGINE" run --rm --security-opt seccomp=unconfined \
    -v "$OUT:/o:ro,z" -v "$TOPDIR:/repo:ro,z" -v "$ROOTFS:/rootfs:ro,z" -v "$WORK:/work:z" \
    docker.io/library/archlinux:latest bash -c '
set -e
pacman -Syu --noconfirm --needed openssl gnupg util-linux grub mtools gptfdisk dosfstools e2fsprogs qemu-img zstd >/dev/null 2>&1
zstd -dcq /o/sbsigntools-*.bpm | tar -x -C / --exclude=.BPM
export BLUEBERRY_SB_KEYDIR=/work/keys
sh /repo/src/secureboot/blueberry-secureboot keygen >/dev/null 2>&1
mkdir -p /tmp/rf/boot; cp /rootfs/boot/vmlinuz /rootfs/boot/initramfs.cpio.zst /tmp/rf/boot/
SECUREBOOT_KEYDIR=/work/keys bash /repo/tools/image/mkdisk.sh /work/signed.img   /tmp/rf 1G >/dev/null 2>&1
                             bash /repo/tools/image/mkdisk.sh /work/unsigned.img /tmp/rf 1G >/dev/null 2>&1
chmod -R a+rX /work
' || fail "image signing step failed"
[ -f "$WORK/signed.img" ] && [ -f "$WORK/keys/db.crt" ] || fail "signing produced no image/keys"

# 2. enroll our keys, Secure Boot on
GUID=$(cat "$WORK/keys/GUID")
"$VFW" -i "$VARS" \
    --set-pk  "$GUID" "$WORK/keys/PK.crt" \
    --add-kek "$GUID" "$WORK/keys/KEK.crt" \
    --add-db  "$GUID" "$WORK/keys/db.crt" \
    --sb -o "$WORK/vars-enrolled.fd" >/dev/null 2>&1 || fail "virt-fw-vars enrollment failed"

boot() {  # boot <img> <varsfile> <logfile> <timeout>
    cp "$WORK/vars-enrolled.fd" "$2"
    timeout "$4" qemu-system-x86_64 \
        -machine q35,smm=on -m 1G -nographic \
        -global driver=cfi.pflash01,property=secure,value=on -global ICH9-LPC.disable_s3=1 \
        -drive if=pflash,format=raw,unit=0,readonly=on,file="$CODE" \
        -drive if=pflash,format=raw,unit=1,file="$2" \
        -drive file="$1",format=raw,if=virtio \
        -serial file:"$3" -display none >/dev/null 2>&1 || true
}
booted() { sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$1" | tr -d '\000' | grep -qaiE 'Linux version [0-9]|kernel [0-9].*-blueberry'; }

# 3. signed image has to boot
echo "[sb-test] booting SIGNED image (Secure Boot ON)..."
boot "$WORK/signed.img" "$WORK/vars-signed.fd" "$WORK/signed.log" 120
booted "$WORK/signed.log" || { echo "--- signed serial tail ---"; sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$WORK/signed.log" | tr -d '\000' | tail -15; fail "signed image did NOT boot the kernel under Secure Boot"; }
echo "[sb-test]   PASS - signed image booted the kernel"

# 4. unsigned image has to be refused
echo "[sb-test] booting UNSIGNED image (must be rejected)..."
boot "$WORK/unsigned.img" "$WORK/vars-unsigned.fd" "$WORK/unsigned.log" 60
if booted "$WORK/unsigned.log"; then fail "unsigned image booted the kernel under Secure Boot (rejection failed)"; fi
echo "[sb-test]   PASS - unsigned image was rejected by Secure Boot"

echo "[sb-test] PASS - own-keys Secure Boot verified: signed boots, unsigned rejected"
