//! Streaming install of a `.pkg.tar.zst`, plus post-install scriptlets and
//! ldconfig. The archive is decompressed and untarred in fixed-size chunks
//! straight to disk via `tar` + `zstd`, so even a multi-hundred-MB package
//! (gcc) installs in a tiny, bounded working set — the OOM the C bpm hit is
//! impossible here by construction.

use crate::config::Config;
use crate::{db, index};
use std::collections::HashMap;
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

/// Free bytes on the filesystem holding `path` (None if statvfs fails).
fn avail_bytes(path: &Path) -> Option<u64> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let c = CString::new(path.as_os_str().as_bytes()).ok()?;
    unsafe {
        let mut s: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(c.as_ptr(), &mut s) == 0 {
            Some(s.f_bavail as u64 * s.f_frsize as u64)
        } else {
            None
        }
    }
}

fn is_meta(name: &str) -> bool {
    matches!(
        name,
        ".PKGINFO" | ".MTREE" | ".BUILDINFO" | ".INSTALL" | ".CHANGELOG"
    )
}

fn strip_dot(rel: &str) -> &str {
    rel.strip_prefix("./").unwrap_or(rel)
}

/// Run a `/bin/sh -c` command inside the install root. Chroots into `dest` when
/// rooted (BPM_ROOT) so scriptlets/ldconfig act on the target, not the host.
/// Best-effort: a missing sh or failed chroot just yields a non-zero status.
fn run_root_sh(cfg: &Config, cmd: &str) {
    let mut c = Command::new("/bin/sh");
    c.arg("-c").arg(cmd);
    if cfg.rooted() {
        let dest = cfg.dest.clone();
        unsafe {
            use std::os::unix::process::CommandExt;
            c.pre_exec(move || {
                std::os::unix::fs::chroot(&dest)?;
                std::env::set_current_dir("/")?;
                Ok(())
            });
        }
    }
    let _ = c.status();
}

/// Refresh /etc/ld.so.cache so freshly-installed libraries are found. Call once
/// per transaction. Quiet and best-effort.
pub fn run_ldconfig(cfg: &Config) {
    run_root_sh(
        cfg,
        "command -v ldconfig >/dev/null 2>&1 && ldconfig 2>/dev/null",
    );
}

struct Outcome {
    name: String,
    version: String,
    upgrade: bool,
    old_version: Option<String>,
    script: Option<String>,
}

