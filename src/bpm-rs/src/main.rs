//! bpm — Blueberry Package Manager (Rust). Drop-in for the C bpm: same on-disk
//! DB/cache/index, same repo index + signature scheme, same commands.

mod cache;
mod config;
mod db;
mod index;
mod net;
mod pkg;
mod repo;
mod repokey;
mod sig;
mod vercmp;

use config::Config;
use std::cmp::Ordering;
use std::collections::HashSet;
use std::path::Path;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        usage();
        return ExitCode::FAILURE;
    }
    let cfg = Config::from_env();
    let rest = &args[1..];
    let r = match args[0].as_str() {
        "install" | "in" => cmd_install(&cfg, rest),
        "remove" | "rm" => cmd_remove(&cfg, rest),
        "autoremove" => cmd_autoremove(&cfg, rest),
        "update" | "up" => cmd_update(&cfg),
        "upgrade" => cmd_upgrade(&cfg),
        "rollback" | "rb" => cmd_rollback(&cfg, rest),
        "downgrade" | "dg" => cmd_downgrade(&cfg, rest),
        "clean" => cmd_clean(&cfg, rest),
        "search" | "se" => cmd_search(&cfg, rest),
        "list" | "ls" => cmd_list(&cfg),
        "info" => cmd_info(&cfg, rest),
        "why" => cmd_why(&cfg, rest),
        "depends" | "deptree" => cmd_depends(&cfg, rest),
        "files" => cmd_files(&cfg, rest),
        "owns" => cmd_owns(&cfg, rest),
        "-h" | "--help" | "help" => {
            usage();
            Ok(())
        }
        "-V" | "--version" => {
            println!("bpm {}", config::VERSION);
            Ok(())
        }
        other => Err(format!("unknown command '{other}' (try: bpm help)")),
    };
    match r {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("bpm: {e}");
            ExitCode::FAILURE
        }
    }
}

fn usage() {
    print!(
        "bpm {} — Blueberry Package Manager\n\n\
         \x20 bpm install <name|file.pkg.tar.zst>...   install (resolve deps from repos)\n\
         \x20 bpm remove  <name>...                    remove installed package(s)\n\
         \x20 bpm autoremove                           remove orphaned dependencies\n\
         \x20 bpm update                               sync repo indices\n\
         \x20 bpm upgrade                              upgrade all installed packages\n\
         \x20 bpm rollback <name>                      revert a package to the previous cached version\n\
         \x20 bpm downgrade <name>[=<ver>]             install a specific older cached version\n\
         \x20 bpm search  <term>                       search the repo index\n\
         \x20 bpm list                                 list installed packages\n\
         \x20 bpm info    <name>                       show package metadata\n\
         \x20 bpm why     <name>                       why a package is installed (reverse deps)\n\
         \x20 bpm depends <name>                       show a package's dependency tree\n\
         \x20 bpm files   <name>                       list files a package owns\n\
         \x20 bpm owns    <path>                       which package owns a path\n\
         \x20 bpm clean   [--all]                      prune cached downloads (keep 2 newest/pkg)\n\n\
         Flags: -f/--force  skip space/conflict/reverse-dep checks.\n\
         Env:   BPM_ROOT=<dir> installs into a staging root instead of /.\n",
        config::VERSION
    );
}

/// Pull -f/--force out of the argument list, returning (force, positionals).
fn split_flags(args: &[String]) -> (bool, Vec<String>) {
    let mut force = false;
    let mut pos = Vec::new();
    for a in args {
        match a.as_str() {
            "-f" | "--force" => force = true,
            // -y/--yes is meaningful for confirmation prompts (autoremove);
            // install/remove don't prompt, so accept and ignore it rather than
            // mistaking it for a package name.
            "-y" | "--yes" => {}
            _ => pos.push(a.clone()),
        }
    }
    (force, pos)
}

