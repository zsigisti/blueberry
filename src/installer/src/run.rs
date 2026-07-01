//! Small command-execution helpers. The installer shells out to the system disk
//! tools (sgdisk, mkfs.*, grub-install, …); these wrap that plumbing.

use std::process::{Command, Stdio};

/// A convenience result type for the whole installer.
pub type R<T> = Result<T, String>;

/// Run a command, inheriting stdio (so the user sees progress). Returns the exit
/// status as a plain bool (true = success).
pub fn run(argv: &[&str]) -> bool {
    status(argv).map(|c| c == 0).unwrap_or(false)
}

/// Run a command, returning Err with context on any non-zero exit.
pub fn check(argv: &[&str]) -> R<()> {
    match status(argv) {
        Ok(0) => Ok(()),
        Ok(c) => Err(format!("command failed ({c}): {}", argv.join(" "))),
        Err(e) => Err(format!("could not run {}: {e}", argv.join(" "))),
    }
}

/// Run a `/bin/sh -c` pipeline (for the few places a pipe is genuinely simplest).
pub fn sh(cmd: &str) -> bool {
    Command::new("/bin/sh")
        .args(["-c", cmd])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Run a pipeline, die-on-failure.
pub fn sh_check(cmd: &str) -> R<()> {
    if sh(cmd) {
        Ok(())
    } else {
        Err(format!("command failed: {cmd}"))
    }
}

/// Capture a command's stdout, trimmed. Empty string on any error.
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

/// `:: message` progress line, matching the old C installer's style.
pub fn step(msg: &str) {
    println!("\n:: {msg}");
}
