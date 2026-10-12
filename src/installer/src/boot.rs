//! GRUB, kernel, fstab and the passwd/shadow bits.
//!
//! Kernel, initramfs and grub.cfg all sit on the root fs under /boot and grub.cfg
//! finds it by UUID, so the same config works for BIOS and UEFI.

use crate::run::{check, R};
use std::fs;
use std::path::Path;

#[derive(Clone, Copy, PartialEq)]
pub enum Firmware {
    Bios,
    Uefi,
}

pub fn detect_firmware() -> Firmware {
    if Path::new("/sys/firmware/efi").exists() {
        Firmware::Uefi
    } else {
        Firmware::Bios
    }
}

/// Module dir for "i386-pc" / "x86_64-efi": live system first, then the payload.
fn grub_modules(platform: &str, payload: &str) -> Option<String> {
    let candidates = [
        format!("/usr/lib/grub/{platform}"),
        format!("/lib/grub/{platform}"),
        format!("{payload}/grub/usr/lib/grub/{platform}"),
    ];
    candidates.into_iter().find(|p| Path::new(p).join("normal.mod").exists())
}

/// core.img lands in the ef02 BIOS-boot partition.
pub fn install_grub_bios(disk_dev: &str, mnt: &str, payload: &str) -> R<()> {
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

/// --removable writes /EFI/BOOT/BOOTX64.EFI, so it boots without an NVRAM entry.
pub fn install_grub_uefi(mnt: &str, esp: &str, payload: &str) -> R<()> {
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

/// `cryptarg` is either empty or a `cryptdevice=... ` prefix for LUKS installs.
pub fn write_grub_cfg(mnt: &str, root_uuid: &str, root_spec: &str, cryptarg: &str, btrfs: bool) -> R<()> {
    let dir = format!("{mnt}/boot/grub");
    fs::create_dir_all(&dir).map_err(|e| format!("mkdir {dir}: {e}"))?;
    // btrfs: GRUB sees the top-level subvolume, so the kernel is at /@/boot/...,
    // and the kernel needs subvol=@ or it mounts the empty top level as /.
    let (boot, rootflags) = if btrfs { ("/@/boot", "rootflags=subvol=@ ") } else { ("/boot", "") };
    // rollback entries that blueberry-snapshot writes before each upgrade
    let snapshots = if btrfs {
        "if [ -f /@/boot/grub/snapshots.cfg ]; then source /@/boot/grub/snapshots.cfg; fi\n"
    } else {
        ""
    };
    let cfg = format!(
        "set timeout=3\n\
         insmod all_video\n\
         insmod lvm\n\
         insmod btrfs\n\
         menuentry 'Blueberry Linux' {{\n\
         \x20   search --no-floppy --fs-uuid --set=root {uuid}\n\
         \x20   linux {boot}/vmlinuz {crypt}root={root} rw {rootflags}console=tty0 console=ttyS0,115200\n\
         \x20   initrd {boot}/initramfs.cpio.zst\n\
         }}\n\
         {snapshots}",
        uuid = root_uuid,
        crypt = cryptarg,
        root = root_spec,
        boot = boot,
        rootflags = rootflags,
        snapshots = snapshots,
    );
    fs::write(format!("{dir}/grub.cfg"), cfg).map_err(|e| format!("write grub.cfg: {e}"))
}

pub fn install_kernel(mnt: &str, payload: &str) -> R<()> {
    fs::create_dir_all(format!("{mnt}/boot")).ok();
    check(&["cp", &format!("{payload}/vmlinuz"), &format!("{mnt}/boot/vmlinuz")])?;
    check(&[
        "cp",
        &format!("{payload}/initramfs.cpio.zst"),
        &format!("{mnt}/boot/initramfs.cpio.zst"),
    ])
}

pub fn write_fstab(mnt: &str, root_spec: &str, rootfs: &str, esp_uuid: Option<&str>) -> R<()> {
    // only ext4 gets an fsck pass: fsck.xfs is a no-op and btrfs checks online,
    // so a non-zero pass there just logs a warning every boot
    let pass = if rootfs == "ext4" { 1 } else { 0 };
    // @home is separate so rolling back @ doesn't eat anyone's files. subvol= is
    // pinned to match grub (/@) and rootflags=subvol=@.
    let root_opts = if rootfs == "btrfs" { "rw,relatime,subvol=@" } else { "rw,relatime" };
    let mut fstab = format!("{root_spec}  /      {rootfs}  {root_opts}  0 {pass}\n");
    if rootfs == "btrfs" {
        fstab.push_str(&format!("{root_spec}  /home  btrfs  rw,relatime,subvol=@home  0 0\n"));
        // nofail: a broken @snapshots must never drop us into emergency mode
        fstab.push_str(&format!(
            "{root_spec}  /.snapshots  btrfs  rw,relatime,subvol=@snapshots,nofail  0 0\n"
        ));
        // the mountpoint has to exist inside @
        let _ = fs::create_dir_all(format!("{mnt}/.snapshots"));
    }
    if let Some(u) = esp_uuid {
        fstab.push_str(&format!("UUID={u}  /boot/efi  vfat  rw,relatime  0 2\n"));
    }
    fs::write(format!("{mnt}/etc/fstab"), fstab).map_err(|e| format!("write fstab: {e}"))
}

pub fn uefi_available(payload: &str) -> bool {
    grub_modules("x86_64-efi", payload).is_some()
}
pub fn bios_available(payload: &str) -> bool {
    grub_modules("i386-pc", payload).is_some()
}

/// Writes a SHA-512 hash straight into the target's /etc/shadow, so we don't
/// need chpasswd/PAM working inside the target. Adds the line if it's missing.
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
            // rest is "<oldhash>:<lastchange>:...", keep everything after the hash
            let tail = rest.split_once(':').map_or("20000:0:99999:7:::", |(_, t)| t);
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

/// Appends to passwd/group/shadow (locked until set_password) and makes $HOME.
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

/// Lowest free uid >= 1000. Also used as the gid.
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