// ── install ──────────────────────────────────────────────────────────────────
fn cmd_install(cfg: &Config, args: &[String]) -> Result<(), String> {
    let (force, names) = split_flags(args);
    if names.is_empty() {
        return Err("usage: bpm install [-f] <name|file.pkg.tar.zst>...".into());
    }
    let mut seen = HashSet::new();
    let mut plan: Vec<(index::Entry, bool)> = Vec::new();
    let mut files: Vec<&String> = Vec::new();
    for a in &names {
        if a.contains(".pkg.tar.") || a.ends_with(".bpm") {
            files.push(a);
        } else {
            resolve(cfg, a, true, &mut seen, &mut plan);
        }
    }
    if !plan.is_empty() {
        // One disk-space check over the whole transitive set (index sizes).
        if !force {
            let need: u64 = plan.iter().map(|(e, _)| e.size).sum();
            if need > 0 {
                if let Some(free) = pkg::free_space(cfg) {
                    if free < need {
                        return Err(format!(
                            "not enough space — need {} MiB, {} MiB free (use -f to override)",
                            need / 1048576,
                            free / 1048576
                        ));
                    }
                }
            }
        }
        let jobs = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4)
            .clamp(1, 8);
        println!(":: downloading {} package(s) ({jobs} parallel)", plan.len());
        let paths = parallel_fetch(cfg, &plan, jobs)?;
        // Install in resolved order (dependencies before dependents).
        for ((entry, explicit), path) in plan.iter().zip(paths.iter()) {
            pkg::install_file(cfg, path, force).map_err(|e| e.to_string())?;
            if *explicit {
                db::mark_explicit(cfg, &entry.name);
            }
        }
    }
    for f in &files {
        let n = pkg::install_file(cfg, Path::new(f), force).map_err(|e| e.to_string())?;
        db::mark_explicit(cfg, &n);
    }
    pkg::refresh(cfg);
    Ok(())
}

/// Collect the transitive install set in dependency order (deps before
/// dependents), skipping provided/already-installed packages. Pure resolution —
/// no downloads — so the set can then be fetched in parallel.
fn resolve(
    cfg: &Config,
    name: &str,
    explicit: bool,
    seen: &mut HashSet<String>,
    plan: &mut Vec<(index::Entry, bool)>,
) {
    if !seen.insert(name.to_string()) {
        return;
    }
    if !explicit && index::is_provided(cfg, name) {
        return;
    }
    if db::is_installed(cfg, name) {
        if explicit {
            println!(":: {name} already installed");
        }
        return;
    }
    let entry = match index::lookup(cfg, name) {
        Some(e) => e,
        None => {
            eprintln!("bpm: warning: {name} not in repo index — assuming provided by the base system");
            return;
        }
    };
    for dep in &entry.deps {
        let dn = index::dep_name(dep);
        if !dn.is_empty() {
            resolve(cfg, dn, false, seen, plan);
        }
    }
    plan.push((entry, explicit));
}

/// Download every package in `plan` concurrently (bounded by `jobs`), preserving
/// order in the returned paths. Each fetch verifies its sha256 (repo::fetch).
fn parallel_fetch(
    cfg: &Config,
    plan: &[(index::Entry, bool)],
    jobs: usize,
) -> Result<Vec<std::path::PathBuf>, String> {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;
    let next = AtomicUsize::new(0);
    let slots: Vec<Mutex<Option<Result<std::path::PathBuf, String>>>> =
        (0..plan.len()).map(|_| Mutex::new(None)).collect();
    std::thread::scope(|s| {
        for _ in 0..jobs {
            s.spawn(|| loop {
                let i = next.fetch_add(1, Ordering::Relaxed);
                if i >= plan.len() {
                    break;
                }
                let r = repo::fetch(cfg, &plan[i].0);
                *slots[i].lock().unwrap() = Some(r);
            });
        }
    });
    let mut paths = Vec::with_capacity(plan.len());
    for slot in slots {
        match slot.into_inner().unwrap() {
            Some(Ok(p)) => paths.push(p),
            Some(Err(e)) => return Err(e),
            None => return Err("download did not complete".into()),
        }
    }
    Ok(paths)
}

