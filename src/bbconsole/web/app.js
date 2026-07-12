// Blueberry Console — pure HTML/JS client. No CSS, no framework, no build step.
//
// Auth is a bearer token in sessionStorage, sent as `Authorization: Bearer <t>`
// on every call — it survives self-signed-cert browsers that drop Secure cookies
// and is immune to CSRF. Panels are data-driven: add a { id, label, render } to
// PANELS to grow the far vision.

const KEY = "bbc_session";
const tok = () => sessionStorage.getItem(KEY) || "";
const setTok = (t) => { if (t) sessionStorage.setItem(KEY, t); else sessionStorage.removeItem(KEY); };

const api = async (path, opts = {}) => {
  const headers = Object.assign({ "Authorization": "Bearer " + tok() }, opts.headers || {});
  const r = await fetch("/api/v1/" + path, Object.assign({ credentials: "omit" }, opts, { headers }));
  if (r.status === 401) { setTok(""); showLogin(); throw new Error("session expired"); }
  return r;
};
const getJSON = async (path) => (await api(path)).json();

// Tiny DOM helper.
const el = (tag, attrs = {}, ...kids) => {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "text") n.textContent = v; else n.setAttribute(k, v);
  }
  for (const k of kids) n.append(k);
  return n;
};
// A plain bordered table (border attribute = readable without any CSS).
const table = (headers, rows) =>
  el("table", { border: "1", cellpadding: "5", cellspacing: "0" },
    el("thead", {}, el("tr", {}, ...headers.map((h) => el("th", { align: "left", text: h })))),
    el("tbody", {}, ...rows));

let liveTimer = null; // overview's metrics poller; cleared on navigation/logout

// ── formatting ────────────────────────────────────────────────────────────────
const fmtUptime = (s) => {
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return [d && d + "d", h && h + "h", m + "m"].filter(Boolean).join(" ");
};
const fmtBytes = (n) => {
  n = Number(n) || 0; const u = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]; let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return n.toFixed(i ? 1 : 0) + " " + u[i];
};
const fmtTime = (e) => (e ? new Date(e * 1000).toLocaleString() : "—");
const PRIO = ["emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"];
const prioLabel = (p) => PRIO[p] || "info";

// ── panels ──────────────────────────────────────────────────────────────────────
const PANELS = [
  { id: "overview", label: "Overview", render: overview },
  { id: "services", label: "Services", render: services },
  { id: "packages", label: "Packages", render: packages },
  { id: "logs", label: "Logs", render: logs },
  { id: "storage", label: "Storage", render: storage },
  { id: "network", label: "Network", render: network },
  { id: "updates", label: "Updates", render: updates },
  { id: "containers", label: "Containers", render: stub("Containers") },
];

function stub(name) {
  return async (view) => view.append(el("p", { text: name + " — planned; not built yet." }));
}

async function overview(view) {
  const s = await getJSON("system");
  document.getElementById("hostname").textContent = s.hostname;
  const cpuEl = el("span", { text: "…" }), memEl = el("span", {}), loadEl = el("span", {});
  view.append(el("dl", {},
    el("dt", { text: "CPU usage" }), el("dd", {}, cpuEl),
    el("dt", { text: "Memory" }), el("dd", {}, memEl),
    el("dt", { text: "Load (1/5/15m)" }), el("dd", {}, loadEl),
    el("dt", { text: "OS" }), el("dd", { text: s.os || "Blueberry Linux" }),
    el("dt", { text: "Kernel" }), el("dd", { text: s.kernel }),
    el("dt", { text: "CPU" }), el("dd", { text: (s.cpu && s.cpu.model) || "—" }),
    el("dt", { text: "Cores" }), el("dd", { text: String((s.cpu && s.cpu.cores) || 0) }),
    el("dt", { text: "Uptime" }), el("dd", { text: fmtUptime(s.uptime_seconds) }),
    el("dt", { text: "Processes" }), el("dd", { text: String(s.processes || 0) }),
  ));
  const tick = async () => {
    try {
      const m = await getJSON("metrics");
      cpuEl.textContent = m.cpu_pct.toFixed(0) + "%";
      const mp = m.memory.total_kb ? Math.round((1 - m.memory.available_kb / m.memory.total_kb) * 100) : 0;
      memEl.textContent = mp + "% of " + (m.memory.total_kb / 1048576).toFixed(1) + " GiB";
      loadEl.textContent = (m.load || []).map((x) => x.toFixed(2)).join("  ");
    } catch (_) { if (liveTimer) { clearInterval(liveTimer); liveTimer = null; } }
  };
  await tick();
  liveTimer = setInterval(tick, 2500);
}

