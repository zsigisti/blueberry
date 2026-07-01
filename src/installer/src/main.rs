//! blueberry-install — guided CLI installer for Blueberry Linux (server/base).
//!
//! Runs on the live system. Partitions a target disk, formats it, lays the base
//! rootfs down from the boot-media payload, installs GRUB for the chosen firmware
//! (BIOS i386-pc or UEFI x86_64-efi), and writes fstab + boot config. Every
//! question can be answered by a `BLUEBERRY_*` environment variable for fully
//! unattended installs (CI, `make dev-disk`); see ui.rs.

mod boot;
mod disk;
mod run;
mod ui;

use boot::Firmware;
use run::{check, run, sh, sh_check, step, R};
use std::env;
use std::fs;
use std::path::Path;
use std::process::exit;

const MNT: &str = "/mnt/blueberry";

fn main() {
    if let Err(e) = real_main() {
        eprintln!("\n[install] ERROR: {e}");
        exit(1);
    }
}

fn real_main() -> R<()> {
    if unsafe { libc::geteuid() } != 0 {
        return Err("must run as root".into());
    }
    // Bundled tools live in /usr/{bin,sbin}; make sure they're found.
    env::set_var("PATH", "/usr/sbin:/usr/bin:/sbin:/bin");
    env::set_var("LD_LIBRARY_PATH", "/usr/lib:/lib");

    println!("\n=== Blueberry Linux installer ===");

    step("locating install payload");
    let payload = find_payload().ok_or(
        "could not find the install payload (rootfs.tar.zst) on any boot medium",
    )?;
    println!("   payload: {payload}");

    // ── Firmware + bootloader ────────────────────────────────────────────────
    let fw = boot::detect_firmware();
    let (mut boot_items, mut boot_kinds) = (Vec::new(), Vec::new());
    if boot::uefi_available(&payload) {
        boot_items.push("GRUB — UEFI (x86_64-efi)".to_string());
        boot_kinds.push(Firmware::Uefi);
    }
    if boot::bios_available(&payload) {
        boot_items.push("GRUB — BIOS (i386-pc)".to_string());
        boot_kinds.push(Firmware::Bios);
    }
    if boot_items.is_empty() {
        return Err("no GRUB module trees found (neither UEFI nor BIOS) — cannot install a bootloader".into());
    }
    // Default to whatever the firmware booted us as.
    let default_idx = boot_kinds
        .iter()
        .position(|k| *k == fw)
        .unwrap_or(0);
    let boot_prompt = format!("Bootloader (firmware detected: {})", fw_name(fw));
    let bidx = ui::select(&boot_prompt, &boot_items, default_idx, "BLUEBERRY_BOOTLOADER");
    let target_fw = boot_kinds[bidx];

    // ── Disk ─────────────────────────────────────────────────────────────────
    let disks = disk::list();
    if disks.is_empty() {
        return Err("no installable disks found".into());
    }
    let disk = pick_disk(&disks)?;
    println!("\nThis will ERASE ALL DATA on {}.", disk.dev);
    if !ui::confirm("Proceed and erase this disk?", false, "BLUEBERRY_ERASE_OK") {
        return Err("aborted by user".into());
    }

    // ── Partition ────────────────────────────────────────────────────────────
    step(&format!(
        "partitioning {} (GPT, {} layout)",
        disk.dev,
        fw_name(target_fw)
    ));
    let (esp, root_part) = match target_fw {
        Firmware::Uefi => {
            let (e, r) = disk::partition_uefi(&disk)?;
            (Some(e), r)
        }
        Firmware::Bios => (None, disk::partition_bios(&disk)?),
    };

    // ── Optional LUKS on root ────────────────────────────────────────────────
    let (rootfs_dev, crypt_uuid) = maybe_luks(&root_part)?;
    let encrypted = crypt_uuid.is_some();

    // ── Format ───────────────────────────────────────────────────────────────
    step("formatting");
    if let Some(e) = &esp {
        disk::mkfs_fat(e, "EFI")?;
    }
    disk::mkfs_ext4(&rootfs_dev, "blueberry-root")?;

    // ── Mount ────────────────────────────────────────────────────────────────
    step("mounting target");
    fs::create_dir_all(MNT).ok();
    check(&["mount", &rootfs_dev, MNT])?;
    if let Some(e) = &esp {
        fs::create_dir_all(format!("{MNT}/boot/efi")).ok();
        check(&["mount", e, &format!("{MNT}/boot/efi")])?;
    }

    // ── Extract rootfs ───────────────────────────────────────────────────────
    step("extracting root filesystem (this takes a moment)");
    sh_check(&format!("zstd -dcq {payload}/rootfs.tar.zst | tar -x -C {MNT}"))?;

    // ── Bootloader + kernel ──────────────────────────────────────────────────
    boot::install_kernel(MNT, &payload)?;

    let uuid = disk::uuid(&rootfs_dev);
    if uuid.is_empty() {
        return Err("could not read root filesystem UUID".into());
    }
    // When encrypted the kernel unlocks the LUKS container then boots the mapper.
    let (root_spec, cryptarg) = if let Some(cu) = &crypt_uuid {
        (
            "/dev/mapper/cryptroot".to_string(),
            format!("cryptdevice=UUID={cu}:cryptroot "),
        )
    } else {
        (format!("UUID={uuid}"), String::new())
    };

    match target_fw {
        Firmware::Bios => boot::install_grub_bios(&disk.dev, MNT, &payload)?,
        Firmware::Uefi => {
            let esp = esp.as_deref().unwrap();
            boot::install_grub_uefi(MNT, &format!("{MNT}/boot/efi"), &payload)?;
            let _ = esp; // ESP already mounted
        }
    }

    step(&format!("writing boot config (root={root_spec}{})", if encrypted { " [encrypted]" } else { "" }));
    boot::write_grub_cfg(MNT, &uuid, &root_spec, &cryptarg)?;

    // crypttab + fstab
    if let Some(cu) = &crypt_uuid {
        let _ = fs::write(
            format!("{MNT}/etc/crypttab"),
            format!("cryptroot  UUID={cu}  none  luks\n"),
        );
    }
    let esp_uuid = esp.as_deref().map(disk::uuid);
    boot::write_fstab(MNT, &root_spec, esp_uuid.as_deref().filter(|u| !u.is_empty()))?;

    // ── System configuration ─────────────────────────────────────────────────
    set_root_password()?;
    set_hostname();
    make_swap();
    make_user();
    install_packages();

    // ── Finish ───────────────────────────────────────────────────────────────
    step("unmounting");
    sh(&format!("swapoff {MNT}/swapfile 2>/dev/null"));
    if esp.is_some() {
        run(&["umount", &format!("{MNT}/boot/efi")]);
    }
    run(&["umount", MNT]);
    if encrypted {
        run(&["cryptsetup", "close", "cryptroot"]);
    }

    println!("\n=== Installation complete. Remove the install medium and reboot. ===");
    Ok(())
}