/// Resolve `name` from the repos and install it with its dependencies first.
/// `explicit` (the user named it) installs even if it's in the provided base
/// set; transitive deps recurse with explicit=false and honour is_provided.
fn install_name(
    cfg: &Config,
    name: &str,
    explicit: bool,
    force: bool,
    seen: &mut HashSet<String>,
) -> Result<(), String> {
    if !seen.insert(name.to_string()) {
        return Ok(());
    }
    if !explicit && index::is_provided(cfg, name) {
        return Ok(());
    }
    if db::is_installed(cfg, name) {
        println!(":: {name} already installed");
        return Ok(());
    }
    let entry = match index::lookup(cfg, name) {
        Some(e) => e,
        None => {
            eprintln!("bpm: warning: {name} not in repo index — assuming provided by the base system");
            return Ok(());
        }
    };
    for dep in &entry.deps {
        let dn = index::dep_name(dep);
        if !dn.is_empty() {
            install_name(cfg, dn, false, force, seen)?;
        }
    }
    // Pre-download disk check from the index size — avoids fetching a big
    // package (gcc is ~84MB) only to fail at extraction on a full disk.
    if !force && entry.size > 0 {
        if let Some(free) = pkg::free_space(cfg) {
            if free < entry.size {
                return Err(format!(
                    "not enough space for {} — need {} MiB, {} MiB free (use -f to override)",
                    entry.name,
                    entry.size / 1048576,
                    free / 1048576
                ));
            }
        }
    }
    println!(":: downloading {} {}", entry.name, entry.version);
    let path = repo::fetch(cfg, &entry)?;
    pkg::install_file(cfg, &path, force).map_err(|e| e.to_string())?;
    if explicit {
        db::mark_explicit(cfg, name);
    }
    Ok(())
}

// ── remove ───────────────────────────────────────────────────────────────────
fn cmd_remove(cfg: &Config, args: &[String]) -> Result<(), String> {
    let (force, names) = split_flags(args);
    if names.is_empty() {
        return Err("usage: bpm remove [-f] <name>...".into());
    }
    for name in &names {
        if !db::is_installed(cfg, name) {
            return Err(format!("{name} is not installed"));
        }
    }
    let removing: HashSet<String> = names.iter().cloned().collect();

    // Refuse to strand a still-needed package (e.g. `bpm remove glibc`).
    if !force {
        for name in &names {
            let req = db::requirers(cfg, name, &removing);
            if !req.is_empty() {
                return Err(format!(
                    "cannot remove {name}: still required by {} (use -f to override)",
                    req.join(", ")
                ));
            }
        }
    }

    // Gather the removed packages' dependencies first, to report new orphans.
    let mut dep_candidates: Vec<String> = Vec::new();
    for name in &names {
        for d in db::package_deps(cfg, name) {
            if !removing.contains(&d) && !dep_candidates.contains(&d) {
                dep_candidates.push(d);
            }
        }
    }

    for name in &names {
        println!(":: removing {name}");
        db::remove_files(cfg, name);
        db::remove(cfg, name);
        println!(":: removed {name}");
    }
    pkg::refresh(cfg);

    let orphans: Vec<String> = dep_candidates
        .into_iter()
        .filter(|d| db::is_installed(cfg, d) && db::requirers(cfg, d, &removing).is_empty())
        .collect();
    if !orphans.is_empty() {
        eprintln!(
            "bpm: note: now unneeded (orphans): {} — remove with 'bpm remove {}'",
            orphans.join(", "),
            orphans.join(" ")
        );
    }
    Ok(())
}

