# Blueberry Website — Build & Deploy Spec (handoff)

> **Audience:** the AI/engineer building the site. This is a complete,
> self-contained brief. Everything you need — repo facts, data sources, design,
> sections, build, and how to deploy on the target host — is here.
>
> **Hosting target:** a **Rocky Linux** machine on the **LAN** (self-hosted with
> nginx). *Not* GitHub Pages. The bootable images are still published to GitHub
> Releases (see §9); the site links to them.

---

## 1. What to build

A single-page **React 18 + Vite 5** static site for Blueberry Linux. It pulls
live data from the GitHub REST API (latest release, recent commits, CI status)
and degrades gracefully to baked-in defaults when the API is unavailable or
rate-limited. No backend, no database, no trackers, no analytics.

Output is a static `dist/` folder served by nginx on the Rocky box.

---

## 2. Project facts (use these exact values)

| Key | Value |
|-----|-------|
| GitHub owner | `zsigisti` |
| GitHub repo | `blueberry` |
| Repo URL | `https://github.com/zsigisti/blueberry` |
| Default branch | `master` |
| CI workflow file | `.github/workflows/ci.yml` (name: **CI**) |
| Release tag pattern | `v*` (e.g. `v0.1.0`) |
| License | GPL-3.0-or-later (kernel GPL-2.0, busybox GPL-2.0, runit BSD-3, glibc LGPL-2.1, dropbear MIT) |

**Component versions** (source of truth is `Make.config` — read them from there
at build time if you can; otherwise hard-code these):

| Component | Version | Role | License |
|-----------|---------|------|---------|
| Linux kernel | 7.0 | kernel | GPL-2.0 |
| glibc | 2.43 | C library (dynamic, pinned `.bpm` from the mirror) | LGPL-2.1 |
| busybox | 1.36.1 | userland (standalone shell) | GPL-2.0 |
| runit | 2.1.2 | init (disk-boot path) | BSD-3-Clause |
| Dropbear | 2024.86 | SSH server + client | MIT |

**Tested hardware** (from `doc/DEPLOY.md` — keep in sync):

| Machine | CPU | Firmware | Result |
|---------|-----|----------|--------|
| Dell Latitude 3140 | Intel N100 | UEFI | boots to live CLI on the laptop screen |
| QEMU (`-cdrom`) | — | SeaBIOS (BIOS) | ✅ |
| QEMU + OVMF | — | UEFI | ✅ |

**Default credentials baked into images** (display with a "change this" warning):
root password is `blueberry`. This is intentionally public — it is *not* a
secret, it's the documented default of the live image.

**Key commands to show** (copy-to-clipboard):
```sh
# write to USB
sudo dd if=blueberry-<ver>-x86_64.iso of=/dev/sdX bs=4M status=progress oflag=sync
# boot in QEMU
qemu-system-x86_64 -cdrom blueberry-<ver>-x86_64.iso -m 512M -nographic
# ssh in
ssh root@<box-ip>          # password: blueberry
```

---

## 3. Secrets & tokens (IMPORTANT — do not hard-code)

- The site reads **public** GitHub data, which works **unauthenticated**
  (limited to ~60 requests/hour per client IP). That's enough for a low-traffic
  LAN page with caching.