/// Install one local .pkg.tar.zst. Streams to disk, records the DB entry, runs
/// the post-install/upgrade scriptlet. Does NOT run ldconfig (the caller does,
/// once per transaction).
pub fn install_file(cfg: &Config, path: &Path, force: bool) -> io::Result<()> {
    fs::create_dir_all(&cfg.dest)?;

    let file = fs::File::open(path)?;
    let decoder = zstd::stream::read::Decoder::new(io::BufReader::new(file))?;
    let mut archive = tar::Archive::new(decoder);

    let mut info: Option<String> = None;
    let mut script: Option<String> = None;
    let mut files: Vec<String> = Vec::new();
    let mut name: Option<String> = None;
    let mut version: Option<String> = None;
    let mut upgrade = false;
    let mut old_version: Option<String> = None;
    let mut settled = false;
    let mut owners: HashMap<String, String> = HashMap::new();

    for entry in archive.entries()? {
        let mut e = entry?;
        let etype = e.header().entry_type();
        let mode = e.header().mode().unwrap_or(0o644) & 0o7777;
        let rel_owned = e.path()?.to_string_lossy().into_owned();
        let rel = strip_dot(&rel_owned).to_string();
        if rel.is_empty() {
            continue;
        }

        if is_meta(&rel) {
            if rel == ".PKGINFO" && info.is_none() {
                let mut s = String::new();
                e.read_to_string(&mut s)?;
                let pkgname = index::pkginfo_field(&s, "pkgname");
                version = index::pkginfo_field(&s, "pkgver");

                // Disk-space precheck (installed `size` vs free space) before we
                // write anything — fails cleanly instead of half-extracting.
                if !force {
                    if let Some(need) = index::pkginfo_field(&s, "size")
                        .and_then(|v| v.parse::<u64>().ok())
                    {
                        if let Some(free) = avail_bytes(&cfg.dest) {
                            if free < need {
                                return Err(err(&format!(
                                    "not enough space for {} — need {} MiB, {} MiB free (use -f to override)",
                                    pkgname.as_deref().unwrap_or("?"),
                                    need / 1048576,
                                    free / 1048576
                                )));
                            }
                        }
                    }
                }

                // Build the file-ownership map for conflict detection (other
                // packages' files; this package's own are excluded so a reinstall
                // doesn't conflict with itself).
                if let Some(ref n) = pkgname {
                    owners = db::file_owners(cfg, n);
                }
                name = pkgname;
                info = Some(s);
            } else if rel == ".INSTALL" && script.is_none() {
                let mut s = String::new();
                e.read_to_string(&mut s)?;
                script = Some(s);
            }
            continue;
        }

        // File-conflict: another installed package already owns this path.
        if !force {
            let key = rel.trim_end_matches('/');
            if let Some(other) = owners.get(key) {
                return Err(err(&format!(
                    "{}: file conflict — /{} is owned by {} (use -f to override)",
                    name.as_deref().unwrap_or("?"),
                    key,
                    other
                )));
            }
        }

        // First real payload member: settle any previously installed version so
        // an upgrade doesn't strand orphaned files.
        if !settled {
            settled = true;
            if let Some(ref n) = name {
                if let Some(old) = db::installed_version(cfg, n) {
                    println!(
                        ":: reinstall/upgrade {} {} -> {}",
                        n,
                        old,
                        version.as_deref().unwrap_or("?")
                    );
                    upgrade = true;
                    old_version = Some(old);
                    db::remove_files(cfg, n);
                } else {
                    println!(":: installing {} {}", n, version.as_deref().unwrap_or("?"));
                }
            }
        }

        let full = cfg.dest.join(&rel);
        if etype.is_dir() {
            fs::create_dir_all(&full)?;
        } else if etype.is_symlink() {
            if let Some(parent) = full.parent() {
                fs::create_dir_all(parent)?;
            }
            let _ = fs::remove_file(&full);
            if let Some(target) = e.link_name()? {
                std::os::unix::fs::symlink(target, &full)?;
            }
            files.push(rel.trim_end_matches('/').to_string());
        } else if etype.is_hard_link() {
            if let Some(parent) = full.parent() {
                fs::create_dir_all(parent)?;
            }
            let _ = fs::remove_file(&full);
            if let Some(target) = e.link_name()? {
                let tgt = cfg.dest.join(strip_dot(&target.to_string_lossy()));
                fs::hard_link(&tgt, &full)?;
            }
            files.push(rel);
        } else {
            if let Some(parent) = full.parent() {
                fs::create_dir_all(parent)?;
            }
            let _ = fs::remove_file(&full);
            let mut out = fs::File::create(&full)?;
            io::copy(&mut e, &mut out)?; // streams in chunks
            out.flush()?;
            fs::set_permissions(&full, fs::Permissions::from_mode(mode))?;
            files.push(rel);
        }
    }

    let info = info.ok_or_else(|| err("not a package (no .PKGINFO)"))?;
    let name = name.ok_or_else(|| err("package has no pkgname"))?;
    let version = version.unwrap_or_default();

    db::record(cfg, &name, &info, &files)?;

    run_scriptlet(
        cfg,
        &Outcome {
            name: name.clone(),
            version: version.clone(),
            upgrade,
            old_version,
            script,
        },
    );

    println!(":: installed {name} {version}");
    Ok(())
}

fn run_scriptlet(cfg: &Config, o: &Outcome) {
    let script = match &o.script {
        Some(s) => s,
        None => return,
    };
    if std::env::var_os("BPM_NO_SCRIPTLETS").is_some() {
        return;
    }
    let tmp = cfg.dest.join(".bpm-scriptlet");
    if fs::write(&tmp, script).is_err() {
        return;
    }
    let hook = if o.upgrade {
        "post_upgrade"
    } else {
        "post_install"
    };
    let cmd = format!(
        ". /.bpm-scriptlet 2>/dev/null; type {hook} >/dev/null 2>&1 && {hook} '{}' '{}'",
        o.version,
        o.old_version.as_deref().unwrap_or("")
    );
    println!(":: running {hook} scriptlet for {}", o.name);
    run_root_sh(cfg, &cmd);
    let _ = fs::remove_file(&tmp);
}

fn err(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.to_string())
}
