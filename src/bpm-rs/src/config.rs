//! Where everything lives. Same paths as the C bpm, keep it that way.

use std::path::PathBuf;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub struct Config {
    pub root: String,   // "" for "/", else an absolute dir with no trailing slash
    pub dest: PathBuf,  // real fs target, never "" ("/" when unrooted)
    pub db: PathBuf,
    pub cache: PathBuf,
    pub index: PathBuf,
    pub conf: PathBuf,
    pub provided: PathBuf,
}

impl Config {
    pub fn from_env() -> Config {
        let mut root = std::env::var("BPM_ROOT").unwrap_or_default();
        if root.is_empty() {
            root = "/".to_string();
        }
        // drop trailing slashes, and "/" becomes ""
        while root.len() > 1 && root.ends_with('/') {
            root.pop();
        }
        if root == "/" {
            root.clear();
        }
        let dest = if root.is_empty() {
            PathBuf::from("/")
        } else {
            PathBuf::from(&root)
        };
        let under = |p: &str| PathBuf::from(format!("{root}{p}"));
        Config {
            dest,
            db: under("/var/lib/bpm/db"),
            cache: under("/var/lib/bpm/cache"),
            index: under("/var/lib/bpm/index"),
            conf: under("/etc/bpm/repos.conf"),
            provided: under("/etc/bpm/provided"),
            root,
        }
    }

    /// Installing somewhere other than / (scriptlets have to chroot).
    pub fn rooted(&self) -> bool {
        !self.root.is_empty()
    }
}
