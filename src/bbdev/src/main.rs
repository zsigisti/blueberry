//! bbdev — the Blueberry repository developer tool.
//!
//! Run it inside a checkout of the Blueberry source tree after editing recipes.
//! With no arguments it does the obvious thing: looks at what you changed under
//! `packages/`, builds those recipes in the ephemeral Arch build container (via
//! tools/pkg/build-bpm-pkg.sh), runs the dependency-closure check, and reports.
//!
//!   bbdev              auto — build the recipes you changed, then closure-check
//!   bbdev status       show changed / never-built recipes; don't build
//!   bbdev build [pkg…] build the given packages (default: the changed set)
//!   bbdev check        run the dependency-closure check
//!   bbdev list         list every recipe
//!   bbdev help
//!
//! Pure std; shells out to git + the repo's existing tools. Needs git and a
//! container engine (podman or docker) on PATH to actually build.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::{exit, Command};
use std::time::SystemTime;

const OUT: &str = "obj/bpm-out";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("auto");
    let rest = if args.is_empty() { &[][..] } else { &args[1..] };
    let root = repo_root();
    let rc = match cmd {
        "auto" => cmd_auto(&root),
        "status" | "st" => cmd_status(&root),
        "build" => cmd_build(&root, rest),
        "check" => cmd_check(&root),
        "list" | "ls" => cmd_list(&root),
        "-h" | "--help" | "help" => {
            usage();
            0
        }
        "-V" | "--version" => {
            println!("bbdev {}", env!("CARGO_PKG_VERSION"));
            0
        }
        other => {
            eprintln!("bbdev: unknown command '{other}' (try: bbdev help)");
            2
        }
    };
    exit(rc);
}

fn usage() {
    print!(
        "bbdev {} — Blueberry repository developer tool\n\n\
         \x20 bbdev              auto: build the recipes you changed, then closure-check\n\
         \x20 bbdev status       show changed / never-built recipes (no build)\n\
         \x20 bbdev build [pkg…] build the given packages (default: the changed set)\n\
         \x20 bbdev check        run the dependency-closure check\n\
         \x20 bbdev list         list every recipe\n\n\
         Env: ENGINE=podman|docker (build container). Needs git + a container engine.\n",
        env!("CARGO_PKG_VERSION")
    );
}

// ── repo discovery ────────────────────────────────────────────────────────────
fn repo_root() -> PathBuf {
    let out = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output();
    match out {
        Ok(o) if o.status.success() => {
            let p = PathBuf::from(String::from_utf8_lossy(&o.stdout).trim());
            if p.join("packages").is_dir() && p.join("tools/pkg/build-bpm-pkg.sh").is_file() {
                return p;
            }
            die("this git repo isn't a Blueberry source tree (missing packages/ or tools/pkg/build-bpm-pkg.sh)");
        }
        _ => die("not inside a git repository — run bbdev from a Blueberry checkout"),
    }
}

fn die(msg: &str) -> ! {
    eprintln!("bbdev: {msg}");
    exit(1);
}

// ── recipe discovery ──────────────────────────────────────────────────────────
fn all_recipes(root: &Path) -> BTreeSet<String> {
    let mut set = BTreeSet::new();
    if let Ok(rd) = std::fs::read_dir(root.join("packages")) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if e.path().join("bpm.toml").is_file() {
                set.insert(name);
            }
        }
    }
    set
}

/// Package names whose recipe or files changed in the working tree or index.
fn changed(root: &Path) -> BTreeSet<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["status", "--porcelain", "--", "packages"])
        .output()
        .unwrap_or_else(|e| die(&format!("git status failed: {e}")));
    let recipes = all_recipes(root);
    let mut set = BTreeSet::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let path = line.get(3..).unwrap_or("").trim();
        let path = path.rsplit(" -> ").next().unwrap_or(path).trim_matches('"');
        if let Some(name) = path.strip_prefix("packages/").and_then(|p| p.split('/').next()) {
            if recipes.contains(name) {
                set.insert(name.to_string());
            }
        }
    }
    set
}

