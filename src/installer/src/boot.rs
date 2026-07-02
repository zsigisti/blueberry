//! Bootloader installation. GRUB is installed with the real `grub-install`
//! (Blueberry ships both the i386-pc and x86_64-efi module trees). The kernel,
//! initramfs and grub.cfg all live on the *root* filesystem under /boot, and
//! grub.cfg locates it by UUID with `search` — so the exact same config works
//! whether GRUB was set up for BIOS or UEFI.

use crate::run::{check, step, R};
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

/// Set `user`'s password by writing a SHA-512 crypt hash straight into the
/// target's /etc/shadow — no chpasswd/PAM needed in the target, so a scripted
/// install works against a minimal base. Adds an entry if the user is new.
pub fn set_password(mnt: &str, user: &str, pw: &str) -> R<()> {
    use sha_crypt::{sha512_simple, Sha512Params};
    let params = Sha512Params::new(5000).map_err(|_| "crypt params".to_string())?;
    let hash = sha512_simple(pw, &params).map_err(|_| "password hashing failed".to_string())?;

    let path = format!("{mnt}/etc/shadow");
    let content = fs::read_to_string(&path).unwrap_or_default();
    let prefix = format!("{user}:");
    let mut out = String::new();
    let mut found = false;
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix(&prefix) {
            // rest = "<oldhash>:<lastchange>:<...>"; keep everything after the hash.
            let tail = rest.splitn(2, ':').nth(1).unwrap_or("20000:0:99999:7:::");
            out.push_str(&format!("{user}:{hash}:{tail}\n"));
            found = true;
        } else {
            out.push_str(line);
            out.push('\n');
        }
    }
    if !found {
        out.push_str(&format!("{user}:{hash}:20000:0:99999:7:::\n"));
    }
    fs::write(&path, out).map_err(|e| format!("write shadow: {e}"))
}

/// Create a login user by appending to /etc/passwd, /etc/group and /etc/shadow
/// (locked until set_password), then making the home directory. Returns the UID.
pub fn create_user(mnt: &str, name: &str) -> R<u32> {
    let uid = next_uid(mnt);
    append(&format!("{mnt}/etc/passwd"), &format!("{name}:x:{uid}:{uid}:{name}:/home/{name}:/bin/bash\n"))?;
    append(&format!("{mnt}/etc/group"), &format!("{name}:x:{uid}:\n"))?;
    append(&format!("{mnt}/etc/shadow"), &format!("{name}:!:20000:0:99999:7:::\n"))?;
    let home = format!("{mnt}/home/{name}");
    fs::create_dir_all(&home).ok();
    if let Ok(c) = std::ffi::CString::new(home) {
        unsafe { libc::chown(c.as_ptr(), uid, uid); }
    }
    Ok(uid)
}

/// Lowest free UID/GID at or above 1000 in the target's /etc/passwd.
fn next_uid(mnt: &str) -> u32 {
    let content = fs::read_to_string(format!("{mnt}/etc/passwd")).unwrap_or_default();
    let mut uid = 1000u32;
    let used: Vec<u32> = content
        .lines()
        .filter_map(|l| l.split(':').nth(2))
        .filter_map(|n| n.parse().ok())
        .collect();
    while used.contains(&uid) {
        uid += 1;
    }
    uid
}

fn append(path: &str, line: &str) -> R<()> {
    use std::io::Write;
    let mut f = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| format!("open {path}: {e}"))?;
    f.write_all(line.as_bytes()).map_err(|e| format!("write {path}: {e}"))
}
