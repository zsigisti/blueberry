//! Bootloader installation. GRUB is installed with the real `grub-install`
//! (Blueberry ships both the i386-pc and x86_64-efi module trees). The kernel,
//! initramfs and grub.cfg all live on the *root* filesystem under /boot, and
//! grub.cfg locates it by UUID with `search` — so the exact same config works
//! whether GRUB was set up for BIOS or UEFI.

use crate::run::{check, run, sh, step, R};
use std::fs;
use std::path::Path;

#[derive(Clone, Copy, PartialEq)]
pub enum Firmware {
    Bios,
    Uefi,
}

/// UEFI if the firmware exposes efivars, else legacy BIOS.
pub fn detect_firmware() -> Firmware {
    if Path::new("/sys/firmware/efi").exists() {
        Firmware::Uefi
    } else {
        Firmware::Bios
    }
}

/// Locate the GRUB module directory for a platform ("i386-pc"/"x86_64-efi"),
/// searching the live system first, then a bundled install payload.
fn grub_modules(platform: &str, payload: &str) -> Option<String> {
    let candidates = [
        format!("/usr/lib/grub/{platform}"),
        format!("/lib/grub/{platform}"),
        format!("{payload}/grub/usr/lib/grub/{platform}"),
    ];
    candidates.into_iter().find(|p| Path::new(p).join("normal.mod").exists())
}

/// Install GRUB for BIOS (i386-pc) onto the whole disk. /mnt is the mounted root,
/// core.img is embedded in the BIOS-boot partition.
pub fn install_grub_bios(disk_dev: &str, mnt: &str, payload: &str) -> R<()> {
    step("installing GRUB (BIOS / i386-pc)");
    let modules = grub_modules("i386-pc", payload)
        .ok_or("GRUB i386-pc modules not found in the live system or payload")?;
    let boot_dir = format!("{mnt}/boot");
    check(&[
        "grub-install",
        "--target=i386-pc",
        &format!("--directory={modules}"),
        &format!("--boot-directory={boot_dir}"),
        "--recheck",
        disk_dev,
    ])
}

/// Install GRUB for UEFI (x86_64-efi). `esp` is the mounted ESP. --removable
/// writes /EFI/BOOT/BOOTX64.EFI so it boots without an NVRAM entry (efibootmgr).
pub fn install_grub_uefi(mnt: &str, esp: &str, payload: &str) -> R<()> {
    step("installing GRUB (UEFI / x86_64-efi)");
    let modules = grub_modules("x86_64-efi", payload)
        .ok_or("GRUB x86_64-efi modules not found in the live system or payload")?;
    let boot_dir = format!("{mnt}/boot");
    check(&[
        "grub-install",
        "--target=x86_64-efi",
        &format!("--directory={modules}"),
        &format!("--efi-directory={esp}"),
        &format!("--boot-directory={boot_dir}"),
        "--removable",
        "--no-nvram",
        "--recheck",
    ])
}

/// Write /boot/grub/grub.cfg. `root_uuid` is the root filesystem's UUID;
/// `cryptarg` is an optional `cryptdevice=…` prefix for encrypted installs.
pub fn write_grub_cfg(mnt: &str, root_uuid: &str, root_spec: &str, cryptarg: &str) -> R<()> {
    let dir = format!("{mnt}/boot/grub");
    fs::create_dir_all(&dir).map_err(|e| format!("mkdir {dir}: {e}"))?;
    let cfg = format!(
        "set timeout=3\n\
         insmod all_video\n\
         menuentry 'Blueberry Linux' {{\n\
         \x20   search --no-floppy --fs-uuid --set=root {uuid}\n\
         \x20   linux /boot/vmlinuz {crypt}root={root} rw console=tty0 console=ttyS0,115200\n\
         \x20   initrd /boot/initramfs.cpio.zst\n\
         }}\n",
        uuid = root_uuid,
        crypt = cryptarg,
        root = root_spec,
    );
    fs::write(format!("{dir}/grub.cfg"), cfg).map_err(|e| format!("write grub.cfg: {e}"))
}

/// Copy the kernel + initramfs from the payload into the target /boot.
pub fn install_kernel(mnt: &str, payload: &str) -> R<()> {
    step("installing kernel + initramfs");
    fs::create_dir_all(format!("{mnt}/boot")).ok();
    check(&["cp", &format!("{payload}/vmlinuz"), &format!("{mnt}/boot/vmlinuz")])?;
    check(&[
        "cp",
        &format!("{payload}/initramfs.cpio.zst"),
        &format!("{mnt}/boot/initramfs.cpio.zst"),
    ])
}

/// Write /etc/fstab (and, for UEFI, mount the ESP under /boot/efi).
pub fn write_fstab(mnt: &str, root_spec: &str, esp_uuid: Option<&str>) -> R<()> {
    let mut fstab = format!("{root_spec}  /      ext4  rw,relatime  0 1\n");
    if let Some(u) = esp_uuid {
        fstab.push_str(&format!("UUID={u}  /boot/efi  vfat  rw,relatime  0 2\n"));
    }
    fs::write(format!("{mnt}/etc/fstab"), fstab).map_err(|e| format!("write fstab: {e}"))
}

/// True if the payload/live system can actually do UEFI (has the module tree).
pub fn uefi_available(payload: &str) -> bool {
    grub_modules("x86_64-efi", payload).is_some()
}
pub fn bios_available(payload: &str) -> bool {
    grub_modules("i386-pc", payload).is_some()
}

/// Set a password for `user` in the mounted target via chpasswd (chroot).
pub fn set_password(mnt: &str, user: &str, pw: &str) -> bool {
    // Feed the hash-less "user:pass" line to chpasswd inside the target.
    let cmd = format!(
        "printf '%s:%s\\n' {user} {pw} | chroot {mnt} /usr/sbin/chpasswd 2>/dev/null \
         || printf '%s:%s\\n' {user} {pw} | chroot {mnt} chpasswd",
        user = shell_quote(user),
        pw = shell_quote(pw),
        mnt = mnt,
    );
    sh(&cmd)
}

/// Interactively set a password with the target's own passwd(1).
pub fn passwd_interactive(mnt: &str, user: &str) -> bool {
    run(&["chroot", mnt, "/usr/bin/passwd", user])
}

fn shell_quote(s: &str) -> String {
    // These come from prompts/env; wrap in single quotes and escape any quote.
    format!("'{}'", s.replace('\'', "'\\''"))
}
