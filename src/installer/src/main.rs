//! blueberry-install — the Blueberry Linux installer.
//!
//! Three front-ends over one engine (engine.rs):
//!   • TUI (default on a terminal)      — full-screen ratatui, easy to use
//!   • CLI (`--cli`)                    — dialoguer prompts (serial-safe)
//!   • unattended (BLUEBERRY_* env)     — no UI at all; used by `bbinstall`
//!     kernel-cmdline installs and CI (BLUEBERRY_YES=1 BLUEBERRY_TARGET=… )
//!
//! The payload on the boot medium decides WHAT gets installed (server base or
//! desktop, offline tarball or online via bpm) — see engine::Payload.

mod boot;
mod disk;
mod engine;
mod run;
mod tui;
mod ui;

use boot::Firmware;
use engine::{Config, Ev, Payload};
use run::R;
use std::env;
use std::process::exit;

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
    env::set_var("PATH", "/usr/sbin:/usr/bin:/sbin:/bin");
    env::set_var("LD_LIBRARY_PATH", "/usr/lib:/lib");
    if env::var("TERM").is_err() {
        env::set_var("TERM", "linux");
    }

    let payload = Payload::discover().ok_or(
        "could not find the install payload (rootfs.tar.zst) on any boot medium",
    )?;

    let unattended = ui::yes_mode() || env::var("BLUEBERRY_TARGET").is_ok();
    let cli = env::args().any(|a| a == "--cli");

    if unattended {
        println!("\n=== Blueberry Linux installer ({}) — unattended ===", payload.name);
        let cfg = config_from_env(&payload)?;
        let mut emit = |e: Ev| match e {
            Ev::Step(s) => println!("\n:: {s}"),
            Ev::Log(s) => println!("   {s}"),
        };
        engine::run_install(&cfg, &payload, &mut emit)?;
        println!("\n=== Installation complete. Remove the install medium and reboot. ===");
        return Ok(());
    }

    if cli {
        println!("\n=== Blueberry Linux installer ({}) ===", payload.name);
        let cfg = config_from_prompts(&payload)?;
        let mut emit = |e: Ev| match e {
            Ev::Step(s) => println!("\n:: {s}"),
            Ev::Log(s) => println!("   {s}"),
        };
        engine::run_install(&cfg, &payload, &mut emit)?;
        println!("\n=== Installation complete. Remove the install medium and reboot. ===");
        return Ok(());
    }

    // Default: the TUI. If it can't start (dumb terminal), fall back to CLI.
    let disks = disk::list();
    match tui::run(payload, disks, boot::detect_firmware()) {
        Ok(true) => Ok(()),   // installed — exit 0, init reboots
        Ok(false) => Err("installation cancelled".into()),
        Err(e) => Err(format!("TUI failed ({e}); re-run with --cli for prompt mode")),
    }
}

/// Unattended config straight from BLUEBERRY_* (defaults where unset).
fn config_from_env(payload: &Payload) -> R<Config> {
    let disks = disk::list();
    if disks.is_empty() {
        return Err("no installable disks found".into());
    }
    let disk_dev = env::var("BLUEBERRY_TARGET").unwrap_or_else(|_| disks[0].dev.clone());
    if !disks.iter().any(|d| d.dev == disk_dev) {
        return Err(format!("BLUEBERRY_TARGET={disk_dev} is not an available disk"));
    }
    let firmware = match env::var("BLUEBERRY_BOOTLOADER").unwrap_or_default().to_lowercase().as_str() {
        "bios" => Firmware::Bios,
        "uefi" => Firmware::Uefi,
        _ => boot::detect_firmware(),
    };
    let user = match env::var("BLUEBERRY_USER") {
        Ok(u) if !u.trim().is_empty() => Some((
            u.trim().to_string(),
            env::var("BLUEBERRY_USERPW").unwrap_or_default(),
        )),
        _ => None,
    };
    let luks_on = matches!(
        env::var("BLUEBERRY_LUKS").unwrap_or_default().as_str(),
        "1" | "y" | "yes" | "true"
    );
    let _ = payload; // profile driven by the payload itself
    Ok(Config {
        disk_dev,
        firmware,
        keymap: env::var("BLUEBERRY_KEYMAP").unwrap_or_else(|_| "us".into()),
        hostname: env::var("BLUEBERRY_HOSTNAME").unwrap_or_else(|_| "blueberry".into()),
        root_pw: env::var("BLUEBERRY_ROOTPW").unwrap_or_else(|_| "blueberry".into()),
        user,
        swap_gib: env::var("BLUEBERRY_SWAP").ok().and_then(|s| s.parse().ok()).unwrap_or(0),
        luks_pw: if luks_on { env::var("BLUEBERRY_LUKSPW").ok() } else { None },
        extra_pkgs: env::var("BLUEBERRY_PKGS").unwrap_or_default(),
    })
}

