//! The local installed-package database, byte-compatible with the C bpm:
//!   <root>/var/lib/bpm/db/<name>/desc   = the package's .PKGINFO text
//!   <root>/var/lib/bpm/db/<name>/files  = installed paths, one per line

use crate::config::Config;
use crate::index;
use std::fs;
use std::path::Path;

pub fn installed_version(cfg: &Config, name: &str) -> Option<String> {
    let desc = cfg.db.join(name).join("desc");
    let txt = fs::read_to_string(desc).ok()?;
    index::pkginfo_field(&txt, "pkgver")
}

pub fn is_installed(cfg: &Config, name: &str) -> bool {
    cfg.db.join(name).is_dir()
}

pub fn installed_names(cfg: &Config) -> Vec<String> {
    let mut names = Vec::new();
    if let Ok(rd) = fs::read_dir(&cfg.db) {
        for e in rd.flatten() {
            if e.path().join("desc").is_file() {
                if let Some(n) = e.file_name().to_str() {
                    names.push(n.to_string());
                }
            }
        }
    }
    names.sort();
    names
}

pub fn read_files(cfg: &Config, name: &str) -> Vec<String> {
    let p = cfg.db.join(name).join("files");
    fs::read_to_string(p)
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| l.to_string())
        .collect()
}

/// Declared dependencies of an installed package (atoms stripped to names).
pub fn package_deps(cfg: &Config, name: &str) -> Vec<String> {
    let desc = cfg.db.join(name).join("desc");
    let txt = fs::read_to_string(desc).unwrap_or_default();
    index::pkginfo_all(&txt, "depend")
        .iter()
        .map(|d| index::dep_name(d).to_string())
        .filter(|d| !d.is_empty())
        .collect()
}

/// Installed packages that depend on `target`, excluding any in `ignore`
/// (e.g. packages being removed in the same transaction).
pub fn requirers(cfg: &Config, target: &str, ignore: &std::collections::HashSet<String>) -> Vec<String> {
    let mut out = Vec::new();
    for name in installed_names(cfg) {
        if ignore.contains(&name) {
            continue;
        }
        if package_deps(cfg, &name).iter().any(|d| d == target) {
            out.push(name);
        }
    }
    out
}

/// Map of every installed file path -> owning package, excluding `skip`'s files
/// (the package currently being (re)installed). Used for conflict detection.
pub fn file_owners(cfg: &Config, skip: &str) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    for name in installed_names(cfg) {
        if name == skip {
            continue;
        }
        for f in read_files(cfg, &name) {
            map.insert(f.trim_end_matches('/').to_string(), name.clone());
        }
    }
    map
}

/// Which installed package owns `rel` (a path with no leading slash).
pub fn owner(cfg: &Config, rel: &str) -> Option<String> {
    for name in installed_names(cfg) {
        if read_files(cfg, &name).iter().any(|f| f == rel) {
            return Some(name);
        }
    }
    None
}

/// Remove an installed package's files from disk (deepest first), pruning empty
/// parent directories — the same teardown the C bpm does before an upgrade.
pub fn remove_files(cfg: &Config, name: &str) {
    let mut files = read_files(cfg, name);
    files.sort();
    files.reverse(); // deepest paths first
    for rel in &files {
        let full = cfg.dest.join(rel);
        let meta = match fs::symlink_metadata(&full) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if meta.is_dir() {
            let _ = fs::remove_dir(&full); // only if empty
        } else {
            let _ = fs::remove_file(&full);
        }
        // best-effort prune of now-empty parents
        let mut parent = full.parent().map(Path::to_path_buf);
        while let Some(dir) = parent {
            if dir == cfg.dest || fs::remove_dir(&dir).is_err() {
                break;
            }
            parent = dir.parent().map(Path::to_path_buf);
        }
    }
}

pub fn record(cfg: &Config, name: &str, info: &str, files: &[String]) -> std::io::Result<()> {
    let dir = cfg.db.join(name);
    fs::create_dir_all(&dir)?;
    fs::write(dir.join("desc"), info)?;
    let mut body = files.join("\n");
    if !body.is_empty() {
        body.push('\n');
    }
    fs::write(dir.join("files"), body)?;
    Ok(())
}

pub fn remove(cfg: &Config, name: &str) {
    let _ = fs::remove_dir_all(cfg.db.join(name));
}

/// Mark a package as explicitly installed (user-requested), so autoremove never
/// reaps it. Dependencies pulled in transitively are left unmarked.
pub fn mark_explicit(cfg: &Config, name: &str) {
    let _ = fs::write(cfg.db.join(name).join("explicit"), b"");
}

pub fn is_explicit(cfg: &Config, name: &str) -> bool {
    cfg.db.join(name).join("explicit").exists()
}