async function services(view) {
  const { services } = await getJSON("services");
  const act = async (unit, action) => {
    await api("services/" + action + "?unit=" + encodeURIComponent(unit), { method: "POST" });
    render("services");
  };
  const btn = (label, unit, action) => {
    const b = el("button", { text: label });
    b.addEventListener("click", () => act(unit, action));
    return b;
  };
  const rows = services.map((s) => {
    const running = s.active === "active";
    return el("tr", {},
      el("td", { text: s.unit }),
      el("td", { text: running ? "running" : (s.sub || s.active) }),
      el("td", { text: s.description }),
      el("td", {},
        running ? btn("Stop", s.unit, "stop") : btn("Start", s.unit, "start"),
        document.createTextNode(" "),
        btn("Restart", s.unit, "restart")));
  });
  view.append(el("h2", { text: "Services (" + services.length + ")" }),
    table(["Unit", "State", "Description", ""], rows));
}

async function packages(view) {
  const { packages } = await getJSON("packages");
  const rows = packages.map((p) => el("tr", {}, el("td", { text: p.name }), el("td", { text: p.version })));
  view.append(el("h2", { text: "Packages (" + packages.length + ")" }), table(["Name", "Version"], rows));
}

async function logs(view) {
  const sel = el("select", {});
  [["All", ""], ["Notice+ (≤5)", "5"], ["Warning+ (≤4)", "4"], ["Error+ (≤3)", "3"]].forEach(([label, val]) => {
    const o = el("option", { value: val }); o.textContent = label; sel.append(o);
  });
  const body = el("div", {});
  const load = async () => {
    body.replaceChildren(el("p", { text: "Loading…" }));
    const q = "logs?lines=200" + (sel.value ? "&priority=" + sel.value : "");
    const { entries } = await getJSON(q);
    const rows = entries.slice().reverse().map((e) => el("tr", {},
      el("td", { text: fmtTime(e.t) }),
      el("td", { text: prioLabel(e.priority) }),
      el("td", { text: e.unit || "—" }),
      el("td", { text: e.message })));
    body.replaceChildren(table(["Time", "Level", "Unit", "Message"], rows));
  };
  sel.addEventListener("change", load);
  view.append(el("h2", { text: "Logs" }),
    el("p", {}, el("label", {}, document.createTextNode("Level: "), sel)), body);
  await load();
}