/// Interactive dialoguer prompts (the `--cli` path, serial-safe).
fn config_from_prompts(payload: &Payload) -> R<Config> {
    let disks = disk::list();
    if disks.is_empty() {
        return Err("no installable disks found".into());
    }
    let items: Vec<String> = disks
        .iter()
        .map(|d| format!("{:<12} {:>7.1} GiB  {}", d.dev, d.gib(), d.model))
        .collect();
    let di = ui::select("Select the disk to INSTALL TO (erased!)", &items, 0, "BLUEBERRY_TARGET_IDX");

    let fw_detected = boot::detect_firmware();
    let mut fw_items = Vec::new();
    let mut fw_kinds = Vec::new();
    if boot::uefi_available(&payload.dir) {
        fw_items.push("GRUB — UEFI (x86_64-efi)".to_string());
        fw_kinds.push(Firmware::Uefi);
    }
    if boot::bios_available(&payload.dir) {
        fw_items.push("GRUB — BIOS (i386-pc)".to_string());
        fw_kinds.push(Firmware::Bios);
    }
    let fdef = fw_kinds.iter().position(|k| *k == fw_detected).unwrap_or(0);
    let fi = ui::select("Bootloader", &fw_items, fdef, "BLUEBERRY_BOOTLOADER");

    println!("\nThis will ERASE ALL DATA on {}.", disks[di].dev);
    if !ui::confirm("Proceed and erase this disk?", false, "BLUEBERRY_ERASE_OK") {
        return Err("aborted by user".into());
    }

    let km_items: Vec<String> = engine::KEYMAPS.iter().map(|(c, _, l)| format!("{l} ({c})")).collect();
    let ki = ui::select("Keyboard layout", &km_items, 0, "BLUEBERRY_KEYMAP");
    let keymap = engine::KEYMAPS[ki].0.to_string();
    let _ = crate::run::out(&["loadkeys", &keymap]); // apply live for the prompts below
    let hostname = ui::input("Hostname", "blueberry", "BLUEBERRY_HOSTNAME");
    let root_pw = ui::password("Root password", "BLUEBERRY_ROOTPW", false)
        .ok_or("a root password is required")?;
    let user_name = ui::input("Create a non-root user (blank to skip)", "", "BLUEBERRY_USER");
    let user = if user_name.trim().is_empty() {
        None
    } else {
        let pw = ui::password(&format!("Password for {}", user_name.trim()), "BLUEBERRY_USERPW", false)
            .ok_or("a user password is required")?;
        Some((user_name.trim().to_string(), pw))
    };
    let swap: u32 = ui::input("Swapfile size in GiB (0 to skip)", "0", "BLUEBERRY_SWAP")
        .trim()
        .parse()
        .unwrap_or(0);
    let luks_pw = if ui::confirm("Encrypt the system with LUKS?", false, "BLUEBERRY_LUKS") {
        Some(ui::password("LUKS passphrase", "BLUEBERRY_LUKSPW", false).ok_or("a LUKS passphrase is required")?)
    } else {
        None
    };
    let extra_pkgs = ui::input("Extra packages (space-separated, blank to skip)", "", "BLUEBERRY_PKGS");

    Ok(Config {
        disk_dev: disks[di].dev.clone(),
        firmware: fw_kinds[fi],
        keymap,
        hostname,
        root_pw,
        user,
        swap_gib: swap,
        luks_pw,
        extra_pkgs,
    })
}
