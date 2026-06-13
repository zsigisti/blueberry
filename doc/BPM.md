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
core https://repo.blueberry.lan/x86_64 http://mirror1.lan/x86_64 http://mirror2.lan/x86_64
```

`bpm update` and downloads try each URL in turn and fail over when one is
unreachable.

Build a repo from a directory of `.pkg.tar.zst` with `tools/mkrepo.sh`:

```sh
tools/mkrepo.sh /path/to/repo      # writes /path/to/repo/bpm.index
```

Mirroring the repo across servers is handled by a separate project:
**[blueberry-mirror](https://github.com/zsigisti/blueberry-mirror)**
(`bpm-mirror-sync` + nginx + a systemd timer).

## Example

```sh
bpm update
bpm install wireguard-tools     # pulls deps, verifies checksums, installs
bpm list
bpm owns /usr/bin/wg
bpm remove wireguard-tools
```