// ── clean ────────────────────────────────────────────────────────────────────
/// Prune the package cache. By default keep the KEEP newest versions of each
/// package (so `bpm rollback`/`downgrade` still have something to fall back to);
/// `--all` empties the cache entirely. Also sweeps stray `.part` downloads.
fn cmd_clean(cfg: &Config, args: &[String]) -> Result<(), String> {
    const KEEP: usize = 2;
    let all = args.iter().any(|a| a == "--all" || a == "-a");
    let mut n = 0u64;
    let mut bytes = 0u64;
    let mut rm = |p: &std::path::Path| {
        let sz = std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
        if std::fs::remove_file(p).is_ok() {
            n += 1;
            bytes += sz;
        }
    };

    for (_name, versions) in cache::grouped(cfg) {
        let skip = if all { 0 } else { KEEP };
        for c in versions.into_iter().skip(skip) {
            rm(&c.path);
        }
    }
    // Interrupted partial downloads are never worth keeping.
    if let Ok(rd) = std::fs::read_dir(&cfg.cache) {
        for e in rd.flatten() {
            let p = e.path();
            if p.extension().and_then(|x| x.to_str()) == Some("part") {
                rm(&p);
            }
        }
    }

    if all {
        println!(":: emptied cache — removed {n} file(s), freed {} MiB", bytes / 1048576);
    } else {
        println!(
            ":: pruned {n} old cached package(s) (kept {KEEP} newest each), freed {} MiB",
            bytes / 1048576
        );
    }
    Ok(())
}

// ── rollback / downgrade ─────────────────────────────────────────────────────
/// Reinstall a package's previous version from the local cache.
fn cmd_rollback(cfg: &Config, args: &[String]) -> Result<(), String> {
    let (force, names) = split_flags(args);
    let name = names.first().ok_or("usage: bpm rollback [-f] <name>")?;
    let cur = db::installed_version(cfg, name)
        .ok_or_else(|| format!("{name} is not installed"))?;
    match cache::previous(cfg, name, &cur) {
        Some(c) => {
            println!(":: rolling back {name} {cur} -> {}", c.version);
            install_cached(cfg, name, &c.path, force)
        }
        None => {
            let have = cache::versions(cfg, name);
            let list = if have.is_empty() {
                "cache is empty for this package".to_string()
            } else {
                format!(
                    "cached: {}",
                    have.iter().map(|c| c.version.as_str()).collect::<Vec<_>>().join(", ")
                )
            };
            Err(format!(
                "no cached version of {name} older than {cur} to roll back to ({list})"
            ))
        }
    }
}

/// Install a specific older cached version (`bpm downgrade foo=1.2.3`), or the
/// previous version when no `=<ver>` is given.
fn cmd_downgrade(cfg: &Config, args: &[String]) -> Result<(), String> {
    let (force, names) = split_flags(args);
    let spec = names.first().ok_or("usage: bpm downgrade [-f] <name>[=<version>]")?;
    let (name, want) = match spec.split_once('=') {
        Some((n, v)) => (n.to_string(), Some(v.to_string())),
        None => (spec.clone(), None),
    };
    if !db::is_installed(cfg, &name) {
        return Err(format!("{name} is not installed"));
    }
    let target = match want {
        Some(v) => cache::exact(cfg, &name, &v).ok_or_else(|| {
            let have = cache::versions(cfg, &name);
            let list = have.iter().map(|c| c.version.as_str()).collect::<Vec<_>>().join(", ");
            format!("version {v} of {name} not in cache (cached: {list})")
        })?,
        None => {
            let cur = db::installed_version(cfg, &name).unwrap_or_default();
            cache::previous(cfg, &name, &cur)
                .ok_or_else(|| format!("no cached version of {name} older than {cur}"))?
        }
    };
    println!(":: downgrading {name} -> {}", target.version);
    install_cached(cfg, &name, &target.path, force)
}

