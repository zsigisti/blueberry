// Blueberry Console — base-layer frontend. Vanilla JS, no build step, no inline
// script (CSP-friendly). Panels are data-driven so far-vision areas (containers,
// logs, updates/rollback, storage, network) drop in by adding an entry to PANELS.

// Auth is a bearer token in sessionStorage (see doc/WEBUI.md security model):
// sent explicitly, so it survives self-signed-cert browsers that drop Secure
// cookies, and is immune to CSRF.
const TOK = "bbc_session";
const tok = () => sessionStorage.getItem(TOK) || "";
const setTok = (t) => { if (t) sessionStorage.setItem(TOK, t); else sessionStorage.removeItem(TOK); };

const api = async (path, opts = {}) => {
  const headers = Object.assign({ "Authorization": "Bearer " + tok() }, opts.headers || {});
  const r = await fetch("/api/v1/" + path, Object.assign({ credentials: "omit" }, opts, { headers }));
  if (r.status === 401) { setTok(""); showLogin(); throw new Error("unauthenticated"); }
  return r;
};
const getJSON = async (path) => (await api(path)).json();
const el = (tag, attrs = {}, ...kids) => {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") n.className = v; else if (k === "text") n.textContent = v; else n.setAttribute(k, v);
  }
  for (const k of kids) n.append(k);
  return n;
};

// ── panels (extend here for the far vision) ───────────────────────────────────
const PANELS = [
  { id: "overview", label: "Overview", render: overview },
  { id: "services", label: "Services", render: services },
  { id: "packages", label: "Packages", render: packages },
  { id: "containers", label: "Containers", render: stub("containers") },
  { id: "updates", label: "Updates", render: stub("updates") },
  { id: "logs", label: "Logs", render: stub("logs") },
  { id: "storage", label: "Storage", render: stub("storage") },
  { id: "network", label: "Network", render: stub("network") },
];

function stub(area) {
  return async (view) => {
    view.append(el("div", { class: "card muted" },
      el("h2", { text: area[0].toUpperCase() + area.slice(1) }),
      el("p", { text: "Planned — this panel is part of the console's roadmap and not built yet." })));
  };
}

const fmtUptime = (s) => {
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return [d && d + "d", h && h + "h", m + "m"].filter(Boolean).join(" ");
};

async function overview(view) {
  const s = await getJSON("system");
  document.getElementById("hostname").textContent = s.hostname;
  const memUsed = s.memory.total_kb - s.memory.available_kb;
  const memPct = s.memory.total_kb ? Math.round((memUsed / s.memory.total_kb) * 100) : 0;
  const stat = (label, value) => el("div", { class: "stat" }, el("div", { class: "k", text: label }), el("div", { class: "v", text: value }));
  view.append(el("div", { class: "grid" },
    stat("OS", s.os || "Blueberry Linux"),
    stat("Kernel", s.kernel),
    stat("Uptime", fmtUptime(s.uptime_seconds)),
    stat("Load (1m)", (s.load[0] ?? 0).toFixed(2)),
    stat("Memory", `${memPct}% of ${(s.memory.total_kb / 1048576).toFixed(1)} GiB`),
  ));
}

async function services(view) {
  const { services } = await getJSON("services");
  const act = async (unit, action) => {
    await api("services/" + action + "?unit=" + encodeURIComponent(unit), { method: "POST" });
    render("services");
  };
  const rows = services.map((s) => {
    const running = s.active === "active";
    const btn = (label, action) => { const b = el("button", { class: "ghost sm", text: label }); b.addEventListener("click", () => act(s.unit, action)); return b; };
    return el("tr", {},
      el("td", {}, el("span", { class: "dot " + (running ? "ok" : "off") }), document.createTextNode(" " + s.unit)),
      el("td", { class: "muted", text: s.sub }),
      el("td", { text: s.description }),
      el("td", {}, running ? btn("Stop", "stop") : btn("Start", "start"), btn("Restart", "restart")));
  });
  const table = el("table", { class: "list" }, el("thead", {}, el("tr", {}, el("th", { text: "Unit" }), el("th", { text: "State" }), el("th", { text: "Description" }), el("th", { text: "" }))), el("tbody", {}, ...rows));
  view.append(el("div", { class: "card" }, el("h2", { text: `Services (${services.length})` }), table));
}

async function packages(view) {
  const { packages } = await getJSON("packages");
  const rows = packages.map((p) => el("tr", {}, el("td", { text: p.name }), el("td", { class: "muted", text: p.version })));
  view.append(el("div", { class: "card" },
    el("h2", { text: `Packages (${packages.length})` }),
    el("table", { class: "list" }, el("tbody", {}, ...rows))));
}

// ── shell / routing ───────────────────────────────────────────────────────────
function buildNav() {
  const nav = document.getElementById("nav");
  nav.replaceChildren();
  for (const p of PANELS) {
    const a = el("button", { class: "tab", text: p.label });
    a.dataset.id = p.id;
    a.addEventListener("click", () => render(p.id));
    nav.append(a);
  }
}

async function render(id) {
  const panel = PANELS.find((p) => p.id === id) || PANELS[0];
  document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("active", t.dataset.id === panel.id));
  const view = document.getElementById("view");
  view.replaceChildren(el("div", { class: "muted", text: "Loading…" }));
  try { view.replaceChildren(); await panel.render(view); }
  catch (e) { view.replaceChildren(el("div", { class: "card error", text: String(e.message || e) })); }
}

function showApp() {
  document.getElementById("login").hidden = true;
  document.getElementById("app").hidden = false;
  buildNav();
  render("overview");
}
function showLogin() {
  document.getElementById("app").hidden = true;
  document.getElementById("login").hidden = false;
}

document.getElementById("login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const err = document.getElementById("login-error");
  err.hidden = true;
  let r;
  try {
    r = await fetch("/api/v1/login", {
      method: "POST", credentials: "omit",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        username: document.getElementById("username").value,
        password: document.getElementById("password").value,
      }),
    });
  } catch (netErr) {
    err.textContent = "Network error: " + ((netErr && netErr.message) || netErr); err.hidden = false; return;
  }
  let data = {};
  try { data = await r.json(); } catch (_) {}
  if (r.ok && data.session) { setTok(data.session); showApp(); }
  else {
    err.textContent = r.status === 429
      ? "Too many attempts — try again shortly."
      : "Invalid credentials, or account not permitted. (HTTP " + r.status + ")";
    err.hidden = false;
  }
});

document.getElementById("logout").addEventListener("click", async () => {
  try { await api("logout", { method: "POST" }); } catch (_) {}
  setTok(); showLogin();
});

// Probe an existing session on load (only if we hold a token).
(async () => {
  if (!tok()) return showLogin();
  try {
    const r = await fetch("/api/v1/system", { headers: { "Authorization": "Bearer " + tok() } });
    if (r.ok) showApp(); else { setTok(""); showLogin(); }
  } catch (_) { showLogin(); }
})();