async function storage(view) {
  const { filesystems, devices } = await getJSON("storage");
  const rows = filesystems.map((f) => el("tr", {},
    el("td", { text: f.mount }),
    el("td", { text: f.source }),
    el("td", { text: fmtBytes(f.total) }),
    el("td", { text: fmtBytes(f.used) }),
    el("td", { text: fmtBytes(f.available) }),
    el("td", { text: f.use_pct + "%" })));
  view.append(el("h2", { text: "Filesystems" }),
    table(["Mount", "Source", "Size", "Used", "Available", "Use"], rows));

  if (devices && devices.length) {
    const flat = [];
    const walk = (d, dep) => { flat.push([d, dep]); (d.children || []).forEach((c) => walk(c, dep + 1)); };
    devices.forEach((d) => walk(d, 0));
    const drows = flat.map(([d, dep]) => el("tr", {},
      el("td", { text: "  ".repeat(dep) + (d.name || "") }),
      el("td", { text: d.type || "" }),
      el("td", { text: fmtBytes(d.size) }),
      el("td", { text: d.fstype || "" }),
      el("td", { text: d.mountpoint || "" })));
    view.append(el("h2", { text: "Block devices" }),
      table(["Name", "Type", "Size", "FS", "Mount"], drows));
  }

  // POST helper shared by the ZFS + Btrfs actions.
  const post = async (path, okMsg) => {
    const r = await api(path, { method: "POST" });
    if (r.ok) { render("storage"); }
    else { const e = await r.json().catch(() => ({})); alert((okMsg || "action") + " failed: " + (e.error || ("HTTP " + r.status))); }
  };

  // ── ZFS ───────────────────────────────────────────────────────────────────
  const z = await getJSON("zfs");
  view.append(el("h2", { text: "ZFS" }));
  if (!z.available) {
    view.append(el("p", { text: "ZFS userland not installed." }));
  } else {
    if (z.note) view.append(el("p", { text: z.note }));
    const prows = z.pools.map((p) => {
      const b = el("button", { text: "Scrub" });
      b.addEventListener("click", () => { if (confirm("Start a scrub of pool '" + p.name + "'?")) post("zfs/scrub?pool=" + encodeURIComponent(p.name), "scrub"); });
      return el("tr", {},
        el("td", { text: p.name }), el("td", { text: p.health }),
        el("td", { text: fmtBytes(p.size) }), el("td", { text: fmtBytes(p.alloc) }),
        el("td", { text: fmtBytes(p.free) }), el("td", { text: p.capacity + "%" }), el("td", {}, b));
    });
    view.append(el("h3", { text: "Pools" }),
      z.pools.length ? table(["Pool", "Health", "Size", "Alloc", "Free", "Cap", ""], prows)
                     : el("p", { text: "No pools imported." }));
    if (z.datasets && z.datasets.length) {
      const drows = z.datasets.map((d) => {
        const b = el("button", { text: "Snapshot" });
        b.addEventListener("click", () => {
          const n = prompt("Snapshot name for '" + d.name + "':", "manual");
          if (n) post("zfs/snapshot?dataset=" + encodeURIComponent(d.name) + "&name=" + encodeURIComponent(n), "snapshot");
        });
        return el("tr", {},
          el("td", { text: d.name }), el("td", { text: d.type }),
          el("td", { text: fmtBytes(d.used) }), el("td", { text: fmtBytes(d.avail) }),
          el("td", { text: d.mountpoint }), el("td", {}, b));
      });
      view.append(el("h3", { text: "Datasets" }), table(["Dataset", "Type", "Used", "Avail", "Mount", ""], drows));
    }
    if (z.snapshots && z.snapshots.length) {
      const srows = z.snapshots.map((s) => el("tr", {},
        el("td", { text: s.name }), el("td", { text: fmtBytes(s.used) }),
        el("td", { text: fmtBytes(s.refer) }), el("td", { text: fmtTime(s.creation) })));
      view.append(el("h3", { text: "Snapshots" }), table(["Snapshot", "Used", "Refer", "Created"], srows));
    }
  }

  // ── Btrfs ──────────────────────────────────────────────────────────────────
  const bt = await getJSON("btrfs");
  view.append(el("h2", { text: "Btrfs" }));
  if (!bt.available) {
    view.append(el("p", { text: "btrfs-progs not installed (bpm install btrfs-progs)." }));
  } else if (!bt.filesystems.length) {
    view.append(el("p", { text: "No btrfs filesystems mounted." }));
  } else {
    bt.filesystems.forEach((f) => {
      const mq = encodeURIComponent(f.mount);
      const scrubB = el("button", { text: "Scrub" });
      scrubB.addEventListener("click", () => { if (confirm("Start a scrub of '" + f.mount + "'?")) post("btrfs/scrub?mount=" + mq, "scrub"); });
      const snapB = el("button", { text: "Snapshot" });
      snapB.addEventListener("click", () => {
        const n = prompt("Read-only snapshot name for '" + f.mount + "' (into .snapshots/):", "manual");
        if (n) post("btrfs/snapshot?mount=" + mq + "&name=" + encodeURIComponent(n), "snapshot");
      });
      const newB = el("button", { text: "New subvolume" });
      newB.addEventListener("click", () => {
        const n = prompt("New subvolume name under '" + f.mount + "':");
        if (n) post("btrfs/subvol-create?mount=" + mq + "&name=" + encodeURIComponent(n), "create");
      });
      view.append(el("h3", { text: f.mount + "  (" + f.device + ")" }),
        el("p", {}, document.createTextNode(fmtBytes(f.used) + " used of " + fmtBytes(f.total) + "   "),
          scrubB, document.createTextNode(" "), snapB, document.createTextNode(" "), newB));

      const delBtn = (p) => {
        const b = el("button", { text: "Delete" });
        b.addEventListener("click", () => { if (confirm("Delete subvolume '" + p + "' permanently?")) post("btrfs/subvol-delete?mount=" + mq + "&path=" + encodeURIComponent(p), "delete"); });
        return b;
      };
      if (f.subvolumes && f.subvolumes.length) {
        view.append(el("h4", { text: "Subvolumes (" + f.subvolumes.length + ")" }),
          table(["Path", ""], f.subvolumes.map((p) => el("tr", {}, el("td", { text: p }), el("td", {}, delBtn(p))))));
      }
      if (f.snapshots && f.snapshots.length) {
        const rows = f.snapshots.map((p) => {
          const rb = el("button", { text: "Rollback" });
          rb.addEventListener("click", async () => {
            if (!confirm("Roll back to snapshot '" + p + "'?\n\nThis makes it the default subvolume and takes effect after a REBOOT. The running system is unchanged until you reboot.")) return;
            const r = await api("btrfs/rollback?mount=" + mq + "&path=" + encodeURIComponent(p), { method: "POST" });
            const d = await r.json().catch(() => ({}));
            if (r.ok) alert("Rollback prepared — reboot to boot into '" + p + "'.");
            else alert("rollback failed: " + (d.error || ("HTTP " + r.status)));
          });
          return el("tr", {}, el("td", { text: p }), el("td", {}, rb, document.createTextNode(" "), delBtn(p)));
        });
        view.append(el("h4", { text: "Snapshots (" + f.snapshots.length + ")" }), table(["Path", ""], rows));
      }
    });
  }
}