/// Shared tail for rollback/downgrade: install a cached artifact (force, since
/// it is an intentional version change), preserving the explicit flag, then
/// refresh ldconfig + the man index.
fn install_cached(cfg: &Config, name: &str, path: &Path, force: bool) -> Result<(), String> {
    let was_explicit = db::is_explicit(cfg, name);
    pkg::install_file(cfg, path, force).map_err(|e| e.to_string())?;
    if was_explicit {
        db::mark_explicit(cfg, name);
    }
    pkg::refresh(cfg);
    Ok(())
}

// ── autoremove ───────────────────────────────────────────────────────────────
fn cmd_autoremove(cfg: &Config, args: &[String]) -> Result<(), String> {
    let yes = args.iter().any(|a| a == "-y" || a == "--yes");

    // An orphan is an installed package that wasn't explicitly requested and
    // that nothing else still depends on. Removing one can orphan its own deps,
    // so iterate until the set is stable.
    let mut removed = 0;
    loop {
        let mut orphans: Vec<String> = Vec::new();
        for name in db::installed_names(cfg) {
            if db::is_explicit(cfg, &name) {
                continue;
            }
            let mut self_set = HashSet::new();
            self_set.insert(name.clone());
            if db::requirers(cfg, &name, &self_set).is_empty() {
                orphans.push(name);
            }
        }
        if orphans.is_empty() {
            break;
        }
        if !yes {
            eprintln!("bpm: orphaned packages (not explicitly installed, unused):");
            for o in &orphans {
                eprintln!("    {o}");
            }
            eprintln!("bpm: run 'bpm autoremove -y' to remove them");
            return Ok(());
        }
        for name in &orphans {
            println!(":: removing orphan {name}");
            db::remove_files(cfg, name);
            db::remove(cfg, name);
            removed += 1;
        }
    }
    if removed > 0 {
        pkg::refresh(cfg);
        println!(":: removed {removed} orphan(s)");
    } else {
        println!(":: no orphans");
    }
    Ok(())
}

// ── update ───────────────────────────────────────────────────────────────────
fn cmd_update(cfg: &Config) -> Result<(), String> {
    let conf = std::fs::read_to_string(&cfg.conf)
        .map_err(|_| format!("no repo config: {}", cfg.conf.display()))?;
    if let Some(parent) = cfg.index.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let tmp = cfg.index.with_extension("repo");

    let mut combined = String::new();
    for line in conf.lines() {
        let s = line.trim();
        if s.is_empty() || s.starts_with('#') {
            continue;
        }
        let mut it = s.split_whitespace();
        let repo = match it.next() {
            Some(r) => r,
            None => continue,
        };
        let mut got = false;
        for url in it {
            println!(":: syncing '{repo}' from {url}");
            if let Err(e) = net::get(&format!("{url}/bpm.index"), &tmp) {
                eprintln!("bpm: warning: mirror unreachable: {url} ({e})");
                continue;
            }
            let body = match std::fs::read(&tmp) {
                Ok(b) if !b.is_empty() => b,
                _ => {
                    eprintln!("bpm: warning: empty index from {url}");
                    continue;
                }
            };
            // Verify the detached ed25519 signature over the raw index bytes
            // (bpm.index.sig, next to the index). Never trust an unsigned/invalid
            // index unless BPM_ALLOW_UNSIGNED is set.
            if sig::required() {
                let sigtmp = cfg.index.with_extension("sig");
                let ok = net::get(&format!("{url}/bpm.index.sig"), &sigtmp).is_ok()
                    && std::fs::read(&sigtmp)
                        .map(|s| sig::verify_index(&body, &s))
                        .unwrap_or(false);
                let _ = std::fs::remove_file(&sigtmp);
                if !ok {
                    eprintln!("bpm: warning: signature verification FAILED for '{repo}' from {url}");
                    continue;
                }
            }
            for l in String::from_utf8_lossy(&body).lines() {
                if l.is_empty() {
                    continue;
                }
                combined.push_str(l);
                combined.push('|');
                combined.push_str(repo);
                combined.push('\n');
            }
            got = true;
            break;
        }
        if !got {
            eprintln!("bpm: warning: all mirrors failed for repo '{repo}'");
        }
    }
    let _ = std::fs::remove_file(&tmp);

    let itmp = cfg.index.with_extension("tmp");
    std::fs::write(&itmp, &combined).map_err(|e| format!("cannot write index: {e}"))?;
    std::fs::rename(&itmp, &cfg.index).map_err(|e| format!("cannot replace index: {e}"))?;

    let count = combined.lines().filter(|l| !l.is_empty()).count();
    println!(":: {count} packages in index");
    Ok(())
}

