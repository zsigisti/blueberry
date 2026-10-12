//! Installing a package file, scriptlets, ldconfig and friends.
//! Everything streams zstd -> tar -> disk in small chunks, so gcc installs in a
//! few MB of RAM. The C bpm buffered whole archives and OOMed on exactly that.

use crate::config::Config;
use crate::{db, index};
use std::collections::HashMap;
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

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

fn triple_delim(v: &str) -> Option<&'static str> {
    if v.starts_with("'''") {
        Some("'''")
    } else if v.starts_with("\"\"\"") {
        Some("\"\"\"")
    } else {
        None
    }
}

/// Turn a .BPM TOML manifest into (.PKGINFO text, .INSTALL script) so the rest
/// of the installer doesn't care which format it got. Only handles what bpmbuild
/// actually writes (scalars, string arrays, [scripts]); not worth a toml crate.
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
            .map(&unquote)
            .filter(|x| !x.is_empty())
            .collect()
    };

    let mut pkginfo = String::new();
    let mut scripts: Vec<(String, String)> = Vec::new();
    let mut in_scripts = false;
    // the index says "ver-rel", so the db has to say "ver-rel" too. record a
    // bare "ver" and upgrade compares 2.10.0 to 2.10.0-2 and re-offers the same
    // package forever. key order isn't fixed, so glue them after the loop.
    let mut ver: Option<String> = None;
    let mut rel: Option<String> = None;

    let lines: Vec<&str> = toml.lines().collect();
    let mut i = 0;
    while i < lines.len() {
        let l = lines[i].trim();
        i += 1;
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
            // scripts come as multi-line strings ('''...''' or """...""").
            // old single-line `key = "cmd"` ones still go through unquote
            let val = if let Some(delim) = triple_delim(v) {
                let mut body = String::new();
                let first = &v[3..];
                let mut closed = false;
                if let Some(end) = first.find(delim) {
                    body.push_str(&first[..end]);
                    closed = true;
                }
                while !closed && i < lines.len() {
                    let raw = lines[i];
                    i += 1;
                    if let Some(end) = raw.find(delim) {
                        body.push_str(&raw[..end]);
                        closed = true;
                    } else {
                        body.push_str(raw);
                        body.push('\n');
                    }
                }
                // the newline right after the opening ''' isn't part of the script
                body.strip_prefix('\n').unwrap_or(&body).to_string()
            } else {
                unquote(v)
            };
            scripts.push((k.to_string(), val));
            continue;
        }
        match k {
            "name" => pkginfo.push_str(&format!("pkgname = {}\n", unquote(v))),
            "version" => ver = Some(unquote(v)),
            "release" => rel = Some(unquote(v)),
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
            "backup" => {
                for b in array_items(v) {
                    // relative, like the files list
                    pkginfo.push_str(&format!("backup = {}\n", b.trim_start_matches('/')));
                }
            }
            _ => {}
        }
    }

    if let Some(v) = ver {
        match rel.as_deref().filter(|r| !r.is_empty()) {
            Some(r) => pkginfo.push_str(&format!("pkgver = {v}-{r}\n")),
            None => pkginfo.push_str(&format!("pkgver = {v}\n")),
        }
    }

    // each [scripts] entry becomes a shell function, same shape as .INSTALL
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

/// sh -c inside the install root. With BPM_ROOT set we chroot first, so
/// scriptlets and ldconfig hit the target and not the host. Best effort.
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

pub fn run_ldconfig(cfg: &Config) {
    run_root_sh(
        cfg,
        "command -v ldconfig >/dev/null 2>&1 && ldconfig 2>/dev/null",
    );
}

/// ldconfig + man index. Once at the end of every transaction.
pub fn refresh(cfg: &Config) {
    run_ldconfig(cfg);
    run_makewhatis(cfg);
}

/// mandoc's makewhatis (what the base ships), or man-db's mandb if that's what's there.
pub fn run_makewhatis(cfg: &Config) {
    run_root_sh(
        cfg,
        "if command -v makewhatis >/dev/null 2>&1; then makewhatis /usr/share/man 2>/dev/null; \
         elif command -v mandb >/dev/null 2>&1; then mandb -q 2>/dev/null; fi",
    );
}

