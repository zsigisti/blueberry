//! bbconsole: the Blueberry web console daemon.
//!
//! Small privileged HTTPS API + static file server for the web UI. Wraps the
//! tools the box already has (systemctl, bpm, /proc) behind /api/v1.
//!
//! Listens on 0.0.0.0:9090 with its own self-signed TLS by default, since it's
//! meant to be hit straight over the LAN. BBCONSOLE_BIND=127.0.0.1:9090 if you'd
//! rather hide it behind a reverse proxy. Login is PAM (or the bootstrap token),
//! writes are argument-checked and go to the audit log. See doc/WEBUI.md.

mod api;
mod auth;
mod http;
mod installer;

use auth::{Sessions, Throttle};
use http::{Request, Response};
use rustls::{ServerConfig, ServerConnection, StreamOwned};
use serde_json::json;
use std::io::{BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

// covers handshake, read and write, so a slow-loris can't pin a thread forever
const IO_TIMEOUT: Duration = Duration::from_secs(20);
// one thread per connection, so cap them. plenty for one admin
const MAX_CONNS: usize = 128;

struct Config {
    bind: String,
    web_root: PathBuf,
    token_path: PathBuf,
    audit_path: PathBuf,
    admin_group: String,
    cert_path: PathBuf,
    key_path: PathBuf,
}

impl Config {
    fn load() -> Config {
        Config {
            bind: env("BBCONSOLE_BIND", "0.0.0.0:9090"),
            web_root: PathBuf::from(env("BBCONSOLE_WEB", "/usr/share/blueberry-console/web")),
            token_path: PathBuf::from(env("BBCONSOLE_TOKEN", "/etc/blueberry/console/token")),
            audit_path: PathBuf::from(env("BBCONSOLE_AUDIT", "/var/log/blueberry-console/audit.log")),
            // root + members of this group may log in
            admin_group: env("BBCONSOLE_ADMIN_GROUP", "wheel"),
            cert_path: PathBuf::from(env("BBCONSOLE_CERT", "/etc/blueberry/console/cert.pem")),
            key_path: PathBuf::from(env("BBCONSOLE_KEY", "/etc/blueberry/console/key.pem")),
        }
    }
}

fn env(k: &str, default: &str) -> String {
    std::env::var(k).unwrap_or_else(|_| default.to_string())
}

struct State {
    cfg: Config,
    sessions: Sessions,
    throttle: Throttle,
    tls: Arc<ServerConfig>,
    inflight: AtomicUsize,
    install: Arc<Mutex<installer::InstallJob>>,
}

fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();

    let cfg = Config::load();
    let token = auth::load_or_create_token(&cfg.token_path)
        .unwrap_or_else(|e| { eprintln!("bbconsole: cannot init token: {e}"); std::process::exit(1); });
    ensure_cert(&cfg.cert_path, &cfg.key_path);
    let tls = load_tls(&cfg.cert_path, &cfg.key_path)
        .unwrap_or_else(|| { eprintln!("bbconsole: cannot load TLS cert/key"); std::process::exit(1); });

    let bind = cfg.bind.clone();
    let state = Arc::new(State {
        cfg, sessions: Sessions::new(token), throttle: Throttle::new(), tls,
        inflight: AtomicUsize::new(0),
        install: Arc::new(Mutex::new(installer::InstallJob::default())),
    });

    let listener = TcpListener::bind(&bind)
        .unwrap_or_else(|e| { eprintln!("bbconsole: cannot bind {bind}: {e}"); std::process::exit(1); });
    eprintln!("bbconsole: HTTPS on https://{bind} (self-signed cert; PAM login required)");

    for conn in listener.incoming() {
        let Ok(stream) = conn else { continue };
        if state.inflight.load(Ordering::Relaxed) >= MAX_CONNS {
            drop(stream); // client can retry
            continue;
        }
        state.inflight.fetch_add(1, Ordering::Relaxed);
        let st = Arc::clone(&state);
        // the guard gives the slot back even if the handler panics
        std::thread::spawn(move || {
            struct Guard<'a>(&'a AtomicUsize);
            impl Drop for Guard<'_> {
                fn drop(&mut self) { self.0.fetch_sub(1, Ordering::Relaxed); }
            }
            let _g = Guard(&st.inflight);
            handle(st.clone(), stream);
        });
    }
}

