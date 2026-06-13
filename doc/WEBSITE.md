# Website & Release Automation — Design

> Status: **design only** — nothing here is built yet. This document is the
> plan for an auto-updating project site + downloadable images. Tracking issue:
> _TBD_.

## 1. Goal

A zero-maintenance public site that always reflects the current state of the
repo: latest version, what's in it, how to get it, and proof it works — all
regenerated automatically from GitHub on every push, with no manual steps.

Two halves:

1. **Release automation** — every tagged release auto-builds the bootable
   images (`make iso`, `make disk`) and publishes them, with checksums, as
   GitHub Release assets. Downloads are therefore always current and verifiable.
2. **Landing page** — a static site (GitHub Pages) that shows version, download
   links, CI status, changelog, component versions, and tested hardware. Rebuilt
   on every push so it never goes stale.

Everything runs on free GitHub infrastructure (Actions + Pages + Releases). No
server to run, no database.

## 2. Architecture

```
                 ┌──────────────────── GitHub ─────────────────────┐
   git push ───► │  Actions                                        │
   git tag  ───► │   ├─ ci.yml          build world + QEMU test    │
                 │   ├─ release.yml     on tag: build images,      │
                 │   │                   checksum, create Release   │
                 │   └─ pages.yml        on push: render site,      │
                 │                        deploy to Pages           │
                 │                                                  │
                 │  Releases   ◄── ISO + disk img + SHA256SUMS      │
                 │  Pages      ◄── static site (HTML/CSS)           │
                 └──────────────────────────────────────────────────┘
                         │                          │
                  downloads (images)         https://<user>.github.io/blueberry
```

No runtime backend: the page is **static HTML generated at build time**. Live
data (latest release, commit list) is baked in by the Actions job, with an
optional sprinkle of client-side `fetch()` to the GitHub REST API for things
that should feel live (e.g. latest release, CI badge) without a rebuild.

## 3. Release automation (`.github/workflows/release.yml`)

Trigger: push of a tag matching `v*` (e.g. `v0.1.0`), plus `workflow_dispatch`.

Steps:
1. Install build deps (same as `ci.yml`) + `grub`, `mtools`, `xorriso`.
2. `make world JOBS=$(nproc)`
3. `make test TIMEOUT=240` — gate the release on a green boot test.
4. `make iso` and `make disk`.
5. Generate `SHA256SUMS` over both images.
6. Create a GitHub Release for the tag and upload:
   - `blueberry-<ver>-x86_64.iso`
   - `blueberry-<ver>-x86_64.img.zst` (zstd-compressed; raw images are sparse
     and huge, so compress before upload)
   - `SHA256SUMS`
7. Auto-generate release notes from the commit range since the previous tag.

Notes / decisions:
- **Compress the disk image** (`zstd`) before upload — a 2 GB raw image is
  mostly zeros and compresses to a few MB.
- **Build cost:** a full `make world` (kernel compile) is ~15–30 min on a GitHub
  runner with no KVM. Only runs on tags, so it's infrequent. Cache the kernel
  source tarball and `ccache` if it gets annoying.
- **Versioning:** derive the version from the git tag; thread it into
  `KERNEL_LOCALVERSION` and the image filenames.
- **Provenance (later):** optionally sign `SHA256SUMS` (minisign/cosign) and add
  SLSA build provenance so downloads are verifiable end-to-end.

## 4. Landing page (`.github/workflows/pages.yml` + `site/`)

Trigger: push to `master` (and after a release completes), plus
`workflow_dispatch`.

Generation: keep it dead simple — a single static page. Options, simplest first:
- **Plain HTML + a tiny build script** (`site/build.sh`) that injects values
  (version, dates, component versions parsed from `Make.config`) into a
  template. No framework, no node_modules.
- Or a static-site generator (Astro/Eleventy) if it grows. Not needed at first.

The job:
1. Read `Make.config` for component versions (Linux/musl/busybox/runit/dropbear).
2. Read the latest tag/release for the version + download URLs.
3. Render `site/index.html` from the template.
4. Deploy to GitHub Pages via `actions/deploy-pages`.

### Page sections

- **Hero:** name, one-line pitch, current version + build date, CI status badge.
- **Download:** buttons for the latest ISO and disk image, with the `dd`
  one-liner and the SHA-256 to verify. Pulls from the latest Release.
- **What's inside:** the component table (Linux/musl/busybox/runit/dropbear
  versions) — generated from `Make.config`, so it's always accurate.
- **Boot it:** the 3-line quick start (`dd` → boot → `root@blueberry`), with the
  default-password note.
- **Tested hardware:** rendered from the table in `doc/DEPLOY.md`.
- **Changelog / activity:** recent commits since the last release (from the
  GitHub API or baked in at build time).
- **Links:** repo, docs, latest CI run.

### Look & feel

Match the blueberry identity: deep indigo/blue palette, the ASCII-art logo from
the boot banner rendered as a monospace hero, minimal and fast (no trackers, no
heavy JS). Mobile-friendly single column.

## 5. Hosting & domain

- Default: **GitHub Pages** at `https://<user>.github.io/blueberry` — free, TLS
  included, deployed by Actions.
- Custom domain (optional): point a CNAME (e.g. `blueberry.mmzsigmond.me`) at
  Pages and add a `CNAME` file; Pages provisions the cert.

## 6. Build plan (phased)

1. **Phase 1 — release workflow.** `release.yml` that builds + tests + publishes
   ISO/disk + `SHA256SUMS` on a `v*` tag. Cut `v0.1.0` to validate.
2. **Phase 2 — minimal page.** `site/` template + `pages.yml` deploying a static
   page with version, download links (to the Phase 1 release), component table,
   and quick start.
3. **Phase 3 — liveness.** Changelog feed + CI badge + tested-hardware section;
   light client-side `fetch()` for latest-release info.
4. **Phase 4 — polish.** Custom domain, signed checksums/provenance, build
   caching, OG/preview metadata, favicon from the logo.

## 7. Open questions

- Release cadence — tag manually, or auto-tag (e.g. dated snapshots) on a
  schedule?
- Keep raw `.img` or ship only the ISO + a documented `make disk` for the disk
  path? (Affects asset size.)
- Do we want signed images now, or defer until there are real users?
