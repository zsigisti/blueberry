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

    // Memory + swap from /proc/meminfo (kB).
    let (mut mem_total, mut mem_avail, mut swap_total, mut swap_free) = (0u64, 0u64, 0u64, 0u64);
    if let Ok(mi) = fs::read_to_string("/proc/meminfo") {
        for l in mi.lines() {
            let mut p = l.split_whitespace();
            match p.next() {
                Some("MemTotal:") => mem_total = p.next().and_then(|v| v.parse().ok()).unwrap_or(0),
                Some("MemAvailable:") => mem_avail = p.next().and_then(|v| v.parse().ok()).unwrap_or(0),
                Some("SwapTotal:") => swap_total = p.next().and_then(|v| v.parse().ok()).unwrap_or(0),
                Some("SwapFree:") => swap_free = p.next().and_then(|v| v.parse().ok()).unwrap_or(0),
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

    // CPU model + core count from /proc/cpuinfo.
    let (mut cpu_model, mut cores) = (String::new(), 0u32);
    if let Ok(ci) = fs::read_to_string("/proc/cpuinfo") {
        for l in ci.lines() {
            if l.starts_with("processor") {
                cores += 1;
            } else if cpu_model.is_empty() && l.starts_with("model name") {
                if let Some((_, v)) = l.split_once(':') {
                    cpu_model = v.trim().to_string();
                }
            }
        }
    }
    // Running processes = numeric entries in /proc.
    let processes = fs::read_dir("/proc")
        .map(|rd| {
            rd.filter_map(Result::ok)
                .filter(|e| {
                    let n = e.file_name();
                    let n = n.to_string_lossy();
                    !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit())
                })
                .count()
        })
        .unwrap_or(0);

    json!({
        "hostname": hostname,
        "os": pretty,
        "kernel": kernel,
        "uptime_seconds": uptime as u64,
        "load": load,
        "memory": { "total_kb": mem_total, "available_kb": mem_avail },
        "swap": { "total_kb": swap_total, "free_kb": swap_free },
        "cpu": { "model": cpu_model, "cores": cores },
        "processes": processes,
    })
}

/// Aggregate + per-core (idle, total) jiffy counters from /proc/stat.
fn cpu_times() -> ((u64, u64), Vec<(u64, u64)>) {
    let stat = fs::read_to_string("/proc/stat").unwrap_or_default();
    let (mut agg, mut cores) = ((0u64, 0u64), Vec::new());
    for l in stat.lines() {
        if !l.starts_with("cpu") {
            break; // cpu lines come first
        }
        let mut p = l.split_whitespace();
        let label = p.next().unwrap_or("");
        let vals: Vec<u64> = p.filter_map(|v| v.parse().ok()).collect();
        if vals.len() < 4 {
            continue;
        }
        let idle = vals[3] + vals.get(4).copied().unwrap_or(0); // idle + iowait
        let total: u64 = vals.iter().sum();
        if label == "cpu" {
            agg = (idle, total);
        } else {
            cores.push((idle, total));
        }
    }
    (agg, cores)
}

/// Busy percentage between two /proc/stat samples, rounded to 0.1.
fn cpu_pct(a: (u64, u64), b: (u64, u64)) -> f64 {
    let didle = b.0.saturating_sub(a.0) as f64;
    let dtotal = b.1.saturating_sub(a.1) as f64;
    if dtotal <= 0.0 {
        0.0
    } else {
        (((1.0 - didle / dtotal) * 100.0).clamp(0.0, 100.0) * 10.0).round() / 10.0
    }
}

/// GET /api/v1/metrics — a fresh live sample: overall + per-core CPU%, memory,
/// swap, load. Samples /proc/stat twice ~120ms apart so the UI can show live
/// utilisation without the client tracking deltas.
pub fn metrics() -> Value {
    let s1 = cpu_times();
    std::thread::sleep(std::time::Duration::from_millis(120));
    let s2 = cpu_times();
    let per_core: Vec<Value> = s1
        .1
        .iter()
        .zip(s2.1.iter())
        .map(|(a, b)| json!(cpu_pct(*a, *b)))
        .collect();

    let load: Vec<f64> = fs::read_to_string("/proc/loadavg")
        .unwrap_or_default()
        .split_whitespace()
        .take(3)
        .filter_map(|s| s.parse().ok())
        .collect();
    let (mut mt, mut ma) = (0u64, 0u64);
    if let Ok(mi) = fs::read_to_string("/proc/meminfo") {
        for l in mi.lines() {
            let mut p = l.split_whitespace();
            match p.next() {
                Some("MemTotal:") => mt = p.next().and_then(|v| v.parse().ok()).unwrap_or(0),
                Some("MemAvailable:") => ma = p.next().and_then(|v| v.parse().ok()).unwrap_or(0),
                _ => {}
            }
        }
    }
    json!({
        "cpu_pct": cpu_pct(s1.0, s2.0),
        "per_core": per_core,
        "memory": { "total_kb": mt, "available_kb": ma },
        "load": load,
    })
}

/// GET /api/v1/logs — recent journald entries as JSON (bounded, read-only).
pub fn logs(lines: u32, priority: Option<u8>, unit: Option<&str>) -> Value {
    let mut args: Vec<String> =
        vec!["-o".into(), "json".into(), "--no-pager".into(), "-n".into(), lines.clamp(1, 500).to_string()];
    if let Some(p) = priority {
        args.push("-p".into());
        args.push(p.min(7).to_string());
    }
    if let Some(u) = unit {
        if !u.is_empty() {
            args.push("-u".into());
            args.push(u.to_string());
        }
    }
    let mut entries = Vec::new();
    if let Ok(o) = Command::new("journalctl").args(&args).output() {
        for line in String::from_utf8_lossy(&o.stdout).lines() {
            let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
            let get = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
            let ts = get("__REALTIME_TIMESTAMP").parse::<u64>().map(|us| us / 1_000_000).unwrap_or(0);
            // MESSAGE is usually a string, occasionally a byte array (binary log).
            let msg = match v.get("MESSAGE") {
                Some(Value::String(s)) => s.clone(),
                Some(Value::Array(a)) => a.iter().filter_map(|b| b.as_u64()).map(|b| b as u8 as char).collect(),
                _ => String::new(),
            };
            let unit = {
                let u = get("_SYSTEMD_UNIT");
                if u.is_empty() { get("SYSLOG_IDENTIFIER") } else { u }
            };
            entries.push(json!({
                "t": ts,
                "priority": get("PRIORITY").parse::<u8>().unwrap_or(6),
                "unit": unit,
                "message": msg,
            }));
        }
    }
    json!({ "entries": entries })
}

/// GET /api/v1/storage — mounted filesystems (df) + block devices (lsblk if present).
pub fn storage() -> Value {
    let mut filesystems = Vec::new();
    if let Ok(o) = Command::new("df").args(["-Pk"]).output() {
        for line in String::from_utf8_lossy(&o.stdout).lines().skip(1) {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() >= 6 {
                filesystems.push(json!({
                    "source": f[0],
                    "total": f[1].parse::<u64>().unwrap_or(0) * 1024,
                    "used": f[2].parse::<u64>().unwrap_or(0) * 1024,
                    "available": f[3].parse::<u64>().unwrap_or(0) * 1024,
                    "use_pct": f[4].trim_end_matches('%').parse::<u32>().unwrap_or(0),
                    "mount": f[5..].join(" "),
                }));
            }
        }
    }
    // Block devices — best effort (util-linux lsblk); omitted if unavailable.
    let mut devices = Vec::new();
    if let Ok(o) = Command::new("lsblk").args(["-J", "-b", "-o", "NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE"]).output() {
        if let Ok(v) = serde_json::from_slice::<Value>(&o.stdout) {
            if let Some(bd) = v.get("blockdevices").and_then(|b| b.as_array()) {
                devices = bd.clone();
            }
        }
    }
    json!({ "filesystems": filesystems, "devices": devices })
}

/// GET /api/v1/network — interfaces (link state, MAC, addresses) + default gateway.
pub fn network() -> Value {
    use std::collections::BTreeMap;
    let mut ifaces: BTreeMap<String, Value> = BTreeMap::new();

    // Addresses (`ip -o addr`): "3: eth0    inet 192.168.0.5/24 ..."
    if let Ok(o) = Command::new("ip").args(["-o", "addr", "show"]).output() {
        for line in String::from_utf8_lossy(&o.stdout).lines() {
            let toks: Vec<&str> = line.split_whitespace().collect();
            if toks.len() < 4 {
                continue;
            }
            let name = toks[1].trim_end_matches(':').to_string();
            let e = ifaces.entry(name.clone()).or_insert_with(|| json!({ "name": name, "addrs": [] }));
            for w in toks.windows(2) {
                if (w[0] == "inet" || w[0] == "inet6") && !w[1].is_empty() {
                    e["addrs"].as_array_mut().unwrap().push(json!({ "family": w[0], "address": w[1] }));
                    break;
                }
            }
        }
    }
    // Link state + MAC (`ip -o link`).
    if let Ok(o) = Command::new("ip").args(["-o", "link", "show"]).output() {
        for line in String::from_utf8_lossy(&o.stdout).lines() {
            let toks: Vec<&str> = line.split_whitespace().collect();
            if toks.len() < 2 {
                continue;
            }
            let name = toks[1].trim_end_matches(':').split('@').next().unwrap_or("").to_string();
            let up = line.contains("state UP") || line.contains("LOWER_UP");
            let mut mac = "";
            for w in toks.windows(2) {
                if w[0] == "link/ether" {
                    mac = w[1];
                    break;
                }
            }
            let e = ifaces.entry(name.clone()).or_insert_with(|| json!({ "name": name, "addrs": [] }));
            e["up"] = json!(up);
            if !mac.is_empty() {
                e["mac"] = json!(mac);
            }
        }
    }
    // Default gateway.
    let mut gateway = String::new();
    if let Ok(o) = Command::new("ip").args(["route", "show", "default"]).output() {
        let s = String::from_utf8_lossy(&o.stdout);
        let toks: Vec<&str> = s.split_whitespace().collect();
        for w in toks.windows(2) {
            if w[0] == "via" {
                gateway = w[1].to_string();
                break;
            }
        }
    }
    json!({ "interfaces": ifaces.into_values().collect::<Vec<_>>(), "gateway": gateway })
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

/// A syntactically valid ZFS pool/dataset name (optionally with an `@snapshot`).
/// No leading '-' (so it can't be read as a zpool/zfs option) and no shell
/// metacharacters. Names are always passed as argv elements, never a shell string.
pub fn valid_zfs_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 256
        && !s.starts_with('-')
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-.:/@".contains(&b))
}

/// GET /api/v1/zfs — pools, datasets, snapshots. Returns { available:false } when
/// the ZFS userland isn't installed, so the frontend degrades gracefully.
pub fn zfs() -> Value {
    let po = match Command::new("zpool")
        .args(["list", "-Hp", "-o", "name,size,alloc,free,health,capacity,fragmentation"])
        .output()
    {
        Ok(o) => o,
        Err(_) => return json!({ "available": false }), // zpool binary absent
    };
    let mut pools = Vec::new();
    for line in String::from_utf8_lossy(&po.stdout).lines() {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() >= 6 {
            pools.push(json!({
                "name": f[0],
                "size": f[1].parse::<u64>().unwrap_or(0),
                "alloc": f[2].parse::<u64>().unwrap_or(0),
                "free": f[3].parse::<u64>().unwrap_or(0),
                "health": f[4],
                "capacity": f[5].parse::<u32>().unwrap_or(0),
                "fragmentation": f.get(6).and_then(|x| x.parse::<u32>().ok()).unwrap_or(0),
            }));
        }
    }
    let mut datasets = Vec::new();
    if let Ok(o) = Command::new("zfs")
        .args(["list", "-Hp", "-t", "filesystem,volume", "-o", "name,used,avail,refer,mountpoint,type"])
        .output()
    {
        for line in String::from_utf8_lossy(&o.stdout).lines() {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() >= 6 {
                datasets.push(json!({
                    "name": f[0], "used": f[1].parse::<u64>().unwrap_or(0),
                    "avail": f[2].parse::<u64>().unwrap_or(0), "refer": f[3].parse::<u64>().unwrap_or(0),
                    "mountpoint": f[4], "type": f[5],
                }));
            }
        }
    }
    let mut snapshots = Vec::new();
    if let Ok(o) = Command::new("zfs")
        .args(["list", "-Hp", "-t", "snapshot", "-o", "name,used,refer,creation"])
        .output()
    {
        for line in String::from_utf8_lossy(&o.stdout).lines() {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() >= 4 {
                snapshots.push(json!({
                    "name": f[0], "used": f[1].parse::<u64>().unwrap_or(0),
                    "refer": f[2].parse::<u64>().unwrap_or(0), "creation": f[3].parse::<u64>().unwrap_or(0),
                }));
            }
        }
    }
    let mut resp = json!({ "available": true, "pools": pools, "datasets": datasets, "snapshots": snapshots });
    // zpool present but e.g. the kernel module isn't loaded → surface the reason.
    if pools.is_empty() && !po.status.success() {
        let note = String::from_utf8_lossy(&po.stderr).trim().to_string();
        if !note.is_empty() {
            resp["note"] = json!(note);
        }
    }
    resp
}

/// POST /api/v1/zfs/{scrub,snapshot} — the few *safe* ZFS write actions. Destroy
/// and pool creation are deliberately omitted from the base layer.
pub fn zfs_action(action: &str, target: &str, snap: Option<&str>) -> Result<Value, String> {
    if !valid_zfs_name(target) {
        return Err("invalid pool/dataset name".into());
    }
    let out = match action {
        "scrub" => Command::new("zpool").args(["scrub", target]).output(),
        "snapshot" => {
            let s = snap.ok_or("missing snapshot name")?;
            if !valid_zfs_name(s) || s.contains('/') || s.contains('@') {
                return Err("invalid snapshot name".into());
            }
            Command::new("zfs").args(["snapshot", &format!("{target}@{s}")]).output()
        }
        _ => return Err("unsupported action".into()),
    };
    match out {
        Ok(o) if o.status.success() => Ok(json!({ "ok": true, "action": action, "target": target })),
        Ok(o) => Err(String::from_utf8_lossy(&o.stderr).trim().to_string()),
        Err(e) => Err(e.to_string()),
    }
}

// ── Btrfs ────────────────────────────────────────────────────────────────────

/// /proc/mounts escapes space/tab/newline/backslash as octal; undo the common ones.
fn unescape_mount(s: &str) -> String {
    s.replace("\\040", " ").replace("\\011", "\t").replace("\\012", "\n").replace("\\134", "\\")
}

/// Distinct btrfs mountpoints from /proc/mounts, as (mountpoint, source device).
fn btrfs_mounts() -> Vec<(String, String)> {
    let mut v: Vec<(String, String)> = Vec::new();
    if let Ok(m) = fs::read_to_string("/proc/mounts") {
        for line in m.lines() {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() >= 3 && f[2] == "btrfs" {
                let mp = unescape_mount(f[1]);
                if !v.iter().any(|(m, _)| m == &mp) {
                    v.push((mp, f[0].to_string()));
                }
            }
        }
    }
    v
}

/// The trailing `path <p>` field of a `btrfs subvolume list` line.
fn subvol_path(line: &str) -> Option<String> {
    line.rsplit_once(" path ").map(|(_, p)| p.trim().to_string())
}

/// GET /api/v1/btrfs — btrfs filesystems (byte usage), their subvolumes and
/// snapshots. { available:false } when btrfs-progs isn't installed.
pub fn btrfs() -> Value {
    if Command::new("btrfs").arg("--version").output().is_err() {
        return json!({ "available": false });
    }
    let mut filesystems = Vec::new();
    for (mp, dev) in btrfs_mounts() {
        let (mut total, mut used) = (0u64, 0u64);
        if let Ok(o) = Command::new("btrfs").args(["filesystem", "usage", "-b", &mp]).output() {
            for l in String::from_utf8_lossy(&o.stdout).lines() {
                let t = l.trim();
                if let Some(v) = t.strip_prefix("Device size:") {
                    total = v.split_whitespace().next().and_then(|x| x.parse().ok()).unwrap_or(0);
                } else if let Some(v) = t.strip_prefix("Used:") {
                    used = v.split_whitespace().next().and_then(|x| x.parse().ok()).unwrap_or(0);
                }
            }
        }
        let mut subvolumes = Vec::new();
        if let Ok(o) = Command::new("btrfs").args(["subvolume", "list", &mp]).output() {
            for l in String::from_utf8_lossy(&o.stdout).lines() {
                if let Some(p) = subvol_path(l) {
                    subvolumes.push(p);
                }
            }
        }
        let mut snapshots = Vec::new();
        if let Ok(o) = Command::new("btrfs").args(["subvolume", "list", "-s", &mp]).output() {
            for l in String::from_utf8_lossy(&o.stdout).lines() {
                if let Some(p) = subvol_path(l) {
                    snapshots.push(p);
                }
            }
        }
        filesystems.push(json!({
            "mount": mp, "device": dev, "total": total, "used": used,
            "subvolumes": subvolumes, "snapshots": snapshots,
        }));
    }
    json!({ "available": true, "filesystems": filesystems })
}

/// A safe snapshot basename: non-empty, no leading '-', no path separators.
pub fn valid_snap_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && !s.starts_with('-')
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-.".contains(&b))
}