- If you want higher limits, support an **optional** read-only token via a Vite
  env var: `VITE_GITHUB_TOKEN`. Read it with `import.meta.env.VITE_GITHUB_TOKEN`
  and send `Authorization: Bearer <token>` only when present.
  - The token is a **fine-grained PAT** with *public-repo read* scope only.
  - It goes in a local, git-ignored `site/.env.local` — **never commit it**, and
    note that a `VITE_*` var is embedded in the built JS, so only use a
    read-only, public-scope token (don't treat it as confidential).
- There are **no other credentials**. Static hosting needs none.

---

## 4. Tech stack & conventions

- **Vite 5 + React 18**, plain JSX (TypeScript optional, fine either way).
- No CSS framework — hand-written CSS (CSS modules or a single `styles.css`).
- No router needed (single page; anchor-scroll between sections).
- Minimal deps. Client-side `fetch()` for GitHub data; no server.
- `vite.config.js`: set `base: '/'` (served at the host root on the LAN box). If
  it ends up under a subpath, set `base` accordingly.
- Lighthouse-friendly: no blocking JS for first paint, system/monospace fonts,
  lazy data fetches.

---

## 5. Design system

- **Background:** `#07081a` (deep indigo/near-black). Optional subtle radial
  glow in violet.
- **Accent:** `#a78bfa` (violet). Hover/active a touch brighter.
- **Text:** off-white `#e6e6f0`; muted `#9aa0b4`.
- **Surfaces/cards:** `#0e1030` with `1px` border `#1c1f44`, ~12px radius.
- **Type:** monospace throughout (`ui-monospace, "JetBrains Mono", Menlo,
  Consolas, monospace`). This is a CLI distro — lean into the terminal look.
- **Layout:** single column, max-width ~960px, generous vertical rhythm, mobile
  first. Sticky slim top nav with anchor links to the sections.
- **Hero logo:** the ASCII-art blueberry from the boot banner, rendered in a
  `<pre>` in the violet accent. (Source: `src/initramfs/init`, the `banner()`
  heredoc.)
- No external font CDNs, no icon-font CDNs (keep it offline/LAN-friendly — inline
  SVG icons if needed).

---

## 6. Sections (single page, in order)

1. **Hero** — name "Blueberry Linux", one-line pitch ("A minimal Linux that
   boots from a single source tree straight into a live CLI"), the ASCII logo,
   a **version pill** (latest release tag, live) and a **CI status** indicator
   (live), and a compact component strip (kernel/glibc/busybox/runit/dropbear
   versions).
2. **Download** — two cards: **ISO** (hybrid BIOS+UEFI) and **Disk image**
   (UEFI). Each: a download button (links to the latest GitHub Release asset),
   the `dd` one-liner, an expandable QEMU command, the asset's **SHA-256**
   (from the release's `SHA256SUMS`), and size. Copy-to-clipboard on commands.
3. **What's Inside** — the component table from §2 (version + role + license).
4. **Quick Start** — 5-step terminal walkthrough: clone → `make world` →
   `make run` (or `dd` → boot) → `root@blueberry:~#` → `ssh root@…`. Each step a
   "terminal" block with copy buttons. Include the default-password note with a
   "change in production" warning.
5. **How It Boots** — a small diagram of the three `/init` branches: `bbtest`
   (self-test), `root=` (disk boot → systemd or runit), default (live CLI: DHCP + SSH +
   ntpd + shell on every console).
6. **Tested Hardware** — the table from §2, plus "driver support" pills (SATA/
   NVMe/USB storage, e1000/igb/ixgbe/mlx/virtio NICs, UEFI+GPT, EFI framebuffer
   console, WireGuard, nftables).
7. **Changelog / Activity** — live feed of recent commits (newest first) from
   the GitHub API: short SHA (link), message first line, relative date. Fall
   back to "see commits on GitHub" link when the API is unavailable.

Footer: repo link, docs link, latest CI run link, license line.

---

## 7. Data integration (GitHub REST API)

Base: `https://api.github.com/repos/zsigisti/blueberry`

| Need | Endpoint |
|------|----------|
| Latest release (version, assets, body) | `GET /releases/latest` |
| All tags (fallback for version) | `GET /tags?per_page=1` |
| Recent commits | `GET /commits?sha=master&per_page=15` |
| CI status (latest run of ci.yml) | `GET /actions/workflows/ci.yml/runs?per_page=1` → `conclusion` |
| CI badge image (no API) | `https://github.com/zsigisti/blueberry/actions/workflows/ci.yml/badge.svg` |

Rules:
- Send `Accept: application/vnd.github+json`. Add the bearer token only if
  `VITE_GITHUB_TOKEN` is set (§3).
- **Cache** responses in `localStorage` with a short TTL (e.g. 10 min) to avoid
  burning the unauthenticated rate limit on refreshes.
- **Graceful degradation:** on any error/429, fall back to baked-in defaults
  (the §2 values) and render a quiet "live data unavailable" state — never a
  blank section or a crash.
- Download links: prefer the latest release's assets; if there is no release
  yet, link to the repo's Releases page and show "no release yet — build with
  `make iso`".

---

## 8. Build

```sh
cd site
npm install          # generates package-lock.json — commit it
npm run dev          # local dev server
npm run build        # -> site/dist/   (what nginx serves)
npm run preview      # sanity-check the production build
```

`package.json` scripts: `dev` = `vite`, `build` = `vite build`,
`preview` = `vite preview`.

---

## 9. Release automation (images → GitHub Releases)

Add `.github/workflows/release.yml`. Trigger: push of a `v*` tag (+
`workflow_dispatch`). It builds the **real** repo targets and publishes the
images so the website's Download section has something to link to.

Steps (must match this repo's actual targets/paths):
1. `apt-get install` build deps: `build-essential bc bison flex libelf-dev
   libssl-dev wget xz-utils zstd cpio qemu-system-x86 grub2-common
   grub-pc-bin grub-efi-amd64-bin mtools xorriso`
2. `make world JOBS=$(nproc)`
3. `make test TIMEOUT=240` (gate the release on a green boot test).
4. `make iso`  → `iso/blueberry-<date>-x86_64.iso`
   `make disk` → `disk/blueberry-<date>-x86_64.img`
5. Compress the disk image: `zstd -19 disk/*.img` (raw image is sparse/large).
6. `sha256sum` the ISO and the `.img.zst` → `SHA256SUMS`.
7. Create a GitHub Release for the tag; upload the `.iso`, the `.img.zst`, and
   `SHA256SUMS`. Auto-generate notes from the commit range since the last tag.

Needs `permissions: contents: write` in the workflow. ~15–30 min per run (kernel
compile, no KVM on the runner) — only fires on tags.

> The existing **`.github/workflows/ci.yml`** (build world + QEMU boot test on
> every push) stays as-is. Do not duplicate it.

---

## 10. Deploying on the Rocky Linux LAN box

The site is static — nginx serving `dist/`. Rocky specifics: **SELinux is
enforcing** and **firewalld** is on, so both need a step (this is where most
"it works locally but 403s on the server" issues come from).

### One-time setup (as root)

```sh
dnf install -y nginx git
# Node.js to build on the box (or build elsewhere and copy dist/):
dnf module install -y nodejs:20         # or use nodesource

systemctl enable --now nginx
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https   # if you add TLS
firewall-cmd --reload

install -d -o root -g root /var/www/blueberry
```

### nginx site (`/etc/nginx/conf.d/blueberry.conf`)

```nginx
server {
    listen 80;
    server_name blueberry.lan _;          # or the box's hostname/IP
    root /var/www/blueberry;
    index index.html;

    # SPA fallback (single page; harmless if no client routing)
    location / { try_files $uri $uri/ /index.html; }

    # cache hashed Vite assets aggressively
    location /assets/ { expires 30d; add_header Cache-Control "public, immutable"; }

    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;
}
```

`nginx -t && systemctl reload nginx`

### Deploy / update script (`/usr/local/bin/blueberry-site-deploy`)

```sh
#!/bin/sh
set -e
REPO=/opt/blueberry           # a checkout of zsigisti/blueberry on the box
WEBROOT=/var/www/blueberry
cd "$REPO"
git pull --ff-only
cd site
npm ci
npm run build
rsync -a --delete dist/ "$WEBROOT"/
# SELinux: label the files so nginx (httpd_sys_content_t) can read them
restorecon -Rv "$WEBROOT" >/dev/null
echo "deployed $(git -C "$REPO" rev-parse --short HEAD)"
```

`chmod +x` it. First run: `git clone https://github.com/zsigisti/blueberry
/opt/blueberry` then run the script.

> **SELinux gotcha:** without `restorecon` (or
> `chcon -R -t httpd_sys_content_t /var/www/blueberry`), nginx gets 403 on
> everything. This is the #1 Rocky deployment trap.

### Auto-tracking GitHub (the "automatic" part)

The page already pulls live release/commit/CI data at load time, so it reflects
GitHub without redeploying. To also rebuild the static bundle when the repo
changes, run the deploy script on a timer:

`/etc/systemd/system/blueberry-site.service`
```ini
[Unit]
Description=Rebuild Blueberry site from GitHub
[Service]
Type=oneshot
ExecStart=/usr/local/bin/blueberry-site-deploy
```
`/etc/systemd/system/blueberry-site.timer`
```ini
[Unit]
Description=Periodic Blueberry site rebuild
[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true
[Install]
WantedBy=timers.target
```
`systemctl enable --now blueberry-site.timer`

(15-min pull+build is plenty for a LAN page. A push-triggered rebuild would need
a public webhook endpoint, which a LAN box doesn't have without tunneling —
the timer avoids that entirely.)

### TLS (optional, LAN)

Public Let's Encrypt needs a public DNS name. On a pure LAN, either run plain
HTTP, or use an internal CA / a self-signed cert and add it to your machines'
trust stores. Keep it simple: HTTP is fine for an internal status page.

---

## 11. File layout to create

```
site/
  index.html
  package.json
  package-lock.json          # generated by `npm install` — commit it
  vite.config.js
  .gitignore                 # node_modules, dist, .env.local
  .env.example               # documents VITE_GITHUB_TOKEN (no real value)
  src/
    main.jsx
    App.jsx
    api/github.js            # fetch + cache + graceful fallback
    data/defaults.js         # baked-in versions/hardware/commands (§2)
    components/
      Hero.jsx  Download.jsx  Inside.jsx  QuickStart.jsx
      BootFlow.jsx  Hardware.jsx  Changelog.jsx
      Terminal.jsx  CopyButton.jsx  Nav.jsx  Footer.jsx
    styles.css
.github/workflows/
  release.yml                # §9  (ci.yml already exists — leave it)
```

Add to the repo root `.gitignore` (or `site/.gitignore`): `site/node_modules/`,
`site/dist/`, `site/.env.local`.

---

## 12. Task checklist for the builder

1. Create everything in §11 with the design (§5), sections (§6), data layer
   (§7), and the §2 baked-in defaults.
2. `cd site && npm install` (commits `package-lock.json`).
3. `npm run build` and confirm `dist/` renders (`npm run preview`).
4. Add `.github/workflows/release.yml` per §9 (verify it calls `make iso`/
   `make disk` and the `iso/`+`disk/` paths — do **not** touch `ci.yml`).
5. Commit and push to `master`.
6. Deploy on the Rocky box per §10 (nginx + SELinux `restorecon` + firewalld +
   the deploy script/timer).
7. To publish the first downloadable images: `git tag v0.1.0 && git push origin
   v0.1.0` (fires `release.yml`).

---

## 13. Open questions

- Release cadence: tag manually, or auto-tag dated snapshots on a schedule?
- Ship the raw `.img.zst` as a release asset, or only the ISO + documented
  `make disk`? (Asset size.)
- Sign `SHA256SUMS` (minisign) now, or defer until there are external users?
- LAN hostname for the site (`blueberry.lan`? the box's IP?) — set `server_name`
  and any `base` accordingly.
