//! Web installer — drive the unattended `blueberry-install` from the console, so
//! a headless box can be installed to a disk from a browser. Deliberately gated
//! to the LIVE installer environment (root on live/RAM media): it erases a disk,
//! so it must never be offered on an already-installed running system.

use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};

/// In-memory state of the single install job (there is only ever one).
#[derive(Default)]
pub struct InstallJob {
    pub running: bool,
    pub done: bool,
    pub ok: bool,
    pub log: String,
}

impl InstallJob {
    pub fn snapshot(&self) -> Value {
        json!({ "running": self.running, "done": self.done, "ok": self.ok, "log": self.log })
    }
}

/// True when `/` is a live/RAM filesystem — the only context where offering to
/// erase a disk and install is safe (an installed system has a real root fs).
fn root_is_live() -> bool {
    if let Ok(m) = fs::read_to_string("/proc/mounts") {
        for l in m.lines() {
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.len() >= 3 && f[1] == "/" {
                return matches!(f[2], "overlay" | "tmpfs" | "squashfs" | "aufs" | "rootfs");
            }
        }
    }
    false
}

fn installer_present() -> bool {
    ["/usr/bin/blueberry-install", "/usr/sbin/blueberry-install", "/sbin/blueberry-install", "/bin/blueberry-install"]
        .iter()
        .any(|p| std::path::Path::new(p).exists())
}

/// Candidate install-target disks (scan /sys/block, like the installer does).
pub fn list_disks() -> Vec<Value> {
    let mut v: Vec<(String, Value)> = Vec::new();
    if let Ok(rd) = fs::read_dir("/sys/block") {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if !["sd", "nvme", "vd", "mmcblk"].iter().any(|p| name.starts_with(p)) {
                continue;
            }
            let bytes = fs::read_to_string(format!("/sys/block/{name}/size"))
                .ok()
                .and_then(|s| s.trim().parse::<u64>().ok())
                .map(|s| s * 512)
                .unwrap_or(0);
            let model = fs::read_to_string(format!("/sys/block/{name}/device/model"))
                .map(|s| s.trim().to_string())
                .unwrap_or_default();
            v.push((name.clone(), json!({ "dev": format!("/dev/{name}"), "name": name, "bytes": bytes, "model": model })));
        }
    }
    v.sort_by(|a, b| a.0.cmp(&b.0));
    v.into_iter().map(|(_, j)| j).collect()
}

/// GET /api/v1/installer — availability + target disks + detected firmware.
pub fn info() -> Value {
    let live = root_is_live();
    let present = installer_present();
    let uefi = std::path::Path::new("/sys/firmware/efi").exists();
    json!({
        "available": live && present,
        "live": live,
        "installer_present": present,
        "firmware": if uefi { "uefi" } else { "bios" },
        "disks": list_disks(),
        "filesystems": ["btrfs", "ext4", "xfs"],
    })
}

fn valid_disk(dev: &str) -> bool {
    list_disks().iter().any(|d| d.get("dev").and_then(|x| x.as_str()) == Some(dev))
}
fn valid_host(s: &str) -> bool {
    !s.is_empty() && s.len() <= 63 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}
fn valid_user(s: &str) -> bool {
    s.is_empty()
        || (s.len() <= 32
            && s.bytes().enumerate().all(|(i, b)| b.is_ascii_lowercase() || b.is_ascii_digit() || (i > 0 && (b == b'-' || b == b'_'))))
}

/// Validate a start request and return the `BLUEBERRY_*` env for the installer.
pub fn build_env(req: &Value) -> Result<Vec<(String, String)>, String> {
    if !(root_is_live() && installer_present()) {
        return Err("installer not available in this environment".into());
    }
    let get = |k: &str| req.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
    let target = get("target");
    if !valid_disk(&target) {
        return Err("invalid or unknown target disk".into());
    }
    let fs = get("fs");
    if !["btrfs", "ext4", "xfs"].contains(&fs.as_str()) {
        return Err("invalid filesystem".into());
    }
    let bootloader = match get("bootloader").as_str() {
        "uefi" => "uefi".to_string(),
        "bios" => "bios".to_string(),
        _ => if std::path::Path::new("/sys/firmware/efi").exists() { "uefi".into() } else { "bios".into() },
    };
    let hostname = {
        let h = get("hostname");
        if h.is_empty() { "blueberry".into() } else { h }
    };
    if !valid_host(&hostname) {
        return Err("invalid hostname".into());
    }
    let rootpw = get("rootpw");
    if rootpw.is_empty() {
        return Err("a root password is required".into());
    }
    let user = get("user");
    if !valid_user(&user) {
        return Err("invalid username".into());
    }

    let mut env = vec![
        ("BLUEBERRY_TARGET".to_string(), target),
        ("BLUEBERRY_FS".to_string(), fs),
        ("BLUEBERRY_BOOTLOADER".to_string(), bootloader),
        ("BLUEBERRY_HOSTNAME".to_string(), hostname),
        ("BLUEBERRY_ROOTPW".to_string(), rootpw),
        ("BLUEBERRY_YES".to_string(), "1".to_string()),
        ("BLUEBERRY_ERASE_OK".to_string(), "1".to_string()),
    ];
    if !user.is_empty() {
        env.push(("BLUEBERRY_USER".to_string(), user));
        env.push(("BLUEBERRY_USERPW".to_string(), get("userpw")));
    }
    Ok(env)
}

/// Spawn the install on a background thread, streaming combined output into the
/// shared job log. Errors if an install is already running.
pub fn start(job: Arc<Mutex<InstallJob>>, env: Vec<(String, String)>) -> Result<(), String> {
    {
        let mut j = job.lock().unwrap();
        if j.running {
            return Err("an install is already running".into());
        }
        *j = InstallJob { running: true, done: false, ok: false, log: String::new() };
    }
    std::thread::spawn(move || {
        let mut cmd = Command::new("sh");
        cmd.args(["-c", "exec blueberry-install 2>&1"]);
        for (k, v) in &env {
            cmd.env(k, v);
        }
        cmd.stdout(Stdio::piped());
        match cmd.spawn() {
            Ok(mut child) => {
                if let Some(out) = child.stdout.take() {
                    for line in BufReader::new(out).lines().map_while(Result::ok) {
                        let mut j = job.lock().unwrap();
                        j.log.push_str(&line);
                        j.log.push('\n');
                        if j.log.len() > 256 * 1024 {
                            let cut = j.log.len() - 200 * 1024;
                            j.log.drain(..cut);
                        }
                    }
                }
                let ok = child.wait().map(|s| s.success()).unwrap_or(false);
                let mut j = job.lock().unwrap();
                j.running = false;
                j.done = true;
                j.ok = ok;
            }
            Err(e) => {
                let mut j = job.lock().unwrap();
                j.running = false;
                j.done = true;
                j.ok = false;
                j.log.push_str(&format!("failed to launch blueberry-install: {e}\n"));
            }
        }
    });
    Ok(())
}
