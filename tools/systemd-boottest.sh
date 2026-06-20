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

if [ "${SELFTEST:-0}" = 1 ]; then
    step "inject functional self-test (systemctl/networkd/journald/dbus + bpm)"
    install -Dm755 /dev/stdin "$R/usr/local/bin/blueberry-selftest.sh" <<'EOS'
#!/bin/sh
exec >/dev/console 2>&1
echo "==SYSTEMD_SELFTEST_START=="
echo "[is-system-running] $(systemctl is-system-running 2>&1)"
for u in systemd-journald dbus systemd-logind systemd-networkd systemd-resolved systemd-timesyncd sshd; do
    echo "[active:$u] $(systemctl is-active $u.service 2>&1)"
done
echo "[failed-units]"; systemctl --failed --no-legend --plain 2>&1 | sed 's/^/   /'
echo "[messagebus-user] $(getent passwd messagebus 2>&1 || grep messagebus /etc/passwd 2>&1 || echo MISSING)"
echo "[dbus-status]"; systemctl status dbus.service --no-pager -l 2>&1 | sed -n '1,8p' | sed 's/^/   /'
echo "[dbus-journal]"; journalctl -u dbus.service -b --no-pager 2>&1 | tail -8 | sed 's/^/   /'
echo "[ip-addr]"; ip addr show 2>&1 | grep -E 'inet |state ' | sed 's/^/   /'
echo "[networkctl]"; networkctl status --no-pager 2>&1 | grep -iE 'State|Address|Gateway|DNS' | sed 's/^/   /'
echo "[resolv.conf]"; cat /etc/resolv.conf 2>&1 | grep -v '^#' | sed 's/^/   /'
echo "[dns-resolve] $(resolvectl query repo.mmzsigmond.me 2>&1 | head -1)"
echo "[nslookup-glibc]"; nslookup repo.mmzsigmond.me 2>&1 | tail -3 | sed 's/^/   /'
echo "[tcp443] $(nc -w4 repo.mmzsigmond.me 443 </dev/null >/dev/null 2>&1 && echo reachable || echo UNREACHABLE)"
echo "[nsswitch] $(grep ^hosts /etc/nsswitch.conf 2>&1)"
echo "[clock] $(date -u 2>&1) | rtc=$(date -u 2>&1)"
echo "[journal-lines] $(journalctl --no-pager 2>/dev/null | wc -l)"
echo "[bpm-update]"; bpm update 2>&1 | tail -4 | sed 's/^/   /'
echo "[bpm-install-file]"; bpm install /opt/htop.pkg.tar.zst 2>&1 | tail -6 | sed 's/^/   /'
echo "[htop-version] $(htop --version 2>&1 | head -1)"
echo "[bpm-list-htop] $(bpm list 2>/dev/null | grep -i htop || echo 'not listed')"
echo "==SYSTEMD_SELFTEST_END=="
systemctl poweroff 2>/dev/null || { echo o >/proc/sysrq-trigger; }
EOS
    install -Dm644 /dev/stdin "$R/etc/systemd/system/blueberry-selftest.service" <<'EOS'
[Unit]
Description=Blueberry systemd self-test
After=network-online.target multi-user.target
Wants=network-online.target
[Service]
Type=oneshot
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/usr/local/bin/blueberry-selftest.sh
EOS
    mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/blueberry-selftest.service \
        "$R/etc/systemd/system/multi-user.target.wants/blueberry-selftest.service"
    # Stage a real package so the self-test can do an offline file install
    # (proves bpm extract/scriptlet/db works under systemd without the repo).
    htoppkg=$(ls -t "$BD"/basepkgs/htop-[0-9]*.pkg.tar.zst 2>/dev/null | head -1)
    if [ -n "$htoppkg" ]; then install -Dm644 "$htoppkg" "$R/opt/htop.pkg.tar.zst"; fi
fi

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
    -append "root=/dev/sda rootfstype=ext4 rw console=ttyS0,115200 systemd.unified_cgroup_hierarchy=1 systemd.show_status=1 ipv6.disable=1 bonding.max_bonds=0 dummy.numdummies=0" \
    -nographic -no-reboot > "$LOG" 2>&1
echo "=== QEMU EXIT rc=$? (ssh port was $PORT) ==="
