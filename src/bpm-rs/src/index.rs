//! The repo index, repos.conf, the "provided" base set, and .PKGINFO parsing.
//!
//! Local index line:  name|version|filename|sha256|deps(comma)|repo
//! repos.conf line:   <name> <url1> [url2 ...]   (extra urls are mirrors)

use crate::config::Config;
use std::fs;
use std::path::Path;

#[derive(Clone, Debug)]
pub struct Entry {
    pub name: String,
    pub version: String,
    pub filename: String,
    pub sha256: String,
    pub deps: Vec<String>,
    pub size: u64,    // installed size in bytes (0 if unknown)
    pub desc: String, // one-line description
    pub repo: String,
}

// Line: name|version|filename|sha256|deps|size|desc|repo  (repo appended on
// `bpm update`; desc is free text with separators stripped by mkrepo).
fn parse_line(line: &str) -> Option<Entry> {
    let f: Vec<&str> = line.split('|').collect();
    if f.first().map(|s| s.is_empty()).unwrap_or(true) {
        return None;
    }
    let get = |i: usize| f.get(i).copied().unwrap_or("");
    let deps = get(4)
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect();
    Some(Entry {
        name: f[0].to_string(),
        version: get(1).to_string(),
        filename: get(2).to_string(),
        sha256: get(3).to_string(),
        deps,
        size: get(5).parse().unwrap_or(0),
        desc: get(6).to_string(),
        repo: get(7).to_string(),
    })
}

/// Every entry in the synced index (empty if `bpm update` hasn't run).
pub fn load_all(cfg: &Config) -> Vec<Entry> {
    let txt = fs::read_to_string(&cfg.index).unwrap_or_default();
    txt.lines().filter_map(parse_line).collect()
}

/// First entry matching `name`.
pub fn lookup(cfg: &Config, name: &str) -> Option<Entry> {
    let txt = fs::read_to_string(&cfg.index).ok()?;
    txt.lines()
        .filter(|l| l.starts_with(name) && l.as_bytes().get(name.len()) == Some(&b'|'))
        .find_map(parse_line)
}

/// Mirror URLs for a repo, in order (first is primary).
pub fn mirrors(cfg: &Config, repo: &str) -> Vec<String> {
    let txt = match fs::read_to_string(&cfg.conf) {
        Ok(t) => t,
        Err(_) => return Vec::new(),
    };
    for line in txt.lines() {
        let s = line.trim();
        if s.is_empty() || s.starts_with('#') {
            continue;
        }
        let mut it = s.split_whitespace();
        if it.next() == Some(repo) {
            return it.map(|u| u.to_string()).collect();
        }
    }
    Vec::new()
}

/// Strip a dependency atom of version/provider syntax: "glibc>=2.38" -> "glibc".
pub fn dep_name(atom: &str) -> &str {
    let end = atom
        .find(['<', '>', '=', ':'])
        .unwrap_or(atom.len());
    &atom[..end]
}

/// Base packages the live image already provides (built-in list, extended by
/// /etc/bpm/provided). A dep in this set is treated as already satisfied.
const BASE: &[&str] = &[
    "glibc", "gcc-libs", "bash", "sh", "dash", "filesystem", "busybox", "coreutils", "util-linux",
    "findutils", "grep", "sed", "gawk", "awk", "gzip", "procps-ng", "iproute2", "iputils",
    "dropbear", "ld-linux", "glibc-locales", "tzdata",
];

pub fn is_provided(cfg: &Config, name: &str) -> bool {
    if BASE.contains(&name) {
        return true;
    }
    if let Ok(txt) = fs::read_to_string(&cfg.provided) {
        for line in txt.lines() {
            let s = line.trim();
            if s.is_empty() || s.starts_with('#') {
                continue;
            }
            if s == name {
                return true;
            }
        }
    }
    false
}

/// Value of a `key = value` field in .PKGINFO text.
pub fn pkginfo_field(info: &str, key: &str) -> Option<String> {
    for line in info.lines() {
        if let Some((k, v)) = line.split_once('=') {
            if k.trim() == key {
                return Some(v.trim().to_string());
            }
        }
    }
    None
}

/// All values for a repeated .PKGINFO field (e.g. every `depend`).
pub fn pkginfo_all<'a>(info: &'a str, key: &str) -> Vec<&'a str> {
    info.lines()
        .filter_map(|l| l.split_once('='))
        .filter(|(k, _)| k.trim() == key)
        .map(|(_, v)| v.trim())
        .collect()
}

/// Lowercase hex SHA-256 of a file, streamed.
pub fn sha256_file(path: &Path) -> std::io::Result<String> {
    use sha2::{Digest, Sha256};
    let mut f = fs::File::open(path)?;
    let mut h = Sha256::new();
    std::io::copy(&mut f, &mut h)?;
    Ok(hex(&h.finalize()))
}

pub fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}