/// A relative subvolume path (under a mount): non-empty, no leading '-', no
/// `.`/`..`/empty components, restricted charset.
fn valid_subvol_rel(p: &str) -> bool {
    !p.is_empty()
        && !p.starts_with('-')
        && p.len() <= 512
        && p.split('/').all(|c| {
            !c.is_empty() && c != "." && c != ".." && c.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-.@".contains(&b))
        })
}

/// Subvolume paths currently present under a btrfs mount (for whitelist checks).
fn btrfs_subvols(mount: &str) -> Vec<String> {
    let mut v = Vec::new();
    if let Ok(o) = Command::new("btrfs").args(["subvolume", "list", mount]).output() {
        for l in String::from_utf8_lossy(&o.stdout).lines() {
            if let Some(p) = subvol_path(l) {
                v.push(p);
            }
        }
    }
    v
}

fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Roll back to a snapshot: clone it into a writable subvolume and make that the
/// filesystem's *default* subvolume. Takes effect on the next boot (and requires
/// the root to be mounted by default subvolume, not a pinned `subvol=`). We never
/// touch the live subvolume, so a running system stays intact until it reboots.
fn btrfs_rollback(mount: &str, snap_path: &str) -> Result<Value, String> {
    let dir = format!("{mount}/.snapshots");
    let _ = std::fs::create_dir_all(&dir);
    let rw = format!("{dir}/rollback-{}", now_secs());
    let src = format!("{mount}/{snap_path}");
    let clone = Command::new("btrfs").args(["subvolume", "snapshot", &src, &rw]).output().map_err(|e| e.to_string())?;
    if !clone.status.success() {
        return Err(String::from_utf8_lossy(&clone.stderr).trim().to_string());
    }
    let show = Command::new("btrfs").args(["subvolume", "show", &rw]).output().map_err(|e| e.to_string())?;
    let id = String::from_utf8_lossy(&show.stdout)
        .lines()
        .find_map(|l| l.trim().strip_prefix("Subvolume ID:").map(|v| v.trim().to_string()))
        .ok_or("could not determine the new subvolume id")?;
    let sd = Command::new("btrfs").args(["subvolume", "set-default", &id, mount]).output().map_err(|e| e.to_string())?;
    if !sd.status.success() {
        return Err(String::from_utf8_lossy(&sd.stderr).trim().to_string());
    }
    Ok(json!({ "ok": true, "rollback_subvol": rw, "default_id": id, "reboot_required": true }))
}

