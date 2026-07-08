// Pure-JS client for the Blueberry Console — no framework, no styling.
//
// Auth is a BEARER TOKEN held in sessionStorage and sent as
// `Authorization: Bearer <token>` on every call. Unlike a Secure cookie, it is
// never attached ambiently, so it survives browsers that drop Secure cookies on
// a self-signed/untrusted cert — and it can't be forged by CSRF. Every failure
// path prints the HTTP status, so "nothing happens" can't happen.

const $ = (id) => document.getElementById(id);
const KEY = "bbc_session";
const tok = () => sessionStorage.getItem(KEY) || "";
const setTok = (t) => { if (t) sessionStorage.setItem(KEY, t); else sessionStorage.removeItem(KEY); };

// Authenticated fetch: attaches the bearer token, never sends cookies.
async function api(path, opts = {}) {
  const headers = Object.assign({ "Authorization": "Bearer " + tok() }, opts.headers || {});
  return fetch("/api/v1/" + path, Object.assign({ credentials: "omit" }, opts, { headers }));
}

function showLogin(msg) {
  $("app").hidden = true;
  $("login").hidden = false;
  $("status").textContent = msg || "";
}

async function showApp() {
  $("login").hidden = true;
  $("app").hidden = false;
  try {
    const who = await (await api("whoami")).json();
    $("who").textContent = who.user;
    $("debug").textContent = JSON.stringify(who, null, 2);
    const sys = await api("system");
    $("system").textContent = sys.ok
      ? JSON.stringify(await sys.json(), null, 2)
      : "system: HTTP " + sys.status;
  } catch (e) {
    $("system").textContent = "error: " + ((e && e.message) || e);
  }
}

$("login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("status").textContent = "signing in…";
  const t = $("token").value.trim();
  const payload = t
    ? { token: t }
    : { username: $("username").value, password: $("password").value };
  let r;
  try {
    r = await fetch("/api/v1/login", {
      method: "POST",
      credentials: "omit",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch (err) {
    $("status").textContent = "network error: " + ((err && err.message) || err);
    return;
  }
  let data = {};
  try { data = await r.json(); } catch (_) {}
  if (r.ok && data.session) {
    setTok(data.session);
    showApp();
  } else {
    $("status").textContent =
      "login failed — HTTP " + r.status + (data.error ? " (" + data.error + ")" : "");
  }
});

$("logout").addEventListener("click", async () => {
  try { await api("logout", { method: "POST" }); } catch (_) {}
  setTok("");
  showLogin("signed out");
});

// On load: resume if we already hold a token, else show the login form.
(async () => {
  if (!tok()) return showLogin();
  try {
    const r = await api("whoami");
    if (r.ok) showApp(); else { setTok(""); showLogin(); }
  } catch (_) { showLogin(); }
})();