fn fw_name(f: Firmware) -> &'static str {
    match f {
        Firmware::Uefi => "UEFI",
        Firmware::Bios => "BIOS",
    }
}

/// Pick the target disk (env `BLUEBERRY_TARGET` or interactive select).
fn pick_disk(disks: &[disk::Disk]) -> R<&disk::Disk> {
    if let Ok(t) = env::var("BLUEBERRY_TARGET") {
        if let Some(d) = disks.iter().find(|d| d.dev == t || d.name == t) {
            return Ok(d);
        }
        return Err(format!("BLUEBERRY_TARGET={t} is not an available disk"));
    }
    let items: Vec<String> = disks
        .iter()
        .map(|d| format!("{:<12} {:>7.1} GiB  {}", d.dev, d.gib(), d.model))
        .collect();
    let idx = ui::select(
        "Select the disk to INSTALL TO (all data on it is erased)",
        &items,
        0,
        "BLUEBERRY_TARGET_IDX",
    );
    Ok(&disks[idx])
}

/// Find rootfs.tar.zst: initramfs-shipped, the mounted live medium, or by
/// probing block devices.
fn find_payload() -> Option<String> {
    for p in ["/blueberry", "/run/live/medium/blueberry", "/live/medium/blueberry"] {
        if Path::new(&format!("{p}/rootfs.tar.zst")).exists() {
            return Some(p.to_string());
        }
    }
    // Probe every block device / partition for an ISO/vfat/ext holding /blueberry.
    let mp = "/run/blueberry-media";
    fs::create_dir_all(mp).ok();
    let rd = fs::read_dir("/sys/block").ok()?;
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        if name.starts_with("loop") || name.starts_with("ram") {
            continue;
        }
        let mut cands = vec![format!("/dev/{name}")];
        for p in 1..=4 {
            let sep = if name.chars().last().unwrap_or(' ').is_ascii_digit() { "p" } else { "" };
            cands.push(format!("/dev/{name}{sep}{p}"));
        }
        for c in cands {
            if !Path::new(&c).exists() {
                continue;
            }
            for fstype in ["iso9660", "vfat", "ext4"] {
                if run(&["mount", "-t", fstype, "-o", "ro", &c, mp]) {
                    if Path::new(&format!("{mp}/blueberry/rootfs.tar.zst")).exists() {
                        return Some(format!("{mp}/blueberry"));
                    }
                    run(&["umount", mp]);
                }
            }
        }
    }
    None
}