// ── upgrade ──────────────────────────────────────────────────────────────────
fn cmd_upgrade(cfg: &Config) -> Result<(), String> {
    let mut plan: Vec<(String, String, String, index::Entry)> = Vec::new();
    for name in db::installed_names(cfg) {
        let have = match db::installed_version(cfg, &name) {
            Some(v) => v,
            None => continue,
        };
        if let Some(e) = index::lookup(cfg, &name) {
            if vercmp::vercmp(&e.version, &have) == Ordering::Greater {
                plan.push((name, have, e.version.clone(), e));
            }
        }
    }
    if plan.is_empty() {
        println!(":: everything is up to date");
        return Ok(());
    }
    println!(":: {} package(s) to upgrade:", plan.len());
    for (n, from, to, _) in &plan {
        println!("    {n:<20} {from} -> {to}");
    }
    let mut seen = HashSet::new();
    let mut ok = 0;
    for (_, _, _, e) in &plan {
        let path = match repo::fetch(cfg, e) {
            Ok(p) => p,
            Err(err) => {
                eprintln!("bpm: warning: {err}");
                continue;
            }
        };
        if let Err(err) = pkg::install_file(cfg, &path, false) {
            eprintln!("bpm: warning: {err}");
            continue;
        }
        for dep in &e.deps {
            let dn = index::dep_name(dep);
            if !dn.is_empty() {
                let _ = install_name(cfg, dn, false, false, &mut seen);
            }
        }
        ok += 1;
    }
    pkg::refresh(cfg);
    println!(":: upgraded {ok}/{} package(s)", plan.len());
    Ok(())
}

// ── query commands ───────────────────────────────────────────────────────────
fn cmd_search(cfg: &Config, args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        return Err("usage: bpm search <term>".into());
    }
    let term = args[0].to_lowercase();
    for e in index::load_all(cfg) {
        if e.name.to_lowercase().contains(&term) || e.desc.to_lowercase().contains(&term) {
            let mark = if db::is_installed(cfg, &e.name) {
                " [installed]"
            } else {
                ""
            };
            println!("{} {} ({}){}", e.name, e.version, e.repo, mark);
            if !e.desc.is_empty() {
                println!("    {}", e.desc);
            }
        }
    }
    Ok(())
}

fn cmd_list(cfg: &Config) -> Result<(), String> {
    for name in db::installed_names(cfg) {
        let v = db::installed_version(cfg, &name).unwrap_or_default();
        println!("{name} {v}");
    }
    Ok(())
}

fn cmd_info(cfg: &Config, args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        return Err("usage: bpm info <name>".into());
    }
    let name = &args[0];
    let desc = cfg.db.join(name).join("desc");
    if let Ok(txt) = std::fs::read_to_string(&desc) {
        print!("{txt}");
        return Ok(());
    }
    match index::lookup(cfg, name) {
        Some(e) => {
            println!("name    : {}", e.name);
            println!("version : {}", e.version);
            println!("repo    : {}", e.repo);
            if !e.desc.is_empty() {
                println!("desc    : {}", e.desc);
            }
            if e.size > 0 {
                println!("size    : {} MiB", e.size / 1048576);
            }
            println!("depends : {}", e.deps.join(" "));
            println!("file    : {}", e.filename);
            Ok(())
        }
        None => Err(format!("{name}: not installed and not in any repo")),
    }
}