/// Recipes with no built .bpm, or whose bpm.toml is newer than the newest build.
fn stale(root: &Path) -> BTreeSet<String> {
    let outdir = root.join(OUT);
    let mut set = BTreeSet::new();
    for name in all_recipes(root) {
        let rec = root.join("packages").join(&name).join("bpm.toml");
        let rm = mtime(&rec);
        match newest_bpm(&outdir, &name) {
            Some(bm) if rm.map(|r| bm >= r).unwrap_or(false) => {}
            _ => {
                set.insert(name);
            }
        }
    }
    set
}

fn mtime(p: &Path) -> Option<SystemTime> {
    std::fs::metadata(p).and_then(|m| m.modified()).ok()
}

fn newest_bpm(outdir: &Path, name: &str) -> Option<SystemTime> {
    let rd = std::fs::read_dir(outdir).ok()?;
    let prefix = format!("{name}-");
    let mut newest: Option<SystemTime> = None;
    for e in rd.flatten() {
        let f = e.file_name().to_string_lossy().into_owned();
        // <name>-<version>-<rel>-<arch>.bpm ; anchor on a digit after "name-"
        if f.starts_with(&prefix)
            && f.ends_with(".bpm")
            && f[prefix.len()..].chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false)
        {
            if let Some(m) = mtime(&e.path()) {
                newest = Some(newest.map_or(m, |n| n.max(m)));
            }
        }
    }
    newest
}

// ── commands ──────────────────────────────────────────────────────────────────
fn cmd_status(root: &Path) -> i32 {
    let ch = changed(root);
    let st = stale(root);
    let st_only: Vec<_> = st.difference(&ch).cloned().collect();
    println!("repo: {}", root.display());
    if ch.is_empty() {
        println!("changed recipes: none");
    } else {
        println!("changed recipes ({}):", ch.len());
        for n in &ch {
            println!("  * {n}");
        }
    }
    if !st_only.is_empty() {
        println!("never-built / stale ({}):", st_only.len());
        for n in &st_only {
            println!("  - {n}");
        }
    }
    0
}

fn cmd_list(root: &Path) -> i32 {
    for n in all_recipes(root) {
        println!("{n}");
    }
    0
}

fn cmd_check(root: &Path) -> i32 {
    run(root, "python3", &["tools/pkg/check-closure.py"])
}

fn cmd_build(root: &Path, names: &[String]) -> i32 {
    let targets: Vec<String> = if names.is_empty() {
        let ch = changed(root);
        if ch.is_empty() {
            println!("bbdev: nothing changed under packages/ — nothing to build");
            return 0;
        }
        ch.into_iter().collect()
    } else {
        // validate the names are real recipes
        let recipes = all_recipes(root);
        for n in names {
            if !recipes.contains(n) {
                die(&format!("no recipe: packages/{n}/bpm.toml"));
            }
        }
        names.to_vec()
    };
    println!("bbdev: building {}: {}", targets.len(), targets.join(" "));
    let mut argv = vec!["tools/pkg/build-bpm-pkg.sh".to_string(), OUT.to_string()];
    argv.extend(targets);
    let sh_args: Vec<&str> = argv.iter().map(String::as_str).collect();
    run(root, "sh", &sh_args)
}

fn cmd_auto(root: &Path) -> i32 {
    let ch = changed(root);
    if ch.is_empty() {
        println!("bbdev: nothing changed under packages/.");
        let st = stale(root);
        if !st.is_empty() {
            println!(
                "  {} recipe(s) have no fresh build — run `bbdev build {}` to build them.",
                st.len(),
                st.iter().take(6).cloned().collect::<Vec<_>>().join(" ")
            );
        }
        return cmd_check(root);
    }
    println!("== bbdev: building changed recipes ==");
    let b = cmd_build(root, &[]);
    if b != 0 {
        eprintln!("bbdev: build failed — not running closure check");
        return b;
    }
    println!("== bbdev: dependency-closure check ==");
    cmd_check(root)
}

// ── process helper ────────────────────────────────────────────────────────────
fn run(root: &Path, prog: &str, args: &[&str]) -> i32 {
    match Command::new(prog).current_dir(root).args(args).status() {
        Ok(s) => s.code().unwrap_or(1),
        Err(e) => {
            eprintln!("bbdev: cannot run {prog}: {e}");
            127
        }
    }
}
