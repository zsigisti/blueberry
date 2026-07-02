//! The install engine — every step of laying Blueberry on a disk, independent
//! of the front-end (TUI, CLI or unattended env). Front-ends build a `Config`,
//! then call `run(cfg, payload, emit)`; `emit` receives progress events.

use crate::boot::{self, Firmware};
use crate::disk;
use crate::run::{check, out, run, sh, R};
use std::fs;
use std::path::Path;

pub const MNT: &str = "/mnt/blueberry";

/// What we found on the boot medium.
pub struct Payload {
    pub dir: String,
    /// PROFILE= from payload.conf: "server", "desktop-offline", "desktop-online".
    pub profile: String,
    /// Human name for the UI (NAME= in payload.conf).
    pub name: String,
    /// desktop-pkgs.txt — when present the installer fetches these with bpm
    /// from the online repo after laying down the base rootfs.
    pub manifest: Option<Vec<String>>,
    /// overlay.tar.zst — extracted over the target after packages (online mode:
    /// carries the desktop system configuration).
    pub overlay: bool,
}

impl Payload {
    pub fn discover() -> Option<Payload> {
        let dir = find_payload_dir()?;
        let mut profile = "server".to_string();
        let mut name = "Blueberry Linux".to_string();
        if let Ok(conf) = fs::read_to_string(format!("{dir}/payload.conf")) {
            for line in conf.lines() {
                if let Some(v) = line.strip_prefix("PROFILE=") {
                    profile = v.trim().to_string();
                }
                if let Some(v) = line.strip_prefix("NAME=") {
                    name = v.trim().to_string();
                }
            }
        }
        let manifest = fs::read_to_string(format!("{dir}/desktop-pkgs.txt"))
            .ok()
            .map(|s| s.split_whitespace().map(str::to_string).collect::<Vec<_>>())
            .filter(|v: &Vec<String>| !v.is_empty());
        let overlay = Path::new(&format!("{dir}/overlay.tar.zst")).exists();
        Some(Payload { dir, profile, name, manifest, overlay })
    }
}

/// Curated console keymaps: (console/loadkeys name, xkb layout, label).
/// Applied live with loadkeys and persisted to vconsole.conf + kxkbrc.
pub const KEYMAPS: &[(&str, &str, &str)] = &[
    ("us", "us", "English (US)"),
    ("hu", "hu", "Hungarian"),
    ("de", "de", "German"),
    ("fr", "fr", "French"),
    ("uk", "gb", "English (UK)"),
    ("es", "es", "Spanish"),
    ("it", "it", "Italian"),
    ("pl", "pl", "Polish"),
    ("cz", "cz", "Czech"),
    ("ro", "ro", "Romanian"),
];

/// Everything the engine needs to know; front-ends fill this in.
pub struct Config {
    pub disk_dev: String, // /dev/vda
    pub firmware: Firmware,
    pub keymap: String, // console keymap name from KEYMAPS
    pub hostname: String,
    pub root_pw: String,
    pub user: Option<(String, String)>, // (name, password)
    pub swap_gib: u32,
    pub luks_pw: Option<String>,
    pub extra_pkgs: String,
}

/// Progress events for the front-end.
pub enum Ev {
    Step(String),
    Log(String),
}

pub type Emit<'a> = &'a mut dyn FnMut(Ev);

fn step(emit: Emit, s: &str) {
    emit(Ev::Step(s.to_string()));
}
fn logln(emit: Emit, s: &str) {
    emit(Ev::Log(s.to_string()));
}

/// How many Step() events run() emits — lets the UI draw a progress gauge.
pub fn total_steps(cfg: &Config, payload: &Payload) -> u32 {
    let mut n = 9; // partition, format, mount, extract, kernel, grub, config, users, finish
    if cfg.luks_pw.is_some() {
        n += 1;
    }
    if payload.manifest.is_some() {
        n += 1;
    }
    if payload.overlay {
        n += 1;
    }
    if cfg.swap_gib > 0 {
        n += 1;
    }
    if !cfg.extra_pkgs.trim().is_empty() {
        n += 1;
    }
    n
}

