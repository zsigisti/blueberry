//! bbconsole — the Blueberry management console daemon (base layer).
//!
//! A small, privileged HTTP API + static-file server for a first-party web UI to
//! manage a Blueberry box. This is the FOUNDATION, deliberately scoped: it wraps
//! tools that already exist (systemctl, bpm, /proc) behind a versioned, audited,
//! authenticated API, and serves a single-page frontend. The far vision —
//! containers, logs, updates with btrfs snapshot/rollback, storage, network —
//! extends the /api/v1 surface without reworking this core.
//!
//! Security posture (see doc/WEBUI.md):
//!   * binds 127.0.0.1 by default — TLS + exposure are a reverse proxy's job.
//!   * token→session auth; every API call is re-checked.
//!   * write actions are few, argument-validated, and appended to an audit log.
//!   * pure-std HTTP, hard request-size limits, one request per connection.

mod api;
mod auth;
mod http;

use auth::{Sessions, Throttle};
use http::{Request, Response};
use serde_json::json;
use std::io::{BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// Per-socket I/O timeout — bounds the TLS handshake, the request read, and the
/// response write, so a slow/idle client can't pin a worker thread (slow-loris).
const IO_TIMEOUT: Duration = Duration::from_secs(20);
/// Max concurrent connections; excess are dropped so a flood can't spawn
/// unbounded threads. Generous for a single-admin console.
const MAX_CONNS: usize = 128;

use rustls::{ServerConfig, ServerConnection, StreamOwned};

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
        // Env overrides keep the base layer configurable without a parser.
        Config {
            bind: env("BBCONSOLE_BIND", "0.0.0.0:9090"),
            web_root: PathBuf::from(env("BBCONSOLE_WEB", "/usr/share/blueberry-console/web")),
            token_path: PathBuf::from(env("BBCONSOLE_TOKEN", "/etc/blueberry/console/token")),
            audit_path: PathBuf::from(env("BBCONSOLE_AUDIT", "/var/log/blueberry-console/audit.log")),
            // Only root + members of this group may log in via PAM.
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
}

fn main() {
    // Install the ring crypto provider once for the whole process.
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
    });

    let listener = TcpListener::bind(&bind)
        .unwrap_or_else(|e| { eprintln!("bbconsole: cannot bind {bind}: {e}"); std::process::exit(1); });
    eprintln!("bbconsole: HTTPS on https://{bind} (self-signed cert; PAM login required)");

    for conn in listener.incoming() {
        let Ok(stream) = conn else { continue };
        // Shed load past the cap so a connection flood can't exhaust threads/RAM.
        if state.inflight.load(Ordering::Relaxed) >= MAX_CONNS {
            drop(stream); // RST/close; the client can retry
            continue;
        }
        state.inflight.fetch_add(1, Ordering::Relaxed);
        let st = Arc::clone(&state);
        // Thread per connection: simple and isolated. The counter is released
        // when the handler returns (even on panic) via the guard below.
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

/// Generate a self-signed cert+key (via openssl) if none exists, so HTTPS works
/// out of the box. Drop in a real cert at the same paths to replace it.
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
    // Build a SAN list that matches how the box is actually reached: localhost,
    // the hostname, and every global IP the machine holds — so browsing by IP
    // doesn't hit a name-mismatch on top of the self-signed warning.
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

/// Assemble an openssl subjectAltName value: localhost + 127.0.0.1 + the
/// hostname + every global IPv4/IPv6 address on the box (via `ip -o addr`).
fn build_san(host: &str) -> String {
    let mut dns = vec!["localhost".to_string()];
    if !host.is_empty() && host != "localhost" {
        dns.push(host.to_string());
    }
    let mut ips = vec!["127.0.0.1".to_string(), "::1".to_string()];
    if let Ok(out) = Command::new("ip").args(["-o", "addr", "show", "scope", "global"]).output() {
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            // "N: iface    inet 192.168.0.5/24 ..."  → take the addr before '/'
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
    // Bound every blocking I/O op (handshake, request read, response write) so a
    // slow or idle client releases the thread instead of pinning it forever.
    let _ = tcp.set_read_timeout(Some(IO_TIMEOUT));
    let _ = tcp.set_write_timeout(Some(IO_TIMEOUT));
    // Wrap the connection in TLS; a client speaking plain HTTP just fails here.
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

/// Resolve the caller's session. Two accepted credentials, in priority order:
///   1. `Authorization: Bearer <session>` — the primary path. Explicit, never
///      sent ambiently, so a cert-error browser can't drop it and CSRF can't
///      forge it. Returns `via_header = true`.
///   2. `bbc_session` cookie — convenience for same-site navigation. Ambient, so
///      state-changing requests using it must also present a matching CSRF token.
/// Returns the live session plus whether it came from the Bearer header.
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
    // 0600 on creation — the log holds source IPs and usernames.
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true).append(true).mode(0o600).open(&st.cfg.audit_path)
    {
        let _ = writeln!(f, "{} {} {}", now(), ip, line);
    }
}

fn now() -> String {
    // Seconds since epoch — enough for an audit timeline without a time crate.
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs().to_string())
        .unwrap_or_default()
}