async function updates(view) {
  const u = await getJSON("updates");
  view.append(el("h2", { text: "Updates" }));
  if (!u.count) {
    view.append(el("p", { text: "Everything is up to date." }));
  } else {
    const rows = u.updates.map((p) => el("tr", {},
      el("td", { text: p.name }), el("td", { text: p.installed }), el("td", { text: "→ " + p.available })));
    view.append(el("p", { text: u.count + " package(s) can be upgraded." }),
      table(["Package", "Installed", "Available"], rows));
  }

  const snapCb = el("input", { type: "checkbox" });
  if (u.btrfs_root) snapCb.checked = true;
  const out = el("pre", {});
  const btn = el("button", { text: "Upgrade all" });
  btn.addEventListener("click", async () => {
    const withSnap = snapCb.checked && u.btrfs_root;
    if (!confirm("Run bpm upgrade now?" + (withSnap ? " A pre-upgrade btrfs snapshot will be taken first." : ""))) return;
    btn.disabled = true; out.textContent = "Upgrading… (this can take a while)";
    try {
      const r = await api("updates/apply?snapshot=" + (snapCb.checked ? "1" : "0"), { method: "POST" });
      const d = await r.json().catch(() => ({}));
      out.textContent = r.ok
        ? (d.snapshot ? "Pre-upgrade snapshot: " + d.snapshot + "\n\n" : "") + (d.output || "(no output)")
        : "Upgrade failed: " + (d.error || ("HTTP " + r.status));
    } catch (e) { out.textContent = "Error: " + ((e && e.message) || e); }
    btn.disabled = false;
  });
  const controls = el("p", {});
  if (u.btrfs_root) controls.append(snapCb, document.createTextNode(" snapshot root before upgrading   "));
  else controls.append(el("span", { text: "(root is not btrfs — no snapshot/rollback available)   " }));
  controls.append(btn);
  view.append(controls, out);
}

async function network(view) {
  const { interfaces, gateway } = await getJSON("network");
  view.append(el("h2", { text: "Network" }), el("p", { text: "Default gateway: " + (gateway || "—") }));
  const rows = interfaces.map((i) => el("tr", {},
    el("td", { text: (i.up ? "● " : "○ ") + i.name }),
    el("td", { text: i.mac || "—" }),
    el("td", { text: (i.addrs || []).map((a) => a.address).join(", ") || "—" })));
  view.append(table(["Interface", "MAC", "Addresses"], rows));
}

// ── shell / routing ───────────────────────────────────────────────────────────
function buildNav() {
  const nav = document.getElementById("nav");
  nav.replaceChildren();
  PANELS.forEach((p) => {
    const a = el("button", { text: p.label });
    a.dataset.id = p.id;
    a.addEventListener("click", () => render(p.id));
    nav.append(a, document.createTextNode(" "));
  });
}

async function render(id) {
  if (liveTimer) { clearInterval(liveTimer); liveTimer = null; }
  const panel = PANELS.find((p) => p.id === id) || PANELS[0];
  const view = document.getElementById("view");
  view.replaceChildren(el("p", { text: "Loading…" }));
  try { view.replaceChildren(); await panel.render(view); }
  catch (e) { view.replaceChildren(el("p", { text: "Error: " + ((e && e.message) || e) })); }
}

function showApp() {
  document.getElementById("login").hidden = true;
  document.getElementById("app").hidden = false;
  buildNav();
  render("overview");
}
function showLogin() {
  if (liveTimer) { clearInterval(liveTimer); liveTimer = null; }
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
