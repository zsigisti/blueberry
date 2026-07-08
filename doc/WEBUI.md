# Blueberry Console (web UI)

A first-party web console to manage a Blueberry server — a deliberately scoped
alternative to Cockpit/Proxmox that integrates the one thing that's uniquely
Blueberry: `bpm` + a rolling, snapshot/rollback-able base.

This document describes the **base layer** (`src/bbconsole`, package
`blueberry-console`) and the far vision it's built to grow into.

## What ships today (the base layer)

- **`bbconsole`** — a small privileged daemon (Rust, pure-std HTTP, one runtime
  dependency: `serde_json`). It wraps tools that already exist on the box —
  `systemctl`, `bpm`, `/proc` — behind a versioned, authenticated, audited JSON
  API, and serves a single-page frontend.
- **API** (`/api/v1`): `system` (host/CPU/swap/processes), `metrics` (live
  per-core CPU%, memory, load — sampled server-side), `services` (list +
  start/stop/restart), `packages` (via `bpm`), `logs` (journald, filterable by
  priority/unit), `storage` (filesystems + block devices), `zfs` (pools/datasets/
  snapshots + scrub/snapshot actions; degrades to `{available:false}`), `network` (interfaces,
  MACs, addresses, gateway). Remaining far-vision areas (`containers`, `updates`)
  return `501` with a stable shape so the frontend can grow without churn.
- **Frontend** — a **pure HTML/JS SPA, no CSS/framework/build step**
  (`/usr/share/blueberry-console/web`):
  a live overview (auto-refreshing CPU/memory/load), plus services, packages,
  logs, storage, and network panels — and a stub tab per remaining roadmap area.

## Security model

The console is **privileged by design** (it manages services and packages), so
the boundary is the whole game:

- **HTTPS by default.** `bbconsole` serves TLS natively (rustls); on first start
  it generates a self-signed cert at `/etc/blueberry/console/{cert,key}.pem`
  (drop in a real one to replace it). The generated cert is RSA-4096/SHA-256 with
  proper extensions and a SAN list built from `localhost`, the hostname, and every
  global IP the box holds — so reaching it by IP doesn't add a name-mismatch on top
  of the untrusted-CA warning. There is **no plaintext mode** — a client speaking
  HTTP just fails. HSTS is sent on every response. It binds
  `0.0.0.0:9090` by default so the LAN can reach it over TLS; set
  `BBCONSOLE_BIND=127.0.0.1:9090` to keep it local. An nginx vhost (on `:443`,
  for a real cert) is optional, not required.
- **Brute-force throttle.** After 8 failed logins from an IP within 5 minutes,
  further attempts are refused (429) until it cools off.