/// Optionally LUKS-encrypt the root partition. Returns (device_to_format,
/// Some(container_uuid) if encrypted).
fn maybe_luks(part: &str) -> R<(String, Option<String>)> {
    if !ui::confirm("Encrypt the system with LUKS?", false, "BLUEBERRY_LUKS") {
        return Ok((part.to_string(), None));
    }
    if !run(&["sh", "-c", "command -v cryptsetup >/dev/null 2>&1"]) {
        return Err("encryption requested but cryptsetup is missing from the live image".into());
    }
    let pw = ui::password("  LUKS passphrase", "BLUEBERRY_LUKSPW", false)
        .ok_or("a LUKS passphrase is required")?;
    let keyfile = "/run/bb-luks.key";
    fs::write(keyfile, &pw).map_err(|e| format!("stage LUKS keyfile: {e}"))?;
    let _ = run(&["chmod", "0600", keyfile]);

    step(&format!("encrypting {part} with LUKS2"));
    // Cap argon2 memory (256 MiB) so it works on low-RAM boxes.
    let fmt = check(&[
        "cryptsetup", "luksFormat", "--type", "luks2", "--batch-mode",
        "--pbkdf", "argon2id", "--pbkdf-memory", "262144",
        "--key-file", keyfile, part,
    ]);
    let opened = fmt
        .and_then(|_| check(&["cryptsetup", "open", "--key-file", keyfile, part, "cryptroot"]));
    let _ = fs::remove_file(keyfile);
    opened?;
    let cu = disk::uuid(part);
    Ok(("/dev/mapper/cryptroot".to_string(), Some(cu)))
}

fn set_root_password() -> R<()> {
    step("set the root password for the installed system");
    if let Some(pw) = ui::password("  root password", "BLUEBERRY_ROOTPW", false) {
        if !boot::set_password(MNT, "root", &pw) {
            return Err("could not set root password".into());
        }
    } else {
        while !boot::passwd_interactive(MNT, "root") {
            println!("   passwords didn't match; try again");
        }
    }
    Ok(())
}

fn set_hostname() {
    let host = ui::input("Hostname for the new system", "blueberry", "BLUEBERRY_HOSTNAME");
    let host = if host.trim().is_empty() { "blueberry" } else { host.trim() };
    step(&format!("hostname: {host}"));
    let _ = fs::write(format!("{MNT}/etc/hostname"), format!("{host}\n"));
}

fn make_swap() {
    let s = ui::input("Swapfile size in GiB (0 to skip)", "0", "BLUEBERRY_SWAP");
    let gib: u64 = s.trim().parse().unwrap_or(0);
    if gib == 0 {
        return;
    }
    step(&format!("creating {gib} GiB swapfile"));
    let ok = sh(&format!(
        "fallocate -l {gib}G {MNT}/swapfile 2>/dev/null \
         || dd if=/dev/zero of={MNT}/swapfile bs=1M count={} 2>/dev/null",
        gib * 1024
    ));
    if !ok {
        eprintln!("[install] WARNING: could not allocate swapfile; skipping");
        return;
    }
    let _ = run(&["chmod", "600", &format!("{MNT}/swapfile")]);
    sh(&format!("mkswap {MNT}/swapfile >/dev/null 2>&1"));
    if let Ok(mut f) = fs::OpenOptions::new().append(true).open(format!("{MNT}/etc/fstab")) {
        use std::io::Write;
        let _ = writeln!(f, "/swapfile  none  swap  sw  0 0");
    }
}

fn make_user() {
    let name = ui::input("Create a non-root user (blank to skip)", "", "BLUEBERRY_USER");
    let name = name.trim();
    if name.is_empty() {
        return;
    }
    step(&format!("creating user {name}"));
    let ok = sh(&format!(
        "chroot {MNT} /usr/sbin/useradd -m -s /bin/bash {name} 2>/dev/null \
         || chroot {MNT} adduser -D -s /bin/bash {name}"
    ));
    if !ok {
        eprintln!("[install] WARNING: could not create user {name}");
        return;
    }
    if let Some(pw) = ui::password(&format!("  password for {name}"), "BLUEBERRY_USERPW", true) {
        boot::set_password(MNT, name, &pw);
    } else if !ui::yes_mode() {
        while !boot::passwd_interactive(MNT, name) {
            println!("   passwords didn't match; try again");
        }
    }
}

fn install_packages() {
    let pkgs = ui::input(
        "Extra packages to install now (space-separated, blank to skip) e.g. vim git sudo",
        "",
        "BLUEBERRY_PKGS",
    );
    let pkgs = pkgs.trim();
    if pkgs.is_empty() {
        return;
    }
    step(&format!("installing extra packages: {pkgs}"));
    disk::ensure_network();
    if !run(&["sh", "-c", &format!("BPM_ROOT={MNT} bpm update")]) {
        eprintln!("[install] WARNING: 'bpm update' failed (no network/repo?); skipping extra packages");
        return;
    }
    if !run(&["sh", "-c", &format!("BPM_ROOT={MNT} bpm install {pkgs}")]) {
        eprintln!("[install] WARNING: some packages failed (base system is still fine)");
    }
}
