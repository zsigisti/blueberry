//! Thin wrappers for shelling out to sgdisk, mkfs.*, grub-install and friends.

use std::process::{Command, Stdio};

pub type R<T> = Result<T, String>;

/// Run with inherited stdio; true on exit 0.
pub fn run(argv: &[&str]) -> bool {
    status(argv).map(|c| c == 0).unwrap_or(false)
}

pub fn check(argv: &[&str]) -> R<()> {
    match status(argv) {
        Ok(0) => Ok(()),
        Ok(c) => Err(format!("command failed ({c}): {}", argv.join(" "))),
        Err(e) => Err(format!("could not run {}: {e}", argv.join(" "))),
    }
}

/// For the few spots where a pipe is just easier.
pub fn sh(cmd: &str) -> bool {
    Command::new("/bin/sh")
        .args(["-c", cmd])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub fn sh_check(cmd: &str) -> R<()> {
    if sh(cmd) {
        Ok(())
    } else {
        Err(format!("command failed: {cmd}"))
    }
}

/// Trimmed stdout, or "" if anything went wrong.
pub fn out(argv: &[&str]) -> String {
    Command::new(argv[0])
        .args(&argv[1..])
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

fn status(argv: &[&str]) -> std::io::Result<i32> {
    Command::new(argv[0])
        .args(&argv[1..])
        .status()
        .map(|s| s.code().unwrap_or(-1))
}
