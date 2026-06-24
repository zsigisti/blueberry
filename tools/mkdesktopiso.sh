#!/bin/bash
# mkdesktopiso.sh — build a live, Calamares-installable Blueberry Desktop ISO.
#
# Unlike the CLI mkiso.sh (which boots a RAM-only shell), this produces a live
# desktop: the kernel + initramfs mount a read-only squashfs of the full DE with
# a tmpfs overlay, systemd reaches graphical.target, SDDM auto-logs into the
# desktop, and "Install Blueberry Desktop" launches Calamares.
#
# Invoked by `make desktop-iso` (editions/desktop/profile.mk), which exports:
#   DE BBD_NAME BBD_VERSION BBD_FULLVERSION BBD_CODENAME BBD_CHANNEL
#   STAGEDIR DESKTOPDIR BOOTDIR ARCH
#
# Usage: tools/mkdesktopiso.sh <output.iso>
set -euo pipefail

OUTPUT=${1:?usage: $0 <output.iso>}
: "${DE:=kde}" "${STAGEDIR:?}" "${DESKTOPDIR:?}" "${BOOTDIR:?}" "${ARCH:=x86_64}"
: "${BBD_NAME:=Blueberry Desktop}" "${BBD_VERSION:=0.0}"
: "${BBD_FULLVERSION:=$BBD_VERSION}" "${BBD_CODENAME:=}" "${BBD_CHANNEL:=stable}"

log()  { printf '\033[1;35m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

# ── DE → display manager + live session mapping ───────────────────────────────
case "$DE" in
  kde)   DEFAULT_DM=sddm; LIVE_SESSION=plasma ;;
  gnome) DEFAULT_DM=gdm;  LIVE_SESSION=gnome  ;;
  *) die "unknown DE '$DE' (kde|gnome)" ;;
esac
VOLID="BLUEBERRY_$(echo "$BBD_VERSION" | tr -d .)"

# ── Tool checks ───────────────────────────────────────────────────────────────
command -v mksquashfs   >/dev/null || die "mksquashfs not found (squashfs-tools)"
command -v grub-mkrescue >/dev/null || die "grub-mkrescue not found (grub2)"
command -v xorriso      >/dev/null || die "xorriso not found"

VMLINUZ="$BOOTDIR/vmlinuz"
INITRD="$BOOTDIR/initramfs.cpio.zst"
[ -f "$VMLINUZ" ] || die "kernel missing: $VMLINUZ (run 'make install')"
[ -f "$INITRD"  ] || die "initramfs missing: $INITRD (run 'make install')"

# ── Sanity: is the desktop actually staged? ───────────────────────────────────
# The DE package tree is built incrementally; until SDDM and the compositor are
# present the ISO will boot but not reach a graphical session. Be explicit.
if [ ! -e "$STAGEDIR/usr/bin/sddm" ] && [ ! -e "$STAGEDIR/usr/bin/gdm" ]; then
    warn "no display manager found in the staged rootfs ($STAGEDIR)."
    warn "the $DE package tree is not built yet — this ISO will be a base"
    warn "system with the live/installer scaffolding but no graphical session."
    [ "${FORCE:-0}" = 1 ] || die "refusing to build a non-graphical 'desktop' ISO; set FORCE=1 to override."
fi

