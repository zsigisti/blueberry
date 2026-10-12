//! API handlers. Reads shell out to systemctl/bpm/etc or read /proc. Writes are
//! few, and main.rs audits them before calling in here.
//!
//! Anything user-supplied goes in as its own argv element, never through a
//! shell, and names can't start with '-' so they can't turn into options.

use serde_json::{json, Value};
use std::fs;
use std::process::Command;

/// GET system
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

    // meminfo is in kB
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

    let mut pretty = String::new();
    if let Ok(osr) = fs::read_to_string("/etc/os-release") {
        for l in osr.lines() {
            if let Some(v) = l.strip_prefix("PRETTY_NAME=") {
                pretty = v.trim_matches('"').to_string();
            }
        }
    }

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
    // every numeric dir in /proc is a process
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

/// (idle, total) jiffies from /proc/stat: the whole box, then each core.
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

/// Busy % between two samples, to one decimal.
fn cpu_pct(a: (u64, u64), b: (u64, u64)) -> f64 {
    let didle = b.0.saturating_sub(a.0) as f64;
    let dtotal = b.1.saturating_sub(a.1) as f64;
    if dtotal <= 0.0 {
        0.0
    } else {
        (((1.0 - didle / dtotal) * 100.0).clamp(0.0, 100.0) * 10.0).round() / 10.0
    }
}

/// GET metrics. Samples /proc/stat twice, 120ms apart, so the client doesn't
/// have to keep track of deltas itself.
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

/// GET logs
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
            // MESSAGE is a byte array instead of a string when it isn't valid UTF-8
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

/// GET storage: df, plus lsblk if it's there.
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

/// GET network
pub fn network() -> Value {
    use std::collections::BTreeMap;
    let mut ifaces: BTreeMap<String, Value> = BTreeMap::new();

    // "3: eth0    inet 192.168.0.5/24 ..."
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
    // link state + MAC
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

/// GET services
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

/// POST services/{start,stop,restart}
pub fn service_action(action: &str, unit: &str) -> Result<Value, String> {
    if !matches!(action, "start" | "stop" | "restart") {
        return Err("unsupported action".into());
    }
    // a leading '-' would make the "unit" a systemctl option (`--version`
    // happily reports success). reject it, and pass `--` anyway
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

/// GET packages. Empty if bpm isn't there.
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

/// ZFS pool/dataset name, optionally with `@snapshot`.
pub fn valid_zfs_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 256
        && !s.starts_with('-')
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-.:/@".contains(&b))
}

/// GET zfs. `available: false` when there's no zpool binary.
pub fn zfs() -> Value {
    let po = match Command::new("zpool")
        .args(["list", "-Hp", "-o", "name,size,alloc,free,health,capacity,fragmentation"])
        .output()
    {
        Ok(o) => o,
        Err(_) => return json!({ "available": false }),
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
    // zpool is there but failed (module not loaded, usually), so say why
    if pools.is_empty() && !po.status.success() {
        let note = String::from_utf8_lossy(&po.stderr).trim().to_string();
        if !note.is_empty() {
            resp["note"] = json!(note);
        }
    }
    resp
}

/// POST zfs/{scrub,snapshot}. No destroy or pool creation on purpose.
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

/// /proc/mounts writes space, tab, newline and backslash as octal escapes.
fn unescape_mount(s: &str) -> String {
    s.replace("\\040", " ").replace("\\011", "\t").replace("\\012", "\n").replace("\\134", "\\")
}

/// (mountpoint, device) for each btrfs mount.
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

fn subvol_path(line: &str) -> Option<String> {
    line.rsplit_once(" path ").map(|(_, p)| p.trim().to_string())
}

/// GET btrfs. `available: false` without btrfs-progs.
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

/// A plain basename: no '/', no leading '-'.
pub fn valid_snap_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && !s.starts_with('-')
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-.".contains(&b))
}

/// Relative subvolume path. No `.`, `..` or empty components.
fn valid_subvol_rel(p: &str) -> bool {
    !p.is_empty()
        && !p.starts_with('-')
        && p.len() <= 512
        && p.split('/').all(|c| {
            !c.is_empty() && c != "." && c != ".." && c.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-.@".contains(&b))
        })
}

/// Subvolumes that really exist under a mount. Delete/rollback must name one.
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

/// Clone the snapshot into a writable subvolume and make that the default.
/// Kicks in on next boot, and only if root is mounted by default subvolume
/// rather than a pinned `subvol=`. The live subvolume is never touched.
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

/// POST btrfs/{scrub,snapshot,subvol-create,subvol-delete,rollback}. `mount`
/// has to be a btrfs mount that exists right now.
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
            // btrfs won't delete a mounted subvolume, so / and /home are safe
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

fn root_is_btrfs() -> bool {
    btrfs_mounts().iter().any(|(mp, _)| mp == "/")
}

/// GET updates. `btrfs_root` tells the UI it can offer a snapshot first.
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

/// POST updates/apply?snapshot=1. Takes a read-only snapshot of / first if
/// asked (and if / is btrfs), then runs `bpm upgrade` and waits for it.
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

/// Container name or id. Also passed after `--`.
pub fn valid_container_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && !s.starts_with('-')
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.-/:@".contains(&b))
}

/// `Names` joined with commas, or `fallback` if there's no Names array.
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

/// GET containers. `available: false` without podman, like zfs/btrfs.
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
    let mut seen = std::collections::HashSet::new();
    if let Ok(o) = Command::new("podman").args(["images", "--format", "json"]).output() {
        if let Ok(Value::Array(arr)) = serde_json::from_slice::<Value>(&o.stdout) {
            for im in arr {
                // podman prints one object per tag, each with the full Names
                // list, so an image tagged twice shows up twice. first one wins
                let id = im.get("Id").and_then(|v| v.as_str()).unwrap_or("").to_string();
                if !id.is_empty() && !seen.insert(id) {
                    continue;
                }
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

/// GET containers/logs?name=<c>&lines=<n>
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

/// POST containers/{start,stop,restart,remove}. `remove` is `podman rm`
/// without -f, so a running container has to be stopped first. No accidental
/// kills from a stray click.
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
