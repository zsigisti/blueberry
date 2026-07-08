//! Authentication for the console. Two ways in, both ending in the same
//! short-lived in-memory session cookie:
//!
//!   1. PAM (primary, Proxmox-style) — a real system user authenticates with
//!      their password against /etc/shadow through the PAM stack, then must pass
//!      an authorization check (root, or a member of the admin group) to actually
//!      manage the box. Authentication ≠ authorization.
//!   2. Bootstrap token (fallback/automation) — on first start the daemon writes
//!      a random admin token to a root-only file; handy for headless setup before
//!      an admin account exists, or for scripts.
//!
//! Every API call re-checks the session (1h idle expiry).

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const SESSION_TTL: Duration = Duration::from_secs(60 * 60); // 1h idle

/// 32 random bytes as lowercase hex, sourced from the kernel CSPRNG.
pub fn random_hex() -> String {
    let mut buf = [0u8; 32];
    let mut f = fs::File::open("/dev/urandom").expect("open /dev/urandom");
    f.read_exact(&mut buf).expect("read /dev/urandom");
    let mut s = String::with_capacity(64);
    for b in buf {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// Constant-time-ish equality (length-independent short-circuit avoided).
pub fn ct_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for i in 0..a.len() {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

/// Load the admin token, creating a fresh one (0600) on first run.
pub fn load_or_create_token(path: &Path) -> std::io::Result<String> {
    if let Ok(s) = fs::read_to_string(path) {
        let t = s.trim().to_string();
        if !t.is_empty() {
            return Ok(t);
        }
    }
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let token = random_hex();
    fs::write(path, format!("{token}\n"))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    eprintln!("bbconsole: generated a new admin token at {}", path.display());
    Ok(token)
}

/// Authenticate a system user's password via PAM (service `blueberry-console`,
/// falling back to `login`). Returns true only if PAM accepts the credentials.
pub fn pam_authenticate(user: &str, pass: &str) -> bool {
    // Reject obviously bogus usernames before touching PAM.
    if user.is_empty() || !user.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b)) {
        return false;
    }
    for service in ["blueberry-console", "login"] {
        if let Ok(mut client) = pam::Client::with_password(service) {
            client.conversation_mut().set_credentials(user, pass);
            if client.authenticate().is_ok() {
                return true;
            }
        }
    }
    false
}

/// Authorization: only root or members of the admin group may manage the box.
/// (PAM says "valid user + password"; this says "allowed to be here".)
pub fn is_admin(user: &str, admin_group: &str) -> bool {
    if user == "root" {
        return true;
    }
    // Membership via /etc/group: "<group>:x:<gid>:<members,comma>".
    if let Ok(groups) = fs::read_to_string("/etc/group") {
        for line in groups.lines() {
            let mut f = line.split(':');
            if f.next() == Some(admin_group) {
                if let Some(members) = f.nth(2) {
                    return members.split(',').any(|m| m == user);
                }
            }
        }
    }
    false
}

/// Per-source-IP failed-login throttle — slows password brute force.
pub struct Throttle {
    fails: Mutex<HashMap<String, (u32, Instant)>>,
}

const MAX_FAILS: u32 = 8;
const FAIL_WINDOW: Duration = Duration::from_secs(300); // 5 min lockout window

impl Throttle {
    pub fn new() -> Throttle {
        Throttle { fails: Mutex::new(HashMap::new()) }
    }

    /// True if `ip` is allowed another attempt right now.
    pub fn allowed(&self, ip: &str) -> bool {
        let mut m = self.fails.lock().unwrap();
        m.retain(|_, (_, t)| t.elapsed() < FAIL_WINDOW);
        m.get(ip).map(|(n, _)| *n < MAX_FAILS).unwrap_or(true)
    }

    pub fn record_fail(&self, ip: &str) {
        let mut m = self.fails.lock().unwrap();
        let e = m.entry(ip.to_string()).or_insert((0, Instant::now()));
        e.0 += 1;
        e.1 = Instant::now();
    }

    pub fn clear(&self, ip: &str) {
        self.fails.lock().unwrap().remove(ip);
    }
}

const ABSOLUTE_TTL: Duration = Duration::from_secs(8 * 60 * 60); // 8h hard cap

pub struct Sessions {
    admin_token: String,
    live: Mutex<HashMap<String, Session>>, // session id -> session
}

#[derive(Clone)]
pub struct Session {
    pub user: String,
    pub csrf: String,     // paired anti-CSRF token (for cookie-authed writes)
    pub created: Instant, // for the absolute-lifetime cap
    pub seen: Instant,    // for the idle timeout
}

/// What a successful login hands back: an opaque bearer session token, its paired
/// CSRF token, and the resolved username. The bearer token is the primary
/// credential — the client sends it as `Authorization: Bearer <session>`, which
/// (unlike a cookie) is never attached ambiently, so it can't be dropped by a
/// cert-error browser and isn't reachable by CSRF.
pub struct Issued {
    pub session: String,
    pub csrf: String,
    pub user: String,
}

impl Sessions {
    pub fn new(admin_token: String) -> Sessions {
        Sessions { admin_token, live: Mutex::new(HashMap::new()) }
    }

    fn start(&self, user: &str) -> Issued {
        let sid = random_hex();
        let csrf = random_hex();
        let now = Instant::now();
        self.live.lock().unwrap().insert(
            sid.clone(),
            Session { user: user.to_string(), csrf: csrf.clone(), created: now, seen: now },
        );
        Issued { session: sid, csrf, user: user.to_string() }
    }

    /// PAM login: authenticate the password, then authorize the user.
    pub fn login_pam(&self, user: &str, pass: &str, admin_group: &str) -> Option<Issued> {
        if pam_authenticate(user, pass) && is_admin(user, admin_group) {
            Some(self.start(user))
        } else {
            None
        }
    }

    /// Bootstrap-token login (automation / first run). An empty configured token
    /// never matches (fail closed).
    pub fn login_token(&self, token: &str) -> Option<Issued> {
        if !self.admin_token.is_empty() && !token.is_empty() && ct_eq(token, &self.admin_token) {
            Some(self.start("token"))
        } else {
            None
        }
    }

    /// A live session — idle under SESSION_TTL *and* total age under ABSOLUTE_TTL.
    /// Refreshes the idle timestamp and returns a snapshot (incl. its CSRF token).
    pub fn check(&self, sid: &str) -> Option<Session> {
        if sid.is_empty() {
            return None;
        }
        let mut live = self.live.lock().unwrap();
        live.retain(|_, s| s.seen.elapsed() < SESSION_TTL && s.created.elapsed() < ABSOLUTE_TTL);
        if let Some(s) = live.get_mut(sid) {
            s.seen = Instant::now();
            Some(s.clone())
        } else {
            None
        }
    }

    pub fn logout(&self, sid: &str) {
        self.live.lock().unwrap().remove(sid);
    }

    /// Revoke every session belonging to a user (e.g. after a password change).
    #[allow(dead_code)]
    pub fn revoke_user(&self, user: &str) {
        self.live.lock().unwrap().retain(|_, s| s.user != user);
    }

    /// Number of live sessions (after pruning) — for a future sessions panel.
    #[allow(dead_code)]
    pub fn active(&self) -> usize {
        let mut live = self.live.lock().unwrap();
        live.retain(|_, s| s.seen.elapsed() < SESSION_TTL && s.created.elapsed() < ABSOLUTE_TTL);
        live.len()
    }
}