/// POST /api/v1/btrfs/{scrub,snapshot,subvol-create,subvol-delete,rollback}.
/// `mount` must be a *current* btrfs mountpoint (whitelisted from /proc/mounts).
/// Delete/rollback targets must be real subvolumes of that mount (whitelisted).
pub fn btrfs_action(action: &str, mount: &str, name: Option<&str>, path: Option<&str>) -> Result<Value, String> {
    if !btrfs_mounts().iter().any(|(m, _)| m == mount) {
        return Err("not a btrfs mountpoint".into());
    }
    let run = |args: &[&str]| -> Result<Value, String> {
        match Command::new("btrfs").args(args).output() {
            Ok(o) if o.status.success() => Ok(json!({ "ok": true, "action": action, "mount": mount })),
            Ok(o) => Err(String::from_utf8_lossy(&o.stderr).trim().to_string()),
            Err(e) => Err(e.to_string()),
        }
    };
    match action {
        "scrub" => run(&["scrub", "start", mount]),
        "snapshot" => {
            let n = name.ok_or("missing snapshot name")?;
            if !valid_snap_name(n) {
                return Err("invalid snapshot name".into());
            }
            let dir = format!("{mount}/.snapshots");
            let _ = std::fs::create_dir_all(&dir);
            let dest = format!("{dir}/{n}");
            run(&["subvolume", "snapshot", "-r", mount, &dest])
        }
        "subvol-create" => {
            let n = name.ok_or("missing name")?;
            if !valid_snap_name(n) {
                return Err("invalid subvolume name".into());
            }
            let dest = format!("{mount}/{n}");
            run(&["subvolume", "create", &dest])
        }
        "subvol-delete" => {
            let p = path.ok_or("missing subvolume path")?;
            if !valid_subvol_rel(p) || !btrfs_subvols(mount).iter().any(|s| s == p) {
                return Err("unknown subvolume".into());
            }
            // btrfs itself refuses to delete a mounted subvolume, so the live
            // root/home can't be removed out from under us.
            run(&["subvolume", "delete", &format!("{mount}/{p}")])
        }
        "rollback" => {
            let p = path.ok_or("missing snapshot path")?;
            if !valid_subvol_rel(p) || !btrfs_subvols(mount).iter().any(|s| s == p) {
                return Err("unknown snapshot".into());
            }
            btrfs_rollback(mount, p)
        }
        _ => Err("unsupported action".into()),
    }
}