fn route(st: &State, req: &Request, peer: &str) -> Response {
    let path = req.path.as_str();

    // ── auth endpoints ────────────────────────────────────────────────────────
    if path == "/api/v1/login" && req.method == "POST" {
        // Brute-force throttle: too many failures from this IP → back off.
        if !st.throttle.allowed(peer) {
            audit(st, peer, "login THROTTLED");
            return Response::error(429, "too many attempts, try again later");
        }
        let body = req.json().unwrap_or(json!({}));
        let field = |k: &str| body.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
        // PAM (username+password) is the primary path; token is the fallback.
        let issued = if !field("username").is_empty() {
            st.sessions.login_pam(&field("username"), &field("password"), &st.cfg.admin_group)
        } else {
            st.sessions.login_token(&field("token"))
        };
        match issued {
            Some(iss) => {
                st.throttle.clear(peer);
                audit(st, peer, &format!("login ok user={}", iss.user));
                // Body carries the bearer token + CSRF token (primary path). The
                // cookie is a same-site convenience mirror; writes made via the
                // cookie must echo the CSRF token.
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

    // ── API (all require a live session) ──────────────────────────────────────
    if let Some(rest) = path.strip_prefix("/api/v1/") {
        let Some((sess, via_header)) = authenticate(st, req) else {
            return Response::error(401, "unauthenticated");
        };
        // CSRF: a cookie-authed unsafe method must echo the session's CSRF token.
        // Bearer-authed requests are exempt (the header can't be sent ambiently).
        if !via_header && req.method != "GET" && req.method != "HEAD" {
            let ok = req.header("x-bbc-csrf").map(|h| auth::ct_eq(h, &sess.csrf)).unwrap_or(false);
            if !ok {
                audit(st, peer, &format!("CSRF reject {} {}", req.method, path));
                return Response::error(403, "missing or invalid CSRF token");
            }
        }
        return api_route(st, req, rest, peer, &sess);
    }

    // ── static frontend ───────────────────────────────────────────────────────
    if req.method == "GET" {
        return serve_static(&st.cfg.web_root, path);
    }
    Response::error(404, "not found")
}

fn api_route(st: &State, req: &Request, rest: &str, peer: &str, sess: &auth::Session) -> Response {
    match (req.method.as_str(), rest) {
        // Identity/session probe — the client uses this to confirm its token is
        // live and to (re)learn its CSRF token after a reload.
        ("GET", "whoami") => Response::json(200, json!({
            "user": sess.user, "csrf": sess.csrf, "sessions": st.sessions.active(),
        })),
        ("GET", "system") => Response::json(200, api::system()),
        ("GET", "services") => Response::json(200, api::services()),
        ("GET", "packages") => Response::json(200, api::packages()),

        // Write action: /api/v1/services/<action>?unit=<name>
        ("POST", r) if r.starts_with("services/") => {
            let action = &r["services/".len()..];
            let unit = query_param(&req.query, "unit").unwrap_or_default();
            audit(st, peer, &format!("service {action} {unit}"));
            match api::service_action(action, &unit) {
                Ok(v) => Response::json(200, v),
                Err(e) => Response::error(400, &e),
            }
        }

        // Far-vision stubs — stable shape, not built yet.
        ("GET", "containers") => Response::json(501, api::not_implemented("containers")),
        ("GET", "logs") => Response::json(501, api::not_implemented("logs")),
        ("GET", "updates") => Response::json(501, api::not_implemented("updates")),
        ("GET", "storage") => Response::json(501, api::not_implemented("storage")),
        ("GET", "network") => Response::json(501, api::not_implemented("network")),

        _ => Response::error(404, "no such endpoint"),
    }
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
    // Path-traversal guard: no "..", no absolute escapes.
    if rel.split('/').any(|c| c == ".." || c.is_empty()) {
        return Response::error(400, "bad path");
    }
    let full = root.join(rel);
    match std::fs::read(&full) {
        Ok(bytes) => Response::bytes(200, content_type(rel), bytes),
        Err(_) => {
            // SPA fallback: unknown non-asset paths return the shell.
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
