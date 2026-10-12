//! Console login. Two ways in, both ending in an in-memory session:
//!
//! - PAM: a real system user and password. Passing PAM only proves who you are;
//!   you also have to be root or in the admin group to get a session.
//! - Bootstrap token: written to a root-only file on first start. For headless
//!   setup before there's an admin account, and for scripts.
//!
//! Sessions expire after 1h idle or 8h total.

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const SESSION_TTL: Duration = Duration::from_secs(60 * 60); // 1h idle

/// 32 random bytes from /dev/urandom, as hex.
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

/// Constant-time compare for equal lengths. Lengths themselves aren't secret.
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

/// Read the bootstrap token, or make a new 0600 one on first run.
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

/// Check a password through PAM. Tries the `blueberry-console` service, then
/// falls back to `login`.
pub fn pam_authenticate(user: &str, pass: &str) -> bool {
    // don't hand PAM anything weird
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

/// Root or a member of the admin group. PAM says "right password", this says
/// "allowed in".
pub fn is_admin(user: &str, admin_group: &str) -> bool {
    if user == "root" {
        return true;
    }
    // "<group>:x:<gid>:<a,b,c>"
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

/// Failed-login counter per source IP, to slow down password guessing.
pub struct Throttle {
    fails: Mutex<HashMap<String, (u32, Instant)>>,
}

const MAX_FAILS: u32 = 8;
const FAIL_WINDOW: Duration = Duration::from_secs(300);

impl Throttle {
    pub fn new() -> Throttle {
        Throttle { fails: Mutex::new(HashMap::new()) }
    }

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
    pub csrf: String,     // needed for writes made with the cookie
    pub created: Instant, // for the 8h cap
    pub seen: Instant,    // for the idle timeout
}

/// What a login hands back. The client sends `session` as a Bearer header.
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

    pub fn login_pam(&self, user: &str, pass: &str, admin_group: &str) -> Option<Issued> {
        if pam_authenticate(user, pass) && is_admin(user, admin_group) {
            Some(self.start(user))
        } else {
            None
        }
    }

    /// An empty token never matches, on either side.
    pub fn login_token(&self, token: &str) -> Option<Issued> {
        if !self.admin_token.is_empty() && !token.is_empty() && ct_eq(token, &self.admin_token) {
            Some(self.start("token"))
        } else {
            None
        }
    }

    /// Look up a live session and bump its idle timer. Prunes expired ones on
    /// the way.
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

    /// Kick all of a user's sessions, e.g. after a password change.
    #[allow(dead_code)]
    pub fn revoke_user(&self, user: &str) {
        self.live.lock().unwrap().retain(|_, s| s.user != user);
    }

    #[allow(dead_code)]
    pub fn active(&self) -> usize {
        let mut live = self.live.lock().unwrap();
        live.retain(|_, s| s.seen.elapsed() < SESSION_TTL && s.created.elapsed() < ABSOLUTE_TTL);
        live.len()
    }
}