# Put WORK on the SAME filesystem as the output ISO so the hardlink-clone of the
# (multi-GB) rootfs is fast and, crucially, doesn't fall back to a cross-fs copy
# that nests the source dir inside liveroot.
WORK=$(mktemp -d "$(dirname "$OUTPUT")/.bbd-iso.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
LIVEROOT="$WORK/liveroot"
ISO_ROOT="$WORK/iso"
mkdir -p "$ISO_ROOT/boot/grub" "$ISO_ROOT/live" "$ISO_ROOT/EFI/BOOT" "$LIVEROOT"

# ── Assemble the live root (hardlink-clone the staged rootfs, then overlay) ────
# Copy CONTENTS (note the trailing /.) into the pre-created LIVEROOT so a fallback
# plain copy can never nest "$STAGEDIR" as a subdirectory.
log "cloning staged rootfs → live root"
cp -al "$STAGEDIR/." "$LIVEROOT/" 2>/dev/null || cp -a "$STAGEDIR/." "$LIVEROOT/"

log "laying down live-session overlay (DM=$DEFAULT_DM session=$LIVE_SESSION)"
cp -a "$DESKTOPDIR/live/." "$LIVEROOT/"

# The base install ships an /etc/fstab for an *installed* disk (/dev/sda1 root,
# /dev/sda2 swap). On the live medium those devices don't exist, so systemd
# blocks ~90s on dev-sda2.device and fails the swap + local-fs deps before the
# graphical target. Replace it with a live-only fstab (the overlay provides /).
log "writing live-only /etc/fstab (no /dev/sda*)"
cat > "$LIVEROOT/etc/fstab" <<'FSTAB'
# Live session — root is the squashfs+tmpfs overlay; nothing to mount from disk.
tmpfs   /tmp    tmpfs   nosuid,nodev,size=512M  0 0
FSTAB

# The live 'live' user (systemd-sysusers, uid 1000) needs a writable home for the
# autologin Plasma session; sysusers declares but does not create it.
mkdir -p "$LIVEROOT/home/live"
chown 1000:1000 "$LIVEROOT/home/live" 2>/dev/null || true

# Template the live session + DM placeholders.
find "$LIVEROOT/etc/sddm.conf.d" -type f -exec \
    sed -i "s/@@LIVE_SESSION@@/$LIVE_SESSION/g" {} + 2>/dev/null || true

# ── Calamares config into the live root ───────────────────────────────────────
log "installing Calamares config + branding"
mkdir -p "$LIVEROOT/etc/calamares"
cp -a "$DESKTOPDIR/calamares/settings.conf" "$LIVEROOT/etc/calamares/"
cp -a "$DESKTOPDIR/calamares/modules"        "$LIVEROOT/etc/calamares/"
cp -a "$DESKTOPDIR/calamares/branding"       "$LIVEROOT/etc/calamares/"
# Substitute branding + DM tokens everywhere they appear.
grep -rl '@@' "$LIVEROOT/etc/calamares" 2>/dev/null | while read -r f; do
    sed -i \
        -e "s/@@VERSION@@/$BBD_VERSION/g" \
        -e "s/@@FULLVERSION@@/$BBD_FULLVERSION/g" \
        -e "s/@@CODENAME@@/$BBD_CODENAME/g" \
        -e "s/@@DEFAULT_DM@@/$DEFAULT_DM/g" \
        "$f"
done

# ── systemd: /sbin/init, the graphical target, the DM ─────────────────────────
# The live-boot initramfs does `switch_root /mnt/root /sbin/init`, so a desktop
# (always systemd) rootfs MUST have /sbin/init → systemd. The base `install`
# may have staged a runit or no /sbin/init; force the systemd entry point here.
log "wiring /sbin/init → systemd + graphical target + $DEFAULT_DM"
[ -x "$LIVEROOT/usr/lib/systemd/systemd" ] || die "no systemd in the staged rootfs ($LIVEROOT/usr/lib/systemd/systemd)"
mkdir -p "$LIVEROOT/sbin" "$LIVEROOT/usr/sbin"
ln -sf /usr/lib/systemd/systemd "$LIVEROOT/sbin/init"
ln -sf /usr/lib/systemd/systemd "$LIVEROOT/usr/sbin/init" 2>/dev/null || true

# Merged-/usr for sbin: systemd unit ExecStarts use absolute /usr/sbin paths
# (mount, sulogin, …) but util-linux installs to /usr/bin. Link every /usr/bin
# tool into /usr/sbin when missing so remount-fs, sulogin, swap, etc. work.
# /bin/sh: the systemd base ships bash but NO sh, so the SDDM wayland-session
# script (#!/bin/sh) and plasma-dbus-run-session can't exec → the Plasma session
# dies ("Exec binary 'sh' does not exist") and SDDM cycles back to the greeter.
log "providing /bin/sh + /usr/bin/sh → bash"
[ -e "$LIVEROOT/usr/bin/sh" ]  || ln -sf bash "$LIVEROOT/usr/bin/sh"
[ -e "$LIVEROOT/bin/sh" ]      || { mkdir -p "$LIVEROOT/bin"; ln -sf /usr/bin/bash "$LIVEROOT/bin/sh"; }

log "merging /usr/bin → /usr/sbin (mount, sulogin, …)"
for b in "$LIVEROOT"/usr/bin/*; do
    [ -e "$b" ] || continue
    n=$(basename "$b")
    [ -e "$LIVEROOT/usr/sbin/$n" ] || ln -sf "../bin/$n" "$LIVEROOT/usr/sbin/$n"
done
# /sbin tools too (some units use /sbin/<x>); /sbin already holds init.
for b in "$LIVEROOT"/usr/bin/*; do
    [ -e "$b" ] || continue
    n=$(basename "$b")
    [ -e "$LIVEROOT/sbin/$n" ] || ln -sf "/usr/bin/$n" "$LIVEROOT/sbin/$n"
done

# Live image is "already set up": preset a machine-id and mask the interactive
# first-boot wizard, or systemd-firstboot blocks on a TTY prompt and drops the
# whole boot into emergency mode before reaching the display manager.
log "disabling systemd-firstboot for the live session"
systemd-machine-id-setup --root="$LIVEROOT" >/dev/null 2>&1 \
    || (head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$LIVEROOT/etc/machine-id")
ln -sf /dev/null "$LIVEROOT/etc/systemd/system/systemd-firstboot.service"
: > "$LIVEROOT/etc/locale.conf"; echo "LANG=en_US.UTF-8" > "$LIVEROOT/etc/locale.conf"
echo "blueberry" > "$LIVEROOT/etc/hostname"

# Fonts + locale: without a UTF-8 locale Qt warns and falls back to ANSI, and
# without a fontconfig cache the first lookup is slow / can miss. the glibc-locales package provides
# the en_US.UTF-8 locale-archive; make sure every login
# path sees it. Build the fontconfig cache against the staged fonts so the
# greeter has glyphs immediately (was rendering tofu — no fonts were staged).
log "locale (en_US.UTF-8) + fontconfig cache"
cat > "$LIVEROOT/etc/locale.conf" <<'LOCALE'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
LOCALE
if command -v fc-cache >/dev/null 2>&1 && [ -d "$LIVEROOT/usr/share/fonts" ]; then
    # Cache into the live root; HOME/XDG point inside it so nothing touches the host.
    HOME="$LIVEROOT/root" XDG_CACHE_HOME="$LIVEROOT/var/cache" \
        fc-cache -f "$LIVEROOT/usr/share/fonts" >/dev/null 2>&1 || true
fi
# SDDM has no GreeterEnvironment key and sddm-helper rebuilds a clean env for the
# greeter from pam_getenvlist(), so /etc/environment/DefaultEnvironment don't
# reach it and Qt keeps detecting "C". Wrap the greeter binary to force the
# locale — the only mechanism that reliably lands. (The Plasma session itself
# gets en_US.UTF-8 via pam_env in system-login.)
for g in sddm-greeter-qt6 sddm-greeter; do
    gb="$LIVEROOT/usr/bin/$g"
    if [ -f "$gb" ] && [ ! -e "$gb.real" ]; then
        log "wrapping $g for en_US.UTF-8"
        mv "$gb" "$gb.real"
        cat > "$gb" <<WRAP
#!/bin/sh
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
exec /usr/bin/$g.real "\$@"
WRAP
        chmod 0755 "$gb"
    fi
done

# Live session launch. SDDM's session helper does not give the autologin session
# DRM-master / active-VT status on this seat (startplasma-wayland exits before
# kwin can open the DRM node). So drive the live desktop the robust way: autologin
# `live` on tty1 via getty and let the user's profile exec the Plasma Wayland
# session directly — now kwin is the sole compositor on the *active* VT and
# acquires DRM master cleanly. (SDDM stays installed for the on-disk system.)
log "live desktop: getty autologin → Plasma on tty1"
ln -sf /usr/lib/systemd/system/multi-user.target "$LIVEROOT/etc/systemd/system/default.target"
# agetty defaults to /bin/login; this rootfs has login at /usr/bin/login and a
# real (non-merged) /bin, so point agetty at it explicitly + add the symlink.
[ -e "$LIVEROOT/bin/login" ] || ln -sf /usr/bin/login "$LIVEROOT/bin/login"
mkdir -p "$LIVEROOT/etc/systemd/system/getty@tty1.service.d"
cat > "$LIVEROOT/etc/systemd/system/getty@tty1.service.d/10-autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --login-program /usr/bin/login --autologin live --noclear %I 38400 linux
EOF
ln -sf /usr/lib/systemd/system/NetworkManager.service \
    "$LIVEROOT/etc/systemd/system/multi-user.target.wants/NetworkManager.service" 2>/dev/null || true

# On tty1 the live user's shell launches the Plasma Wayland session once (guarded
# so logging out doesn't relaunch into a loop). Software GL for VMs without a
# native Mesa driver. Calamares is reachable from the desktop once it's up.
install -d -m 0755 "$LIVEROOT/home/live"
cat > "$LIVEROOT/home/live/.bash_profile" <<'EOF'
# Auto-start the Plasma (Wayland) session on the first VT. Use $XDG_VTNR (set by
# pam_systemd for the login session) rather than the `tty` command, which the
# systemd base does not ship.
if [ "${XDG_VTNR:-0}" = "1" ] && [ -z "$WAYLAND_DISPLAY" ] && [ -z "$DISPLAY" ]; then
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe KWIN_DRM_USE_QPAINTER=1
    export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=KDE
    # Mirror the session log. Prefer /dev/ttyS1 (a tty → line-buffered → flushes
    # immediately to the host serial file for diagnostics); a regular file would
    # be block-buffered and stay empty until Plasma exits. Falls back to the home
    # dir on real hardware without a second serial port.
    _plog="$HOME/.plasma.log"; [ -w /dev/ttyS1 ] && _plog=/dev/ttyS1
    echo "=== blueberry: launching Plasma session (log=$_plog) ===" > "$_plog" 2>&1
    exec dbus-run-session startplasma-wayland >> "$_plog" 2>&1
fi
EOF
chown -R 1000:1000 "$LIVEROOT/home/live" 2>/dev/null || true

# Free-but-honest /etc/os-release so the live + installed system identify right.
cat > "$LIVEROOT/etc/os-release" <<EOF
NAME="$BBD_NAME"
PRETTY_NAME="$BBD_NAME $BBD_FULLVERSION ($BBD_CODENAME)"
ID=blueberry-desktop
ID_LIKE=blueberry
VERSION="$BBD_FULLVERSION"
VERSION_ID="$BBD_VERSION"
VERSION_CODENAME="$BBD_CODENAME"
BUILD_ID="$BBD_CHANNEL"
HOME_URL="https://repo.mmzsigmond.me"
EOF
cp -a "$LIVEROOT/etc/os-release" "$ISO_ROOT/" 2>/dev/null || true

# ── Squash the live root ──────────────────────────────────────────────────────
log "building squashfs (zstd) — this is the bulk of the build"
mksquashfs "$LIVEROOT" "$ISO_ROOT/live/filesystem.squashfs" \
    -comp zstd -Xcompression-level 19 -noappend -quiet \
    -e boot/vmlinuz boot/initramfs.cpio.zst

# ── Boot assets ───────────────────────────────────────────────────────────────
cp "$VMLINUZ" "$ISO_ROOT/boot/vmlinuz"
cp "$INITRD"  "$ISO_ROOT/boot/initramfs.cpio.zst"

# ── GRUB menu (live: try + install) ───────────────────────────────────────────
# blueberry.live=1 tells the initramfs to mount the squashfs + tmpfs overlay
# instead of a disk root. CDLABEL lets it find the medium by volume id.
cat > "$ISO_ROOT/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=10
set timeout_style=menu
if [ "\$grub_platform" = "efi" ]; then set gfxpayload=keep; else set gfxpayload=text; fi

menuentry "Try $BBD_NAME $BBD_FULLVERSION ($DE)" {
    linux /boot/vmlinuz blueberry.live=1 root=live:CDLABEL=$VOLID console=tty0 console=ttyS0,115200 systemd.firstboot=0 systemd.unified_cgroup_hierarchy=1 systemd.journald.forward_to_console=1 systemd.log_target=console
    initrd /boot/initramfs.cpio.zst
}
menuentry "Install $BBD_NAME $BBD_FULLVERSION ($DE)" {
    linux /boot/vmlinuz blueberry.live=1 blueberry.installer=1 root=live:CDLABEL=$VOLID console=tty0 quiet splash systemd.firstboot=0 systemd.unified_cgroup_hierarchy=1
    initrd /boot/initramfs.cpio.zst
}
menuentry "Try (safe graphics / nomodeset)" {
    linux /boot/vmlinuz blueberry.live=1 root=live:CDLABEL=$VOLID console=tty0 nomodeset systemd.unified_cgroup_hierarchy=1
    initrd /boot/initramfs.cpio.zst
}
EOF

# ── Build the hybrid ISO ──────────────────────────────────────────────────────
log "building hybrid BIOS+UEFI ISO: $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
grub-mkrescue --output "$OUTPUT" "$ISO_ROOT" -- -volid "$VOLID" >/dev/null 2>&1 \
    || grub-mkrescue --output "$OUTPUT" "$ISO_ROOT" -- -volid "$VOLID"

log "ISO written: $OUTPUT ($(du -sh "$OUTPUT" | cut -f1))"
log "Boot:  qemu-system-x86_64 -cdrom $OUTPUT -m 4096 -enable-kvm -vga virtio"
log "USB:   dd if=$OUTPUT of=/dev/sdX bs=4M status=progress oflag=sync"