/// The whole install. Any Err aborts (front-end reports it).
pub fn run_install(cfg: &Config, payload: &Payload, emit: Emit) -> R<()> {
    let d = disk::list()
        .into_iter()
        .find(|d| d.dev == cfg.disk_dev)
        .ok_or(format!("{} is not an available disk", cfg.disk_dev))?;

    // ── Partition ────────────────────────────────────────────────────────────
    step(emit, &format!("Partitioning {} (GPT, {})", d.dev, fw_name(cfg.firmware)));
    let (esp, root_part) = match cfg.firmware {
        Firmware::Uefi => {
            let (e, r) = disk::partition_uefi(&d)?;
            (Some(e), r)
        }
        Firmware::Bios => (None, disk::partition_bios(&d)?),
    };

    // ── LUKS (optional) ─────────────────────────────────────────────────────
    let mut rootfs_dev = root_part.clone();
    let mut crypt_uuid = None;
    if let Some(pw) = &cfg.luks_pw {
        step(emit, "Encrypting root partition (LUKS2)");
        rootfs_dev = luks_setup(&root_part, pw)?;
        crypt_uuid = Some(disk::uuid(&root_part));
    }

    // ── Format + mount ──────────────────────────────────────────────────────
    step(emit, "Formatting filesystems");
    if let Some(e) = &esp {
        disk::mkfs_fat(e, "EFI")?;
    }
    disk::mkfs_ext4(&rootfs_dev, "blueberry-root")?;

    step(emit, "Mounting target");
    fs::create_dir_all(MNT).ok();
    check(&["mount", &rootfs_dev, MNT])?;
    if let Some(e) = &esp {
        fs::create_dir_all(format!("{MNT}/boot/efi")).ok();
        check(&["mount", e, &format!("{MNT}/boot/efi")])?;
    }

    // ── Root filesystem ─────────────────────────────────────────────────────
    step(emit, "Extracting root filesystem (this takes a few minutes)");
    crate::run::sh_check(&format!(
        "zstd -dcq {}/rootfs.tar.zst | tar -x -C {MNT}",
        payload.dir
    ))?;

    // ── Online mode: fetch the desktop set with bpm ─────────────────────────
    if let Some(pkgs) = &payload.manifest {
        step(emit, &format!("Downloading + installing {} packages (online)", pkgs.len()));
        disk::ensure_network();
        logln(emit, "bpm update…");
        if !run(&["sh", "-c", &format!("BPM_ROOT={MNT} bpm update")]) {
            return Err("bpm update failed — is the network up? (online install needs the repo)".into());
        }
        let list = pkgs.join(" ");
        logln(emit, &format!("bpm install {list}"));
        if !run(&["sh", "-c", &format!("BPM_ROOT={MNT} bpm install {list}")]) {
            return Err("bpm install of the desktop set failed".into());
        }
    }

    // ── Config overlay (online desktop config / branding) ───────────────────
    if payload.overlay {
        step(emit, "Applying system configuration overlay");
        crate::run::sh_check(&format!(
            "zstd -dcq {}/overlay.tar.zst | tar -x -C {MNT}",
            payload.dir
        ))?;
    }

    // ── Kernel + bootloader ─────────────────────────────────────────────────
    step(emit, "Installing kernel + initramfs");
    boot::install_kernel(MNT, &payload.dir)?;

    let uuid = disk::uuid(&rootfs_dev);
    if uuid.is_empty() {
        return Err("could not read root filesystem UUID".into());
    }
    let (root_spec, cryptarg) = match &crypt_uuid {
        Some(cu) => (
            "/dev/mapper/cryptroot".to_string(),
            format!("cryptdevice=UUID={cu}:cryptroot "),
        ),
        None => (format!("UUID={uuid}"), String::new()),
    };

    step(emit, &format!("Installing GRUB ({})", fw_name(cfg.firmware)));
    match cfg.firmware {
        Firmware::Bios => boot::install_grub_bios(&d.dev, MNT, &payload.dir)?,
        Firmware::Uefi => boot::install_grub_uefi(MNT, &format!("{MNT}/boot/efi"), &payload.dir)?,
    }
    boot::write_grub_cfg(MNT, &uuid, &root_spec, &cryptarg)?;

    // ── System configuration ────────────────────────────────────────────────
    step(emit, "Writing system configuration");
    if let Some(cu) = &crypt_uuid {
        let _ = fs::write(
            format!("{MNT}/etc/crypttab"),
            format!("cryptroot  UUID={cu}  none  luks\n"),
        );
    }
    let esp_uuid = esp.as_deref().map(disk::uuid).filter(|u| !u.is_empty());
    boot::write_fstab(MNT, &root_spec, esp_uuid.as_deref())?;

    let host = if cfg.hostname.trim().is_empty() { "blueberry" } else { cfg.hostname.trim() };
    let _ = fs::write(format!("{MNT}/etc/hostname"), format!("{host}\n"));

    // Keymap: console (systemd-vconsole-setup) + Wayland/X11 (KWin/SDDM read
    // the XDG-wide kxkbrc). loadkeys+keymaps ship in the kbd package.
    if !cfg.keymap.is_empty() && cfg.keymap != "us" {
        let xkb = KEYMAPS
            .iter()
            .find(|(c, _, _)| *c == cfg.keymap)
            .map(|(_, x, _)| *x)
            .unwrap_or(cfg.keymap.as_str());
        let _ = fs::write(format!("{MNT}/etc/vconsole.conf"), format!("KEYMAP={}\n", cfg.keymap));
        fs::create_dir_all(format!("{MNT}/etc/xdg")).ok();
        let _ = fs::write(
            format!("{MNT}/etc/xdg/kxkbrc"),
            format!("[Layout]\nUse=true\nLayoutList={xkb}\n"),
        );
    }

    // A fresh machine-id (and no interactive firstboot) for the installed system.
    if fs::metadata(format!("{MNT}/etc/machine-id")).map(|m| m.len()).unwrap_or(0) == 0 {
        let id = out(&["sh", "-c", "head -c16 /dev/urandom | od -An -tx1 | tr -d ' \\n'"]);
        let _ = fs::write(format!("{MNT}/etc/machine-id"), format!("{id}\n"));
    }
    let _ = sh(&format!(
        "ln -sf /dev/null {MNT}/etc/systemd/system/systemd-firstboot.service"
    ));

    // Payload tarballs are packed unprivileged, so setuid bits never survive —
    // restore them on the binaries that need them (sudo/polkit/mount…).
    for b in [
        "usr/bin/sudo", "usr/bin/pkexec", "usr/bin/su", "usr/bin/mount",
        "usr/bin/umount", "usr/bin/passwd", "usr/bin/chsh", "usr/bin/chfn",
        "usr/bin/newgrp", "usr/bin/crontab",
        "usr/lib/polkit-1/polkit-agent-helper-1",
        "usr/libexec/dbus-daemon-launch-helper",
    ] {
        let p = format!("{MNT}/{b}");
        if Path::new(&p).exists() {
            let _ = run(&["chmod", "4755", &p]);
        }
    }

    // ── Users ────────────────────────────────────────────────────────────────
    step(emit, "Setting passwords + users");
    boot::set_password(MNT, "root", &cfg.root_pw)?;
    if let Some((name, pw)) = &cfg.user {
        if !name.trim().is_empty() {
            boot::create_user(MNT, name.trim())?;
            if !pw.is_empty() {
                boot::set_password(MNT, name.trim(), pw)?;
            }
            // Desktop niceties: admin (wheel/sudo) + device access groups.
            for g in ["wheel", "video", "audio", "render", "input"] {
                add_to_group(MNT, g, name.trim());
            }
        }
    }

    // ── Swap ─────────────────────────────────────────────────────────────────
    if cfg.swap_gib > 0 {
        step(emit, &format!("Creating {} GiB swapfile", cfg.swap_gib));
        make_swap(cfg.swap_gib, emit);
    }

    // ── Extra packages ───────────────────────────────────────────────────────
    let extra = cfg.extra_pkgs.trim();
    if !extra.is_empty() {
        step(emit, &format!("Installing extra packages: {extra}"));
        disk::ensure_network();
        if !run(&["sh", "-c", &format!("BPM_ROOT={MNT} bpm update")])
            || !run(&["sh", "-c", &format!("BPM_ROOT={MNT} bpm install {extra}")])
        {
            logln(emit, "WARNING: extra packages failed (base system is still fine)");
        }
    }

    // ── Finish ───────────────────────────────────────────────────────────────
    step(emit, "Unmounting");
    let _ = sh(&format!("swapoff {MNT}/swapfile 2>/dev/null"));
    if esp.is_some() {
        run(&["umount", &format!("{MNT}/boot/efi")]);
    }
    run(&["umount", MNT]);
    if crypt_uuid.is_some() {
        run(&["cryptsetup", "close", "cryptroot"]);
    }
    Ok(())
}

