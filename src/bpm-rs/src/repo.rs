//! Package downloads: try each mirror in turn, verify the sha256, cache it.

use crate::config::Config;
use crate::index::{self, Entry};
use crate::net;
use std::path::PathBuf;

/// Download `entry`'s file from a mirror of its repo, verify the checksum, and
/// return the cached path. Returns Err with a message on total failure.
pub fn fetch(cfg: &Config, entry: &Entry) -> Result<PathBuf, String> {
    let out = cfg.cache.join(&entry.filename);

    // Already cached and current?
    if out.is_file() && !entry.sha256.is_empty() {
        if let Ok(have) = index::sha256_file(&out) {
            if have == entry.sha256 {
                return Ok(out);
            }
        }
    }
    if let Some(parent) = out.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    let mirrors = index::mirrors(cfg, &entry.repo);
    if mirrors.is_empty() {
        return Err(format!("no mirrors for repo '{}'", entry.repo));
    }

    let mut got = false;
    for m in &mirrors {
        let url = format!("{m}/{}", entry.filename);
        match net::get(&url, &out) {
            Ok(()) => {
                got = true;
                break;
            }
            Err(e) => eprintln!("bpm: warning: mirror unreachable: {m} ({e})"),
        }
    }
    if !got {
        return Err(format!(
            "all mirrors failed for {} (repo '{}')",
            entry.filename, entry.repo
        ));
    }

    if !entry.sha256.is_empty() {
        match index::sha256_file(&out) {
            Ok(have) if have == entry.sha256 => {}
            _ => {
                // Drop the bad artifact (and any partial) so the next run
                // re-downloads from scratch instead of resuming corruption.
                let _ = std::fs::remove_file(&out);
                let _ = std::fs::remove_file(format!("{}.part", out.display()));
                return Err(format!("checksum mismatch for {}", entry.filename));
            }
        }
    }
    Ok(out)
}