/// Make a self-signed cert with openssl on first start. Drop a real one at the
/// same paths to replace it.
fn ensure_cert(cert: &Path, key: &Path) {
    if cert.exists() && key.exists() {
        return;
    }
    if let Some(dir) = cert.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let host = std::fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "blueberry".into());
    // put every IP in the SAN too, so browsing by IP doesn't add a name
    // mismatch on top of the self-signed warning
    let san = build_san(&host);
    let ok = Command::new("openssl")
        .args([
            "req", "-x509", "-newkey", "rsa:4096", "-sha256", "-nodes", "-days", "3650",
            "-keyout", &key.to_string_lossy(),
            "-out", &cert.to_string_lossy(),
            "-subj", &format!("/O=Blueberry Linux/OU=Console/CN={host}"),
            "-addext", &format!("subjectAltName={san}"),
            "-addext", "basicConstraints=critical,CA:false",
            "-addext", "keyUsage=critical,digitalSignature,keyEncipherment",
            "-addext", "extendedKeyUsage=serverAuth",
        ])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if ok {
        let _ = std::fs::set_permissions(key, std::os::unix::fs::PermissionsExt::from_mode(0o600));
        eprintln!("bbconsole: generated a self-signed TLS cert at {}", cert.display());
    } else {
        eprintln!("bbconsole: WARNING could not generate a cert (is openssl installed?)");
    }
}

/// subjectAltName: localhost, the hostname, loopback and every global address.
fn build_san(host: &str) -> String {
    let mut dns = vec!["localhost".to_string()];
    if !host.is_empty() && host != "localhost" {
        dns.push(host.to_string());
    }
    let mut ips = vec!["127.0.0.1".to_string(), "::1".to_string()];
    if let Ok(out) = Command::new("ip").args(["-o", "addr", "show", "scope", "global"]).output() {
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            // "2: eth0    inet 192.168.0.5/24 ..."
            let mut it = line.split_whitespace();
            while let Some(tok) = it.next() {
                if tok == "inet" || tok == "inet6" {
                    if let Some(addr) = it.next().and_then(|a| a.split('/').next()) {
                        let a = addr.to_string();
                        if !ips.contains(&a) { ips.push(a); }
                    }
                }
            }
        }
    }
    let mut parts: Vec<String> = dns.iter().map(|d| format!("DNS:{d}")).collect();
    parts.extend(ips.iter().map(|i| format!("IP:{i}")));
    parts.join(",")
}

fn load_tls(cert: &Path, key: &Path) -> Option<Arc<ServerConfig>> {
    let certs: Vec<_> = rustls_pemfile::certs(&mut BufReader::new(std::fs::File::open(cert).ok()?))
        .filter_map(Result::ok)
        .collect();
    let key = rustls_pemfile::private_key(&mut BufReader::new(std::fs::File::open(key).ok()?))
        .ok()??;
    let cfg = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .ok()?;
    Some(Arc::new(cfg))
}

fn handle(st: Arc<State>, tcp: TcpStream) {
    let peer = tcp.peer_addr().map(|a| a.ip().to_string()).unwrap_or_default();
    let _ = tcp.set_read_timeout(Some(IO_TIMEOUT));
    let _ = tcp.set_write_timeout(Some(IO_TIMEOUT));
    // plain HTTP clients just fail the handshake
    let Ok(conn) = ServerConnection::new(Arc::clone(&st.tls)) else { return };
    let stream = StreamOwned::new(conn, tcp);
    serve(&st, stream, &peer);
}

fn serve<S: Read + Write>(st: &State, stream: S, peer: &str) {
    let mut reader = BufReader::new(stream);
    let Some(req) = http::read_request(&mut reader) else { return };
    let resp = route(st, &req, peer);
    let mut inner = reader.into_inner();
    resp.write(&mut inner);
}

/// Find the caller's session. The bool is true when it came from the Bearer
/// header.
///
/// Bearer is the main path: browsers never send it on their own, so CSRF can't
/// forge it and a cert-warning browser can't drop it (they do drop Secure
/// cookies). The `bbc_session` cookie is accepted too, but since it rides along
/// ambiently, writes made with it need the CSRF token as well.
fn authenticate(st: &State, req: &Request) -> Option<(auth::Session, bool)> {
    if let Some(h) = req.header("authorization") {
        if let Some(tok) = h.strip_prefix("Bearer ").or_else(|| h.strip_prefix("bearer ")) {
            if let Some(s) = st.sessions.check(tok.trim()) {
                return Some((s, true));
            }
        }
    }
    if let Some(c) = req.cookie("bbc_session") {
        if let Some(s) = st.sessions.check(&c) {
            return Some((s, false));
        }
    }
    None
}

fn audit(st: &State, ip: &str, line: &str) {
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(dir) = st.cfg.audit_path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    // 0600: it has IPs and usernames in it
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true).append(true).mode(0o600).open(&st.cfg.audit_path)
    {
        let _ = writeln!(f, "{} {} {}", now(), ip, line);
    }
}

fn now() -> String {
    // epoch seconds, good enough without pulling in a time crate
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs().to_string())
        .unwrap_or_default()
}