fn cmd_files(cfg: &Config, args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        return Err("usage: bpm files <name>".into());
    }
    let name = &args[0];
    if !db::is_installed(cfg, name) {
        return Err(format!("{name} is not installed"));
    }
    for f in db::read_files(cfg, name) {
        println!("/{f}");
    }
    Ok(())
}

fn cmd_owns(cfg: &Config, args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        return Err("usage: bpm owns <path>".into());
    }
    let rel = args[0].trim_start_matches('/');
    match db::owner(cfg, rel) {
        Some(n) => {
            println!("/{rel} is owned by {n}");
            Ok(())
        }
        None => Err(format!("no package owns /{rel}")),
    }
}

/// Explain why a package is on the system: which installed packages require it,
/// and whether the user asked for it explicitly.
fn cmd_why(cfg: &Config, args: &[String]) -> Result<(), String> {
    let name = args.first().ok_or("usage: bpm why <name>")?;
    if !db::is_installed(cfg, name) {
        return Err(format!("{name} is not installed"));
    }
    let explicit = db::is_explicit(cfg, name);
    let reqs = db::requirers(cfg, name, &HashSet::new());
    if reqs.is_empty() {
        if explicit {
            println!("{name} was explicitly installed; nothing else depends on it.");
        } else {
            println!(
                "{name} is installed but nothing requires it and it isn't explicit — \
                 an orphan (remove with 'bpm autoremove')."
            );
        }
    } else {
        println!("{name} is required by:");
        for r in &reqs {
            let tag = if db::is_explicit(cfg, r) { " (explicit)" } else { "" };
            println!("    {r}{tag}");
        }
        if explicit {
            println!("{name} is also explicitly installed.");
        }
    }
    Ok(())
}

/// Print a package's dependency tree (installed deps from the DB, otherwise the
/// repo index). Base-provided deps are tagged and not recursed into.
fn cmd_depends(cfg: &Config, args: &[String]) -> Result<(), String> {
    let name = args.first().ok_or("usage: bpm depends <name>")?;
    if !db::is_installed(cfg, name) && index::lookup(cfg, name).is_none() {
        return Err(format!("{name}: not installed and not in any repo"));
    }
    println!("{name}");
    let mut seen = HashSet::new();
    seen.insert(name.clone());
    print_deptree(cfg, name, "", &mut seen);
    Ok(())
}

/// Direct dependency names of `name`: from the installed DB when present, else
/// from the repo index.
fn deps_of(cfg: &Config, name: &str) -> Vec<String> {
    if db::is_installed(cfg, name) {
        db::package_deps(cfg, name)
    } else if let Some(e) = index::lookup(cfg, name) {
        e.deps
            .iter()
            .map(|d| index::dep_name(d).to_string())
            .filter(|d| !d.is_empty())
            .collect()
    } else {
        Vec::new()
    }
}

fn print_deptree(cfg: &Config, name: &str, prefix: &str, seen: &mut HashSet<String>) {
    let deps = deps_of(cfg, name);
    let n = deps.len();
    for (i, dep) in deps.iter().enumerate() {
        let last = i + 1 == n;
        let branch = if last { "└─ " } else { "├─ " };
        let tag = if index::is_provided(cfg, dep) {
            " (base)"
        } else if db::is_installed(cfg, dep) {
            ""
        } else {
            " (missing)"
        };
        let repeated = seen.contains(dep);
        let ell = if repeated { " ..." } else { "" };
        println!("{prefix}{branch}{dep}{tag}{ell}");
        if !repeated && !index::is_provided(cfg, dep) {
            seen.insert(dep.clone());
            let child = format!("{prefix}{}", if last { "   " } else { "│  " });
            print_deptree(cfg, dep, &child, seen);
        }
    }
}
