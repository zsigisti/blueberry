#!/bin/bash
# mkdesktopinstiso.sh — build the Blueberry Desktop INSTALLER ISO (TUI).
#
# Replaces the Calamares live ISO: booting this image lands straight in the
# full-screen Rust installer (initramfs `bbtui` mode) — no live desktop session.
# Two variants:
#   MODE=offline  payload = the complete installed-desktop rootfs tarball;
#                 installs with no network. (default)
#   MODE=online   payload = the CLI base rootfs + a desktop package manifest;
#                 the installer fetches the desktop set from the signed repo
#                 with bpm at install time (small "netinstall" image).
#
# Invoked by `make desktop-iso` / `make desktop-iso-online`, which export:
#   DE BBD_NAME BBD_VERSION BBD_FULLVERSION BBD_CODENAME BBD_CHANNEL
#   STAGEDIR (desktop rootfs for offline, base rootfs for online)
#   DESKTOPDIR BOOTDIR ARCH
set -euo pipefail

OUTPUT=${1:?usage: $0 <output.iso>}
: "${MODE:=offline}" "${DE:=kde}" "${STAGEDIR:?}" "${DESKTOPDIR:?}" "${BOOTDIR:?}" "${ARCH:=x86_64}"
: "${BBD_NAME:=Blueberry Desktop}" "${BBD_VERSION:=0.0}"
: "${BBD_FULLVERSION:=$BBD_VERSION}" "${BBD_CODENAME:=}" "${BBD_CHANNEL:=stable}"
: "${ZSTD_LVL:=10}"   # payload compression (10 = good ratio, much faster than 19)

log()  { printf '\033[1;35m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

case "$DE" in
  kde)   DEFAULT_DM=sddm ;;
  gnome) DEFAULT_DM=gdm  ;;
  *) die "unknown DE '$DE' (kde|gnome)" ;;
esac
VOLID="BLUEBERRY_$(echo "$BBD_VERSION" | tr -d .)"

command -v grub-mkrescue >/dev/null || die "grub-mkrescue not found (grub2)"
command -v xorriso       >/dev/null || die "xorriso not found"
command -v zstd          >/dev/null || die "zstd not found"

VMLINUZ="$BOOTDIR/vmlinuz"
INITRD="$BOOTDIR/initramfs.cpio.zst"
[ -f "$VMLINUZ" ] || die "kernel missing: $VMLINUZ (run 'make install')"
[ -f "$INITRD"  ] || die "initramfs missing: $INITRD (run 'make install')"

if [ "$MODE" = offline ] && [ ! -e "$STAGEDIR/usr/bin/sddm" ] && [ ! -e "$STAGEDIR/usr/bin/gdm" ]; then
    die "no display manager in the staged rootfs ($STAGEDIR) — run 'make desktop-stage' first"
fi