// ── Updates (bpm + optional btrfs pre-upgrade snapshot) ──────────────────────

/// Is the root filesystem btrfs? (offer a pre-upgrade snapshot if so).
fn root_is_btrfs() -> bool {
    btrfs_mounts().iter().any(|(mp, _)| mp == "/")
}

/// GET /api/v1/updates — upgradable packages (via `bpm outdated`) + whether the
/// root is btrfs (so the UI can offer a pre-upgrade snapshot).
pub fn updates() -> Value {
    let mut list = Vec::new();
    if let Ok(o) = Command::new("bpm").arg("outdated").output() {
        for l in String::from_utf8_lossy(&o.stdout).lines() {
            let f: Vec<&str> = l.split('\t').collect();
            if f.len() >= 3 {
                list.push(json!({ "name": f[0], "installed": f[1], "available": f[2] }));
            }
        }
    }
    let count = list.len();
    json!({ "updates": list, "count": count, "btrfs_root": root_is_btrfs() })
}

/// POST /api/v1/updates/apply?snapshot=1 — take a read-only btrfs snapshot of the
/// root first (if root is btrfs and requested), then `bpm upgrade`. Synchronous;
/// returns bpm's combined output. The snapshot is the rollback point.
pub fn updates_apply(snapshot: bool) -> Result<Value, String> {
    let mut snap = Value::Null;
    if snapshot && root_is_btrfs() {
        let _ = std::fs::create_dir_all("/.snapshots");
        let dest = format!("/.snapshots/pre-upgrade-{}", now_secs());
        match Command::new("btrfs").args(["subvolume", "snapshot", "-r", "/", &dest]).output() {
            Ok(r) if r.status.success() => snap = json!(dest),
            Ok(r) => return Err(format!("pre-upgrade snapshot failed: {}", String::from_utf8_lossy(&r.stderr).trim())),
            Err(e) => return Err(format!("pre-upgrade snapshot failed: {e}")),
        }
    }
    let up = Command::new("bpm").arg("upgrade").output().map_err(|e| e.to_string())?;
    let out = format!("{}{}", String::from_utf8_lossy(&up.stdout), String::from_utf8_lossy(&up.stderr));
    Ok(json!({ "ok": up.status.success(), "snapshot": snap, "output": out.trim() }))
}