/// (pkgname, pkgver) of a package file, reading just the manifest. The cache
/// code uses this since filenames can't be trusted to split name from version.
pub fn read_meta(path: &Path) -> io::Result<(String, String)> {
    let file = fs::File::open(path)?;
    let decoder = zstd::stream::read::Decoder::new(io::BufReader::new(file))?;
    let mut archive = tar::Archive::new(decoder);
    for entry in archive.entries()? {
        let mut e = entry?;
        let rel_owned = e.path()?.to_string_lossy().into_owned();
        let rel = strip_dot(&rel_owned);
        if rel == ".BPM" || rel == ".PKGINFO" {
            let mut raw = String::new();
            e.read_to_string(&mut raw)?;
            let s = if rel == ".BPM" {
                bpm_manifest_to_pkginfo(&raw).0
            } else {
                raw
            };
            let name = index::pkginfo_field(&s, "pkgname").unwrap_or_default();
            let ver = index::pkginfo_field(&s, "pkgver").unwrap_or_default();
            if name.is_empty() {
                break;
            }
            return Ok((name, ver));
        }
    }
    Err(err("no package manifest (.BPM/.PKGINFO) found"))
}

struct Outcome {
    name: String,
    version: String,
    upgrade: bool,
    old_version: Option<String>,
    script: Option<String>,
}

/// Install one package file. Doesn't run ldconfig, the caller does that once
/// per transaction via refresh().
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
    // config files (backup =) and the hashes of what we ship for them
    let mut backup_set: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut new_backup: Vec<(String, String)> = Vec::new();

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

                // bail before writing anything rather than half-extracting
                if !force {
                    if let Some(need) = index::pkginfo_field(&s, "size")
                        .and_then(|v| v.parse::<u64>().ok())
                    {
                        if let Some(free) = avail_bytes(&cfg.dest) {
                            if free < need {
                                return Err(err(&format!(
                                    "not enough space for {}: need {} MiB, only {} MiB free (-f to try anyway)",
                                    pkgname.as_deref().unwrap_or("?"),
                                    need / 1048576,
                                    free / 1048576
                                )));
                            }
                        }
                    }
                }

                // who owns what, minus our own files so a reinstall doesn't
                // conflict with itself
                if let Some(ref n) = pkgname {
                    owners = db::file_owners(cfg, n);
                }
                backup_set = index::pkginfo_all(&s, "backup")
                    .iter()
                    .map(|p| p.trim_start_matches('/').to_string())
                    .collect();
                name = pkgname;
                info = Some(s);
            } else if rel == ".INSTALL" && script.is_none() {
                let mut s = String::new();
                e.read_to_string(&mut s)?;
                script = Some(s);
            }
            continue;
        }

        if !force {
            let key = rel.trim_end_matches('/');
            if let Some(other) = owners.get(key) {
                return Err(err(&format!(
                    "{}: file conflict, /{} already belongs to {} (-f to overwrite it)",
                    name.as_deref().unwrap_or("?"),
                    key,
                    other
                )));
            }
        }

        // first real file: clear out the old version now, so files it had and
        // we don't aren't left lying around
        if !settled {
            settled = true;
            if let Some(ref n) = name {
                let ver = version.as_deref().unwrap_or("?");
                if let Some(old) = db::installed_version(cfg, n) {
                    println!(":: reinstall/upgrade {n} {old} -> {ver}");
                    upgrade = true;
                    // pre_upgrade has to run while the old files are still there.
                    // the linux package uses it to stash the running vmlinuz as a
                    // fallback before we overwrite it
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
            // write next to it and rename over. that's how bpm can replace a
            // running binary (itself included) without ETXTBSY, and a crash
            // never leaves half a file behind
            let fname = full.file_name().and_then(|f| f.to_str()).unwrap_or("f");
            let tmp = full.with_file_name(format!(".{fname}.bpm-new"));
            {
                let mut out = fs::File::create(&tmp)?;
                io::copy(&mut e, &mut out)?; // streams in chunks
                out.flush()?;
            }
            fs::set_permissions(&tmp, fs::Permissions::from_mode(mode))?;
            if backup_set.contains(&rel) {
                // config file, pacman/dpkg style: never clobber user edits
                let newhash = index::sha256_file(&tmp).unwrap_or_default();
                let on_disk = full.exists();
                let disk_hash = if on_disk { index::sha256_file(&full).ok() } else { None };
                let old_pkg = match (upgrade, name.as_deref()) {
                    (true, Some(n)) => db::backup_hash(cfg, n, &rel),
                    _ => None,
                };
                if !on_disk || disk_hash.as_deref() == Some(newhash.as_str()) {
                    // fresh install, or already the same as the new one
                    fs::rename(&tmp, &full)?;
                } else if old_pkg.is_some() && disk_hash == old_pkg {
                    // untouched since the last install, safe to update
                    fs::rename(&tmp, &full)?;
                } else {
                    // user edited it and ours changed too: keep theirs
                    let nf = full.with_file_name(format!("{fname}.bpmnew"));
                    fs::rename(&tmp, &nf)?;
                    println!(":: kept your /{rel}, new version is in /{rel}.bpmnew");
                }
                new_backup.push((rel.clone(), newhash));
            } else {
                fs::rename(&tmp, &full)?;
            }
            files.push(rel);
        }
    }

    let info = info.ok_or_else(|| err("not a package (no .PKGINFO)"))?;
    let name = name.ok_or_else(|| err("package has no pkgname"))?;
    let version = version.unwrap_or_default();

    db::record(cfg, &name, &info, &files)?;
    // next upgrade compares against these to spot user edits
    let _ = db::write_backup(cfg, &name, &new_backup);

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

    // a package that wants a service on ships an empty usr/lib/bpm/enable/<unit>.
    // we write the [Install] symlinks ourselves so it works in a chroot/image too,
    // and start it right away if this is the live system
    enable_services(cfg, &files);

    println!(":: installed {name} {version}");
    Ok(name)
}

