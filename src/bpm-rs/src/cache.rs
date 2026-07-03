//! The on-disk package cache (`<root>/var/lib/bpm/cache`). Downloaded `.bpm`
//! artifacts are kept here after install so a package can be rolled back or
//! downgraded to a previously-fetched version without the mirror still hosting
//! it. Versions are read from each artifact's manifest (authoritative), not
//! parsed out of the filename — package names contain dashes, so filename
//! parsing is ambiguous.

use crate::config::Config;
use crate::pkg;
use crate::vercmp;
use std::cmp::Ordering;
use std::path::PathBuf;

/// One cached artifact: its version and path on disk.
pub struct Cached {
    pub version: String,
    pub path: PathBuf,
}

fn is_pkg(fname: &str) -> bool {
    fname.ends_with(".bpm") || fname.ends_with(".pkg.tar.zst")
}

/// Every cached artifact, grouped by package name, each group sorted
/// newest-version-first.
pub fn grouped(cfg: &Config) -> std::collections::BTreeMap<String, Vec<Cached>> {
    let mut map: std::collections::BTreeMap<String, Vec<Cached>> = std::collections::BTreeMap::new();
    if let Ok(rd) = std::fs::read_dir(&cfg.cache) {
        for e in rd.flatten() {
            let p = e.path();
            let fname = match p.file_name().and_then(|f| f.to_str()) {
                Some(f) => f,
                None => continue,
            };
            if !is_pkg(fname) {
                continue;
            }
            if let Ok((name, version)) = pkg::read_meta(&p) {
                map.entry(name).or_default().push(Cached { version, path: p });
            }
        }
    }
    for v in map.values_mut() {
        v.sort_by(|a, b| vercmp::vercmp(&b.version, &a.version));
    }
    map
}

/// Cached artifacts for one package, newest-version-first.
pub fn versions(cfg: &Config, name: &str) -> Vec<Cached> {
    let mut out: Vec<Cached> = Vec::new();
    if let Ok(rd) = std::fs::read_dir(&cfg.cache) {
        for e in rd.flatten() {
            let p = e.path();
            let fname = match p.file_name().and_then(|f| f.to_str()) {
                Some(f) => f,
                None => continue,
            };
            if !is_pkg(fname) || !fname.starts_with(&format!("{name}-")) {
                continue;
            }
            if let Ok((n, version)) = pkg::read_meta(&p) {
                if n == name {
                    out.push(Cached { version, path: p });
                }
            }
        }
    }
    out.sort_by(|a, b| vercmp::vercmp(&b.version, &a.version));
    out
}

/// The newest cached version strictly older than `current` (the rollback
/// target), or None if the cache holds nothing older.
pub fn previous(cfg: &Config, name: &str, current: &str) -> Option<Cached> {
    versions(cfg, name)
        .into_iter()
        .find(|c| vercmp::vercmp(&c.version, current) == Ordering::Less)
}

/// The cached artifact for an exact version, if present.
pub fn exact(cfg: &Config, name: &str, version: &str) -> Option<Cached> {
    versions(cfg, name)
        .into_iter()
        .find(|c| vercmp::vercmp(&c.version, version) == Ordering::Equal)
}
