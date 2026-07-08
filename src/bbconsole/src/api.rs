//! API handlers. Read-only endpoints shell out to the tools that already exist
//! on a Blueberry box (systemctl, bpm) or read /proc directly. Write actions are
//! deliberately few and audited (see main.rs). Everything is namespaced under
//! /api/v1 so the far-vision surface can grow without breaking clients.

use serde_json::{json, Value};
use std::fs;
use std::process::Command;

/// GET /api/v1/system — host identity + live load/memory. No external tools.
pub fn system() -> Value {
    let hostname = fs::read_to_string("/proc/sys/kernel/hostname")
        .unwrap_or_default()
        .trim()
        .to_string();
    let kernel = fs::read_to_string("/proc/sys/kernel/osrelease")
        .unwrap_or_default()
        .trim()
        .to_string();
    let uptime = fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|s| s.split_whitespace().next().map(str::to_string))
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(0.0);
    let loadavg = fs::read_to_string("/proc/loadavg").unwrap_or_default();
    let load: Vec<f64> = loadavg
        .split_whitespace()
        .take(3)
        .filter_map(|s| s.parse().ok())
        .collect();

    // Memory from /proc/meminfo (kB).
    let mut mem_total = 0u64;
    let mut mem_avail = 0u64;
    if let Ok(mi) = fs::read_to_string("/proc/meminfo") {
        for l in mi.lines() {
            let mut p = l.split_whitespace();
            match p.next() {
                Some("MemTotal:") => mem_total = p.next().and_then(|v| v.parse().ok()).unwrap_or(0),
                Some("MemAvailable:") => {
                    mem_avail = p.next().and_then(|v| v.parse().ok()).unwrap_or(0)
                }
                _ => {}
            }
        }
    }

    // os-release PRETTY_NAME for branding.
    let mut pretty = String::new();
    if let Ok(osr) = fs::read_to_string("/etc/os-release") {
        for l in osr.lines() {
            if let Some(v) = l.strip_prefix("PRETTY_NAME=") {
                pretty = v.trim_matches('"').to_string();
            }
        }
    }

    json!({
        "hostname": hostname,
        "os": pretty,
        "kernel": kernel,
        "uptime_seconds": uptime as u64,
        "load": load,
        "memory": { "total_kb": mem_total, "available_kb": mem_avail },
    })
}

/// GET /api/v1/services — systemd services and their state.
pub fn services() -> Value {
    let out = Command::new("systemctl")
        .args(["list-units", "--type=service", "--all", "--no-legend", "--plain", "--no-pager"])
        .output();
    let mut list = Vec::new();
    if let Ok(o) = out {
        for line in String::from_utf8_lossy(&o.stdout).lines() {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() >= 4 {
                list.push(json!({
                    "unit": f[0], "load": f[1], "active": f[2], "sub": f[3],
                    "description": f[4..].join(" "),
                }));
            }
        }
    }
    json!({ "services": list })
}

/// POST /api/v1/services/{start,stop,restart} — a WRITE action (audited by caller).
pub fn service_action(action: &str, unit: &str) -> Result<Value, String> {
    if !matches!(action, "start" | "stop" | "restart") {
        return Err("unsupported action".into());
    }
    // Only operate on plausible unit names, never arbitrary args. A leading '-'
    // would let the name be parsed as a systemctl *option* (argument injection:
    // e.g. `--version` reports success), so reject it, and pass `--` so the shell
    // of systemctl treats the name as strictly positional regardless.
    if unit.is_empty()
        || unit.starts_with('-')
        || !unit.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.@".contains(&b))
    {
        return Err("invalid unit name".into());
    }
    let out = Command::new("systemctl").args([action, "--", unit]).output();
    match out {
        Ok(o) if o.status.success() => Ok(json!({ "ok": true, "unit": unit, "action": action })),
        Ok(o) => Err(String::from_utf8_lossy(&o.stderr).trim().to_string()),
        Err(e) => Err(e.to_string()),
    }
}

/// GET /api/v1/packages — installed packages via bpm (empty if bpm absent).
pub fn packages() -> Value {
    let out = Command::new("bpm").arg("list").output();
    let mut list = Vec::new();
    if let Ok(o) = out {
        for line in String::from_utf8_lossy(&o.stdout).lines() {
            let mut p = line.split_whitespace();
            if let Some(name) = p.next() {
                list.push(json!({ "name": name, "version": p.next().unwrap_or("") }));
            }
        }
    }
    json!({ "packages": list, "manager": "bpm" })
}

/// The far-vision surface, stubbed so the shape is stable for the frontend.
/// Each becomes a real module: containers (podman), logs (journald), updates +
/// snapshot/rollback (bpm + btrfs), storage (lvm/btrfs), network (nftables).
pub fn not_implemented(area: &str) -> Value {
    json!({
        "error": "not implemented yet",
        "area": area,
        "planned": true,
    })
}