fn route(st: &State, req: &Request, peer: &str) -> Response {
    let path = req.path.as_str();

    if path == "/api/v1/login" && req.method == "POST" {
        if !st.throttle.allowed(peer) {
            audit(st, peer, "login THROTTLED");
            return Response::error(429, "too many attempts, try again later");
        }
        let body = req.json().unwrap_or(json!({}));
        let field = |k: &str| body.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
        // username means PAM, otherwise try the bootstrap token
        let issued = if !field("username").is_empty() {
            st.sessions.login_pam(&field("username"), &field("password"), &st.cfg.admin_group)
        } else {
            st.sessions.login_token(&field("token"))
        };
        match issued {
            Some(iss) => {
                st.throttle.clear(peer);
                audit(st, peer, &format!("login ok user={}", iss.user));
                // the client uses the bearer token from the body; the cookie
                // is just a same-site mirror (and needs CSRF for writes)
                return Response::json(200, json!({
                    "ok": true, "user": iss.user,
                    "session": iss.session, "csrf": iss.csrf, "expires_in": 3600,
                })).with_header(
                    "Set-Cookie",
                    &format!("bbc_session={}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=3600", iss.session),
                );
            }
            None => {
                st.throttle.record_fail(peer);
                audit(st, peer, "login FAILED");
                return Response::error(401, "invalid credentials");
            }
        }
    }
    if path == "/api/v1/logout" && req.method == "POST" {
        if let Some(h) = req.header("authorization").and_then(|h| h.strip_prefix("Bearer ").or_else(|| h.strip_prefix("bearer "))) {
            st.sessions.logout(h.trim());
        }
        if let Some(sid) = req.cookie("bbc_session") {
            st.sessions.logout(&sid);
        }
        return Response::json(200, json!({ "ok": true }))
            .with_header("Set-Cookie", "bbc_session=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0");
    }

    // everything under /api/v1/ needs a live session
    if let Some(rest) = path.strip_prefix("/api/v1/") {
        let Some((sess, via_header)) = authenticate(st, req) else {
            return Response::error(401, "unauthenticated");
        };
        // cookie-authed writes must echo the CSRF token. bearer can't be sent
        // ambiently, so it's exempt
        if !via_header && req.method != "GET" && req.method != "HEAD" {
            let ok = req.header("x-bbc-csrf").map(|h| auth::ct_eq(h, &sess.csrf)).unwrap_or(false);
            if !ok {
                audit(st, peer, &format!("CSRF reject {} {}", req.method, path));
                return Response::error(403, "missing or invalid CSRF token");
            }
        }
        return api_route(st, req, rest, peer, &sess);
    }

    if req.method == "GET" {
        return serve_static(&st.cfg.web_root, path);
    }
    Response::error(404, "not found")
}