// ── Containers (podman) ──────────────────────────────────────────────────────

/// A valid podman container/image name or id: non-empty, no leading '-' (so it
/// can't be read as a podman option), restricted charset. Always passed as an
/// argv element after `--`, never interpolated into a shell string.
pub fn valid_container_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && !s.starts_with('-')
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.-/:@".contains(&b))
}

/// Join a podman JSON `Names` array (or fall back to a string field) to a label.
fn podman_names(v: &Value, fallback: &str) -> String {
    v.get("Names")
        .and_then(|n| n.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(","))
        .or_else(|| v.get(fallback).and_then(|x| x.as_str()).map(str::to_string))
        .unwrap_or_default()
}

fn short_id(v: &Value) -> String {
    v.get("Id").and_then(|x| x.as_str()).unwrap_or("").chars().take(12).collect()
}

/// GET /api/v1/containers — podman containers (running + stopped) and images.
/// Returns { available:false } when podman isn't installed, so the frontend
/// degrades gracefully (same contract as zfs/btrfs).
pub fn containers() -> Value {
    if Command::new("podman").arg("--version").output().is_err() {
        return json!({ "available": false });
    }
    let mut containers = Vec::new();
    if let Ok(o) = Command::new("podman").args(["ps", "-a", "--format", "json"]).output() {
        if let Ok(Value::Array(arr)) = serde_json::from_slice::<Value>(&o.stdout) {
            for c in arr {
                containers.push(json!({
                    "id": short_id(&c),
                    "names": podman_names(&c, "Names"),
                    "image": c.get("Image").and_then(|v| v.as_str()).unwrap_or(""),
                    "state": c.get("State").and_then(|v| v.as_str()).unwrap_or(""),
                    "status": c.get("Status").and_then(|v| v.as_str()).unwrap_or(""),
                }));
            }
        }
    }
    let mut images = Vec::new();
    if let Ok(o) = Command::new("podman").args(["images", "--format", "json"]).output() {
        if let Ok(Value::Array(arr)) = serde_json::from_slice::<Value>(&o.stdout) {
            for im in arr {
                images.push(json!({
                    "id": short_id(&im),
                    "names": podman_names(&im, "Repository"),
                    "size": im.get("Size").and_then(|v| v.as_u64()).unwrap_or(0),
                }));
            }
        }
    }
    json!({ "available": true, "containers": containers, "images": images })
}