WORK=$(mktemp -d "$(dirname "$OUTPUT")/.bbd-inst.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ISO_ROOT="$WORK/iso"
PAYLOAD="$ISO_ROOT/blueberry"
mkdir -p "$ISO_ROOT/boot/grub" "$PAYLOAD"

# ── Installed-desktop system configuration ────────────────────────────────────
# Applies the boot/session wiring an INSTALLED desktop needs (the parts the old
# live ISO layered at ISO build time): systemd entry point, /bin/sh, /usr/sbin
# merge, locale, DM autostart, os-release + the editions/desktop/system overlay.
# $1 = target root. Used on the offline INSTALLROOT and the online overlay build.
apply_system_config() {
    local R=$1 full=$2   # full=1: rootfs-wide ops (init links, bin merge, caches)
    cp -a "$DESKTOPDIR/system/." "$R/"

    mkdir -p "$R/etc/systemd/system/graphical.target.wants" \
             "$R/etc/systemd/system/multi-user.target.wants"
    ln -sf /usr/lib/systemd/system/graphical.target "$R/etc/systemd/system/default.target"
    ln -sf "/usr/lib/systemd/system/$DEFAULT_DM.service" \
        "$R/etc/systemd/system/graphical.target.wants/$DEFAULT_DM.service"
    ln -sf /usr/lib/systemd/system/NetworkManager.service \
        "$R/etc/systemd/system/multi-user.target.wants/NetworkManager.service" 2>/dev/null || true

    printf 'LANG=en_US.UTF-8\nLC_ALL=en_US.UTF-8\n' > "$R/etc/locale.conf"

    cat > "$R/etc/os-release" <<EOF
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

    [ "$full" = 1 ] || return 0

    # systemd entry point (the initramfs switch_root execs /sbin/init).
    [ -x "$R/usr/lib/systemd/systemd" ] || die "no systemd in $R"
    mkdir -p "$R/sbin" "$R/usr/sbin" "$R/bin"
    ln -sf /usr/lib/systemd/systemd "$R/sbin/init"
    ln -sf /usr/lib/systemd/systemd "$R/usr/sbin/init" 2>/dev/null || true

    # merged-usr: everything ships in /usr/bin, but plenty of tools hardcode
    # /bin/* and /sbin/* (agetty execs /bin/login, scripts use /bin/sh, units
    # use /usr/sbin/*). Mirror /usr/bin into /bin, /sbin and /usr/sbin.
    [ -e "$R/usr/bin/sh" ] || ln -sf bash "$R/usr/bin/sh"
    local b n
    for b in "$R"/usr/bin/*; do
        [ -e "$b" ] || continue
        n=$(basename "$b")
        [ -e "$R/bin/$n" ]      || ln -sf "/usr/bin/$n" "$R/bin/$n"
        [ -e "$R/sbin/$n" ]     || ln -sf "/usr/bin/$n" "$R/sbin/$n"
        [ -e "$R/usr/sbin/$n" ] || ln -sf "../bin/$n" "$R/usr/sbin/$n"
    done

    # Font + icon caches so the first SDDM greeter paint has glyphs/icons.
    if command -v fc-cache >/dev/null 2>&1 && [ -d "$R/usr/share/fonts" ]; then
        HOME="$R/root" XDG_CACHE_HOME="$R/var/cache" \
            fc-cache -f "$R/usr/share/fonts" >/dev/null 2>&1 || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        local t d
        for t in breeze breeze-dark Breeze_Light hicolor; do
            d="$R/usr/share/icons/$t"
            [ -f "$d/index.theme" ] && gtk-update-icon-cache -q -f -t "$d" >/dev/null 2>&1 || true
        done
    fi

    # SDDM greeter locale+softGL wrapper (sddm-helper wipes the env for the
    # greeter; the wrapper is the only reliable way in).
    local g gb
    for g in sddm-greeter-qt6 sddm-greeter; do
        gb="$R/usr/bin/$g"
        if [ -f "$gb" ] && [ ! -e "$gb.real" ]; then
            mv "$gb" "$gb.real"
            cat > "$gb" <<WRAP
#!/bin/sh
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
export MESA_LOADER_DRIVER_OVERRIDE=kms_swrast KWIN_DRM_USE_QPAINTER=1
exec /usr/bin/$g.real "\$@"
WRAP
            chmod 0755 "$gb"
        fi
    done
}

# ── Payload ───────────────────────────────────────────────────────────────────
if [ "$MODE" = offline ]; then
    log "preparing installed-desktop root (hardlink clone + system config)"
    INSTALLROOT="$WORK/installroot"
    mkdir -p "$INSTALLROOT"
    cp -al "$STAGEDIR/." "$INSTALLROOT/" 2>/dev/null || cp -a "$STAGEDIR/." "$INSTALLROOT/"
    apply_system_config "$INSTALLROOT" 1

    log "packing rootfs.tar.zst (zstd -$ZSTD_LVL, this is the bulk of the build)"
    tar -C "$INSTALLROOT" --owner=0 --group=0 --numeric-owner \
        --exclude='./boot/vmlinuz' --exclude='./boot/initramfs.cpio.zst' \
        -cf - . | zstd -q "-$ZSTD_LVL" -T0 > "$PAYLOAD/rootfs.tar.zst"

    cat > "$PAYLOAD/payload.conf" <<EOF
PROFILE=desktop-offline
NAME=$BBD_NAME $BBD_FULLVERSION ($DE)
EOF
else
    log "packing base rootfs.tar.zst (online/netinstall base)"
    tar -C "$STAGEDIR" --owner=0 --group=0 --numeric-owner \
        --exclude='./boot/vmlinuz' --exclude='./boot/initramfs.cpio.zst' \
        -cf - . | zstd -q "-$ZSTD_LVL" -T0 > "$PAYLOAD/rootfs.tar.zst"

    log "building desktop package manifest + config overlay"
    sed -e 's/#.*//' -e '/^[[:space:]]*$/d' \
        "$DESKTOPDIR/packages/common.list" "$DESKTOPDIR/packages/$DE.list" \
        | tr -s ' \n' ' \n' > "$PAYLOAD/desktop-pkgs.txt"

    OVERLAY="$WORK/overlay"
    mkdir -p "$OVERLAY"
    apply_system_config "$OVERLAY" 0
    tar -C "$OVERLAY" --owner=0 --group=0 --numeric-owner -cf - . \
        | zstd -q -19 > "$PAYLOAD/overlay.tar.zst"

    cat > "$PAYLOAD/payload.conf" <<EOF
PROFILE=desktop-online
NAME=$BBD_NAME $BBD_FULLVERSION ($DE, netinstall)
EOF
fi

cp "$VMLINUZ" "$PAYLOAD/vmlinuz"
cp "$INITRD"  "$PAYLOAD/initramfs.cpio.zst"

# ── Boot assets + GRUB menu ───────────────────────────────────────────────────
cp "$VMLINUZ" "$ISO_ROOT/boot/vmlinuz"
cp "$INITRD"  "$ISO_ROOT/boot/initramfs.cpio.zst"

cat > "$ISO_ROOT/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5
set timeout_style=menu
if [ "\$grub_platform" = "efi" ]; then set gfxpayload=keep; else set gfxpayload=text; fi

menuentry "Install $BBD_NAME $BBD_FULLVERSION ($DE)" {
    linux /boot/vmlinuz bbtui quiet loglevel=3 console=tty0
    initrd /boot/initramfs.cpio.zst
}
menuentry "Install (serial console)" {
    linux /boot/vmlinuz bbtui quiet loglevel=3 console=ttyS0,115200
    initrd /boot/initramfs.cpio.zst
}
menuentry "Rescue shell" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200
    initrd /boot/initramfs.cpio.zst
}
EOF

log "building hybrid BIOS+UEFI ISO: $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
grub-mkrescue --output "$OUTPUT" "$ISO_ROOT" -- -volid "$VOLID" >/dev/null 2>&1 \
    || grub-mkrescue --output "$OUTPUT" "$ISO_ROOT" -- -volid "$VOLID"

log "ISO written: $OUTPUT ($(du -sh "$OUTPUT" | cut -f1))  [$MODE]"
log "Boot:  qemu-system-x86_64 -cdrom $OUTPUT -m 4096 -enable-kvm -vga virtio"