fn api_route(st: &State, req: &Request, rest: &str, peer: &str, sess: &auth::Session) -> Response {
    match (req.method.as_str(), rest) {
        // the client checks its token with this and re-learns the CSRF token
        // after a reload
        ("GET", "whoami") => Response::json(200, json!({
            "user": sess.user, "csrf": sess.csrf, "sessions": st.sessions.active(),
        })),
        ("GET", "system") => Response::json(200, api::system()),
        ("GET", "metrics") => Response::json(200, api::metrics()),
        ("GET", "services") => Response::json(200, api::services()),
        ("GET", "packages") => Response::json(200, api::packages()),
        ("GET", "storage") => Response::json(200, api::storage()),
        ("GET", "network") => Response::json(200, api::network()),
        ("GET", "zfs") => Response::json(200, api::zfs()),

        // zfs/{scrub,snapshot}?pool|dataset=<n>&name=<snap>
        ("POST", r) if r.starts_with("zfs/") => {
            let action = &r["zfs/".len()..];
            let target = query_param(&req.query, "pool")
                .or_else(|| query_param(&req.query, "dataset"))
                .unwrap_or_default();
            let snap = query_param(&req.query, "name");
            audit(st, peer, &format!("zfs {action} {target}"));
            match api::zfs_action(action, &target, snap.as_deref()) {
                Ok(v) => Response::json(200, v),
                Err(e) => Response::error(400, &e),
            }
        }

        ("GET", "btrfs") => Response::json(200, api::btrfs()),

        // btrfs/{scrub,snapshot,subvol-create}?mount=<mp>&name=<n>
        // btrfs/{subvol-delete,rollback}?mount=<mp>&path=<subvol>
        ("POST", r) if r.starts_with("btrfs/") => {
            let action = &r["btrfs/".len()..];
            let mount = query_param(&req.query, "mount").unwrap_or_default();
            let name = query_param(&req.query, "name");
            let path = query_param(&req.query, "path");
            audit(st, peer, &format!("btrfs {action} {mount} {}", path.as_deref().unwrap_or("")));
            match api::btrfs_action(action, &mount, name.as_deref(), path.as_deref()) {
                Ok(v) => Response::json(200, v),
                Err(e) => Response::error(400, &e),
            }
        }

        ("GET", "updates") => Response::json(200, api::updates()),
        ("POST", "updates/apply") => {
            let snap = query_param(&req.query, "snapshot").as_deref() == Some("1");
            audit(st, peer, &format!("updates apply snapshot={snap}"));
            match api::updates_apply(snap) {
                Ok(v) => Response::json(200, v),
                Err(e) => Response::error(400, &e),
            }
        }

        // installer: live media only, this one wipes a disk
        ("GET", "installer") => Response::json(200, installer::info()),
        ("GET", "installer/status") => Response::json(200, st.install.lock().unwrap().snapshot()),
        ("POST", "installer/start") => {
            let body = req.json().unwrap_or(json!({}));
            match installer::build_env(&body) {
                Ok(env) => {
                    let target = env.iter().find(|(k, _)| k == "BLUEBERRY_TARGET").map(|(_, v)| v.clone()).unwrap_or_default();
                    audit(st, peer, &format!("INSTALL start target={target}"));
                    match installer::start(Arc::clone(&st.install), env) {
                        Ok(()) => Response::json(200, json!({ "ok": true, "started": true })),
                        Err(e) => Response::error(409, &e),
                    }
                }
                Err(e) => Response::error(400, &e),
            }
        }

        // logs?lines=<1..500>&priority=<0..7>&unit=<name>
        ("GET", "logs") => {
            let lines = query_param(&req.query, "lines").and_then(|s| s.parse().ok()).unwrap_or(150);
            let priority = query_param(&req.query, "priority").and_then(|s| s.parse().ok());
            let unit = query_param(&req.query, "unit");
            let unit_ref = unit.as_deref().filter(|u| valid_unit(u));
            Response::json(200, api::logs(lines, priority, unit_ref))
        }

        // services/<action>?unit=<name>
        ("POST", r) if r.starts_with("services/") => {
            let action = &r["services/".len()..];
            let unit = query_param(&req.query, "unit").unwrap_or_default();
            audit(st, peer, &format!("service {action} {unit}"));
            match api::service_action(action, &unit) {
                Ok(v) => Response::json(200, v),
                Err(e) => Response::error(400, &e),
            }
        }

        ("GET", "containers") => Response::json(200, api::containers()),
        ("GET", "containers/logs") => {
            let name = query_param(&req.query, "name").unwrap_or_default();
            let lines = query_param(&req.query, "lines").and_then(|s| s.parse().ok()).unwrap_or(200);
            match api::container_logs(&name, lines) {
                Ok(v) => Response::json(200, v),
                Err(e) => Response::error(400, &e),
            }
        }
        // containers/{start,stop,restart,remove}?name=<container>
        ("POST", r) if r.starts_with("containers/") => {
            let action = &r["containers/".len()..];
            let name = query_param(&req.query, "name").unwrap_or_default();
            audit(st, peer, &format!("container {action} {name}"));
            match api::container_action(action, &name) {
                Ok(v) => Response::json(200, v),
                Err(e) => Response::error(400, &e),
            }
        }

        _ => Response::error(404, "no such endpoint"),
    }
}

/// Filter for `logs?unit=` before it goes to journalctl. No leading '-', or it
/// turns into an option.
fn valid_unit(u: &str) -> bool {
    !u.is_empty()
        && !u.starts_with('-')
        && u.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.@".contains(&b))
}

fn query_param(query: &str, key: &str) -> Option<String> {
    for pair in query.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            if k == key {
                return Some(v.to_string());
            }
        }
    }
    None
}

fn serve_static(root: &Path, path: &str) -> Response {
    let rel = if path == "/" { "index.html" } else { path.trim_start_matches('/') };
    // no "..", no empty components (so no "//etc/passwd" either)
    if rel.split('/').any(|c| c == ".." || c.is_empty()) {
        return Response::error(400, "bad path");
    }
    let full = root.join(rel);
    match std::fs::read(&full) {
        Ok(bytes) => Response::bytes(200, content_type(rel), bytes),
        Err(_) => {
            // unknown path: hand back the app shell
            match std::fs::read(root.join("index.html")) {
                Ok(b) => Response::bytes(200, "text/html; charset=utf-8", b),
                Err(_) => Response::error(404, "not found"),
            }
        }
    }
}

fn content_type(name: &str) -> &'static str {
    match name.rsplit('.').next() {
        Some("html") => "text/html; charset=utf-8",
        Some("js") => "text/javascript; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("json") => "application/json",
        Some("svg") => "image/svg+xml",
        _ => "application/octet-stream",
    }
}
