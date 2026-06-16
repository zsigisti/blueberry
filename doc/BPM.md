# bpm — Blueberry Package Manager

`bpm` installs Arch-format binary packages (`.pkg.tar.zst`) — the output of the
PKGBUILDs in [`packages/`](../packages/) (built locally with `makepkg` or on
OBS). It is a small POSIX-sh program (`src/bpm/bpm`) that runs natively on the
busybox/glibc live system; the only extra runtime it needs is the bundled
`zstd` binary (busybox has no zstd).

## Commands

```sh
bpm install <name|file.pkg.tar.zst>...   install (resolve deps from repos)
bpm remove  <name>...                    remove installed package(s)
bpm update                               sync repo indices
bpm upgrade                              upgrade all installed packages
bpm search  <term>                       search the repo index
bpm list                                 list installed packages
bpm info    <name>                       show package metadata
bpm files   <name>                       list files a package owns
bpm owns    <path>                       which package owns a path
```

`BPM_ROOT=<dir>` installs into a staging root instead of `/` (used for image
assembly and tests).

## How it works

- **Database:** `/var/lib/bpm/db/<name>/{desc,files}` — `desc` is the package's
  `.PKGINFO`; `files` is the owned-file list (used by `remove` and `owns`).
- **Index:** `/var/lib/bpm/index`, fetched by `bpm update`. Each line is
  `name|version|filename|sha256|deps|repo`.
- **Cache:** `/var/lib/bpm/cache/`.
- **Integrity:** every download is checked against the sha256 from the index.
- **Dependencies:** `install <name>` resolves `depend` entries recursively;
  names not in any repo are assumed provided by the base system (glibc, bash…).

## Repositories and mirrors

`/etc/bpm/repos.conf` — one line per repo, origin first then mirrors:

```
core https://repo.mmzsigmond.me http://mirror1.lan http://mirror2.lan
```

`bpm update` and downloads try each URL in turn and fail over when one is
unreachable. Integrity is the per-package SHA-256 recorded in `bpm.index`
(verified on every download), with the index fetched over TLS — there is no
index signing.

Build a repo from a directory of `.pkg.tar.zst` with `tools/mkrepo.sh`:

```sh
tools/mkrepo.sh /path/to/repo      # writes /path/to/repo/bpm.index
```

### Building + publishing a repo

`tools/blueberry-repo-sync.sh` builds the `packages/` tree and publishes the
repo. It is **incremental by content hash**: a package is rebuilt only when the
contents of its `packages/<name>/` directory change, so adding one package
builds one package, not all of them.

```sh
# build everything that changed, publish to $WEBROOT, reindex
WEBROOT=/srv/blueberry-repo tools/blueberry-repo-sync.sh

# just check what would build/publish
tools/blueberry-repo-sync.sh -n

# force a single package through the pipeline
tools/blueberry-repo-sync.sh nano
```

The build cache (`$CACHE`, default `/var/cache/blueberry-repo-sync`) is a
**private directory, never the webroot**. The webroot is a pure publish target:
artifacts are copied in, superseded versions pruned, and `bpm.index` regenerated.
Nothing served is ever used to decide what to rebuild, so a wiped or hand-edited
webroot can't trigger a full rebuild and a half-built artifact can never be
served. Builds run in an ephemeral Arch container (`ENGINE`/`IMAGE`), parallel
across all cores (`JOBS`).

### Self-hosting the build server

For a turnkey box (Proxmox LXC, Ubuntu 22.04 + nginx) that clones the recipes,
builds on a timer, and serves the repo, see **[doc/BUILDSERVER.md](BUILDSERVER.md)**.
`tools/blueberry-build-server.sh` is the one-command entry point (git pull →
repo-sync); `tools/buildserver-provision.sh` sets the whole host up.

## Example

```sh
bpm update
bpm install wireguard-tools     # pulls deps, verifies checksums, installs
bpm list
bpm owns /usr/bin/wg
bpm remove wireguard-tools
```