pub fn fw_name(f: Firmware) -> &'static str {
    match f {
        Firmware::Uefi => "UEFI",
        Firmware::Bios => "BIOS",
    }
}

fn luks_setup(part: &str, pw: &str) -> R<String> {
    if !run(&["sh", "-c", "command -v cryptsetup >/dev/null 2>&1"]) {
        return Err("cryptsetup is missing from the live image".into());
    }
    let keyfile = "/run/bb-luks.key";
    fs::write(keyfile, pw).map_err(|e| format!("stage LUKS keyfile: {e}"))?;
    let _ = run(&["chmod", "0600", keyfile]);
    let r = check(&[
        "cryptsetup", "luksFormat", "--type", "luks2", "--batch-mode",
        "--pbkdf", "argon2id", "--pbkdf-memory", "262144",
        "--key-file", keyfile, part,
    ])
    .and_then(|_| check(&["cryptsetup", "open", "--key-file", keyfile, part, "cryptroot"]));
    let _ = fs::remove_file(keyfile);
    r?;
    Ok("/dev/mapper/cryptroot".to_string())
}

fn make_swap(gib: u32, emit: Emit) {
    let ok = sh(&format!(
        "fallocate -l {gib}G {MNT}/swapfile 2>/dev/null \
         || dd if=/dev/zero of={MNT}/swapfile bs=1M count={} 2>/dev/null",
        gib as u64 * 1024
    ));
    if !ok {
        logln(emit, "WARNING: could not allocate swapfile; skipping");
        return;
    }
    let _ = run(&["chmod", "600", &format!("{MNT}/swapfile")]);
    let _ = sh(&format!("mkswap {MNT}/swapfile >/dev/null 2>&1"));
    if let Ok(mut f) = fs::OpenOptions::new().append(true).open(format!("{MNT}/etc/fstab")) {
        use std::io::Write;
        let _ = writeln!(f, "/swapfile  none  swap  sw  0 0");
    }
}