fn enable_services(cfg: &Config, files: &[String]) {
    if std::env::var_os("BPM_NO_SCRIPTLETS").is_some() {
        return;
    }
    let mut units: Vec<String> = files
        .iter()
        .filter_map(|f| f.trim_end_matches('/').strip_prefix("usr/lib/bpm/enable/"))
        .filter(|u| !u.is_empty())
        .map(|u| u.to_string())
        .collect();
    units.sort();
    units.dedup();
    if units.is_empty() {
        return;
    }
    for unit in &units {
        offline_enable(cfg, unit);
    }
    if cfg.root == "/" && which("systemctl") {
        let _ = Command::new("systemctl").arg("daemon-reload").status();
        for unit in &units {
            if Command::new("systemctl")
                .args(["start", unit])
                .status()
                .map(|s| s.success())
                .unwrap_or(false)
            {
                println!(":: started {unit}");
            }
        }
    }
}

/// What `systemctl enable` would do, minus needing systemd running: read
/// WantedBy=/RequiredBy= and drop the symlinks.
fn offline_enable(cfg: &Config, unit: &str) {
    let unit_file = cfg
        .dest
        .join("usr/lib/systemd/system")
        .join(unit);
    let body = match fs::read_to_string(&unit_file) {
        Ok(b) => b,
        Err(_) => {
            eprintln!("bpm: enable: unit file not found for {unit}");
            return;
        }
    };
    let mut in_install = false;
    for line in body.lines() {
        let l = line.trim();
        if l.starts_with('[') {
            in_install = l.eq_ignore_ascii_case("[Install]");
            continue;
        }
        if !in_install {
            continue;
        }
        let (key, val) = match l.split_once('=') {
            Some(kv) => kv,
            None => continue,
        };
        let suffix = match key.trim() {
            "WantedBy" => ".wants",
            "RequiredBy" => ".requires",
            _ => continue,
        };
        for target in val.split_whitespace() {
            let dir = cfg
                .dest
                .join("etc/systemd/system")
                .join(format!("{target}{suffix}"));
            if fs::create_dir_all(&dir).is_err() {
                continue;
            }
            let link = dir.join(unit);
            let _ = fs::remove_file(&link);
            if std::os::unix::fs::symlink(format!("/usr/lib/systemd/system/{unit}"), &link).is_ok() {
                println!(":: enabled {unit} ({target})");
            }
        }
    }
}

fn which(bin: &str) -> bool {
    std::env::var_os("PATH")
        .map(|p| {
            std::env::split_paths(&p).any(|d| d.join(bin).is_file())
        })
        .unwrap_or(false)
}

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

/// Source the scriptlet in the target root and call `hook` if it defines it.
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

#[cfg(test)]
mod tests {
    use super::*;

    // scripts have to survive the manifest round trip byte for byte: they run
    // as root, and the BUR publish check diffs them against the reviewed recipe.
    // the old parser quietly dropped everything after line one
    #[test]
    fn multiline_scriptlet_round_trips() {
        let manifest = "\
format = 1
name = \"demo\"
version = \"1.0\"
release = 2
arch = \"x86_64\"
installed_size = 10

[scripts]
post_install = '''
echo one
echo \"two\" a\\b
echo three
'''
";
        let (pkginfo, script) = bpm_manifest_to_pkginfo(manifest);
        assert!(pkginfo.contains("pkgver = 1.0-2"), "pkgver: {pkginfo}");
        let s = script.expect("scriptlet present");
        assert!(s.contains("echo one"), "missing line 1: {s}");
        assert!(s.contains("echo \"two\" a\\b"), "quotes/backslash mangled: {s}");
        assert!(s.contains("echo three"), "missing line 3: {s}");
        assert!(s.contains("post_install()"), "not wrapped as a hook fn: {s}");
    }

    #[test]
    fn single_line_scriptlet_still_parses() {
        let manifest = "name = \"x\"\nversion = \"1\"\n[scripts]\npost_remove = \"rm -f /x\"\n";
        let (_pi, script) = bpm_manifest_to_pkginfo(manifest);
        assert!(script.unwrap().contains("rm -f /x"));
    }
}