/// GET /api/v1/containers/logs?name=<c>&lines=<n> — tail a container's logs.
pub fn container_logs(name: &str, lines: u32) -> Result<Value, String> {
    if !valid_container_name(name) {
        return Err("invalid container name".into());
    }
    let n = lines.clamp(1, 1000).to_string();
    let out = Command::new("podman")
        .args(["logs", "--tail", &n, "--", name])
        .output()
        .map_err(|e| e.to_string())?;
    let text = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    Ok(json!({ "name": name, "output": text.trim_end() }))
}

/// POST /api/v1/containers/{start,stop,restart,remove} — the few audited write
/// actions. `remove` maps to `podman rm` WITHOUT -f, so podman refuses a running
/// container (stop it first) — there is no accidental kill from the console.
pub fn container_action(action: &str, name: &str) -> Result<Value, String> {
    if !valid_container_name(name) {
        return Err("invalid container name".into());
    }
    let verb = match action {
        "start" => "start",
        "stop" => "stop",
        "restart" => "restart",
        "remove" => "rm",
        _ => return Err("unsupported action".into()),
    };
    match Command::new("podman").args([verb, "--", name]).output() {
        Ok(o) if o.status.success() => Ok(json!({ "ok": true, "action": action, "name": name })),
        Ok(o) => Err(String::from_utf8_lossy(&o.stderr).trim().to_string()),
        Err(e) => Err(e.to_string()),
    }
}

/// The far-vision surface, stubbed so the shape is stable for the frontend.
/// Each becomes a real module: logs (journald), updates + snapshot/rollback
/// (bpm + btrfs), storage (lvm/btrfs), network (nftables).
pub fn not_implemented(area: &str) -> Value {
    json!({
        "error": "not implemented yet",
        "area": area,
        "planned": true,
    })
}
