//! Downloads. ureq + rustls with the bundled Mozilla roots (same set as
//! ca-certificates). Bodies go straight to disk, never into RAM.

use std::fs::{File, OpenOptions};
use std::io::{self, IsTerminal, Read, Write};
use std::net::{SocketAddr, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

/// One pacman-style progress line shared by all the parallel downloads.
pub struct Progress {
    total_pkgs: usize,
    done_pkgs: AtomicUsize,
    total_bytes: AtomicU64, // grows as each download reports its Content-Length
    done_bytes: AtomicU64,
    start: Instant,
    stop: AtomicBool,
}

impl Progress {
    pub fn new(total_pkgs: usize) -> Self {
        Progress {
            total_pkgs,
            done_pkgs: AtomicUsize::new(0),
            total_bytes: AtomicU64::new(0),
            done_bytes: AtomicU64::new(0),
            start: Instant::now(),
            stop: AtomicBool::new(false),
        }
    }
    fn add_total(&self, n: u64) { self.total_bytes.fetch_add(n, Ordering::Relaxed); }
    fn add(&self, n: u64) { self.done_bytes.fetch_add(n, Ordering::Relaxed); }
    pub fn finish_pkg(&self) { self.done_pkgs.fetch_add(1, Ordering::Relaxed); }
    pub fn stop(&self) { self.stop.store(true, Ordering::Relaxed); }

    fn line(&self) -> String {
        let done = self.done_bytes.load(Ordering::Relaxed);
        let total = self.total_bytes.load(Ordering::Relaxed);
        let dp = self.done_pkgs.load(Ordering::Relaxed);
        let secs = self.start.elapsed().as_secs_f64().max(0.001);
        let speed = done as f64 / secs / 1_048_576.0; // MiB/s
        let mib = |b: u64| b as f64 / 1_048_576.0;
        let pct = if total > 0 {
            (done as f64 / total as f64 * 100.0).min(100.0)
        } else {
            0.0
        };
        format!(
            ":: downloading  {}/{} pkgs  {:.1}/{:.1} MiB  {:>3.0}%  {:.1} MiB/s",
            dp, self.total_pkgs, mib(done), mib(total), pct, speed
        )
    }

    /// Repaints until stop(), then clears the line. Run it on its own thread.
    pub fn run(&self) {
        let tty = std::io::stderr().is_terminal();
        while !self.stop.load(Ordering::Relaxed) {
            if tty {
                eprint!("\r\x1b[K{}", self.line());
                let _ = std::io::stderr().flush();
            }
            std::thread::sleep(Duration::from_millis(150));
        }
        if tty {
            eprint!("\r\x1b[K");
            let _ = std::io::stderr().flush();
        }
    }
}

/// IPv4 goes first. QEMU SLIRP (and plenty of real networks) hand out an IPv6
/// address with no route anywhere, and then every download hangs on the AAAA.
fn agent() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| {
        ureq::builder()
            // no overall timeout on purpose: it would kill gcc (~84 MB) on a
            // slow link. the read timeout resets whenever bytes arrive
            .timeout_connect(Duration::from_secs(20))
            .timeout_read(Duration::from_secs(120))
            .resolver(|netloc: &str| -> io::Result<Vec<SocketAddr>> {
                let mut addrs: Vec<SocketAddr> = netloc.to_socket_addrs()?.collect();
                addrs.sort_by_key(SocketAddr::is_ipv6); // false sorts first, so v4 wins
                Ok(addrs)
            })
            .build()
    })
}

fn other(e: impl std::fmt::Display) -> io::Error {
    io::Error::other(e.to_string())
}

/// GET `url` into `dest` via `<dest>.part`, so `dest` is only ever complete.
/// A leftover .part gets resumed with a Range request; if the server ignores
/// that we just start over.
pub fn get(url: &str, dest: &Path, prog: Option<&Progress>) -> io::Result<()> {
    let part = PathBuf::from(format!("{}.part", dest.display()));
    let have = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);

    let (resp, append) = if have > 0 {
        let r = agent()
            .get(url)
            .set("Range", &format!("bytes={have}-"))
            .call()
            .map_err(other)?;
        let resumed = r.status() == 206; // 200 means it sent the whole thing
        (r, resumed)
    } else {
        (agent().get(url).call().map_err(other)?, false)
    };

    if let Some(p) = prog {
        let clen = resp
            .header("Content-Length")
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(0);
        let already = if append { have } else { 0 };
        p.add_total(clen + already);
        if already > 0 {
            p.add(already);
        }
    }

    let mut reader = resp.into_reader();
    let mut out = if append {
        OpenOptions::new().append(true).open(&part)?
    } else {
        File::create(&part)?
    };
    // not io::copy, the progress bar wants to see the bytes
    let mut buf = vec![0u8; 65536];
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        out.write_all(&buf[..n])?;
        if let Some(p) = prog {
            p.add(n as u64);
        }
    }
    out.sync_all()?;
    drop(out);
    std::fs::rename(&part, dest)?;
    Ok(())
}
