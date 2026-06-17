//! HTTP(S) downloads. TLS is rustls (via ureq); the public repo cert validates
//! against the bundled Mozilla roots, the same trust set as the system
//! ca-certificates bundle. Streams the body to a file — never into RAM.

use std::fs::{File, OpenOptions};
use std::io;
use std::net::{SocketAddr, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

/// Shared agent with an IPv4-first resolver. Many setups (notably QEMU SLIRP)
/// hand out a site-local IPv6 with no route to the internet; a dual-stack repo
/// then resolves to an unreachable AAAA and downloads hang/fail. Trying IPv4
/// first makes bpm work regardless of a broken/half-configured IPv6 stack.
fn agent() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| {
        ureq::builder()
            // Connect timeout fails fast on an unreachable mirror; the read
            // timeout is per-read (resets while bytes flow), so a large package
            // (gcc is ~84 MB) downloads for as long as it keeps making progress.
            // A single overall timeout would kill big downloads on slow links.
            .timeout_connect(Duration::from_secs(20))
            .timeout_read(Duration::from_secs(120))
            .resolver(|netloc: &str| -> io::Result<Vec<SocketAddr>> {
                let mut addrs: Vec<SocketAddr> = netloc.to_socket_addrs()?.collect();
                addrs.sort_by_key(SocketAddr::is_ipv6); // IPv4 (false) before IPv6
                Ok(addrs)
            })
            .build()
    })
}

fn other(e: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::Other, e.to_string())
}

/// GET `url` into `dest`. Downloads to `<dest>.part` and renames on success, so
/// `dest` only ever exists complete. If a `.part` from an interrupted run is
/// present, resume it with a Range request (the server may ignore it, in which
/// case we restart). Returns Ok on success.
pub fn get(url: &str, dest: &Path) -> io::Result<()> {
    let part = PathBuf::from(format!("{}.part", dest.display()));
    let have = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);

    let (resp, append) = if have > 0 {
        let r = agent()
            .get(url)
            .set("Range", &format!("bytes={have}-"))
            .call()
            .map_err(other)?;
        let resumed = r.status() == 206; // 206 = partial; 200 = full, restart
        (r, resumed)
    } else {
        (agent().get(url).call().map_err(other)?, false)
    };

    let mut reader = resp.into_reader();
    let mut out = if append {
        OpenOptions::new().append(true).open(&part)?
    } else {
        File::create(&part)?
    };
    io::copy(&mut reader, &mut out)?;
    out.sync_all()?;
    drop(out);
    std::fs::rename(&part, dest)?;
    Ok(())
}
