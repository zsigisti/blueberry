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
        ".PKGINFO" | ".MTREE" | ".BUILDINFO" | ".INSTALL" | ".CHANGELOG" | ".BPM"
    )
}

fn strip_dot(rel: &str) -> &str {
    rel.strip_prefix("./").unwrap_or(rel)
}

/// Translate a native `.BPM` TOML manifest into the internal (.PKGINFO, .INSTALL)
/// pair the rest of the installer already understands, so the streaming install
/// path is identical for both `.pkg.tar.zst` and `.bpm`. Parses only the small,
/// fixed subset `bpmbuild` emits (scalars, string arrays, a [scripts] table) —
/// no general TOML library is pulled in.
fn bpm_manifest_to_pkginfo(toml: &str) -> (String, Option<String>) {
    let unquote = |v: &str| -> String {
        let v = v.trim();
        if v.len() >= 2 && v.starts_with('"') && v.ends_with('"') {
            v[1..v.len() - 1].replace("\\\"", "\"").replace("\\\\", "\\")
        } else {
            v.to_string()
        }
    };
    let array_items = |v: &str| -> Vec<String> {
        let v = v.trim();
        let inner = v.strip_prefix('[').and_then(|s| s.strip_suffix(']')).unwrap_or("");
        inner
            .split(',')
            .map(|x| unquote(x))
            .filter(|x| !x.is_empty())
            .collect()
    };

    let mut pkginfo = String::new();
    let mut scripts: Vec<(String, String)> = Vec::new();
    let mut in_scripts = false;

    for line in toml.lines() {
        let l = line.trim();
        if l.is_empty() || l.starts_with('#') {
            continue;
        }
        if l.starts_with('[') {
            in_scripts = l == "[scripts]";
            continue;
        }
        let (k, v) = match l.split_once('=') {
            Some((k, v)) => (k.trim(), v.trim()),
            None => continue,
        };
        if in_scripts {
            scripts.push((k.to_string(), unquote(v)));
            continue;
        }
        match k {
            "name" => pkginfo.push_str(&format!("pkgname = {}\n", unquote(v))),
            "version" => {
                // fold release into pkgver as ver-rel when present (set later).
                pkginfo.push_str(&format!("pkgver = {}\n", unquote(v)));
            }
            "installed_size" => pkginfo.push_str(&format!("size = {}\n", v.trim())),
            "arch" => pkginfo.push_str(&format!("arch = {}\n", unquote(v))),
            "summary" => pkginfo.push_str(&format!("pkgdesc = {}\n", unquote(v))),
            "depends" => {
                for d in array_items(v) {
                    pkginfo.push_str(&format!("depend = {d}\n"));
                }
            }
            "provides" => {
                for p in array_items(v) {
                    pkginfo.push_str(&format!("provides = {p}\n"));
                }
            }
            _ => {}
        }
    }

    // Synthesise an .INSTALL-style script: each [scripts] entry becomes a shell
    // function the existing run_hook() sources and calls (post_install, …).
    let install = if scripts.is_empty() {
        None
    } else {
        let mut s = String::new();
        for (hook, body) in &scripts {
            s.push_str(&format!("{hook}() {{\n{body}\n}}\n"));
        }
        Some(s)
    };
    (pkginfo, install)
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
pub fn install_file(cfg: &Config, path: &Path, force: bool) -> io::Result<String> {
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
            if (rel == ".PKGINFO" || rel == ".BPM") && info.is_none() {
                let mut raw = String::new();
                e.read_to_string(&mut raw)?;
                // A native .bpm carries TOML; translate it into the .PKGINFO
                // shape (and pull out its install scriptlet). A legacy
                // .pkg.tar.zst .PKGINFO is used as-is.
                let s = if rel == ".BPM" {
                    let (pkginfo, bpm_script) = bpm_manifest_to_pkginfo(&raw);
                    if script.is_none() {
                        script = bpm_script;
                    }
                    pkginfo
                } else {
                    raw
                };
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
                let ver = version.as_deref().unwrap_or("?");
                if let Some(old) = db::installed_version(cfg, n) {
                    println!(":: reinstall/upgrade {n} {old} -> {ver}");
                    upgrade = true;
                    // pre_upgrade runs while the old version's files are still on
                    // disk — this is what lets the linux package stash the
                    // running /boot/vmlinuz as a fallback before it's replaced.
                    run_hook(cfg, n, script.as_deref(), "pre_upgrade", ver, &old);
                    old_version = Some(old);
                    db::remove_files(cfg, n);
                } else {
                    println!(":: installing {n} {ver}");
                    run_hook(cfg, n, script.as_deref(), "pre_install", ver, "");
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
            // Write to a temp sibling, then atomically rename over the target.
            // This is what lets bpm replace an in-use file — including its own
            // running /usr/bin/bpm — without ETXTBSY, and never leaves a
            // half-written file if interrupted.
            let fname = full.file_name().and_then(|f| f.to_str()).unwrap_or("f");
            let tmp = full.with_file_name(format!(".{fname}.bpm-new"));
            {
                let mut out = fs::File::create(&tmp)?;
                io::copy(&mut e, &mut out)?; // streams in chunks
                out.flush()?;
            }
            fs::set_permissions(&tmp, fs::Permissions::from_mode(mode))?;
            fs::rename(&tmp, &full)?;
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
    Ok(name)
}

/// Free bytes on the filesystem holding the install root (None if unknown).
pub fn free_space(cfg: &Config) -> Option<u64> {
    avail_bytes(&cfg.dest)
}

fn run_scriptlet(cfg: &Config, o: &Outcome) {
    let hook = if o.upgrade {
        "post_upgrade"
    } else {
        "post_install"
    };
    run_hook(
        cfg,
        &o.name,
        o.script.as_deref(),
        hook,
        &o.version,
        o.old_version.as_deref().unwrap_or(""),
    );
}

/// Run one .INSTALL hook function (pre/post_install/upgrade). No-op when the
/// package has no scriptlet, the function isn't defined, or BPM_NO_SCRIPTLETS
/// is set. The script is sourced in the (possibly chrooted) target root.
fn run_hook(
    cfg: &Config,
    name: &str,
    script: Option<&str>,
    hook: &str,
    version: &str,
    old_version: &str,
) {
    let script = match script {
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
    let cmd = format!(
        ". /.bpm-scriptlet 2>/dev/null; type {hook} >/dev/null 2>&1 && {hook} '{version}' '{old_version}'",
    );
    println!(":: running {hook} scriptlet for {name}");
    run_root_sh(cfg, &cmd);
    let _ = fs::remove_file(&tmp);
}

fn err(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.to_string())
}