/// Append `user` to `group`'s member list in the target's /etc/group (no-op if
/// the group doesn't exist or the user is already in it).
fn add_to_group(mnt: &str, group: &str, user: &str) {
    let path = format!("{mnt}/etc/group");
    let Ok(content) = fs::read_to_string(&path) else { return };
    let mut out_s = String::new();
    for line in content.lines() {
        if line.starts_with(&format!("{group}:")) {
            let members = line.rsplit(':').next().unwrap_or("");
            let already = members.split(',').any(|m| m == user);
            if !already {
                let sep = if members.is_empty() { "" } else { "," };
                out_s.push_str(&format!("{line}{sep}{user}\n"));
                continue;
            }
        }
        out_s.push_str(line);
        out_s.push('\n');
    }
    let _ = fs::write(&path, out_s);
}

/// Locate the payload dir: initramfs-shipped, mounted live medium, or probing
/// block devices for a filesystem holding /blueberry/rootfs.tar.zst.
fn find_payload_dir() -> Option<String> {
    for p in ["/blueberry", "/run/live/medium/blueberry", "/live/medium/blueberry"] {
        if Path::new(&format!("{p}/rootfs.tar.zst")).exists() {
            return Some(p.to_string());
        }
    }
    let mp = "/run/blueberry-media";
    fs::create_dir_all(mp).ok();
    let rd = fs::read_dir("/sys/block").ok()?;
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        if name.starts_with("loop") || name.starts_with("ram") {
            continue;
        }
        let mut cands = vec![format!("/dev/{name}")];
        let sep = if name.chars().last().unwrap_or(' ').is_ascii_digit() { "p" } else { "" };
        for p in 1..=4 {
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