- **PAM auth (primary, like Proxmox's PAM realm).** A real system user signs in
  with their username + password, authenticated through PAM
  (`/etc/pam.d/blueberry-console` → `pam_unix` → `/etc/shadow`). Authentication is
  then gated by **authorization**: only `root` or members of the admin group
  (default `wheel`, `BBCONSOLE_ADMIN_GROUP`) may log in — a valid password for a
  non-admin user is rejected.
- **Bearer-token sessions (primary credential).** A successful login mints a
  random session token (32 bytes from the kernel CSPRNG) and returns it in the
  JSON body. The client holds it and sends it as `Authorization: Bearer <token>`
  on every call. This is deliberately **not** an ambient cookie: it survives
  browsers that drop `Secure` cookies over a self-signed cert, and it is immune to
  CSRF (a cross-site page can't set a custom header). Sessions live in memory with
  a **1-hour idle** timeout *and* an **8-hour absolute** cap, and are re-checked on
  every request. `GET /api/v1/whoami` echoes the current user + CSRF token.
- **Cookie mirror + CSRF.** Login also sets a `HttpOnly; Secure; SameSite=Strict`
  `bbc_session` cookie for convenience. Any *state-changing* request authenticated
  by the cookie (rather than the Bearer header) must also send a matching
  `X-BBC-CSRF` token (issued at login, re-fetchable via `whoami`); otherwise it is
  refused with `403`. Bearer-authed writes are exempt (no ambient credential to
  forge). Logout revokes the session server-side and clears the cookie.
- **Bootstrap token (fallback/automation).** On first start the daemon also
  writes a random admin token to `/etc/blueberry/console/token` (mode 0600),
  usable for headless setup before an admin account exists, or for scripts.
  `POST /api/v1/login {"token": "..."}` instead of username/password. An empty
  configured token never matches (fail closed).
- **Small surface.** Pure-std HTTP, hard request-size limits (2 MiB body, 8 KiB
  per line, 32 KiB of headers — each enforced *while* reading, so no unbounded
  buffer), one request per connection, path-traversal guard on static files,
  security headers + a strict CSP on every response. With no inline styles or
  scripts anywhere, the CSP is tight: `default-src 'self'; frame-ancestors 'none';
  base-uri 'none'`. Two pure HTML/JS frontends ship: the full console (`/`) and a
  minimal login-only client (`/login.html`) that surfaces raw HTTP status codes.
- **DoS resistance.** Every socket has a 20 s I/O timeout (bounds the TLS
  handshake, request read, and response write) so a slow/idle client can't pin a
  worker thread (slow-loris); concurrent connections are capped so a flood can't
  spawn unbounded threads. Service actions pass `--` and reject names starting
  with `-`, so a unit name can never be parsed as a `systemctl` flag.
- **Write actions are few, validated, and audited.** Service actions accept only
  `start`/`stop`/`restart` on a validated unit name; every login and write is
  appended to `/var/log/blueberry-console/audit.log`.

Run it:

```sh
bpm install blueberry-console
systemctl enable --now blueberry-console
# reach https://<host-ip>:9090 (accept the self-signed-cert warning) and sign in
# with a system account: root (the live ISO ships a documented default password,
# "blueberry" — change it with `passwd`), or an admin-group user you created with
#   useradd -m -G wheel admin && passwd admin
# The bootstrap token in /etc/blueberry/console/token works for headless/automation.
```

## To-do (near-term)

Concrete, mostly-small tasks on the current base layer:

- [ ] **Session panel** — surface `whoami`/`active()` in the UI; list + revoke
      live sessions (`revoke_user` already exists).
- [ ] **Change-password flow** — `passwd` via PAM from the UI; revoke the user's
      other sessions on success.
- [ ] **Server-side rate limiting** on *all* endpoints (not just login), plus a
      per-connection read timeout (slow-loris guard).
- [ ] **Structured audit** — JSON lines (ts, ip, user, action, result) instead of
      free text; ship a log-rotate drop-in.
- [ ] **Config surface** — expose `BBCONSOLE_*` (bind, admin group, TLS paths) via
      a read-only settings panel.
- [ ] **Real-cert helper** — a one-shot to drop in a cert/key (and, later, ACME
      DNS-01 for a hostname — see below).
- [ ] **Tests** — an integration harness that boots the daemon on a scratch dir
      and asserts the auth matrix (the flow this doc describes).
- [ ] **Graceful systemctl** — bound the `systemctl` calls with a timeout so a
      hung unit can't wedge a request thread.

## Security roadmap

Building out from the current model (Bearer sessions + CSRF + PAM authz):

1. **Roles** — beyond binary admin: read-only vs operator vs admin, mapped from
   groups; enforce per-endpoint.
2. **2FA / TOTP** — optional second factor after PAM, per user.
3. **ACME / real certs** — DNS-01 (Proxmox-style) for a hostname, auto-renewing;
   removes the browser warning without per-device CA installs.
4. **Session binding** — optionally pin a session to its origin IP / user-agent;
   configurable for NAT'd setups.
5. **PAM hardening** — `pam_faillock` in the console PAM stack; account/expiry
   checks; optional `pam_env`.
6. ~~**CSP tightening**~~ — *done (0.6.0):* the frontend is pure HTML/JS with no
   inline styles/scripts, so the CSP is now `default-src 'self'; frame-ancestors
   'none'; base-uri 'none'`.
7. **Privilege reduction** — split a thin privileged helper from the HTTP daemon
   so the network-facing process isn't full root.

## Far vision (feature panels)

Each area extends the `/api/v1` surface + adds a frontend panel; the base layer's
router, auth, and audit don't change.

1. **Containers** — podman (there's already a `podman.socket` REST API to proxy):
   list/start/stop/logs, images, pods; rootless-aware.
2. **Updates + rollback** — the differentiator. Surface `bpm` updates, and if the
   root is btrfs: snapshot → `bpm upgrade` → one-click rollback if it broke. No
   other console does this for a source-built rolling distro.

Shipped (0.5.0): **Logs** (journald, priority filter), **Storage** (filesystems +
block devices), **Network** (interfaces/addresses/gateway), and a **live overview**
(auto-refreshing per-core CPU / memory / load).
Shipped (0.7.0): **ZFS** in the Storage panel — pools (size/alloc/free/health/cap),
datasets, and snapshots, with safe **scrub** and **snapshot** actions (validated
pool/dataset names, no option injection, audited). Needs the `zfs` userland (not
yet packaged — the panel shows "not installed" until then). Next: dataset
create/destroy, snapshot rollback/destroy, pool import/export; storage SMART;
logs follow/tail; network firewall (nftables) + wireguard.

## Extending

- A new read panel = one handler in `src/bbconsole/src/api.rs` + a match arm in
  `api_route` + one entry in `PANELS` in `web/app.js`.
- Keep write actions argument-validated and audited (see `service_action`).
- Keep the daemon localhost-bound and dependency-light; push exposure/TLS to the
  proxy layer.
